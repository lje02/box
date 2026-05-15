#!/bin/bash
# 系统信息与优化模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi
detect_os
check_dependencies

show_system_info() {
    clear
    printf "${BLUE}========== 系统信息 ==========${NC}\n"
    printf "主机名       : %s\n" "$(hostname)"
    printf "操作系统     : %s\n" "$(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    printf "内核版本     : %s\n" "$(uname -r)"
    printf "运行时间     : %s  启动于 %s\n" "$(uptime -p)" "$(uptime -s)"
    printf "当前用户数   : %s\n" "$(who | wc -l)"
    echo ""

    # CPU
    printf "${YELLOW}--- CPU ---${NC}\n"
    printf "型号         : %s\n" "$(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
    printf "核心/线程    : %s 核 / %s 线程\n" "$(lscpu | grep -E '^Core\(s\) per socket' | awk '{print $4}')" "$(nproc)"
    # 1 秒采样计算 CPU 使用率
    read cpu_user1 cpu_nice1 cpu_sys1 cpu_idle1 < <(grep 'cpu ' /proc/stat | awk '{print $2,$3,$4,$5}')
    sleep 1
    read cpu_user2 cpu_nice2 cpu_sys2 cpu_idle2 < <(grep 'cpu ' /proc/stat | awk '{print $2,$3,$4,$5}')
    cpu_total1=$((cpu_user1 + cpu_nice1 + cpu_sys1 + cpu_idle1))
    cpu_total2=$((cpu_user2 + cpu_nice2 + cpu_sys2 + cpu_idle2))
    cpu_diff=$((cpu_total2 - cpu_total1))
    cpu_idle_diff=$((cpu_idle2 - cpu_idle1))
    [ $cpu_diff -eq 0 ] && cpu_usage=0 || cpu_usage=$(( (cpu_diff - cpu_idle_diff) * 100 / cpu_diff ))
    printf "CPU 使用率   : %s%%\n" "$cpu_usage"
    # 负载
    printf "平均负载     : %s\n" "$(uptime | awk -F'load average:' '{print $2}' | sed 's/,//g')"
    echo ""

    # 内存
    printf "${YELLOW}--- 内存 ---${NC}\n"
    mem_total=$(free -m | awk 'NR==2{print $2}')
    mem_used=$(free -m | awk 'NR==2{print $3}')
    mem_pct=$(( mem_used * 100 / mem_total ))
    printf "内存使用     : %dMB / %dMB (%d%%)\n" "$mem_used" "$mem_total" "$mem_pct"
    # 显示缓存/可用
    mem_buff=$(free -m | awk 'NR==2{print $6}')
    printf "缓冲/缓存    : %dMB\n" "$mem_buff"
    # Swap
    swap_total=$(free -m | awk 'NR==3{print $2}')
    swap_used=$(free -m | awk 'NR==3{print $3}')
    if [ "$swap_total" -gt 0 ]; then
        swap_pct=$(( swap_used * 100 / swap_total ))
        printf "Swap 使用    : %dMB / %dMB (%d%%)\n" "$swap_used" "$swap_total" "$swap_pct"
    else
        printf "Swap         : 未启用\n"
    fi
    echo ""

    # 磁盘
    printf "${YELLOW}--- 磁盘使用 ---${NC}\n"
    df -h --type=ext4 --type=xfs --type=btrfs --type=ext3 --type=zfs 2>/dev/null || df -h | grep -vE '^(tmpfs|devtmpfs|efivarfs|overlay|none)'
    echo ""

    # 进程
    printf "${YELLOW}--- 进程 ---${NC}\n"
    printf "进程总数     : %s\n" "$(ps aux --no-headers 2>/dev/null | wc -l)"
    zombies=$(ps aux --no-headers 2>/dev/null | awk '{if ($8=="Z") print}' | wc -l)
    printf "僵尸进程     : %s\n" "$zombies"
    echo ""

    # 网络配置
    printf "${BLUE}========== 网络信息 ==========${NC}\n"
    echo "=== 网卡地址 ==="
    ip -br addr | grep -v "lo"
    echo ""
    echo "=== 默认网关 ==="
    ip route | grep default
    echo ""
    echo "=== DNS 服务器 ==="
    cat /etc/resolv.conf | grep nameserver
    echo ""

    # 公网 IPv4 (可能耗时)
    printf "${YELLOW}--- 公网 IP ---${NC}\n"
    pub_ip=$(curl -s4 --max-time 2 ifconfig.me 2>/dev/null || echo "无法获取")
    printf "IPv4         : %s\n" "$pub_ip"
    # IPv6
    pub_ip6=$(curl -s6 --max-time 2 ifconfig.me 2>/dev/null || echo "无或超时")
    printf "IPv6         : %s\n" "$pub_ip6"
    echo ""

    # 网络流量 (需要 vnstat)
    if command -v vnstat &>/dev/null; then
        iface=$(ip route | grep default | awk '{print $5}' | head -n1)
        if [ -n "$iface" ]; then
            printf "${YELLOW}--- 网络流量 (%s) ---${NC}\n" "$iface"
            vnstat -i "$iface" -d | tail -3
        fi
    fi

    echo ""
    read -p "按回车键继续..." dummy
}

install_bbr() {
    clear
    printf "${BLUE}===== BBR 加速状态与设置 =====${NC}\n"
    local kernel_full=$(uname -r)
    local kernel_ver=$(echo "$kernel_full" | cut -d. -f1-2)
    printf "当前内核版本: %s\n" "$kernel_full"

    local current_cc
    current_cc=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    printf "当前拥塞控制算法: %s\n" "${current_cc:-未知}"
    printf "当前队列算法: %s\n" "$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || echo '未知')"

    if [ "$current_cc" = "bbr" ]; then
        printf "${GREEN}BBR 已启用！${NC}\n"
        read -p "按回车键返回..." dummy
        return
    fi

    if ! printf '%s\n' "$kernel_ver" "4.9" | sort -V | head -1 | grep -q "4.9"; then
        printf "${RED}内核版本过低（当前 %s，需要 >= 4.9），不支持 BBR。${NC}\n" "$kernel_ver"
        read -p "按回车键返回..." dummy
        return
    fi

    printf "${YELLOW}BBR 未启用，是否立即开启？[Y/n]: ${NC}"
    read -p "" confirm
    if [[ ! $confirm =~ ^[Yy]?$ ]]; then
        return
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    if sysctl -p &>/dev/null; then
        printf "${GREEN}BBR 加速已激活！${NC}\n"
        printf "新拥塞控制算法: %s\n" "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    else
        printf "${RED}sysctl 应用失败，请检查配置。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

config_swap() {
    clear
    printf "${BLUE}当前 Swap 状态：${NC}\n"; swapon --show; echo ""
    read -p "输入要创建的 Swap 大小 (MB) [例如 1024]，0 取消: " swap_size
    [[ -z "$swap_size" || "$swap_size" -eq 0 ]] && return
    if [[ $swap_size =~ ^[0-9]+$ ]]; then
        if swapon --show | grep -q "swapfile"; then swapoff /swapfile; rm -f /swapfile; fi
        dd if=/dev/zero of=/ swapfile bs=1M count=$swap_size status=progress
        chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        printf "${GREEN}Swap 创建成功，大小 ${swap_size}MB${NC}\n"
    else
        printf "${RED}输入的不是有效数字${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

system_opt_menu() {
    while true; do
        clear
        printf "${BLUE}===== 系统信息与优化 =====${NC}\n"
        echo "1. 查看系统与网络信息"
        echo "2. 安装/开启 BBR"
        echo "3. 虚拟内存配置 (Swap)"
        echo "0. 返回上级菜单"
        read -p "请选择: " opt_choice
        case $opt_choice in
            1) show_system_info ;;
            2) install_bbr ;;
            3) config_swap ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n" ;;
        esac
    done
}

system_opt_menu
