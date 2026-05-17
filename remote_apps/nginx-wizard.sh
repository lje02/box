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

# ==========================================
# Nginx 安装与环境检测
# ==========================================
check_and_install_nginx() {
    echo -e "${BLUE}[检测]${NC} 正在检查 Nginx 安装状态..."

    if command -v nginx &>/dev/null; then
        echo -e "${GREEN}[已安装]${NC} $(nginx -v 2>&1)"
        return 0
    fi

    echo -e "${YELLOW}[未检测到 Nginx]${NC} 正在尝试自动安装..."

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
        echo -e "${RED}[错误]${NC} 无法识别的发行版，请手动安装 Nginx 后重新运行脚本。"
        exit 1
    fi

    systemctl enable nginx
    echo -e "${GREEN}[完成]${NC} Nginx 安装成功: $(nginx -v 2>&1)"
}

# 检测 sub_filter 模块（镜像模式依赖）
check_sub_filter_module() {
    if ! nginx -V 2>&1 | grep -q "http_sub_module"; then
        echo -e "${RED}[警告]${NC} 当前 Nginx 未编译 http_sub_module，多源聚合/镜像模式无法使用 sub_filter。"
        echo -e "       请使用带该模块的 Nginx 版本，或在 Debian/Ubuntu 上安装 nginx-full："
        echo -e "       ${YELLOW}apt install nginx-full${NC}"
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

        # 模糊兜底：搜索目录下任意含证书内容的文件
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
# 通用 SSL 安全块（注入到各模式中）
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
    local mode=$1        # 1: 反向代理, 2: 正向代理, 3: 本地静态站
    local sub_mode=$2    # 子模式
    local domain_or_port=$3
    local target_or_path=$4

    # 修复：配置文件直接写入 SITES_DIR 根目录，避免子目录不被 include 读取
    local conf_file=""

    # ------------------------------------------
    # 模式三：本地静态站点
    # ------------------------------------------
    if [[ "$mode" == "3" ]]; then
        conf_file="$SITES_DIR/${domain_or_port}-static.conf"
        find_certs_advanced "$domain_or_port" && local has_ssl=true || local has_ssl=false

        if $has_ssl; then
            echo -e "${GREEN}[证书发现]${NC} 配置静态站点 HTTPS + 301 强转..."
            cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain_or_port;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $domain_or_port;
    root $target_or_path;
    index index.html index.htm;

$(ssl_block "$CERT_PATH" "$KEY_PATH")

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
        else
            echo -e "${YELLOW}[未发现证书]${NC} 降级为普通 HTTP 静态站点..."
            cat > "$conf_file" <<EOF
server {
    listen 80;
    server_name $domain_or_port;
    root $target_or_path;
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
        find_certs_advanced "$domain_or_port" && local has_ssl=true || local has_ssl=false

        # 使用 mktemp 避免临时文件竞态
        local loc_tmp
        loc_tmp=$(mktemp)
        trap 'rm -f "$loc_tmp"' RETURN

        {
            if $has_ssl; then
                echo -e "${GREEN}[证书发现]${NC} 配置反向代理 HTTPS + 301 强转..."
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

$(ssl_block "$CERT_PATH" "$KEY_PATH")
EOF
            else
                echo -e "${YELLOW}[未发现证书]${NC} 降级为普通 HTTP 反向代理..."
                cat <<EOF
server {
    listen 80;
    server_name $domain_or_port;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
EOF
            fi

            # --- 普通反代/端口透传 ---
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
            # --- 多源聚合/镜像 ---
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
                echo -e "${YELLOW}进入多源资源聚合流（直接回车结束）${NC}"
                local count=1
                while true; do
                    read -p "请输入额外的资源URL（回车结束）: " res_url
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
                    cat >> "$loc_tmp" <<EOF

    location /$key/ {
        rewrite ^/$key/(.*) /\$1 break;
        proxy_pass $res_url;
        proxy_set_header Host $res_host;
        proxy_set_header Referer $res_url;
        proxy_set_header Accept-Encoding "";
        proxy_ssl_server_name on;
    }
EOF
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
        echo -e "${GREEN}[正向代理]${NC} 在端口 $domain_or_port 上配置 HTTP 正向代理..."
        echo -e "${YELLOW}[说明]${NC} Nginx 原生仅支持 HTTP 正向代理。"
        echo -e "       HTTPS 请求需要 CONNECT 隧道支持，标准 Nginx 不具备此能力。"
        echo -e "       如需完整的 HTTPS 正向代理，请改用 Squid 或 3proxy。"
        cat > "$conf_file" <<EOF
# ⚠️  仅支持 HTTP 正向代理，不支持 HTTPS CONNECT 隧道
# 如需 HTTPS 支持，请改用 Squid (squid.conf) 或 3proxy
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

    echo ""
    echo -e "${GREEN}==> 配置已写入: $conf_file${NC}"

    # 配置语法验证 + 自动 reload
    echo -e "${BLUE}[验证]${NC} 正在执行 nginx -t ..."
    if nginx -t 2>&1; then
        echo -e "${GREEN}[通过]${NC} 配置语法正确，正在 reload Nginx..."
        systemctl reload nginx && echo -e "${GREEN}[完成]${NC} Nginx 已成功加载新配置。"
    else
        echo -e "${RED}[失败]${NC} 配置存在语法错误，Nginx 未 reload，请检查上方错误信息。"
        echo -e "       有问题的配置文件: $conf_file"
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

    echo "1. 静态站点托管（本地 HTML 目录，自带 HTTPS 301 强转）"
    echo "2. 反向代理模式（网站镜像 / 多源聚合 / 端口穿透）"
    echo "3. 正向代理模式（仅 HTTP，HTTPS 请用 Squid/3proxy）"
    echo ""
    read -p "请选择业务类型 [1-3]: " main_mode

    case "$main_mode" in
        1)
            read -p "请输入你的域名 (如: www.yourdomain.com): " domain
            [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }
            read -p "请输入网页文件根目录 (绝对路径，如: /var/www/my-site): " web_dir
            [[ -z "$web_dir" ]] && { echo -e "${RED}根目录不能为空${NC}"; exit 1; }
            generate_nginx_conf "3" "" "$domain" "$web_dir"
            ;;
        2)
            read -p "请输入解析好的域名: " domain
            [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空${NC}"; exit 1; }
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
            echo -e "${RED}无效选项${NC}"; exit 1
            ;;
    esac
}

# 启动向导
create_site_wizard
