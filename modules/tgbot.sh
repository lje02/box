#!/bin/bash

# ============================================
# Telegram Bot with Sing-box Monitoring
# 支持菜单推送、用户管理、sing-box 运行状态
# ============================================

# --- 路径定义 ---
BOT_DIR="/etc/sing-box"
BOT_SCRIPT="$BOT_DIR/tg_worker.sh"
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_USERS="$BOT_DIR/tg_bot_users.conf"
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
# 基础监控与状态函数 (供终端菜单使用)
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
    # 修复：获取两次采样以计算准确的实时 CPU 占用率
    local cpu_per=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local dev=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)
    # 修复：更稳健的网卡流量解析方式
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
# 用户管理函数
# ============================================

check_user_permission() {
    local user_id=$1
    local required_role=${2:-"user"}
    
    if [[ ! -f "$BOT_USERS" ]]; then return 1; fi
    local user_line=$(grep "^$user_id|" "$BOT_USERS")
    if [[ -z "$user_line" ]]; then return 1; fi
    
    local role=$(echo "$user_line" | cut -d'|' -f3)
    if [[ "$required_role" == "admin" ]]; then
        [[ "$role" == "admin" ]]
    else
        [[ "$role" == "admin" || "$role" == "user" ]]
    fi
}

add_user() {
    local user_id=$1; local username=$2; local role=$3
    if grep -q "^$user_id|" "$BOT_USERS" 2>/dev/null; then return 1; fi
    echo "$user_id|$username|$role" >> "$BOT_USERS"
    return 0
}

remove_user() {
    local user_id=$1
    if [[ ! -f "$BOT_USERS" ]]; then return 1; fi
    sed -i "/^$user_id|/d" "$BOT_USERS"
    return 0
}

list_users() {
    if [[ ! -f "$BOT_USERS" ]]; then echo "暂无用户"; return; fi
    echo "👥 *授权用户列表*"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    awk -F'|' '{printf "🔹 %s (ID: %s) - %s\n", $2, $1, $3}' "$BOT_USERS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================
# 安装配置函数
# ============================================

install_bot() {
    echo -e "${YELLOW}--- Telegram 机器人安装 ---${PLAIN}"
    
    apt update && apt install -y jq curl bc procps iproute2 net-tools 2>/dev/null
    mkdir -p "$BOT_DIR"
    
    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入管理员 Chat ID: " TG_CHATID
    
    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then
        echo -e "${RED}✘ 错误: Token 或 Chat ID 不能为空${PLAIN}"
        return
    fi
    
    cat > "$BOT_CONF" <<EOF
TOKEN="$TG_TOKEN"
CHAT_ID="$TG_CHATID"
EOF

    if [[ ! -f "$BOT_USERS" ]]; then
        echo "$TG_CHATID|Admin|admin" > "$BOT_USERS"
    fi
    chmod 600 "$BOT_CONF" "$BOT_USERS"

    # 生成工作脚本
    cat > "$BOT_SCRIPT" <<'WORKER_EOF'
#!/bin/bash

source /etc/sing-box/tg_bot.conf

# 修复：修改 Offset 路径防止重启丢失导致消息风暴
OFFSET_FILE="/etc/sing-box/tg_bot_offset"
LAST_ALERT_TIME=0
BOT_USERS="/etc/sing-box/tg_bot_users.conf"

get_singbox_status() {
    if systemctl is-active --quiet sing-box 2>/dev/null; then echo "✅ 运行中"; return 0; else echo "❌ 已停止"; return 1; fi
}

get_singbox_pid() { pgrep -f "sing-box" | head -n1; }

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
    # 修复 CPU 计算
    local cpu_per=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local dev=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1)
    # 修复流量解析
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

check_user_permission() {
    local user_id=$1; local required_role=${2:-"user"}
    if [[ ! -f "$BOT_USERS" ]]; then return 1; fi
    local user_line=$(grep "^$user_id|" "$BOT_USERS")
    if [[ -z "$user_line" ]]; then return 1; fi
    
    local role=$(echo "$user_line" | cut -d'|' -f3)
    if [[ "$required_role" == "admin" ]]; then [[ "$role" == "admin" ]]
    else [[ "$role" == "admin" || "$role" == "user" ]]; fi
}

get_user_info() {
    local user_id=$1
    if [[ ! -f "$BOT_USERS" ]]; then return; fi
    grep "^$user_id|" "$BOT_USERS"
}

send_msg() {
    local chat_id=$1; local text=$2
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$chat_id" -d "parse_mode=Markdown" -d "text=$text" > /dev/null
}

send_inline_keyboard() {
    local chat_id=$1; local text=$2; local buttons=$3
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$chat_id" -d "parse_mode=Markdown" -d "text=$text" -d "reply_markup=$buttons" > /dev/null
}

send_callback_answer() {
    local callback_query_id=$1; local text=$2
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/answerCallbackQuery" \
        -d "callback_query_id=$callback_query_id" -d "text=$text" > /dev/null
}

# ============ 负载警报 ============
check_alert() {
    local now=$(date +%s)
    if (( now - LAST_ALERT_TIME < 120 )); then return; fi

    local mem_per=$(free | awk '/Mem:/ {print $3/$2 * 100.0}')
    local cpu_per=$(top -bn2 -d 0.5 | grep "Cpu(s)" | tail -n 1 | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    local singbox_status=$(get_singbox_status)
    
    if [[ "$singbox_status" == "❌ 已停止" ]]; then
        send_msg "$CHAT_ID" "🚨 *严重警告* 🚨
━━━━━━━━━━━━━━━━━━━━━━━━
❌ Sing-box 服务已停止！
请立即检查！
━━━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')"
        LAST_ALERT_TIME=$now
        return
    fi
    
    # 修复：使用 awk 判断浮点数警报逻辑
    local is_high_load=$(awk -v cpu="$cpu_per" -v mem="$mem_per" 'BEGIN { if (cpu > 80 || mem > 80) print 1; else print 0 }')
    if [[ "$is_high_load" == "1" ]]; then
        send_msg "$CHAT_ID" "⚠️ *负载预警 (超过 80%)*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 CPU 占用: ${cpu_per}%
🔹 内存占用: ${mem_per}%
━━━━━━━━━━━━━━━━━━━━━━━━
🚨 请检查系统状态！"
        LAST_ALERT_TIME=$now
    fi
}

# ============ 主循环 ============
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

        if ! check_user_permission "$USER_ID"; then
            send_msg "$FROM_CHAT" "❌ 你没有权限使用此机器人"
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            continue
        fi

        if [[ ! -z "$MSG_TEXT" ]]; then
            case "$MSG_TEXT" in
                /start)
                    send_msg "$FROM_CHAT" "✨ Sing-box 监控管理系统
━━━━━━━━━━━━━━━━━━━━━━━━
欢迎使用！发送 /1 查看所有命令。"
                    ;;
                /1)
                    send_msg "$FROM_CHAT" "📖 *帮助菜单*
━━━━━━━━━━━━━━━━━━━━━━━━
/status     - 查看系统和节点完整报告
/singbox    - 仅查看 Sing-box 状态并操作
/system     - 仅查看系统状态
/id       - 显示你的用户 ID 信息"
                    ;;
                /status)
                    # 激活菜单按钮
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 刷新状态","callback_data":"refresh_status"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "$(get_full_report)" "$inline_kb"
                    ;;
                /singbox)
                    # 激活管理员操作按钮
                    local inline_kb='{"inline_keyboard": [[{"text":"🔄 重启服务","callback_data":"restart_singbox"},{"text":"🛑 停止服务","callback_data":"stop_singbox"}],[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                    send_inline_keyboard "$FROM_CHAT" "$(get_singbox_detailed_status)" "$inline_kb"
                    ;;
                /system)
                    send_msg "$FROM_CHAT" "$(get_system_stats)"
                    ;;
                /id)
                    local user_info=$(get_user_info "$USER_ID")
                    local username=$(echo "$user_info" | cut -d'|' -f2)
                    local role=$(echo "$user_info" | cut -d'|' -f3)
                    send_msg "$FROM_CHAT" "👤 *你的信息*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 用户 ID: $USER_ID
🔹 用户名: $username
🔹 权限: $role"
                    ;;
            esac
        fi

        if [[ ! -z "$CALLBACK_DATA" ]]; then
            case "$CALLBACK_DATA" in
                restart_singbox)
                    if check_user_permission "$USER_ID" "admin"; then
                        systemctl restart sing-box
                        send_callback_answer "$CALLBACK_ID" "✅ 重启中..."
                        sleep 1
                        local inline_kb='{"inline_keyboard": [[{"text":"🔄 重启服务","callback_data":"restart_singbox"},{"text":"🛑 停止服务","callback_data":"stop_singbox"}],[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                        send_inline_keyboard "$FROM_CHAT" "🔄 Sing-box 已重启！\n$(get_singbox_detailed_status)" "$inline_kb"
                    else
                        send_callback_answer "$CALLBACK_ID" "❌ 权限不足，需 Admin 角色"
                    fi
                    ;;
                stop_singbox)
                    if check_user_permission "$USER_ID" "admin"; then
                        systemctl stop sing-box
                        send_callback_answer "$CALLBACK_ID" "✅ 已停止"
                        local inline_kb='{"inline_keyboard": [[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                        send_inline_keyboard "$FROM_CHAT" "🛑 Sing-box 已停止！\n$(get_singbox_detailed_status)" "$inline_kb"
                    else
                        send_callback_answer "$CALLBACK_ID" "❌ 权限不足"
                    fi
                    ;;
                start_singbox)
                    if check_user_permission "$USER_ID" "admin"; then
                        systemctl start sing-box
                        send_callback_answer "$CALLBACK_ID" "✅ 已启动"
                        sleep 1
                        local inline_kb='{"inline_keyboard": [[{"text":"🔄 重启服务","callback_data":"restart_singbox"},{"text":"🛑 停止服务","callback_data":"stop_singbox"}],[{"text":"▶️ 启动服务","callback_data":"start_singbox"}]]}'
                        send_inline_keyboard "$FROM_CHAT" "▶️ Sing-box 已启动！\n$(get_singbox_detailed_status)" "$inline_kb"
                    else
                        send_callback_answer "$CALLBACK_ID" "❌ 权限不足"
                    fi
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
    
    echo -e "${GREEN}✔ 机器人已启动！${PLAIN}"
    echo -e "${GREEN}✔ 已设置开机自启${PLAIN}"
    echo -e "${CYAN}用户配置: $BOT_USERS${PLAIN}"
}

# ============================================
# 卸载与管理菜单
# ============================================

uninstall_bot() {
    echo -e "${YELLOW}正在卸载 Telegram 机器人...${PLAIN}"
    systemctl stop tg-bot 2>/dev/null
    systemctl disable tg-bot 2>/dev/null
    rm -f "$BOT_SERVICE" "$BOT_SCRIPT"
    systemctl daemon-reload
    echo -e "${GREEN}✔ 卸载完成${PLAIN}"
    echo -e "${YELLOW}配置文件保留在 $BOT_DIR${PLAIN}"
}

manage_users() {
    while true; do
        clear
        echo -e "${CYAN}--- 用户管理 ---${PLAIN}"
        echo "1. 添加用户"
        echo "2. 删除用户"
        echo "3. 列表用户"
        echo "0. 返回"
        read -p "请选择: " choice
        case $choice in
            1)
                read -p "输入用户 ID: " uid
                read -p "输入用户名: " uname
                echo -e "1. admin (管理员)\n2. user (普通用户)"
                read -p "选择角色 (输入数字): " role_choice
                [[ "$role_choice" == "1" ]] && role="admin" || role="user"
                if add_user "$uid" "$uname" "$role"; then
                    echo -e "${GREEN}✔ 用户添加成功${PLAIN}"
                else
                    echo -e "${RED}✘ 用户已存在${PLAIN}"
                fi
                read -p "按 Enter 继续..." ;;
            2)
                read -p "输入要删除的用户 ID: " uid
                if remove_user "$uid"; then echo -e "${GREEN}✔ 用户删除成功${PLAIN}"; else echo -e "${RED}✘ 删除失败${PLAIN}"; fi
                read -p "按 Enter 继续..." ;;
            3) list_users; read -p "按 Enter 继续..." ;;
            0) break ;;
        esac
    done
}

view_monitoring() {
    while true; do
        clear
        echo -e "${CYAN}--- 监控查看 ---${PLAIN}"
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
        echo -e "${CYAN}║ Sing-box Telegram Bot + Monitor ║${PLAIN}"
        echo -e "${CYAN}╚════════════════════════════════╝${PLAIN}"
        echo ""
        echo "1. 安装/重新安装 机器人"
        echo "2. 卸载 机器人"
        echo "3. 用户管理"
        echo "4. 终端查看监控"
        echo "0. 退出"
        echo ""
        read -p "请选择: " choice

        case $choice in
            1) install_bot; read -p "按 Enter 继续..." ;;
            2) uninstall_bot; read -p "按 Enter 继续..." ;;
            3) manage_users ;;
            4) view_monitoring ;;
            0) exit 0 ;;
            *) echo -e "${RED}✘ 无效选择${PLAIN}"; read -p "按 Enter 继续..." ;;
        esac
    done
}

main_menu
