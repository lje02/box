#!/bin/bash
# ╔══════════════════════════════════════════════════════╗
# ║     Telegram 专属私信机器人 — 一键安装脚本           ║
# ║     用户发消息 → Bot 转发给绑定的 Owner              ║
# ║     支持: Ubuntu / Debian / CentOS / RHEL            ║
# ╚══════════════════════════════════════════════════════╝

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/tg-relay-bot"
SERVICE_NAME="tg-relay-bot"

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

banner() {
cat << 'EOF'

  ╔═══════════════════════════════════════════╗
  ║   📨  Telegram 专属私信机器人              ║
  ║   所有人发消息 → 转发给你 → 你可以回复     ║
  ╚═══════════════════════════════════════════╝

EOF
}

check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 权限: sudo bash install.sh"
}

detect_os() {
    [ -f /etc/os-release ] && . /etc/os-release && OS=$ID || OS="unknown"
    info "操作系统: ${OS} ${VERSION_ID:-}"
}

install_deps() {
    step "安装系统依赖"
    case $OS in
        ubuntu|debian)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y python3 python3-pip python3-venv curl >/dev/null 2>&1 ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y python3 python3-pip curl >/dev/null 2>&1
            else
                yum install -y python3 python3-pip curl >/dev/null 2>&1
            fi ;;
        *) warn "未知系统，尝试继续..." ;;
    esac
    success "依赖完成"
}

collect_config() {
    step "配置机器人"

    echo ""
    echo -e "${BOLD}① Bot Token${NC}  （去 @BotFather → /newbot 获取）"
    while true; do
        read -rp "  Token: " BOT_TOKEN
        BOT_TOKEN="${BOT_TOKEN//[[:space:]]/}"
        [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{35,}$ ]] && break
        warn "格式不正确，请重新输入"
    done
    success "Token OK"

    echo ""
    echo -e "${BOLD}② 你的 Telegram 用户 ID${NC}（Owner，所有消息将转发给你）"
    echo -e "   不知道？发消息给 ${CYAN}@userinfobot${NC} 查询"
    while true; do
        read -rp "  Owner ID: " OWNER_ID
        OWNER_ID="${OWNER_ID//[[:space:]]/}"
        [[ "$OWNER_ID" =~ ^[0-9]+$ ]] && break
        warn "ID 应为纯数字，请重新输入"
    done
    success "Owner ID: $OWNER_ID"

    echo ""
    echo -e "${BOLD}③ 欢迎语${NC}（用户 /start 时看到，留空用默认）"
    read -rp "  欢迎语: " WELCOME_MSG
    WELCOME_MSG="${WELCOME_MSG:-你好！给我发消息，我会尽快回复你 😊}"
}

write_files() {
    step "写入程序文件"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # ── config.py ──
    cat > config.py << PYEOF
BOT_TOKEN   = "${BOT_TOKEN}"
OWNER_ID    = ${OWNER_ID}
WELCOME_MSG = "${WELCOME_MSG}"
PYEOF

    echo "python-telegram-bot==20.7" > requirements.txt

    # ── bot.py ──
    cat > bot.py << 'BOTEOF'
"""
Telegram 专属私信中转机器人
- 任何用户发消息 → 转发给 OWNER（带发件人信息）
- OWNER 直接回复那条消息 → 自动转回给原始用户
- 支持全部消息类型：文字/图片/视频/文件/语音/贴纸等
- OWNER 可一键屏蔽用户，或 /ban /unban /users 管理
"""

import logging, sqlite3
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, constants
from telegram.ext import (
    Application, CommandHandler, MessageHandler,
    CallbackQueryHandler, ContextTypes, filters
)
from config import BOT_TOKEN, OWNER_ID, WELCOME_MSG

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
log = logging.getLogger(__name__)


# ── 数据库 ───────────────────────────────────────────────────────

def db():
    c = sqlite3.connect("relay.db", check_same_thread=False)
    c.row_factory = sqlite3.Row
    return c

def init_db():
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            uid        INTEGER PRIMARY KEY,
            username   TEXT,
            first_name TEXT,
            banned     INTEGER DEFAULT 0,
            first_seen TEXT DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS msg_map (
            owner_msg_id  INTEGER PRIMARY KEY,
            sender_uid    INTEGER
        );
        """)

def upsert(user):
    with db() as c:
        c.execute("""
        INSERT INTO users (uid, username, first_name) VALUES (?,?,?)
        ON CONFLICT(uid) DO UPDATE SET
            username=excluded.username,
            first_name=excluded.first_name
        """, (user.id, user.username, user.first_name))

def is_banned(uid):
    with db() as c:
        r = c.execute("SELECT banned FROM users WHERE uid=?", (uid,)).fetchone()
        return bool(r and r["banned"])

def save_map(owner_msg_id, sender_uid):
    with db() as c:
        c.execute("INSERT OR REPLACE INTO msg_map VALUES (?,?)",
                  (owner_msg_id, sender_uid))

def get_map(owner_msg_id):
    with db() as c:
        return c.execute("SELECT sender_uid FROM msg_map WHERE owner_msg_id=?",
                         (owner_msg_id,)).fetchone()

def display(user):
    name = user.first_name or ""
    if user.last_name:
        name += f" {user.last_name}"
    if user.username:
        name += f" (@{user.username})"
    return name or f"uid:{user.id}"


# ── 命令处理 ─────────────────────────────────────────────────────

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    upsert(user)
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "👑 <b>你是机器人 Owner</b>\n\n"
            "所有用户消息都会转发到这里。\n"
            "<b>直接回复</b>转发消息即可回复给对方。\n\n"
            "📋 管理命令：\n"
            "  /ban UID   — 屏蔽用户\n"
            "  /unban UID — 解除屏蔽\n"
            "  /users     — 用户列表"
        )
    else:
        await update.message.reply_text(WELCOME_MSG)

async def cmd_ban(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID: return
    if not ctx.args or not ctx.args[0].isdigit():
        await update.message.reply_text("用法: /ban <用户ID>"); return
    uid = int(ctx.args[0])
    with db() as c:
        c.execute("UPDATE users SET banned=1 WHERE uid=?", (uid,))
    await update.message.reply_text(f"🚫 已屏蔽 {uid}")

async def cmd_unban(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID: return
    if not ctx.args or not ctx.args[0].isdigit():
        await update.message.reply_text("用法: /unban <用户ID>"); return
    uid = int(ctx.args[0])
    with db() as c:
        c.execute("UPDATE users SET banned=0 WHERE uid=?", (uid,))
    await update.message.reply_text(f"✅ 已解封 {uid}")

async def cmd_users(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id != OWNER_ID: return
    with db() as c:
        rows = c.execute(
            "SELECT uid, username, first_name, banned FROM users ORDER BY first_seen DESC LIMIT 50"
        ).fetchall()
    if not rows:
        await update.message.reply_text("暂无用户记录"); return
    lines = ["👥 <b>用户列表（最近50）</b>\n"]
    for r in rows:
        name = f"@{r['username']}" if r["username"] else (r["first_name"] or "—")
        flag = " 🚫" if r["banned"] else ""
        lines.append(f"  <code>{r['uid']}</code>  {name}{flag}")
    await update.message.reply_html("\n".join(lines))


# ── 消息转发核心 ─────────────────────────────────────────────────

async def on_message(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    msg  = update.message
    user = update.effective_user
    if not msg: return
    upsert(user)

    # ── Owner 回复转发消息 → 发回给用户 ──────────────────────────
    if user.id == OWNER_ID:
        if not msg.reply_to_message:
            return  # owner 主动发消息不处理
        mapping = get_map(msg.reply_to_message.message_id)
        if not mapping:
            await msg.reply_text("⚠️ 找不到原始用户，可能消息太老了。", quote=True)
            return
        target_uid = mapping["sender_uid"]
        try:
            await _send_any(ctx.bot, target_uid, msg, prefix="")
            await msg.reply_text("✓ 已回复", quote=True)
        except Exception as e:
            log.error("回复用户失败: %s", e)
            await msg.reply_text(f"❌ 发送失败: {e}", quote=True)
        return

    # ── 普通用户 → 转发给 Owner ──────────────────────────────────
    if is_banned(user.id):
        await msg.reply_text("您已被屏蔽，无法发送消息。")
        return

    header = (
        f"📨 来自 <b>{display(user)}</b>\n"
        f"<code>ID: {user.id}</code>"
    )
    kb = InlineKeyboardMarkup([[
        InlineKeyboardButton("🚫 屏蔽此人", callback_data=f"ban_{user.id}")
    ]])

    try:
        # 发 header 通知
        await ctx.bot.send_message(
            chat_id=OWNER_ID,
            text=header,
            parse_mode=constants.ParseMode.HTML,
            reply_markup=kb
        )
        # 转发实际消息内容，记录这条消息的 ID 做映射
        fwd = await _send_any(ctx.bot, OWNER_ID, msg)
        save_map(fwd.message_id, user.id)

        await msg.reply_text("✅ 消息已发送，等待回复～")
    except Exception as e:
        log.error("转发给 Owner 失败: %s", e)
        await msg.reply_text("❌ 发送失败，请稍后重试。")


async def _send_any(bot, chat_id: int, msg, prefix=""):
    """将任意类型消息发送到目标，返回发出的 Message 对象"""
    cap = prefix + (msg.caption or "") if prefix else (msg.caption or None)
    txt = prefix + msg.text         if (prefix and msg.text) else msg.text

    if msg.text:
        return await bot.send_message(chat_id=chat_id, text=txt or msg.text)
    elif msg.photo:
        return await bot.send_photo(chat_id=chat_id,
               photo=msg.photo[-1].file_id, caption=cap or None)
    elif msg.video:
        return await bot.send_video(chat_id=chat_id,
               video=msg.video.file_id, caption=cap or None)
    elif msg.document:
        return await bot.send_document(chat_id=chat_id,
               document=msg.document.file_id, caption=cap or None)
    elif msg.voice:
        return await bot.send_voice(chat_id=chat_id, voice=msg.voice.file_id)
    elif msg.audio:
        return await bot.send_audio(chat_id=chat_id,
               audio=msg.audio.file_id, caption=cap or None)
    elif msg.sticker:
        return await bot.send_sticker(chat_id=chat_id, sticker=msg.sticker.file_id)
    elif msg.video_note:
        return await bot.send_video_note(chat_id=chat_id, video_note=msg.video_note.file_id)
    elif msg.location:
        return await bot.send_location(chat_id=chat_id,
               latitude=msg.location.latitude, longitude=msg.location.longitude)
    elif msg.contact:
        return await bot.send_contact(chat_id=chat_id,
               phone_number=msg.contact.phone_number,
               first_name=msg.contact.first_name)
    else:
        return await bot.send_message(chat_id=chat_id,
               text=f"{prefix}[不支持的消息类型]")


# ── 按钮回调 ─────────────────────────────────────────────────────

async def on_callback(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if update.effective_user.id != OWNER_ID: return
    if q.data.startswith("ban_"):
        uid = int(q.data.split("_")[1])
        with db() as c:
            c.execute("UPDATE users SET banned=1 WHERE uid=?", (uid,))
        await q.edit_message_reply_markup(reply_markup=None)
        await q.message.reply_text(f"🚫 已屏蔽用户 {uid}")


# ── 主程序 ───────────────────────────────────────────────────────

def main():
    init_db()
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start",  cmd_start))
    app.add_handler(CommandHandler("ban",    cmd_ban))
    app.add_handler(CommandHandler("unban",  cmd_unban))
    app.add_handler(CommandHandler("users",  cmd_users))
    app.add_handler(CallbackQueryHandler(on_callback))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, on_message))
    log.info("Bot 启动，Owner=%s", OWNER_ID)
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF

    success "文件写入完成"
}

setup_venv() {
    step "安装 Python 依赖"
    cd "$INSTALL_DIR"
    python3 -m venv venv >/dev/null 2>&1
    venv/bin/pip install --upgrade pip -q
    venv/bin/pip install python-telegram-bot==20.7 -q
    success "python-telegram-bot 安装完成"
}

create_service() {
    step "注册系统服务"
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Telegram Relay Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/python3 ${INSTALL_DIR}/bot.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME} >/dev/null 2>&1
    success "systemd 服务已注册"
}

create_cli() {
    cat > /usr/local/bin/relaybot << CLIEOF
#!/bin/bash
SVC="${SERVICE_NAME}"
case "\$1" in
    start)     systemctl start   \$SVC && echo "✅ 已启动" ;;
    stop)      systemctl stop    \$SVC && echo "⏹ 已停止" ;;
    restart)   systemctl restart \$SVC && echo "🔄 已重启" ;;
    status)    systemctl status  \$SVC ;;
    log)       journalctl -u \$SVC -f ;;
    uninstall)
        systemctl stop    \$SVC 2>/dev/null
        systemctl disable \$SVC 2>/dev/null
        rm -f /etc/systemd/system/\${SVC}.service
        rm -f /usr/local/bin/relaybot
        rm -rf ${INSTALL_DIR}
        systemctl daemon-reload
        echo "✅ 已完全卸载" ;;
    *) echo "用法: relaybot {start|stop|restart|status|log|uninstall}" ;;
esac
CLIEOF
    chmod +x /usr/local/bin/relaybot
    success "管理命令 relaybot 已安装"
}

start_bot() {
    step "启动机器人"
    systemctl start ${SERVICE_NAME}
    sleep 2
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        success "机器人运行中！"
    else
        warn "启动异常，请查看日志: relaybot log"
    fi
}

summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║   🎉  安装完成！机器人已启动                      ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}工作方式：${NC}"
    echo -e "  用户发任意消息 → Bot → 你（Owner）收到 + 发件人信息"
    echo -e "  你 ${CYAN}直接回复${NC} 那条消息 → Bot → 自动发给对方"
    echo ""
    echo -e "  ${BOLD}管理操作（在 Telegram 里）：${NC}"
    echo -e "  • 点 ${RED}🚫 屏蔽此人${NC} 按钮 或 /ban UID  — 屏蔽用户"
    echo -e "  • /unban UID                           — 解除屏蔽"
    echo -e "  • /users                               — 用户列表"
    echo ""
    echo -e "  ${BOLD}服务器管理：${NC}"
    echo -e "  ${CYAN}relaybot start|stop|restart|status|log|uninstall${NC}"
    echo ""
    echo -e "  ${BOLD}配置文件：${NC} ${INSTALL_DIR}/config.py"
    echo -e "  修改后执行 ${CYAN}relaybot restart${NC} 生效"
    echo ""
}

main() {
    banner
    check_root
    detect_os
    install_deps
    collect_config
    write_files
    setup_venv
    create_service
    create_cli
    start_bot
    summary
}

main
