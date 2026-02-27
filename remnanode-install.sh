#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════╗
# ║  Упрощенный скрипт установки RemnawaveNode + Caddy Selfsteal   ║
# ║  Wildcard Сертификат (DNS-01 challenge через Cloudflare)
# ║  Только установка, без лишних функций                           ║
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

# Отслеживание статуса установки для финального саммари
STATUS_NETWORK="пропущен"
STATUS_DOCKER="пропущен"
STATUS_REMNANODE="пропущен"
STATUS_CADDY="пропущен"
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

    wget --timeout=30 --tries=3 "$url" -q -O "$output" &
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
        if [[ "$_choice" =~ ^[0-9]+$ ]] && [ "$_choice" -ge 1 ] && [ "$_choice" -le "$max" ]; then
            printf -v "$result_var" '%s' "$_choice"
            return 0
        fi
        log_warning "Неверный выбор. Введите число от 1 до $max."
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
        # shellcheck source=/dev/null
        source "$config_file"
        NON_INTERACTIVE=true
    fi
}

# Итоговое саммари установки
show_installation_summary() {
    echo
    echo -e "${GRAY}$(printf '═%.0s' $(seq 1 56))${NC}"
    echo -e "${WHITE}  📋 Итоги установки${NC}"
    echo -e "${GRAY}$(printf '═%.0s' $(seq 1 56))${NC}"
    echo

    local -a components=("network:Сетевые настройки" "docker:Docker" "remnanode:RemnawaveNode" "caddy:Caddy Selfsteal" "netbird:Netbird VPN" "monitoring:Мониторинг Grafana")

    for entry in "${components[@]}"; do
        local key="${entry%%:*}"
        local label="${entry#*:}"
        local status

        case "$key" in
            network)     status="$STATUS_NETWORK" ;;
            docker)      status="$STATUS_DOCKER" ;;
            remnanode)   status="$STATUS_REMNANODE" ;;
            caddy)       status="$STATUS_CADDY" ;;
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
    echo -e "${GRAY}$(printf '═%.0s' $(seq 1 56))${NC}"
    echo -e "${GRAY}  Сервер: $NODE_IP${NC}"
    echo -e "${GRAY}  Лог: $INSTALL_LOG${NC}"
    echo -e "${GRAY}$(printf '═%.0s' $(seq 1 56))${NC}"
    echo
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
    exit 1
}

# Открытие портов в файерволе (ufw)
ensure_firewall_ports() {
    # Проверяем наличие ufw
    if ! command -v ufw >/dev/null 2>&1; then
        log_info "ufw не установлен — пропуск настройки файервола"
        return 0
    fi

    # Проверяем активен ли ufw
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "ufw неактивен — порты уже доступны"
        return 0
    fi

    log_info "Настройка файервола (ufw)..."

    # 443/tcp — Xray Reality (входящий трафик клиентов)
    if ! ufw status 2>/dev/null | grep -qE "443/tcp.*ALLOW"; then
        ufw allow 443/tcp >/dev/null 2>&1 && log_success "Порт 443/tcp открыт (Xray Reality)" || log_warning "Не удалось открыть порт 443/tcp"
    else
        log_success "Порт 443/tcp уже открыт"
    fi

    # 80/tcp — нужен для HTTP-01 challenge (получение сертификата Caddy)
    if ! ufw status 2>/dev/null | grep -qE "80/tcp.*ALLOW"; then
        ufw allow 80/tcp >/dev/null 2>&1 && log_success "Порт 80/tcp открыт (HTTP-01 challenge)" || log_warning "Не удалось открыть порт 80/tcp"
    else
        log_success "Порт 80/tcp уже открыт"
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
        exit 1
    fi

    # Запрос порта
    if [ "${NON_INTERACTIVE:-false}" = true ]; then
        NODE_PORT="$CFG_NODE_PORT"
    else
        echo
        read -p "Введите NODE_PORT (по умолчанию 3000): " -r NODE_PORT
        NODE_PORT=${NODE_PORT:-3000}
    fi

    # Валидация порта
    if ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_PORT" -lt 1 ] || [ "$NODE_PORT" -gt 65535 ]; then
        log_error "Неверный номер порта"
        exit 1
    fi
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
                exit 1
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
EOF
    
    # Добавление volumes если Xray установлен
    if [ "$INSTALL_XRAY" = "true" ]; then
        cat >> "$REMNANODE_DIR/docker-compose.yml" << EOF
    volumes:
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
    # volumes:
    #   - /dev/shm:/dev/shm  # Раскомментируйте для selfsteal socket access
EOF
    fi
    
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
    ARCH=$(uname -m)
    log_info "Обнаружена архитектура: $ARCH"

    case "$ARCH" in
        x86_64) ARCH="64" ;;
        aarch64|arm64) ARCH="arm64-v8a" ;;
        armv7l|armv6l) ARCH="arm32-v7a" ;;
        *)
            log_error "Неподдерживаемая архитектура: $ARCH"
            log_error "Поддерживаемые архитектуры: x86_64, aarch64, arm64, armv7l, armv6l"
            return 1
            ;;
    esac

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
        local temp_dir="/tmp/selfsteal-template-$$"
        mkdir -p "$temp_dir"

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
            sh -c 'find /data/caddy/certificates -type d -name "*'"$1"'*" 2>/dev/null | head -1' _ "$domain_to_check" 2>/dev/null | grep -q .; then
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
            elif ! [[ "$original_domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || ! [[ "$original_domain" == *.* ]]; then
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
            read -p "Продолжить установку? [Y/n]: " -r continue_install
            if [[ $continue_install =~ ^[Nn]$ ]]; then
                exit 1
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
    
    # Валидация порта
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Неверный номер порта"
        exit 1
    fi
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
        echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN" >> "$CADDY_DIR/.env"
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

    # Добавление переменной окружения для Cloudflare если используется wildcard
    if [ "$USE_WILDCARD" = true ]; then
        cat >> "$CADDY_DIR/docker-compose.yml" << EOF
    environment:
      - CLOUDFLARE_API_TOKEN=\${CLOUDFLARE_API_TOKEN}
EOF
    fi

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
		level ERROR
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
		level ERROR
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
		level ERROR
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
	root * /var/www/html
	try_files {path} /index.html
	file_server
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level ERROR
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
    
    # Загрузка случайного шаблона
    echo
    log_info "Загрузка шаблона..."
    local templates=("1:10gag" "2:503-1" "3:503-2" "4:convertit" "5:converter" "6:downloader" "7:filecloud" "8:games-site" "9:modmanager" "10:speedtest" "11:YouTube")
    local random_template=${templates[$RANDOM % ${#templates[@]}]}
    local template_id=$(echo "$random_template" | cut -d: -f1)
    local template_folder=$(echo "$random_template" | cut -d: -f2)
    
    download_template "$template_folder" "Template $template_id" || true
    
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

    # Запуск Caddy
    log_info "Запуск Caddy..."
    docker compose --project-directory "$CADDY_DIR" up -d

    # Проверка что контейнер поднялся (с ожиданием до 30 сек)
    log_info "Ожидание запуска контейнера..."
    if check_container_health "$CADDY_DIR" "caddy-selfsteal" 30; then
        log_success "Caddy запущен"
        STATUS_CADDY="установлен"
    else
        log_warning "Caddy может не запуститься корректно. Проверьте логи:"
        log_warning "   cd $CADDY_DIR && docker compose logs"
        STATUS_CADDY="ошибка"
    fi

    # Вывод итоговой информации
    echo
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo -e "${WHITE}🎉 Установка завершена успешно!${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
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
    echo
    echo -e "${WHITE}🌐 Установка Netbird VPN${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    echo

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
    echo
    echo -e "${WHITE}📊 Установка мониторинга Grafana${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    echo
    
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
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv6l) ARCH="armv7" ;;
        *)
            log_error "Неподдерживаемая архитектура: $ARCH"
            log_error "Поддерживаемые архитектуры: x86_64, aarch64, arm64, armv7l, armv6l"
            return 1
            ;;
    esac

    log_info "Обнаружена архитектура: $ARCH"
    
    # Создание пользователя для мониторинга (node_exporter и vmagent не требуют root)
    if ! id -u monitoring >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin monitoring 2>/dev/null || true
    fi

    # Создание директорий
    mkdir -p /opt/monitoring/{cadvisor,nodeexporter,vmagent/conf.d}
    
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
        log_error "Не удалось скачать VictoriaMetrics Agent"
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
scrape_config_files:
  - "/opt/monitoring/vmagent/conf.d/*.yml"
EOF
    
    # Конфигурация cadvisor
    cat > /opt/monitoring/vmagent/conf.d/cadvisor.yml << EOF
- job_name: integrations/cAdvisor
  scrape_interval: 15s
  static_configs:
    - targets: ['localhost:9101']
      labels:
        instance: "$instance_name"
EOF
    
    # Конфигурация node_exporter
    cat > /opt/monitoring/vmagent/conf.d/nodeexporter.yml << EOF
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
    
    # Node Exporter service (не требует root)
    cat > /etc/systemd/system/nodeexporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=monitoring
Group=monitoring
Type=simple
ExecStart=/opt/monitoring/nodeexporter/node_exporter --web.listen-address=127.0.0.1:9100
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # VictoriaMetrics Agent service
    # VictoriaMetrics Agent service (не требует root)
    chown -R monitoring:monitoring /opt/monitoring/vmagent
    chown -R monitoring:monitoring /opt/monitoring/nodeexporter
    cat > /etc/systemd/system/vmagent.service << EOF
[Unit]
Description=VictoriaMetrics Agent
Wants=network-online.target
After=network-online.target

[Service]
User=monitoring
Group=monitoring
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
    echo
    echo -e "${WHITE}🌐 Оптимизация сетевых настроек${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 40))${NC}"
    echo

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

    # Проверка поддержки BBR2 (требует ядро 5.18+ или пропатченное)
    log_info "Проверка поддержки BBR2..."
    BBR_MODULE="tcp_bbr2"
    BBR_ALGO="bbr2"

    if ! grep -q "tcp_bbr2" /proc/modules 2>/dev/null && ! modprobe tcp_bbr2 2>/dev/null; then
        log_warning "Модуль BBR2 не найден, пробуем BBR1 как fallback..."
        BBR_MODULE="tcp_bbr"
        BBR_ALGO="bbr"
        if ! grep -q "tcp_bbr" /proc/modules 2>/dev/null && ! modprobe tcp_bbr 2>/dev/null; then
            modprobe tcp_bbr 2>/dev/null || true
        fi
    fi

    if lsmod | grep -q "$BBR_MODULE" 2>/dev/null; then
        log_success "Модуль ${BBR_MODULE} загружен"
    else
        log_warning "${BBR_MODULE} может быть недоступен на этом ядре"
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
main() {
    echo
    echo -e "${WHITE}🚀 Установка RemnawaveNode + Caddy Selfsteal${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo

    # Проверка root
    check_root

    # Загрузка конфиг-файла для non-interactive режима
    if [ -f "$CONFIG_FILE" ]; then
        load_config_file "$CONFIG_FILE"
    fi

    # Получение IP сервера (после check_root)
    NODE_IP=$(get_server_ip)

    # Определение ОС
    detect_os
    detect_package_manager

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
    log_info "Проверка актуальных версий компонентов..."
    local new_cadvisor new_node_exporter new_vmagent
    new_cadvisor=$(fetch_latest_version "google/cadvisor" "$CADVISOR_VERSION")
    new_node_exporter=$(fetch_latest_version "prometheus/node_exporter" "$NODE_EXPORTER_VERSION")
    new_vmagent=$(fetch_latest_version "VictoriaMetrics/VictoriaMetrics" "$VMAGENT_VERSION")

    # Обновляем версии если получены более новые
    if [ -n "$new_cadvisor" ] && [ "$new_cadvisor" != "$CADVISOR_VERSION" ]; then
        CADVISOR_VERSION="$new_cadvisor"
        log_info "cAdvisor: v$CADVISOR_VERSION (обновлено)"
    fi
    if [ -n "$new_node_exporter" ] && [ "$new_node_exporter" != "$NODE_EXPORTER_VERSION" ]; then
        NODE_EXPORTER_VERSION="$new_node_exporter"
        log_info "Node Exporter: v$NODE_EXPORTER_VERSION (обновлено)"
    fi
    if [ -n "$new_vmagent" ] && [ "$new_vmagent" != "$VMAGENT_VERSION" ]; then
        VMAGENT_VERSION="$new_vmagent"
        log_info "VM Agent: v$VMAGENT_VERSION (обновлено)"
    fi
    echo

    # Применение сетевых настроек (BBR, TCP tuning, лимиты)
    apply_network_settings

    echo

    # Установка необходимых пакетов
    log_info "Проверка и установка необходимых пакетов..."
    if ! command -v curl >/dev/null 2>&1; then
        if ! install_package curl; then
            log_error "Не удалось установить curl"
            exit 1
        fi
        log_success "curl установлен"
    else
        log_success "curl уже установлен"
    fi
    if ! command -v wget >/dev/null 2>&1; then
        if ! install_package wget; then
            log_error "Не удалось установить wget"
            exit 1
        fi
        log_success "wget установлен"
    else
        log_success "wget уже установлен"
    fi
    # Опциональные утилиты (не требуются для работы)
    if ! command -v nano >/dev/null 2>&1 || ! command -v btop >/dev/null 2>&1; then
        if prompt_yn "Установить дополнительные утилиты (nano, btop)? (y/n): " "n"; then
            if ! command -v nano >/dev/null 2>&1; then
                if install_package nano; then
                    log_success "nano установлен"
                else
                    log_warning "Не удалось установить nano (некритично)"
                fi
            fi
            if ! command -v btop >/dev/null 2>&1; then
                if install_package btop; then
                    log_success "btop установлен"
                else
                    log_warning "Не удалось установить btop (некритично)"
                fi
            fi
        fi
    fi
    echo

    # Установка Docker
    if ! install_docker; then
        log_error "Не удалось установить или запустить Docker"
        STATUS_DOCKER="ошибка"
        exit 1
    fi
    STATUS_DOCKER="установлен"

    # Проверка Docker Compose
    check_docker_compose

    echo

    # Установка RemnawaveNode
    install_remnanode

    echo

    # Установка Caddy Selfsteal
    install_caddy_selfsteal

    echo

    # Открытие портов 443 и 80 в файерволе
    ensure_firewall_ports

    echo

    # Установка Netbird
    install_netbird

    echo

    # Установка мониторинга Grafana
    install_grafana_monitoring

    echo

    # Восстановление автоматических обновлений (также вызывается автоматически из _cleanup_on_exit)
    restore_auto_updates
    _RESTORE_AUTO_UPDATES=false

    # Итоговое саммари
    show_installation_summary

    log_success "Всё готово! Установка завершена."
}

# Вывод справки
show_help() {
    echo
    echo -e "${WHITE}🚀 Remnawave Node Installer${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo
    echo -e "${WHITE}Использование:${NC} $(basename "$0") ${CYAN}[ОПЦИЯ]${NC}"
    echo
    echo -e "${WHITE}Опции:${NC}"
    echo -e "  ${CYAN}--help${NC}          Показать эту справку"
    echo -e "  ${CYAN}--uninstall${NC}     Удалить все компоненты"
    echo -e "  ${CYAN}--config FILE${NC}   Использовать конфиг-файл (non-interactive режим)"
    echo -e "  ${GRAY}(без опций)${NC}     Запустить интерактивную установку"
    echo
    echo -e "${WHITE}Компоненты:${NC}"
    echo -e "  ${GREEN}●${NC} RemnawaveNode (Docker)     → ${GRAY}$REMNANODE_DIR${NC}"
    echo -e "  ${GREEN}●${NC} Caddy Selfsteal (Docker)   → ${GRAY}$CADDY_DIR${NC}"
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
    echo -e "  ${CYAN}CFG_INSTALL_MONITORING${NC}=n      ${GRAY}# Установка мониторинга (y/n)${NC}"
    echo
    echo -e "${WHITE}Env переменные:${NC}"
    echo -e "  ${CYAN}NON_INTERACTIVE=true${NC} ${GRAY}# Включить non-interactive режим${NC}"
    echo -e "  ${CYAN}CONFIG_FILE=/path${NC}   ${GRAY}# Путь к конфиг-файлу${NC}"
    echo
    echo -e "${GRAY}Лог установки: $INSTALL_LOG${NC}"
    echo
}

# Удаление всех компонентов
uninstall_all() {
    check_root

    echo -e "${RED}⚠️  Удаление всех компонентов Remnawave${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo
    echo "Будут удалены:"
    echo "  - RemnawaveNode ($REMNANODE_DIR)"
    echo "  - Caddy Selfsteal ($CADDY_DIR)"
    echo "  - Мониторинг (/opt/monitoring)"
    echo "  - Данные Xray ($REMNANODE_DATA_DIR)"
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

    # Удаление директорий
    log_info "Удаление файлов..."
    rm -rf "$REMNANODE_DIR"
    rm -rf "$REMNANODE_DATA_DIR"
    rm -rf "$CADDY_DIR"
    rm -rf /opt/monitoring

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
