#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="clash-traffic-original"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run the shadow service on the VPS as root." >&2
    exit 1
fi
if systemctl show "${UNIT}.service" --property=LoadState --value | grep -qv '^not-found$'; then
    echo "The original-node shadow unit already exists." >&2
    exit 1
fi

systemd-run --unit="${UNIT}" \
    --property=User=clash-traffic-preview \
    --property=DynamicUser=yes \
    --property=StateDirectory=clash-traffic-preview \
    --property=WorkingDirectory="${SCRIPT_DIR}" \
    --property=MemoryHigh=192M \
    --property=MemoryMax=256M \
    --property=TasksMax=256 \
    --property=LimitNOFILE=8192 \
    --property=NoNewPrivileges=yes \
    --property=PrivateTmp=yes \
    --property=ProtectSystem=strict \
    --property=ProtectHome=yes \
    --property=Restart=on-failure \
    --property=RestartSec=5 \
    --setenv="TRAFFIC_DATA_DIR=/var/lib/clash-traffic-preview" \
    /usr/bin/python3 "${SCRIPT_DIR}/original.py"

echo "The shadow service is separate and does not change network routing."
