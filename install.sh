#!/usr/bin/env bash
#
# Shadowsocks + Caddy (HTTPS Clash subscription) setup
# Supports: CentOS Stream 9 / RHEL 9 / Fedora
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# shellcheck source=scripts/load-config.sh
source "${SCRIPT_DIR}/scripts/load-config.sh"
load_project_config "${SCRIPT_DIR}"

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

ss_password="${SS_PASSWORD}"
ss_port="${SS_PORT}"
ss_method="${SS_METHOD}"
sub_token="${SUB_TOKEN}"
public_ip="${PUBLIC_IP}"

configure_runtime_values() {
    local detected_ip=""
    local input=""

    if should_autogenerate "${ss_password}"; then
        ss_password="$(random_hex 16)"
        info "Generated Shadowsocks password."
    else
        info "Using Shadowsocks password from config file."
    fi

    if should_autogenerate "${sub_token}"; then
        sub_token="$(random_hex 20)"
        info "Generated subscription token."
    else
        info "Using subscription token from config file."
    fi

    if [[ -z "${public_ip}" ]]; then
        detected_ip="$(curl -s4 --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
        public_ip="${detected_ip}"
    fi

    echo ""
    echo "=== Configuration Summary ==="
    echo "  SS port           : ${ss_port}"
    echo "  Encryption        : ${ss_method}"
    echo "  Public IP         : ${public_ip}"
    echo "  Proxy name        : ${CLASH_PROXY_NAME}"
    echo "  Clash mixed port  : ${CLASH_MIXED_PORT}"
    echo ""

    read -rp "Proceed with these settings? [Y/n] " input
    [[ "${input:-Y}" =~ ^[Yy]$ ]] || { info "Aborted."; exit 0; }
}

install_shadowsocks() {
    if command -v ss-server &>/dev/null; then
        info "shadowsocks-libev already installed: $(ss-server -h 2>&1 | head -1)"
        return
    fi

    info "Installing shadowsocks-libev from source..."
    dnf install -y epel-release
    dnf install -y gcc make autoconf automake libtool \
        libev-devel mbedtls-devel pcre-devel libsodium-devel c-ares-devel

    local tmpdir
    tmpdir="$(mktemp -d)"
    git clone --depth 1 --branch v3.3.6 \
        https://github.com/shadowsocks/shadowsocks-libev.git "${tmpdir}/shadowsocks-libev"
    pushd "${tmpdir}/shadowsocks-libev" >/dev/null
    git submodule update --init --recursive
    ./autogen.sh
    ./configure
    make
    make install
    popd >/dev/null
    rm -rf "${tmpdir}"

    info "ss-server installed: $(ss-server -h 2>&1 | head -1)"
}

configure_shadowsocks() {
    info "Writing Shadowsocks config..."
    install -d -m 0755 /etc/shadowsocks-libev

    local json="/etc/shadowsocks-libev/server.json"
    cat > "${json}" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${ss_port},
    "password": "${ss_password}",
    "method": "${ss_method}",
    "mode": "tcp_and_udp"
}
EOF
    chmod 0600 "${json}"
    chown root:root "${json}"
    info "Config written to ${json}"
}

install_systemd_unit() {
    info "Installing systemd template unit..."
    cp "${TEMPLATES_DIR}/ss-server@.service" /etc/systemd/system/ss-server@.service
    systemctl daemon-reload
    systemctl enable --now "ss-server@server"
    info "ss-server@server enabled and started."
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

    info "Generating Clash YAML..."
    cat > "${yaml_file}" <<YAML
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

proxies:
  - name: "${CLASH_PROXY_NAME}"
    type: ss
    server: ${public_ip}
    port: ${ss_port}
    cipher: ${ss_method}
    password: ${ss_password}
    udp: true

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
<!DOCTYPE html><html><body><h2>Clash subscription</h2>
<p>Use this URL in Clash Verge:</p>
<code>https://${domain}/${sub_token}.yaml</code>
</body></html>
HTML

    info "Writing Caddy configs..."
    install -d -m 0755 /etc/caddy/Caddyfile.d

    cat > /etc/caddy/Caddyfile <<EOF
{
    email admin@${domain}
}

http://\${PUBLIC_IP} {
    redir https://${domain}{uri}
}

http://${domain} {
    redir https://{host}{uri}
}

import /etc/caddy/Caddyfile.d/*.caddyfile
EOF

    cat > /etc/caddy/Caddyfile.d/clash-sub.caddyfile <<EOF
https://${domain} {
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

    mkdir -p /etc/systemd/system/caddy.service.d
    cat > /etc/systemd/system/caddy.service.d/env.conf <<EOF
[Service]
Environment=PUBLIC_IP=${public_ip}
EOF

    systemctl daemon-reload
    systemctl enable --now caddy || systemctl restart caddy
    info "Caddy configured and started."
}

configure_firewall() {
    info "Configuring firewalld..."
    systemctl is-active firewalld &>/dev/null || systemctl enable --now firewalld

    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-port="${ss_port}/tcp"
    firewall-cmd --permanent --add-port="${ss_port}/udp"
    firewall-cmd --reload
    info "Firewall updated (ports 80, 22, ${ss_port}/tcp+udp)."
}

configure_selinux() {
    if ! command -v semanage &>/dev/null; then
        dnf install -y policycoreutils-python-utils
    fi

    local mode
    mode="$(getenforce 2>/dev/null || echo Disabled)"
    if [[ "${mode}" == "Disabled" ]]; then
        warn "SELinux is disabled, skipping port label."
        return
    fi

    info "SELinux mode: ${mode}"
    semanage port -a -t unreserved_port_t -p tcp "${ss_port}" 2>/dev/null \
        || semanage port -m -t unreserved_port_t -p tcp "${ss_port}"
    semanage port -a -t unreserved_port_t -p udp "${ss_port}" 2>/dev/null \
        || semanage port -m -t unreserved_port_t -p udp "${ss_port}"
    info "SELinux port ${ss_port} labeled as unreserved_port_t."
}

render_client_examples() {
    info "Rendering client example files from config..."
    RENDER_PUBLIC_IP="${public_ip}" \
    RENDER_SS_PORT="${ss_port}" \
    RENDER_SS_METHOD="${ss_method}" \
    RENDER_SS_PASSWORD="${ss_password}" \
    RENDER_SUB_TOKEN="${sub_token}" \
    bash "${SCRIPT_DIR}/scripts/render-client-configs.sh"
}

print_summary() {
    local domain="${public_ip}.sslip.io"

    echo ""
    echo "============================================"
    echo "  Setup complete!"
    echo "============================================"
    echo ""
    echo "  Shadowsocks"
    echo "    Server   : ${public_ip}:${ss_port}"
    echo "    Password : ${ss_password}"
    echo "    Method   : ${ss_method}"
    echo "    Config   : /etc/shadowsocks-libev/server.json"
    echo ""
    echo "  Clash Subscription"
    echo "    URL      : https://${domain}/${sub_token}.yaml"
    echo ""
    echo "  Useful commands"
    echo "    systemctl status ss-server@server"
    echo "    systemctl restart ss-server@server"
    echo "    systemctl status caddy"
    echo "    firewall-cmd --list-all"
    echo "    getenforce"
    echo ""
}

main() {
    require_root
    detect_os
    configure_runtime_values
    install_shadowsocks
    configure_shadowsocks
    install_systemd_unit
    install_caddy
    configure_caddy
    configure_firewall
    configure_selinux
    render_client_examples
    print_summary
}

main "$@"
