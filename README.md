# 🚀 Упрощенный скрипт установки Remnawave Node + Caddy Selfsteal + Wildcard + Netbird + Grafana

Автоматизированный скрипт для быстрой установки и настройки Remnawave Node, Caddy Selfsteal, Netbird VPN и мониторинга Grafana на Linux сервере для Remnawave Panel.

## 🙏 Контакты

- [Telegram Chat](https://t.me/remnawave_admin) - Официальная Telegram-группа

## 📋 Возможности

- ✅ **Remnawave Node** - установка и настройка ноды Remnawave
- ✅ **Caddy Selfsteal** - веб-сервер для маскировки Reality трафика
  - Поддержка обычных SSL сертификатов (HTTP-01 challenge)
  - Поддержка Wildcard сертификатов через Cloudflare DNS-01 challenge
  - Автоматическая проверка существующих сертификатов
  - Валидация Cloudflare API Token перед использованием
- ✅ **Netbird VPN** - подключение к mesh сети
- ✅ **Grafana Monitoring** - установка компонентов мониторинга
  - cAdvisor (мониторинг Docker контейнеров)
  - Node Exporter (метрики системы)
  - VictoriaMetrics Agent (отправка метрик)
- ✅ **Сетевая оптимизация** - BBR2/BBR, TCP tuning, лимиты

### Новые возможности v2.0

- 🎯 **Валидация ввода** — все меню с проверкой и повторным запросом при ошибке
- 🔄 **Спиннер** — анимированный индикатор для длительных операций (скачивание, ожидание)
- 📊 **Итоговое саммари** — сводная таблица установленных компонентов по завершении
- 💾 **Бэкап конфигурации** — автоматическое сохранение `.env` и `docker-compose.yml` при перезаписи
- 🔐 **Валидация CF Token** — проверка Cloudflare API токена через API перед использованием
- 🏥 **Health checks** — проверка работоспособности контейнеров после запуска (до 30 сек)
- 🤖 **Non-interactive режим** — автоматическая установка через конфиг-файл или env переменные
- 📏 **Проверка диска** — контроль свободного места перед установкой (минимум 500 МБ)
- 🔄 **Авто-версии** — автоматическое определение последних версий компонентов через GitHub API
- 🧹 **Очистка логов** — ANSI-коды удаляются из лог-файла для читаемости
- 🗑️ **Temp cleanup** — гарантированная очистка временных файлов при любом завершении
- ↩️ **Отмена** — возможность ввести `cancel` для отмены ввода SECRET_KEY и Netbird Setup Key
- ✅ **Верификация удаления** — проверка что компоненты действительно удалены при `--uninstall`

## 🔧 Требования

- Linux сервер (Ubuntu, Debian, CentOS, AlmaLinux, Fedora, Arch)
- Root доступ (sudo)
- Минимум 500 МБ свободного места на диске (проверяется автоматически)
- Минимум 1GB RAM
- Минимум 1 Core

## 📦 Что устанавливается автоматически

- Docker и Docker Compose
- Необходимые системные пакеты (curl, wget, unzip)
- Remnawave Node (опционально с Xray-core)
- Caddy веб-сервер
- Netbird VPN клиент
- Компоненты мониторинга Grafana

## 🚀 Быстрый старт

### Установка одной командой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh)
```

### Альтернативные способы

<details>
<summary>Скачать и запустить вручную</summary>

```bash
curl -fsSL https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh -o remnanode-install.sh
chmod +x remnanode-install.sh
sudo ./remnanode-install.sh
```

</details>

<details>
<summary>Клонировать репозиторий</summary>

```bash
git clone https://github.com/Case211/remnanode-install.git
cd remnanode-install
chmod +x remnanode-install.sh
sudo ./remnanode-install.sh
```

</details>

<details>
<summary>Non-interactive режим</summary>

С конфиг-файлом:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh) --config /path/to/config
```

Через env переменные:

```bash
sudo NON_INTERACTIVE=true CFG_SECRET_KEY="..." CFG_DOMAIN="example.com" bash <(curl -fsSL https://raw.githubusercontent.com/Case211/remnanode-install/refs/heads/main/remnanode-install.sh)
```

</details>

## 🤖 Non-interactive режим

Для автоматизированного деплоя создайте конфиг-файл `/etc/remnanode-install.conf`:

```bash
# Обязательные параметры
CFG_SECRET_KEY="your_secret_key_from_panel"
CFG_DOMAIN="reality.example.com"

# Опциональные параметры (показаны значения по умолчанию)
CFG_NODE_PORT=3000
CFG_INSTALL_XRAY=y
CFG_CERT_TYPE=1              # 1 = обычный, 2 = wildcard
CFG_CADDY_PORT=9443
CFG_APPLY_NETWORK=y

# Для wildcard сертификата (CFG_CERT_TYPE=2)
CFG_CLOUDFLARE_TOKEN="your_cloudflare_api_token"

# Netbird
CFG_INSTALL_NETBIRD=n
CFG_NETBIRD_SETUP_KEY="your_setup_key"

# Мониторинг
CFG_INSTALL_MONITORING=n
CFG_INSTANCE_NAME="my-server"
CFG_GRAFANA_IP="100.64.0.1"
```

Запуск:

```bash
sudo ./remnanode-install.sh --config /etc/remnanode-install.conf
```

Или через конфиг по умолчанию (`/etc/remnanode-install.conf`):

```bash
sudo ./remnanode-install.sh
```

Скрипт автоматически обнаружит конфиг-файл и переключится в non-interactive режим.

## 📝 Процесс установки

### Шаг 0: Предварительные проверки

Скрипт автоматически:
- Проверяет права root
- Определяет ОС и архитектуру
- Проверяет свободное место на диске (минимум 500 МБ)
- Определяет последние версии компонентов через GitHub API

### Шаг 1: Сетевая оптимизация

Скрипт предложит применить:
- **BBR2/BBR** — алгоритм управления перегрузкой TCP
- **TCP tuning** — оптимизация буферов, keepalive, fastopen
- **Системные лимиты** — файловые дескрипторы, nproc

### Шаг 2: Remnawave Node

Скрипт запросит:
- **SECRET_KEY** из Remnawave Panel (можно ввести `cancel` для отмены)
- **NODE_PORT** (по умолчанию 3000)
- Установку **Xray-core** (опционально)

### Шаг 3: Caddy Selfsteal

Скрипт запросит:
- **Домен** для сертификата
- **Тип сертификата**:
  - Обычный (HTTP-01 challenge)
  - Wildcard (DNS-01 через Cloudflare)
- **Cloudflare API Token** (для wildcard — валидируется через API)
- **HTTPS порт** (по умолчанию 9443)
- Проверку DNS (опционально)

### Шаг 4: Netbird VPN

Скрипт запросит:
- **Setup Key** из Netbird Dashboard (можно ввести `cancel` для отмены)

### Шаг 5: Grafana Monitoring

Скрипт запросит:
- **Имя инстанса** (для отображения в Grafana)
- **Netbird IP адрес** сервера Grafana

### Итоги

По завершении выводится сводная таблица:

```
════════════════════════════════════════════════════════
  📋 Итоги установки
════════════════════════════════════════════════════════

  ✅  Сетевые настройки          применены
  ✅  Docker                     установлен
  ✅  RemnawaveNode              установлен
  ✅  Caddy Selfsteal            установлен
  ⏭️   Netbird VPN                пропущен
  ✅  Мониторинг Grafana         установлен

  Node порт: 3000
  Домен: reality.example.com
  HTTPS порт: 9443
  Grafana: 100.64.0.1

════════════════════════════════════════════════════════
  Сервер: 1.2.3.4
  Лог: /var/log/remnanode-install.log
════════════════════════════════════════════════════════
```

## 🔐 Wildcard сертификат через Cloudflare

Для получения wildcard сертификата (*.example.com):

1. Создайте API Token в Cloudflare Dashboard:
   - Перейдите: My Profile → API Tokens
   - Создайте токен с правами:
     - Zone / Zone / Read
     - Zone / DNS / Edit
   - Выберите зону для которой нужен сертификат

2. При установке выберите опцию "Wildcard сертификат" и введите токен

3. Скрипт автоматически:
   - **Проверит токен** через Cloudflare API
   - Преобразует домен в wildcard формат
   - Настроит DNS-01 challenge
   - Получит сертификат для всех поддоменов

## 💾 Бэкап конфигурации

При выборе "Перезаписать" для существующей установки скрипт автоматически создаёт бэкап:

```
/opt/remnanode.backup.20260219_143022/
├── .env
└── docker-compose.yml

/opt/caddy.backup.20260219_143022/
├── .env
├── docker-compose.yml
└── Caddyfile
```

## 📁 Структура установки

```
/opt/
├── remnanode/          # Remnawave Node
│   ├── docker-compose.yml
│   └── .env
├── caddy/              # Caddy Selfsteal
│   ├── docker-compose.yml
│   ├── Caddyfile
│   ├── .env
│   └── html/           # HTML шаблоны
└── monitoring/         # Компоненты мониторинга
    ├── cadvisor/
    ├── nodeexporter/
    └── vmagent/
```

## ⚙️ Проверка существующих установок

Скрипт автоматически проверяет наличие существующих установок и предлагает:
- **Пропустить** - оставить как есть
- **Перезаписать** - создать бэкап и установить заново

Проверяются:
- Remnawave Node (`/opt/remnanode`)
- Caddy Selfsteal (`/opt/caddy`)
- Netbird (команда `netbird`)
- Мониторинг (`/opt/monitoring`)

## 🔍 Проверка существующих сертификатов

При установке Caddy скрипт проверяет:
- Сертификаты в Caddy volume
- Сертификаты в существующих контейнерах
- Сертификаты acme.sh

Если найден существующий сертификат, можно:
- Использовать существующий
- Получить новый

## 📊 Мониторинг Grafana

После установки компоненты мониторинга будут отправлять метрики на сервер Grafana:

- **cAdvisor** - метрики Docker контейнеров (порт 9101)
- **Node Exporter** - системные метрики (порт 9100)
- **VM Agent** - агрегация и отправка метрик (порт 8429)

Версии компонентов определяются автоматически через GitHub API. Если API недоступен, используются встроенные fallback-версии.

Все службы запускаются автоматически и добавляются в автозагрузку.

## 🛠️ Управление после установки

### Remnawave Node

```bash
cd /opt/remnanode
```

```bash
docker compose logs -f    # Просмотр логов
```

```bash
docker compose restart    # Перезапуск
```

```bash
docker compose down       # Остановка
```

```bash
docker compose up -d      # Запуск
```

### Caddy

```bash
cd /opt/caddy
```

```bash
docker compose logs -f    # Просмотр логов
```

```bash
docker compose restart    # Перезапуск
```

```bash
docker compose down       # Остановка
```

```bash
docker compose up -d      # Запуск
```

### Netbird

```bash
netbird status            # Статус подключения
```

```bash
netbird up                # Подключение
```

```bash
netbird down              # Отключение
```

### Мониторинг

```bash
systemctl status cadvisor      # Статус cAdvisor
```

```bash
systemctl status nodeexporter  # Статус Node Exporter
```

```bash
systemctl status vmagent       # Статус VM Agent
```

## 🔧 Решение проблем

### Docker не устанавливается

Если пакетный менеджер заблокирован процессом обновления:

```bash
sudo killall unattended-upgr
```

```bash
sudo systemctl stop unattended-upgrades
```

### Caddy не запускается

Проверьте логи:

```bash
cd /opt/caddy && docker compose logs
```

Проверьте конфигурацию:

```bash
docker compose config
```

### Netbird не подключается

Проверьте статус:
```bash
netbird status
```

Убедитесь что Setup Key правильный и сервер доступен.

### Мониторинг не отправляет метрики

Проверьте статус служб:
```bash
systemctl status vmagent
```

Проверьте доступность сервера Grafana:
```bash
curl http://<GRAFANA_IP>:8428/health
```

### Cloudflare Token невалиден

Скрипт валидирует токен при вводе. Если токен не проходит проверку:
1. Убедитесь что токен имеет права: Zone / Zone / Read и Zone / DNS / Edit
2. Проверьте что выбрана правильная зона
3. Создайте новый токен если текущий истёк

### Логи скрипта

Лог установки сохраняется в `/var/log/remnanode-install.log` (без ANSI-кодов для читаемости):

```bash
cat /var/log/remnanode-install.log
```

## 📋 Конфигурация Xray Reality

После установки используйте следующие настройки в Xray Reality:

### Для обычного сертификата:
```json
{
  "serverNames": ["your-domain.com"],
  "dest": "127.0.0.1:9443",
  "xver": 0
}
```

### Для wildcard сертификата:
```json
{
  "serverNames": ["your-domain.com", "subdomain.your-domain.com"],
  "dest": "127.0.0.1:9443",
  "xver": 0
}
```

## 🎨 HTML Шаблоны

Caddy автоматически загружает случайный шаблон из доступных:
- 10gag - Сайт мемов
- Convertit - Конвертер файлов
- Converter - Видеостудия-конвертер
- Downloader - Даунлоадер
- FileCloud - Облачное хранилище
- Games-site - Ретро игровой портал
- ModManager - Мод-менеджер для игр
- SpeedTest - Спидтест
- YouTube - Видеохостинг с капчей
- 503 Error - Страницы ошибок

Шаблоны находятся в `/opt/caddy/html/`

## 🔒 Безопасность

- Все службы запускаются в Docker контейнерах
- Caddy использует только локальные порты (127.0.0.1)
- Мониторинг слушает только localhost
- Cloudflare API Token сохраняется в `.env` файле (chmod 600)
- Бэкап конфигурации создаётся автоматически при перезаписи
- Временные файлы гарантированно очищаются при любом завершении скрипта

## 📝 Логи

Логи сохраняются в:
- Установка: `/var/log/remnanode-install.log` (без ANSI-кодов)
- Remnawave Node: `docker compose logs` в `/opt/remnanode`
- Caddy: `/opt/caddy/logs/`
- Мониторинг: `journalctl -u <service-name>`

Примеры просмотра логов:

```bash
cd /opt/remnanode && docker compose logs
```

```bash
cd /opt/caddy && docker compose logs
```

```bash
journalctl -u cadvisor -f
```

```bash
journalctl -u nodeexporter -f
```

```bash
journalctl -u vmagent -f
```

## 🗑️ Удаление

```bash
sudo ./remnanode-install.sh --uninstall
```

Скрипт удалит все компоненты и проверит что удаление прошло успешно. Docker volumes и Netbird не удаляются автоматически:

```bash
docker volume rm caddy_data caddy_config  # Удалить Docker volumes
apt remove netbird                         # Удалить Netbird
```

## 🤝 Поддержка

При возникновении проблем:
1. Проверьте логи: `cat /var/log/remnanode-install.log`
2. Проверьте логи служб
3. Убедитесь что все порты свободны
4. Проверьте доступность интернета
5. Проверьте права доступа к файлам

## 📄 Лицензия

MIT License

## 🙏 Благодарности

- [Remnawave](https://github.com/remnawave) - за отличный проект
- [Caddy](https://caddyserver.com/) - за простой веб-сервер
- [Netbird](https://www.netbird.io/) - за mesh VPN
- [VictoriaMetrics](https://victoriametrics.com/) - за систему мониторинга

## 📚 Полезные ссылки

- [Remnawave Documentation](https://docs.rw/)
- [Caddy Documentation](https://caddyserver.com/docs/)
- [Netbird Documentation](https://docs.netbird.io/)
- [Grafana Monitoring Setup](https://wiki.egam.es/ru/configuration/grafana-monitoring-setup/)

---

**Версия скрипта:** 2.0.0
**Последнее обновление:** 19.02.2026
