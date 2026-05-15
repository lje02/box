#!/bin/bash
# ╔══════════════════════════════════════════════════════╗
# ║     Telegram 客服中转机器人 — 一键安装脚本           ║
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

INSTALL_DIR="/opt/tg-relay-bot"
SERVICE_NAME="tg-relay-bot"
PYTHON_MIN="3.8"

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

         Telegram 客服中转机器人 — 一键安装程序
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

check_python() {
    if command -v python3 &>/dev/null; then
        if python3 -c "import sys; exit(0 if sys.version_info >= (3,8) else 1)"; then
            PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
            success "Python ${PY_VER} ✓"
            PYTHON_CMD="python3"
            return
        fi
    fi
    warn "未找到满足要求的 Python，将自动安装..."
    case $OS in
        ubuntu|debian) apt-get install -y python3 python3-pip python3-venv >/dev/null 2>&1 ;;
        *) dnf install -y python3 python3-pip >/dev/null 2>&1 || yum install -y python3 python3-pip >/dev/null 2>&1 ;;
    esac
    PYTHON_CMD="python3"
    success "Python 安装完成"
}

# ─────────────────────────── 配置交互 ───────────────────────────

collect_config() {
    step "配置机器人参数"

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

    echo ""
    echo -e "${BOLD}请输入绑定的主人 Telegram 用户 ID${NC}"
    echo -e "  说明: 所有用户的消息都会转发给这个 ID 的账号"
    echo -e "  不知道自己的 ID？发消息给 ${CYAN}@userinfobot${NC} 查询"
    echo ""
    while true; do
        read -rp "  主人 ID: " OWNER_ID
        OWNER_ID=$(echo "$OWNER_ID" | tr -d '[:space:]')
        if [[ "$OWNER_ID" =~ ^[0-9]+$ ]]; then
            success "主人 ID: ${OWNER_ID}"
            break
        else
            warn "ID 格式不正确，请输入纯数字的用户 ID"
        fi
    done

    echo ""
    echo -e "${BOLD}是否启用匿名模式？${NC}"
    echo -e "  ${GREEN}y${NC} = 匿名（主人看不到来信者真实用户名，只显示编号）"
    echo -e "  ${YELLOW}n${NC} = 实名（显示来信者的名字和用户名）"
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

# ─────────────────────────── 写入文件 ───────────────────────────

write_files() {
    step "写入程序文件"
    mkdir -p "$INSTALL_DIR"
    cd "$INSTALL_DIR"

    # config.py
    cat > config.py << PYEOF
BOT_TOKEN = "${BOT_TOKEN}"
OWNER_ID = ${OWNER_ID}
ANONYMOUS_MODE = ${ANONYMOUS_MODE}
PYEOF

    # requirements.txt
    cat > requirements.txt << 'REQEOF'
python-telegram-bot==20.7
REQEOF

    # bot.py
    cat > bot.py << 'BOTEOF'
"""
Telegram 客服中转机器人
────────────────────────
工作流程：
  1. 任何用户给机器人发消息
  2. 机器人把消息转发给「主人」，并附带来源信息
  3. 主人回复某条转发消息，机器人把回复转回给原始用户
  4. 用户或主人均可发送 /end 结束与对方的会话

数据库表：
  - sessions  : 记录 user_id <-> 是否活跃，以及主人正在回复哪个用户
"""

import logging
import sqlite3
import hashlib
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, constants
from telegram.ext import (
    Application, CommandHandler, MessageHandler,
    CallbackQueryHandler, ContextTypes, filters,
)
from config import BOT_TOKEN, OWNER_ID, ANONYMOUS_MODE

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

# ──────────────────────── 数据库 ────────────────────────

def get_db():
    conn = sqlite3.connect("chat.db", check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as db:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS sessions (
            user_id     INTEGER PRIMARY KEY,
            status      TEXT    DEFAULT 'active',
            started_at  TEXT    DEFAULT (datetime('now')),
            ended_at    TEXT
        );
        -- 记录主人当前正在回复哪个用户（只存一行）
        CREATE TABLE IF NOT EXISTS owner_reply_target (
            id          INTEGER PRIMARY KEY CHECK (id = 1),
            user_id     INTEGER
        );
        -- 消息映射：owner_msg_id -> user_id（方便通过回复定位用户）
        CREATE TABLE IF NOT EXISTS msg_map (
            owner_msg_id  INTEGER PRIMARY KEY,
            user_id       INTEGER NOT NULL
        );
        """)

# ──────────────────────── 工具函数 ────────────────────────

def display_name(user) -> str:
    """返回展示给主人看的用户名称"""
    if ANONYMOUS_MODE:
        tag = hashlib.md5(str(user.id).encode()).hexdigest()[:6].upper()
        return f"匿名#{tag}"
    parts = []
    if user.first_name:
        parts.append(user.first_name)
    if user.last_name:
        parts.append(user.last_name)
    name = " ".join(parts) or f"用户{user.id}"
    if user.username:
        name += f" (@{user.username})"
    return name

def is_session_active(user_id: int) -> bool:
    with get_db() as db:
        row = db.execute(
            "SELECT status FROM sessions WHERE user_id=?", (user_id,)
        ).fetchone()
        return row is not None and row["status"] == "active"

def open_session(user_id: int):
    with get_db() as db:
        db.execute(
            "INSERT INTO sessions (user_id, status) VALUES (?,?)"
            " ON CONFLICT(user_id) DO UPDATE SET status='active', started_at=datetime('now'), ended_at=NULL",
            (user_id, "active"),
        )

def close_session(user_id: int):
    with get_db() as db:
        db.execute(
            "UPDATE sessions SET status='closed', ended_at=datetime('now') WHERE user_id=?",
            (user_id,),
        )

def set_reply_target(user_id: int):
    """主人输入 /r 或通过回复消息选定要回复的用户"""
    with get_db() as db:
        db.execute(
            "INSERT INTO owner_reply_target (id, user_id) VALUES (1,?)"
            " ON CONFLICT(id) DO UPDATE SET user_id=excluded.user_id",
            (user_id,),
        )

def get_reply_target() -> int | None:
    with get_db() as db:
        row = db.execute("SELECT user_id FROM owner_reply_target WHERE id=1").fetchone()
        return row["user_id"] if row else None

def save_msg_map(owner_msg_id: int, user_id: int):
    """保存主人收到的转发消息ID -> 来源用户ID"""
    with get_db() as db:
        db.execute(
            "INSERT OR REPLACE INTO msg_map (owner_msg_id, user_id) VALUES (?,?)",
            (owner_msg_id, user_id),
        )

def lookup_user_by_owner_msg(owner_msg_id: int) -> int | None:
    with get_db() as db:
        row = db.execute(
            "SELECT user_id FROM msg_map WHERE owner_msg_id=?", (owner_msg_id,)
        ).fetchone()
        return row["user_id"] if row else None

# ──────────────────────── 发送媒体的辅助 ────────────────────────

async def relay_message(bot, target_id: int, msg, prefix: str = "") -> int | None:
    """
    把 msg 转发给 target_id，返回发出消息的 message_id（用于映射）。
    prefix 只对文字/caption 生效。
    """
    try:
        if msg.text:
            sent = await bot.send_message(chat_id=target_id, text=f"{prefix}{msg.text}")
        elif msg.photo:
            sent = await bot.send_photo(
                chat_id=target_id, photo=msg.photo[-1].file_id,
                caption=f"{prefix}{msg.caption or ''}",
            )
        elif msg.video:
            sent = await bot.send_video(
                chat_id=target_id, video=msg.video.file_id,
                caption=f"{prefix}{msg.caption or ''}",
            )
        elif msg.document:
            sent = await bot.send_document(
                chat_id=target_id, document=msg.document.file_id,
                caption=f"{prefix}{msg.caption or ''}",
            )
        elif msg.voice:
            sent = await bot.send_voice(chat_id=target_id, voice=msg.voice.file_id)
        elif msg.audio:
            sent = await bot.send_audio(
                chat_id=target_id, audio=msg.audio.file_id,
                caption=f"{prefix}{msg.caption or ''}",
            )
        elif msg.sticker:
            sent = await bot.send_sticker(chat_id=target_id, sticker=msg.sticker.file_id)
        elif msg.video_note:
            sent = await bot.send_video_note(chat_id=target_id, video_note=msg.video_note.file_id)
        elif msg.location:
            sent = await bot.send_location(
                chat_id=target_id,
                latitude=msg.location.latitude,
                longitude=msg.location.longitude,
            )
        else:
            return None
        return sent.message_id
    except Exception as e:
        logger.error("relay_message 失败: %s", e)
        return None

# ──────────────────────── 命令处理 ────────────────────────

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "👋 你好，主人！\n\n"
            "📌 <b>使用说明：</b>\n"
            "  • 用户发消息给机器人，你会收到转发\n"
            "  • <b>直接回复</b>某条转发消息，即可回复给对应用户\n"
            "  • 或用 /r 用户ID 切换当前回复对象，之后直接发消息即可\n"
            "  • /sessions — 查看所有活跃用户\n"
            "  • /end 用户ID — 结束与某用户的会话\n"
            "  • /endall — 结束所有会话"
        )
    else:
        open_session(user.id)
        await update.message.reply_html(
            f"👋 你好，{user.first_name}！\n\n"
            "直接发消息给我，我会转达给对方。\n"
            "发送 /end 可以结束本次对话。"
        )

async def cmd_end(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """用户或主人结束会话"""
    user = update.effective_user

    if user.id == OWNER_ID:
        # 主人结束指定用户的会话
        if context.args and context.args[0].isdigit():
            target_uid = int(context.args[0])
            close_session(target_uid)
            await update.message.reply_text(f"✅ 已结束与用户 {target_uid} 的会话。")
            try:
                await context.bot.send_message(
                    chat_id=target_uid,
                    text="📴 对方已结束本次对话。如需再次联系，请重新发送消息。",
                )
            except Exception:
                pass
        else:
            # 结束当前回复目标
            target_uid = get_reply_target()
            if target_uid:
                close_session(target_uid)
                await update.message.reply_text(f"✅ 已结束与用户 {target_uid} 的会话。")
                try:
                    await context.bot.send_message(
                        chat_id=target_uid,
                        text="📴 对方已结束本次对话。如需再次联系，请重新发送消息。",
                    )
                except Exception:
                    pass
            else:
                await update.message.reply_text("❌ 用法: /end 用户ID，或先用 /r 选定用户再 /end")
    else:
        # 普通用户结束自己的会话
        if not is_session_active(user.id):
            await update.message.reply_text("❌ 你当前没有活跃的对话。")
            return
        close_session(user.id)
        await update.message.reply_text("✅ 已结束对话。如需再次联系，直接发消息即可重新开始。")
        try:
            await context.bot.send_message(
                chat_id=OWNER_ID,
                text=f"📴 用户 {display_name(user)}（ID: {user.id}）结束了对话。",
            )
        except Exception:
            pass

async def cmd_endall(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """主人结束所有活跃会话"""
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。")
        return
    with get_db() as db:
        rows = db.execute(
            "SELECT user_id FROM sessions WHERE status='active'"
        ).fetchall()
        db.execute("UPDATE sessions SET status='closed', ended_at=datetime('now') WHERE status='active'")
    for row in rows:
        try:
            await context.bot.send_message(
                chat_id=row["user_id"],
                text="📴 对方已结束所有对话。",
            )
        except Exception:
            pass
    await update.message.reply_text(f"✅ 已结束 {len(rows)} 个活跃会话。")

async def cmd_sessions(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """主人查看所有活跃会话"""
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。")
        return
    with get_db() as db:
        rows = db.execute(
            "SELECT user_id, started_at FROM sessions WHERE status='active' ORDER BY started_at"
        ).fetchall()
    if not rows:
        await update.message.reply_text("💤 当前没有活跃用户。")
        return
    lines = [f"💬 <b>活跃会话 ({len(rows)} 个)：</b>"]
    for r in rows:
        lines.append(f"  • 用户ID <code>{r['user_id']}</code> — 开始于 {r['started_at']}")
    lines.append("\n回复某条转发消息，或用 /r 用户ID 切换回复对象")
    await update.message.reply_html("\n".join(lines))

async def cmd_r(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """主人切换当前回复目标: /r 用户ID"""
    if update.effective_user.id != OWNER_ID:
        await update.message.reply_text("❌ 仅主人可用。")
        return
    if not context.args or not context.args[0].isdigit():
        current = get_reply_target()
        if current:
            await update.message.reply_text(f"当前回复目标: 用户 {current}\n切换用法: /r 用户ID")
        else:
            await update.message.reply_text("❌ 用法: /r 用户ID")
        return
    uid = int(context.args[0])
    if not is_session_active(uid):
        await update.message.reply_text(f"⚠️ 用户 {uid} 没有活跃会话，已切换，发消息会重新开启会话。")
    set_reply_target(uid)
    await update.message.reply_text(f"✅ 已切换回复对象为用户 {uid}。\n现在直接发消息即可发给 ta。")

async def cmd_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    if user.id == OWNER_ID:
        await update.message.reply_html(
            "📖 <b>主人操作指南</b>\n\n"
            "<b>回复用户消息：</b>\n"
            "  • 直接<b>回复</b>某条转发消息（推荐）\n"
            "  • 或 /r 用户ID 切换目标，之后直接发消息\n\n"
            "<b>会话管理：</b>\n"
            "  /sessions — 查看所有活跃用户\n"
            "  /r — 查看/切换当前回复目标\n"
            "  /end 用户ID — 结束与某用户的对话\n"
            "  /endall — 结束全部对话\n\n"
            "<b>消息类型：</b>支持文字、图片、视频、文件、语音、贴纸等"
        )
    else:
        await update.message.reply_html(
            "📖 <b>使用帮助</b>\n\n"
            "直接发消息给我，我会帮你转达。\n"
            "对方回复后，我也会把回复转给你。\n\n"
            "/end — 结束本次对话\n"
            "/start — 重新开始"
        )

# ──────────────────────── 消息转发核心 ────────────────────────

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    msg = update.message
    if msg is None:
        return

    # ── 主人发消息 ──
    if user.id == OWNER_ID:
        target_uid = None

        # 1. 优先：主人回复了某条转发消息 → 从 msg_map 找目标用户
        if msg.reply_to_message:
            target_uid = lookup_user_by_owner_msg(msg.reply_to_message.message_id)
            if target_uid:
                set_reply_target(target_uid)  # 顺便更新当前目标

        # 2. 次选：使用 /r 设置的当前目标
        if target_uid is None:
            target_uid = get_reply_target()

        if target_uid is None:
            await msg.reply_text(
                "⚠️ 还没有选定回复对象。\n"
                "请<b>回复</b>某条转发消息，或用 /r 用户ID 指定。",
                parse_mode=constants.ParseMode.HTML,
            )
            return

        # 确保会话活跃（主人主动联系可重新开启）
        open_session(target_uid)

        sent_id = await relay_message(context.bot, target_uid, msg, prefix="📩 ")
        if sent_id is not None:
            await msg.reply_text("✓ 已发送", quote=True)
        else:
            await msg.reply_text("❌ 发送失败，对方可能已屏蔽机器人。")
        return

    # ── 普通用户发消息 ──
    # 自动开启会话
    open_session(user.id)

    name = display_name(user)
    prefix = f"📨 [{name}]（ID: <code>{user.id}</code>）：\n" if not ANONYMOUS_MODE \
        else f"📨 [{name}]：\n"

    # 转发给主人
    try:
        sent = await context.bot.send_message(
            chat_id=OWNER_ID,
            text=f"{prefix}",
            parse_mode=constants.ParseMode.HTML,
        )
        # 转发实际内容
        forwarded_id = await relay_message(context.bot, OWNER_ID, msg)
        # 以 header 消息ID 做映射（主人回复任意一条都能找到用户）
        save_msg_map(sent.message_id, user.id)
        if forwarded_id:
            save_msg_map(forwarded_id, user.id)
    except Exception as e:
        logger.error("转发给主人失败: %s", e)
        await msg.reply_text("❌ 消息发送失败，请稍后重试。")
        return

    await msg.reply_text("✓ 消息已发送，等待回复…", quote=True)

# ──────────────────────── 主入口 ────────────────────────

def main():
    init_db()
    app = Application.builder().token(BOT_TOKEN).build()

    app.add_handler(CommandHandler("start",    cmd_start))
    app.add_handler(CommandHandler("end",      cmd_end))
    app.add_handler(CommandHandler("endall",   cmd_endall))
    app.add_handler(CommandHandler("sessions", cmd_sessions))
    app.add_handler(CommandHandler("r",        cmd_r))
    app.add_handler(CommandHandler("help",     cmd_help))
    app.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, handle_message))

    logger.info("机器人启动，主人ID: %s", OWNER_ID)
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
BOTEOF

    success "程序文件写入完成"
}

# ─────────────────────────── 安装 ───────────────────────────

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
Description=Telegram Relay Chat Bot
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
    echo -e "  ${BOLD}主人 ID:${NC}   ${OWNER_ID}"
    echo ""
    echo -e "  ${BOLD}管理命令：${NC}"
    echo -e "    ${CYAN}tgbot start${NC}     — 启动"
    echo -e "    ${CYAN}tgbot stop${NC}      — 停止"
    echo -e "    ${CYAN}tgbot restart${NC}   — 重启"
    echo -e "    ${CYAN}tgbot status${NC}    — 查看状态"
    echo -e "    ${CYAN}tgbot log${NC}       — 实时日志"
    echo -e "    ${CYAN}tgbot uninstall${NC} — 卸载"
    echo ""
    echo -e "  ${BOLD}主人操作（在 Telegram 里）：${NC}"
    echo -e "    ${CYAN}直接回复转发消息${NC}    — 回复对应用户（推荐）"
    echo -e "    ${CYAN}/r 用户ID${NC}           — 切换当前回复对象"
    echo -e "    ${CYAN}/sessions${NC}           — 查看所有活跃用户"
    echo -e "    ${CYAN}/end 用户ID${NC}         — 结束与某用户的对话"
    echo -e "    ${CYAN}/endall${NC}             — 结束所有对话"
    echo ""
    echo -e "  ${BOLD}修改配置后重启:${NC}"
    echo -e "    ${CYAN}nano ${INSTALL_DIR}/config.py && tgbot restart${NC}"
    echo ""
    echo -e "  ${BOLD}去 Telegram 找你的机器人，发 /start 开始！${NC}"
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
