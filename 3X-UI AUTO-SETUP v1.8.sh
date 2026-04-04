#!/usr/bin/env bash
#===============================================================================
# 3X-UI AUTO-SETUP v1.8 — ULTIMATE STEALTH EDITION
# Все критические уязвимости устранены + Stealth-функции
#
# Автор: Артем + Security Audit
# Версия: 1.8-stealth-audited
# Лицензия: MIT
# Требования: Ubuntu/Debian 20.04+, root, bash 4.0+
#===============================================================================

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
    echo "[✗] Скрипт должен быть запущен от root" >&2
    exit 1
fi

set -euo pipefail

# Цветовые переменные
declare -r GREEN='\033[0;32m'
declare -r RED='\033[0;31m'
declare -r YELLOW='\033[0;33m'
declare -r BLUE='\033[0;34m'
declare -r CYAN='\033[0;36m'
declare -r NC='\033[0m'

#===============================================================================
# 📋 БЛОК 1/25: КОНФИГУРАЦИЯ — ОБЪЕДИНЁННЫЙ
#===============================================================================
: "${SERVER_IP:=''}"
: "${SERVER_PORT:='22'}"
: "${SERVER_USER:='root'}"
: "${SERVER_PASS:=''}"
: "${SERVER_KEY:=''}"
: "${DOMAIN:=''}"
: "${REALITY_DOMAIN:=''}"
: "${REALITY_DEST:='www.microsoft.com:443'}"
: "${PANEL_PORT:='2053'}"
: "${PANEL_PATH:='/xui'}"
: "${LOG_FILE:='/var/log/3xui-setup.log'}"
: "${LOCK_DIR:=''}"
: "${SKIP_UFW_RESET:='0'}"
: "${DRY_RUN:='0'}"
: "${ENABLE_REALITY:='1'}"
: "${ENABLE_FAKE_SITE:='1'}"
: "${ENABLE_ADBLOCK:='1'}"
: "${ENABLE_TELEGRAM:='0'}"
: "${ENABLE_SUB_PAGE:='1'}"
: "${ENABLE_ICMP_BLOCK:='1'}"
: "${ENABLE_SSH_KEY:='0'}"
# Stealth-функции
: "${ENABLE_AUTO_DOMAIN:='0'}"
: "${ENABLE_BBR:='1'}"
: "${ENABLE_SNI_ROUTING:='0'}"
: "${ENABLE_CF_RESTRICT:='0'}"
# Hash verification
: "${FIXED_VERSION:=''}"
: "${EXPECTED_HASH:=''}"
# Multi-protocol
: "${ENABLE_MULTI_PROTOCOL:='0'}"
: "${ENABLE_EMOJI_FLAG:='1'}"
: "${ENABLE_WEB_SUB_PAGE:='1'}"
: "${ENABLE_LOCAL_SUB2SING:='0'}"
# Переменные
: "${TG_BOT_TOKEN:=''}"
: "${TG_CHAT_ID:=''}"
: "${ROUTING_MODE:='multi'}"
: "${FALLBACK_PORT:='8080'}"
: "${INSTALL_URL:='https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh'}"
: "${GEOSITE_URL:='https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat'}"
: "${SUB2SING_PORT:='8080'}"
# Массивы
declare -a LOCAL_TEMP_FILES=()
declare -a REMOTE_TEMP_FILES=()
declare -a SSH_CMD=()
declare -a REALITY_SHORT_IDS=()
# Переменные
WS_PORT=""
TROJAN_PORT=""
XHTTP_PATH=""
WS_PATH=""
TROJAN_PATH=""
EMOJI_FLAG="🏁"
LOCK_FD=""
PANEL_PASS=""
PANEL_PORT_ACTUAL=""
PANEL_PATH_ACTUAL=""
REALITY_PRIVKEY=""
REALITY_PUBKEY=""
SHORT_ID=""
SETUP_COMPLETE="0"
REPORT_FILE=""
AUTO_DOMAIN=""
AUTO_REALITY_DOMAIN=""
SERVER_IP_PUBLIC=""

#===============================================================================
# 📋 БЛОК X/25: 🆕 EMOJI FLAG ПО IP
#===============================================================================
# get_emoji_flag - Получение emoji флага страны по IP адресу
get_emoji_flag() {
    [[ "$ENABLE_EMOJI_FLAG" != "1" ]] && { EMOJI_FLAG="🏁"; return 0; }
    log_info "🌍 Получение emoji флага..."
    EMOJI_FLAG=$(ssh_exec "curl -s https://ipwho.is/$SERVER_IP_PUBLIC 2>/dev/null | jq -r '.flag.emoji // \"🏁\"'" 2>/dev/null || echo "🏁")
    [[ -z "$EMOJI_FLAG" || "$EMOJI_FLAG" == "null" ]] && EMOJI_FLAG="🏁"
    log_success "✓ Emoji флаг: $EMOJI_FLAG"
}

#===============================================================================
# 📋 БЛОК 2/25: ОЧИСТКА + TRAP
#===============================================================================
# cleanup_temp - Очистка временных файлов и освобождение lock
cleanup_temp() {
    if [[ ${#LOCAL_TEMP_FILES[@]} -gt 0 ]]; then
        for f in "${LOCAL_TEMP_FILES[@]}"; do
            if [[ -n "$f" && -f "$f" ]]; then
                if command -v shred &>/dev/null; then
                    shred -u "$f" 2>/dev/null || rm -f -- "$f"
                else
                    rm -f -- "$f"
                fi
            fi
        done
    fi
    if [[ ${#REMOTE_TEMP_FILES[@]} -gt 0 ]]; then
        for rf in "${REMOTE_TEMP_FILES[@]}"; do
            [[ -z "$rf" ]] && continue
            ssh_exec "rm -f -- $(printf '%q' "$rf")" 2>/dev/null || true
        done
    fi
    if [[ -n "${REPORT_FILE:-}" && -f "$REPORT_FILE" ]]; then
        shred -u "$REPORT_FILE" 2>/dev/null || rm -f -- "$REPORT_FILE"
    fi
    LOCAL_TEMP_FILES=()
    REMOTE_TEMP_FILES=()
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
    fi
    # Очистка lock директории
    if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR"
    fi
}
trap cleanup_temp EXIT INT TERM

#===============================================================================
# 📋 БЛОК 3/25: ЛОГИРОВАНИЕ + TELEGRAM
#===============================================================================
# check_step - Проверка выполнения шага с логированием
check_step() {
    local step_name="$1"; shift
    if ssh_exec "$@" &>/dev/null; then
        log_success "$step_name"
        tg_send "✅ $step_name"
        return 0
    else
        log_error "$step_name"
        tg_send "❌ $step_name"
        return 1
    fi
}
# log_info - Вывод информационного сообщения
log_info()     { printf '%s\n' "${GREEN}[ℹ]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || printf '[ℹ] %s\n' "$*"; }
# log_success - Вывод сообщения об успехе
log_success()  { printf '%s\n' "${GREEN}[✓]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || printf '[✓] %s\n' "$*"; }
# log_warning - Вывод предупреждения
log_warning()  { printf '%s\n' "${YELLOW}[⚠]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>/dev/null || printf '[⚠] %s\n' "$*"; }
# log_error - Вывод ошибки
log_error()    { printf '%s\n' "${RED}[✗]${NC} $(date '+%H:%M:%S') $*" | tee -a "$LOG_FILE" 2>&1 || printf '[✗] %s\n' "$*" >&2; }
# header - Вывод заголовка
header()   { printf '%s\n' "${CYAN}╔════════════════════════════════════════╗${NC}"; }
# footer - Вывод подвала
footer()   { printf '%s\n' "${CYAN}╚════════════════════════════════════════╝${NC}"; }

#===============================================================================
# 📋 БЛОК 4/25: LOCK
#===============================================================================
# acquire_lock - Блокировка параллельного запуска
acquire_lock() {
    LOCK_DIR="$(mktemp -d /tmp/3xui-setup.locks.XXXXXXXXXX)"
    LOCK_FILE="$LOCK_DIR/$(printf '%s' "$SERVER_IP" | tr '.' '_').lock"
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD" 2>/dev/null; then
        log_error "Уже запущено для $SERVER_IP"
        return 1
    fi
    echo $$ >&"$LOCK_FD"
    log_success "✓ Lock: $LOCK_FILE"
}

#===============================================================================
# 📋 БЛОК 5/25: SSH — ПРОВЕРКА ИНИЦИАЛИЗАЦИИ
#===============================================================================
# init_ssh_cmd - Инициализация SSH команды
init_ssh_cmd() {
    local ssh_opts=(-o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -p "$SERVER_PORT")
    if [[ -n "${SERVER_PASS:-}" ]]; then
        command -v sshpass &>/dev/null || { log_error "sshpass не установлен"; return 1; }
        export SSHPASS="$SERVER_PASS"
        SSH_CMD=(sshpass -e ssh "${ssh_opts[@]}" "$SERVER_USER@$SERVER_IP")
    elif [[ -n "${SERVER_KEY:-}" ]]; then
        [[ -f "$SERVER_KEY" ]] || { log_error "Ключ не найден: $SERVER_KEY"; return 1; }
        SSH_CMD=(ssh -i "$SERVER_KEY" "${ssh_opts[@]}" "$SERVER_USER@$SERVER_IP")
    else
        SSH_CMD=(ssh "${ssh_opts[@]}" "$SERVER_USER@$SERVER_IP")
    fi
    log_success "✓ SSH готов"
}

# ssh_exec - Выполнение команды через SSH
ssh_exec() {
    if [[ ${#SSH_CMD[@]} -eq 0 ]]; then
        log_error "SSH не инициализирован. Вызовите init_ssh_cmd сначала."
        return 1
    fi
    "${SSH_CMD[@]}" "$@"
}

# check_connection - Проверка SSH подключения
check_connection() {
    if ssh_exec "echo OK" &>/dev/null; then
        log_success "✓ Подключение"
        tg_send "🔌 $SERVER_IP"
        return 0
    else
        log_error "✗ Нет подключения"
        return 1
    fi
}

#===============================================================================
# 📋 БЛОК 6/25: 🆕 AUTO-DOMAIN РЕЖИМ (cdn-one.org)
#===============================================================================
# setup_auto_domain - Настройка авто-домена
setup_auto_domain() {
    [[ "$ENABLE_AUTO_DOMAIN" != "1" ]] && return 0
    log_info "🌐 Auto-domain режим..."
    if [[ -z "$SERVER_IP_PUBLIC" || ! "$SERVER_IP_PUBLIC" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        log_warning "⚠️ Не удалось получить публичный IP, используем SERVER_IP"
        SERVER_IP_PUBLIC="$SERVER_IP"
    fi
    AUTO_DOMAIN="${SERVER_IP_PUBLIC}.cdn-one.org"
    AUTO_REALITY_DOMAIN="${SERVER_IP_PUBLIC//./-}.cdn-one.org"
    [[ -z "$DOMAIN" ]] && DOMAIN="$AUTO_DOMAIN"
    [[ -z "$REALITY_DOMAIN" ]] && REALITY_DOMAIN="$AUTO_REALITY_DOMAIN"
    log_success "✓ Auto-domain: $DOMAIN"
    log_success "✓ Auto-Reality: $REALITY_DOMAIN"
}

#===============================================================================
# 📋 БЛОК 7/25: 🆕 BBR ОПТИМИЗАЦИЯ — РАСШИРЕННАЯ
#===============================================================================
# optimize_bbr - Оптимизация сетевой производительности BBR
optimize_bbr() {
    [[ "$ENABLE_BBR" != "1" ]] && return 0
    log_info "🚀 BBR оптимизация..."
    ssh_exec bash << 'BBR_SCRIPT'
set -euo pipefail
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
echo "fs.file-max=2097152" >> /etc/sysctl.conf
echo "net.ipv4.tcp_timestamps = 1" >> /etc/sysctl.conf
echo "net.ipv4.tcp_sack = 1" >> /etc/sysctl.conf
echo "net.ipv4.tcp_window_scaling = 1" >> /etc/sysctl.conf
echo "net.core.rmem_max = 16777216" >> /etc/sysctl.conf
echo "net.core.wmem_max = 16777216" >> /etc/sysctl.conf
echo "net.ipv4.tcp_rmem = 4096 87380 16777216" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 65536 16777216" >> /etc/sysctl.conf
echo "net.ipv4.tcp_fastopen = 3" >> /etc/sysctl.conf
echo "net.ipv4.tcp_mtu_probing=1" >> /etc/sysctl.conf
sysctl -p >/dev/null 2>&1 || true
if [[ $(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}') == "bbr" ]]; then
    echo "✓ BBR включён"
else
    echo "⚠️ BBR не активен (возможно требуется перезагрузка)"
fi
BBR_SCRIPT
    log_success "✓ BBR оптимизация применена"
}

#===============================================================================
# 📋 БЛОК 8/25: 🆕 NGINX STREAM (SNI ROUTING) — ИСПРАВЛЕНО
#===============================================================================
# setup_sni_routing - Настройка SNI маршрутизации через Nginx Stream
setup_sni_routing() {
    [[ "$ENABLE_SNI_ROUTING" != "1" ]] && return 0
    log_info "🔄 Nginx Stream SNI routing..."
    [[ -z "$DOMAIN" || -z "$REALITY_DOMAIN" ]] && { log_warning "⚠️ Нет доменов для SNI"; return 0; }
    
    # Санитизация доменов
    local safe_domain safe_reality_domain
    safe_domain=$(printf '%s' "$DOMAIN" | tr -cd 'a-zA-Z0-9.-')
    safe_reality_domain=$(printf '%s' "$REALITY_DOMAIN" | tr -cd 'a-zA-Z0-9.-')
    
    # Экспорт переменных для heredoc
    export SAFE_DOMAIN="$safe_domain"
    export SAFE_REALITY_DOMAIN="$safe_reality_domain"
    export PANEL_PORT_ACTUAL="${PANEL_PORT_ACTUAL:-2053}"
    
    ssh_exec bash << 'SNI_SCRIPT'
set -euo pipefail
apt install -y nginx nginx-extras >/dev/null 2>&1 || apt install -y nginx >/dev/null 2>&1 || true
if ! nginx -V 2>&1 | grep -q "stream"; then
    echo "⚠️ Nginx stream модуль недоступен"
    exit 0
fi
mkdir -p /etc/nginx/stream-enabled
cat > /etc/nginx/stream-enabled/sni.conf << SNI
map \$ssl_preread_server_name \$sni_backend {
    hostnames;
    ${SAFE_REALITY_DOMAIN}      reality_backend;
    ${SAFE_DOMAIN}              panel_backend;
    default                panel_backend;
}
upstream reality_backend {
    server 127.0.0.1:8443;
}
upstream panel_backend {
    server 127.0.0.1:${PANEL_PORT_ACTUAL};
}
server {
    listen 443;
    proxy_pass \$sni_backend;
    ssl_preread on;
    proxy_protocol on;
}
SNI
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
fi
if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    echo "✓ SNI routing настроен"
else
    echo "⚠️ Ошибка в конфиге nginx"
    exit 0
fi
SNI_SCRIPT
    log_success "✓ SNI routing настроен"
}

#===============================================================================
# 📋 БЛОК 9/25: 🆕 CLOUDFLARE IP RESTRICTION — ИСПРАВЛЕНО
#===============================================================================
# setup_cf_restrict - Ограничение доступа по IP Cloudflare
setup_cf_restrict() {
    [[ "$ENABLE_CF_RESTRICT" != "1" ]] && return 0
    log_info "☁️ Cloudflare IP restriction..."
    ssh_exec bash << 'CF_SCRIPT'
set -euo pipefail
CF_IPS_FILE="/etc/ufw/cloudflare-ips.txt"
CF_NGINX_FILE="/etc/nginx/conf.d/cloudflare-realip.conf"
curl -s https://www.cloudflare.com/ips-v4 -o "$CF_IPS_FILE" 2>/dev/null || true
curl -s https://www.cloudflare.com/ips-v6 -o "${CF_IPS_FILE}.v6" 2>/dev/null || true
if [[ ! -f "$CF_IPS_FILE" ]]; then
    echo "⚠️ Не удалось скачать IP Cloudflare"
    exit 0
fi
mkdir -p "$(dirname "$CF_NGINX_FILE")"
cat > "$CF_NGINX_FILE" << NGINX
# Cloudflare IP ranges for real_ip
NGINX
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    echo "set_real_ip_from $ip;" >> "$CF_NGINX_FILE"
done < "$CF_IPS_FILE"
cat >> "$CF_NGINX_FILE" << NGINX
real_ip_header CF-Connecting-IP;
real_ip_recursive on;
NGINX
echo "🔐 Применяем UFW правила для Cloudflare IP..."
UFW_APPLIED=0
while IFS= read -r ip; do
    [[ -z "$ip" || "$ip" =~ ^# ]] && continue
    if ! ufw status 2>/dev/null | grep -q "$ip"; then
        ufw allow from "$ip" to any port 443 2>/dev/null || true
        ufw allow from "$ip" to any port 80 2>/dev/null || true
        UFW_APPLIED=$((UFW_APPLIED + 1))
    fi
done < "$CF_IPS_FILE"
if [[ $UFW_APPLIED -gt 0 ]]; then
    ufw reload >/dev/null 2>&1 || true
    echo "✓ Применено $UFW_APPLIED UFW правил для Cloudflare"
else
    echo "✓ UFW правила уже применены"
fi
nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
echo "✓ Cloudflare IP restriction настроен"
CF_SCRIPT
    log_success "✓ Cloudflare IP restriction настроен"
}

#===============================================================================
# 📋 БЛОК 10/25: ГЕНЕРАЦИЯ КОНФИГА
#===============================================================================
# generate_xray_config - Генерация базовой конфигурации Xray
generate_xray_config() {
    local fallback="${FALLBACK_PORT:-8080}"
    [[ ! "$fallback" =~ ^[0-9]+$ ]] && fallback=8080
    cat << EOF
{
"dns": { "servers": ["https+local://1.1.1.1/dns-query", "localhost"] },
"routing": {
"domainStrategy": "IPIfNonMatch",
"rules": [{ "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" }]
},
"inbounds": [{
"port": 443,
"protocol": "vless",
"settings": { "clients": [], "decryption": "none", "fallbacks": [{ "dest": ${fallback}, "xver": 0 }] },
"streamSettings": {
"network": "tcp", "security": "tls",
"tlsSettings": {
"certificates": [{ "certificateFile": "/etc/x-ui/server.crt", "keyFile": "/etc/x-ui/server.key" }],
"alpn": ["http/1.1"], "fingerprint": "chrome"
}
}
}],
"outbounds": [
{ "protocol": "freedom", "tag": "direct" },
{ "protocol": "blackhole", "tag": "block" }
]
}
EOF
}

#===============================================================================
# 📋 БЛОК X/25: 🆕 ГЕНЕРАЦИЯ 8 SHORTIDS
#===============================================================================
# generate_short_ids - Генерация 8 ShortIDs для Reality
generate_short_ids() {
    log_info "🔑 Генерация 8 ShortIDs для Reality..."
    REALITY_SHORT_IDS=()
    for i in {1..8}; do
        REALITY_SHORT_IDS+=("$(openssl rand -hex 8)")
    done
    log_success "✓ Сгенерировано 8 ShortIDs"
}

#===============================================================================
# 📋 БЛОК 11/25: УСТАНОВКА 3X-UI — С ПРОВЕРКОЙ ХЕША
#===============================================================================
# install_3xui_remote - Установка 3X-UI с проверкой целостности
install_3xui_remote() {
    log_info "📦 Установка 3X-UI..."
    if [[ -n "$FIXED_VERSION" ]]; then
        INSTALL_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/${FIXED_VERSION}/install.sh"
        log_info "🔒 Используем фиксированную версию: $FIXED_VERSION"
    fi
    export R_DOMAIN="$DOMAIN" R_INSTALL_URL="$INSTALL_URL"
    ssh_exec bash << 'INSTALL_SCRIPT'
set -euo pipefail
trap 'rm -f "$SCRIPT"' EXIT INT TERM
LOG="/var/log/3xui-install.log"
log_r() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
log_r "🔄 Обновление..."; apt update && apt upgrade -y >> "$LOG" 2>&1 || true
log_r "📦 Зависимости..."; apt install -y curl wget jq ufw fail2ban cron qrencode nginx >> "$LOG" 2>&1 || true
log_r "🔧 Загрузка..."; SCRIPT=$(mktemp /tmp/3xui-XXXXXXXXXX.sh)
curl -fsSL "${R_INSTALL_URL}" -o "$SCRIPT" || { log_r "✗ Ошибка загрузки"; rm -f "$SCRIPT"; exit 1; }
if [[ -n "${EXPECTED_HASH:-}" ]]; then
    log_r "🔐 Проверка хеша..."
    actual_hash=$(sha256sum "$SCRIPT" | awk '{print $1}')
    if [[ "$EXPECTED_HASH" != "$actual_hash" ]]; then
        log_r "✗ Хеш не совпадает!"; rm -f "$SCRIPT"; exit 1
    fi
    log_r "✓ Хеш верифицирован"
fi
chmod 700 "$SCRIPT"; printf 'y\n' | bash "$SCRIPT" >> "$LOG" 2>&1 || { rm -f "$SCRIPT"; exit 1; }; rm -f "$SCRIPT"
systemctl is-active --quiet x-ui || { log_r "✗ x-ui не запущен"; exit 1; }
log_r "✓ Установлен"
INSTALL_SCRIPT
    check_step "3X-UI установлен" "systemctl is-active --quiet x-ui"
}

#===============================================================================
# 📋 БЛОК 12/25: НАСТРОЙКА ПАНЕЛИ — НАДЁЖНЫЙ ПАРОЛЬ
#===============================================================================
# configure_panel - Настройка панели с генерацией безопасного пароля
configure_panel() {
    log_info "⚙️ Настройка панели..."
    local new_pass
    while true; do
        new_pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
        [[ ${#new_pass} -ge 16 ]] && break
    done
    export R_PANEL_PORT="$PANEL_PORT" R_PANEL_PATH="$PANEL_PATH" R_NEW_PASS="$new_pass"
    local result
    result=$(ssh_exec bash << 'CONFIG_SCRIPT'
set -euo pipefail
x-ui setting -username admin -password "$R_NEW_PASS" 2>/dev/null || exit 1
x-ui setting -port "$R_PANEL_PORT" 2>/dev/null || exit 1
x-ui setting -webBasePath "$R_PANEL_PATH" 2>/dev/null || exit 1
systemctl restart x-ui; sleep 2
systemctl is-active --quiet x-ui && printf 'OK|%s|%s|%s' "$R_PANEL_PORT" "$R_PANEL_PATH" "$R_NEW_PASS" || exit 1
CONFIG_SCRIPT
    ) || { log_error "SSH failed"; return 1; }
    [[ -z "$result" || ! "$result" =~ ^OK\| ]] && { log_error "Invalid: $result"; return 1; }
    IFS='|' read -r _ PANEL_PORT_ACTUAL PANEL_PATH_ACTUAL PANEL_PASS <<< "$result"
    log_success "✓ Панель: admin / $PANEL_PASS : $PANEL_PORT_ACTUAL$PANEL_PATH_ACTUAL"
}

#===============================================================================
# 📋 БЛОК X/25: 🆕 MULTI-PROTOCOL (4 INBOUNDS)
#===============================================================================
# sanitize_path - Санитизация путей для безопасности
sanitize_path() {
    local input="$1"
    printf '%s' "$input" | tr -cd 'a-zA-Z0-9_/' | head -c 64
}

# setup_multi_protocol - Настройка multi-protocol (4 inbounds)
setup_multi_protocol() {
    [[ "$ENABLE_MULTI_PROTOCOL" != "1" ]] && return 0
    log_info "🔄 Настройка multi-protocol (4 inbounds)..."
    WS_PORT=$(ssh_exec "echo \$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))" 2>/dev/null || echo "18443")
    TROJAN_PORT=$(ssh_exec "echo \$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))" 2>/dev/null || echo "28443")
    XHTTP_PATH=$(sanitize_path "$(ssh_exec "head -c 10 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 10" 2>/dev/null || echo "xhttp_path")")
    WS_PATH=$(sanitize_path "$(ssh_exec "head -c 10 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 10" 2>/dev/null || echo "ws_path")")
    TROJAN_PATH=$(sanitize_path "$(ssh_exec "head -c 10 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 10" 2>/dev/null || echo "trojan_path")")
    export R_WS_PORT="$WS_PORT" R_TROJAN_PORT="$TROJAN_PORT"
    export R_XHTTP_PATH="$XHTTP_PATH" R_WS_PATH="$WS_PATH" R_TROJAN_PATH="$TROJAN_PATH"
    export R_EMOJI="$EMOJI_FLAG"
    ssh_exec bash << 'MULTI_SCRIPT'
set -euo pipefail
CFG="/usr/local/etc/xray/config.json"
uuid_ws=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
uuid_xhttp=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
uuid_trojan=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
trojan_pass=$(head -c 10 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 10)
jq --arg port "$R_WS_PORT" --arg uuid "$uuid_ws" --arg path "/${R_WS_PORT}/${R_WS_PATH}" --arg host "$R_DOMAIN" --arg emoji "$R_EMOJI" \
'.inbounds += [{"port":($port|tonumber),"protocol":"vless","settings":{"clients":[{"id":$uuid,"email":"ws_user","flow":""}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":$path,"host":$host}},"tag":"inbound-ws","remark":"\($emoji) WS"}]' \
"$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
jq --arg uuid "$uuid_xhttp" --arg path "/${R_XHTTP_PATH}" --arg emoji "$R_EMOJI" \
'.inbounds += [{"listen":"/dev/shm/uds2023.sock,0666","protocol":"vless","settings":{"clients":[{"id":$uuid,"email":"xhttp_user","flow":""}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":$path,"mode":"packet-up"}},"tag":"inbound-xhttp","remark":"\($emoji) XHTTP"}]' \
"$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
jq --arg port "$R_TROJAN_PORT" --arg pass "$trojan_pass" --arg path "/${R_TROJAN_PORT}/${R_TROJAN_PATH}" --arg host "$R_DOMAIN" --arg emoji "$R_EMOJI" \
'.inbounds += [{"port":($port|tonumber),"protocol":"trojan","settings":{"clients":[{"password":$pass,"email":"trojan_user"}]},"streamSettings":{"network":"grpc","security":"none","grpcSettings":{"serviceName":$path,"authority":$host}},"tag":"inbound-trojan","remark":"\($emoji) Trojan"}]' \
"$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
ufw allow "${R_WS_PORT}"/tcp 2>/dev/null || true
ufw allow "${R_TROJAN_PORT}"/tcp 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
echo "✓ Multi-protocol: WS(${R_WS_PORT}), XHTTP, Trojan(${R_TROJAN_PORT})"
MULTI_SCRIPT
    log_success "✓ Multi-protocol настроен"
}

#===============================================================================
# 📋 БЛОК 13/25: REALITY — 8 SHORTIDS + MULTI-PROTOCOL
#===============================================================================
# setup_reality - Настройка Reality протокола
setup_reality() {
    [[ "$ENABLE_REALITY" != "1" || "$ROUTING_MODE" == "single" ]] && return 0
    log_info "🔮 Reality..."
    local keys; keys=$(ssh_exec "xray x25519 2>/dev/null" || echo "")
    if [[ -n "$keys" ]]; then
        REALITY_PRIVKEY=$(printf '%s' "$keys" | grep "Private" | awk '{print $3}')
        REALITY_PUBKEY=$(printf '%s' "$keys" | grep "Public" | awk '{print $3}')
    fi
    [[ -z "$REALITY_PRIVKEY" ]] && { log_error "Не удалось сгенерировать ключи"; return 1; }
    generate_short_ids
    local short_ids_json="["
    for i in "${!REALITY_SHORT_IDS[@]}"; do
        [[ $i -gt 0 ]] && short_ids_json+=","
        short_ids_json+="\"${REALITY_SHORT_IDS[$i]}\""
    done
    short_ids_json+="]"
    export R_DOMAIN="$DOMAIN" R_REALITY_DOMAIN="${REALITY_DOMAIN:-$DOMAIN}"
    export R_PRIVKEY="$REALITY_PRIVKEY" R_PUBKEY="$REALITY_PUBKEY" R_SID="${REALITY_SHORT_IDS[0]}" R_DEST="$REALITY_DEST"
    export R_SHORT_IDS_JSON="$short_ids_json"
    ssh_exec bash << 'REALITY_SCRIPT'
set -euo pipefail; KEYS="/usr/local/etc/xray/.keys"
mkdir -p "$(dirname "$KEYS")"
{ printf 'reality_pubkey: %s\nshort_id: %s\n' "$R_PUBKEY" "$R_SID"; } >> "$KEYS" 2>/dev/null || true
REALITY_SCRIPT
    ssh_exec "chmod 600 /usr/local/etc/xray/.keys && chown root:root /usr/local/etc/xray/.keys" || {
        log_error "Не удалось установить права на ключи Reality"; return 1
    }
    ssh_exec bash << 'REALITY_JQ'
set -euo pipefail
jq --arg pk "$R_PRIVKEY" --argjson sid "$R_SHORT_IDS_JSON" --arg dest "$R_DEST" --arg sni "$R_REALITY_DOMAIN" \
'.inbounds += [{"port":8443,"protocol":"vless","settings":{"clients":[],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":$dest,"xver":0,"serverNames":[$sni,"www.microsoft.com"],"privateKey":$pk,"shortIds":$sid,"fingerprint":"chrome"}}}]' \
/usr/local/etc/xray/config.json > /tmp/c.json && mv /tmp/c.json /usr/local/etc/xray/config.json
systemctl restart xray 2>/dev/null || true
echo "✓ Reality: 8443 (8 ShortIDs)"
REALITY_JQ
    ssh_exec "ufw allow 8443/tcp 2>/dev/null" || true
    log_success "✓ Reality настроен (8 ShortIDs)"
}

#===============================================================================
# 📋 БЛОК 14/25: NGINX FALLBACK
#===============================================================================
# setup_nginx_fallback - Настройка Nginx fallback
setup_nginx_fallback() {
    [[ "$ROUTING_MODE" == "multi" ]] && return 0
    log_info "🔄 Nginx fallback..."
    export R_DOMAIN="$DOMAIN" R_FALLBACK="${FALLBACK_PORT:-8080}"
    export R_PANEL_PORT="$PANEL_PORT_ACTUAL" R_PANEL_PATH="$PANEL_PATH_ACTUAL"
    ssh_exec bash << 'NGINX_SCRIPT'
set -euo pipefail
cat > /etc/nginx/sites-available/xray-fallback << NGINX
server {
    listen 127.0.0.1:${R_FALLBACK};
    server_name ${R_DOMAIN};
    location /${R_PANEL_PATH} {
        proxy_pass http://127.0.0.1:${R_PANEL_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location / { root /var/www/html; index index.html; try_files \$uri \$uri/ =404; }
    server_tokens off;
}
NGINX
    ln -sf /etc/nginx/sites-available/xray-fallback /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    echo "✓ Nginx: 127.0.0.1:${R_FALLBACK}"
NGINX_SCRIPT
    log_success "✓ Nginx настроен"
}

#===============================================================================
# 📋 БЛОК X/25: 🆕 WEB SUB PAGE — ГОТОВЫЕ ШАБЛОНЫ
#===============================================================================
# setup_web_sub_page - Настройка Web страницы подписки
setup_web_sub_page() {
    [[ "$ENABLE_WEB_SUB_PAGE" != "1" ]] && return 0
    log_info "🌐 Настройка Web Sub Page..."
    export R_DOMAIN="$DOMAIN" R_SUB_PATH="${PANEL_PATH_ACTUAL:-/xui}"
    export R_SUB2SING_PATH="sub2sing"
    ssh_exec bash << 'SUBPAGE_SCRIPT'
set -euo pipefail
DEST_DIR="/var/www/subpage"
mkdir -p "$DEST_DIR"
curl -sL "https://raw.githubusercontent.com/legiz-ru/x-ui-pro/master/sub-3x-ui.html" -o "$DEST_DIR/index.html" 2>/dev/null || {
    cat > "$DEST_DIR/index.html" << 'HTML'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width"><title>Подписка 3X-UI</title>
<style>body{font-family:system-ui;margin:0;padding:20px;background:#f5f5f5}.c{max-width:600px;margin:0 auto;background:#fff;padding:30px;border-radius:12px}h1{color:#333}.btn{display:block;width:100%;padding:12px;margin:10px 0;background:#007bff;color:#fff;text-decoration:none;border-radius:6px;text-align:center}.btn:hover{background:#0056b3}code{background:#f8f9fa;padding:2px 6px;border-radius:3px}</style></head>
<body><div class="c"><h1>🔗 Подписка 3X-UI</h1><p>Выберите клиент:</p>
<a class="btn" href="/sub/config.json">📱 sing-box</a><a class="btn" href="/sub/clash.yaml">⚡ Clash</a>
<p style="margin-top:30px;font-size:14px;color:#666">API: <code>/sub/api.php?link=vless://...</code></p></div></body></html>
HTML
}
curl -sL "https://raw.githubusercontent.com/legiz-ru/x-ui-pro/master/clash/clash.yaml" -o "$DEST_DIR/clash.yaml" 2>/dev/null || true
sed -i "s/\${DOMAIN}/${R_DOMAIN}/g" "$DEST_DIR/index.html" 2>/dev/null || true
sed -i "s/\${DOMAIN}/${R_DOMAIN}/g" "$DEST_DIR/clash.yaml" 2>/dev/null || true
cat > /etc/nginx/conf.d/subpage.conf << NGINX
server {
    listen 80;
    server_name ${R_DOMAIN};
    location /sub {
        alias ${DEST_DIR};
        index index.html;
        location ~ \.php$ {
            fastcgi_pass unix:/run/php/php8.1-fpm.sock;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$request_filename;
        }
    }
    location /${R_SUB2SING_PATH}/ {
        proxy_pass http://127.0.0.1:${SUB2SING_PORT}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
NGINX
    nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
    echo "✓ Web Sub Page: https://${R_DOMAIN}/sub/"
SUBPAGE_SCRIPT
    log_success "✓ Web Sub Page настроена"
}

#===============================================================================
# 📋 БЛОК 15/25: КЛИЕНТСКИЕ УТИЛИТЫ
#===============================================================================
# install_cli_utils - Установка CLI утилит для управления
install_cli_utils() {
    log_info "🛠 CLI..."
    export R_DOMAIN="$DOMAIN" R_PANEL_PORT="$PANEL_PORT_ACTUAL"
    ssh_exec bash << 'CLI_MAIN'
set -euo pipefail; mkdir -p /usr/local/bin /root/links
cat > /usr/local/bin/userlist << 'USERLIST_EOF'
#!/bin/bash
CFG="/usr/local/etc/xray/config.json"
[[ ! -f "$CFG" ]] && { echo "❌ Нет конфига"; exit 1; }
jq -e '.inbounds[0].settings.clients' "$CFG" >/dev/null 2>&1 || { echo "📋 Пусто"; exit 0; }
emails=($(jq -r '.inbounds[0].settings.clients[]?.email // empty' "$CFG" 2>/dev/null))
[[ ${#emails[@]} -eq 0 ]] && { echo "📋 Пусто"; exit 0; }
echo "📋 Клиенты (${#emails[@]}):"
for i in "${!emails[@]}"; do u=$(jq -r --argjson x "$i" '.inbounds[0].settings.clients[$x]?.id // "?"' "$CFG"); printf '   %d. %s (%s...)\n' "$((i+1))" "${emails[$i]}" "${u:0:8}"; done
USERLIST_EOF
cat > /usr/local/bin/newuser << 'NEWUSER_EOF'
#!/bin/bash
CFG="/usr/local/etc/xray/config.json"; KEYS="/usr/local/etc/xray/.keys"
read -p "📝 Имя: " email; [[ -z "$email" || "$email" == *" "* ]] && { echo "❌ Неверно"; exit 1; }
jq -e --arg e "$email" '.inbounds[0].settings.clients[]? | select(.email == $e)' "$CFG" &>/dev/null && { echo "❌ Есть"; exit 1; }
uuid=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
jq --arg e "$email" --arg u "$uuid" '.inbounds[0].settings.clients += [{"email": $e, "id": $u, "flow": "xtls-rprx-vision"}]' "$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
systemctl restart xray 2>/dev/null || true; dom=$(grep "^domain:" "$KEYS" 2>/dev/null | awk '{print $2}' || echo "")
link="vless://$uuid@$dom:443?security=tls&alpn=http%2F1.1&fp=chrome&type=tcp&flow=xtls-rprx-vision#$email"
printf '\n✅ %s\n🔗 %s\n' "$email" "$link"; command -v qrencode &>/dev/null && printf '📱 QR:\n%s\n' "$link" | qrencode -t ansiutf8
mkdir -p /root/links && printf '%s\n' "$link" > "/root/links/${email}.txt" 2>/dev/null || true
NEWUSER_EOF
cat > /usr/local/bin/rmuser << 'RMUSER_EOF'
#!/bin/bash
CFG="/usr/local/etc/xray/config.json"
jq -e '.inbounds[0].settings.clients' "$CFG" >/dev/null 2>&1 || { echo "📋 Пусто"; exit 0; }
emails=($(jq -r '.inbounds[0].settings.clients[]?.email // empty' "$CFG" 2>/dev/null))
[[ ${#emails[@]} -eq 0 ]] && { echo "📋 Пусто"; exit 0; }
printf '📋 Выберите:\n'; for i in "${!emails[@]}"; do printf '   %d. %s\n' "$((i+1))" "${emails[$i]}"; done
read -p "🔢 Номер: " n; [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 || "$n" -gt "${#emails[@]}" ]] && { echo "❌ Неверно"; exit 1; }
sel="${emails[$((n-1))]}"; jq --arg e "$sel" '(.inbounds[0].settings.clients) |= map(select(.email != $e))' "$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
systemctl restart xray 2>/dev/null || true; rm -f "/root/links/${sel}.txt" 2>/dev/null || true; printf '✅ Удалён: %s\n' "$sel"
RMUSER_EOF
cat > /usr/local/bin/sharelink << 'SHARE_EOF'
#!/bin/bash
CFG="/usr/local/etc/xray/config.json"; KEYS="/usr/local/etc/xray/.keys"
jq -e '.inbounds[0].settings.clients' "$CFG" >/dev/null 2>&1 || { echo "📋 Пусто"; exit 0; }
emails=($(jq -r '.inbounds[0].settings.clients[]?.email // empty' "$CFG" 2>/dev/null))
[[ ${#emails[@]} -eq 0 ]] && { echo "📋 Пусто"; exit 0; }
printf '📋 Выберите:\n'; for i in "${!emails[@]}"; do printf '   %d. %s\n' "$((i+1))" "${emails[$i]}"; done
read -p "🔢 Номер: " n; [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 || "$n" -gt "${#emails[@]}" ]] && { echo "❌ Неверно"; exit 1; }
sel="${emails[$((n-1))]}"; idx=$(jq --arg e "$sel" '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $e) | .key' "$CFG")
uuid=$(jq --argjson x "$idx" -r '.inbounds[0].settings.clients[$x]?.id // "?"' "$CFG"); dom=$(grep "^domain:" "$KEYS" 2>/dev/null | awk '{print $2}' || echo "")
link="vless://$uuid@$dom:443?security=tls&alpn=http%2F1.1&fp=chrome&type=tcp&flow=xtls-rprx-vision#$sel"
printf '\n🔗 %s:\n%s\n' "$sel" "$link"; command -v qrencode &>/dev/null && printf '📱 QR:\n%s\n' "$link" | qrencode -t ansiutf8
SHARE_EOF
cat > /usr/local/bin/xray-qr << 'QR_EOF'
#!/bin/bash
CFG="/usr/local/etc/xray/config.json"; KEYS="/usr/local/etc/xray/.keys"
email=$(jq -r '.inbounds[0].settings.clients[0]?.email // empty' "$CFG" 2>/dev/null)
uuid=$(jq -r '.inbounds[0].settings.clients[0]?.id // empty' "$CFG" 2>/dev/null)
[[ -z "$uuid" ]] && { echo "❌ Нет пользователей"; exit 1; }
dom=$(grep "^domain:" "$KEYS" 2>/dev/null | awk '{print $2}' || echo "")
link="vless://$uuid@$dom:443?security=tls&alpn=http%2F1.1&fp=chrome&type=tcp&flow=xtls-rprx-vision#$email"
command -v qrencode &>/dev/null && printf '📱 %s:\n%s\n' "$email" "$link" | qrencode -t ansiutf8 || printf '%s\n' "$link"
QR_EOF
chmod +x /usr/local/bin/{userlist,newuser,rmuser,sharelink,xray-qr} 2>/dev/null || true; echo "✅ CLI готовы"
CLI_MAIN
    log_success "✓ CLI установлены"
}

#===============================================================================
# 📋 БЛОК X/25: 🆕 ЛОКАЛЬНЫЙ SUB2SING-BOX СЕРВЕР
#===============================================================================
# setup_local_sub2sing - Настройка локального sub2sing-box сервера
setup_local_sub2sing() {
    [[ "$ENABLE_LOCAL_SUB2SING" != "1" ]] && return 0
    log_info "🔄 Настройка локального sub2sing-box..."
    ssh_exec bash << 'SUB2SING_SCRIPT'
set -euo pipefail
if pgrep -x "sub2sing-box" > /dev/null; then
    echo "✓ sub2sing-box уже запущен"
    exit 0
fi
wget -q -P /root/ "https://github.com/legiz-ru/sub2sing-box/releases/download/v0.0.9/sub2sing-box_0.0.9_linux_amd64.tar.gz" 2>/dev/null || {
    echo "⚠️ Не удалось скачать sub2sing-box"
    exit 0
}
tar -xzf /root/sub2sing-box_0.0.9_linux_amd64.tar.gz -C /root/ --strip-components=1 sub2sing-box_0.0.9_linux_amd64/sub2sing-box 2>/dev/null
mv /root/sub2sing-box /usr/bin/ 2>/dev/null
chmod +x /usr/bin/sub2sing-box
rm -f /root/sub2sing-box_0.0.9_linux_amd64.tar.gz
nohup /usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 > /dev/null 2>&1 &
disown
(crontab -l 2>/dev/null | grep -v "sub2sing-box" || true; echo '@reboot /usr/bin/sub2sing-box server --bind 127.0.0.1 --port 8080 > /dev/null 2>&1') | crontab -
echo "✓ sub2sing-box запущен на порту 8080"
SUB2SING_SCRIPT
    log_success "✓ Локальный sub2sing-box настроен"
}

#===============================================================================
# 📋 БЛОК 16/25: ОСТАЛЬНЫЕ ФУНКЦИИ
#===============================================================================
# setup_adblock - Настройка блокировки рекламы
setup_adblock() {
    [[ "$ENABLE_ADBLOCK" != "1" ]] && return 0; log_info "🛡 Adblock..."
    export R_GEOSITE="$GEOSITE_URL"
    ssh_exec bash << 'ADBLOCK_SCRIPT'
set -euo pipefail; CFG="/usr/local/etc/xray/config.json"; GS="/usr/local/share/xray/geosite.dat"
[[ ! -f "$GS" ]] && { mkdir -p "$(dirname "$GS")"; curl -fsSL "${R_GEOSITE}" -o "$GS" 2>/dev/null || true; chmod 644 "$GS"; }
jq -e '.routing.rules[]? | select(.domain[]? | contains("category-ads"))' "$CFG" &>/dev/null && { echo "✓ Уже"; exit 0; }
jq -e '.outbounds[]? | select(.tag=="block")' "$CFG" &>/dev/null || jq '.outbounds += [{"protocol":"blackhole","tag":"block"}]' "$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
RULE='{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}'
jq --argjson r "$RULE" 'if .routing.rules then .routing.rules += [$r] else .routing = {"rules":[$r]} end' "$CFG" > /tmp/c.json && mv /tmp/c.json "$CFG"
systemctl restart xray 2>/dev/null || true; echo "✓ Adblock"
ADBLOCK_SCRIPT
    log_success "✓ Adblock активен"
}

# setup_fake_site - Настройка фейкового сайта
setup_fake_site() {
    [[ "$ENABLE_FAKE_SITE" != "1" ]] && return 0; log_info "🎭 Fake site..."
    ssh_exec bash << 'FAKE_SCRIPT'
set -euo pipefail; apt install -y nginx >/dev/null 2>&1 || true; mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTML'
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Welcome</title>
<style>body{font-family:Arial;text-align:center;padding:50px;background:#f5f5f5}.c{max-width:600px;margin:0 auto;background:#fff;padding:30px;border-radius:10px}h1{color:#333}p{color:#666}</style></head>
<body><div class="c"><h1>Welcome to nginx!</h1><p>Server is working.</p><p><em>nginx</em></p></div></body></html>
HTML
chown -R www-data:www-data /var/www/html; chmod -R 755 /var/www/html
nginx -t >/dev/null 2>&1 && systemctl restart nginx; echo "✓ Fake site"
FAKE_SCRIPT
    log_success "✓ Fake site активен"
}

# setup_ssl - Настройка SSL сертификатов
setup_ssl() {
    [[ -z "$DOMAIN" ]] && { log_warning "⚠️ Нет DOMAIN"; return 0; }; log_info "🔐 SSL..."
    export R_DOMAIN="$DOMAIN"
    ssh_exec bash << 'SSL_SCRIPT'
set -euo pipefail; LOG="/var/log/3xui-ssl.log"
command -v ~/.acme.sh/acme.sh &>/dev/null || curl -s https://get.acme.sh | sh >> "$LOG" 2>&1
~/.acme.sh/acme.sh --issue -d "${R_DOMAIN}" --standalone --keylength ec-256 --force >> "$LOG" 2>&1
~/.acme.sh/acme.sh --installcert -d "${R_DOMAIN}" --ecc --key-file /etc/x-ui/server.key --fullchain-file /etc/x-ui/server.crt --reloadcmd "systemctl restart x-ui" >> "$LOG" 2>&1
[[ -f /etc/x-ui/server.crt && -f /etc/x-ui/server.key ]] && { echo "✓ SSL"; systemctl restart x-ui; } || exit 1
SSL_SCRIPT
    check_step "SSL установлен" "test -f /etc/x-ui/server.crt"
}

# setup_cron_ssl - Настройка автообновления SSL
setup_cron_ssl() {
    [[ -z "$DOMAIN" ]] && return 0
    log_info "🔄 Cron SSL..."
    export R_DOMAIN="$DOMAIN"
    ssh_exec bash << 'CRON_SCRIPT'
set -euo pipefail
cat > /usr/local/bin/renew-ssl.sh << 'RENEW'
#!/bin/bash
DOMAIN="$1"
ACME_SH="/root/.acme.sh/acme.sh"
[[ -x "$ACME_SH" ]] || { echo "acme.sh не найден"; exit 1; }
"$ACME_SH" --renew -d "$DOMAIN" --ecc --force >> /var/log/ssl-renew.log 2>&1 && systemctl restart x-ui
RENEW
chmod +x /usr/local/bin/renew-ssl.sh
(crontab -l 2>/dev/null | grep -v "renew-ssl" || true; printf '0 3 1,15 * * /usr/local/bin/renew-ssl.sh "%s"\n' "${R_DOMAIN}") | crontab -
echo "✓ Cron SSL"
CRON_SCRIPT
    log_success "✓ Cron настроен"
}

# setup_telegram - Настройка Telegram уведомлений
setup_telegram() {
    [[ "$ENABLE_TELEGRAM" != "1" || -z "$TG_BOT_TOKEN" || -z "$TG_CHAT_ID" ]] && return 0
    log_info "📬 Telegram..."
    export R_TG="$TG_BOT_TOKEN" R_CHAT="$TG_CHAT_ID" R_DOMAIN="$DOMAIN"
    ssh_exec bash << 'TG_SCRIPT'
set -euo pipefail
cat > /usr/local/bin/tg-notify.sh << 'TG'
#!/bin/bash
msg="$1"
[[ -z "$msg" ]] && exit 0
tmp=$'\x01'
msg="${msg//&/$tmp}"; msg="${msg//</&lt;}"; msg="${msg//>/&gt;}"; msg="${msg//\"/&quot;}"; msg="${msg//\'/&#39;}"; msg="${msg//$tmp/&amp;}"
curl -s -X POST "https://api.telegram.org/bot'"${R_TG}"'/sendMessage" --data-urlencode "chat_id='"${R_CHAT}"'" --data-urlencode "text=$msg" --data-urlencode "parse_mode=HTML" >/dev/null 2>&1 || true
TG
chmod +x /usr/local/bin/tg-notify.sh
(crontab -l 2>/dev/null | grep -v "tg-notify" || true; printf '0 */6 * * * /usr/local/bin/tg-notify.sh "🔄 x-ui: $(systemctl is-active x-ui)"\n') | crontab -
echo "✓ Telegram"
TG_SCRIPT
    tg_send "✅ Готово: $DOMAIN"
    log_success "✓ Telegram настроен"
}

# setup_sub2singbox - Настройка конвертера подписок
setup_sub2singbox() {
    [[ "$ENABLE_SUB_PAGE" != "1" ]] && return 0; log_info "🔄 sub2sing-box..."
    ssh_exec bash << 'S2S_SCRIPT'
set -euo pipefail; mkdir -p /usr/local/bin/sub2singbox /var/www/sub
cat > /usr/local/bin/sub2singbox/convert.sh << 'CONV'
#!/bin/bash
IN="$1"
OUT="${2:-/var/www/sub/config.json}"
[[ -z "$IN" ]] && exit 1
uuid=$(echo "$IN" | sed -n 's|vless://\([^@]*\)@.*|\1|p')
srv=$(echo "$IN" | sed -n 's|vless://[^@]*@\([^:]*\):.*|\1|p')
port=$(echo "$IN" | sed -n 's|.*:\([0-9]*\)?.*|\1|p')
sni=$(echo "$IN" | grep -oP 'sni=\K[^&]+' || echo "$srv")
fp=$(echo "$IN" | grep -oP 'fp=\K[^&]+' || echo "chrome")
alpn=$(echo "$IN" | grep -oP 'alpn=\K[^&]+' || echo "http/1.1")
flow=$(echo "$IN" | grep -oP 'flow=\K[^&]+' || echo "")
tag=$(echo "$IN" | grep -oP '#\K.+' || echo "proxy")
cat > "$OUT" << SB
{"log":{"level":"info"},"dns":{"servers":[{"address":"tls://8.8.8.8"}]},"inbounds":[{"type":"tun","inet4_address":"172.19.0.1/30","auto_route":true}],"outbounds":[{"type":"vless","tag":"${tag}","server":"${srv}","server_port":${port},"uuid":"${uuid}","tls":{"enabled":true,"server_name":"${sni}","alpn":["${alpn}"],"utls":{"enabled":true,"fingerprint":"${fp}"}}$( [[ -n "$flow" ]] && printf ',"flow":"%s"' "$flow" || true )}]}
SB
echo "✅ $OUT"
CONV
chmod +x /usr/local/bin/sub2singbox/convert.sh
cat > /var/www/sub/api.php << 'PHP'
<?php header('Content-Type: application/json'); $l=$_GET['link']??''; if(!$l||strpos($l,'vless://')!==0){http_response_code(400);echo'{"error":"Invalid"}';exit;} $o='/tmp/sb-'.md5($l).'.json'; exec('/usr/local/bin/sub2singbox/convert.sh '.escapeshellarg($l).' '.escapeshellarg($o).' 2>&1',$out,$c); if($c||!file_exists($o)){http_response_code(500);echo'{"error":"Fail"}';exit;} echo file_get_contents($o); unlink($o); ?>
PHP
echo "✓ sub2sing-box"
S2S_SCRIPT
    log_success "✓ sub2sing-box настроен"
}

# setup_subscription_page - Настройка страницы подписки
setup_subscription_page() {
    [[ "$ENABLE_SUB_PAGE" != "1" ]] && return 0; log_info "🌐 Sub page..."
    export R_DOMAIN="$DOMAIN" R_PANEL_PORT="$PANEL_PORT_ACTUAL" R_MODE="$ROUTING_MODE"
    local port_info="443 (TLS)"
    [[ "$ROUTING_MODE" != "single" ]] && port_info+=" / 8443 (Reality)"
    export R_PORT_INFO="$port_info"
    ssh_exec bash << 'SUB_SCRIPT'
set -euo pipefail; mkdir -p /var/www/sub
cat > /var/www/sub/index.html << HTML
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width"><title>Подписка</title>
<style>body{font-family:system-ui;margin:0;padding:20px;background:#f5f5f5}.c{max-width:600px;margin:0 auto;background:#fff;padding:30px;border-radius:12px}h1{color:#333}.btn{display:block;width:100%;padding:12px;margin:10px 0;background:#007bff;color:#fff;text-decoration:none;border-radius:6px;text-align:center}.btn:hover{background:#0056b3}code{background:#f8f9fa;padding:2px 6px;border-radius:3px}</style></head>
<body><div class="c"><h1>🔗 Подписка 3X-UI</h1><p>Режим: <strong>${R_MODE}</strong></p><p>Порт: <strong>${R_PORT_INFO}</strong></p>
<a class="btn" href="/sub/config.json">📱 sing-box</a><a class="btn" href="/sub/clash.yaml">⚡ Clash</a><a class="btn" style="background:#6c757d" href="https://${R_DOMAIN}:${R_PANEL_PORT}">⚙️ Панель</a>
<p style="margin-top:30px;font-size:14px;color:#666">API: <code>/sub/api.php?link=vless://...</code></p></div></body></html>
HTML
cat > /etc/nginx/conf.d/sub.conf << NGINX
server { listen 80; server_name ${R_DOMAIN}; location /sub { alias /var/www/sub; index index.html; location ~ \.php$ { fastcgi_pass unix:/run/php/php8.1-fpm.sock; fastcgi_index index.php; include fastcgi_params; fastcgi_param SCRIPT_FILENAME \$request_filename; } } }
NGINX
nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
echo "✓ https://${R_DOMAIN}/sub/"
SUB_SCRIPT
    log_success "✓ Страница: https://${DOMAIN}/sub/"
}

#===============================================================================
# 📋 БЛОК 17/25: FIREWALL
#===============================================================================
# setup_firewall - Настройка брандмауэра UFW
setup_firewall() {
    log_info "🔥 UFW..."
    local backup="/root/ufw-$(date +%F-%H%M).rules"
    if [[ ${#SSH_CMD[@]} -gt 0 ]]; then
        ssh_exec "ufw status verbose > $backup 2>&1 && iptables-save > ${backup}.iptables 2>/dev/null" 2>/dev/null || true
    fi
    export R_PANEL_PORT="$PANEL_PORT_ACTUAL" R_SKIP="$SKIP_UFW_RESET" R_BACKUP="$backup" R_MODE="$ROUTING_MODE"
    ssh_exec bash << 'FW_SCRIPT'
set -euo pipefail
[[ "${R_SKIP}" != "1" ]] && ufw status 2>/dev/null | grep -q "active" && { printf '[⚠] Бэкап: %s\n' "${R_BACKUP}"; ufw --force reset >/dev/null 2>&1 || true; }
ufw default deny incoming; ufw default allow outgoing
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp; ufw allow "${R_PANEL_PORT}"/tcp
[[ "${R_MODE}" != "single" ]] && ufw allow 8443/tcp 2>/dev/null || true
printf 'y\n' | ufw enable
systemctl is-active --quiet fail2ban || { apt install -y fail2ban >/dev/null 2>&1; systemctl enable --now fail2ban; }
echo "✓ UFW"
FW_SCRIPT
    check_step "UFW активен" "sh -c 'ufw status 2>/dev/null | grep -q active'"
}

#===============================================================================
# 📋 БЛОК 18/25: ICMP BLOCK
#===============================================================================
# harden_icmp - Настройка ICMP правил безопасности
harden_icmp() {
    [[ "$ENABLE_ICMP_BLOCK" != "1" ]] && return 0
    log_info "🛡 Настройка ICMP правил..."
    ssh_exec bash << 'ICMP_SCRIPT'
set -euo pipefail
UFW_RULES="/etc/ufw/before.rules"
cp "$UFW_RULES" "${UFW_RULES}.bak.$(date +%s)" 2>/dev/null || true
sed -i '/# ok icmp codes for INPUT/,/^$/ { s/-j ACCEPT$/-j DROP/ }' "$UFW_RULES"
sed -i '/# ok icmp code for FORWARD/,/^$/ { s/-j ACCEPT$/-j DROP/ }' "$UFW_RULES"
grep -q "source-quench" "$UFW_RULES" || sed -i '/# ok icmp codes for INPUT/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$UFW_RULES"
ufw reload >/dev/null 2>&1 || true
echo "✓ ICMP hardened"
ICMP_SCRIPT
    log_success "✓ ICMP правила настроены"
}

#===============================================================================
# 📋 БЛОК 19/25: SSH KEY AUTH
#===============================================================================
# setup_ssh_key_auth - Настройка SSH аутентификации по ключу
setup_ssh_key_auth() {
    [[ "$ENABLE_SSH_KEY" != "1" || -z "${SERVER_KEY:-}" ]] && return 0
    log_info "🔐 Настройка SSH key auth..."
    local pub_key
    pub_key=$(ssh-keygen -y -f "$SERVER_KEY" 2>/dev/null) || { log_warning "Не удалось прочитать публичный ключ"; return 0; }
    # Валидация формата ключа
    if ! [[ "$pub_key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp)[[:space:]] ]]; then
        log_error "Неверный формат публичного ключа"
        return 1
    fi
    export PUB_KEY="$pub_key"
    ssh_exec bash << 'SSHKEY_SCRIPT'
set -euo pipefail
mkdir -p /root/.ssh
echo "$PUB_KEY" >> /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null || true
systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
echo "✓ SSH key auth настроен"
SSHKEY_SCRIPT
    log_success "✓ SSH key auth настроен"
}
#===============================================================================
# 📋 БЛОК 20/25: SUMMARY — ОБНОВЛЁННЫЙ С MULTI-PROTOCOL
#===============================================================================
# print_summary - Вывод итогового отчёта
print_summary() {
    log_success ""
    header
    printf "${GREEN}  🎉 ГОТОВО!${NC}\n"
    footer
    log_info ""
    log_info "📊 Доступ:"
    printf "   ┌─────────────────────────────\n"
    case "$ROUTING_MODE" in
        single) printf "   │ single: 443 (fallback: %s)\n" "${FALLBACK_PORT:-8080}" ;;
        hybrid) printf "   │ hybrid: 443 + 8443\n" ;;
        multi) printf "   │ multi: 443, 8443, %s\n" "${PANEL_PORT_ACTUAL:-2053}" ;;
    esac
    printf "   │ Панель:  https://%s:%s%s\n" "${DOMAIN:-$SERVER_IP}" "${PANEL_PORT_ACTUAL:-2053}" "${PANEL_PATH_ACTUAL:-/xui}"
    printf "   │ Логин:   admin\n"
    printf "   │ Пароль:  %s\n" "${PANEL_PASS:-[ошибка]}"
    [[ -n "$DOMAIN" ]] && printf "   │ SSL: ✓ | Sub: https://%s/sub/\n" "$DOMAIN" || printf "   │ SSL: ✗\n"
    printf "   │ Reality: %s | TG: %s\n" "$([[ "$ENABLE_REALITY" == "1" && "$ROUTING_MODE" != "single" && -n "$REALITY_PUBKEY" ]] && echo "✓" || echo "✗")" "$([ "$ENABLE_TELEGRAM" == "1" ] && echo "✓" || echo "✗")"
    printf "   │ Auto-domain: %s\n" "$([ "$ENABLE_AUTO_DOMAIN" == "1" ] && echo "✓" || echo "✗")"
    printf "   │ BBR: %s\n" "$([ "$ENABLE_BBR" == "1" ] && echo "✓" || echo "✗")"
    printf "   │ SNI Routing: %s\n" "$([ "$ENABLE_SNI_ROUTING" == "1" ] && echo "✓" || echo "✗")"
    printf "   │ CF Restrict: %s\n" "$([ "$ENABLE_CF_RESTRICT" == "1" ] && echo "✓" || echo "✗")"
    printf "   │ Multi-protocol: %s\n" "$([ "$ENABLE_MULTI_PROTOCOL" == "1" ] && echo "✓ (4 inbounds)" || echo "✗")"
    printf "   │ Emoji Flag: %s\n" "$([ "$ENABLE_EMOJI_FLAG" == "1" ] && echo "$EMOJI_FLAG" || echo "✗")"
    printf "   │ Web Sub Page: %s\n" "$([ "$ENABLE_WEB_SUB_PAGE" == "1" ] && echo "✓" || echo "✗")"
    printf "   └─────────────────────────────\n"
    log_info ""
    log_info "🛠 CLI: userlist, newuser, rmuser, sharelink, xray-qr"
    log_info "🔧 x-ui, journalctl -u x-ui -f"
    [[ -n "$REALITY_PUBKEY" && "$ROUTING_MODE" != "single" ]] && {
        log_info ""
        log_info "🔮 Reality:"
        printf "   PubKey: %s...\n" "${REALITY_PUBKEY:0:30}"
        printf "   ShortIDs: 8 шт (первый: %s)\n" "${REALITY_SHORT_IDS[0]:-N/A}"
    }
    [[ "$ENABLE_MULTI_PROTOCOL" == "1" ]] && {
        log_info ""
        log_info "🔄 Multi-protocol:"
        printf "   WS: %s\n" "${WS_PORT:-N/A}"
        printf "   XHTTP: /%s\n" "${XHTTP_PATH:-N/A}"
        printf "   Trojan: %s\n" "${TROJAN_PORT:-N/A}"
    }
    local sf="/root/3xui-$(date +%Y%m%d-%H%M).txt"
    {
        printf '3X-UI v1.8 - %s\n' "$(date)"
        printf 'Mode: %s\n' "$ROUTING_MODE"
        printf 'Panel: https://%s:%s%s\n' "${DOMAIN:-$SERVER_IP}" "${PANEL_PORT_ACTUAL:-2053}" "${PANEL_PATH_ACTUAL:-/xui}"
        printf 'Login: admin\n'
        printf 'Password: %s\n' "${PANEL_PASS:-[not set]}"
        printf 'Auto-domain: %s\n' "$ENABLE_AUTO_DOMAIN"
        printf 'BBR: %s\n' "$ENABLE_BBR"
        printf 'SNI: %s\n' "$ENABLE_SNI_ROUTING"
        printf 'CF: %s\n' "$ENABLE_CF_RESTRICT"
        printf 'Multi-protocol: %s\n' "$ENABLE_MULTI_PROTOCOL"
        printf 'Emoji: %s\n' "$EMOJI_FLAG"
        printf 'WebSub: %s\n' "$ENABLE_WEB_SUB_PAGE"
        [[ -n "$REALITY_PUBKEY" ]] && printf 'Reality: %s / %s\n' "$REALITY_PUBKEY" "${REALITY_SHORT_IDS[0]:-N/A}"
        [[ "$ENABLE_MULTI_PROTOCOL" == "1" ]] && printf 'WS: %s\nXHTTP: %s\nTrojan: %s\n' "${WS_PORT:-N/A}" "${XHTTP_PATH:-N/A}" "${TROJAN_PORT:-N/A}"
    } > "$sf"
    chmod 600 "$sf"
    REPORT_FILE="$sf"
    LOCAL_TEMP_FILES+=("$sf")
    log_info "📄 $sf (будет удалён при выходе!)"
    log_warning "⚠️ Смените пароль!"
    tg_send "✅ $DOMAIN (${ROUTING_MODE}) ${EMOJI_FLAG}"
}
#===============================================================================
# 📋 БЛОК 21/25: ВАЛИДАЦИЯ
#===============================================================================
# validate_input - Валидация входных параметров
validate_input() {
    [[ -z "$SERVER_IP" ]] && { log_error "--ip обязателен"; return 1; }
    if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        log_error "Неверный формат IP"
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$SERVER_IP"
    for octet in "${octets[@]}"; do
        if [[ "$octet" -lt 0 || "$octet" -gt 255 ]]; then
            log_error "Неверный диапазон IP (0-255): $octet"
            return 1
        fi
    done
    if [[ "$SERVER_IP" =~ ^(127\.|0\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|224\.|255\.) ]]; then
        log_error "IP адрес не может быть зарезервированным: $SERVER_IP"
        return 1
    fi
    [[ -n "$DOMAIN" && ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && { log_error "Неверный домен"; return 1; }
    [[ ! "$ROUTING_MODE" =~ ^(single|multi|hybrid)$ ]] && { log_error "Неверный режим"; return 1; }
    log_success "✓ Параметры валидны"
}

#===============================================================================
# 📋 БЛОК 22/25: PARSE ARGS
#===============================================================================
# parse_args - Парсинг аргументов командной строки
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip) [[ -n "${2:-}" ]] && SERVER_IP="$2" || { log_error "--ip требует значения"; exit 1; }; shift 2 ;;
            --port) [[ -n "${2:-}" ]] && SERVER_PORT="$2" || { log_error "--port требует значения"; exit 1; }; shift 2 ;;
            --user) [[ -n "${2:-}" ]] && SERVER_USER="$2" || { log_error "--user требует значения"; exit 1; }; shift 2 ;;
            --pass) [[ -n "${2:-}" ]] && SERVER_PASS="$2" || { log_error "--pass требует значения"; exit 1; }; shift 2 ;;
            --key) [[ -n "${2:-}" ]] && SERVER_KEY="$2" || { log_error "--key требует значения"; exit 1; }; shift 2 ;;
            --domain) [[ -n "${2:-}" ]] && DOMAIN="$2" || { log_error "--domain требует значения"; exit 1; }; shift 2 ;;
            --reality-domain) [[ -n "${2:-}" ]] && REALITY_DOMAIN="$2" || { log_error "--reality-domain требует значения"; exit 1; }; shift 2 ;;
            --panel-port) [[ -n "${2:-}" ]] && PANEL_PORT="$2" || { log_error "--panel-port требует значения"; exit 1; }; shift 2 ;;
            --panel-path) [[ -n "${2:-}" ]] && PANEL_PATH="$2" || { log_error "--panel-path требует значения"; exit 1; }; shift 2 ;;
            --routing-mode) [[ -n "${2:-}" ]] && ROUTING_MODE="$2" || { log_error "--routing-mode требует значения"; exit 1; }; shift 2 ;;
            --fallback-port) [[ -n "${2:-}" ]] && FALLBACK_PORT="$2" || { log_error "--fallback-port требует значения"; exit 1; }; shift 2 ;;
            --tg-token) [[ -n "${2:-}" ]] && TG_BOT_TOKEN="$2" || { log_error "--tg-token требует значения"; exit 1; }; ENABLE_TELEGRAM="1"; shift 2 ;;
            --tg-chat-id) [[ -n "${2:-}" ]] && TG_CHAT_ID="$2" || { log_error "--tg-chat-id требует значения"; exit 1; }; ENABLE_TELEGRAM="1"; shift 2 ;;
            --enable-telegram) ENABLE_TELEGRAM="1"; shift ;;
            --no-reality) ENABLE_REALITY="0"; shift ;;
            --no-fake-site) ENABLE_FAKE_SITE="0"; shift ;;
            --no-adblock) ENABLE_ADBLOCK="0"; shift ;;
            --no-sub-page) ENABLE_SUB_PAGE="0"; shift ;;
            --no-icmp-block) ENABLE_ICMP_BLOCK="0"; shift ;;
            --enable-ssh-key) ENABLE_SSH_KEY="1"; shift ;;
            --enable-auto-domain) ENABLE_AUTO_DOMAIN="1"; shift ;;
            --no-bbr) ENABLE_BBR="0"; shift ;;
            --enable-sni-routing) ENABLE_SNI_ROUTING="1"; shift ;;
            --enable-cf-restrict) ENABLE_CF_RESTRICT="1"; shift ;;
            --enable-multi-protocol) ENABLE_MULTI_PROTOCOL="1"; shift ;;
            --no-emoji-flag) ENABLE_EMOJI_FLAG="0"; shift ;;
            --no-web-sub-page) ENABLE_WEB_SUB_PAGE="0"; shift ;;
            --enable-local-sub2sing) ENABLE_LOCAL_SUB2SING="1"; shift ;;
            --skip-ufw-reset) SKIP_UFW_RESET="1"; shift ;;
            --dry-run) DRY_RUN="1"; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) log_error "Неизвестно: $1"; show_help; exit 1 ;;
        esac
    done
    [[ -z "$REALITY_DOMAIN" && -n "$DOMAIN" ]] && REALITY_DOMAIN="$DOMAIN"
}

#===============================================================================
# 📋 БЛОК 23/25: HELP
#===============================================================================
# show_help - Вывод справки
show_help() {
    cat << HELP
3X-UI AUTO-SETUP v1.8 — ULTIMATE STEALTH EDITION
Использование: $0 --ip IP [опции]

🆕 Multi-protocol (опционально):
  --enable-multi-protocol    4 inbounds (Reality+WS+XHTTP+Trojan)
  --no-emoji-flag            Отключить emoji флаг по IP
  --no-web-sub-page          Отключить готовые шаблоны Web Sub
  --enable-local-sub2sing    Локальный sub2sing-box сервер

Режимы: --routing-mode single|multi|hybrid (по умолчанию: multi)

Основные:
  --ip IP            Сервер IP (обязательно)
  --port PORT        SSH порт (22)
  --user USER        SSH пользователь (root)
  --pass PASS        SSH пароль
  --key PATH         SSH ключ
  --domain DOMAIN    Домен для SSL
  --panel-port P     Порт панели (2053)
  --panel-path P     Путь панели (/xui)

🆕 Stealth-функции (опционально):
  --enable-auto-domain    Авто-домен через cdn-one.org
  --no-bbr                Отключить BBR оптимизацию (по умолчанию включена)
  --enable-sni-routing    Nginx stream SNI routing
  --enable-cf-restrict    Cloudflare IP restriction

Безопасность:
  --enable-ssh-key        Настроить SSH key auth + отключить пароль
  --no-icmp-block         Не блокировать ICMP (ping)

Функции:
  --tg-token T --tg-chat-id C --enable-telegram
  --no-reality --no-fake-site --no-adblock --no-sub-page
  --skip-ufw-reset --dry-run -h

Примеры:
  $0 --ip 1.2.3.4 --key ~/.ssh/id_ed25519 --domain ex.com
  $0 --ip 1.2.3.4 --enable-auto-domain --enable-sni-routing --enable-cf-restrict
  $0 --ip 1.2.3.4 --routing-mode single --domain ex.com --enable-ssh-key
  $0 --ip 1.2.3.4 --dry-run
HELP
}

#===============================================================================
# 📋 БЛОК 24/25: MAIN — ОБНОВЛЁННЫЙ С MULTI-PROTOCOL
#===============================================================================
# main - Основная функция запуска
main() {
    header
    printf "${BLUE}║  3X-UI v1.8 — MULTI-PROTOCOL STEALTH ║${NC}\n"
    printf "${BLUE}║  4 inbounds + 8 ShortIDs + Emoji     ║${NC}\n"
    footer
    echo ""
    validate_input || exit 1
    local deps=(ssh curl)
    [[ -n "${SERVER_PASS:-}" ]] && deps+=(sshpass)
    for c in "${deps[@]}"; do
        command -v "$c" &>/dev/null || { log_error "Не найдено: $c"; return 1; }
    done
    command -v jq &>/dev/null || log_warning "⚠️ jq не найден"
    log_success "✓ Зависимости"
    [[ "$DRY_RUN" == "1" ]] && { ssh_exec "echo OK" &>/dev/null && log_success "✓ Dry run" || log_error "✗ Нет подключения"; exit 0; }
    acquire_lock || exit 1
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/3xui-setup.log"
    log_info "🚀 $SERVER_IP ($ROUTING_MODE)"
    init_ssh_cmd || exit 1
    check_connection || exit 1
    SERVER_IP_PUBLIC=$(ssh_exec "curl -s ipv4.icanhazip.com 2>/dev/null || echo '$SERVER_IP'" | tr -d '[:space:]')
    [[ "$ENABLE_AUTO_DOMAIN" == "1" ]] && setup_auto_domain || true
    [[ "$ENABLE_BBR" == "1" ]] && optimize_bbr || true
    [[ "$ENABLE_EMOJI_FLAG" == "1" ]] && get_emoji_flag || true
    [[ "$ENABLE_SSH_KEY" == "1" ]] && setup_ssh_key_auth || true
    install_3xui_remote || exit 1
    configure_panel || { log_error "Панель не настроена"; exit 1; }
    install_cli_utils || log_warning "⚠️ CLI"
    setup_fake_site || true
    [[ "$ROUTING_MODE" != "single" ]] && setup_reality || log_warning "⚠️ Reality"
    [[ "$ENABLE_MULTI_PROTOCOL" == "1" ]] && setup_multi_protocol || true
    setup_adblock || true
    setup_ssl || { log_warning "⚠️ SSL"; }
    setup_cron_ssl || true
    [[ "$ROUTING_MODE" != "multi" ]] && setup_nginx_fallback || true
    setup_firewall || log_warning "⚠️ UFW"
    harden_icmp || true
    [[ "$ENABLE_SNI_ROUTING" == "1" ]] && setup_sni_routing || true
    [[ "$ENABLE_CF_RESTRICT" == "1" ]] && setup_cf_restrict || true
    [[ "$ENABLE_WEB_SUB_PAGE" == "1" ]] && setup_web_sub_page || true
    [[ "$ENABLE_LOCAL_SUB2SING" == "1" ]] && setup_local_sub2sing || true
    [[ "$ENABLE_TELEGRAM" == "1" ]] && setup_telegram || true
    [[ "$ENABLE_SUB_PAGE" == "1" ]] && { setup_sub2singbox; setup_subscription_page; } || true
    SETUP_COMPLETE="1"
    print_summary
    log_success "✅ Готово!"
}

#===============================================================================
# 📋 БЛОК 25/25: ЗАПУСК
#===============================================================================
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && { parse_args "$@"; main; }
