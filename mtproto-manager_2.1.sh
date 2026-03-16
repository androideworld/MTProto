#!/bin/bash
#
# 🚀 MTProto Proxy Manager v2.1
# Автоматическая установка и управление + Веб-интерфейс
#

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
check_root() { [ "$EUID" -ne 0 ] && { log_error "Запустите от root: sudo $0"; exit 1; }; }

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_info "Установка Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker >/dev/null 2>&1 || true
    fi
}

check_ufw() {
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" || ufw --force enable >/dev/null 2>&1 || true
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

is_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"; }

generate_secret() { openssl rand -hex 16; }

open_firewall_port() {
    local port="$1" comment="${2:-Telegram Proxy}"
    command -v ufw &>/dev/null && { ufw allow "$port"/tcp comment "$comment" >/dev/null 2>&1 || ufw allow "$port"/tcp >/dev/null 2>&1 || true; log_info "Порт $port открыт"; }
}

close_firewall_port() {
    local port="$1"
    command -v ufw &>/dev/null && ufw delete allow "$port"/tcp >/dev/null 2>&1 && log_info "Порт $port закрыт"
}

get_container_name() {
    local port="$1"
    [[ "$port" == "443" ]] && echo "mtproto" || echo "mtproto-${port}"
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

# ==================== УПРАВЛЕНИЕ ====================
add_proxy() {
    log_header "➕ Добавление прокси"
    local port="" domain=""
    while [ -z "$port" ]; do
        echo -n "Порт (1024-65535): "
        read -r port
        [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]] && { log_error "Неверно"; port=""; }
        [ -n "${PROXIES[$port]}" ] && { log_warn "Занят"; port=""; }
    done
    echo "1) 1c.ru  2) vk.com  3) yandex.ru  4) mail.ru  5) ok.ru  6) Свой"
    while [ -z "$domain" ]; do
        echo -n "Домен [4]: "
        read -r choice
        case "${choice:-4}" in 1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";; 4|"") domain="mail.ru";; 5) domain="ok.ru";; 6) echo -n "Домен: "; read -r domain; [[ ! "$domain" =~ \. ]] && domain="";; esac
    done
    local secret=$(generate_secret)
    echo -n "Запустить? [Y/n]: "
    read -r confirm; [[ "$confirm" =~ ^[Nn]$ ]] && return 0
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    is_running "$container" && { log_success "Запущен"; open_firewall_port "$port"; PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions; printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"; } || log_error "Ошибка"
}

# 🔥 ИСПРАВЛЕНО: правильное удаление порта
remove_proxy() {
    log_header "🗑️ Удаление прокси"
    show_proxy_list || return 0
    local port_to_remove=""
    echo -n "Порт для удаления: "
    read -r port_to_remove
    [ -z "${PROXIES[$port_to_remove]}" ] && { log_error "Не найден"; return 1; }
    echo -n "Удалить порт $port_to_remove? [y/N]: "
    read -r confirm; [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    local container=$(get_container_name "$port_to_remove")
    is_running "$container" && { docker stop "$container" >/dev/null; docker rm "$container" >/dev/null; }
    # 🔥 КРИТИЧНО: сохраняем порт ДО вызова функций!
    local deleted_port="$port_to_remove"
    unset "PROXIES[$port_to_remove]"
    save_config
    regenerate_functions
    echo -n "Закрыть порт $deleted_port в фаерволе? [y/N]: "
    read -r fw_confirm; [[ "$fw_confirm" =~ ^[Yy]$ ]] && close_firewall_port "$deleted_port"
    log_success "Порт $deleted_port удалён"
}

update_domain() {
    log_header "🔄 Обновление домена"
    show_proxy_list || return 0
    local port=""
    echo -n "Порт: "
    read -r port
    [ -z "${PROXIES[$port]}" ] && { log_error "Не найден"; return 1; }
    local secret="${PROXIES[$port]#*:}"
    echo "1) 1c.ru  2) vk.com  3) yandex.ru  4) mail.ru  5) ok.ru  6) Свой"
    echo -n "Домен [4]: "
    read -r choice
    case "${choice:-4}" in 1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";; 4|"") domain="mail.ru";; 5) domain="ok.ru";; 6) echo -n "Домен: "; read -r domain;; esac
    echo -n "Обновить? [y/N]: "
    read -r confirm; [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    is_running "$container" && { PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions; log_success "Обновлено"; } || log_error "Ошибка"
}

# ==================== ГЕНЕРАЦИЯ ФУНКЦИЙ ====================
regenerate_functions() {
    log_info "Генерация функций..."
    local port="" container=""
    cat > "$BASHRC_PROXY" << EOF
#!/bin/bash
PROXY_IP="$SERVER_IP"
EOF
    for port in "${!PROXIES[@]}"; do
        container=$(get_container_name "$port")
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
        container=$(get_container_name "$port")
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
}



# ==================== МЕНЮ И ЗАПУСК ====================

main_menu() {
    while true; do
        log_header "🚀 MTProto Proxy Manager v$SCRIPT_VERSION"
        echo "Сервер: $SERVER_IP"; echo ""
        local count=$(scan_existing_proxies)
        echo "Найдено прокси: $count"; echo ""
        echo "🔧 Выберите действие:"
        echo "   1) 📋 Показать список прокси"
        echo "   2) ➕ Добавить новый прокси"
        echo "   3) 🗑️  Удалить прокси"
        echo "   4) 🔄 Обновить домен маскировки"
        echo "   5) 🔗 Показать все ссылки"
        echo "   6) 🌐 Веб-интерфейс (QR-коды)"
        echo "   7) 🌐 Веб-панель (статическая)"  # ← НОВОЕ
        echo "   8) 🔄 Обновить функции bash"
        echo "   0) ❌ Выход"                      # ← Измените номер     
        echo -n "Ваш выбор (1-8): "
        read -r choice       
        case "$choice" in
            1) show_proxy_list ;; 2) add_proxy ;; 3) remove_proxy ;; 4) update_domain ;;
            5) show_all_links ;; 6) cli_web ;; 7) cli_web_panel ;; 8|*) log_info "Выход"; exit 0 ;;
            *) log_warn "Неверный выбор" ;;
        esac
        echo ""; echo -n "Нажмите Enter для продолжения..."; read -r
    done
}

check_installation_status() {
    local has_config=false has_containers=false
    [ -f "$CONFIG_FILE" ] && has_config=true
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^mtproto" && has_containers=true
    [ "$has_config" = true ] || [ "$has_containers" = true ]
}

quick_install() {
    log_header "🚀 Первая установка MTProto Proxy"
    echo ""; echo "Добро пожаловать! Давайте настроим ваш первый прокси."; echo ""
    local port="" domain="" secret=""
    while [ -z "$port" ]; do
        echo -n "Введите порт для прокси (1024-65535) [443]: "
        read -r port; port="${port:-443}"
        [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]] && { log_error "Неверный формат порта"; port=""; }
    done
    echo ""; echo "🎭 Выберите домен для маскировки:"; echo "   1) 1c.ru   2) vk.com   3) yandex.ru   4) mail.ru   5) ok.ru"
    echo -n "Ваш выбор [4]: "; read -r choice
    case "${choice:-4}" in 1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";; 4|"") domain="mail.ru";; 5) domain="ok.ru";; *) domain="mail.ru";; esac
    secret=$(generate_secret)
    echo ""; echo -e "${YELLOW}Параметры:${NC}"; echo "  Порт:     $port"; echo "  Домен:    $domain"; echo "  Секрет:   $secret"; echo "  IP:       $SERVER_IP"; echo ""
    echo -n "Продолжить установку? [Y/n]: "; read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "Установка отменена"; exit 0; }
    local container=$(get_container_name "$port")
    log_info "Запуск контейнера $container..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 3
    if is_running "$container"; then
        log_success "✅ Прокси запущен"; open_firewall_port "$port" "Telegram Proxy - $domain"
        PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions
        echo ""; log_header "🔗 Ваша ссылка"; printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"; echo ""
        log_success "🎉 Установка завершена!"; echo ""; echo "📋 Полезные команды:"; echo "   sudo mtproto-manager          — главное меню"; echo "   sudo mtproto-manager links    — показать ссылки"; echo "   sudo mtproto-manager add      — добавить порт"; echo ""
        return 0
    else
        log_error "❌ Ошибка запуска контейнера"; return 1
    fi
}

main() {
    check_root
    check_docker
    check_ufw
    case "${1:-}" in
        add) cli_add "${@:2}" ;;
        remove) cli_remove "${@:2}" ;;
        links) cli_links ;;
        scan) scan_existing_proxies; show_proxy_list ;;
        web-panel) cli_web_panel "${@:2}" ;;
        *) main_menu ;;
    esac
}
main "$@"
