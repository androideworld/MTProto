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
        echo "   6) 🌐 Веб-интерфейс (QR-коды)"
        echo "   7) 🔄 Обновить функции bash"
        echo "   8) ❌ Выход"
        echo ""
        
        echo -n "Ваш выбор (1-8): "
        read -r choice
        
        case "$choice" in
            1) show_proxy_list ;;
            2) add_proxy ;;
            3) remove_proxy ;;
            4) update_domain ;;
            5) show_all_links ;;
            6) cli_web ;;
            7) regenerate_functions ;;
            8|*) log_info "Выход"; exit 0 ;;
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

# ==================== ВЕБ-ИНТЕРФЕЙС ====================

# 🔥 Правильное URL-кодирование через Python
urlencode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('''$1'''))" 2>/dev/null
}

# ==================== ВЕБ-ИНТЕРФЕЙС (обновлённый) ====================

generate_html_page() {
    local output_file="/tmp/mtproto-web.html"
    
    # Считаем статистику
    local total_proxies=${#PROXIES[@]}
    local active_count=0
    for port in "${!PROXIES[@]}"; do
        local container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
        is_running "$container" && ((active_count++))
    done
    
    cat > "$output_file" << HTML_HEAD
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MTProto Proxy — Безопасный Telegram</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(145deg, #0B1120 0%, #192132 100%);
            min-height: 100vh;
            padding: 24px;
            position: relative;
            overflow-x: hidden;
        }
        body::before {
            content: '';
            position: fixed;
            width: 200%;
            height: 200%;
            top: -50%;
            left: -50%;
            background: radial-gradient(circle at center, rgba(79, 91, 147, 0.15) 0%, transparent 50%);
            animation: rotate 30s linear infinite;
            z-index: 0;
        }
        @keyframes rotate { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
        .container { max-width: 1000px; margin: 0 auto; position: relative; z-index: 1; }
        .header { text-align: center; margin-bottom: 48px; animation: fadeInDown 0.8s ease; }
        @keyframes fadeInDown { from { opacity: 0; transform: translateY(-30px); } to { opacity: 1; transform: translateY(0); } }
        .badge {
            display: inline-block;
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            color: #A5B4FC;
            padding: 8px 20px;
            border-radius: 100px;
            font-size: 0.9rem;
            font-weight: 500;
            margin-bottom: 20px;
            border: 1px solid rgba(165, 180, 252, 0.3);
        }
        .header h1 {
            font-size: 3.5rem;
            font-weight: 800;
            background: linear-gradient(135deg, #FFFFFF 0%, #A5B4FC 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 16px;
        }
        .header p { color: #94A3B8; font-size: 1.2rem; max-width: 600px; margin: 0 auto; line-height: 1.6; }
        .server-info {
            background: rgba(255, 255, 255, 0.03);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.05);
            border-radius: 100px;
            padding: 12px 24px;
            display: inline-block;
            margin-top: 24px;
            color: #E2E8F0;
            font-size: 1.1rem;
        }
        .server-info strong { color: #A5B4FC; font-weight: 600; }
        .proxy-grid { display: flex; flex-direction: column; gap: 24px; margin-bottom: 40px; }
        .proxy-card {
            background: rgba(30, 41, 59, 0.7);
            backdrop-filter: blur(20px);
            border: 1px solid rgba(255, 255, 255, 0.05);
            border-radius: 32px;
            padding: 28px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
            transition: all 0.4s cubic-bezier(0.4, 0, 0.2, 1);
            animation: fadeInUp 0.6s ease backwards;
            position: relative;
            overflow: hidden;
        }
        .proxy-card:hover { transform: translateY(-4px); border-color: rgba(165, 180, 252, 0.3); }
        @keyframes fadeInUp { from { opacity: 0; transform: translateY(30px); } to { opacity: 1; transform: translateY(0); } }
        .proxy-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; flex-wrap: wrap; gap: 12px; }
        .proxy-title { display: flex; align-items: center; gap: 8px; font-size: 1.5rem; font-weight: 600; color: #F1F5F9; }
        .proxy-title span { background: rgba(165, 180, 252, 0.2); padding: 4px 12px; border-radius: 20px; font-size: 0.9rem; color: #A5B4FC; }
        .proxy-status {
            padding: 6px 16px;
            border-radius: 100px;
            font-size: 0.9rem;
            font-weight: 500;
            display: flex;
            align-items: center;
            gap: 6px;
            background: rgba(16, 185, 129, 0.1);
            color: #10B981;
            border: 1px solid rgba(16, 185, 129, 0.2);
        }
        .proxy-status::before {
            content: '';
            width: 8px;
            height: 8px;
            background: #10B981;
            border-radius: 50%;
            display: inline-block;
            animation: pulse 2s infinite;
        }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
        .proxy-info { background: rgba(15, 23, 42, 0.6); border-radius: 20px; padding: 16px 20px; margin-bottom: 24px; }
        .info-row { display: flex; align-items: center; gap: 12px; color: #CBD5E1; font-size: 1rem; padding: 8px 0; }
        .info-row:not(:last-child) { border-bottom: 1px solid rgba(255, 255, 255, 0.05); }
        .info-label { min-width: 140px; color: #94A3B8; }
        .info-value { color: #F1F5F9; font-weight: 500; }
        .info-value.highlight { color: #A5B4FC; font-family: monospace; }
        .qr-section { display: flex; align-items: center; gap: 24px; margin-bottom: 24px; flex-wrap: wrap; }
        .qr-code { background: white; padding: 12px; border-radius: 20px; box-shadow: 0 20px 40px rgba(0,0,0,0.4); transition: transform 0.3s; flex-shrink: 0; }
        .qr-code:hover { transform: scale(1.05); }
        .qr-code img { width: 120px; height: 120px; display: block; }
        .qr-info { flex: 1; }
        .qr-info p { color: #94A3B8; margin-bottom: 8px; font-size: 0.95rem; }
        .qr-info .tip { background: rgba(165, 180, 252, 0.1); padding: 12px 16px; border-radius: 16px; color: #CBD5E1; font-size: 0.9rem; border-left: 3px solid #A5B4FC; }
        .proxy-link {
            background: rgba(15, 23, 42, 0.8);
            padding: 16px 20px;
            border-radius: 16px;
            font-family: monospace;
            font-size: 0.9rem;
            color: #A5B4FC;
            word-break: break-all;
            border: 1px solid rgba(165, 180, 252, 0.2);
            margin-bottom: 24px;
            transition: all 0.3s;
        }
        .proxy-link:hover { border-color: #A5B4FC; }
        .card-actions { display: flex; gap: 12px; flex-wrap: wrap; }
        .btn {
            padding: 14px 28px;
            border: none;
            border-radius: 16px;
            font-size: 1rem;
            font-weight: 500;
            cursor: pointer;
            text-decoration: none;
            transition: all 0.3s;
            display: inline-flex;
            align-items: center;
            gap: 8px;
            flex: 1;
            justify-content: center;
            min-width: 160px;
        }
        .btn-copy { background: linear-gradient(135deg, #4F5B93, #6366F1); color: white; box-shadow: 0 8px 20px rgba(99,102,241,0.3); }
        .btn-copy:hover { transform: translateY(-2px); box-shadow: 0 12px 30px rgba(99,102,241,0.4); }
        .btn-telegram { background: rgba(255,255,255,0.05); backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.1); color: #E2E8F0; }
        .btn-telegram:hover { background: rgba(255,255,255,0.1); border-color: #A5B4FC; transform: translateY(-2px); }
        .footer { text-align: center; padding: 40px 0 20px; border-top: 1px solid rgba(255,255,255,0.05); margin-top: 40px; }
        .stats { display: flex; justify-content: center; gap: 40px; margin-bottom: 24px; flex-wrap: wrap; }
        .stat-item { text-align: center; }
        .stat-value { font-size: 2rem; font-weight: 700; color: #A5B4FC; line-height: 1; margin-bottom: 8px; }
        .stat-label { color: #64748B; font-size: 0.9rem; text-transform: uppercase; letter-spacing: 1px; }
        .copyright { color: #475569; font-size: 0.9rem; }
        .refresh-info { margin-top: 20px; color: #64748B; font-size: 0.9rem; display: flex; align-items: center; justify-content: center; gap: 8px; }
        .refresh-info::before { content: '↻'; font-size: 1.2rem; animation: spin 2s linear infinite; }
        @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
        @media (max-width: 768px) {
            .header h1 { font-size: 2.5rem; }
            .qr-section { flex-direction: column; align-items: flex-start; }
            .qr-code { align-self: center; }
            .info-row { flex-direction: column; align-items: flex-start; gap: 4px; }
            .info-label { min-width: auto; }
        }
        @media (max-width: 480px) {
            .card-actions { flex-direction: column; }
            .proxy-header { flex-direction: column; align-items: flex-start; }
            .stats { gap: 20px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div class="badge">⚡️ Быстро и безопасно</div>
            <h1>MTProto Proxy</h1>
            <p>Обход блокировок с максимальной скоростью и защитой ваших данных</p>
            <div class="server-info">
                <span>🖥 Сервер: <strong>$SERVER_IP</strong></span>
            </div>
        </div>
        <div class="proxy-grid">
HTML_HEAD

    # Генерация карточек прокси
    local delay=0.1
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}"
        local domain="${value%%:*}"
        local secret="${value#*:}"
        local container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
        local status_text=$(is_running "$container" && echo "Активен" || echo "Неактивен")
        local status_class=$(is_running "$container" && echo "proxy-status" || echo "proxy-status" )
        local link="tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"
        local qr_url="https://api.qrserver.com/v1/create-qr-code/?size=120x120&data=$(echo -n "$link" | sed 's/ /%20/g; s/:/%3A/g; s/?/%3F/g; s/=/\%3D/g; s/&/%26/g')"
        
        cat >> "$output_file" << CARD_END
            <div class="proxy-card" style="animation-delay: ${delay}s">
                <div class="proxy-header">
                    <div class="proxy-title">
                        Порт $port
                        <span>Маскировка</span>
                    </div>
                    <div class="$status_class">$status_text</div>
                </div>
                <div class="proxy-info">
                    <div class="info-row">
                        <span class="info-label">Домен маскировки:</span>
                        <span class="info-value highlight">$domain</span>
                    </div>
                    <div class="info-row">
                        <span class="info-label">Протокол:</span>
                        <span class="info-value">MTProto 2.0</span>
                    </div>
                </div>
                <div class="qr-section">
                    <div class="qr-code">
                        <img src="$qr_url" alt="QR Code для порта $port">
                    </div>
                    <div class="qr-info">
                        <p>📱 Отсканируйте QR-код камерой телефона</p>
                        <div class="tip">💡 Наведите камеру на QR-код и нажмите на ссылку для подключения</div>
                    </div>
                </div>
                <div class="proxy-link" id="link-$port">$link</div>
                <div class="card-actions">
                    <button class="btn btn-copy" onclick="copyLink('$link')">📋 Копировать ссылку</button>
                    <a href="$link" class="btn btn-telegram">✈️ Открыть в Telegram</a>
                </div>
            </div>
CARD_END
        delay=$(echo "$delay + 0.1" | bc)
    done

    cat >> "$output_file" << HTML_FOOT
        </div>
        <div class="footer">
            <div class="stats">
                <div class="stat-item">
                    <div class="stat-value">$total_proxies</div>
                    <div class="stat-label">Всего прокси</div>
                </div>
                <div class="stat-item">
                    <div class="stat-value">$active_count</div>
                    <div class="stat-label">Активных</div>
                </div>
                <div class="stat-item">
                    <div class="stat-value">24/7</div>
                    <div class="stat-label">Поддержка</div>
                </div>
            </div>
            <div class="copyright">
                MTProto Proxy Manager v$SCRIPT_VERSION • Все прокси сервера работают стабильно
            </div>
            <div class="refresh-info">
                Автообновление каждые 30 секунд
            </div>
        </div>
    </div>
    <script>
        function copyLink(text) {
            navigator.clipboard.writeText(text).then(function() {
                const notification = document.createElement('div');
                notification.style.cssText = 'position:fixed;top:20px;right:20px;background:linear-gradient(135deg,#10B981,#059669);color:white;padding:16px 24px;border-radius:16px;font-weight:500;box-shadow:0 10px 40px rgba(16,185,129,0.3);z-index:9999;animation:slideIn 0.3s ease;';
                notification.textContent = '✅ Ссылка скопирована!';
                const style = document.createElement('style');
                style.textContent = '@keyframes slideIn{from{transform:translateX(100%);opacity:0;}to{transform:translateX(0);opacity:1;}}';
                document.head.appendChild(style);
                document.body.appendChild(notification);
                setTimeout(() => { notification.style.animation = 'slideIn 0.3s ease reverse'; setTimeout(() => document.body.removeChild(notification), 300); }, 2000);
            }, function(err) {
                const textarea = document.createElement('textarea');
                textarea.value = text;
                document.body.appendChild(textarea);
                textarea.select();
                document.execCommand('copy');
                document.body.removeChild(textarea);
                alert('✅ Ссылка скопирована!');
            });
        }
        setTimeout(function() { location.reload(); }, 30000);
    </script>
</body>
</html>
HTML_FOOT

    echo "$output_file"
}

web_interface() {
    echo ""
    log_header "🌐 Веб-интерфейс"
    
    local port="${1:-8080}"
    
    if ! command -v python3 &>/dev/null; then
        log_error "Python3 не установлен. Установите: apt install -y python3"
        return 1
    fi
    
    local html_file=$(generate_html_page)
    log_success "HTML-страница сгенерирована: $html_file"
    
    echo ""
    echo -e "${YELLOW}Веб-интерфейс запущен!${NC}"
    echo ""
    echo "📍 Откройте в браузере:"
    echo "   http://$SERVER_IP:$port"
    echo "   http://localhost:$port"
    echo ""
    echo "🔒 Для остановки нажмите: Ctrl+C"
    echo ""
    
    cd /tmp
    python3 -m http.server "$port" --bind "0.0.0.0"
}

cli_web() {
    local port="${1:-8080}"
    scan_existing_proxies >/dev/null
    web_interface "$port"
}

# ==================== CLI ДЛЯ ВЕБА ====================
cli_web() {
    local port="${1:-8080}"
    scan_existing_proxies >/dev/null
    web_interface "$port"
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

# ==================== 🔥 НОВЫЕ ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ====================

# Проверка статуса установки
check_installation_status() {
    local has_config=false
    local has_containers=false
    
    # Проверка конфига
    [ -f "$CONFIG_FILE" ] && has_config=true
    
    # Проверка контейнеров
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
    
    # Порт
    while [ -z "$port" ]; do
        echo -n "Введите порт для прокси (1024-65535) [443]: "
        read -r port
        port="${port:-443}"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
            log_error "Неверный формат порта"
            port=""
        fi
    done
    
    # Домен
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
    
    # Секрет
    secret=$(generate_secret)
    
    # Подтверждение
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
    
    # Запуск контейнера
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

# ==================== 🔥 ОБНОВЛЁННАЯ ФУНКЦИЯ main() ====================

main() {
    check_root
    check_docker
    check_ufw
    
    case "${1:-}" in
        add) cli_add "${@:2}" ;;
        remove) cli_remove "${@:2}" ;;
        links) cli_links ;;
        scan) scan_existing_proxies; show_proxy_list ;;
        web) cli_web "${@:2}" ;;
        *) main_menu ;;
    esac
}

main "$@"
