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
- `PUBLIC_IPV6`
- `REALITY_SERVER_NAME`
- `REALITY_DEST`
- `SUBSCRIPTION_PORT`
- `CLASH_PROXY_NAME`
- `CLASH_DIRECT_EXTRA_DOMAINS`

`CLASH_DIRECT_EXTRA_DOMAINS` changes the server-managed defaults in the published subscription. Personal computer rules belong in `client/user-config/` instead.

Notes:

- `server/config/setup.conf.example` is only a template.
- `server/config/setup.conf` is private, machine-specific, and ignored by Git.
- Generated runtime values are written back to `server/config/setup.conf` after a successful install.
- `PUBLIC_IPV6=AUTO_DETECT` publishes an additional IPv6 REALITY node and IPv6 subscription URLs when the VPS has a globally routable IPv6 address. Set it to an explicit address when automatic detection is unavailable.
- Keep UUIDs, REALITY keys, short IDs, tokens, private IPs, and subscription URLs out of commits and public messages.

Run the installer with root privileges:

```bash
sudo bash server/install-ubuntu.sh
```

or:

```bash
sudo bash server/install-centos.sh
```

When installation finishes, the script prints the private IPv4 subscription and provider URLs. If `PUBLIC_IPV6` is available, it also prints IPv6 equivalents whose sslip.io hostnames resolve through AAAA records.

- Full subscription URL for Clash Verge and other subscription clients.
- Node provider URL ending in `-provider.yaml` for a local Mihomo config.

All URLs reuse `SUB_TOKEN`. Keep them private. The full subscription and provider files contain both IPv4 and IPv6 nodes when IPv6 publishing is enabled, so importing either URL provides both paths.

The subscription service only serves the two exact tokenized YAML paths. The homepage, `/index.html`, unknown tokens, and other files return HTTP 404. Updating with the matching installer removes the credential-bearing homepage created by older versions while preserving existing subscription URLs. Custom tokens may contain only letters, digits, dots, underscores, or hyphens.

Subscription URLs are printed in the installer's terminal output, not on a public webpage. Keep that output out of public CI/CD logs. Closing the homepage does not revoke credentials already downloaded; rotating `SUB_TOKEN` revokes old download links, while rotating `XRAY_UUID` also requires updating installed clients.

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

The VPS installer also writes generated examples to `client/local-config/`. That directory is ignored by Git and is never the source of personal routing rules.

Server-managed rules explicitly route Dianping, Meituan, Amap, and their supporting domains through `DIRECT`. Other domestic services use `GEOSITE,cn,DIRECT` and `GEOIP,CN,DIRECT,no-resolve` before the final proxy fallback. Explicit GitHub and OpenAI proxy rules take precedence over these domestic fallbacks; personal prepended rules still take precedence over server defaults.

## Personal Routing Rules

Personal domain rules are stored separately from the VPS subscription. Subscription updates cannot overwrite them.

Initialize the private local files on Windows:

```bat
.\client\manage-user-rules.cmd init
```

Edit these Git-ignored files:

- `client/user-config/direct-domains.txt`: one domain suffix per line routed through `DIRECT`.
- `client/user-config/proxy-domains.txt`: one domain suffix per line routed through the stable `PROXY` group.
- `client/user-config/provider-url.txt`: the private node provider URL printed by this project's VPS installer for a standalone Mihomo config.

Blank lines and `#` comments are ignored. Domains are normalized to lowercase and rendered as `DOMAIN-SUFFIX`. More specific subdomains are ordered before their parent domains. The same domain cannot appear in both policy files.

Validate the local inputs:

```bat
.\client\manage-user-rules.cmd validate
```

Generated files belong under `client/local-config/`:

- `clash-verge-user-rules.yaml`: persistent subscription enhancement rules.
- `mihomo.yaml`: complete local Mihomo config when `provider-url.txt` is configured.

To apply the Clash Verge rules:

1. Run `.\client\manage-user-rules.cmd copy`.
2. Right-click the current VPS subscription in Clash Verge Rev.
3. Select **Edit Rules**, then **Advanced**.
4. Paste, save, and update the subscription.

The rules use `prepend`, so personal choices win when a server-managed rule conflicts. The text files under `client/user-config/` are the source of truth; update them before copying again.

For standalone Mihomo, paste the provider URL printed by the VPS installer into `provider-url.txt`, run `.\client\manage-user-rules.cmd render`, and load `client/local-config/mihomo.yaml`. Mihomo updates nodes every hour while personal and server-default rule snapshots remain local. `render` fails rather than leaving a stale Mihomo file when the Provider URL is missing or invalid.

The old generated `custom-routing-rules.yaml` is no longer produced. Existing copies are legacy files and are not deleted automatically.

## Validation

Validate a generated local profile with:

```bash
bash client/validate-subscription.sh client/local-config/clash-verge-check.yaml
```

The validation checks for the required Clash profile sections and parses the YAML structure when PyYAML is available.

Run the local rule and rendering tests from the personal computer:

```powershell
& .\client\tests\manage-user-rules.tests.ps1
```

```bash
bash client/tests/render-configs.tests.sh
```

Verify access to a running subscription service using private environment values:

```bash
SUBSCRIPTION_TEST_BASE_URL='https://<subscription-host>:<port>' \
SUBSCRIPTION_TEST_TOKEN='<private-token>' \
bash server/tests/subscription-access.tests.sh
```

This checks that valid subscription and provider URLs return YAML, while public discovery paths and unknown files return HTTP 404. It does not print private URLs or response bodies.

## Updating

After changing repository code or `server/config/setup.conf`, rerun the matching VPS installer:

```bash
sudo bash server/install-ubuntu.sh
```

or:

```bash
sudo bash server/install-centos.sh
```

Tracked files under `client/active-config/` are public examples. Generated machine-local files belong under `client/local-config/`. Personal inputs under `client/user-config/` are not regenerated or tracked by Git.

If `SUB_TOKEN` changes, replace the URL in `client/user-config/provider-url.txt` and rerun `render`. The domain files do not need to change. If a Clash Verge subscription is deleted and re-imported, run `copy` and paste the rules into the new profile once.

## Uninstall

Ubuntu or Debian-like systems:

```bash
sudo bash server/uninstall-ubuntu.sh
```

CentOS, RHEL, Rocky Linux, AlmaLinux, or Fedora-like systems:

```bash
sudo bash server/uninstall-centos.sh
```
