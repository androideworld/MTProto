#!/bin/bash
#
# MTProto Proxy Manager v2.1
# Автоматическая установка и управление прокси для Telegram
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
log_info()    { echo -e "${BLUE}[i]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[ERR]${NC} $1"; }
log_header()  { echo -e "\n${GREEN}+======================================+${NC}\n${GREEN}|${NC} $1 ${GREEN}|${NC}\n${GREEN}+======================================+${NC}\n"; }
log_divider() { echo -e "${CYAN}----------------------------------------${NC}"; }

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
    if [[ "$port" == "443" ]]; then
        echo "mtproto"
    else
        echo "mtproto-${port}"
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
            [[ "$key" == "port_"* ]] && PROXIES["${key#port_}"]="$value"
        done < "$CONFIG_FILE"
    fi
    echo "$found"
}

show_proxy_list() {
    log_header "Настроенные прокси"
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Прокси не найдены"; return 1; }
    log_divider
    printf "${CYAN}%-8s %-20s %-35s %s${NC}\n" "ПОРТ" "ДОМЕН" "СЕКРЕТ" "СТАТУС"
    log_divider
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo "[UP]" || echo "[DOWN]")
        printf "%-8s %-20s %-35s %s\n" "$port" "$domain" "${secret:0:32}..." "$status"
    done
    log_divider
}

# ==================== УПРАВЛЕНИЕ ====================
add_proxy() {
    log_header "Добавление прокси"
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
        case "${choice:-4}" in
            1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";;
            4|"") domain="mail.ru";; 5) domain="ok.ru";;
            6) echo -n "Домен: "; read -r domain; [[ ! "$domain" =~ \. ]] && domain="";;
        esac
    done
    local secret=$(generate_secret)
    echo -n "Запустить? [Y/n]: "
    read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    if is_running "$container"; then
        log_success "Запущен"
        open_firewall_port "$port"
        PROXIES["$port"]="${domain}:${secret}"
        save_config
        regenerate_functions
        printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
    else
        log_error "Ошибка запуска"
        return 1
    fi
}

# ИСПРАВЛЕНО: правильное удаление порта
remove_proxy() {
    log_header "Удаление прокси"
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
    # КРИТИЧНО: сохраняем порт ДО вызова функций!
    local deleted_port="$port_to_remove"
    unset "PROXIES[$port_to_remove]"
    save_config
    regenerate_functions
    echo -n "Закрыть порт $deleted_port в фаерволе? [y/N]: "
    read -r fw_confirm
    [[ "$fw_confirm" =~ ^[Yy]$ ]] && close_firewall_port "$deleted_port"
    log_success "Порт $deleted_port удален"
}

update_domain() {
    log_header "Обновление домена"
    show_proxy_list || return 0
    local port=""
    echo -n "Порт: "
    read -r port
    [ -z "${PROXIES[$port]}" ] && { log_error "Не найден"; return 1; }
    local secret="${PROXIES[$port]#*:}"
    echo "1) 1c.ru  2) vk.com  3) yandex.ru  4) mail.ru  5) ok.ru  6) Свой"
    echo -n "Домен [4]: "
    read -r choice
    case "${choice:-4}" in
        1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";;
        4|"") domain="mail.ru";; 5) domain="ok.ru";;
        6) echo -n "Домен: "; read -r domain;;
    esac
    echo -n "Обновить? [y/N]: "
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    is_running "$container" && { PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions; log_success "Обновлено"; } || log_error "Ошибка"
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
    log_header "Ссылки"
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Нет прокси"; return 1; }
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo " [UP]" || echo " [DOWN]")
        echo -e "${CYAN}Порт $port${NC} ($domain)$status"
        printf "   tg://proxy?server=%s&port=%s&secret=%s\n\n" "$SERVER_IP" "$port" "$secret"
    done
    { echo "# MTProto Links - $(date)"; for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do echo "tg://proxy?server=$SERVER_IP&port=$port&secret=${PROXIES[$port]#*:}"; done; } > "$HOME/mtproto-links.txt"
    log_info "Сохранено: $HOME/mtproto-links.txt"
}

# ==================== СТАТИЧЕСКИЙ ВЕБ-ИНТЕРФЕЙС ====================

generate_web_panel() {
    local output="/tmp/mtproto-panel.html"
    local total=${#PROXIES[@]}
    local active=0
    for port in "${!PROXIES[@]}"; do
        local container=$(get_container_name "$port")
        is_running "$container" && ((active++))
    done
    local ports_list=$(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n)
    
    cat > "$output" << 'HTML_HEAD'
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTProto Proxy Manager</title><style>
body{font-family:sans-serif;background:linear-gradient(145deg,#0a0f1f,#1a1f30);color:#e2e8f0;min-height:100vh;padding:20px}
.container{max-width:1200px;margin:0 auto}.header{text-align:center;margin-bottom:30px}
.header h1{font-size:2.5rem;background:linear-gradient(135deg,#fff,#a5b4fc);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.server-badge{background:rgba(255,255,255,0.05);border:1px solid rgba(255,255,255,0.1);border-radius:30px;padding:10px 20px;display:inline-flex;align-items:center;gap:15px}
.server-ip{color:#a5b4fc;font-weight:500}.status-dot{width:8px;height:8px;background:#10b981;border-radius:50%;display:inline-block;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:0.5}}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:15px;margin-bottom:30px}
.stat-card{background:rgba(15,23,42,0.6);border:1px solid rgba(255,255,255,0.05);border-radius:20px;padding:20px;text-align:center}
.stat-value{font-size:2rem;font-weight:700;color:#a5b4fc}.stat-label{color:#8b949e;font-size:14px;margin-top:5px}
.proxies-grid{display:grid;gap:20px}.proxy-card{background:rgba(15,23,42,0.7);border:1px solid rgba(255,255,255,0.05);border-radius:24px;padding:25px}
.proxy-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:15px;flex-wrap:wrap;gap:10px}
.proxy-title{font-size:1.3rem;font-weight:600;color:#f1f5f9}.proxy-status{padding:4px 12px;border-radius:20px;font-size:13px;font-weight:500}
.status-up{background:rgba(16,185,129,0.1);color:#10b981}.status-down{background:rgba(239,68,68,0.1);color:#ef4444}
.proxy-info{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin-bottom:15px}
.info-item{color:#cbd5e1;font-size:14px}.info-label{color:#8b949e}
.qr-section{text-align:center;margin:15px 0}.qr-code{background:#fff;padding:10px;border-radius:16px;display:inline-block}
.qr-code img{width:150px;height:150px}.proxy-link{background:rgba(0,0,0,0.3);padding:12px;border-radius:12px;font-family:monospace;font-size:13px;color:#a5b4fc;word-break:break-all;margin:10px 0}
.btn-group{display:flex;gap:10px;flex-wrap:wrap}.btn{padding:10px 20px;border:none;border-radius:16px;font-size:14px;cursor:pointer;display:inline-flex;align-items:center;gap:6px}
.btn-copy{background:linear-gradient(135deg,#4f5b93,#6366f1);color:#fff}.btn-tg{background:rgba(255,255,255,0.05);border:1px solid rgba(255,255,255,0.1);color:#e2e8f0}
.footer{text-align:center;padding:30px 0 20px;color:#4b5563;font-size:14px;border-top:1px solid rgba(255,255,255,0.05);margin-top:30px}
@media(max-width:768px){.proxy-header{flex-direction:column;align-items:flex-start}.btn-group{flex-direction:column}}
</style></head><body><div class="container">
<div class="header"><h1>MTProto Proxy Manager</h1>
<div class="server-badge"><span class="server-ip">Server: SERVER_IP_PLACEHOLDER</span><span class="status-indicator"><span class="status-dot"></span> Active</span></div></div>
<div class="stats">
<div class="stat-card"><div class="stat-value" id="activeCount">ACTIVE_COUNT</div><div class="stat-label">Active</div></div>
<div class="stat-card"><div class="stat-value" id="totalCount">TOTAL_COUNT</div><div class="stat-label">Total Proxies</div></div>
<div class="stat-card"><div class="stat-value">24/7</div><div class="stat-label">Uptime</div></div>
</div><div class="proxies-grid" id="proxiesGrid">
HTML_HEAD

    for port in $ports_list; do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status_text=$(is_running "$container" && echo "Active" || echo "Inactive")
        local status_class=$(is_running "$container" && echo "status-up" || echo "status-down")
        local link="tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"
        local qr_data=$(echo -n "$link" | sed 's/ /%20/g;s/:/%3A/g;s/?/%3F/g;s/=/\%3D/g;s/&/%26/g')
        local qr_url="https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=$qr_data"
        cat >> "$output" << CARD
<div class="proxy-card"><div class="proxy-header"><div class="proxy-title">Port $port</div><div class="proxy-status $status_class">$status_text</div></div>
<div class="proxy-info"><div class="info-item"><span class="info-label">Domain:</span> $domain</div><div class="info-item"><span class="info-label">Protocol:</span> MTProto 2.0</div></div>
<div class="qr-section"><div class="qr-code"><img src="$qr_url" alt="QR"></div><p style="color:#94a3b8;font-size:13px;margin-top:8px">Scan to connect</p></div>
<div class="proxy-link">$link</div><div class="btn-group">
<button class="btn btn-copy" onclick="copyLink('$link')">Copy</button><a href="$link" class="btn btn-tg">Telegram</a></div></div>
CARD
    done

    cat >> "$output" << 'HTML_FOOT'
</div><div class="footer"><p>MTProto Proxy Manager vSCRIPT_VERSION - Static Panel</p>
<p style="margin-top:8px;font-size:12px">Auto-refresh: 30 seconds</p></div></div>
<script>
document.getElementById('activeCount')&&(document.getElementById('activeCount').textContent=ACTIVE_COUNT_JS);
document.getElementById('totalCount')&&(document.getElementById('totalCount').textContent=TOTAL_COUNT_JS);
function copyLink(t){navigator.clipboard.writeText(t).then(()=>alert('Copied!')).catch(()=>prompt('Copy:',t));}
setTimeout(()=>location.reload(),30000);
</script></body></html>
HTML_FOOT

    sed -i "s/SERVER_IP_PLACEHOLDER/$SERVER_IP/g;s/ACTIVE_COUNT/$active/g;s/TOTAL_COUNT/$total/g;s/ACTIVE_COUNT_JS/$active/g;s/TOTAL_COUNT_JS/$total/g;s/SCRIPT_VERSION/$SCRIPT_VERSION/g" "$output"
    echo "$output"
}

cli_web_panel() {
    scan_existing_proxies >/dev/null 2>&1 || true
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "No proxies to display"; return 1; }
    local html_file=$(generate_web_panel)
    log_success "Panel generated: $html_file"
    echo ""; echo -e "${YELLOW}Open in browser:${NC}"; echo "   file://$html_file"
    echo ""; echo -e "${CYAN}Tip: For network access run:${NC}"; echo "   cd /tmp && python3 -m http.server 8080"
    echo "   Then open: http://$SERVER_IP:8080/mtproto-panel.html"
}

# ==================== CLI КОМАНДЫ ====================
cli_add() {
    local port="$1" domain="$2" secret="${3:-$(generate_secret)}"
    [[ -z "$port" || -z "$domain" ]] && { log_error "add <port> <domain>"; exit 1; }
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2; is_running "$container" || exit 1
    open_firewall_port "$port"; PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions
    printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"
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

# ==================== МЕНЮ И ЗАПУСК ====================

main_menu() {
    while true; do
        log_header "MTProto Manager v$SCRIPT_VERSION"
        echo "Server: $SERVER_IP"; echo ""
        local count=$(scan_existing_proxies)
        echo "Found proxies: $count"; echo ""
        echo "1) List  2) Add  3) Remove  4) Update domain  5) Links  6) Web panel  7) Refresh  8) Exit"
        echo -n "Choice: "
        read -r choice
        case "$choice" in
            1) show_proxy_list;; 2) add_proxy;; 3) remove_proxy;; 4) update_domain;;
            5) show_all_links;; 6) cli_web_panel;; 7) regenerate_functions;; 8|*) log_info "Exit"; exit 0;;
            *) log_warn "Invalid";;
        esac
        echo -n "Press Enter..."; read -r
    done
}

check_installation_status() {
    local has_config=false has_containers=false
    [ -f "$CONFIG_FILE" ] && has_config=true
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^mtproto" && has_containers=true
    [ "$has_config" = true ] || [ "$has_containers" = true ]
}

quick_install() {
    log_header "First installation"
    echo ""; echo "Setup your first proxy."; echo ""
    local port="" domain="" secret=""
    while [ -z "$port" ]; do
        echo -n "Port [443]: "; read -r port; port="${port:-443}"
        [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]] && { log_error "Invalid"; port=""; }
    done
    echo "1) 1c.ru  2) vk.com  3) yandex.ru  4) mail.ru  5) ok.ru"
    echo -n "Domain [4]: "; read -r choice
    case "${choice:-4}" in 1) domain="1c.ru";; 2) domain="vk.com";; 3) domain="yandex.ru";; 4|"") domain="mail.ru";; 5) domain="ok.ru";; *) domain="mail.ru";; esac
    secret=$(generate_secret)
    echo ""; echo -e "${YELLOW}Params:${NC}"; echo " Port: $port  Domain: $domain  Secret: $secret  IP: $SERVER_IP"; echo ""
    echo -n "Continue? [Y/n]: "; read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && { log_info "Cancelled"; exit 0; }
    local container=$(get_container_name "$port")
    log_info "Starting $container..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 3
    if is_running "$container"; then
        log_success "Started"; open_firewall_port "$port"
        PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions
        echo ""; log_header "Your link"; printf "tg://proxy?server=%s&port=%s&secret=%s\n" "$SERVER_IP" "$port" "$secret"; echo ""
        log_success "Done!"; echo ""; echo "Commands: mtproto-manager | links | add"
        return 0
    else
        log_error "Failed"; return 1
    fi
}

main() {
    check_root; check_docker; check_ufw
    case "${1:-}" in
        add) cli_add "${@:2}";; remove) cli_remove "${@:2}";; links) cli_links;;
        scan) scan_existing_proxies; show_proxy_list;; web-panel) cli_web_panel "${@:2}";;
        *) if check_installation_status; then
            log_info "Existing installation found"
            scan_existing_proxies >/dev/null; show_proxy_list; main_menu
        else
            log_warn "No installation found"
            echo ""; echo "Install now? [Y/n]"; read -r confirm
            if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                quick_install
                [ $? -eq 0 ] && { echo -n "Open menu? [Y/n]: "; read -r mc; [[ ! "$mc" =~ ^[Nn]$ ]] && main_menu; }
            else
                log_info "Exit"; exit 0
            fi
        fi;;
    esac
}

main "$@"
