#!/bin/bash
# 备份/还原模块（支持系统备份、全量备份、数据备份、自定义文件夹）

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

BACKUP_DIR="/var/backups/vn_backups"
mkdir -p "$BACKUP_DIR"

# ── 辅助函数 ──────────────────────────────────────────────────

timestamp() {
    date +%Y%m%d_%H%M%S
}

human_size() {
    local size=$1
    if [ "$size" -ge 1073741824 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size/1073741824}") GB"
    elif [ "$size" -ge 1048576 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size/1048576}") MB"
    elif [ "$size" -ge 1024 ]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $size/1024}") KB"
    else
        echo "${size} B"
    fi
}

# 检查备份目录剩余空间（单位 KB），不足时给出警告并询问是否继续
check_space() {
    local required_kb=$1
    local available_kb
    available_kb=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    if [ "$available_kb" -lt "$required_kb" ]; then
        printf "${RED}⚠ 磁盘空间不足：需要约 %s，剩余 %s${NC}\n" \
            "$(human_size $((required_kb * 1024)))" \
            "$(human_size $((available_kb * 1024)))"
        read -p "仍要继续？[y/N]: " go
        [[ $go =~ ^[Yy]$ ]] || return 1
    fi
    return 0
}

# 统一的备份收尾：检查文件、显示大小
_finish_backup() {
    local dest="$1" label="$2"
    if [ -f "$dest" ]; then
        local sz
        sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        printf "${GREEN}%s完成: %s (%s)${NC}\n" "$label" "$dest" "$(human_size "$sz")"
    else
        printf "${RED}%s失败，请检查磁盘空间或权限。${NC}\n" "$label"
    fi
    read -p "按回车键继续..." dummy
}

# ── 备份系统核心（仅系统文件，不含用户数据）──────────────────
# 范围: /etc /boot /bin /sbin /lib /lib64 /usr（排除 /usr/local）
backup_system() {
    local dest="$BACKUP_DIR/system_$(timestamp).tar.gz"
    # 粗估：系统核心一般 1~3 GB，预留 4 GB（4194304 KB）
    check_space 4194304 || return

    printf "${YELLOW}正在备份系统核心文件（/etc /boot /bin /sbin /lib /usr 等）...${NC}\n"
    printf "不含用户数据 (/home /opt /root /srv /usr/local)\n\n"
    sleep 1

    local dirs=()
    for d in /etc /boot /bin /sbin /lib /lib32 /lib64 /libx32 /usr; do
        [ -e "$d" ] && dirs+=("$d")
    done

    tar -czpf "$dest" \
        --exclude=/usr/local \
        --warning=no-file-changed \
        "${dirs[@]}" 2>/tmp/vn_backup_err

    # 只在有非 warning 错误时才展示
    grep -v "^tar: Removing" /tmp/vn_backup_err | grep -v "^$" >&2 || true

    _finish_backup "$dest" "系统核心备份"
}

# ── 全量备份（整个根目录，排除虚拟文件系统）─────────────────
backup_full() {
    local dest="$BACKUP_DIR/full_$(timestamp).tar.gz"
    printf "${YELLOW}正在全量备份（整个 /，排除虚拟文件系统）...${NC}\n"
    printf "排除: /proc /sys /dev /run /tmp /mnt /media /lost+found 及备份目录自身\n\n"
    sleep 1

    tar -czpf "$dest" \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/tmp \
        --exclude=/mnt \
        --exclude=/media \
        --exclude=/lost+found \
        --exclude="$BACKUP_DIR" \
        --warning=no-file-changed \
        / 2>/tmp/vn_backup_err

    grep -v "^tar: Removing" /tmp/vn_backup_err | grep -v "^$" >&2 || true

    _finish_backup "$dest" "全量备份"
}

# ── 数据备份（用户/服务数据，排除系统文件）──────────────────
backup_data() {
    local dest="$BACKUP_DIR/data_$(timestamp).tar.gz"
    printf "${YELLOW}正在备份用户数据目录...${NC}\n"

    local dirs=()
    for d in /home /opt /root /srv /usr/local; do
        [ -d "$d" ] && dirs+=("$d")
    done
    # 从 /var 中排除备份目录自身
    [ -d /var ] && dirs+=(/var)

    if [ ${#dirs[@]} -eq 0 ]; then
        printf "${RED}未找到可备份的数据目录${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    printf "包含: %s\n\n" "${dirs[*]}"
    sleep 1

    tar -czpf "$dest" \
        --exclude="$BACKUP_DIR" \
        --warning=no-file-changed \
        "${dirs[@]}" 2>/tmp/vn_backup_err

    grep -v "^tar: Removing" /tmp/vn_backup_err | grep -v "^$" >&2 || true

    _finish_backup "$dest" "数据备份"
}

# ── 自定义文件夹备份 ─────────────────────────────────────────
backup_custom() {
    read -p "请输入要备份的绝对路径（多个用空格分隔）: " -a paths
    if [ ${#paths[@]} -eq 0 ]; then
        printf "${RED}未输入路径${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    # 逐一校验路径
    local valid=()
    for p in "${paths[@]}"; do
        if [ -e "$p" ]; then
            valid+=("$p")
        else
            printf "${RED}路径不存在，已跳过: %s${NC}\n" "$p"
        fi
    done

    if [ ${#valid[@]} -eq 0 ]; then
        printf "${RED}没有有效路径，已取消。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    local dest="$BACKUP_DIR/custom_$(timestamp).tar.gz"
    printf "${YELLOW}正在备份: %s${NC}\n\n" "${valid[*]}"
    sleep 1

    tar -czpf "$dest" \
        --warning=no-file-changed \
        "${valid[@]}" 2>/tmp/vn_backup_err

    grep -v "^tar: Removing" /tmp/vn_backup_err | grep -v "^$" >&2 || true

    _finish_backup "$dest" "自定义备份"
}

# ── 还原功能 ─────────────────────────────────────────────────
restore_backup() {
    printf "${BLUE}当前备份文件列表:${NC}\n"
    if ! ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
        printf "${YELLOW}无备份文件${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    # 用编号让用户选择，避免手动输全名出错
    local files=("$BACKUP_DIR"/*.tar.gz)
    local i=1
    for f in "${files[@]}"; do
        local sz
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        printf "  %d. %-40s %s\n" "$i" "$(basename "$f")" "$(human_size "$sz")"
        (( i++ ))
    done
    echo ""

    read -p "请输入备份编号（0 取消）: " idx
    [[ "$idx" =~ ^[0-9]+$ ]] || { printf "${RED}无效输入${NC}\n"; read -p "按回车键继续..." dummy; return; }
    [ "$idx" -eq 0 ] && return
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#files[@]}" ]; then
        printf "${RED}编号超出范围${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    local bfile="${files[$((idx-1))]}"
    printf "\n已选择: %s\n" "$(basename "$bfile")"

    printf "${RED}警告: 还原操作将覆盖现有文件！${NC}\n"
    echo "1. 还原到 / （危险，完全覆盖）"
    echo "2. 还原到指定目录"
    echo "0. 取消"
    read -p "选择: " rchoice

    case $rchoice in
        1)
            printf "${RED}确认要还原到根目录吗？此操作不可逆！[y/N]: ${NC}"
            read -p "" confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                tar -xzpf "$bfile" -C / 2>/dev/null \
                    && printf "${GREEN}还原完成。${NC}\n" \
                    || printf "${RED}还原过程中出现错误，请检查文件。${NC}\n"
            else
                printf "已取消。\n"
            fi
            ;;
        2)
            read -p "输入目标目录（例: /restore）: " target
            if [ -z "$target" ]; then
                printf "${RED}目录不能为空${NC}\n"
                read -p "按回车键继续..." dummy
                return   # ← 修复：原代码此处用 exit 会退出整个脚本
            fi
            mkdir -p "$target"
            tar -xzpf "$bfile" -C "$target" 2>/dev/null \
                && printf "${GREEN}已还原到 %s${NC}\n" "$target" \
                || printf "${RED}还原过程中出现错误。${NC}\n"
            ;;
        0) return ;;
        *) printf "${RED}无效选择${NC}\n" ;;
    esac
    read -p "按回车键继续..." dummy
}

# ── 查看备份列表 ──────────────────────────────────────────────
list_backups() {
    printf "${BLUE}备份文件列表:${NC}\n"
    echo "--------------------------------------"
    if ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
        for f in "$BACKUP_DIR"/*.tar.gz; do
            local sz
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            printf "%-40s %s\n" "$(basename "$f")" "$(human_size "$sz")"
        done
    else
        printf "${YELLOW}暂无备份文件。${NC}\n"
    fi
    echo ""
    read -p "按回车键继续..." dummy
}

# ── 删除备份 ──────────────────────────────────────────────────
delete_backup() {
    if ! ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
        printf "${YELLOW}暂无备份文件可删除。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    printf "${BLUE}选择要删除的备份:${NC}\n"
    local files=("$BACKUP_DIR"/*.tar.gz)
    local i=1
    for f in "${files[@]}"; do
        local sz
        sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
        printf "  %d. %-40s %s\n" "$i" "$(basename "$f")" "$(human_size "$sz")"
        (( i++ ))
    done
    echo "  0. 取消"
    echo ""

    read -p "请输入编号: " idx
    [[ "$idx" =~ ^[0-9]+$ ]] || { printf "${RED}无效输入${NC}\n"; read -p "按回车键继续..." dummy; return; }
    [ "$idx" -eq 0 ] && return
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#files[@]}" ]; then
        printf "${RED}编号超出范围${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    local target="${files[$((idx-1))]}"
    read -p "确认删除 $(basename "$target")？[y/N]: " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        rm -f "$target" && printf "${GREEN}已删除 %s${NC}\n" "$(basename "$target")" \
                        || printf "${RED}删除失败${NC}\n"
    else
        printf "已取消。\n"
    fi
    read -p "按回车键继续..." dummy
}

# ── 主菜单 ────────────────────────────────────────────────────
while true; do
    clear
    printf "${BLUE}===== 备份与还原 =====${NC}\n"
    printf "备份存储: ${GREEN}%s${NC}  可用: %s\n" \
        "$BACKUP_DIR" "$(df -h "$BACKUP_DIR" | awk 'NR==2{print $4}')"
    echo "--------------------------------------"
    echo "1. 备份系统核心  (/etc /boot /bin /sbin /lib /usr)"
    echo "2. 整盘备份      (完整根目录，排除虚拟文件系统)"
    echo "3. 备份用户数据  (/home /opt /var /root /srv /usr/local)"
    echo "4. 备份自定义路径"
    echo "--------------------------------------"
    echo "5. 查看备份列表"
    echo "6. 还原备份"
    echo "7. 删除备份"
    echo "0. 返回主菜单"
    read -p "选择: " choice
    case $choice in
        1) backup_system ;;
        2) backup_full ;;
        3) backup_data ;;
        4) backup_custom ;;
        5) list_backups ;;
        6) restore_backup ;;
        7) delete_backup ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done
