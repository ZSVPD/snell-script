#!/bin/bash
# =========================================
# Автор: jinqians
# Дата: Ноябрь 2024
# Сайт: jinqians.com
# Описание: Данный скрипт предназначен для настройки BBR
# =========================================

# Определение цветов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Проверка на запуск с правами root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Пожалуйста, запустите этот скрипт с правами root.${RESET}"
    exit 1
fi

# Настройка системных параметров и включение BBR
configure_system_and_bbr() {
    echo -e "${YELLOW}Настройка системных параметров и BBR...${RESET}"
    
    # ИСПРАВЛЕНИЕ: Записываем в отдельный файл вместо перезаписи основного sysctl.conf
    cat > /etc/sysctl.d/99-bbr.conf << EOF
fs.file-max = 6815744
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.ip_forward = 1
net.ipv4.conf.all.route_localnet = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF

    # Применяем настройки
    sysctl --system

    # Подгружаем модуль ядра, если он еще не загружен
    modprobe tcp_bbr 2>/dev/null

    if lsmod | grep -q tcp_bbr && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR и системные параметры успешно настроены.${RESET}"
    else
        echo -e "${YELLOW}Возможно, для применения настроек BBR или системных параметров потребуется перезагрузка.${RESET}"
    fi
}

# Включение стандартного BBR
enable_bbr() {
    echo -e "${YELLOW}Включение стандартного BBR...${RESET}"
    
    # Проверка, включен ли BBR уже
    if lsmod | grep -q "^tcp_bbr" && sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR уже включен.${RESET}"
        return 0
    fi
    
    configure_system_and_bbr
}

# Установка BBR v3 (Ядро XanMod)
install_xanmod_bbr() {
    echo -e "${YELLOW}Подготовка к установке ядра XanMod...${RESET}"
    
    # Проверка архитектуры
    if [ "$(uname -m)" != "x86_64" ]; then
        echo -e "${RED}Ошибка: поддерживается только архитектура x86_64${RESET}"
        return 1
    fi
    
    # Проверка операционной системы
    if ! grep -Eqi "debian|ubuntu" /etc/os-release; then
        echo -e "${RED}Ошибка: поддерживаются только системы Debian/Ubuntu${RESET}"
        return 1
    fi
    
    # Регистрация PGP-ключа
    wget -qO - https://dl.xanmod.org/archive.key | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg --yes
    
    # Добавление репозитория
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | tee /etc/apt/sources.list.d/xanmod-release.list
    
    # Обновление списка пакетов
    apt update -y
    
    # Попытка установить последнюю версию ядра
    echo -e "${YELLOW}Попытка установить последнюю версию ядра...${RESET}"
    if apt install -y linux-xanmod-x64v4; then
        echo -e "${GREEN}Последняя версия ядра успешно установлена${RESET}"
    else
        echo -e "${YELLOW}Не удалось установить последнюю версию, попытка установить совместимую версию...${RESET}"
        if apt install -y linux-xanmod-x64v2; then
            echo -e "${GREEN}Совместимая версия ядра успешно установлена${RESET}"
        else
            echo -e "${RED}Ошибка установки ядра${RESET}"
            return 1
        fi
    fi
    
    configure_system_and_bbr
    
    echo -e "${GREEN}Установка ядра XanMod завершена. Перезагрузите систему, чтобы использовать новое ядро.${RESET}"
    read -p "Перезагрузить систему сейчас? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Ручная компиляция и установка BBR v3
install_bbr3_manual() {
    echo -e "${YELLOW}Подготовка к ручной компиляции и установке BBR v3...${RESET}"
    
    # Установка зависимостей для компиляции
    apt update
    # ИСПРАВЛЕНИЕ: добавлены linux-headers и другие необходимые зависимости
    apt install -y build-essential git bison flex libssl-dev libelf-dev bc linux-headers-$(uname -r)
    
    # Клонирование исходного кода
    git clone -b v3 https://github.com/google/bbr.git
    cd bbr
    
    # ВНИМАНИЕ: Компиляция целого ядра (make) займет очень много времени!
    make
    make install
    
    configure_system_and_bbr
    
    echo -e "${GREEN}Компиляция и установка BBR v3 завершены${RESET}"
    read -p "Перезагрузить систему сейчас? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
}

# Главное меню
main_menu() {
    while true; do
        echo -e "\n${CYAN}Меню управления BBR${RESET}"
        echo -e "${YELLOW}1. Включить стандартный BBR${RESET}"
        echo -e "${YELLOW}2. Установить BBR v3 (версия XanMod)${RESET}"
        echo -e "${YELLOW}3. Установить BBR v3 (ручная компиляция - ОСТОРОЖНО)${RESET}"
        echo -e "${YELLOW}4. Вернуться в предыдущее меню${RESET}"
        echo -e "${YELLOW}5. Выйти из скрипта${RESET}"
        if ! read -rp "Выберите действие [1-5]: " choice; then
            echo
            echo -e "${YELLOW}Ввод не распознан, выход из меню BBR.${RESET}"
            return 0
        fi

        case "$choice" in
            1)
                enable_bbr
                ;;
            2)
                install_xanmod_bbr
                ;;
            3)
                install_bbr3_manual
                ;;
            4)
                return 0
                ;;
            5)
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
}

# Запуск главного меню
main_menu
