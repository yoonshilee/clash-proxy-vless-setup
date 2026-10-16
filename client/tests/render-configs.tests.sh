#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

TEMPLATES_DIR="${REPO_ROOT}/server/templates"
SCRIPT_NAME="client/tests/render-configs.tests.sh"
OS_ID="test"
OS_VERSION_ID="1"

# shellcheck source=server/scripts/load-config.sh
source "${REPO_ROOT}/server/scripts/load-config.sh"
load_project_config "${REPO_ROOT}"

# shellcheck source=server/scripts/install-common.sh
source "${REPO_ROOT}/server/scripts/install-common.sh"

public_ip="203.0.113.10"
public_ipv6="2001:db8::10"
xray_port="443"
xray_uuid="11111111-1111-4111-8111-111111111111"
reality_server_name="www.cloudflare.com"
reality_fingerprint="chrome"
reality_public_key="test-public-key"
reality_short_id="0123456789abcdef"
subscription_port="8443"
sub_token="test-token"

subscription_file="${TEMP_DIR}/test-token.yaml"
write_subscription_yaml "${subscription_file}"
validate_subscription_yaml "${subscription_file}"
bash "${REPO_ROOT}/client/validate-subscription.sh" "${subscription_file}"

provider_file="${TEMP_DIR}/test-token-provider.yaml"
write_proxy_provider_yaml "${provider_file}"
validate_proxy_provider_yaml "${provider_file}"

grep -Fq "server: '203.0.113.10'" "${subscription_file}"
grep -Fq "server: '2001:db8::10'" "${subscription_file}"
grep -Fq "IP-CIDR6,${public_ipv6}/128,DIRECT,no-resolve" "${subscription_file}"
grep -Eq '^proxies:' "${provider_file}"
grep -Eq 'type: vless' "${provider_file}"
[[ "$(grep -c 'type: vless' "${provider_file}")" -eq 2 ]]
grep -Fq "server: '2001:db8::10'" "${provider_file}"
! grep -Eq '^proxy-groups:' "${provider_file}"
! grep -Eq '^rules:' "${provider_file}"
[[ "$(sslip_domain_for_address "${public_ipv6}")" == "2001-db8--10.sslip.io" ]]

public_ipv6=""
ipv4_only_subscription_file="${TEMP_DIR}/ipv4-only.yaml"
ipv4_only_provider_file="${TEMP_DIR}/ipv4-only-provider.yaml"
write_subscription_yaml "${ipv4_only_subscription_file}"
validate_subscription_yaml "${ipv4_only_subscription_file}"
write_proxy_provider_yaml "${ipv4_only_provider_file}"
validate_proxy_provider_yaml "${ipv4_only_provider_file}"
[[ "$(grep -c 'type: vless' "${ipv4_only_provider_file}")" -eq 1 ]]
! grep -Fq 'IP-CIDR6,' "${ipv4_only_subscription_file}"
public_ipv6="2001:db8::10"

RENDER_PUBLIC_IP="${public_ip}" \
RENDER_PUBLIC_IPV6="${public_ipv6}" \
RENDER_XRAY_PORT="${xray_port}" \
RENDER_XRAY_UUID="${xray_uuid}" \
RENDER_REALITY_PUBLIC_KEY="${reality_public_key}" \
RENDER_REALITY_SHORT_ID="${reality_short_id}" \
RENDER_REALITY_SERVER_NAME="${reality_server_name}" \
RENDER_SUB_TOKEN="${sub_token}" \
RENDER_PROVIDER_URL="https://${public_ip}.sslip.io:${subscription_port}/${sub_token}-provider.yaml" \
RENDER_OUTPUT_DIR="${TEMP_DIR}/rendered" \
bash "${REPO_ROOT}/client/render-client-configs.sh"

bash "${REPO_ROOT}/client/validate-subscription.sh" "${TEMP_DIR}/rendered/clash-verge-check.yaml"
[[ -f "${TEMP_DIR}/rendered/mihomo-provider.yaml" ]]
[[ ! -f "${TEMP_DIR}/rendered/custom-routing-rules.yaml" ]]
grep -Fq '# __USER_RULES__' "${TEMP_DIR}/rendered/mihomo-provider.yaml"
grep -Fq "${sub_token}-provider.yaml" "${TEMP_DIR}/rendered/mihomo-provider.yaml"
grep -Fq 'name: PROXY' "${TEMP_DIR}/rendered/mihomo-provider.yaml"
grep -Fq "server: '${public_ipv6}'" "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq "IP-CIDR6,${public_ipv6}/128,DIRECT,no-resolve" "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq "IP-CIDR6,${public_ipv6}/128,DIRECT,no-resolve" "${TEMP_DIR}/rendered/mihomo-provider.yaml"
grep -Fq 'DOMAIN-SUFFIX,apps.apple.com,DIRECT' "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq 'DOMAIN-SUFFIX,itunes.apple.com,DIRECT' "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq 'DOMAIN-SUFFIX,mail.me.com,DIRECT' "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq 'DOMAIN-SUFFIX,mail.icloud.com.cn,DIRECT' "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq 'DOMAIN-SUFFIX,mzstatic.com,DIRECT' "${TEMP_DIR}/rendered/clash-verge-check.yaml"
grep -Fq 'DOMAIN-SUFFIX,devstreaming-cdn.apple.com,DIRECT' "${TEMP_DIR}/rendered/clash-verge-check.yaml"
! grep -Fq 'push2his.eastmoney.com' "${TEMP_DIR}/rendered/clash-verge-check.yaml"

for profile in "${subscription_file}" \
    "${TEMP_DIR}/rendered/clash-verge.yaml" \
    "${TEMP_DIR}/rendered/clash-verge-check.yaml" \
    "${TEMP_DIR}/rendered/mihomo-provider.yaml"; do
    for domain in dianping.com dpfile.com meituan.com meituan.net sankuai.com \
        amap.com autonavi.com gaode.com oray.com oray.net orayimg.com \
        uuyc.163.com netease.com todesk.com todesk.cn dingtalk.com feishu.cn \
        feishucdn.com wps.cn kdocs.cn qq.com qpic.cn baidupcs.com alipan.com \
        quark.cn xunlei.com jianguoyun.com 115.com jd.com pddpic.com ele.me \
        didichuxing.com ctrip.com qunar.com iqiyi.com youku.com kuaishou.com \
        kugou.com kuwo.cn lkcoffee.com luckincoffeecdn.com yyds.co \
        cotticoffee.com cotti.com cdn-product-prod.yummy.tech heytea.com \
        chagee.com mxbc.com mxbc.net naixuecha.com starbucks.com.cn \
        kfc.com.cn pizzahut.com.cn yumchina.com 4008-517-517.cn mcd.cn \
        mcdchina.net mcdonalds.com.cn npmjs.com npmjs.org captcha-delivery.com \
        mihoyo.com mhystatic.com miyoushe.com yuanshen.com bh3.com bhsr.com \
        juequling.com hoyoverse.com hoyolab.com genshinimpact.com \
        ninebot.com segway-ninebot.com niu.com niucache.com yadea.com.cn \
        aimatech.com tailg.com.cn tailgvip.com luyuan.cn xinri.com \
        byd.com bydauto.com.cn tengshiauto.com yangwangauto.com fangchengbao.com \
        nio.com nio.cn onvo.cn firefly.com.cn xiaopeng.com lixiang.com ampmake.com \
        zeekrlife.com geely.com xiaomiev.com mi-img.com mifile.cn hima.auto \
        leapmotor.com leapmotor.cn huaweicloud.com myhuaweicloud.com hc-cdn.com \
        hc-cdn.cn cloud.tencent.com cloud.tencent.cn qcloud.com tencentcloudapi.com \
        qcloudimg.com portal.volccdn.com res.volccdn.com jdcloud.com img1.jcloudcs.com \
        ctyun.cn ctyunapi.cn ecloud.10086.cn cmecloud.cn cucloud.cn ksyun.com \
        ucloud.cn qingcloud.com qiniu.com qiniuapi.com qiniup.com static-file.qiniu.io \
        aliyun.com aliyuncs.com alibabacloud.com baidubce.com bcebos.com \
        volcengine.com volces.com; do
        grep -Fq "DOMAIN-SUFFIX,${domain},DIRECT" "${profile}"
    done
    for domain in starbucks.com mcdonalds.com yummy.tech cloudflare.com datadome.co \
        akamaized.net myqcloud.com amazonaws.com qiniudn.com ksyuncs.com; do
        ! grep -Fq "DOMAIN-SUFFIX,${domain},DIRECT" "${profile}"
    done
    [[ "$(grep -F 'DOMAIN-SUFFIX,' "${profile}" | sort | uniq -d | wc -l)" -eq 0 ]]
    awk '
        /DOMAIN-SUFFIX,github.com,PROXY/ { github = NR }
        /DOMAIN-SUFFIX,openai.com,PROXY/ { openai = NR }
        /GEOSITE,cn,DIRECT/ { domestic = NR }
        /DOMAIN-SUFFIX,.*,DIRECT/ { last_direct = NR }
        /GEOIP,CN,DIRECT,no-resolve/ { china_ip = NR }
        /MATCH,PROXY/ { fallback = NR }
        END { exit !(github && openai && github < domestic && openai < domestic &&
            last_direct < domestic && domestic < china_ip && china_ip < fallback) }
    ' "${profile}"
done

echo "Validated subscription, proxy provider, and Mihomo template generation."
