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

# ---------- 辅助函数 ----------
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

check_space() {
    local required=$1
    local available=$(df -k "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    [ "$available" -ge "$required" ] && return 0
    return 1
}

# ---------- 备份系统核心 ----------
backup_system() {
    local name="system_$(timestamp).tar.gz"
    local dest="$BACKUP_DIR/$name"
    printf "${YELLOW}正在备份系统核心文件...${NC}\n"
    printf "排除 /proc /sys /dev /run /tmp /mnt /media /lost+found /var/backups\n"
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
        --exclude=/var/backups \
        --exclude="$BACKUP_DIR" \
        / 2>/dev/null
    if [ -f "$dest" ]; then
        local sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        printf "${GREEN}系统备份完成: %s (%s)${NC}\n" "$dest" "$(human_size $sz)"
    else
        printf "${RED}系统备份失败${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 全量备份 (整盘文件) ----------
backup_full() {
    local name="full_$(timestamp).tar.gz"
    local dest="$BACKUP_DIR/$name"
    printf "${YELLOW}正在全量备份 (整个 / )...${NC}\n"
    printf "排除虚拟文件系统和备份自身\n"
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
        / 2>/dev/null
    if [ -f "$dest" ]; then
        local sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        printf "${GREEN}全量备份完成: %s (%s)${NC}\n" "$dest" "$(human_size $sz)"
    else
        printf "${RED}全量备份失败${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 备份非系统数据 (系统以外的所有) ----------
backup_data() {
    local name="data_$(timestamp).tar.gz"
    local dest="$BACKUP_DIR/$name"
    printf "${YELLOW}正在备份用户数据 (常用目录)...${NC}\n"
    local dirs=""
    for d in /home /opt /var /root /srv /usr/local; do
        [ -d "$d" ] && dirs="$dirs $d"
    done
    if [ -z "$dirs" ]; then
        printf "${RED}未找到可备份的数据目录${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi
    printf "包含: %s\n" "$dirs"
    sleep 1
    tar -czpf "$dest" $dirs 2>/dev/null
    if [ -f "$dest" ]; then
        local sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        printf "${GREEN}数据备份完成: %s (%s)${NC}\n" "$dest" "$(human_size $sz)"
    else
        printf "${RED}数据备份失败${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 自定义文件夹备份 ----------
backup_custom() {
    read -p "请输入要备份的文件夹绝对路径 (多个用空格分隔): " paths
    [ -z "$paths" ] && { printf "${RED}未输入路径${NC}\n"; read -p "按回车键继续..." dummy; return; }
    local name="custom_$(timestamp).tar.gz"
    local dest="$BACKUP_DIR/$name"
    printf "${YELLOW}正在备份自定义文件夹...${NC}\n"
    tar -czpf "$dest" $paths 2>/dev/null
    if [ -f "$dest" ]; then
        local sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        printf "${GREEN}备份完成: %s (%s)${NC}\n" "$dest" "$(human_size $sz)"
    else
        printf "${RED}备份失败，请检查路径。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 还原功能 ----------
restore_backup() {
    printf "${BLUE}当前备份文件列表:${NC}\n"
    ls -lh "$BACKUP_DIR"/*.tar.gz 2>/dev/null || { printf "${YELLOW}无备份文件${NC}\n"; read -p "按回车键继续..." dummy; return; }
    echo ""
    read -p "请输入要还原的备份文件名 (全名): " bfile
    if [ ! -f "$BACKUP_DIR/$bfile" ]; then
        printf "${RED}文件不存在${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    printf "${RED}警告: 还原操作将覆盖现有文件！${NC}\n"
    printf "1. 还原到 / (危险，完全覆盖)\n"
    printf "2. 还原到指定目录\n"
    printf "0. 取消\n"
    read -p "选择: " rchoice
    case $rchoice in
        1)
            printf "${RED}确认要还原到根目录吗？此操作不可逆！ [y/N]: ${NC}"
            read -p "" confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                cd /
                tar -xzpf "$BACKUP_DIR/$bfile" 2>/dev/null
                printf "${GREEN}还原完成。${NC}\n"
            else
                printf "已取消。\n"
            fi
            ;;
        2)
            read -p "输入目标目录 (例如 /restore): " target
            [ -z "$target" ] && { printf "${RED}目录不能为空${NC}\n"; read -p "按回车键继续..." dummy; return; }
            mkdir -p "$target"
            cd "$target" || exit
            tar -xzpf "$BACKUP_DIR/$bfile" 2>/dev/null
            printf "${GREEN}已还原到 %s${NC}\n" "$target"
            ;;
        0) return ;;
        *) printf "${RED}无效选择${NC}\n" ;;
    esac
    read -p "按回车键继续..." dummy
}

# ---------- 查看备份信息 ----------
list_backups() {
    printf "${BLUE}备份文件列表:${NC}\n"
    if ls -lh "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
        for f in "$BACKUP_DIR"/*.tar.gz; do
            local sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            printf "%-40s %s\n" "$(basename "$f")" "$(human_size $sz)"
        done
    else
        printf "${YELLOW}暂无备份文件。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 删除备份 ----------
delete_backup() {
    printf "${BLUE}选择要删除的备份:${NC}\n"
    select f in "$BACKUP_DIR"/*.tar.gz; do
        if [ -f "$f" ]; then
            rm -f "$f" && printf "${GREEN}已删除 %s${NC}\n" "$(basename "$f")"
        else
            printf "${RED}无效选择${NC}\n"
        fi
        break
    done
    read -p "按回车键继续..." dummy
}

# ---------- 主菜单 ----------
while true; do
    clear
    printf "${BLUE}===== 备份与还原 =====${NC}\n"
    printf "备份存储: ${GREEN}%s${NC} (可用: %s)\n" "$BACKUP_DIR" "$(df -h "$BACKUP_DIR" | awk 'NR==2{print $4}')"
    echo "--------------------------------------"
    echo "1. 备份系统核心 (排除虚拟文件)"
    echo "2. 整盘备份 (整个根目录)"
    echo "3. 备份非系统数据 (/home/opt/var等)"
    echo "4. 备份自定义文件夹"
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
