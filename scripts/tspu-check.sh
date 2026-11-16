#!/bin/bash
# Wrapper around tspu-check.pl: detect whether packets to the configured
# servers are dropped by Russian TSPU/DPI.
#
# tspu-check.pl only gives a meaningful answer when it runs from a network
# behind TSPU. Servers hosted abroad cannot see the Russian DPI, so set
# TSPU_PROBE_HOST to a Russian VPS and the check will run there over SSH.
#
# Usage:
#   tspu-check.sh [--target IP] [--cached] [--fresh] [--quiet]
#
# Output: one line per target: "IP<TAB>blocked|not_blocked<TAB>detail".
# Also writes /var/lib/warp-monitor/tspu.json and tspu.txt.
set -u
. /etc/warp-monitor.conf 2>/dev/null || true

STATE_DIR="${STATE_DIR:-/var/lib/warp-monitor}"
BIN="${TSPU_BIN:-/usr/local/sbin/tspu-check.pl}"
OUT_JSON="$STATE_DIR/tspu.json"
OUT_TXT="$STATE_DIR/tspu.txt"
CACHE_TTL="${TSPU_CACHE_TTL:-600}"
TIMEOUT="${TSPU_TIMEOUT:-180}"
ENABLE="${TSPU_ENABLE:-0}"
PROBE_HOST="${TSPU_PROBE_HOST:-}"
PROBE_USER="${TSPU_PROBE_USER:-root}"
PROBE_KEY="${TSPU_PROBE_KEY:-/root/.ssh/id_ed25519_monitor}"
DPI_HOP="${TSPU_DPI_HOP:-}"
QUIET=0
CACHED=0
TARGET=""

usage() {
    cat <<'EOF'
tspu-check.sh — проверка IP на блокировку ТСПУ

  tspu-check.sh [--target IP] [--cached|--fresh] [--quiet]

  --target IP   проверить только этот адрес
  --cached      вернуть результат из кеша, если ему меньше TSPU_CACHE_TTL
  --fresh       игнорировать кеш (по умолчанию)
  --quiet       не печатать пояснения в stderr

Настройки в /etc/warp-monitor.conf:
  TSPU_ENABLE=1
  TSPU_PROBE_HOST=root@ru-vps   # точка в РФ; пусто = проверять локально
  TSPU_TARGETS=1.2.3.4,5.6.7.0/24
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift 2 ;;
        --cached) CACHED=1; shift ;;
        --fresh|--no-cache) CACHED=0; shift ;;
        --quiet|-q) QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[ "$ENABLE" = "1" ] || { echo "TSPU check is disabled (TSPU_ENABLE=0)"; exit 3; }

mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR" 2>/dev/null || true

if [ "$CACHED" -eq 1 ] && [ -f "$OUT_TXT" ] && [ -f "$OUT_JSON" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$OUT_JSON" 2>/dev/null || echo 0) ))
    if [ "$age" -lt "$CACHE_TTL" ]; then
        if [ -n "$TARGET" ]; then
            awk -F'\t' -v ip="$TARGET" '$1 == ip' "$OUT_TXT"
        else
            cat "$OUT_TXT"
        fi
        exit 0
    fi
fi

[ "$(id -u)" -eq 0 ] || { echo "tspu-check needs root (raw ICMP socket)" >&2; exit 2; }
[ -x "$BIN" ] || { echo "tspu-check.pl not installed: $BIN" >&2; exit 2; }

targets="$TARGET"
[ -n "$targets" ] || targets="${TSPU_TARGETS:-}"
if [ -z "$targets" ]; then
    targets=$(printf '%s\n' "${SELF_IP:-}" "${PEER_IP:-}" "${SERVER1_IP:-}" "${SERVER2_IP:-}" \
        | awk 'NF && !seen[$0]++' | paste -sd, -)
fi
[ -n "$targets" ] || { echo "no targets to check" >&2; exit 2; }

args=(--json)
[ -n "$DPI_HOP" ] && args+=(--dpi-hop "$DPI_HOP")

if [ -n "$PROBE_HOST" ]; then
    case "$PROBE_HOST" in
        *@*) probe="$PROBE_HOST" ;;
        *)   probe="${PROBE_USER}@${PROBE_HOST}" ;;
    esac
    raw=$(timeout "$TIMEOUT" ssh -i "$PROBE_KEY" \
        -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        "$probe" "$BIN ${args[*]} $(printf '%q' "$targets")" 2>/dev/null)
    rc=$?
    source_desc="probe ${probe}"
else
    [ "$QUIET" -eq 1 ] || \
        echo "note: local check from ${SELF_NAME:-this host}; Russian TSPU is only visible from a network behind it" >&2
    raw=$(timeout "$TIMEOUT" "$BIN" "${args[@]}" "$targets" 2>/dev/null)
    rc=$?
    source_desc="local ${SELF_NAME:-host} (${SELF_IP:-?})"
fi

if [ -z "$raw" ]; then
    echo "TSPU check failed (exit $rc)" >&2
    exit 2
fi

printf '%s' "$raw" > "$OUT_JSON.raw"
python3 - "$OUT_JSON.raw" "$OUT_JSON" "$OUT_TXT" "$source_desc" "$rc" <<'PY'
import json
import sys
import time

raw_path, json_path, txt_path, source, rc = sys.argv[1:6]
try:
    with open(raw_path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    sys.exit(f"cannot parse tspu-check JSON: {exc}")

results = data.get("results") or []
norm = {
    "ts": int(time.time()),
    "source": source,
    "exit_code": int(rc),
    "control_status": data.get("control_status"),
    "dpi_hop": data.get("dpi_hop"),
    "dpi_router": data.get("dpi_router"),
    "results": results,
}
with open(json_path, "w", encoding="utf-8") as f:
    json.dump(norm, f, ensure_ascii=False, indent=1)
with open(txt_path, "w", encoding="utf-8") as f:
    for item in results:
        f.write(f"{item.get('ip', '?')}\t{item.get('status', '?')}\t{item.get('detail', '')}\n")
PY
rm -f "$OUT_JSON.raw"

cat "$OUT_TXT"
[ "$rc" -eq 1 ] && exit 1
exit 0
