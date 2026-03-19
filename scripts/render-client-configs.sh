#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs/active-config"

# shellcheck source=scripts/load-config.sh
source "${SCRIPT_DIR}/load-config.sh"
load_project_config "${REPO_ROOT}"

public_ip="${RENDER_PUBLIC_IP:-${PUBLIC_IP:-<server-public-ip>}}"
ss_port="${RENDER_SS_PORT:-${SS_PORT}}"
ss_method="${RENDER_SS_METHOD:-${SS_METHOD}}"
ss_password="${RENDER_SS_PASSWORD:-${SS_PASSWORD}}"
sub_token="${RENDER_SUB_TOKEN:-${SUB_TOKEN}}"

if should_autogenerate "${ss_password}"; then
    ss_password="<generated-password>"
fi

if should_autogenerate "${sub_token}"; then
    sub_token="<subscription-token>"
fi

mkdir -p "${DOCS_DIR}"

cat > "${DOCS_DIR}/clash-verge.yaml" <<EOF
# Generated from config/setup.conf(.example) by scripts/render-client-configs.sh

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
external-controller-pipe: \\\\.\pipe\verge-mihomo
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
  type: ss
  server: ${public_ip}
  port: ${ss_port}
  cipher: ${ss_method}
  password: ${ss_password}
  udp: true
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
# Generated from config/setup.conf(.example) by scripts/render-client-configs.sh

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
external-controller-pipe: \\\\.\pipe\verge-mihomo
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
  type: ss
  server: ${public_ip}
  port: ${ss_port}
  cipher: ${ss_method}
  password: ${ss_password}
  udp: true
proxy-groups:
- name: PROXY
  type: select
  proxies:
  - ${CLASH_PROXY_NAME}
rules:
- DOMAIN-SUFFIX,bitwarden.com,DIRECT
- DOMAIN-SUFFIX,bitwarden.eu,DIRECT
- DOMAIN,vault.bitwarden.com,DIRECT
- DOMAIN,vault.bitwarden.eu,DIRECT
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
# Generated from config/setup.conf(.example) by scripts/render-client-configs.sh

prepend:
  - IP-CIDR,${public_ip}/32,DIRECT,no-resolve
  - DOMAIN-SUFFIX,bitwarden.com,DIRECT
  - DOMAIN-SUFFIX,bitwarden.eu,DIRECT
  - DOMAIN,vault.bitwarden.com,DIRECT
  - DOMAIN,vault.bitwarden.eu,DIRECT
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

REM Generated from config/setup.conf(.example) by scripts/render-client-configs.sh
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
