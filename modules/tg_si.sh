#!/bin/bash
# ╔══════════════════════════════════════════════════════╗
# ║     Telegram 私聊机器人 — 一键安装脚本               ║
# ║     支持: Ubuntu / Debian / CentOS / RHEL            ║
# ╚══════════════════════════════════════════════════════╝

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="/opt/tg-private-chat-bot"
SERVICE_NAME="tg-private-chat"
PYTHON_MIN="3.8"

# ─────────────────────────── 工具函数 ───────────────────────────

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

banner() {
cat << 'EOF'

  ████████╗ ██████╗     ██████╗  ██████╗ ████████╗
     ██╔══╝██╔════╝     ██╔══██╗██╔═══██╗╚══██╔══╝
     ██║   ██║  ███╗    ██████╔╝██║   ██║   ██║   
     ██║   ██║   ██║    ██╔══██╗██║   ██║   ██║   
     ██║   ╚██████╔╝    ██████╔╝╚██████╔╝   ██║   
     ╚═╝    ╚═════╝     ╚═════╝  ╚═════╝    ╚═╝   

         Telegram 私聊中转机器人 — 一键安装程序
EOF
echo ""
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本: sudo bash install.sh"
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VER=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    else
        error "无法识别操作系统，请手动安装。"
    fi
    info "检测到操作系统: ${OS} ${OS_VER}"
}

check_python() {
    if command -v python3 &>/dev/null; then
        PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        if python3 -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)"; then
            success "Python ${PY_VER} ✓"
            PYTHON_CMD="python3"
            return
        fi
    fi
    warn "未找到满足要求的 Python (需要 >= ${PYTHON_MIN})，将自动安装..."
    install_python
}

install_python() {
    case $OS in
        ubuntu|debian)
            apt-get install -y python3 python3-pip python3-venv >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y python3 python3-pip >/dev/null 2>&1
            else
                yum install -y python3 python3-pip >/dev/null 2>&1
            fi
            ;;
        *)
            error "不支持的系统，请手动安装 Python 3.8+"
            ;;
    esac
    PYTHON_CMD="python3"
    success "Python 安装完成"
}

install_system_deps() {
    step "安装系统依赖"
    case $OS in
        ubuntu|debian)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y python3 python3-pip python3-venv curl git >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux)
            if command -v dnf &>/dev/null; then
                dnf install -y python3 python3-pip curl git >/dev/null 2>&1
            else
                yum install -y python3 python3-pip curl git >/dev/null 2>&1
            fi
            ;;
        fedora)
            dnf install -y python3 python3-pip curl git >/dev/null 2>&1
            ;;
    esac
    success "系统依赖安装完成"
}

# ─────────────────────────── 配置交互 ───────────────────────────

collect_config() {
    step "配置机器人参数"

    # Bot Token
    echo ""
    echo -e "${BOLD}请输入你的 Bot Token${NC}"
    echo -e "  还没有？去 Telegram 找 ${CYAN}@BotFather${NC} → /newbot 创建"
    echo ""
    while true; do
        read -rp "  Bot Token: " BOT_TOKEN
        BOT_TOKEN=$(echo "$BOT_TOKEN" | tr -d '[:space:]')
        if [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{35,}$ ]]; then
            success "Token 格式正确"
            break
        else
            warn "Token 格式不正确，请重新输入（格式: 数字:字母数字串）"
        fi
    done

    # 管理员 ID
    echo ""
    echo -e "${BOLD}请输入你的 Telegram 用户 ID（管理员）${NC}"
    echo -e "  不知道？发消息给 ${CYAN}@userinfobot${NC} 即可查询"
    echo ""
    read -rp "  管理员 ID (可留空): " ADMIN_ID
    ADMIN_ID=$(echo "$ADMIN_ID" | tr -d '[:space:]')
    if [[ -n "$ADMIN_ID" && ! "$ADMIN_ID" =~ ^[0-9]+$ ]]; then
        warn "ID 格式不正确，已忽略"
        ADMIN_ID=""
    fi

    # 匿名模式
    echo ""
    echo -e "${BOLD}是否启用匿名模式？${NC}"
    echo -e "  ${GREEN}y${NC} = 匿名（双方看不到对方真实名字）"
    echo -e "  ${YELLOW}n${NC} = 实名（显示用户名/昵称）"
    echo ""
    read -rp "  启用匿名模式? [y/N]: " ANON_CHOICE
    if [[ "$ANON_CHOICE" =~ ^[Yy]$ ]]; then
        ANONYMOUS_MODE="True"
        info "已选择: 匿名模式"
    else
        ANONYMOUS_MODE="False"
        info "已选择: 实名模式"
    fi
}

# ─────────────────────────── 安装 ───────────────────────────

write_files() {
    step "写入程序文件"

    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # config.py
    cat > config.py << PYEOF
BOT_TOKEN = "${BOT_TOKEN}"
ADMIN_IDS = [${ADMIN_ID}]
ANONYMOUS_MODE = ${ANONYMOUS_MODE}
PYEOF

    # requirements.txt
    cat > requirements.txt << 'REQEOF'
python-telegram-bot==20.7
REQEOF

    # bot.py — 完整机器人代码
    cat > bot.py << 'BOTEOF'
import logging, sqlite3, hashlib
from functools import wraps
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, constants
from telegram.ext import (Application, CommandHandler, MessageHandler,
                           CallbackQueryHandler, ContextTypes, filters)
from config import BOT_TOKEN, ADMIN_IDS, ANONYMOUS_MODE

logging.basicConfig(format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO)
logger = logging.getLogger(__name__)

def get_db():
    conn = sqlite3.connect("chat.db", check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as db:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            user_id INTEGER PRIMARY KEY, username TEXT, first_name TEXT,
            is_blocked INTEGER DEFAULT 0, created_at TEXT DEFAULT (datetime('now')));
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, user_a INTEGER NOT NULL,
            user_b INTEGER NOT NULL, status TEXT DEFAULT 'pending',
            created_at TEXT DEFAULT (datetime('now')), UNIQUE(user_a, user_b));
        CREATE TABLE IF NOT EXISTS blocked_users (
            blocker_id INTEGER, blocked_id INTEGER, PRIMARY KEY (blocker_id, blocked_id));
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER,
            from_user INTEGER, content TEXT, msg_type TEXT DEFAULT 'text',
            sent_at TEXT DEFAULT (datetime('now')));
        """)

def upsert_user(user):
    with get_db() as db:
        db.execute("""INSERT INTO users (user_id, username, first_name) VALUES (?,?,?)
            ON CONFLICT(user_id) DO UPDATE SET username=excluded.username, first_name=excluded.first_name""",
            (user.id, user.username, user.first_name))

def get_session(a, b):
    with get_db() as db:
        row = db.execute("SELECT * FROM sessions WHERE (user_a=? AND user_b=?) OR (user_a=? AND user_b=?)",
            (a,b,b,a)).fetchone()
        return dict(row) if row else None

def get_active_partner(uid):
    with get_db() as db:
        row = db.execute("SELECT * FROM sessions WHERE (user_a=? OR user_b=?) AND status='active'",
            (uid,uid)).fetchone()
        if row: return row["user_b"] if row["user_a"]==uid else row["user_a"]
        return None

def is_blocked(blocker, blocked):
    with get_db() as db:
        return db.execute("SELECT 1 FROM blocked_users WHERE blocker_id=? AND blocked_id=?",
            (blocker,blocked)).fetchone() is not None

def get_display_name(uid):
    if ANONYMOUS_MODE:
        return f"匿名用户#{hashlib.md5(str(uid).encode()).hexdigest()[:6].upper()}"
    with get_db() as db:
        row = db.execute("SELECT username, first_name FROM users WHERE user_id=?", (uid,)).fetchone()
        if row: return f"@{row['username']}" if row["username"] else row["first_name"]
    return f"用户{uid}"

def log_message(sid, uid, content, mtype="text"):
    with get_db() as db:
        db.execute("INSERT INTO messages (session_id,from_user,content,msg_type) VALUES (?,?,?,?)",
            (sid,uid,content,mtype))

async def cmd_start(update, context):
    user = update.effective_user
    upsert_user(user)
    if context.args and context.args[0].startswith("link_"):
        await handle_accept_invite(update, context, int(context.args[0].split("_")[1]))
        return
    await update.message.reply_html(
        f"👋 你好，{user.first_name}！\n\n这是一个 <b>私聊中转机器人</b>，可以让你与任意用户互相发消息。\n\n"
        "📌 <b>常用命令：</b>\n  /chat @用户名 — 发起私聊\n  /end — 结束当前会话\n"
        "  /block — 屏蔽当前对话者\n  /unblock @用户名 — 取消屏蔽\n  /status — 查看当前会话状态\n  /help — 帮助")

async def cmd_chat(update, context):
    user = update.effective_user; upsert_user(user)
    if not context.args:
        await update.message.reply_text("❌ 用法: /chat @用户名 或 /chat 用户ID"); return
    target_arg = context.args[0].lstrip("@")
    with get_db() as db:
        row = db.execute("SELECT * FROM users WHERE user_id=?", (int(target_arg),)).fetchone() \
            if target_arg.isdigit() else \
            db.execute("SELECT * FROM users WHERE username=?", (target_arg,)).fetchone()
    if not row:
        await update.message.reply_text(
            f"❌ 找不到该用户。\n提示：对方需要先启动机器人。\n分享链接给对方: https://t.me/{context.bot.username}"); return
    target_id = row["user_id"]
    if target_id == user.id: await update.message.reply_text("❌ 不能和自己私聊！"); return
    if row["is_blocked"]: await update.message.reply_text("❌ 该用户已被封禁。"); return
    if is_blocked(target_id, user.id): await update.message.reply_text("❌ 对方已屏蔽你。"); return
    current = get_active_partner(user.id)
    if current:
        await update.message.reply_text("✅ 已在会话中！" if current==target_id else "⚠️ 请先 /end 结束当前会话。"); return
    existing = get_session(user.id, target_id)
    if existing and existing["status"]=="pending":
        await update.message.reply_text("⏳ 已发送邀请，等待对方接受。"); return
    with get_db() as db:
        db.execute("INSERT OR REPLACE INTO sessions (user_a,user_b,status) VALUES (?,?,'pending')", (user.id,target_id))
    kb = InlineKeyboardMarkup([[InlineKeyboardButton("✅ 接受", callback_data=f"accept_{user.id}"),
                                InlineKeyboardButton("❌ 拒绝", callback_data=f"reject_{user.id}")]])
    try:
        await context.bot.send_message(chat_id=target_id,
            text=f"📨 <b>{get_display_name(user.id)}</b> 想与你私聊！\n接受后消息将通过机器人互相转发。\n可随时 /end 结束。",
            parse_mode=constants.ParseMode.HTML, reply_markup=kb)
        await update.message.reply_text("✅ 邀请已发送，等待对方接受...")
    except Exception as e:
        logger.error(e); await update.message.reply_text("❌ 无法联系到对方（对方可能未启动机器人）。")

async def handle_accept_invite(update, context, inviter_id):
    user = update.effective_user
    if is_blocked(user.id, inviter_id): await update.message.reply_text("❌ 你已屏蔽该用户。"); return
    session = get_session(inviter_id, user.id)
    if not session or session["status"]!="pending": await update.message.reply_text("❌ 邀请已过期。"); return
    with get_db() as db:
        db.execute("UPDATE sessions SET status='active' WHERE id=?", (session["id"],))
    await update.message.reply_html(f"✅ 已与 <b>{get_display_name(inviter_id)}</b> 建立私聊！\n直接发消息即可。/end 结束会话")
    try: await context.bot.send_message(chat_id=inviter_id,
        text=f"🎉 <b>{get_display_name(user.id)}</b> 接受了你的邀请！", parse_mode=constants.ParseMode.HTML)
    except: pass

async def callback_handler(update, context):
    query = update.callback_query; await query.answer()
    user = query.from_user; upsert_user(user)
    data = query.data
    if data.startswith("accept_"):
        inviter_id = int(data.split("_")[1])
        session = get_session(inviter_id, user.id)
        if not session or session["status"]!="pending":
            await query.edit_message_text("❌ 邀请已过期。"); return
        with get_db() as db:
            db.execute("UPDATE sessions SET status='active' WHERE id=?", (session["id"],))
        await query.edit_message_text(f"✅ 已接受 {get_display_name(inviter_id)} 的邀请！直接发消息吧。/end 结束")
        try: await context.bot.send_message(chat_id=inviter_id, text=f"🎉 {get_display_name(user.id)} 接受了你的邀请！")
        except: pass
    elif data.startswith("reject_"):
        inviter_id = int(data.split("_")[1])
        with get_db() as db:
            db.execute("DELETE FROM sessions WHERE (user_a=? AND user_b=?) OR (user_a=? AND user_b=?)",
                (inviter_id,user.id,user.id,inviter_id))
        await query.edit_message_text("❌ 已拒绝该邀请。")
        try: await context.bot.send_message(chat_id=inviter_id, text=f"😔 {get_display_name(user.id)} 拒绝了你的邀请。")
        except: pass

async def cmd_end(update, context):
    user = update.effective_user; upsert_user(user)
    partner_id = get_active_partner(user.id)
    if not partner_id: await update.message.reply_text("❌ 你当前没有活跃的会话。"); return
    with get_db() as db:
        db.execute("UPDATE sessions SET status='closed' WHERE (user_a=? OR user_b=?) AND status='active'", (user.id,user.id))
    await update.message.reply_text(f"✅ 已结束与 {get_display_name(partner_id)} 的会话。")
    try: await context.bot.send_message(chat_id=partner_id, text=f"📴 {get_display_name(user.id)} 结束了会话。")
    except: pass

async def cmd_block(update, context):
    user = update.effective_user; upsert_user(user)
    partner_id = get_active_partner(user.id)
    if not partner_id: await update.message.reply_text("❌ 你当前没有活跃的会话。"); return
    with get_db() as db:
        db.execute("INSERT OR IGNORE INTO blocked_users (blocker_id,blocked_id) VALUES (?,?)", (user.id,partner_id))
        db.execute("UPDATE sessions SET status='closed' WHERE (user_a=? OR user_b=?) AND status='active'", (user.id,user.id))
    await update.message.reply_text(f"🚫 已屏蔽并结束与 {get_display_name(partner_id)} 的会话。\n/unblock @用户名 可取消屏蔽。")

async def cmd_unblock(update, context):
    user = update.effective_user
    if not context.args: await update.message.reply_text("❌ 用法: /unblock @用户名 或 /unblock 用户ID"); return
    ta = context.args[0].lstrip("@")
    with get_db() as db:
        row = db.execute("SELECT * FROM users WHERE user_id=?", (int(ta),)).fetchone() if ta.isdigit() else \
              db.execute("SELECT * FROM users WHERE username=?", (ta,)).fetchone()
    if not row: await update.message.reply_text("❌ 找不到该用户。"); return
    with get_db() as db:
        db.execute("DELETE FROM blocked_users WHERE blocker_id=? AND blocked_id=?", (user.id,row["user_id"]))
    await update.message.reply_text(f"✅ 已取消屏蔽 {get_display_name(row['user_id'])}。")

async def cmd_status(update, context):
    user = update.effective_user
    partner_id = get_active_partner(user.id)
    if partner_id:
        await update.message.reply_html(
            f"💬 <b>当前会话状态</b>\n\n正在与 <b>{get_display_name(partner_id)}</b> 私聊中\n/end 结束  /block 屏蔽")
    else:
        await update.message.reply_text("💤 当前没有活跃会话\n\n使用 /chat @用户名 发起私聊")

async def cmd_help(update, context):
    await update.message.reply_html(
        "📖 <b>帮助文档</b>\n\n<b>发起会话：</b>\n  /chat @用户名 — 向对方发起私聊邀请\n\n"
        "<b>会话管理：</b>\n  /end — 结束当前会话\n  /status — 查看会话状态\n\n"
        "<b>用户管理：</b>\n  /block — 屏蔽当前对话者\n  /unblock @用户名 — 取消屏蔽\n\n"
        "<b>消息类型：</b>\n支持文字、图片、视频、文件、语音、贴纸等。\n\n"
        f"<b>当前模式：</b>{'🎭 匿名' if ANONYMOUS_MODE else '👤 实名'}")

async def forward_message(update, context):
    user = update.effective_user; upsert_user(user)
    msg = update.message
    partner_id = get_active_partner(user.id)
    if not partner_id:
        await msg.reply_text("💬 没有活跃的会话。\n使用 /chat @用户名 发起私聊，或 /help 查看帮助。"); return
    if is_blocked(partner_id, user.id):
        await msg.reply_text("❌ 对方已屏蔽你，消息无法发送。"); return
    label = "" if ANONYMOUS_MODE else f"[{get_display_name(user.id)}] "
    try:
        if msg.text: await context.bot.send_message(chat_id=partner_id, text=f"{label}{msg.text}")
        elif msg.photo: await context.bot.send_photo(chat_id=partner_id, photo=msg.photo[-1].file_id, caption=f"{label}{msg.caption or ''}")
        elif msg.video: await context.bot.send_video(chat_id=partner_id, video=msg.video.file_id, caption=f"{label}{msg.caption or ''}")
        elif msg.document: await context.bot.send_document(chat_id=partner_id, document=msg.document.file_id, caption=f"{label}{msg.caption or ''}")
        elif msg.voice: await context.bot.send_voice(chat_id=partner_id, voice=msg.voice.file_id)
        elif msg.audio: await context.bot.send_audio(chat_id=partner_id, audio=msg.audio.file_id, caption=f"{label}{msg.caption or ''}")
        elif msg.sticker: await context.bot.send_sticker(chat_id=partner_id, sticker=msg.sticker.file_id)
        elif msg.video_note: await context.bot.send_video_note(chat_id=partner_id, video_note=msg.video_note.file_id)
        elif msg.location: await context.bot.send_location(chat_id=partner_id, latitude=msg.location.latitude, longitude=msg.location.longitude)
        else: await msg.reply_text("⚠️ 暂不支持此消息类型。"); return
        await msg.reply_text("✓ 已发送", quote=True)
        session = get_session(user.id, partner_id)
        if session: log_message(session["id"], user.id, msg.text or msg.caption or "[媒体]")
    except Exception as e:
        logger.error(e); await msg.reply_text("❌ 消息发送失败，对方可能已屏蔽机器人。")

def admin_only(func):
    @wraps(func)
    async def wrapper(update, context):
        if update.effective_user.id not in ADMIN_IDS:
            await update.message.reply_text("❌ 仅管理员可用此命令。"); return
        return await func(update, context)
    return wrapper

@admin_only
async def cmd_ban(update, context):
    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法: /ban 用户ID"); return
    uid = int(context.args[0])
    with get_db() as db:
        db.execute("UPDATE users SET is_blocked=1 WHERE user_id=?", (uid,))
        db.execute("UPDATE sessions SET status='closed' WHERE (user_a=? OR user_b=?) AND status='active'", (uid,uid))
    await update.message.reply_text(f"✅ 已封禁用户 {uid}")

@admin_only
async def cmd_unban(update, context):
    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("用法: /unban 用户ID"); return
    with get_db() as db:
        db.execute("UPDATE users SET is_blocked=0 WHERE user_id=?", (int(context.args[0]),))
    await update.message.reply_text(f"✅ 已解封用户 {context.args[0]}")

@admin_only
async def cmd_stats(update, context):
    with get_db() as db:
        tu = db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        as_ = db.execute("SELECT COUNT(*) FROM sessions WHERE status='active'").fetchone()[0]
        tm = db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    await update.message.reply_html(f"📊 <b>统计</b>\n用户总数: {tu}\n活跃会话: {as_}\n消息总数: {tm}")

def main():
    init_db()
    app = Application.builder().token(BOT_TOKEN).build()
    for cmd, handler in [("start",cmd_start),("chat",cmd_chat),("end",cmd_end),("block",cmd_block),
                          ("unblock",cmd_unblock),("status",cmd_status),("help",cmd_help),
                          ("ban",cmd_ban),("unban",cmd_unban),("stats",cmd_stats)]:
        app.add_handler(CommandHandler(cmd, handler))
    app.add_handler(CallbackQueryHandler(callback_handler))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, forward_message))
    logger.info("机器人启动中...")
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF

    success "程序文件写入完成"
}

setup_venv() {
    step "创建 Python 虚拟环境"
    cd "$INSTALL_DIR"
    $PYTHON_CMD -m venv venv >/dev/null 2>&1
    source venv/bin/activate
    pip install --upgrade pip -q
    pip install -r requirements.txt -q
    success "依赖安装完成 (python-telegram-bot 20.7)"
}

create_service() {
    step "创建系统服务 (systemd)"

    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Telegram Private Chat Bot
After=network.target
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
    success "systemd 服务已创建: ${SERVICE_NAME}"
}

create_manage_script() {
    cat > /usr/local/bin/tgbot << EOF
#!/bin/bash
case "\$1" in
    start)   systemctl start ${SERVICE_NAME} && echo "✅ 机器人已启动" ;;
    stop)    systemctl stop ${SERVICE_NAME} && echo "⏹ 机器人已停止" ;;
    restart) systemctl restart ${SERVICE_NAME} && echo "🔄 机器人已重启" ;;
    status)  systemctl status ${SERVICE_NAME} ;;
    log)     journalctl -u ${SERVICE_NAME} -f ;;
    uninstall)
        systemctl stop ${SERVICE_NAME} 2>/dev/null
        systemctl disable ${SERVICE_NAME} 2>/dev/null
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        rm -rf ${INSTALL_DIR}
        rm -f /usr/local/bin/tgbot
        systemctl daemon-reload
        echo "✅ 机器人已卸载"
        ;;
    *) echo "用法: tgbot {start|stop|restart|status|log|uninstall}" ;;
esac
EOF
    chmod +x /usr/local/bin/tgbot
    success "管理工具已安装: tgbot"
}

start_bot() {
    step "启动机器人"
    systemctl start ${SERVICE_NAME}
    sleep 2
    if systemctl is-active --quiet ${SERVICE_NAME}; then
        success "机器人启动成功！"
    else
        warn "启动可能遇到问题，请检查日志: tgbot log"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║          🎉 安装完成！                        ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}安装目录:${NC}  ${INSTALL_DIR}"
    echo -e "  ${BOLD}数据库:${NC}    ${INSTALL_DIR}/chat.db"
    echo -e "  ${BOLD}配置文件:${NC}  ${INSTALL_DIR}/config.py"
    echo ""
    echo -e "  ${BOLD}管理命令：${NC}"
    echo -e "    ${CYAN}tgbot start${NC}     — 启动"
    echo -e "    ${CYAN}tgbot stop${NC}      — 停止"
    echo -e "    ${CYAN}tgbot restart${NC}   — 重启"
    echo -e "    ${CYAN}tgbot status${NC}    — 查看状态"
    echo -e "    ${CYAN}tgbot log${NC}       — 实时日志"
    echo -e "    ${CYAN}tgbot uninstall${NC} — 卸载"
    echo ""
    echo -e "  ${BOLD}修改配置后重启:${NC}"
    echo -e "    ${CYAN}nano ${INSTALL_DIR}/config.py && tgbot restart${NC}"
    echo ""
    echo -e "  ${BOLD}去 Telegram 找你的机器人开始使用吧！${NC}"
    echo ""
}

# ─────────────────────────── 主流程 ───────────────────────────

main() {
    banner
    check_root
    detect_os
    install_system_deps
    check_python
    collect_config
    write_files
    setup_venv
    create_service
    create_manage_script
    start_bot
    print_summary
}

main
