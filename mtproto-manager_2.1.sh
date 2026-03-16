#!/bin/bash
#
# MTProto Proxy Manager v2.1
# Автоматическая установка и управление
# Теперь проверяет: установлен или нет

set -e

# ==================== КОНФИГУРАЦИЯ ====================
readonly SCRIPT_VERSION="2.1"
readonly CONFIG_FILE="/etc/mtproto.conf"
readonly BASHRC_PROXY="$HOME/.bashrc_proxy"
readonly DOCKER_IMAGE="telegrammessenger/proxy:latest"
readonly SERVER_IP="${PROXY_IP:-$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Ассоциативный массив для конфигурации
declare -A PROXIES  # [port]="domain:secret"

# ==================== ЛОГИРОВАНИЕ ====================
log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1"; }
log_error()   { echo -e "${RED}[❌]${NC} $1"; }
log_header()  { echo -e "\n${GREEN}╔════════════════════════════════════╗${NC}\n${GREEN}║${NC} $1 ${GREEN}║${NC}\n${GREEN}╚════════════════════════════════════╝${NC}\n"; }
log_divider() { echo -e "${CYAN}────────────────────────────────────────${NC}"; }

# ==================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ====================

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Запустите от root: sudo $0"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_info "Установка Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker >/dev/null 2>&1 || true
        log_success "Docker установлен"
    fi
}

check_ufw() {
    if command -v ufw &>/dev/null; then
        if ! ufw status &>/dev/null | grep -q "Status: active"; then
            log_info "Активация UFW..."
            ufw --force enable >/dev/null 2>&1 || true
        fi
    fi
}

get_secret() {
    local container=$1
    docker inspect "$container" --format='{{range .Config.Env}}{{if hasPrefix . "SECRET="}}{{trimPrefix "SECRET=" .}}{{end}}{{end}}' 2>/dev/null | head -1 || \
    docker inspect "$container" 2>/dev/null | grep -oE "SECRET=[0-9a-f]+" | head -1 | cut -d= -f2
}

get_domain() {
    local container=$1
    docker inspect "$container" --format='{{range .Config.Env}}{{if hasPrefix . "FAKE_TLS_DOMAIN="}}{{trimPrefix "FAKE_TLS_DOMAIN=" .}}{{end}}{{end}}' 2>/dev/null | head -1
}

is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"
}

generate_secret() {
    openssl rand -hex 16
}

open_firewall_port() {
    local port=$1 comment="${2:-Telegram Proxy}"
    if command -v ufw &>/dev/null; then
        ufw allow "$port"/tcp comment "$comment" >/dev/null 2>&1 || \
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
        log_info "Порт $port открыт в фаерволе"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_info "Порт $port открыт в firewalld"
    else
        log_warn "Фаервол не обнаружен, порт $port не настроен"
    fi
}

close_firewall_port() {
    local port=$1
    if command -v ufw &>/dev/null; then
        if ufw delete allow "$port"/tcp >/dev/null 2>&1; then
            log_info "Порт $port закрыт в фаерволе"
        fi
    fi
}

# ==================== СКАНИРОВАНИЕ ====================

scan_existing_proxies() {
    log_info "Сканирование существующих прокси..."
    PROXIES=()
    local found=0
    
    for container in $(docker ps --format '{{.Names}}' 2>/dev/null | grep "^mtproto"); do
        local port=""
        [[ "$container" == "mtproto" ]] && port="443"
        [[ "$container" =~ ^mtproto-([0-9]+)$ ]] && port="${BASH_REMATCH[1]}"
        
        if [ -n "$port" ]; then
            local secret=$(get_secret "$container")
            local domain=$(get_domain "$container")
            if [ -n "$secret" ]; then
                PROXIES["$port"]="${domain:-unknown}:${secret}"
                ((found++))
            fi
        fi
    done
    
    if [ "$found" -eq 0 ] && [ -f "$CONFIG_FILE" ]; then
        log_info "Загрузка конфигурации из $CONFIG_FILE..."
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            if [[ "$key" == "port_"* ]]; then
                local port="${key#port_}"
                PROXIES["$port"]="$value"
            fi
        done < "$CONFIG_FILE"
    fi
    
    echo "$found"
}

show_proxy_list() {
    echo ""
    log_header "📋 Настроенные прокси"
    
    if [ ${#PROXIES[@]} -eq 0 ]; then
        log_warn "Прокси не найдены"
        return 1
    fi
    
    log_divider
    printf "${CYAN}%-8s %-20s %-35s %s${NC}\n" "ПОРТ" "ДОМЕН" "СЕКРЕТ" "СТАТУС"
    log_divider
    
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}"
        local domain="${value%%:*}"
        local secret="${value#*:}"
        local container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
        local status="🟢 UP"
        is_running "$container" || status="🔴 DOWN"
        
        printf "%-8s %-20s %-35s %s\n" "$port" "$domain" "${secret:0:32}..." "$status"
    done
    log_divider
    echo ""
}

# ==================== УПРАВЛЕНИЕ ПРОКСИ ====================

add_proxy() {
    echo ""
    log_header "➕ Добавление нового прокси"
    
    local port=""
    while true; do
        echo -n "Введите порт (1024-65535): "
        read -r port
        if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
            if [ -n "${PROXIES[$port]}" ]; then
                log_warn "Порт $port уже настроен"
                echo -n "Продолжить с заменой? [y/N]: "
                read -r confirm
                [[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
            fi
            break
        else
            log_error "Неверный формат порта"
        fi
    done
    
    local domain=""
    echo ""
    echo "🎭 Выберите домен для маскировки:"
    echo "   1) 1c.ru       (официальный сайт 1С)"
    echo "   2) vk.com      (ВКонтакте)"
    echo "   3) yandex.ru   (Яндекс)"
    echo "   4) mail.ru     (Mail.ru) ← Выбрано"
    echo "   5) ok.ru       (Одноклассники)"
    echo "   6) 🔧 Ввести свой"
    echo ""
    
    while true; do
        echo -n "Ваш выбор (1-6) [4]: "
        read -r choice
        choice="${choice:-4}"
        case "$choice" in
            1) domain="1c.ru"; break ;;
            2) domain="vk.com"; break ;;
            3) domain="yandex.ru"; break ;;
            4|"") domain="mail.ru"; break ;;
            5) domain="ok.ru"; break ;;
            6)
                echo -n "Введите домен: "
                read -r domain
                if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    break
                else
                    log_error "Неверный формат домена"
                fi
                ;;
            *) log_warn "Введите 1-6" ;;
        esac
    done
    
    local secret=$(generate_secret)
    log_info "Сгенерирован секрет: $secret"
    
    echo ""
    echo -e "${YELLOW}Параметры:${NC}"
    echo "  Порт:     $port"
    echo "  Домен:    $domain"
    echo "  Секрет:   $secret"
    echo "  IP:       $SERVER_IP"
    echo ""
    echo -n "Запустить прокси? [Y/n]: "
    read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0
    
    local container="mtproto"
    [[ "$port" != "443" ]] && container="${container}-${port}"
    
    log_info "Запуск контейнера $container..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d \
        --name="$container" \
        --restart=always \
        -p "$port":443 \
        -e "SECRET=$secret" \
        -e "FAKE_TLS_DOMAIN=$domain" \
        "$DOCKER_IMAGE" >/dev/null
    
    sleep 2
    
    if is_running "$container"; then
        log_success "✅ Прокси запущен"
        open_firewall_port "$port" "Telegram Proxy - $domain"
        PROXIES["$port"]="${domain}:${secret}"
        save_config
        regenerate_functions
        
        echo ""
        log_header "🔗 Новая ссылка"
        printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
        echo ""
        return 0
    else
        log_error "❌ Ошибка запуска контейнера"
        return 1
    fi
}

# 🔥 ИСПРАВЛЕНО: правильное удаление порта
remove_proxy() {
    echo ""
    log_header "🗑️  Удаление прокси"
    
    show_proxy_list || return 0
    
    # 🔥 КРИТИЧНО: уникальное имя переменной!
    local port_to_remove=""
    echo -n "Введите порт для удаления: "
    read -r port_to_remove
    
    if [ -z "${PROXIES[$port_to_remove]}" ]; then
        log_error "Порт $port_to_remove не найден в конфигурации"
        return 1
    fi
    
    local container="mtproto"
    [[ "$port_to_remove" != "443" ]] && container="${container}-${port_to_remove}"
    
    echo -n "Удалить прокси на порту $port_to_remove? [y/N]: "
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    
    if is_running "$container"; then
        docker stop "$container" >/dev/null
        docker rm "$container" >/dev/null
        log_success "Контейнер $container удалён"
    fi
    
    # 🔥 КРИТИЧНО: сохраняем порт ДО вызова функций!
    local deleted_port="$port_to_remove"
    
    unset "PROXIES[$port_to_remove]"
    save_config
    regenerate_functions
    
    # 🔥 КРИТИЧНО: используем deleted_port, а не $port!
    if command -v ufw &>/dev/null; then
        echo -n "Закрыть порт $deleted_port в фаерволе? [y/N]: "
        read -r fw_confirm
        if [[ "$fw_confirm" =~ ^[Yy]$ ]]; then
            ufw delete allow "$deleted_port"/tcp >/dev/null 2>&1 || true
            log_info "Порт $deleted_port закрыт в фаерволе"
        fi
    fi
    
    log_success "✅ Прокси на порту $deleted_port удалён"
}

update_domain() {
    echo ""
    log_header "🔄 Обновление домена маскировки"
    
    show_proxy_list || return 0
    
    local port=""
    echo -n "Введите порт для обновления домена: "
    read -r port
    
    if [ -z "${PROXIES[$port]}" ]; then
        log_error "Порт $port не найден"
        return 1
    fi
    
    local current_domain="${PROXIES[$port]%%:*}"
    local secret="${PROXIES[$port]#*:}"
    
    echo "Текущий домен: $current_domain"
    echo ""
    echo "🎭 Выберите новый домен:"
    echo "   1) 1c.ru   2) vk.com   3) yandex.ru   4) mail.ru   5) ok.ru   6) 🔧 Свой"
    echo ""
    
    local domain=""
    while true; do
        echo -n "Ваш выбор (1-6): "
        read -r choice
        case "$choice" in
            1) domain="1c.ru"; break ;;
            2) domain="vk.com"; break ;;
            3) domain="yandex.ru"; break ;;
            4) domain="mail.ru"; break ;;
            5) domain="ok.ru"; break ;;
            6)
                echo -n "Введите домен: "
                read -r domain
                [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && break
                log_error "Неверный формат"
                ;;
            *) log_warn "Введите 1-6" ;;
        esac
    done
    
    echo -n "Обновить домен для порта $port? [y/N]: "
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    
    local container="mtproto"
    [[ "$port" != "443" ]] && container="${container}-${port}"
    
    log_info "Перезапуск $container с доменом $domain..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d \
        --name="$container" \
        --restart=always \
        -p "$port":443 \
        -e "SECRET=$secret" \
        -e "FAKE_TLS_DOMAIN=$domain" \
        "$DOCKER_IMAGE" >/dev/null
    
    sleep 2
    
    if is_running "$container"; then
        PROXIES["$port"]="${domain}:${secret}"
        save_config
        regenerate_functions
        log_success "✅ Домен обновлён"
        
        echo ""
        printf "🔗 Обновлённая ссылка:\n"
        printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
        echo ""
    else
        log_error "❌ Ошибка перезапуска"
        return 1
    fi
}

# ==================== ГЕНЕРАЦИЯ ФУНКЦИЙ ====================

regenerate_functions() {
    log_info "Генерация функций bash..."
    
    # 🔥 КРИТИЧНО: все переменные локальные!
    local port=""
    local container=""
    
    cat > "$BASHRC_PROXY" << EOF
# MTProto Proxy Functions - Auto-generated
# Server: $SERVER_IP | Generated: \$(date)

PROXY_IP="$SERVER_IP"

EOF
    
    for port in "${!PROXIES[@]}"; do
        container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
        
        cat >> "$BASHRC_PROXY" << EOF
link${port}() {
    local s=\$(docker inspect $container --format='{{range .Config.Env}}{{if hasPrefix . "SECRET="}}{{trimPrefix "SECRET=" .}}{{end}}{{end}}' 2>/dev/null)
    [ -n "\$s" ] && printf "tg://proxy?server=%s&port=${port}&secret=%s\n" "\$PROXY_IP" "\$s" || echo "[ERR] ${port}"
}

EOF
    done
    
    local ports_sorted=$(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n | tr '\n' ' ')
    
    cat >> "$BASHRC_PROXY" << EOF
links() {
    echo ""
    echo "=== 📡 MTProto Proxy Links ==="
    echo "Server: \$PROXY_IP"
    echo ""
EOF
    
    for port in $ports_sorted; do
        cat >> "$BASHRC_PROXY" << EOF
    printf "%s: " "$port"; link${port}; echo ""
EOF
    done
    
    cat >> "$BASHRC_PROXY" << 'EOF'
    echo ""
}

# Алиасы управления
alias proxy-status='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | grep mtproto || echo "Нет прокси"'
EOF
    
    for port in "${!PROXIES[@]}"; do
        container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
        echo "alias proxy-logs${port}='docker logs --tail 30 $container 2>/dev/null'" >> "$BASHRC_PROXY"
        echo "alias proxy-restart${port}='docker restart $container 2>/dev/null && echo \"🔄 Перезапущено\"'" >> "$BASHRC_PROXY"
    done
    
    if ! grep -q "bashrc_proxy" ~/.bashrc 2>/dev/null; then
        echo "" >> ~/.bashrc
        echo "# MTProto Proxy Functions" >> ~/.bashrc
        echo "source $BASHRC_PROXY 2>/dev/null" >> ~/.bashrc
    fi
    
    source "$BASHRC_PROXY" 2>/dev/null || true
    log_success "Функции обновлены ✅"
}

# ==================== КОНФИГУРАЦИЯ ====================

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    {
        echo "# MTProto Proxy Configuration"
        echo "# Generated: $(date)"
        echo "# Version: $SCRIPT_VERSION"
        echo "server_ip=$SERVER_IP"
        for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
            echo "port_${port}=${PROXIES[$port]}"
        done
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            if [[ "$key" == "port_"* ]]; then
                local port="${key#port_}"
                PROXIES["$port"]="$value"
            elif [[ "$key" == "server_ip" ]]; then
                SERVER_IP="$value"
            fi
        done < "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# ==================== ВЫВОД ССЫЛОК ====================

show_all_links() {
    echo ""
    log_header "🔗 Рабочие ссылки"
    
    if [ ${#PROXIES[@]} -eq 0 ]; then
        log_warn "Нет настроенных прокси"
        return 1
    fi
    
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}"
        local domain="${value%%:*}"
        local secret="${value#*:}"
        local container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
        local status=""
        is_running "$container" && status=" 🟢" || status=" 🔴"
        
        echo -e "${CYAN}📌 Порт $port${NC} (маскировка: $domain)$status"
        printf "   tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
        echo ""
    done
    
    local file="$HOME/mtproto-links.txt"
    {
        echo "# MTProto Proxy Links - Generated: $(date)"
        echo "# Server: $SERVER_IP"
        echo ""
        for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
            local value="${PROXIES[$port]}"
            local secret="${value#*:}"
            echo "tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"
        done
    } > "$file"
    chmod 644 "$file"
    log_info "Ссылки сохранены в: $file"
    echo ""
}

# ==================== ГЛАВНОЕ МЕНЮ ====================

main_menu() {
    while true; do
        echo ""
        log_header "🚀 MTProto Proxy Manager v$SCRIPT_VERSION"
        echo "Сервер: $SERVER_IP"
        echo ""
        
        local count=$(scan_existing_proxies)
        echo "Найдено прокси: $count"
        echo ""
        
        echo "🔧 Выберите действие:"
        echo "   1) 📋 Показать список прокси"
        echo "   2) ➕ Добавить новый прокси"
        echo "   3) 🗑️  Удалить прокси"
        echo "   4) 🔄 Обновить домен маскировки"
        echo "   5) 🔗 Показать все ссылки"
        echo "   6) 🔄 Обновить функции bash"
        echo "   7) ❌ Выход"
        echo ""
        
        echo -n "Ваш выбор (1-7): "
        read -r choice
        
        case "$choice" in
            1) show_proxy_list ;;
            2) add_proxy ;;
            3) remove_proxy ;;
            4) update_domain ;;
            5) show_all_links ;;
            6) regenerate_functions ;;
            7|*) log_info "Выход"; exit 0 ;;
            *) log_warn "Неверный выбор" ;;
        esac
        
        echo ""
        echo -n "Нажмите Enter для продолжения..."
        read -r
    done
}

# ==================== CLI РЕЖИМ ====================

cli_add() {
    local port=$1 domain=$2 secret=$3
    [[ -z "$port" || -z "$domain" ]] && { log_error "Использование: $0 add <port> <domain> [secret]"; exit 1; }
    secret="${secret:-$(generate_secret)}"
    
    local container="mtproto"
    [[ "$port" != "443" ]] && container="${container}-${port}"
    
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    
    sleep 2
    is_running "$container" || { log_error "Ошибка запуска"; exit 1; }
    
    open_firewall_port "$port" "Telegram Proxy - $domain"
    PROXIES["$port"]="${domain}:${secret}"
    save_config
    regenerate_functions
    
    printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
}

cli_remove() {
    local port=$1
    [[ -z "$port" ]] && { log_error "Использование: $0 remove <port>"; exit 1; }
    
    local container="mtproto"
    [[ "$port" != "443" ]] && container="${container}-${port}"
    
    docker rm -f "$container" >/dev/null 2>&1 || true
    unset "PROXIES[$port]"
    save_config
    regenerate_functions
    close_firewall_port "$port"
    
    log_success "Прокси на порту $port удалён"
}

cli_links() {
    scan_existing_proxies >/dev/null
    show_all_links
}

# ==================== 🔥 НОВЫЕ ФУНКЦИИ ====================

# Проверка установки
check_installation_status() {
    local has_config=false
    local has_containers=false
    
    [ -f "$CONFIG_FILE" ] && has_config=true
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^mtproto" && has_containers=true
    
    if [ "$has_config" = true ] || [ "$has_containers" = true ]; then
        return 0  # ✅ Установлено
    else
        return 1  # ❌ Не установлено
    fi
}

# Быстрая установка (первый запуск)
quick_install() {
    log_header "🚀 Первая установка MTProto Proxy"
    echo ""
    echo "Добро пожаловать! Давайте настроим ваш первый прокси."
    echo ""
    
    local port="" domain="" secret=""
    
    while [ -z "$port" ]; do
        echo -n "Введите порт для прокси (1024-65535) [443]: "
        read -r port
        port="${port:-443}"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
            log_error "Неверный формат порта"
            port=""
        fi
    done
    
    echo ""
    echo "🎭 Выберите домен для маскировки:"
    echo "   1) 1c.ru   2) vk.com   3) yandex.ru   4) mail.ru   5) ok.ru"
    echo -n "Ваш выбор [4]: "
    read -r choice
    case "${choice:-4}" in
        1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";;
        4|"") domain="mail.ru";; 5) domain="ok.ru";;
        *) domain="mail.ru";;
    esac
    
    secret=$(generate_secret)
    
    echo ""
    echo -e "${YELLOW}Параметры:${NC}"
    echo "  Порт:     $port"
    echo "  Домен:    $domain"
    echo "  Секрет:   $secret"
    echo "  IP:       $SERVER_IP"
    echo ""
    echo -n "Продолжить установку? [Y/n]: "
    read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "Установка отменена"; exit 0; }
    
    local container="mtproto"
    [[ "$port" != "443" ]] && container="${container}-${port}"
    
    log_info "Запуск контейнера $container..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d \
        --name="$container" \
        --restart=always \
        -p "$port":443 \
        -e "SECRET=$secret" \
        -e "FAKE_TLS_DOMAIN=$domain" \
        "$DOCKER_IMAGE" >/dev/null
    
    sleep 3
    
    if is_running "$container"; then
        log_success "✅ Прокси запущен"
        open_firewall_port "$port" "Telegram Proxy - $domain"
        PROXIES["$port"]="${domain}:${secret}"
        save_config
        regenerate_functions
        
        echo ""
        log_header "🔗 Ваша ссылка"
        printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
        echo ""
        
        log_success "🎉 Установка завершена!"
        echo ""
        echo "📋 Полезные команды:"
        echo "   sudo mtproto-manager          — главное меню"
        echo "   sudo mtproto-manager links    — показать ссылки"
        echo "   sudo mtproto-manager add      — добавить порт"
        echo ""
        
        return 0
    else
        log_error "❌ Ошибка запуска контейнера"
        return 1
    fi
}

# ==================== 🔥 ОБНОВЛЁННЫЙ ЗАПУСК ====================

main() {
    check_root
    check_docker
    check_ufw
    
    # 🔥 ПРОВЕРКА: установлен или нет?
    if check_installation_status; then
        # ✅ Уже установлен — показываем данные и меню
        log_info "Обнаружена существующая установка"
        scan_existing_proxies >/dev/null
        show_proxy_list
        main_menu
    else
        # ❌ Не установлен — запускаем установку
        log_warn "MTProto Proxy не найден"
        echo ""
        echo "Хотите выполнить установку? [Y/n]"
        read -r confirm
        if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
            quick_install
            if [ $? -eq 0 ]; then
                echo -n "Перейти в главное меню? [Y/n]: "
                read -r menu_confirm
                [[ ! "$menu_confirm" =~ ^[Nn]$ ]] && main_menu
            fi
        else
            log_info "Выход"
            exit 0
        fi
    fi
}

main "$@"
