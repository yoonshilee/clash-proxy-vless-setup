@echo off

REM Generated from server/config/setup.conf(.example) by client/render-client-configs.sh
REM opencode (Bun runtime) does NOT respect WinINET system proxy on Windows.
REM It DOES respect HTTP_PROXY/HTTPS_PROXY env vars.
REM We set them here when Clash mixed port is reachable.
REM This avoids permanent env vars that would pollute other applications.

set "_CLASH_RUNNING="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "if(Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 7897 -ErrorAction SilentlyContinue){'yes'}else{'no'}"`) do set "_CLASH_RUNNING=%%i"

if "%_CLASH_RUNNING%"=="yes" (
  set "HTTP_PROXY=http://127.0.0.1:7897"
  set "HTTPS_PROXY=http://127.0.0.1:7897"
  set "ALL_PROXY=http://127.0.0.1:7897"
  set "NO_PROXY=localhost,127.0.0.1,::1"
  echo [opencode-proxy] Clash detected, proxy enabled
)

"%~dp0opencode.cmd" %*
