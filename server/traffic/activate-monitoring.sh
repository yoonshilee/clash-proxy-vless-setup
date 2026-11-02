#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_FILE="/run/clash-traffic-control/firewall-hash"

systemctl is-active --quiet ufw.service
systemctl is-active --quiet xray.service
systemctl is-active --quiet clash-traffic-capture.service

[[ -f "$HASH_FILE" ]] || { echo "The verified firewall fingerprint is missing." >&2; exit 1; }
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

if ! systemctl is-active --quiet clash-traffic-gate.service; then
    TRAFFIC_DATABASE_PATH=/var/lib/clash-traffic/traffic.sqlite3 \
    TRAFFIC_ORIGINAL_CONFIG_DIR=/etc/clash-traffic/private \
    TRAFFIC_PYTHON=/opt/clash-traffic/venv/bin/python \
    TRAFFIC_GATE_HASH_PATH="$HASH_FILE" \
        bash "$SCRIPT_DIR/start-gate.sh" --activate
fi
