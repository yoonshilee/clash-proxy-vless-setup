#!/usr/bin/env bash

set -euo pipefail

CLASH_MICROSOFT_DIRECT_SUFFIXES=(
    "outlook.com"
    "office.com"
    "office365.com"
    "office.net"
    "microsoft.com"
    "live.com"
    "live.net"
    "msftconnecttest.com"
    "msftncsi.com"
    "msauth.net"
    "msftauth.net"
    "msidentity.com"
    "onestore.ms"
    "global.ssl.fastly.net"
    "azure.com"
    "azureedge.net"
)

CLASH_CHINA_APP_DIRECT_SUFFIXES=(
    "doubao.com"
    "bytedance.com"
    "bytecdn.cn"
    "byteimg.com"
    "byteimg.cn"
    "bytimg.com"
    "zijieapi.com"
    "snssdk.com"
    "amemv.com"
    "douyin.com"
    "douyincdn.com"
    "douyinpic.com"
    "douyinstatic.com"
    "toutiao.com"
    "ixigua.com"
    "pstatp.com"
    "volces.com"
    "volcengine.com"
    "weixin.qq.com"
    "wx.qq.com"
    "qlogo.cn"
    "wechat.com"
    "wechatapp.com"
    "servicewechat.com"
    "tenpay.com"
    "bilibili.com"
    "bilibili.tv"
    "biliapi.com"
    "biliapi.net"
    "bilivideo.com"
    "hdslb.com"
    "acgvideo.com"
    "xiaohongshu.com"
    "xiaohongshu.cn"
    "xhscdn.com"
    "xhscdn.net"
    "xhslink.com"
)

CLASH_OPENAI_PROXY_SUFFIXES=(
    "openai.com"
    "chatgpt.com"
    "oaistatic.com"
    "oaiusercontent.com"
)

normalize_domain_list() {
    local raw="${1:-}"

    tr ',[:space:]' '\n' <<<"${raw}" \
        | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | awk 'NF { print tolower($0) }'
}

emit_clash_rule_lines() {
    local prefix="$1"
    local public_ip="$2"
    local include_match="${3:-yes}"
    local extra_domains="${CLASH_DIRECT_EXTRA_DOMAINS:-}"
    local domain=""
    declare -A seen=()

    printf '%sIP-CIDR,%s/32,DIRECT,no-resolve\n' "${prefix}" "${public_ip}"
    printf '%sGEOSITE,microsoft,DIRECT\n' "${prefix}"

    for domain in "${CLASH_MICROSOFT_DIRECT_SUFFIXES[@]}"; do
        [[ -n "${domain}" ]] || continue
        [[ -n "${seen[${domain}]:-}" ]] && continue
        seen["${domain}"]=1
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done

    for domain in "${CLASH_CHINA_APP_DIRECT_SUFFIXES[@]}"; do
        [[ -n "${domain}" ]] || continue
        [[ -n "${seen[${domain}]:-}" ]] && continue
        seen["${domain}"]=1
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done

    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        [[ -n "${seen[${domain}]:-}" ]] && continue
        seen["${domain}"]=1
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done < <(normalize_domain_list "${extra_domains}")

    printf '%sGEOSITE,openai,PROXY\n' "${prefix}"

    for domain in "${CLASH_OPENAI_PROXY_SUFFIXES[@]}"; do
        printf '%sDOMAIN-SUFFIX,%s,PROXY\n' "${prefix}" "${domain}"
    done

    if [[ "${include_match}" == "yes" ]]; then
        printf '%sMATCH,PROXY\n' "${prefix}"
    fi
}
