#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_FILE="${TRAFFIC_GATE_BOOT_RUNTIME_DIR:-/run/clash-traffic-autostart}/firewall-hash"

systemctl is-active --quiet ufw.service
systemctl is-active --quiet xray.service

if [[ ! -f "$HASH_FILE" ]]; then
    /usr/bin/python3 "$SCRIPT_DIR/gate_setup.py" --install-inactive --firewall-hash "$HASH_FILE"
fi

cd "$SCRIPT_DIR"
/usr/bin/python3 - "$HASH_FILE" <<'PY'
import asyncio
from pathlib import Path
import sys
import gate

fingerprint = Path(sys.argv[1]).read_text().strip()
if not asyncio.run(gate.firewall_ready(fingerprint)):
    raise SystemExit("Traffic gate does not match the verified firewall policy")
PY

if ! systemctl is-active --quiet clash-traffic-preview.service; then
    TRAFFIC_PREVIEW_PYTHONPATH=/opt/clash-traffic-preview/deps bash "$SCRIPT_DIR/start-preview.sh"
fi
if ! systemctl is-active --quiet clash-traffic-original.service; then
    bash "$SCRIPT_DIR/start-original-shadow.sh"
fi
if ! systemctl is-active --quiet clash-traffic-gate.service; then
    TRAFFIC_GATE_HASH_PATH="$HASH_FILE" bash "$SCRIPT_DIR/start-gate.sh" --activate
fi
