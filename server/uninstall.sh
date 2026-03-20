#!/usr/bin/env bash
#
# Uninstall Xray VLESS + REALITY + Caddy subscription setup
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=server/scripts/load-config.sh
source "${SCRIPT_DIR}/scripts/load-config.sh"
load_project_config "${REPO_ROOT}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "Stopping services..."
systemctl disable --now xray 2>/dev/null || true
systemctl disable --now caddy 2>/dev/null || true

echo "Removing Xray..."
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/xray@.service
rm -rf /etc/systemd/system/xray.service.d
rm -rf /etc/systemd/system/xray@.service.d
rm -rf /usr/local/etc/xray
rm -f /usr/local/bin/xray
rm -rf /usr/local/share/xray
systemctl daemon-reload

echo "Removing Caddy configs..."
rm -rf /etc/caddy /var/lib/clash-sub
rm -f /etc/systemd/system/caddy.service.d/env.conf
rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
systemctl daemon-reload

echo "Removing firewalld rules (${XRAY_PORT}, ${SUBSCRIPTION_PORT})..."
firewall-cmd --permanent --remove-port="${XRAY_PORT}/tcp" 2>/dev/null || true
firewall-cmd --permanent --remove-port="${SUBSCRIPTION_PORT}/tcp" 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

echo "Removing SELinux port labels (${SUBSCRIPTION_PORT})..."
semanage port -d -t http_port_t -p tcp "${SUBSCRIPTION_PORT}" 2>/dev/null || true

userdel clashsub 2>/dev/null || true

echo "Legacy Shadowsocks config and binaries were left in place."
echo "Done."
