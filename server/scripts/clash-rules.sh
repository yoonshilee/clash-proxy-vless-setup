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

CLASH_APPLE_DIRECT_SUFFIXES=(
    "apps.apple.com"
    "appstore.com"
    "itunes.apple.com"
    "mail.me.com"
    "mail.icloud.com.cn"
    "mzstatic.com"
    "cdn-apple.com"
    "swcdn.apple.com"
    "appldnld.apple.com"
    "devstreaming-cdn.apple.com"
)

CLASH_GITHUB_PROXY_SUFFIXES=(
    "github.com"
    "githubusercontent.com"
    "githubassets.com"
    "githubcopilot.com"
    "github.dev"
    "github.io"
    "githubapp.com"
    "githubstatus.com"
    "codeload.github.com"
    "objects.githubusercontent.com"
    "raw.githubusercontent.com"
    "api.github.com"
    "alive.github.com"
    "collector.github.com"
    "api.individual.githubcopilot.com"
    "proxy.individual.githubcopilot.com"
    "telemetry.individual.githubcopilot.com"
)

CLASH_CHINA_APP_DIRECT_SUFFIXES=(
    # Remote access: official Oray, NetEase UU Remote, and ToDesk domains.
    # https://service.oray.com/question/831.html
    # https://uuyc.163.com/ and https://www.todesk.com/news/749.html
    "oray.com"
    "oray.net"
    "orayimg.com"
    "uuyc.163.com"
    "todesk.com"
    "todesk.cn"
    # Common app/CDN suffixes also checked against v2fly/domain-list-community.
    # NetEase accounts, downloads, music, mail, and customer support.
    "163.com"
    "126.com"
    "126.net"
    "127.net"
    "netease.com"
    "netease.im"
    "qiyukf.com"
    # Domestic office and messaging services, including their resource CDNs.
    "dingtalk.com"
    "dingtalk.cn"
    "dingtalk.net"
    "dingtalkapps.com"
    "dingtalkcloud.com"
    "laiwang.com"
    "feishu.cn"
    "feishu.net"
    "feishuapp.com"
    "feishuapp.cn"
    "feishuapp-cdn.net"
    "feishucdn.com"
    "feishuimg.com"
    "feishudoc.com"
    "feishudoc.cn"
    "feishumeetings.com"
    "feishuvc.com"
    "feishupkg.com"
    "wps.cn"
    "wps.com"
    "wpscdn.cn"
    "wpscdn.com"
    "kdocs.cn"
    "qq.com"
    "qqmail.com"
    "qpic.cn"
    "gtimg.cn"
    "gtimg.com"
    "weiyun.com"
    # Domestic search, maps, cloud storage, and downloads.
    "baidu.com"
    "baidupcs.com"
    "baidubce.com"
    "baidustatic.com"
    "bdstatic.com"
    "bdimg.com"
    "bcebos.com"
    "alipan.com"
    "aliyundrive.com"
    "aliyundrive.net"
    "aliyundrive.cloud"
    "alicloudccp.com"
    "quark.cn"
    "myquark.cn"
    "xunlei.com"
    "sandai.net"
    "thundercdn.com"
    "xycdn.com"
    "jianguoyun.com"
    "jianguoyun.net.cn"
    "115.com"
    "115cdn.com"
    "115cdn.net"
    # Domestic shopping, delivery, and travel services.
    "jd.com"
    "jd.cn"
    "jdcdn.com"
    "360buy.com"
    "360buyimg.com"
    "pinduoduo.com"
    "pinduoduo.net"
    "yangkeduo.com"
    "pddpic.com"
    "pddcdn.com"
    "pddim.com"
    "ele.me"
    "eleme.cn"
    "eleme.io"
    "elemecdn.com"
    "elenet.me"
    "didichuxing.com"
    "didistatic.com"
    "diditaxi.com.cn"
    "udache.com"
    "xiaojukeji.com"
    "ctrip.com"
    "ctrip.cn"
    "ctripgslb.com"
    "tripcdn.cn"
    "qunar.com"
    "qunarcdn.com"
    "qunarzz.com"
    # Domestic video and music services; international variants are not added.
    "iqiyi.com"
    "iqiyipic.com"
    "qiyi.com"
    "qiyipic.com"
    "qy.net"
    "youku.com"
    "ykimg.com"
    "tudou.com"
    "kuaishou.com"
    "gifshow.com"
    "kwimgs.com"
    "yximgs.com"
    "kugou.com"
    "kugouaudio.com"
    "kgimg.com"
    "kuwo.cn"
    "koowo.com"
    "51ping.com"
    "baobaoaichi.cn"
    "dianping.com"
    "dpfile.com"
    "maoyan.com"
    "meituan.com"
    "meituan.net"
    "mtyun.com"
    "neixin.cn"
    "sankuai.com"
    "a-map.cn"
    "a-map.co"
    "a-map.link"
    "a-map.vip"
    "acloudrender.com"
    "amap.com"
    "amap.net"
    "amapauto.com"
    "anav.com"
    "autonavi.com"
    "gaode.com"
    "taobao.com"
    "tb.cn"
    "tmall.com"
    "tmall.hk"
    "alicdn.com"
    "alimama.com"
    "alipay.com"
    "alipayobjects.com"
    "mmstat.com"
    "cainiao.com"
    "cainiao.com.cn"
    "1688.com"
    "etao.com"
    "alibaba.com"
    "alibabacloud.com"
    "aliyun.com"
    "aliyuncs.com"
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
    local public_ipv6="${4:-}"
    local extra_domains="${CLASH_DIRECT_EXTRA_DOMAINS:-}"
    local domain=""
    local seen_domains=$'\n'

    if [[ -n "${public_ip}" ]]; then
        printf '%sIP-CIDR,%s/32,DIRECT,no-resolve\n' "${prefix}" "${public_ip}"
    fi

    if [[ -n "${public_ipv6}" ]]; then
        printf '%sIP-CIDR6,%s/128,DIRECT,no-resolve\n' "${prefix}" "${public_ipv6}"
    fi

    for domain in "${CLASH_GITHUB_PROXY_SUFFIXES[@]}"; do
        [[ -n "${domain}" ]] || continue
        printf '%sDOMAIN-SUFFIX,%s,PROXY\n' "${prefix}" "${domain}"
    done

    printf '%sGEOSITE,microsoft,DIRECT\n' "${prefix}"

    for domain in "${CLASH_MICROSOFT_DIRECT_SUFFIXES[@]}"; do
        [[ -n "${domain}" ]] || continue
        [[ "${seen_domains}" == *$'\n'"${domain}"$'\n'* ]] && continue
        seen_domains+="${domain}"$'\n'
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done

    for domain in "${CLASH_APPLE_DIRECT_SUFFIXES[@]}"; do
        [[ -n "${domain}" ]] || continue
        [[ "${seen_domains}" == *$'\n'"${domain}"$'\n'* ]] && continue
        seen_domains+="${domain}"$'\n'
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done

    for domain in "${CLASH_CHINA_APP_DIRECT_SUFFIXES[@]}"; do
        [[ -n "${domain}" ]] || continue
        [[ "${seen_domains}" == *$'\n'"${domain}"$'\n'* ]] && continue
        seen_domains+="${domain}"$'\n'
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done

    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        [[ "${seen_domains}" == *$'\n'"${domain}"$'\n'* ]] && continue
        seen_domains+="${domain}"$'\n'
        printf '%sDOMAIN-SUFFIX,%s,DIRECT\n' "${prefix}" "${domain}"
    done < <(normalize_domain_list "${extra_domains}")

    printf '%sGEOSITE,openai,PROXY\n' "${prefix}"

    for domain in "${CLASH_OPENAI_PROXY_SUFFIXES[@]}"; do
        printf '%sDOMAIN-SUFFIX,%s,PROXY\n' "${prefix}" "${domain}"
    done

    # Keep explicit proxy rules ahead of the domestic domain and IP fallbacks.
    printf '%sGEOSITE,cn,DIRECT\n' "${prefix}"
    printf '%sGEOIP,CN,DIRECT,no-resolve\n' "${prefix}"

    if [[ "${include_match}" == "yes" ]]; then
        printf '%sMATCH,PROXY\n' "${prefix}"
    fi
}
