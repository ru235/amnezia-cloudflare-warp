#!/bin/bash
# Forced command for the Russian TSPU probe.
#
# The probe host (a machine inside Russia, behind TSPU) connects over SSH and
# may only run two things:
#
#   ssh <server> targets   -> comma-separated list of IPs worth checking
#   ssh <server> push      -> results, JSON on stdin
#
# Results are validated and written to /var/lib/warp-monitor/tspu-remote.{json,txt}.
# Nothing else can be executed, so a stolen probe key cannot open a shell.
set -u

STATE_DIR="${STATE_DIR:-/var/lib/warp-monitor}"
CONF="/etc/warp-monitor.conf"
JSON="$STATE_DIR/tspu-remote.json"
TXT="$STATE_DIR/tspu-remote.txt"
MAX_BYTES="${TSPU_INGEST_MAX_BYTES:-131072}"

if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF" || true
fi

mkdir -p "$STATE_DIR" || exit 2

cmd="${SSH_ORIGINAL_COMMAND:-}"

case "$cmd" in
    targets)
        printf '%s\n' "${SELF_IP:-}" "${PEER_IP:-}" "${SERVER1_IP:-}" "${SERVER2_IP:-}" \
            | awk 'NF && !seen[$0]++' | paste -sd, -
        exit 0
        ;;
    push)
        ;;
    *)
        echo "tspu-ingest: unknown command" >&2
        exit 2
        ;;
esac

tmp=$(mktemp "$STATE_DIR/.tspu-in.XXXXXX") || exit 2
trap 'rm -f "$tmp" "$tmp.out" "$tmp.txt"' EXIT

head -c $((MAX_BYTES + 1)) > "$tmp"
bytes=$(wc -c < "$tmp")
if [ "$bytes" -eq 0 ] || [ "$bytes" -gt "$MAX_BYTES" ]; then
    echo "tspu-ingest: bad payload size ($bytes bytes)" >&2
    exit 2
fi

python3 - "$tmp" "$tmp.out" "$tmp.txt" <<'PY'
import json
import re
import sys
import time

src, jout, tout = sys.argv[1:4]

try:
    with open(src, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    sys.exit(f"tspu-ingest: invalid JSON: {exc}")

if not isinstance(data, dict):
    sys.exit("tspu-ingest: payload is not an object")

results = data.get("results")
if not isinstance(results, list):
    sys.exit("tspu-ingest: no results list")
if len(results) > 64:
    sys.exit("tspu-ingest: too many results")

ip_re = re.compile(r"^[0-9a-fA-F:.]{3,45}$")
clean = []
for item in results:
    if not isinstance(item, dict):
        continue
    ip = str(item.get("ip", "")).strip()
    if not ip_re.match(ip):
        continue
    status = str(item.get("status", "unknown"))
    if status not in ("blocked", "not_blocked", "unknown"):
        status = "unknown"
    detail = str(item.get("detail", "")).replace("\n", " ")[:300]
    clean.append({"ip": ip, "status": status, "detail": detail})

if not clean:
    sys.exit("tspu-ingest: no valid results")

now = int(time.time())
try:
    ts = int(data.get("ts") or now)
except Exception:
    ts = now
if abs(ts - now) > 900:
    ts = now

norm = {
    "ts": ts,
    "source": str(data.get("source") or "ТСПУ (Москва)")[:64],
    "remote": True,
    "exit_code": data.get("exit_code"),
    "control_status": data.get("control_status"),
    "dpi_hop": data.get("dpi_hop"),
    "dpi_router": data.get("dpi_router"),
    "targets": str(data.get("targets") or "")[:512],
    "results": clean,
}

with open(jout, "w", encoding="utf-8") as f:
    json.dump(norm, f, ensure_ascii=False, indent=1)
with open(tout, "w", encoding="utf-8") as f:
    for item in clean:
        f.write(f"{item['ip']}\t{item['status']}\t{item['detail']}\n")

print(f"ok {len(clean)}")
PY
rc=$?
[ "$rc" -eq 0 ] || exit 2

chmod 644 "$tmp.out" "$tmp.txt"
mv -f "$tmp.out" "$JSON" || exit 2
mv -f "$tmp.txt" "$TXT" || exit 2
exit 0
