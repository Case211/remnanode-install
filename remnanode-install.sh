#!/usr/bin/env bash
# ╔════════════════════════════════════════════════════════════════╗
# ║  Упрощенный скрипт установки RemnawaveNode + Caddy Selfsteal   ║
# ║  Wildcard Сертификат (DNS-01 challenge через Cloudflare)
# ║  Только установка, без лишних функций                           ║
# ╚════════════════════════════════════════════════════════════════╝

set -euo pipefail

# Обработка ошибок
trap 'log_error "Ошибка на строке $LINENO. Команда: $BASH_COMMAND"' ERR

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
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
DEFAULT_PORT="9443"
USE_WILDCARD=false
USE_EXISTING_CERT=false
EXISTING_CERT_LOCATION=""
CLOUDFLARE_API_TOKEN=""

# Получение IP сервера
get_server_ip() {
    local ip
    ip=$(curl -s -4 --connect-timeout 5 ifconfig.io 2>/dev/null | tr -d '[:space:]') || \
    ip=$(curl -s -4 --connect-timeout 5 icanhazip.com 2>/dev/null | tr -d '[:space:]') || \
    ip=$(curl -s -4 --connect-timeout 5 ipecho.net/plain 2>/dev/null | tr -d '[:space:]') || \
    ip="127.0.0.1"
    echo "${ip:-127.0.0.1}"
}

NODE_IP=$(get_server_ip)

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
        OS=$(cat /etc/redhat-release | awk '{print $1}')
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
    local install_log=$(mktemp)
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
        
        if $PKG_MANAGER update -qq >"$install_log" 2>&1 && \
           $PKG_MANAGER install -y -qq "$package" >>"$install_log" 2>&1; then
            install_success=true
        else
            # Проверяем если это ошибка lock
            if grep -q "lock" "$install_log" 2>/dev/null; then
                log_warning "Обнаружена блокировка пакетного менеджера. Ожидание..."
                if wait_for_dpkg_lock; then
                    log_info "Повторная попытка установки $package..."
                    rm -f "$install_log"
                    install_log=$(mktemp)
                    if $PKG_MANAGER update -qq >"$install_log" 2>&1 && \
                       $PKG_MANAGER install -y -qq "$package" >>"$install_log" 2>&1; then
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
    # Проверяем процессы, которые могут держать lock
    if pgrep -f 'unattended-upgr|apt-get|apt\.systemd|dpkg' >/dev/null 2>&1; then
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

        # Если всё ещё заблокирован — принудительно завершаем
        if is_dpkg_locked; then
            log_warning "Принудительное завершение процессов, блокирующих пакетный менеджер..."
            killall -9 unattended-upgr 2>/dev/null || true
            killall -9 apt-get 2>/dev/null || true
            killall -9 apt 2>/dev/null || true
            sleep 2

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
        local docker_install_log=$(mktemp)
        local install_success=false
        
        # Пробуем установить Docker
        if curl -fsSL https://get.docker.com 2>/dev/null | sh >"$docker_install_log" 2>&1; then
            install_success=true
        else
            # Проверяем если это ошибка lock
            if grep -q "lock" "$docker_install_log" 2>/dev/null; then
                log_warning "Обнаружена блокировка пакетного менеджера. Ожидание..."
                if wait_for_dpkg_lock; then
                    log_info "Повторная попытка установки Docker..."
                    rm -f "$docker_install_log"
                    docker_install_log=$(mktemp)
                    if curl -fsSL https://get.docker.com 2>/dev/null | sh >"$docker_install_log" 2>&1; then
                        install_success=true
                    fi
                fi
            fi
        fi
        
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
        read -p "Выберите опцию [1-2]: " remnanode_choice
        
        if [ "$remnanode_choice" = "2" ]; then
            log_warning "Удаление существующей установки RemnawaveNode..."
            if [ -f "$REMNANODE_DIR/docker-compose.yml" ]; then
                cd "$REMNANODE_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
            fi
            rm -rf "$REMNANODE_DIR"
            log_success "Существующая установка удалена"
            echo
        else
            log_info "Установка RemnawaveNode пропущена"
            return 0
        fi
    fi
    
    log_info "Установка Remnawave Node..."
    
    # Создание директорий
    mkdir -p "$REMNANODE_DIR"
    mkdir -p "$REMNANODE_DATA_DIR"
    
    # Запрос SECRET_KEY
    echo
    echo -e "${CYAN}📝 Введите SECRET_KEY из Remnawave-Panel${NC}"
    echo -e "${GRAY}   Вставьте содержимое и нажмите ENTER на новой строке для завершения:${NC}"
    SECRET_KEY_VALUE=""
    while IFS= read -r line; do
        if [[ -z $line ]]; then
            break
        fi
        SECRET_KEY_VALUE="$SECRET_KEY_VALUE$line"
    done

    if [ -z "$SECRET_KEY_VALUE" ]; then
        log_error "SECRET_KEY не может быть пустым!"
        exit 1
    fi

    # Запрос порта
    echo
    read -p "Введите NODE_PORT (по умолчанию 3000): " -r NODE_PORT
    NODE_PORT=${NODE_PORT:-3000}
    
    # Валидация порта
    if ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_PORT" -lt 1 ] || [ "$NODE_PORT" -gt 65535 ]; then
        log_error "Неверный номер порта"
        exit 1
    fi
    
    # Запрос установки Xray-core
    echo
    read -p "Установить последнюю версию Xray-core? (y/n): " -r install_xray
    INSTALL_XRAY=false
    if [[ "$install_xray" =~ ^[Yy]$ ]]; then
        INSTALL_XRAY=true
        if ! install_xray_core; then
            log_error "Не удалось установить Xray-core"
            echo
            read -p "Продолжить установку RemnawaveNode без Xray-core? (y/n): " -r continue_without_xray
            if [[ ! $continue_without_xray =~ ^[Yy]$ ]]; then
                log_error "Установка прервана"
                exit 1
            fi
            INSTALL_XRAY=false
            log_warning "Продолжаем установку без Xray-core"
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
    if [ "$INSTALL_XRAY" == "true" ]; then
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
    cd "$REMNANODE_DIR"
    docker compose up -d
    log_success "RemnawaveNode запущен"
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
    
    # Переходим в директорию данных
    if ! cd "$REMNANODE_DATA_DIR"; then
        log_error "Не удалось перейти в директорию: $REMNANODE_DATA_DIR"
        return 1
    fi
    
    # Скачиваем файл
    if ! wget --timeout=30 --tries=3 "${xray_download_url}" -q -O "${xray_filename}"; then
        log_error "Не удалось скачать Xray-core"
        log_error "Проверьте интернет-соединение и доступность GitHub"
        return 1
    fi
    
    if [ ! -f "${xray_filename}" ]; then
        log_error "Файл ${xray_filename} не найден после скачивания"
        return 1
    fi
    
    local file_size
    file_size=$(stat -c%s "${xray_filename}" 2>/dev/null || echo "unknown")
    log_success "Файл скачан (размер: ${file_size} байт)"
    
    # Распаковка
    log_info "Распаковка Xray-core..."
    if ! unzip -o "${xray_filename}" -d "$REMNANODE_DATA_DIR" >/dev/null 2>&1; then
        log_error "Не удалось распаковать архив"
        rm -f "${xray_filename}"
        return 1
    fi
    
    # Удаляем архив
    rm -f "${xray_filename}"
    
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
    
    # Проверка DNS
    local dns_ip
    dns_ip=$(dig +short "$domain" A | tail -1)
    
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
    rm -rf "${CADDY_HTML_DIR:?}"/* 2>/dev/null || true
    cd "$CADDY_HTML_DIR"
    
    # Попытка загрузки через git
    if command -v git >/dev/null 2>&1; then
        local temp_dir="/tmp/selfsteal-template-$$"
        mkdir -p "$temp_dir"
        
        if git clone --filter=blob:none --sparse "https://github.com/DigneZzZ/remnawave-scripts.git" "$temp_dir" 2>/dev/null; then
            cd "$temp_dir"
            git sparse-checkout set "sni-templates/$template_folder" 2>/dev/null
            
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
    local base_url="https://raw.githubusercontent.com/DigneZzZ/remnawave-scripts/main/sni-templates/$template_folder"
    local common_files=("index.html" "favicon.ico")
    
    local files_downloaded=0
    for file in "${common_files[@]}"; do
        local url="$base_url/$file"
        if curl -fsSL "$url" -o "$file" 2>/dev/null; then
            ((files_downloaded++))
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
        read -p "Выберите опцию [1-2]: " caddy_choice
        
        if [ "$caddy_choice" = "1" ]; then
            log_info "Установка Caddy Selfsteal пропущена"
            return 0
        else
            log_warning "Удаление существующей установки Caddy..."
            if [ -f "$CADDY_DIR/docker-compose.yml" ]; then
                cd "$CADDY_DIR" 2>/dev/null && docker compose down 2>/dev/null || true
            fi
            rm -rf "$CADDY_DIR"
            log_success "Существующая установка удалена"
            echo
        fi
    fi
    
    log_info "Установка Caddy Selfsteal..."
    
    # Создание директорий
    mkdir -p "$CADDY_DIR"
    mkdir -p "$CADDY_HTML_DIR"
    mkdir -p "$CADDY_DIR/logs"
    
    # Запрос домена
    echo
    echo -e "${CYAN}🌐 Конфигурация домена${NC}"
    echo -e "${GRAY}   Домен должен совпадать с realitySettings.serverNames в Xray Reality${NC}"
    echo
    local original_domain=""
    while [ -z "$original_domain" ]; do
        read -p "Введите домен (например, reality.example.com): " original_domain
        if [ -z "$original_domain" ]; then
            log_error "Домен не может быть пустым!"
        fi
    done
    
    # Выбор типа сертификата
    echo
    echo -e "${WHITE}🔐 Тип SSL сертификата:${NC}"
    echo -e "   ${WHITE}1)${NC} ${GRAY}Обычный сертификат (HTTP-01 challenge)${NC}"
    echo -e "   ${WHITE}2)${NC} ${GRAY}Wildcard сертификат (DNS-01 challenge через Cloudflare)${NC}"
    echo
    read -p "Выберите опцию [1-2]: " cert_choice
    
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
        
        while [ -z "$CLOUDFLARE_API_TOKEN" ]; do
            read -s -p "Введите Cloudflare API Token: " -r CLOUDFLARE_API_TOKEN
            echo
            if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
                log_error "API Token не может быть пустым!"
            fi
        done
        
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
        read -p "Выберите опцию [1-2]: " cert_action
        
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
    read -p "Выберите опцию [1-2]: " dns_choice
    
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
    echo
    read -p "Введите HTTPS порт (по умолчанию $DEFAULT_PORT): " input_port
    local port="${input_port:-$DEFAULT_PORT}"
    
    # Валидация порта
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Неверный номер порта"
        exit 1
    fi
    
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

    # Если используется существующий сертификат, монтируем существующий volume
    if [ "$USE_EXISTING_CERT" = true ]; then
        # Проверяем существующий volume или создаем новый
        if docker volume inspect caddy_data >/dev/null 2>&1; then
            log_info "Используется существующий volume caddy_data для сертификатов"
            cat >> "$CADDY_DIR/docker-compose.yml" << EOF
      - caddy_data:/data
EOF
        else
            log_info "Создается новый volume caddy_data для сертификатов"
            cat >> "$CADDY_DIR/docker-compose.yml" << EOF
      - caddy_data:/data
EOF
        fi
    else
        cat >> "$CADDY_DIR/docker-compose.yml" << EOF
      - caddy_data:/data
EOF
    fi

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
    local templates=("1:10gag" "2:convertit" "3:converter" "4:downloader" "5:filecloud" "6:games-site" "7:modmanager" "8:speedtest" "9:YouTube")
    local random_template=${templates[$RANDOM % ${#templates[@]}]}
    local template_id=$(echo "$random_template" | cut -d: -f1)
    local template_folder=$(echo "$random_template" | cut -d: -f2)
    
    download_template "$template_folder" "Template $template_id" || true
    
    # Запуск Caddy
    log_info "Запуск Caddy..."
    cd "$CADDY_DIR"
    docker compose up -d
    log_success "Caddy запущен"
    
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
    echo -e "${GRAY}   serverNames: совпадает с доменом выше${NC}"
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
    
    read -p "Установить Netbird VPN? (y/n): " -r install_netbird_choice
    if [[ ! $install_netbird_choice =~ ^[Yy]$ ]]; then
        log_info "Установка Netbird пропущена"
        return 0
    fi
    
    # Проверка, установлен ли уже Netbird
    if check_existing_netbird; then
        echo
        echo -e "${YELLOW}⚠️  Netbird уже установлен${NC}"
        local current_status=$(netbird status 2>/dev/null | head -1 || echo "unknown")
        log_info "Текущий статус: $current_status"
        echo
        echo -e "${WHITE}Выберите действие:${NC}"
        echo -e "   ${WHITE}1)${NC} ${GRAY}Пропустить установку${NC}"
        echo -e "   ${WHITE}2)${NC} ${GRAY}Переподключить Netbird${NC}"
        echo -e "   ${WHITE}3)${NC} ${YELLOW}Переустановить Netbird${NC}"
        echo
        read -p "Выберите опцию [1-3]: " netbird_choice
        
        case "$netbird_choice" in
            1)
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
            *)
                log_info "Установка Netbird пропущена"
                return 0
                ;;
        esac
    fi
    
    log_info "Установка Netbird..."
    
    # Установка через официальный скрипт
    local install_log=$(mktemp)
    if curl -fsSL https://pkgs.netbird.io/install.sh 2>/dev/null | sh >"$install_log" 2>&1; then
        rm -f "$install_log"
        log_success "Netbird установлен"
    else
        log_error "Ошибка установки Netbird"
        if [ -s "$install_log" ]; then
            local error_details=$(tail -5 "$install_log" | tr '\n' ' ' | head -c 200)
            log_error "Детали: $error_details"
        fi
        rm -f "$install_log"
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
    echo
    
    local setup_key=""
    while [ -z "$setup_key" ]; do
        read -s -p "Введите Netbird Setup Key: " -r setup_key
        echo
        if [ -z "$setup_key" ]; then
            log_error "Setup Key не может быть пустым!"
        fi
    done

    log_info "Подключение к Netbird..."

    # Подключение
    if netbird up --setup-key "$setup_key" 2>&1; then
        log_success "Подключение к Netbird выполнено"
        
        # Проверка статуса
        sleep 2
        echo
        log_info "Статус Netbird:"
        netbird status 2>/dev/null || true
        
        # Показать IP адрес
        local netbird_ip=$(ip addr show wt0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1 || echo "не определен")
        if [ -n "$netbird_ip" ] && [ "$netbird_ip" != "не определен" ]; then
            echo
            log_success "Netbird IP адрес: $netbird_ip"
        fi
    else
        log_error "Не удалось подключиться к Netbird"
        log_error "Проверьте правильность Setup Key и доступность сервера"
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
    
    read -p "Установить мониторинг Grafana (cadvisor, node_exporter, vmagent)? (y/n): " -r install_monitoring_choice
    if [[ ! $install_monitoring_choice =~ ^[Yy]$ ]]; then
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
        read -p "Выберите опцию [1-2]: " monitoring_choice
        
        if [ "$monitoring_choice" = "1" ]; then
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
    
    # Создание директорий
    mkdir -p /opt/monitoring/{cadvisor,nodeexporter,vmagent/conf.d}
    
    # Установка cadvisor
    log_info "Установка cAdvisor..."
    cd /opt/monitoring/cadvisor
    local cadvisor_version="v0.53.0"
    local cadvisor_url="https://github.com/google/cadvisor/releases/download/${cadvisor_version}/cadvisor-${cadvisor_version}-linux-${ARCH}"
    
    if ! wget --timeout=30 --tries=3 "$cadvisor_url" -q -O cadvisor; then
        log_error "Не удалось скачать cAdvisor"
        return 1
    fi
    chmod +x cadvisor
    log_success "cAdvisor установлен"
    
    # Установка node_exporter
    log_info "Установка Node Exporter..."
    cd /opt/monitoring/nodeexporter
    local node_exporter_version="1.9.1"
    local node_exporter_url="https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.linux-${ARCH}.tar.gz"
    
    if ! wget --timeout=30 --tries=3 "$node_exporter_url" -q -O node_exporter.tar.gz; then
        log_error "Не удалось скачать Node Exporter"
        return 1
    fi
    
    tar -xzf node_exporter.tar.gz
    mv node_exporter-${node_exporter_version}.linux-${ARCH}/node_exporter ./
    chmod +x node_exporter
    rm -rf node_exporter-${node_exporter_version}.linux-${ARCH} node_exporter.tar.gz
    log_success "Node Exporter установлен"
    
    # Установка vmagent
    log_info "Установка VictoriaMetrics Agent..."
    cd /opt/monitoring/vmagent
    local vmagent_version="v1.123.0"
    local vmagent_url="https://github.com/VictoriaMetrics/VictoriaMetrics/releases/download/${vmagent_version}/vmutils-linux-${ARCH}-${vmagent_version}.tar.gz"
    
    if ! wget --timeout=30 --tries=3 "$vmagent_url" -q -O vmagent.tar.gz; then
        log_error "Не удалось скачать VictoriaMetrics Agent"
        return 1
    fi
    
    tar -xzf vmagent.tar.gz
    mv vmagent-prod vmagent
    rm -f vmagent.tar.gz vmalert-prod vmauth-prod vmbackup-prod vmrestore-prod vmctl-prod
    chmod +x vmagent
    log_success "VictoriaMetrics Agent установлен"
    
    # Запрос имени инстанса
    echo
    read -p "Введите название инстанса (имя сервера для Grafana): " -r instance_name
    instance_name=${instance_name:-$(hostname)}
    log_info "Используется имя инстанса: $instance_name"
    
    # Запрос IP адреса сервера Grafana (Netbird IP)
    echo
    echo -e "${CYAN}🌐 Конфигурация подключения к Grafana${NC}"
    echo -e "${GRAY}   Укажите Netbird IP адрес сервера с Grafana${NC}"
    echo -e "${GRAY}   Можно узнать командой: netbird status${NC}"
    echo
    local grafana_ip=""
    while [ -z "$grafana_ip" ]; do
        read -p "Введите Netbird IP адрес сервера Grafana (например, 100.64.0.1): " -r grafana_ip
        if [ -z "$grafana_ip" ]; then
            log_error "IP адрес не может быть пустым!"
        elif ! [[ "$grafana_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_error "Неверный формат IP адреса!"
            grafana_ip=""
        fi
    done
    
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

    read -p "Применить оптимизацию сетевых настроек (BBR, TCP tuning, лимиты)? (y/n): " -r apply_network_choice
    if [[ ! $apply_network_choice =~ ^[Yy]$ ]]; then
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
        read -p "Выберите опцию [1-2]: " sysctl_choice

        if [ "$sysctl_choice" = "1" ]; then
            log_info "Сетевые настройки не изменены"
            return 0
        fi
    fi

    # Проверка поддержки BBR
    log_info "Проверка поддержки BBR..."
    if ! grep -q "tcp_bbr" /proc/modules 2>/dev/null && ! modprobe tcp_bbr 2>/dev/null; then
        log_warning "Модуль BBR не найден, пробуем загрузить..."
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if lsmod | grep -q tcp_bbr 2>/dev/null; then
        log_success "Модуль BBR загружен"
    else
        log_warning "BBR может быть недоступен на этом ядре"
    fi

    # Создание конфигурационного файла
    log_info "Создание конфигурации sysctl..."

    cat > "$sysctl_file" << 'EOF'
# ╔════════════════════════════════════════════════════════════════╗
# ║  Remnawave Network Tuning Configuration                        ║
# ║  Оптимизация сети для VPN/Proxy нод                           ║
# ╚════════════════════════════════════════════════════════════════╝

# === IPv6 (Отключен для стабильности) ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# === IPv4 и Маршрутизация ===
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# === Оптимизация TCP и BBR ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
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
vm.overcommit_memory = 1
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
    echo -e "${CYAN}   Для полного применения лимитов рекомендуется перезагрузка системы${NC}"
}

# Главная функция
main() {
    clear
    echo -e "${WHITE}🚀 Установка RemnawaveNode + Caddy Selfsteal${NC}"
    echo -e "${GRAY}$(printf '─%.0s' $(seq 1 50))${NC}"
    echo
    
    # Проверка root
    check_root
    
    # Определение ОС
    detect_os
    detect_package_manager
    
    log_info "Обнаружена ОС: $OS"
    echo

    # Проактивная очистка блокировок пакетного менеджера (apt lock, unattended-upgrades)
    ensure_package_manager_available
    # Гарантируем восстановление автообновлений даже при падении скрипта
    trap 'restore_auto_updates' EXIT

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
    echo
    
    # Установка Docker
    if ! install_docker; then
        log_error "Не удалось установить или запустить Docker"
        exit 1
    fi
    
    # Проверка Docker Compose
    check_docker_compose
    
    echo
    
    # Установка RemnawaveNode
    install_remnanode
    
    echo
    
    # Установка Caddy Selfsteal
    install_caddy_selfsteal
    
    echo
    
    # Установка Netbird
    install_netbird
    
    echo
    
    # Установка мониторинга Grafana
    install_grafana_monitoring
    
    echo

    # Восстановление автоматических обновлений
    restore_auto_updates

    log_success "Всё готово! Установка завершена."
}

# Запуск
main "$@"
