# AGENTS.md

## Purpose

This file tells an agent how to work with this repository and, most importantly, which machine each action belongs to.

## Two Endpoints

There are two different environments in this project. Do not mix them.

### 1. VPS Side

This is the remote Linux server that hosts Xray `VLESS + REALITY` and Caddy.

Relevant files:

- `server/install.sh`
- `server/uninstall.sh`
- `server/config/setup.conf.example`
- `server/templates/xray.service`

Agent rules on the VPS side:

- Run `server/install.sh` only on the VPS.
- Run `server/uninstall.sh` only on the VPS.
- Edit `server/config/setup.conf` when changing server-side values.
- Server-side values include `XRAY_PORT`, `PUBLIC_IP`, `REALITY_SERVER_NAME`, `REALITY_DEST`, `XRAY_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`, `REALITY_SHORT_ID`, `SUB_TOKEN`, and `SUBSCRIPTION_PORT`.
- The installer requires root or sudo.
- The installer configures Xray, Caddy, firewall rules, and SELinux.
- The installer stops and disables the legacy Shadowsocks service if it exists, but keeps its config file in place.
- The installer prints the subscription URL at the end. That URL is meant for the personal computer side.

Typical VPS workflow:

1. Copy `server/config/setup.conf.example` to `server/config/setup.conf`.
2. Edit `server/config/setup.conf`.
3. Run `sudo bash server/install.sh` on the VPS.
4. Save the generated subscription URL.

### 2. Personal Computer Side

This is the local machine running Clash Verge, Mihomo, or another Clash-compatible client.

Relevant files:

- `client/render-client-configs.sh`
- `client/active-config/clash-verge.yaml`
- `client/active-config/clash-verge-check.yaml`
- `client/active-config/custom-routing-rules.yaml`
- `client/active-config/opencode-proxy.cmd`
- `client/README.md`

Agent rules on the personal computer side:

- Do not run `server/install.sh` on the personal computer.
- Do not treat local Clash files as VPS deployment files.
- Local Clash-related changes belong under `client/`.
- If the user asks to modify Clash local configuration, work on `client/active-config/*` or `client/render-client-configs.sh`.
- If the user only needs to use the server, importing the subscription URL into Clash Verge is usually enough.

Typical personal computer workflow:

1. Get the subscription URL produced on the VPS.
2. Import that URL into Clash Verge or Mihomo.
3. If custom local examples are needed, edit `server/config/setup.conf` values and run `bash client/render-client-configs.sh`.
4. Apply or adapt the files under `client/active-config/` locally.

## Operational Boundary

When deciding what to do, first determine the endpoint:

- If the task is about installing Xray, changing the REALITY port, opening firewall ports, configuring Caddy, or rotating REALITY credentials on the server, it is a VPS-side task.
- If the task is about Clash Verge profiles, routing rules, local proxy wrappers, or importing subscriptions, it is a personal-computer-side task.

If the endpoint is unclear, the agent should ask which side the user is working on before making changes.

## Safety

- Never commit real UUIDs, REALITY private keys, public keys, short IDs, subscription URLs, or private IPs.
- Treat `server/config/setup.conf` as private machine-specific configuration.
- Do not assume a local Clash config should be deployed to the VPS.
- Do not assume a VPS installation script should be run on the personal computer.
- Do not delete the legacy Shadowsocks config unless the user explicitly asks for full removal.
