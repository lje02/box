#!/bin/bash
# 入侵防御 (Fail2Ban + ipset + GeoIP )

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vp_modules/common.sh 2>/dev/null || true
fi

detect_os
check_dependencies

# ---------- 确保 Fail2Ban 可用 ----------
ensure_fail2ban() {
    if ! command -v fail2ban-client &>/dev/null; then
        printf "${YELLOW}Fail2Ban 未安装，正在自动安装...${NC}\n"
        if [ "$OS_FAMILY" = "debian" ]; then
            apt-get update -qq && apt-get install -y fail2ban iptables || {
                printf "${RED}Fail2Ban 安装失败${NC}\n"; return 1
            }
        else
            yum install -y epel-release && yum install -y fail2ban iptables || {
                printf "${RED}Fail2Ban 安装失败${NC}\n"; return 1
            }
        fi
        # 基本配置
        [ ! -f /etc/fail2ban/jail.local ] && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        if ! [ -f /var/log/auth.log ] && command -v journalctl &>/dev/null; then
            sed -i '/^\[sshd\]/,/^\[/ s/backend.*/backend = systemd/' /etc/fail2ban/jail.local
        fi
        systemctl enable fail2ban --now 2>/dev/null || service fail2ban start 2>/dev/null
    fi
    if ! pgrep -x fail2ban-server &>/dev/null; then
        printf "${RED}Fail2Ban 未运行，请先排查。${NC}\n"
        return 1
    fi
    return 0
}

# ---------- 启用防端口扫描 (recidive + 自定义 portscan) ----------
enable_portscan_protection() {
    ensure_fail2ban || return

    local jail_local="/etc/fail2ban/jail.local"
    # 备份
    cp "$jail_local" "${jail_local}.bak"

    # 开启 recidive (将多次被 ban 的 IP 长期封禁)
    if grep -q '^\[recidive\]' "$jail_local"; then
        sed -i '/^\[recidive\]/,/^\[/ s/^enabled.*/enabled = true/' "$jail_local"
    else
        cat >> "$jail_local" <<'EOF'

[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
banaction = iptables-allports
bantime  = 1w
findtime = 1d
maxretry = 3
EOF
    fi

    # 自定义 portscan jail (利用 iptables 日志检测新建连接风暴)
    cat >> "$jail_local" <<'EOF'

[portscan]
enabled  = true
filter   = portscan
logpath  = /var/log/kern.log
maxretry = 10
findtime = 60
bantime  = 86400
port     = 0:65535
banaction = iptables-allports
EOF

    # 创建 portscan 过滤器
    cat > /etc/fail2ban/filter.d/portscan.conf <<'EOF'
[Definition]
failregex = ^\s*\S+\s+\S+\s+\[<HOST>\]\s+TCP\s+.*\s+SYN
ignoreregex =
EOF

    # 添加 iptables 日志规则，记录新连接中 SYN 包（避免重复）
    iptables -C INPUT -p tcp -m state --state NEW -j LOG --log-prefix "Portscan detected: " --log-ip-options 2>/dev/null || \
    iptables -I INPUT -p tcp -m state --state NEW -j LOG --log-prefix "Portscan detected: "

    systemctl restart fail2ban 2>/dev/null || service fail2ban restart
    printf "${GREEN}防端口扫描已启用 (recidive + portscan)。${NC}\n"
    read -p "按回车键继续..." dummy
}

# ---------- IP 黑名单管理 (ipset + iptables) ----------
manage_ip_blacklist() {
    ensure_fail2ban || return  # 其实主要用 ipset，但可以同归于安全模块

    while true; do
        clear
        printf "${BLUE}===== IP 黑名单 (ipset) =====${NC}\n"
        echo "1. 查看当前黑名单"
        echo "2. 添加 IP 到黑名单"
        echo "3. 删除 IP"
        echo "4. 清空黑名单"
        echo "0. 返回"
        read -p "选择: " ip_choice
        case $ip_choice in
            1)
                ipset list blacklist 2>/dev/null || echo "黑名单尚未创建"
                read -p "按回车键继续..." dummy
                ;;
            2)
                read -p "输入要封禁的IP: " ban_ip
                [ -z "$ban_ip" ] && continue
                # 创建 ipset 集合（如果不存在），并添加 iptables 规则
                ipset create blacklist hash:ip timeout 0 -exist
                ipset add blacklist "$ban_ip" -exist
                iptables -C INPUT -m set --match-set blacklist src -j DROP 2>/dev/null || \
                iptables -I INPUT -m set --match-set blacklist src -j DROP
                printf "${GREEN}已添加 %s 到黑名单。${NC}\n" "$ban_ip"
                read -p "按回车键继续..." dummy
                ;;
            3)
                read -p "输入要移除的IP: " unban_ip
                ipset del blacklist "$unban_ip" 2>/dev/null
                printf "${GREEN}已移除。${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            4)
                ipset flush blacklist 2>/dev/null
                printf "${GREEN}黑名单已清空。${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# ---------- GeoIP 地域封锁建议 ----------
show_geoip_guide() {
    clear
    printf "${BLUE}===== GeoIP 地域封锁配置指南 =====${NC}\n"
    echo "本功能需要 xt_geoip 内核模块和 GeoIP 数据库。"
    echo ""
    echo "自动安装命令 (Debian/Ubuntu):"
    echo "  apt install xtables-addons-common libtext-csv-xs-perl"
    echo "  /usr/lib/xtables-addons/xt_geoip_dl"
    echo "  mkdir -p /usr/share/xt_geoip"
    echo "  /usr/lib/xtables-addons/xt_geoip_build -D /usr/share/xt_geoip *.csv"
    echo ""
    echo "然后手动添加 iptables 规则，例如禁止中国 IP:"
    echo "  iptables -I INPUT -m geoip --src-cc CN -j DROP"
    echo ""
    printf "${YELLOW}出于安全，本模块不自动执行以上操作，请按需配置。${NC}\n"
    read -p "按回车键继续..." dummy
}

# ---------- 主菜单 ----------
while true; do
    clear
    printf "${BLUE}===== 高级入侵防御 =====${NC}\n"
    printf "Fail2Ban: "; detect_fail2ban
    echo "1. 启用防端口扫描 (recidive+portscan)"
    echo "2. IP 黑名单管理 (ipset)"
    echo "3. GeoIP 地域封锁 (参考说明)"
    echo "0. 返回主菜单"
    read -p "选择: " choice
    case $choice in
        1) enable_portscan_protection ;;
        2) manage_ip_blacklist ;;
        3) show_geoip_guide ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done