#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MODE="${1:---install}"
APP_ROOT="/opt/clash-traffic"
CONFIG_ROOT="/etc/clash-traffic"
DATA_ROOT="/var/lib/clash-traffic"
CADDY_SITE="/etc/caddy/Caddyfile.d/clash-traffic.caddyfile"
HTTPS_PORT=9443
UNITS=(clash-traffic-web.socket clash-traffic-web.service clash-traffic-firewall.service clash-traffic-capture.service clash-traffic-network.service clash-traffic-journal.service clash-traffic-scheduler.service)

fail() { echo "Traffic dashboard: $*" >&2; return 1; }
all_active() { for unit in "$@"; do systemctl is-active --quiet "$unit" || return 1; done; }
[[ "$MODE" == --install || "$MODE" == --check ]] || fail "Use --check or --install."
[[ "$(id -u)" -eq 0 ]] || fail "Run this command on the VPS as root."
[[ -r /etc/os-release ]] || fail "The VPS operating system cannot be identified."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:debian|*:*\ debian|*:debian\ *|*:*\ debian\ *) ;;
    *) fail "This installer currently requires a Debian-family VPS using UFW." ;;
esac
for command in python3 systemctl systemd-run ufw nft iptables ip6tables caddy curl getent groupadd useradd runuser install tar; do
    command -v "$command" >/dev/null || fail "Required command is missing: $command."
done
systemctl is-active --quiet xray.service || fail "The existing Xray service is not active."
systemctl is-active --quiet caddy.service || fail "The existing Caddy service is not active."
systemctl is-active --quiet ufw.service || fail "UFW is not active."
ufw status | grep -q '^Status: active' || fail "UFW is not enabled."
[[ "$(systemctl show caddy.service -p CanReload --value)" == yes ]] || fail "Caddy does not support a configuration reload."
[[ -r "$REPO_ROOT/server/config/setup.conf" ]] || fail "Install the existing proxy first so its private configuration is available."
[[ -r /usr/local/etc/xray/config.json ]] || fail "The existing Xray configuration is unavailable."
if [[ "$MODE" == --install && -f "$CONFIG_ROOT/environment" && -f "$CADDY_SITE" ]] && all_active "${UNITS[@]}" clash-traffic-gate.service; then
    installed_host="$(python3 - "$CONFIG_ROOT/environment" <<'PY'
from pathlib import Path
import re
import sys
values = [line.partition("=")[2] for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith("TRAFFIC_PUBLIC_HOST=")]
if len(values) != 1 or not re.fullmatch(r"traffic\.(?:[0-9]{1,3}\.){4}sslip\.io", values[0]):
    raise SystemExit("The existing dashboard hostname is invalid")
print(values[0])
PY
)"
    echo "The existing dashboard is running; no services or credentials were changed."
    echo "Traffic dashboard: https://$installed_host:$HTTPS_PORT/"
    echo "Administrator username: admin"
    if [[ -f "$CONFIG_ROOT/admin-login.txt" ]]; then
        echo "To read the initial password on this VPS: sudo cat $CONFIG_ROOT/admin-login.txt"
    else
        echo "The initial credentials file is unavailable; use your saved administrator password."
    fi
    exit 0
fi
[[ ! -e "$APP_ROOT" && ! -e "$CONFIG_ROOT" && ! -e "$DATA_ROOT" && ! -e "$CADDY_SITE" ]] || fail "Traffic dashboard files already exist; this installer will not replace them."
for unit in "${UNITS[@]}" clash-traffic-gate.service clash-traffic-preview.service clash-traffic-original.service clash-traffic-autostart.service; do
    [[ "$(systemctl show "$unit" -p LoadState --value)" == not-found ]] || fail "An existing traffic service requires a separate migration: $unit."
done
for account in clash-traffic-web clash-traffic-capture; do
    ! getent passwd "$account" >/dev/null || fail "The system account already exists: $account."
done
! getent group clash-traffic-data >/dev/null || fail "The traffic data group already exists."
getent passwd caddy >/dev/null || fail "The existing Caddy account is missing."
if ufw status | grep -Eq "^${HTTPS_PORT}(/tcp)?[[:space:]]"; then
    fail "The dashboard firewall port already has a rule; it will not be replaced."
fi

PYTHON="${TRAFFIC_PYTHON:-python3}"
"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 11)' || fail "Python 3.11 or newer is required."
PUBLIC_IP="$(python3 - "$REPO_ROOT/server/config/setup.conf" <<'PY'
import ipaddress
from pathlib import Path
import sys

values = [line.partition("=")[2].strip().strip("'\"") for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith("PUBLIC_IP=")]
if len(values) != 1:
    raise SystemExit("The existing configuration must contain one PUBLIC_IP value")
address = ipaddress.ip_address(values[0])
if address.version != 4 or not address.is_global:
    raise SystemExit("The existing PUBLIC_IP must be a public IPv4 address")
print(address)
PY
)"
ORIGINAL_PORT="$(python3 - <<'PY'
import json
from pathlib import Path
config = json.loads(Path("/usr/local/etc/xray/config.json").read_text())
inbounds = config.get("inbounds", [])
if len(inbounds) != 1 or type(inbounds[0].get("port")) is not int or not 1 <= inbounds[0]["port"] <= 65535:
    raise SystemExit("The existing Xray listener is unsupported")
print(inbounds[0]["port"])
PY
)"

stage="$(mktemp -d /var/tmp/clash-traffic-install-XXXXXXXX)"
cleanup_stage() { [[ "$stage" == /var/tmp/clash-traffic-install-* ]] && rm -rf -- "$stage"; }
trap cleanup_stage EXIT
"$PYTHON" -m venv "$stage/venv" || fail "Python venv support is required."
"$stage/venv/bin/python" -m pip download --disable-pip-version-check -q -r "$SCRIPT_DIR/requirements.txt" -d "$stage/wheels"
"$stage/venv/bin/python" -m pip install --disable-pip-version-check --no-index --find-links "$stage/wheels" -q -r "$SCRIPT_DIR/requirements.txt"
HOSTNAME="$(cd "$SCRIPT_DIR" && TRAFFIC_ORIGINAL_PORT="$ORIGINAL_PORT" TRAFFIC_GATE_PROTECT_DIRECT=1 "$stage/venv/bin/python" deployment.py --source /usr/local/etc/xray/config.json --public-ip "$PUBLIC_IP" --caddyfile /etc/caddy/Caddyfile)"
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
if [[ "$MODE" == --check ]]; then
    echo "Preflight passed. Dashboard hostname: $HOSTNAME"
    echo "No proxy, firewall, Caddy, or dashboard service was changed."
    exit 0
fi

site_installed=0
firewall_added=0
gate_started=0
rollback() {
    local status=$?
    trap - ERR
    echo "Traffic dashboard installation failed; preserving the existing proxy." >&2
    if [[ "$gate_started" == 1 ]] || systemctl is-active --quiet clash-traffic-gate.service; then
        systemctl stop clash-traffic-gate.service || true
        echo "The collector remains running so redirected connections can finish." >&2
    else
        systemctl stop clash-traffic-network.service clash-traffic-capture.service clash-traffic-journal.service clash-traffic-scheduler.service clash-traffic-web.service clash-traffic-web.socket 2>/dev/null || true
    fi
    if [[ "$firewall_added" == 1 ]]; then ufw --force delete allow "${HTTPS_PORT}/tcp" >/dev/null || true; fi
    if [[ "$site_installed" == 1 && -f "$CADDY_SITE" ]]; then
        mv "$CADDY_SITE" "$CONFIG_ROOT/failed-caddy-site.conf" || true
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 && systemctl reload caddy.service || true
    fi
    systemctl disable "${UNITS[@]}" >/dev/null 2>&1 || true
    echo "New dashboard files remain under $APP_ROOT and $CONFIG_ROOT for inspection; no existing data was deleted." >&2
    exit "$status"
}
trap rollback ERR

groupadd --system clash-traffic-data
useradd --system --no-create-home --shell /usr/sbin/nologin --gid clash-traffic-data clash-traffic-web
useradd --system --no-create-home --shell /usr/sbin/nologin --gid clash-traffic-data clash-traffic-capture
install -d -m 0755 "$APP_ROOT/app" "$CONFIG_ROOT"
install -d -m 2770 -o root -g clash-traffic-data "$DATA_ROOT"
install -d -m 0700 -o clash-traffic-capture -g clash-traffic-data "$CONFIG_ROOT/private"
tar --exclude='__pycache__' --exclude='*.pyc' --exclude='*.sqlite3*' --exclude='*.db' \
    -cf - -C "$SCRIPT_DIR" dashboard traffic systemd manage.py requirements.txt \
    collector.py collector_async.py original.py prepare_original.py gate.py gate_setup.py \
    start-gate.sh prepare-firewall.sh activate-monitoring.sh | tar -xf - -C "$APP_ROOT/app"
chmod -R a+rX "$APP_ROOT/app"
"$PYTHON" -m venv "$APP_ROOT/venv"
"$APP_ROOT/venv/bin/python" -m pip install --disable-pip-version-check --no-index --find-links "$stage/wheels" -q -r "$APP_ROOT/app/requirements.txt"
chmod -R a+rX "$APP_ROOT/venv"
cat > "$CONFIG_ROOT/environment" <<EOF
TRAFFIC_PUBLIC_HOST=$HOSTNAME
TRAFFIC_HTTPS_PORT=$HTTPS_PORT
TRAFFIC_ORIGINAL_PORT=$ORIGINAL_PORT
TRAFFIC_GATE_PROTECT_DIRECT=1
EOF
chmod 0644 "$CONFIG_ROOT/environment"
"$APP_ROOT/venv/bin/python" -c 'import secrets; print(secrets.token_urlsafe(48))' > "$DATA_ROOT/secret"
chown root:clash-traffic-data "$DATA_ROOT/secret"
chmod 0640 "$DATA_ROOT/secret"
export TRAFFIC_DATA_DIR="$DATA_ROOT" TRAFFIC_PUBLIC_HOST="$HOSTNAME" TRAFFIC_HTTPS_PORT="$HTTPS_PORT" TRAFFIC_ORIGINAL_PORT="$ORIGINAL_PORT" TRAFFIC_GATE_PROTECT_DIRECT=1 DJANGO_SETTINGS_MODULE=traffic.secure_settings
unset TRAFFIC_SECRET_KEY
cd "$APP_ROOT/app"
umask 007
"$APP_ROOT/venv/bin/python" manage.py migrate --noinput
"$APP_ROOT/venv/bin/python" manage.py bootstrap_traffic_admin --credentials "$CONFIG_ROOT/admin-login.txt"
chown root:clash-traffic-data "$DATA_ROOT/traffic.sqlite3"
chmod 0660 "$DATA_ROOT/traffic.sqlite3"
"$APP_ROOT/venv/bin/python" prepare_original.py --source /usr/local/etc/xray/config.json --state-dir "$CONFIG_ROOT/private" --uid "$(id -u clash-traffic-capture)" --gid "$(getent group clash-traffic-data | cut -d: -f3)"
if runuser -u clash-traffic-web -- test -r "$CONFIG_ROOT/private/original-server.json"; then fail "The web account can read proxy credentials."; fi
runuser -u clash-traffic-capture -- test -r "$CONFIG_ROOT/private/original-server.json" || fail "The collector cannot read its private configuration."
runuser -u clash-traffic-web -- test -w "$DATA_ROOT/traffic.sqlite3" || fail "The dashboard cannot write its database."
runuser -u clash-traffic-capture -- test -w "$DATA_ROOT/traffic.sqlite3" || fail "The collector cannot write its database."

for unit in "${UNITS[@]}"; do install -m 0644 "$APP_ROOT/app/systemd/$unit" "/etc/systemd/system/$unit"; done
systemctl daemon-reload
systemctl start clash-traffic-web.socket clash-traffic-web.service
curl --noproxy '*' --unix-socket /run/clash-traffic-web/dashboard.sock --fail --silent --show-error --max-time 40 \
    -H "Host: $HOSTNAME:$HTTPS_PORT" -H 'X-Forwarded-Proto: https' http://localhost/login/ >/dev/null
if runuser -u nobody -- test -w /run/clash-traffic-web/dashboard.sock; then fail "The dashboard socket is accessible to unprivileged local users."; fi
cat > "$CADDY_SITE" <<EOF
https://$HOSTNAME:$HTTPS_PORT {
    reverse_proxy unix//run/clash-traffic-web/dashboard.sock {
        header_up X-Traffic-Client-IP {remote_host}
        header_up X-Forwarded-Proto https
    }
    tls {
        protocols tls1.2 tls1.3
    }
}
EOF
chmod 0644 "$CADDY_SITE"
site_installed=1
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl reload caddy.service
curl --noproxy '*' --resolve "$HOSTNAME:$HTTPS_PORT:127.0.0.1" --fail --silent --show-error \
    --retry 12 --retry-all-errors --retry-delay 5 --max-time 15 "https://$HOSTNAME:$HTTPS_PORT/login/" >/dev/null
ufw allow "${HTTPS_PORT}/tcp" comment 'clash-traffic-dashboard'
firewall_added=1
systemctl start clash-traffic-firewall.service clash-traffic-capture.service clash-traffic-journal.service clash-traffic-scheduler.service
systemctl start clash-traffic-network.service
gate_started=1
python3 - <<'PY'
import json
from pathlib import Path
import time

path = Path("/run/clash-traffic-gate/status.json")
deadline = time.monotonic() + 40
while time.monotonic() < deadline:
    try:
        state = json.loads(path.read_text())
        if state["state"] == "active" and time.time() - state["updated"] < 12:
            break
    except (OSError, ValueError, KeyError):
        pass
    time.sleep(1)
else:
    raise SystemExit("The monitored proxy path did not become healthy")
PY
systemctl enable "${UNITS[@]}"
trap - ERR
echo "Traffic dashboard: https://$HOSTNAME:$HTTPS_PORT/"
echo "Administrator username: admin"
echo "To read the initial password on this VPS: sudo cat $CONFIG_ROOT/admin-login.txt"
echo "Keep the password private and remove the credentials file after saving it securely."
