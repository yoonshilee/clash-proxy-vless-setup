#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HASH_FILE="/run/clash-traffic-control/firewall-hash"

[[ "${TRAFFIC_GATE_PROTECT_DIRECT:-}" == 1 ]] || { echo "Direct-port protection is required." >&2; exit 1; }
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
