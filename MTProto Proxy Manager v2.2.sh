#!/bin/bash
#
# 🚀 MTProto Proxy Manager v2.2
# Интеграция: gotelegram UI + mtproto-manager backend
# Фичи: QR-коды, 20+ доменов, очистка экрана, веб-панель
#

set -e

# ==================== КОНФИГУРАЦИЯ ====================
readonly SCRIPT_VERSION="2.2"
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
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# Ассоциативный массив
declare -A PROXIES

# ==================== ЛОГИРОВАНИЕ ====================
log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1"; }
log_error()   { echo -e "${RED}[❌]${NC} $1"; }
log_header()  { echo -e "\n${GREEN}╔════════════════════════════════════╗${NC}\n${GREEN}║${NC} $1 ${GREEN}║${NC}\n${GREEN}╚════════════════════════════════════╝${NC}\n"; }
log_divider() { echo -e "${CYAN}────────────────────────────────────────${NC}"; }

# ==================== ПРОВЕРКИ ====================
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

# 🔥 НОВОЕ: Проверка и установка qrencode
check_qrencode() {
    if ! command -v qrencode &>/dev/null; then
        log_info "Установка qrencode для QR-кодов..."
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y qrencode >/dev/null 2>&1 || yum install -y qrencode >/dev/null 2>&1 || true
        if command -v qrencode &>/dev/null; then
            log_success "qrencode установлен"
        else
            log_warn "qrencode не установлен, QR-коды будут недоступны"
        fi
    fi
}

# ==================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ====================
get_secret() {
    local container="$1"
    docker inspect "$container" --format='{{range .Config.Env}}{{if hasPrefix . "SECRET="}}{{trimPrefix "SECRET=" .}}{{end}}{{end}}' 2>/dev/null | head -1 || \
    docker inspect "$container" 2>/dev/null | grep -oE "SECRET=[0-9a-f]+" | head -1 | cut -d= -f2
}

get_domain() {
    local container="$1"
    docker inspect "$container" --format='{{range .Config.Env}}{{if hasPrefix . "FAKE_TLS_DOMAIN="}}{{trimPrefix "FAKE_TLS_DOMAIN=" .}}{{end}}{{end}}' 2>/dev/null | head -1
}

is_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"
}

generate_secret() {
    openssl rand -hex 16
}

open_firewall_port() {
    local port="$1" comment="${2:-Telegram Proxy}"
    if command -v ufw &>/dev/null; then
        ufw allow "$port"/tcp comment "$comment" >/dev/null 2>&1 || ufw allow "$port"/tcp >/dev/null 2>&1 || true
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
    local port="$1"
    if command -v ufw &>/dev/null; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 && log_info "Порт $port закрыт в фаерволе"
    fi
}

get_container_name() {
    local port="$1"
    [[ "$port" == "443" ]] && echo "mtproto" || echo "mtproto-${port}"
}

# 🔥 НОВОЕ: Генерация и отображение QR-кода
show_qr_code() {
    local link="$1"
    if command -v qrencode &>/dev/null; then
        echo ""
        log_header "📱 QR-код для подключения"
        qrencode -t ANSIUTF8 "$link"
        echo ""
    fi
}

# ==================== СКАНИРОВАНИЕ ====================
scan_existing_proxies() {
    log_info "Сканирование прокси..."
    PROXIES=()
    local found=0
    for container in $(docker ps --format '{{.Names}}' 2>/dev/null | grep "^mtproto"); do
        local port=""
        [[ "$container" == "mtproto" ]] && port="443"
        [[ "$container" =~ ^mtproto-([0-9]+)$ ]] && port="${BASH_REMATCH[1]}"
        if [ -n "$port" ]; then
            local secret=$(get_secret "$container")
            local domain=$(get_domain "$container")
            [ -n "$secret" ] && { PROXIES["$port"]="${domain:-unknown}:${secret}"; ((found++)); }
        fi
    done
    [ "$found" -eq 0 ] && [ -f "$CONFIG_FILE" ] && while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        [[ "$key" == "port_"* ]] && PROXIES["${key#port_}"]="$value"
    done < "$CONFIG_FILE"
    echo "$found"
}

show_proxy_list() {
    clear  # 🔥 Очистка экрана
    log_header "📋 Настроенные прокси"
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Прокси не найдены"; return 1; }
    log_divider
    printf "${CYAN}%-8s %-20s %-35s %s${NC}\n" "ПОРТ" "ДОМЕН" "СЕКРЕТ" "СТАТУС"
    log_divider
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo "🟢 UP" || echo "🔴 DOWN")
        printf "%-8s %-20s %-35s %s\n" "$port" "$domain" "${secret:0:32}..." "$status"
    done
    log_divider
}

# ==================== ДОБАВЛЕНИЕ ПРОКСИ (ОБНОВЛЕНО) ====================
add_proxy() {
    clear  # 🔥 Очистка экрана
    
    log_header "➕ Добавление нового прокси"
    
    # 🔥 НОВОЕ: Большой список доменов (как в gotelegram)
    local domains=(
        "google.com" "wikipedia.org" "habr.com" "github.com"
        "coursera.org" "udemy.com" "medium.com" "stackoverflow.com"
        "bbc.com" "cnn.com" "reuters.com" "nytimes.com"
        "lenta.ru" "rbc.ru" "ria.ru" "kommersant.ru"
        "stepik.org" "duolingo.com" "khanacademy.org" "ted.com"
        "1c.ru" "vk.com" "yandex.ru" "mail.ru" "ok.ru"
    )
    
    # Ввод порта
    local port=""
    while [ -z "$port" ]; do
        echo -n "Введите порт (1024-65535): "
        read -r port
        [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]] && { log_error "Неверно"; port=""; }
        [ -n "${PROXIES[$port]}" ] && { log_warn "Занят"; port=""; }
    done
    
    # 🔥 НОВОЕ: Красивый выбор домена (2 колонки, как в gotelegram)
    echo ""
    echo -e "${CYAN}=== Выберите домен для маскировки (Fake TLS) ===${NC}"
    for i in "${!domains[@]}"; do
        printf "${YELLOW}%2d)${NC} %-22s " "$((i+1))" "${domains[$i]}"
        [[ $(( (i+1) % 2 )) -eq 0 ]] && echo ""
    done
    echo ""
    
    local domain=""
    while [ -z "$domain" ]; do
        echo -n "Ваш выбор [1-${#domains[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#domains[@]}" ]; then
            domain="${domains[$((choice-1))]}"
        elif [[ "$choice" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            domain="$choice"
        else
            log_error "Введите номер или домен"
        fi
    done
    
    # Генерация секрета
    local secret=$(generate_secret)
    log_info "Сгенерирован секрет: $secret"
    
    # Подтверждение
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
    
    # Запуск контейнера
    local container=$(get_container_name "$port")
    log_info "Запуск контейнера $container..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    
    if is_running "$container"; then
        log_success "✅ Прокси запущен"
        open_firewall_port "$port" "Telegram Proxy - $domain"
        PROXIES["$port"]="${domain}:${secret}"
        save_config
        regenerate_functions
        
        # 🔥 НОВОЕ: Показываем ссылку + QR-код
        local link="tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"
        echo ""
        log_header "🔗 Новая ссылка"
        printf "${BLUE}%s${NC}\n" "$link"
        show_qr_code "$link"  # 🔥 QR-код!
        
        log_success "🎉 Готово!"
        echo ""
        echo "📋 Полезные команды:"
        echo "   sudo mtproto-manager          — главное меню"
        echo "   sudo mtproto-manager links    — показать ссылки"
        echo "   sudo mtproto-manager web      — веб-панель"
        echo ""
        echo -n "Нажмите Enter для продолжения..."
        read -r
        return 0
    else
        log_error "❌ Ошибка запуска контейнера"
        return 1
    fi
}

# ==================== УДАЛЕНИЕ ПРОКСИ ====================
remove_proxy() {
    clear  # 🔥 Очистка экрана
    log_header "🗑️ Удаление прокси"
    show_proxy_list || return 0
    
    local port_to_remove=""
    echo -n "Порт для удаления: "
    read -r port_to_remove
    [ -z "${PROXIES[$port_to_remove]}" ] && { log_error "Не найден"; return 1; }
    
    echo -n "Удалить порт $port_to_remove? [y/N]: "
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    
    local container=$(get_container_name "$port_to_remove")
    is_running "$container" && { docker stop "$container" >/dev/null; docker rm "$container" >/dev/null; }
    
    local deleted_port="$port_to_remove"
    unset "PROXIES[$port_to_remove]"
    save_config
    regenerate_functions
    
    echo -n "Закрыть порт $deleted_port в фаерволе? [y/N]: "
    read -r fw_confirm
    [[ "$fw_confirm" =~ ^[Yy]$ ]] && close_firewall_port "$deleted_port"
    
    log_success "Порт $deleted_port удалён"
    echo -n "Нажмите Enter..."
    read -r
}

# ==================== ОБНОВЛЕНИЕ ДОМЕНА ====================
update_domain() {
    clear  # 🔥 Очистка экрана
    log_header "🔄 Обновление домена"
    show_proxy_list || return 0
    
    local port=""
    echo -n "Порт: "
    read -r port
    [ -z "${PROXIES[$port]}" ] && { log_error "Не найден"; return 1; }
    
    local secret="${PROXIES[$port]#*:}"
    
    # 🔥 Большой список доменов
    local domains=("1c.ru" "vk.com" "yandex.ru" "mail.ru" "ok.ru" "google.com" "github.com" "wikipedia.org")
    echo ""
    echo -e "${CYAN}=== Выберите новый домен ===${NC}"
    for i in "${!domains[@]}"; do
        printf "${YELLOW}%d)${NC} %-15s " "$((i+1))" "${domains[$i]}"
        [[ $(( (i+1) % 4 )) -eq 0 ]] && echo ""
    done
    echo ""
    
    local domain=""
    while [ -z "$domain" ]; do
        echo -n "Ваш выбор: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#domains[@]}" ]; then
            domain="${domains[$((choice-1))]}"
        elif [[ "$choice" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            domain="$choice"
        else
            log_error "Введите номер или домен"
        fi
    done
    
    echo -n "Обновить? [y/N]: "
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    
    is_running "$container" && { PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions; log_success "Обновлено"; } || log_error "Ошибка"
    echo -n "Нажмите Enter..."
    read -r
}

# ==================== ГЕНЕРАЦИЯ ФУНКЦИЙ ====================
regenerate_functions() {
    log_info "Генерация функций..."
    cat > "$BASHRC_PROXY" << EOF
#!/bin/bash
PROXY_IP="$SERVER_IP"
EOF
    for port in "${!PROXIES[@]}"; do
        local container=$(get_container_name "$port")
        cat >> "$BASHRC_PROXY" << EOF
link${port}(){ local s=\$(docker inspect $container --format='{{range .Config.Env}}{{if hasPrefix . "SECRET="}}{{trimPrefix "SECRET=" .}}{{end}}{{end}}' 2>/dev/null); [ -n "\$s" ] && printf "tg://proxy?server=%s&port=${port}&secret=%s\n" "\$PROXY_IP" "\$s" || echo "[ERR] ${port}"; }
EOF
    done
    cat >> "$BASHRC_PROXY" << 'EOF'
links(){ echo ""; echo "=== MTProto Links ==="; echo "Server: $PROXY_IP"; echo "";
EOF
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        echo "    printf \"%s: \" \"$port\"; link${port}; echo \"\"" >> "$BASHRC_PROXY"
    done
    cat >> "$BASHRC_PROXY" << 'EOF'
echo ""; }
alias proxy-status='docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep mtproto'
EOF
    for port in "${!PROXIES[@]}"; do
        local container=$(get_container_name "$port")
        echo "alias proxy-logs${port}='docker logs --tail 30 $container 2>/dev/null'" >> "$BASHRC_PROXY"
    done
    grep -q "bashrc_proxy" ~/.bashrc 2>/dev/null || echo -e "\n# MTProto\nsource $BASHRC_PROXY" >> ~/.bashrc
    source "$BASHRC_PROXY" 2>/dev/null || true
    log_success "Функции обновлены"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    { echo "# MTProto Config"; echo "server_ip=$SERVER_IP"; for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do echo "port_${port}=${PROXIES[$port]}"; done; } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

show_all_links() {
    clear  # 🔥 Очистка экрана
    log_header "🔗 Ссылки"
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Нет прокси"; return 1; }
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo " 🟢" || echo " 🔴")
        echo -e "${CYAN}Порт $port${NC} ($domain)$status"
        printf "   tg://proxy?server=%s&port=%s&secret=%s\n\n" "$SERVER_IP" "$port" "$secret"
    done
    { echo "# MTProto Links - $(date)"; for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do echo "tg://proxy?server=$SERVER_IP&port=$port&secret=${PROXIES[$port]#*:}"; done; } > "$HOME/mtproto-links.txt"
    log_info "Сохранено: $HOME/mtproto-links.txt"
    echo -n "Нажмите Enter..."
    read -r
}

# ==================== ВЕБ-ПАНЕЛЬ ====================
generate_web_panel() {
    local output="/tmp/mtproto-mini.html"
    local active=0 total=${#PROXIES[@]}
    for port in "${!PROXIES[@]}"; do
        local c=$(get_container_name "$port")
        is_running "$c" && ((active++))
    done
    local json="[" first=true
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local v="${PROXIES[$port]}" d="${v%%:*}" s="${v#*:}"
        local c=$(get_container_name "$port")
        local st=$(is_running "$c" && echo up || echo down)
        $first || json+=","; first=false
        json+="{\"p\":$port,\"d\":\"$d\",\"s\":\"$s\",\"st\":\"$st\"}"
    done
    json+="]"
    
    cat > "$output" << EOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>MTProto</title><style>
body{font-family:sans-serif;background:#0a0e1a;color:#e2e8f0;padding:20px}
.container{max-width:900px;margin:0 auto}.header{text-align:center;margin-bottom:25px}
h1{color:#a5b4fc}table{width:100%;border-collapse:collapse;background:#141b2b;border-radius:8px}
th,td{padding:12px;border-bottom:1px solid #2d3748}.secret{font-family:monospace;color:#a5b4fc}
.status-up{color:#10b981}.status-up::before{content:'🟢 '}.status-down{color:#ef4444}.status-down::before{content:'🔴 '}
.btn{background:none;border:1px solid #2d3748;color:#8b949e;padding:5px 10px;border-radius:4px;cursor:pointer}
.btn:hover{border-color:#4f6bc4;color:#a5b4fc}
</style></head><body><div class="container">
<div class="header"><h1>🚀 MTProto Proxy</h1><p>Server: $SERVER_IP</p><p>Active: <b>$active</b> / Total: <b>$total</b></p></div>
<table><thead><tr><th>Port</th><th>Domain</th><th>Secret</th><th>Status</th><th></th></tr></thead><tbody>
EOF
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local v="${PROXIES[$port]}" d="${v%%:*}" s="${v#*:}"
        local c=$(get_container_name "$port")
        local st=$(is_running "$c" && echo up || echo down)
        local lnk="tg://proxy?server=$SERVER_IP&port=$port&secret=$s"
        echo "<tr><td><b>$port</b></td><td>$d</td><td class=\"secret\">${s:0:8}…${s: -4}</td><td class=\"status-$st\">$([ "$st" = up ] && echo Active || echo Down)</td><td><button class=\"btn\" onclick=\"navigator.clipboard.writeText('$lnk').then(()=>alert('✅'))\">📋</button></td></tr>" >> "$output"
    done
    cat >> "$output" << 'EOF'
</tbody></table><p style="color:#6b7a8f;font-size:12px;margin-top:20px">Auto-refresh: 30s</p>
<script>setTimeout(()=>location.reload(),30000)</script></body></html>
EOF
    echo "$output"
}

cli_web_panel() {
    scan_existing_proxies >/dev/null 2>&1 || true
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Нет прокси"; return 1; }
    local f=$(generate_web_panel)
    log_success "Панель: $f"
    echo ""; echo -e "${YELLOW}Откройте:${NC} file://$f"
    echo -e "${CYAN}Или через веб-сервер:${NC} http://$SERVER_IP:8080/"
}

# ==================== CLI КОМАНДЫ ====================
cli_add() {
    local port="$1" domain="$2" secret="${3:-$(generate_secret)}"
    [[ -z "$port" || -z "$domain" ]] && { log_error "add <port> <domain>"; exit 1; }
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2; is_running "$container" || exit 1
    open_firewall_port "$port"; PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions
    local link="tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"
    printf "%s\n" "$link"
    show_qr_code "$link"
}

cli_remove() {
    local port="$1"
    [[ -z "$port" ]] && { log_error "remove <port>"; exit 1; }
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    unset "PROXIES[$port]"; save_config; regenerate_functions; close_firewall_port "$port"
    log_success "Port $port removed"
}

cli_links() { scan_existing_proxies >/dev/null; show_all_links; }

# ==================== ГЛАВНОЕ МЕНЮ (ОБНОВЛЕНО) ====================
main_menu() {
    while true; do
        clear  # 🔥 Очистка экрана перед каждым показом меню
        log_header "🚀 MTProto Proxy Manager v$SCRIPT_VERSION"
        echo -e "${MAGENTA}Сервер: ${WHITE}$SERVER_IP${NC}"
        echo ""
        local count=$(scan_existing_proxies)
        echo -e "${CYAN}Найдено прокси: ${WHITE}$count${NC}"
        echo ""
        echo -e "${YELLOW}🔧 Выберите действие:${NC}"
        echo -e "   ${GREEN}1)${NC} 📋 Показать список прокси"
        echo -e "   ${GREEN}2)${NC} ➕ Добавить новый прокси"
        echo -e "   ${GREEN}3)${NC} 🗑️  Удалить прокси"
        echo -e "   ${GREEN}4)${NC} 🔄 Обновить домен маскировки"
        echo -e "   ${GREEN}5)${NC} 🔗 Показать все ссылки"
        echo -e "   ${GREEN}6)${NC} 🌐 Веб-панель"
        echo -e "   ${GREEN}7)${NC} ❌ Выход"
        echo ""
        echo -n "Ваш выбор (1-7): "
        read -r choice
        case "$choice" in
            1) show_proxy_list ;;
            2) add_proxy ;;
            3) remove_proxy ;;
            4) update_domain ;;
            5) show_all_links ;;
            6) cli_web_panel ;;
            7|*) log_info "Выход"; exit 0 ;;
            *) log_warn "Неверный выбор" ;;
        esac
    done
}

# ==================== ЗАПУСК ====================
main() {
    check_root
    check_docker
    check_ufw
    check_qrencode  # 🔥 Проверка qrencode
    
    case "${1:-}" in
        add) cli_add "${@:2}" ;;
        remove) cli_remove "${@:2}" ;;
        links) cli_links ;;
        scan) scan_existing_proxies; show_proxy_list ;;
        web) cli_web_panel ;;
        *) main_menu ;;
    esac
}

main "$@"
