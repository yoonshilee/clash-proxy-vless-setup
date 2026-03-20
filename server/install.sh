#!/usr/bin/env bash
#
# Xray VLESS + REALITY + Caddy subscription setup
# Supports: CentOS Stream 9 / RHEL 9 / Fedora
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# shellcheck source=server/scripts/load-config.sh
source "${SCRIPT_DIR}/scripts/load-config.sh"
load_project_config "${REPO_ROOT}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || error "Please run as root (sudo)."
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION_ID="${VERSION_ID:-unknown}"
    else
        error "Cannot detect OS: /etc/os-release is missing."
    fi
    info "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
}

random_hex() {
    openssl rand -hex "$1"
}

random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

xray_port="${XRAY_PORT}"
xray_uuid="${XRAY_UUID}"
reality_private_key="${REALITY_PRIVATE_KEY}"
reality_public_key="${REALITY_PUBLIC_KEY}"
reality_short_id="${REALITY_SHORT_ID}"
reality_server_name="${REALITY_SERVER_NAME}"
reality_dest="${REALITY_DEST}"
reality_fingerprint="${REALITY_FINGERPRINT}"
sub_token="${SUB_TOKEN}"
public_ip="${PUBLIC_IP}"
subscription_port="${SUBSCRIPTION_PORT}"

detect_public_ip() {
    curl -s4 --max-time 5 ifconfig.me || hostname -I | awk '{print $1}'
}

get_legacy_ss_port() {
    local json="/etc/shadowsocks-libev/server.json"

    if [[ -f "${json}" ]]; then
        python3 - <<'PY'
import json
from pathlib import Path

path = Path('/etc/shadowsocks-libev/server.json')
try:
    data = json.loads(path.read_text())
    print(data.get('server_port', ''))
except Exception:
    print('')
PY
    fi
}

install_xray() {
    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version 2>&1 | head -1)"
        return
    fi

    info "Installing Xray using the official installer..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-logfiles
    info "Xray installed: $(xray version 2>&1 | head -1)"
}

ensure_runtime_values() {
    local key_output=""
    local detected_ip=""
    local input=""

    if should_autogenerate "${xray_uuid}"; then
        xray_uuid="$(random_uuid)"
        info "Generated VLESS UUID."
    else
        info "Using VLESS UUID from config file."
    fi

    if should_autogenerate "${sub_token}"; then
        sub_token="$(random_hex 20)"
        info "Generated subscription token."
    else
        info "Using subscription token from config file."
    fi

    if should_autogenerate "${reality_short_id}"; then
        reality_short_id="$(random_hex 8)"
        info "Generated REALITY short ID."
    else
        info "Using REALITY short ID from config file."
    fi

    if should_autogenerate "${reality_private_key}"; then
        key_output="$(xray x25519)"
        reality_private_key="$(awk -F': ' '/Private key|PrivateKey/ {print $2}' <<<"${key_output}")"
        reality_public_key="$(awk -F': ' '/Public key|PublicKey|Password/ {print $2}' <<<"${key_output}")"
        info "Generated REALITY key pair."
    elif should_autogenerate "${reality_public_key}"; then
        key_output="$(xray x25519 -i "${reality_private_key}")"
        reality_public_key="$(awk -F': ' '/Public key|PublicKey|Password/ {print $2}' <<<"${key_output}")"
        info "Derived REALITY public key from config private key."
    else
        info "Using REALITY key pair from config file."
    fi

    if [[ -z "${public_ip}" ]]; then
        detected_ip="$(detect_public_ip)"
        public_ip="${detected_ip}"
    fi

    echo ""
    echo "=== Configuration Summary ==="
    echo "  Xray port         : ${xray_port}"
    echo "  Public IP         : ${public_ip}"
    echo "  Proxy name        : ${CLASH_PROXY_NAME}"
    echo "  Reality target    : ${reality_dest}"
    echo "  Reality SNI       : ${reality_server_name}"
    echo "  Subscription port : ${subscription_port}"
    echo "  Clash mixed port  : ${CLASH_MIXED_PORT}"
    echo "  UDP support       : enabled (XUDP)"
    echo ""

    read -rp "Proceed with these settings? [Y/n] " input
    [[ "${input:-Y}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
}

disable_legacy_shadowsocks() {
    info "Stopping and disabling legacy Shadowsocks service if present..."
    systemctl disable --now "ss-server@server" 2>/dev/null || true
}

configure_xray() {
    local config_dir="/usr/local/etc/xray"
    local json="${config_dir}/config.json"

    info "Writing Xray config..."
    install -d -m 0755 "${config_dir}"

    cat > "${json}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${xray_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${xray_uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${reality_dest}",
          "xver": 0,
          "serverNames": ["${reality_server_name}"],
          "privateKey": "${reality_private_key}",
          "shortIds": ["${reality_short_id}"]
        },
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
    chmod 0600 "${json}"
    chown root:root "${json}"
    info "Config written to ${json}"
}

install_systemd_unit() {
    info "Installing Xray systemd unit..."
    cp "${TEMPLATES_DIR}/xray.service" /etc/systemd/system/xray.service
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    info "xray enabled and restarted."
}

install_caddy() {
    if command -v caddy &>/dev/null; then
        info "Caddy already installed: $(caddy version 2>&1 | head -1)"
        return
    fi

    info "Installing Caddy..."
    dnf install -y 'dnf-command(copr)'
    dnf copr enable -y @caddy/caddy
    dnf install -y caddy
    info "Caddy installed: $(caddy version 2>&1 | head -1)"
}

configure_caddy() {
    local sub_dir="/var/lib/clash-sub"
    local yaml_file="${sub_dir}/${sub_token}.yaml"
    local domain="${public_ip}.sslip.io"

    info "Setting up Clash subscription directory..."
    install -d -m 0750 -o clashsub -g caddy "${sub_dir}" 2>/dev/null || {
        id clashsub &>/dev/null || useradd -r -s /sbin/nologin -d "${sub_dir}" clashsub
        install -d -m 0750 -o clashsub -g caddy "${sub_dir}"
    }

    info "Generating Mihomo subscription YAML..."
    rm -f "${sub_dir}"/*.yaml
    cat > "${yaml_file}" <<YAML
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

proxies:
  - name: "${CLASH_PROXY_NAME}"
    type: vless
    server: ${public_ip}
    port: ${xray_port}
    uuid: ${xray_uuid}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${reality_server_name}
    client-fingerprint: ${reality_fingerprint}
    packet-encoding: xudp
    reality-opts:
      public-key: ${reality_public_key}
      short-id: ${reality_short_id}

proxy-groups:
  - name: "Auto"
    type: select
    proxies:
      - "${CLASH_PROXY_NAME}"

rules:
  - GEOIP,CN,DIRECT
  - MATCH,Auto
YAML
    chmod 0640 "${yaml_file}"
    chown clashsub:caddy "${yaml_file}"

    cat > "${sub_dir}/index.html" <<HTML
<!DOCTYPE html><html><body><h2>Mihomo subscription</h2>
<p>Use this URL in Clash Verge / Mihomo:</p>
<code>https://${domain}:${subscription_port}/${sub_token}.yaml</code>
</body></html>
HTML

    info "Writing Caddy configs..."
    install -d -m 0755 /etc/caddy/Caddyfile.d

    cat > /etc/caddy/Caddyfile <<EOF
{
    email admin@${domain}
    http_port 80
    https_port ${subscription_port}
}

http://${public_ip} {
    redir https://${domain}:${subscription_port}{uri}
}

http://${domain} {
    redir https://${domain}:${subscription_port}{uri}
}

import /etc/caddy/Caddyfile.d/*.caddyfile
EOF

    cat > /etc/caddy/Caddyfile.d/clash-sub.caddyfile <<EOF
https://${domain}:${subscription_port} {
    root * ${sub_dir}
    file_server

    header {
        Content-Type "text/yaml; charset=utf-8" {
            if {path} ends_with ".yaml"
        }
        Cache-Control "no-store" {
            if {path} ends_with ".yaml"
        }
    }

    tls {
        protocols tls1.2 tls1.3
    }
}
EOF

    rm -f /etc/systemd/system/caddy.service.d/env.conf
    rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true

    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy
    info "Caddy configured and restarted."
}

configure_firewall() {
    local legacy_ss_port=""

    info "Configuring firewalld..."
    systemctl is-active firewalld &>/dev/null || systemctl enable --now firewalld

    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-port="${xray_port}/tcp"
    firewall-cmd --permanent --add-port="${subscription_port}/tcp"

    legacy_ss_port="$(get_legacy_ss_port)"
    if [[ -n "${legacy_ss_port}" ]]; then
        firewall-cmd --permanent --remove-port="${legacy_ss_port}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --remove-port="${legacy_ss_port}/udp" 2>/dev/null || true
        info "Removed legacy Shadowsocks firewall rules for port ${legacy_ss_port}."
    fi

    firewall-cmd --reload
    info "Firewall updated (ports 80, 22, ${xray_port}/tcp, ${subscription_port}/tcp)."
}

configure_selinux() {
    local mode=""
    local legacy_ss_port=""

    if ! command -v semanage &>/dev/null; then
        dnf install -y policycoreutils-python-utils
    fi

    mode="$(getenforce 2>/dev/null || echo Disabled)"
    if [[ "${mode}" == "Disabled" ]]; then
        warn "SELinux is disabled, skipping port label changes."
        return
    fi

    info "SELinux mode: ${mode}"
    semanage port -a -t http_port_t -p tcp "${subscription_port}" 2>/dev/null \
        || semanage port -m -t http_port_t -p tcp "${subscription_port}"

    legacy_ss_port="$(get_legacy_ss_port)"
    if [[ -n "${legacy_ss_port}" ]]; then
        semanage port -d -t unreserved_port_t -p tcp "${legacy_ss_port}" 2>/dev/null || true
        semanage port -d -t unreserved_port_t -p udp "${legacy_ss_port}" 2>/dev/null || true
        info "Removed legacy Shadowsocks SELinux labels for port ${legacy_ss_port}."
    fi
}

render_client_examples() {
    info "Rendering client example files from config..."
    RENDER_PUBLIC_IP="${public_ip}" \
    RENDER_XRAY_PORT="${xray_port}" \
    RENDER_XRAY_UUID="${xray_uuid}" \
    RENDER_REALITY_PUBLIC_KEY="${reality_public_key}" \
    RENDER_REALITY_SHORT_ID="${reality_short_id}" \
    RENDER_REALITY_SERVER_NAME="${reality_server_name}" \
    RENDER_SUB_TOKEN="${sub_token}" \
    bash "${REPO_ROOT}/client/render-client-configs.sh"
}

print_summary() {
    local domain="${public_ip}.sslip.io"
    local legacy_ss_port=""

    legacy_ss_port="$(get_legacy_ss_port)"

    echo ""
    echo "============================================"
    echo "  Setup complete!"
    echo "============================================"
    echo ""
    echo "  VLESS + REALITY"
    echo "    Server        : ${public_ip}:${xray_port}"
    echo "    UUID          : ${xray_uuid}"
    echo "    Flow          : xtls-rprx-vision"
    echo "    Server Name   : ${reality_server_name}"
    echo "    Public Key    : ${reality_public_key}"
    echo "    Short ID      : ${reality_short_id}"
    echo "    UDP           : enabled (XUDP)"
    echo "    Config        : /usr/local/etc/xray/config.json"
    echo ""
    echo "  Clash Subscription"
    echo "    URL           : https://${domain}:${subscription_port}/${sub_token}.yaml"
    echo ""
    echo "  Legacy Shadowsocks"
    if [[ -n "${legacy_ss_port}" ]]; then
        echo "    Status        : disabled and stopped"
        echo "    Config kept   : /etc/shadowsocks-libev/server.json"
        echo "    Old port      : ${legacy_ss_port}"
    else
        echo "    Status        : no existing server config detected"
    fi
    echo ""
    echo "  Useful commands"
    echo "    systemctl status xray"
    echo "    systemctl restart xray"
    echo "    systemctl status caddy"
    echo "    systemctl status ss-server@server"
    echo "    firewall-cmd --list-all"
    echo "    getenforce"
    echo ""
}

main() {
    require_root
    detect_os
    install_xray
    ensure_runtime_values
    disable_legacy_shadowsocks
    configure_xray
    install_systemd_unit
    install_caddy
    configure_caddy
    configure_firewall
    configure_selinux
    render_client_examples
    print_summary
}

main "$@"
