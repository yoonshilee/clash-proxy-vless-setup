#!/usr/bin/env bash

set -euo pipefail

: "${SUBSCRIPTION_TEST_BASE_URL:?Set the subscription base URL in the environment.}"
: "${SUBSCRIPTION_TEST_TOKEN:?Set the subscription token in the environment.}"

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

assert_http_status() {
    local path="$1"
    local expected="$2"
    local label="$3"
    local user_agent="${4:-SubscriptionAccessTest/1.0}"
    local actual=""

    actual="$(curl --silent --show-error --connect-timeout 10 --max-time 20 --user-agent "${user_agent}" \
        --dump-header "${TEMP_DIR}/headers" --output "${TEMP_DIR}/response" --write-out '%{http_code}' \
        "${SUBSCRIPTION_TEST_BASE_URL%/}${path}" 2>"${TEMP_DIR}/curl-error")" || {
        echo "Request failed: ${label}" >&2
        exit 1
    }

    if [[ "${actual}" != "${expected}" ]]; then
        echo "Unexpected HTTP status for ${label}: expected ${expected}, got ${actual}." >&2
        exit 1
    fi
}

assert_subscription_title() {
    python3 - "${TEMP_DIR}/headers" "${SUBSCRIPTION_TEST_NAME:-}" <<'PY'
from base64 import b64decode
from email.parser import BytesHeaderParser
from pathlib import Path
import sys
from urllib.parse import unquote

response = Path(sys.argv[1]).read_bytes().splitlines()
headers = BytesHeaderParser().parsebytes(b'\n'.join(response[1:]))
prefix, separator, encoded = headers.get('Profile-Title', '').partition(':')
assert prefix == 'base64' and separator, 'Missing Base64 profile title'
title = b64decode(encoded, validate=True).decode()
filename = headers.get('Content-Disposition', '').partition("filename*=UTF-8''")[2]
assert title and unquote(filename) == title, 'Subscription titles disagree'
assert not sys.argv[2] or title == sys.argv[2], 'Unexpected subscription display name'
PY
}

assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}.yaml" 200 'full subscription'
assert_subscription_title
grep -Eq '^proxies:' "${TEMP_DIR}/response"
grep -Eq '^rules:' "${TEMP_DIR}/response"
shadowrocket_agent='Shadowrocket/3488 CFNetwork/3896.300.31 Darwin/27.3.0'
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}.yaml" 200 'same subscription from Shadowrocket' "${shadowrocket_agent}"
assert_subscription_title
grep -Eq '^[A-Za-z0-9+/]+=*$' "${TEMP_DIR}/response"
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}-provider.yaml" 200 'node provider'
grep -Eq '^proxies:' "${TEMP_DIR}/response"
! grep -Eq '^rules:' "${TEMP_DIR}/response"
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}-provider.yaml" 200 'node provider with Shadowrocket user-agent' "${shadowrocket_agent}"
grep -Eq '^proxies:' "${TEMP_DIR}/response"

assert_http_status / 404 'homepage'
assert_http_status /index.html 404 'legacy HTML index'
assert_http_status /index.txt 404 'text index'
assert_http_status "/wrong-${SUBSCRIPTION_TEST_TOKEN}.yaml" 404 'unknown subscription'
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}.yaml.bak" 404 'subscription backup'
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}-provider.yaml.bak" 404 'provider backup'
assert_http_status "/wrong-${SUBSCRIPTION_TEST_TOKEN}.yaml" 404 'unknown subscription from Shadowrocket' "${shadowrocket_agent}"
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}-shadowrocket.txt" 404 'internal Shadowrocket file' "${shadowrocket_agent}"

echo 'Validated subscription access: exact tokenized paths only; public discovery paths return 404.'
