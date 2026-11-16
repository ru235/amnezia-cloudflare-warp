#!/bin/bash
# Install the upstream tspu-check.pl (TSPU/DPI block detector).
#
# The upstream project has no license file, so this script downloads the
# unmodified file at a pinned commit instead of vendoring it in this repository.
set -eu

DEST="${TSPU_BIN:-/usr/local/sbin/tspu-check.pl}"
COMMIT="68f8132150a29cc1845dd0a66a47cc004b5cce7f"
URL="https://raw.githubusercontent.com/porutchik/tspu-check/${COMMIT}/tspu-check.pl"
SHA256="c24f21973a50c41d08fd4cfa96aa8e3beb1aca7c113c20bb834f16a067d08ac9"

info() { echo -e "\033[36m[*]\033[0m $*"; }
warn() { echo -e "\033[33m[!]\033[0m $*" >&2; }

command -v perl >/dev/null 2>&1 || {
    warn "perl is missing; install it first (apt install -y perl)"
    exit 1
}
command -v curl >/dev/null 2>&1 || {
    warn "curl is missing; install it first"
    exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

info "downloading tspu-check.pl (upstream ${COMMIT:0:9})"
curl -fsSL --max-time 60 "$URL" -o "$tmp"

if command -v sha256sum >/dev/null 2>&1; then
    echo "${SHA256}  ${tmp}" | sha256sum -c - >/dev/null 2>&1 || {
        warn "tspu-check.pl checksum mismatch — refusing to install"
        exit 1
    }
else
    warn "sha256sum not found, skipping checksum verification"
fi

install -d -m 755 "$(dirname "$DEST")"
install -m 755 "$tmp" "$DEST"
perl -c "$DEST" >/dev/null 2>&1 || {
    warn "downloaded tspu-check.pl does not compile with this perl"
    exit 1
}

info "installed $DEST"
echo "    source: https://github.com/porutchik/tspu-check"
