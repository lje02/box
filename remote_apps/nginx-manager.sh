#!/bin/bash
# ============================================================
#  nginx-manager.sh
#  Nginx 站点 & SSL 证书一体化管理脚本
#  支持：Let's Encrypt (certbot) / 自签证书
#  系统：Ubuntu / Debian / CentOS / RHEL
# ============================================================

set -euo pipefail

# ──────────────────────────────────────────
# 全局配置
# ──────────────────────────────────────────
NGINX_CONF_DIR="/etc/nginx"
SITES_AVAILABLE="${NGINX_CONF_DIR}/sites-available"
SITES_ENABLED="${NGINX_CONF_DIR}/sites-enabled"
CERT_BASE_DIR="/etc/letsencrypt/live"
SELF_CERT_DIR="/etc/nginx/ssl"
WEBROOT_BASE="/var/www"
LOG_FILE="/var/log/nginx-manager.log"
ACME_WEBROOT="/var/www/html"          # certbot webroot 验证目录
EMAIL=""                               # 申请证书默认邮箱（可通过参数覆盖）

# ──────────────────────────────────────────
# 颜色 & 工具函数
# ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERR]${NC}   $*" | tee -a "$LOG_FILE"; }
die()     { error "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "请以 root 身份运行本脚本（sudo $0）"
}

confirm() {
  read -rp "${YELLOW}$1 [y/N]${NC} " ans
  [[ ${ans,,} == "y" ]]
}

nginx_reload() {
  info "检查 Nginx 配置..."
  nginx -t 2>&1 | tee -a "$LOG_FILE" || die "Nginx 配置检查失败，已回滚"
  info "重载 Nginx..."
  systemctl reload nginx && success "Nginx 重载成功"
}

detect_pkg_manager() {
  if command -v apt-get &>/dev/null; then echo "apt"
  elif command -v yum &>/dev/null;   then echo "yum"
  elif command -v dnf &>/dev/null;   then echo "dnf"
  else die "不支持的包管理器，请手动安装依赖"; fi
}

install_pkg() {
  local pkg=$1
  local mgr; mgr=$(detect_pkg_manager)
  info "安装 ${pkg}..."
  case $mgr in
    apt) apt-get install -y "$pkg" ;;
    yum) yum install -y "$pkg" ;;
    dnf) dnf install -y "$pkg" ;;
  esac
}

ensure_certbot() {
  command -v certbot &>/dev/null && return
  warn "未检测到 certbot，尝试安装..."
  local mgr; mgr=$(detect_pkg_manager)
  case $mgr in
    apt)
      apt-get install -y certbot python3-certbot-nginx ;;
    yum|dnf)
      $mgr install -y epel-release
      $mgr install -y certbot python3-certbot-nginx ;;
  esac
  command -v certbot &>/dev/null || die "certbot 安装失败，请手动安装"
  success "certbot 安装完成"
}

ensure_openssl() {
  command -v openssl &>/dev/null || install_pkg openssl
}

init_dirs() {
  mkdir -p "$SITES_AVAILABLE" "$SITES_ENABLED" "$SELF_CERT_DIR"
  touch "$LOG_FILE"
  # 确保 sites-enabled 被 nginx.conf include
  if ! grep -q "sites-enabled" "${NGINX_CONF_DIR}/nginx.conf" 2>/dev/null; then
    warn "nginx.conf 中未包含 sites-enabled，请手动添加："
    warn "  include /etc/nginx/sites-enabled/*;"
  fi
}

# ──────────────────────────────────────────
# 模块 1：申请 Let's Encrypt 证书
# ──────────────────────────────────────────
cert_issue() {
  require_root
  ensure_certbot

  local domain="" email="" method="nginx" webroot="" wildcard=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--domain)    domain="$2";   shift 2 ;;
      -e|--email)     email="$2";    shift 2 ;;
      -m|--method)    method="$2";   shift 2 ;;   # nginx | webroot | standalone
      -w|--webroot)   webroot="$2";  shift 2 ;;
      --wildcard)     wildcard=true; shift   ;;
      *) die "未知参数: $1" ;;
    esac
  done

  [[ -n "$domain" ]] || { read -rp "请输入域名（如 example.com）: " domain; }
  [[ -n "$email" ]]  || { read -rp "请输入邮箱（用于证书到期通知）: " email; }
  [[ -n "$domain" && -n "$email" ]] || die "域名和邮箱不能为空"

  if $wildcard; then
    info "申请泛域名证书 *.${domain}（需要 DNS 验证）..."
    certbot certonly \
      --manual \
      --preferred-challenges dns \
      -d "${domain}" \
      -d "*.${domain}" \
      --agree-tos \
      --email "$email" \
      --no-eff-email
  else
    case $method in
      nginx)
        info "使用 Nginx 插件申请证书 ${domain}..."
        certbot --nginx -d "$domain" --agree-tos --email "$email" --no-eff-email --non-interactive
        ;;
      webroot)
        local wr="${webroot:-$ACME_WEBROOT}"
        mkdir -p "$wr"
        info "使用 webroot 方式申请证书 ${domain}（webroot: $wr）..."
        certbot certonly --webroot -w "$wr" -d "$domain" \
          --agree-tos --email "$email" --no-eff-email --non-interactive
        ;;
      standalone)
        info "使用 standalone 方式申请证书 ${domain}（会短暂占用 80 端口）..."
        certbot certonly --standalone -d "$domain" \
          --agree-tos --email "$email" --no-eff-email --non-interactive
        ;;
      *) die "未知验证方式: $method（支持: nginx / webroot / standalone）" ;;
    esac
  fi

  success "证书申请成功！路径: ${CERT_BASE_DIR}/${domain}/"
}

# ──────────────────────────────────────────
# 模块 2：生成自签名证书
# ──────────────────────────────────────────
cert_self_signed() {
  require_root
  ensure_openssl

  local domain="" days=3650

  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--domain) domain="$2"; shift 2 ;;
      --days)      days="$2";   shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  [[ -n "$domain" ]] || { read -rp "请输入域名: " domain; }

  local cert_dir="${SELF_CERT_DIR}/${domain}"
  mkdir -p "$cert_dir"

  info "生成自签名证书（有效期 ${days} 天）..."
  openssl req -x509 -nodes -days "$days" \
    -newkey rsa:2048 \
    -keyout "${cert_dir}/privkey.pem" \
    -out    "${cert_dir}/fullchain.pem" \
    -subj "/CN=${domain}/O=Self-Signed/C=CN" \
    -extensions v3_ca \
    -addext "subjectAltName=DNS:${domain},DNS:www.${domain}"

  chmod 600 "${cert_dir}/privkey.pem"
  success "自签名证书已生成：${cert_dir}/"
  echo -e "  证书: ${cert_dir}/fullchain.pem"
  echo -e "  私钥: ${cert_dir}/privkey.pem"
}

# ──────────────────────────────────────────
# 模块 3：续期证书
# ──────────────────────────────────────────
cert_renew() {
  require_root
  ensure_certbot

  local domain="${1:-}"
  if [[ -n "$domain" ]]; then
    info "续期证书: ${domain}..."
    certbot renew --cert-name "$domain" --non-interactive
  else
    info "续期所有即将到期的证书..."
    certbot renew --non-interactive
  fi
  nginx_reload
  success "证书续期完成"
}

# ──────────────────────────────────────────
# 模块 4：列出证书
# ──────────────────────────────────────────
cert_list() {
  require_root
  echo -e "\n${BOLD}=== Let's Encrypt 证书 ===${NC}"
  if command -v certbot &>/dev/null; then
    certbot certificates 2>/dev/null || warn "暂无 Let's Encrypt 证书"
  else
    warn "certbot 未安装"
  fi

  echo -e "\n${BOLD}=== 自签名证书 ===${NC}"
  if [[ -d "$SELF_CERT_DIR" ]]; then
    local found=false
    for dir in "${SELF_CERT_DIR}"/*/; do
      [[ -d "$dir" ]] || continue
      found=true
      local domain; domain=$(basename "$dir")
      local cert="${dir}fullchain.pem"
      if [[ -f "$cert" ]]; then
        local expiry; expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
        echo -e "  ${CYAN}${domain}${NC}  到期: ${expiry}"
      fi
    done
    $found || echo "  暂无自签名证书"
  fi
}

# ──────────────────────────────────────────
# 模块 5：撤销/删除证书
# ──────────────────────────────────────────
cert_revoke() {
  require_root
  local domain="${1:-}"
  [[ -n "$domain" ]] || { read -rp "请输入要撤销的域名: " domain; }
  confirm "确认撤销并删除 ${domain} 的证书？" || { info "已取消"; return; }
  ensure_certbot
  certbot revoke --cert-name "$domain" --delete-after-revoke --non-interactive
  success "证书已撤销"
}

# ──────────────────────────────────────────
# 模块 6：设置证书自动续期 (cron)
# ──────────────────────────────────────────
cert_auto_renew() {
  require_root
  local cron_job="0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'"
  local cron_file="/etc/cron.d/certbot-renew"

  echo "$cron_job" > "$cron_file"
  chmod 644 "$cron_file"
  success "已添加自动续期任务（每天凌晨 3:00 执行）"
  echo -e "  文件: ${cron_file}"
  echo -e "  任务: ${cron_job}"
}

# ──────────────────────────────────────────
# 模块 7：创建新站点
# ──────────────────────────────────────────
site_create() {
  require_root
  init_dirs

  local domain="" port=80 root="" proxy="" ssl=false ssl_type="letsencrypt"
  local email="" php=false redirect_www=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--domain)      domain="$2";    shift 2 ;;
      -r|--root)        root="$2";      shift 2 ;;
      -p|--proxy)       proxy="$2";     shift 2 ;;   # 反向代理目标，如 http://127.0.0.1:3000
      --port)           port="$2";      shift 2 ;;
      --ssl)            ssl=true;       shift   ;;
      --ssl-type)       ssl_type="$2";  shift 2 ;;   # letsencrypt | self
      --email)          email="$2";     shift 2 ;;
      --php)            php=true;       shift   ;;
      --redirect-www)   redirect_www=true; shift ;;
      *) die "未知参数: $1" ;;
    esac
  done

  [[ -n "$domain" ]] || { read -rp "请输入域名: " domain; }
  local conf_file="${SITES_AVAILABLE}/${domain}.conf"
  [[ -f "$conf_file" ]] && die "站点配置已存在: ${conf_file}"

  # 默认 webroot
  [[ -z "$root" && -z "$proxy" ]] && root="${WEBROOT_BASE}/${domain}/public"

  # 创建 webroot
  if [[ -n "$root" ]]; then
    mkdir -p "$root"
    cat > "${root}/index.html" <<EOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>${domain}</title></head>
<body><h1>Welcome to ${domain}</h1><p>Nginx 站点已就绪。</p></body>
</html>
EOF
    chown -R www-data:www-data "$(dirname "$root")" 2>/dev/null || \
    chown -R nginx:nginx "$(dirname "$root")" 2>/dev/null || true
  fi

  # ── 生成 Nginx 配置 ──
  {
    echo "# Generated by nginx-manager.sh — $(date)"
    echo "# Domain: ${domain}"

    # HTTP → HTTPS 重定向块
    if $ssl; then
      cat <<BLOCK
server {
    listen 80;
    listen [::]:80;
    server_name ${domain}$(${redirect_www} && echo " www.${domain}" || echo "");
    return 301 https://\$host\$request_uri;
}
BLOCK
    fi

    # 主 server 块
    echo "server {"
    if $ssl; then
      echo "    listen 443 ssl http2;"
      echo "    listen [::]:443 ssl http2;"
    else
      echo "    listen ${port};"
      echo "    listen [::]:${port};"
    fi

    echo "    server_name ${domain}$(${redirect_www} && echo " www.${domain}" || echo "");"

    # SSL 证书路径
    if $ssl; then
      if [[ "$ssl_type" == "self" ]]; then
        local cert_dir="${SELF_CERT_DIR}/${domain}"
        echo "    ssl_certificate     ${cert_dir}/fullchain.pem;"
        echo "    ssl_certificate_key ${cert_dir}/privkey.pem;"
      else
        echo "    ssl_certificate     ${CERT_BASE_DIR}/${domain}/fullchain.pem;"
        echo "    ssl_certificate_key ${CERT_BASE_DIR}/${domain}/privkey.pem;"
      fi
      cat <<'SSL'
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000" always;
SSL
    fi

    echo "    access_log /var/log/nginx/${domain}.access.log;"
    echo "    error_log  /var/log/nginx/${domain}.error.log;"

    # 反向代理 or 静态文件
    if [[ -n "$proxy" ]]; then
      cat <<PROXY
    location / {
        proxy_pass         ${proxy};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
PROXY
    else
      echo "    root  ${root};"
      echo "    index index.html index.htm$(${php} && echo " index.php" || echo "");"
      cat <<'STATIC'
    location / {
        try_files $uri $uri/ =404;
    }
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
STATIC
      # PHP-FPM
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
    fi

    cat <<'COMMON'
    location ~ /\. { deny all; }
}
COMMON
  } > "$conf_file"

  success "站点配置已创建: ${conf_file}"

  # 申请证书
  if $ssl; then
    if [[ "$ssl_type" == "self" ]]; then
      cert_self_signed --domain "$domain"
    else
      [[ -n "$email" ]] || { read -rp "请输入邮箱（用于证书通知）: " email; }
      cert_issue --domain "$domain" --email "$email" --method standalone
    fi
  fi

  # 启用站点
  site_enable "$domain"
}

# ──────────────────────────────────────────
# 模块 8：启用/禁用站点
# ──────────────────────────────────────────
site_enable() {
  require_root
  local domain="${1:-}"
  [[ -n "$domain" ]] || { read -rp "请输入域名: " domain; }
  local conf="${SITES_AVAILABLE}/${domain}.conf"
  [[ -f "$conf" ]] || die "配置文件不存在: ${conf}"

  ln -sf "$conf" "${SITES_ENABLED}/${domain}.conf"
  nginx_reload
  success "站点已启用: ${domain}"
}

site_disable() {
  require_root
  local domain="${1:-}"
  [[ -n "$domain" ]] || { read -rp "请输入域名: " domain; }
  local link="${SITES_ENABLED}/${domain}.conf"
  [[ -L "$link" ]] || die "站点未启用或不存在: ${domain}"

  rm -f "$link"
  nginx_reload
  success "站点已禁用: ${domain}"
}

# ──────────────────────────────────────────
# 模块 9：删除站点
# ──────────────────────────────────────────
site_delete() {
  require_root
  local domain="${1:-}" del_files=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -d|--domain)      domain="$2"; shift 2 ;;
      --delete-files)   del_files=true; shift ;;
      *) domain="$1"; shift ;;
    esac
  done

  [[ -n "$domain" ]] || { read -rp "请输入域名: " domain; }
  confirm "确认删除站点 ${domain} 的配置？" || { info "已取消"; return; }

  rm -f "${SITES_ENABLED}/${domain}.conf"
  rm -f "${SITES_AVAILABLE}/${domain}.conf"

  if $del_files; then
    local webroot="${WEBROOT_BASE}/${domain}"
    [[ -d "$webroot" ]] && rm -rf "$webroot" && info "已删除网站文件: ${webroot}"
  fi

  nginx_reload
  success "站点 ${domain} 已删除"
}

# ──────────────────────────────────────────
# 模块 10：列出所有站点
# ──────────────────────────────────────────
site_list() {
  init_dirs
  echo -e "\n${BOLD}══════════════════════════════════════${NC}"
  printf "${BOLD}%-30s %-10s %-6s${NC}\n" "域名" "状态" "SSL"
  echo -e "${BOLD}──────────────────────────────────────${NC}"

  local found=false
  for conf in "${SITES_AVAILABLE}"/*.conf; do
    [[ -f "$conf" ]] || continue
    found=true
    local domain; domain=$(basename "$conf" .conf)
    local status="禁用"
    [[ -L "${SITES_ENABLED}/${domain}.conf" ]] && status="${GREEN}启用${NC}"

    local has_ssl="否"
    grep -q "ssl_certificate" "$conf" 2>/dev/null && has_ssl="${CYAN}是${NC}"

    printf "%-30s %-18b %-6b\n" "$domain" "$status" "$has_ssl"
  done

  $found || echo "  暂无站点配置"
  echo -e "${BOLD}══════════════════════════════════════${NC}\n"
}

# ──────────────────────────────────────────
# 模块 11：查看站点配置
# ──────────────────────────────────────────
site_info() {
  local domain="${1:-}"
  [[ -n "$domain" ]] || { read -rp "请输入域名: " domain; }
  local conf="${SITES_AVAILABLE}/${domain}.conf"
  [[ -f "$conf" ]] || die "配置不存在: ${conf}"
  echo -e "\n${BOLD}=== ${domain} ===${NC}"
  cat "$conf"
}

# ──────────────────────────────────────────
# 模块 12：Nginx 状态/安装/重启
# ──────────────────────────────────────────
nginx_status()  { systemctl status nginx; }
nginx_restart() { require_root; systemctl restart nginx && success "Nginx 已重启"; }
nginx_install() {
  require_root
  command -v nginx &>/dev/null && { info "Nginx 已安装"; return; }
  local mgr; mgr=$(detect_pkg_manager)
  case $mgr in
    apt) apt-get install -y nginx ;;
    yum|dnf) $mgr install -y nginx ;;
  esac
  systemctl enable --now nginx
  success "Nginx 安装完成"
}

# ──────────────────────────────────────────
# 帮助菜单
# ──────────────────────────────────────────
show_help() {
  cat <<HELP
${BOLD}nginx-manager.sh — Nginx 站点 & SSL 证书管理工具${NC}

${BOLD}用法:${NC}
  $0 <命令> [选项]

${BOLD}证书管理:${NC}
  cert issue        申请 Let's Encrypt 证书
    -d <域名>  -e <邮箱>  -m <方法: nginx|webroot|standalone>  [--wildcard]
  cert self-signed  生成自签名证书
    -d <域名>  [--days <天数，默认3650>]
  cert renew        续期证书（不指定域名则续期所有）
  cert list         列出所有证书
  cert revoke       撤销并删除证书
  cert auto-renew   配置 cron 自动续期

${BOLD}站点管理:${NC}
  site create       创建新站点
    -d <域名>
    -r <网站根目录>（静态）或 -p <代理目标，如 http://127.0.0.1:3000>
    [--ssl]  [--ssl-type letsencrypt|self]  [--email <邮箱>]
    [--php]  [--redirect-www]
  site enable       启用站点
  site disable      禁用站点
  site delete       删除站点  [--delete-files 同时删除网站文件]
  site list         列出所有站点
  site info         查看站点配置

${BOLD}Nginx:${NC}
  nginx install     安装 Nginx
  nginx reload      检查并重载配置
  nginx restart     重启 Nginx
  nginx status      查看运行状态

${BOLD}快速示例:${NC}
  # 创建静态站点并申请 SSL
  $0 site create -d example.com -r /var/www/example.com/public --ssl --email me@example.com

  # 创建反向代理站点（Node.js / Go 等）
  $0 site create -d api.example.com -p http://127.0.0.1:3000 --ssl --email me@example.com

  # 创建自签名 HTTPS 站点
  $0 site create -d dev.local --ssl --ssl-type self

  # 申请泛域名证书（DNS 验证）
  $0 cert issue -d example.com -e me@example.com --wildcard

  # 手动续期指定证书
  $0 cert renew example.com

  # 配置自动续期
  $0 cert auto-renew

HELP
}

# ──────────────────────────────────────────
# 交互式菜单（无参数时显示）
# ──────────────────────────────────────────
interactive_menu() {
  while true; do
    echo -e "\n${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║     Nginx 站点 & 证书管理工具         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo -e " ${CYAN}── 证书 ──${NC}"
    echo "  1) 申请 Let's Encrypt 证书"
    echo "  2) 生成自签名证书"
    echo "  3) 续期证书"
    echo "  4) 列出所有证书"
    echo "  5) 配置自动续期"
    echo -e " ${CYAN}── 站点 ──${NC}"
    echo "  6) 创建新站点"
    echo "  7) 启用站点"
    echo "  8) 禁用站点"
    echo "  9) 删除站点"
    echo " 10) 列出所有站点"
    echo -e " ${CYAN}── Nginx ──${NC}"
    echo " 11) 重载 Nginx 配置"
    echo " 12) 查看 Nginx 状态"
    echo "  0) 退出"
    echo ""
    read -rp "请选择 [0-12]: " choice

    case $choice in
      1)  read -rp "域名: " d; read -rp "邮箱: " e
          echo "验证方式 [nginx/webroot/standalone] (默认nginx): "; read -r m
          cert_issue -d "$d" -e "$e" -m "${m:-nginx}" ;;
      2)  read -rp "域名: " d; cert_self_signed -d "$d" ;;
      3)  read -rp "域名（留空续期所有）: " d; cert_renew "$d" ;;
      4)  cert_list ;;
      5)  cert_auto_renew ;;
      6)  read -rp "域名: " d
          read -rp "网站根目录（留空则输入代理地址）: " r
          if [[ -z "$r" ]]; then
            read -rp "代理目标（如 http://127.0.0.1:3000）: " p
            read -rp "启用 SSL？[y/N]: " s
            if [[ ${s,,} == "y" ]]; then
              read -rp "SSL 类型 [letsencrypt/self]: " st
              read -rp "邮箱: " e
              site_create -d "$d" -p "$p" --ssl --ssl-type "${st:-letsencrypt}" --email "$e"
            else
              site_create -d "$d" -p "$p"
            fi
          else
            read -rp "启用 SSL？[y/N]: " s
            if [[ ${s,,} == "y" ]]; then
              read -rp "SSL 类型 [letsencrypt/self]: " st
              read -rp "邮箱: " e
              site_create -d "$d" -r "$r" --ssl --ssl-type "${st:-letsencrypt}" --email "$e"
            else
              site_create -d "$d" -r "$r"
            fi
          fi ;;
      7)  read -rp "域名: " d; site_enable "$d" ;;
      8)  read -rp "域名: " d; site_disable "$d" ;;
      9)  read -rp "域名: " d; site_delete "$d" ;;
     10)  site_list ;;
     11)  nginx_reload ;;
     12)  nginx_status ;;
      0)  echo "再见！"; exit 0 ;;
      *)  warn "无效选项，请重试" ;;
    esac
  done
}

# ──────────────────────────────────────────
# 入口
# ──────────────────────────────────────────
main() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/nginx-manager.log"
  touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/nginx-manager.log"

  [[ $# -eq 0 ]] && { interactive_menu; exit 0; }

  local cmd="${1:-help}"; shift || true
  local sub="${1:-}"; [[ $# -gt 0 ]] && shift || true

  case "${cmd} ${sub}" in
    "cert issue")       cert_issue "$@" ;;
    "cert self-signed") cert_self_signed "$@" ;;
    "cert renew")       cert_renew "${1:-}" ;;
    "cert list")        cert_list ;;
    "cert revoke")      cert_revoke "${1:-}" ;;
    "cert auto-renew")  cert_auto_renew ;;
    "site create")      site_create "$@" ;;
    "site enable")      site_enable "${1:-}" ;;
    "site disable")     site_disable "${1:-}" ;;
    "site delete")      site_delete "$@" ;;
    "site list")        site_list ;;
    "site info")        site_info "${1:-}" ;;
    "nginx install")    nginx_install ;;
    "nginx reload")     nginx_reload ;;
    "nginx restart")    nginx_restart ;;
    "nginx status")     nginx_status ;;
    "help "*)           show_help ;;
    *)                  show_help ;;
  esac
}

main "$@"
