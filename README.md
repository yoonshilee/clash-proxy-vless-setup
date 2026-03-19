# clash-proxy-shadowsocks-setup

This repository is split into two clearly separated parts:

- `server/`: VPS-side installation and removal scripts
- `client/`: local Clash client examples and helper files

## Server Setup

Use the files under [server](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server).

Main files:

- [server/install.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/install.sh)
- [server/uninstall.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/uninstall.sh)
- [server/config/setup.conf.example](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/config/setup.conf.example)
- [server/templates/ss-server@.service](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/templates/ss-server@.service)

Quick start on the VPS:

```bash
git clone <this-repo> clash-proxy-shadowsocks-setup
cd clash-proxy-shadowsocks-setup
cp server/config/setup.conf.example server/config/setup.conf
# edit server/config/setup.conf if needed
sudo bash server/install.sh
```

The server installer:

- installs `shadowsocks-libev`
- installs and configures Caddy
- opens firewall ports
- applies SELinux port labels
- generates an HTTPS subscription URL for Clash clients

## Local Client Setup

Use the files under [client](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client).

Main files:

- [client/README.md](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client/README.md)
- [client/render-client-configs.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client/render-client-configs.sh)
- [client/active-config/clash-verge.yaml](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client/active-config/clash-verge.yaml)
- [client/active-config/clash-verge-check.yaml](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client/active-config/clash-verge-check.yaml)
- [client/active-config/custom-routing-rules.yaml](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client/active-config/custom-routing-rules.yaml)

The local client does not run the VPS install scripts. In most cases you only need the subscription URL printed by `server/install.sh`, then import it into Clash Verge with `Profiles -> Import from URL`.

## Shared Config

User-editable values are centralized in:

- [server/config/setup.conf.example](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/config/setup.conf.example)

Copy it to `server/config/setup.conf`. That private file is ignored by Git.

These scripts read from the same config source:

- [server/install.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/install.sh)
- [server/uninstall.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/uninstall.sh)
- [client/render-client-configs.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/client/render-client-configs.sh)

## Share-Safe Checklist

Do not commit:

- real server IP addresses
- real Shadowsocks passwords
- live subscription URLs
- your private `server/config/setup.conf`
