#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="clash-traffic-preview"
DEPENDENCIES="${TRAFFIC_PREVIEW_PYTHONPATH:?Set TRAFFIC_PREVIEW_PYTHONPATH to the private dependency directory}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run the preview on the VPS as root." >&2
    exit 1
fi
if systemctl show "${UNIT}.service" --property=LoadState --value | grep -qv '^not-found$'; then
    echo "The preview unit already exists. Stop it before starting another preview." >&2
    exit 1
fi
if [[ ! -x /usr/local/bin/xray ]]; then
    echo "The existing Xray binary was not found." >&2
    exit 1
fi
PYTHONPATH="${DEPENDENCIES}" /usr/bin/python3 -c 'import django, gunicorn'

systemd-run --unit="${UNIT}" \
    --property=DynamicUser=yes \
    --property=StateDirectory="${UNIT}" \
    --property=WorkingDirectory="${SCRIPT_DIR}" \
    --property=MemoryHigh=192M \
    --property=MemoryMax=256M \
    --property=CPUQuota=25% \
    --property=TasksMax=256 \
    --property=Nice=15 \
    --property=NoNewPrivileges=yes \
    --property=PrivateTmp=yes \
    --property=ProtectSystem=strict \
    --property=ProtectHome=yes \
    --property=Restart=on-failure \
    --property=RestartSec=5 \
    --setenv="TRAFFIC_DATA_DIR=/var/lib/${UNIT}" \
    --setenv="PYTHONPATH=${DEPENDENCIES}" \
    /usr/bin/python3 "${SCRIPT_DIR}/preview.py"

echo "The preview listens on 127.0.0.1 only. Check its status before connecting."
