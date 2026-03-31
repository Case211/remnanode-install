#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════╗
# ║  Remnawave Node Installer v3                                    ║
# ║  Установка, обновление и диагностика RemnawaveNode + Caddy      ║
# ║  HTTP-01 / DNS-01 (Cloudflare) сертификаты                      ║
# ╚════════════════════════════════════════════════════════════════╝

set -Eeuo pipefail

# Проверка версии bash (требуется 4.0+ для массивов и ассоциативных массивов)
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Ошибка: требуется bash версии 4.0 или выше (текущая: $BASH_VERSION)" >&2
    exit 1
fi

# Логирование в файл (ANSI-коды очищаются при выходе)
INSTALL_LOG="/var/log/remnanode-install.log"
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "--- Начало установки: $(date) ---" >> "$INSTALL_LOG"

# Отслеживание temp файлов для гарантированной очистки
TEMP_FILES=()

# Функция очистки при выходе
_cleanup_on_exit() {
    local exit_code=$?
    # Восстановление автообновлений если были остановлены
    if [ "${_RESTORE_AUTO_UPDATES:-false}" = true ]; then
        restore_auto_updates 2>/dev/null || true
    fi
    # Очистка temp файлов
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
    # Удаление ANSI-кодов из лог-файла для читаемости
    if [ -f "$INSTALL_LOG" ]; then
        sed -i 's/\x1b\[[0-9;]*m//g' "$INSTALL_LOG" 2>/dev/null || true
    fi
    return $exit_code
}

# Обработка ошибок и очистка
trap 'log_error "Ошибка на строке $LINENO. Команда: $BASH_COMMAND"' ERR
trap '_cleanup_on_exit' EXIT

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly GRAY='\033[0;37m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'

# Версия скрипта
readonly SCRIPT_VERSION="3.0.0"

# Константы
INSTALL_DIR="/opt"
REMNANODE_DIR="$INSTALL_DIR/remnanode"
REMNANODE_DATA_DIR="/var/lib/remnanode"
CADDY_DIR="$INSTALL_DIR/caddy"
CADDY_HTML_DIR="$CADDY_DIR/html"
CADDY_VERSION="2.10.2"
CADDY_IMAGE="caddy:${CADDY_VERSION}"
CADVISOR_VERSION="0.53.0"
NODE_EXPORTER_VERSION="1.9.1"
VMAGENT_VERSION="1.123.0"
DEFAULT_PORT="9443"
USE_WILDCARD=false
USE_EXISTING_CERT=false
EXISTING_CERT_LOCATION=""
CLOUDFLARE_API_TOKEN=""

# ═══════════════════════════════════════════════════════════════════
#  Non-interactive режим (env переменные или конфиг-файл)
# ═══════════════════════════════════════════════════════════════════
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
CONFIG_FILE="${CONFIG_FILE:-/etc/remnanode-install.conf}"

# Переменные для non-interactive режима
CFG_SECRET_KEY="${CFG_SECRET_KEY:-}"
CFG_NODE_PORT="${CFG_NODE_PORT:-3000}"
CFG_INSTALL_XRAY="${CFG_INSTALL_XRAY:-y}"
CFG_DOMAIN="${CFG_DOMAIN:-}"
CFG_CERT_TYPE="${CFG_CERT_TYPE:-1}"
CFG_CLOUDFLARE_TOKEN="${CFG_CLOUDFLARE_TOKEN:-}"
CFG_CADDY_PORT="${CFG_CADDY_PORT:-$DEFAULT_PORT}"
CFG_INSTALL_NETBIRD="${CFG_INSTALL_NETBIRD:-n}"
CFG_NETBIRD_SETUP_KEY="${CFG_NETBIRD_SETUP_KEY:-}"
CFG_INSTALL_MONITORING="${CFG_INSTALL_MONITORING:-n}"
CFG_INSTANCE_NAME="${CFG_INSTANCE_NAME:-}"
CFG_GRAFANA_IP="${CFG_GRAFANA_IP:-}"
CFG_APPLY_NETWORK="${CFG_APPLY_NETWORK:-y}"
CFG_SETUP_UFW="${CFG_SETUP_UFW:-y}"
CFG_INSTALL_FAIL2BAN="${CFG_INSTALL_FAIL2BAN:-y}"

# Отслеживание статуса установки для финального саммари
STATUS_NETWORK="пропущен"
STATUS_DOCKER="пропущен"
STATUS_REMNANODE="пропущен"
STATUS_CADDY="пропущен"
STATUS_UFW="пропущен"
STATUS_FAIL2BAN="пропущен"
STATUS_NETBIRD="пропущен"
STATUS_MONITORING="пропущен"

# Детали установки (заполняются по ходу)
DETAIL_REMNANODE_PORT=""
DETAIL_CADDY_DOMAIN=""
DETAIL_CADDY_PORT=""
DETAIL_NETBIRD_IP=""
DETAIL_GRAFANA_IP=""

# Получение IP сервера
get_server_ip() {
    local ip
    ip=$(curl -s -4 --connect-timeout 5 ifconfig.io 2>/dev/null | tr -d '[:space:]') || \
    ip=$(curl -s -4 --connect-timeout 5 icanhazip.com 2>/dev/null | tr -d '[:space:]') || \
    ip=$(curl -s -4 --connect-timeout 5 ipecho.net/plain 2>/dev/null | tr -d '[:space:]') || \
    ip="127.0.0.1"
    echo "${ip:-127.0.0.1}"
}

# NODE_IP инициализируется в main() после check_root
NODE_IP=""

# Функции логирования
log_info() {
    echo -e "${WHITE}ℹ️  $*${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $*${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $*${NC}"
}

log_error() {
    echo -e "${RED}❌ $*${NC}" >&2
}

# ═══════════════════════════════════════════════════════════════════
#  Утилиты: спиннер, валидация, бэкап, проверки
# ═══════════════════════════════════════════════════════════════════

# Создание отслеживаемого temp файла (автоочистка при выходе)
create_temp_file() {
    local tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")
    echo "$tmp"
}

# Анимированный спиннер для длительных операций
spinner() {
    local pid=$1
    local msg="${2:-Выполнение...}"
    local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0

    # Без спиннера в non-interactive режиме
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        wait "$pid" 2>/dev/null
        return $?
    fi

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}%s${NC} %s" "${frames[$i]}" "$msg"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.1
    done
    printf "\r\033[K"
    wait "$pid" 2>/dev/null
    return $?
}

# Скачивание файла со спиннером
download_with_progress() {
    local url="$1"
    local output="$2"
    local msg="${3:-Скачивание...}"

    wget --timeout=60 --tries=5 --waitretry=2 "$url" -q -O "$output" &
    local pid=$!
    spinner "$pid" "$msg"
    return $?
}

# Валидированный выбор из меню (с повторным запросом при ошибке)
prompt_choice() {
    local prompt="$1"
    local max="$2"
    local result_var="$3"
    local default="${4:-}"

    # Non-interactive: использовать default
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        printf -v "$result_var" '%s' "${default:-1}"
        return 0
    fi

    while true; do
        read -p "$prompt" -r _choice
        # Если пустой ввод и есть default
        if [ -z "$_choice" ] && [ -n "$default" ]; then
            printf -v "$result_var" '%s' "$default"
            return 0
        fi
        if [[ "$_choice" =~ ^[0-9]+$ ]] && [ "$_choice" -ge 0 ] && [ "$_choice" -le "$max" ]; then
            printf -v "$result_var" '%s' "$_choice"
            return 0
        fi
        log_warning "Неверный выбор. Введите число от 0 до $max."
    done
}

# Запрос yes/no с валидацией
prompt_yn() {
    local prompt="$1"
    local default="${2:-}"
    local config_val="${3:-}"

    # Non-interactive: использовать config значение или default
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        local val="${config_val:-$default}"
        [[ "$val" =~ ^[Yy]$ ]] && return 0 || return 1
    fi

    while true; do
        read -p "$prompt" -r _answer
        _answer="${_answer:-$default}"
        if [[ "$_answer" =~ ^[Yy]$ ]]; then
            return 0
        elif [[ "$_answer" =~ ^[Nn]$ ]]; then
            return 1
        fi
        log_warning "Введите y или n."
    done
}

# Проверка свободного места на диске
check_disk_space() {
    local required_mb="${1:-500}"
    local target_dir="${2:-/opt}"

    local available_mb
    available_mb=$(df -m "$target_dir" 2>/dev/null | awk 'NR==2 {print $4}')

    if [ -z "$available_mb" ]; then
        log_warning "Не удалось определить свободное место на диске"
        return 0
    fi

    if [ "$available_mb" -lt "$required_mb" ]; then
        log_error "Недостаточно места на диске: ${available_mb} МБ доступно, требуется минимум ${required_mb} МБ"
        return 1
    fi

    log_success "Свободное место на диске: ${available_mb} МБ"
    return 0
}

# Бэкап существующей конфигурации перед перезаписью
backup_existing_config() {
    local dir="$1"
    local backup_dir="${dir}.backup.$(date +%Y%m%d_%H%M%S)"

    if [ -d "$dir" ]; then
        local has_files=false
        for f in "$dir"/.env "$dir"/docker-compose.yml "$dir"/Caddyfile; do
            if [ -f "$f" ]; then
                has_files=true
                break
            fi
        done

        if [ "$has_files" = true ]; then
            mkdir -p "$backup_dir"
            for f in "$dir"/.env "$dir"/docker-compose.yml "$dir"/Caddyfile; do
                [ -f "$f" ] && cp "$f" "$backup_dir/" 2>/dev/null || true
            done
            # Защита секретов в бэкапе
            chmod 700 "$backup_dir"
            [ -f "$backup_dir/.env" ] && chmod 600 "$backup_dir/.env"
            log_info "Бэкап конфигурации: $backup_dir"
        fi
    fi
}

# Валидация Cloudflare API Token через API
validate_cloudflare_token() {
    local token="$1"

    log_info "Проверка Cloudflare API Token..."

    local response
    response=$(curl -s --connect-timeout 10 --max-time 15 \
        -H "Authorization: Bearer $token" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || true

    if echo "$response" | grep -q '"success":true'; then
        log_success "Cloudflare API Token валиден"
        return 0
    else
        local error_msg
        error_msg=$(echo "$response" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p' | head -1)
        log_error "Cloudflare API Token невалиден${error_msg:+: $error_msg}"
        return 1
    fi
}

# Получение последней версии с GitHub (с fallback)
fetch_latest_version() {
    local repo="$1"
    local default="$2"

    local version=""
    local api_response
    api_response=$(curl -s --connect-timeout 5 --max-time 10 \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || true

    if [ -n "$api_response" ]; then
        # Используем jq если доступен, иначе sed
        if command -v jq >/dev/null 2>&1; then
            version=$(echo "$api_response" | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
        else
            version=$(echo "$api_response" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 | sed 's/^v//')
        fi
    fi

    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "$default"
    fi
}

# Получение последней версии VictoriaMetrics с open-source vmutils
# /releases/latest может указывать на enterprise-only LTS ветку (v1.122.x),
# поэтому ищем первый релиз с open-source vmutils-linux ассетом
fetch_latest_vmagent_version() {
    local default="$1"
    local version=""
    local api_response

    api_response=$(curl -s --connect-timeout 5 --max-time 15 \
        "https://api.github.com/repos/VictoriaMetrics/VictoriaMetrics/releases?per_page=15" 2>/dev/null) || true

    if [ -n "$api_response" ]; then
        if command -v jq >/dev/null 2>&1; then
            # Найти первый релиз, содержащий open-source vmutils-linux ассет
            version=$(echo "$api_response" | jq -r '
                [.[] | select(.assets[]?.name | test("^vmutils-linux-.*\\.tar\\.gz$") and (test("enterprise") | not))][0].tag_name // empty
            ' 2>/dev/null | sed 's/^v//')
        else
            # Без jq — проверяем URL каждого релиза до первого успешного
            local tags
            tags=$(echo "$api_response" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
            for tag in $tags; do
                local ver="${tag#v}"
                local check_url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${tag}/vmutils-linux-amd64-${tag}.tar.gz"
                local http_code
                http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 --max-time 5 -I -L "$check_url" 2>/dev/null) || true
                if [ "$http_code" = "200" ]; then
                    version="$ver"
                    break
                fi
            done
        fi
    fi

    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "$default"
    fi
}

# Проверка здоровья Docker контейнера с ожиданием
check_container_health() {
    local compose_dir="$1"
    local service_name="$2"
    local max_wait="${3:-30}"

    local waited=0
    while [ $waited -lt "$max_wait" ]; do
        if docker compose --project-directory "$compose_dir" ps "$service_name" 2>/dev/null | grep -qE "Up|running"; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# Загрузка конфиг-файла для non-interactive режима
load_config_file() {
    local config_file="${1:-$CONFIG_FILE}"

    if [ -f "$config_file" ]; then
        # Проверка безопасности конфиг-файла
        local file_owner file_perms
        file_owner=$(stat -c '%U' "$config_file" 2>/dev/null || echo "unknown")
        file_perms=$(stat -c '%a' "$config_file" 2>/dev/null || echo "unknown")
        if [ "$file_owner" != "root" ]; then
            log_warning "Конфиг-файл $config_file принадлежит $file_owner (ожидается root)"
        fi
        if [[ "$file_perms" =~ [0-7][2367][0-7] ]]; then
            log_warning "Конфиг-файл $config_file доступен на запись группе/другим (права: $file_perms)"
        fi
        log_info "Загрузка конфигурации из $config_file"
        # Безопасный парсинг: извлекаем только известные CFG_* переменные (без eval/source)
        local _allowed_vars="CFG_SECRET_KEY CFG_NODE_PORT CFG_INSTALL_XRAY CFG_DOMAIN CFG_CERT_TYPE CFG_CLOUDFLARE_TOKEN CFG_CADDY_PORT CFG_INSTALL_NETBIRD CFG_NETBIRD_SETUP_KEY CFG_INSTALL_MONITORING CFG_INSTANCE_NAME CFG_GRAFANA_IP CFG_APPLY_NETWORK CFG_SETUP_UFW CFG_INSTALL_FAIL2BAN NON_INTERACTIVE"
        while IFS='=' read -r key value; do
            # Пропуск комментариев и пустых строк
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Удаление пробелов вокруг ключа
            key=$(echo "$key" | xargs)
            # Удаление кавычек из значения
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            # Присваиваем только разрешённые переменные
            if echo " $_allowed_vars " | grep -q " $key "; then
                printf -v "$key" '%s' "$value"
            else
                log_warning "Игнорируется неизвестная переменная в конфиге: $key"
            fi
        done < "$config_file"
        NON_INTERACTIVE=true
    fi
}

# Итоговое саммари установки
show_installation_summary() {
    echo
    print_separator '═'
    echo -e "${WHITE}${BOLD}  📋 Итоги установки${NC}"
    print_separator '═'
    echo

    local -a components=("network:Сетевые настройки" "docker:Docker" "remnanode:RemnawaveNode" "caddy:Caddy Selfsteal" "ufw:UFW Firewall" "fail2ban:Fail2ban" "netbird:Netbird VPN" "monitoring:Мониторинг Grafana")

    for entry in "${components[@]}"; do
        local key="${entry%%:*}"
        local label="${entry#*:}"
        local status

        case "$key" in
            network)     status="$STATUS_NETWORK" ;;
            docker)      status="$STATUS_DOCKER" ;;
            remnanode)   status="$STATUS_REMNANODE" ;;
            caddy)       status="$STATUS_CADDY" ;;
            ufw)         status="$STATUS_UFW" ;;
            fail2ban)    status="$STATUS_FAIL2BAN" ;;
            netbird)     status="$STATUS_NETBIRD" ;;
            monitoring)  status="$STATUS_MONITORING" ;;
        esac

        local icon status_colored
        case "$status" in
            "установлен"|"настроен"|"запущен"|"подключен"|"уже установлен"|"применены")
                icon="✅"
                status_colored="${GREEN}${status}${NC}"
                ;;
            "пропущен")
                icon="⏭️ "
                status_colored="${GRAY}${status}${NC}"
                ;;
            "ошибка"|"не запущен")
                icon="❌"
                status_colored="${RED}${status}${NC}"
                ;;
            *)
                icon="⚠️ "
                status_colored="${YELLOW}${status}${NC}"
                ;;
        esac

        printf "  %s  %-24s %b\n" "$icon" "$label" "$status_colored"
    done

    # Детали
    echo
    if [ -n "$DETAIL_REMNANODE_PORT" ]; then
        echo -e "${GRAY}  Node порт: $DETAIL_REMNANODE_PORT${NC}"
    fi
    if [ -n "$DETAIL_CADDY_DOMAIN" ]; then
        echo -e "${GRAY}  Домен: $DETAIL_CADDY_DOMAIN${NC}"
    fi
    if [ -n "$DETAIL_CADDY_PORT" ]; then
        echo -e "${GRAY}  HTTPS порт: $DETAIL_CADDY_PORT${NC}"
    fi
    if [ -n "$DETAIL_NETBIRD_IP" ]; then
        echo -e "${GRAY}  Netbird IP: $DETAIL_NETBIRD_IP${NC}"
    fi
    if [ -n "$DETAIL_GRAFANA_IP" ]; then
        echo -e "${GRAY}  Grafana: $DETAIL_GRAFANA_IP${NC}"
    fi

    echo
    print_separator '═'
    echo -e "${GRAY}  Сервер: $NODE_IP${NC}"
    echo -e "${GRAY}  Лог: $INSTALL_LOG${NC}"
    print_separator '═'
    echo
}

# ═══════════════════════════════════════════════════════════════════
#  UI Helper функции
# ═══════════════════════════════════════════════════════════════════

# Горизонтальный разделитель стандартной ширины
print_separator() {
    local char="${1:-─}"
    local width="${2:-56}"
    echo -e "${GRAY}$(printf "${char}%.0s" $(seq 1 "$width"))${NC}"
}

# Стандартный заголовок секции
print_header() {
    local title="$1"
    local emoji="${2:-}"
    echo
    print_separator '─'
    if [ -n "$emoji" ]; then
        echo -e "${WHITE}${BOLD}${emoji}  ${title}${NC}"
    else
        echo -e "${WHITE}${BOLD}  ${title}${NC}"
    fi
    print_separator '─'
    echo
}

# Стартовый баннер
print_banner() {
    echo
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC}  ${WHITE}${BOLD}🚀 Remnawave Node Installer v${SCRIPT_VERSION}${NC}                    ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC}  ${GRAY}RemnawaveNode + Caddy Selfsteal${NC}                         ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}║${NC}  ${GRAY}Автоматический установщик для Linux${NC}                     ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
}

# Проверка и отображение текущего состояния системы
show_system_status() {
    echo
    print_separator '═'
    echo -e "${WHITE}${BOLD}  📋 Состояние системы${NC}"
    print_separator '═'
    echo

    # Системная информация
    local os_name ip_addr disk_free ram_free ram_total
    os_name=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || echo "Неизвестно")
    ip_addr="${NODE_IP:-$(get_server_ip 2>/dev/null || echo '?')}"
    disk_free=$(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo "?")
    ram_total=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo "?")
    ram_free=$(free -h 2>/dev/null | awk '/^Mem:/{print $7}' || echo "?")

    echo -e "  ${GRAY}ОС:${NC}      ${WHITE}${os_name}${NC}"
    echo -e "  ${GRAY}IP:${NC}      ${WHITE}${ip_addr}${NC}"
    echo -e "  ${GRAY}Диск:${NC}    ${WHITE}${disk_free} свободно${NC}"
    echo -e "  ${GRAY}RAM:${NC}     ${WHITE}${ram_free} / ${ram_total}${NC}"
    echo
    print_separator '─'
    echo

    # Docker
    if command -v docker >/dev/null 2>&1; then
        local docker_ver
        docker_ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "?")
        if systemctl is-active --quiet docker 2>/dev/null; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "Docker" "запущен v${docker_ver}"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "Docker" "установлен, не запущен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "Docker" "не установлен"
    fi

    # RemnawaveNode
    if check_existing_remnanode 2>/dev/null; then
        if command -v docker >/dev/null 2>&1 && docker compose --project-directory "$REMNANODE_DIR" ps 2>/dev/null | grep -qE "Up|running"; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "RemnawaveNode" "запущен"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "RemnawaveNode" "установлен, остановлен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "RemnawaveNode" "не установлен"
    fi

    # Caddy
    if check_existing_caddy 2>/dev/null; then
        if command -v docker >/dev/null 2>&1 && docker compose --project-directory "$CADDY_DIR" ps 2>/dev/null | grep -qE "Up|running"; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "Caddy Selfsteal" "запущен"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "Caddy Selfsteal" "установлен, остановлен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "Caddy Selfsteal" "не установлен"
    fi

    # UFW
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "active"; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "UFW Firewall" "активен"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "UFW Firewall" "установлен, неактивен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "UFW Firewall" "не установлен"
    fi

    # Fail2ban
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "Fail2ban" "активен"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "Fail2ban" "установлен, не запущен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "Fail2ban" "не установлен"
    fi

    # Netbird
    if check_existing_netbird 2>/dev/null; then
        if netbird status 2>/dev/null | grep -qi "connected"; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "Netbird VPN" "подключен"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "Netbird VPN" "установлен, не подключен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "Netbird VPN" "не установлен"
    fi

    # Мониторинг
    if check_existing_monitoring 2>/dev/null; then
        if systemctl is-active --quiet vmagent 2>/dev/null; then
            printf "  ✅  ${GRAY}%-24s${NC} ${GREEN}%s${NC}\n" "Grafana мониторинг" "запущен"
        else
            printf "  ⚠️   ${GRAY}%-24s${NC} ${YELLOW}%s${NC}\n" "Grafana мониторинг" "установлен, остановлен"
        fi
    else
        printf "  ⭕  ${GRAY}%-24s${NC} ${GRAY}%s${NC}\n" "Grafana мониторинг" "не установлен"
    fi

    echo
    print_separator '═'
    echo
}

# Главное меню (интерактивный режим)
show_main_menu() {
    while true; do
        print_separator '─'
        echo -e "${WHITE}${BOLD}  Выберите действие:${NC}"
        print_separator '─'
        echo
        echo -e "   ${CYAN}1)${NC} ${WHITE}🚀 Установить всё${NC}              ${GRAY}(полная установка)${NC}"
        echo -e "   ${CYAN}2)${NC} ${WHITE}📦 Выборочная установка${NC}        ${GRAY}(выбрать компоненты)${NC}"
        echo -e "   ${CYAN}3)${NC} ${WHITE}📋 Проверить статус${NC}            ${GRAY}(текущее состояние)${NC}"
        echo -e "   ${CYAN}4)${NC} ${WHITE}🗑️  Удалить всё${NC}                ${GRAY}(полное удаление)${NC}"
        echo -e "   ${CYAN}5)${NC} ${WHITE}❓ Справка${NC}                     ${GRAY}(--help)${NC}"
        echo -e "   ${CYAN}0)${NC} ${WHITE}🚪 Выход${NC}"
        echo
        print_separator '─'
        echo

        local menu_choice
        prompt_choice "Введите номер [0-5]: " 5 menu_choice "0"

        case "$menu_choice" in
            0) log_info "Выход."; exit 0 ;;
            1) run_full_install; return ;;
            2) run_selective_install; return ;;
            3) show_system_status ;;
            4) uninstall_all; return ;;
            5) show_help ;;
        esac
    done
}

# Выборочная установка — выбор компонентов
run_selective_install() {
    print_header "Выборочная установка" "📦"
    echo -e "${GRAY}  Выберите компоненты для установки.${NC}"
    echo -e "${GRAY}  Введите номера через пробел (например: 1 3 5)${NC}"
    echo -e "${GRAY}  или нажмите ENTER для выбора всех.${NC}"
    echo
    echo -e "   ${CYAN}1)${NC} 🌐 Сетевые настройки      ${GRAY}(BBR, TCP tuning)${NC}"
    echo -e "   ${CYAN}2)${NC} 🐳 Docker                  ${GRAY}(обязателен для 3 и 4)${NC}"
    echo -e "   ${CYAN}3)${NC} 📦 RemnawaveNode           ${GRAY}(требует Docker)${NC}"
    echo -e "   ${CYAN}4)${NC} 🔒 Caddy Selfsteal         ${GRAY}(требует Docker)${NC}"
    echo -e "   ${CYAN}5)${NC} 🛡️  UFW Firewall${NC}"
    echo -e "   ${CYAN}6)${NC} 🛡️  Fail2ban${NC}"
    echo -e "   ${CYAN}7)${NC} 🌐 Netbird VPN${NC}"
    echo -e "   ${CYAN}8)${NC} 📊 Grafana мониторинг${NC}"
    echo

    local selection_raw
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        selection_raw="1 2 3 4 5 6 7 8"
    else
        read -p "Ваш выбор [1-8, ENTER=все]: " -r selection_raw
        if [ -z "$selection_raw" ]; then
            selection_raw="1 2 3 4 5 6 7 8"
        fi
    fi

    # Валидация
    local -a chosen=()
    for token in $selection_raw; do
        if [[ "$token" =~ ^[1-8]$ ]]; then
            chosen+=("$token")
        else
            log_warning "Неверный номер '$token' — пропущен"
        fi
    done

    if [ ${#chosen[@]} -eq 0 ]; then
        log_error "Не выбрано ни одного компонента."
        return 1
    fi

    # Автодобавление Docker если выбран Remnanode/Caddy
    local need_docker=false
    for c in "${chosen[@]}"; do
        [[ "$c" == "3" || "$c" == "4" ]] && need_docker=true
    done
    if [ "$need_docker" = true ]; then
        local has_docker=false
        for c in "${chosen[@]}"; do [ "$c" = "2" ] && has_docker=true; done
        if [ "$has_docker" = false ] && ! command -v docker >/dev/null 2>&1; then
            log_warning "RemnawaveNode/Caddy требуют Docker. Docker добавлен автоматически."
            chosen=("2" "${chosen[@]}")
        fi
    fi

    echo
    log_info "Выбранные компоненты: ${chosen[*]}"
    echo

    # Общие подготовительные шаги (если ещё не выполнены)
    if [ -z "${NODE_IP:-}" ]; then
        NODE_IP=$(get_server_ip)
    fi
    if [ -z "${OS:-}" ]; then
        detect_os
        detect_package_manager
    fi

    if ! check_disk_space 500 "/opt"; then
        if ! prompt_yn "Недостаточно места. Продолжить? (y/n): " "n"; then
            return 1
        fi
    fi

    ensure_package_manager_available
    _RESTORE_AUTO_UPDATES=true

    # Установка базовых утилит
    install_base_utilities

    # Автоопределение версий
    update_component_versions

    # Выполнение в фиксированном порядке зависимостей
    for c in 1 2 3 4 5 6 7 8; do
        local selected=false
        for x in "${chosen[@]}"; do [ "$x" = "$c" ] && selected=true; done
        [ "$selected" = false ] && continue

        case "$c" in
            1) apply_network_settings ;;
            2)
                if ! install_docker; then
                    log_error "Не удалось установить Docker"
                    STATUS_DOCKER="ошибка"
                    continue
                fi
                STATUS_DOCKER="установлен"
                check_docker_compose
                ;;
            3) install_remnanode ;;
            4) install_caddy_selfsteal ;;
            5) setup_ufw ;;
            6) install_fail2ban ;;
            7) install_netbird ;;
            8) install_grafana_monitoring ;;
        esac
        echo
    done

    restore_auto_updates
    _RESTORE_AUTO_UPDATES=false
    show_installation_summary
    log_success "Выборочная установка завершена."
}

# Проверка root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log_error "Скрипт должен запускаться от root (используйте sudo)"
        exit 1
    fi
}

# Определение ОС
detect_os() {
    if [ -f /etc/lsb-release ]; then
        OS=$(lsb_release -si)
    elif [ -f /etc/os-release ]; then
        OS=$(awk -F= '/^NAME=/{print $2}' /etc/os-release | tr -d '"')
        if [[ "$OS" == "Amazon Linux" ]]; then
            OS="Amazon"
        fi
    elif [ -f /etc/redhat-release ]; then
        OS=$(awk '{print $1}' /etc/redhat-release)
    elif [ -f /etc/arch-release ]; then
        OS="Arch"
    else
        log_error "Неподдерживаемая операционная система"
        exit 1
    fi
}

# Определение архитектуры (формат: xray|prometheus|generic)
# Использование: detect_arch xray → "64", detect_arch prometheus → "amd64"
detect_arch() {
    local format="${1:-generic}"
    local arch
    arch=$(uname -m)

    case "$format" in
        xray)
            case "$arch" in
                x86_64) echo "64" ;;
                aarch64|arm64) echo "arm64-v8a" ;;
                armv7l|armv6l) echo "arm32-v7a" ;;
                *) log_error "Неподдерживаемая архитектура: $arch"; return 1 ;;
            esac
            ;;
        prometheus|generic|*)
            case "$arch" in
                x86_64) echo "amd64" ;;
                aarch64|arm64) echo "arm64" ;;
                armv7l|armv6l) echo "armv7" ;;
                *) log_error "Неподдерживаемая архитектура: $arch"; return 1 ;;
            esac
            ;;
    esac
}

# Обновление версий компонентов через GitHub API
update_component_versions() {
    log_info "Проверка актуальных версий компонентов..."
    local new_ver

    new_ver=$(fetch_latest_version "google/cadvisor" "$CADVISOR_VERSION")
    if [ -n "$new_ver" ]; then
        [ "$new_ver" != "$CADVISOR_VERSION" ] && log_info "cAdvisor: v$new_ver (обновлено)"
        CADVISOR_VERSION="$new_ver"
    fi

    new_ver=$(fetch_latest_version "prometheus/node_exporter" "$NODE_EXPORTER_VERSION")
    if [ -n "$new_ver" ]; then
        [ "$new_ver" != "$NODE_EXPORTER_VERSION" ] && log_info "Node Exporter: v$new_ver (обновлено)"
        NODE_EXPORTER_VERSION="$new_ver"
    fi

    new_ver=$(fetch_latest_vmagent_version "$VMAGENT_VERSION")
    if [ -n "$new_ver" ]; then
        [ "$new_ver" != "$VMAGENT_VERSION" ] && log_info "VM Agent: v$new_ver (обновлено)"
        VMAGENT_VERSION="$new_ver"
    fi
}

# Определение пакетного менеджера
detect_package_manager() {
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        PKG_MANAGER="apt-get"
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]] || [[ "$OS" == "Amazon"* ]]; then
        PKG_MANAGER="yum"
    elif [[ "$OS" == "Fedora"* ]]; then
        PKG_MANAGER="dnf"
    elif [[ "$OS" == "Arch"* ]]; then
        PKG_MANAGER="pacman"
    else
        log_error "Неподдерживаемая операционная система"
        exit 1
    fi
}

# Установка пакета
install_package() {
    local package=$1
    local install_log
    install_log=$(create_temp_file)
    local install_success=false
    
    # Для Ubuntu/Debian проверяем блокировку перед установкой
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        # Быстрая проверка блокировки
        if is_dpkg_locked; then
            log_warning "Обнаружен процесс обновления системы. Ожидание..."
            if ! wait_for_dpkg_lock; then
                log_error "Не удалось дождаться освобождения пакетного менеджера"
                rm -f "$install_log"
                return 1
            fi
        fi

        # apt-get update выполняется один раз, потом кешируется флагом
        if [ "${_APT_UPDATED:-}" != "true" ]; then
            $PKG_MANAGER update -qq >"$install_log" 2>&1 || true
            _APT_UPDATED=true
        fi

        if $PKG_MANAGER install -y -qq "$package" >>"$install_log" 2>&1; then
            install_success=true
        else
            # Проверяем если это ошибка lock
            if grep -q "lock" "$install_log" 2>/dev/null; then
                log_warning "Обнаружена блокировка пакетного менеджера. Ожидание..."
                if wait_for_dpkg_lock; then
                    log_info "Повторная попытка установки $package..."
                    rm -f "$install_log"
                    install_log=$(create_temp_file)
                    if $PKG_MANAGER install -y -qq "$package" >>"$install_log" 2>&1; then
                        install_success=true
                    fi
                fi
            fi
        fi
    elif [[ "$OS" == "CentOS"* ]] || [[ "$OS" == "AlmaLinux"* ]] || [[ "$OS" == "Amazon"* ]]; then
        if $PKG_MANAGER install -y -q "$package" >"$install_log" 2>&1; then
            install_success=true
        fi
    elif [[ "$OS" == "Fedora"* ]]; then
        if $PKG_MANAGER install -y -q "$package" >"$install_log" 2>&1; then
            install_success=true
        fi
    elif [[ "$OS" == "Arch"* ]]; then
        if $PKG_MANAGER -S --noconfirm --quiet "$package" >"$install_log" 2>&1; then
            install_success=true
        fi
    fi
    
    if [ "$install_success" = false ]; then
        log_error "Ошибка установки $package"
        if [ -s "$install_log" ]; then
            local error_details=$(tail -3 "$install_log" | tr '\n' ' ' | head -c 200)
            log_error "Детали: $error_details"
        fi
        rm -f "$install_log"
        return 1
    fi
    
    rm -f "$install_log"
    return 0
}

# Проверка, заблокирован ли пакетный менеджер
is_dpkg_locked() {
    # Проверяем процессы, которые могут держать lock (точное совпадение имени процесса)
    if pgrep -x 'dpkg' >/dev/null 2>&1 || \
       pgrep -x 'apt-get' >/dev/null 2>&1 || \
       pgrep -x 'apt' >/dev/null 2>&1 || \
       pgrep -x 'aptitude' >/dev/null 2>&1 || \
       pgrep -f 'unattended-upgr' >/dev/null 2>&1 || \
       pgrep -f 'apt.systemd.daily' >/dev/null 2>&1; then
        return 0  # Заблокирован
    fi

    # Проверяем lock файлы через fuser
    if command -v fuser >/dev/null 2>&1; then
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
           fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
           fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            return 0  # Заблокирован
        fi
    fi

    # Проверяем lock файлы через lsof
    if command -v lsof >/dev/null 2>&1; then
        if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
           lsof /var/lib/dpkg/lock >/dev/null 2>&1; then
            return 0  # Заблокирован
        fi
    fi

    return 1  # Свободен
}

# Ожидание освобождения dpkg lock
wait_for_dpkg_lock() {
    log_info "Проверка доступности пакетного менеджера..."
    local max_wait=300  # Максимум 5 минут
    local waited=0

    # Если уже свободен, возвращаемся сразу
    if ! is_dpkg_locked; then
        return 0
    fi

    log_warning "Пакетный менеджер заблокирован другим процессом (вероятно, обновление системы)"
    log_info "Ожидание освобождения..."

    while [ $waited -lt $max_wait ]; do
        if ! is_dpkg_locked; then
            # Дополнительно проверяем, что dpkg --configure -a проходит
            if dpkg --configure -a >/dev/null 2>&1; then
                log_success "Пакетный менеджер свободен"
                return 0
            fi
        fi

        sleep 5
        waited=$((waited + 5))

        # Показываем прогресс каждые 30 секунд
        if [ $((waited % 30)) -eq 0 ]; then
            log_info "Ожидание... ($waited/$max_wait сек)"
        fi
    done

    log_error "Не удалось дождаться освобождения пакетного менеджера (ожидалось $max_wait сек)"
    return 1
}

# Проактивная очистка блокировок пакетного менеджера перед установкой
# Останавливает автоматические обновления и ждёт освобождения lock
ensure_package_manager_available() {
    # Только для Debian/Ubuntu
    if [[ "$PKG_MANAGER" != "apt-get" ]]; then
        return 0
    fi

    log_info "Подготовка пакетного менеджера..."

    # Останавливаем службы автоматических обновлений
    local services_to_stop=("unattended-upgrades" "apt-daily.service" "apt-daily-upgrade.service")
    for svc in "${services_to_stop[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "Остановка $svc..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done

    # Останавливаем таймеры автообновлений
    local timers_to_stop=("apt-daily.timer" "apt-daily-upgrade.timer")
    for timer in "${timers_to_stop[@]}"; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            log_info "Остановка таймера $timer..."
            systemctl stop "$timer" 2>/dev/null || true
            systemctl disable "$timer" 2>/dev/null || true
        fi
    done

    # Если lock всё ещё занят — завершаем мешающие процессы
    if is_dpkg_locked; then
        log_warning "Пакетный менеджер заблокирован. Завершение мешающих процессов..."

        # Даём текущим операциям 30 секунд на завершение
        local grace_wait=0
        while is_dpkg_locked && [ $grace_wait -lt 30 ]; do
            sleep 2
            grace_wait=$((grace_wait + 2))
        done

        # Если всё ещё заблокирован — сначала мягко (SIGTERM), потом принудительно
        if is_dpkg_locked; then
            log_warning "Завершение процессов, блокирующих пакетный менеджер (SIGTERM)..."
            killall unattended-upgr 2>/dev/null || true
            killall apt-get 2>/dev/null || true
            killall apt 2>/dev/null || true
            sleep 5

            # Если SIGTERM не помог — SIGKILL
            if is_dpkg_locked; then
                log_warning "Принудительное завершение процессов (SIGKILL)..."
                killall -9 unattended-upgr 2>/dev/null || true
                killall -9 apt-get 2>/dev/null || true
                killall -9 apt 2>/dev/null || true
                sleep 2
            fi

            # Удаляем stale lock файлы
            rm -f /var/lib/dpkg/lock-frontend 2>/dev/null || true
            rm -f /var/lib/dpkg/lock 2>/dev/null || true
            rm -f /var/lib/apt/lists/lock 2>/dev/null || true
            rm -f /var/cache/apt/archives/lock 2>/dev/null || true

            # Восстанавливаем dpkg после прерывания
            dpkg --configure -a >/dev/null 2>&1 || true
        fi
    fi

    # Финальная проверка
    if is_dpkg_locked; then
        log_error "Не удалось освободить пакетный менеджер"
        return 1
    fi

    log_success "Пакетный менеджер готов к работе"
    return 0
}

# Установка XanMod ядра с поддержкой BBR2/BBR3
install_xanmod_kernel() {
    # Только для Debian/Ubuntu x86_64
    local arch
    arch=$(uname -m)
    if [ "$arch" != "x86_64" ]; then
        log_error "XanMod доступен только для x86_64 (текущая: $arch)"
        return 1
    fi

    # Проверка совместимости процессора (уровень ISA)
    local xanmod_level=""
    if grep -q "v4" /proc/cpuinfo 2>/dev/null && grep -q "avx512" /proc/cpuinfo 2>/dev/null; then
        xanmod_level="x64v4"
    elif grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
        xanmod_level="x64v3"
    elif grep -q "sse4_2" /proc/cpuinfo 2>/dev/null; then
        xanmod_level="x64v2"
    else
        xanmod_level="x64v1"
    fi
    log_info "Уровень ISA процессора: $xanmod_level"

    # Добавление репозитория XanMod
    log_info "Добавление репозитория XanMod..."

    if ! command -v gpg >/dev/null 2>&1; then
        install_package gnupg 2>/dev/null || true
    fi

    local xanmod_key="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    if ! curl -fsSL https://dl.xanmod.org/archive.key 2>/dev/null | gpg --dearmor -o "$xanmod_key" 2>/dev/null; then
        log_error "Не удалось добавить GPG ключ XanMod"
        return 1
    fi

    echo "deb [signed-by=$xanmod_key] http://deb.xanmod.org releases main" > /etc/apt/sources.list.d/xanmod-release.list

    # Обновление списка пакетов
    apt-get update -qq >/dev/null 2>&1 || true

    # Установка ядра XanMod MAIN (стабильная ветка с BBR2)
    local kernel_pkg="linux-xanmod-${xanmod_level}"
    log_info "Установка пакета: $kernel_pkg..."

    if apt-get install -y -qq "$kernel_pkg" >/dev/null 2>&1; then
        log_success "XanMod ядро ($xanmod_level) установлено"
        log_warning "Для активации BBR2 необходима перезагрузка сервера!"
        return 0
    else
        log_error "Не удалось установить $kernel_pkg"
        # Очистка
        rm -f "$xanmod_key" /etc/apt/sources.list.d/xanmod-release.list
        apt-get update -qq >/dev/null 2>&1 || true
        return 1
    fi
}

# Восстановление служб автоматических обновлений после установки
restore_auto_updates() {
    if [[ "${PKG_MANAGER:-}" != "apt-get" ]]; then
        return 0
    fi

    log_info "Восстановление служб автоматических обновлений..."
    local services=("unattended-upgrades" "apt-daily.service" "apt-daily-upgrade.service")
    local timers=("apt-daily.timer" "apt-daily-upgrade.timer")

    for svc in "${services[@]}"; do
        systemctl enable "$svc" 2>/dev/null || true
    done
    for timer in "${timers[@]}"; do
        systemctl enable "$timer" 2>/dev/null || true
        systemctl start "$timer" 2>/dev/null || true
    done
}

# Установка базовых утилит
install_base_utilities() {
    log_info "Проверка и установка необходимых пакетов..."

    # Обязательные утилиты (без них скрипт не работает)
    local -a required=("curl" "wget")
    for pkg in "${required[@]}"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            if install_package "$pkg"; then
                log_success "$pkg установлен"
            else
                log_error "Не удалось установить $pkg (обязательный)"
                return 1
            fi
        else
            log_success "$pkg уже установлен"
        fi
    done

    # Опциональные утилиты
    # Формат: "команда:пакет:описание"
    local -a optional=(
        "nano:nano:текстовый редактор"
        "btop:btop:монитор ресурсов"
        "jq:jq:парсер JSON"
        "htop:htop:монитор процессов"
        "iotop:iotop:монитор дисковых операций"
        "ncdu:ncdu:анализ дискового пространства"
        "tmux:tmux:мультиплексор терминала"
        "unzip:unzip:распаковка ZIP архивов"
    )

    # Собираем список отсутствующих утилит
    local -a missing=()
    for entry in "${optional[@]}"; do
        local cmd="${entry%%:*}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$entry")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log_success "Все базовые утилиты уже установлены"
        return 0
    fi

    echo
    echo -e "${WHITE}📦 Доступные утилиты для установки:${NC}"
    echo
    local i=1
    for entry in "${missing[@]}"; do
        local cmd="${entry%%:*}"
        local rest="${entry#*:}"
        local pkg="${rest%%:*}"
        local desc="${rest#*:}"
        printf "   ${CYAN}%2d)${NC} %-10s — %s\n" "$i" "$pkg" "$desc"
        i=$((i + 1))
    done
    echo
    echo -e "   ${CYAN} a)${NC} ${WHITE}Установить все${NC}"
    echo -e "   ${CYAN} s)${NC} ${GRAY}Пропустить${NC}"
    echo

    local util_choice
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        util_choice="a"
    else
        read -p "Выберите (номера через пробел, a=все, s=пропустить): " -r util_choice
    fi

    if [ "$util_choice" = "s" ] || [ -z "$util_choice" ]; then
        log_info "Установка дополнительных утилит пропущена"
        return 0
    fi

    local -a to_install=()
    if [ "$util_choice" = "a" ]; then
        to_install=("${missing[@]}")
    else
        for num in $util_choice; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#missing[@]} ]; then
                to_install+=("${missing[$((num - 1))]}")
            fi
        done
    fi

    for entry in "${to_install[@]}"; do
        local cmd="${entry%%:*}"
        local rest="${entry#*:}"
        local pkg="${rest%%:*}"
        if install_package "$pkg"; then
            log_success "$pkg установлен"
        else
            log_warning "Не удалось установить $pkg (некритично)"
        fi
    done
}

# Установка Docker
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker уже установлен"
        # Проверяем что Docker работает
        if docker ps >/dev/null 2>&1; then
            return 0
        else
            log_warning "Docker установлен, но не запущен. Запускаем..."
            if command -v systemctl >/dev/null 2>&1; then
                systemctl start docker >/dev/null 2>&1 || true
                sleep 3
            fi
            # Проверяем, удалось ли запустить
            if docker ps >/dev/null 2>&1; then
                log_success "Docker запущен"
                return 0
            fi
            log_warning "Docker не отвечает после запуска, переустановка..."
        fi
    fi
    
    # Для Ubuntu/Debian проверяем доступность пакетного менеджера
    if [[ "$OS" == "Ubuntu"* ]] || [[ "$OS" == "Debian"* ]]; then
        if ! wait_for_dpkg_lock; then
            return 1
        fi
    fi
    
    log_info "Установка Docker..."
    
    if [[ "$OS" == "Amazon"* ]]; then
        amazon-linux-extras enable docker >/dev/null 2>&1
        yum install -y docker >/dev/null 2>&1
        systemctl start docker
        systemctl enable docker
    else
        # Устанавливаем Docker с выводом ошибок
        local docker_install_log
        docker_install_log=$(create_temp_file)
        local install_success=false

        # Скачиваем скрипт установки Docker в файл для безопасности
        local docker_script
        docker_script=$(create_temp_file)
        if ! curl -fsSL https://get.docker.com -o "$docker_script" 2>/dev/null; then
            log_error "Не удалось скачать скрипт установки Docker"
            rm -f "$docker_install_log" "$docker_script"
            return 1
        fi

        # Пробуем установить Docker
        if sh "$docker_script" >"$docker_install_log" 2>&1; then
            install_success=true
        else
            # Проверяем если это ошибка lock
            if grep -q "lock" "$docker_install_log" 2>/dev/null; then
                log_warning "Обнаружена блокировка пакетного менеджера. Ожидание..."
                if wait_for_dpkg_lock; then
                    log_info "Повторная попытка установки Docker..."
                    rm -f "$docker_install_log"
                    docker_install_log=$(create_temp_file)
                    if sh "$docker_script" >"$docker_install_log" 2>&1; then
                        install_success=true
                    fi
                fi
            fi
        fi
        rm -f "$docker_script"
        
        if [ "$install_success" = false ]; then
            log_error "Ошибка установки Docker. Лог:"
            cat "$docker_install_log" >&2
            rm -f "$docker_install_log"
            return 1
        fi
        
        rm -f "$docker_install_log"
        
        # Запускаем Docker
        if command -v systemctl >/dev/null 2>&1; then
            log_info "Запуск службы Docker..."
            systemctl start docker >/dev/null 2>&1 || true
            systemctl enable docker >/dev/null 2>&1 || true
            sleep 3  # Даем время Docker запуститься
        fi
    fi
    
    # Проверяем что Docker работает
    local retries=0
    while [ $retries -lt 5 ]; do
        if docker ps >/dev/null 2>&1; then
            log_success "Docker установлен и запущен"
            return 0
        fi
        log_info "Ожидание запуска Docker... ($((retries + 1))/5)"
        sleep 2
        retries=$((retries + 1))
    done
    
    log_error "Docker установлен, но не отвечает. Попробуйте запустить вручную: systemctl start docker"
    return 1
}

# Проверка Docker Compose
check_docker_compose() {
    log_info "Проверка Docker Compose..."
    
    # Проверяем несколько раз, так как Docker может еще запускаться
    local retries=0
    while [ $retries -lt 5 ]; do
        if docker compose version >/dev/null 2>&1; then
            local compose_version=$(docker compose version --short 2>/dev/null || echo "unknown")
            log_success "Docker Compose доступен (версия: $compose_version)"
            return 0
        fi
        log_info "Ожидание Docker Compose... ($((retries + 1))/5)"
        sleep 2
        retries=$((retries + 1))
    done
    
    log_error "Docker Compose V2 не найден или не отвечает"
    log_error "Убедитесь что Docker установлен правильно: docker --version"
    return 1
}

# Полная настройка UFW файервола
setup_ufw() {
    print_header "Настройка UFW Firewall" "🛡️"

    if ! prompt_yn "Настроить UFW файервол (default deny + whitelist портов)? (y/n): " "y" "$CFG_SETUP_UFW"; then
        log_info "Настройка UFW пропущена"
        return 0
    fi

    # Установка ufw если не установлен
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "Установка ufw..."
        if ! install_package ufw; then
            log_error "Не удалось установить ufw"
            STATUS_UFW="ошибка"
            return 1
        fi
    fi

    log_info "Настройка правил UFW..."

    # Базовые политики (без сброса существующих правил)
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    log_success "Политика: deny incoming, allow outgoing"

    # SSH — открываем первым чтобы не потерять доступ
    ufw allow 22/tcp >/dev/null 2>&1 && log_success "Порт 22/tcp открыт (SSH)" || log_warning "Не удалось открыть порт 22/tcp"

    # 443/tcp — Xray Reality (входящий трафик клиентов)
    ufw allow 443/tcp >/dev/null 2>&1 && log_success "Порт 443/tcp открыт (Xray Reality)" || log_warning "Не удалось открыть порт 443/tcp"

    # 80/tcp — HTTP-01 challenge / Caddy redirect
    ufw allow 80/tcp >/dev/null 2>&1 && log_success "Порт 80/tcp открыт (HTTP-01 challenge)" || log_warning "Не удалось открыть порт 80/tcp"

    # Caddy HTTPS порт (если отличается от 443)
    local caddy_port="${DETAIL_CADDY_PORT:-$DEFAULT_PORT}"
    if [ -n "$caddy_port" ] && [ "$caddy_port" != "443" ]; then
        ufw allow "$caddy_port/tcp" >/dev/null 2>&1 && log_success "Порт ${caddy_port}/tcp открыт (Caddy HTTPS)" || log_warning "Не удалось открыть порт ${caddy_port}/tcp"
    fi

    # Активация UFW
    ufw --force enable >/dev/null 2>&1
    log_success "UFW активирован"

    # Показать статус
    echo
    log_info "Текущие правила UFW:"
    ufw status numbered 2>/dev/null | head -20

    STATUS_UFW="настроен"
}

# Установка и настройка Fail2ban
install_fail2ban() {
    print_header "Установка Fail2ban" "🛡️"

    if ! prompt_yn "Установить Fail2ban (защита SSH, Caddy, порт-сканы)? (y/n): " "y" "$CFG_INSTALL_FAIL2BAN"; then
        log_info "Установка Fail2ban пропущена"
        return 0
    fi

    # Проверка существующей установки
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo
        echo -e "${YELLOW}⚠️  Fail2ban уже установлен${NC}"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить (оставить текущую конфигурацию)${NC}"
        echo -e "   ${WHITE}2)${NC} ${YELLOW}Перенастроить Fail2ban${NC}"
        echo

        local f2b_choice
        prompt_choice "Выберите опцию [1-2]: " 2 f2b_choice

        if [ "$f2b_choice" = "1" ]; then
            STATUS_FAIL2BAN="уже установлен"
            log_info "Настройка Fail2ban пропущена"
            return 0
        fi
    fi

    # Установка fail2ban
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        log_info "Установка fail2ban..."
        if ! install_package fail2ban; then
            log_error "Не удалось установить fail2ban"
            STATUS_FAIL2BAN="ошибка"
            return 1
        fi
        log_success "fail2ban установлен"
    fi

    # Создание директории для логов remnanode (для будущих фильтров)
    mkdir -p /var/log/remnanode

    # Создание кастомного фильтра для Caddy (JSON логи) — только если Caddy установлен
    log_info "Создание фильтров Fail2ban..."

    if [ -f /opt/caddy/logs/access.log ] || [ -d /opt/caddy ]; then
        cat > /etc/fail2ban/filter.d/caddy-status.conf << 'EOF'
[Definition]
# Детект подозрительных запросов к Caddy из JSON access.log
# Ловим 4xx ошибки (сканеры, брутфорс путей)
failregex = "client_ip":"<HOST>".*"status":(401|403|404|405|444)
ignoreregex =
EOF
    fi

    # Создание фильтра для порт-сканирования (через iptables LOG)
    cat > /etc/fail2ban/filter.d/portscan.conf << 'EOF'
[Definition]
# Детект порт-сканирования через iptables LOG
failregex = PORTSCAN.*SRC=<HOST>
ignoreregex =
EOF

    # Настройка iptables правила для логирования порт-сканов
    log_info "Настройка детекта порт-сканирования..."

    # Создание systemd сервиса для iptables правила (переживает перезагрузку)
    cat > /etc/systemd/system/portscan-detect.service << 'EOF'
[Unit]
Description=Portscan detection iptables rules
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -N PORTSCAN 2>/dev/null || true; iptables -F PORTSCAN 2>/dev/null || true; iptables -A PORTSCAN -p tcp --tcp-flags ALL NONE -j LOG --log-prefix "PORTSCAN: " --log-level 4; iptables -A PORTSCAN -p tcp --tcp-flags ALL ALL -j LOG --log-prefix "PORTSCAN: " --log-level 4; iptables -A PORTSCAN -p tcp --tcp-flags ALL FIN,URG,PSH -j LOG --log-prefix "PORTSCAN: " --log-level 4; iptables -A PORTSCAN -p tcp --tcp-flags SYN,RST SYN,RST -j LOG --log-prefix "PORTSCAN: " --log-level 4; iptables -A PORTSCAN -p tcp --tcp-flags SYN,FIN SYN,FIN -j LOG --log-prefix "PORTSCAN: " --log-level 4; iptables -D INPUT -j PORTSCAN 2>/dev/null || true; iptables -I INPUT -j PORTSCAN'
ExecStop=/bin/sh -c 'iptables -D INPUT -j PORTSCAN 2>/dev/null || true; iptables -F PORTSCAN 2>/dev/null || true; iptables -X PORTSCAN 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable portscan-detect >/dev/null 2>&1
    systemctl start portscan-detect >/dev/null 2>&1 || log_warning "Не удалось запустить portscan-detect (iptables может быть недоступен)"

    # Создание jail.local
    log_info "Создание конфигурации jail.local..."

    cat > /etc/fail2ban/jail.local << 'EOF'
# ╔════════════════════════════════════════════════════════════════╗
# ║  Remnawave Fail2ban Configuration                              ║
# ╚════════════════════════════════════════════════════════════════╝

[DEFAULT]
# Бан через UFW
banaction = ufw
banaction_allports = ufw
# Игнорировать localhost и приватные сети
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
# Время бана по умолчанию — 1 час
bantime = 3600
# Окно поиска — 10 минут
findtime = 600
# Количество попыток по умолчанию
maxretry = 5

# ── SSH защита от брутфорса ──────────────────────────────────────
[sshd]
enabled = true
port = 22
filter = sshd
backend = systemd
maxretry = 5
findtime = 600
bantime = 3600
EOF

    # Добавление Caddy jail только если Caddy установлен и лог-директория существует
    if [ -f /opt/caddy/logs/access.log ] || [ -d /opt/caddy ]; then
        # Создаём лог-файл если директория есть но файл ещё не создан
        if [ -d /opt/caddy ] && [ ! -f /opt/caddy/logs/access.log ]; then
            mkdir -p /opt/caddy/logs
            touch /opt/caddy/logs/access.log
        fi
        cat >> /etc/fail2ban/jail.local << 'EOF'

# ── Caddy — подозрительные запросы (сканеры, 4xx) ────────────────
[caddy-status]
enabled = true
port = http,https
filter = caddy-status
logpath = /opt/caddy/logs/access.log
maxretry = 15
findtime = 600
bantime = 3600
EOF
        log_info "Caddy jail включён"
    else
        log_info "Caddy не обнаружен — caddy-status jail пропущен"
    fi

    # Добавление portscan jail только если лог-файл существует
    local portscan_log=""
    if [ -f /var/log/kern.log ]; then
        portscan_log="/var/log/kern.log"
    elif [ -f /var/log/syslog ]; then
        portscan_log="/var/log/syslog"
    fi

    if [ -n "$portscan_log" ]; then
        cat >> /etc/fail2ban/jail.local << EOF

# ── Детект порт-сканирования ─────────────────────────────────────
[portscan]
enabled = true
filter = portscan
logpath = $portscan_log
maxretry = 3
findtime = 300
bantime = 86400
EOF
        log_info "Portscan jail включён (лог: $portscan_log)"
    else
        log_info "Лог ядра не найден — portscan jail пропущен"
    fi

    log_success "jail.local создан"

    # Перезапуск fail2ban
    log_info "Запуск Fail2ban..."
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1

    # Проверка статуса
    sleep 2
    if systemctl is-active --quiet fail2ban; then
        log_success "Fail2ban запущен"

        echo
        log_info "Активные jail'ы:"
        fail2ban-client status 2>/dev/null | grep "Jail list" || true
        echo

        STATUS_FAIL2BAN="установлен"
    else
        log_warning "Fail2ban не запустился. Проверьте: journalctl -u fail2ban"
        STATUS_FAIL2BAN="ошибка"
    fi

    echo
    echo -e "${WHITE}📋 Конфигурация Fail2ban:${NC}"
    echo -e "${GRAY}   SSH: maxretry=5, bantime=1ч${NC}"
    if [ -f /opt/caddy/logs/access.log ] || [ -d /opt/caddy ]; then
        echo -e "${GRAY}   Caddy: maxretry=15, bantime=1ч${NC}"
    fi
    if [ -n "$portscan_log" ]; then
        echo -e "${GRAY}   Порт-сканы: maxretry=3, bantime=24ч${NC}"
    fi
    echo -e "${GRAY}   Конфиг: /etc/fail2ban/jail.local${NC}"
    echo
}

# Настройка logrotate для логов RemnawaveNode
setup_logrotate() {
    log_info "Настройка logrotate для RemnawaveNode..."

    # Установка logrotate если не установлен
    if ! command -v logrotate >/dev/null 2>&1; then
        install_package logrotate 2>/dev/null || true
    fi

    if command -v logrotate >/dev/null 2>&1; then
        cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    size 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
        log_success "logrotate настроен: /etc/logrotate.d/remnanode"
    else
        log_warning "logrotate не установлен, пропуск настройки ротации логов"
    fi
}

# Проверка существующей установки RemnawaveNode
check_existing_remnanode() {
    if [ -d "$REMNANODE_DIR" ] && [ -f "$REMNANODE_DIR/docker-compose.yml" ]; then
        return 0  # Установлен
    fi
    return 1  # Не установлен
}

# Установка RemnawaveNode
install_remnanode() {
    # Проверка существующей установки
    if check_existing_remnanode; then
        echo
        echo -e "${YELLOW}⚠️  RemnawaveNode уже установлен${NC}"
        echo -e "${GRAY}   Путь: $REMNANODE_DIR${NC}"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить установку${NC}"
        echo -e "   ${WHITE}2)${NC} ${YELLOW}Перезаписать (удалить существующую установку)${NC}"
        echo

        local remnanode_choice
        prompt_choice "Выберите опцию [1-2]: " 2 remnanode_choice

        if [ "$remnanode_choice" = "2" ]; then
            backup_existing_config "$REMNANODE_DIR"
            log_warning "Удаление существующей установки RemnawaveNode..."
            if [ -f "$REMNANODE_DIR/docker-compose.yml" ]; then
                docker compose --project-directory "$REMNANODE_DIR" down 2>/dev/null || true
            fi
            rm -rf "$REMNANODE_DIR"
            log_success "Существующая установка удалена"
            echo
        else
            STATUS_REMNANODE="уже установлен"
            log_info "Установка RemnawaveNode пропущена"
            return 0
        fi
    fi

    log_info "Установка Remnawave Node..."

    # Создание директорий
    mkdir -p "$REMNANODE_DIR"
    mkdir -p "$REMNANODE_DATA_DIR"

    # Запрос SECRET_KEY
    if [ "${NON_INTERACTIVE:-false}" = true ] && [ -n "$CFG_SECRET_KEY" ]; then
        SECRET_KEY_VALUE="$CFG_SECRET_KEY"
    else
        echo
        echo -e "${CYAN}📝 Введите SECRET_KEY из Remnawave-Panel${NC}"
        echo -e "${GRAY}   Где найти: Remnawave Panel → Nodes → Add Node → скопировать ключ${NC}"
        echo -e "${GRAY}   Вставьте содержимое и нажмите ENTER на новой строке для завершения${NC}"
        echo -e "${GRAY}   (или введите 'cancel' для отмены):${NC}"
        SECRET_KEY_VALUE=""
        while IFS= read -r line; do
            if [[ -z $line ]]; then
                break
            fi
            if [[ "$line" == "cancel" ]]; then
                log_info "Установка RemnawaveNode отменена"
                STATUS_REMNANODE="пропущен"
                return 0
            fi
            SECRET_KEY_VALUE="$SECRET_KEY_VALUE$line"
        done
    fi

    if [ -z "$SECRET_KEY_VALUE" ]; then
        log_error "SECRET_KEY не может быть пустым!"
        STATUS_REMNANODE="ошибка"
        return 1
    fi

    # Запрос порта
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        NODE_PORT="$CFG_NODE_PORT"
    else
        echo
        read -p "Введите NODE_PORT (по умолчанию 3000): " -r NODE_PORT
        NODE_PORT=${NODE_PORT:-3000}
    fi

    # Валидация порта (с повторным вводом)
    while ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_PORT" -lt 1 ] || [ "$NODE_PORT" -gt 65535 ]; do
        log_warning "Неверный номер порта: $NODE_PORT (допустимо 1-65535)"
        if [ "${NON_INTERACTIVE:-false}" = true ]; then
            STATUS_REMNANODE="ошибка"
            return 1
        fi
        read -p "Введите NODE_PORT (по умолчанию 3000): " -r NODE_PORT
        NODE_PORT=${NODE_PORT:-3000}
    done
    DETAIL_REMNANODE_PORT="$NODE_PORT"

    # Запрос установки Xray-core
    INSTALL_XRAY=false
    if prompt_yn "Установить последнюю версию Xray-core? (y/n): " "y" "$CFG_INSTALL_XRAY"; then
        INSTALL_XRAY=true
        if ! install_xray_core; then
            log_error "Не удалось установить Xray-core"
            echo
            if prompt_yn "Продолжить установку RemnawaveNode без Xray-core? (y/n): " "y"; then
                INSTALL_XRAY=false
                log_warning "Продолжаем установку без Xray-core"
            else
                log_error "Установка прервана"
                STATUS_REMNANODE="ошибка"
                return 1
            fi
        fi
    fi

    # Создание .env файла
    cat > "$REMNANODE_DIR/.env" << EOF
### NODE ###
NODE_PORT=$NODE_PORT

### XRAY ###
SECRET_KEY=$SECRET_KEY_VALUE
EOF
    chmod 600 "$REMNANODE_DIR/.env"

    log_success ".env файл создан"
    
    # Создание docker-compose.yml
    cat > "$REMNANODE_DIR/docker-compose.yml" << EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:latest
    env_file:
      - .env
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
EOF
    
    # Добавление volumes
    if [ "$INSTALL_XRAY" = "true" ]; then
        cat >> "$REMNANODE_DIR/docker-compose.yml" << EOF
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - $REMNANODE_DATA_DIR/xray:/usr/local/bin/xray
EOF

        if [ -f "$REMNANODE_DATA_DIR/geoip.dat" ]; then
            echo "      - $REMNANODE_DATA_DIR/geoip.dat:/usr/local/share/xray/geoip.dat" >> "$REMNANODE_DIR/docker-compose.yml"
        fi
        if [ -f "$REMNANODE_DATA_DIR/geosite.dat" ]; then
            echo "      - $REMNANODE_DATA_DIR/geosite.dat:/usr/local/share/xray/geosite.dat" >> "$REMNANODE_DIR/docker-compose.yml"
        fi

        cat >> "$REMNANODE_DIR/docker-compose.yml" << EOF
      - /dev/shm:/dev/shm  # Для selfsteal socket access
EOF
    else
        cat >> "$REMNANODE_DIR/docker-compose.yml" << EOF
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      # - /dev/shm:/dev/shm  # Раскомментируйте для selfsteal socket access
EOF
    fi

    # Создание директории для логов и настройка logrotate
    mkdir -p /var/log/remnanode
    setup_logrotate
    
    log_success "docker-compose.yml создан"
    
    # Запуск контейнера
    log_info "Запуск RemnawaveNode..."
    docker compose --project-directory "$REMNANODE_DIR" up -d

    # Проверка что контейнер поднялся (с ожиданием до 30 сек)
    log_info "Ожидание запуска контейнера..."
    if check_container_health "$REMNANODE_DIR" "remnanode" 30; then
        log_success "RemnawaveNode запущен"
        STATUS_REMNANODE="установлен"
    else
        log_warning "RemnawaveNode может не запуститься корректно. Проверьте логи:"
        log_warning "   cd $REMNANODE_DIR && docker compose logs"
        STATUS_REMNANODE="ошибка"
    fi
}

# Установка Xray-core
install_xray_core() {
    log_info "Установка Xray-core..."

    # Определение архитектуры
    local ARCH
    ARCH=$(detect_arch xray) || return 1
    log_info "Используется архитектура для Xray: $ARCH"
    
    # Установка unzip если нужно
    if ! command -v unzip >/dev/null 2>&1; then
        log_info "Установка unzip..."
        if ! install_package unzip; then
            log_error "Не удалось установить unzip"
            return 1
        fi
        log_success "unzip установлен"
    else
        log_success "unzip уже установлен"
    fi
    
    # Установка wget если нужно
    if ! command -v wget >/dev/null 2>&1; then
        log_info "Установка wget..."
        if ! install_package wget; then
            log_error "Не удалось установить wget"
            return 1
        fi
        log_success "wget установлен"
    else
        log_success "wget уже установлен"
    fi
    
    # Получение последней версии
    log_info "Получение информации о последней версии Xray-core..."
    local latest_release=""
    local api_response=""
    
    api_response=$(curl -s --connect-timeout 10 --max-time 30 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null) || true

    if [ -z "$api_response" ]; then
        log_error "Не удалось подключиться к GitHub API"
        log_error "Проверьте интернет-соединение и попробуйте снова"
        return 1
    fi
    
    latest_release=$(echo "$api_response" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    
    if [ -z "$latest_release" ]; then
        log_error "Не удалось получить версию Xray-core из ответа API"
        log_error "Ответ API: ${api_response:0:200}..."
        return 1
    fi
    
    log_success "Найдена версия Xray-core: $latest_release"
    
    # Скачивание
    local xray_filename="Xray-linux-$ARCH.zip"
    local xray_download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_release}/${xray_filename}"
    
    log_info "Скачивание Xray-core версии ${latest_release}..."
    log_info "URL: $xray_download_url"
    
    # Скачиваем файл в директорию данных (со спиннером)
    if ! download_with_progress "${xray_download_url}" "${REMNANODE_DATA_DIR}/${xray_filename}" "Скачивание Xray-core ${latest_release}..."; then
        log_error "Не удалось скачать Xray-core"
        log_error "Проверьте интернет-соединение и доступность GitHub"
        return 1
    fi
    
    if [ ! -f "${REMNANODE_DATA_DIR}/${xray_filename}" ]; then
        log_error "Файл ${xray_filename} не найден после скачивания"
        return 1
    fi

    local file_size
    file_size=$(stat -c%s "${REMNANODE_DATA_DIR}/${xray_filename}" 2>/dev/null || echo "unknown")
    log_success "Файл скачан (размер: ${file_size} байт)"

    # Распаковка
    log_info "Распаковка Xray-core..."
    if ! unzip -o "${REMNANODE_DATA_DIR}/${xray_filename}" -d "$REMNANODE_DATA_DIR" >/dev/null 2>&1; then
        log_error "Не удалось распаковать архив"
        rm -f "${REMNANODE_DATA_DIR}/${xray_filename}"
        return 1
    fi

    # Удаляем архив
    rm -f "${REMNANODE_DATA_DIR}/${xray_filename}"
    
    # Проверяем что xray файл существует
    if [ ! -f "$REMNANODE_DATA_DIR/xray" ]; then
        log_error "Файл xray не найден после распаковки"
        return 1
    fi
    
    # Устанавливаем права на выполнение
    chmod +x "$REMNANODE_DATA_DIR/xray"
    
    # Проверяем версию xray
    if [ -x "$REMNANODE_DATA_DIR/xray" ]; then
        local xray_version=$("$REMNANODE_DATA_DIR/xray" version 2>/dev/null | head -1 || echo "unknown")
        log_success "Xray-core установлен: $xray_version"
    else
        log_success "Xray-core установлен"
    fi
    
    # Проверяем наличие geo файлов
    if [ -f "$REMNANODE_DATA_DIR/geoip.dat" ]; then
        log_success "geoip.dat найден"
    fi
    if [ -f "$REMNANODE_DATA_DIR/geosite.dat" ]; then
        log_success "geosite.dat найден"
    fi
}

# Валидация DNS
validate_domain_dns() {
    local domain="$1"
    local server_ip="$2"
    
    log_info "Проверка DNS конфигурации..."
    
    # Установка dig если нужно
    if ! command -v dig >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            install_package dnsutils
        elif command -v yum >/dev/null 2>&1; then
            install_package bind-utils
        elif command -v dnf >/dev/null 2>&1; then
            install_package bind-utils
        fi
    fi
    
    # Проверка DNS (фильтруем только IPv4 адреса, исключая CNAME)
    local dns_ip
    dns_ip=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)

    if [ -z "$dns_ip" ]; then
        log_warning "Не удалось получить IP для домена $domain"
        return 1
    fi
    
    if [ "$dns_ip" != "$server_ip" ]; then
        log_warning "DNS не совпадает: домен указывает на $dns_ip, сервер имеет IP $server_ip"
        return 1
    fi
    
    log_success "DNS настроен правильно: $domain -> $dns_ip"
    return 0
}

# Загрузка шаблона
download_template() {
    local template_folder="$1"
    local template_name="$2"
    
    log_info "Загрузка шаблона: $template_name..."
    
    # Создание директории
    mkdir -p "$CADDY_HTML_DIR"
    find "${CADDY_HTML_DIR:?}" -mindepth 1 -delete 2>/dev/null || true

    # Попытка загрузки через git (в подоболочке чтобы не менять рабочую директорию)
    if command -v git >/dev/null 2>&1; then
        local temp_dir
        temp_dir=$(mktemp -d) || { log_error "Не удалось создать временную директорию"; return 1; }

        if git clone --filter=blob:none --sparse "https://github.com/Case211/remnanode-install.git" "$temp_dir" 2>/dev/null; then
            (
                cd "$temp_dir"
                git sparse-checkout set "sni-templates/$template_folder" 2>/dev/null
            )
            local source_path="$temp_dir/sni-templates/$template_folder"
            if [ -d "$source_path" ] && cp -r "$source_path"/* "$CADDY_HTML_DIR/" 2>/dev/null; then
                rm -rf "$temp_dir"
                log_success "Шаблон загружен"
                return 0
            fi
        fi
        rm -rf "$temp_dir"
    fi

    # Fallback: загрузка основных файлов через curl
    log_info "Использование fallback метода загрузки..."
    local base_url="https://raw.githubusercontent.com/Case211/remnanode-install/main/sni-templates/$template_folder"
    local common_files=("index.html" "favicon.ico")

    local files_downloaded=0
    for file in "${common_files[@]}"; do
        local url="$base_url/$file"
        if curl -fsSL "$url" -o "$CADDY_HTML_DIR/$file" 2>/dev/null; then
            files_downloaded=$((files_downloaded + 1))
        fi
    done

    if [ $files_downloaded -gt 0 ]; then
        log_success "Базовые файлы шаблона загружены"
        return 0
    fi

    # Создание простого fallback HTML
    create_fallback_html
    return 1
}

# Создание fallback HTML
create_fallback_html() {
    cat > "$CADDY_HTML_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
</head>
<body>
    <h1>Welcome</h1>
</body>
</html>
EOF
    log_warning "Создан простой fallback HTML"
}

# Проверка существующих сертификатов
check_existing_certificate() {
    local check_domain="$1"
    local cert_found=false
    local cert_location=""
    
    # Нормализация домена для проверки (убираем wildcard префикс если есть)
    local domain_to_check=$(echo "$check_domain" | sed 's/^\*\.//')
    local wildcard_domain="*.$domain_to_check"
    
    # Проверка сертификатов Caddy (в volume)
    if docker volume inspect caddy_data >/dev/null 2>&1; then
        # Проверяем через временный контейнер (домен передаётся через аргументы, не через sh -c)
        if docker run --rm \
            -v caddy_data:/data:ro \
            alpine:latest \
            sh -c 'find /data/caddy/certificates -type d -name "*$1*" 2>/dev/null | head -1' _ "$domain_to_check" 2>/dev/null | grep -q .; then
            cert_found=true
            cert_location="Caddy volume (caddy_data)"
        fi
    fi

    # Проверка существующих контейнеров Caddy
    local existing_caddy
    existing_caddy=$(docker ps -a --format '{{.Names}}' | grep -E '^caddy' | head -1) || true
    if [ -n "$existing_caddy" ]; then
        # Проверяем доступность контейнера
        if docker exec "$existing_caddy" test -d /data/caddy/certificates >/dev/null 2>&1; then
            # Ищем сертификаты для домена
            if docker exec "$existing_caddy" find /data/caddy/certificates -type d -name "*${domain_to_check}*" 2>/dev/null | grep -q .; then
                cert_found=true
                if [ -z "$cert_location" ]; then
                    cert_location="Существующий контейнер Caddy ($existing_caddy)"
                else
                    cert_location="$cert_location, контейнер ($existing_caddy)"
                fi
            fi
        fi
    fi
    
    # Проверка acme.sh сертификатов (для текущего пользователя)
    local acme_home="$HOME/.acme.sh"
    if [ -d "$acme_home" ]; then
        # Проверяем обычный домен
        if [ -d "$acme_home/$domain_to_check" ]; then
            cert_found=true
            if [ -z "$cert_location" ]; then
                cert_location="acme.sh ($acme_home/$domain_to_check)"
            else
                cert_location="$cert_location, acme.sh"
            fi
        fi
        # Проверяем wildcard домен
        if [ -d "$acme_home/$wildcard_domain" ]; then
            cert_found=true
            if [ -z "$cert_location" ]; then
                cert_location="acme.sh ($acme_home/$wildcard_domain)"
            else
                cert_location="$cert_location, acme.sh (wildcard)"
            fi
        fi
    fi
    
    # Проверка для root пользователя
    if [ "$(id -u)" = "0" ] && [ -d "/root/.acme.sh" ]; then
        if [ -d "/root/.acme.sh/$domain_to_check" ]; then
            cert_found=true
            if [ -z "$cert_location" ]; then
                cert_location="acme.sh (/root/.acme.sh/$domain_to_check)"
            else
                cert_location="$cert_location, acme.sh (root)"
            fi
        fi
        if [ -d "/root/.acme.sh/$wildcard_domain" ]; then
            cert_found=true
            if [ -z "$cert_location" ]; then
                cert_location="acme.sh (/root/.acme.sh/$wildcard_domain)"
            else
                cert_location="$cert_location, acme.sh (root wildcard)"
            fi
        fi
    fi
    
    if [ "$cert_found" = true ]; then
        echo "$cert_location"
        return 0
    else
        return 1
    fi
}

# Проверка существующей установки Caddy
check_existing_caddy() {
    if [ -d "$CADDY_DIR" ] && [ -f "$CADDY_DIR/docker-compose.yml" ]; then
        return 0  # Установлен
    fi
    return 1  # Не установлен
}

# Установка Caddy Selfsteal
install_caddy_selfsteal() {
    # Проверка существующей установки
    if check_existing_caddy; then
        echo
        echo -e "${YELLOW}⚠️  Caddy Selfsteal уже установлен${NC}"
        echo -e "${GRAY}   Путь: $CADDY_DIR${NC}"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить установку${NC}"
        echo -e "   ${WHITE}2)${NC} ${YELLOW}Перезаписать (удалить существующую установку)${NC}"
        echo

        local caddy_choice
        prompt_choice "Выберите опцию [1-2]: " 2 caddy_choice

        if [ "$caddy_choice" = "2" ]; then
            backup_existing_config "$CADDY_DIR"
            log_warning "Удаление существующей установки Caddy..."
            if [ -f "$CADDY_DIR/docker-compose.yml" ]; then
                docker compose --project-directory "$CADDY_DIR" down 2>/dev/null || true
            fi
            rm -rf "$CADDY_DIR"
            log_success "Существующая установка удалена"
            echo
        else
            STATUS_CADDY="уже установлен"
            log_info "Установка Caddy Selfsteal пропущена"
            return 0
        fi
    fi
    
    log_info "Установка Caddy Selfsteal..."
    
    # Создание директорий
    mkdir -p "$CADDY_DIR"
    mkdir -p "$CADDY_HTML_DIR"
    mkdir -p "$CADDY_DIR/logs"
    
    # Запрос домена
    local original_domain=""
    if [ "${NON_INTERACTIVE:-false}" = true ] && [ -n "$CFG_DOMAIN" ]; then
        original_domain="$CFG_DOMAIN"
    else
        echo
        echo -e "${CYAN}🌐 Конфигурация домена${NC}"
        echo -e "${GRAY}   Домен должен совпадать с realitySettings.serverNames в Xray Reality${NC}"
        echo
        while [ -z "$original_domain" ]; do
            read -p "Введите домен (например, reality.example.com): " original_domain
            if [ -z "$original_domain" ]; then
                log_error "Домен не может быть пустым!"
            elif [[ "$original_domain" =~ [[:space:]] ]] || ! [[ "$original_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || ! [[ "$original_domain" == *.* ]]; then
                log_error "Неверный формат домена: $original_domain"
                original_domain=""
            fi
        done
    fi
    DETAIL_CADDY_DOMAIN="$original_domain"

    # Выбор типа сертификата
    echo
    echo -e "${WHITE}🔐 Тип SSL сертификата:${NC}"
    echo -e "   ${WHITE}1)${NC} ${GRAY}Обычный сертификат (HTTP-01 challenge)${NC}"
    echo -e "   ${WHITE}2)${NC} ${GRAY}Wildcard сертификат (DNS-01 challenge через Cloudflare)${NC}"
    echo

    local cert_choice
    prompt_choice "Выберите опцию [1-2]: " 2 cert_choice "$CFG_CERT_TYPE"
    
    local domain="$original_domain"
    local root_domain=""
    
    if [ "$cert_choice" = "2" ]; then
        USE_WILDCARD=true
        CADDY_IMAGE="caddybuilds/caddy-cloudflare:latest"
        
        echo
        echo -e "${CYAN}☁️  Cloudflare API Token${NC}"
        echo -e "${GRAY}   Для получения токена:${NC}"
        echo -e "${GRAY}   1. Перейдите в Cloudflare Dashboard → My Profile → API Tokens${NC}"
        echo -e "${GRAY}   2. Создайте токен с правами: Zone / Zone / Read и Zone / DNS / Edit${NC}"
        echo -e "${GRAY}   3. Выберите зону для которой нужен сертификат${NC}"
        echo
        
        if [ "${NON_INTERACTIVE:-false}" = true ] && [ -n "$CFG_CLOUDFLARE_TOKEN" ]; then
            CLOUDFLARE_API_TOKEN="$CFG_CLOUDFLARE_TOKEN"
        else
            while [ -z "$CLOUDFLARE_API_TOKEN" ]; do
                read -s -p "Введите Cloudflare API Token: " -r CLOUDFLARE_API_TOKEN
                echo
                # Убираем \r, пробелы и невидимые символы (часто попадают при copy-paste)
                CLOUDFLARE_API_TOKEN=$(echo "$CLOUDFLARE_API_TOKEN" | tr -d '\r\n ' | sed 's/[^a-zA-Z0-9_-]//g')
                if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
                    log_error "API Token не может быть пустым!"
                fi
            done
        fi

        # Валидация токена через Cloudflare API
        if ! validate_cloudflare_token "$CLOUDFLARE_API_TOKEN"; then
            if prompt_yn "Токен невалиден. Продолжить всё равно? (y/n): " "n"; then
                log_warning "Продолжаем с невалидным токеном"
            else
                log_error "Установка Caddy отменена"
                STATUS_CADDY="ошибка"
                return 1
            fi
        fi
        
        # Преобразование домена в wildcard формат
        root_domain=$(echo "$original_domain" | sed 's/^[^.]*\.//')
        if [ "$root_domain" != "$original_domain" ] && [ -n "$root_domain" ]; then
            domain="*.$root_domain"
            log_info "Используется wildcard домен: $domain (для сертификата)"
            log_info "Оригинальный домен: $original_domain (для Xray serverNames)"
        else
            log_warning "Не удалось определить корневой домен, используется: *.$original_domain"
            domain="*.$original_domain"
            root_domain="$original_domain"
        fi
    else
        # Для обычного сертификата определяем root_domain для вывода
        root_domain=$(echo "$original_domain" | sed 's/^[^.]*\.//')
        if [ "$root_domain" = "$original_domain" ]; then
            root_domain=""
        fi
    fi
    
    # Проверка существующих сертификатов
    echo
    log_info "Проверка существующих SSL сертификатов..."
    local cert_check_domain="$original_domain"
    if [ "$USE_WILDCARD" = true ] && [ -n "$root_domain" ]; then
        cert_check_domain="$root_domain"
    fi
    
    local existing_cert=""
    if existing_cert=$(check_existing_certificate "$cert_check_domain"); then
        EXISTING_CERT_LOCATION="$existing_cert"
        echo
        echo -e "${YELLOW}⚠️  Найден существующий SSL сертификат!${NC}"
        echo -e "${GRAY}   Расположение: $existing_cert${NC}"
        echo -e "${GRAY}   Домен: $cert_check_domain${NC}"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Использовать существующий сертификат${NC}"
        echo -e "   ${WHITE}2)${NC} ${GRAY}Получить новый сертификат${NC}"
        echo

        local cert_action
        prompt_choice "Выберите опцию [1-2]: " 2 cert_action
        
        if [ "$cert_action" = "1" ]; then
            log_info "Будет использован существующий сертификат"
            USE_EXISTING_CERT=true
        else
            log_info "Будет получен новый сертификат"
            USE_EXISTING_CERT=false
            EXISTING_CERT_LOCATION=""
        fi
    else
        log_info "Существующие сертификаты не найдены, будет получен новый"
        USE_EXISTING_CERT=false
        EXISTING_CERT_LOCATION=""
    fi
    
    # Проверка DNS (опционально)
    echo
    echo -e "${WHITE}🔍 Проверка DNS:${NC}"
    echo -e "   ${WHITE}1)${NC} ${GRAY}Проверить DNS (рекомендуется)${NC}"
    echo -e "   ${WHITE}2)${NC} ${GRAY}Пропустить проверку${NC}"
    echo

    local dns_choice
    prompt_choice "Выберите опцию [1-2]: " 2 dns_choice

    if [ "$dns_choice" = "1" ]; then
        # Проверяем оригинальный домен, не wildcard
        if ! validate_domain_dns "$original_domain" "$NODE_IP"; then
            echo
            if ! prompt_yn "Продолжить установку? (y/n): " "y"; then
                STATUS_CADDY="ошибка"
                return 1
            fi
        fi
    fi
    
    # Запрос порта
    local input_port
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        input_port="$CFG_CADDY_PORT"
    else
        echo
        read -p "Введите HTTPS порт (по умолчанию $DEFAULT_PORT): " input_port
    fi
    local port="${input_port:-$DEFAULT_PORT}"
    
    # Валидация порта (с повторным вводом)
    while ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; do
        log_warning "Неверный номер порта: $port (допустимо 1-65535)"
        if [ "${NON_INTERACTIVE:-false}" = true ]; then
            STATUS_CADDY="ошибка"
            return 1
        fi
        read -p "Введите HTTPS порт (по умолчанию $DEFAULT_PORT): " input_port
        port="${input_port:-$DEFAULT_PORT}"
    done
    DETAIL_CADDY_PORT="$port"

    # Создание .env файла
    cat > "$CADDY_DIR/.env" << EOF
# Caddy for Reality Selfsteal Configuration
SELF_STEAL_DOMAIN=$domain
SELF_STEAL_PORT=$port

# Generated on $(date)
# Server IP: $NODE_IP
EOF

    # Добавление Cloudflare токена если используется wildcard
    if [ "$USE_WILDCARD" = true ]; then
        printf 'CLOUDFLARE_API_TOKEN=%s\n' "$CLOUDFLARE_API_TOKEN" >> "$CADDY_DIR/.env"
        echo "# Wildcard certificate enabled for: $domain" >> "$CADDY_DIR/.env"
        echo "# Original domain for Xray serverNames: $original_domain" >> "$CADDY_DIR/.env"
    fi
    
    # Добавление информации об использовании существующего сертификата
    if [ "$USE_EXISTING_CERT" = true ] && [ -n "$EXISTING_CERT_LOCATION" ]; then
        echo "# Using existing certificate from: $EXISTING_CERT_LOCATION" >> "$CADDY_DIR/.env"
    fi
    
    chmod 600 "$CADDY_DIR/.env"
    log_success ".env файл создан"

    # Создание docker-compose.yml
    cat > "$CADDY_DIR/docker-compose.yml" << EOF
services:
  caddy:
    image: ${CADDY_IMAGE}
    container_name: caddy-selfsteal
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ${CADDY_HTML_DIR}:/var/www/html
      - ./logs:/var/log/caddy
EOF

    cat >> "$CADDY_DIR/docker-compose.yml" << EOF
      - caddy_data:/data
EOF

    cat >> "$CADDY_DIR/docker-compose.yml" << EOF
      - caddy_config:/config
    env_file:
      - .env
EOF

    cat >> "$CADDY_DIR/docker-compose.yml" << EOF
    network_mode: "host"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config
EOF
    
    log_success "docker-compose.yml создан"
    
    # Создание Caddyfile
    if [ "$USE_WILDCARD" = true ]; then
        # Caddyfile с DNS-01 challenge для wildcard
        cat > "$CADDY_DIR/Caddyfile" << EOF
{
	https_port {\$SELF_STEAL_PORT}
	default_bind 127.0.0.1
	auto_https disable_redirects
	log {
		output file /var/log/caddy/default.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level INFO
		format json
	}
}

:80 {
	bind 0.0.0.0
	redir https://{host}{uri} permanent
	log {
		output file /var/log/caddy/redirect.log {
			roll_size 5MB
			roll_keep 3
			roll_keep_for 168h
		}
	}
}

https://{\$SELF_STEAL_DOMAIN} {
	tls {
		dns cloudflare {env.CLOUDFLARE_API_TOKEN}
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level INFO
		format json
	}
}
EOF
    else
        # Обычный Caddyfile с HTTP-01 challenge
        cat > "$CADDY_DIR/Caddyfile" << EOF
{
	https_port {\$SELF_STEAL_PORT}
	default_bind 127.0.0.1
	auto_https disable_redirects
	log {
		output file /var/log/caddy/default.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level INFO
		format json
	}
}

http://{\$SELF_STEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://{host}{uri} permanent
	log {
		output file /var/log/caddy/redirect.log {
			roll_size 5MB
			roll_keep 3
			roll_keep_for 168h
		}
	}
}

https://{\$SELF_STEAL_DOMAIN} {
	tls {
		issuer acme {
			disable_tlsalpn_challenge
		}
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level INFO
		format json
	}
}

:80 {
	bind 0.0.0.0
	respond 204
	log off
}
EOF
    fi
    
    log_success "Caddyfile создан"
    
    # Выбор и загрузка шаблона
    echo
    select_and_download_template || true
    
    # Проверка занятости портов перед запуском
    log_info "Проверка доступности портов..."
    local port_conflict=false
    if ss -tlnp 2>/dev/null | grep -q ":80 "; then
        local port80_proc
        port80_proc=$(ss -tlnp 2>/dev/null | grep ":80 " | head -1)
        log_warning "Порт 80 уже занят: $port80_proc"
        port_conflict=true
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        local port_proc
        port_proc=$(ss -tlnp 2>/dev/null | grep ":${port} " | head -1)
        log_warning "Порт $port уже занят: $port_proc"
        port_conflict=true
    fi
    if [ "$port_conflict" = true ]; then
        echo
        if ! prompt_yn "Порты заняты. Продолжить запуск Caddy? (y/n): " "n"; then
            log_warning "Запуск Caddy отложен. Запустите вручную: cd $CADDY_DIR && docker compose up -d"
            STATUS_CADDY="отложен"
            return 0
        fi
    fi

    # Загрузка образа и запуск Caddy
    log_info "Загрузка образа Caddy..."
    docker compose --project-directory "$CADDY_DIR" pull --quiet 2>/dev/null || true
    log_info "Запуск Caddy..."
    docker compose --project-directory "$CADDY_DIR" up -d

    # Проверка что контейнер поднялся (с ожиданием до 30 сек)
    log_info "Ожидание запуска контейнера..."
    if check_container_health "$CADDY_DIR" "caddy" 30; then
        log_success "Caddy запущен"
        STATUS_CADDY="установлен"
    else
        log_warning "Caddy может не запуститься корректно. Проверьте логи:"
        log_warning "   cd $CADDY_DIR && docker compose logs"
        STATUS_CADDY="ошибка"
    fi

    # Вывод итоговой информации
    echo
    print_separator
    echo -e "${WHITE}${BOLD}🎉 Установка завершена успешно!${NC}"
    print_separator
    echo
    echo -e "${WHITE}📋 Конфигурация Xray Reality:${NC}"
    if [ "$USE_WILDCARD" = true ]; then
        if [ -n "$root_domain" ]; then
            echo -e "${GRAY}   serverNames: [\"$original_domain\", \"$root_domain\"]${NC}"
        else
            echo -e "${GRAY}   serverNames: [\"$original_domain\"]${NC}"
        fi
        echo -e "${CYAN}   (Wildcard сертификат - работает для всех поддоменов *.${root_domain:-$original_domain})${NC}"
    else
        echo -e "${GRAY}   serverNames: [\"$original_domain\"]${NC}"
    fi
    echo -e "${GRAY}   dest: \"127.0.0.1:$port\"${NC}"
    echo -e "${GRAY}   xver: 0${NC}"
    echo
    echo -e "${WHITE}📁 Пути установки:${NC}"
    echo -e "${GRAY}   RemnawaveNode: $REMNANODE_DIR${NC}"
    echo -e "${GRAY}   Caddy: $CADDY_DIR${NC}"
    echo -e "${GRAY}   HTML: $CADDY_HTML_DIR${NC}"
    echo
    if [ "$USE_WILDCARD" = true ]; then
        echo -e "${WHITE}🔐 Wildcard сертификат:${NC}"
        echo -e "${GRAY}   Сертификат выдан для: $domain${NC}"
        echo -e "${GRAY}   Работает для всех поддоменов *.${root_domain:-$original_domain}${NC}"
        echo -e "${CYAN}   Cloudflare API Token сохранен в: $CADDY_DIR/.env${NC}"
        echo
    fi
    
    if [ "$USE_EXISTING_CERT" = true ] && [ -n "$EXISTING_CERT_LOCATION" ]; then
        echo -e "${WHITE}🔐 Используется существующий сертификат:${NC}"
        echo -e "${GRAY}   Расположение: $EXISTING_CERT_LOCATION${NC}"
        echo -e "${CYAN}   Новый сертификат не будет запрошен${NC}"
        echo
    fi
}

# Проверка существующей установки Netbird
check_existing_netbird() {
    if command -v netbird >/dev/null 2>&1; then
        return 0  # Установлен
    fi
    return 1  # Не установлен
}

# Установка Netbird
install_netbird() {
    print_header "Установка Netbird VPN" "🌐"

    if ! prompt_yn "Установить Netbird VPN? (y/n): " "n" "$CFG_INSTALL_NETBIRD"; then
        log_info "Установка Netbird пропущена"
        return 0
    fi

    # Проверка, установлен ли уже Netbird
    if check_existing_netbird; then
        echo
        echo -e "${YELLOW}⚠️  Netbird уже установлен${NC}"
        echo
        log_info "Текущий статус:"
        netbird status 2>/dev/null || echo "  unknown"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить установку${NC}"
        echo -e "   ${WHITE}2)${NC} ${GRAY}Переподключить Netbird${NC}"
        echo -e "   ${WHITE}3)${NC} ${YELLOW}Переустановить Netbird${NC}"
        echo

        local netbird_choice
        prompt_choice "Выберите опцию [1-3]: " 3 netbird_choice

        case "$netbird_choice" in
            1)
                STATUS_NETBIRD="уже установлен"
                log_info "Установка Netbird пропущена"
                return 0
                ;;
            2)
                connect_netbird
                return 0
                ;;
            3)
                log_warning "Удаление существующей установки Netbird..."
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl stop netbird >/dev/null 2>&1 || true
                    systemctl disable netbird >/dev/null 2>&1 || true
                fi
                # Удаление Netbird зависит от дистрибутива
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get remove -y netbird >/dev/null 2>&1 || true
                elif command -v yum >/dev/null 2>&1; then
                    yum remove -y netbird >/dev/null 2>&1 || true
                elif command -v dnf >/dev/null 2>&1; then
                    dnf remove -y netbird >/dev/null 2>&1 || true
                fi
                log_success "Существующая установка удалена"
                echo
                ;;
        esac
    fi
    
    log_info "Установка Netbird..."
    
    # Установка через официальный скрипт (скачиваем в файл для безопасности)
    local install_log netbird_script
    install_log=$(create_temp_file)
    netbird_script=$(create_temp_file)
    if ! curl -fsSL https://pkgs.netbird.io/install.sh -o "$netbird_script" 2>/dev/null; then
        log_error "Не удалось скачать скрипт установки Netbird"
        rm -f "$install_log" "$netbird_script"
        return 1
    fi
    if sh "$netbird_script" >"$install_log" 2>&1; then
        rm -f "$install_log" "$netbird_script"
        log_success "Netbird установлен"
    else
        log_error "Ошибка установки Netbird"
        if [ -s "$install_log" ]; then
            local error_details=$(tail -5 "$install_log" | tr '\n' ' ' | head -c 200)
            log_error "Детали: $error_details"
        fi
        rm -f "$install_log" "$netbird_script"
        return 1
    fi
    
    # Запуск и включение службы
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Запуск службы Netbird..."
        systemctl start netbird >/dev/null 2>&1 || true
        systemctl enable netbird >/dev/null 2>&1 || true
        sleep 2
    fi
    
    # Подключение к Netbird
    connect_netbird
}

# Подключение к Netbird
connect_netbird() {
    echo
    echo -e "${CYAN}🔑 Подключение к Netbird${NC}"
    echo -e "${GRAY}   Для подключения нужен Setup Key из Netbird Dashboard${NC}"
    echo -e "${GRAY}   Получить ключ: https://app.netbird.io/ (или ваш self-hosted сервер)${NC}"
    echo -e "${GRAY}   Введите 'cancel' для отмены${NC}"
    echo

    local setup_key=""
    if [ "${NON_INTERACTIVE:-false}" = true ] && [ -n "$CFG_NETBIRD_SETUP_KEY" ]; then
        setup_key="$CFG_NETBIRD_SETUP_KEY"
    else
        while [ -z "$setup_key" ]; do
            read -s -p "Введите Netbird Setup Key: " -r setup_key
            echo
            if [ "$setup_key" = "cancel" ]; then
                log_info "Подключение к Netbird отменено"
                STATUS_NETBIRD="пропущен"
                return 0
            fi
            if [ -z "$setup_key" ]; then
                log_error "Setup Key не может быть пустым!"
            fi
        done
    fi

    log_info "Подключение к Netbird..."

    # Подключение (setup key виден в ps, но он одноразовый)
    if netbird up --setup-key "$setup_key" 2>&1; then
        log_success "Подключение к Netbird выполнено"

        # Проверка статуса
        sleep 2
        echo
        log_info "Статус Netbird:"
        netbird status 2>/dev/null || true

        # Показать IP адрес
        local netbird_ip
        netbird_ip=$(ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "")
        if [ -n "$netbird_ip" ]; then
            echo
            log_success "Netbird IP адрес: $netbird_ip"
            DETAIL_NETBIRD_IP="$netbird_ip"
        fi
        STATUS_NETBIRD="подключен"
    else
        log_error "Не удалось подключиться к Netbird"
        log_error "Проверьте правильность Setup Key и доступность сервера"
        STATUS_NETBIRD="ошибка"
        return 1
    fi
}

# Проверка существующей установки мониторинга
check_existing_monitoring() {
    if [ -d "/opt/monitoring" ] && [ -f "/opt/monitoring/vmagent/vmagent" ]; then
        return 0  # Установлен
    fi
    return 1  # Не установлен
}

# Установка мониторинга Grafana
install_grafana_monitoring() {
    print_header "Установка мониторинга Grafana" "📊"
    
    if ! prompt_yn "Установить мониторинг Grafana (cadvisor, node_exporter, vmagent)? (y/n): " "n" "$CFG_INSTALL_MONITORING"; then
        log_info "Установка мониторинга пропущена"
        return 0
    fi

    # Проверка существующей установки
    if check_existing_monitoring; then
        echo
        echo -e "${YELLOW}⚠️  Мониторинг уже установлен${NC}"
        echo -e "${GRAY}   Путь: /opt/monitoring${NC}"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить установку${NC}"
        echo -e "   ${WHITE}2)${NC} ${YELLOW}Переустановить (удалить существующую установку)${NC}"
        echo

        local monitoring_choice
        prompt_choice "Выберите опцию [1-2]: " 2 monitoring_choice

        if [ "$monitoring_choice" = "1" ]; then
            STATUS_MONITORING="уже установлен"
            log_info "Установка мониторинга пропущена"
            return 0
        else
            log_warning "Удаление существующей установки мониторинга..."
            # Останавливаем службы
            systemctl stop cadvisor nodeexporter vmagent 2>/dev/null || true
            systemctl disable cadvisor nodeexporter vmagent 2>/dev/null || true
            # Удаляем службы
            rm -f /etc/systemd/system/cadvisor.service
            rm -f /etc/systemd/system/nodeexporter.service
            rm -f /etc/systemd/system/vmagent.service
            systemctl daemon-reload
            # Удаляем директорию
            rm -rf /opt/monitoring
            log_success "Существующая установка удалена"
            echo
        fi
    fi
    
    log_info "Установка компонентов мониторинга..."

    # Определение архитектуры
    local ARCH
    ARCH=$(detect_arch prometheus) || return 1
    log_info "Обнаружена архитектура: $ARCH"
    
    # Создание директорий
    mkdir -p /opt/monitoring/{cadvisor,nodeexporter,vmagent}
    
    # Установка cadvisor
    log_info "Установка cAdvisor v${CADVISOR_VERSION}..."
    local cadvisor_url="https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-${ARCH}"

    if ! download_with_progress "$cadvisor_url" "/opt/monitoring/cadvisor/cadvisor" "Скачивание cAdvisor v${CADVISOR_VERSION}..."; then
        log_error "Не удалось скачать cAdvisor"
        return 1
    fi
    chmod +x /opt/monitoring/cadvisor/cadvisor
    log_success "cAdvisor установлен"

    # Установка node_exporter
    log_info "Установка Node Exporter ${NODE_EXPORTER_VERSION}..."
    local ne_dir="/opt/monitoring/nodeexporter"
    local node_exporter_url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"

    if ! download_with_progress "$node_exporter_url" "${ne_dir}/node_exporter.tar.gz" "Скачивание Node Exporter ${NODE_EXPORTER_VERSION}..."; then
        log_error "Не удалось скачать Node Exporter"
        return 1
    fi

    tar -xzf "${ne_dir}/node_exporter.tar.gz" -C "${ne_dir}"
    mv "${ne_dir}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" "${ne_dir}/"
    chmod +x "${ne_dir}/node_exporter"
    rm -rf "${ne_dir}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}" "${ne_dir}/node_exporter.tar.gz"
    log_success "Node Exporter установлен"

    # Установка vmagent
    log_info "Установка VictoriaMetrics Agent v${VMAGENT_VERSION}..."
    local vm_dir="/opt/monitoring/vmagent"
    local vmagent_url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/vmutils-linux-${ARCH}-v${VMAGENT_VERSION}.tar.gz"

    if ! download_with_progress "$vmagent_url" "${vm_dir}/vmagent.tar.gz" "Скачивание VictoriaMetrics Agent v${VMAGENT_VERSION}..."; then
        log_error "Не удалось скачать VictoriaMetrics Agent с $vmagent_url"
        log_info "Проверьте: 1) Интернет соединение, 2) Доступность GitHub, 3) Версия пакета"
        return 1
    fi

    tar -xzf "${vm_dir}/vmagent.tar.gz" -C "${vm_dir}"
    mv "${vm_dir}/vmagent-prod" "${vm_dir}/vmagent"
    rm -f "${vm_dir}/vmagent.tar.gz" "${vm_dir}/vmalert-prod" "${vm_dir}/vmauth-prod" "${vm_dir}/vmbackup-prod" "${vm_dir}/vmrestore-prod" "${vm_dir}/vmctl-prod"
    chmod +x "${vm_dir}/vmagent"
    log_success "VictoriaMetrics Agent установлен"
    
    # Запрос имени инстанса
    local instance_name
    if [ "${NON_INTERACTIVE:-false}" = true ] && [ -n "$CFG_INSTANCE_NAME" ]; then
        instance_name="$CFG_INSTANCE_NAME"
    else
        echo
        read -p "Введите название инстанса (имя сервера для Grafana): " -r instance_name
        instance_name=${instance_name:-$(hostname)}
    fi
    log_info "Используется имя инстанса: $instance_name"
    
    # Запрос IP адреса сервера Grafana (Netbird IP)
    echo
    echo -e "${CYAN}🌐 Конфигурация подключения к Grafana${NC}"
    echo -e "${GRAY}   Укажите Netbird IP адрес сервера с Grafana${NC}"
    echo -e "${GRAY}   Можно узнать командой: netbird status${NC}"
    echo
    local grafana_ip=""
    if [ "${NON_INTERACTIVE:-false}" = true ] && [ -n "$CFG_GRAFANA_IP" ]; then
        grafana_ip="$CFG_GRAFANA_IP"
    else
        while [ -z "$grafana_ip" ]; do
            read -p "Введите Netbird IP адрес сервера Grafana (например, 100.64.0.1): " -r grafana_ip
            if [ -z "$grafana_ip" ]; then
                log_error "IP адрес не может быть пустым!"
            elif ! [[ "$grafana_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                log_error "Неверный формат IP адреса!"
                grafana_ip=""
            fi
        done
    fi
    DETAIL_GRAFANA_IP="$grafana_ip"
    
    # Создание конфигурации vmagent
    log_info "Создание конфигурации vmagent..."
    cat > /opt/monitoring/vmagent/scrape.yml << EOF
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: integrations/cAdvisor
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:9101']
        labels:
          instance: "$instance_name"
  - job_name: integrations/node_exporter
    scrape_interval: 15s
    static_configs:
      - targets: ['localhost:9100']
        labels:
          instance: "$instance_name"
EOF
    
    log_success "Конфигурационные файлы созданы"
    
    # Создание systemd служб
    log_info "Создание systemd служб..."
    
    # cAdvisor service
    cat > /etc/systemd/system/cadvisor.service << EOF
[Unit]
Description=cAdvisor
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/cadvisor/cadvisor \\
        -listen_ip=127.0.0.1 \\
        -logtostderr \\
        -port=9101 \\
        -docker_only=true
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Node Exporter service
    cat > /etc/systemd/system/nodeexporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/nodeexporter/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # VictoriaMetrics Agent service
    cat > /etc/systemd/system/vmagent.service << EOF
[Unit]
Description=VictoriaMetrics Agent
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/opt/monitoring/vmagent/vmagent \\
      -httpListenAddr=127.0.0.1:8429 \\
      -promscrape.config=/opt/monitoring/vmagent/scrape.yml \\
      -promscrape.configCheckInterval=60s \\
      -remoteWrite.url=http://${grafana_ip}:8428/api/v1/write
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    log_success "Systemd службы созданы"
    
    # Запуск служб
    log_info "Запуск служб мониторинга..."
    systemctl daemon-reload
    systemctl enable cadvisor nodeexporter vmagent
    systemctl start cadvisor nodeexporter vmagent
    
    # Проверка статуса
    sleep 2
    echo
    log_info "Проверка статуса служб..."
    if systemctl is-active --quiet cadvisor; then
        log_success "cAdvisor запущен"
    else
        log_warning "cAdvisor не запущен"
    fi
    
    if systemctl is-active --quiet nodeexporter; then
        log_success "Node Exporter запущен"
    else
        log_warning "Node Exporter не запущен"
    fi
    
    if systemctl is-active --quiet vmagent; then
        log_success "VictoriaMetrics Agent запущен"
    else
        log_warning "VictoriaMetrics Agent не запущен"
    fi
    
    echo
    log_success "Мониторинг Grafana установлен и настроен"
    STATUS_MONITORING="установлен"
    echo
    echo -e "${WHITE}📋 Информация о мониторинге:${NC}"
    echo -e "${GRAY}   Имя инстанса: $instance_name${NC}"
    echo -e "${GRAY}   Grafana сервер: $grafana_ip:8428${NC}"
    echo -e "${GRAY}   cAdvisor: http://127.0.0.1:9101${NC}"
    echo -e "${GRAY}   Node Exporter: http://127.0.0.1:9100${NC}"
    echo -e "${GRAY}   VM Agent: http://127.0.0.1:8429${NC}"
    echo
}

# Применение сетевых настроек
apply_network_settings() {
    print_header "Оптимизация сетевых настроек" "🌐"

    if ! prompt_yn "Применить оптимизацию сетевых настроек (BBR, TCP tuning, лимиты)? (y/n): " "y" "$CFG_APPLY_NETWORK"; then
        log_info "Оптимизация сетевых настроек пропущена"
        return 0
    fi

    log_info "Применение сетевых настроек..."

    # Создание файла конфигурации sysctl
    local sysctl_file="/etc/sysctl.d/99-remnawave-tuning.conf"

    # Проверка существующего файла
    if [ -f "$sysctl_file" ]; then
        echo
        echo -e "${YELLOW}⚠️  Файл конфигурации уже существует${NC}"
        echo -e "${GRAY}   Путь: $sysctl_file${NC}"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить (оставить текущие настройки)${NC}"
        echo -e "   ${WHITE}2)${NC} ${YELLOW}Перезаписать настройки${NC}"
        echo

        local sysctl_choice
        prompt_choice "Выберите опцию [1-2]: " 2 sysctl_choice

        if [ "$sysctl_choice" = "1" ]; then
            log_info "Сетевые настройки не изменены"
            return 0
        fi
    fi

    # Проверка поддержки BBR: bbr3 (ядро 6.12+) → bbr2 (XanMod) → bbr (стандартный)
    log_info "Проверка поддержки BBR..."
    BBR_MODULE=""
    BBR_ALGO=""

    # 1. Пробуем BBR3 (встроен в ядро 6.12+)
    if grep -q "bbr3" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_MODULE="tcp_bbr"
        BBR_ALGO="bbr3"
        log_success "BBR3 доступен (ядро $(uname -r))"
    # 2. Пробуем BBR2 (XanMod / пропатченные ядра)
    elif grep -q "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        BBR_MODULE="tcp_bbr2"
        BBR_ALGO="bbr2"
        log_success "BBR2 доступен (ядро $(uname -r))"
    elif grep -q "tcp_bbr2" /proc/modules 2>/dev/null || modprobe tcp_bbr2 2>/dev/null; then
        BBR_MODULE="tcp_bbr2"
        BBR_ALGO="bbr2"
        log_success "Модуль BBR2 загружен"
    else
        # 3. BBR2 недоступен — предлагаем установить XanMod ядро
        log_warning "BBR2/BBR3 недоступны на текущем ядре ($(uname -r))"

        # Установка XanMod только для Debian/Ubuntu
        if [[ "$PKG_MANAGER" = "apt-get" ]]; then
            echo
            echo -e "${WHITE}🔧 Установка ядра XanMod с поддержкой BBR2:${NC}"
            echo -e "   ${WHITE}1)${NC} ${GRAY}Установить XanMod ядро с BBR2 (рекомендуется, требуется перезагрузка)${NC}"
            echo -e "   ${WHITE}2)${NC} ${GRAY}Использовать стандартный BBR1${NC}"
            echo

            local bbr_choice
            prompt_choice "Выберите опцию [1-2]: " 2 bbr_choice

            if [ "$bbr_choice" = "1" ]; then
                log_info "Установка XanMod ядра..."
                if install_xanmod_kernel; then
                    # После установки ядра BBR2 будет доступен после перезагрузки
                    BBR_MODULE="tcp_bbr2"
                    BBR_ALGO="bbr2"
                    log_success "XanMod ядро установлено. BBR2 будет активен после перезагрузки"
                else
                    log_warning "Не удалось установить XanMod. Используется BBR1"
                fi
            fi
        fi

        # Fallback на BBR1
        if [ -z "$BBR_ALGO" ]; then
            BBR_MODULE="tcp_bbr"
            BBR_ALGO="bbr"
            if ! grep -q "tcp_bbr" /proc/modules 2>/dev/null; then
                modprobe tcp_bbr 2>/dev/null || true
            fi
            if lsmod | grep -q "tcp_bbr" 2>/dev/null; then
                log_success "Модуль BBR1 загружен (fallback)"
            else
                log_warning "BBR1 может быть недоступен на этом ядре"
            fi
        fi
    fi

    log_info "Используется алгоритм: ${BBR_ALGO}"

    # Создание конфигурационного файла
    log_info "Создание конфигурации sysctl..."

    cat > "$sysctl_file" << EOF
# ╔════════════════════════════════════════════════════════════════╗
# ║  Remnawave Network Tuning Configuration                        ║
# ║  Оптимизация сети для VPN/Proxy нод                           ║
# ╚════════════════════════════════════════════════════════════════╝

# === IPv6 (Отключен для стабильности, lo оставлен для совместимости) ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 0

# === IPv4 и Маршрутизация ===
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === Оптимизация TCP и BBR2 ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${BBR_ALGO}
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

# === TCP Keepalive ===
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15

# === Буферы сокетов (16 MB) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Безопасность ===
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.tcp_syncookies = 1

# === Системные лимиты ===
fs.file-max = 2097152
vm.swappiness = 10
EOF

    log_success "Конфигурация sysctl создана: $sysctl_file"

    # Применение настроек
    log_info "Применение настроек sysctl..."
    if sysctl -p "$sysctl_file" >/dev/null 2>&1; then
        log_success "Настройки sysctl применены"
    else
        log_warning "Некоторые настройки могли не примениться (это нормально для некоторых систем)"
        sysctl -p "$sysctl_file" 2>&1 | grep -i "error\|invalid" || true
    fi

    # Настройка лимитов файлов
    log_info "Настройка лимитов файловых дескрипторов..."

    local limits_file="/etc/security/limits.d/99-remnawave.conf"
    cat > "$limits_file" << 'EOF'
# Remnawave File Limits
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
root soft nofile 1048576
root hard nofile 1048576
root soft nproc 65535
root hard nproc 65535
EOF

    log_success "Лимиты файлов настроены: $limits_file"

    # Настройка systemd лимитов
    log_info "Настройка systemd лимитов..."

    local systemd_conf="/etc/systemd/system.conf.d"
    mkdir -p "$systemd_conf"
    cat > "$systemd_conf/99-remnawave.conf" << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

    # Перезагрузка systemd
    systemctl daemon-reexec 2>/dev/null || true

    log_success "Systemd лимиты настроены"

    # Проверка применённых настроек
    echo
    log_info "Проверка применённых настроек:"
    echo -e "${GRAY}   BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'не определено')${NC}"
    echo -e "${GRAY}   IP Forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 'не определено')${NC}"
    echo -e "${GRAY}   TCP FastOpen: $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 'не определено')${NC}"
    echo -e "${GRAY}   File Max: $(sysctl -n fs.file-max 2>/dev/null || echo 'не определено')${NC}"
    echo -e "${GRAY}   Somaxconn: $(sysctl -n net.core.somaxconn 2>/dev/null || echo 'не определено')${NC}"
    echo

    log_success "Оптимизация сетевых настроек завершена"
    STATUS_NETWORK="применены"
    echo -e "${CYAN}   Для полного применения лимитов рекомендуется перезагрузка системы${NC}"
}

# Главная функция
run_full_install() {
    print_header "Полная установка RemnawaveNode + Caddy" "🚀"

    # Проверка root (идемпотентна, safe для повторного вызова)
    check_root

    # Получение IP сервера
    if [ -z "${NODE_IP:-}" ]; then
        NODE_IP=$(get_server_ip)
    fi

    # Определение ОС (если ещё не определена)
    if [ -z "${OS:-}" ]; then
        detect_os
        detect_package_manager
    fi

    log_info "Обнаружена ОС: $OS"
    log_info "IP сервера: $NODE_IP"
    echo

    # Проверка свободного места на диске
    if ! check_disk_space 500 "/opt"; then
        if ! prompt_yn "Недостаточно места. Продолжить? (y/n): " "n"; then
            exit 1
        fi
    fi
    echo

    # Проактивная очистка блокировок пакетного менеджера (apt lock, unattended-upgrades)
    ensure_package_manager_available
    # Флаг для восстановления автообновлений при выходе
    _RESTORE_AUTO_UPDATES=true

    echo

    # Автоопределение последних версий компонентов
    update_component_versions
    echo

    # [1/8] Применение сетевых настроек (BBR, TCP tuning, лимиты)
    echo -e "${BOLD}[1/8] Сетевые настройки${NC}"
    apply_network_settings

    echo

    # Установка необходимых и полезных пакетов
    install_base_utilities
    echo

    # [2/8] Установка Docker
    echo -e "${BOLD}[2/8] Docker${NC}"
    if ! install_docker; then
        log_error "Не удалось установить или запустить Docker"
        STATUS_DOCKER="ошибка"
        exit 1
    fi
    STATUS_DOCKER="установлен"
    check_docker_compose
    echo

    # [3/8] Установка RemnawaveNode
    echo -e "${BOLD}[3/8] RemnawaveNode${NC}"
    install_remnanode
    echo

    # [4/8] Установка Caddy Selfsteal
    echo -e "${BOLD}[4/8] Caddy Selfsteal${NC}"
    install_caddy_selfsteal
    echo

    # [5/8] Настройка UFW файервола
    echo -e "${BOLD}[5/8] UFW Firewall${NC}"
    setup_ufw
    echo

    # [6/8] Установка Fail2ban
    echo -e "${BOLD}[6/8] Fail2ban${NC}"
    install_fail2ban
    echo

    # [7/8] Установка Netbird
    echo -e "${BOLD}[7/8] Netbird VPN${NC}"
    install_netbird
    echo

    # [8/8] Установка мониторинга Grafana
    echo -e "${BOLD}[8/8] Мониторинг Grafana${NC}"
    install_grafana_monitoring
    echo

    # Восстановление автоматических обновлений
    restore_auto_updates
    _RESTORE_AUTO_UPDATES=false

    # Итоговое саммари
    show_installation_summary

    log_success "Всё готово! Установка завершена."
}

# Точка входа
main() {
    # Загрузка конфиг-файла (может установить NON_INTERACTIVE=true)
    if [ -f "$CONFIG_FILE" ] && [ "${NON_INTERACTIVE:-false}" != true ]; then
        load_config_file "$CONFIG_FILE"
    fi

    # Non-interactive: пропустить меню, запустить полную установку
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        run_full_install
        return
    fi

    # Интерактивный режим: баннер → статус → меню
    check_root
    NODE_IP=$(get_server_ip)
    detect_os
    detect_package_manager

    print_banner
    show_system_status
    show_main_menu
}

# Вывод справки
show_help() {
    print_header "Remnawave Node Installer v${SCRIPT_VERSION}" "🚀"
    echo -e "${WHITE}Использование:${NC} $(basename "$0") ${CYAN}[ОПЦИЯ]${NC}"
    echo
    echo -e "${WHITE}Команды установки:${NC}"
    echo -e "  ${GRAY}(без опций)${NC}            Показать главное меню"
    echo -e "  ${CYAN}--config FILE${NC}          Non-interactive установка с конфиг-файлом"
    echo
    echo -e "${WHITE}Управление:${NC}"
    echo -e "  ${CYAN}--status${NC}               Показать статус всех компонентов"
    echo -e "  ${CYAN}--update${NC}               Обновить компоненты до последних версий"
    echo -e "  ${CYAN}--change-template${NC}      Сменить HTML шаблон маскировки"
    echo -e "  ${CYAN}--diagnose${NC}             Диагностика: проверка всех компонентов"
    echo -e "  ${CYAN}--uninstall${NC}            Удалить все компоненты"
    echo
    echo -e "${WHITE}Утилиты:${NC}"
    echo -e "  ${CYAN}--self-update${NC}          Обновить сам скрипт до последней версии"
    echo -e "  ${CYAN}--export-config${NC}        Экспорт текущей конфигурации в файл"
    echo -e "  ${CYAN}--dry-run${NC}              Показать план установки без выполнения"
    echo -e "  ${CYAN}--help${NC}                 Показать эту справку"
    echo
    echo -e "${WHITE}Компоненты:${NC}"
    echo -e "  ${GREEN}●${NC} RemnawaveNode (Docker)     → ${GRAY}$REMNANODE_DIR${NC}"
    echo -e "  ${GREEN}●${NC} Caddy Selfsteal (Docker)   → ${GRAY}$CADDY_DIR${NC}"
    echo -e "  ${GREEN}●${NC} UFW Firewall               → ${GRAY}deny all + whitelist${NC}"
    echo -e "  ${GREEN}●${NC} Fail2ban                   → ${GRAY}SSH + Caddy + порт-сканы${NC}"
    echo -e "  ${GREEN}●${NC} Netbird VPN"
    echo -e "  ${GREEN}●${NC} Grafana мониторинг         → ${GRAY}/opt/monitoring${NC}"
    echo
    echo -e "${WHITE}Non-interactive режим:${NC}"
    echo -e "  ${GRAY}Создайте файл /etc/remnanode-install.conf:${NC}"
    echo -e "  ${CYAN}CFG_SECRET_KEY${NC}=\"...\"         ${GRAY}# SECRET_KEY из панели${NC}"
    echo -e "  ${CYAN}CFG_DOMAIN${NC}=\"reality.example.com\" ${GRAY}# Домен${NC}"
    echo -e "  ${CYAN}CFG_NODE_PORT${NC}=3000           ${GRAY}# Порт ноды${NC}"
    echo -e "  ${CYAN}CFG_CERT_TYPE${NC}=1              ${GRAY}# 1=обычный, 2=wildcard${NC}"
    echo -e "  ${CYAN}CFG_CADDY_PORT${NC}=9443          ${GRAY}# HTTPS порт Caddy${NC}"
    echo -e "  ${CYAN}CFG_INSTALL_NETBIRD${NC}=n         ${GRAY}# Установка Netbird (y/n)${NC}"
    echo -e "  ${CYAN}CFG_SETUP_UFW${NC}=y               ${GRAY}# Настройка UFW (y/n)${NC}"
    echo -e "  ${CYAN}CFG_INSTALL_FAIL2BAN${NC}=y        ${GRAY}# Установка Fail2ban (y/n)${NC}"
    echo -e "  ${CYAN}CFG_INSTALL_MONITORING${NC}=n      ${GRAY}# Установка мониторинга (y/n)${NC}"
    echo
    echo -e "${WHITE}Env переменные:${NC}"
    echo -e "  ${CYAN}NON_INTERACTIVE=true${NC} ${GRAY}# Включить non-interactive режим${NC}"
    echo -e "  ${CYAN}CONFIG_FILE=/path${NC}   ${GRAY}# Путь к конфиг-файлу${NC}"
    echo
    echo -e "${GRAY}Лог установки: $INSTALL_LOG${NC}"
    echo
}

# ═══════════════════════════════════════════════════════════════════
#  Общая инициализация для CLI-команд
# ═══════════════════════════════════════════════════════════════════
_init_env() {
    check_root
    NODE_IP=$(get_server_ip)
    detect_os
    detect_package_manager
}

# ═══════════════════════════════════════════════════════════════════
#  Список доступных SNI шаблонов
# ═══════════════════════════════════════════════════════════════════
TEMPLATES=(
    "10gag:Сайт мемов (10gag)"
    "503-1:Страница ошибки 503 (v1)"
    "503-2:Страница ошибки 503 (v2)"
    "convertit:Конвертер файлов (Convertit)"
    "converter:Видеостудия-конвертер"
    "downloader:Даунлоадер"
    "filecloud:Облачное хранилище"
    "games-site:Ретро игровой портал"
    "modmanager:Мод-менеджер для игр"
    "speedtest:Спидтест"
    "YouTube:Видеохостинг с капчей"
)

# Интерактивный выбор шаблона + загрузка
select_and_download_template() {
    local target_dir="${1:-$CADDY_HTML_DIR}"

    echo -e "${WHITE}🎨 Выбор HTML шаблона для маскировки:${NC}"
    echo
    local i=1
    for entry in "${TEMPLATES[@]}"; do
        local folder="${entry%%:*}"
        local label="${entry#*:}"
        printf "   ${CYAN}%2d)${NC} %s\n" "$i" "$label"
        i=$((i + 1))
    done
    printf "   ${CYAN}%2d)${NC} ${YELLOW}Случайный шаблон${NC}\n" "$i"
    echo

    local tmpl_choice
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        tmpl_choice=$i  # случайный в non-interactive
    else
        prompt_choice "Выберите шаблон [1-$i]: " "$i" tmpl_choice "$i"
    fi

    local template_folder
    if [ "$tmpl_choice" -eq "$i" ]; then
        # Случайный
        local random_entry="${TEMPLATES[$RANDOM % ${#TEMPLATES[@]}]}"
        template_folder="${random_entry%%:*}"
        local template_label="${random_entry#*:}"
        log_info "Случайный выбор: $template_label"
    else
        local idx=$((tmpl_choice - 1))
        local entry="${TEMPLATES[$idx]}"
        template_folder="${entry%%:*}"
    fi

    download_template "$template_folder" "$template_folder"
}

# Смена шаблона на существующей установке
change_template() {
    check_root

    if [ ! -d "$CADDY_HTML_DIR" ]; then
        log_error "Caddy не установлен ($CADDY_HTML_DIR не найден)"
        exit 1
    fi

    print_header "Смена HTML шаблона" "🎨"
    echo -e "${GRAY}  Текущий шаблон: $CADDY_HTML_DIR${NC}"
    echo

    select_and_download_template "$CADDY_HTML_DIR"

    # Перезапуск Caddy не требуется — он отдаёт статические файлы
    log_success "Шаблон обновлён. Перезапуск Caddy не требуется."
}

# ═══════════════════════════════════════════════════════════════════
#  --update: обновление компонентов без изменения конфигов
# ═══════════════════════════════════════════════════════════════════
update_components() {
    _init_env

    print_header "Обновление компонентов" "🔄"

    echo -e "${WHITE}Что обновить?${NC}"
    echo
    echo -e "   ${CYAN}1)${NC} Всё"
    echo -e "   ${CYAN}2)${NC} RemnawaveNode (docker pull)"
    echo -e "   ${CYAN}3)${NC} Xray-core (последняя версия)"
    echo -e "   ${CYAN}4)${NC} Caddy (docker pull)"
    echo -e "   ${CYAN}5)${NC} Мониторинг (cadvisor, node_exporter, vmagent)"
    echo

    local upd_choice
    prompt_choice "Выберите [1-5]: " 5 upd_choice

    case "$upd_choice" in
        1)
            _update_remnanode
            _update_xray
            _update_caddy
            _update_monitoring
            ;;
        2) _update_remnanode ;;
        3) _update_xray ;;
        4) _update_caddy ;;
        5) _update_monitoring ;;
    esac

    echo
    log_success "Обновление завершено."
}

_update_remnanode() {
    if [ ! -f "$REMNANODE_DIR/docker-compose.yml" ]; then
        log_warning "RemnawaveNode не установлен — пропуск"
        return 0
    fi
    log_info "Обновление RemnawaveNode..."
    if ! docker compose --project-directory "$REMNANODE_DIR" pull; then
        log_error "Не удалось скачать образ RemnawaveNode"
        return 1
    fi
    if ! docker compose --project-directory "$REMNANODE_DIR" up -d; then
        log_error "Не удалось запустить RemnawaveNode"
        return 1
    fi
    log_success "RemnawaveNode обновлён"
}

_update_xray() {
    if [ ! -d "$REMNANODE_DATA_DIR" ]; then
        log_warning "Xray-core не установлен — пропуск"
        return 0
    fi
    log_info "Обновление Xray-core..."
    if install_xray_core; then
        # Перезапуск ноды чтобы подхватить новый бинарник
        if [ -f "$REMNANODE_DIR/docker-compose.yml" ]; then
            docker compose --project-directory "$REMNANODE_DIR" restart
        fi
        log_success "Xray-core обновлён"
    else
        log_error "Не удалось обновить Xray-core"
    fi
}

_update_caddy() {
    if [ ! -f "$CADDY_DIR/docker-compose.yml" ]; then
        log_warning "Caddy не установлен — пропуск"
        return 0
    fi
    log_info "Обновление Caddy..."
    if ! docker compose --project-directory "$CADDY_DIR" pull; then
        log_error "Не удалось скачать образ Caddy"
        return 1
    fi
    if ! docker compose --project-directory "$CADDY_DIR" up -d; then
        log_error "Не удалось запустить Caddy"
        return 1
    fi
    log_success "Caddy обновлён"
}

_update_monitoring() {
    if [ ! -d "/opt/monitoring" ]; then
        log_warning "Мониторинг не установлен — пропуск"
        return 0
    fi
    log_info "Обновление компонентов мониторинга..."

    update_component_versions
    local ARCH
    ARCH=$(detect_arch prometheus) || return 1

    # Останавливаем службы
    systemctl stop cadvisor nodeexporter vmagent 2>/dev/null || true

    # cAdvisor
    log_info "Обновление cAdvisor v${CADVISOR_VERSION}..."
    local cadvisor_url="https://github.com/google/cadvisor/releases/download/v${CADVISOR_VERSION}/cadvisor-v${CADVISOR_VERSION}-linux-${ARCH}"
    if download_with_progress "$cadvisor_url" "/opt/monitoring/cadvisor/cadvisor" "Скачивание cAdvisor..."; then
        chmod +x /opt/monitoring/cadvisor/cadvisor
        log_success "cAdvisor обновлён"
    else
        log_error "Не удалось обновить cAdvisor"
    fi

    # Node Exporter
    log_info "Обновление Node Exporter v${NODE_EXPORTER_VERSION}..."
    local ne_dir="/opt/monitoring/nodeexporter"
    local ne_url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}.tar.gz"
    if download_with_progress "$ne_url" "${ne_dir}/node_exporter.tar.gz" "Скачивание Node Exporter..."; then
        tar --no-same-owner -xzf "${ne_dir}/node_exporter.tar.gz" -C "${ne_dir}" || { log_error "Не удалось распаковать Node Exporter"; return 1; }
        mv "${ne_dir}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}/node_exporter" "${ne_dir}/" || { log_error "Файл node_exporter не найден в архиве"; return 1; }
        chmod +x "${ne_dir}/node_exporter"
        rm -rf "${ne_dir}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH}" "${ne_dir}/node_exporter.tar.gz"
        log_success "Node Exporter обновлён"
    else
        log_error "Не удалось обновить Node Exporter"
    fi

    # VictoriaMetrics Agent
    log_info "Обновление VM Agent v${VMAGENT_VERSION}..."
    local vm_dir="/opt/monitoring/vmagent"
    local vm_url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/v${VMAGENT_VERSION}/vmutils-linux-${ARCH}-v${VMAGENT_VERSION}.tar.gz"
    if download_with_progress "$vm_url" "${vm_dir}/vmagent.tar.gz" "Скачивание VM Agent..."; then
        tar -xzf "${vm_dir}/vmagent.tar.gz" -C "${vm_dir}"
        mv "${vm_dir}/vmagent-prod" "${vm_dir}/vmagent" 2>/dev/null || true
        rm -f "${vm_dir}/vmagent.tar.gz" "${vm_dir}/vmalert-prod" "${vm_dir}/vmauth-prod" "${vm_dir}/vmbackup-prod" "${vm_dir}/vmrestore-prod" "${vm_dir}/vmctl-prod"
        chmod +x "${vm_dir}/vmagent"
        log_success "VM Agent обновлён"
    else
        log_error "Не удалось обновить VM Agent с $vm_url"
        log_info "Проверьте: 1) Интернет соединение, 2) Доступность GitHub, 3) Версия пакета"
    fi

    # Запуск служб
    systemctl start cadvisor nodeexporter vmagent 2>/dev/null || true
    log_success "Мониторинг обновлён"
}

# ═══════════════════════════════════════════════════════════════════
#  --diagnose: диагностика всех компонентов
# ═══════════════════════════════════════════════════════════════════
run_diagnose() {
    _init_env

    print_header "Диагностика системы" "🩺"

    local issues=0

    # 1. Система
    echo -e "${WHITE}[1/7] Система${NC}"
    local disk_free_mb
    disk_free_mb=$(df -m /opt 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$disk_free_mb" ] && [ "$disk_free_mb" -lt 500 ]; then
        log_warning "Мало места на диске: ${disk_free_mb} МБ (рекомендуется > 500 МБ)"
        issues=$((issues + 1))
    else
        log_success "Диск: ${disk_free_mb:-?} МБ свободно"
    fi

    local ram_avail
    ram_avail=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    if [ -n "$ram_avail" ] && [ "$ram_avail" -lt 256 ]; then
        log_warning "Мало свободной RAM: ${ram_avail} МБ"
        issues=$((issues + 1))
    else
        log_success "RAM: ${ram_avail:-?} МБ доступно"
    fi
    echo

    # 2. Docker
    echo -e "${WHITE}[2/7] Docker${NC}"
    if command -v docker >/dev/null 2>&1; then
        if docker ps >/dev/null 2>&1; then
            log_success "Docker работает: $(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
        else
            log_error "Docker установлен, но не отвечает"
            issues=$((issues + 1))
        fi
    else
        log_error "Docker не установлен"
        issues=$((issues + 1))
    fi
    echo

    # 3. RemnawaveNode
    echo -e "${WHITE}[3/7] RemnawaveNode${NC}"
    if [ -f "$REMNANODE_DIR/docker-compose.yml" ]; then
        if docker compose --project-directory "$REMNANODE_DIR" ps 2>/dev/null | grep -qE "Up|running"; then
            log_success "RemnawaveNode запущен"
            # Проверка подключения к панели
            local node_port
            node_port=$(grep "^NODE_PORT=" "$REMNANODE_DIR/.env" 2>/dev/null | cut -d= -f2)
            if [ -n "$node_port" ]; then
                if ss -tlnp 2>/dev/null | grep -q ":${node_port} "; then
                    log_success "Порт $node_port прослушивается"
                else
                    log_warning "Порт $node_port не прослушивается (контейнер может стартовать)"
                fi
            fi
        else
            log_error "RemnawaveNode установлен, но не запущен"
            log_info "Последние логи:"
            docker compose --project-directory "$REMNANODE_DIR" logs --tail 5 2>/dev/null || true
            issues=$((issues + 1))
        fi
    else
        log_info "RemnawaveNode не установлен"
    fi
    echo

    # 4. Caddy
    echo -e "${WHITE}[4/7] Caddy Selfsteal${NC}"
    if [ -f "$CADDY_DIR/docker-compose.yml" ]; then
        if docker compose --project-directory "$CADDY_DIR" ps 2>/dev/null | grep -qE "Up|running"; then
            log_success "Caddy запущен"
            # Проверка порта
            local caddy_port
            caddy_port=$(grep "^SELF_STEAL_PORT=" "$CADDY_DIR/.env" 2>/dev/null | cut -d= -f2)
            if [ -n "$caddy_port" ]; then
                if ss -tlnp 2>/dev/null | grep -q ":${caddy_port} "; then
                    log_success "HTTPS порт $caddy_port прослушивается"
                else
                    log_warning "HTTPS порт $caddy_port не прослушивается"
                    issues=$((issues + 1))
                fi
            fi
            # Проверка сертификата
            local caddy_domain
            caddy_domain=$(grep "^SELF_STEAL_DOMAIN=" "$CADDY_DIR/.env" 2>/dev/null | cut -d= -f2)
            if [ -n "$caddy_domain" ]; then
                log_info "Домен: $caddy_domain"
            fi
        else
            log_error "Caddy установлен, но не запущен"
            log_info "Последние логи:"
            docker compose --project-directory "$CADDY_DIR" logs --tail 5 2>/dev/null || true
            issues=$((issues + 1))
        fi
    else
        log_info "Caddy не установлен"
    fi
    echo

    # 5. UFW / Fail2ban
    echo -e "${WHITE}[5/7] Безопасность${NC}"
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qi "active"; then
            local rule_count
            rule_count=$(ufw status 2>/dev/null | grep -c "ALLOW\|DENY\|REJECT" || echo 0)
            log_success "UFW активен ($rule_count правил)"
        else
            log_warning "UFW установлен, но неактивен"
            issues=$((issues + 1))
        fi
    else
        log_info "UFW не установлен"
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            local jail_count
            jail_count=$(fail2ban-client status 2>/dev/null | grep -oP '\d+' | tail -1 || echo "?")
            log_success "Fail2ban активен ($jail_count jail'ов)"
        else
            log_warning "Fail2ban установлен, но не запущен"
            issues=$((issues + 1))
        fi
    else
        log_info "Fail2ban не установлен"
    fi
    echo

    # 6. Netbird
    echo -e "${WHITE}[6/7] Netbird VPN${NC}"
    if command -v netbird >/dev/null 2>&1; then
        if netbird status 2>/dev/null | grep -qi "connected"; then
            local nb_ip
            nb_ip=$(ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "?")
            log_success "Netbird подключен (IP: $nb_ip)"
        else
            log_warning "Netbird установлен, но не подключен"
            issues=$((issues + 1))
        fi
    else
        log_info "Netbird не установлен"
    fi
    echo

    # 7. Мониторинг
    echo -e "${WHITE}[7/7] Мониторинг${NC}"
    local mon_ok=0
    for svc in cadvisor nodeexporter vmagent; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_success "$svc запущен"
            mon_ok=$((mon_ok + 1))
        elif [ -f "/etc/systemd/system/${svc}.service" ]; then
            log_error "$svc не запущен"
            issues=$((issues + 1))
        fi
    done
    if [ $mon_ok -eq 0 ] && [ ! -d "/opt/monitoring" ]; then
        log_info "Мониторинг не установлен"
    fi
    echo

    # Итог
    print_separator '═'
    if [ $issues -eq 0 ]; then
        echo -e "${GREEN}${BOLD}  ✅ Все проверки пройдены. Проблем не обнаружено.${NC}"
    else
        echo -e "${YELLOW}${BOLD}  ⚠️  Обнаружено проблем: $issues${NC}"
    fi
    echo -e "${GRAY}  Сервер: $NODE_IP | ОС: $(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null)${NC}"
    print_separator '═'
    echo
}

# ═══════════════════════════════════════════════════════════════════
#  --self-update: обновление самого скрипта
# ═══════════════════════════════════════════════════════════════════
self_update() {
    local script_url="https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh"
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")

    log_info "Проверка обновлений скрипта..."

    # Скачиваем один раз во временный файл
    local tmp_script
    tmp_script=$(mktemp)
    if ! curl -fsSL --connect-timeout 10 "$script_url" -o "$tmp_script" 2>/dev/null; then
        rm -f "$tmp_script"
        log_error "Не удалось скачать скрипт с GitHub"
        return 1
    fi

    # Проверяем что скачанный файл валиден
    if ! head -1 "$tmp_script" | grep -q "^#!/"; then
        rm -f "$tmp_script"
        log_error "Скачанный файл невалиден"
        return 1
    fi

    # Извлекаем версию из скачанного файла
    local remote_version
    remote_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$tmp_script" | head -1)

    if [ -z "$remote_version" ]; then
        rm -f "$tmp_script"
        log_error "Не удалось определить версию скачанного скрипта"
        return 1
    fi

    if [ "$remote_version" = "$SCRIPT_VERSION" ]; then
        rm -f "$tmp_script"
        log_success "Установлена последняя версия: v${SCRIPT_VERSION}"
        return 0
    fi

    log_info "Доступна новая версия: v${remote_version} (текущая: v${SCRIPT_VERSION})"

    if ! prompt_yn "Обновить скрипт? (y/n): " "y"; then
        rm -f "$tmp_script"
        log_info "Обновление отменено"
        return 0
    fi

    # Заменяем текущий скрипт скачанным
    chmod +x "$tmp_script"
    cp "$tmp_script" "$script_path"
    rm -f "$tmp_script"
    log_success "Скрипт обновлён до v${remote_version}"
    log_info "Перезапустите скрипт для использования новой версии"
}

# ═══════════════════════════════════════════════════════════════════
#  --dry-run: показать план без выполнения
# ═══════════════════════════════════════════════════════════════════
dry_run() {
    _init_env

    print_header "Dry Run — план установки" "📋"

    echo -e "${GRAY}  Этот режим показывает что будет сделано при полной установке,${NC}"
    echo -e "${GRAY}  без фактических изменений в системе.${NC}"
    echo

    echo -e "${WHITE}ОС:${NC}          $(awk -F= '/^PRETTY_NAME=/{gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null)"
    echo -e "${WHITE}IP:${NC}          $NODE_IP"
    echo -e "${WHITE}Архитектура:${NC} $(uname -m)"
    echo -e "${WHITE}Ядро:${NC}        $(uname -r)"
    echo

    print_separator '─'
    echo -e "${WHITE}${BOLD}  Компоненты для установки:${NC}"
    print_separator '─'
    echo

    # Сетевые настройки
    local bbr_status="BBR1"
    if grep -q "bbr3" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        bbr_status="BBR3"
    elif grep -q "bbr2" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        bbr_status="BBR2"
    fi
    echo -e "  ${CYAN}1.${NC} Сетевые настройки — $bbr_status, TCP tuning, лимиты"

    # Docker
    if command -v docker >/dev/null 2>&1; then
        echo -e "  ${CYAN}2.${NC} Docker — ${GREEN}уже установлен${NC}"
    else
        echo -e "  ${CYAN}2.${NC} Docker — будет установлен"
    fi

    # RemnawaveNode
    if check_existing_remnanode 2>/dev/null; then
        echo -e "  ${CYAN}3.${NC} RemnawaveNode — ${GREEN}уже установлен${NC} (спросит: пропустить/перезаписать)"
    else
        echo -e "  ${CYAN}3.${NC} RemnawaveNode — будет установлен в $REMNANODE_DIR"
    fi

    # Caddy
    if check_existing_caddy 2>/dev/null; then
        echo -e "  ${CYAN}4.${NC} Caddy Selfsteal — ${GREEN}уже установлен${NC} (спросит: пропустить/перезаписать)"
    else
        echo -e "  ${CYAN}4.${NC} Caddy Selfsteal — будет установлен в $CADDY_DIR"
    fi

    # UFW
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "active"; then
        echo -e "  ${CYAN}5.${NC} UFW Firewall — ${GREEN}уже активен${NC}"
    else
        echo -e "  ${CYAN}5.${NC} UFW Firewall — будет настроен (deny all + whitelist 22, 80, 443)"
    fi

    # Fail2ban
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "  ${CYAN}6.${NC} Fail2ban — ${GREEN}уже установлен${NC}"
    else
        echo -e "  ${CYAN}6.${NC} Fail2ban — будет установлен (SSH + Caddy + portscan jails)"
    fi

    # Netbird
    echo -e "  ${CYAN}7.${NC} Netbird VPN — опционально (потребуется Setup Key)"

    # Мониторинг
    if check_existing_monitoring 2>/dev/null; then
        echo -e "  ${CYAN}8.${NC} Мониторинг — ${GREEN}уже установлен${NC}"
    else
        echo -e "  ${CYAN}8.${NC} Мониторинг — опционально (cadvisor + node_exporter + vmagent)"
    fi

    echo
    print_separator '─'
    echo -e "${WHITE}${BOLD}  Файлы и директории:${NC}"
    print_separator '─'
    echo
    echo -e "  ${GRAY}/opt/remnanode/${NC}             — конфиг и compose ноды"
    echo -e "  ${GRAY}/var/lib/remnanode/${NC}         — бинарники Xray-core"
    echo -e "  ${GRAY}/opt/caddy/${NC}                 — Caddy + HTML шаблоны"
    echo -e "  ${GRAY}/opt/monitoring/${NC}            — бинарники мониторинга"
    echo -e "  ${GRAY}/etc/sysctl.d/99-remnawave*${NC} — сетевые настройки"
    echo -e "  ${GRAY}/etc/fail2ban/jail.local${NC}    — конфиг Fail2ban"
    echo -e "  ${GRAY}/var/log/remnanode-install.log${NC} — лог установки"
    echo

    log_info "Для запуска установки выполните: $0"
}

# ═══════════════════════════════════════════════════════════════════
#  --export-config: экспорт текущей конфигурации в файл
# ═══════════════════════════════════════════════════════════════════
export_config() {
    check_root

    local output="${1:-/etc/remnanode-install.conf}"

    print_header "Экспорт конфигурации" "💾"

    log_info "Сбор конфигурации из текущей установки..."

    local cfg_secret="" cfg_port="3000" cfg_domain="" cfg_cert_type="1"
    local cfg_caddy_port="9443" cfg_cf_token=""
    local cfg_netbird="n" cfg_monitoring="n" cfg_instance="" cfg_grafana=""

    # RemnawaveNode
    if [ -f "$REMNANODE_DIR/.env" ]; then
        cfg_secret=$(grep "^SECRET_KEY=" "$REMNANODE_DIR/.env" 2>/dev/null | cut -d= -f2-)
        cfg_port=$(grep "^NODE_PORT=" "$REMNANODE_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "3000")
    fi

    # Caddy
    if [ -f "$CADDY_DIR/.env" ]; then
        cfg_domain=$(grep "^SELF_STEAL_DOMAIN=" "$CADDY_DIR/.env" 2>/dev/null | cut -d= -f2-)
        cfg_caddy_port=$(grep "^SELF_STEAL_PORT=" "$CADDY_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "9443")
        cfg_cf_token=$(grep "^CLOUDFLARE_API_TOKEN=" "$CADDY_DIR/.env" 2>/dev/null | cut -d= -f2-)
        if [ -n "$cfg_cf_token" ]; then
            cfg_cert_type="2"
        fi
        # Убираем wildcard для экспорта
        cfg_domain=$(echo "$cfg_domain" | sed 's/^\*\.//')
    fi

    # Netbird
    if command -v netbird >/dev/null 2>&1; then
        cfg_netbird="y"
    fi

    # Мониторинг
    if [ -d "/opt/monitoring" ]; then
        cfg_monitoring="y"
        cfg_instance=$(grep "instance:" /opt/monitoring/vmagent/scrape.yml 2>/dev/null | head -1 | sed 's/.*instance: *"\(.*\)"/\1/')
        cfg_grafana=$(grep "remoteWrite.url" /etc/systemd/system/vmagent.service 2>/dev/null | grep -oP '//\K[^:]+' || echo "")
    fi

    # Генерация конфига
    cat > "$output" << EOF
# Remnawave Node Install Configuration
# Сгенерировано: $(date)
# Сервер: $(get_server_ip)

# Обязательные параметры
CFG_SECRET_KEY="${cfg_secret}"
CFG_DOMAIN="${cfg_domain}"

# Параметры ноды
CFG_NODE_PORT=${cfg_port}
CFG_INSTALL_XRAY=y

# SSL сертификат (1=обычный, 2=wildcard)
CFG_CERT_TYPE=${cfg_cert_type}
CFG_CADDY_PORT=${cfg_caddy_port}
${cfg_cf_token:+CFG_CLOUDFLARE_TOKEN="${cfg_cf_token}"}

# Сетевые настройки
CFG_APPLY_NETWORK=y

# Безопасность
CFG_SETUP_UFW=y
CFG_INSTALL_FAIL2BAN=y

# Netbird VPN
CFG_INSTALL_NETBIRD=${cfg_netbird}
# CFG_NETBIRD_SETUP_KEY=""

# Мониторинг
CFG_INSTALL_MONITORING=${cfg_monitoring}
${cfg_instance:+CFG_INSTANCE_NAME="${cfg_instance}"}
${cfg_grafana:+CFG_GRAFANA_IP="${cfg_grafana}"}
EOF

    chmod 600 "$output"
    log_success "Конфигурация экспортирована в $output"
    if [ -n "$cfg_secret" ]; then
        log_warning "Конфиг содержит SECRET_KEY — храните файл в безопасности!"
    fi
    echo
    echo -e "${GRAY}  Используйте для деплоя на новом сервере:${NC}"
    echo -e "${CYAN}  scp $output root@<new-server>:/etc/remnanode-install.conf${NC}"
    echo -e "${CYAN}  ssh root@<new-server> 'bash <(curl -fsSL https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh)'${NC}"
    echo
}

# Удаление всех компонентов
uninstall_all() {
    check_root

    echo -e "${RED}${BOLD}⚠️  Удаление всех компонентов Remnawave${NC}"
    print_separator
    echo
    echo "Будут удалены:"
    echo "  - RemnawaveNode ($REMNANODE_DIR)"
    echo "  - Caddy Selfsteal ($CADDY_DIR)"
    echo "  - Fail2ban конфигурация (jail.local, фильтры)"
    echo "  - Мониторинг (/opt/monitoring)"
    echo "  - Данные Xray ($REMNANODE_DATA_DIR)"
    echo "  - Логи RemnawaveNode (/var/log/remnanode)"
    echo
    echo -e "${YELLOW}Docker volumes (caddy_data, caddy_config) НЕ будут удалены.${NC}"
    echo -e "${YELLOW}Netbird НЕ будет удалён (используйте: apt remove netbird).${NC}"
    echo
    read -p "Вы уверены? Введите 'YES' для подтверждения: " -r confirm
    if [ "$confirm" != "YES" ]; then
        echo "Отменено."
        exit 0
    fi

    echo

    # Остановка контейнеров
    if [ -f "$REMNANODE_DIR/docker-compose.yml" ]; then
        log_info "Остановка RemnawaveNode..."
        docker compose --project-directory "$REMNANODE_DIR" down 2>/dev/null || true
        log_success "RemnawaveNode остановлен"
    fi

    if [ -f "$CADDY_DIR/docker-compose.yml" ]; then
        log_info "Остановка Caddy..."
        docker compose --project-directory "$CADDY_DIR" down 2>/dev/null || true
        log_success "Caddy остановлен"
    fi

    # Остановка мониторинга
    if systemctl is-active --quiet cadvisor 2>/dev/null || \
       systemctl is-active --quiet nodeexporter 2>/dev/null || \
       systemctl is-active --quiet vmagent 2>/dev/null; then
        log_info "Остановка мониторинга..."
        systemctl stop cadvisor nodeexporter vmagent 2>/dev/null || true
        systemctl disable cadvisor nodeexporter vmagent 2>/dev/null || true
        rm -f /etc/systemd/system/cadvisor.service
        rm -f /etc/systemd/system/nodeexporter.service
        rm -f /etc/systemd/system/vmagent.service
        systemctl daemon-reload
        log_success "Мониторинг остановлен"
    fi

    # Остановка и удаление fail2ban конфигов
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        log_info "Остановка Fail2ban..."
        systemctl stop fail2ban 2>/dev/null || true
    fi
    rm -f /etc/fail2ban/jail.local
    rm -f /etc/fail2ban/filter.d/caddy-status.conf
    rm -f /etc/fail2ban/filter.d/portscan.conf
    systemctl stop portscan-detect 2>/dev/null || true
    systemctl disable portscan-detect 2>/dev/null || true
    rm -f /etc/systemd/system/portscan-detect.service

    # Удаление logrotate конфига
    rm -f /etc/logrotate.d/remnanode

    # Удаление директорий (с проверкой на пустые переменные)
    log_info "Удаление файлов..."
    [ -n "$REMNANODE_DIR" ] && [ -d "$REMNANODE_DIR" ] && rm -rf "$REMNANODE_DIR"
    [ -n "$REMNANODE_DATA_DIR" ] && [ -d "$REMNANODE_DATA_DIR" ] && rm -rf "$REMNANODE_DATA_DIR"
    [ -n "$CADDY_DIR" ] && [ -d "$CADDY_DIR" ] && rm -rf "$CADDY_DIR"
    [ -d /opt/monitoring ] && rm -rf /opt/monitoring
    [ -d /var/log/remnanode ] && rm -rf /var/log/remnanode

    echo

    # Верификация удаления
    log_info "Проверка удаления..."
    local all_clean=true

    if [ -d "$REMNANODE_DIR" ]; then
        log_warning "Директория $REMNANODE_DIR всё ещё существует"
        all_clean=false
    fi
    if [ -d "$CADDY_DIR" ]; then
        log_warning "Директория $CADDY_DIR всё ещё существует"
        all_clean=false
    fi
    if [ -d "/opt/monitoring" ]; then
        log_warning "Директория /opt/monitoring всё ещё существует"
        all_clean=false
    fi
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE "^(remnanode|caddy)"; then
        log_warning "Обнаружены оставшиеся Docker контейнеры"
        all_clean=false
    fi

    if [ "$all_clean" = true ]; then
        log_success "Все компоненты успешно удалены"
    else
        log_warning "Некоторые компоненты могли быть удалены не полностью"
    fi

    echo -e "${GRAY}Для удаления Docker volumes: docker volume rm caddy_data caddy_config${NC}"
    echo -e "${GRAY}Для удаления Netbird: apt remove netbird (или yum remove netbird)${NC}"
}

# Запуск
case "${1:-}" in
    --help|-h)
        show_help
        exit 0
        ;;
    --status)
        _init_env
        print_banner
        show_system_status
        exit 0
        ;;
    --update)
        update_components
        exit 0
        ;;
    --diagnose)
        run_diagnose
        exit 0
        ;;
    --change-template)
        change_template
        exit 0
        ;;
    --self-update)
        self_update
        exit 0
        ;;
    --dry-run)
        dry_run
        exit 0
        ;;
    --export-config)
        export_config "${2:-/etc/remnanode-install.conf}"
        exit 0
        ;;
    --uninstall)
        uninstall_all
        exit 0
        ;;
    --config)
        if [ -n "${2:-}" ] && [ -f "$2" ]; then
            CONFIG_FILE="$2"
            NON_INTERACTIVE=true
        else
            echo -e "${RED}❌ Укажите путь к конфиг-файлу: $0 --config /path/to/config${NC}"
            exit 1
        fi
        main
        ;;
    "")
        main
        ;;
    *)
        echo -e "${RED}Неизвестная опция: $1${NC}"
        echo -e "${GRAY}Используйте --help для справки${NC}"
        exit 1
        ;;
esac
