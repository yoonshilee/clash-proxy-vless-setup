#!/usr/bin/env bash

set -euo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Run as root." >&2
    exit 1
}

: "${XRAY_PORT:?XRAY_PORT is required}"
: "${SUBSCRIPTION_PORT:?SUBSCRIPTION_PORT is required}"

systemctl enable --now firewalld

firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port="${XRAY_PORT}/tcp"
firewall-cmd --permanent --add-port="${SUBSCRIPTION_PORT}/tcp"

if [[ -n "${LEGACY_SS_PORT:-}" ]]; then
    firewall-cmd --permanent --remove-port="${LEGACY_SS_PORT}/tcp" 2>/dev/null || true
    firewall-cmd --permanent --remove-port="${LEGACY_SS_PORT}/udp" 2>/dev/null || true
fi

firewall-cmd --reload
