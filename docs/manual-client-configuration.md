# Manual Client Configuration

User-editable values are centralized in [config/setup.conf.example](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/config/setup.conf.example). Copy it to `config/setup.conf` and edit that file instead of changing `install.sh` or the generated files under `docs/active-config/`.

These files read from the same config source:

- [install.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/install.sh)
- [uninstall.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/uninstall.sh)
- [scripts/render-client-configs.sh](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/scripts/render-client-configs.sh)

Do not commit real passwords, tokens, subscription URLs, API keys, or host-specific snapshots to a shared repository.

## Main Variables

| Variable | Meaning |
|------|------------|
| `SS_PORT` | Shadowsocks server port |
| `SS_METHOD` | Encryption method |
| `PUBLIC_IP` | Public server IP used by Caddy and generated client examples |
| `SS_PASSWORD` | Server password, or `AUTO_GENERATE` |
| `SUB_TOKEN` | Subscription token, or `AUTO_GENERATE` |
| `CLASH_PROXY_NAME` | Proxy name used in generated Clash examples |
| `CLASH_MIXED_PORT` | Local Clash mixed port used by `opencode-proxy.cmd` |
| `CLASH_GLOBAL_MODE` | Mode used in `docs/active-config/clash-verge.yaml` |
| `CLASH_RULE_MODE` | Mode used in `docs/active-config/clash-verge-check.yaml` |

## Clash Verge Import

After installation, use one of these approaches:

1. Import the generated subscription URL directly.
2. Create a manual node with the same server IP, port, method, and password.

If you change any client-related variables later, regenerate the example files:

```bash
bash scripts/render-client-configs.sh
```

## Optional Local Routing Rules

The generated Clash examples still need user review for:

- domains that must always go through the proxy
- domains that must always go direct
- any IP-based direct rules for your own server

## Optional OpenCode Proxy Wrapper

If your local tools do not respect the Windows system proxy, `docs/active-config/opencode-proxy.cmd` is generated from `CLASH_MIXED_PORT`.

## Share-Safe Checklist

Remove or replace these before committing:

- public server IP addresses
- Shadowsocks passwords
- subscription tokens and URLs
- local machine paths
- personal provider configuration
- permissive local tool settings that are only meant for your own machine
