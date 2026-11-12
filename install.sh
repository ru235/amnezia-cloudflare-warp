#!/bin/bash
# Installer for amnezia-cloudflare-warp.
#
#   sudo ./install.sh                          # single server, no Telegram
#   sudo ./install.sh --telegram               # ask for token/chat, enable bot
#   sudo ./install.sh --peer-ip 1.2.3.4 --peer-name Aeza --telegram
#
# It is idempotent: run it again to change settings. Existing values in
# /etc/warp-monitor.conf are used as defaults for flags you do not pass.
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR=/usr/local/sbin
UNIT_DIR=/etc/systemd/system
CONF_PATH=/etc/warp-monitor.conf
TG_ENV_PATH=/etc/warp-telegram.env

ok()   { echo -e "  \033[32m+\033[0m $*"; }
info() { echo -e "\033[36m[*]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[x]\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
amnezia-cloudflare-warp installer

  sudo ./install.sh [options]

Server:
  --self-name NAME        Human readable name (default: hostname)
  --self-ip IP            Public IPv4 (default: auto-detect)
  --peer-ip IP            Peer server IPv4, enables the second card and SSH checks
  --peer-name NAME        Peer display name

Telegram (optional):
  --telegram              Enable reports, alerts and the bot
  --token TOKEN           Bot token (or env TELEGRAM_TOKEN); prompted if omitted
  --chat ID               Chat ID (or env TELEGRAM_CHAT); prompted if omitted
  --bot-role ROLE         active | passive | none (default: active)
  --no-bot                Same as --bot-role none

Schedule (UTC):
  --report-utc HH:MM      Daily report time (default: 05:00)
  --rotate-utc HH:MM      Daily WARP key rotation (default: 04:45)
  --report-label TEXT     Label in the report header (default: "<time> UTC")
  --rotate-s1-label TEXT  Rotation label for the first server in the bot
  --rotate-s2-label TEXT  Rotation label for the second server in the bot

Advanced:
  --awg-port PORT         AmneziaWG UDP port (default: auto-detect)
  --bypass-mark MARK      Routing mark for direct traffic (default: 0x100cf)
  --bypass-prio N         ip rule priority (default: 10)
  --install-deps          apt-get install missing packages
  --dry-run               Print the plan, change nothing
  --uninstall             Run uninstall.sh
  -h, --help              This help

Examples:
  sudo ./install.sh
  sudo ./install.sh --telegram --token 123:ABC --chat 123456789
  sudo ./install.sh --peer-ip 192.0.2.20 --peer-name Aeza --telegram --bot-role passive
USAGE
}

# --- defaults, then existing config as defaults ------------------------------
SELF_NAME=""
SELF_IP=""
PEER_NAME=""
PEER_IP=""
TELEGRAM=-1
TG_TOKEN="${TELEGRAM_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT:-}"
BOT_ROLE=""
REPORT_UTC="05:00"
ROTATE_UTC="04:45"
REPORT_LABEL=""
AWG_PORT=""
BYPASS_MARK="0x100cf"
BYPASS_PRIO="10"
WARP_IF="CloudflareWARP"
AWG_IFACE="amn0"
INSTALL_DEPS=0
DRY_RUN=0
DO_UNINSTALL=0
PURGE=0

if [ -f "$CONF_PATH" ]; then
    # shellcheck disable=SC1090
    . "$CONF_PATH" || die "cannot parse $CONF_PATH"
fi
if [ -f "$TG_ENV_PATH" ]; then
    # shellcheck disable=SC1090
    . "$TG_ENV_PATH" || true
fi

SELF_NAME="${SELF_NAME:-$(hostname)}"
REPORT_UTC="${REPORT_UTC:-05:00}"
ROTATE_UTC="${ROTATE_UTC:-04:45}"
REPORT_LABEL="${REPORT_TIME:-$REPORT_UTC UTC}"
BOT_ROLE="${BOT_ROLE:-active}"
BYPASS_MARK="${BYPASS_MARK:-0x100cf}"
BYPASS_PRIO="${BYPASS_PRIO:-10}"
WARP_IF="${WARP_IF:-CloudflareWARP}"
AWG_IFACE="${AWG_IFACE:-amn0}"
AWG_PORT="${AWG_PORT:-}"
ROTATE_LABEL_S1="${ROTATE_S1:-}"
ROTATE_LABEL_S2="${ROTATE_S2:-}"

# --- arguments ---------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --self-name)      SELF_NAME="$2"; shift 2 ;;
        --self-ip)        SELF_IP="$2"; shift 2 ;;
        --peer-ip)        PEER_IP="$2"; shift 2 ;;
        --peer-name)      PEER_NAME="$2"; shift 2 ;;
        --telegram)       TELEGRAM=1; shift ;;
        --token)          TG_TOKEN="$2"; shift 2 ;;
        --chat)           TG_CHAT="$2"; shift 2 ;;
        --bot-role)       BOT_ROLE="$2"; shift 2 ;;
        --no-bot)         BOT_ROLE="none"; shift ;;
        --report-utc)     REPORT_UTC="$2"; REPORT_LABEL="$2 UTC"; shift 2 ;;
        --rotate-utc)     ROTATE_UTC="$2"; shift 2 ;;
        --rotate-s1-label) ROTATE_LABEL_S1="$2"; shift 2 ;;
        --rotate-s2-label) ROTATE_LABEL_S2="$2"; shift 2 ;;
        --report-label)   REPORT_LABEL="$2"; shift 2 ;;
        --awg-port)       AWG_PORT="$2"; shift 2 ;;
        --bypass-mark)    BYPASS_MARK="$2"; shift 2 ;;
        --bypass-prio)    BYPASS_PRIO="$2"; shift 2 ;;
        --install-deps)   INSTALL_DEPS=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --uninstall)      DO_UNINSTALL=1; shift ;;
        --purge)          PURGE=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

# --- uninstall shortcut ------------------------------------------------------
if [ "$DO_UNINSTALL" -eq 1 ]; then
    args=()
    if [ "$PURGE" -eq 1 ]; then args+=(--purge); fi
    if [ "$DRY_RUN" -eq 1 ]; then args+=(--dry-run); fi
    exec bash "$REPO_DIR/uninstall.sh" "${args[@]+"${args[@]}"}"
fi

# --- validation --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root: sudo ./install.sh"

is_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
is_time "$REPORT_UTC" || die "--report-utc must be HH:MM (UTC), got '$REPORT_UTC'"
is_time "$ROTATE_UTC" || die "--rotate-utc must be HH:MM (UTC), got '$ROTATE_UTC'"
case "$BOT_ROLE" in active|passive|none) ;; *) die "--bot-role must be active, passive or none" ;; esac

sanitize() { printf '%s' "$1" | tr -d '"\\`$' ; }
SELF_NAME="$(sanitize "$SELF_NAME")"
PEER_NAME="$(sanitize "$PEER_NAME")"
REPORT_LABEL="$(sanitize "$REPORT_LABEL")"
ROTATE_LABEL_S1="$(sanitize "${ROTATE_LABEL_S1:-$ROTATE_UTC UTC}")"
ROTATE_LABEL_S2="$(sanitize "${ROTATE_LABEL_S2:-$ROTATE_UTC UTC}")"

# --- dependencies ------------------------------------------------------------
need_pkgs=()
command -v curl     >/dev/null 2>&1 || need_pkgs+=(curl)
command -v iptables >/dev/null 2>&1 || need_pkgs+=(iptables)
command -v python3  >/dev/null 2>&1 || need_pkgs+=(python3)
python3 -c 'import matplotlib' >/dev/null 2>&1 || need_pkgs+=(python3-matplotlib)

if [ "${#need_pkgs[@]}" -gt 0 ]; then
    if [ "$INSTALL_DEPS" -eq 1 ]; then
        info "installing packages: ${need_pkgs[*]}"
        [ "$DRY_RUN" -eq 1 ] || { apt-get update -qq && apt-get install -y -qq "${need_pkgs[@]}"; }
    else
        warn "missing packages: ${need_pkgs[*]}"
        warn "install them or re-run with --install-deps"
    fi
fi

command -v warp-cli >/dev/null 2>&1 \
    || warn "warp-cli not found: install Cloudflare WARP first (docs/INSTALL.md)"
command -v docker >/dev/null 2>&1 \
    || warn "docker not found: install AmneziaWG first (docs/INSTALL.md)"

# --- auto-detect -------------------------------------------------------------
detect_self_ip() {
    local ip=""
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "$ip"
}

UGW_CONTAINER=""
detect_awg() {
    UGW_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null | grep '^amnezia-awg' | head -1 || true)
    if [ -z "$AWG_PORT" ] && [ -n "$UGW_CONTAINER" ]; then
        AWG_PORT=$(docker port "$UGW_CONTAINER" 2>/dev/null \
            | awk -F'[/: ]+' '/udp/ {print $1; exit}')
        if [ -z "$AWG_PORT" ]; then
            AWG_PORT=$(docker exec "$UGW_CONTAINER" awg show all dump 2>/dev/null \
                | awk 'NR==1 {print $4; exit}')
        fi
    fi
}

[ -n "$SELF_IP" ] || SELF_IP="$(detect_self_ip)"
[ -n "$SELF_IP" ] || die "cannot auto-detect the public IPv4, pass --self-ip"
detect_awg
[ -n "$AWG_PORT" ] || AWG_PORT=44059

if [ "$BOT_ROLE" = "passive" ] && [ -z "$PEER_IP" ]; then
    warn "--bot-role passive without --peer-ip is pointless, switching to active"
    BOT_ROLE="active"
fi

# --- Telegram input ----------------------------------------------------------
# Without an explicit flag keep whatever is already configured on disk, so a
# plain `install.sh` after `git pull` does not silently stop a running bot.
if [ "$TELEGRAM" -eq -1 ]; then
    if [ -f "$TG_ENV_PATH" ] && [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
        TELEGRAM=1
    else
        TELEGRAM=0
    fi
fi

if [ "$TELEGRAM" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    if [ -z "$TG_TOKEN" ] && [ -t 0 ]; then
        read -rp "  Bot token (from @BotFather): " TG_TOKEN
    fi
    if [ -z "$TG_CHAT" ] && [ -t 0 ]; then
        read -rp "  Chat ID (from @userinfobot): " TG_CHAT
    fi
    [ -n "$TG_TOKEN" ] || die "Telegram enabled but no token (--token or TELEGRAM_TOKEN)"
    [ -n "$TG_CHAT" ]  || die "Telegram enabled but no chat id (--chat or TELEGRAM_CHAT)"
fi

# --- plan --------------------------------------------------------------------
echo
info "amnezia-cloudflare-warp"
echo "    server      : $SELF_NAME ($SELF_IP)"
echo "    peer        : ${PEER_NAME:-—} ${PEER_IP:+($PEER_IP)}"
echo "    AWG         : ${UGW_CONTAINER:-not found}, UDP ${AWG_PORT}, iface ${AWG_IFACE}"
echo "    routing     : mark ${BYPASS_MARK}, prio ${BYPASS_PRIO}, WARP iface ${WARP_IF}"
echo "    report      : ${REPORT_UTC} UTC (${REPORT_LABEL})"
echo "    rotation    : ${ROTATE_UTC} UTC"
if [ "$TELEGRAM" -eq 1 ]; then
    echo "    telegram    : enabled, bot role ${BOT_ROLE}"
else
    echo "    telegram    : disabled (monitoring and reports still run)"
fi
echo

if [ "$DRY_RUN" -eq 1 ]; then
    info "dry run: nothing was changed"
    exit 0
fi

# --- config ------------------------------------------------------------------
info "writing $CONF_PATH"
if [ -f "$CONF_PATH" ]; then
    cp -a "$CONF_PATH" "$CONF_PATH.bak"
fi
umask 077
cat > "$CONF_PATH" <<EOF
# Generated by amnezia-cloudflare-warp install.sh
# Re-run install.sh or edit this file; the scripts source it directly.

SELF_NAME="$SELF_NAME"
SELF_IP="$SELF_IP"

PEER_NAME="$PEER_NAME"
PEER_IP="$PEER_IP"

SERVER1_NAME="${SERVER1_NAME:-$SELF_NAME}"
SERVER1_IP="${SERVER1_IP:-$SELF_IP}"
SERVER2_NAME="${SERVER2_NAME:-$PEER_NAME}"
SERVER2_IP="${SERVER2_IP:-$PEER_IP}"

REPORT_TIME="$REPORT_LABEL"
REPORT_UTC="$REPORT_UTC"
ROTATE_UTC="$ROTATE_UTC"
ROTATE_S1="$ROTATE_LABEL_S1"
ROTATE_S2="$ROTATE_LABEL_S2"

BOT_ROLE="$BOT_ROLE"

BYPASS_MARK="$BYPASS_MARK"
BYPASS_PRIO="$BYPASS_PRIO"
WARP_IF="$WARP_IF"
AWG_IFACE="$AWG_IFACE"
AWG_PORT="$AWG_PORT"
EOF
chmod 644 "$CONF_PATH"
ok "config written"

# --- scripts -----------------------------------------------------------------
info "installing scripts into $BIN_DIR"
install -d -m 755 "$BIN_DIR"
install -m 755 "$REPO_DIR/scripts/warp-amnezia-routing.sh" "$BIN_DIR/warp-amnezia-routing.sh"
install -m 755 "$REPO_DIR/scripts/peer-monitor.sh"         "$BIN_DIR/peer-monitor.sh"
install -m 755 "$REPO_DIR/scripts/warp-rotate.sh"          "$BIN_DIR/warp-rotate.sh"
install -m 755 "$REPO_DIR/scripts/bot-guard.sh"            "$BIN_DIR/bot-guard.sh"
install -m 755 "$REPO_DIR/scripts/warp-daily-report.py"    "$BIN_DIR/warp-daily-report.py"
install -m 755 "$REPO_DIR/scripts/warp-bot.py"             "$BIN_DIR/warp-bot.py"
ok "scripts installed"

# --- Telegram env ------------------------------------------------------------
if [ "$TELEGRAM" -eq 1 ]; then
    info "writing $TG_ENV_PATH"
    umask 077
    cat > "$TG_ENV_PATH" <<EOF
TG_TOKEN=$TG_TOKEN
TG_CHAT=$TG_CHAT
EOF
    chmod 600 "$TG_ENV_PATH"
    ok "telegram credentials saved"
fi

# --- systemd units -----------------------------------------------------------
info "installing systemd units"
install -m 644 "$REPO_DIR/systemd/warp-amnezia-routing.service" "$UNIT_DIR/warp-amnezia-routing.service"
install -m 644 "$REPO_DIR/systemd/peer-monitor.service"         "$UNIT_DIR/peer-monitor.service"
install -m 644 "$REPO_DIR/systemd/peer-monitor.timer"           "$UNIT_DIR/peer-monitor.timer"
install -m 644 "$REPO_DIR/systemd/warp-daily-report.service"    "$UNIT_DIR/warp-daily-report.service"
install -m 644 "$REPO_DIR/systemd/warp-rotate.service"          "$UNIT_DIR/warp-rotate.service"
install -m 644 "$REPO_DIR/systemd/warp-bot.service"             "$UNIT_DIR/warp-bot.service"
install -m 644 "$REPO_DIR/systemd/bot-guard.service"            "$UNIT_DIR/bot-guard.service"
install -m 644 "$REPO_DIR/systemd/bot-guard.timer"              "$UNIT_DIR/bot-guard.timer"

sed "s/__REPORT_UTC__/${REPORT_UTC}/" "$REPO_DIR/systemd/warp-daily-report.timer" \
    > "$UNIT_DIR/warp-daily-report.timer"
sed "s/__ROTATE_UTC__/${ROTATE_UTC}/" "$REPO_DIR/systemd/warp-rotate.timer" \
    > "$UNIT_DIR/warp-rotate.timer"
chmod 644 "$UNIT_DIR/warp-daily-report.timer" "$UNIT_DIR/warp-rotate.timer"

systemctl daemon-reload
ok "units installed"

# --- enable ------------------------------------------------------------------
info "enabling services"
systemctl enable warp-amnezia-routing.service >/dev/null
systemctl restart warp-amnezia-routing.service || warn "routing script returned an error, check: journalctl -u warp-amnezia-routing"

systemctl enable --now peer-monitor.timer >/dev/null
systemctl enable --now warp-daily-report.timer >/dev/null
systemctl enable --now warp-rotate.timer >/dev/null

if [ "$TELEGRAM" -eq 1 ] && [ "$BOT_ROLE" = "active" ]; then
    systemctl enable --now warp-bot.service >/dev/null
    ok "bot started (role: active)"
else
    systemctl disable --now warp-bot.service >/dev/null 2>&1 || true
fi

if [ "$TELEGRAM" -eq 1 ] && [ "$BOT_ROLE" = "passive" ] && [ -n "$PEER_IP" ]; then
    systemctl enable --now bot-guard.timer >/dev/null
    ok "bot-guard enabled"
else
    systemctl disable --now bot-guard.timer >/dev/null 2>&1 || true
fi
ok "services enabled"

# --- peer SSH key ------------------------------------------------------------
if [ -n "$PEER_IP" ]; then
    KEY=/root/.ssh/id_ed25519_monitor
    if [ ! -f "$KEY" ]; then
        info "generating SSH key for peer monitoring"
        install -d -m 700 /root/.ssh
        ssh-keygen -t ed25519 -N "" -C "warp-monitor@$SELF_NAME" -f "$KEY" >/dev/null
    fi
    echo
    info "Add this public key to $PEER_NAME ($PEER_IP) to enable peer metrics:"
    echo
    cat "${KEY}.pub"
    echo
    echo "    ssh root@$PEER_IP \"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys\" < ${KEY}.pub"
    echo
fi

# --- first run ---------------------------------------------------------------
info "running the first monitor check"
"$BIN_DIR/peer-monitor.sh" >/dev/null 2>&1 || warn "monitor returned an error; run it manually to see why"

# --- summary -----------------------------------------------------------------
echo
ok "installation finished"
echo
echo "  status      : systemctl list-timers 'peer-monitor*' 'warp-*' 'bot-guard*'"
echo "  monitor log : tail -f /var/log/syslog | grep peer-monitor"
echo "  data        : /var/lib/warp-monitor/history.csv"
echo "  config      : $CONF_PATH"
if [ "$TELEGRAM" -eq 1 ] && [ "$BOT_ROLE" = "active" ]; then
    echo "  bot         : send /start in Telegram"
fi
echo
echo "  Next: docs/INSTALL.md, docs/TELEGRAM.md, docs/TROUBLESHOOTING.md"
echo
