#!/bin/bash
# 环境部署模块

if [ -z "$VPS_COMMON_LOADED" ]; then          # 第 3-4 行
    source /usr/local/share/vn_modules/common.sh 2>/dev/null || {
        echo "无法加载公共函数库"
        exit 1
    }
fi                                              # 第 9 行

detect_os
check_dependencies

# ---------- 安装 Node.js (LTS) ----------
install_nodejs() {
    printf "${BLUE}▶ 安装 Node.js LTS...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
    else
        curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
        yum install -y nodejs
    fi
    printf "${GREEN}✔ Node.js 版本: %s${NC}\n" "$(node -v 2>/dev/null || echo '安装失败')"
    read -p "按回车键继续..." dummy
}

# ---------- 安装 Nginx ----------
install_nginx() {
    printf "${BLUE}▶ 安装 Nginx...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y nginx
    else
        yum install -y epel-release && yum install -y nginx
    fi
    systemctl enable nginx --now 2>/dev/null || service nginx start 2>/dev/null
    printf "${GREEN}✔ Nginx 已安装并启动${NC}\n"
    read -p "按回车键继续..." dummy
}

# ---------- 安装 Python3 及 pip ----------
install_python() {
    printf "${BLUE}▶ 安装 Python3 及 pip...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y python3 python3-pip
    else
        yum install -y python3 python3-pip
    fi
    printf "${GREEN}✔ Python: %s, pip: %s${NC}\n" "$(python3 --version 2>/dev/null)" "$(pip3 --version 2>/dev/null | awk '{print $2}')"
    read -p "按回车键继续..." dummy
}

# ---------- 安装 Docker 及 Docker Compose ----------
install_docker() {
    printf "${BLUE}▶ 安装 Docker...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y docker.io docker-compose
    else
        yum install -y yum-utils
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    systemctl enable docker --now 2>/dev/null || service docker start 2>/dev/null
    printf "${GREEN}✔ Docker: %s${NC}\n" "$(docker --version 2>/dev/null)"
    printf "${GREEN}✔ Docker Compose: %s${NC}\n" "$(docker compose version 2>/dev/null || docker-compose --version 2>/dev/null)"
    read -p "按回车键继续..." dummy
}

# ---------- 安装 MySQL / MariaDB ----------
install_mysql() {
    printf "${YELLOW}选择数据库:${NC}\n"
    echo "1. MariaDB (推荐, 兼容MySQL)"
    echo "2. MySQL 8.0 (官方仓库)"
    echo "0. 返回"
    read -p "选择: " db_choice
    case $db_choice in
        1)
            if [ "$OS_FAMILY" = "debian" ]; then
                apt-get update -qq && apt-get install -y mariadb-server
            else
                yum install -y mariadb-server
            fi
            systemctl enable mariadb --now 2>/dev/null || service mariadb start 2>/dev/null
            printf "${GREEN}✔ MariaDB 已安装${NC}\n"
            ;;
        2)
            if [ "$OS_FAMILY" = "debian" ]; then
                wget -q https://dev.mysql.com/get/mysql-apt-config_0.8.22-1_all.deb
                dpkg -i mysql-apt-config_*.deb
                apt-get update -qq && apt-get install -y mysql-server
                rm -f mysql-apt-config_*.deb
            else
                yum install -y https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm
                yum install -y mysql-community-server
            fi
            systemctl enable mysqld --now 2>/dev/null || service mysqld start 2>/dev/null
            printf "${GREEN}✔ MySQL 8.0 已安装${NC}\n"
            ;;
        0) return ;;
        *) printf "${RED}无效选项${NC}\n";;
    esac
    read -p "按回车键继续..." dummy
}

# ---------- 安装 PHP ----------
install_php() {
    printf "${BLUE}▶ 安装 PHP (常用扩展)...${NC}\n"
    if [ "$OS_FAMILY" = "debian" ]; then
        apt-get update -qq && apt-get install -y php php-fpm php-mysql php-curl php-gd php-mbstring php-xml php-zip
    else
        yum install -y epel-release
        yum install -y https://rpms.remirepo.net/enterprise/remi-release-7.rpm
        yum module enable php:remi-7.4 -y
        yum install -y php php-fpm php-mysqlnd php-curl php-gd php-mbstring php-xml php-zip
    fi
    systemctl enable php-fpm --now 2>/dev/null || service php-fpm start 2>/dev/null
    printf "${GREEN}✔ PHP: %s${NC}\n" "$(php -v 2>/dev/null | head -1)"
    read -p "按回车键继续..." dummy
}

# ---------- 查看已安装环境 ----------
show_installed() {
    printf "${BLUE}===== 已安装环境概要 =====${NC}\n"
    command -v node   &>/dev/null && printf "Node.js  : %s\n" "$(node -v)"   || printf "Node.js  : ${RED}未安装${NC}\n"
    command -v nginx  &>/dev/null && printf "Nginx    : %s\n" "$(nginx -v 2>&1 | cut -d/ -f2)" || printf "Nginx    : ${RED}未安装${NC}\n"
    command -v python3 &>/dev/null && printf "Python   : %s\n" "$(python3 --version)" || printf "Python   : ${RED}未安装${NC}\n"
    command -v docker &>/dev/null && printf "Docker   : %s\n" "$(docker --version)" || printf "Docker   : ${RED}未安装${NC}\n"
    command -v mysql  &>/dev/null && printf "MySQL    : %s\n" "$(mysql --version)" || command -v mariadb &>/dev/null && printf "MariaDB  : %s\n" "$(mariadb --version)" || printf "MySQL/MariaDB : ${RED}未安装${NC}\n"
    command -v php    &>/dev/null && printf "PHP      : %s\n" "$(php -v 2>/dev/null | head -1)" || printf "PHP      : ${RED}未安装${NC}\n"
    echo ""
    read -p "按回车键继续..." dummy
}

# ---------- 一键组合安装 ----------
combo_install() {
    while true; do
        clear
        printf "${BLUE}===== 组合安装方案 =====${NC}\n"
        echo "1. LEMP (Nginx + MySQL/MariaDB + PHP)"
        echo "2. Node.js + Nginx + Python (全栈基础)"
        echo "3. Docker + Node.js + Nginx (容器化)"
        echo "0. 返回"
        read -p "选择方案: " combo
        case $combo in
            1)
                install_nginx
                install_mysql
                install_php
                printf "${GREEN}✔ LEMP 环境部署完成！${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            2)
                install_nodejs
                install_nginx
                install_python
                printf "${GREEN}✔ 全栈基础环境就绪${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            3)
                install_docker
                install_nodejs
                install_nginx
                printf "${GREEN}✔ 容器化环境已准备${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

update_menu() {
    while true; do
        clear
        printf "${BLUE}===== 更新已安装软件 =====${NC}\n"
        echo "1. 更新 Node.js"
        echo "2. 更新 Nginx"
        echo "3. 更新 Python3 + pip"
        echo "4. 更新 Docker"
        echo "5. 更新 MySQL / MariaDB"
        echo "6. 更新 PHP"
        echo "7. 一键更新所有已安装软件"
        echo "0. 返回上级菜单"
        read -p "选择: " up_choice
        case $up_choice in
            1) command -v node &>/dev/null && install_nodejs || printf "${RED}Node.js 未安装${NC}\n"; sleep 1 ;;
            2) command -v nginx &>/dev/null && install_nginx || printf "${RED}Nginx 未安装${NC}\n"; sleep 1 ;;
            3) command -v python3 &>/dev/null && install_python || printf "${RED}Python 未安装${NC}\n"; sleep 1 ;;
            4) command -v docker &>/dev/null && install_docker || printf "${RED}Docker 未安装${NC}\n"; sleep 1 ;;
            5) command -v mysql &>/dev/null && install_mysql || command -v mariadb &>/dev/null && install_mysql || printf "${RED}MySQL/MariaDB 未安装${NC}\n"; sleep 1 ;;
            6) command -v php &>/dev/null && install_php || printf "${RED}PHP 未安装${NC}\n"; sleep 1 ;;
            7)
                printf "${YELLOW}正在更新所有已安装软件...${NC}\n"
                command -v node &>/dev/null && install_nodejs
                command -v nginx &>/dev/null && install_nginx
                command -v python3 &>/dev/null && install_python
                command -v docker &>/dev/null && install_docker
                (command -v mysql &>/dev/null || command -v mariadb &>/dev/null) && install_mysql
                command -v php &>/dev/null && install_php
                printf "${GREEN}全部更新完成！${NC}\n"
                read -p "按回车键继续..." dummy
                ;;
            0) break ;;
            *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
        esac
    done
}

# ---------- 主菜单 ----------
while true; do
    clear
    printf "${BLUE}===== 环境部署中心 =====${NC}\n"
    echo "1. Node.js (LTS)"
    echo "2. Nginx"
    echo "3. Python3 + pip"
    echo "4. Docker & Docker Compose"
    echo "5. MySQL / MariaDB"
    echo "6. PHP (FPM)"
    echo "--------------------------------------"
    echo "7. 查看已安装版本"
    echo "8. 一键组合部署 (LEMP等)"
    echo "9. 更新已安装软件"
    echo "0. 返回主菜单"
    read -p "选择: " choice
    case $choice in
        1) install_nodejs ;;
        2) install_nginx ;;
        3) install_python ;;
        4) install_docker ;;
        5) install_mysql ;;
        6) install_php ;;
        7) show_installed ;;
        8) combo_install ;;
        9) update_menu ;;
        0) break ;;
        *) printf "${RED}无效选项${NC}\n"; sleep 1 ;;
    esac
done
