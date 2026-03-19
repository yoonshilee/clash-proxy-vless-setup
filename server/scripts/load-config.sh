#!/usr/bin/env bash

load_project_config() {
    local repo_root="$1"
    local example_config="${repo_root}/server/config/setup.conf.example"
    local user_config="${repo_root}/server/config/setup.conf"

    [[ -f "${example_config}" ]] || {
        echo "Missing config template: ${example_config}" >&2
        exit 1
    }

    # shellcheck disable=SC1090
    source "${example_config}"

    if [[ -f "${user_config}" ]]; then
        # shellcheck disable=SC1090
        source "${user_config}"
    fi

    : "${SS_PORT:=8388}"
    : "${SS_METHOD:=chacha20-ietf-poly1305}"
    : "${PUBLIC_IP:=}"
    : "${SS_PASSWORD:=AUTO_GENERATE}"
    : "${SUB_TOKEN:=AUTO_GENERATE}"
    : "${CLASH_PROXY_NAME:=example-ss}"
    : "${CLASH_MIXED_PORT:=7897}"
    : "${CLASH_GLOBAL_MODE:=global}"
    : "${CLASH_RULE_MODE:=rule}"
}

should_autogenerate() {
    [[ -z "${1:-}" || "${1}" == "AUTO_GENERATE" ]]
}

