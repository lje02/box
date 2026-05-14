#!/bin/bash

# ============================================
# Telegram Bot with Sing-box Monitoring
# 单一管理员版本 + 自动配置 API
# ============================================

# --- 路径定义 ---
BOT_DIR="/etc/sing-box"
BOT_SCRIPT="$BOT_DIR/tg_worker.sh"
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_SERVICE="/etc/systemd/system/tg-bot.service"
LOG_FILE="/tmp/tg_bot.log"
SING_BOX_API="http://127.0.0.1:9090"
SING_BOX_CONFIG="/etc/sing-box/config.json"

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

get_singbox_detailed_status() {
    local status=$(get_singbox_status)
    local pid=$(get_singbox_pid)
    local ports=$(get_singbox_ports)
    local connections=$(get_singbox_connections)
    local memory=$(get_singbox_memory)
    local cpu=$(get_singbox_cpu)
    local uptime=""
    
    if [[ ! -z "$pid" ]]; then
        uptime=$(ps -p "$pid" -o etime= 2>/dev/null | xargs)
    fi
    
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
        jq '.experimental.api = {"enabled": true, "listen": "127.0.0.1:9090"}' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp" && mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
        systemctl restart sing-box
        echo -e "${GREEN}✔ 已开启 Sing-box 内部 API (127.0.0.1:9090) 并重启服务${PLAIN}"
    else
        echo -e "${RED}✘ 未找到 $SING_BOX_CONFIG，跳过 API 配置注入${PLAIN}"
    fi

    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入管理员 Chat ID (此后仅该 ID 可用): " TG_CHATID
    
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
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$1" -d "parse_mode=Markdown" -d "text=$2" > /dev/null
}

send_inline_keyboard() {
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$1" -d "parse_mode=Markdown" -d "text=$2" -d "reply_markup=$3" > /dev/null
}

send_callback_answer() {
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/answerCallbackQuery" \
        -d "callback_query_id=$1" -d "text=$2" > /dev/null
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
                /start|/help)
                    send_msg "$FROM_CHAT" "✨ *Sing-box 监控系统*\n━━━━━━━━━━━━━━━━━━━━━━━━\n/status - 完整系统与节点报告\n/singbox - 仅查看节点并管理\n/system - 仅查看系统资源\n/myid - 查看你的管理员 ID\n━━━━━━━━━━━━━━━━━━━━━━━━"
                    ;;
                /status)
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 刷新状态","callback_data":"refresh_status"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "$(get_full_report)" "$inline_kb"
                    ;;
                /singbox)
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 重启服务","callback_data":"restart_singbox"},{"text":"🛑 停止服务","callback_data":"stop_singbox"}],[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "$(get_singbox_detailed_status)" "$inline_kb"
                    ;;
                /system)
                    send_msg "$FROM_CHAT" "$(get_system_stats)"
                    ;;
                /myid)
                    send_msg "$FROM_CHAT" "👑 *管理员信息*\n━━━━━━━━━━━━━━━━━━━━━━━━\n🔹 ID: $USER_ID\n🔹 权限: 最高管理员"
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

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}╔════════════════════════════════╗${PLAIN}"
        echo -e "${CYAN}║ Sing-box Telegram Bot 管理系统 ║${PLAIN}"
        echo -e "${CYAN}╚════════════════════════════════╝${PLAIN}"
        echo ""
        echo "1. 安装 / 更新 机器人"
        echo "2. 卸载 机器人"
        echo "3. 终端实时查看监控"
        echo "0. 退出"
        echo ""
        read -p "请选择: " choice

        case $choice in
            1) install_bot; read -p "按 Enter 继续..." ;;
            2) uninstall_bot; read -p "按 Enter 继续..." ;;
            3) view_monitoring ;;
            0) exit 0 ;;
            *) echo -e "${RED}✘ 无效选择${PLAIN}"; read -p "按 Enter 继续..." ;;
        esac
    done
}

main_menu
