#!/bin/bash
# =========================================
# Автор: jinqians
# Дата: Февраль 2025
# Сайт: jinqians.com
# Описание: Скрипт для установки, удаления, просмотра и обновления прокси Snell
# =========================================

# Цветовые коды
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Текущая версия скрипта
current_version="5.5"

# Глобальная переменная: выбранная версия Snell
SNELL_VERSION_CHOICE=""

# Режим шифрования Snell v6: default / unshaped / unsafe-raw (клиент должен совпадать с сервером)
SNELL_MODE="default"

# Предпочтение семейства IP при резолве DNS в Snell v6: default / prefer-ipv4 / prefer-ipv6 / ipv4-only / ipv6-only
# Если оставить пустым, определяется автоматически по переключателю IPv6
SNELL_DNS_IP_PREFERENCE=""

# Флаг: задавал ли пользователь параметры v6 явно в этой сессии (влияет на перезапись конфига при обновлении)
SNELL_V6_OPTIONS_SET="false"

# Резервные версии на случай сбоя парсинга
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"

# === Функция выбора версии ===
select_snell_version() {
    echo -e "${CYAN}Выберите версию Snell для установки:${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)"

    while true; do
        read -rp "Введите пункт [1-3]: " version_choice
        case "$version_choice" in
            1)
                SNELL_VERSION_CHOICE="v4"
                echo -e "${GREEN}Выбран Snell v4${RESET}"
                break
                ;;
            2)
                SNELL_VERSION_CHOICE="v5"
                echo -e "${GREEN}Выбран Snell v5${RESET}"
                break
                ;;
            3)
                SNELL_VERSION_CHOICE="v6"
                echo -e "${GREEN}Выбран Snell v6 (RC)${RESET}"
                echo -e "${YELLOW}Внимание: v6 всё ещё в статусе пре-релиза, возможны несовместимые обновления протокола${RESET}"
                echo -e "${YELLOW}В v6 удалены режим QUIC и obfs, сборки под armv7l отсутствуют${RESET}"
                echo -e "${YELLOW}Режим шифрования: mode = ${SNELL_MODE} (на клиенте должен быть указан аналогичный mode)${RESET}"
                break
                ;;
            *)
                echo -e "${RED}Пожалуйста, выберите корректный пункт [1-3]${RESET}"
                ;;
        esac
    done
}

# === Настройка параметров Snell v6 ===
# Режим шифрования (mode): клиент и сервер обязаны иметь строго одинаковое значение
select_snell_v6_mode() {
    local current="$1"
    local default_choice="1"
    case "$current" in
        unshaped)   default_choice="2" ;;
        unsafe-raw) default_choice="3" ;;
    esac

    echo -e "\n${CYAN}=== Режим шифрования Snell v6 (mode) ===${RESET}"
    echo -e "${YELLOW}Клиент должен использовать строго тот же mode, что и сервер, иначе подключение не установится${RESET}\n"
    echo -e "${GREEN}1.${RESET} default     Обфускация трафика + шифрование AES"
    echo -e "   Максимальная маскировка сигнатуры, наилучшая устойчивость к анализу и блокировкам"
    echo -e "   ${CYAN}Рекомендация: подходит для большинства пользователей, при наличии помех на линии или QoS${RESET}"
    echo -e "${GREEN}2.${RESET} unshaped    Без обфускации, только шифрование AES"
    echo -e "   Пропускная способность выше примерно на 10% по сравнению с default, но сигнатура заметнее"
    echo -e "   ${CYAN}Рекомендация: чистые каналы, приоритет скорости или работа поверх внешнего слоя вроде ShadowTLS${RESET}"
    echo -e "${GREEN}3.${RESET} unsafe-raw  Открытый трафик без шифрования и без обфускации"
    echo -e "   ${RED}Данные передаются в открытом виде! Категорически не использовать в публичном интернете${RESET}"
    echo -e "   ${CYAN}Рекомендация: исключительно для тестов производительности внутри изолированных доверенных сетей${RESET}\n"

    while true; do
        read -rp "Выберите режим шифрования [1-3] (Enter — ${default_choice}): " mode_choice
        [ -z "$mode_choice" ] && mode_choice="$default_choice"
        case "$mode_choice" in
            1) SNELL_MODE="default";    break ;;
            2) SNELL_MODE="unshaped";   break ;;
            3)
                SNELL_MODE="unsafe-raw"
                echo -e "${RED}Предупреждение: unsafe-raw передает данные открытым текстом. Убедитесь в безопасности канала!${RESET}"
                read -rp "Подтверждаете использование unsafe-raw? [y/N]: " raw_confirm
                case "$raw_confirm" in
                    [yY]|[yY][eE][sS]) break ;;
                    *) echo -e "${CYAN}Отменено, выберите снова${RESET}" ;;
                esac
                ;;
            *) echo -e "${RED}Пожалуйста, выберите корректный пункт [1-3]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}Выбран mode = ${SNELL_MODE}${RESET}"
}

# Приоритет адресов при DNS-резолве (dns-ip-preference): задает тип исходящего подключения после резолва домена
select_snell_v6_dns_preference() {
    local current="$1"
    local default_choice="1"

    # Если не указано, вычисляем значение по умолчанию на основе флага IPv6
    if [ -z "$current" ]; then
        [ "$IPV6_ENABLE" = "false" ] && default_choice="4"
    else
        case "$current" in
            default)     default_choice="1" ;;
            prefer-ipv4) default_choice="2" ;;
            prefer-ipv6) default_choice="3" ;;
            ipv4-only)   default_choice="4" ;;
            ipv6-only)   default_choice="5" ;;
        esac
    fi

    echo -e "\n${CYAN}=== Приоритет DNS-резолва в Snell v6 (dns-ip-preference) ===${RESET}"
    echo -e "${YELLOW}Определяет, какой адрес сервер выбирает для исходящего трафика при резолве домена. Не влияет на адрес прослушивания.${RESET}\n"
    echo -e "${GREEN}1.${RESET} default       Стандартное поведение системного резолвера"
    echo -e "   ${CYAN}Рекомендация: если сомневаетесь — выбирайте этот вариант, подходит для большинства VPS${RESET}"
    echo -e "${GREEN}2.${RESET} prefer-ipv4   При наличии dual-stack приоритет IPv4, при сбое — переход на IPv6"
    echo -e "   ${CYAN}Рекомендация: плохое качество IPv6 маршрута или проблемы с доступностью сервисов по IPv6${RESET}"
    echo -e "${GREEN}3.${RESET} prefer-ipv6   При наличии dual-stack приоритет IPv6, при сбое — переход на IPv4"
    echo -e "   ${CYAN}Рекомендация: лучший маршрут по IPv6 или необходимость разблокировки стримингов через IPv6${RESET}"
    echo -e "${GREEN}4.${RESET} ipv4-only     Использовать исключительно IPv4-результаты"
    echo -e "   ${CYAN}Рекомендация: у VPS нет выхода в IPv6; исключает задержки по таймауту при попытках подключения по IPv6${RESET}"
    echo -e "${GREEN}5.${RESET} ipv6-only     Использовать исключительно IPv6-результаты"
    echo -e "   ${CYAN}Рекомендация: VPS только с IPv6 (отсутствует исходящий IPv4)${RESET}\n"

    while true; do
        read -rp "Выберите предпочтение DNS [1-5] (Enter — ${default_choice}): " dns_pref_choice
        [ -z "$dns_pref_choice" ] && dns_pref_choice="$default_choice"
        case "$dns_pref_choice" in
            1) SNELL_DNS_IP_PREFERENCE="default";     break ;;
            2) SNELL_DNS_IP_PREFERENCE="prefer-ipv4"; break ;;
            3) SNELL_DNS_IP_PREFERENCE="prefer-ipv6"; break ;;
            4) SNELL_DNS_IP_PREFERENCE="ipv4-only";   break ;;
            5) SNELL_DNS_IP_PREFERENCE="ipv6-only";   break ;;
            *) echo -e "${RED}Пожалуйста, выберите корректный пункт [1-5]${RESET}" ;;
        esac
    done
    echo -e "${GREEN}Выбран dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}${RESET}"
}

# Единая точка входа: вызывается при установке v6 или апгрейде до v6, может принимать текущий файл конфига
configure_snell_v6_options() {
    local conf_file="$1"
    local current_mode="" current_pref=""

    if [ -n "$conf_file" ] && [ -f "$conf_file" ]; then
        current_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
        current_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
        if [ -n "$current_mode" ] || [ -n "$current_pref" ]; then
            echo -e "${CYAN}Обнаружена текущая конфигурация: mode = ${current_mode:-не задан}, dns-ip-preference = ${current_pref:-не задан}${RESET}"
        fi
    fi

    select_snell_v6_mode "$current_mode"
    select_snell_v6_dns_preference "$current_pref"
    SNELL_V6_OPTIONS_SET="true"

    echo -e "\n${CYAN}=== Подтверждение параметров v6 ===${RESET}"
    echo -e "${GREEN}Серверный mode            : ${SNELL_MODE}${RESET}"
    echo -e "${GREEN}Серверный dns-ip-preference: ${SNELL_DNS_IP_PREFERENCE}${RESET}"
    echo -e "${YELLOW}Параметры для клиента: version = 6, mode = ${SNELL_MODE}${RESET}"
}

# Официальная страница релизов Snell
SNELL_RELEASE_NOTES_URL="https://kb.nssurge.com/surge-knowledge-base/release-notes/snell"
SNELL_RELEASE_NOTES_URL_ZH="https://kb.nssurge.com/surge-knowledge-base/zh/release-notes/snell"

# Загрузка страницы релизов
fetch_snell_release_notes() {
    local notes
    notes=$(curl -s --max-time 15 "$SNELL_RELEASE_NOTES_URL")
    if [ -z "$notes" ]; then
        notes=$(curl -s --max-time 15 "$SNELL_RELEASE_NOTES_URL_ZH")
    fi
    echo "$notes"
}

# Преобразование версии в ключ фиксированной длины для сортировки: beta < rc < релиз
# 6.0.0b4 -> 006.000.000.1.0004; 6.0.0rc -> 006.000.000.2.0000; 6.0.0rc2 -> 006.000.000.2.0002; 6.0.0 -> 006.000.000.3.0000
snell_version_sort_key() {
    echo "${1#[vV]}" | awk '{
        ver = $0
        suffix = ""
        if (match(ver, /[a-zA-Z]+[0-9]*$/)) {
            suffix = tolower(substr(ver, RSTART))
            ver = substr(ver, 1, RSTART - 1)
        }
        split(ver, part, ".")
        stage = 3
        seq = 0
        if (suffix != "") {
            stage = (suffix ~ /^rc/) ? 2 : 1
            digits = suffix
            gsub(/[^0-9]/, "", digits)
            if (digits != "") seq = digits + 0
        }
        printf "%03d.%03d.%03d.%d.%04d", part[1], part[2], part[3], stage, seq
    }'
}

# Извлечение актуальной версии для указанной мажорной ветки
pick_latest_snell_version() {
    local major="$1"
    local notes="$2"

    echo "$notes" \
        | grep -oE "snell-server-v${major}\.[0-9]+\.[0-9]+[a-zA-Z0-9]*" \
        | sed 's/^snell-server-v//' \
        | sort -u \
        | while read -r ver; do
              echo "$(snell_version_sort_key "$ver") ${ver}"
          done \
        | sort \
        | tail -n 1 \
        | awk '{print $2}'
}

# Получение последней версии Snell v4
get_latest_snell_v4_version() {
    local ver
    ver=$(pick_latest_snell_version 4 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V4_FALLBACK}"
    fi
}

# Получение последней версии Snell v5
get_latest_snell_v5_version() {
    local ver
    ver=$(pick_latest_snell_version 5 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V5_FALLBACK}"
    fi
}

# Получение последней версии Snell v6
get_latest_snell_v6_version() {
    local ver
    ver=$(pick_latest_snell_version 6 "$(fetch_snell_release_notes)")
    if [ -n "$ver" ]; then
        echo "v${ver}"
    else
        echo "${SNELL_V6_FALLBACK}"
    fi
}

# Чтение режима mode из установленного сервера v6 (при отсутствии — дефолт)
get_snell_mode() {
    local conf_file="${1:-${SNELL_CONF_DIR}/users/snell-main.conf}"
    local mode=""
    if [ -f "$conf_file" ]; then
        mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    fi
    if [ -z "$mode" ]; then
        mode="$SNELL_MODE"
    fi
    echo "$mode"
}

# Генерация конфигурационного файла snell-server
# В v6 используются mode / dns-ip-preference; параметр ipv6 устарел (false эквивалентен ipv4-only)
write_snell_conf() {
    local conf_file="$1"
    local listen_addr="$2"
    local port="$3"
    local psk="$4"
    local ipv6_enable="$5"
    local dns="$6"
    local version_choice="$7"

    {
        case "$version_choice" in
            v4|v5|v6) echo "#${SNELL_VERSION_MARKER_KEY} = ${version_choice}" ;;
        esac
        echo "[snell-server]"
        echo "listen = ${listen_addr}:${port}"
        echo "psk = ${psk}"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${SNELL_MODE}"
            if [ -n "$SNELL_DNS_IP_PREFERENCE" ]; then
                echo "dns-ip-preference = ${SNELL_DNS_IP_PREFERENCE}"
            elif [ "$ipv6_enable" = "false" ]; then
                echo "dns-ip-preference = ipv4-only"
            else
                echo "dns-ip-preference = default"
            fi
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
        echo "dns = ${dns}"
    } > "$conf_file"
}

# Синхронизация параметров конфигурации при смене версии: v6 использует mode / dns-ip-preference, v4/v5 — ipv6
migrate_snell_conf_for_version() {
    local conf_file="$1"
    local version_choice="$2"
    [ -f "$conf_file" ] || return 0

    local ipv6_enable="true"
    if grep -Eq '^[[:space:]]*ipv6[[:space:]]*=[[:space:]]*false' "$conf_file" \
        || grep -Eq '^[[:space:]]*dns-ip-preference[[:space:]]*=[[:space:]]*ipv4-only' "$conf_file"; then
        ipv6_enable="false"
    fi

    # Сохраняем существующие параметры v6; перезаписываем только если пользователь выбрал их явно
    local target_mode target_pref
    target_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')
    target_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$conf_file" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ')

    if [ "$SNELL_V6_OPTIONS_SET" = "true" ]; then
        target_mode="$SNELL_MODE"
        target_pref="$SNELL_DNS_IP_PREFERENCE"
    fi

    [ -z "$target_mode" ] && target_mode="$SNELL_MODE"
    if [ -z "$target_pref" ]; then
        if [ "$ipv6_enable" = "false" ]; then
            target_pref="ipv4-only"
        else
            target_pref="default"
        fi
    fi

    local tmp_conf="${conf_file}.tmp"
    {
        grep -Ev '^[[:space:]]*(ipv6|mode|dns-ip-preference)[[:space:]]*=' "$conf_file"
        if [ "$version_choice" = "v6" ]; then
            echo "mode = ${target_mode}"
            echo "dns-ip-preference = ${target_pref}"
        else
            echo "ipv6 = ${ipv6_enable}"
        fi
    } > "$tmp_conf" || {
        rm -f "$tmp_conf"
        echo -e "${RED}Ошибка формирования конфигурации: ${conf_file}${RESET}" >&2
        return 1
    }

    # Перезапись через cat сохраняет владельца и права исходного файла
    cat "$tmp_conf" > "$conf_file" || {
        rm -f "$tmp_conf"
        echo -e "${RED}Ошибка записи конфигурации: ${conf_file}${RESET}" >&2
        return 1
    }
    rm -f "$tmp_conf"

    # Обновление метки версии канала
    set_conf_snell_version "$conf_file" "$version_choice"
}

# Определение двухбуквенного кода страны IP-адреса (с резервными API)
get_ip_country() {
    local target="$1"
    local api=""
    local raw=""
    local result=""

    if [ -z "$target" ]; then
        echo "Unknown"
        return 1
    fi

    for api in "http://ipinfo.io/${target}/country" \
               "http://ip-api.com/line/${target}?fields=countryCode" \
               "https://ipwho.is/${target}?fields=country_code" \
               "https://ipapi.co/${target}/country/"; do
        raw=$(curl -s --connect-timeout 5 --max-time 10 "$api" 2>/dev/null)
        result=$(echo "$raw" | tr -d ' \t\r\n')
        case "$result" in
            [A-Za-z][A-Za-z]) ;;
            *) result=$(echo "$raw" | sed -n 's/.*"country_code"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' | head -n 1) ;;
        esac
        case "$result" in
            [A-Za-z][A-Za-z])
                echo "$result" | tr '[:lower:]' '[:upper:]'
                return 0
                ;;
        esac
    done

    echo "Unknown"
    return 1
}

# Генерация конфигурации в формате Surge
generate_surge_config() {
    local ip_addr=$1
    local port=$2
    local psk=$3
    local version=$4
    local country=$5
    local installed_version=$6

    if [ "$installed_version" = "v6" ]; then
        # Для версии v6: протокол v6 (без QUIC и obfs), mode обязан совпадать с сервером
        local mode
        mode=$(get_snell_mode "$(snell_conf_for_port "$port")")
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 6, mode = ${mode}, reuse = true, tfo = true${RESET}"
    elif [ "$installed_version" = "v5" ]; then
        # Для v5 выводим варианты v4 и v5
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 5, reuse = true, tfo = true${RESET}"
    else
        # Для v4 выводится только конфиг v4
        echo -e "${GREEN}${country} = snell, ${ip_addr}, ${port}, psk = ${psk}, version = 4, reuse = true, tfo = true${RESET}"
    fi
}

# Определение установленной версии Snell
detect_installed_snell_version() {
    if command -v snell-server &> /dev/null; then
        local version_output=$(snell-server --v 2>&1)
        if echo "$version_output" | grep -q "v6"; then
            echo "v6"
        elif echo "$version_output" | grep -q "v5"; then
            echo "v5"
        else
            echo "v4"
        fi
    else
        echo "unknown"
    fi
}

# === Функции резервного копирования и восстановления ===
backup_snell_config() {
    local backup_dir="${SNELL_CONF_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "${SNELL_CONF_DIR}/users"/*.conf "$backup_dir"/ 2>/dev/null
    echo "$backup_dir"
}

restore_snell_config() {
    local backup_dir="$1"
    if [ -d "$backup_dir" ]; then
        cp -a "$backup_dir"/*.conf "${SNELL_CONF_DIR}/users"/
        echo -e "${GREEN}Конфигурация успешно восстановлена из резервной копии.${RESET}"
    else
        echo -e "${RED}Каталог резервной копии не найден, восстановление невозможно.${RESET}"
    fi
}

# Проверка наличия bc
check_bc() {
    if ! command -v bc &> /dev/null; then
        echo -e "${YELLOW}Пакет bc не найден, установка...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y bc
        elif [ -x "$(command -v yum)" ]; then
            yum install -y bc
        else
            echo -e "${RED}Неподдерживаемый пакетный менеджер. Установите bc вручную.${RESET}"
            exit 1
        fi
    fi
}

# Проверка наличия curl
check_curl() {
    if ! command -v curl &> /dev/null; then
        echo -e "${YELLOW}Пакет curl не найден, установка...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y curl
        elif [ -x "$(command -v yum)" ]; then
            yum install -y curl
        else
            echo -e "${RED}Неподдерживаемый пакетный менеджер. Установите curl вручную.${RESET}"
            exit 1
        fi
    fi
}

# Системные пути
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
SYSTEMD_SERVICE_FILE="${SYSTEMD_DIR}/snell.service"
SYSTEMD_SOCKET_FILE="${SYSTEMD_DIR}/snell.socket"
SYSTEMD_NETNS_FILE="${SYSTEMD_DIR}/snell-netns.service"
NETNS_SETUP_SCRIPT="${INSTALL_DIR}/snell-netns-setup.sh"

# Параметры по умолчанию для управления исходящим трафиком (netns + socket activation)
EGRESS_FEATURE_ENABLED="false"
EGRESS_IFACE=""
EGRESS_NS="snell-egress"
EGRESS_HOST_IP=""
EGRESS_NS_IP=""
EGRESS_SUBNET=""
EGRESS_GW=""

# Устаревшие пути конфигурации (для проверки совместимости)
OLD_SNELL_CONF_FILE="${SNELL_CONF_DIR}/snell-server.conf"
OLD_SYSTEMD_SERVICE_FILE="/lib/systemd/system/snell.service"
SNELL_SERVICE_USER="snell"
SNELL_SERVICE_GROUP="snell"

# =========================================
# Поддержка одновременного сосуществования версий (v4 / v5 / v6)
# =========================================
SNELL_VERSION_MARKER_KEY="version-choice"
SNELL_ALL_VERSIONS="v4 v5 v6"

# Определение пути к бинарнику по версии
snell_binary_for_version() {
    case "$1" in
        v4|v5|v6) echo "${INSTALL_DIR}/snell-server-$1" ;;
        *)        echo "${INSTALL_DIR}/snell-server" ;;
    esac
}

# Определение версии самого бинарного файла
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
        # Ранние версии v4 в выводе --v не содержат мажорный номер, считаем v4
        echo "v4"
    fi
}

# Список фактически установленных бинарников каналов
list_installed_snell_versions() {
    local version installed=""
    for version in $SNELL_ALL_VERSIONS; do
        if [ -x "$(snell_binary_for_version "$version")" ]; then
            installed="${installed}${version} "
        fi
    done
    echo "${installed% }"
}

# Чтение маркера версии из файла конфигурации
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

# Определение версии для конфигурации: приоритет у маркера, затем проверка симлинка
get_conf_snell_version() {
    local conf_file="$1"
    local marked
    if marked=$(read_conf_snell_version "$conf_file"); then
        echo "$marked"
        return 0
    fi
    detect_installed_snell_version
}

# Идемпотентная запись маркера версии в первую строку конфига
set_conf_snell_version() {
    local conf_file="$1"
    local version="$2"

    [ -f "$conf_file" ] || return 1
    case "$version" in
        v4|v5|v6) ;;
        *) return 1 ;;
    esac

    local current=""
    current=$(read_conf_snell_version "$conf_file" 2>/dev/null)
    if [ "$current" = "$version" ]; then
        return 0
    fi

    local tmp_conf="${conf_file}.vtmp.$$"
    if ! {
        echo "#${SNELL_VERSION_MARKER_KEY} = ${version}"
        grep -Ev "^[[:space:]]*#[[:space:]]*${SNELL_VERSION_MARKER_KEY}[[:space:]]*=" "$conf_file"
    } > "$tmp_conf"; then
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось сформировать маркер версии: ${conf_file}${RESET}" >&2
        return 1
    fi

    if ! cat "$tmp_conf" > "$conf_file"; then
        rm -f "$tmp_conf"
        echo -e "${RED}Не удалось записать маркер версии: ${conf_file}${RESET}" >&2
        return 1
    fi
    rm -f "$tmp_conf"
    return 0
}

# Порт -> путь к файлу конфигурации
snell_conf_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "$SNELL_CONF_FILE"
    else
        echo "${SNELL_CONF_DIR}/users/snell-${port}.conf"
    fi
}

# Порт -> версия канала
get_port_snell_version() {
    get_conf_snell_version "$(snell_conf_for_port "$1")"
}

# Порт -> имя службы systemd
snell_service_for_port() {
    local port="$1"
    local main_port
    main_port=$(get_snell_port 2>/dev/null)
    if [ -n "$main_port" ] && [ "$port" = "$main_port" ]; then
        echo "snell"
    else
        echo "snell-${port}"
    fi
}

# Список служб, использующих указанный канал версии
list_services_using_version() {
    local version="$1"
    local conf_file port

    if [ -f "$SNELL_CONF_FILE" ] && [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        echo "snell"
    fi

    [ -d "${SNELL_CONF_DIR}/users" ] || return 0
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        [ -f "$conf_file" ] || continue
        case "$conf_file" in
            *snell-main.conf) continue ;;
        esac
        port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        [ -n "$port" ] || continue
        if [ "$(get_conf_snell_version "$conf_file")" = "$version" ]; then
            echo "snell-${port}"
        fi
    done
}

# Обновление симлинка snell-server на указанный канал
update_snell_symlink() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    if [ ! -x "$target" ]; then
        return 1
    fi

    if [ -e "${INSTALL_DIR}/snell-server" ] && [ ! -L "${INSTALL_DIR}/snell-server" ]; then
        rm -f "${INSTALL_DIR}/snell-server"
    fi
    ln -sfn "$target" "${INSTALL_DIR}/snell-server"
}

# Генерация URL для скачивания бинарника под архитектуру
snell_download_url_for() {
    local version_choice="$1"
    local resolved_version="$2"
    local arch
    arch=$(uname -m)

    if [ "$version_choice" = "v6" ] && { [ "$arch" = "armv7l" ] || [ "$arch" = "armv7" ]; }; then
        echo -e "${RED}Для Snell v6 отсутствуют сборки под armv7l${RESET}" >&2
        return 1
    fi

    case "$arch" in
        "x86_64"|"amd64")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-amd64.zip" ;;
        "i386"|"i686")     echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-i386.zip" ;;
        "aarch64"|"arm64") echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-aarch64.zip" ;;
        "armv7l"|"armv7")  echo "https://dl.nssurge.com/snell/snell-server-${resolved_version}-linux-armv7l.zip" ;;
        *)
            echo -e "${RED}Неподдерживаемая архитектура: ${arch}${RESET}" >&2
            return 1
            ;;
    esac
}

# Получение номера актуальной версии для канала
resolve_latest_version_for_channel() {
    case "$1" in
        v6) get_latest_snell_v6_version ;;
        v5) get_latest_snell_v5_version ;;
        v4) get_latest_snell_v4_version ;;
        *)  return 1 ;;
    esac
}

# Скачивание и установка бинарника для указанного канала
install_snell_binary_for_version() {
    local version="$1"
    local force="${2:-false}"
    local target
    target=$(snell_binary_for_version "$version")

    if [ -x "$target" ] && [ "$force" != "true" ]; then
        return 0
    fi

    local resolved
    resolved=$(resolve_latest_version_for_channel "$version")
    if [ -z "$resolved" ]; then
        echo -e "${RED}Не удалось определить номер версии для Snell ${version}${RESET}" >&2
        return 1
    fi

    local url
    if ! url=$(snell_download_url_for "$version" "$resolved"); then
        return 1
    fi

    echo -e "${CYAN}Загрузка Snell ${version} (${resolved})...${RESET}" >&2
    echo -e "${YELLOW}${url}${RESET}" >&2

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1

    local downloaded=false
    if command -v wget >/dev/null 2>&1; then
        wget -O "${tmp_dir}/snell-server.zip" "$url" && downloaded=true
    elif command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 -o "${tmp_dir}/snell-server.zip" "$url" && downloaded=true
    else
        echo -e "${RED}В системе отсутствуют wget и curl, скачивание невозможно${RESET}" >&2
    fi

    if [ "$downloaded" != "true" ]; then
        echo -e "${RED}Ошибка загрузки Snell ${version}: ${url}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! unzip -o -q "${tmp_dir}/snell-server.zip" -d "$tmp_dir"; then
        echo -e "${RED}Ошибка распаковки архива Snell ${version}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    if [ ! -f "${tmp_dir}/snell-server" ]; then
        echo -e "${RED}Исполняемый файл snell-server не найден в архиве${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi

    # install выполняет атомарную замену, работающий процесс удерживает старый inode
    if ! install -m 755 "${tmp_dir}/snell-server" "$target"; then
        echo -e "${RED}Ошибка записи в ${target}${RESET}" >&2
        rm -rf "$tmp_dir"
        return 1
    fi
    rm -rf "$tmp_dir"

    # Проверка установленного бинарника
    local actual
    actual=$(probe_snell_binary_version "$target")
    if [ "$actual" != "$version" ]; then
        echo -e "${YELLOW}Предупреждение: ${target} сообщает версию ${actual}, ожидалась ${version}${RESET}" >&2
    fi

    echo -e "${GREEN}✓ Snell ${version} (${resolved}) успешно установлен: ${target}${RESET}" >&2
    return 0
}

# Проверка наличия бинарника канала (скачивание при отсутствии)
ensure_snell_binary() {
    install_snell_binary_for_version "$1" "false"
}

# Путь к бинарнику для основной службы
main_snell_binary() {
    local version target
    version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    target=$(snell_binary_for_version "$version")
    if [ -x "$target" ]; then
        echo "$target"
    else
        echo "${INSTALL_DIR}/snell-server"
    fi
}

# Переключение пути ExecStart служб на версионированные бинарники
sync_service_units_to_versioned_binary() {
    local changed=false
    local conf_file port unit version target

    if [ -f "$SYSTEMD_SERVICE_FILE" ] && grep -q "ExecStart=${INSTALL_DIR}/snell-server " "$SYSTEMD_SERVICE_FILE"; then
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        target=$(snell_binary_for_version "$version")
        if [ -x "$target" ]; then
            sed -i "s|ExecStart=${INSTALL_DIR}/snell-server |ExecStart=${target} |" "$SYSTEMD_SERVICE_FILE"
            changed=true
        fi
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            unit="${SYSTEMD_DIR}/snell-${port}.service"
            [ -f "$unit" ] || continue
            grep -q "ExecStart=${INSTALL_DIR}/snell-server " "$unit" || continue

            version=$(get_conf_snell_version "$conf_file")
            target=$(snell_binary_for_version "$version")
            if [ -x "$target" ]; then
                sed -i "s|ExecStart=${INSTALL_DIR}/snell-server |ExecStart=${target} |" "$unit"
                changed=true
            fi
        done
    fi

    if [ "$changed" = "true" ]; then
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}✓ Службы systemd переключены на версионированные пути${RESET}"
    fi
}

# Направление ExecStart службы на конкретный канал версии
point_service_unit_to_version() {
    local unit="$1"
    local version="$2"
    local target
    target=$(snell_binary_for_version "$version")

    [ -f "$unit" ] || return 1
    [ -x "$target" ] || return 1

    sed -i -E "s|ExecStart=${INSTALL_DIR}/snell-server(-v[456])? |ExecStart=${target} |" "$unit"
}

# Миграция со старой схемы (один файл snell-server) на раздельные файлы каналов
migrate_snell_binary_layout() {
    local snell_bin="${INSTALL_DIR}/snell-server"
    local main_version=""

    if [ -e "$snell_bin" ] && [ ! -L "$snell_bin" ]; then
        local detected versioned
        detected=$(probe_snell_binary_version "$snell_bin")
        if [ "$detected" = "unknown" ]; then
            echo -e "${YELLOW}Не удалось распознать версию ${snell_bin}, миграция схемы пропущена${RESET}"
            return 1
        fi

        versioned=$(snell_binary_for_version "$detected")
        echo -e "${CYAN}Обнаружена старая схема расположения файлов, миграция на мультверсионную схему...${RESET}"
        if [ ! -e "$versioned" ]; then
            if ! cp -a "$snell_bin" "$versioned"; then
                echo -e "${RED}Ошибка копирования файла в ${versioned}, сохранена исходная схема${RESET}"
                return 1
            fi
        fi
        chmod 755 "$versioned" 2>/dev/null || true
        ln -sfn "$versioned" "$snell_bin"
        echo -e "${GREEN}✓ ${snell_bin} теперь указывает на ${versioned} (Snell ${detected})${RESET}"
        main_version="$detected"
    elif [ -L "$snell_bin" ]; then
        main_version=$(probe_snell_binary_version "$snell_bin")
    fi

    [ "$main_version" = "unknown" ] && main_version=""

    # Добавляем маркер версии в конфигурации, где он отсутствует
    if [ -n "$main_version" ] && [ -d "${SNELL_CONF_DIR}/users" ]; then
        local conf_file
        for conf_file in "${SNELL_CONF_DIR}/users"/*.conf; do
            [ -f "$conf_file" ] || continue
            if read_conf_snell_version "$conf_file" >/dev/null 2>&1; then
                continue
            fi
            if set_conf_snell_version "$conf_file" "$main_version"; then
                echo -e "${GREEN}✓ Для $(basename "$conf_file") проставлена версия ${main_version}${RESET}"
            fi
        done
    fi

    sync_service_units_to_versioned_binary
    return 0
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
    mkdir -p "${SNELL_CONF_DIR}/users"
    if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
        chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}" 2>/dev/null || true
    fi
    chmod 755 "${SNELL_CONF_DIR}" "${SNELL_CONF_DIR}/users" 2>/dev/null || true
}

migrate_legacy_main_config_if_needed() {
    ensure_snell_config_dir

    if [ -f "$SNELL_CONF_FILE" ]; then
        return 0
    fi

    if [ -f "$OLD_SNELL_CONF_FILE" ]; then
        cp -a "$OLD_SNELL_CONF_FILE" "$SNELL_CONF_FILE"
        if getent group "${SNELL_SERVICE_GROUP}" >/dev/null 2>&1 && getent passwd "${SNELL_SERVICE_USER}" >/dev/null 2>&1; then
            chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "$SNELL_CONF_FILE" 2>/dev/null || true
        fi
        chmod 644 "$SNELL_CONF_FILE"
        echo -e "${GREEN}Старая конфигурация перенесена в ${SNELL_CONF_FILE}${RESET}"
        return 0
    fi

    return 1
}

validate_snell_main_config() {
    migrate_legacy_main_config_if_needed || true

    if [ ! -s "$SNELL_CONF_FILE" ]; then
        echo -e "${RED}Основной файл конфигурации не найден: ${SNELL_CONF_FILE}${RESET}"
        echo -e "${YELLOW}Сначала выполните установку или поместите старый конфиг по этому пути перед запуском.${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*listen[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}В основном конфиге отсутствует параметр listen: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    if ! grep -Eq '^[[:space:]]*psk[[:space:]]*=' "$SNELL_CONF_FILE"; then
        echo -e "${RED}В основном конфиге отсутствует параметр psk: ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    return 0
}

write_main_systemd_service() {
    ensure_snell_config_dir
    local snell_binary
    snell_binary=$(main_snell_binary)
    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main)
After=network.target

[Service]
Type=simple
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
LimitNOFILE=32768
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

sync_existing_main_service_unit() {
    if [ ! -f "$SYSTEMD_SERVICE_FILE" ]; then
        return 0
    fi

    if systemctl is-enabled --quiet snell.socket 2>/dev/null; then
        return 0
    fi

    if grep -q "NetworkNamespacePath=" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if ! grep -Eq "ExecStart=${INSTALL_DIR}/snell-server(-v[456])? -c ${SNELL_CONF_FILE}" "$SYSTEMD_SERVICE_FILE"; then
        return 0
    fi

    if grep -q "StandardOutput=syslog\\|StandardError=syslog\\|User=nobody\\|Group=nogroup" "$SYSTEMD_SERVICE_FILE"; then
        write_main_systemd_service
        systemctl daemon-reload 2>/dev/null || true
        echo -e "${GREEN}Обновлена конфигурация службы snell.service systemd.${RESET}"
    fi
}

# Генерация адресов host/ns и шлюза на основе подсети /30
apply_egress_subnet() {
    local subnet="$1"
    local base prefix

    base="${subnet%/30}"
    prefix="${base%.*}"

    EGRESS_SUBNET="$subnet"
    EGRESS_HOST_IP="${prefix}.1/30"
    EGRESS_NS_IP="${prefix}.2/30"
    EGRESS_GW="${prefix}.1"
}

# Автоподбор незанятой подсети /30 (пул по умолчанию: 172.31.0.0/16)
auto_pick_egress_subnet() {
    local i candidate

    if ! command -v ip &> /dev/null; then
        apply_egress_subnet "172.31.0.0/30"
        return
    fi

    for i in $(seq 0 255); do
        candidate="172.31.${i}.0/30"
        if ip -o -4 addr show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi
        if ip -4 route show | grep -q "172\\.31\\.${i}\\."; then
            continue
        fi

        apply_egress_subnet "$candidate"
        return
    done

    apply_egress_subnet "172.31.0.0/30"
}

# Инициализация подсети по умолчанию
auto_pick_egress_subnet

# Автоопределение исходящего сетевого интерфейса
auto_detect_egress_iface() {
    local detected_iface

    if command -v ip &> /dev/null; then
        detected_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    fi

    if [ -n "$detected_iface" ]; then
        EGRESS_IFACE="$detected_iface"
    elif [ -z "$EGRESS_IFACE" ]; then
        EGRESS_IFACE="eth1"
    fi
}

# Инициализация интерфейса по умолчанию
auto_detect_egress_iface

# Проверка и миграция старых конфигураций
check_and_migrate_config() {
    local need_migration=false
    local old_files_exist=false

    # Автоисправление после перехода 4.x -> 5.x
    if [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; then
        migrate_legacy_main_config_if_needed
        if [ -f "$SYSTEMD_SERVICE_FILE" ] && ! systemctl is-enabled --quiet snell.socket 2>/dev/null; then
            write_main_systemd_service
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    if { [ ! -f "$SNELL_CONF_FILE" ] && [ -f "$OLD_SNELL_CONF_FILE" ]; } || [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
        old_files_exist=true
        echo -e "\n${YELLOW}Обнаружены файлы конфигурации старой версии Snell${RESET}"
        echo -e "Расположение старых файлов:"
        [ -f "$OLD_SNELL_CONF_FILE" ] && echo -e "- Файл конфигурации: ${OLD_SNELL_CONF_FILE}"
        [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && echo -e "- Файл службы:       ${OLD_SYSTEMD_SERVICE_FILE}"
        
        # Проверка каталога пользователей
        if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
            need_migration=true
            mkdir -p "${SNELL_CONF_DIR}/users"
            ensure_snell_service_user
            chown -R "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_DIR}"
            chmod -R 755 "${SNELL_CONF_DIR}"
        fi
    fi

    if [ "$old_files_exist" = true ]; then
        echo -e "\n${YELLOW}Выполнить миграцию старых конфигурационных файлов? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            echo -e "${CYAN}Начало миграции...${RESET}"
            
            # Остановка службы
            systemctl stop snell 2>/dev/null
            
            # Перенос конфига
            if [ -f "$OLD_SNELL_CONF_FILE" ]; then
                cp "$OLD_SNELL_CONF_FILE" "${SNELL_CONF_FILE}"
                ensure_snell_service_user
                chown "${SNELL_SERVICE_USER}:${SNELL_SERVICE_GROUP}" "${SNELL_CONF_FILE}"
                chmod 644 "${SNELL_CONF_FILE}"
                echo -e "${GREEN}Конфигурация перенесена${RESET}"
            fi
            
            # Перенос файла службы
            if [ -f "$OLD_SYSTEMD_SERVICE_FILE" ]; then
                write_main_systemd_service
                echo -e "${GREEN}Файл службы обновлен${RESET}"
            fi
            
            # Запрос на удаление старых файлов
            echo -e "${YELLOW}Удалить старые файлы конфигурации? [y/N]${RESET}"
            read -r del_choice
            if [[ "$del_choice" == "y" || "$del_choice" == "Y" ]]; then
                [ -f "$OLD_SNELL_CONF_FILE" ] && rm -f "$OLD_SNELL_CONF_FILE"
                [ -f "$OLD_SYSTEMD_SERVICE_FILE" ] && rm -f "$OLD_SYSTEMD_SERVICE_FILE"
                echo -e "${GREEN}Старые файлы удалены${RESET}"
            fi
            
            # Перезагрузка службы
            systemctl daemon-reload
            if validate_snell_main_config; then
                systemctl start snell
            fi
            
            # Проверка статуса
            if systemctl is-active --quiet snell; then
                echo -e "${GREEN}Миграция завершена, служба успешно запущена${RESET}"
            else
                echo -e "${RED}Предупреждение: не удалось запустить службу, проверьте конфигурацию и права доступа${RESET}"
                systemctl status snell
            fi
        else
            echo -e "${YELLOW}Миграция конфигурации пропущена${RESET}"
        fi
    fi
}

# Автообновление скрипта
auto_update_script() {
    echo -e "${CYAN}Проверка обновлений скрипта...${RESET}"
    
    TMP_SCRIPT=$(mktemp)
    
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)
        
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${GREEN}Доступна новая версия: ${new_version}${RESET}"
            echo -e "${YELLOW}Текущая версия:       ${current_version}${RESET}"
            
            cp "$0" "${0}.backup"
            mv "$TMP_SCRIPT" "$0"
            chmod +x "$0"
            
            echo -e "${GREEN}Скрипт успешно обновлен до последней версии${RESET}"
            echo -e "${YELLOW}Резервная копия сохранена в: ${0}.backup${RESET}"
            echo -e "${CYAN}Пожалуйста, запустите скрипт заново для применения изменений${RESET}"
            exit 0
        else
            echo -e "${GREEN}У вас уже установлена последняя версия (${current_version})${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}Не удалось проверить наличие обновлений, проверьте подключение к сети${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

# Ожидание завершения других процессов apt
wait_for_apt() {
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        echo -e "${YELLOW}Ожидание завершения других процессов apt...${RESET}"
        sleep 1
    done
}

# Проверка запуска от root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Пожалуйста, запустите этот скрипт с правами root.${RESET}"
        exit 1
    fi
}
check_root

# Проверка наличия jq
check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}Пакет jq не найден, установка...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y jq
        elif [ -x "$(command -v yum)" ]; then
            yum install -y jq
        else
            echo -e "${RED}Неподдерживаемый пакетный менеджер. Установите jq вручную.${RESET}"
            exit 1
        fi
    fi
}
check_jq

# Проверка, установлен ли Snell
check_snell_installed() {
    if command -v snell-server &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# Сравнение номеров версий (с учетом beta / rc / rc2 / релизов)
version_greater_equal() {
    local key1 key2
    key1=$(snell_version_sort_key "$1")
    key2=$(snell_version_sort_key "$2")

    [[ "$key1" > "$key2" || "$key1" == "$key2" ]]
}

# Ввод номера порта пользователем (1-65535)
get_user_port() {
    while true; do
        read -rp "Введите номер порта (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            echo -e "${GREEN}Выбран порт: $PORT${RESET}"
            break
        else
            echo -e "${RED}Недопустимый номер порта, введите число от 1 до 65535.${RESET}"
        fi
    done
}

# Получение системного DNS
get_system_dns() {
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi
    echo "1.1.1.1,8.8.8.8"
}

# Ввод DNS-сервера пользователем
get_dns() {
    read -rp "Введите адрес DNS-сервера (Enter — использовать системный DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS=$(get_system_dns)
        echo -e "${GREEN}Используется системный DNS: $DNS${RESET}"
    else
        DNS=$custom_dns
        echo -e "${GREEN}Используется пользовательский DNS: $DNS${RESET}"
    fi
}

# Выбор использования IPv6
get_ipv6_choice() {
    IPV6_ENABLE="true"
    LISTEN_ADDR="::0"
    read -rp "Включить IPv6? [Y/n]: " ipv6_choice
    case "$ipv6_choice" in
        [nN]|[nN][oO])
            IPV6_ENABLE="false"
            LISTEN_ADDR="0.0.0.0"
            echo -e "${GREEN}IPv6 отключен, прослушивание только IPv4${RESET}"
            ;;
        *)
            echo -e "${GREEN}IPv6 включен${RESET}"
            ;;
    esac
}

# Выбор управления исходящим трафиком в Snell v5/v6
get_egress_feature_choice() {
    EGRESS_FEATURE_ENABLED="false"
    if [ "$SNELL_VERSION_CHOICE" != "v5" ] && [ "$SNELL_VERSION_CHOICE" != "v6" ]; then
        return
    fi

    echo -e "${CYAN}Включить контроль egress-трафика в Snell ${SNELL_VERSION_CHOICE} (netns + socket activation)?${RESET}"
    echo -e "${GREEN}1.${RESET} Включить (новая функция)"
    echo -e "${GREEN}2.${RESET} Не включать (рекомендуется)"

    while true; do
        read -rp "Введите пункт [1-2]: " egress_choice
        case "$egress_choice" in
            1)
                EGRESS_FEATURE_ENABLED="true"
                echo -e "${GREEN}Включен контроль egress-трафика Snell v5/v6${RESET}"
                break
                ;;
            2)
                EGRESS_FEATURE_ENABLED="false"
                echo -e "${YELLOW}Выбран традиционный режим${RESET}"
                break
                ;;
            *)
                echo -e "${RED}Пожалуйста, выберите корректный пункт [1-2]${RESET}"
                ;;
        esac
    done
}

# Настройка параметров контроля egress-трафика
get_egress_settings() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    auto_detect_egress_iface
    read -rp "Введите имя egress-интерфейса (по умолчанию ${EGRESS_IFACE}): " custom_iface
    if [ -n "$custom_iface" ]; then
        EGRESS_IFACE="$custom_iface"
    fi

    read -rp "Введите имя netns (по умолчанию snell-egress): " custom_ns
    if [ -n "$custom_ns" ]; then
        EGRESS_NS="$custom_ns"
    fi

    auto_pick_egress_subnet
    read -rp "Введите подсеть veth (CIDR, по умолчанию ${EGRESS_SUBNET}): " custom_subnet
    if [ -n "$custom_subnet" ]; then
        if [[ "$custom_subnet" =~ ^([0-9]{1,3}\.){3}0/30$ ]]; then
            apply_egress_subnet "$custom_subnet"
        else
            echo -e "${YELLOW}Некорректный формат подсети, остается автовыбор: ${EGRESS_SUBNET}${RESET}"
        fi
    fi

    echo -e "${GREEN}Исходящий интерфейс: ${EGRESS_IFACE}${RESET}"
    echo -e "${GREEN}Сетевой неймспейс:   ${EGRESS_NS}${RESET}"
    echo -e "${GREEN}Подсеть veth:        ${EGRESS_SUBNET}${RESET}"
    echo -e "${YELLOW}Схема: ${EGRESS_HOST_IP} (хост) <-> ${EGRESS_NS_IP} (${EGRESS_NS})${RESET}"
}

# Проверка зависимостей для контроля egress-трафика
check_egress_dependencies() {
    if [ "$EGRESS_FEATURE_ENABLED" != "true" ]; then
        return
    fi

    if ! command -v ip &> /dev/null; then
        echo -e "${YELLOW}Пакет iproute2 не найден, установка...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y iproute2
        elif [ -x "$(command -v yum)" ]; then
            yum install -y iproute
        else
            echo -e "${RED}Неподдерживаемый пакетный менеджер, установите iproute2 вручную.${RESET}"
            exit 1
        fi
    fi

    if ! command -v nft &> /dev/null; then
        echo -e "${YELLOW}Пакет nftables не найден, установка...${RESET}"
        if [ -x "$(command -v apt)" ]; then
            wait_for_apt
            apt update && apt install -y nftables
        elif [ -x "$(command -v yum)" ]; then
            yum install -y nftables
        else
            echo -e "${RED}Неподдерживаемый пакетный менеджер, установите nftables вручную.${RESET}"
            exit 1
        fi
    fi
}

# Создание юнита инициализации netns
write_snell_netns_service() {
    cat > ${NETNS_SETUP_SCRIPT} << EOF
#!/bin/bash
set -eux

ip netns add ${EGRESS_NS} 2>/dev/null || true
ip link show veth-host >/dev/null 2>&1 || ip link add veth-host type veth peer name veth-snell
ip link set veth-snell netns ${EGRESS_NS} 2>/dev/null || true

ip addr replace ${EGRESS_HOST_IP} dev veth-host
ip link set veth-host up

ip netns exec ${EGRESS_NS} ip addr replace ${EGRESS_NS_IP} dev veth-snell
ip netns exec ${EGRESS_NS} ip link set lo up
ip netns exec ${EGRESS_NS} ip link set veth-snell up
ip netns exec ${EGRESS_NS} ip route replace default via ${EGRESS_GW}

mkdir -p /etc/netns/${EGRESS_NS}
cp -f /etc/resolv.conf /etc/netns/${EGRESS_NS}/resolv.conf
if grep -Eq '^nameserver[[:space:]]+127\\.0\\.0\\.53$' /etc/netns/${EGRESS_NS}/resolv.conf; then
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/netns/${EGRESS_NS}/resolv.conf
fi

sysctl -w net.ipv4.ip_forward=1

nft delete table ip snell_nat 2>/dev/null || true
nft add table ip snell_nat
nft add chain ip snell_nat postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft add rule ip snell_nat postrouting oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} masquerade

nft add table inet snell_filter 2>/dev/null || true
nft list chain inet snell_filter forward >/dev/null 2>&1 || nft add chain inet snell_filter forward '{ type filter hook forward priority -5; policy accept; }'
nft add rule inet snell_filter forward iifname 'veth-host' oifname "${EGRESS_IFACE}" ip saddr ${EGRESS_SUBNET} accept 2>/dev/null || true
nft add rule inet snell_filter forward iifname "${EGRESS_IFACE}" oifname 'veth-host' ct state established,related accept 2>/dev/null || true

if command -v iptables >/dev/null 2>&1; then
    iptables -C FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i veth-host -o ${EGRESS_IFACE} -s ${EGRESS_SUBNET} -j ACCEPT
    iptables -C FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${EGRESS_IFACE} -o veth-host -d ${EGRESS_SUBNET} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
fi
EOF
    chmod +x ${NETNS_SETUP_SCRIPT}

    cat > ${SYSTEMD_NETNS_FILE} << EOF
[Unit]
Description=Prepare netns and NAT for Snell egress
DefaultDependencies=no
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NETNS_SETUP_SCRIPT}
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF
}

# Создание юнитов socket activation
write_snell_socket_service_units() {
    local listen_port=$1
    local snell_binary
    snell_binary=$(main_snell_binary)

    cat > ${SYSTEMD_SOCKET_FILE} << EOF
[Unit]
Description=Snell v5 (socket-activated)

[Socket]
ListenStream=0.0.0.0:${listen_port}
ListenDatagram=0.0.0.0:${listen_port}
FileDescriptorName=snell_inet
ReusePort=no
NoDelay=true

[Install]
WantedBy=sockets.target
EOF

    cat > ${SYSTEMD_SERVICE_FILE} << EOF
[Unit]
Description=Snell Proxy Service (Main, netns)
Requires=snell-netns.service
After=snell-netns.service

[Service]
Type=simple
NetworkNamespacePath=/run/netns/${EGRESS_NS}
BindReadOnlyPaths=/etc/netns/${EGRESS_NS}/resolv.conf:/etc/resolv.conf
User=${SNELL_SERVICE_USER}
Group=${SNELL_SERVICE_GROUP}
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
LimitNOFILE=32768
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
WorkingDirectory=${INSTALL_DIR}
ExecStart=${snell_binary} -c ${SNELL_CONF_FILE}
Restart=on-failure
RestartSec=2s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF
}

# Проверка, занят ли порт (TCP/UDP)
is_port_in_use() {
    local port="$1"
    if command -v ss &> /dev/null; then
        ss -H -ltn "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
        ss -H -lun "( sport = :${port} )" 2>/dev/null | grep -q . && return 0
        return 1
    fi

    if command -v lsof &> /dev/null; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        lsof -nP -iUDP:"${port}" >/dev/null 2>&1
        return $?
    fi

    return 1
}

# Вывод информации о процессах, занимающих порт
show_port_occupier() {
    local port="$1"
    if command -v ss &> /dev/null; then
        ss -ltnp "( sport = :${port} )" 2>/dev/null | sed 's/^/  /'
        ss -lunp "( sport = :${port} )" 2>/dev/null | sed 's/^/  /'
        return
    fi

    if command -v lsof &> /dev/null; then
        lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /'
        lsof -nP -iUDP:"${port}" 2>/dev/null | sed 's/^/  /'
    fi
}

# Принудительное освобождение порта по PID
force_release_port_by_pid() {
    local port="$1"
    local pids pid cmd

    if command -v ss &> /dev/null; then
        pids=$( {
            ss -H -ltnp "( sport = :${port} )" 2>/dev/null
            ss -H -lunp "( sport = :${port} )" 2>/dev/null
        } | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
    elif command -v lsof &> /dev/null; then
        pids=$( {
            lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null
            lsof -t -nP -iUDP:"${port}" 2>/dev/null
        } | sort -u)
    fi

    [ -z "$pids" ] && return 0

    for pid in $pids; do
        cmd=$(ps -p "$pid" -o args= 2>/dev/null)
        if echo "$cmd" | grep -q "snell"; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    sleep 0.2

    if is_port_in_use "$port"; then
        for pid in $pids; do
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi
}

# Освобождение основного порта перед переключением на socket activation
ensure_main_port_free_for_socket() {
    local port="$1"
    local i

    systemctl stop snell.socket 2>/dev/null
    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl reset-failed snell.socket 2>/dev/null

    systemctl kill snell --signal=SIGKILL 2>/dev/null
    pkill -f "${INSTALL_DIR}/snell-server -c ${SNELL_CONF_FILE}" 2>/dev/null || true
    force_release_port_by_pid "$port"

    for i in {1..20}; do
        if ! is_port_in_use "$port"; then
            return 0
        fi
        sleep 0.2
    done

    echo -e "${RED}Порт ${port} все еще занят, невозможно запустить snell.socket.${RESET}"
    echo -e "${YELLOW}Информация о занятости:${RESET}"
    show_port_occupier "$port"
    return 1
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
        echo -e "${YELLOW}Конфигурационный файл nftables не найден, правила применены в текущем сеансе${RESET}"
    fi
}

# Открытие порта в nftables
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

# Открытие портов в ufw, nftables и iptables
open_port() {
    local PORT=$1
    local ufw_active=false

    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}Открытие порта $PORT в UFW${RESET}"
        ufw allow "$PORT"/tcp
        ufw allow "$PORT"/udp
        if ufw status 2>/dev/null | grep -qw "active"; then
            ufw_active=true
        fi
    fi

    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}Открытие порта $PORT в iptables${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        iptables -I INPUT -p udp --dport "$PORT" -j ACCEPT
        
        if [ ! -d "/etc/iptables" ]; then
            mkdir -p /etc/iptables
        fi
        iptables-save > /etc/iptables/rules.v4 || true
    fi

    if [ "$ufw_active" = false ]; then
        open_nftables_port "$PORT"
    fi
}

close_nftables_port() {
    local PORT=$1

    if ! command -v nft &> /dev/null; then
        return
    fi

    nft -a list ruleset 2>/dev/null | awk -v port="$PORT" '
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
    local PORT=$1

    if command -v ufw &> /dev/null; then
        ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$PORT"/udp >/dev/null 2>&1 || true
    fi

    if command -v iptables &> /dev/null; then
        iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    close_nftables_port "$PORT"
}

# Запуск среды egress: socket + service, при ошибке — прямой запуск через netns
start_egress_runtime() {
    local port="$1"

    if ! ensure_main_port_free_for_socket "$port"; then
        return 1
    fi

    if ! systemctl enable snell.socket; then
        echo -e "${RED}Не удалось включить snell.socket.${RESET}"
        return 1
    fi
    if ! systemctl start snell.socket; then
        echo -e "${RED}Не удалось запустить snell.socket.${RESET}"
        return 1
    fi

    # Принудительный подъем службы для доступности UDP/QUIC
    if systemctl start snell; then
        echo -e "${GREEN}Включен режим работы socket + service.${RESET}"
        return 0
    fi

    echo -e "${YELLOW}Не удалось запустить службу в режиме socket, откат к прямому запуску через netns.${RESET}"
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null

    if ! systemctl enable snell; then
        echo -e "${RED}Режим отката: не удалось включить snell.${RESET}"
        return 1
    fi
    if ! systemctl restart snell; then
        echo -e "${RED}Режим отката: не удалось запустить snell.${RESET}"
        return 1
    fi

    echo -e "${GREEN}Выполнен откат к прямому запуску через netns (без socket-активации).${RESET}"
    return 0
}

# Установка Snell
install_snell() {
    echo -e "${CYAN}Установка Snell${RESET}"

    select_snell_version

    wait_for_apt
    apt update && apt install -y wget unzip

    migrate_snell_binary_layout

    if ! install_snell_binary_for_version "$SNELL_VERSION_CHOICE" "true"; then
        echo -e "${RED}Ошибка установки Snell ${SNELL_VERSION_CHOICE}.${RESET}"
        exit 1
    fi

    update_snell_symlink "$SNELL_VERSION_CHOICE"

    get_user_port
    get_dns
    get_ipv6_choice
    if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
        configure_snell_v6_options
    fi
    get_egress_feature_choice
    get_egress_settings
    check_egress_dependencies
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)

    mkdir -p ${SNELL_CONF_DIR}/users

    write_snell_conf "${SNELL_CONF_FILE}" "${LISTEN_ADDR}" "${PORT}" "${PSK}" "${IPV6_ENABLE}" "${DNS}" "${SNELL_VERSION_CHOICE}"

    write_main_systemd_service

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        write_snell_netns_service
        write_snell_socket_service_units "$PORT"
    fi

    systemctl daemon-reload
    if [ $? -ne 0 ]; then
        echo -e "${RED}Не удалось перезагрузить конфигурацию Systemd.${RESET}"
        exit 1
    fi

    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        systemctl enable snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось включить службу snell-netns.${RESET}"
            exit 1
        fi

        systemctl start snell-netns
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось запустить службу snell-netns.${RESET}"
            exit 1
        fi

        if ! start_egress_runtime "$PORT"; then
            exit 1
        fi

        echo -e "${GREEN}snell.socket запущен, служба snell будет запускаться по требованию (при первом подключении)${RESET}"
        if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
            echo -e "${YELLOW}В v6 удален режим QUIC. На клиенте требуется: version = 6 и совпадение параметра mode.${RESET}"
        else
            echo -e "${YELLOW}На клиенте рекомендуется использовать version = 4 (у v5 повышенные требования к QUIC/UDP).${RESET}"
        fi
    else
        systemctl stop snell.socket 2>/dev/null
        systemctl disable snell.socket 2>/dev/null
        systemctl stop snell-netns 2>/dev/null
        systemctl disable snell-netns 2>/dev/null

        systemctl enable snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось настроить автозапуск Snell.${RESET}"
            exit 1
        fi

        if ! validate_snell_main_config; then
            exit 1
        fi

        systemctl start snell
        if [ $? -ne 0 ]; then
            echo -e "${RED}Не удалось запустить службу Snell.${RESET}"
            exit 1
        fi
    fi

    open_port "$PORT"

    echo -e "\n${GREEN}Установка завершена! Параметры вашей конфигурации:${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    if [ "$EGRESS_FEATURE_ENABLED" = "true" ]; then
        echo -e "${YELLOW}Контроль egress : Включен (интерфейс ${EGRESS_IFACE}, неймспейс ${EGRESS_NS})${RESET}"
        echo -e "${YELLOW}Активация сокета: snell.socket${RESET}"
    fi
    echo -e "${YELLOW}Порт            : ${PORT}${RESET}"
    echo -e "${YELLOW}Ключ PSK        : ${PSK}${RESET}"
    echo -e "${YELLOW}IPv6            : true${RESET}"
    echo -e "${YELLOW}DNS-сервер      : ${DNS}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"

    echo -e "\n${GREEN}Информация об IP-адресах сервера:${RESET}"
    
    IPV4_ADDR=$(curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 адрес: ${RESET}${IPV4_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    IPV6_ADDR=$(curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6 адрес: ${RESET}${IPV6_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    echo -e "\n${GREEN}Конфигурация для Surge:${RESET}"
    local installed_version="$SNELL_VERSION_CHOICE"
    if [ ! -z "$IPV4_ADDR" ]; then
        generate_surge_config "$IPV4_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV4" "$installed_version"
    fi
    
    if [ ! -z "$IPV6_ADDR" ]; then
        generate_surge_config "$IPV6_ADDR" "$PORT" "$PSK" "$SNELL_VERSION_CHOICE" "$IP_COUNTRY_IPV6" "$installed_version"
    fi

    echo -e "${CYAN}Установка скрипта управления...${RESET}"
    mkdir -p /usr/local/bin
    
    cat > /usr/local/bin/snell << 'EOFSCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root${RESET}"
    exit 1
fi

echo -e "${CYAN}Получение последней версии скрипта управления...${RESET}"
TMP_SCRIPT=$(mktemp)
if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
    bash "$TMP_SCRIPT"
    rm -f "$TMP_SCRIPT"
else
    echo -e "${RED}Не удалось скачать скрипт, проверьте соединение с интернетом.${RESET}"
    rm -f "$TMP_SCRIPT"
    exit 1
fi
EOFSCRIPT
    
    if [ $? -eq 0 ]; then
        chmod +x /usr/local/bin/snell
        if [ $? -eq 0 ]; then
            echo -e "\n${GREEN}Скрипт управления успешно установлен!${RESET}"
            echo -e "${YELLOW}Вы можете ввести команду 'snell' в терминале для вызова меню.${RESET}"
            echo -e "${YELLOW}Примечание: требуется запуск через sudo snell или от имени root.${RESET}\n"
        else
            echo -e "\n${RED}Не удалось назначить права на выполнение.${RESET}"
            echo -e "${YELLOW}Вы можете управлять Snell, запуская исходный файл скрипта напрямую.${RESET}\n"
        fi
    else
        echo -e "\n${RED}Не удалось создать скрипт управления.${RESET}"
        echo -e "${YELLOW}Вы можете управлять Snell, запуская исходный файл скрипта напрямую.${RESET}\n"
    fi
}

# Управление egress-контролем для установленных Snell v5/v6
configure_v5_egress_control() {
    echo -e "${CYAN}=============== Настройка egress-контроля (v5/v6) ===============${RESET}"

    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}Snell не обнаружен, сначала выполните установку.${RESET}"
        return 1
    fi

    local installed_version
    installed_version=$(get_conf_snell_version "$SNELL_CONF_FILE")
    if [ "$installed_version" != "v5" ] && [ "$installed_version" != "v6" ]; then
        echo -e "${YELLOW}Основной пользователь использует ${installed_version}, опция доступна только для Snell v5/v6.${RESET}"
        return 1
    fi

    local main_port
    main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        echo -e "${RED}Не удалось определить порт основного сервиса, проверьте ${SNELL_CONF_FILE}${RESET}"
        return 1
    fi

    local egress_enabled="false"
    if systemctl is-enabled snell.socket &> /dev/null || systemctl is-active snell.socket &> /dev/null; then
        egress_enabled="true"
    fi

    echo -e "${GREEN}Версия основного сервиса: Snell ${installed_version}${RESET}"
    echo -e "${GREEN}Основной порт           : ${main_port}${RESET}"
    if [ "$egress_enabled" = "true" ]; then
        echo -e "${YELLOW}Текущий статус контроля egress: Включен${RESET}"
    else
        echo -e "${YELLOW}Текущий статус контроля egress: Отключен${RESET}"
    fi

    echo -e "${GREEN}1.${RESET} Включить / Обновить контроль egress"
    echo -e "${GREEN}2.${RESET} Отключить контроль egress (возврат к традиционному режиму)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Выберите пункт [0-2]: " egress_manage_choice

    case "$egress_manage_choice" in
        1)
            EGRESS_FEATURE_ENABLED="true"
            get_egress_settings
            check_egress_dependencies

            write_snell_netns_service
            write_snell_socket_service_units "$main_port"

            systemctl daemon-reload
            if ! systemctl enable snell-netns; then
                echo -e "${RED}Не удалось включить snell-netns.${RESET}"
                return 1
            fi
            if ! systemctl start snell-netns; then
                echo -e "${RED}Не удалось запустить snell-netns, выполните: systemctl status snell-netns.service${RESET}"
                return 1
            fi

            if ! start_egress_runtime "$main_port"; then
                return 1
            fi

            echo -e "${GREEN}Контроль egress применен (интерфейс ${EGRESS_IFACE}, неймспейс ${EGRESS_NS}).${RESET}"
            if [ "$SNELL_VERSION_CHOICE" = "v6" ]; then
                echo -e "${YELLOW}В v6 удален режим QUIC. На клиенте: version = 6 и mode должен совпадать с сервером.${RESET}"
            else
                echo -e "${YELLOW}Рекомендуется использовать version = 4 на клиенте (у v5 выше зависимость от QUIC/UDP).${RESET}"
            fi
            echo -e "${YELLOW}Справка: snell.socket слушает порт, snell.service запустится автоматически при первом подключении.${RESET}"
            ;;
        2)
            systemctl stop snell.socket 2>/dev/null
            systemctl disable snell.socket 2>/dev/null
            systemctl stop snell-netns 2>/dev/null
            systemctl disable snell-netns 2>/dev/null

            write_main_systemd_service

            rm -f ${SYSTEMD_SOCKET_FILE}
            rm -f ${SYSTEMD_NETNS_FILE}

            systemctl daemon-reload
            systemctl enable snell
            if ! validate_snell_main_config; then
                return 1
            fi
            systemctl restart snell

            echo -e "${GREEN}Контроль egress отключен, восстановлен традиционный режим.${RESET}"
            ;;
        0)
            echo -e "${CYAN}Возврат в меню.${RESET}"
            ;;
        *)
            echo -e "${RED}Пожалуйста, выберите корректный пункт [0-2]${RESET}"
            ;;
    esac
}

# Удаление Snell
uninstall_snell() {
    echo -e "${CYAN}Удаление Snell${RESET}"

    local snell_shadowtls_services
    snell_shadowtls_services=$(find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-snell-*.service" 2>/dev/null)
    if [ -n "$snell_shadowtls_services" ]; then
        while IFS= read -r service_file; do
            [ -z "$service_file" ] && continue
            local service_name
            service_name=$(basename "$service_file")
            local shadowtls_port
            shadowtls_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            echo -e "${YELLOW}Остановка службы ShadowTLS (${service_name})${RESET}"
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            rm -f "$service_file"
            if [ -n "$shadowtls_port" ]; then
                close_port "$shadowtls_port"
            fi
        done <<< "$snell_shadowtls_services"
    fi

    systemctl stop snell 2>/dev/null
    systemctl disable snell 2>/dev/null
    systemctl stop snell.socket 2>/dev/null
    systemctl disable snell.socket 2>/dev/null
    systemctl stop snell-netns 2>/dev/null
    systemctl disable snell-netns 2>/dev/null

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}Остановка пользовательской службы (порт: $port)${RESET}"
                    systemctl stop "snell-${port}" 2>/dev/null
                    systemctl disable "snell-${port}" 2>/dev/null
                    rm -f "${SYSTEMD_DIR}/snell-${port}.service"
                    close_port "$port"
                fi
            fi
        done
    fi

    rm -f /lib/systemd/system/snell.service
    rm -f ${SYSTEMD_SERVICE_FILE}
    rm -f ${SYSTEMD_SOCKET_FILE}
    rm -f ${SYSTEMD_NETNS_FILE}
    rm -f ${NETNS_SETUP_SCRIPT}

    local version
    for version in $SNELL_ALL_VERSIONS; do
        rm -f "$(snell_binary_for_version "$version")"
    done
    rm -f "${INSTALL_DIR}"/snell-server-v[456].bak.*
    rm -f ${INSTALL_DIR}/snell-server
    rm -rf ${SNELL_CONF_DIR}
    rm -f /usr/local/bin/snell

    if ! find "${SYSTEMD_DIR}" -maxdepth 1 -name "shadowtls-*.service" 2>/dev/null | grep -q .; then
        rm -f /usr/local/bin/shadow-tls
    fi
    
    systemctl daemon-reload
    
    echo -e "${GREEN}Snell и все конфигурации пользователей успешно удалены${RESET}"
}

# Перезапуск Snell
restart_snell() {
    echo -e "${YELLOW}Перезапуск всех служб Snell...${RESET}"

    if ! validate_snell_main_config; then
        echo -e "${RED}Перезапуск отменен во избежание сбоя snell-server из-за отсутствия конфигурации.${RESET}"
        return 1
    fi
    
    if systemctl list-unit-files | grep -q '^snell.socket'; then
        systemctl restart snell-netns 2>/dev/null
        systemctl restart snell.socket 2>/dev/null
    fi

    systemctl restart snell
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Основная служба Snell успешно перезапущена.${RESET}"
    else
        echo -e "${RED}Не удалось перезапустить основную службу Snell.${RESET}"
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                if [ ! -z "$port" ]; then
                    echo -e "${YELLOW}Перезапуск пользовательской службы (порт: $port)${RESET}"
                    systemctl restart "snell-${port}" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}Пользовательская служба (порт: $port) успешно перезапущена.${RESET}"
                    else
                        echo -e "${RED}Не удалось перезапустить службу (порт: $port).${RESET}"
                    fi
                fi
            fi
        done
    fi
}

# Проверка и отображение статуса служб
check_and_show_status() {
    echo -e "\n${CYAN}=============== Проверка статуса служб ===============${RESET}"
    
    if command -v snell-server &> /dev/null; then
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu=0
        
        local main_available=false
        if systemctl is-active snell &> /dev/null; then
            main_available=true
        elif systemctl is-active snell.socket &> /dev/null; then
            main_available=true
        fi

        if [ "$main_available" = "true" ]; then
            user_count=$((user_count + 1))
            running_count=$((running_count + 1))
            
            local main_pid=$(systemctl show -p MainPID snell | cut -d'=' -f2)
            if [ ! -z "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem=$(ps -o rss= -p $main_pid 2>/dev/null)
                local cpu=$(ps -o %cpu= -p $main_pid 2>/dev/null)
                if [ ! -z "$mem" ]; then
                    total_snell_memory=$((total_snell_memory + mem))
                fi
                if [ ! -z "$cpu" ]; then
                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                fi
            fi
        else
            user_count=$((user_count + 1))
        fi
        
        if [ -d "${SNELL_CONF_DIR}/users" ]; then
            for user_conf in "${SNELL_CONF_DIR}/users"/*; do
                if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                    if [ ! -z "$port" ]; then
                        user_count=$((user_count + 1))
                        if systemctl is-active --quiet "snell-${port}"; then
                            running_count=$((running_count + 1))
                            
                            local user_pid=$(systemctl show -p MainPID "snell-${port}" | cut -d'=' -f2)
                            if [ ! -z "$user_pid" ] && [ "$user_pid" != "0" ]; then
                                local mem=$(ps -o rss= -p $user_pid 2>/dev/null)
                                local cpu=$(ps -o %cpu= -p $user_pid 2>/dev/null)
                                if [ ! -z "$mem" ]; then
                                    total_snell_memory=$((total_snell_memory + mem))
                                fi
                                if [ ! -z "$cpu" ]; then
                                    total_snell_cpu=$(echo "$total_snell_cpu + $cpu" | bc -l)
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        local total_snell_memory_mb=$(echo "scale=2; $total_snell_memory/1024" | bc)
        printf "${GREEN}Snell установлен${RESET}   ${YELLOW}CPU: %.2f%%${RESET}   ${YELLOW}Память: %.2f МБ${RESET}   ${GREEN}Активно: ${running_count}/${user_count}${RESET}\n" "$total_snell_cpu" "$total_snell_memory_mb"

        local installed_channels channel channel_summary=""
        installed_channels=$(list_installed_snell_versions)
        if [ -n "$installed_channels" ]; then
            for channel in $installed_channels; do
                channel_summary="${channel_summary}${channel}(×$(list_services_using_version "$channel" | grep -c .)) "
            done
            echo -e "${GREEN}Установленные каналы${RESET}   ${YELLOW}${channel_summary}${RESET}"
        fi
    else
        echo -e "${YELLOW}Snell не установлен${RESET}"
    fi
    
    if [ -f "/usr/local/bin/shadow-tls" ]; then
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu=0
        declare -A processed_ports
        
        local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
        if [ ! -z "$snell_services" ]; then
            while IFS= read -r service_file; do
                local port=$(basename "$service_file" | sed 's/shadowtls-snell-\([0-9]*\)\.service/\1/')
                
                if [ -z "${processed_ports[$port]}" ]; then
                    processed_ports[$port]=1
                    stls_total=$((stls_total + 1))
                    if systemctl is-active "shadowtls-snell-${port}" &> /dev/null; then
                        stls_running=$((stls_running + 1))
                        
                        local stls_pid=$(systemctl show -p MainPID "shadowtls-snell-${port}" | cut -d'=' -f2)
                        if [ ! -z "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                            local mem=$(ps -o rss= -p $stls_pid 2>/dev/null)
                            local cpu=$(ps -o %cpu= -p $stls_pid 2>/dev/null)
                            if [ ! -z "$mem" ]; then
                                total_stls_memory=$((total_stls_memory + mem))
                            fi
                            if [ ! -z "$cpu" ]; then
                                total_stls_cpu=$(echo "$total_stls_cpu + $cpu" | bc -l)
                            fi
                        fi
                    fi
                fi
            done <<< "$snell_services"
        fi
        
        if [ $stls_total -gt 0 ]; then
            local total_stls_memory_mb=$(echo "scale=2; $total_stls_memory/1024" | bc)
            printf "${GREEN}ShadowTLS установлен${RESET}   ${YELLOW}CPU: %.2f%%${RESET}   ${YELLOW}Память: %.2f МБ${RESET}   ${GREEN}Активно: ${stls_running}/${stls_total}${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb"
        else
            echo -e "${YELLOW}ShadowTLS не установлен${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS не установлен${RESET}"
    fi
    
    echo -e "${CYAN}============================================${RESET}\n"
}

# Просмотр конфигурации
view_snell_config() {
    echo -e "${GREEN}Конфигурация Snell:${RESET}"
    echo -e "${CYAN}================================${RESET}"
    
    local installed_channels
    installed_channels=$(list_installed_snell_versions)
    if [ -n "$installed_channels" ]; then
        echo -e "${YELLOW}Установленные каналы: ${installed_channels}${RESET}"
    else
        echo -e "${YELLOW}Установленные каналы Snell не найдены${RESET}"
    fi
    
    IPV4_ADDR=$(curl -s4 --connect-timeout 5 --max-time 10 https://api.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV4_ADDR" ]; then
        IP_COUNTRY_IPV4=$(get_ip_country "${IPV4_ADDR}")
        echo -e "${GREEN}IPv4 адрес: ${RESET}${IPV4_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV4}"
    fi

    IPV6_ADDR=$(curl -s6 --connect-timeout 5 --max-time 10 https://api64.ipify.org)
    if [ $? -eq 0 ] && [ ! -z "$IPV6_ADDR" ]; then
        IP_COUNTRY_IPV6=$(get_ip_country "${IPV6_ADDR}")
        echo -e "${GREEN}IPv6 адрес: ${RESET}${IPV6_ADDR} ${GREEN}Страна: ${RESET}${IP_COUNTRY_IPV6}"
    fi

    if [ -z "$IPV4_ADDR" ] && [ -z "$IPV6_ADDR" ]; then
        echo -e "${RED}Не удалось определить публичный IP-адрес, проверьте сетевое подключение.${RESET}"
        return
    fi
    
    echo -e "\n${YELLOW}=== Список конфигураций пользователей ===${RESET}"
    
    local main_conf="${SNELL_CONF_DIR}/users/snell-main.conf"
    if [ -f "$main_conf" ]; then
        echo -e "\n${GREEN}Основная конфигурация:${RESET}"
        local main_port=$(grep -E '^listen' "$main_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        local main_psk=$(grep -E '^psk' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$main_conf" | awk -F'=' '{print $2}' | tr -d ' ')
        local main_version=$(get_conf_snell_version "$main_conf")

        echo -e "${YELLOW}Порт:                 ${main_port}${RESET}"
        echo -e "${YELLOW}Версия:               Snell ${main_version}${RESET}"
        echo -e "${YELLOW}PSK:                  ${main_psk}${RESET}"
        [ -n "$main_ipv6" ] && echo -e "${YELLOW}IPv6:                 ${main_ipv6}${RESET}"
        [ -n "$main_mode" ] && echo -e "${YELLOW}Режим (mode):         ${main_mode}${RESET}"
        [ -n "$main_dns_pref" ] && echo -e "${YELLOW}Приоритет DNS:        ${main_dns_pref}${RESET}"
        echo -e "${YELLOW}DNS:                  ${main_dns}${RESET}"
        
        echo -e "\n${GREEN}Конфигурация для Surge:${RESET}"
        if [ ! -z "$IPV4_ADDR" ]; then
            generate_surge_config "$IPV4_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV4" "$main_version"
        fi
        if [ ! -z "$IPV6_ADDR" ]; then
            generate_surge_config "$IPV6_ADDR" "$main_port" "$main_psk" "$main_version" "$IP_COUNTRY_IPV6" "$main_version"
        fi
    fi
    
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for user_conf in "${SNELL_CONF_DIR}/users"/*; do
            if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
                local user_port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
                local user_psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_ipv6=$(grep -E '^[[:space:]]*ipv6[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns=$(grep -E '^[[:space:]]*dns[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_dns_pref=$(grep -E '^[[:space:]]*dns-ip-preference[[:space:]]*=' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local user_version=$(get_conf_snell_version "$user_conf")

                echo -e "\n${GREEN}Конфигурация пользователя (порт: ${user_port}):${RESET}"
                echo -e "${YELLOW}Версия:               Snell ${user_version}${RESET}"
                echo -e "${YELLOW}PSK:                  ${user_psk}${RESET}"
                [ -n "$user_ipv6" ] && echo -e "${YELLOW}IPv6:                 ${user_ipv6}${RESET}"
                [ -n "$user_mode" ] && echo -e "${YELLOW}Режим (mode):         ${user_mode}${RESET}"
                [ -n "$user_dns_pref" ] && echo -e "${YELLOW}Приоритет DNS:        ${user_dns_pref}${RESET}"
                echo -e "${YELLOW}DNS:                  ${user_dns}${RESET}"
                
                echo -e "\n${GREEN}Конфигурация для Surge:${RESET}"
                if [ ! -z "$IPV4_ADDR" ]; then
                    generate_surge_config "$IPV4_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV4" "$user_version"
                fi
                if [ ! -z "$IPV6_ADDR" ]; then
                    generate_surge_config "$IPV6_ADDR" "$user_port" "$user_psk" "$user_version" "$IP_COUNTRY_IPV6" "$user_version"
                fi
            fi
        done
    fi
    
    local snell_services=$(find /etc/systemd/system -name "shadowtls-snell-*.service" 2>/dev/null | sort -u)
    if [ ! -z "$snell_services" ]; then
        echo -e "\n${YELLOW}=== Комбинированная конфигурация ShadowTLS ===${RESET}"
        declare -A processed_ports
        while IFS= read -r service_file; do
            local exec_line=$(grep "ExecStart=" "$service_file")
            local stls_port=$(echo "$exec_line" | grep -oP '(?<=--listen ::0:)\d+')
            local stls_password=$(echo "$exec_line" | grep -oP '(?<=--password )[^ ]+')
            local stls_domain=$(echo "$exec_line" | grep -oP '(?<=--tls )[^ ]+')
            local snell_port=$(echo "$exec_line" | grep -oP '(?<=--server 127.0.0.1:)\d+')
            local psk=""
            if [ -f "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-${snell_port}.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            elif [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ] && [ "$snell_port" = "$(get_snell_port)" ]; then
                psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
            fi
            if [ -z "$snell_port" ] || [ -z "$psk" ] || [ -n "${processed_ports[$snell_port]}" ]; then
                continue
            fi
            processed_ports[$snell_port]=1
            local snell_version=$(get_port_snell_version "$snell_port")
            local snell_mode=$(get_snell_mode "$(snell_conf_for_port "$snell_port")")
            if [ "$snell_port" = "$(get_snell_port)" ]; then
                echo -e "\n${GREEN}Конфигурация ShadowTLS для основного пользователя:${RESET}"
            else
                echo -e "\n${GREEN}Конфигурация ShadowTLS пользователя (порт: ${snell_port}):${RESET}"
            fi
            echo -e "  - Порт Snell:                   ${snell_port}"
            echo -e "  - PSK:                          ${psk}"
            echo -e "  - Порт прослушивания ShadowTLS: ${stls_port}"
            echo -e "  - Пароль ShadowTLS:             ${stls_password}"
            echo -e "  - SNI ShadowTLS:                ${stls_domain}"
            echo -e "  - Версия:                       3"
            echo -e "  - Версия Snell:                 ${snell_version}"
            echo -e "\n${GREEN}Конфигурация для Surge:${RESET}"
            if [ ! -z "$IPV4_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV4} = snell, ${IPV4_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
            if [ ! -z "$IPV6_ADDR" ]; then
                if [ "$snell_version" = "v6" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 6, mode = ${snell_mode}, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                elif [ "$snell_version" = "v5" ]; then
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                else
                    echo -e "${GREEN}${IP_COUNTRY_IPV6} = snell, ${IPV6_ADDR}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3${RESET}"
                fi
            fi
        done <<< "$snell_services"
    fi
    
    echo -e "\n${YELLOW}Примечания:${RESET}"
    echo -e "1. Протокол Snell поддерживается только клиентом Surge"
    echo -e "2. Замените адрес сервера в конфигурации на актуальный IP или домен"
    read -p "Нажмите любую клавишу для возврата в главное меню..."
}

# =========================================
# Управление версиями Snell: обновление каналов / добавление / переключение
# =========================================
get_channel_binary_version() {
    local version="$1"
    local binary
    binary=$(snell_binary_for_version "$version")
    [ -x "$binary" ] || return 1

    local detail
    detail=$("$binary" --v 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9]*' | head -n 1)
    if [ -z "$detail" ]; then
        case "$version" in
            v4) detail="$SNELL_V4_FALLBACK" ;;
            v5) detail="$SNELL_V5_FALLBACK" ;;
            v6) detail="$SNELL_V6_FALLBACK" ;;
        esac
    fi
    echo "$detail"
}

# Перезапуск службы с валидацией активности
restart_and_verify_service() {
    local service="$1"
    local waited=0

    if ! systemctl restart "$service" 2>/dev/null; then
        echo -e "${RED}Команда systemctl restart ${service} завершилась с ошибкой${RESET}"
        journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
        return 1
    fi

    while [ "$waited" -lt 10 ]; do
        if systemctl is-active --quiet "$service"; then
            return 0
        fi
        if [ "$service" = "snell" ] && systemctl is-active --quiet snell.socket; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    echo -e "${RED}Служба ${service} не перешла в статус active за ${waited} сек.${RESET}"
    journalctl -u "$service" -n 30 --no-pager 2>/dev/null | sed 's/^/   /'
    return 1
}

# Обновление отдельного канала версии до актуального релиза
update_snell_channel() {
    local version="$1"
    local target
    target=$(snell_binary_for_version "$version")

    echo -e "\n${CYAN}=============== Обновление канала Snell ${version} ===============${RESET}"
    echo -e "${GREEN}✓ Будет заменен только бинарник ${version}, остальные каналы не затрагиваются${RESET}"
    echo -e "${GREEN}✓ Порты, пароли и настройки пользователей остаются без изменений${RESET}"

    local services
    services=$(list_services_using_version "$version")
    if [ -n "$services" ]; then
        echo -e "${YELLOW}Будут перезапущены: $(echo "$services" | tr '\n' ' ')${RESET}"
    else
        echo -e "${YELLOW}Ни одна служба не использует канал ${version}, будет обновлен только бинарник${RESET}"
    fi

    local backup_dir
    backup_dir=$(backup_snell_config)
    echo -e "${GREEN}Резервная копия конфига создана: ${backup_dir}${RESET}"

    local backup_binary=""
    if [ -f "$target" ]; then
        backup_binary="${target}.bak.$(date +%Y%m%d_%H%M%S)"
        if cp -a "$target" "$backup_binary"; then
            echo -e "${GREEN}Резервная копия бинарника создана: ${backup_binary}${RESET}"
        else
            echo -e "${YELLOW}Внимание: не удалось создать бэкап бинарника, автооткат при ошибке будет невозможен${RESET}"
            backup_binary=""
        fi
    fi

    if ! install_snell_binary_for_version "$version" "true"; then
        if [ -n "$backup_binary" ]; then
            cp -a "$backup_binary" "$target" && echo -e "${YELLOW}Выполнен откат к исходному бинарнику${RESET}"
        fi
        return 1
    fi

    if [ "$(get_conf_snell_version "$SNELL_CONF_FILE")" = "$version" ]; then
        update_snell_symlink "$version"
    fi

    local service failed=""
    while IFS= read -r service; do
        [ -n "$service" ] || continue
        if [ "$service" = "snell" ] && ! validate_snell_main_config; then
            failed="${failed}${service} "
            continue
        fi
        echo -e "${CYAN}Перезапуск ${service}...${RESET}"
        if ! restart_and_verify_service "$service"; then
            failed="${failed}${service} "
        fi
    done <<< "$services"

    if [ -n "$failed" ]; then
        echo -e "\n${RED}Следующие службы не удалось запустить: ${failed}${RESET}"
        if [ -n "$backup_binary" ]; then
            echo -e "${YELLOW}Откат бинарника канала ${version}...${RESET}"
            cp -a "$backup_binary" "$target"
            for service in $failed; do
                systemctl restart "$service" 2>/dev/null
            done
            echo -e "${YELLOW}Откат выполнен. Резервная копия конфигурации сохранена в ${backup_dir}${RESET}"
        fi
        return 1
    fi

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}✅ Канал Snell ${version} успешно обновлен ($(get_channel_binary_version "$version"))${RESET}"
    echo -e "${GREEN}✓ Остальные каналы и настройки пользователей не затронуты${RESET}"
    echo -e "${YELLOW}Каталог резервной копии: ${backup_dir}${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    [ -n "$backup_binary" ] && rm -f "$backup_binary"
    return 0
}

snell_backup_path() {
    local src="$1"
    local stamp="$2"
    local dir="${SNELL_CONF_DIR}/backup"
    mkdir -p "$dir" 2>/dev/null || return 1
    echo "${dir}/$(basename "$src").${stamp}"
}

# Переключение пользователя на другой канал версии с автооткатом
switch_conf_to_version() {
    local conf_file="$1"
    local target_version="$2"
    local port service unit current_version

    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}Файл конфигурации не найден: ${conf_file}${RESET}"
        return 1
    fi

    current_version=$(get_conf_snell_version "$conf_file")
    port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
    if [ -z "$port" ]; then
        echo -e "${RED}Не удалось определить порт прослушивания из ${conf_file}${RESET}"
        return 1
    fi

    if [ "$current_version" = "$target_version" ]; then
        echo -e "${YELLOW}Порт ${port} уже работает на канале ${target_version}, переключение не требуется${RESET}"
        return 0
    fi

    service=$(snell_service_for_port "$port")
    if [ "$service" = "snell" ]; then
        unit="$SYSTEMD_SERVICE_FILE"
    else
        unit="${SYSTEMD_DIR}/snell-${port}.service"
    fi

    if [ ! -f "$unit" ]; then
        echo -e "${RED}Файл службы не найден: ${unit}${RESET}"
        return 1
    fi

    if ! ensure_snell_binary "$target_version"; then
        return 1
    fi

    if [ "$target_version" = "v6" ]; then
        configure_snell_v6_options "$conf_file"
    fi

    local stamp backup_conf backup_unit
    stamp=$(date +%Y%m%d_%H%M%S)
    backup_conf=$(snell_backup_path "$conf_file" "$stamp")
    if [ -z "$backup_conf" ] || ! cp -a "$conf_file" "$backup_conf"; then
        echo -e "${RED}Не удалось создать бэкап конфигурации, операция отменена${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 1
    fi
    backup_unit=$(snell_backup_path "$unit" "$stamp")
    cp -a "$unit" "$backup_unit" 2>/dev/null || backup_unit=""

    echo -e "${CYAN}Переключение порта ${port} с ${current_version} на ${target_version}...${RESET}"

    migrate_snell_conf_for_version "$conf_file" "$target_version"
    point_service_unit_to_version "$unit" "$target_version"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$target_version"
    fi

    if restart_and_verify_service "$service"; then
        echo -e "${GREEN}✓ Порт ${port} успешно переключен на Snell ${target_version}${RESET}"
        echo -e "${YELLOW}В клиенте укажите: version = ${target_version#v}${RESET}"
        if [ "$target_version" = "v6" ]; then
            echo -e "${YELLOW}И добавьте параметр: mode = $(get_snell_mode "$conf_file")${RESET}"
        fi
        echo -e "${YELLOW}Бэкап для отката: ${backup_conf}${RESET}"
        SNELL_V6_OPTIONS_SET="false"
        return 0
    fi

    echo -e "${RED}Служба не запустилась после переключения, откат на ${current_version}...${RESET}"
    cat "$backup_conf" > "$conf_file"
    [ -n "$backup_unit" ] && cat "$backup_unit" > "$unit"
    systemctl daemon-reload 2>/dev/null || true
    if [ "$service" = "snell" ]; then
        update_snell_symlink "$current_version"
    fi
    if restart_and_verify_service "$service"; then
        echo -e "${YELLOW}Откат на ${current_version} выполнен, служба работает в штатном режиме${RESET}"
    else
        echo -e "${RED}Служба не запустилась даже после отката. Проверьте: systemctl status ${service}${RESET}"
    fi
    SNELL_V6_OPTIONS_SET="false"
    return 1
}

# Проверка обновлений для всех установленных каналов
update_installed_channels() {
    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}Установленные каналы не найдены${RESET}"
        return 1
    fi

    local version current latest updated=0
    for version in $installed; do
        current=$(get_channel_binary_version "$version")
        latest=$(resolve_latest_version_for_channel "$version")
        echo -e "\n${CYAN}--- Канал ${version} ---${RESET}"
        echo -e "${YELLOW}Текущая: ${current:-неизвестно}   Последняя: ${latest:-неизвестно}${RESET}"

        if [ -z "$latest" ]; then
            echo -e "${YELLOW}Не удалось получить последнюю версию, пропуск${RESET}"
            continue
        fi
        if [ -n "$current" ] && version_greater_equal "$current" "$latest"; then
            echo -e "${GREEN}Уже установлена последняя версия${RESET}"
            continue
        fi

        echo -e "${CYAN}Найдена новая версия. Обновить канал ${version}? [y/N]${RESET}"
        read -r choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            update_snell_channel "$version" && updated=$((updated + 1))
        else
            echo -e "${CYAN}Обновление канала ${version} пропущено${RESET}"
        fi
    done

    echo -e "\n${GREEN}Проверка завершена, обновлено каналов: ${updated}${RESET}"
}

# Добавление нового канала версий (скачивание бинарника без изменения пользователей)
install_extra_channel() {
    local installed missing version
    installed=" $(list_installed_snell_versions) "
    missing=""
    for version in $SNELL_ALL_VERSIONS; do
        case "$installed" in
            *" ${version} "*) ;;
            *) missing="${missing}${version} " ;;
        esac
    done
    missing="${missing% }"

    if [ -z "$missing" ]; then
        echo -e "${GREEN}Все три канала (v4 / v5 / v6) уже установлены${RESET}"
        return 0
    fi

    echo -e "\n${YELLOW}Неустановленные каналы: ${missing}${RESET}"
    echo -e "${CYAN}После установки их можно назначить конкретным портам в «Управлении пользователями» или пункте «Сменить канал»${RESET}"
    local idx=1
    local options=()
    for version in $missing; do
        echo -e "${GREEN}${idx}.${RESET} Установить Snell ${version}"
        options+=("$version")
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} Назад"

    read -rp "Выберите пункт [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#options[@]}" ]; then
        echo -e "${RED}Недопустимый выбор${RESET}"
        return 1
    fi

    local target="${options[$((pick - 1))]}"
    if install_snell_binary_for_version "$target" "true"; then
        echo -e "${GREEN}✓ Snell ${target} готов к использованию, существующие службы не затронуты${RESET}"
    else
        return 1
    fi
}

# Переключение канала конкретного пользователя
switch_user_channel() {
    local conf_file port version
    local confs=()
    local labels=()

    if [ -f "$SNELL_CONF_FILE" ]; then
        port=$(grep -E '^listen' "$SNELL_CONF_FILE" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        version=$(get_conf_snell_version "$SNELL_CONF_FILE")
        confs+=("$SNELL_CONF_FILE")
        labels+=("Основной пользователь (порт ${port}) текущая версия: ${version}")
    fi

    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            [ -f "$conf_file" ] || continue
            case "$conf_file" in
                *snell-main.conf) continue ;;
            esac
            port=$(grep -E '^listen' "$conf_file" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            [ -n "$port" ] || continue
            version=$(get_conf_snell_version "$conf_file")
            confs+=("$conf_file")
            labels+=("Пользователь (порт ${port}) текущая версия: ${version}")
        done
    fi

    if [ "${#confs[@]}" -eq 0 ]; then
        echo -e "${RED}Нет пользователей, доступных для переключения${RESET}"
        return 1
    fi

    echo -e "\n${YELLOW}=== Выберите пользователя для смены канала ===${RESET}"
    local idx=1
    for label in "${labels[@]}"; do
        echo -e "${GREEN}${idx}.${RESET} ${label}"
        idx=$((idx + 1))
    done
    echo -e "${GREEN}0.${RESET} Назад"

    read -rp "Выберите пункт [0-$((idx - 1))]: " pick
    if [ "$pick" = "0" ] || [ -z "$pick" ]; then
        return 0
    fi
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#confs[@]}" ]; then
        echo -e "${RED}Недопустимый выбор${RESET}"
        return 1
    fi

    local selected="${confs[$((pick - 1))]}"
    local current
    current=$(get_conf_snell_version "$selected")

    echo -e "\n${YELLOW}=== Выберите целевой канал (текущий: ${current}) ===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell v4"
    echo -e "${GREEN}2.${RESET} Snell v5"
    echo -e "${GREEN}3.${RESET} Snell v6 (RC)"
    echo -e "${GREEN}0.${RESET} Назад"
    read -rp "Выберите пункт [0-3]: " target_pick

    local target=""
    case "$target_pick" in
        1) target="v4" ;;
        2) target="v5" ;;
        3)
            target="v6"
            echo -e "${YELLOW}Внимание: v6 всё ещё пре-релиз, удалены режим QUIC и obfs${RESET}"
            ;;
        0|"") return 0 ;;
        *) echo -e "${RED}Недопустимый выбор${RESET}"; return 1 ;;
    esac

    switch_conf_to_version "$selected" "$target"
}

# Меню управления версиями Snell
check_snell_update() {
    echo -e "\n${CYAN}=============== Управление версиями Snell ===============${RESET}"

    migrate_snell_binary_layout

    local installed
    installed=$(list_installed_snell_versions)
    if [ -z "$installed" ]; then
        echo -e "${RED}Установленные каналы Snell не найдены, сначала выполните установку.${RESET}"
        return 1
    fi

    echo -e "${YELLOW}Установленные каналы:${RESET}"
    local version svc_count svc_list
    for version in $installed; do
        svc_list=$(list_services_using_version "$version")
        svc_count=$(echo "$svc_list" | grep -c .)
        echo -e "  ${GREEN}${version}${RESET}   Версия: $(get_channel_binary_version "$version")   Используется: ${svc_count} служб(ами)"
    done

    echo -e "\n${GREEN}1.${RESET} Проверить и обновить установленные каналы"
    echo -e "${GREEN}2.${RESET} Установить дополнительный канал (только бинарник, без изменения конфигураций)"
    echo -e "${GREEN}3.${RESET} Сменить используемый канал для пользователя"
    echo -e "${GREEN}0.${RESET} Назад"

    read -rp "Выберите пункт [0-3]: " manage_choice
    case "$manage_choice" in
        1) update_installed_channels ;;
        2) install_extra_channel ;;
        3) switch_user_channel ;;
        0|"") echo -e "${CYAN}Возврат в меню${RESET}" ;;
        *) echo -e "${RED}Пожалуйста, выберите корректный пункт [0-3]${RESET}" ;;
    esac
}

# Получение последней версии скрипта с GitHub
get_latest_github_version() {
    local api_url="https://api.github.com/repos/jinqians/snell.sh/releases/latest"
    local response
    
    response=$(curl -s "$api_url")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        echo -e "${RED}Не удалось получить информацию о последней версии с GitHub.${RESET}"
        return 1
    fi

    GITHUB_VERSION=$(echo "$response" | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
    if [ -z "$GITHUB_VERSION" ]; then
        echo -e "${RED}Не удалось распарсить номер версии с GitHub.${RESET}"
        return 1
    fi
}

# Ручное обновление скрипта
update_script() {
    echo -e "${CYAN}Проверка обновлений скрипта...${RESET}"
    
    TMP_SCRIPT=$(mktemp)
    
    if curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh -o "$TMP_SCRIPT"; then
        new_version=$(grep -m1 -E '^current_version="' "$TMP_SCRIPT" | cut -d'"' -f2)
        
        if [ -z "$new_version" ]; then
            echo -e "${RED}Не удалось получить информацию о новой версии${RESET}"
            rm -f "$TMP_SCRIPT"
            return 1
        fi
        
        echo -e "${YELLOW}Текущая версия: ${current_version}${RESET}"
        echo -e "${YELLOW}Новая версия:   ${new_version}${RESET}"
        
        if [ "$new_version" != "$current_version" ]; then
            echo -e "${CYAN}Обновиться до новой версии? [y/N]${RESET}"
            read -r choice
            if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
                SCRIPT_PATH=$(readlink -f "$0")
                
                cp "$SCRIPT_PATH" "${SCRIPT_PATH}.backup"
                mv "$TMP_SCRIPT" "$SCRIPT_PATH"
                chmod +x "$SCRIPT_PATH"
                
                echo -e "${GREEN}Скрипт успешно обновлен${RESET}"
                echo -e "${YELLOW}Резервная копия сохранена в: ${SCRIPT_PATH}.backup${RESET}"
                echo -e "${CYAN}Пожалуйста, запустите скрипт заново для применения изменений${RESET}"
                exit 0
            else
                echo -e "${YELLOW}Обновление отменено${RESET}"
                rm -f "$TMP_SCRIPT"
            fi
        else
            echo -e "${GREEN}У вас установлена самая актуальная версия${RESET}"
            rm -f "$TMP_SCRIPT"
        fi
    else
        echo -e "${RED}Ошибка загрузки обновления, проверьте соединение с интернетом${RESET}"
        rm -f "$TMP_SCRIPT"
    fi
}

check_installation() {
    local service=$1
    if systemctl list-unit-files | grep -q "^$service.service"; then
        echo -e "${GREEN}Установлено${RESET}"
    else
        echo -e "${RED}Не установлено${RESET}"
    fi
}

get_shadowtls_config() {
    local main_port=$(get_snell_port)
    if [ -z "$main_port" ]; then
        return 1
    fi
    
    local service_name="shadowtls-snell-${main_port}"
    if ! systemctl is-active --quiet "$service_name"; then
        return 1
    fi
    
    local service_file="/etc/systemd/system/${service_name}.service"
    if [ ! -f "$service_file" ]; then
        return 1
    fi
    
    local exec_line=$(grep "ExecStart=" "$service_file")
    if [ -z "$exec_line" ]; then
        return 1
    fi
    
    local tls_domain=$(echo "$exec_line" | grep -o -- "--tls [^ ]*" | cut -d' ' -f2)
    local password=$(echo "$exec_line" | grep -o -- "--password [^ ]*" | cut -d' ' -f2)
    local listen_part=$(echo "$exec_line" | grep -o -- "--listen [^ ]*" | cut -d' ' -f2)
    local listen_port=$(echo "$listen_part" | grep -o '[0-9]*$')
    
    if [ -z "$tls_domain" ] || [ -z "$password" ] || [ -z "$listen_port" ]; then
        return 1
    fi
    
    echo "${password}|${tls_domain}|${listen_port}"
    return 0
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Пожалуйста, запустите этот скрипт с правами root${RESET}"
        exit 1
    fi
}

initial_check() {
    check_root
    check_curl
    check_bc
    check_and_migrate_config
    if [ -e "${INSTALL_DIR}/snell-server" ]; then
        migrate_snell_binary_layout
    fi
    sync_existing_main_service_unit
    check_and_show_status
}

initial_check

# Управление мульти-пользовательским режимом
setup_multi_user() {
    echo -e "${CYAN}Запуск скрипта управления несколькими пользователями...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/multi-user.sh)
    echo -e "${GREEN}Операция завершена${RESET}"
    sleep 1
}

# Главное меню
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}     Скрипт управления Snell v${current_version} (v4/v5/v6)${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}Автор: jinqian${RESET}"
    echo -e "${GREEN}Сайт : https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    check_and_show_status
    
    echo -e "${YELLOW}=== Основные функции ===${RESET}"
    echo -e "${GREEN}1.${RESET}  Установить Snell"
    echo -e "${GREEN}2.${RESET}  Удалить Snell"
    echo -e "${GREEN}3.${RESET}  Просмотреть конфигурацию"
    echo -e "${GREEN}4.${RESET}  Перезапустить службы"
    
    echo -e "\n${YELLOW}=== Дополнительные функции ===${RESET}"
    echo -e "${GREEN}5.${RESET}  Управление ShadowTLS"
    echo -e "${GREEN}6.${RESET}  Управление BBR"
    echo -e "${GREEN}7.${RESET}  Управление пользователями"
    
    echo -e "\n${YELLOW}=== Системные функции ===${RESET}"
    echo -e "${GREEN}8.${RESET}  Управление версиями (обновление / добавление / смена каналов)"
    echo -e "${GREEN}9.${RESET}  Обновить этот скрипт"
    echo -e "${GREEN}10.${RESET} Проверить статус служб"
    echo -e "${GREEN}11.${RESET} Настройка egress-контроля Snell v5/v6"
    echo -e "${GREEN}0.${RESET}  Выход"
    
    echo -e "${CYAN}============================================${RESET}"
    if ! read -rp "Выберите пункт [0-11]: " num; then
        echo
        echo -e "${YELLOW}Ввод не получен, выход из меню Snell.${RESET}"
        exit 0
    fi
}

# Настройка BBR
setup_bbr() {
    echo -e "${CYAN}Загрузка и запуск скрипта управления BBR...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/bbr.sh)
    echo -e "${GREEN}Операция настройки BBR завершена${RESET}"
    sleep 1
}

# Настройка ShadowTLS
setup_shadowtls() {
    echo -e "${CYAN}Запуск скрипта управления ShadowTLS...${RESET}"
    bash <(curl -sL https://raw.githubusercontent.com/jinqians/snell.sh/main/shadowtls.sh)
    echo -e "${GREEN}Операция настройки ShadowTLS завершена${RESET}"
    sleep 1
}

get_snell_port() {
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p'
    fi
}

get_all_snell_users() {
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_DIR}/users/snell-main.conf" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_DIR}/users/snell-main.conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_DIR}/users/snell-main.conf" | awk -F'=' '{print $2}' | tr -d ' ')
        if [ ! -z "$main_port" ] && [ ! -z "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi
    
    for user_conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$user_conf" ] && [[ "$user_conf" != *"snell-main.conf" ]]; then
            local port=$(grep -E '^listen' "$user_conf" | sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\).*/\1/p')
            local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
            if [ ! -z "$port" ] && [ ! -z "$psk" ]; then
                echo "${port}|${psk}"
            fi
        fi
    done
}

# Основной цикл обработки
while true; do
    show_menu
    case "$num" in
        1)
            install_snell
            ;;
        2)
            uninstall_snell
            ;;
        3)
            view_snell_config
            ;;
        4)
            restart_snell
            ;;
        5)
            setup_shadowtls
            ;;
        6)
            setup_bbr
            ;;
        7)
            setup_multi_user
            ;;
        8)
            check_snell_update
            ;;
        9)
            update_script
            ;;
        10)
            check_and_show_status
            read -p "Нажмите любую клавишу для продолжения..." || exit 0
            ;;
        11)
            configure_v5_egress_control
            read -p "Нажмите любую клавишу для продолжения..." || exit 0
            ;;
        0)
            echo -e "${GREEN}Спасибо за использование! До свидания!${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}Пожалуйста, выберите корректный пункт [0-11]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}Нажмите любую клавишу для возврата в главное меню...${RESET}"
    read -n 1 -s -r || exit 0
done
