#!/bin/bash
# 日志查看与分析模块

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# ── 日志路径自动检测 ──────────────────────────────────────────
AUTH_LOG="/var/log/auth.log"
SYS_LOG="/var/log/syslog"
KERN_LOG="/var/log/kern.log"
FAIL2BAN_LOG="/var/log/fail2ban.log"

[ -f /var/log/secure   ] && AUTH_LOG="/var/log/secure"
[ -f /var/log/messages ] && SYS_LOG="/var/log/messages"

# ── 工具函数 ─────────────────────────────────────────────────

# 检查 root 权限
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        printf "${RED}此操作需要 root 权限${NC}\n"
        read -p "按回车键继续..." dummy
        return 1
    fi
    return 0
}

# 显示日志文件内容（最后 100 行）
view_log() {
    local file="$1" title="$2"
    if [ ! -f "$file" ]; then
        printf "${RED}日志文件不存在: %s${NC}\n" "$file"
        read -p "按回车键继续..." dummy
        return
    fi
    clear
    printf "${BLUE}===== %s =====${NC}\n" "$title"
    printf "文件: %s\n" "$file"
    echo "--------------------------------------"
    tail -n 100 "$file" 2>/dev/null
    echo ""
    read -p "按回车键继续..." dummy
}

# 实时跟踪日志
tail_follow() {
    local file="$1"
    if [ ! -f "$file" ]; then
        printf "${RED}日志文件不存在: %s${NC}\n" "$file"
        read -p "按回车键继续..." dummy
        return
    fi
    printf "${GREEN}实时跟踪 %s（按 Ctrl+C 退出）...${NC}\n" "$file"
    sleep 1
    tail -f "$file" || true
    echo ""
    read -p "已退出跟踪，按回车键继续..." dummy
}

# 按关键字搜索
search_log() {
    local file="$1"
    if [ ! -f "$file" ]; then
        printf "${RED}日志文件不存在: %s${NC}\n" "$file"
        read -p "按回车键继续..." dummy
        return
    fi
    read -p "输入搜索关键词: " keyword
    [ -z "$keyword" ] && return
    printf "${GREEN}在 %s 中搜索「%s」${NC}\n" "$file" "$keyword"
    echo "--------------------------------------"
    grep -i --color=auto "$keyword" "$file" | tail -n 50
    echo ""
    read -p "按回车键继续..." dummy
}

# 立即清理日志
clean_logs_now() {
    require_root || return
    local targets=("$AUTH_LOG" "$SYS_LOG" "$KERN_LOG")
    [ -f "$FAIL2BAN_LOG" ] && targets+=("$FAIL2BAN_LOG")

    printf "${RED}⚠ 以下日志文件内容将被清空:${NC}\n"
    for f in "${targets[@]}"; do
        printf "  %s\n" "$f"
    done
    echo ""
    read -p "确认清空以上所有日志？[y/N]: " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        local failed=0
        for f in "${targets[@]}"; do
            if [ -f "$f" ]; then
                if : > "$f" 2>/dev/null; then
                    printf "${GREEN}  已清空: %s${NC}\n" "$f"
                else
                    printf "${RED}  清空失败: %s${NC}\n" "$f"
                    failed=1
                fi
            fi
        done
        [ "$failed" -eq 0 ] && printf "\n${GREEN}所有日志已清空。${NC}\n" \
                             || printf "\n${RED}部分日志清空失败，请检查权限。${NC}\n"
    else
        printf "已取消。\n"
    fi
    read -p "按回车键继续..." dummy
}

# ── 定时清理日志 ──────────────────────────────────────────────

# 生成清理脚本内容
_gen_clean_script() {
    local targets=("$AUTH_LOG" "$SYS_LOG" "$KERN_LOG")
    [ -f "$FAIL2BAN_LOG" ] && targets+=("$FAIL2BAN_LOG")

    cat <<SCRIPT
#!/bin/bash
# 由 log_manager.sh 自动生成 —— 定时清理日志
for f in ${targets[*]}; do
    [ -f "\$f" ] && : > "\$f"
done
SCRIPT
}

CRON_SCRIPT="/usr/local/bin/vn_clean_logs.sh"
CRON_TAG="# vn_log_manager_clean"

# 设置定时清理
setup_cron_clean() {
    require_root || return

    echo ""
    echo "请选择清理频率:"
    echo "  1. 每天凌晨 3:00"
    echo "  2. 每周一凌晨 3:00"
    echo "  3. 每月 1 日凌晨 3:00"
    echo "  4. 自定义 cron 表达式"
    echo "  0. 取消"
    read -p "请选择: " freq

    local cron_time=""
    case $freq in
        1) cron_time="0 3 * * *"   ;;
        2) cron_time="0 3 * * 1"   ;;
        3) cron_time="0 3 1 * *"   ;;
        4)
            read -p "输入 cron 时间字段（例: 0 4 * * *）: " cron_time
            if [[ ! "$cron_time" =~ ^([0-9\*/,-]+[[:space:]]){4}[0-9\*/,-]+$ ]]; then
                printf "${RED}cron 表达式格式不正确，已取消。${NC}\n"
                read -p "按回车键继续..." dummy
                return
            fi
            ;;
        0) return ;;
        *) printf "${RED}无效选项${NC}\n"; read -p "按回车键继续..." dummy; return ;;
    esac

    # 写入清理脚本
    _gen_clean_script > "$CRON_SCRIPT" && chmod +x "$CRON_SCRIPT"

    # 先移除旧任务，再写入新任务
    ( crontab -l 2>/dev/null | grep -v "$CRON_TAG" ; \
      echo "$cron_time $CRON_SCRIPT $CRON_TAG" ) | crontab -

    printf "${GREEN}定时清理已设置: %s${NC}\n" "$cron_time"
    printf "清理脚本路径: %s\n" "$CRON_SCRIPT"
    read -p "按回车键继续..." dummy
}

# 查看当前定时任务
view_cron_clean() {
    echo ""
    local entry
    entry=$(crontab -l 2>/dev/null | grep "$CRON_TAG")
    if [ -n "$entry" ]; then
        printf "${GREEN}当前定时清理任务:${NC}\n"
        echo "  $entry"
    else
        printf "${RED}未设置定时清理任务。${NC}\n"
    fi
    echo ""
    read -p "按回车键继续..." dummy
}

# 取消定时任务
remove_cron_clean() {
    require_root || return
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
        [ -f "$CRON_SCRIPT" ] && rm -f "$CRON_SCRIPT"
        printf "${GREEN}定时清理任务已取消。${NC}\n"
    else
        printf "${RED}未找到定时清理任务。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# 定时清理子菜单
menu_cron_clean() {
    while true; do
        clear
        printf "${BLUE}===== 定时清理日志 =====${NC}\n"
        echo "1. 设置/修改定时清理"
        echo "2. 查看当前定时任务"
        echo "3. 取消定时清理"
        echo "0. 返回上级"
        read -p "请选择: " c
        case $c in
            1) setup_cron_clean ;;
            2) view_cron_clean ;;
            3) remove_cron_clean ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# ── 主菜单 ────────────────────────────────────────────────────
while true; do
    clear
    printf "${BLUE}===== 日志查看与分析 =====${NC}\n"
    echo "1. 认证日志 (auth.log / secure)"
    echo "2. 系统日志 (syslog / messages)"
    echo "3. 内核日志 (kern.log / dmesg)"
    [ -f "$FAIL2BAN_LOG" ] && echo "4. Fail2Ban 日志"
    echo ""
    echo "5. 实时跟踪日志"
    echo "6. 搜索日志关键词"
    echo "7. 立即清空所有日志"
    echo "8. 定时清理日志"
    echo "0. 返回主菜单"
    read -p "请选择: " choice

    case $choice in
        1) view_log "$AUTH_LOG" "认证日志" ;;
        2) view_log "$SYS_LOG"  "系统日志" ;;
        3)
            if [ -f "$KERN_LOG" ]; then
                view_log "$KERN_LOG" "内核日志"
            else
                clear
                printf "${BLUE}===== 内核环形缓冲区（最近 100 行）=====${NC}\n"
                dmesg | tail -n 100
                echo ""
                read -p "按回车键继续..." dummy
            fi
            ;;
        4)
            if [ -f "$FAIL2BAN_LOG" ]; then
                view_log "$FAIL2BAN_LOG" "Fail2Ban 日志"
            else
                printf "${RED}Fail2Ban 日志不存在${NC}\n"
                read -p "按回车键继续..." dummy
            fi
            ;;
        5)
            # 实时跟踪：让用户选择目标文件
            clear
            printf "${BLUE}===== 实时跟踪 =====${NC}\n"
            echo "1. 认证日志"
            echo "2. 系统日志"
            echo "3. 内核日志"
            [ -f "$FAIL2BAN_LOG" ] && echo "4. Fail2Ban 日志"
            echo "5. 自定义路径"
            read -p "请选择: " tf
            case $tf in
                1) tail_follow "$AUTH_LOG" ;;
                2) tail_follow "$SYS_LOG" ;;
                3) tail_follow "${KERN_LOG:-/dev/null}" ;;
                4) [ -f "$FAIL2BAN_LOG" ] && tail_follow "$FAIL2BAN_LOG" \
                       || { printf "${RED}Fail2Ban 日志不存在${NC}\n"; read -p "按回车键继续..." dummy; } ;;
                5)
                    read -p "输入日志文件完整路径: " custom_log
                    tail_follow "$custom_log"
                    ;;
                *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
            esac
            ;;
        6)
            clear
            printf "${BLUE}===== 搜索日志关键词 =====${NC}\n"
            echo "1. 认证日志"
            echo "2. 系统日志"
            echo "3. 内核日志"
            [ -f "$FAIL2BAN_LOG" ] && echo "4. Fail2Ban 日志"
            read -p "选择文件: " lc
            case $lc in
                1) search_log "$AUTH_LOG" ;;
                2) search_log "$SYS_LOG" ;;
                3) [ -f "$KERN_LOG" ] && search_log "$KERN_LOG" \
                       || { printf "${RED}内核日志文件缺失${NC}\n"; read -p "按回车键继续..." dummy; } ;;
                4) [ -f "$FAIL2BAN_LOG" ] && search_log "$FAIL2BAN_LOG" \
                       || { printf "${RED}Fail2Ban 日志缺失${NC}\n"; read -p "按回车键继续..." dummy; } ;;
                *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
            esac
            ;;
        7) clean_logs_now ;;
        8) menu_cron_clean ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done
