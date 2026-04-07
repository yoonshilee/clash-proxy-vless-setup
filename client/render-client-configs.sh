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
setlocal

REM Generated from server/config/setup.conf(.example) by client/render-client-configs.sh
REM opencode (Bun/runtime variants) does NOT reliably respect WinINET system proxy on Windows.
REM It DOES respect HTTP_PROXY/HTTPS_PROXY env vars.
REM We set them here when Clash mixed port is reachable.
REM Launch strategy:
REM 1. Try the opencode command directly after setting env vars
REM 2. Fall back to OPENCODE_BIN if defined
REM 3. Fall back to sibling opencode.cmd / opencode.exe / opencode
REM 4. Fall back to common direct-install locations that expose the real opencode binary

set "_SELF=%~f0"
set "_SCRIPT_DIR=%~dp0"
set "_USER_HOME=%USERPROFILE%"
set "_OPENCODE_TARGET="
set "_CLASH_RUNNING="
for /f "usebackq delims=" %%i in (\`powershell -NoProfile -Command "if(Get-NetTCPConnection -State Listen -LocalPort ${CLASH_MIXED_PORT} -ErrorAction SilentlyContinue){'yes'}else{'no'}"\`) do set "_CLASH_RUNNING=%%i"

if /I "%_CLASH_RUNNING%"=="yes" (
  set "HTTP_PROXY=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "HTTPS_PROXY=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "ALL_PROXY=socks5://127.0.0.1:${CLASH_SOCKS_PORT}"
  set "NO_PROXY=localhost,127.0.0.1,::1"
  set "http_proxy=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "https_proxy=http://127.0.0.1:${CLASH_MIXED_PORT}"
  set "all_proxy=socks5://127.0.0.1:${CLASH_SOCKS_PORT}"
  set "no_proxy=localhost,127.0.0.1,::1"
  echo [opencode-proxy] Clash detected, proxy enabled
) else (
  echo [opencode-proxy] Clash not detected, starting without proxy
)

where.exe opencode >NUL 2>NUL
if not errorlevel 1 (
  echo [opencode-proxy] Launching: opencode
  endlocal & opencode %*
)

if defined OPENCODE_BIN (
  if exist "%OPENCODE_BIN%" (
    set "_OPENCODE_TARGET=%OPENCODE_BIN%"
  ) else (
    echo [opencode-proxy] OPENCODE_BIN is set but missing: %OPENCODE_BIN% 1>&2
    exit /b 1
  )
)

if not defined _OPENCODE_TARGET (
  for %%F in ("%_SCRIPT_DIR%opencode.cmd" "%_SCRIPT_DIR%opencode.exe" "%_SCRIPT_DIR%opencode") do (
    if exist "%%~fF" if /I not "%%~fF"=="%_SELF%" if not defined _OPENCODE_TARGET set "_OPENCODE_TARGET=%%~fF"
  )
)

if not defined _OPENCODE_TARGET (
  for /f "usebackq delims=" %%i in (\`where.exe opencode 2^>NUL\`) do (
    if /I not "%%~fi"=="%_SELF%" if /I not "%%~nxi"=="opencode-proxy.cmd" if not defined _OPENCODE_TARGET set "_OPENCODE_TARGET=%%~fi"
  )
)

if not defined _OPENCODE_TARGET (
  for %%F in (
    "%LOCALAPPDATA%\\Programs\\opencode\\opencode.exe"
    "%LOCALAPPDATA%\\Microsoft\\WinGet\\Links\\opencode.exe"
    "%_USER_HOME%\\.local\\bin\\opencode.exe"
    "%_USER_HOME%\\.local\\share\\opencode\\bin\\opencode.exe"
  ) do (
    if exist "%%~fF" if not defined _OPENCODE_TARGET set "_OPENCODE_TARGET=%%~fF"
  )
)

if not defined _OPENCODE_TARGET (
  echo [opencode-proxy] Could not find an OpenCode executable. 1>&2
  echo [opencode-proxy] Make sure 'opencode' works in cmd, or set OPENCODE_BIN to opencode.exe/opencode.cmd. 1>&2
  exit /b 1
)

echo [opencode-proxy] Launching: %_OPENCODE_TARGET%
endlocal & "%_OPENCODE_TARGET%" %*
EOF
