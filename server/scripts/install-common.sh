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

detect_public_ipv6() {
    local detected_ipv6=""

    detected_ipv6="$(curl -fsS6 --max-time 5 ifconfig.me 2>/dev/null || true)"
    if [[ -z "${detected_ipv6}" ]] && command -v ip &>/dev/null; then
        detected_ipv6="$(ip -6 -o address show scope global 2>/dev/null \
            | awk '!/ temporary / && !/ deprecated / { sub(/\/.*/, "", $4); print $4; exit }')"
    fi

    printf '%s' "${detected_ipv6}"
}

validate_public_ipv6() {
    local address="$1"

    python3 - "${address}" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)

raise SystemExit(0 if address.version == 6 and address.is_global else 1)
PY
}

sslip_domain_for_address() {
    local address="$1"

    printf '%s.sslip.io' "${address//:/-}"
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
    local detected_ipv6=""
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
    public_ipv6="${PUBLIC_IPV6}"
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

    if should_autodetect "${public_ipv6}"; then
        detected_ipv6="$(detect_public_ipv6)"
        public_ipv6="${detected_ipv6}"
        if [[ -n "${public_ipv6}" ]]; then
            info "Detected PUBLIC_IPV6 automatically: ${public_ipv6}"
        else
            info "No public IPv6 address detected; IPv6 publishing is disabled."
        fi
    else
        info "Using PUBLIC_IPV6 from config file."
    fi

    if [[ -n "${public_ipv6}" ]] && ! validate_public_ipv6 "${public_ipv6}"; then
        error "PUBLIC_IPV6 must be a globally routable IPv6 address: ${public_ipv6}"
    fi

    echo ""
    echo "=== Configuration Summary ==="
    echo "  Installer variant : ${OS_FAMILY}"
    echo "  Xray port         : ${xray_port}"
    echo "  Public IP         : ${public_ip}"
    echo "  Public IPv6       : ${public_ipv6:-disabled}"
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
PUBLIC_IPV6=${public_ipv6}
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

emit_vless_proxy_yaml() {
    local list_indent="$1"
    local proxy_name="$2"
    local server_address="$3"
    local field_indent="${list_indent}  "
    local q_proxy_name=""
    local q_server_address=""
    local q_xray_uuid=""
    local q_reality_server_name=""
    local q_reality_fingerprint=""
    local q_reality_public_key=""
    local q_reality_short_id=""

    q_proxy_name="$(yaml_quote "${proxy_name}")"
    q_server_address="$(yaml_quote "${server_address}")"
    q_xray_uuid="$(yaml_quote "${xray_uuid}")"
    q_reality_server_name="$(yaml_quote "${reality_server_name}")"
    q_reality_fingerprint="$(yaml_quote "${reality_fingerprint}")"
    q_reality_public_key="$(yaml_quote "${reality_public_key}")"
    q_reality_short_id="$(yaml_quote "${reality_short_id}")"

    cat <<EOF
${list_indent}- name: ${q_proxy_name}
${field_indent}type: vless
${field_indent}server: ${q_server_address}
${field_indent}port: ${xray_port}
${field_indent}uuid: ${q_xray_uuid}
${field_indent}network: tcp
${field_indent}udp: true
${field_indent}tls: true
${field_indent}flow: xtls-rprx-vision
${field_indent}servername: ${q_reality_server_name}
${field_indent}client-fingerprint: ${q_reality_fingerprint}
${field_indent}packet-encoding: xudp
${field_indent}reality-opts:
${field_indent}  public-key: ${q_reality_public_key}
${field_indent}  short-id: ${q_reality_short_id}
EOF
}

write_subscription_yaml() {
    local yaml_file="$1"
    local ipv6_proxy_name="${CLASH_PROXY_NAME}-ipv6"
    local proxy_entries=""
    local proxy_group_entries=""

    proxy_entries="$(emit_vless_proxy_yaml "  " "${CLASH_PROXY_NAME}" "${public_ip}")"
    proxy_group_entries="      - $(yaml_quote "${CLASH_PROXY_NAME}")"
    if [[ -n "${public_ipv6}" ]]; then
        proxy_entries+=$'\n'"$(emit_vless_proxy_yaml "  " "${ipv6_proxy_name}" "${public_ipv6}")"
        proxy_group_entries+=$'\n'"      - $(yaml_quote "${ipv6_proxy_name}")"
    fi

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
${proxy_entries}

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
${proxy_group_entries}
  - name: "Auto"
    type: select
    proxies:
      - "PROXY"
${proxy_group_entries}

rules:
$(emit_clash_rule_lines "  - " "${public_ip}" yes "${public_ipv6}")
EOF
}

write_proxy_provider_yaml() {
    local yaml_file="$1"
    local ipv6_proxy_name="${CLASH_PROXY_NAME}-ipv6"
    local proxy_entries=""

    proxy_entries="$(emit_vless_proxy_yaml "  " "${CLASH_PROXY_NAME}" "${public_ip}")"
    if [[ -n "${public_ipv6}" ]]; then
        proxy_entries+=$'\n'"$(emit_vless_proxy_yaml "  " "${ipv6_proxy_name}" "${public_ipv6}")"
    fi

    cat > "${yaml_file}" <<EOF
# Generated by ${SCRIPT_NAME} on ${OS_ID} ${OS_VERSION_ID}

proxies:
${proxy_entries}
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
        'DOMAIN-SUFFIX,github.com,PROXY'
        'DOMAIN-SUFFIX,githubusercontent.com,PROXY'
        'DOMAIN-SUFFIX,githubcopilot.com,PROXY'
        'DOMAIN-SUFFIX,outlook.com,DIRECT'
        'DOMAIN-SUFFIX,office365.com,DIRECT'
        'DOMAIN-SUFFIX,office.net,DIRECT'
        'DOMAIN-SUFFIX,microsoft.com,DIRECT'
        'DOMAIN-SUFFIX,apps.apple.com,DIRECT'
        'DOMAIN-SUFFIX,appstore.com,DIRECT'
        'DOMAIN-SUFFIX,itunes.apple.com,DIRECT'
        'DOMAIN-SUFFIX,mail.me.com,DIRECT'
        'DOMAIN-SUFFIX,mail.icloud.com.cn,DIRECT'
        'DOMAIN-SUFFIX,mzstatic.com,DIRECT'
        'DOMAIN-SUFFIX,cdn-apple.com,DIRECT'
        'DOMAIN-SUFFIX,swcdn.apple.com,DIRECT'
        'DOMAIN-SUFFIX,appldnld.apple.com,DIRECT'
        'DOMAIN-SUFFIX,devstreaming-cdn.apple.com,DIRECT'
        'DOMAIN-SUFFIX,doubao.com,DIRECT'
        'DOMAIN-SUFFIX,byteimg.com,DIRECT'
        'DOMAIN-SUFFIX,weixin.qq.com,DIRECT'
        'DOMAIN-SUFFIX,bilibili.com,DIRECT'
        'DOMAIN-SUFFIX,xiaohongshu.com,DIRECT'
        'DOMAIN-SUFFIX,dianping.com,DIRECT'
        'DOMAIN-SUFFIX,dpfile.com,DIRECT'
        'DOMAIN-SUFFIX,meituan.com,DIRECT'
        'DOMAIN-SUFFIX,amap.com,DIRECT'
        'DOMAIN-SUFFIX,autonavi.com,DIRECT'
        'DOMAIN-SUFFIX,oray.com,DIRECT'
        'DOMAIN-SUFFIX,oray.net,DIRECT'
        'DOMAIN-SUFFIX,uuyc.163.com,DIRECT'
        'DOMAIN-SUFFIX,netease.com,DIRECT'
        'DOMAIN-SUFFIX,todesk.com,DIRECT'
        'GEOSITE,cn,DIRECT'
        'GEOIP,CN,DIRECT,no-resolve'
        'DOMAIN-SUFFIX,openai.com,PROXY'
        'MATCH,PROXY'
    )
    local pattern=""

    if [[ -n "${public_ipv6}" ]]; then
        required_patterns+=(
            'IP-CIDR6,.*?/128,DIRECT,no-resolve'
            "server: '${public_ipv6}'"
        )
    fi

    [[ -f "${yaml_file}" ]] || error "Generated subscription YAML is missing: ${yaml_file}"

    for pattern in "${required_patterns[@]}"; do
        if ! grep -Eq "${pattern}" "${yaml_file}"; then
            error "Generated subscription YAML is missing required content: ${pattern}"
        fi
    done

    info "Validated Clash/Mihomo subscription YAML."
}

validate_proxy_provider_yaml() {
    local yaml_file="$1"
    local required_patterns=(
        '^proxies:'
        'type: vless'
        'packet-encoding: xudp'
        'reality-opts:'
    )
    local forbidden_patterns=(
        '^proxy-groups:'
        '^rules:'
    )
    local pattern=""

    if [[ -n "${public_ipv6}" ]]; then
        required_patterns+=("server: '${public_ipv6}'")
    fi

    [[ -f "${yaml_file}" ]] || error "Generated proxy provider YAML is missing: ${yaml_file}"

    for pattern in "${required_patterns[@]}"; do
        if ! grep -Eq "${pattern}" "${yaml_file}"; then
            error "Generated proxy provider YAML is missing required content: ${pattern}"
        fi
    done

    for pattern in "${forbidden_patterns[@]}"; do
        if grep -Eq "${pattern}" "${yaml_file}"; then
            error "Generated proxy provider YAML contains forbidden content: ${pattern}"
        fi
    done

    info "Validated Mihomo proxy provider YAML."
}

configure_caddy() {
    local sub_dir="/var/lib/clash-sub"
    local yaml_file="${sub_dir}/${sub_token}.yaml"
    local provider_file="${sub_dir}/${sub_token}-provider.yaml"
    local domain=""
    local ipv6_domain=""
    local ipv6_http_redirect=""
    local subscription_sites=""

    [[ "${sub_token}" =~ ^[A-Za-z0-9._-]+$ ]] \
        || error "SUB_TOKEN must contain only letters, digits, dots, underscores, or hyphens."

    domain="$(sslip_domain_for_address "${public_ip}")"
    subscription_sites="https://${domain}:${subscription_port}"
    if [[ -n "${public_ipv6}" ]]; then
        ipv6_domain="$(sslip_domain_for_address "${public_ipv6}")"
        subscription_sites+=$',\n'"https://${ipv6_domain}:${subscription_port}"
        ipv6_http_redirect="http://${ipv6_domain} {
    redir https://${ipv6_domain}:${subscription_port}{uri}
}"
    fi

    info "Setting up Clash subscription directory..."
    id clashsub &>/dev/null || useradd -r -s /usr/sbin/nologin -d "${sub_dir}" clashsub 2>/dev/null || useradd -r -s /sbin/nologin -d "${sub_dir}" clashsub
    install -d -m 0750 -o clashsub -g caddy "${sub_dir}"

    info "Generating Clash/Mihomo subscription YAML..."
    rm -f "${sub_dir}"/*.yaml
    write_subscription_yaml "${yaml_file}"
    validate_subscription_yaml "${yaml_file}"
    write_proxy_provider_yaml "${provider_file}"
    validate_proxy_provider_yaml "${provider_file}"
    chmod 0640 "${yaml_file}" "${provider_file}"
    chown clashsub:caddy "${yaml_file}" "${provider_file}"

    # Remove the credential-bearing homepage left by older installations.
    rm -f "${sub_dir}/index.html"

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

${ipv6_http_redirect}

import /etc/caddy/Caddyfile.d/*.caddyfile
EOF

    cat > /etc/caddy/Caddyfile.d/clash-sub.caddyfile <<EOF
${subscription_sites} {
    @subscription path /${sub_token}.yaml /${sub_token}-provider.yaml
    handle @subscription {
        root * ${sub_dir}
        header Content-Type "text/yaml; charset=utf-8"
        header Cache-Control "no-store"
        file_server
    }

    handle {
        respond 404
    }

    tls {
        protocols tls1.2 tls1.3
    }
}
EOF

    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
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
    PUBLIC_IPV6="${public_ipv6}" \
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
    local provider_domain=""
    local provider_url=""

    provider_domain="$(sslip_domain_for_address "${public_ip}")"
    provider_url="https://${provider_domain}:${subscription_port}/${sub_token}-provider.yaml"

    info "Rendering local client example files from config..."
    RENDER_PUBLIC_IP="${public_ip}" \
    RENDER_PUBLIC_IPV6="${public_ipv6}" \
    RENDER_XRAY_PORT="${xray_port}" \
    RENDER_XRAY_UUID="${xray_uuid}" \
    RENDER_REALITY_PUBLIC_KEY="${reality_public_key}" \
    RENDER_REALITY_SHORT_ID="${reality_short_id}" \
    RENDER_REALITY_SERVER_NAME="${reality_server_name}" \
    RENDER_SUB_TOKEN="${sub_token}" \
    RENDER_PROVIDER_URL="${provider_url}" \
    RENDER_OUTPUT_DIR="${REPO_ROOT}/client/local-config" \
    bash "${REPO_ROOT}/client/render-client-configs.sh"
}

print_summary() {
    local domain=""
    local ipv6_domain=""
    local legacy_ss_port=""
    local subscription_url=""
    local provider_url=""
    local ipv6_subscription_url=""
    local ipv6_provider_url=""

    domain="$(sslip_domain_for_address "${public_ip}")"
    subscription_url="https://${domain}:${subscription_port}/${sub_token}.yaml"
    provider_url="https://${domain}:${subscription_port}/${sub_token}-provider.yaml"
    if [[ -n "${public_ipv6}" ]]; then
        ipv6_domain="$(sslip_domain_for_address "${public_ipv6}")"
        ipv6_subscription_url="https://${ipv6_domain}:${subscription_port}/${sub_token}.yaml"
        ipv6_provider_url="https://${ipv6_domain}:${subscription_port}/${sub_token}-provider.yaml"
    fi

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
    echo "    IPv4 Server   : ${public_ip}:${xray_port}"
    if [[ -n "${public_ipv6}" ]]; then
        echo "    IPv6 Server   : [${public_ipv6}]:${xray_port}"
    fi
    echo "    UUID          : ${xray_uuid}"
    echo "    Flow          : xtls-rprx-vision"
    echo "    Server Name   : ${reality_server_name}"
    echo "    Public Key    : ${reality_public_key}"
    echo "    Short ID      : ${reality_short_id}"
    echo "    UDP           : enabled (XUDP)"
    echo "    Config        : /usr/local/etc/xray/config.json"
    echo ""
    echo "  Clash Subscription"
    echo "    IPv4 URL      : ${subscription_url}"
    if [[ -n "${ipv6_subscription_url}" ]]; then
        echo "    IPv6 URL      : ${ipv6_subscription_url}"
    fi
    echo "    Includes      : proxies, proxy-groups, rules"
    echo "    IPv4 Provider : ${provider_url}"
    if [[ -n "${ipv6_provider_url}" ]]; then
        echo "    IPv6 Provider : ${ipv6_provider_url}"
    fi
    echo "    Provider has  : proxies only"
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
    if [[ -n "${ipv6_subscription_url}" ]]; then
        echo "    ${ipv6_subscription_url}"
    fi
    echo ""
    echo "  Mihomo node provider URL:"
    echo "    ${provider_url}"
    if [[ -n "${ipv6_provider_url}" ]]; then
        echo "    ${ipv6_provider_url}"
    fi
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
