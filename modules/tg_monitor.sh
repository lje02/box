#!/bin/bash
# 远程监控机器人 (Telegram) - 仅提供状态查询，无控制功能

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || true
fi

TG_CONF="/etc/vp_tg.conf"
LISTENER_SCRIPT="/usr/local/bin/vp_tg_listener.sh"
PID_FILE="/var/run/vp_tg_bot.pid"

# ---------- 生成监听脚本（精简版） ----------
generate_listener() {
    cat > "$LISTENER_SCRIPT" <<'EOF'
#!/bin/bash
# VPS 远程监控机器人 (只读)

TG_CONF="/etc/vp_tg.conf"
[ ! -f "$TG_CONF" ] && exit 1
source "$TG_CONF"

OFFSET=0

# HTML 发送消息
reply() {
    local chat_id=$1 text=$2
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
        -d chat_id="$chat_id" \
        -d parse_mode="HTML" \
        --data-urlencode "text=$text" >/dev/null
}

# 发送“正在输入”状态
send_typing() {
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendChatAction" \
        -d chat_id="$1" \
        -d action="typing" >/dev/null
}

echo "VPS 监控机器人启动 (只读模式)"

while true; do
    updates=$(curl -s "https://api.telegram.org/bot$TG_BOT_TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    [ $? -ne 0 ] && { sleep 5; continue; }
    [ "$(echo "$updates" | jq -r '.ok')" != "true" ] && { sleep 5; continue; }
    count=$(echo "$updates" | jq '.result | length')
    [ "$count" -eq 0 ] && continue

    echo "$updates" | jq -c '.result[]' | while read row; do
        update_id=$(echo "$row" | jq '.update_id')
        text=$(echo "$row" | jq -r '.message.text // empty')
        chat_id=$(echo "$row" | jq -r '.message.chat.id // empty')

        if [ "$chat_id" == "$TG_CHAT_ID" ] && [ -n "$text" ]; then
            send_typing "$chat_id"

            case "$text" in
                "/start" | "/help")
                    msg="🤖 <b>VPS 远程监控</b>\n"
                    msg+="-----------------------------\n"
                    msg+="📊 /status - 系统状态\n"
                    msg+="🌐 /ip - 公网 IP\n"
                    msg+="⏱ /uptime - 运行时间\n"
                    reply "$chat_id" "$msg"
                    ;;

                "/status")
                    load=$(uptime | awk -F'load average:' '{print $2}' | sed 's/,//g')
                    mem_used=$(free -m | awk 'NR==2{print $3}')
                    mem_total=$(free -m | awk 'NR==2{print $2}')
                    disk=$(df -h / | awk 'NR==2{print $5}')
                    containers=$(docker ps -q 2>/dev/null | wc -l)
                    msg="📊 <b>系统状态</b>\n"
                    msg+="-----------------------------\n"
                    msg+="🧠 负载: <code>$load</code>\n"
                    msg+="💾 内存: ${mem_used}MB / ${mem_total}MB\n"
                    msg+="💿 磁盘: $disk 已用\n"
                    msg+="🐳 容器: 运行 $containers 个\n"
                    msg+="⏱ 运行: $(uptime -p)"
                    reply "$chat_id" "$msg"
                    ;;

                "/ip")
                    ip=$(curl -s4 ifconfig.me)
                    reply "$chat_id" "🌐 公网 IP: <code>$ip</code>"
                    ;;

                "/uptime")
                    reply "$chat_id" "⏱ 系统已运行: $(uptime -p)"
                    ;;
            esac
        fi

        # 更新 offset
        next=$((update_id + 1))
        echo $next > /tmp/vp_tg_offset
    done

    if [ -f /tmp/vp_tg_offset ]; then
        OFFSET=$(cat /tmp/vp_tg_offset)
    fi
done
EOF
    chmod +x "$LISTENER_SCRIPT"
}

# ---------- 配置向导 ----------
configure_bot() {
    printf "${BLUE}===== Telegram 机器人配置 =====${NC}\n"
    read -p "Bot Token: " token
    read -p "管理员 Chat ID: " chat_id
    cat > "$TG_CONF" <<EOF
TG_BOT_TOKEN="$token"
TG_CHAT_ID="$chat_id"
EOF
    chmod 600 "$TG_CONF"
    printf "${GREEN}配置已保存到 %s${NC}\n" "$TG_CONF"
}

# ---------- 后台启动/停止 ----------
start_bot() {
    if [ ! -f "$TG_CONF" ]; then
        printf "${RED}请先配置机器人！${NC}\n"
        return 1
    fi
    generate_listener
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        printf "${YELLOW}机器人已在运行中。${NC}\n"
        return
    fi
    nohup bash "$LISTENER_SCRIPT" > /dev/null 2>&1 &
    echo $! > "$PID_FILE"
    printf "${GREEN}监控机器人已启动 (PID: %s)${NC}\n" $(cat "$PID_FILE")
}

stop_bot() {
    if [ -f "$PID_FILE" ]; then
        kill $(cat "$PID_FILE") 2>/dev/null && printf "${GREEN}机器人已停止。${NC}\n"
        rm -f "$PID_FILE"
    else
        printf "${YELLOW}机器人未运行。${NC}\n"
    fi
}

status_bot() {
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE") 2>/dev/null; then
        printf "${GREEN}运行中 (PID: %s)${NC}\n" $(cat "$PID_FILE")
    else
        printf "${RED}未运行${NC}\n"
    fi
}

# ---------- 主菜单 ----------
while true; do
    clear
    printf "${BLUE}===== Telegram 远程监控 =====${NC}\n"
    printf "状态: "; status_bot
    echo "1. 配置 Bot Token / Chat ID"
    echo "2. 启动监控机器人"
    echo "3. 停止机器人"
    echo "0. 返回主菜单"
    read -p "选择: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || continue
    case $choice in
        1) configure_bot ;;
        2) start_bot ;;
        3) stop_bot ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done