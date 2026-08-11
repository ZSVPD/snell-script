#!/bin/bash
# =========================================
# Автор: jinqians
# Дата: Февраль 2025
# Сайт: jinqians.com
# Описание: Этот скрипт используется для управления многопользовательской конфигурацией прокси Snell
# =========================================

# Определение цветовых кодов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Определение каталога конфигурации
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"

# Определение путей к каталогам и файлам
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

ensure_snell_service_user() {
    if ! getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${SNELL_SERVICE_GROUP}" 2>/dev/null || true
    fi

    if ! getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || \
        useradd -r -M -s /usr/sbin/nologin -g "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || true
    fi
}

# Проверка, запущен ли скрипт с правами root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Пожалуйста, запустите этот скрипт с правами root.${RESET}"
        exit 1
    fi
}

# Проверка, установлен ли Snell
check_snell_installed() {
    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}Установка Snell не обнаружена, пожалуйста, сначала установите Snell.${RESET}"
        exit 1
    fi
}

# Получение системного DNS
get_system_dns() {
    # Попытка получить системный DNS из resolv.conf
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi
    
    # Если не удалось получить из resolv.conf, используем публичный DNS
    echo "1.1.1.1,8.8.8.8"
}

# Получение DNS-сервера, введенного пользователем
get_dns() {
    read -rp "Введите адрес DNS-сервера (нажмите Enter для использования системного DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS=$(get_system_dns)
        echo -e "${GREEN}Используется системный DNS-сервер: $DNS${RESET}"
    else
        DNS=$custom_dns
        echo -e "${GREEN}Используется пользовательский DNS-сервер: $DNS${RESET}"
    fi
}

# Сохранение правил nftables
save_nftables_rules() {
    if ! command -v nft &> /dev/null; then
        return
    fi

    if [ -f "/etc/nftables.conf" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
        echo -e "${GREEN}Правила nftables сохранены${RESET}"
    elif [ -f "/etc/sysconfig/nftables.conf" ]; then
        nft list ruleset > /etc/sysconfig/nftables.conf 2>/dev/null || true
        systemctl enable nftables >/dev/null 2>&1 || true
        echo -e "${GREEN}Правила nftables сохранены${RESET}"
    else
        echo -e "${YELLOW}Файл конфигурации nftables не найден, правила для портов применены в текущей сессии${RESET}"
    fi
}

# Открытие портов в nftables
open_nftables_port() {
    local PORT=$1
    local chains
    local chain_opened=false

    if ! command -v nft &> /dev/null; then
        return
    fi

    echo -e "${CYAN}Открытие порта $PORT в nftables${RESET}"

    chains=$(nft -a list ruleset 2>/dev/null | awk '
        $1 == "table" {
            family=$2
            table=$3
            gsub(/[{}]/, "", table)
        }
        $1 == "chain" {
            chain=$2
            gsub(/[{}]/, "", chain)
            in_chain=1
            next
        }
        in_chain && /type filter/ && /hook input/ {
            print family " " table " " chain
        }
        in_chain && /^[[:space:]]*}/ {
            in_chain=0
        }
    ')

    while read -r family table chain; do
        [ -z "$family" ] && continue

        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "tcp dport $PORT .*accept"; then
            nft insert rule "$family" "$table" "$chain" tcp dport "$PORT" accept 2>/dev/null || true
        fi
        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "udp dport $PORT .*accept"; then
            nft insert rule "$family" "$table" "$chain" udp dport "$PORT" accept 2>/dev/null || true
        fi
        chain_opened=true
    done << EOF
$chains
EOF

    if [ "$chain_opened" = false ]; then
        nft add table inet snell_filter 2>/dev/null || true
        nft list chain inet snell_filter input >/dev/null 2>&1 || nft add chain inet snell_filter input '{ type filter hook input priority -5; policy accept; }'
        if ! nft list chain inet snell_filter input 2>/dev/null | grep -q "tcp dport $PORT .*accept"; then
            nft add rule inet snell_filter input tcp dport "$PORT" accept 2>/dev/null || true
        fi
        if ! nft list chain inet snell_filter input 2>/dev/null | grep -q "udp dport $PORT .*accept"; then
            nft add rule inet snell_filter input udp dport "$PORT" accept 2>/dev/null || true
        fi
    fi

    save_nftables_rules
}

# Открытие порта (ufw, nftables и iptables)
open_port() {
    local PORT=$1
    local ufw_active=false

    # Проверка, установлен ли ufw
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}Открытие порта $PORT в UFW${RESET}"
        ufw allow "$PORT"/tcp
        ufw allow "$PORT"/udp
        if ufw status 2>/dev/null | grep -qw "active"; then
            ufw_active=true
        fi
    fi

    # Проверка, установлен ли iptables
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}Открытие порта $PORT в iptables${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        
        # Создание каталога сохранения правил iptables (если он не существует)
        if [ ! -d "/etc/iptables" ]; then
            mkdir -p /etc/iptables
        fi
        
        # Попытка сохранить правила, если не удастся - не прерываем скрипт
        iptables-save > /etc/iptables/rules.v4 || true
    fi

    if [ "$ufw_active" = false ]; then
        open_nftables_port "$PORT"
    fi
}

# Получение порта основного пользователя
get_main_port() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        echo "$main_port"
    fi
}

# Получение портов всех пользователей
get_all_ports() {
    # Проверка существования каталога конфигураций пользователей
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    # Извлечение портов из всех конфигурационных файлов
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$conf_file" ]; then
            grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
        fi
    done | sort -n | uniq
}

# Список всех пользователей
list_users() {
    echo -e "\n${YELLOW}=== Текущий список пользователей ===${RESET}"
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        local count=0
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                count=$((count + 1))
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                echo -e "${GREEN}Пользователь $count:${RESET}"
                echo -e "Порт: ${port}"
                echo -e "PSK: ${psk}"
                echo -e "Файл конфигурации: ${user_conf}\n"
            fi
        done
        if [ $count -eq 0 ]; then
            echo -e "${YELLOW}В настоящее время нет настроенных пользователей${RESET}"
        fi
    else
        echo -e "${YELLOW}В настоящее время нет настроенных пользователей${RESET}"
    fi
}

# Проверка, занят ли порт
check_port_usage() {
    local port=$1
    # Проверка, используется ли порт другим экземпляром snell
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$conf" ]; then
                local used_port=$(grep -E '^listen' "$conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ "$used_port" == "$port" ]; then
                    return 1
                fi
            fi
        done
    fi
    # Проверка основного файла конфигурации
    if [ -f "${SNELL_CONF_DIR}/snell-server.conf" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/snell-server.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        if [ "$main_port" == "$port" ]; then
            return 1
        fi
    fi
    return 0
}

# Добавление нового пользователя
add_user() {
    echo -e "\n${YELLOW}=== Добавление нового пользователя ===${RESET}"
    
    # Создание каталога для конфигураций пользователей
    mkdir -p "${SNELL_CONF_DIR}/users"
    
    # Получение номера порта
    while true; do
        read -rp "Введите номер порта для нового пользователя (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            # Проверка, занят ли порт
            if ! check_port_usage "$PORT"; then
                echo -e "${RED}Порт $PORT уже используется, пожалуйста, выберите другой порт${RESET}"
                continue
            fi
            break
        else
            echo -e "${RED}Недействительный номер порта, введите число от 1 до 65535${RESET}"
        fi
    done
    
    # Генерация случайного PSK
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    
    # Получение настроек DNS
    get_dns
    
    # Создание файла конфигурации пользователя (настройки IPv6 следуют за основной конфигурацией)
    ensure_snell_service_user
    local ipv6_enable="true"
    local listen_addr="::0"
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ] && grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$main_conf"; then
        ipv6_enable="false"
        listen_addr="0.0.0.0"
    fi
    local user_conf="${SNELL_CONF_DIR}/users/snell-${PORT}.conf"
    cat > "$user_conf" << EOF
[snell-server]
listen = ${listen_addr}:${PORT}
psk = ${PSK}
ipv6 = ${ipv6_enable}
dns = ${DNS}
EOF
    
    # Создание файла службы systemd для пользователя
    local service_name="snell-${PORT}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Snell Proxy Service (Port ${PORT})
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server-${PORT}

[Install]
WantedBy=multi-user.target
EOF

    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    
    # Включение и запуск службы
    systemctl enable "$service_name"
    systemctl start "$service_name"
    
    # Открытие порта
    open_port "$PORT"
    
    echo -e "\n${GREEN}Пользователь успешно добавлен! Информация о конфигурации:${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}Порт: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}Файл конфигурации: ${user_conf}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
}

# Удаление пользователя
delete_user() {
    echo -e "\n${YELLOW}=== Удаление пользователя ===${RESET}"
    
    # Показ списка пользователей
    list_users
    
    # Запрос порта пользователя для удаления
    read -rp "Введите номер порта пользователя для удаления: " del_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${del_port}.conf"
    local service_name="snell-${del_port}"
    
    if [ -f "$user_conf" ]; then
        # Остановка и отключение службы
        systemctl stop "$service_name"
        systemctl disable "$service_name"
        
        # Удаление файлов службы
        rm -f "${SYSTEMD_DIR}/${service_name}.service"
        rm -f "/lib/systemd/system/${service_name}.service"
        # Удаление файла конфигурации
        rm -f "$user_conf"
        
        # Перезагрузка конфигурации systemd
        systemctl daemon-reload
        
        echo -e "${GREEN}Пользователь успешно удален${RESET}"
    else
        echo -e "${RED}Пользователь с портом ${del_port} не найден${RESET}"
    fi
}

# Изменение конфигурации пользователя
modify_user() {
    echo -e "\n${YELLOW}=== Изменение конфигурации пользователя ===${RESET}"
    
    # Показ списка пользователей
    list_users
    
    # Запрос порта пользователя для изменения
    read -rp "Введите номер порта пользователя для изменения: " mod_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${mod_port}.conf"
    local service_name="snell-${mod_port}"
    
    if [ -f "$user_conf" ]; then
        echo -e "\n${YELLOW}Выберите, что вы хотите изменить:${RESET}"
        echo -e "${GREEN}1.${RESET} Изменить порт"
        echo -e "${GREEN}2.${RESET} Сбросить PSK"
        echo -e "${GREEN}3.${RESET} Изменить DNS"
        echo -e "${GREEN}0.${RESET} Назад"
        
        read -rp "Введите опцию [0-3]: " mod_choice
        case "$mod_choice" in
            1)
                # Изменение порта
                while true; do
                    read -rp "Введите новый номер порта (1-65535): " new_port
                    if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                        if ! check_port_usage "$new_port"; then
                            echo -e "${RED}Порт $new_port уже используется, пожалуйста, выберите другой порт${RESET}"
                            continue
                        fi
                        break
                    else
                        echo -e "${RED}Недействительный номер порта, введите число от 1 до 65535${RESET}"
                    fi
                done
                
                # Остановка службы
                systemctl stop "$service_name"
                
                # Изменение порта в конфигурационном файле
                sed -i "s/\(listen = .*:\)${mod_port}/\1${new_port}/" "$user_conf"
                
                # Переименование конфигурационного файла и файла службы
                mv "$user_conf" "${SNELL_CONF_DIR}/users/snell-${new_port}.conf"
                mv "${SYSTEMD_DIR}/${service_name}.service" "${SYSTEMD_DIR}/snell-${new_port}.service"
                
                # Перемещение и обновление файла службы (Исправлено с использованием '|' как разделителя)
                sed -i "s/Description=Snell Proxy Service (Port ${mod_port})/Description=Snell Proxy Service (Port ${new_port})/" "${SYSTEMD_DIR}/snell-${new_port}.service"
                sed -i "s/SyslogIdentifier=snell-server-${mod_port}/SyslogIdentifier=snell-server-${new_port}/" "${SYSTEMD_DIR}/snell-${new_port}.service"
                sed -i "s|${user_conf}|${SNELL_CONF_DIR}/users/snell-${new_port}.conf|" "${SYSTEMD_DIR}/snell-${new_port}.service"
                
                # Перезагрузка конфигурации и запуск службы
                systemctl daemon-reload
                systemctl enable "snell-${new_port}"
                systemctl start "snell-${new_port}"
                
                # Открытие нового порта
                open_port "$new_port"
                
                echo -e "${GREEN}Порт успешно изменен${RESET}"
                ;;
            2)
                # Сброс PSK
                local new_psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
                sed -i "s/psk = .*/psk = ${new_psk}/" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}PSK был сброшен на: ${new_psk}${RESET}"
                ;;
            3)
                # Изменение DNS
                get_dns
                sed -i "s/dns = .*/dns = ${DNS}/" "$user_conf"
                systemctl restart "$service_name"
                echo -e "${GREEN}DNS успешно изменен${RESET}"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Недействительная опция${RESET}"
                ;;
        esac
    else
        echo -e "${RED}Пользователь с портом ${mod_port} не найден${RESET}"
    fi
}

# Показ информации о конфигурации пользователя
show_user_config() {
    echo -e "\n${YELLOW}=== Информация о конфигурации пользователя ===${RESET}"
    
    # Показ списка пользователей
    list_users
    
    # Запрос порта пользователя для просмотра
    read -rp "Введите номер порта пользователя для просмотра: " view_port
    
    local user_conf="${SNELL_CONF_DIR}/users/snell-${view_port}.conf"
    
    if [ -f "$user_conf" ]; then
        local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local dns=$(grep -E '^dns' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        
        echo -e "\n${GREEN}Детали конфигурации пользователя:${RESET}"
        echo -e "${CYAN}--------------------------------${RESET}"
        echo -e "${YELLOW}Порт: ${port}${RESET}"
        echo -e "${YELLOW}PSK: ${psk}${RESET}"
        echo -e "${YELLOW}DNS: ${dns}${RESET}"
        
        # Получение IPv4 адреса
        IPV4_ADDR=$(curl -s4 https://api.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
            IP_COUNTRY_IPV4=$(curl -s http://ipinfo.io/${IPV4_ADDR}/country)
            echo -e "\n${GREEN}Конфигурация IPv4:${RESET}"
            echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        fi
        
        # Получение IPv6 адреса
        IPV6_ADDR=$(curl -s6 https://api64.ipify.org)
        if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
            IP_COUNTRY_IPV6=$(curl -s https://ipapi.co/${IPV6_ADDR}/country/)
            echo -e "\n${GREEN}Конфигурация IPv6:${RESET}"
            echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        fi
        
        echo -e "${CYAN}--------------------------------${RESET}"
    else
        echo -e "${RED}Пользователь с портом ${view_port} не найден${RESET}"
    fi
}

# Главное меню
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          Управление пользователями Snell${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}Автор: jinqian${RESET}"
    echo -e "${GREEN}Сайт: https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    echo -e "${YELLOW}=== Управление пользователями ===${RESET}"
    echo -e "${GREEN}1.${RESET} Просмотреть всех пользователей"
    echo -e "${GREEN}2.${RESET} Добавить нового пользователя"
    echo -e "${GREEN}3.${RESET} Удалить пользователя"
    echo -e "${GREEN}4.${RESET} Изменить конфигурацию пользователя"
    echo -e "${GREEN}5.${RESET} Просмотреть детальную конфигурацию пользователя"
    echo -e "${GREEN}0.${RESET} Выход"
    
    echo -e "${CYAN}============================================${RESET}"
    if ! read -rp "Введите опцию [0-5]: " choice; then
        echo
        echo -e "${YELLOW}Ввод не получен, выход из многопользовательского меню.${RESET}"
        exit 0
    fi
}

# Первоначальные проверки
check_root
check_snell_installed

# Главный цикл
while true; do
    show_menu
    case "$choice" in
        1)
            list_users
            ;;
        2)
            add_user
            ;;
        3)
            delete_user
            ;;
        4)
            modify_user
            ;;
        5)
            show_user_config
            ;;
        0)
            echo -e "${GREEN}Спасибо за использование, до свидания!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Пожалуйста, введите правильную опцию [0-5]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}Нажмите любую клавишу для возврата в главное меню...${RESET}"
    read -n 1 -s -r || exit 0
done
