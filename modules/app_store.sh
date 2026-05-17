#!/bin/bash
# 应用商店 - 远程加载，不存储功能代码

if [ -z "$VPS_COMMON_LOADED" ]; then
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi

detect_os
check_dependencies

# ---------- 远程应用注册表 ----------
# 格式： "菜单显示名称|脚本下载URL"
declare -A APPS=(
    ["公开相册"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/photo.sh"
    ["Docker 环境"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/docker.sh"
    ["Nginx 环境"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/nginx.sh"
    ["BBR 优化"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/bbr.sh"
    ["Fail2Ban 配置"]="https://raw.githubusercontent.com/lje02/vp/main/remote_apps/fail2ban.sh"
    # 后续新增应用只需在此添加一行
)

# ---------- 执行远程应用 ----------
run_remote_app() {
    local name="$1"
    local url="$2"
    local tmp_script="/tmp/vn_app_$$.sh"

    printf "${BLUE}▶ 正在加载: %s ...${NC}\n" "$name"
    if curl -fsSL "$url" -o "$tmp_script" 2>/dev/null; then
        if [ -s "$tmp_script" ]; then
            chmod +x "$tmp_script"
            bash "$tmp_script"
            rm -f "$tmp_script"
            printf "${GREEN}✔ %s 执行完毕。${NC}\n" "$name"
        else
            printf "${RED}✘ 下载的脚本为空。${NC}\n"
            rm -f "$tmp_script"
        fi
    else
        printf "${RED}✘ 无法连接到远程仓库，请检查网络。${NC}\n"
    fi
    read -p "按回车键继续..." dummy
}

# ---------- 主菜单 ----------
while true; do
    clear
    printf "${BLUE}===== 应用商店 (远程加载) =====${NC}\n"
    printf "共 %d 个可用应用\n" "${#APPS[@]}"
    echo "--------------------------------------"
    local i=1
    for app_name in "${!APPS[@]}"; do
        printf "%d. %s\n" "$i" "$app_name"
        ((i++))
    done
    echo "0. 返回主菜单"
    read -p "选择: " choice

    if [[ "$choice" == "0" ]]; then
        break
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#APPS[@]}" ]; then
        # 根据数字提取名称和URL
        local selected_name="" selected_url=""
        local j=1
        for n in "${!APPS[@]}"; do
            if [ "$j" -eq "$choice" ]; then
                selected_name="$n"
                selected_url="${APPS[$n]}"
                break
            fi
            ((j++))
        done
        run_remote_app "$selected_name" "$selected_url"
    else
        printf "${RED}无效选项${NC}\n"
        sleep 1
    fi
done
