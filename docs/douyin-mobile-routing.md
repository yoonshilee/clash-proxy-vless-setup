# Douyin mobile routing evidence

Checked: 2026-10-19 (Asia/Shanghai).

## What the sources establish

- Douyin's official documentation names `aweme.snssdk.com/oauth/authorize/v2/` for silent authorization inside an in-app H5 page. This confirms an in-app use of the hostname, not the native recommendation feed. [Official documentation](https://open.douyin.com/platform/resource/docs/openapi/account-permission/douyin-default-get-permission-code/)
- The third-party `ucmao/media-parser` implementation configures `api5-normal-c-hl.amemv.com/aweme/v1/feed/` and `aweme.snssdk.com/aweme/v1/feed/`, and its request method actually uses these endpoints. This is public implementation evidence, not an official supported feed API or a capture from the user's phone. [Endpoint constants](https://github.com/ucmao/media-parser/blob/main/src/parsers/douyin_parser.py#L47-L56), [request method](https://github.com/ucmao/media-parser/blob/main/src/parsers/douyin_parser.py#L372-L408)
- That implementation reads returned media URL lists. A feed endpoint is therefore not one fixed universal video-file URL; actual media hosts must be considered separately. [Media URL extraction](https://github.com/ucmao/media-parser/blob/main/src/parsers/douyin_parser.py#L829-L846)
- Both original rule publishers associate `douyinvod.com` and `idouyinvod.com` with Douyin; these media-domain suffixes are already direct in this repository. [v2fly list](https://github.com/v2fly/domain-list-community/blob/master/data/douyin), [blackmatrix7 list](https://github.com/blackmatrix7/ios_rule_script/blob/master/rule/Clash/DouYin/DouYin.list), [shared routing source](../server/scripts/clash-rules.sh)

## Narrow additions

The original blackmatrix7 DouYin list, whose header reports an update on 2025-06-06, contains 13 entries. Comparing its entries with the previous repository rules found three missing associations. The publisher lists the first two as exact hosts, so only those hostnames are added to the existing suffix-based generator, not their entire shared CDN parent domains. [Publisher list](https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/DouYin/DouYin.list)

| Entry | Routing scope |
| --- | --- |
| `lf3-static.bytednsdoc.com` | This hostname and its subdomains only; not all `bytednsdoc.com` |
| `v5-dy-o-abtest.zjcdn.com` | This hostname and its subdomains only; not all `zjcdn.com` |
| `ixiguavideo.com` | Domain suffix associated with Douyin by the publisher |

The representative feed hostnames already match `amemv.com` or `snssdk.com` direct rules. Duplicating every `api*` hostname or adding URL paths is unnecessary for the existing domain-suffix routing model. [Shared routing source](../server/scripts/clash-rules.sh)

## Verification boundary

These sources identify useful routing coverage, not the user's current iOS or Android request set. No phone traffic was captured, and the additions do not establish the cause of intermittent loading delays. Refresh the full subscription on the phone and inspect its actual connection rules if delays persist. Avoid importing entire shared-CDN parents or unrelated TikTok domains solely from these associations.
