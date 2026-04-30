#!/usr/bin/env bash

set -euo pipefail

INSTALLER_VARIANT="${INSTALLER_VARIANT:-}"

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

# shellcheck source=server/scripts/clash-rules.sh
source "${REPO_ROOT}/server/scripts/clash-rules.sh"

detect_os() {
    [[ -f /etc/os-release ]] || error "Cannot detect OS: /etc/os-release is missing."

    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"

    case "${OS_ID}" in
        ubuntu)
            OS_FAMILY="ubuntu"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            OS_FAMILY="centos"
            ;;
        *)
            case " ${OS_ID_LIKE} " in
                *" rhel "*|*" fedora "*)
                    OS_FAMILY="centos"
                    ;;
                *" debian "*)
                    OS_FAMILY="ubuntu"
                    ;;
                *)
                    error "Unsupported OS: ${OS_ID} ${OS_VERSION_ID}. Use Ubuntu or a CentOS/RHEL-compatible system."
                    ;;
            esac
            ;;
    esac

    if [[ -n "${INSTALLER_VARIANT}" && "${INSTALLER_VARIANT}" != "${OS_FAMILY}" ]]; then
        error "This machine is ${OS_ID} ${OS_VERSION_ID}. Use server/install-${OS_FAMILY}.sh instead."
    fi

    info "Detected OS: ${OS_ID} ${OS_VERSION_ID} (${OS_FAMILY})"
}

random_hex() {
    openssl rand -hex "$1"
}

random_uuid() {
    cat /proc/sys/kernel/random/uuid
}

detect_public_ip() {
    curl -fsS4 --max-time 5 ifconfig.me || hostname -I | awk '{print $1}'
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

install_os_prerequisites() {
    case "${OS_FAMILY}" in
        centos)
            info "Installing OS prerequisites with dnf..."
            dnf install -y curl openssl ca-certificates python3
            ;;
        ubuntu)
            info "Installing OS prerequisites with apt..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y curl openssl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https python3 ufw
            ;;
    esac
}

install_xray() {
    if command -v xray &>/dev/null; then
        info "Xray already installed: $(xray version 2>&1 | head -1)"
        return
    fi

    info "Installing Xray using the official installer..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-logfiles
    info "Xray installed: $(xray version 2>&1 | head -1)"
}

ensure_runtime_values() {
    local key_output=""
    local detected_ip=""
    local input=""

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
        info "Detected PUBLIC_IP automatically: ${public_ip}"
    else
        info "Using PUBLIC_IP from config file."
    fi

    echo ""
    echo "=== Configuration Summary ==="
    echo "  Installer variant : ${OS_FAMILY}"
    echo "  Xray port         : ${xray_port}"
    echo "  Public IP         : ${public_ip}"
    echo "  Proxy name        : ${CLASH_PROXY_NAME}"
    echo "  Reality target    : ${reality_dest}"
    echo "  Reality SNI       : ${reality_server_name}"
    echo "  Subscription port : ${subscription_port}"
    echo "  Clash mixed port  : ${CLASH_MIXED_PORT}"
    echo "  Clash mode        : ${CLASH_RULE_MODE}"
    echo "  UDP support       : enabled (XUDP)"
    echo ""

    read -rp "Proceed with these settings? [Y/n] " input
    [[ "${input:-Y}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
}

write_runtime_config() {
    local config_path="${PROJECT_USER_CONFIG:-${REPO_ROOT}/server/config/setup.conf}"
    local backup_path="${config_path}.bak"

    if [[ -f "${config_path}" && ! -f "${backup_path}" ]]; then
        cp "${config_path}" "${backup_path}"
    fi

    cat > "${config_path}" <<EOF
# Generated by ${SCRIPT_NAME}.
# This private local config file now contains the final effective values from the last successful install.

# Server-side settings
XRAY_PORT=${xray_port}
PUBLIC_IP=${public_ip}
REALITY_SERVER_NAME=${reality_server_name}
REALITY_DEST=${reality_dest}
REALITY_FINGERPRINT=${reality_fingerprint}
SUBSCRIPTION_PORT=${subscription_port}

# Generated or user-provided runtime values
XRAY_UUID=${xray_uuid}
REALITY_PRIVATE_KEY=${reality_private_key}
REALITY_PUBLIC_KEY=${reality_public_key}
REALITY_SHORT_ID=${reality_short_id}
SUB_TOKEN=${sub_token}

# Client example settings
CLASH_PROXY_NAME=${CLASH_PROXY_NAME}
CLASH_MIXED_PORT=${CLASH_MIXED_PORT}
CLASH_GLOBAL_MODE=${CLASH_GLOBAL_MODE}
CLASH_RULE_MODE=${CLASH_RULE_MODE}
CLASH_DIRECT_EXTRA_DOMAINS=${CLASH_DIRECT_EXTRA_DOMAINS}
EOF

    info "Saved effective install values to ${config_path}"
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

    case "${OS_FAMILY}" in
        centos)
            info "Installing Caddy from the official COPR repository..."
            dnf install -y dnf-plugins-core
            dnf copr enable -y @caddy/caddy
            dnf install -y caddy
            ;;
        ubuntu)
            info "Installing Caddy from the official APT repository..."
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
            chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
            chmod o+r /etc/apt/sources.list.d/caddy-stable.list
            apt-get update
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y caddy
            ;;
    esac

    info "Caddy installed: $(caddy version 2>&1 | head -1)"
}

write_subscription_yaml() {
    local yaml_file="$1"

    cat > "${yaml_file}" <<EOF
# Generated by ${SCRIPT_NAME} on ${OS_ID} ${OS_VERSION_ID}

mode: ${CLASH_RULE_MODE}
mixed-port: ${CLASH_MIXED_PORT}
allow-lan: false
log-level: info
ipv6: true
unified-delay: true
profile:
  store-selected: true
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
  - name: "PROXY"
    type: select
    proxies:
      - "${CLASH_PROXY_NAME}"
  - name: "Auto"
    type: select
    proxies:
      - "PROXY"
      - "${CLASH_PROXY_NAME}"

rules:
$(emit_clash_rule_lines "  - " "${public_ip}" yes)
EOF
}

validate_subscription_yaml() {
    local yaml_file="$1"
    local required_patterns=(
        '^mode: rule$'
        '^proxies:'
        '^proxy-groups:'
        '^rules:'
        'type: vless'
        'packet-encoding: xudp'
        'reality-opts:'
        'name: "PROXY"'
        'name: "Auto"'
        'IP-CIDR,.*?/32,DIRECT,no-resolve'
        'DOMAIN-SUFFIX,outlook.com,DIRECT'
        'DOMAIN-SUFFIX,office365.com,DIRECT'
        'DOMAIN-SUFFIX,office.net,DIRECT'
        'DOMAIN-SUFFIX,microsoft.com,DIRECT'
        'DOMAIN-SUFFIX,openai.com,PROXY'
        'MATCH,PROXY'
    )
    local pattern=""

    [[ -f "${yaml_file}" ]] || error "Generated subscription YAML is missing: ${yaml_file}"

    for pattern in "${required_patterns[@]}"; do
        if ! grep -Eq "${pattern}" "${yaml_file}"; then
            error "Generated subscription YAML is missing required content: ${pattern}"
        fi
    done

    info "Validated Clash/Mihomo subscription YAML."
}

configure_caddy() {
    local sub_dir="/var/lib/clash-sub"
    local yaml_file="${sub_dir}/${sub_token}.yaml"
    local domain="${public_ip}.sslip.io"

    info "Setting up Clash subscription directory..."
    id clashsub &>/dev/null || useradd -r -s /usr/sbin/nologin -d "${sub_dir}" clashsub 2>/dev/null || useradd -r -s /sbin/nologin -d "${sub_dir}" clashsub
    install -d -m 0750 -o clashsub -g caddy "${sub_dir}"

    info "Generating Clash/Mihomo subscription YAML..."
    rm -f "${sub_dir}"/*.yaml
    write_subscription_yaml "${yaml_file}"
    validate_subscription_yaml "${yaml_file}"
    chmod 0640 "${yaml_file}"
    chown clashsub:caddy "${yaml_file}"

    cat > "${sub_dir}/index.html" <<EOF
<!DOCTYPE html><html><body><h2>Mihomo subscription</h2>
<p>Use this URL in Clash Verge / Mihomo:</p>
<code>https://${domain}:${subscription_port}/${sub_token}.yaml</code>
</body></html>
EOF
    chmod 0640 "${sub_dir}/index.html"
    chown clashsub:caddy "${sub_dir}/index.html"

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

    @yaml path *.yaml
    header @yaml Content-Type "text/yaml; charset=utf-8"
    header @yaml Cache-Control "no-store"

    tls {
        protocols tls1.2 tls1.3
    }
}
EOF

    systemctl daemon-reload
    systemctl enable caddy
    systemctl restart caddy
    info "Caddy configured and restarted."
}

configure_firewall() {
    local legacy_ss_port=""
    local firewall_script=""

    legacy_ss_port="$(get_legacy_ss_port)"

    case "${OS_FAMILY}" in
        centos)
            firewall_script="${REPO_ROOT}/server/scripts/open-firewall-centos.sh"
            ;;
        ubuntu)
            firewall_script="${REPO_ROOT}/server/scripts/open-firewall-ubuntu.sh"
            ;;
    esac

    [[ -n "${firewall_script}" && -f "${firewall_script}" ]] || error "Missing firewall script for ${OS_FAMILY}: ${firewall_script}"

    info "Configuring firewall with ${firewall_script##*/}..."
    XRAY_PORT="${xray_port}" \
    SUBSCRIPTION_PORT="${subscription_port}" \
    LEGACY_SS_PORT="${legacy_ss_port}" \
    bash "${firewall_script}"

    info "Firewall updated (ports 22/tcp, 80/tcp, ${xray_port}/tcp, ${subscription_port}/tcp)."
}

configure_selinux() {
    local mode=""
    local legacy_ss_port=""

    if [[ "${OS_FAMILY}" != "centos" ]]; then
        return
    fi

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
    info "Rendering local client example files from config..."
    RENDER_PUBLIC_IP="${public_ip}" \
    RENDER_XRAY_PORT="${xray_port}" \
    RENDER_XRAY_UUID="${xray_uuid}" \
    RENDER_REALITY_PUBLIC_KEY="${reality_public_key}" \
    RENDER_REALITY_SHORT_ID="${reality_short_id}" \
    RENDER_REALITY_SERVER_NAME="${reality_server_name}" \
    RENDER_SUB_TOKEN="${sub_token}" \
    RENDER_OUTPUT_DIR="${REPO_ROOT}/client/local-config" \
    bash "${REPO_ROOT}/client/render-client-configs.sh"
}

print_summary() {
    local domain="${public_ip}.sslip.io"
    local legacy_ss_port=""
    local subscription_url="https://${domain}:${subscription_port}/${sub_token}.yaml"

    legacy_ss_port="$(get_legacy_ss_port)"

    echo ""
    echo "============================================"
    echo "  Setup complete!"
    echo "============================================"
    echo ""
    echo "  VPS OS"
    echo "    Variant       : ${OS_ID} ${OS_VERSION_ID}"
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
    echo "    URL           : ${subscription_url}"
    echo "    Includes      : proxies, proxy-groups, rules"
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
    if [[ "${OS_FAMILY}" == "centos" ]]; then
        echo "    firewall-cmd --list-all"
        echo "    getenforce"
    else
        echo "    ufw status verbose"
    fi
    echo ""
    echo "  Save this subscription URL on your personal computer:"
    echo "    ${subscription_url}"
    echo ""
}

main_install() {
    require_root
    detect_os
    install_os_prerequisites
    install_xray
    ensure_runtime_values
    write_runtime_config
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
