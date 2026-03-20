#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCS_DIR="${SCRIPT_DIR}/active-config"

# shellcheck source=server/scripts/load-config.sh
source "${REPO_ROOT}/server/scripts/load-config.sh"
load_project_config "${REPO_ROOT}"

derive_reality_public_key() {
    local private_key="$1"
    local key_output=""

    command -v xray &>/dev/null || return 1
    key_output="$(xray x25519 -i "${private_key}")" || return 1
    awk -F': ' '/Public key|PublicKey|Password/ {print $2}' <<<"${key_output}"
}

public_ip="${RENDER_PUBLIC_IP:-${PUBLIC_IP:-<server-public-ip>}}"
xray_port="${RENDER_XRAY_PORT:-${XRAY_PORT}}"
xray_uuid="${RENDER_XRAY_UUID:-${XRAY_UUID}}"
reality_server_name="${RENDER_REALITY_SERVER_NAME:-${REALITY_SERVER_NAME}}"
reality_short_id="${RENDER_REALITY_SHORT_ID:-${REALITY_SHORT_ID}}"
reality_public_key="${RENDER_REALITY_PUBLIC_KEY:-${REALITY_PUBLIC_KEY}}"
sub_token="${RENDER_SUB_TOKEN:-${SUB_TOKEN}}"

if should_autogenerate "${xray_uuid}"; then
    xray_uuid="<generated-uuid>"
fi

if should_autogenerate "${reality_short_id}"; then
    reality_short_id="<generated-short-id>"
fi

if should_autogenerate "${reality_public_key}"; then
    reality_public_key=""
    if ! should_autogenerate "${REALITY_PRIVATE_KEY}"; then
        reality_public_key="$(derive_reality_public_key "${REALITY_PRIVATE_KEY}" 2>/dev/null || true)"
    fi

    if [[ -z "${reality_public_key}" ]]; then
        reality_public_key="<generated-public-key>"
    fi
fi

if should_autogenerate "${sub_token}"; then
    sub_token="<subscription-token>"
fi

mkdir -p "${DOCS_DIR}"

cat > "${DOCS_DIR}/clash-verge.yaml" <<EOF
# Generated from server/config/setup.conf(.example) by client/render-client-configs.sh

mode: ${CLASH_GLOBAL_MODE}
mixed-port: ${CLASH_MIXED_PORT}
allow-lan: false
log-level: info
ipv6: true
external-controller: ''
secret: set-your-secret
unified-delay: true
profile:
  store-selected: true
tun:
  enable: false
  stack: gvisor
  auto-route: true
  strict-route: false
  auto-detect-interface: true
  dns-hijack:
  - any:53
external-controller-pipe: \\\\.\\pipe\\verge-mihomo
external-controller-cors:
  allow-private-network: true
  allow-origins:
  - tauri://localhost
  - http://tauri.localhost
  - https://yacd.metacubex.one
  - https://metacubex.github.io
  - https://board.zash.run.place
proxies:
- name: ${CLASH_PROXY_NAME}
  type: vless
  server: ${public_ip}
  port: ${xray_port}
  uuid: ${xray_uuid}
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: ${reality_server_name}
  client-fingerprint: ${REALITY_FINGERPRINT}
  packet-encoding: xudp
  reality-opts:
    public-key: ${reality_public_key}
    short-id: ${reality_short_id}
proxy-groups:
- name: PROXY
  type: select
  proxies:
  - ${CLASH_PROXY_NAME}
rules:
- GEOSITE,microsoft,DIRECT
- DOMAIN-SUFFIX,outlook.com,DIRECT
- DOMAIN-SUFFIX,office.com,DIRECT
- DOMAIN-SUFFIX,office365.com,DIRECT
- DOMAIN-SUFFIX,microsoft.com,DIRECT
- DOMAIN-SUFFIX,live.com,DIRECT
- DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
- DOMAIN-SUFFIX,msftncsi.com,DIRECT
- GEOSITE,openai,PROXY
- DOMAIN-SUFFIX,openai.com,PROXY
- DOMAIN-SUFFIX,chatgpt.com,PROXY
- DOMAIN-SUFFIX,oaistatic.com,PROXY
- DOMAIN-SUFFIX,oaiusercontent.com,PROXY
- MATCH,PROXY
EOF

cat > "${DOCS_DIR}/clash-verge-check.yaml" <<EOF
# Generated from server/config/setup.conf(.example) by client/render-client-configs.sh

mode: ${CLASH_RULE_MODE}
mixed-port: ${CLASH_MIXED_PORT}
allow-lan: false
log-level: info
ipv6: true
external-controller: ''
secret: set-your-secret
unified-delay: true
profile:
  store-selected: true
tun:
  enable: false
  stack: gvisor
  auto-route: true
  strict-route: false
  auto-detect-interface: true
  dns-hijack:
  - any:53
external-controller-pipe: \\\\.\\pipe\\verge-mihomo
external-controller-cors:
  allow-private-network: true
  allow-origins:
  - tauri://localhost
  - http://tauri.localhost
  - https://yacd.metacubex.one
  - https://metacubex.github.io
  - https://board.zash.run.place
proxies:
- name: ${CLASH_PROXY_NAME}
  type: vless
  server: ${public_ip}
  port: ${xray_port}
  uuid: ${xray_uuid}
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: ${reality_server_name}
  client-fingerprint: ${REALITY_FINGERPRINT}
  packet-encoding: xudp
  reality-opts:
    public-key: ${reality_public_key}
    short-id: ${reality_short_id}
proxy-groups:
- name: PROXY
  type: select
  proxies:
  - ${CLASH_PROXY_NAME}
rules:
- GEOSITE,microsoft,DIRECT
- DOMAIN-SUFFIX,outlook.com,DIRECT
- DOMAIN-SUFFIX,office.com,DIRECT
- DOMAIN-SUFFIX,office365.com,DIRECT
- DOMAIN-SUFFIX,microsoft.com,DIRECT
- DOMAIN-SUFFIX,live.com,DIRECT
- DOMAIN-SUFFIX,live.net,DIRECT
- DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
- DOMAIN-SUFFIX,msftncsi.com,DIRECT
- DOMAIN-SUFFIX,msauth.net,DIRECT
- DOMAIN-SUFFIX,msftauth.net,DIRECT
- DOMAIN-SUFFIX,msidentity.com,DIRECT
- DOMAIN-SUFFIX,onestore.ms,DIRECT
- DOMAIN-SUFFIX,global.ssl.fastly.net,DIRECT
- DOMAIN-SUFFIX,azure.com,DIRECT
- DOMAIN-SUFFIX,azureedge.net,DIRECT
- GEOSITE,openai,PROXY
- DOMAIN-SUFFIX,openai.com,PROXY
- DOMAIN-SUFFIX,chatgpt.com,PROXY
- DOMAIN-SUFFIX,oaistatic.com,PROXY
- DOMAIN-SUFFIX,oaiusercontent.com,PROXY
- MATCH,PROXY
EOF

cat > "${DOCS_DIR}/custom-routing-rules.yaml" <<EOF
# Generated from server/config/setup.conf(.example) by client/render-client-configs.sh

prepend:
  - IP-CIDR,${public_ip}/32,DIRECT,no-resolve
  - GEOSITE,microsoft,DIRECT
  - DOMAIN-SUFFIX,outlook.com,DIRECT
  - DOMAIN-SUFFIX,office.com,DIRECT
  - DOMAIN-SUFFIX,office365.com,DIRECT
  - DOMAIN-SUFFIX,microsoft.com,DIRECT
  - DOMAIN-SUFFIX,live.com,DIRECT
  - DOMAIN-SUFFIX,live.net,DIRECT
  - DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
  - DOMAIN-SUFFIX,msftncsi.com,DIRECT
  - DOMAIN-SUFFIX,msauth.net,DIRECT
  - DOMAIN-SUFFIX,msftauth.net,DIRECT
  - DOMAIN-SUFFIX,msidentity.com,DIRECT
  - DOMAIN-SUFFIX,onestore.ms,DIRECT
  - DOMAIN-SUFFIX,global.ssl.fastly.net,DIRECT
  - DOMAIN-SUFFIX,azure.com,DIRECT
  - DOMAIN-SUFFIX,azureedge.net,DIRECT
  - GEOSITE,openai,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY

append: []

delete: []
EOF

cat > "${DOCS_DIR}/opencode-proxy.cmd" <<EOF
@echo off

REM Generated from server/config/setup.conf(.example) by client/render-client-configs.sh
REM opencode (Bun runtime) does NOT respect WinINET system proxy on Windows.
REM It DOES respect HTTP_PROXY/HTTPS_PROXY env vars.
REM We set them here when Clash mixed port is reachable.
REM This avoids permanent env vars that would pollute other applications.

set "_CLASH_RUNNING="
for /f "usebackq delims=" %%i in (\`powershell -NoProfile -Command "if(Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort ${CLASH_MIXED_PORT} -ErrorAction SilentlyContinue){'yes'}else{'no'}"\`) do set "_CLASH_RUNNING=%%i"

if "%_CLASH_RUNNING%"=="yes" (
  set "HTTP_PROXY=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "HTTPS_PROXY=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "ALL_PROXY=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "NO_PROXY=localhost,127.0.0.1,::1"
  echo [opencode-proxy] Clash detected, proxy enabled
)

"%~dp0opencode.cmd" %*
EOF
