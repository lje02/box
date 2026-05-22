#!/bin/bash
# ============================================================
#  Docker + Docker Compose 安装 & 热门应用一键部署脚本
#  支持：WordPress / Nextcloud / Gitea / Uptime Kuma /
#        Portainer / phpMyAdmin / Redis Commander / MinIO /
#        Lsky Pro / EasyImage / AList
#  用法：sudo bash setup-docker-apps.sh [选项]
# ============================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $*"; }
warn()   { echo -e "${YELLOW}[!]${NC} $*"; }
error()  { echo -e "${RED}[✘]${NC} $*"; exit 1; }
info()   { echo -e "${BLUE}[i]${NC} $*"; }
header() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

BASE_DIR="/opt/docker-apps"
mkdir -p "$BASE_DIR"

[[ $EUID -ne 0 ]] && error "请使用 root 或 sudo 运行此脚本"

ALL_APPS=(
    wordpress
    nextcloud
    gitea
    uptime-kuma
    portainer
    phpmyadmin
    redis-commander
    minio
    lskypro
    easyimage
    alist
)

declare -A APP_DESC=(
    [wordpress]="WordPress          博客/CMS（含 MariaDB + Redis）"
    [nextcloud]="Nextcloud          私有网盘（含 MariaDB + Redis）"
    [gitea]="Gitea              Git 代码托管（含 PostgreSQL）"
    [uptime-kuma]="Uptime Kuma        服务监控面板"
    [portainer]="Portainer CE       Docker 可视化管理"
    [phpmyadmin]="phpMyAdmin         MySQL/MariaDB Web 管理"
    [redis-commander]="Redis Commander    Redis GUI"
    [minio]="MinIO              S3 兼容对象存储"
    [lskypro]="Lsky Pro           兰空图床（含 MariaDB）"
    [easyimage]="EasyImage          轻量图床"
    [alist]="AList              多存储文件列表/网盘挂载"
)

declare -A APP_PORT=(
    [wordpress]="http://127.0.0.1:8080"
    [nextcloud]="http://127.0.0.1:8081"
    [gitea]="http://127.0.0.1:3000"
    [uptime-kuma]="http://127.0.0.1:3001"
    [portainer]="http://127.0.0.1:9000"
    [phpmyadmin]="http://127.0.0.1:8082"
    [redis-commander]="http://127.0.0.1:8083"
    [minio]="http://127.0.0.1:9001 (控制台)"
    [lskypro]="http://127.0.0.1:8085"
    [easyimage]="http://127.0.0.1:8086"
    [alist]="http://127.0.0.1:5244"
)

# ============================================================
# 交互式主菜单
# ============================================================
interactive_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
        echo -e "║          🐳  Docker 应用部署管理工具                        ║"
        echo -e "╠══════════════════════════════════════════════════════════════╣"
        echo -e "║  1) 安装 / 更新 Docker                                       ║"
        echo -e "║  2) 选择应用部署（多选）                                     ║"
        echo -e "║  3) 部署全部应用                                              ║"
        echo -e "║  4) 卸载应用                                                  ║"
        echo -e "║  5) 备份应用                                                  ║"
        echo -e "║  6) 查看已部署应用状态                                        ║"
        echo -e "║  7) 更新应用镜像                                              ║"
        echo -e "║  8) 更新应用组件（PHP/DB/Redis 等）                          ║"
        echo -e "║  0) 退出                                                      ║"
        echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -rp "请选择操作 [0-8]: " choice

        case "$choice" in
            1) check_system; install_docker ;;
            2) ensure_docker; menu_select_apps ;;
            3) check_system; ensure_docker; deploy_all_apps ;;
            4) menu_uninstall_app ;;
            5) menu_backup_app ;;
            6) list_apps ;;
            7) menu_update_images ;;
            8) menu_update_components ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-8" ;;
        esac
    done
}

ensure_docker() {
    if ! command -v docker &>/dev/null; then
        warn "未检测到 Docker，自动执行安装..."
        check_system
        install_docker
    fi
}

menu_select_apps() {
    local selected=()
    while true; do
        echo ""
        echo -e "${CYAN}${BOLD}── 选择要部署的应用（输入编号切换选中，支持多选）──${NC}"
        echo ""
        local i=1
        for app in "${ALL_APPS[@]}"; do
            local mark=" "
            for s in "${selected[@]:-}"; do
                [[ "$s" == "$app" ]] && mark="${GREEN}✔${NC}" && break
            done
            printf "  %2d) [%b] %s\n" "$i" "$mark" "${APP_DESC[$app]}"
            ((i++))
        done
        echo ""
        echo -e "   a) 全选    c) 清空选择    d) 开始部署    q) 返回"
        echo ""
        read -rp "请输入编号或操作: " input

        case "$input" in
            [0-9]|[0-9][0-9])
                local idx=$((input - 1))
                if [[ $idx -ge 0 && $idx -lt ${#ALL_APPS[@]} ]]; then
                    local app="${ALL_APPS[$idx]}"
                    local found=0
                    local new_selected=()
                    for s in "${selected[@]:-}"; do
                        if [[ "$s" == "$app" ]]; then
                            found=1
                        else
                            new_selected+=("$s")
                        fi
                    done
                    if [[ $found -eq 0 ]]; then
                        selected+=("$app")
                        info "已选中: $app"
                    else
                        selected=("${new_selected[@]:-}")
                        info "已取消: $app"
                    fi
                else
                    warn "编号超出范围"
                fi
                ;;
            a) selected=("${ALL_APPS[@]}"); info "已全选 ${#ALL_APPS[@]} 个应用" ;;
            c) selected=(); info "已清空选择" ;;
            d)
                if [[ ${#selected[@]:-0} -eq 0 ]]; then
                    warn "请至少选择一个应用"
                else
                    echo ""
                    echo -e "${CYAN}即将部署以下应用:${NC}"
                    for app in "${selected[@]}"; do echo "  - ${APP_DESC[$app]}"; done
                    echo ""
                    read -rp "确认部署？[y/N]: " confirm
                    if [[ "${confirm,,}" == "y" ]]; then
                        for app in "${selected[@]}"; do
                            "deploy_${app//-/_}" || warn "$app 部署失败，继续下一个..."
                        done
                        print_summary "${selected[@]}"
                    fi
                    return
                fi
                ;;
            q) return ;;
            *) warn "无效输入" ;;
        esac
    done
}

menu_uninstall_app() {
    echo ""
    echo -e "${CYAN}${BOLD}── 已部署的应用 ──${NC}"
    local deployed=()
    for app in "${ALL_APPS[@]}"; do
        [[ -f "$BASE_DIR/$app/docker-compose.yml" ]] && deployed+=("$app")
    done
    if [[ ${#deployed[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi
    local i=1
    for app in "${deployed[@]}"; do printf "  %2d) %s\n" "$i" "${APP_DESC[$app]}"; ((i++)); done
    echo ""
    read -rp "请输入要卸载的编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    if [[ $idx -ge 0 && $idx -lt ${#deployed[@]} ]]; then
        local app="${deployed[$idx]}"
        read -rp "确认卸载 $app 并删除所有数据？[y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] && uninstall_app "$app" || info "已取消"
    else
        warn "编号无效"
    fi
}

menu_backup_app() {
    echo ""
    echo -e "${CYAN}${BOLD}── 已部署的应用 ──${NC}"
    local deployed=()
    for app in "${ALL_APPS[@]}"; do
        [[ -f "$BASE_DIR/$app/docker-compose.yml" ]] && deployed+=("$app")
    done
    if [[ ${#deployed[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi
    local i=1
    for app in "${deployed[@]}"; do printf "  %2d) %s\n" "$i" "${APP_DESC[$app]}"; ((i++)); done
    echo ""
    read -rp "请输入要备份的编号（0 返回）: " input
    [[ "$input" == "0" ]] && return
    local idx=$((input - 1))
    if [[ $idx -ge 0 && $idx -lt ${#deployed[@]} ]]; then
        backup_app "${deployed[$idx]}"
    else
        warn "编号无效"
    fi
}

# ============================================================
# 更新镜像菜单
# ============================================================
menu_update_images() {
    echo ""
    echo -e "${CYAN}${BOLD}── 更新应用镜像 ──${NC}"
    echo ""
    echo -e "  1) 更新指定应用镜像"
    echo -e "  2) 更新全部已部署应用镜像"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-2]: " choice

    case "$choice" in
        1)
            local deployed=()
            for app in "${ALL_APPS[@]}"; do
                [[ -f "$BASE_DIR/$app/docker-compose.yml" ]] && deployed+=("$app")
            done
            if [[ ${#deployed[@]} -eq 0 ]]; then warn "没有已部署的应用"; return; fi
            local i=1
            for app in "${deployed[@]}"; do printf "  %2d) %s\n" "$i" "${APP_DESC[$app]}"; ((i++)); done
            echo ""
            read -rp "请输入要更新的编号（0 返回）: " input
            [[ "$input" == "0" ]] && return
            local idx=$((input - 1))
            if [[ $idx -ge 0 && $idx -lt ${#deployed[@]} ]]; then
                update_app_images "${deployed[$idx]}"
            else
                warn "编号无效"
            fi
            ;;
        2)
            local updated=0
            for app in "${ALL_APPS[@]}"; do
                if [[ -f "$BASE_DIR/$app/docker-compose.yml" ]]; then
                    update_app_images "$app"
                    ((updated++))
                fi
            done
            [[ $updated -eq 0 ]] && warn "没有已部署的应用"
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

# ── 更新单个应用的所有镜像并重启 ─────────────────────────────
update_app_images() {
    local app="$1"
    local dir="$BASE_DIR/$app"
    [[ ! -f "$dir/docker-compose.yml" ]] && warn "$app 未部署，跳过" && return

    header "更新 $app 镜像"
    info "拉取 $app 最新镜像..."
    cd "$dir"
    if docker compose pull; then
        info "镜像拉取完成，重启服务..."
        if docker compose up -d --remove-orphans; then
            log "$app 已使用最新镜像重启"
        else
            warn "$app 重启失败，请手动检查"
        fi
    else
        warn "$app 镜像拉取失败，保持当前版本运行"
    fi
    cd - > /dev/null

    local dangling
    dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if [[ "$dangling" -gt 0 ]]; then
        info "清理 $dangling 个悬空旧镜像..."
        docker image prune -f > /dev/null
    fi
}

# ============================================================
# 更新组件菜单
# ============================================================
menu_update_components() {
    echo ""
    echo -e "${CYAN}${BOLD}── 更新应用组件（PHP / MariaDB / PostgreSQL / Redis / Nginx）──${NC}"
    echo ""
    echo -e "  说明: 修改 docker-compose.yml 中的镜像标签后自动拉取并重启。"
    echo -e "        PostgreSQL 大版本升级需手动迁移数据，脚本会提示确认。"
    echo ""
    echo -e "  1) 升级 WordPress PHP（php8.3 → php8.4-fpm-alpine）"
    echo -e "  2) 升级 Nextcloud（production → stable-fpm-alpine）"
    echo -e "  3) 统一所有 MariaDB → mariadb:11"
    echo -e "  4) 升级所有 PostgreSQL → postgres:17-alpine（需手动迁移）"
    echo -e "  5) 统一所有 Redis → redis:7-alpine"
    echo -e "  6) 统一所有 Nginx → nginx:alpine"
    echo -e "  7) 批量执行以上全部"
    echo -e "  0) 返回"
    echo ""
    read -rp "请选择 [0-7]: " choice

    case "$choice" in
        1) update_component_php_wordpress ;;
        2) update_component_nextcloud ;;
        3) update_component_mariadb ;;
        4) update_component_postgres ;;
        5) update_component_redis ;;
        6) update_component_nginx ;;
        7)
            update_component_php_wordpress
            update_component_nextcloud
            update_component_mariadb
            update_component_postgres
            update_component_redis
            update_component_nginx
            log "全部组件更新操作完成"
            ;;
        0) return ;;
        *) warn "无效输入" ;;
    esac
}

update_component_php_wordpress() {
    local dir="$BASE_DIR/wordpress"
    [[ ! -f "$dir/docker-compose.yml" ]] && warn "WordPress 未部署，跳过" && return
    header "升级 WordPress PHP 版本"
    local current new_tag="wordpress:php8.4-fpm-alpine"
    current=$(grep -oP 'wordpress:php[\d.]+-fpm-alpine' "$dir/docker-compose.yml" | head -1)
    if [[ "$current" == "$new_tag" ]]; then
        info "WordPress 已是 $new_tag，无需升级"; return
    fi
    info "当前: $current  →  目标: $new_tag"
    read -rp "确认升级？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }
    sed -i "s|${current}|${new_tag}|g" "$dir/docker-compose.yml"
    update_app_images "wordpress"
    log "WordPress PHP 已升级到 php8.4-fpm-alpine"
}

update_component_nextcloud() {
    local dir="$BASE_DIR/nextcloud"
    [[ ! -f "$dir/docker-compose.yml" ]] && warn "Nextcloud 未部署，跳过" && return
    header "升级 Nextcloud 镜像标签"
    local new_tag="nextcloud:stable-fpm-alpine"
    local current
    current=$(grep -oP 'nextcloud:[a-z0-9.\-]+fpm-alpine' "$dir/docker-compose.yml" | head -1)
    if [[ "$current" == "$new_tag" ]]; then
        info "Nextcloud 已是 $new_tag，无需修改"; return
    fi
    info "当前: $current  →  目标: $new_tag"
    warn "注意：版本跨越升级前请先备份数据"
    read -rp "确认升级？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }
    sed -i "s|${current}|${new_tag}|g" "$dir/docker-compose.yml"
    update_app_images "nextcloud"
    log "Nextcloud 镜像标签已更新为 $new_tag"
}

update_component_mariadb() {
    header "统一 MariaDB → mariadb:11"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        local dir="$BASE_DIR/$app"
        [[ ! -f "$dir/docker-compose.yml" ]] && continue
        if grep -q 'mariadb:' "$dir/docker-compose.yml"; then
            local current
            current=$(grep -oP 'mariadb:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" != "mariadb:11" ]]; then
                info "[$app] $current → mariadb:11"
                sed -i "s|${current}|mariadb:11|g" "$dir/docker-compose.yml"
                (cd "$dir" && docker compose pull db lskypro-db 2>/dev/null; docker compose up -d 2>/dev/null) || warn "$app 重启失败"
                ((updated++))
            else
                info "[$app] MariaDB 已是 11，跳过"
            fi
        fi
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已更新 $updated 个 MariaDB 实例"
}

update_component_postgres() {
    header "升级 PostgreSQL → postgres:17-alpine"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        local dir="$BASE_DIR/$app"
        [[ ! -f "$dir/docker-compose.yml" ]] && continue
        if grep -q 'postgres:' "$dir/docker-compose.yml"; then
            local current
            current=$(grep -oP 'postgres:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" != "postgres:17-alpine" ]]; then
                warn "[$app] PostgreSQL 大版本升级（$current → postgres:17-alpine）需手动迁移数据！"
                warn "参考: https://www.postgresql.org/docs/current/upgrading.html"
                read -rp "仍要修改 $app 的镜像标签？[y/N]: " confirm
                if [[ "${confirm,,}" == "y" ]]; then
                    sed -i "s|${current}|postgres:17-alpine|g" "$dir/docker-compose.yml"
                    warn "[$app] 标签已修改，请手动完成数据库迁移后再执行 docker compose up -d"
                    ((updated++))
                fi
            else
                info "[$app] PostgreSQL 已是 17-alpine，跳过"
            fi
        fi
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已修改 $updated 个 PostgreSQL 实例标签"
}

update_component_redis() {
    header "统一 Redis → redis:7-alpine"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        local dir="$BASE_DIR/$app"
        [[ ! -f "$dir/docker-compose.yml" ]] && continue
        if grep -q 'redis:' "$dir/docker-compose.yml"; then
            local current
            current=$(grep -oP 'redis:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" != "redis:7-alpine" ]]; then
                info "[$app] $current → redis:7-alpine"
                sed -i "s|${current}|redis:7-alpine|g" "$dir/docker-compose.yml"
                (cd "$dir" && docker compose pull redis 2>/dev/null && docker compose up -d redis 2>/dev/null) || warn "$app Redis 重启失败"
                ((updated++))
            else
                info "[$app] Redis 已是 7-alpine，跳过"
            fi
        fi
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已更新 $updated 个 Redis 实例"
}

update_component_nginx() {
    header "统一 Nginx → nginx:alpine"
    local updated=0
    for app in "${ALL_APPS[@]}"; do
        local dir="$BASE_DIR/$app"
        [[ ! -f "$dir/docker-compose.yml" ]] && continue
        if grep -q 'nginx:' "$dir/docker-compose.yml"; then
            local current
            current=$(grep -oP 'nginx:[^\s"]+' "$dir/docker-compose.yml" | head -1)
            if [[ "$current" != "nginx:alpine" ]]; then
                info "[$app] $current → nginx:alpine"
                sed -i "s|${current}|nginx:alpine|g" "$dir/docker-compose.yml"
                (cd "$dir" && docker compose pull nginx 2>/dev/null && docker compose up -d nginx 2>/dev/null) || warn "$app Nginx 重启失败"
                ((updated++))
            else
                info "[$app] Nginx 已是 alpine，跳过"
            fi
        fi
    done
    [[ $updated -eq 0 ]] && info "无需更新" || log "已更新 $updated 个 Nginx 实例"
}

deploy_all_apps() {
    echo ""
    echo -e "${YELLOW}即将部署全部 ${#ALL_APPS[@]} 个应用，这会占用大量磁盘和内存。${NC}"
    read -rp "确认继续？[y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && { info "已取消"; return; }
    for app in "${ALL_APPS[@]}"; do
        "deploy_${app//-/_}" || warn "$app 部署失败，继续下一个..."
    done
    print_summary "${ALL_APPS[@]}"
}

usage() {
    cat <<EOF
用法: $0 [选项]
选项:
  无参数              进入交互式菜单（推荐）
  --install           仅安装 / 更新 Docker
  --deploy APP        仅部署指定应用（自动安装 Docker）
  --uninstall APP     卸载指定应用并删除数据
  --backup APP        备份指定应用到 /tmp
  --update APP        更新指定应用镜像并重启
  --update-all        更新全部已部署应用镜像
  --list              列出所有可管理的应用及状态
  --all               部署全部应用（非交互，适合自动化）
  --help              显示此帮助

可部署的应用:
  wordpress, nextcloud, gitea, uptime-kuma, portainer
  phpmyadmin, redis-commander, minio, lskypro, easyimage, alist

示例:
  sudo bash $0                        # 进入交互菜单
  sudo bash $0 --deploy alist         # 仅部署 AList
  sudo bash $0 --update nextcloud     # 更新 Nextcloud 镜像
  sudo bash $0 --update-all           # 更新全部已部署应用镜像
  sudo bash $0 --list                 # 查看应用状态
EOF
    exit 0
}

list_apps() {
    echo ""
    echo -e "${CYAN}${BOLD}── 应用状态 ──${NC}"
    echo ""
    local found=0
    for app in "${ALL_APPS[@]}"; do
        local dir="$BASE_DIR/$app"
        if [[ -f "$dir/docker-compose.yml" ]]; then
            found=1
            local status total
            status=$(cd "$dir" && docker compose ps --status running --quiet 2>/dev/null | wc -l || echo "0")
            total=$(cd "$dir" && docker compose ps --quiet 2>/dev/null | wc -l || echo "0")
            if [[ "$status" -gt 0 ]]; then
                echo -e "  ${GREEN}[运行中]${NC} $app  (${status}/${total} 容器)  → ${APP_PORT[$app]}"
            else
                echo -e "  ${RED}[已停止]${NC} $app"
            fi
        fi
    done
    [[ $found -eq 0 ]] && warn "尚未部署任何应用"
    echo ""
}

check_system() {
    local mem disk
    mem=$(free -m | awk '/^Mem:/{print $2}')
    disk=$(df -m /opt | awk 'NR==2{print $4}')
    [[ "$mem" -lt 1024 ]] && warn "内存不足 1GB（当前 ${mem}MB），可能影响性能"
    [[ "$disk" -lt 5120 ]] && warn "磁盘空间不足 5GB（剩余 ${disk}MB），建议扩展空间"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) ;;
            *) error "仅支持 Ubuntu/Debian 系统，当前系统: $ID" ;;
        esac
    else
        error "无法检测系统发行版"
    fi
}

run_compose() {
    local dir="$1" name="$2"
    cd "$dir"
    if docker compose up -d; then
        log "$name 启动成功"
    else
        cd - > /dev/null
        error "无法启动 $name，请检查 $dir 目录"
    fi
    cd - > /dev/null
}

# ============================================================
# 安装 / 更新 Docker
# ============================================================
install_docker() {
    header "安装 / 更新 Docker Engine"
    if command -v docker &>/dev/null; then
        local CURRENT
        CURRENT=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")
        warn "检测到已安装 Docker（版本 $CURRENT），执行更新..."
    fi
    . /etc/os-release
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${ID} $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    local DOCKER_VER COMPOSE_VER
    DOCKER_VER=$(docker version --format '{{.Server.Version}}')
    COMPOSE_VER=$(docker compose version --short)
    log "Docker         $DOCKER_VER"
    log "Docker Compose $COMPOSE_VER"
    if command -v ufw &>/dev/null && ufw status | grep -q inactive; then
        warn "检测到 ufw 未启用，建议执行: ufw enable && ufw allow 22/tcp"
    fi
}

randpw() {
    local len="${1:-24}"
    (set +o pipefail; tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' </dev/urandom | head -c "$len")
    echo
}

backup_app() {
    local app="$1"
    local dir="$BASE_DIR/$app"
    local backup_file="/tmp/${app}_$(date +%Y%m%d_%H%M%S).tar.gz"
    [[ ! -d "$dir" ]] && error "应用 $app 未部署，目录 $dir 不存在"
    header "备份 $app"
    (cd "$dir" && docker compose stop 2>/dev/null) || true
    tar -czf "$backup_file" -C "$(dirname "$dir")" "$(basename "$dir")"
    (cd "$dir" && docker compose start 2>/dev/null) || true
    local size
    size=$(du -h "$backup_file" | cut -f1)
    log "已备份 $app 到 $backup_file（大小: $size）"
}

uninstall_app() {
    local app="$1"
    local dir="$BASE_DIR/$app"
    [[ ! -d "$dir" ]] && error "应用 $app 未部署，目录 $dir 不存在"
    header "卸载 $app"
    if [[ -f "$dir/docker-compose.yml" ]]; then
        (cd "$dir" && docker compose down -v --remove-orphans) || warn "容器停止失败，继续清理..."
    fi
    if [[ -f "$dir/.env" ]]; then
        local bak="/tmp/${app}_env_backup_$(date +%Y%m%d_%H%M%S)"
        cp "$dir/.env" "$bak" 2>/dev/null || true
        log "凭据已备份到 $bak"
    fi
    rm -rf "$dir"
    log "已卸载 $app 并删除所有数据"
}

# ============================================================
# WordPress（含 MariaDB + Redis）
# ============================================================
deploy_wordpress() {
    header "部署 WordPress"
    local DIR="$BASE_DIR/wordpress"
    mkdir -p "$DIR"/{data,db,redis,uploads}
    local DB_ROOT_PW DB_PW
    DB_ROOT_PW=$(randpw); DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
WORDPRESS_DB_ROOT_PASSWORD=${DB_ROOT_PW}
WORDPRESS_DB_PASSWORD=${DB_PW}
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wpuser
EOF
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${WORDPRESS_DB_ROOT_PASSWORD}
      MARIADB_DATABASE: ${WORDPRESS_DB_NAME}
      MARIADB_USER: ${WORDPRESS_DB_USER}
      MARIADB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [wp_net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save 60 1 --loglevel warning
    volumes:
      - ./redis:/data
    networks: [wp_net]

  wordpress:
    image: wordpress:php8.3-fpm-alpine
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      WORDPRESS_DB_HOST: db:3306
      WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
      WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
      WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
      WORDPRESS_CONFIG_EXTRA: |
        define('WP_REDIS_HOST', 'redis');
        define('WP_REDIS_PORT', 6379);
        define('WP_CACHE', true);
        define('WP_MEMORY_LIMIT', '512M');
        define('WP_MAX_MEMORY_LIMIT', '1024M');
    volumes:
      - ./data:/var/www/html
      - ./uploads/php-uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    networks: [wp_net]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [wordpress]
    volumes:
      - ./data:/var/www/html:ro
      - ./uploads/nginx-wp.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [wp_net]
    ports:
      - "127.0.0.1:8080:80"

networks:
  wp_net:
    driver: bridge
YAML
    cat > "$DIR/uploads/php-uploads.ini" <<'INI'
upload_max_filesize = 2048M
post_max_size       = 2048M
memory_limit        = 1024M
max_execution_time  = 600
max_input_time      = 600
max_input_vars      = 10000
INI
    cat > "$DIR/uploads/nginx-wp.conf" <<'NGINX'
server {
    listen 80;
    root /var/www/html;
    index index.php index.html;
    client_max_body_size 2048M;
    location / { try_files $uri $uri/ /index.php?$args; }
    location ~ \.php$ {
        fastcgi_pass  wordpress:9000;
        fastcgi_index index.php;
        include       fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_read_timeout 600;
    }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2)$ {
        expires max;
        log_not_found off;
    }
}
NGINX
    run_compose "$DIR" "WordPress"
    log "WordPress 已启动 → http://127.0.0.1:8080"
    log "凭据已保存至 $DIR/.env"
}

# ============================================================
# Nextcloud（含 MariaDB + Redis）
# ============================================================
deploy_nextcloud() {
    header "部署 Nextcloud"
    local DIR="$BASE_DIR/nextcloud"
    mkdir -p "$DIR"/{data,db,redis,config,apps}
    local DB_ROOT_PW DB_PW ADMIN_PW
    DB_ROOT_PW=$(randpw); DB_PW=$(randpw); ADMIN_PW=$(randpw 20)
    cat > "$DIR/.env" <<EOF
MYSQL_ROOT_PASSWORD=${DB_ROOT_PW}
MYSQL_PASSWORD=${DB_PW}
NEXTCLOUD_ADMIN_PASSWORD=${ADMIN_PW}
EOF
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MARIADB_DATABASE: nextcloud
      MARIADB_USER: nextcloud
      MARIADB_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [nc_net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    networks: [nc_net]

  nextcloud:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
      REDIS_HOST: redis
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      PHP_UPLOAD_LIMIT: 2048M
      PHP_MEMORY_LIMIT: 1024M
    volumes:
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
      - ./apps:/var/www/html/custom_apps
    networks: [nc_net]

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      - ./data:/var/www/html/data:ro
      - ./config:/var/www/html/config:ro
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks: [nc_net]
    ports:
      - "127.0.0.1:8081:80"

  cron:
    image: nextcloud:production-fpm-alpine
    restart: unless-stopped
    depends_on: [nextcloud]
    volumes:
      - ./data:/var/www/html/data
      - ./config:/var/www/html/config
    entrypoint: /cron.sh
    networks: [nc_net]

networks:
  nc_net:
    driver: bridge
YAML
    cat > "$DIR/nginx.conf" <<'NGINX'
upstream php-handler { server nextcloud:9000; }
server {
    listen 80;
    root /var/www/html;
    client_max_body_size 2048M;
    add_header Strict-Transport-Security "max-age=15768000" always;
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location ^~ /.well-known { return 301 /index.php$uri; }
    location / { rewrite ^ /index.php; }
    location ~ ^\/(?:build|tests|config|lib|3rdparty|templates|data)\/ { deny all; }
    location ~ ^\/(?:\.|autotest|occ|issue|indie|db_|console) { deny all; }
    location ~ ^\/(?:index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+)\.php(?:$|\/) {
        fastcgi_split_path_info ^(.+?\.php)(\/.*|)$;
        fastcgi_pass php-handler;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_read_timeout 600;
    }
    location ~ ^\/(?:updater|oc[ms]-provider)(?:$|\/) { try_files $uri/ =404; index index.php; }
    location ~* \.(?:css|js|woff2|svg|gif|map)$ { try_files $uri /index.php$request_uri; expires 6M; }
    location ~* \.(?:png|html|ttf|ico|jpg|jpeg|bcmap|mp4|webm)$ { try_files $uri /index.php$request_uri; }
}
NGINX
    run_compose "$DIR" "Nextcloud"
    log "Nextcloud 已启动 → http://127.0.0.1:8081"
    log "管理员账号: admin  密码: ${ADMIN_PW}"
}

# ============================================================
# Gitea（Git 服务，含 PostgreSQL）
# ============================================================
deploy_gitea() {
    header "部署 Gitea"
    local DIR="$BASE_DIR/gitea"
    mkdir -p "$DIR"/{data,db}
    local DB_PW; DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
POSTGRES_PASSWORD=${DB_PW}
EOF
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: gitea
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: gitea
    volumes:
      - ./db:/var/lib/postgresql/data
    networks: [gitea_net]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gitea"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: gitea/gitea:latest
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      USER_UID: 1000
      USER_GID: 1000
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: db:5432
      GITEA__database__NAME: gitea
      GITEA__database__USER: gitea
      GITEA__database__PASSWD: ${POSTGRES_PASSWORD}
      GITEA__server__DOMAIN: localhost
      GITEA__server__ROOT_URL: http://localhost/
      GITEA__attachment__MAX_SIZE: 2048
      GITEA__picture__MAX_ORIGINAL_FILE_SIZE: 4096
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "127.0.0.1:3000:3000"
      - "127.0.0.1:2222:22"
    networks: [gitea_net]

networks:
  gitea_net:
    driver: bridge
YAML
    run_compose "$DIR" "Gitea"
    log "Gitea 已启动 → http://127.0.0.1:3000  SSH: 127.0.0.1:2222"
}

# ============================================================
# Uptime Kuma
# ============================================================
deploy_uptime_kuma() {
    header "部署 Uptime Kuma"
    local DIR="$BASE_DIR/uptime-kuma"
    mkdir -p "$DIR/data"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:3001:3001"
YAML
    run_compose "$DIR" "Uptime Kuma"
    log "Uptime Kuma 已启动 → http://127.0.0.1:3001"
}

# ============================================================
# Portainer
# ============================================================
deploy_portainer() {
    header "部署 Portainer CE"
    local DIR="$BASE_DIR/portainer"
    mkdir -p "$DIR/data"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  portainer:
    image: portainer/portainer-ce:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "127.0.0.1:9443:9443"
      - "127.0.0.1:9000:9000"
YAML
    run_compose "$DIR" "Portainer"
    log "Portainer 已启动 → http://127.0.0.1:9000  HTTPS: https://127.0.0.1:9443"
}

# ============================================================
# phpMyAdmin
# ============================================================
deploy_phpmyadmin() {
    header "部署 phpMyAdmin"
    local DIR="$BASE_DIR/phpmyadmin"
    mkdir -p "$DIR"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  phpmyadmin:
    image: phpmyadmin:latest
    restart: unless-stopped
    environment:
      PMA_ARBITRARY: 1
      PMA_ABSOLUTE_URI: "http://localhost/pma/"
      UPLOAD_LIMIT: 2048M
      MEMORY_LIMIT: 1024M
      MAX_EXECUTION_TIME: 600
    ports:
      - "127.0.0.1:8082:80"
YAML
    run_compose "$DIR" "phpMyAdmin"
    log "phpMyAdmin 已启动 → http://127.0.0.1:8082"
}

# ============================================================
# Redis Commander
# ============================================================
deploy_redis_commander() {
    header "部署 Redis Commander"
    local DIR="$BASE_DIR/redis-commander"
    mkdir -p "$DIR"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  redis-commander:
    image: rediscommander/redis-commander:latest
    restart: unless-stopped
    environment:
      REDIS_HOSTS: "local:host.docker.internal:6379"
    ports:
      - "127.0.0.1:8083:8081"
    extra_hosts:
      - "host.docker.internal:host-gateway"
YAML
    run_compose "$DIR" "Redis Commander"
    log "Redis Commander 已启动 → http://127.0.0.1:8083"
}

# ============================================================
# MinIO
# ============================================================
deploy_minio() {
    header "部署 MinIO"
    local DIR="$BASE_DIR/minio"
    mkdir -p "$DIR/data"
    local SECRET_KEY; SECRET_KEY=$(randpw 32)
    cat > "$DIR/.env" <<EOF
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=${SECRET_KEY}
EOF
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  minio:
    image: minio/minio:latest
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - ./data:/data
    ports:
      - "127.0.0.1:9002:9000"
      - "127.0.0.1:9001:9001"
    networks: [minio_net]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3

networks:
  minio_net:
    driver: bridge
YAML
    run_compose "$DIR" "MinIO"
    log "MinIO 控制台: http://127.0.0.1:9001  API: http://127.0.0.1:9002"
    log "Access Key: admin  Secret Key: ${SECRET_KEY}"
}

# ============================================================
# Lsky Pro（兰空图床）
# ────────────────────────────────────────────────────────────
#  官方镜像 lskypro/lsky-pro 已停止维护（最后推送 2023 年）。
#  改用社区镜像 bestzwei/lskypro，持续跟进官方源码构建。
# ============================================================
deploy_lskypro() {
    header "部署 Lsky Pro 图床"
    local DIR="$BASE_DIR/lskypro"
    mkdir -p "$DIR"/{uploads,db}
    local DB_ROOT_PW DB_PW
    DB_ROOT_PW=$(randpw); DB_PW=$(randpw)
    cat > "$DIR/.env" <<EOF
MARIADB_ROOT_PASSWORD=${DB_ROOT_PW}
MARIADB_PASSWORD=${DB_PW}
EOF
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  lskypro-db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      MARIADB_DATABASE: lskypro
      MARIADB_USER: lskypro
      MARIADB_PASSWORD: ${MARIADB_PASSWORD}
    volumes:
      - ./db:/var/lib/mysql
    networks: [lskypro_net]
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  lskypro:
    # 官方镜像 lskypro/lsky-pro 已停止维护，使用社区维护镜像
    image: bestzwei/lskypro:latest
    restart: unless-stopped
    environment:
      DB_CONNECTION: mysql
      DB_HOST: lskypro-db
      DB_PORT: 3306
      DB_DATABASE: lskypro
      DB_USERNAME: lskypro
      DB_PASSWORD: ${MARIADB_PASSWORD}
    volumes:
      - ./uploads:/var/www/html/storage/app/uploads
    ports:
      - "127.0.0.1:8085:80"
    depends_on:
      lskypro-db:
        condition: service_healthy
    networks: [lskypro_net]

networks:
  lskypro_net:
    driver: bridge
YAML
    run_compose "$DIR" "Lsky Pro"
    log "Lsky Pro 已启动 → http://127.0.0.1:8085"
    warn "首次访问需完成 Web 安装向导（数据库主机填 lskypro-db）"
    log "数据库: lskypro  用户: lskypro  密码见 $DIR/.env"
}

# ============================================================
# EasyImage
# ============================================================
deploy_easyimage() {
    header "部署 EasyImage 图床"
    local DIR="$BASE_DIR/easyimage"
    mkdir -p "$DIR"/{data,config}
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  easyimage:
    image: ddsderek/easyimage:latest
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      PUID: 1000
      PGID: 1000
    volumes:
      - ./data:/app/web/i
      - ./config:/app/web/config
    ports:
      - "127.0.0.1:8086:80"
    networks: [easyimage_net]

networks:
  easyimage_net:
    driver: bridge
YAML
    run_compose "$DIR" "EasyImage"
    log "EasyImage 已启动 → http://127.0.0.1:8086"
}

# ============================================================
# AList（多存储文件列表 / 网盘挂载）
# ============================================================
deploy_alist() {
    header "部署 AList"
    local DIR="$BASE_DIR/alist"
    mkdir -p "$DIR/data"
    cat > "$DIR/docker-compose.yml" <<'YAML'
services:
  alist:
    image: xhofe/alist:latest
    restart: unless-stopped
    environment:
      - PUID=0
      - PGID=0
      - UMASK=022
    volumes:
      - ./data:/opt/alist/data
    ports:
      - "127.0.0.1:5244:5244"
    networks: [alist_net]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5244/ping"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  alist_net:
    driver: bridge
YAML
    run_compose "$DIR" "AList"

    # 等待初始化后尝试从日志提取初始密码
    info "等待 AList 初始化（约 5 秒）..."
    sleep 5
    local cid init_pw
    cid=$(cd "$DIR" && docker compose ps -q alist 2>/dev/null | head -1)
    init_pw=$(docker logs "$cid" 2>&1 | grep -oP '(?<=password: )[^\s]+' | tail -1 || true)

    log "AList 已启动 → http://127.0.0.1:5244"
    if [[ -n "${init_pw:-}" ]]; then
        log "初始管理员密码: ${init_pw}"
        echo "ALIST_INIT_PASSWORD=${init_pw}" > "$DIR/.env"
        log "凭据已保存至 $DIR/.env"
    else
        warn "无法自动获取初始密码，请手动执行以下命令查看或重置："
        warn "  docker exec -it ${cid:-<容器ID>} ./alist admin"
        warn "  重置密码: docker exec -it ${cid:-<容器ID>} ./alist admin set <新密码>"
    fi
}

print_summary() {
    local apps=("$@")
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║              🐳  部署完成 — 访问地址汇总                    ║"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    for app in "${apps[@]}"; do
        printf "║  %-16s → %-38s║\n" "$app" "${APP_PORT[$app]}"
    done
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  凭据文件位置: /opt/docker-apps/<app>/.env                  ║"
    echo -e "║  在外部 nginx 将以上端口逐一反代即可对外提供服务            ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ============================================================
# 主流程
# ============================================================
main() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --install)    check_system; install_docker; exit 0 ;;
            --deploy)
                [[ -z "${2:-}" ]] && error "请指定应用名称"
                ensure_docker
                case "$2" in
                    wordpress)       deploy_wordpress ;;
                    nextcloud)       deploy_nextcloud ;;
                    gitea)           deploy_gitea ;;
                    uptime-kuma)     deploy_uptime_kuma ;;
                    portainer)       deploy_portainer ;;
                    phpmyadmin)      deploy_phpmyadmin ;;
                    redis-commander) deploy_redis_commander ;;
                    minio)           deploy_minio ;;
                    lskypro)         deploy_lskypro ;;
                    easyimage)       deploy_easyimage ;;
                    alist)           deploy_alist ;;
                    *)               error "未知应用: $2" ;;
                esac
                exit 0
                ;;
            --uninstall)
                [[ -z "${2:-}" ]] && error "请指定应用名称"
                uninstall_app "$2"; exit 0
                ;;
            --backup)
                [[ -z "${2:-}" ]] && error "请指定应用名称"
                backup_app "$2"; exit 0
                ;;
            --update)
                [[ -z "${2:-}" ]] && error "请指定应用名称"
                ensure_docker; update_app_images "$2"; exit 0
                ;;
            --update-all)
                ensure_docker
                local updated=0
                for app in "${ALL_APPS[@]}"; do
                    if [[ -f "$BASE_DIR/$app/docker-compose.yml" ]]; then
                        update_app_images "$app"; ((updated++))
                    fi
                done
                [[ $updated -eq 0 ]] && warn "没有已部署的应用"
                exit 0
                ;;
            --list)   list_apps; exit 0 ;;
            --all)    check_system; ensure_docker; deploy_all_apps; exit 0 ;;
            --help|-h) usage ;;
            *)        error "未知选项: $1，使用 --help 查看帮助" ;;
        esac
    fi
    interactive_menu
}

main "$@"
