# Client Setup

This directory contains local Clash Verge / Mihomo examples. These files are for the personal computer side and should not be deployed to the VPS.

## If Subscription Import Fails

Use one of these local files directly:

- `client/active-config/clash-verge.yaml`: full profile with `global` mode
- `client/active-config/clash-verge-check.yaml`: full profile with `rule` mode

In Clash Verge you can usually:

1. create a new local profile
2. paste the contents of one of the YAML files
3. save and select that profile

## Local Rule Files

There are two ways local rules are represented in this project:

- `client/active-config/clash-verge.yaml`
- `client/active-config/clash-verge-check.yaml`

Both files already contain a `rules:` section for direct use.

There is also a separate rule fragment file:

- `client/active-config/custom-routing-rules.yaml`

This file is meant for clients or workflows that support merging custom rules into an existing Clash/Mihomo profile.

Its structure is:

- `prepend`: rules inserted before existing rules
- `append`: rules added after existing rules
- `delete`: rules to remove from an existing base profile

## Rule Intent In This Project

The generated local rules mainly do this:

- keep Microsoft / Outlook / Office related traffic on `DIRECT`
- send OpenAI related traffic to `PROXY`
- send the rest to `PROXY`
- keep the server IP itself on `DIRECT` to avoid proxy loops

## About System Proxy Settings

Clash subscription content can carry proxy nodes, groups, DNS, and `rules:` in the YAML profile.

But Clash Verge app-level local settings usually do not get fully managed by the subscription itself, including things like:

- whether `Set as system proxy` is toggled on
- OS-level bypass lists managed by the client UI
- service mode or TUN mode switches stored as local client preferences

So in practice:

- routing rules inside the profile can be delivered by subscription
- operating system proxy behavior still usually needs to be enabled once on the local machine in Clash Verge
- if an app ignores system proxy, use app-specific env vars or wrappers like `client/active-config/opencode-proxy.cmd`

## Regenerating Local Files

After changing `server/config/setup.conf`, regenerate the local files with:

```bash
bash client/render-client-configs.sh
```
