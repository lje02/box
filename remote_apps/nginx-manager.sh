#!/bin/bash
# ============================================================
#  nginx-gateway.sh — Nginx 全功能网关管理脚本
#  融合：站点管理 / 证书申请 / 反向代理 / 镜像聚合 / 正向代理
#  系统：Ubuntu / Debian / CentOS / RHEL / Arch
# ============================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────
# 全局配置（可通过环境变量覆盖）
# ──────────────────────────────────────────────────────────
NGINX_CONF_DIR="${NGINX_CONF_DIR:-/etc/nginx}"
SITES_AVAILABLE="${NGINX_CONF_DIR}/sites-available"
SITES_DIR="${SITES_DIR:-${NGINX_CONF_DIR}/sites-enabled}"   # sites-enabled
CERT_DIR="${CERT_DIR:-${NGINX_CONF_DIR}/certs}"             # 自定义证书根目录
SELF_CERT_DIR="${SELF_CERT_DIR:-${NGINX_CONF_DIR}/ssl}"     # 自签名证书目录
WEBROOT_BASE="${WEBROOT_BASE:-/var/www}"
LE_CERT_BASE="/etc/letsencrypt/live"                        # Let's Encrypt 证书根
LOG_FILE="/var/log/nginx-gateway.log"

# ──────────────────────────────────────────────────────────
# 颜色 & 日志工具
# ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# 所有状态信息输出到 stderr，避免混入文件重定向
_log() { echo -e "$*" >&2 | tee -a "$LOG_FILE" >/dev/null 2>&1 || echo -e "$*" >&2; }
info()    { _log "${CYAN}[信息]${NC}  $*"; }
success() { _log "${GREEN}[成功]${NC}  $*"; }
warn()    { _log "${YELLOW}[警告]${NC}  $*"; }
error()   { _log "${RED}[错误]${NC}  $*"; }
die()     { error "$*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "请以 root 身份运行本脚本（sudo $0）"
}

confirm() {
    read -rp "${YELLOW}$1 [y/N]${NC} " _ans
    [[ ${_ans,,} == "y" ]]
}

init_dirs() {
    mkdir -p "$SITES_AVAILABLE" "$SITES_DIR" "$CERT_DIR" "$SELF_CERT_DIR"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nginx-gateway.log"
    # 确保 nginx.conf include sites-enabled
    if [[ -f "${NGINX_CONF_DIR}/nginx.conf" ]] && \
       ! grep -q "sites-enabled" "${NGINX_CONF_DIR}/nginx.conf" 2>/dev/null; then
        warn "nginx.conf 未包含 sites-enabled，请手动添加: include /etc/nginx/sites-enabled/*;"
    fi
}

normalize_url() {
    local url="$1"
    [[ ! "$url" =~ ^https?:// ]] && url="http://$url"
    echo "$url"
}

# ──────────────────────────────────────────────────────────
# Nginx 安装与检测
# ──────────────────────────────────────────────────────────
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf &>/dev/null;   then echo "dnf"
    elif command -v yum &>/dev/null;   then echo "yum"
    elif command -v pacman &>/dev/null; then echo "pacman"
    else die "不支持的包管理器，请手动安装依赖"; fi
}

install_pkg() {
    local pkg="$1"
    local mgr; mgr=$(detect_pkg_manager)
    info "安装 ${pkg}..."
    case $mgr in
        apt)    apt-get install -y "$pkg" ;;
        dnf)    dnf install -y "$pkg" ;;
        yum)    yum install -y "$pkg" ;;
        pacman) pacman -Sy --noconfirm "$pkg" ;;
    esac
}

check_and_install_nginx() {
    info "检查 Nginx 安装状态..."
    if command -v nginx &>/dev/null; then
        success "Nginx 已安装: $(nginx -v 2>&1)"
        return 0
    fi
    warn "未检测到 Nginx，正在尝试自动安装..."
    local mgr; mgr=$(detect_pkg_manager)
    case $mgr in
        apt)    apt-get update -qq && apt-get install -y nginx ;;
        dnf|yum) $mgr install -y nginx ;;
        pacman) pacman -Sy --noconfirm nginx ;;
    esac
    systemctl enable nginx
    success "Nginx 安装成功: $(nginx -v 2>&1)"
}

nginx_reload() {
    info "检查 Nginx 配置语法..."
    nginx -t 2>&1 >&2 || die "Nginx 配置检查失败，请修正后重试"
    systemctl reload nginx
    success "Nginx 已重载"
}

nginx_restart() { require_root; systemctl restart nginx && success "Nginx 已重启"; }
nginx_status()  { systemctl status nginx; }

# 检测 sub_filter 模块（镜像模式依赖）
check_sub_filter_module() {
    if ! nginx -V 2>&1 | grep -q "http_sub_module"; then
        warn "当前 Nginx 未编译 http_sub_module，镜像/多源聚合模式的内容替换功能不可用。"
        warn "Debian/Ubuntu 可执行: apt install nginx-full"
        echo ""
        read -rp "是否仍继续生成配置？[y/N]: " _c
        [[ "${_c,,}" == "y" ]] || exit 0
    fi
}

# ──────────────────────────────────────────────────────────
# 智能证书扫描
# ──────────────────────────────────────────────────────────
CERT_PATH=""
KEY_PATH=""

find_certs_advanced() {
    local domain="$1"
    CERT_PATH=""; KEY_PATH=""

    local search_dirs=(
        "${CERT_DIR}/${domain}"
        "${LE_CERT_BASE}/${domain}"
        "/root/.acme.sh/${domain}_ecc"
        "/root/.acme.sh/${domain}"
        "${SELF_CERT_DIR}/${domain}"
        "/etc/ssl/${domain}"
        "/etc/nginx/certs/${domain}"
    )

    local c_names=("fullchain.pem" "fullchain.cer" "server.crt" "${domain}.cer" "cert.pem")
    local k_names=("privkey.pem" "server.key" "${domain}.key" "cert.key" "key.pem")

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        for f in "${c_names[@]}"; do
            [[ -f "${dir}/${f}" ]] && CERT_PATH="${dir}/${f}" && break
        done
        for f in "${k_names[@]}"; do
            [[ -f "${dir}/${f}" ]] && KEY_PATH="${dir}/${f}" && break
        done
        # 兜底：内容特征扫描
        if [[ -z "$CERT_PATH" ]]; then
            CERT_PATH=$(grep -rl -m 1 "BEGIN CERTIFICATE" "$dir" 2>/dev/null \
                        | grep -E '\.(pem|crt|cer)$' | head -n 1 || true)
        fi
        if [[ -z "$KEY_PATH" ]]; then
            KEY_PATH=$(grep -rl -m 1 "PRIVATE KEY" "$dir" 2>/dev/null \
                       | grep -E '\.(pem|key)$' | head -n 1 || true)
        fi
        [[ -n "$CERT_PATH" && -n "$KEY_PATH" ]] && return 0
    done
    return 1
}

# ──────────────────────────────────────────────────────────
# 通用 SSL 安全配置块（供 heredoc 嵌入）
# ──────────────────────────────────────────────────────────
ssl_block() {
    local cert="$1" key="$2"
    cat <<EOF
    ssl_certificate     $cert;
    ssl_certificate_key $key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:CHACHA20;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
EOF
}

# ──────────────────────────────────────────────────────────
# 证书 SSL 参数交互（复用）
# ──────────────────────────────────────────────────────────
# 出参（全局变量）：_SSL_MODE  _SSL_PORT  _SSL_CERT  _SSL_KEY  _SSL_301  _SSL_HTTP_PORT
ask_ssl_params() {
    echo ""
    echo -e "${CYAN}── SSL / 证书配置 ──${NC}"
    echo "  1) 自动扫描证书（根据域名查找常见路径）"
    echo "  2) 手动指定证书路径"
    echo "  3) 申请 Let's Encrypt 证书（需域名已解析）"
    echo "  4) 生成自签名证书（本地 / 内网）"
    echo "  5) 纯 HTTP，不使用 SSL"
    echo ""
    read -rp "请选择 [1-5，默认 1]: " _ssl_choice
    [[ -z "$_ssl_choice" ]] && _ssl_choice="1"

    _SSL_CERT=""; _SSL_KEY=""; _SSL_MODE=""; _SSL_PORT=""; _SSL_301="no"; _SSL_HTTP_PORT="80"

    _ask_301_and_ports() {
        # HTTPS 目标端口
        read -rp "HTTPS 监听端口 [默认 443]: " _SSL_PORT
        [[ -z "$_SSL_PORT" ]] && _SSL_PORT="443"
        # 是否开启强转
        read -rp "开启 HTTP→HTTPS 301 强转？[Y/n]: " _r
        if [[ "${_r,,}" != "n" ]]; then
            _SSL_301="yes"
            # HTTP 来源端口（非 443/SSL 的明文端口）
            read -rp "HTTP 来源端口（强转监听端口）[默认 80]: " _SSL_HTTP_PORT
            [[ -z "$_SSL_HTTP_PORT" ]] && _SSL_HTTP_PORT="80"
            # 非 80 端口时给出提示
            if [[ "$_SSL_HTTP_PORT" != "80" ]]; then
                warn "非标准 HTTP 端口 ${_SSL_HTTP_PORT}：客户端须先访问 http://域名:${_SSL_HTTP_PORT}/ 才会触发 301 跳转"
                warn "浏览器直接访问 https://域名:${_SSL_PORT}/ 不受影响"
            fi
        fi
    }

    case "$_ssl_choice" in
        1) _SSL_MODE="auto";        _ask_301_and_ports ;;
        2)
            _SSL_MODE="manual"
            read -rp "证书文件路径 (fullchain.pem): " _SSL_CERT
            [[ -z "$_SSL_CERT" || ! -f "$_SSL_CERT" ]] && die "证书文件不存在: $_SSL_CERT"
            read -rp "私钥文件路径 (privkey.pem): " _SSL_KEY
            [[ -z "$_SSL_KEY"  || ! -f "$_SSL_KEY"  ]] && die "私钥文件不存在: $_SSL_KEY"
            _ask_301_and_ports
            ;;
        3) _SSL_MODE="letsencrypt"; _ask_301_and_ports ;;
        4) _SSL_MODE="self";        _ask_301_and_ports ;;
        5)
            _SSL_MODE="none"
            read -rp "HTTP 监听端口 [默认 80]: " _SSL_PORT
            [[ -z "$_SSL_PORT" ]] && _SSL_PORT="80"
            ;;
        *) die "无效选项" ;;
    esac
}

# 根据 _SSL_MODE 解析出真实证书路径，填入 _SSL_CERT / _SSL_KEY
# 同时处理申请逻辑（letsencrypt / self）
resolve_ssl_cert() {
    local domain="$1"

    case "$_SSL_MODE" in
        auto)
            if find_certs_advanced "$domain"; then
                _SSL_CERT="$CERT_PATH"; _SSL_KEY="$KEY_PATH"
                success "自动发现证书: $_SSL_CERT"
            else
                die "未找到任何证书，请改用手动、Let's Encrypt 或自签名模式。"
            fi
            ;;
        letsencrypt)
            cert_issue_auto "$domain"
            _SSL_CERT="${LE_CERT_BASE}/${domain}/fullchain.pem"
            _SSL_KEY="${LE_CERT_BASE}/${domain}/privkey.pem"
            ;;
        self)
            cert_self_signed_auto "$domain"
            _SSL_CERT="${SELF_CERT_DIR}/${domain}/fullchain.pem"
            _SSL_KEY="${SELF_CERT_DIR}/${domain}/privkey.pem"
            ;;
        manual)
            : # 已由 ask_ssl_params 填好
            ;;
        none)
            _SSL_CERT=""; _SSL_KEY=""
            ;;
    esac
}

# ──────────────────────────────────────────────────────────
# 证书管理
# ──────────────────────────────────────────────────────────
ensure_certbot() {
    command -v certbot &>/dev/null && return
    warn "未检测到 certbot，尝试安装..."
    local mgr; mgr=$(detect_pkg_manager)
    case $mgr in
        apt)        apt-get install -y certbot python3-certbot-nginx ;;
        dnf|yum)    $mgr install -y epel-release; $mgr install -y certbot python3-certbot-nginx ;;
        pacman)     pacman -Sy --noconfirm certbot certbot-nginx ;;
    esac
    command -v certbot &>/dev/null || die "certbot 安装失败，请手动安装"
    success "certbot 安装完成"
}

ensure_openssl() { command -v openssl &>/dev/null || install_pkg openssl; }

# 内部调用：申请 LE 证书（交互收集 email）
cert_issue_auto() {
    local domain="$1"
    ensure_certbot
    local email
    read -rp "请输入邮箱（用于证书到期通知）: " email
    [[ -z "$email" ]] && die "邮箱不能为空"
    info "申请 Let's Encrypt 证书: ${domain}..."
    certbot certonly --nginx -d "$domain" \
        --agree-tos --email "$email" --no-eff-email --non-interactive \
        || certbot certonly --standalone -d "$domain" \
           --agree-tos --email "$email" --no-eff-email --non-interactive
    success "证书申请成功: ${LE_CERT_BASE}/${domain}/"
}

# 内部调用：生成自签名证书
cert_self_signed_auto() {
    local domain="$1" days="${2:-3650}"
    ensure_openssl
    local cert_dir="${SELF_CERT_DIR}/${domain}"
    mkdir -p "$cert_dir"
    if [[ -f "${cert_dir}/fullchain.pem" ]]; then
        success "自签名证书已存在: ${cert_dir}/"
        return
    fi
    info "生成自签名证书（有效期 ${days} 天）..."
    openssl req -x509 -nodes -days "$days" \
        -newkey rsa:2048 \
        -keyout "${cert_dir}/privkey.pem" \
        -out    "${cert_dir}/fullchain.pem" \
        -subj   "/CN=${domain}/O=Self-Signed/C=CN" \
        -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" 2>/dev/null
    chmod 600 "${cert_dir}/privkey.pem"
    success "自签名证书已生成: ${cert_dir}/"
}

# 命令行：cert issue（交互式）
cmd_cert_issue() {
    require_root
    ensure_certbot
    local domain="" email="" method="nginx" wildcard=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain)  domain="$2";  shift 2 ;;
            -e|--email)   email="$2";   shift 2 ;;
            -m|--method)  method="$2";  shift 2 ;;
            --wildcard)   wildcard=true; shift ;;
            *) die "未知参数: $1" ;;
        esac
    done

    [[ -n "$domain" ]] || read -rp "域名: " domain
    [[ -n "$email"  ]] || read -rp "邮箱: " email
    [[ -n "$domain" && -n "$email" ]] || die "域名和邮箱不能为空"

    if $wildcard; then
        certbot certonly --manual --preferred-challenges dns \
            -d "${domain}" -d "*.${domain}" \
            --agree-tos --email "$email" --no-eff-email
    else
        case $method in
            nginx)
                certbot --nginx -d "$domain" --agree-tos --email "$email" \
                    --no-eff-email --non-interactive ;;
            webroot)
                local wr="/var/www/html"; mkdir -p "$wr"
                certbot certonly --webroot -w "$wr" -d "$domain" \
                    --agree-tos --email "$email" --no-eff-email --non-interactive ;;
            standalone)
                certbot certonly --standalone -d "$domain" \
                    --agree-tos --email "$email" --no-eff-email --non-interactive ;;
            *) die "未知验证方式: $method" ;;
        esac
    fi
    success "证书路径: ${LE_CERT_BASE}/${domain}/"
}

cmd_cert_self_signed() {
    require_root
    local domain="" days=3650
    while [[ $# -gt 0 ]]; do
        case $1 in
            -d|--domain) domain="$2"; shift 2 ;;
            --days)      days="$2";   shift 2 ;;
            *) die "未知参数: $1" ;;
        esac
    done
    [[ -n "$domain" ]] || read -rp "域名: " domain
    cert_self_signed_auto "$domain" "$days"
}

cmd_cert_renew() {
    require_root; ensure_certbot
    local domain="${1:-}"
    if [[ -n "$domain" ]]; then
        certbot renew --cert-name "$domain" --non-interactive
    else
        certbot renew --non-interactive
    fi
    nginx_reload
    success "证书续期完成"
}

cmd_cert_list() {
    require_root
    echo -e "\n${BOLD}=== Let's Encrypt 证书 ===${NC}"
    if command -v certbot &>/dev/null; then
        certbot certificates 2>/dev/null || warn "暂无 LE 证书"
    else warn "certbot 未安装"; fi

    echo -e "\n${BOLD}=== 自签名证书 ===${NC}"
    local found=false
    for dir in "${SELF_CERT_DIR}"/*/; do
        [[ -d "$dir" ]] || continue; found=true
        local dom; dom=$(basename "$dir")
        local cert="${dir}fullchain.pem"
        if [[ -f "$cert" ]]; then
            local exp; exp=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            echo -e "  ${CYAN}${dom}${NC}  到期: ${exp}"
        fi
    done
    $found || echo "  暂无自签名证书"
}

cmd_cert_auto_renew() {
    require_root
    local cron_file="/etc/cron.d/nginx-gateway-certbot"
    echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" > "$cron_file"
    chmod 644 "$cron_file"
    success "自动续期已配置（每天凌晨 3:00）: $cron_file"
}

# ──────────────────────────────────────────────────────────
# 配置文件写入辅助：HTTP→HTTPS 重定向块
# 参数：
#   $1 domain       — server_name
#   $2 https_port   — 目标 HTTPS 端口
#   $3 http_port    — 来源 HTTP 端口（默认 80）
# 规则：
#   - 目标端口 443 时省略端口号（标准 HTTPS URL）
#   - 来源端口 80 时同时监听 IPv4/IPv6
#   - 非标准来源端口单独监听，避免占用 80
# ──────────────────────────────────────────────────────────
write_redirect_block() {
    local domain="$1"
    local https_port="$2"
    local http_port="${3:-80}"

    local target_url
    if [[ "$https_port" == "443" ]]; then
        target_url="https://\$host\$request_uri"
    else
        target_url="https://\$host:${https_port}\$request_uri"
    fi

    if [[ "$http_port" == "80" ]]; then
        # 标准 80 端口：301 跳转到 HTTPS
        cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $domain;
    return 301 ${target_url};
}

EOF
    else
        # 非标准 HTTP 端口：直接拒绝，不提供 HTTP 访问
        # 注意：此端口只用于强制拒绝明文连接，HTTPS 服务在下方 ssl 块
        cat <<EOF
# 非标准端口 ${http_port} 拒绝 HTTP 明文访问（强制只走 HTTPS:${https_port}）
server {
    listen ${http_port};
    server_name $domain;
    return 444;  # 直接断开，不返回任何内容
}

EOF
        warn "非标准端口 ${http_port} 的 HTTP 访问将被直接拒绝（return 444）"
        warn "用户须直接访问 https://${domain}:${https_port}/"
    fi
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 A — 静态文件托管
# ──────────────────────────────────────────────────────────
site_create_static() {
    require_root; init_dirs

    local domain="" web_dir="" php=false
    read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    read -rp "网站根目录（绝对路径）[默认 ${WEBROOT_BASE}/${domain}/public]: " web_dir
    [[ -z "$web_dir" ]] && web_dir="${WEBROOT_BASE}/${domain}/public"

    read -rp "是否启用 PHP-FPM？[y/N]: " _php
    [[ "${_php,,}" == "y" ]] && php=true

    ask_ssl_params
    resolve_ssl_cert "$domain"

    # 准备目录和默认首页
    mkdir -p "$web_dir"
    [[ ! -f "${web_dir}/index.html" ]] && cat > "${web_dir}/index.html" <<HTML
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>${domain}</title></head>
<body><h1>Welcome to ${domain}</h1><p>站点已就绪。</p></body></html>
HTML
    chown -R www-data:www-data "$(dirname "$web_dir")" 2>/dev/null || \
    chown -R nginx:nginx "$(dirname "$web_dir")" 2>/dev/null || true

    local conf_file="${SITES_AVAILABLE}/${domain}.conf"
    {
        [[ "$_SSL_301" == "yes" ]] && write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            echo "    listen ${_SSL_PORT} ssl;"
            echo "    listen [::]:${_SSL_PORT} ssl;"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi
        echo "    server_name $domain;"
        echo "    root $web_dir;"
        echo "    index index.html index.htm$(${php} && echo " index.php" || true);"
        echo ""
        echo "    access_log /var/log/nginx/${domain}.access.log;"
        echo "    error_log  /var/log/nginx/${domain}.error.log;"
        echo ""

        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" && echo ""

        cat <<'CONF'
    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    location ~ /\. { deny all; }
CONF
        if $php; then
            cat <<'PHP'

    location ~ \.php$ {
        include        snippets/fastcgi-php.conf;
        fastcgi_pass   unix:/run/php/php-fpm.sock;
        fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include        fastcgi_params;
    }
PHP
        fi
        echo "}"
    } > "$conf_file"

    _site_activate "$domain"
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 B — 反向代理（普通端口穿透）
# ──────────────────────────────────────────────────────────
site_create_proxy() {
    require_root; init_dirs

    local domain="" backend=""
    read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"
    read -rp "后端目标地址（如 127.0.0.1:3000 或 http://10.0.0.5:8080）: " backend
    [[ -z "$backend" ]] && die "后端地址不能为空"
    backend=$(normalize_url "$backend")

    ask_ssl_params
    resolve_ssl_cert "$domain"

    local conf_file="${SITES_AVAILABLE}/${domain}.conf"
    {
        [[ "$_SSL_301" == "yes" ]] && write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            echo "    listen ${_SSL_PORT} ssl;"
            echo "    listen [::]:${_SSL_PORT} ssl;"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi
        cat <<CONF
    server_name $domain;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

CONF
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" && echo ""

        cat <<CONF
    location / {
        proxy_pass         $backend;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_ssl_server_name on;
    }

    location ~ /\. { deny all; }
}
CONF
    } > "$conf_file"

    _site_activate "$domain"
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 C — 镜像 / 多源聚合（sub_filter）
# ──────────────────────────────────────────────────────────
site_create_mirror() {
    require_root; init_dirs
    check_sub_filter_module

    local domain="" target_url=""
    read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"
    read -rp "镜像目标网站 URL（如 https://example.com）: " target_url
    [[ -z "$target_url" ]] && die "目标 URL 不能为空"
    target_url=$(normalize_url "$target_url")
    local target_host; target_host=$(echo "$target_url" | awk -F/ '{print $3}')

    ask_ssl_params
    resolve_ssl_cert "$domain"

    # 收集额外资源域名
    local extra_locs="" count=1
    echo ""
    info "可添加额外的静态资源/CDN 域名（作为子路径代理，回车结束）"
    while true; do
        read -rp "额外资源 URL（回车跳过）: " res_url
        [[ -z "$res_url" ]] && break
        res_url=$(normalize_url "$res_url")
        local res_host; res_host=$(echo "$res_url" | awk -F/ '{print $3}')
        local key="_res_${count}"
        extra_locs+=$(cat <<LOCEOF

    location /${key}/ {
        rewrite ^/${key}/(.*) /\$1 break;
        proxy_pass $res_url;
        proxy_set_header Host $res_host;
        proxy_set_header Referer $res_url;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
    }
LOCEOF
)
        ((count++))
    done

    local conf_file="${SITES_AVAILABLE}/${domain}.conf"
    {
        [[ "$_SSL_301" == "yes" ]] && write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            echo "    listen ${_SSL_PORT} ssl;"
            echo "    listen [::]:${_SSL_PORT} ssl;"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi
        cat <<CONF
    server_name $domain;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

CONF
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" && echo ""

        cat <<CONF
    location / {
        proxy_pass $target_url;
        proxy_set_header Host $target_host;
        proxy_set_header Referer $target_url;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
        sub_filter "</head>" "<meta name='referrer' content='no-referrer'></head>";
        sub_filter "$target_host"          "$domain";
        sub_filter "https://$target_host"  "https://$domain";
        sub_filter "http://$target_host"   "https://$domain";
        sub_filter_once off;
        sub_filter_types *;
    }
CONF
        [[ -n "$extra_locs" ]] && echo "$extra_locs"
        echo ""
        echo "    location ~ /\. { deny all; }"
        echo "}"
    } > "$conf_file"

    _site_activate "$domain"
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 D — HTTP 正向代理
# ──────────────────────────────────────────────────────────
site_create_forward_proxy() {
    require_root; init_dirs

    local port=""
    read -rp "正向代理监听端口 [默认 8888]: " port
    [[ -z "$port" ]] && port="8888"

    warn "Nginx 原生仅支持 HTTP 正向代理，不支持 HTTPS CONNECT 隧道。"
    warn "如需完整 HTTPS 支持，请改用 Squid 或 3proxy。"

    local conf_file="${SITES_DIR}/forward-proxy-${port}.conf"
    cat > "$conf_file" <<EOF
# Nginx HTTP 正向代理（不支持 HTTPS CONNECT 隧道）
# 如需 HTTPS 支持请改用 Squid / 3proxy
server {
    listen $port;
    server_name _;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    location / {
        proxy_pass \$scheme://\$http_host\$request_uri;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_buffers 256 4k;
        proxy_max_temp_file_size 0;
        proxy_connect_timeout 30;
    }
}
EOF
    success "正向代理配置已写入: $conf_file"
    nginx_reload
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 E — TCP/UDP 流代理（stream 模块）
# ──────────────────────────────────────────────────────────
site_create_stream_proxy() {
    require_root

    if ! nginx -V 2>&1 | grep -q "stream"; then
        die "当前 Nginx 未编译 stream 模块，无法使用 TCP/UDP 流代理。\nDebian/Ubuntu 可执行: apt install nginx-full"
    fi

    local listen_port="" backend_host="" backend_port="" proto="tcp"
    read -rp "本地监听端口: " listen_port
    [[ -z "$listen_port" ]] && die "端口不能为空"
    read -rp "后端 IP/域名: " backend_host
    [[ -z "$backend_host" ]] && die "后端地址不能为空"
    read -rp "后端端口: " backend_port
    [[ -z "$backend_port" ]] && die "后端端口不能为空"
    read -rp "协议 [tcp/udp，默认 tcp]: " proto
    [[ -z "$proto" ]] && proto="tcp"

    local stream_conf="${NGINX_CONF_DIR}/conf.d/stream-${listen_port}.conf"
    local udp_flag; [[ "$proto" == "udp" ]] && udp_flag=" udp" || udp_flag=""

    cat > "$stream_conf" <<EOF
# TCP/UDP 流代理 — 端口 ${listen_port} → ${backend_host}:${backend_port}
stream {
    server {
        listen ${listen_port}${udp_flag};
        proxy_pass ${backend_host}:${backend_port};
        proxy_connect_timeout 10s;
        proxy_timeout 60s;
    }
}
EOF
    warn "stream 块不能嵌套在 http 块内，请确认 nginx.conf 中已顶层 include conf.d/*.conf"
    success "流代理配置已写入: $stream_conf"
    nginx_reload
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 F — 域名跳转（Redirect）
# 支持：301 永久 / 302 临时 / 307 保留Method临时 / 308 保留Method永久
# 支持：整站跳转 / 精确路径跳转 / 正则路径跳转
# ──────────────────────────────────────────────────────────
site_create_redirect() {
    require_root; init_dirs

    local src_domain="" target_url="" code="301" keep_path="yes"

    read -rp "来源域名（访问者访问的域名，如 old.example.com）: " src_domain
    [[ -z "$src_domain" ]] && die "来源域名不能为空"

    read -rp "跳转目标 URL（如 https://google.com 或 https://new.example.com）: " target_url
    [[ -z "$target_url" ]] && die "目标 URL 不能为空"
    # 目标 URL 去掉末尾斜杠，便于拼接路径
    target_url="${target_url%/}"

    echo ""
    echo -e "${CYAN}── 跳转类型 ──${NC}"
    echo "  1) 301 — 永久跳转（浏览器/搜索引擎缓存，推荐换域名用）"
    echo "  2) 302 — 临时跳转（不缓存，推荐维护期用）"
    echo "  3) 307 — 临时跳转（保留请求 Method，POST 不变为 GET）"
    echo "  4) 308 — 永久跳转（保留请求 Method）"
    read -rp "选择 [1-4，默认 1]: " _code_choice
    case "${_code_choice:-1}" in
        1) code=301 ;;
        2) code=302 ;;
        3) code=307 ;;
        4) code=308 ;;
        *) die "无效选项" ;;
    esac

    echo ""
    echo -e "${CYAN}── 路径处理 ──${NC}"
    echo "  1) 保留路径跳转（访问 /foo/bar → 目标/foo/bar）"
    echo "  2) 整站跳转到固定 URL（所有路径都跳到目标根）"
    echo "  3) 精确路径规则（自定义 location 和 rewrite）"
    read -rp "选择 [1-3，默认 1]: " _path_choice

    # 监听端口（重定向站点一般只需 80，但也可加 SSL）
    echo ""
    echo -e "${CYAN}── 监听配置 ──${NC}"
    echo "  1) 仅监听 HTTP 80（最常用，来源本身就是 HTTP 域名）"
    echo "  2) 同时监听 HTTP 80 + HTTPS 443（来源域名有 SSL）"
    read -rp "选择 [1-2，默认 1]: " _listen_choice

    local has_ssl=false
    if [[ "${_listen_choice:-1}" == "2" ]]; then
        has_ssl=true
        ask_ssl_params
        resolve_ssl_cert "$src_domain"
    fi

    local conf_file="${SITES_AVAILABLE}/${src_domain}-redirect.conf"

    {
        echo "# 跳转规则: ${src_domain} → ${target_url} [${code}]"
        echo "# 生成时间: $(date)"
        echo ""

        # ── HTTP server 块 ──
        echo "server {"
        echo "    listen 80;"
        echo "    listen [::]:80;"
        echo "    server_name ${src_domain};"
        echo ""
        echo "    access_log /var/log/nginx/${src_domain}-redirect.access.log;"
        echo "    error_log  /var/log/nginx/${src_domain}-redirect.error.log;"
        echo ""

        case "${_path_choice:-1}" in
            1)
                echo "    # 保留原始路径跳转"
                echo "    return ${code} ${target_url}\$request_uri;"
                ;;
            2)
                echo "    # 整站跳转到固定目标"
                echo "    return ${code} ${target_url}/;"
                ;;
            3)
                echo ""
                echo -e "${CYAN}请输入自定义路径规则（输入完成后回车空行结束）${NC}" >&2
                echo "示例: location /old-page { return 301 ${target_url}/new-page; }" >&2
                echo "示例: location ~* ^/blog/(.+) { return 301 ${target_url}/posts/\$1; }" >&2
                local rules=()
                while true; do
                    read -rp "location 规则（回车结束）: " _rule
                    [[ -z "$_rule" ]] && break
                    rules+=("    $_rule")
                done
                if [[ ${#rules[@]} -gt 0 ]]; then
                    printf '%s\n' "${rules[@]}"
                else
                    # 兜底：保留路径
                    echo "    return ${code} ${target_url}\$request_uri;"
                fi
                ;;
        esac

        echo "}"

        # ── HTTPS server 块（可选）──
        if $has_ssl; then
            echo ""
            echo "server {"
            echo "    listen ${_SSL_PORT} ssl;"
            echo "    listen [::]:${_SSL_PORT} ssl;"
            echo "    server_name ${src_domain};"
            echo ""
            ssl_block "$_SSL_CERT" "$_SSL_KEY"
            echo ""
            echo "    access_log /var/log/nginx/${src_domain}-redirect.access.log;"
            echo "    error_log  /var/log/nginx/${src_domain}-redirect.error.log;"
            echo ""
            case "${_path_choice:-1}" in
                1) echo "    return ${code} ${target_url}\$request_uri;" ;;
                2) echo "    return ${code} ${target_url}/;" ;;
                3) [[ ${#rules[@]} -gt 0 ]] && printf '%s\n' "${rules[@]}" \
                   || echo "    return ${code} ${target_url}\$request_uri;" ;;
            esac
            echo "}"
        fi
    } > "$conf_file"

    _site_activate "${src_domain}-redirect"

    echo ""
    info "跳转规则预览："
    echo -e "  ${CYAN}${src_domain}${NC}  ──[${code}]──▶  ${target_url}"
}

# ──────────────────────────────────────────────────────────
# 站点生成：模式 G — 负载均衡（upstream）
# 支持：轮询 / least_conn / ip_hash / random
# 支持：健康检查参数 / 权重 / 备用节点
# ──────────────────────────────────────────────────────────
site_create_loadbalance() {
    require_root; init_dirs

    local domain=""
    read -rp "域名或 server_name: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    echo ""
    echo -e "${CYAN}── 负载均衡算法 ──${NC}"
    echo "  1) round-robin   轮询（默认，按顺序分发）"
    echo "  2) least_conn    最少连接（优先分发到连接数最少的节点）"
    echo "  3) ip_hash       IP 哈希（同一 IP 固定到同一节点，适合 Session）"
    echo "  4) random        随机（随机选择节点）"
    read -rp "选择 [1-4，默认 1]: " _lb_algo
    local lb_directive=""
    case "${_lb_algo:-1}" in
        1) lb_directive="" ;;
        2) lb_directive="    least_conn;" ;;
        3) lb_directive="    ip_hash;" ;;
        4) lb_directive="    random;" ;;
        *) die "无效选项" ;;
    esac

    # 收集后端节点
    echo ""
    info "请逐行输入后端节点，格式：IP:端口 [weight=N] [backup]"
    info "示例: 192.168.1.10:8080  或  192.168.1.11:8080 weight=3  或  192.168.1.12:8080 backup"
    info "输入空行结束"
    local servers=()
    while true; do
        read -rp "后端节点: " _srv
        [[ -z "$_srv" ]] && break
        servers+=("$_srv")
    done
    [[ ${#servers[@]} -eq 0 ]] && die "至少需要一个后端节点"

    # 健康检查参数
    read -rp "max_fails（失败次数判定不可用，默认 3）: " _mf
    read -rp "fail_timeout（不可用持续时间，默认 10s）: " _ft
    [[ -z "$_mf" ]] && _mf=3
    [[ -z "$_ft" ]] && _ft="10s"

    ask_ssl_params
    resolve_ssl_cert "$domain"

    local upstream_name="${domain//./_}_upstream"
    local conf_file="${SITES_AVAILABLE}/${domain}.conf"

    {
        echo "# 负载均衡配置: ${domain}"
        echo "# 生成时间: $(date)"
        echo ""
        echo "upstream ${upstream_name} {"
        [[ -n "$lb_directive" ]] && echo "$lb_directive"
        echo ""
        for srv in "${servers[@]}"; do
            echo "    server ${srv} max_fails=${_mf} fail_timeout=${_ft};"
        done
        echo ""
        echo "    keepalive 32;  # 保持长连接池"
        echo "}"
        echo ""

        [[ "$_SSL_301" == "yes" ]] && write_redirect_block "$domain" "$_SSL_PORT" "$_SSL_HTTP_PORT"

        echo "server {"
        if [[ "$_SSL_MODE" != "none" ]]; then
            echo "    listen ${_SSL_PORT} ssl;"
            echo "    listen [::]:${_SSL_PORT} ssl;"
        else
            echo "    listen ${_SSL_PORT};"
            echo "    listen [::]:${_SSL_PORT};"
        fi
        cat <<CONF
    server_name ${domain};

    access_log /var/log/nginx/${domain}.access.log;
    error_log  /var/log/nginx/${domain}.error.log;

CONF
        [[ "$_SSL_MODE" != "none" ]] && ssl_block "$_SSL_CERT" "$_SSL_KEY" && echo ""

        cat <<CONF
    location / {
        proxy_pass         http://${upstream_name};
        proxy_http_version 1.1;
        proxy_set_header   Connection "";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;

        # 超时设置
        proxy_connect_timeout  5s;
        proxy_send_timeout     60s;
        proxy_read_timeout     60s;
    }

    location ~ /\. { deny all; }
}
CONF
    } > "$conf_file"

    _site_activate "$domain"

    echo ""
    info "后端节点列表："
    for srv in "${servers[@]}"; do
        echo -e "  ${CYAN}▶${NC} $srv"
    done
}

# ──────────────────────────────────────────────────────────
# 访问控制：为现有站点追加 IP 黑/白名单 或 Basic Auth
# ──────────────────────────────────────────────────────────
site_add_acl() {
    require_root; init_dirs

    local domain=""
    read -rp "要添加访问控制的域名: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ ! -f "$conf" ]] && conf="${SITES_AVAILABLE}/${domain}-redirect.conf"
    [[ ! -f "$conf" ]] && die "找不到站点配置: ${domain}，请先创建站点"

    echo ""
    echo -e "${CYAN}── 访问控制类型 ──${NC}"
    echo "  1) IP 白名单（只允许指定 IP，拒绝其余所有）"
    echo "  2) IP 黑名单（拒绝指定 IP，允许其余所有）"
    echo "  3) Basic Auth（用户名/密码认证）"
    echo "  4) IP 白名单 + Basic Auth（双重保护）"
    read -rp "选择 [1-4]: " _acl_type

    local acl_snippet=""
    local acl_conf_file="${NGINX_CONF_DIR}/conf.d/acl-${domain}.conf"

    case "${_acl_type:-1}" in
        1|2)
            local ips=()
            local action=""; local default_action=""
            if [[ "${_acl_type}" == "1" ]]; then
                action="allow"; default_action="deny"
                info "请逐行输入允许的 IP 或 CIDR（如 192.168.1.0/24），空行结束:"
            else
                action="deny"; default_action="allow"
                info "请逐行输入要拒绝的 IP 或 CIDR，空行结束:"
            fi
            while true; do
                read -rp "IP/CIDR: " _ip
                [[ -z "$_ip" ]] && break
                ips+=("$_ip")
            done
            [[ ${#ips[@]} -eq 0 ]] && die "至少输入一个 IP"

            acl_snippet="# ACL — 生成时间: $(date)\ngeo \$blocked_ip {\n    default ${default_action};\n"
            for ip in "${ips[@]}"; do
                acl_snippet+="    ${ip} ${action};\n"
            done
            acl_snippet+="}\n"

            # 将 geo 块写入 http 级别独立文件
            printf "${acl_snippet}" > "$acl_conf_file"
            success "ACL 规则写入: $acl_conf_file"

            warn "请在站点 location / 块中手动添加: if (\$blocked_ip = deny) { return 403; }"
            warn "或使用以下命令查看配置后手动编辑: $0 site edit ${domain}"
            ;;

        3|4)
            # Basic Auth
            command -v htpasswd &>/dev/null || install_pkg apache2-utils 2>/dev/null || \
            install_pkg httpd-tools 2>/dev/null || die "无法安装 htpasswd，请手动安装 apache2-utils"

            local auth_file="${NGINX_CONF_DIR}/.htpasswd-${domain}"
            local username=""
            read -rp "用户名: " username
            [[ -z "$username" ]] && die "用户名不能为空"
            htpasswd -c "$auth_file" "$username"
            chmod 640 "$auth_file"
            success "密码文件已创建: $auth_file"

            # 若同时要 IP 白名单
            if [[ "${_acl_type}" == "4" ]]; then
                local ips=()
                info "请逐行输入允许的 IP 或 CIDR，空行结束:"
                while true; do
                    read -rp "IP/CIDR: " _ip
                    [[ -z "$_ip" ]] && break
                    ips+=("$_ip")
                done
                acl_snippet="# IP+Auth 双重保护\n"
                for ip in "${ips[@]}"; do
                    acl_snippet+="allow ${ip};\n"
                done
                acl_snippet+="deny all;\n"
                acl_snippet+="auth_basic \"Restricted\";\n"
                acl_snippet+="auth_basic_user_file ${auth_file};\n"
            else
                acl_snippet="auth_basic \"Restricted\";\nauth_basic_user_file ${auth_file};\n"
            fi

            echo ""
            success "请将以下指令添加到站点 location / 块中："
            echo "────────────────────────────────"
            printf "${acl_snippet}"
            echo "────────────────────────────────"
            warn "使用 $0 site edit ${domain} 打开编辑器添加"
            ;;
        *) die "无效选项" ;;
    esac
}

# ──────────────────────────────────────────────────────────
# 限流：为现有站点生成 limit_req_zone 配置片段
# ──────────────────────────────────────────────────────────
site_add_ratelimit() {
    require_root; init_dirs

    local domain=""
    read -rp "要添加限流的域名: " domain
    [[ -z "$domain" ]] && die "域名不能为空"

    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ ! -f "$conf" ]] && die "站点配置不存在，请先创建站点"

    echo ""
    echo -e "${CYAN}── 限流参数 ──${NC}"
    read -rp "每秒最大请求数（rate，默认 10）: " _rate
    read -rp "内存区大小（zone size，默认 10m，可存约 16万 IP）: " _zone_size
    read -rp "突发请求容量（burst，默认 20）: " _burst
    read -rp "启用 nodelay（超出 burst 直接 503，而非排队）？[Y/n]: " _nodelay

    [[ -z "$_rate"      ]] && _rate=10
    [[ -z "$_zone_size" ]] && _zone_size="10m"
    [[ -z "$_burst"     ]] && _burst=20
    local nodelay_flag=""
    [[ "${_nodelay,,}" != "n" ]] && nodelay_flag=" nodelay"

    local zone_name="limit_${domain//./_}"
    local rl_conf="${NGINX_CONF_DIR}/conf.d/ratelimit-${domain}.conf"

    cat > "$rl_conf" <<EOF
# 限流配置: ${domain}  生成时间: $(date)
# 此文件需被 nginx.conf 的 http{} 块包含
limit_req_zone \$binary_remote_addr zone=${zone_name}:${_zone_size} rate=${_rate}r/s;
limit_req_status 429;
EOF
    success "限流 zone 配置写入: $rl_conf"

    echo ""
    success "请将以下指令添加到站点 location / 块中："
    echo "────────────────────────────────"
    echo "    limit_req zone=${zone_name} burst=${_burst}${nodelay_flag};"
    echo "────────────────────────────────"
    warn "然后执行: $0 site edit ${domain} 打开编辑器添加上述指令"
    warn "并确认 nginx.conf 的 http{} 中已 include /etc/nginx/conf.d/*.conf"
}

# ──────────────────────────────────────────────────────────
# 配置备份 & 还原
# ──────────────────────────────────────────────────────────
BACKUP_DIR="${BACKUP_DIR:-/var/backups/nginx-gateway}"

config_backup() {
    require_root
    mkdir -p "$BACKUP_DIR"

    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/nginx-backup-${ts}.tar.gz"

    info "正在备份 Nginx 配置..."

    local items=()
    [[ -d "$SITES_AVAILABLE" ]] && items+=("$SITES_AVAILABLE")
    [[ -d "$SITES_DIR"       ]] && items+=("$SITES_DIR")
    [[ -d "$SELF_CERT_DIR"   ]] && items+=("$SELF_CERT_DIR")
    [[ -d "${NGINX_CONF_DIR}/conf.d" ]] && items+=("${NGINX_CONF_DIR}/conf.d")
    [[ -f "${NGINX_CONF_DIR}/nginx.conf" ]] && items+=("${NGINX_CONF_DIR}/nginx.conf")

    tar -czf "$backup_file" "${items[@]}" 2>/dev/null || true

    local size; size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)
    success "备份完成: ${backup_file} (${size})"
    echo ""
    info "备份内容:"
    tar -tzf "$backup_file" 2>/dev/null | head -30 || true
}

config_restore() {
    require_root

    echo ""
    info "可用的备份文件:"
    local backups=()
    while IFS= read -r f; do
        backups+=("$f")
    done < <(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true)

    if [[ ${#backups[@]} -eq 0 ]]; then
        warn "暂无备份文件（目录: ${BACKUP_DIR}）"
        return
    fi

    local i=1
    for f in "${backups[@]}"; do
        local ts size
        ts=$(basename "$f" .tar.gz | sed 's/nginx-backup-//')
        size=$(du -sh "$f" 2>/dev/null | cut -f1)
        printf "  %2d) %s  [%s]\n" "$i" "$ts" "$size"
        ((i++))
    done
    echo ""
    read -rp "选择备份序号 [1-${#backups[@]}]: " _idx
    local _idx_n=$((_idx - 1))
    local chosen="${backups[$_idx_n]:-}"
    [[ -z "$chosen" || ! -f "$chosen" ]] && die "无效序号"

    confirm "将用 $(basename "$chosen") 覆盖当前配置？此操作不可撤销！" || { info "已取消"; return; }

    # 先备份当前配置
    info "先备份当前配置..."
    config_backup

    info "正在还原..."
    tar -xzf "$chosen" -C / 2>/dev/null || true
    nginx_reload
    success "配置已还原自: $(basename "$chosen")"
}

config_backup_list() {
    echo -e "\n${BOLD}=== 备份文件列表 ===${NC}"
    if ls "${BACKUP_DIR}"/*.tar.gz &>/dev/null; then
        ls -lht "${BACKUP_DIR}"/*.tar.gz | awk '{printf "  %-40s %s %s\n", $9, $5, $6" "$7}'
    else
        echo "  暂无备份（目录: ${BACKUP_DIR}）"
    fi
    echo ""
}

# ──────────────────────────────────────────────────────────
# 站点生命周期管理
# ──────────────────────────────────────────────────────────
_site_activate() {
    local domain="$1"
    local avail="${SITES_AVAILABLE}/${domain}.conf"
    local enabled="${SITES_DIR}/${domain}.conf"
    ln -sf "$avail" "$enabled"
    success "配置已写入: $avail"
    nginx_reload
    echo ""
    success "✓ 站点 ${domain} 已就绪"
}

site_enable() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && read -rp "域名: " domain
    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ -f "$conf" ]] || die "配置不存在: $conf"
    ln -sf "$conf" "${SITES_DIR}/${domain}.conf"
    nginx_reload
    success "站点已启用: $domain"
}

site_disable() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && read -rp "域名: " domain
    local link="${SITES_DIR}/${domain}.conf"
    [[ -L "$link" ]] || die "站点未启用: $domain"
    rm -f "$link"
    nginx_reload
    success "站点已禁用: $domain"
}

site_delete() {
    require_root
    local domain="${1:-}" del_files=false
    [[ -z "$domain" ]] && read -rp "域名: " domain
    confirm "确认删除站点 ${domain} 的配置？" || { info "已取消"; return; }
    rm -f "${SITES_DIR}/${domain}.conf" "${SITES_AVAILABLE}/${domain}.conf"
    if confirm "是否同时删除网站文件（${WEBROOT_BASE}/${domain}）？"; then
        [[ -d "${WEBROOT_BASE}/${domain}" ]] && rm -rf "${WEBROOT_BASE}/${domain}"
        info "网站文件已删除"
    fi
    nginx_reload
    success "站点 $domain 已删除"
}

site_list() {
    init_dirs
    echo -e "\n${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    printf  "${BOLD}║  %-28s %-8s %-10s  ║${NC}\n" "域名/配置" "状态" "类型"
    echo -e "${BOLD}╠══════════════════════════════════════════════════╣${NC}"

    local found=false
    for conf in "${SITES_AVAILABLE}"/*.conf "${SITES_DIR}"/forward-proxy-*.conf \
                "${NGINX_CONF_DIR}"/conf.d/stream-*.conf; do
        [[ -f "$conf" ]] || continue; found=true
        local name; name=$(basename "$conf" .conf)
        local status="${RED}禁用${NC}"
        [[ -L "${SITES_DIR}/${name}.conf" || "$conf" == "${SITES_DIR}"/* ]] && \
            status="${GREEN}启用${NC}"

        local type="静态文件"
        grep -q "upstream"        "$conf" 2>/dev/null && type="负载均衡"
        grep -q "sub_filter"      "$conf" 2>/dev/null && type="镜像聚合"
        grep -q "proxy_pass"      "$conf" 2>/dev/null && [[ "$type" == "静态文件" ]] && type="反向代理"
        grep -q "stream"          "$conf" 2>/dev/null && type="流代理"
        grep -q "forward"         "$name" 2>/dev/null && type="正向代理"
        grep -qE "return [0-9]{3}" "$conf" 2>/dev/null && \
            ! grep -q "proxy_pass\|root " "$conf" 2>/dev/null && type="跳转重定向"
        grep -q "ssl_certificate" "$conf" 2>/dev/null && type+=" [SSL]"

        printf "${BOLD}║${NC}  %-28s %-18b %-10s  ${BOLD}║${NC}\n" "$name" "$status" "$type"
    done
    $found || echo "  暂无站点配置"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"
}

site_info() {
    local domain="${1:-}"
    [[ -z "$domain" ]] && read -rp "域名: " domain
    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ -f "$conf" ]] || conf="${SITES_DIR}/forward-proxy-${domain}.conf"
    [[ -f "$conf" ]] || die "配置不存在"
    echo -e "\n${BOLD}=== $domain ===${NC}"
    cat "$conf"
}

site_edit() {
    require_root
    local domain="${1:-}"
    [[ -z "$domain" ]] && read -rp "域名: " domain
    local conf="${SITES_AVAILABLE}/${domain}.conf"
    [[ -f "$conf" ]] || die "配置不存在: $conf"
    local editor="${EDITOR:-vi}"
    "$editor" "$conf"
    nginx_reload
}

# ──────────────────────────────────────────────────────────
# 帮助
# ──────────────────────────────────────────────────────────
show_help() {
    cat <<HELP
${BOLD}nginx-gateway.sh — Nginx 全功能网关管理工具${NC}

${BOLD}用法:${NC}
  $0 <命令> [子命令] [选项]
  $0                      （无参数，进入交互式主菜单）

${BOLD}站点创建:${NC}
  site static             静态文件托管（PHP / 自定义端口 / 多种 SSL 模式）
  site proxy              反向代理（WebSocket 穿透 / 自定义 Header）
  site mirror             镜像/多源聚合（sub_filter 内容替换）
  site forward            HTTP 正向代理
  site stream             TCP/UDP 流代理（需 stream 模块）
  site redirect           域名跳转（301/302/307/308，路径保留/整站/精确规则）
  site loadbalance        负载均衡（upstream 多节点，含健康检查）

${BOLD}站点管理:${NC}
  site enable  <域名>     启用站点
  site disable <域名>     禁用站点
  site delete  <域名>     删除站点（可选同时删除文件）
  site list               列出所有站点及类型/状态
  site info    <域名>     查看配置内容
  site edit    <域名>     编辑配置文件

${BOLD}安全增强:${NC}
  site acl                为站点添加 IP 白/黑名单 或 Basic Auth 认证
  site ratelimit          为站点添加限流（limit_req_zone，防刷接口）

${BOLD}证书管理:${NC}
  cert issue              申请 Let's Encrypt 证书
    -d <域名> -e <邮箱>  [-m nginx|webroot|standalone]  [--wildcard]
  cert self-signed        生成自签名证书
    -d <域名>  [--days <天数，默认3650>]
  cert renew  [域名]      手动续期（不填则续期全部）
  cert list               列出所有证书及到期时间
  cert auto-renew         配置 cron 自动续期（每天凌晨 3:00）

${BOLD}配置备份:${NC}
  backup create           备份 Nginx 所有配置到 ${BACKUP_DIR}/
  backup restore          从备份还原配置（自动先备份当前）
  backup list             列出所有备份文件

${BOLD}Nginx 控制:${NC}
  nginx install           安装 Nginx（自动检测包管理器）
  nginx reload            检查语法并重载配置
  nginx restart           重启 Nginx
  nginx status            查看运行状态

${BOLD}SSL 模式（站点创建时交互选择）:${NC}
  1-auto          根据域名自动扫描常见证书路径（acme.sh / certbot / 自定义）
  2-manual        手动指定证书/私钥文件路径
  3-letsencrypt   自动申请 Let's Encrypt（需域名已解析且 80 端口可访问）
  4-self          生成自签名证书（本地/内网开发）
  5-none          纯 HTTP，不使用 SSL

${BOLD}跳转类型说明:${NC}
  301   永久跳转，浏览器/搜索引擎缓存，适合换域名
  302   临时跳转，不缓存，适合维护期
  307   临时跳转，严格保留 POST 等请求方法
  308   永久跳转，严格保留 POST 等请求方法

${BOLD}示例:${NC}
  sudo $0                                           # 进入交互式菜单
  sudo $0 site redirect                             # 创建跳转规则
  sudo $0 site loadbalance                          # 配置负载均衡
  sudo $0 site acl                                  # 添加 IP 访问控制
  sudo $0 cert issue -d example.com -e me@a.com    # 申请 LE 证书
  sudo $0 cert issue -d example.com -e me@a.com --wildcard  # 泛域名证书
  sudo $0 backup create                             # 备份配置
  sudo $0 site disable old.example.com             # 禁用站点

HELP
}

# ──────────────────────────────────────────────────────────
# 交互式主菜单
# ──────────────────────────────────────────────────────────
interactive_menu() {
    while true; do
        clear
        echo -e "${BOLD}${GREEN}"
        echo "  ╔════════════════════════════════════════════════╗"
        echo "  ║        Nginx 全功能网关管理工具                 ║"
        echo "  ╚════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e " ${CYAN}── 站点创建 ──${NC}"
        echo "  1) 静态文件托管（PHP / 自定义端口 / SSL）"
        echo "  2) 反向代理（WebSocket / HTTP 穿透）"
        echo "  3) 镜像 / 多源聚合（sub_filter 内容替换）"
        echo "  4) HTTP 正向代理"
        echo "  5) TCP/UDP 流代理（stream 模块）"
        echo "  6) 域名跳转（301/302/307/308 重定向）"
        echo "  7) 负载均衡（upstream 多节点）"
        echo ""
        echo -e " ${CYAN}── 站点管理 ──${NC}"
        echo "  8) 列出所有站点"
        echo "  9) 启用站点"
        echo " 10) 禁用站点"
        echo " 11) 删除站点"
        echo " 12) 查看 / 编辑配置"
        echo ""
        echo -e " ${CYAN}── 安全增强 ──${NC}"
        echo " 13) 添加 IP 访问控制（白/黑名单 / Basic Auth）"
        echo " 14) 添加限流规则（防刷 / rate limiting）"
        echo ""
        echo -e " ${CYAN}── 证书管理 ──${NC}"
        echo " 15) 申请 Let's Encrypt 证书"
        echo " 16) 生成自签名证书"
        echo " 17) 续期证书"
        echo " 18) 列出所有证书"
        echo " 19) 配置自动续期 (cron)"
        echo ""
        echo -e " ${CYAN}── 配置备份 ──${NC}"
        echo " 20) 备份 Nginx 配置"
        echo " 21) 还原配置"
        echo " 22) 查看备份列表"
        echo ""
        echo -e " ${CYAN}── Nginx ──${NC}"
        echo " 23) 重载 Nginx 配置"
        echo " 24) 重启 Nginx"
        echo " 25) 查看 Nginx 状态"
        echo "  0) 退出"
        echo ""
        read -rp "请选择 [0-25]: " choice

        case "$choice" in
            1)  site_create_static ;;
            2)  site_create_proxy ;;
            3)  site_create_mirror ;;
            4)  site_create_forward_proxy ;;
            5)  site_create_stream_proxy ;;
            6)  site_create_redirect ;;
            7)  site_create_loadbalance ;;
            8)  site_list; read -rp "按回车继续..." _ ;;
            9)  site_enable ;;
           10)  site_disable ;;
           11)  site_delete ;;
           12)  read -rp "域名（查看 info）或输入 e<域名>（编辑）: " _inp
                [[ "$_inp" == e* ]] && site_edit "${_inp#e}" || site_info "$_inp"
                read -rp "按回车继续..." _ ;;
           13)  site_add_acl ;;
           14)  site_add_ratelimit ;;
           15)  cmd_cert_issue ;;
           16)  cmd_cert_self_signed ;;
           17)  read -rp "域名（留空续期全部）: " _d; cmd_cert_renew "${_d:-}" ;;
           18)  cmd_cert_list; read -rp "按回车继续..." _ ;;
           19)  cmd_cert_auto_renew ;;
           20)  config_backup ;;
           21)  config_restore ;;
           22)  config_backup_list; read -rp "按回车继续..." _ ;;
           23)  nginx_reload ;;
           24)  nginx_restart ;;
           25)  nginx_status; read -rp "按回车继续..." _ ;;
            0)  echo "再见！"; exit 0 ;;
            *)  warn "无效选项，请重试" ;;
        esac
        echo ""
    done
}

# ──────────────────────────────────────────────────────────
# 命令行入口
# ──────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/nginx-gateway.log"
    touch "$LOG_FILE" 2>/dev/null || true

    [[ $# -eq 0 ]] && { check_and_install_nginx; init_dirs; interactive_menu; exit 0; }

    local cmd="${1}"; shift || true
    local sub="${1:-}"; [[ $# -gt 0 ]] && shift || true

    case "${cmd}" in
        site)
            case "${sub}" in
                static)       site_create_static ;;
                proxy)        site_create_proxy ;;
                mirror)       site_create_mirror ;;
                forward)      site_create_forward_proxy ;;
                stream)       site_create_stream_proxy ;;
                redirect)     site_create_redirect ;;
                loadbalance)  site_create_loadbalance ;;
                acl)          site_add_acl ;;
                ratelimit)    site_add_ratelimit ;;
                enable)       site_enable "${1:-}" ;;
                disable)      site_disable "${1:-}" ;;
                delete)       site_delete "${1:-}" ;;
                list)         site_list ;;
                info)         site_info "${1:-}" ;;
                edit)         site_edit "${1:-}" ;;
                *)            show_help ;;
            esac ;;
        cert)
            case "${sub}" in
                issue)        cmd_cert_issue "$@" ;;
                self-signed)  cmd_cert_self_signed "$@" ;;
                renew)        cmd_cert_renew "${1:-}" ;;
                list)         cmd_cert_list ;;
                auto-renew)   cmd_cert_auto_renew ;;
                *)            show_help ;;
            esac ;;
        backup)
            case "${sub}" in
                create)       config_backup ;;
                restore)      config_restore ;;
                list)         config_backup_list ;;
                *)            show_help ;;
            esac ;;
        nginx)
            case "${sub}" in
                install)      check_and_install_nginx ;;
                reload)       nginx_reload ;;
                restart)      nginx_restart ;;
                status)       nginx_status ;;
                *)            show_help ;;
            esac ;;
        help|--help|-h) show_help ;;
        *) show_help ;;
    esac
}

main "$@"
