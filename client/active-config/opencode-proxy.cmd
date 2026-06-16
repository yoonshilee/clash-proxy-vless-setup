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
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "if(Get-NetTCPConnection -State Listen -LocalPort 7897 -ErrorAction SilentlyContinue){'yes'}else{'no'}"`) do set "_CLASH_RUNNING=%%i"

if /I "%_CLASH_RUNNING%"=="yes" (
  set "HTTP_PROXY=http://127.0.0.1:7897"
  set "HTTPS_PROXY=http://127.0.0.1:7897"
  set "ALL_PROXY=socks5://127.0.0.1:7898"
  set "NO_PROXY=localhost,127.0.0.1,::1"
  set "http_proxy=http://127.0.0.1:7897"
  set "https_proxy=http://127.0.0.1:7897"
  set "all_proxy=socks5://127.0.0.1:7898"
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
  for /f "usebackq delims=" %%i in (`where.exe opencode 2^>NUL`) do (
    if /I not "%%~fi"=="%_SELF%" if /I not "%%~nxi"=="opencode-proxy.cmd" if not defined _OPENCODE_TARGET set "_OPENCODE_TARGET=%%~fi"
  )
)

if not defined _OPENCODE_TARGET (
  for %%F in (
    "%LOCALAPPDATA%\Programs\opencode\opencode.exe"
    "%LOCALAPPDATA%\Microsoft\WinGet\Links\opencode.exe"
    "%_USER_HOME%\.local\bin\opencode.exe"
    "%_USER_HOME%\.local\share\opencode\bin\opencode.exe"
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
