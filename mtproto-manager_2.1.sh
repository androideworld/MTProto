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

# ==================== СТАТИЧЕСКИЙ ВЕБ-ИНТЕРФЕЙС ====================

generate_web_panel() {
    local output="/tmp/mtproto-panel.html"
    local total=${#PROXIES[@]}
    local active=0
    for port in "${!PROXIES[@]}"; do
        local container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
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
        local container="mtproto"
        [[ "$port" != "443" ]] && container="${container}-${port}"
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
# ==================== МЕНЮ И ЗАПУСК ====================

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
        echo "   7) 🎨 Консольная панель"    # ← НОВОЕ
        echo "   0) ❌ Выход"


        
        
        
        echo ""
        echo -n "Ваш выбор (1-8): "
        read -r choice
        case "$choice" in
            1) show_proxy_list ;;
            2) add_proxy ;;
            3) remove_proxy ;;
            4) update_domain ;;
            5) show_all_links ;;
            6) regenerate_functions ;;
            7) cli_web_panel ;;
            8|*) log_info "Выход"; exit 0 ;;
            0|*) log_info "Выход"; exit 0 ;;      # ← Измените
            *) log_warn "Неверный выбор" ;;
        esac
        echo ""
        echo -n "Нажмите Enter для продолжения..."
        read -r
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

# ==================== 🎨 КОНСОЛЬНАЯ ВЕБ-ПАНЕЛЬ ====================

generate_web_panel() {
    local output="/tmp/mtproto-panel.html"
    local total=${#PROXIES[@]}
    local active=0
    for port in "${!PROXIES[@]}"; do
        local container=$(get_container_name "$port")
        is_running "$container" && ((active++))
    done
    local ports_list=$(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n)
    local port_range=""
    if [ -n "$ports_list" ]; then
        local first=$(echo "$ports_list" | head -1)
        local last=$(echo "$ports_list" | tail -1)
        port_range="${first}-${last}"
    fi

    # Генерация JSON-массива прокси для JavaScript
    local proxies_json="["
    local first_item=true
    for port in $ports_list; do
        local value="${PROXIES[$port]}"
        local domain="${value%%:*}"
        local secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo "up" || echo "down")
        if [ "$first_item" = true ]; then
            first_item=false
        else
            proxies_json+=","
        fi
        proxies_json+="{\"port\":$port,\"domain\":\"$domain\",\"secret\":\"$secret\",\"status\":\"$status\"}"
    done
    proxies_json+="]"

    cat > "$output" << HTML_HEAD
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MTProto Proxy Manager | Console Panel</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'SF Mono', 'Monaco', 'Cascadia Code', 'Roboto Mono', monospace; background: #0a0e1a; color: #e2e8f0; min-height: 100vh; padding: 20px; line-height: 1.6; }
        .container { max-width: 1400px; margin: 0 auto; }
        .terminal-header { background: #1e2434; border-radius: 12px 12px 0 0; padding: 12px 20px; display: flex; align-items: center; gap: 10px; border-bottom: 2px solid #4f6bc4; }
        .terminal-dots { display: flex; gap: 8px; }
        .terminal-dot { width: 14px; height: 14px; border-radius: 50%; }
        .dot-red { background: #ff5f56; } .dot-yellow { background: #ffbd2e; } .dot-green { background: #27c93f; }
        .terminal-title { color: #8b949e; font-size: 14px; margin-left: 10px; }
        .terminal-body { background: #141b2b; border-radius: 0 0 12px 12px; padding: 25px; border: 1px solid #2d3748; border-top: none; box-shadow: 0 20px 40px rgba(0,0,0,0.5); }
        .command-line { background: #0f1625; border-left: 4px solid #4f6bc4; padding: 15px 20px; margin-bottom: 25px; border-radius: 8px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
        .prompt { color: #4f6bc4; font-weight: bold; }
        .command-text { color: #e2e8f0; }
        .stats-panel { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 15px; margin-bottom: 30px; }
        .stat-block { background: #0f1625; border: 1px solid #2d3748; border-radius: 8px; padding: 15px; }
        .stat-label { color: #6b7a8f; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 5px; }
        .stat-value { font-size: 28px; font-weight: 600; color: #a5b4fc; }
        .stat-sub { color: #4a5a72; font-size: 12px; margin-top: 5px; }
        .tabs { display: flex; gap: 5px; margin-bottom: 25px; border-bottom: 1px solid #2d3748; padding-bottom: 5px; }
        .tab { padding: 10px 20px; background: none; border: none; color: #8b949e; cursor: pointer; font-size: 14px; border-radius: 6px 6px 0 0; transition: all 0.2s; }
        .tab:hover { color: #a5b4fc; background: rgba(79,107,196,0.1); }
        .tab.active { color: #a5b4fc; border-bottom: 2px solid #4f6bc4; background: rgba(79,107,196,0.05); }
        .create-panel { background: #0f1625; border: 1px solid #2d3748; border-radius: 8px; padding: 20px; margin-bottom: 30px; }
        .panel-title { font-size: 16px; color: #a5b4fc; margin-bottom: 20px; display: flex; align-items: center; gap: 8px; }
        .panel-title::before { content: '>'; color: #4f6bc4; font-weight: bold; }
        .form-row { display: flex; gap: 15px; margin-bottom: 20px; flex-wrap: wrap; align-items: flex-end; }
        .form-group { flex: 1; min-width: 200px; }
        .form-label { display: block; color: #6b7a8f; font-size: 12px; margin-bottom: 5px; text-transform: uppercase; }
        .form-control { width: 100%; background: #1e2434; border: 1px solid #2d3748; color: #e2e8f0; padding: 12px 15px; border-radius: 6px; font-size: 14px; }
        .form-control:focus { outline: none; border-color: #4f6bc4; }
        .domain-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(100px, 1fr)); gap: 8px; margin-top: 10px; }
        .domain-btn { background: #1e2434; border: 1px solid #2d3748; color: #8b949e; padding: 8px; border-radius: 4px; cursor: pointer; font-size: 12px; text-align: center; transition: all 0.2s; }
        .domain-btn:hover { border-color: #4f6bc4; color: #a5b4fc; }
        .domain-btn.active { background: #4f6bc4; border-color: #4f6bc4; color: white; }
        .table-container { background: #0f1625; border: 1px solid #2d3748; border-radius: 8px; overflow-x: auto; margin-bottom: 30px; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { text-align: left; padding: 15px 12px; background: #1a2335; color: #8b949e; font-weight: 500; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; border-bottom: 2px solid #2d3748; }
        td { padding: 15px 12px; border-bottom: 1px solid #2d3748; color: #e2e8f0; }
        tr:last-child td { border-bottom: none; }
        tr:hover td { background: rgba(79,107,196,0.05); }
        .status-badge { display: inline-flex; align-items: center; gap: 6px; padding: 4px 8px; border-radius: 4px; font-size: 11px; font-weight: 500; }
        .status-up { background: rgba(16,185,129,0.1); color: #10b981; border: 1px solid rgba(16,185,129,0.2); }
        .status-up::before { content: '●'; font-size: 12px; }
        .status-down { background: rgba(239,68,68,0.1); color: #ef4444; border: 1px solid rgba(239,68,68,0.2); }
        .status-down::before { content: '●'; font-size: 12px; }
        .secret-preview { font-family: 'SF Mono', monospace; color: #a5b4fc; max-width: 150px; overflow: hidden; text-overflow: ellipsis; }
        .link-preview { font-family: 'SF Mono', monospace; color: #6b7a8f; font-size: 11px; max-width: 200px; overflow: hidden; text-overflow: ellipsis; }
        .action-btn { background: none; border: 1px solid #2d3748; color: #8b949e; width: 32px; height: 32px; border-radius: 4px; cursor: pointer; font-size: 16px; transition: all 0.2s; margin: 0 2px; }
        .action-btn:hover { border-color: #4f6bc4; color: #a5b4fc; background: rgba(79,107,196,0.1); }
        .action-btn.delete:hover { border-color: #ef4444; color: #ef4444; }
        .commands-panel { background: #0f1625; border: 1px solid #2d3748; border-radius: 8px; padding: 20px; }
        .commands-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 15px; margin-top: 15px; }
        .command-item { background: #1a2335; border: 1px solid #2d3748; border-radius: 6px; padding: 12px 15px; }
        .command-name { color: #a5b4fc; font-weight: 600; margin-bottom: 5px; }
        .command-example { color: #6b7a8f; font-size: 11px; }
        .copy-btn { background: none; border: 1px solid #2d3748; color: #8b949e; padding: 4px 10px; border-radius: 4px; font-size: 11px; cursor: pointer; margin-left: 10px; }
        .copy-btn:hover { border-color: #4f6bc4; color: #a5b4fc; }
        .qr-modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.9); align-items: center; justify-content: center; z-index: 1000; }
        .qr-modal.active { display: flex; }
        .qr-content { background: #1a2335; border: 1px solid #4f6bc4; border-radius: 12px; padding: 30px; max-width: 400px; width: 90%; }
        .qr-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
        .qr-header h3 { color: #a5b4fc; }
        .qr-close { background: none; border: none; color: #8b949e; font-size: 24px; cursor: pointer; }
        .qr-code { background: white; padding: 15px; border-radius: 8px; text-align: center; margin-bottom: 20px; }
        .qr-code img { width: 200px; height: 200px; }
        .qr-link { background: #0f1625; padding: 12px; border-radius: 4px; font-family: 'SF Mono', monospace; font-size: 11px; word-break: break-all; color: #a5b4fc; }
        .notification { position: fixed; bottom: 20px; right: 20px; background: #1e293b; border-left: 4px solid #4f6bc4; padding: 15px 25px; border-radius: 4px; color: white; font-size: 13px; z-index: 2000; animation: slideIn 0.3s; box-shadow: 0 10px 30px rgba(0,0,0,0.5); }
        @keyframes slideIn { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }
        .notification.success { border-left-color: #10b981; }
        .notification.error { border-left-color: #ef4444; }
        .notification.warning { border-left-color: #f59e0b; }
        .footer { margin-top: 30px; text-align: center; color: #4a5a72; font-size: 12px; border-top: 1px solid #2d3748; padding-top: 20px; }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        @media (max-width: 768px) { .form-row { flex-direction: column; } .stats-panel { grid-template-columns: 1fr 1fr; } .commands-grid { grid-template-columns: 1fr; } }
    </style>
</head>
<body>
<div class="container">
    <div class="terminal-header">
        <div class="terminal-dots"><span class="terminal-dot dot-red"></span><span class="terminal-dot dot-yellow"></span><span class="terminal-dot dot-green"></span></div>
        <div class="terminal-title">root@mtproto-proxy:~/manager</div>
    </div>
    <div class="terminal-body">
        <div class="command-line">
            <span class="prompt">root@server:~$</span>
            <span class="command-text">./mtproto-manager</span>
        </div>
        <div class="stats-panel">
            <div class="stat-block"><div class="stat-label">Активные прокси</div><div class="stat-value" id="statsActive">ACTIVE_COUNT</div><div class="stat-sub">online</div></div>
            <div class="stat-block"><div class="stat-label">Всего</div><div class="stat-value" id="statsTotal">TOTAL_COUNT</div><div class="stat-sub">настроено</div></div>
            <div class="stat-block"><div class="stat-label">Порты</div><div class="stat-value" id="statsPorts">PORT_RANGE</div><div class="stat-sub">диапазон</div></div>
            <div class="stat-block"><div class="stat-label">Сервер</div><div class="stat-value" style="font-size:16px" id="serverIP">SERVER_IP_PLACEHOLDER</div><div class="stat-sub">IPv4</div></div>
        </div>
        <div class="tabs">
            <button class="tab active" onclick="switchTab('proxies')">📋 Прокси</button>
            <button class="tab" onclick="switchTab('create')">➕ Создать</button>
            <button class="tab" onclick="switchTab('commands')">💻 Команды</button>
            <button class="tab" onclick="switchTab('config')">⚙️ Конфиг</button>
        </div>
        <div id="tabProxies" class="tab-content active">
            <div class="table-container">
                <table>
                    <thead><tr><th>Порт</th><th>Домен</th><th>Секрет</th><th>Ссылка</th><th>Статус</th><th>Действия</th></tr></thead>
                    <tbody id="proxiesTable"></tbody>
                </table>
            </div>
        </div>
        <div id="tabCreate" class="tab-content">
            <div class="create-panel">
                <div class="panel-title">mtproto-manager add --interactive</div>
                <div class="form-row">
                    <div class="form-group"><label class="form-label">Порт</label><input type="number" class="form-control" id="newPort" placeholder="1024-65535" min="1024" max="65535"></div>
                    <div class="form-group"><label class="form-label">Секрет (опционально)</label><input type="text" class="form-control" id="newSecret" placeholder="auto-generate"></div>
                    <div class="form-group"><label class="form-label">&nbsp;</label><button class="form-control" onclick="generateSecret()" style="background:#1e2434;cursor:pointer">🎲 Сгенерировать</button></div>
                </div>
                <label class="form-label">Домен маскировки</label>
                <div class="domain-grid">
                    <div class="domain-btn active" onclick="selectDomain('1c.ru',this)">1c.ru</div>
                    <div class="domain-btn" onclick="selectDomain('vk.com',this)">vk.com</div>
                    <div class="domain-btn" onclick="selectDomain('yandex.ru',this)">yandex.ru</div>
                    <div class="domain-btn" onclick="selectDomain('mail.ru',this)">mail.ru</div>
                    <div class="domain-btn" onclick="selectDomain('ok.ru',this)">ok.ru</div>
                    <div class="domain-btn" onclick="showCustomDomain()">✏️ Свой</div>
                </div>
                <div id="customDomainInput" style="display:none;margin-top:15px"><input type="text" class="form-control" id="customDomain" placeholder="example.com"></div>
                <div style="display:flex;gap:10px;margin-top:25px">
                    <button class="form-control" onclick="createProxy()" style="background:#4f6bc4;color:white;border:none;flex:2;cursor:pointer">🚀 Создать прокси</button>
                    <button class="form-control" onclick="clearForm()" style="background:#1e2434;cursor:pointer;flex:1">Очистить</button>
                </div>
                <div id="createResult" style="margin-top:20px;padding:15px;background:#1a2335;border-radius:4px;display:none">
                    <div style="color:#a5b4fc;margin-bottom:10px"># Результат:</div>
                    <div style="font-family:'SF Mono',monospace;font-size:12px;word-break:break-all" id="createLink"></div>
                </div>
            </div>
        </div>
        <div id="tabCommands" class="tab-content">
            <div class="commands-panel">
                <div class="panel-title">mtproto-manager --help</div>
                <div class="commands-grid">
                    <div class="command-item"><div class="command-name">./mtproto-manager add 1050 1c.ru</div><div class="command-example"># Создать прокси на порту 1050</div><button class="copy-btn" onclick="copyCommand('./mtproto-manager add 1050 1c.ru')">Копировать</button></div>
                    <div class="command-item"><div class="command-name">./mtproto-manager remove 1050</div><div class="command-example"># Удалить прокси на порту 1050</div><button class="copy-btn" onclick="copyCommand('./mtproto-manager remove 1050')">Копировать</button></div>
                    <div class="command-item"><div class="command-name">./mtproto-manager links</div><div class="command-example"># Показать все ссылки</div><button class="copy-btn" onclick="copyCommand('./mtproto-manager links')">Копировать</button></div>
                    <div class="command-item"><div class="command-name">./mtproto-manager scan</div><div class="command-example"># Сканировать прокси</div><button class="copy-btn" onclick="copyCommand('./mtproto-manager scan')">Копировать</button></div>
                    <div class="command-item"><div class="command-name">docker logs mtproto-1050</div><div class="command-example"># Логи контейнера</div><button class="copy-btn" onclick="copyCommand('docker logs mtproto-1050')">Копировать</button></div>
                    <div class="command-item"><div class="command-name">sudo ufw allow 1050/tcp</div><div class="command-example"># Открыть порт в фаерволе</div><button class="copy-btn" onclick="copyCommand('sudo ufw allow 1050/tcp')">Копировать</button></div>
                </div>
            </div>
        </div>
        <div id="tabConfig" class="tab-content">
            <div class="create-panel">
                <div class="panel-title">Конфигурация (/etc/mtproto.conf)</div>
                <pre style="background:#1a2335;padding:20px;border-radius:6px;font-size:12px;overflow-x:auto" id="configText">
# MTProto Proxy Configuration
# Generated: $(date)
# Version: SCRIPT_VERSION
server_ip=SERVER_IP_PLACEHOLDER
CONFIG_ENTRIES_PLACEHOLDER
                </pre>
                <div style="display:flex;gap:10px;margin-top:20px">
                    <button class="form-control" onclick="copyConfig()" style="background:#1e2434;cursor:pointer">📋 Копировать конфиг</button>
                    <button class="form-control" onclick="downloadConfig()" style="background:#1e2434;cursor:pointer">⬇️ Скачать</button>
                </div>
            </div>
        </div>
        <div class="qr-modal" id="qrModal">
            <div class="qr-content">
                <div class="qr-header"><h3>QR-код для подключения</h3><button class="qr-close" onclick="closeQR()">&times;</button></div>
                <div class="qr-code" id="qrImage"><img src="" alt="QR"></div>
                <div class="qr-link" id="qrLinkText"></div>
                <div style="display:flex;gap:10px;margin-top:20px">
                    <button class="form-control" onclick="copyQRLink()" style="background:#4f6bc4;color:white;border:none">📋 Копировать ссылку</button>
                    <button class="form-control" onclick="closeQR()" style="background:#1e2434">Закрыть</button>
                </div>
            </div>
        </div>
        <div class="footer">
            <div style="display:flex;justify-content:center;gap:30px;margin-bottom:15px">
                <span>🔹 MTProto Proxy Manager vSCRIPT_VERSION</span>
                <span>🔹 <span id="footerActive">ACTIVE_COUNT</span> прокси активны</span>
                <span>🔹 uptime: 99.9%</span>
            </div>
            <div style="color:#2d3748">root@server:~# ./mtproto-manager — интерактивный режим</div>
        </div>
    </div>
</div>
<script>
// Динамические данные
const SERVER_IP = 'SERVER_IP_JS';
const PROXIES_DATA = PROXIES_JSON_PLACEHOLDER;
let proxies = JSON.parse(JSON.stringify(PROXIES_DATA));
let selectedDomain = '1c.ru';
let currentQRPort = null;

// Инициализация
document.addEventListener('DOMContentLoaded', function() {
    document.getElementById('serverIP').textContent = SERVER_IP;
    document.getElementById('statsActive').textContent = proxies.filter(p=>p.status==='up').length;
    document.getElementById('statsTotal').textContent = proxies.length;
    document.getElementById('footerActive').textContent = proxies.filter(p=>p.status==='up').length;
    if(proxies.length>0){const ports=proxies.map(p=>p.port).sort((a,b)=>a-b);document.getElementById('statsPorts').textContent=ports[0]+'-'+ports[ports.length-1];}
    renderProxies();
    updateConfig();
    loadFromStorage();
});

function loadFromStorage(){const saved=localStorage.getItem('mtproto-proxies');if(saved){proxies=JSON.parse(saved);renderProxies();updateStats();}}
function saveToStorage(){localStorage.setItem('mtproto-proxies',JSON.stringify(proxies));}

function renderProxies(){
    const tbody=document.getElementById('proxiesTable');tbody.innerHTML='';
    proxies.sort((a,b)=>a.port-b.port).forEach(proxy=>{
        const link='tg://proxy?server='+SERVER_IP+'&port='+proxy.port+'&secret='+proxy.secret;
        const shortSecret=proxy.secret.substring(0,8)+'…'+proxy.secret.substring(proxy.secret.length-4);
        const row=document.createElement('tr');
        row.innerHTML='<td><strong>'+proxy.port+'</strong></td><td>'+proxy.domain+'</td><td><div class="secret-preview" title="'+proxy.secret+'">'+shortSecret+'</div></td><td><div class="link-preview" title="'+link+'">'+link.substring(0,35)+'…</div></td><td><span class="status-badge status-'+proxy.status+'">'+(proxy.status==='up'?'Активен':'Неактивен')+'</span></td><td><button class="action-btn" onclick="copyProxyLink('+proxy.port+')" title="Копировать">📋</button><button class="action-btn" onclick="showQR('+proxy.port+')" title="QR">📱</button><button class="action-btn" onclick="editProxy('+proxy.port+')" title="Редактировать">✏️</button><button class="action-btn delete" onclick="deleteProxy('+proxy.port+')" title="Удалить">🗑️</button></td>';
        tbody.appendChild(row);
    });
}

function updateStats(){const active=proxies.filter(p=>p.status==='up').length;document.getElementById('statsActive').textContent=active;document.getElementById('statsTotal').textContent=proxies.length;if(proxies.length>0){const ports=proxies.map(p=>p.port).sort((a,b)=>a-b);document.getElementById('statsPorts').textContent=ports[0]+'-'+ports[ports.length-1];}}

function switchTab(tab){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.tab-content').forEach(c=>c.classList.remove('active'));if(tab==='proxies'){document.querySelectorAll('.tab')[0].classList.add('active');document.getElementById('tabProxies').classList.add('active');}else if(tab==='create'){document.querySelectorAll('.tab')[1].classList.add('active');document.getElementById('tabCreate').classList.add('active');}else if(tab==='commands'){document.querySelectorAll('.tab')[2].classList.add('active');document.getElementById('tabCommands').classList.add('active');}else if(tab==='config'){document.querySelectorAll('.tab')[3].classList.add('active');document.getElementById('tabConfig').classList.add('active');}}

function selectDomain(domain,el){selectedDomain=domain;document.querySelectorAll('.domain-btn').forEach(btn=>btn.classList.remove('active'));el.classList.add('active');document.getElementById('customDomainInput').style.display='none';}
function showCustomDomain(){document.querySelectorAll('.domain-btn').forEach(btn=>btn.classList.remove('active'));document.querySelector('.domain-btn:last-child').classList.add('active');document.getElementById('customDomainInput').style.display='block';selectedDomain='';}

function generateSecret(){const secret=Array.from({length:32},()=>Math.floor(Math.random()*16).toString(16)).join('');document.getElementById('newSecret').value=secret;showNotification('Секрет сгенерирован','success');}

function createProxy(){
    const port=parseInt(document.getElementById('newPort').value);const secret=document.getElementById('newSecret').value||generateRandomSecret();
    let domain=selectedDomain;if(selectedDomain===''){domain=document.getElementById('customDomain').value;if(!domain||!domain.match(/^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/)){showNotification('Введите корректный домен','error');return;}}
    if(port<1024||port>65535){showNotification('Порт должен быть 1024-65535','error');return;}
    const existing=proxies.findIndex(p=>p.port===port);if(existing!==-1){if(!confirm('Порт '+port+' уже используется. Заменить?')){return;}proxies.splice(existing,1);}
    proxies.push({port:port,domain:domain,secret:secret,status:'up'});saveToStorage();renderProxies();updateStats();
    const link='tg://proxy?server='+SERVER_IP+'&port='+port+'&secret='+secret;document.getElementById('createLink').textContent=link;document.getElementById('createResult').style.display='block';
    showNotification('Прокси на порту '+port+' создан','success');clearForm();
}

function deleteProxy(port){if(confirm('Удалить прокси на порту '+port+'?')){proxies=proxies.filter(p=>p.port!==port);saveToStorage();renderProxies();updateStats();showNotification('Прокси удалён','success');}}
function editProxy(port){const proxy=proxies.find(p=>p.port===port);if(!proxy)return;const newDomain=prompt('Новый домен:',proxy.domain);if(newDomain&&newDomain.match(/^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$/)){proxy.domain=newDomain;saveToStorage();renderProxies();showNotification('Домен обновлён','success');}}
function copyProxyLink(port){const proxy=proxies.find(p=>p.port===port);if(!proxy)return;const link='tg://proxy?server='+SERVER_IP+'&port='+port+'&secret='+proxy.secret;copyToClipboard(link);showNotification('Ссылка скопирована','success');}

function showQR(port){const proxy=proxies.find(p=>p.port===port);if(!proxy)return;const link='tg://proxy?server='+SERVER_IP+'&port='+port+'&secret='+proxy.secret;const qrUrl='https://api.qrserver.com/v1/create-qr-code/?size=200x200&data='+encodeURIComponent(link);document.getElementById('qrImage').innerHTML='<img src="'+qrUrl+'" alt="QR">';document.getElementById('qrLinkText').textContent=link;document.getElementById('qrModal').classList.add('active');currentQRPort=port;}
function closeQR(){document.getElementById('qrModal').classList.remove('active');}
function copyQRLink(){copyToClipboard(document.getElementById('qrLinkText').textContent);showNotification('Ссылка скопирована','success');}
function copyCommand(cmd){copyToClipboard(cmd);showNotification('Команда скопирована','success');}
function copyConfig(){copyToClipboard(document.getElementById('configText').textContent);showNotification('Конфиг скопирован','success');}
function downloadConfig(){const config=document.getElementById('configText').textContent;const blob=new Blob([config],{type:'text/plain'});const url=URL.createObjectURL(blob);const a=document.createElement('a');a.href=url;a.download='mtproto.conf';a.click();URL.revokeObjectURL(url);}
function clearForm(){document.getElementById('newPort').value='';document.getElementById('newSecret').value='';document.getElementById('customDomain').value='';document.getElementById('customDomainInput').style.display='none';document.getElementById('createResult').style.display='none';selectedDomain='1c.ru';document.querySelectorAll('.domain-btn').forEach(btn=>btn.classList.remove('active'));document.querySelector('.domain-btn').classList.add('active');}

function generateRandomSecret(){return Array.from({length:32},()=>Math.floor(Math.random()*16).toString(16)).join('');}
function copyToClipboard(text){const textarea=document.createElement('textarea');textarea.value=text;document.body.appendChild(textarea);textarea.select();document.execCommand('copy');document.body.removeChild(textarea);}
function showNotification(msg,type='info'){const n=document.createElement('div');n.className='notification '+type;n.textContent=msg;document.body.appendChild(n);setTimeout(()=>{n.style.animation='slideIn 0.3s ease reverse';setTimeout(()=>n.remove(),300)},2000);}
function updateConfig(){let cfg='# MTProto Proxy Configuration\n# Generated: '+new Date().toISOString().slice(0,10)+'\n# Version: SCRIPT_VERSION\nserver_ip='+SERVER_IP+'\n';proxies.forEach(p=>cfg+='port_'+p.port+'='+p.domain+':'+p.secret+'\n');document.getElementById('configText').textContent=cfg;}
setInterval(updateStats,10000);window.addEventListener('beforeunload',saveToStorage);
</script>
</body>
</html>
HTML_HEAD

    # Замена плейсхолдеров
    sed -i "s/SERVER_IP_PLACEHOLDER/$SERVER_IP/g;s/SERVER_IP_JS/$SERVER_IP/g;s/ACTIVE_COUNT/$active/g;s/TOTAL_COUNT/$total/g;s/PORT_RANGE/$port_range/g;s/SCRIPT_VERSION/$SCRIPT_VERSION/g;s|PROXIES_JSON_PLACEHOLDER|$proxies_json|g" "$output"
    
    # Генерация строк конфига
    local config_entries=""
    for port in $ports_list; do
        local value="${PROXIES[$port]}"
        config_entries+="port_${port}=${value}\n"
    done
    sed -i "s|CONFIG_ENTRIES_PLACEHOLDER|$config_entries|g" "$output"
    
    echo "$output"
}

cli_web_panel() {
    scan_existing_proxies >/dev/null 2>&1 || true
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "No proxies to display"; return 1; }
    local html_file=$(generate_web_panel)
    log_success "Console panel generated: $html_file"
    echo ""; echo -e "${YELLOW}Open in browser:${NC}"; echo "   file://$html_file"
    echo ""; echo -e "${CYAN}Tip: For network access run:${NC}"; echo "   cd /tmp && python3 -m http.server 8080"
    echo "   Then open: http://$SERVER_IP:8080/mtproto-panel.html"
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
        web-panel) cli_web_panel "${@:2}" ;;  # ← Уже должно быть
        *) main_menu ;;
esac
}
main "$@"
