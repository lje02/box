#!/bin/bash
# 系统实时监控模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

function sys_monitor() {
    # --- 内部工具函数 ---
    function draw_bar() {
        local pct=$1; local color=$2; local width=20; local num=$((pct * width / 100)); local bar=""
        for ((i=0; i<num; i++)); do bar="${bar}█"; done
        for ((i=num; i<width; i++)); do bar="${bar}░"; done
        echo -e "${color}[${bar}] ${pct}%${NC}"
    }
    function format_bytes() {
        local bytes=$1
        if (( $(echo "$bytes < 1024" | bc -l 2>/dev/null || awk 'BEGIN {print ('$bytes' < 1024)}') )); then echo "${bytes} B/s"
        elif (( $(echo "$bytes < 1048576" | bc -l 2>/dev/null || awk 'BEGIN {print ('$bytes' < 1048576)}') )); then echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1024}") KB/s"
        else echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}") MB/s"; fi
    }

    # === 获取终端尺寸 (用于判断是否开启 btop) ===
    read rows cols < <(stty size 2>/dev/null || echo "24 80")

    # === Level 1: 智能启动 btop ===
    if command -v btop >/dev/null 2>&1; then
        if [ "$cols" -ge 80 ] && [ "$rows" -ge 24 ]; then
            btop; return
        else
            echo -e "${YELLOW}提示: 窗口太小，已降级模式。${NC}"; sleep 1
        fi
    fi

    # === Level 2: htop (如果不喜欢 htop 也可以注释掉这段) ===
    if command -v htop >/dev/null 2>&1; then
        htop; return
    fi

    # === Level 3: 原生 Bash 面板 (支持按 q 退出) ===
    local net_interface=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    echo -e "${YELLOW}>>> 启动面板 (按 'q' 或 '0' 退出)...${NC}"
    
    # 隐藏光标，看起来更像专业软件
    echo -e "\033[?25l"
    
    while true; do
        # 1. 采集数据 (开始)
        read cpu_user1 cpu_nice1 cpu_sys1 cpu_idle1 cpu_iowait1 cpu_irq1 cpu_softirq1 cpu_steal1 < <(grep 'cpu ' /proc/stat | awk '{print $2,$3,$4,$5,$6,$7,$8,$9}')
        read rx1 tx1 < <(grep "$net_interface" /proc/net/dev | awk '{print $2,$10}')
        
        # [核心改进] 使用 read 等待 1 秒
        # -t 1: 超时1秒 (相当于 sleep 1)
        # -n 1: 只读取 1 个字符 (不需要按回车)
        # -s: 静默模式 (不把按键显示在屏幕上)
        read -t 1 -n 1 -s key
        
        # 检查按键
        if [[ "$key" == "q" ]] || [[ "$key" == "0" ]]; then
            echo -e "\n${GREEN}>>> 已退出监控${NC}"
            break
        fi
        
        # 2. 采集数据 (结束)
        read cpu_user2 cpu_nice2 cpu_sys2 cpu_idle2 cpu_iowait2 cpu_irq2 cpu_softirq2 cpu_steal2 < <(grep 'cpu ' /proc/stat | awk '{print $2,$3,$4,$5,$6,$7,$8,$9}')
        read rx2 tx2 < <(grep "$net_interface" /proc/net/dev | awk '{print $2,$10}')

        # 3. 计算逻辑
        cpu_total1=$((cpu_user1 + cpu_nice1 + cpu_sys1 + cpu_idle1 + cpu_iowait1 + cpu_irq1 + cpu_softirq1 + cpu_steal1))
        cpu_total2=$((cpu_user2 + cpu_nice2 + cpu_sys2 + cpu_idle2 + cpu_iowait2 + cpu_irq2 + cpu_softirq2 + cpu_steal2))
        cpu_diff=$((cpu_total2 - cpu_total1))
        cpu_idle_diff=$((cpu_idle2 - cpu_idle1))
        [ $cpu_diff -eq 0 ] && cpu_usage=0 || cpu_usage=$(( (cpu_diff - cpu_idle_diff) * 100 / cpu_diff ))

        mem_total=$(free -m | awk 'NR==2{print $2}')
        mem_used=$(free -m | awk 'NR==2{print $3}')
        mem_pct=$(( mem_used * 100 / mem_total ))
        disk_pct=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

        rx_rate=$((rx2 - rx1)); tx_rate=$((tx2 - tx1))
        rx_fmt=$(format_bytes $rx_rate); tx_fmt=$(format_bytes $tx_rate)

        # 4. 渲染界面
        clear
        echo -e "${GREEN}=== 🖥️  原生监控 (按 'q' 退出) ===${NC}"
        echo -e "IP: $(hostname -I | awk '{print $1}') | 运行: $(uptime -p)"
        echo "----------------------------------------"
        echo -n "🧠 CPU : "; draw_bar $cpu_usage $CYAN
        echo -n "💾 RAM : "; draw_bar $mem_pct $PURPLE
        echo -n "💿 DISK: "; draw_bar $disk_pct $YELLOW
        echo "----------------------------------------"
        echo -e "⬇️  下载: ${GREEN}$rx_fmt${NC}"
        echo -e "⬆️  上传: ${BLUE}$tx_fmt${NC}"
        echo "----------------------------------------"
        echo -e "🏆 Top 5: "
        ps -eo comm,%cpu,%mem --sort=-%cpu | head -n 4 | tail -n 3 | awk '{printf "   %-10s C:%-3s%% M:%-3s%%\n", $1, $2, $3, $4, $5}'
        echo "----------------------------------------"
    done
    
    # 恢复光标显示
    echo -e "\033[?25h"
}
