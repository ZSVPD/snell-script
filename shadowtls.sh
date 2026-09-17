#!/bin/bash
# =========================================
# Автор: jinqians
# Дата: 16 марта 2025
# Сайт: jinqians.com
# Описание: Скрипт для установки и управления ShadowTLS V3
# =========================================

# Определение цветовых кодов
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Определение системных путей
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="${SYSTEMD_DIR}/shadowtls.service"

# Определение путей конфигураций
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
USERS_DIR="${SNELL_CONF_DIR}/users"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

# =========================================
# Чтение информации о каналах Snell (read-only подмножество, совместимое с логикой версий snell.sh)
# Первая строка конфигурации каждого пользователя "#version-choice = vX" указывает, какая версия работает на порту;
# При отсутствии метки (старая установка до миграции) берется версия самого симлинка snell-server.
# =========================================
SNELL_VERSION_MARKER_KEY="version-choice"

snell_binary_for_version() {
    case "$1" in
        v4|v5|v6) echo "${INSTALL_DIR}/snell-server-$1" ;;
        *)        echo "${INSTALL_DIR}/snell-server" ;;
    esac
}

probe_snell_binary_version() {
    local binary="$1"
    if [ ! -x "$binary" ]; then
        echo "unknown"
        return 1
    fi

    local version_output
    version_output=$("$binary" --v 2>&1)
    if echo "$version_output" | grep -q "v6"; then
        echo "v6"
    elif echo "$version_output" | grep -q "v5"; then
        echo "v5"
    else
        echo "v4"
    fi
}

detect_installed_snell_version() {
    probe_snell_binary_version "${INSTALL_DIR}/snell-server"
}

read_conf_snell_version() {
    local conf_file="$1"
    [ -f "$conf_file" ] || return 1

    local marked
    marked=$(grep -E "^[[:space:]]*#[[:space:]]*${SNELL_VERSION_MARKER_KEY}[[:space:]]*=" "$conf_file" \
        | head -n 1 | awk -F'=' '{print $2}' | tr -d '[:space:]')
    case "$marked" in
        v4|v5|v6) echo "$marked" ;;
        *)        return 1 ;;
    esac
}

get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

snell_conf_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "$SNELL_CONF_FILE"
    else
        echo "${USERS_DIR}/snell-${port}.conf"
    fi
}

# Бэкенд-порт -> версия Snell, запущенная на этом порту
get_port_snell_version() {
    get_conf_snell_version "$(snell_conf_for_port "$1")"
}

# Бэкенд-порт -> режим mode для v6 (на клиенте и сервере должен совпадать)
get_port_snell_mode() {
    local conf_file mode=""
    conf_file=$(snell_conf_for_port "$1")
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    echo "${mode:-default}"
}

# Генерация строки прокси Surge для соответствующего порта бэкенда (с параметрами ShadowTLS)
print_snell_shadowtls_line() {
    local label="$1"
    local server_ip="$2"
    local stls_port="$3"
    local psk="$4"
    local stls_password="$5"
    local stls_sni="$6"
    local backend_port="$7"

    local version stls_suffix
    version=$(get_port_snell_version "$backend_port")
    stls_suffix="reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"

    case "$version" in
        v6)
            echo -e "${label} (v6) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 6, mode = $(get_port_snell_mode "$backend_port"), ${stls_suffix}"
            ;;
        v5)
            echo -e "${label} (v4) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, ${stls_suffix}"
            echo -e "${label} (v5) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 5, ${stls_suffix}"
            ;;
        *)
            echo -e "${label} (v4) = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, ${stls_suffix}"
            ;;
    esac
}

# Проверка прав root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Пожалуйста, запустите этот скрипт с правами root${RESET}"
        exit 1
    fi
}

# Установка необходимых утилит
install_requirements() {
    apt update
    apt install -y wget curl jq
}

# Получение последней версии
SHADOWTLS_FALLBACK_VERSION="v0.2.25"

get_latest_version() {
    local latest_version=""

    # В первую очередь запрос к API; при ошибке jq может вернуть "null"
    latest_version=$(curl -fsSL --connect-timeout 10 "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)

    # При сбое API (например, rate-limit), откат к редиректу releases/latest
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        latest_version=$(curl -fsSL --connect-timeout 10 -o /dev/null -w '%{url_effective}' "https://github.com/ihciah/shadow-tls/releases/latest" 2>/dev/null | sed -E 's#.*/tag/##')
    fi

    # Если оба варианта завершились неудачей, использовать встроенную рабочую версию
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        echo -e "${YELLOW}Не удалось получить последнюю версию с GitHub, используется встроенная версия ${SHADOWTLS_FALLBACK_VERSION}${RESET}" >&2
        latest_version="$SHADOWTLS_FALLBACK_VERSION"
    fi

    echo "$latest_version"
}

# Проверка, установлен ли Shadowsocks-Rust
check_ssrust() {
    if [ ! -f "/usr/local/bin/ss-rust" ]; then
        return 1
    fi
    return 0
}

# Проверка, установлен ли Snell
check_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        return 1
    fi
    return 0
}

save_nftables_rules() {
    if ! command -v nft >/dev/null 2>&1; then
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
        echo -e "${YELLOW}Файл сохранения правил nftables не найден, правила применены только для текущей сессии${RESET}"
    fi
}

open_nftables_port() {
    local port=$1
    local chains
    local chain_opened=false

    if ! command -v nft >/dev/null 2>&1; then
        return
    fi

    echo -e "${CYAN}Открытие порта ${port} в nftables${RESET}"

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

        if ! nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "tcp dport ${port} .*accept"; then
            nft insert rule "$family" "$table" "$chain" tcp dport "$port" accept 2>/dev/null || true
        fi
        chain_opened=true
    done << EOF
$chains
EOF

    if [ "$chain_opened" = false ]; then
        nft add table inet shadowtls_filter 2>/dev/null || true
        nft list chain inet shadowtls_filter input >/dev/null 2>&1 || nft add chain inet shadowtls_filter input '{ type filter hook input priority -5; policy accept; }'
        if ! nft list chain inet shadowtls_filter input 2>/dev/null | grep -q "tcp dport ${port} .*accept"; then
            nft add rule inet shadowtls_filter input tcp dport "$port" accept 2>/dev/null || true
        fi
    fi

    save_nftables_rules
}

open_port() {
    local port=$1
    local ufw_active=false

    if command -v ufw >/dev/null 2>&1; then
        echo -e "${CYAN}Открытие порта ${port} в UFW${RESET}"
        ufw allow "${port}"/tcp
        if ufw status 2>/dev/null | grep -qw "active"; then
            ufw_active=true
        fi
    fi

    if command -v iptables >/dev/null 2>&1; then
        echo -e "${CYAN}Открытие порта ${port} в iptables${RESET}"
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 || true
    fi

    if [ "$ufw_active" = false ]; then
        open_nftables_port "$port"
    fi
}

close_nftables_port() {
    local port=$1

    if ! command -v nft >/dev/null 2>&1; then
        return
    fi

    nft -a list ruleset 2>/dev/null | awk -v port="$port" '
        $1 == "table" {
            family=$2
            table=$3
            gsub(/[{}]/, "", table)
        }
        $1 == "chain" {
            chain=$2
            gsub(/[{}]/, "", chain)
        }
        ($0 ~ "tcp dport " port " .*accept" || $0 ~ "udp dport " port " .*accept") && /# handle/ {
            handle=$NF
            print family " " table " " chain " " handle
        }
    ' | while read -r family table chain handle; do
        [ -z "$handle" ] && continue
        nft delete rule "$family" "$table" "$chain" handle "$handle" 2>/dev/null || true
    done

    save_nftables_rules
}

close_port() {
    local port=$1

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$port"/udp >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    close_nftables_port "$port"
}

ensure_snell_service_user() {
    if ! getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${SNELL_SERVICE_GROUP}" 2>/dev/null || true
    fi

    if ! getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || \
        useradd -r -M -s /usr/sbin/nologin -g "${SNELL_SERVICE_GROUP}" "${SNELL_SERVICE_USER}" 2>/dev/null || true
    fi
}

ensure_snell_config_dir() {
    ensure_snell_service_user
    mkdir -p "${USERS_DIR}"
    if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${SNELL_CONF_DIR}" "${USERS_DIR}" 2>/dev/null || true
}

migrate_legacy_snell_config() {
    ensure_snell_config_dir

    if [ -f "${SNELL_CONF_FILE}" ]; then
        return 0
    fi

    if [ -f "${OLD_SNELL_CONF_FILE}" ]; then
        cp -a "${OLD_SNELL_CONF_FILE}" "${SNELL_CONF_FILE}"
        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}" 2>/dev/null || true
        fi
        chmod 644 "${SNELL_CONF_FILE}"
        echo -e "${GREEN}Старая конфигурация Snell успешно перенесена в ${SNELL_CONF_FILE}${RESET}"
        return 0
    fi

    return 1
}

check_snell_config() {
    if ! check_snell; then
        return 1
    fi

    migrate_legacy_snell_config || true

    if [ ! -s "${SNELL_CONF_FILE}" ]; then
        echo -e "${RED}Основной конфигурационный файл Snell не существует: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}Пожалуйста, сначала выполните установку/восстановление Snell или переместите старый конфиг ${OLD_SNELL_CONF_FILE} в каталог users.${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "${SNELL_CONF_FILE}"; then
        echo -e "${RED}В основном конфиге Snell отсутствует параметр listen: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "${SNELL_CONF_FILE}"; then
        echo -e "${RED}В основном конфиге Snell отсутствует параметр psk: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

# Получение порта Shadowsocks
get_ssrust_port() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local port=$(jq -r '.server_port' "$ssrust_conf" 2>/dev/null)
    echo "$port"
}

# Получение пароля Shadowsocks
get_ssrust_password() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local password=$(jq -r '.password' "$ssrust_conf" 2>/dev/null)
    echo "$password"
}

# Получение метода шифрования Shadowsocks
get_ssrust_method() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local method=$(jq -r '.method' "$ssrust_conf" 2>/dev/null)
    echo "$method"
}

# Получение порта Snell
get_snell_port() {
    migrate_legacy_snell_config >/dev/null 2>&1 || true
    if [ -f "${SNELL_CONF_FILE}" ]; then
        grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
}

# Получение PSK ключа Snell
get_snell_psk() {
    local snell_conf="${SNELL_CONF_FILE}"
    migrate_legacy_snell_config >/dev/null 2>&1 || true
    if [ ! -f "$snell_conf" ]; then
        return 1
    fi
    local psk=$(grep -E '^psk' "$snell_conf" | sed 's/psk = //')
    echo "$psk"
}

# Получение конфигурации Snell
get_snell_config() {
    local port=$1
    local snell_conf="${USERS_DIR}/snell-${port}.conf"
    local main_conf="${USERS_DIR}/snell-main.conf"
    local psk=""
    
    migrate_legacy_snell_config >/dev/null 2>&1 || true

    if [ -f "$snell_conf" ]; then
        psk=$(grep -E "^psk[[:space:]]*=" "$snell_conf" 2>/dev/null | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    fi

    if [ -z "$psk" ] && [ -f "$main_conf" ]; then
        psk=$(grep -E "^psk[[:space:]]*=" "$main_conf" 2>/dev/null | head -n 1 | sed 's/^[^=]*=[[:space:]]*//')
    fi

    echo "$psk"
}

# Получение конфигураций всех пользователей Snell
get_all_snell_users() {
    migrate_legacy_snell_config >/dev/null 2>&1 || true

    # Проверка существования директории пользовательских конфигураций
    if [ ! -d "${USERS_DIR}" ]; then
        return 1
    fi
    
    # Сначала получить конфигурацию основного пользователя
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_FILE}" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_FILE}" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ ! -z "$main_port" ] && [ ! -z "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi
    
    # Получить конфигурации остальных пользователей
    for user_conf in "${USERS_DIR}"/snell-*.conf; do
        if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
            local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
            if [ ! -z "$port" ] && [ ! -z "$psk" ]; then
                echo "${port}|${psk}"
            fi
        fi
    done
}

get_snell_config_file_by_port() {
    local target_port=$1
    local conf
    local port

    migrate_legacy_snell_config >/dev/null 2>&1 || true

    for conf in "${SNELL_CONF_FILE}" "${USERS_DIR}"/snell-*.conf; do
        [ -f "$conf" ] || continue
        port=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$conf" | head -n 1)
        if [ "$port" = "$target_port" ]; then
            echo "$conf"
            return 0
        fi
    done

    return 1
}

get_snell_service_name_by_config() {
    local conf=$1
    local filename

    if [ "$conf" = "${SNELL_CONF_FILE}" ]; then
        echo "snell"
        return 0
    fi

    filename=$(basename "$conf")
    case "$filename" in
        snell-[0-9]*.conf)
            echo "${filename%.conf}"
            return 0
            ;;
    esac

    return 1
}

restrict_snell_to_loopback() {
    local port=$1
    local conf
    local service_name

    conf=$(get_snell_config_file_by_port "$port") || {
        echo -e "${RED}Не найден конфигурационный файл для порта Snell ${port}${RESET}"
        return 1
    }

    service_name=$(get_snell_service_name_by_config "$conf") || {
        echo -e "${RED}Не удалось определить службу systemd для порта Snell ${port}${RESET}"
        return 1
    }

    if [ "$service_name" = "snell" ] && { systemctl is-active --quiet snell.socket 2>/dev/null || systemctl is-enabled --quiet snell.socket 2>/dev/null; }; then
        echo -e "${RED}Обнаружено использование snell.socket; автоматический перевод основного Snell в режим ShadowTLS-бэкенда пока невозможен${RESET}"
        echo -e "${YELLOW}Пожалуйста, отключите socket-активацию в скрипте управления Snell перед настройкой ShadowTLS.${RESET}"
        return 1
    fi

    if grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${port}[[:space:]]*$" "$conf"; then
        echo -e "${GREEN}Порт Snell ${port} уже слушает только 127.0.0.1${RESET}"
    else
        cp -a "$conf" "${conf}.bak.$(date +%Y%m%d%H%M%S)"
        sed -i "s|^[[:space:]]*listen[[:space:]]*=.*:${port}[[:space:]]*$|listen = 127.0.0.1:${port}|" "$conf"

        if ! grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:${port}[[:space:]]*$" "$conf"; then
            echo -e "${RED}Не удалось изменить адрес прослушивания Snell: ${conf}${RESET}"
            return 1
        fi

        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$conf" 2>/dev/null || true
        fi
        chmod 644 "$conf" 2>/dev/null || true

        echo -e "${GREEN}Порт Snell ${port} переведен на локальный адрес 127.0.0.1${RESET}"
    fi

    systemctl restart "$service_name"
    close_port "$port"
    echo -e "${GREEN}Внешний доступ к исходному порту Snell ${port} закрыт в фаерволе; клиенты должны подключаться через порт ShadowTLS${RESET}"
}

# Получение мажорной версии Snell (4 / 5 / 6) для бэкенд-порта
# Если порт не передан, возвращается версия для порта основного пользователя.
get_snell_version() {
    local port="${1:-$(get_snell_port)}"
    local version

    if [ -z "$port" ]; then
        version=$(detect_installed_snell_version)
    else
        version=$(get_port_snell_version "$port")
    fi

    case "$version" in
        v6) echo "6" ;;
        v5) echo "5" ;;
        v4) echo "4" ;;
        *)  return 1 ;;
    esac
}

# Получение IP-адреса сервера
get_server_ip() {
    local ipv4
    local ipv6
    
    # Получение адреса IPv4
    ipv4=$(curl -s -4 ip.sb 2>/dev/null)
    
    # Получение адреса IPv6
    ipv6=$(curl -s -6 ip.sb 2>/dev/null)
    
    # Определение типа IP и возврат значения
    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        # Dual-stack, приоритет отдается IPv4
        echo "$ipv4"
    elif [ -n "$ipv4" ]; then
        # Только IPv4
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        # Только IPv6
        echo "$ipv6"
    else
        echo -e "${RED}Не удалось получить IP-адрес сервера${RESET}"
        return 1
    fi
    
    return 0
}

# Проверка формата команд shadow-tls
check_shadowtls_command() {
    local help_output
    help_output=$($INSTALL_DIR/shadow-tls --help 2>&1)
    echo -e "${YELLOW}Справка shadow-tls:${RESET}"
    echo "$help_output"
    return 0
}

# Генерация безопасного Base64 (URL-safe)
urlsafe_base64() {
    date=$(echo -n "$1"|base64|sed ':a;N;s/\n/ /g;ta'|sed 's/ //g;s/=//g;s/+/-/g;s/\//_/g')
    echo -e "${date}"
}

# Генерация случайного порта
generate_random_port() {
    local min_port=10000
    local max_port=65535
    echo $(shuf -i ${min_port}-${max_port} -n 1)
}

# Проверка занятости порта
check_port_usage() {
    local port=$1

    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":${port}\b"; then
            return 0  # Порт занят
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":${port}\b"; then
            return 0  # Порт занят
        fi
    fi

    return 1     # Порт свободен
}

# Получение уже используемых портов ShadowTLS
get_used_stls_ports() {
    local used_ports=()
    
    # Проверка службы Shadowsocks
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    if [ -f "$ss_service" ]; then
        local ss_port=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_service")
        if [ ! -z "$ss_port" ]; then
            used_ports+=("$ss_port")
        fi
    fi
    
    # Проверка служб Snell
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port=$(grep -oP '(?<=--listen ::0:)\d+' "$service_file")
            if [ ! -z "$port" ]; then
                used_ports+=("$port")
            fi
        done <<< "$snell_services"
    fi
    
    echo "${used_ports[@]}"
}

# Проверка и выбор доступного порта
get_available_port() {
    local port=$1
    local used_ports=($(get_used_stls_ports))
    
    # Если порт указан пользователем
    if [ ! -z "$port" ]; then
        # Проверка, не используется ли порт другой службой ShadowTLS
        for used_port in "${used_ports[@]}"; do
            if [ "$port" = "$used_port" ]; then
                echo -e "${RED}Порт ${port} уже используется другой службой ShadowTLS${RESET}"
                return 1
            fi
        done
        
        # Проверка, не занят ли порт сторонними службами в системе
        if check_port_usage "$port"; then
            echo -e "${RED}Порт ${port} уже занят другой службой${RESET}"
            return 1
        fi
        
        echo "$port"
        return 0
    fi
    
    # Если порт не указан, генерация случайного
    local attempts=0
    while [ $attempts -lt 10 ]; do
        local random_port=$(generate_random_port)
        local is_used=0
        
        # Проверка среди портов ShadowTLS
        for used_port in "${used_ports[@]}"; do
            if [ "$random_port" = "$used_port" ]; then
                is_used=1
                break
            fi
        done
        
        # Если свободен в ShadowTLS и не занят в системе
        if [ $is_used -eq 0 ] && ! check_port_usage "$random_port"; then
            echo "$random_port"
            return 0
        fi
        
        attempts=$((attempts + 1))
    done
    
    echo -e "${RED}Не удалось найти свободный порт${RESET}"
    return 1
}

# Генерация ссылок и конфигураций Shadowsocks
generate_ss_links() {
    local server_ip=$1
    local listen_port=$2
    local ssrust_password=$3
    local ssrust_method=$4
    local stls_password=$5
    local stls_sni=$6
    local backend_port=$7
    
    echo -e "\n${YELLOW}=== Конфигурация сервера ===${RESET}"
    echo -e "IP сервера: ${server_ip}"
    echo -e "\nПараметры Shadowsocks:"
    echo -e "  - Порт: ${backend_port}"
    echo -e "  - Метод шифрования: ${ssrust_method}"
    echo -e "  - Пароль: ${ssrust_password}"
    echo -e "\nПараметры ShadowTLS:"
    echo -e "  - Порт: ${listen_port}"
    echo -e "  - Пароль: ${stls_password}"
    echo -e "  - SNI: ${stls_sni}"
    echo -e "  - Версия: 3"
    
    # Генерация объединенной ссылки SS + ShadowTLS
    local userinfo=$(echo -n "${ssrust_method}:${ssrust_password}" | base64 | tr -d '\n')
    local shadow_tls_config="plugin=shadow-tls;host=${stls_sni};password=${stls_password};version=3"
    local ss_url="ss://${userinfo}@${server_ip}:${listen_port}?${shadow_tls_config}"

    echo -e "\n${YELLOW}=== Конфигурация для Surge ===${RESET}"
    echo -e "SS-${server_ip} = ss, ${server_ip}, ${listen_port}, encrypt-method=${ssrust_method}, password=${ssrust_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
    
    echo -e "\n${YELLOW}=== Инструкция по настройке Shadowrocket ===${RESET}"
    echo -e "1. Добавьте узел Shadowsocks:"
    echo -e "   - Тип: Shadowsocks"
    echo -e "   - Адрес: ${server_ip}"
    echo -e "   - Порт: ${backend_port}"
    echo -e "   - Метод шифрования: ${ssrust_method}"
    echo -e "   - Пароль: ${ssrust_password}"
    
    echo -e "\n2. Добавьте узел ShadowTLS:"
    echo -e "   - Тип: ShadowTLS"
    echo -e "   - Адрес: ${server_ip}"
    echo -e "   - Порт: ${listen_port}"
    echo -e "   - Пароль: ${stls_password}"
    echo -e "   - SNI: ${stls_sni}"
    echo -e "   - Версия: 3"

    echo -e "\n${YELLOW}=== Ссылка для импорта в Shadowrocket ===${RESET}"
    echo -e "${GREEN}Ссылка SS + ShadowTLS: ${RESET}${ss_url}"
    
    echo -e "\n${YELLOW}=== QR-код для Shadowrocket ===${RESET}"
    qrencode -t UTF8 "${ss_url}"
    
    echo -e "\n${YELLOW}=== Конфигурация для Clash Meta ===${RESET}"
    echo -e "proxies:"
    echo -e "  - name: SS-${server_ip}"
    echo -e "    type: ss"
    echo -e "    server: ${server_ip}"
    echo -e "    port: ${listen_port}"
    echo -e "    cipher: ${ssrust_method}"
    echo -e "    password: \"${ssrust_password}\""
    echo -e "    plugin: shadow-tls"
    echo -e "    plugin-opts:"
    echo -e "      host: \"${stls_sni}\""
    echo -e "      password: \"${stls_password}\""
    echo -e "      version: 3"
}

# Генерация ссылок и конфигураций Snell
generate_snell_links() {
    local server_ip=$1
    local listen_port=$2
    local snell_psk=$3
    local stls_password=$4
    local stls_sni=$5
    local backend_port=$6
    
    # Версия берется из конфигурации конкретного бэкенд-порта
    local snell_version=$(get_snell_version "$backend_port")
    
    echo -e "\n${YELLOW}=== Конфигурация сервера ===${RESET}"
    echo -e "IP сервера: ${server_ip}"
    echo -e "\nПараметры Snell:"
    echo -e "  - Порт: ${backend_port}"
    echo -e "  - PSK: ${snell_psk}"
    echo -e "  - Версия: ${snell_version}"
    echo -e "\nПараметры ShadowTLS:"
    echo -e "  - Порт: ${listen_port}"
    echo -e "  - Пароль: ${stls_password}"
    echo -e "  - SNI: ${stls_sni}"
    echo -e "  - Версия: 3"
    
    echo -e "\n${YELLOW}=== Конфигурация для Surge ===${RESET}"
    
    # Для v5 выводятся варианты записи v4 и v5; для v6 дополнительно передается параметр mode
    print_snell_shadowtls_line "Snell + ShadowTLS" "$server_ip" "$listen_port" "$snell_psk" \
        "$stls_password" "$stls_sni" "$backend_port"
}

# Запрос на включение wildcard-sni (по умолчанию выключено)
prompt_wildcard_sni() {
    wildcard_sni="off"
    echo -e "${YELLOW}Включить режим wildcard-sni=authed?${RESET}"
    echo -e "После включения авторизованные клиенты смогут использовать SNI, отличный от серверного"
    read -rp "Включить wildcard-sni=authed? [y/N]: " wildcard_choice
    case "$wildcard_choice" in
        [yY]|[yY][eE][sS])
            wildcard_sni="authed"
            echo -e "${GREEN}Параметр wildcard-sni=authed включен${RESET}"
            ;;
        *)
            echo -e "${GREEN}Оставлено значение по умолчанию (wildcard-sni выключен)${RESET}"
            ;;
    esac
}

# Включение TCP Fast Open
enable_tcp_fastopen() {
    # Применение немедленно
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1

    # Сохранение конфигурации для применения после перезагрузки
    if [ -d /etc/sysctl.d ]; then
        echo "net.ipv4.tcp_fastopen = 3" > /etc/sysctl.d/99-tcp-fastopen.conf
    elif ! grep -q "^net.ipv4.tcp_fastopen" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
    fi
}

# Шаблон создания unit-файла systemd
create_shadowtls_service() {
    local service_type=$1  # ss или snell
    local port=$2
    local listen_port=$3
    local tls_domain=$4
    local password=$5
    local service_file
    local description
    local identifier
    
    if [ "$service_type" = "ss" ]; then
        service_file="${SYSTEMD_DIR}/shadowtls-ss.service"
        description="Служба Shadow-TLS Server для Shadowsocks"
        identifier="shadow-tls-ss"
    else
        service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
        description="Служба Shadow-TLS Server для Snell (Порт: ${port})"
        identifier="shadow-tls-snell-${port}"
    fi

    # Включение TCP Fast Open (параметры ядра)
    enable_tcp_fastopen

    # Флаг wildcard-sni (по умолчанию off, аргумент не добавляется)
    local wildcard_sni_flag=""
    if [ "$wildcard_sni" = "authed" ] || [ "$wildcard_sni" = "all" ]; then
        wildcard_sni_flag=" --wildcard-sni ${wildcard_sni}"
    fi

    cat > "$service_file" << EOF
[Unit]
Description=${description}
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_BACKTRACE=1
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen ::0:${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}${wildcard_sni_flag}
StandardOutput=append:/var/log/shadowtls-${identifier}.log
StandardError=append:/var/log/shadowtls-${identifier}.log
SyslogIdentifier=${identifier}
Restart=always
RestartSec=3

# Параметры оптимизации производительности
LimitNOFILE=65535
CPUAffinity=0
Nice=0
IOSchedulingClass=realtime
IOSchedulingPriority=0
MemoryMax=512M
CPUQuota=50%
LimitCORE=infinity
LimitRSS=infinity
LimitNPROC=65535
LimitAS=infinity
SystemCallFilter=@system-service
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Параметры системной оптимизации
Environment=RUST_THREADS=1
Environment=MONOIO_FORCE_LEGACY_DRIVER=1
Environment=RUST_LOG_LEVEL=info
Environment=RUST_LOG_TARGET=journal
Environment=RUST_LOG_FORMAT=json
Environment=RUST_LOG_FILTER=info,shadow_tls=info

[Install]
WantedBy=multi-user.target
EOF

    # Создание файла лога и установка прав доступа
    touch "/var/log/shadowtls-${identifier}.log"
    chmod 640 "/var/log/shadowtls-${identifier}.log"
    chown root:root "/var/log/shadowtls-${identifier}.log"
}

# Установка ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}Установка ShadowTLS...${RESET}"

    install_requirements
    
    # Проверка установленных протоколов
    local has_ss=false
    local has_snell=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}Обнаружен установленный Shadowsocks Rust${RESET}"
    fi
    
    if check_snell_config; then
        has_snell=true
        echo -e "${GREEN}Обнаружен установленный Snell${RESET}"
    elif check_snell; then
        echo -e "${YELLOW}Бинарный файл Snell найден, но основной конфиг недоступен. Настройка ShadowTLS для Snell пока невозможна${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}Не обнаружены Shadowsocks Rust или Snell. Сначала установите один из них${RESET}"
        return 1
    fi
    
    # Определение архитектуры системы и загрузка ShadowTLS
    arch=$(uname -m)
    case $arch in
        x86_64|amd64)
            arch="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            arch="aarch64-unknown-linux-musl"
            ;;
        armv7l|armv7)
            arch="armv7-unknown-linux-musleabihf"
            ;;
        arm)
            arch="arm-unknown-linux-musleabi"
            ;;
        *)
            echo -e "${RED}Неподдерживаемая архитектура системы: $arch${RESET}"
            exit 1
            ;;
    esac

    # Получение последней версии
    version=$(get_latest_version)

    # Попытка загрузки: сначала напрямую с GitHub, при сбое через зеркало ghproxy
    binary_name="shadow-tls-${arch}"
    github_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/${binary_name}"
    proxy_url="https://ghproxy.com/${github_url}"

    echo -e "${CYAN}Загрузка ShadowTLS ${version} (${arch})...${RESET}"
    echo -e "${YELLOW}URL загрузки: ${github_url}${RESET}"

    if ! wget --timeout=30 --tries=2 -q "$github_url" -O "/tmp/shadow-tls.tmp" 2>/dev/null; then
        echo -e "${YELLOW}Прямое подключение к GitHub не удалось, попытка загрузки через зеркало...${RESET}"
        echo -e "${YELLOW}URL зеркала: ${proxy_url}${RESET}"
        if ! wget --timeout=60 --tries=3 "$proxy_url" -O "/tmp/shadow-tls.tmp"; then
            echo -e "${RED}Ошибка загрузки ShadowTLS, проверьте сетевое подключение и повторите попытку${RESET}"
            rm -f "/tmp/shadow-tls.tmp"
            exit 1
        fi
    fi

    # Проверка, что скачанный файл не пустой
    if [ ! -s "/tmp/shadow-tls.tmp" ]; then
        echo -e "${RED}Скачанный файл пуст, повторите попытку${RESET}"
        rm -f "/tmp/shadow-tls.tmp"
        exit 1
    fi
    
    # Перемещение в целевую директорию и установка прав исполнения
    mv "/tmp/shadow-tls.tmp" "$INSTALL_DIR/shadow-tls"
    chmod +x "$INSTALL_DIR/shadow-tls"
    
    # Генерация случайного пароля
    password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    
    # Запрос маскировочного домена TLS
    read -rp "Введите домен для TLS маскировки (Enter для значения по умолчанию www.microsoft.com): " tls_domain
    if [ -z "$tls_domain" ]; then
        tls_domain="www.microsoft.com"
    fi
    prompt_wildcard_sni
    
    # Выбор протокола для настройки ShadowTLS
    while true; do
        echo -e "\n${YELLOW}Выберите протокол для настройки:${RESET}"
        echo -e "1. Настроить ShadowTLS для Shadowsocks"
        echo -e "2. Настроить ShadowTLS для Snell"
        echo -e "3. Настроить ShadowTLS для обоих протоколов"
        echo -e "0. Выход"
        
        read -rp "Выберите пункт [0-3]: " protocol_choice
        
        case "$protocol_choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss; then
                    echo -e "${RED}Shadowsocks не установлен${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=false
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}Snell не установлен${RESET}"
                    continue
                fi
                configure_ss=false
                configure_snell=true
                break
                ;;
            3)
                if ! $has_ss || ! $has_snell; then
                    echo -e "${RED}Требуется установка как Shadowsocks, так и Snell${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=true
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
    
    # Настройка Shadowsocks
    if $configure_ss; then
        echo -e "\n${YELLOW}Настройка ShadowTLS для Shadowsocks...${RESET}"
        while true; do
            read -rp "Введите порт прослушивания ShadowTLS (1-65535, Enter для генерации случайного): " ss_listen_port
            
            # Проверка и получение доступного порта
            ss_listen_port=$(get_available_port "$ss_listen_port")
            if [ $? -eq 0 ]; then
                break
            fi
            echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
        done
        
        echo -e "${GREEN}Будет использован порт: ${ss_listen_port}${RESET}"
        
        # Создание сервиса ShadowTLS для Shadowsocks
        local ss_port=$(get_ssrust_port)
        create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
        open_port "$ss_listen_port"
        systemctl start shadowtls-ss
        systemctl enable shadowtls-ss
    fi
    
    # Настройка Snell
    if $configure_snell; then
        echo -e "\n${YELLOW}Настройка ShadowTLS для Snell...${RESET}"
        
        # Получение конфигураций пользователей Snell
        local user_configs=$(get_all_snell_users)
        if [ -z "$user_configs" ]; then
            echo -e "${RED}Действующие конфигурации пользователей Snell не найдены${RESET}"
            return 1
        fi
        
        # Вывод списка портов Snell
        echo -e "\n${YELLOW}Текущий список портов Snell:${RESET}"
        local port_list=()
        while IFS='|' read -r port psk; do
            if [ ! -z "$port" ]; then
                port_list+=("$port")
                if [ "$port" = "$(get_snell_port)" ]; then
                    echo -e "${GREEN}${#port_list[@]}. ${port} (Основной пользователь)${RESET}"
                else
                    echo -e "${GREEN}${#port_list[@]}. ${port}${RESET}"
                fi
            fi
        done <<< "$user_configs"
        
        # Выбор портов для настройки
        echo -e "\n${YELLOW}Выберите порт для настройки:${RESET}"
        echo -e "1-${#port_list[@]}. Выбрать конкретный порт"
        echo -e "0. Настроить ShadowTLS для всех портов"
        
        read -rp "Ваш выбор: " port_choice
        
        if [ "$port_choice" = "0" ]; then
            # Настройка ShadowTLS для всех портов
            for port in "${port_list[@]}"; do
                echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${port}${RESET}"
                while true; do
                    read -rp "Введите порт прослушивания ShadowTLS (1-65535, Enter для генерации случайного): " stls_port
                    
                    # Проверка и получение доступного порта
                    stls_port=$(get_available_port "$stls_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                done
                
                echo -e "${GREEN}Будет использован порт: ${stls_port}${RESET}"
                
                restrict_snell_to_loopback "$port" || return 1

                # Создание unit-файла сервиса
                create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                open_port "$stls_port"
                systemctl start "shadowtls-snell-${port}"
                systemctl enable "shadowtls-snell-${port}"
            done
        elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
            # Настройка ShadowTLS для выбранного порта
            local selected_port="${port_list[$((port_choice-1))]}"
            echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${selected_port}${RESET}"
            while true; do
                read -rp "Введите порт прослушивания ShadowTLS (1-65535, Enter для генерации случайного): " stls_port
                
                # Проверка и получение доступного порта
                stls_port=$(get_available_port "$stls_port")
                if [ $? -eq 0 ]; then
                    break
                fi
                echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
            done
            
            echo -e "${GREEN}Будет использован порт: ${stls_port}${RESET}"
            
            restrict_snell_to_loopback "$selected_port" || return 1

            # Создание unit-файла сервиса
            create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
            open_port "$stls_port"
            systemctl start "shadowtls-snell-${selected_port}"
            systemctl enable "shadowtls-snell-${selected_port}"
        else
            echo -e "${RED}Неверный выбор${RESET}"
            return 1
        fi
    fi
    
    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    
    # Получение IP-адреса сервера
    local server_ip=$(get_server_ip)
    
    echo -e "\n${GREEN}=== Установка ShadowTLS успешно завершена ===${RESET}"
    
    # Вывод всех сгенерированных конфигураций
    if $configure_ss; then
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        local ss_port=$(get_ssrust_port)
        generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi
    
    if $configure_snell; then
        while IFS='|' read -r port psk; do
            if [ ! -z "$port" ]; then
                local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                if [ -f "$service_file" ]; then
                    local stls_port=$(grep -oP '(?<=--listen ::0:)\d+' "$service_file")
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                fi
            fi
        done <<< "$user_configs"
    fi

    echo -e "\n${GREEN}Службы запущены и добавлены в автозагрузку${RESET}"
}

# Удаление ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}Удаление ShadowTLS...${RESET}"
    
    # Остановка и отключение службы Shadowsocks
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        local ss_listen_port
        ss_listen_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "${SYSTEMD_DIR}/shadowtls-ss.service" | head -n 1)
        systemctl stop shadowtls-ss 2>/dev/null
        systemctl disable shadowtls-ss 2>/dev/null
        rm -f "${SYSTEMD_DIR}/shadowtls-ss.service"
        if [ -n "$ss_listen_port" ]; then
            close_port "$ss_listen_port"
        fi
    fi
    
    # Остановка и отключение всех служб ShadowTLS для Snell
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local service_name=$(basename "$service_file")
            local listen_port
            listen_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
            if [ -n "$listen_port" ]; then
                close_port "$listen_port"
            fi
        done <<< "$snell_services"
    fi
    
    # Удаление бинарного файла
    rm -f "$INSTALL_DIR/shadow-tls"
    
    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}ShadowTLS успешно удален${RESET}"
}

# Просмотр конфигурации
view_config() {
    echo -e "${CYAN}Получение данных конфигурации...${RESET}"
    
    # Проверка установленных служб
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    
    if [ ! -f "$ss_service" ] && [ -z "$snell_services" ]; then
        echo -e "${RED}ShadowTLS не установлен${RESET}"
        return 1
    fi
    
    # Получение IP-адреса сервера
    local server_ip=$(get_server_ip)
    
    # Проверка Shadowsocks и получение параметров
    if [ -f "$ss_service" ] && check_ssrust; then
        echo -e "\n${YELLOW}=== Конфигурация Shadowsocks + ShadowTLS ===${RESET}"
        local ss_listen_port=$(grep -oP '(?<=--listen ::0:)\d+' "$ss_service")
        local tls_domain=$(grep -oP '(?<=--tls )[^ ]+' "$ss_service")
        local password=$(grep -oP '(?<=--password )[^ ]+' "$ss_service")
        local ss_port=$(get_ssrust_port)
        local ssrust_password=$(get_ssrust_password)
        local ssrust_method=$(get_ssrust_method)
        
        if [ ! -z "$ss_listen_port" ] && [ ! -z "$tls_domain" ] && [ ! -z "$password" ]; then
            generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
        else
            echo -e "${RED}Файл конфигурации SS поврежден или неполон${RESET}"
        fi
    fi
    
    # Проверка Snell и получение параметров
    if [ ! -z "$snell_services" ] && check_snell; then
        echo -e "\n${YELLOW}=== Конфигурация Snell + ShadowTLS ===${RESET}"
        
        # Получение конфигураций всех пользователей
        local user_configs=$(get_all_snell_users)
        if [ ! -z "$user_configs" ]; then
            # Ассоциативный массив для исключения повторной обработки портов
            declare -A processed_ports
            
            while IFS='|' read -r port psk; do
                if [ ! -z "$port" ] && [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    
                    # Получение настроек соответствующей службы ShadowTLS
                    local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                    if [ -f "$service_file" ]; then
                        local exec_line=$(grep "ExecStart=" "$service_file")
                        local stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
                        local stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
                        local stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
                        
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "\n${GREEN}Конфигурация основного пользователя:${RESET}"
                        else
                            echo -e "\n${GREEN}Конфигурация пользователя (Порт Snell: ${port}):${RESET}"
                        fi
                        
                        if [ ! -z "$stls_port" ] && [ ! -z "$stls_password" ] && [ ! -z "$stls_domain" ]; then
                            echo -e "${YELLOW}Параметры Snell:${RESET}"
                            echo -e "  - Порт: ${port}"
                            echo -e "  - PSK: ${psk}"
                            
                            echo -e "\n${YELLOW}Параметры ShadowTLS:${RESET}"
                            echo -e "  - Порт прослушивания: ${stls_port}"
                            echo -e "  - Пароль: ${stls_password}"
                            echo -e "  - SNI: ${stls_domain}"
                            echo -e "  - Версия: 3"
                            
                            echo -e "\n${GREEN}Конфигурация Surge:${RESET}"
                            echo -e "${YELLOW}Версия Snell: $(get_port_snell_version "$port")${RESET}"
                            print_snell_shadowtls_line "Snell + ShadowTLS" "$server_ip" "$stls_port" "$psk" \
                                "$stls_password" "$stls_domain" "$port"
                            
                            # Проверка состояния службы
                            local service_status=$(systemctl is-active "shadowtls-snell-${port}")
                            if [ "$service_status" = "active" ]; then
                                echo -e "\n${GREEN}Статус службы: Работает${RESET}"
                                # Проверка конфликта портов
                                local port_usage=$(netstat -tuln | grep ":${stls_port}")
                                local port_count=$(echo "$port_usage" | wc -l)
                                if [ "$port_count" -gt 1 ]; then
                                    echo -e "${RED}Внимание: порт ${stls_port} занят несколькими службами!${RESET}"
                                    echo -e "${YELLOW}Информация о занятости порта:${RESET}"
                                    netstat -tuln | grep ":${stls_port}"
                                fi
                            else
                                echo -e "\n${RED}Статус службы: Не работает${RESET}"
                                echo -e "${YELLOW}Попробуйте перезапустить службу командой:${RESET}"
                                echo -e "systemctl restart shadowtls-snell-${port}"
                            fi
                        else
                            echo -e "${RED}Файл конфигурации поврежден или неполон${RESET}"
                        fi
                    else
                        echo -e "\n${YELLOW}Конфигурация ShadowTLS для пользователя (порт: ${port}) не найдена${RESET}"
                    fi
                fi
            done <<< "$user_configs"
        else
            echo -e "\n${YELLOW}Действующие конфигурации пользователей Snell не найдены${RESET}"
        fi
    fi
    
    # Вывод статуса служб
    echo -e "\n${YELLOW}=== Статус служб ShadowTLS ===${RESET}"
    
    # Статус службы SS
    if [ -f "$ss_service" ]; then
        echo -e "\n${YELLOW}Статус службы SS:${RESET}"
        systemctl status shadowtls-ss --no-pager
        
        # Если служба не запущена, вывести команду перезапуска
        if [ "$(systemctl is-active shadowtls-ss)" != "active" ]; then
            echo -e "\n${YELLOW}Служба SS не запущена. Команда для перезапуска:${RESET}"
            echo -e "systemctl restart shadowtls-ss"
        fi
    fi
    
    # Статус всех служб Snell (без дублирования)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}Статус служб Snell:${RESET}"
        declare -A shown_services
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            if [ -z "${shown_services[$port]}" ]; then
                shown_services[$port]=1
                echo -e "\n${GREEN}Статус службы ShadowTLS для порта Snell ${port}:${RESET}"
                systemctl status "shadowtls-snell-${port}" --no-pager
                
                # Если служба не запущена, вывести команду перезапуска
                if [ "$(systemctl is-active shadowtls-snell-${port})" != "active" ]; then
                    echo -e "\n${YELLOW}Служба не запущена. Команда для перезапуска:${RESET}"
                    echo -e "systemctl restart shadowtls-snell-${port}"
                fi
            fi
        done <<< "$snell_services"
    fi
}

# Добавление конфигурации ShadowTLS
add_shadowtls_config() {
    echo -e "${CYAN}Добавление новой конфигурации ShadowTLS...${RESET}"
    
    # Проверка установленных протоколов
    local has_ss=false
    local has_snell=false
    local has_ss_stls=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}Обнаружен установленный Shadowsocks Rust${RESET}"
        if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
            has_ss_stls=true
            echo -e "${YELLOW}Конфигурация ShadowTLS для Shadowsocks уже существует${RESET}"
        fi
    fi
    
    if check_snell_config; then
        has_snell=true
        echo -e "${GREEN}Обнаружен установленный Snell${RESET}"
    elif check_snell; then
        echo -e "${YELLOW}Бинарный файл Snell найден, но основной конфиг недоступен. Добавление конфигурации пока невозможно${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}Не обнаружены Shadowsocks Rust или Snell. Сначала установите один из них${RESET}"
        return 1
    fi
    
    # Выбор протокола для добавления конфигурации
    while true; do
        echo -e "\n${YELLOW}Выберите протокол для добавления конфигурации:${RESET}"
        if $has_ss && ! $has_ss_stls; then
            echo -e "1. Добавить конфигурацию ShadowTLS для Shadowsocks"
        fi
        if $has_snell; then
            echo -e "2. Добавить конфигурацию ShadowTLS для Snell"
        fi
        echo -e "0. Назад"
        
        read -rp "Ваш выбор: " choice
        
        case "$choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss || $has_ss_stls; then
                    echo -e "${RED}Неверный выбор${RESET}"
                    continue
                fi
                # Получение необходимых параметров
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                read -rp "Введите домен для TLS маскировки (Enter для значения по умолчанию www.microsoft.com): " tls_domain
                if [ -z "$tls_domain" ]; then
                    tls_domain="www.microsoft.com"
                fi
                prompt_wildcard_sni
                
                # Настройка ShadowTLS для SS
                while true; do
                    read -rp "Введите порт прослушивания ShadowTLS (1-65535, Enter для генерации случайного): " ss_listen_port
                    
                    # Проверка и получение доступного порта
                    ss_listen_port=$(get_available_port "$ss_listen_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                done
                
                # Создание службы ShadowTLS для SS
                local ss_port=$(get_ssrust_port)
                create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
                open_port "$ss_listen_port"
                systemctl start shadowtls-ss
                systemctl enable shadowtls-ss
                
                # Вывод конфигурации
                local server_ip=$(get_server_ip)
                local ssrust_password=$(get_ssrust_password)
                local ssrust_method=$(get_ssrust_method)
                generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}Неверный выбор${RESET}"
                    continue
                fi
                
                # Получение необходимых параметров
                password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
                read -rp "Введите домен для TLS маскировки (Enter для значения по умолчанию www.microsoft.com): " tls_domain
                if [ -z "$tls_domain" ]; then
                    tls_domain="www.microsoft.com"
                fi
                prompt_wildcard_sni
                
                # Получение конфигураций всех пользователей Snell
                local user_configs=$(get_all_snell_users)
                if [ -z "$user_configs" ]; then
                    echo -e "${RED}Действующие конфигурации пользователей Snell не найдены${RESET}"
                    return 1
                fi
                
                # Вывод списка ненастроенных портов Snell
                echo -e "\n${YELLOW}Список портов Snell без конфигурации ShadowTLS:${RESET}"
                local port_list=()
                local port_count=0
                while IFS='|' read -r port psk; do
                    if [ ! -z "$port" ] && [ ! -f "${SYSTEMD_DIR}/shadowtls-snell-${port}.service" ]; then
                        port_list+=("$port")
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "${GREEN}$((++port_count)). ${port} (Основной пользователь)${RESET}"
                        else
                            echo -e "${GREEN}$((++port_count)). ${port}${RESET}"
                        fi
                    fi
                done <<< "$user_configs"
                
                if [ ${#port_list[@]} -eq 0 ]; then
                    echo -e "${YELLOW}Для всех портов Snell уже настроен ShadowTLS${RESET}"
                    return 0
                fi
                
                # Выбор портов для настройки
                echo -e "\n${YELLOW}Выберите порт для настройки:${RESET}"
                echo -e "1-${#port_list[@]}. Выбрать конкретный порт"
                echo -e "0. Настроить ShadowTLS для всех оставшихся портов"
                
                read -rp "Ваш выбор: " port_choice
                
                if [ "$port_choice" = "0" ]; then
                    # Настройка ShadowTLS для всех ненастроенных портов
                    for port in "${port_list[@]}"; do
                        echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${port}${RESET}"
                        while true; do
                            read -rp "Введите порт прослушивания ShadowTLS (1-65535, Enter для генерации случайного): " stls_port
                            
                            # Проверка и получение доступного порта
                            stls_port=$(get_available_port "$stls_port")
                            if [ $? -eq 0 ]; then
                                break
                            fi
                            echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                        done
                        
                        restrict_snell_to_loopback "$port" || return 1

                        # Создание unit-файла сервиса
                        create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                        open_port "$stls_port"
                        systemctl start "shadowtls-snell-${port}"
                        systemctl enable "shadowtls-snell-${port}"
                        
                        # Вывод конфигурации
                        local server_ip=$(get_server_ip)
                        local psk=$(get_snell_config "$port")
                        generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                    done
                elif [[ "$port_choice" =~ ^[0-9]+$ ]] && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le ${#port_list[@]} ]; then
                    # Настройка ShadowTLS для выбранного порта
                    local selected_port="${port_list[$((port_choice-1))]}"
                    echo -e "\n${YELLOW}Настройка ShadowTLS для порта Snell ${selected_port}${RESET}"
                    while true; do
                        read -rp "Введите порт прослушивания ShadowTLS (1-65535, Enter для генерации случайного): " stls_port
                        
                        # Проверка и получение доступного порта
                        stls_port=$(get_available_port "$stls_port")
                        if [ $? -eq 0 ]; then
                            break
                        fi
                        echo -e "${YELLOW}Пожалуйста, введите порт заново${RESET}"
                    done
                    
                    restrict_snell_to_loopback "$selected_port" || return 1

                    # Создание unit-файла сервиса
                    create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
                    open_port "$stls_port"
                    systemctl start "shadowtls-snell-${selected_port}"
                    systemctl enable "shadowtls-snell-${selected_port}"
                    
                    # Вывод конфигурации
                    local server_ip=$(get_server_ip)
                    local psk=$(get_snell_config "$selected_port")
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${selected_port}"
                else
                    echo -e "${RED}Неверный выбор${RESET}"
                    continue
                fi
                break
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
    
    # Перезагрузка конфигурации systemd
    systemctl daemon-reload
    echo -e "\n${GREEN}Добавление конфигурации завершено${RESET}"
}

# Перезапуск служб ShadowTLS
restart_shadowtls_services() {
    echo -e "${CYAN}Перезапуск служб ShadowTLS...${RESET}"
    
    local has_services=false
    
    # Перезапуск службы SS
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        has_services=true
        echo -e "\n${YELLOW}Перезапуск службы ShadowTLS для Shadowsocks...${RESET}"
        systemctl restart shadowtls-ss
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Служба ShadowTLS для Shadowsocks успешно перезапущена${RESET}"
        else
            echo -e "${RED}Ошибка перезапуска службы ShadowTLS для Shadowsocks${RESET}"
        fi
    fi
    
    # Перезапуск всех служб Snell
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ ! -z "$snell_services" ]; then
        has_services=true
        echo -e "\n${YELLOW}Перезапуск служб ShadowTLS для Snell...${RESET}"
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "Перезапуск службы для порта ${port}..."
            systemctl restart "shadowtls-snell-${port}"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}Служба для порта ${port} успешно перезапущена${RESET}"
            else
                echo -e "${RED}Ошибка перезапуска службы для порта ${port}${RESET}"
            fi
        done <<< "$snell_services"
    fi
    
    if ! $has_services; then
        echo -e "${RED}Службы ShadowTLS не найдены${RESET}"
        return 1
    fi
    
    echo -e "\n${GREEN}Все службы перезапущены${RESET}"
    
    # Вывод статуса служб
    echo -e "\n${YELLOW}Статус служб:${RESET}"
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ]; then
        echo -e "\n${CYAN}Статус службы ShadowTLS для Shadowsocks:${RESET}"
        systemctl status shadowtls-ss --no-pager
    fi
    
    if [ ! -z "$snell_services" ]; then
        while IFS= read -r service_file; do
            local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
            echo -e "\n${CYAN}Статус службы ShadowTLS для порта Snell ${port}:${RESET}"
            systemctl status "shadowtls-snell-${port}" --no-pager
        done <<< "$snell_services"
    fi
}

# Главное меню
main_menu() {
    while true; do
        echo -e "\n${CYAN}Меню управления ShadowTLS${RESET}"
        echo -e "${YELLOW}1. Установить ShadowTLS${RESET}"
        echo -e "${YELLOW}2. Удалить ShadowTLS${RESET}"
        echo -e "${YELLOW}3. Просмотреть конфигурацию${RESET}"
        echo -e "${YELLOW}4. Добавить конфигурацию${RESET}"
        echo -e "${YELLOW}5. Перезапустить службы${RESET}"
        echo -e "${YELLOW}6. Назад в предыдущее меню${RESET}"
        echo -e "${YELLOW}0. Выход${RESET}"
        
        if ! read -rp "Выберите действие [0-6]: " choice; then
            echo
            echo -e "${YELLOW}Ввод не получен, выход из меню ShadowTLS.${RESET}"
            return 0
        fi
        
        case "$choice" in
            1)
                install_shadowtls
                ;;
            2)
                uninstall_shadowtls
                ;;
            3)
                view_config
                ;;
            4)
                add_shadowtls_config
                ;;
            5)
                restart_shadowtls_services
                ;;
            6)
                return 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}Неверный выбор${RESET}"
                ;;
        esac
    done
}

# Проверка прав суперпользователя
check_root

# Запуск меню, если скрипт запущен напрямую
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main_menu
fi
