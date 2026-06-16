#!/usr/bin/env bash

set -euo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Run as root." >&2
    exit 1
}

: "${XRAY_PORT:?XRAY_PORT is required}"
: "${SUBSCRIPTION_PORT:?SUBSCRIPTION_PORT is required}"

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow "${XRAY_PORT}/tcp"
ufw allow "${SUBSCRIPTION_PORT}/tcp"

if [[ -n "${LEGACY_SS_PORT:-}" ]]; then
    ufw delete allow "${LEGACY_SS_PORT}/tcp" 2>/dev/null || true
    ufw delete allow "${LEGACY_SS_PORT}/udp" 2>/dev/null || true
fi

ufw --force enable
