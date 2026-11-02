#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="clash-traffic-gate"
DATABASE="/var/lib/private/clash-traffic-preview/traffic.sqlite3"
HASH_FILE="${TRAFFIC_GATE_HASH_PATH:-/var/lib/private/clash-traffic-preview/gate-firewall-hash}"
MODE="${1:---shadow}"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run the watchdog on the VPS as root." >&2
    exit 1
fi
if systemctl show "${UNIT}.service" --property=LoadState --value | grep -qv '^not-found$'; then
    echo "The gate watchdog already exists." >&2
    exit 1
fi
args=(--database "$DATABASE")
if [[ "$MODE" == --activate ]]; then
    [[ -f "$HASH_FILE" ]] || { echo "The verified firewall fingerprint is missing." >&2; exit 1; }
    original_hash="$(cd "$SCRIPT_DIR" && /usr/bin/python3 -c 'from pathlib import Path; from prepare_original import verified_source_hash; print(verified_source_hash(Path("/usr/local/etc/xray/config.json"), Path("/var/lib/private/clash-traffic-preview")))')"
    args+=(--activate --firewall-hash "$(cat "$HASH_FILE")" --original-hash "$original_hash")
elif [[ "$MODE" != --shadow ]]; then
    echo "Use --shadow or --activate." >&2
    exit 1
fi

systemd-run --unit="$UNIT" \
    --property=User=root \
    --property=CapabilityBoundingSet='CAP_NET_ADMIN CAP_DAC_READ_SEARCH' \
    --property=RuntimeDirectory="$UNIT" \
    --property=RuntimeDirectoryMode=0755 \
    --property=WorkingDirectory="$SCRIPT_DIR" \
    --property=MemoryMax=64M \
    --property=CPUQuota=10% \
    --property=TasksMax=32 \
    --property=NoNewPrivileges=yes \
    --property=PrivateTmp=yes \
    --property=ProtectSystem=strict \
    --property=ProtectHome=yes \
    --property=Restart=on-failure \
    --property=RestartSec=2 \
    /usr/bin/python3 "${SCRIPT_DIR}/gate.py" "${args[@]}"
