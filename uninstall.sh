#!/usr/bin/env bash
#
# Uninstall Shadowsocks + Caddy setup
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/load-config.sh
source "${SCRIPT_DIR}/scripts/load-config.sh"
load_project_config "${SCRIPT_DIR}"

[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "Stopping services..."
systemctl disable --now ss-server@server 2>/dev/null || true
systemctl disable --now caddy 2>/dev/null || true

echo "Removing Shadowsocks..."
systemctl daemon-reload
rm -f /etc/systemd/system/ss-server@.service
rm -rf /etc/shadowsocks-libev
rm -f /usr/local/bin/ss-server /usr/local/bin/ss-local /usr/local/bin/ss-redir \
      /usr/local/bin/ss-tunnel /usr/local/bin/ss-manager /usr/local/bin/ss-nat \
      /usr/local/bin/ss-setup

echo "Removing Caddy configs..."
rm -rf /etc/caddy /var/lib/clash-sub
rm -f /etc/systemd/system/caddy.service.d/env.conf
rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
systemctl daemon-reload

echo "Removing firewalld rules (${SS_PORT})..."
firewall-cmd --permanent --remove-port="${SS_PORT}/tcp" 2>/dev/null || true
firewall-cmd --permanent --remove-port="${SS_PORT}/udp" 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true

echo "Removing SELinux port labels (${SS_PORT})..."
semanage port -d -t unreserved_port_t -p tcp "${SS_PORT}" 2>/dev/null || true
semanage port -d -t unreserved_port_t -p udp "${SS_PORT}" 2>/dev/null || true

userdel clashsub 2>/dev/null || true

echo "Done."
