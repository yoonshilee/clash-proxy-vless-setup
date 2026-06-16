# AGENTS.md

## Purpose

This file tells an agent how to work with this repository and, most importantly, which machine each action belongs to.

## Two Endpoints

There are two different environments in this project. Do not mix them.

### 1. VPS Side

This is the remote Linux server that hosts Xray `VLESS + REALITY` and Caddy.

Relevant files:

- `server/install-centos.sh`
- `server/install-ubuntu.sh`
- `server/install.sh`
- `server/scripts/install-common.sh`
- `server/scripts/open-firewall-centos.sh`
- `server/scripts/open-firewall-ubuntu.sh`
- `server/uninstall-centos.sh`
- `server/uninstall-ubuntu.sh`
- `server/uninstall.sh`

Agent rules on the VPS side:

- Run VPS install commands only on the VPS.
- Before installing, identify the VPS distribution first by reading `/etc/os-release`.
- If `ID=ubuntu` or `ID_LIKE` contains `debian`, run `sudo bash server/install-ubuntu.sh`.
- If `ID=centos`, `rhel`, `rocky`, `almalinux`, `fedora`, or `ID_LIKE` contains `rhel` / `fedora`, run `sudo bash server/install-centos.sh`.
- `server/install.sh` is only a convenience dispatcher. Agents should still identify the OS first and choose the matching installer explicitly.
- Run `server/uninstall.sh`, `server/uninstall-centos.sh`, or `server/uninstall-ubuntu.sh` only on the VPS.
- Edit `server/config/setup.conf` when changing server-side values. It is the VPS-side private config file and is not tracked by Git. After a successful install, the final effective values are also written back into it automatically.
- Server-side values include `XRAY_PORT`, `PUBLIC_IP`, `REALITY_SERVER_NAME`, `REALITY_DEST`, `REALITY_FINGERPRINT`, `XRAY_UUID`, `REALITY_PRIVATE_KEY`, `REALITY_PUBLIC_KEY`, `REALITY_SHORT_ID`, `SUB_TOKEN`, and `SUBSCRIPTION_PORT`.
- The installer requires root or sudo.
- The installer configures Xray, Caddy, then runs the distro-appropriate firewall-open script, and applies SELinux changes when applicable.
- The installer stops and disables the legacy Shadowsocks service if it exists, but keeps its config file in place.
- The installer prints the subscription URL at the end. That URL is meant for the personal computer side.
- The generated subscription YAML includes `proxies`, `proxy-groups`, and `rules`, so the personal computer can import the subscription directly in Clash Verge or Mihomo.

Typical VPS workflow:

1. Clone or copy this repository onto the VPS.
2. Check the VPS OS with `cat /etc/os-release`.
3. Copy `server/config/setup.conf.example` to `server/config/setup.conf`.
4. Edit `server/config/setup.conf`.
5. Run the matching installer:
   `sudo bash server/install-centos.sh`
   or
   `sudo bash server/install-ubuntu.sh`
6. Wait for the installer to finish. The final effective values, including generated credentials, are written into `server/config/setup.conf`.
7. Save the printed subscription URL.

### 2. Personal Computer Side

This is the local machine running Clash Verge, Mihomo, or another Clash-compatible client.

Relevant files:

- `client/render-client-configs.sh`
- `client/active-config/clash-verge.yaml`
- `client/active-config/clash-verge-check.yaml`
- `client/active-config/custom-routing-rules.yaml`
- `client/active-config/opencode-proxy.cmd`
- `client/local-config/`
- `client/validate-subscription.sh`

Agent rules on the personal computer side:

- Do not run VPS install commands on the personal computer.
- Do not treat local Clash files as VPS deployment files.
- Local Clash-related changes belong under `client/`.
- Treat `client/active-config/*` as public example templates tracked by Git.
- Treat `client/local-config/*` as VPS- or machine-local generated output that is not tracked by Git.
- If the user asks to modify Clash local configuration, work on `client/active-config/*` or `client/render-client-configs.sh`.
- If the user only needs to use the server, importing the subscription URL into Clash Verge or Mihomo is the default path.
- Use `bash client/validate-subscription.sh` to verify that the generated Clash profile still contains a node, proxy groups, and routing rules.

Typical personal computer workflow:

1. Get the subscription URL produced on the VPS.
2. Import that URL into Clash Verge or Mihomo.
3. Enable the imported profile.
4. If custom local examples are needed on the VPS, edit `server/config/setup.conf` and rerun the installer, or run `bash client/render-client-configs.sh` manually.
5. If needed, validate the generated local profile with `bash client/validate-subscription.sh client/local-config/clash-verge-check.yaml`.
6. Apply or adapt the files under `client/active-config/` only as tracked example templates, and use `client/local-config/` for machine-local generated output.

## Operational Boundary

When deciding what to do, first determine the endpoint:

- If the task is about installing Xray, changing the REALITY port, opening firewall ports, configuring Caddy, rotating REALITY credentials, or publishing the subscription URL on the server, it is a VPS-side task.
- If the task is about Clash Verge profiles, routing rules, local proxy wrappers, importing subscriptions, or validating a generated Clash YAML on the personal computer, it is a personal-computer-side task.

If the endpoint is unclear, the agent should ask which side the user is working on before making changes.

## Safety

- Never commit real UUIDs, REALITY private keys, public keys, short IDs, subscription URLs, or private IPs.
- Treat `server/config/setup.conf` as a private machine-specific config file. Do not expect Git updates to manage or replace it.
- Do not assume a local Clash config should be deployed to the VPS.
- Do not assume a VPS installation script should be run on the personal computer.
- Do not delete the legacy Shadowsocks config unless the user explicitly asks for full removal.



