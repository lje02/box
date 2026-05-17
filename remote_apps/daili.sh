#!/bin/bash
set -euo pipefail

# ==========================================
# 全局环境配置
# ==========================================
SITES_DIR="${SITES_DIR:-/etc/nginx/sites-enabled}"
CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# 所有状态信息输出到 stderr，避免意外混入文件重定向
info()    { echo -e "${BLUE}[信息]${NC} $*" >&2; }
success() { echo -e "${GREEN}[成功]${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*" >&2; }
error()   { echo -e "${RED}[错误]${NC} $*" >&2; }

# ==========================================
# Nginx 安装与环境检测
# ==========================================
check_and_install_nginx() {
    info "正在检查 Nginx 安装状态..."

    if command -v nginx &>/dev/null; then
        success "Nginx 已安装: $(nginx -v 2>&1)"
        return 0
    fi

    warn "未检测到 Nginx，正在尝试自动安装..."

    if [[ -f /etc/debian_version ]]; then
        apt-get update -qq && apt-get install -y nginx
    elif [[ -f /etc/redhat-release ]]; then
        if command -v dnf &>/dev/null; then
            dnf install -y nginx
        else
            yum install -y nginx
        fi
    elif [[ -f /etc/arch-release ]]; then
        pacman -Sy --noconfirm nginx
    else
        error "无法识别的发行版，请手动安装 Nginx 后重新运行脚本。"
        exit 1
    fi

    systemctl enable nginx
    success "Nginx 安装成功: $(nginx -v 2>&1)"
}

# 检测 sub_filter 模块（镜像模式依赖）
check_sub_filter_module() {
    if ! nginx -V 2>&1 | grep -q "http_sub_module"; then
        warn "当前 Nginx 未编译 http_sub_module，多源聚合/镜像模式无法使用 sub_filter。"
        warn "Debian/Ubuntu 可执行: apt install nginx-full"
        echo ""
        read -p "是否仍要继续生成配置文件？[y/N]: " cont
        [[ "$cont" != "y" && "$cont" != "Y" ]] && exit 0
    fi
}

normalize_url() {
    local url="$1"
    [[ ! "$url" =~ ^http:// && ! "$url" =~ ^https:// ]] && url="http://$url"
    echo "$url"
}

# ==========================================
# 智能证书扫描
# ==========================================
CERT_PATH=""
KEY_PATH=""

find_certs_advanced() {
    local domain=$1
    CERT_PATH=""; KEY_PATH=""

    local search_dirs=(
        "$CERT_DIR/$domain"
        "/etc/letsencrypt/live/$domain"
        "/root/.acme.sh/${domain}_ecc"
        "/root/.acme.sh/$domain"
        "/etc/nginx/certs/$domain"
        "/etc/ssl/$domain"
    )

    for dir in "${search_dirs[@]}"; do
        [[ ! -d "$dir" ]] && continue

        local c_names=("fullchain.pem" "fullchain.cer" "server.crt" "$domain.cer" "cert.pem")
        local k_names=("privkey.pem" "server.key" "$domain.key" "cert.key" "key.pem")

        for f in "${c_names[@]}"; do
            [[ -f "$dir/$f" ]] && CERT_PATH="$dir/$f" && break
        done
        for f in "${k_names[@]}"; do
            [[ -f "$dir/$f" ]] && KEY_PATH="$dir/$f" && break
        done

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

# ==========================================
# 通用 SSL 安全块（纯文本输出，供写入配置）
# ==========================================
ssl_block() {
    local cert=$1
    local key=$2
    cat <<EOF
    ssl_certificate $cert;
    ssl_certificate_key $key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:CHACHA20;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
EOF
}

# ==========================================
# 核心配置生成器
# ==========================================
generate_nginx_conf() {
    local mode=$1
    local sub_mode=$2
    local domain_or_port=$3
    local target_or_path=$4
    local conf_file=""

    # ------------------------------------------
    # 模式三：本地静态站点（支持任意端口 + 三种证书模式）
    # ------------------------------------------
    # 参数约定（通过 target_or_path 传递，竖线分隔）：
    #   web_dir|listen_port|ssl_mode|cert_path|key_path|enable_301
    #   ssl_mode: none / auto / manual
    if [[ "$mode" == "3" ]]; then
        local web_dir listen_port ssl_mode _cert _key enable_301
        IFS='|' read -r web_dir listen_port ssl_mode _cert _key enable_301 <<< "$target_or_path"

        conf_file="$SITES_DIR/${domain_or_port}-static.conf"

        if [[ "$ssl_mode" == "auto" || "$ssl_mode" == "manual" ]]; then
            if [[ "$ssl_mode" == "auto" ]]; then
                if find_certs_advanced "$domain_or_port"; then
                    _cert="$CERT_PATH"; _key="$KEY_PATH"
                    success "自动发现证书: $_cert"
                else
                    error "未找到任何证书，请改用手动模式或纯 HTTP 模式。"
                    exit 1
                fi
            else
                success "使用手动指定证书: $_cert"
            fi

            if [[ "$enable_301" == "yes" ]]; then
                cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain_or_port;
    return 301 https://\$host:${listen_port}\$request_uri;
}

server {
    listen ${listen_port} ssl;
    server_name $domain_or_port;
    root $web_dir;
    index index.html index.htm;

$(ssl_block "$_cert" "$_key")

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
            else
                cat > "$conf_file" <<EOF
server {
    listen ${listen_port} ssl;
    server_name $domain_or_port;
    root $web_dir;
    index index.html index.htm;

$(ssl_block "$_cert" "$_key")

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
            fi

        else
            info "配置纯 HTTP 静态站点，端口 ${listen_port}"
            cat > "$conf_file" <<EOF
server {
    listen ${listen_port};
    server_name $domain_or_port;
    root $web_dir;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
        fi

    # ------------------------------------------
    # 模式一：反向代理
    # ------------------------------------------
    elif [[ "$mode" == "1" ]]; then
        conf_file="$SITES_DIR/${domain_or_port}-proxy.conf"
        local target_host
        target_host=$(echo "$target_or_path" | awk -F/ '{print $3}')

        # 证书检测与提示放在文件写入之前，完全独立于重定向
        local has_ssl=false
        local _cert="" _key=""
        if find_certs_advanced "$domain_or_port"; then
            has_ssl=true
            _cert="$CERT_PATH"
            _key="$KEY_PATH"
            success "发现证书，配置反向代理 HTTPS + 301 强转"
        else
            warn "未发现证书，降级为普通 HTTP 反向代理"
        fi

        # local 声明时直接赋空值，避免 set -u 下 unset 报错
        local loc_tmp=""
        loc_tmp=$(mktemp)
        trap '[[ -n "${loc_tmp:-}" ]] && rm -f "$loc_tmp"' RETURN

        # 文件写入块内只有纯配置文本，不含任何 echo/warn/info
        {
            if $has_ssl; then
                cat <<EOF
server {
    listen 80;
    server_name $domain_or_port;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain_or_port;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

$(ssl_block "$_cert" "$_key")
EOF
            else
                cat <<EOF
server {
    listen 80;
    server_name $domain_or_port;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

EOF
            fi

            if [[ "$sub_mode" == "2" ]]; then
                cat <<EOF
    location / {
        proxy_pass $target_or_path;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_ssl_server_name on;
    }
}
EOF
            else
                cat <<EOF
    location / {
        proxy_pass $target_or_path;
        proxy_set_header Host $target_host;
        proxy_set_header Referer $target_or_path;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
        sub_filter "</head>" "<meta name='referrer' content='no-referrer'></head>";
        sub_filter "$target_host" "$domain_or_port";
        sub_filter "https://$target_host" "https://$domain_or_port";
        sub_filter "http://$target_host" "https://$domain_or_port";
EOF
                local count=1
                while true; do
                    read -p $'\033[1;33m请输入额外的资源URL（回车结束）: \033[0m' res_url
                    [[ -z "$res_url" ]] && break
                    res_url=$(normalize_url "$res_url")
                    local res_host
                    res_host=$(echo "$res_url" | awk -F/ '{print $3}')
                    local key="_res_${count}"
                    cat <<EOF
        sub_filter "$res_host" "$domain_or_port/$key";
        sub_filter "https://$res_host" "https://$domain_or_port/$key";
        sub_filter "http://$res_host" "https://$domain_or_port/$key";
EOF
                    cat >> "$loc_tmp" <<LOCEOF

    location /$key/ {
        rewrite ^/$key/(.*) /\$1 break;
        proxy_pass $res_url;
        proxy_set_header Host $res_host;
        proxy_set_header Referer $res_url;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
    }
LOCEOF
                    ((count++))
                done

                cat <<EOF
        sub_filter_once off;
        sub_filter_types *;
    }
EOF
                cat "$loc_tmp"
                echo "}"
            fi
        } > "$conf_file"

    # ------------------------------------------
    # 模式二：正向代理
    # ------------------------------------------
    elif [[ "$mode" == "2" ]]; then
        conf_file="$SITES_DIR/forward-proxy-${domain_or_port}.conf"
        info "在端口 $domain_or_port 上配置 HTTP 正向代理"
        warn "Nginx 原生仅支持 HTTP 正向代理，不支持 HTTPS CONNECT 隧道。"
        warn "如需完整 HTTPS 支持，请改用 Squid 或 3proxy。"
        cat > "$conf_file" <<EOF
# 仅支持 HTTP 正向代理，不支持 HTTPS CONNECT 隧道
# 如需 HTTPS 支持，请改用 Squid 或 3proxy
server {
    listen $domain_or_port;
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
    fi

    success "配置已写入: $conf_file"

    info "正在执行 nginx -t ..."
    if nginx -t 2>&1 >&2; then
        success "配置语法正确，正在 reload Nginx..."
        systemctl reload nginx
        success "Nginx 已成功加载新配置。"
    else
        error "配置存在语法错误，Nginx 未 reload，请检查上方错误信息。"
        error "有问题的配置文件: $conf_file"
        exit 1
    fi
}

# ==========================================
# 主交互入口
# ==========================================
create_site_wizard() {
    clear
    echo -e "${GREEN}======================================"
    echo -e "     Nginx 站点与代理配置终极向导     "
    echo -e "======================================${NC}"

    check_and_install_nginx
    echo ""

    echo "1. 静态站点托管（自定义端口 / 自动或手动证书 / 纯 HTTP）"
    echo "2. 反向代理模式（网站镜像 / 多源聚合 / 端口穿透）"
    echo "3. 正向代理模式（仅 HTTP，HTTPS 请用 Squid/3proxy）"
    echo ""
    read -p "请选择业务类型 [1-3]: " main_mode

    case "$main_mode" in
        1)
            read -p "请输入你的域名或 server_name (如: www.yourdomain.com): " domain
            [[ -z "$domain" ]] && { error "域名不能为空"; exit 1; }

            read -p "请输入网页文件根目录 (绝对路径，如: /var/www/my-site): " web_dir
            [[ -z "$web_dir" ]] && { error "根目录不能为空"; exit 1; }

            # 证书模式
            echo ""
            echo "请选择 SSL/证书模式:"
            echo "  1. 自动扫描证书（根据域名查找常见路径）"
            echo "  2. 手动指定证书路径"
            echo "  3. 纯 HTTP，不使用证书"
            read -p "选择 [1-3，默认 1]: " ssl_choice
            [[ -z "$ssl_choice" ]] && ssl_choice="1"

            _cert=""; _key=""; ssl_mode=""; listen_port=""; enable_301="no"

            case "$ssl_choice" in
                1)
                    ssl_mode="auto"
                    read -p "请输入 SSL 监听端口 (默认 443): " listen_port
                    [[ -z "$listen_port" ]] && listen_port="443"
                    read -p "是否开启 HTTP→HTTPS 301 强转？[Y/n]: " r301
                    [[ "$r301" != "n" && "$r301" != "N" ]] && enable_301="yes"
                    ;;
                2)
                    ssl_mode="manual"
                    read -p "请输入证书文件路径 (fullchain.pem): " _cert
                    [[ -z "$_cert" || ! -f "$_cert" ]] && { error "证书文件不存在: $_cert"; exit 1; }
                    read -p "请输入私钥文件路径 (privkey.pem): " _key
                    [[ -z "$_key" || ! -f "$_key" ]] && { error "私钥文件不存在: $_key"; exit 1; }
                    read -p "请输入 SSL 监听端口 (默认 443): " listen_port
                    [[ -z "$listen_port" ]] && listen_port="443"
                    read -p "是否开启 HTTP→HTTPS 301 强转？[Y/n]: " r301
                    [[ "$r301" != "n" && "$r301" != "N" ]] && enable_301="yes"
                    ;;
                3)
                    ssl_mode="none"
                    read -p "请输入 HTTP 监听端口 (默认 80): " listen_port
                    [[ -z "$listen_port" ]] && listen_port="80"
                    ;;
                *)
                    error "无效选项"; exit 1 ;;
            esac

            # 将扩展参数打包为竖线分隔字符串传入生成器
            packed="${web_dir}|${listen_port}|${ssl_mode}|${_cert}|${_key}|${enable_301}"
            generate_nginx_conf "3" "" "$domain" "$packed"
            ;;
        2)
            read -p "请输入解析好的域名: " domain
            [[ -z "$domain" ]] && { error "域名不能为空"; exit 1; }
            echo ""
            echo "请选择反向代理子模式:"
            echo "  1. 多源聚合 / 高级镜像（含 sub_filter）"
            echo "  2. 普通反代 / 端口透传"
            read -p "选择模式 [1-2，默认 1]: " sub_mode
            [[ -z "$sub_mode" ]] && sub_mode="1"

            if [[ "$sub_mode" == "1" ]]; then
                check_sub_filter_module
                read -p "请输入要镜像的目标网站 URL: " target_url
                target_url=$(normalize_url "$target_url")
                generate_nginx_conf "1" "1" "$domain" "$target_url"
            else
                read -p "请输入后端目标 IP:端口 (如: 127.0.0.1:8080): " backend
                backend=$(normalize_url "$backend")
                generate_nginx_conf "1" "2" "$domain" "$backend"
            fi
            ;;
        3)
            read -p "请输入正向代理监听的端口 (默认 8888): " f_port
            [[ -z "$f_port" ]] && f_port="8888"
            generate_nginx_conf "2" "" "$f_port" ""
            ;;
        *)
            error "无效选项"; exit 1
            ;;
    esac
}

# 启动向导
create_site_wizard
