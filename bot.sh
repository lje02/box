BOT_DIR="/etc/sing-box"
BOT_SCRIPT="$0"  # 记录脚本自身路径
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_SERVICE="/etc/systemd/system/tg-bot.service"
SING_BOX_CONFIG="/etc/sing-box/config.json"
# 更新地址
UPDATE_URL="https://raw.githubusercontent.com/lje02/vp/main/bot.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ============================================
# 基础监控与状态函数
# ============================================

get_singbox_status() {
    if systemctl is-active --quiet sing-box; then
        echo "✅ 运行中"
        return 0
    else
        echo "❌ 已停止"
        return 1
    fi
}

get_singbox_pid() {
    pgrep -f "sing-box" | head -n1
}

get_singbox_ports() {
    local pid=$(get_singbox_pid)
    if [[ -z "$pid" ]]; then echo "未运行"; return; fi
    ss -tnp 2>/dev/null | grep "$pid" | awk '{print $4}' | sort -u | paste -sd "," -
}

get_singbox_connections() {
    local pid=$(get_singbox_pid)
    if [[ -z "$pid" ]]; then echo "0"; return; fi
    ss -tnp 2>/dev/null | grep "$pid" | grep ESTABLISHED | wc -l
}

get_singbox_memory() {
    local pid=$(get_singbox_pid)
    if [[ -z "$pid" ]]; then echo "0"; return; fi
    ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.2f MB", $1/1024}'
}

get_singbox_cpu() {
    local pid=$(get_singbox_pid)
    if [[ -z "$pid" ]]; then echo "0"; return; fi
    ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' '
}

update_bot() {
    echo -e "${YELLOW}正在从远程获取最新版本...${PLAIN}"
    # 
    echo -e "${CYAN}提示：只需将本地脚本替换为新代码，执行 'systemctl restart tg-bot' 即可热重载。${PLAIN}"
}

view_logs() {
    echo -e "${YELLOW}正在查看机器人实时日志 (Ctrl+C 退出)...${PLAIN}"
    journalctl -u tg-bot -f -n 50
}

inject_api_config() {
    local port=$1
    if [[ -f "$SING_BOX_CONFIG" ]]; then
        cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.bak"
        # 注入标准 clash_api 格式
        jq --arg port "127.0.0.1:$port" '.experimental.clash_api = {"external_controller": $port}' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
        
        if sing-box check -c "${SING_BOX_CONFIG}.tmp" &>/dev/null; then
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            systemctl restart sing-box
            echo -e "${GREEN}✔ Sing-box API 已开启 (端口: $port)${PLAIN}"
        else
            echo -e "${RED}✘ JSON 校验失败，已放弃修改以保护服务。${PLAIN}"
            rm -f "${SING_BOX_CONFIG}.tmp"
        fi
    fi
}

get_singbox_detailed_status() {
    # 1. 尝试从 API 获取活跃连接数
    local api_conn=$(curl -s http://127.0.0.1:9090/connections | jq '.connections | length' 2>/dev/null)
    # 如果 API 请求失败（比如服务没开），回退到系统命令统计
    [[ -z "$api_conn" || "$api_conn" == "null" ]] && api_conn=$(ss -tnp 2>/dev/null | grep sing-box | grep -c ESTABLISHED)

    # 2. 获取监听端口 (包含 API 端口和业务端口)
    local ports=$(ss -tlnp 2>/dev/null | grep sing-box | awk '{print $4}' | awk -F':' '{print $NF}' | sort -u | tr '\n' ' ' )
    [[ -z "$ports" ]] && ports="无"

    # 3. 获取基础信息
    local pid=$(pgrep -f sing-box | head -n 1)
    local runtime="未知"
    [[ ! -z "$pid" ]] && runtime=$(ps -o etimes= -p "$pid" | awk '{printf "%02d:%02d", $1/60, $1%60}')

    echo "🔷 Sing-box 服务监控"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🟢 服务状态: ✅ 运行中"
    echo "🔹 进程 ID: $pid"
    echo "🔹 运行时长: $runtime"
    echo "🔹 监听端口: $ports"
    echo "🔹 活跃连接: $api_conn"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
}

get_system_stats() {
    local uptime=$(uptime -p | sed 's/up //')
    local mem_info=$(free -m | awk '/Mem:/ {printf "%d %d %.2f", $3, $2, $3/$2*100}')
    local mem_used=$(echo $mem_info | awk '{print $1}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_per=$(echo $mem_info | awk '{print $3}')
    
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cpu_per=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local dev=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)
    local rx_bytes=$(cat /proc/net/dev 2>/dev/null | grep "${dev}:" | awk -F: '{print $2}' | awk '{print $1}')
    local tx_bytes=$(cat /proc/net/dev 2>/dev/null | grep "${dev}:" | awk -F: '{print $2}' | awk '{print $9}')
    local rx=$(awk -v rx="${rx_bytes:-0}" 'BEGIN { printf "%.2f GB", rx/1073741824 }')
    local tx=$(awk -v tx="${tx_bytes:-0}" 'BEGIN { printf "%.2f GB", tx/1073741824 }')

    cat << EOF
📊 *系统监控报告*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 *CPU 占用*: ${cpu_per}%
🔹 *内存占用*: ${mem_used}/${mem_total}MB (${mem_per}%)
🔹 *系统负载*: $load
🔹 *网卡流量*: ⬇️$rx | ⬆️$tx
🔹 *系统运行*: $uptime
━━━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_full_report() {
    echo "$(get_singbox_detailed_status)"
    echo ""
    echo "$(get_system_stats)"
}

# ============================================
# 安装配置函数
# ============================================

install_bot() {
    echo -e "${YELLOW}--- Telegram 机器人安装 ---${PLAIN}"
    
    apt update && apt install -y jq curl bc procps iproute2 net-tools 2>/dev/null
    mkdir -p "$BOT_DIR"
    
    # 注入 Sing-box API 配置
    if [[ -f "$SING_BOX_CONFIG" ]]; then
        echo -e "${YELLOW}正在为 Sing-box 注入 API 配置...${PLAIN}"
        cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.bak"
        jq '.experimental.clash_api = {"external_controller": "127.0.0.1:9090"}' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp" && mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
        systemctl restart sing-box
        echo -e "${GREEN}✔ 已开启 Sing-box 内部 API (127.0.0.1:9090) 并重启服务${PLAIN}"
    else
        echo -e "${RED}✘ 未找到 $SING_BOX_CONFIG，跳过 API 配置注入${PLAIN}"
    fi

    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入管理员 Chat ID: " TG_CHATID
    
    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then
        echo -e "${RED}✘ 错误: Token 或 Chat ID 不能为空${PLAIN}"
        return
    fi
    
    # 保存单一管理员配置
    cat > "$BOT_CONF" <<EOF
TOKEN="$TG_TOKEN"
ADMIN_ID="$TG_CHATID"
EOF
    chmod 600 "$BOT_CONF"

    # 生成工作脚本
    cat > "$BOT_SCRIPT" <<'WORKER_EOF'
#!/bin/bash

source /etc/sing-box/tg_bot.conf

OFFSET_FILE="/etc/sing-box/tg_bot_offset"
LAST_ALERT_TIME=0

get_singbox_status() {
    if systemctl is-active --quiet sing-box 2>/dev/null; then echo "✅ 运行中"; return 0; else echo "❌ 已停止"; return 1; fi
}
get_singbox_pid() { pgrep -f "sing-box" | head -n1; }
get_singbox_ports() {
    local pid=$(get_singbox_pid); if [[ -z "$pid" ]]; then echo "未运行"; return; fi
    ss -tnp 2>/dev/null | grep "$pid" | awk '{print $4}' | sort -u | paste -sd "," -
}
get_singbox_connections() {
    local pid=$(get_singbox_pid); if [[ -z "$pid" ]]; then echo "0"; return; fi
    ss -tnp 2>/dev/null | grep "$pid" | grep ESTABLISHED | wc -l
}
get_singbox_memory() {
    local pid=$(get_singbox_pid); if [[ -z "$pid" ]]; then echo "0"; return; fi
    ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.2f MB", $1/1024}'
}
get_singbox_cpu() {
    local pid=$(get_singbox_pid); if [[ -z "$pid" ]]; then echo "0"; return; fi
    ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' '
}

get_singbox_detailed_status() {
    local status=$(get_singbox_status)
    local pid=$(get_singbox_pid)
    local ports=$(get_singbox_ports)
    local connections=$(get_singbox_connections)
    local memory=$(get_singbox_memory)
    local cpu=$(get_singbox_cpu)
    local uptime=$( [[ ! -z "$pid" ]] && ps -p "$pid" -o etime= 2>/dev/null | xargs )
    
    cat << EOF
🔷 *Sing-box 服务监控*
━━━━━━━━━━━━━━━━━━━━━━━━
🟢 *服务状态*: $status
🔹 *进程 ID*: ${pid:-未运行}
🔹 *运行时长*: ${uptime:-N/A}
🔹 *CPU 占用*: ${cpu}%
🔹 *内存占用*: $memory
🔹 *监听端口*: ${ports:-无}
🔹 *活跃连接*: $connections
━━━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_system_stats() {
    local uptime=$(uptime -p | sed 's/up //')
    local mem_info=$(free -m | awk '/Mem:/ {printf "%d %d %.2f", $3, $2, $3/$2*100}')
    local mem_used=$(echo $mem_info | awk '{print $1}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_per=$(echo $mem_info | awk '{print $3}')
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cpu_per=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local dev=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)
    local rx_bytes=$(cat /proc/net/dev 2>/dev/null | grep "${dev}:" | awk -F: '{print $2}' | awk '{print $1}')
    local tx_bytes=$(cat /proc/net/dev 2>/dev/null | grep "${dev}:" | awk -F: '{print $2}' | awk '{print $9}')
    local rx=$(awk -v rx="${rx_bytes:-0}" 'BEGIN { printf "%.2f GB", rx/1073741824 }')
    local tx=$(awk -v tx="${tx_bytes:-0}" 'BEGIN { printf "%.2f GB", tx/1073741824 }')

    cat << EOF
📊 *系统监控报告*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 *CPU 占用*: ${cpu_per}%
🔹 *内存占用*: ${mem_used}/${mem_total}MB (${mem_per}%)
🔹 *系统负载*: $load
🔹 *网卡流量*: ⬇️$rx | ⬆️$tx
🔹 *系统运行*: $uptime
━━━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')
EOF
}

get_full_report() { echo "$(get_singbox_detailed_status)"; echo ""; echo "$(get_system_stats)"; }

send_msg() {
    local chat_id=$1
    local text=$2
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$chat_id" -d "parse_mode=Markdown" -d "text=$text" > /dev/null
}

send_inline_keyboard() {
    local chat_id=$1
    local text=$2
    local buttons=$3  # JSON 格式的按钮数组
    
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$chat_id" \
        -d "parse_mode=Markdown" \
        -d "text=$text" \
        -d "reply_markup=$buttons" > /dev/null
}

send_callback_answer() {
    local callback_query_id=$1
    local text=$2
    
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/answerCallbackQuery" \
        -d "callback_query_id=$callback_query_id" \
        -d "text=$text" > /dev/null
}

check_alert() {
    local now=$(date +%s)
    if (( now - LAST_ALERT_TIME < 121 )); then return; fi

    local mem_per=$(free | awk '/Mem:/ {print $3/$2 * 100.0}')
    local cpu_per=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    local singbox_status=$(get_singbox_status)
    
    if [[ "$singbox_status" == "❌ 已停止" ]]; then
        send_msg "$ADMIN_ID" "🚨 *严重警告* 🚨\n━━━━━━━━━━━━━━━━━━━━━━━━\n❌ Sing-box 服务已停止！\n请立即检查！\n━━━━━━━━━━━━━━━━━━━━━━━━\n🕒 $(date '+%Y-%m-%d %H:%M:%S')"
        LAST_ALERT_TIME=$now; return
    fi
    
    local is_high_load=$(awk -v cpu="$cpu_per" -v mem="$mem_per" 'BEGIN { if (cpu > 80 || mem > 80) print 1; else print 0 }')
    if [[ "$is_high_load" == "1" ]]; then
        send_msg "$ADMIN_ID" "⚠️ *负载预警 (超过 80%)*\n━━━━━━━━━━━━━━━━━━━━━━━━\n🔹 CPU 占用: ${cpu_per}%\n🔹 内存占用: ${mem_per}%\n━━━━━━━━━━━━━━━━━━━━━━━━\n🚨 请检查系统状态！"
        LAST_ALERT_TIME=$now
    fi
}

while true; do
    check_alert

    OFFSET=$(cat $OFFSET_FILE 2>/dev/null || echo 0)
    UPDATES=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    
    echo "$UPDATES" | jq -c '.result[]' 2>/dev/null | while read -r update; do
        MSG_TEXT=$(echo "$update" | jq -r '.message.text // empty')
        CALLBACK_DATA=$(echo "$update" | jq -r '.callback_query.data // empty')
        CALLBACK_ID=$(echo "$update" | jq -r '.callback_query.id // empty')
        USER_ID=$(echo "$update" | jq -r '.message.from.id // .callback_query.from.id')
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        FROM_CHAT=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')

        # 唯一管理员权限校验
        if [[ "$USER_ID" != "$ADMIN_ID" ]]; then
            send_msg "$FROM_CHAT" "❌ 拒绝访问：非管理员账号"
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            continue
        fi

        if [[ ! -z "$MSG_TEXT" ]]; then
            case "$MSG_TEXT" in
                /start)
                    send_msg "$FROM_CHAT" "✨ Sing-box 监控管理系统
━━━━━━━━━━━━━━━━━━━━━━━━
欢迎使用！发送 /help 查看所有命令。
━━━━━━━━━━━━━━━━━━━━━━━━"
                    ;;
                /help)
                    send_msg "$FROM_CHAT" "📖 *帮助菜单*
━━━━━━━━━━━━━━━━━━━━━━━━
/status     - 查看完整报告
/singbox    - Sing-box 状态
/system     - 系统状态
/myid       - 显示你的 ID
/start      - 主菜单
━━━━━━━━━━━━━━━━━━━━━━━━"
                    ;;
                /status)
                    send_msg "$FROM_CHAT" "$(get_full_report)"
                    ;;
                /singbox)
                    send_msg "$FROM_CHAT" "$(get_singbox_detailed_status)"
                    ;;
                /system)
                    send_msg "$FROM_CHAT" "$(get_system_stats)"
                    ;;
                /myid)
                    local user_info=$(get_user_info "$USER_ID")
                    local username=$(echo "$user_info" | cut -d'|' -f2)
                    local role=$(echo "$user_info" | cut -d'|' -f3)
                    send_msg "$FROM_CHAT" "👤 *你的信息*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 用户 ID: $USER_ID
🔹 用户名: $username
🔹 权限: $role
━━━━━━━━━━━━━━━━━━━━━━━━"
                    ;;
            esac
        fi


        if [[ ! -z "$CALLBACK_DATA" ]]; then
            case "$CALLBACK_DATA" in
                restart_singbox)
                    systemctl restart sing-box
                    send_callback_answer "$CALLBACK_ID" "✅ 重启中..."
                    sleep 1
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 重启服务","callback_data":"restart_singbox"},{"text":"🛑 停止服务","callback_data":"stop_singbox"}],[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "🔄 Sing-box 已重启！\n$(get_singbox_detailed_status)" "$inline_kb"
                    ;;
                stop_singbox)
                    systemctl stop sing-box
                    send_callback_answer "$CALLBACK_ID" "✅ 已停止"
                    local inline_kb='{"inline_keyboard": [[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "🛑 Sing-box 已停止！\n$(get_singbox_detailed_status)" "$inline_kb"
                    ;;
                start_singbox)
                    systemctl start sing-box
                    send_callback_answer "$CALLBACK_ID" "✅ 已启动"
                    sleep 1
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 重启服务","callback_data":"restart_singbox"},{"text":"🛑 停止服务","callback_data":"stop_singbox"}],[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "▶️ Sing-box 已启动！\n$(get_singbox_detailed_status)" "$inline_kb"
                    ;;
                refresh_status)
                    send_callback_answer "$CALLBACK_ID" "🔄 刷新中..."
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 刷新状态","callback_data":"refresh_status"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "$(get_full_report)" "$inline_kb"
                    ;;
            esac
        fi

        echo $((UPDATE_ID + 1)) > $OFFSET_FILE
    done
    sleep 2
done
WORKER_EOF

    chmod +x "$BOT_SCRIPT"

    cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Sing-box Telegram Bot with Monitoring
After=network.target sing-box.service

[Service]
Type=simple
ExecStart=/bin/bash $BOT_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tg-bot
    
    echo -e "${GREEN}✔ 机器人已启动并设置开机自启！${PLAIN}"
}

# ============================================
# 卸载与终端查看菜单
# ============================================

uninstall_bot() {
    echo -e "${YELLOW}正在卸载 Telegram 机器人...${PLAIN}"
    systemctl stop tg-bot 2>/dev/null
    systemctl disable tg-bot 2>/dev/null
    rm -f "$BOT_SERVICE" "$BOT_SCRIPT" "$BOT_CONF"
    systemctl daemon-reload
    echo -e "${GREEN}✔ 卸载完成${PLAIN}"
}

view_monitoring() {
    while true; do
        clear
        echo -e "${CYAN}--- 终端监控查看 ---${PLAIN}"
        echo "1. 完整报告"
        echo "2. Sing-box 状态"
        echo "3. 系统状态"
        echo "0. 返回"
        read -p "请选择: " choice
        case $choice in
            1) clear; get_full_report; read -p "按 Enter 继续..." ;;
            2) clear; get_singbox_detailed_status; read -p "按 Enter 继续..." ;;
            3) clear; get_system_stats; read -p "按 Enter 继续..." ;;
            0) break ;;
        esac
    done
}

show_menu() {
    clear
    echo -e "${CYAN}================================${PLAIN}"
    echo -e "${GREEN}   Sing-box Bot 管理面板 Pro   ${PLAIN}"
    echo -e "${CYAN}================================${PLAIN}"
    echo -e "1. 安装/重装 机器人"
    echo -e "2. ${YELLOW}一键检查/更新脚本${PLAIN}"
    echo -e "3. ${RED}查看机器人运行日志 (调试)${PLAIN}"
    echo -e "4. 修改 API 监听端口"
    echo -e "5. 卸载机器人"
    echo -e "0. 退出"
    echo -e "${CYAN}--------------------------------${PLAIN}"
    read -p "请输入选项 [0-5]: " choice

    case $choice in
        1) install_bot ;;
        2) update_bot ;;
        3) view_logs ;;
        4) 
            read -p "请输入新的 API 端口 (默认 9090): " new_port
            inject_api_config ${new_port:-9090}
            ;;
        5) uninstall_bot ;;
        *) exit 0 ;;
    esac
}

show_menu
