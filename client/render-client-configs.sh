#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/active-config"
DOCS_DIR="${RENDER_OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"

# shellcheck source=server/scripts/load-config.sh
source "${REPO_ROOT}/server/scripts/load-config.sh"
# shellcheck source=server/scripts/clash-rules.sh
source "${REPO_ROOT}/server/scripts/clash-rules.sh"
load_project_config "${REPO_ROOT}"

derive_reality_public_key() {
    local private_key="$1"
    local key_output=""

    command -v xray &>/dev/null || return 1
    key_output="$(xray x25519 -i "${private_key}")" || return 1
    awk -F': ' '/Public key|PublicKey|Password/ {print $2}' <<<"${key_output}"
}

emit_rendered_proxy_yaml() {
    local list_indent="$1"
    local proxy_name="$2"
    local server_address="$3"
    local field_indent="${list_indent}  "
    local q_name=""
    local q_address=""

    q_name="$(yaml_quote "${proxy_name}")"
    q_address="$(yaml_quote "${server_address}")"

    cat <<EOF
${list_indent}- name: ${q_name}
${field_indent}type: vless
${field_indent}server: ${q_address}
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
${field_indent}  support-x25519mlkem768: true
EOF
}

public_ip="${RENDER_PUBLIC_IP:-${PUBLIC_IP:-<server-public-ip>}}"
public_ipv6="${RENDER_PUBLIC_IPV6:-${PUBLIC_IPV6:-}}"
xray_port="${RENDER_XRAY_PORT:-${XRAY_PORT}}"
xray_uuid="${RENDER_XRAY_UUID:-${XRAY_UUID}}"
reality_server_name="${RENDER_REALITY_SERVER_NAME:-${REALITY_SERVER_NAME}}"
reality_short_id="${RENDER_REALITY_SHORT_ID:-${REALITY_SHORT_ID}}"
reality_public_key="${RENDER_REALITY_PUBLIC_KEY:-${REALITY_PUBLIC_KEY}}"
sub_token="${RENDER_SUB_TOKEN:-${SUB_TOKEN}}"
provider_url="${RENDER_PROVIDER_URL:-__VPS_PROVIDER_URL__}"
mihomo_public_ip="${RENDER_PUBLIC_IP:-__VPS_PUBLIC_IP__}"
mihomo_public_ipv6="${RENDER_PUBLIC_IPV6:-}"

if should_autodetect "${public_ipv6}"; then
    public_ipv6=""
fi

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

q_proxy_name="$(yaml_quote "${CLASH_PROXY_NAME}")"
q_public_ip="$(yaml_quote "${public_ip}")"
q_xray_uuid="$(yaml_quote "${xray_uuid}")"
q_reality_server_name="$(yaml_quote "${reality_server_name}")"
q_reality_fingerprint="$(yaml_quote "${REALITY_FINGERPRINT}")"
q_reality_public_key="$(yaml_quote "${reality_public_key}")"
q_reality_short_id="$(yaml_quote "${reality_short_id}")"
q_provider_url="$(yaml_quote "${provider_url}")"

ipv6_proxy_name="${CLASH_PROXY_NAME}-ipv6"
proxy_entries="$(emit_rendered_proxy_yaml "" "${CLASH_PROXY_NAME}" "${public_ip}")"
proxy_group_entries="  - ${q_proxy_name}"
if [[ -n "${public_ipv6}" ]]; then
    proxy_entries+=$'\n'"$(emit_rendered_proxy_yaml "" "${ipv6_proxy_name}" "${public_ipv6}")"
    proxy_group_entries+=$'\n'"  - $(yaml_quote "${ipv6_proxy_name}")"
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
${proxy_entries}
proxy-groups:
- name: PROXY
  type: select
  proxies:
${proxy_group_entries}
- name: Auto
  type: select
  proxies:
  - PROXY
${proxy_group_entries}
rules:
$(emit_clash_rule_lines "- " "${public_ip}" yes "${public_ipv6}")
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
${proxy_entries}
proxy-groups:
- name: PROXY
  type: select
  proxies:
${proxy_group_entries}
- name: Auto
  type: select
  proxies:
  - PROXY
${proxy_group_entries}
rules:
$(emit_clash_rule_lines "- " "${public_ip}" yes "${public_ipv6}")
EOF

cat > "${DOCS_DIR}/mihomo-provider.yaml" <<EOF
# Generated from server/config/setup.conf(.example) by client/render-client-configs.sh
# Personal domain rules are inserted by client/manage-user-rules.ps1.

mode: ${CLASH_RULE_MODE}
mixed-port: ${CLASH_MIXED_PORT}
allow-lan: false
log-level: info
ipv6: true
unified-delay: true
profile:
  store-selected: true

proxy-providers:
  vps:
    type: http
    url: ${q_provider_url}
    path: ./proxy_providers/vps.yaml
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      timeout: 5000
      lazy: true
      expected-status: 204

proxy-groups:
- name: Auto
  type: url-test
  use:
  - vps
  url: https://www.gstatic.com/generate_204
  interval: 300
  tolerance: 100
  lazy: true
- name: PROXY
  type: select
  proxies:
  - Auto
  use:
  - vps

rules:
# __USER_RULES__
$(emit_clash_rule_lines "- " "${mihomo_public_ip}" yes "${mihomo_public_ipv6}")
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
