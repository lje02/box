#!/bin/bash
# SSH 安全加固模块（密钥管理 + 关闭密码登录）

# ---------- 0. 权限检查 ----------
if [ "$(id -u)" -ne 0 ]; then
    printf "\033[31m✘ 错误：请使用 root 权限执行此脚本 (可以先使用 sudo -i 切换)\033[0m\n"
    exit 1
fi

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

SSH_CONF="/etc/ssh/sshd_config"
SSH_PORT=$(get_ssh_port)

# ---------- 备份 sshd_config ----------
backup_ssh() {
    if [ ! -f "${SSH_CONF}.bak" ]; then
        cp "$SSH_CONF" "${SSH_CONF}.bak"
        printf "${GREEN}已备份配置文件 -> ${SSH_CONF}.bak${NC}\n"
    fi
}

# ---------- 生成密钥对 ----------
generate_key() {
    printf "${BLUE}===== 生成 SSH 密钥对 =====${NC}\n"
    printf "密钥类型: 1. RSA (4096)   2. Ed25519 (推荐)\n"
    read -p "请选择 [1-2，默认2]: " key_type
    key_type=${key_type:-2}

    read -p "密钥保存路径 (默认 ~/.ssh/vps_key): " key_path
    key_path=${key_path:-~/.ssh/vps_key}

    read -p "密钥备注 (默认 vps@$(hostname)): " key_comment
    key_comment=${key_comment:-vps@$(hostname)}

    if [ -f "${key_path}" ]; then
        read -p "文件已存在，是否覆盖？[y/N]: " overwrite
        if [[ ! $overwrite =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    mkdir -p "$(dirname "$key_path")"

    case $key_type in
        1) ssh-keygen -t rsa -b 4096 -f "$key_path" -C "$key_comment" -N "" ;;
        2) ssh-keygen -t ed25519 -f "$key_path" -C "$key_comment" -N "" ;;
        *) ssh-keygen -t ed25519 -f "$key_path" -C "$key_comment" -N "" ;;
    esac

    printf "${GREEN}密钥对已生成:${NC}\n"
    printf "  私钥: %s\n" "$key_path"
    printf "  公钥: %s.pub\n" "$key_path"
    echo ""

    # ===== 打印私钥 =====
    printf "${YELLOW}========== 私钥内容 (请妥善保管，不要泄露) ==========${NC}\n"
    printf "${RED}"
    cat "$key_path"
    printf "${NC}"
    printf "${YELLOW}========== 私钥结束 ==========${NC}\n"
    echo ""

    # ===== 打印公钥 =====
    printf "${GREEN}========== 公钥内容 (用于添加到服务器 authorized_keys) ==========${NC}\n"
    cat "${key_path}.pub"
    printf "${GREEN}========== 公钥结束 ==========${NC}\n"
    echo ""

    printf "${YELLOW}提示：请将私钥下载到本地并妥善保存，然后删除服务器上的私钥文件。${NC}\n"
    read -p "按回车键继续..." dummy
}

# ---------- 添加公钥到当前用户 ----------
add_pubkey_local() {
    printf "${BLUE}===== 添加公钥到本机 =====${NC}\n"
    echo "可添加的公钥来源:"
    echo "1. 粘贴公钥内容"
    echo "2. 从本地文件读取"
    echo "3. 从 ~/.ssh/id_rsa.pub 读取"
    echo "0. 返回"
    read -p "选择: " src_choice

    local pubkey=""
    case $src_choice in
        1)
            printf "请粘贴公钥内容 (以 ssh-rsa/ssh-ed25519/ecdsa-sha2 开头)，粘贴后按 Ctrl+D 结束:\n"
            pubkey=$(cat)
            ;;
        2)
            read -p "输入公钥文件路径: " pubkey_path
            if [ -f "$pubkey_path" ]; then
                pubkey=$(cat "$pubkey_path")
            else
                printf "${RED}文件不存在${NC}\n"
                read -p "按回车键继续..." dummy
                return
            fi
            ;;
        3)
            if [ -f ~/.ssh/id_rsa.pub ]; then
                pubkey=$(cat ~/.ssh/id_rsa.pub)
            elif [ -f ~/.ssh/id_ed25519.pub ]; then
                pubkey=$(cat ~/.ssh/id_ed25519.pub)
            else
                printf "${RED}未找到 ~/.ssh/id_*.pub${NC}\n"
                read -p "按回车键继续..." dummy
                return
            fi
            ;;
        0) return ;;
        *) printf "${RED}无效选项${NC}\n"; read -p "按回车键继续..." dummy; return ;;
    esac

    # 验证公钥格式
    if ! echo "$pubkey" | grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2)'; then
        printf "${RED}无效的公钥格式${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    # 添加到 authorized_keys
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    if ! grep -qF "$pubkey" ~/.ssh/authorized_keys 2>/dev/null; then
        echo "$pubkey" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        printf "${GREEN}公钥已添加。${NC}\n"
    else
        printf "${YELLOW}公钥已存在，跳过。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 关闭密码登录 ----------
disable_password_auth() {
    printf "${RED}⚠ 警告：关闭密码登录后，只能通过密钥登录！${NC}\n"
    printf "${RED}   请确保你已经添加了公钥并测试成功，否则会锁死服务器！${NC}\n"
    echo ""

    # 1. 检查是否有授权密钥 (兼容 RSA, Ed25519, ECDSA)
    if [ ! -f ~/.ssh/authorized_keys ] || [ ! -s ~/.ssh/authorized_keys ]; then
        printf "${RED}✘ 错误：未找到任何授权的公钥！${NC}\n"
        printf "   请先使用菜单选项 2 添加公钥，或手动创建 ~/.ssh/authorized_keys\n"
        read -p "按回车键继续..." dummy
        return
    fi
    local key_count=$(grep -E -c '^(ssh-|ecdsa-sha2-)' ~/.ssh/authorized_keys 2>/dev/null || echo 0)
    if [ "$key_count" -eq 0 ]; then
        printf "${RED}✘ 错误：authorized_keys 中没有有效的公钥！${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi
    printf "${GREEN}检测到 %d 个有效公钥。${NC}\n" "$key_count"

    read -p "是否继续？[y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        return
    fi

    backup_ssh

    # 2. 确保 PubkeyAuthentication 是开启的（关键）
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONF"
    grep -q '^PubkeyAuthentication yes' "$SSH_CONF" || echo "PubkeyAuthentication yes" >> "$SSH_CONF"

    # 3. 关闭密码登录和交互式键盘登录（带保底机制）
    for param in PasswordAuthentication ChallengeResponseAuthentication KbdInteractiveAuthentication; do
        sed -i "s/^#*${param}.*/${param} no/" "$SSH_CONF"
        grep -q "^${param} no" "$SSH_CONF" || echo "${param} no" >> "$SSH_CONF"
    done

    # 4. 处理新版系统及云厂商的附加配置目录覆盖问题
    if [ -d /etc/ssh/sshd_config.d ]; then
        find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' {} \;
        find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' {} \;
        find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' {} \;
    fi

    # 5. 语法检查
    printf "${YELLOW}正在检查配置文件语法...${NC}\n"
    if ! sshd -t 2>/dev/null; then
        printf "${RED}✘ SSH 配置文件语法错误！已中止操作，并恢复备份。${NC}\n"
        cp "${SSH_CONF}.bak" "$SSH_CONF"
        read -p "按回车键继续..." dummy
        return
    fi
    printf "${GREEN}配置语法正确。${NC}\n"

    # 6. 询问重启
    printf "${YELLOW}即将重启 SSH 服务...${NC}\n"
    read -p "继续？[y/N]: " confirm2
    if [[ ! $confirm2 =~ ^[Yy]$ ]]; then
        printf "${YELLOW}已取消重启，配置已写入但未生效。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    # 7. 尝试重启，同时兼容 ssh / sshd 两种服务名
    local restarted=false
    if systemctl restart ssh 2>/dev/null; then
        restarted=true
    elif systemctl restart sshd 2>/dev/null; then
        restarted=true
    elif service ssh restart 2>/dev/null; then
        restarted=true
    elif service sshd restart 2>/dev/null; then
        restarted=true
    elif /etc/init.d/ssh restart 2>/dev/null; then
        restarted=true
    fi

    if $restarted; then
        printf "${GREEN}✔ SSH 服务已重启，密码登录已关闭。${NC}\n"
        printf "${GREEN}   请保持当前会话不要断开，新开窗口测试密钥登录！${NC}\n"
    else
        printf "${RED}✘ SSH 服务重启失败！配置已写入但未生效，请手动检查。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 开启密码登录（恢复） ----------
enable_password_auth() {
    printf "${YELLOW}将重新开启密码登录...${NC}\n"
    read -p "确定？[y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        return
    fi

    backup_ssh

    # 恢复主配置
    for param in PasswordAuthentication ChallengeResponseAuthentication KbdInteractiveAuthentication UsePAM; do
        sed -i "s/^#*${param}.*/${param} yes/" "$SSH_CONF"
        grep -q "^${param} yes" "$SSH_CONF" || echo "${param} yes" >> "$SSH_CONF"
    done

    # 恢复目录配置
    if [ -d /etc/ssh/sshd_config.d ]; then
        find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' {} \;
        find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication yes/' {} \;
        find /etc/ssh/sshd_config.d/ -type f -name "*.conf" -exec sed -i 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' {} \;
    fi

    systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null || /etc/init.d/ssh restart 2>/dev/null
    printf "${GREEN}密码登录已重新开启。${NC}\n"
    read -p "按回车键继续..." dummy
}

# ---------- 查看授权密钥 ----------
list_keys() {
    printf "${BLUE}===== 已授权的公钥 =====${NC}\n"
    if [ -f ~/.ssh/authorized_keys ] && [ -s ~/.ssh/authorized_keys ]; then
        cat -n ~/.ssh/authorized_keys
    else
        printf "${YELLOW}没有已授权的公钥。${NC}\n"
    fi
    echo ""
    read -p "按回车键继续..." dummy
}

# ---------- 查看当前 SSH 配置摘要 ----------
show_config() {
    printf "${BLUE}===== SSH 配置摘要 =====${NC}\n"
    printf "SSH 端口: %s\n" "$SSH_PORT"
    printf "密码登录: %s\n" "$(grep -E '^PasswordAuthentication' "$SSH_CONF" 2>/dev/null | tail -1 || echo '未设置 (默认 yes)')"
    printf "密钥认证: %s\n" "$(grep -E '^PubkeyAuthentication' "$SSH_CONF" 2>/dev/null | tail -1 || echo '未设置 (默认 yes)')"
    printf "Root 登录: %s\n" "$(grep -E '^PermitRootLogin' "$SSH_CONF" 2>/dev/null | tail -1 || echo '未设置 (默认 yes)')"
    printf "已授权密钥数: %s\n" "$(grep -E -c '^(ssh-|ecdsa-sha2-)' ~/.ssh/authorized_keys 2>/dev/null || echo 0)"
    echo ""
    read -p "按回车键继续..." dummy
}

# ---------- 删除指定公钥 ----------
delete_key() {
    if [ ! -f ~/.ssh/authorized_keys ] || [ ! -s ~/.ssh/authorized_keys ]; then
        printf "${YELLOW}没有已授权的公钥。${NC}\n"
        read -p "按回车键继续..." dummy
        return
    fi

    printf "${BLUE}===== 删除公钥 =====${NC}\n"
    cat -n ~/.ssh/authorized_keys
    echo ""
    read -p "输入要删除的行号 (0 取消): " line_num
    if [[ "$line_num" =~ ^[0-9]+$ ]] && [ "$line_num" -gt 0 ]; then
        sed -i "${line_num}d" ~/.ssh/authorized_keys
        printf "${GREEN}已删除第 %s 行的公钥。${NC}\n" "$line_num"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 主菜单 ----------
while true; do
    clear
    printf "${BLUE}===== SSH 安全加固 =====${NC}\n"
    printf "当前端口: ${GREEN}%s${NC}\n" "$SSH_PORT"
    echo "--------------------------------------"
    echo "1. 生成新的密钥对"
    echo "2. 添加公钥到本机授权"
    echo "3. 查看已授权公钥"
    echo "4. 删除指定公钥"
    echo "--------------------------------------"
    echo "5. 关闭密码登录 (仅允许密钥)"
    echo "6. 开启密码登录 (恢复)"
    echo "--------------------------------------"
    echo "7. 查看 SSH 配置摘要"
    echo "0. 返回主菜单"
    read -p "请选择: " choice

    case $choice in
        1) generate_key ;;
        2) add_pubkey_local ;;
        3) list_keys ;;
        4) delete_key ;;
        5) disable_password_auth ;;
        6) enable_password_auth ;;
        7) show_config ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done
