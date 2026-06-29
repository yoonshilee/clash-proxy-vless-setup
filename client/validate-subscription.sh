#!/usr/bin/env bash

set -euo pipefail

PROFILE_PATH="${1:-client/local-config/clash-verge-check.yaml}"

[[ -f "${PROFILE_PATH}" ]] || {
    echo "Profile not found: ${PROFILE_PATH}" >&2
    exit 1
}

required_patterns=(
    '^mode: rule$'
    '^mixed-port: '
    '^proxies:'
    '^proxy-groups:'
    '^rules:'
    'type: vless'
    'packet-encoding: xudp'
    'reality-opts:'
    'name: Auto'
    'IP-CIDR,.*?/32,DIRECT,no-resolve'
    'DOMAIN-SUFFIX,github.com,PROXY'
    'DOMAIN-SUFFIX,githubusercontent.com,PROXY'
    'DOMAIN-SUFFIX,githubcopilot.com,PROXY'
    'DOMAIN-SUFFIX,outlook.com,DIRECT'
    'DOMAIN-SUFFIX,office365.com,DIRECT'
    'DOMAIN-SUFFIX,office.net,DIRECT'
    'DOMAIN-SUFFIX,taobao.com,DIRECT'
    'DOMAIN-SUFFIX,tmall.com,DIRECT'
    'DOMAIN-SUFFIX,alicdn.com,DIRECT'
    'DOMAIN-SUFFIX,alipay.com,DIRECT'
    'DOMAIN-SUFFIX,cainiao.com,DIRECT'
    'DOMAIN-SUFFIX,doubao.com,DIRECT'
    'DOMAIN-SUFFIX,byteimg.com,DIRECT'
    'DOMAIN-SUFFIX,weixin.qq.com,DIRECT'
    'DOMAIN-SUFFIX,bilibili.com,DIRECT'
    'DOMAIN-SUFFIX,xiaohongshu.com,DIRECT'
    'DOMAIN-SUFFIX,openai.com,PROXY'
    'DOMAIN-SUFFIX,microsoft.com,DIRECT'
    'MATCH,PROXY'
)

for pattern in "${required_patterns[@]}"; do
    if ! grep -Eq "${pattern}" "${PROFILE_PATH}"; then
        echo "Missing required content: ${pattern}" >&2
        exit 1
    fi
done

python3 - "${PROFILE_PATH}" <<'PY'
import sys

path = sys.argv[1]

try:
    import yaml
except Exception:
    print("PyYAML is not available; skipped structural YAML validation.")
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as handle:
        profile = yaml.safe_load(handle)
except Exception as exc:
    print(f"Invalid YAML: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(profile, dict):
    print("Profile must be a YAML mapping.", file=sys.stderr)
    sys.exit(1)

checks = (
    ("proxies", list),
    ("proxy-groups", list),
    ("rules", list),
)

for key, expected_type in checks:
    value = profile.get(key)
    if not isinstance(value, expected_type) or not value:
        print(f"Profile must contain a non-empty {key} list.", file=sys.stderr)
        sys.exit(1)

proxy = profile["proxies"][0]
if not isinstance(proxy, dict):
    print("The first proxy entry must be a mapping.", file=sys.stderr)
    sys.exit(1)

required_proxy_keys = (
    "name",
    "type",
    "server",
    "port",
    "uuid",
    "network",
    "tls",
    "flow",
    "servername",
    "client-fingerprint",
    "packet-encoding",
    "reality-opts",
)

missing = [key for key in required_proxy_keys if key not in proxy]
if missing:
    print(f"Proxy is missing required keys: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

if proxy.get("type") != "vless":
    print("The first proxy must be type vless.", file=sys.stderr)
    sys.exit(1)

if not isinstance(proxy.get("reality-opts"), dict):
    print("Proxy reality-opts must be a mapping.", file=sys.stderr)
    sys.exit(1)

for key in ("public-key", "short-id"):
    if key not in proxy["reality-opts"]:
        print(f"Proxy reality-opts is missing {key}.", file=sys.stderr)
        sys.exit(1)
PY

echo "Validated profile: ${PROFILE_PATH}"
