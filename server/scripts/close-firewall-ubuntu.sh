#!/usr/bin/env bash

set -euo pipefail

[[ $EUID -eq 0 ]] || {
    echo "Run as root." >&2
    exit 1
}

: "${XRAY_PORT:?XRAY_PORT is required}"
: "${SUBSCRIPTION_PORT:?SUBSCRIPTION_PORT is required}"

ufw delete allow "${XRAY_PORT}/tcp" 2>/dev/null || true
ufw delete allow "${SUBSCRIPTION_PORT}/tcp" 2>/dev/null || true
