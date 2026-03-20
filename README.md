# clash-proxy-shadowsocks-setup

A split server-and-client repository for migrating a VPS from legacy Shadowsocks to self-hosted `Xray VLESS + REALITY`, while keeping local Clash/Mihomo client examples in the same project.

## What This Project Does

This project provides:

- a VPS-side installer for `Xray` using `VLESS + REALITY + XTLS Vision`
- UDP-capable Mihomo/Clash client profiles using `packet-encoding: xudp`
- automatic Caddy setup for serving a Clash/Mihomo subscription over HTTPS on port `8443`
- firewall and SELinux handling for the server port and subscription port
- legacy Shadowsocks shutdown during migration without deleting its existing server config

## Repository Structure

- `server/`: VPS-side installation, removal, shared config template, and systemd templates
- `client/`: local Clash/Mihomo example files and helper scripts

## Main Outcome

After the VPS install completes, the server exposes:

- a `VLESS + REALITY` node on port `443`
- a subscription URL like `https://<public-ip>.sslip.io:8443/<token>.yaml`

The generated node is meant for Clash Verge, Mihomo, or another compatible client on a personal computer.

## Shared Config

User-editable values are driven by `server/config/setup.conf`.

Start from:

- `server/config/setup.conf.example`

The same values are reused by the VPS scripts and the local client example generator.

Important variables include:

- `XRAY_PORT`
- `PUBLIC_IP`
- `REALITY_SERVER_NAME`
- `REALITY_DEST`
- `REALITY_FINGERPRINT`
- `SUBSCRIPTION_PORT`
- `XRAY_UUID`
- `REALITY_PRIVATE_KEY`
- `REALITY_PUBLIC_KEY`
- `REALITY_SHORT_ID`
- `SUB_TOKEN`
- `CLASH_PROXY_NAME`
- `CLASH_MIXED_PORT`
- `CLASH_GLOBAL_MODE`
- `CLASH_RULE_MODE`

## VPS Migration Behavior

`server/install.sh` is designed for migration from the old Shadowsocks setup on the VPS.

During install it will:

1. install or update `xray`
2. generate REALITY credentials when configured as `AUTO_GENERATE`
3. stop and disable `ss-server@server` if that legacy service exists
4. keep `/etc/shadowsocks-libev/server.json` in place
5. reconfigure firewall rules away from the old Shadowsocks port and onto the new Xray/Caddy ports

## Local Client Setup

The local client side lives under `client/`. These files are not deployed to the VPS.

Typical local usage after the VPS installation is complete:

1. Get the subscription URL printed by `server/install.sh`.
2. Import that URL into Clash Verge or Mihomo.
3. If needed, create a manual node with the same server IP, port, UUID, REALITY public key, short ID, and server name.

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
- local Clash/Mihomo examples are generated from the same shared values for convenience
- private UUIDs, REALITY keys, short IDs, subscription URLs, and local private config should not be committed
- the subscription service uses `8443` because `443` is reserved for the REALITY listener
