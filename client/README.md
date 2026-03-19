# Local Client Setup

This directory contains local Clash client examples. These files are not deployed to the VPS.

User-editable values are centralized in [setup.conf.example](/d:/Projects/Personal%20Project/clash-proxy-shadowsocks-setup/server/config/setup.conf.example). Copy it to `server/config/setup.conf` and edit that file instead of changing server scripts or generated files directly.

## Main Variables

| Variable | Meaning |
|------|------------|
| `SS_PORT` | Shadowsocks server port |
| `SS_METHOD` | Encryption method |
| `PUBLIC_IP` | Public VPS IP used by generated client examples |
| `SS_PASSWORD` | Server password, or `AUTO_GENERATE` |
| `SUB_TOKEN` | Subscription token, or `AUTO_GENERATE` |
| `CLASH_PROXY_NAME` | Proxy name used in generated Clash examples |
| `CLASH_MIXED_PORT` | Local Clash mixed port used by `opencode-proxy.cmd` |
| `CLASH_GLOBAL_MODE` | Mode used in `client/active-config/clash-verge.yaml` |
| `CLASH_RULE_MODE` | Mode used in `client/active-config/clash-verge-check.yaml` |

## Typical Local Setup

After the VPS finishes installation, do one of the following on your local machine:

1. Import the generated subscription URL into Clash Verge.
2. Create a manual node with the same server IP, port, method, and password.

## Regenerating Client Examples

If you change any client-related values, regenerate the example files:

```bash
bash client/render-client-configs.sh
```

## Files In This Directory

- `active-config/clash-verge.yaml`: example Clash Verge profile
- `active-config/clash-verge-check.yaml`: example verification profile
- `active-config/custom-routing-rules.yaml`: optional routing rule template
- `active-config/opencode-proxy.cmd`: optional Windows launcher wrapper for local proxy env vars

## Share-Safe Checklist

Remove or replace these before committing:

- public server IP addresses
- Shadowsocks passwords
- subscription tokens and URLs
- local machine paths
- permissive local tool settings that are only meant for your own machine
