#!/bin/bash
# Run on a host inside Russia (behind TSPU) and push results to the monitors.
#
# The probe never accepts incoming connections: it connects out to each
# monitoring server over SSH, where the key is restricted to `targets`/`push`.
set -u

CONF="${TSPU_PROBE_CONF:-/etc/tspu-probe.conf}"
if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF" || true
fi

BIN="${PROBE_BIN:-/usr/local/sbin/tspu-check.pl}"
SERVERS="${PROBE_SERVER:-}"
PORT="${PROBE_PORT:-22}"
KEY="${PROBE_KEY:-/root/.ssh/id_ed25519_tspu}"
LABEL="${PROBE_LABEL:-ТСПУ (Москва)}"
FIXED="${PROBE_TARGETS:-}"
TIMEOUT="${PROBE_TIMEOUT:-300}"

say() { printf '%s: %s\n' "tspu-probe" "$*" >&2; }

[ -n "$SERVERS" ] || { say "PROBE_SERVER is not set in $CONF"; exit 1; }
[ -x "$BIN" ]     || { say "$BIN not found; run install-probe.sh"; exit 1; }
[ -r "$KEY" ]     || { say "SSH key $KEY not found; run install-probe.sh"; exit 1; }

ssh_to() {  # ssh_to <server> <command...>
    local srv="$1"
    shift
    ssh -i "$KEY" -p "$PORT" \
        -o BatchMode=yes -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o UpdateHostKeys=no \
        -o ConnectTimeout=10 -o ServerAliveInterval=15 \
        "$srv" "$@"
}

# Ask the first reachable server which VPN addresses to check, so a changed
# server IP is picked up automatically without touching this host.
targets="$FIXED"
if [ -z "$targets" ]; then
    for srv in $SERVERS; do
        got=$(ssh_to "$srv" targets 2>/dev/null) || continue
        got=$(printf '%s' "$got" | tr -d ' \r\n\t')
        if [ -n "$got" ]; then
            targets="$got"
            break
        fi
    done
fi
[ -n "$targets" ] || { say "cannot get the target list from any server"; exit 1; }

say "checking $targets"
raw=$(timeout "$TIMEOUT" "$BIN" --json "$targets" 2>/dev/null)
rc=$?
if [ -z "$raw" ]; then
    say "tspu-check produced no output (rc=$rc)"
    exit 1
fi

payload=$(printf '%s' "$raw" | PROBE_LABEL="$LABEL" PROBE_TARGETS="$targets" PROBE_RC="$rc" python3 -c '
import json, os, sys, time
try:
    data = json.loads(sys.stdin.read())
except Exception as exc:
    sys.exit(f"cannot parse tspu-check output: {exc}")
data["source"] = os.environ["PROBE_LABEL"]
data["targets"] = os.environ["PROBE_TARGETS"]
data["ts"] = int(time.time())
try:
    data["exit_code"] = int(os.environ["PROBE_RC"])
except Exception:
    pass
print(json.dumps(data, ensure_ascii=False))
')
if [ -z "$payload" ]; then
    say "cannot build payload"
    exit 1
fi

pushed=0
for srv in $SERVERS; do
    if out=$(printf '%s' "$payload" | ssh_to "$srv" push 2>&1); then
        say "pushed to $srv: $out"
        pushed=$((pushed + 1))
    else
        say "push to $srv failed: $out"
    fi
done

[ "$pushed" -gt 0 ] || exit 1
