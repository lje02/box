#!/bin/bash

# --- 路径定义 ---
BOT_DIR="/etc/sing-box"
BOT_SCRIPT="$BOT_DIR/tg_worker.sh"
BOT_CONF="$BOT_DIR/tg_bot.conf"
BOT_SERVICE="/etc/systemd/system/tg-bot.service"

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
PLAIN='\033[0m'

# --- 内部函数：获取监控数据 ---
get_stats() {
    local uptime=$(uptime -p | sed 's/up //')
    local mem_info=$(free -m | awk '/Mem:/ {printf "%d %d %.2f", $3, $2, $3/$2*100}')
    local mem_used=$(echo $mem_info | awk '{print $1}')
    local mem_total=$(echo $mem_info | awk '{print $2}')
    local mem_per=$(echo $mem_info | awk '{print $3}')
    
    local load=$(uptime | awk -F'load average:' '{print $2}' | xargs)
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    local status=$(systemctl is-active sing-box == "active" && echo "✅ 运行中" || echo "❌ 已停止")
    
    # 获取默认网卡流量 (兼容常见命名)
    local dev=$(ip route | grep default | awk '{print $5}' | head -n1)
    local rx=$(cat /proc/net/dev | grep "$dev" | awk '{printf "%.2f GB", $2/1024/1024/1024}')
    local tx=$(cat /proc/net/dev | grep "$dev" | awk '{printf "%.2f GB", $10/1024/1024/1024}')

    echo "📊 *sing-box 系统报告*
--------------------------
🔹 *服务状态*: $status
🔹 *CPU 占用*: ${cpu_per}%
🔹 *内存占用*: ${mem_used}/${mem_total}MB (${mem_per}%)
🔹 *系统负载*: $load
🔹 *网卡流量*: ⬇️$rx | ⬆️$tx
🔹 *系统运行*: $uptime
--------------------------
🕒 $(date '+%Y-%m-%d %H:%M:%S')"
}

# --- 脚本安装功能 ---
install_bot() {
    echo -e "${YELLOW}--- Telegram 机器人安装 ---${PLAIN}"
    
    # 环境检查
    apt update && apt install -y jq curl bc procps
    
    mkdir -p "$BOT_DIR"
    
    read -p "请输入 Bot Token: " TG_TOKEN
    read -p "请输入 Chat ID: " TG_CHATID
    
    if [[ -z "$TG_TOKEN" || -z "$TG_CHATID" ]]; then
        echo -e "${RED}✘ 错误: Token 或 Chat ID 不能为空${PLAIN}"
        return
    fi
    
    # 保存配置
    cat > "$BOT_CONF" <<EOF
TOKEN="$TG_TOKEN"
CHAT_ID="$TG_CHATID"
EOF

    # 生成工作脚本
    cat > "$BOT_SCRIPT" <<'EOF'
#!/bin/bash
source /etc/sing-box/tg_bot.conf
OFFSET_FILE="/tmp/tg_bot_offset"
LAST_ALERT_TIME=0

send_msg() {
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
        -d "chat_id=$CHAT_ID" -d "parse_mode=Markdown" -d "text=$1" > /dev/null
}

# 负载警报逻辑 (80%)
check_alert() {
    local now=$(date +%s)
    # 每 1 分钟最多触发一次警报，防止刷屏
    if (( now - LAST_ALERT_TIME < 60 )); then return; fi

    local mem_per=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    local cpu_per=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    
    if (( $(echo "$mem_per > 80" | bc -l) )) || (( $(echo "$cpu_per > 80" | bc -l) )); then
        send_msg "⚠️ *负载预警 (超过80%)*
--------------------------
🔹 CPU占用: ${cpu_per}%
🔹 内存占用: ${mem_per}%
🚨 请检查系统状态！"
        LAST_ALERT_TIME=$now
    fi
}

while true; do
    # 负载检查
    check_alert

    # 指令监听 (长轮询)
    OFFSET=$(cat $OFFSET_FILE 2>/dev/null || echo 0)
    UPDATES=$(curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET&timeout=30")
    
    echo "$UPDATES" | jq -c '.result[]' 2>/dev/null | while read -r update; do
        MSG_TEXT=$(echo "$update" | jq -r '.message.text')
        USER_ID=$(echo "$update" | jq -r '.message.from.id')
        UPDATE_ID=$(echo "$update" | jq -r '.update_id')

        if [[ "$USER_ID" == "$CHAT_ID" ]]; then
            if [[ "$MSG_TEXT" == "/status" ]]; then
                # 这里调用外部生成的报告函数逻辑
                source /etc/sing-box/tg_bot_functions.sh
                send_msg "$(get_stats)"
            elif [[ "$MSG_TEXT" == "/start" ]]; then
                send_msg "✅ 监控已上线！发送 /status 获取报告。负载超过 80% 我会自动通知你。"
            fi
        fi
        echo $((UPDATE_ID + 1)) > $OFFSET_FILE
    done
    sleep 2
done
EOF

    # 提取监控函数到独立文件供 worker 调用
    declare -f get_stats > "$BOT_DIR/tg_bot_functions.sh"
    echo "PLAIN=''" >> "$BOT_DIR/tg_bot_functions.sh" # 补丁

    chmod +x "$BOT_SCRIPT"

    # 生成 Service
    cat > "$BOT_SERVICE" <<EOF
[Unit]
Description=Sing-box Telegram Bot
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $BOT_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now tg-bot
    echo -e "${GREEN}✔ 机器人已启动并设置为开机自启${PLAIN}"
}

# --- 卸载功能 ---
uninstall_bot() {
    echo -e "${YELLOW}正在卸载 Telegram 机器人...${PLAIN}"
    systemctl stop tg-bot 2>/dev/null
    systemctl disable tg-bot 2>/dev/null
    rm -f "$BOT_SERVICE"
    rm -f "$BOT_SCRIPT"
    rm -f "$BOT_CONF"
    rm -f "$BOT_DIR/tg_bot_functions.sh"
    systemctl daemon-reload
    echo -e "${GREEN}✔ 卸载完成${PLAIN}"
}

# --- 主菜单 ---
clear
echo -e "${CYAN}sing-box Telegram 监控管理脚本${PLAIN}"
echo -e "--------------------------------"
echo -e "1. 安装/重新安装 机器人"
echo -e "2. 卸载 机器人"
echo -e "0. 退出"
read -p "请选择: " choice

case $choice in
    1) install_bot ;;
    2) uninstall_bot ;;
    *) exit 0 ;;
esac
