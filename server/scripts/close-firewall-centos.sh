#!/usr/bin/env bash

set -euo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Run as root." >&2
    exit 1
}

: "${XRAY_PORT:?XRAY_PORT is required}"
: "${SUBSCRIPTION_PORT:?SUBSCRIPTION_PORT is required}"

systemctl is-enabled firewalld >/dev/null 2>&1 || true
firewall-cmd --permanent --remove-port="${XRAY_PORT}/tcp" 2>/dev/null || true
firewall-cmd --permanent --remove-port="${SUBSCRIPTION_PORT}/tcp" 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true
