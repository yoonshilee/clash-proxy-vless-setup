# Chinese carrier service-hall routing evidence

Checked: 2026-10-19 (Asia/Shanghai).

## Narrow routing additions

These nine domain suffixes cover verified first-party service-hall, download, and carrier-authentication domains. A suffix rule also covers subdomains; URL paths are evidence, not additional routing rules. This is public-source verification, not a capture of requests from the user's phone.

| Operator | Domain suffix | First-party evidence |
| --- | --- | --- |
| China Mobile | `10086.cn` | The official portal privacy policy describes business inquiries and processing, login, and scanning a code with the China Mobile app. [Portal policy](https://www.10086.cn/web_notice/privacy/) |
| China Mobile | `chinamobile.com` | The same official policy identifies `cmccapp@cmos.chinamobile.com` as its personal-information contact. This establishes a first-party domain association, not a claim that every app API uses this root. [Portal policy](https://www.10086.cn/web_notice/privacy/) |
| China Mobile | `cmpassport.com` | The policy hosted at `wap.cmpassport.com` identifies China Mobile Internet as the provider and describes one-click login and local-number verification. [Authentication privacy policy](https://wap.cmpassport.com/resources/html/contract2.html) |
| China Unicom | `10010.com` | The app's policy is hosted at `img.client.10010.com`; it covers login, bill payment, allowance queries, and service processing. [App privacy policy](https://img.client.10010.com/stprototype/stAPPxy/indexUser.html) |
| China Unicom | `10010.cn` | The first-party `u.10010.cn` short-link landing page directs users to the Unicom app download and online service hall when a link has expired. It is not evidence that the app's main API uses this root. [Short-link landing page](https://u.10010.cn/) |
| China Unicom | `wosms.cn` | The policy at `msv6.wosms.cn` identifies Unicom Online Information Technology as the provider of one-click login and number authentication. [Authentication privacy policy](https://msv6.wosms.cn/html/oauth/privacy-policy.html) |
| China Telecom | `189.cn` | The official Guangdong service-hall policy names `www.189.cn` and the operating company; the account policy at `id.189.cn` describes passwordless, SMS, QR-code, and password login. [Service-hall policy](https://m.gd.189.cn/TS/myhome/handle/futong.html?in_cmpid=cpb), [account policy](https://id.189.cn/html/agreement_539.html) |
| China Telecom | `id6.me` | The published Tianyi account API document specifies `http://id6.me/openapi/networkauth/preGetMobile.do` for client preauthorization. This documents a supported hostname in that publication, not current use by every app version. [Official API PDF](https://id.189.cn/source/files/abilityPDF/preGetMobile.pdf) |
| China Broadnet | `10099.com.cn` | The first-party mobile service-hall page lists the China Broadnet app and service-hall mini-program as service channels and names `www.10099.com.cn` as the online service hall. [Official service page](https://m.10099.com.cn/h5wap/busiClient/account/youngCard/firstPage.html?chanId=VCH020000489&mainGoodsId=2d16dc69ecef4765995c95b49fe0b932) |

## Verification boundary

- No phone traffic was captured; these domains do not establish the complete request set of any installed app or prove that a loading problem is resolved.
- Carrier number verification can depend on cellular-network access and permission. China Mobile's policy explicitly describes switching from Wi-Fi to cellular data; `DIRECT` means bypassing the configured proxy, not guaranteeing the required SIM, network, permission, or account state. [China Mobile policy](https://wap.cmpassport.com/resources/html/contract2.html)
- No API request containing a phone number, authentication credential, account query, recharge, or service-order action was submitted during this research.
- Broad shared-CDN, cloud-hosting, payment, and unrelated corporate domains are not inferred from these findings. `10099.com`, `cbn.cn`, and `21cn.com` are not included merely because their names resemble a carrier brand or are associated with a wider group.
- The official China Telecom anti-spam app policy links `e.dlife.cn` for its authentication SDK policy. This is a candidate for future observed traffic, not grounds to bypass the entire `dlife.cn` parent or to claim it is required by the service-hall app. [First-party policy link](https://donotcall.189.cn/dnc_h5_all/agreements/pages/an_secrecy_agreement.html)
- On a phone, refresh and enable the complete rule-bearing configuration. Updating a node-only subscription does not establish that these routing rules are active.
