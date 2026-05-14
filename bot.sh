#!/bin/bash

# ============================================
# Sing-box Bot Pro (一键安装/管理/调试全能版)
# ============================================

BOT_DIR="/etc/sing-box"
BOT_SCRIPT="/etc/sing-box/tg_worker.sh"  # 明确工作脚本路径
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_SERVICE="/etc/systemd/system/tg-bot.service"
SING_BOX_CONFIG="/etc/sing-box/config.json"
UPDATE_URL="https://raw.githubusercontent.com/lje02/vp/main/bot.sh"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ============================================
# 基础工具函数 (用于安装面板)
# ============================================

view_logs() {
    echo -e "${YELLOW}正在查看机器人实时日志 (Ctrl+C 退出)...${PLAIN}"
    journalctl -u tg-bot -f -n 50
}

inject_api_config() {
    local port=$1
    if [[ -f "$SING_BOX_CONFIG" ]]; then
        cp "$SING_BOX_CONFIG" "${SING_BOX_CONFIG}.bak"
        jq --arg port "127.0.0.1:$port" '.experimental.clash_api = {"external_controller": $port}' "$SING_BOX_CONFIG" > "${SING_BOX_CONFIG}.tmp"
        
        if sing-box check -c "${SING_BOX_CONFIG}.tmp" &>/dev/null; then
            mv "${SING_BOX_CONFIG}.tmp" "$SING_BOX_CONFIG"
            systemctl restart sing-box
            echo -e "${GREEN}✔ Sing-box API 已开启并同步修改配置 (端口: $port)${PLAIN}"
        else
            echo -e "${RED}✘ JSON 校验失败，已还原。请检查是否有重复的 experimental 模块。${PLAIN}"
            rm -f "${SING_BOX_CONFIG}.tmp"
        fi
    fi
}

# ============================================
# 安装配置函数
# ============================================

install_bot() {
    echo -e "${YELLOW}--- Telegram 机器人安装 ---${PLAIN}"
    
    apt update && apt install -y jq curl bc procps iproute2 net-tools 2>/dev/null
    mkdir -p "$BOT_DIR"
    
    # 注入 API 配置
    read -p "请输入 Sing-box API 端口 (默认 9090): " API_PORT
    API_PORT=${API_PORT:-9090}
    inject_api_config "$API_PORT"

    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入管理员 Chat ID: " TG_CHATID
    
    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then
        echo -e "${RED}✘ 错误: Token 或 Chat ID 不能为空${PLAIN}"
        return
    fi
    
    cat > "$BOT_CONF" <<EOF
TOKEN="$TG_TOKEN"
ADMIN_ID="$TG_CHATID"
API_PORT="$API_PORT"
EOF
    chmod 600 "$BOT_CONF"

    # ============================================
    # 生成后台工作脚本 (核心修复区)
    # ============================================
    cat > "$BOT_SCRIPT" <<'WORKER_EOF'
#!/bin/bash
# 导入配置
source /etc/sing-box/tg_bot.conf

OFFSET_FILE="/etc/sing-box/tg_bot_offset"
LAST_ALERT_TIME=0

# --- 监控函数 (定义在函数内，可以使用 local) ---
get_singbox_detailed_status() {
    local api_conn=$(curl -s http://127.0.0.1:$API_PORT/connections | jq '.connections | length' 2>/dev/null)
    [[ -z "$api_conn" || "$api_conn" == "null" ]] && api_conn=$(ss -tnp 2>/dev/null | grep sing-box | grep -c ESTABLISHED)

    local ports=$(ss -tlnp 2>/dev/null | grep sing-box | awk '{print $4}' | awk -F':' '{print $NF}' | sort -un | tr '\n' ' ' )
    [[ -z "$ports" ]] && ports="无"

    local pid=$(pgrep -f sing-box | head -n 1)
    local status="❌ 已停止"
    local runtime="N/A"
    local cpu="0"
    local mem="0 MB"

    if [[ ! -z "$pid" ]]; then
        status="✅ 运行中"
        runtime=$(ps -o etimes= -p "$pid" | awk '{printf "%02d:%02d:%02d", $1/3600, ($1%3600)/60, $1%60}')
        cpu=$(ps -p "$pid" -o %cpu= | xargs)
        mem=$(ps -p "$pid" -o rss= | awk '{printf "%.2f MB", $1/1024}')
    fi

    cat << EOF
🔷 *Sing-box 服务监控*
━━━━━━━━━━━━━━━━━━━━━━━━
🟢 *服务状态*: $status
🔹 *进程 ID*: ${pid:-N/A}
🔹 *运行时长*: $runtime
🔹 *CPU 占用*: ${cpu}%
🔹 *内存占用*: $mem
🔹 *监听端口*: $ports
🔹 *活跃连接*: $api_conn
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
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | awk '{print 100 - $8}')
    
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
    echo -e "$(get_singbox_detailed_status)\n\n$(get_system_stats)"
}

# --- 自动报警函数 (放在循环外，可以使用 local) ---
check_system_alerts() {
    local now=$(date +%s)
    # 每 120 秒检查一次，避免刷屏
    [[ $((now - LAST_ALERT_TIME)) -lt 120 ]] && return

    # 1. 检查服务状态
    if ! systemctl is-active --quiet sing-box; then
        send_msg "$ADMIN_ID" "🚨 *严重警告*
━━━━━━━━━━━━━━━━━━━━━━━━
❌ Sing-box 服务已停止！
请立即检查服务器状态。
━━━━━━━━━━━━━━━━━━━━━━━━
🕒 $(date '+%Y-%m-%d %H:%M:%S')"
        LAST_ALERT_TIME=$now
        return
    fi

    # 2. 检查负载 (CPU/内存 > 90%)
    local mem_per=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100.0}')
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | awk '{printf "%.0f", 100 - $8}')
    
    if [ "$cpu_per" -gt 90 ] || [ "$mem_per" -gt 90 ]; then
        send_msg "$ADMIN_ID" "⚠️ *高负载预警*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 CPU 占用: ${cpu_per}%
🔹 内存占用: ${mem_per}%
━━━━━━━━━━━━━━━━━━━━━━━━
🚨 服务器压力过大，可能存在环路或异常连接！"
        LAST_ALERT_TIME=$now
    fi
}

send_msg() {
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$1" \
        -d "parse_mode=Markdown" \
        -d "text=$2" > /dev/null
}

send_inline_keyboard() {
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$1" \
        -d "parse_mode=Markdown" \
        -d "text=$2" \
        -d "reply_markup=$3" > /dev/null
}

# --- 主循环 ---
while true; do
    # 执行报警检查
    check_system_alerts

    # 获取 Telegram 更新
    CURRENT_OFFSET=$(cat $OFFSET_FILE 2>/dev/null || echo 0)
    UPDATES=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$CURRENT_OFFSET&timeout=30")
    
    # 获取消息
    CURRENT_OFFSET=$(cat $OFFSET_FILE 2>/dev/null || echo 0)
    UPDATES=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$CURRENT_OFFSET&timeout=30")
    
    echo "$UPDATES" | jq -c '.result[]' 2>/dev/null | while read -r update; do
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')
        MSG_TEXT=$(echo "$update" | jq -r '.message.text // empty')
        CB_DATA=$(echo "$update" | jq -r '.callback_query.data // empty')
        CB_ID=$(echo "$update" | jq -r '.callback_query.id // empty')
        USER_ID=$(echo "$update" | jq -r '.message.from.id // .callback_query.from.id')
        CHAT_ID=$(echo "$update" | jq -r '.message.chat.id // .callback_query.message.chat.id')

        # 权限校验
        if [[ "$USER_ID" != "$ADMIN_ID" ]]; then
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            continue
        fi

        # 处理文本指令 (已移除 local)
        if [[ ! -z "$MSG_TEXT" ]]; then
            case "$MSG_TEXT" in
                /start|/help)
                    send_msg "$CHAT_ID" "📖 *帮助菜单*
━━━━━━━━━━━━━━━━━━━━━━━━
/status  - 完整监控报告
/singbox - 节点服务管理
/system  - 仅看系统状态
/myid    - 查看你的 ID
━━━━━━━━━━━━━━━━━━━━━━━━"
                    ;;
                /status)
                    KB='{"inline_keyboard": [[{"text":"🔄 刷新状态","callback_data":"refresh_status"}]]}'
                    send_inline_keyboard "$CHAT_ID" "$(get_full_report)" "$KB"
                    ;;
                /singbox)
                    KB='{"inline_keyboard": [[{"text":"🔄 重启","callback_data":"restart_sb"},{"text":"🛑 停止","callback_data":"stop_sb"}],[{"text":"▶️ 启动","callback_data":"start_sb"}]]}'
                    send_inline_keyboard "$CHAT_ID" "$(get_singbox_detailed_status)" "$KB"
                    ;;
                /system)
                    send_msg "$CHAT_ID" "$(get_system_stats)"
                    ;;
                /myid)
                    # 彻底修复此处报错：移除 get_user_info 调用，移除 local
                    MY_ID_MSG="👤 *你的个人信息*
━━━━━━━━━━━━━━━━━━━━━━━━
🔹 用户 ID: \`$USER_ID\`
🔹 权限等级: 管理员
━━━━━━━━━━━━━━━━━━━━━━━━"
                    send_msg "$CHAT_ID" "$MY_ID_MSG"
                    ;;
            esac
        fi

        # 处理按钮回调 (已移除 local)
        if [[ ! -z "$CB_DATA" ]]; then
            CALLBACK_MSG=""
            case "$CB_DATA" in
                restart_sb) systemctl restart sing-box; CALLBACK_MSG="✅ 服务已重启" ;;
                stop_sb) systemctl stop sing-box; CALLBACK_MSG="🛑 服务已停止" ;;
                start_sb) systemctl start sing-box; CALLBACK_MSG="▶️ 服务已启动" ;;
                refresh_status) CALLBACK_MSG="🔄 状态已刷新" ;;
            esac
            
            # 反馈点击效果
            curl -s "https://api.telegram.org/bot$TOKEN/answerCallbackQuery?callback_query_id=$CB_ID&text=$(echo $CALLBACK_MSG | jq -sRr @uri)"
            
            # 刷新消息内容
            NEW_KB='{"inline_keyboard": [[{"text":"🔄 重启","callback_data":"restart_sb"},{"text":"🛑 停止","callback_data":"stop_sb"}],[{"text":"▶️ 启动","callback_data":"start_sb"}]]}'
            send_inline_keyboard "$CHAT_ID" "$(get_full_report)" "$NEW_KB"
        fi

        echo $((UPDATE_ID + 1)) > $OFFSET_FILE
    done
    sleep 1
done

WORKER_EOF

    chmod +x "$BOT_SCRIPT"

    # 生成服务文件
    cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Sing-box Telegram Bot
After=network.target sing-box.service

[Service]
ExecStart=/bin/bash $BOT_SCRIPT
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tg-bot
    echo -e "${GREEN}✔ 机器人已启动！请在 TG 发送 /status 试试。${PLAIN}"
}

# ============================================
# 其他管理函数
# ============================================

uninstall_bot() {
    systemctl stop tg-bot && systemctl disable tg-bot
    rm -rf "$BOT_DIR" "$BOT_SERVICE"
    echo -e "${GREEN}✔ 机器人已成功卸载${PLAIN}"
}

update_bot() {
    echo -e "${YELLOW}正在从远程更新脚本...${PLAIN}"
    curl -sL "$UPDATE_URL" -o "$0" && chmod +x "$0"
    echo -e "${GREEN}✔ 脚本主程序已更新，请重新运行脚本并选择安装以更新后台服务。${PLAIN}"
    exit 0
}

show_menu() {
    clear
    echo -e "${CYAN}================================${PLAIN}"
    echo -e "${GREEN}   Sing-box Bot 管理面板 Pro   ${PLAIN}"
    echo -e "${CYAN}================================${PLAIN}"
    echo -e "1. 安装/重装 机器人"
    echo -e "2. ${YELLOW}一键检查/更新脚本主程序${PLAIN}"
    echo -e "3. ${RED}查看运行日志 (调试必备)${PLAIN}"
    echo -e "4. 修改 API 监听端口"
    echo -e "5. 卸载机器人"
    echo -e "0. 退出"
    echo -e "${CYAN}--------------------------------${PLAIN}"
    read -p "请输入选项 [0-5]: " choice
    case $choice in
        1) install_bot ;;
        2) update_bot ;;
        3) view_logs ;;
        4) read -p "新端口: " p; inject_api_config "$p" ;;
        5) uninstall_bot ;;
        *) exit 0 ;;
    esac
}

show_menu
