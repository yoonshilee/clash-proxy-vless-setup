# clash-proxy-shadowsocks-setup

A split server-and-client repository for deploying a self-hosted Shadowsocks service on a VPS and consuming it from a local Clash client.

## What This Project Does

This project provides:

- a VPS-side installer for `shadowsocks-libev`
- automatic Caddy setup for serving a Clash subscription over HTTPS
- firewall and SELinux handling for the server port
- local Clash example files for importing or adapting the generated proxy connection

## Repository Structure

- `server/`: VPS-side installation, removal, shared config template, and systemd template
- `client/`: local Clash example files and helper scripts

## Main Outcome

After the VPS is installed, the server exposes a subscription URL that can be imported into Clash Verge or another Clash-compatible client on a personal computer.

## Shared Config

User-editable values are driven by `server/config/setup.conf`.

Start from:

- `server/config/setup.conf.example`

The same values are reused by the VPS scripts and the local client example generator.

Important variables include:

- `SS_PORT`
- `SS_METHOD`
- `PUBLIC_IP`
- `SS_PASSWORD`
- `SUB_TOKEN`
- `CLASH_PROXY_NAME`
- `CLASH_MIXED_PORT`
- `CLASH_GLOBAL_MODE`
- `CLASH_RULE_MODE`

## Local Client Setup

The local client side lives under `client/`. These files are not deployed to the VPS.

Typical local usage after the VPS installation is complete:

1. Get the subscription URL printed by `server/install.sh`.
2. Import that URL into Clash Verge.
3. If needed, create a manual node with the same server IP, port, method, and password.

If you want to regenerate the local example files from the shared config values, run:

```bash
bash client/render-client-configs.sh
```

Main local example files:

- `client/active-config/clash-verge.yaml`
- `client/active-config/clash-verge-check.yaml`
- `client/active-config/custom-routing-rules.yaml`
- `client/active-config/opencode-proxy.cmd`

## Notes

- VPS-side settings are driven by `server/config/setup.conf`
- local Clash examples are generated from the same shared values for convenience
- private server IPs, passwords, tokens, and local private config should not be committed
