#!/bin/bash
# 系统实时监控模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

#!/bin/bash
# 高级系统监控模块（智能选择 btop / htop / 原生面板）

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || true
fi

# 补充可能缺少的颜色
CYAN="${CYAN:-\033[0;36m}"
PURPLE="${PURPLE:-\033[0;35m}"

# --- 主监控函数 ---
sys_monitor() {
    # 内部函数：绘制进度条
    function draw_bar() {
        local pct=$1 color=$2 width=20 num=$((pct * width / 100)) bar=""
        for ((i=0; i<num; i++)); do bar="${bar}█"; done
        for ((i=num; i<width; i++)); do bar="${bar}░"; done
        printf "${color}[%s] %3d%%${NC}" "$bar" "$pct"
    }

    # 内部函数：格式化网络速率
    function format_bytes() {
        local bytes=$1
        awk -v b="$bytes" 'BEGIN {
            if (b < 1024) printf "%.0f B/s", b;
            else if (b < 1048576) printf "%.1f KB/s", b/1024;
            else printf "%.1f MB/s", b/1048576
        }'
    }

    # 获取终端尺寸
    read rows cols < <(stty size 2>/dev/null || echo "24 80")

    # 1. 尝试 btop
    if command -v btop >/dev/null 2>&1; then
        if [ "$cols" -ge 80 ] && [ "$rows" -ge 24 ]; then
            btop
            return
        else
            printf "${YELLOW}提示: 窗口过小，降级模式。${NC}\n"
            sleep 1
        fi
    fi

    # 2. 尝试 htop
    if command -v htop >/dev/null 2>&1; then
        htop
        return
    fi

    # 3. 原生 Bash 面板
    # 获取主网络接口（有默认路由优先，否则取第一个非 lo 接口）
    local net_interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$net_interface" ]; then
        net_interface=$(ip -br link | awk '$1!="lo"{print $1; exit}')
    fi

    printf "${YELLOW}>>> 启动原生面板 (按 q 或 0 退出)...${NC}\n"
    echo -ne "\033[?25l"   # 隐藏光标

    while true; do
        # 第一轮采样
        read cpu_user1 cpu_nice1 cpu_sys1 cpu_idle1 cpu_iowait1 cpu_irq1 cpu_softirq1 cpu_steal1 < <(grep 'cpu ' /proc/stat | awk '{print $2,$3,$4,$5,$6,$7,$8,$9}')
        read rx1 tx1 < <(grep "$net_interface" /proc/net/dev 2>/dev/null | awk '{print $2,$10}')
        [ -z "$rx1" ] && rx1=0; [ -z "$tx1" ] && tx1=0   # 接口不存在时防呆

        # 等待 1 秒并同时检测按键
        read -t 1 -n 1 -s key
        if [[ "$key" == "q" || "$key" == "0" ]]; then
            printf "\n${GREEN}>>> 已退出监控${NC}\n"
            break
        fi

        # 第二轮采样
        read cpu_user2 cpu_nice2 cpu_sys2 cpu_idle2 cpu_iowait2 cpu_irq2 cpu_softirq2 cpu_steal2 < <(grep 'cpu ' /proc/stat | awk '{print $2,$3,$4,$5,$6,$7,$8,$9}')
        read rx2 tx2 < <(grep "$net_interface" /proc/net/dev 2>/dev/null | awk '{print $2,$10}')
        [ -z "$rx2" ] && rx2=0; [ -z "$tx2" ] && tx2=0

        # 计算 CPU
        cpu_total1=$((cpu_user1 + cpu_nice1 + cpu_sys1 + cpu_idle1 + cpu_iowait1 + cpu_irq1 + cpu_softirq1 + cpu_steal1))
        cpu_total2=$((cpu_user2 + cpu_nice2 + cpu_sys2 + cpu_idle2 + cpu_iowait2 + cpu_irq2 + cpu_softirq2 + cpu_steal2))
        cpu_diff=$((cpu_total2 - cpu_total1))
        cpu_idle_diff=$((cpu_idle2 - cpu_idle1))
        [ $cpu_diff -eq 0 ] && cpu_usage=0 || cpu_usage=$(( (cpu_diff - cpu_idle_diff) * 100 / cpu_diff ))

        # 内存
        mem_total=$(free -m | awk 'NR==2{print $2}')
        mem_used=$(free -m | awk 'NR==2{print $3}')
        mem_pct=$(( mem_used * 100 / mem_total ))
        # 磁盘
        disk_pct=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

        # 网络速率
        rx_rate=$((rx2 - rx1))
        tx_rate=$((tx2 - tx1))
        [ $rx_rate -lt 0 ] && rx_rate=0
        [ $tx_rate -lt 0 ] && tx_rate=0

        # 渲染
        clear
        printf "${GREEN}=== 🖥️  原生监控 (q/0退出) ===${NC}\n"
        printf "IP: %s | 运行: %s\n" "$(hostname -I | awk '{print $1}')" "$(uptime -p)"
        echo "----------------------------------------"
        printf "🧠 CPU : "; draw_bar $cpu_usage $CYAN; echo
        printf "💾 RAM : "; draw_bar $mem_pct $PURPLE; echo
        printf "💿 DISK: "; draw_bar $disk_pct $YELLOW; echo
        echo "----------------------------------------"
        printf "⬇️  下载: ${GREEN}%s${NC}\n" "$(format_bytes $rx_rate)"
        printf "⬆️  上传: ${BLUE}%s${NC}\n" "$(format_bytes $tx_rate)"
        echo "----------------------------------------"
        echo "🏆 Top 3 进程:"
        ps -eo comm,%cpu,%mem --sort=-%cpu --no-headers | head -3 | awk '{printf "   %-10s CPU:%-3s%% MEM:%-3s%%\n", $1, $2, $3}'
        echo "----------------------------------------"
    done

    echo -ne "\033[?25h"   # 恢复光标
}

# 启动监控
sys_monitor
