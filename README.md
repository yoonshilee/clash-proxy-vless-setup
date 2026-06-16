# Clash VLESS REALITY Setup

Install Xray `VLESS + REALITY` on a VPS and publish a Clash Verge / Mihomo compatible subscription profile.

## Overview

This repository has two separate sides:

- VPS side: installs and configures Xray, Caddy, firewall rules, and the subscription endpoint.
- Personal computer side: imports the generated subscription URL into Clash Verge, Mihomo, or another Clash-compatible client.

Do not run VPS installation scripts on your personal computer.

## VPS Installation

Clone the repository on the VPS:

```bash
git clone <repository-url>
cd clash-proxy-vless-setup
```

Check the VPS operating system first:

```bash
cat /etc/os-release
```

Use the matching installer:

- Ubuntu or Debian-like systems: `server/install-ubuntu.sh`
- CentOS, RHEL, Rocky Linux, AlmaLinux, or Fedora-like systems: `server/install-centos.sh`

Create the private local configuration file:

```bash
cp server/config/setup.conf.example server/config/setup.conf
vi server/config/setup.conf
```

Common settings:

- `XRAY_PORT`
- `PUBLIC_IP`
- `REALITY_SERVER_NAME`
- `REALITY_DEST`
- `SUBSCRIPTION_PORT`
- `CLASH_PROXY_NAME`
- `CLASH_DIRECT_EXTRA_DOMAINS`

Notes:

- `server/config/setup.conf.example` is only a template.
- `server/config/setup.conf` is private, machine-specific, and ignored by Git.
- Generated runtime values are written back to `server/config/setup.conf` after a successful install.
- Keep UUIDs, REALITY keys, short IDs, tokens, private IPs, and subscription URLs out of commits and public messages.

Run the installer with root privileges:

```bash
sudo bash server/install-ubuntu.sh
```

or:

```bash
sudo bash server/install-centos.sh
```

When installation finishes, the script prints a subscription URL. Save that URL for your personal computer.

## Client Usage

On your personal computer:

1. Open Clash Verge, Mihomo, or another Clash-compatible client.
2. Create a new subscription profile.
3. Paste the subscription URL printed by the VPS installer.
4. Update the subscription.
5. Select and enable the imported profile.

The generated subscription profile includes:

- `proxies`
- `proxy-groups`
- `rules`

The VPS installer also writes local generated examples to `client/local-config/`. That directory is ignored by Git.

## Validation

Validate a generated local profile with:

```bash
bash client/validate-subscription.sh client/local-config/clash-verge-check.yaml
```

The validation checks for the required Clash profile sections and parses the YAML structure when PyYAML is available.

## Updating

After changing repository code or `server/config/setup.conf`, rerun the matching VPS installer:

```bash
sudo bash server/install-ubuntu.sh
```

or:

```bash
sudo bash server/install-centos.sh
```

Tracked files under `client/active-config/` are public examples. Generated machine-local files belong under `client/local-config/`.

## Uninstall

Ubuntu or Debian-like systems:

```bash
sudo bash server/uninstall-ubuntu.sh
```

CentOS, RHEL, Rocky Linux, AlmaLinux, or Fedora-like systems:

```bash
sudo bash server/uninstall-centos.sh
```
