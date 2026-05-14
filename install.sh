#!/bin/bash
# 一键部署 VPS 管理面板 (vp)

REPO_URL="https://raw.githubusercontent.com/lje02/vp/main"
INSTALL_DIR="/usr/local/bin"
MODULES_DIR="/usr/local/share/vp_modules"
ORIG_ARGS=("$@")
set -e

mkdir -p "$MODULES_DIR"

# 下载公共库和主控
echo "下载公共库和主控..."
curl -sSL "$REPO_URL/common.sh" -o "$MODULES_DIR/common.sh" || { echo "公共库下载失败"; exit 1; }
curl -sSL "$REPO_URL/vp" -o "$INSTALL_DIR/vp" || { echo "主控下载失败"; exit 1; }
chmod +x "$INSTALL_DIR/vp"

# 静态后备模块列表
BASE_MODULES=(
    "firewall_fail2ban.sh"
    "system_optimize.sh"
    "remote_jump.sh"
    "singbox.sh"
    "monitor.sh"
    "ssh_harden.sh"
    "traffic_monitor.sh"
    "logs.sh"
    "tg_monitor.sh"
)

# 动态提取主控中的 MODULES_LIST
modules=()
if [ -f "$INSTALL_DIR/vp" ]; then
    modules=($(awk '/^MODULES_LIST=\(/ {flag=1; next} /^\)/ {flag=0} flag {gsub(/"/, ""); if ($1 ~ /\.sh$/) print $1}' "$INSTALL_DIR/vp"))
fi

# 提取为空时使用静态列表
if [ ${#modules[@]} -eq 0 ]; then
    modules=("${BASE_MODULES[@]}")
    echo "使用静态模块列表"
fi

echo -n "下载模块中"
for mod in "${modules[@]}"; do
    if curl -sSL "$REPO_URL/modules/$mod" -o "$MODULES_DIR/$mod" 2>/dev/null; then
        chmod +x "$MODULES_DIR/$mod" 2>/dev/null
        echo -n "."
    else
        echo -n "!"
    fi
done
echo " 完成"

echo ""
echo "安装完成！输入 'vp' 即可启动管理面板。"
