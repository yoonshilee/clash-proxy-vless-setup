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
    local actual=""

    actual="$(curl --silent --show-error --connect-timeout 10 --max-time 20 \
        --output "${TEMP_DIR}/response" --write-out '%{http_code}' \
        "${SUBSCRIPTION_TEST_BASE_URL%/}${path}" 2>"${TEMP_DIR}/curl-error")" || {
        echo "Request failed: ${label}" >&2
        exit 1
    }

    if [[ "${actual}" != "${expected}" ]]; then
        echo "Unexpected HTTP status for ${label}: expected ${expected}, got ${actual}." >&2
        exit 1
    fi
}

assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}.yaml" 200 'full subscription'
grep -Eq '^proxies:' "${TEMP_DIR}/response"
grep -Eq '^rules:' "${TEMP_DIR}/response"
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}-provider.yaml" 200 'node provider'
grep -Eq '^proxies:' "${TEMP_DIR}/response"
! grep -Eq '^rules:' "${TEMP_DIR}/response"

assert_http_status / 404 'homepage'
assert_http_status /index.html 404 'legacy HTML index'
assert_http_status /index.txt 404 'text index'
assert_http_status "/wrong-${SUBSCRIPTION_TEST_TOKEN}.yaml" 404 'unknown subscription'
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}.yaml.bak" 404 'subscription backup'
assert_http_status "/${SUBSCRIPTION_TEST_TOKEN}-provider.yaml.bak" 404 'provider backup'

echo 'Validated subscription access: tokenized YAML only; public discovery paths return 404.'
