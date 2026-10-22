# 数据来源

## IPv4 网段

`Sources/RouteWeaver/Resources/cn-ipv4.txt` 来自 [APNIC 官方分配统计](https://ftp.apnic.net/stats/apnic/delegated-apnic-latest) 的 CN IPv4 记录，获取日期见文件头。地址分配地区不等同于实际使用地点，也不能保证覆盖所有中国服务。可在应用中更新，应用规则后才影响路由。

内置的 5,499 条 CIDR 可由 [2026-10-21 UTC 官方归档](https://ftp.apnic.net/stats/apnic/2026/delegated-apnic-20261021.gz)逐字节重建。文件头的 `Retrieved: 2026-10-20` 是获取日期，不是归档标识；重建时应使用下表固定输入。

| 固定对象 | SHA-256 |
| --- | --- |
| `delegated-apnic-20261021.gz` | `d9832f96d3ba99c3b3468bd4713e08d274afd3c7f51c0ad52ffddcfa2d9cafa6` |
| 解压后的 APNIC 原始文本 | `9905a8dad583cbee6e8685761822b1e7b3fcd9099b204d6962fc41fea0522ea3` |
| CIDR 正文（每行 LF，含末尾 LF） | `12c0385f1790283fc93122a3383281a9e35e6ad06300df5434e6326709a6649f` |
| 内置文件（包括原有三行文件头） | `a9459dce5ce38670c434b0d4e611f4f9fe74b59e141d300eaece1544fcd30179` |

重建脚本只接收固定原始输入：筛选 `apnic|CN|ipv4` 且状态为 `allocated` / `assigned` 的记录，将起始地址和数量展开为区间、合并区间，再输出按地址排序的最小 CIDR 集合。该算法对应 `Sources/RouteCore/APNICParser.swift` 的有效记录处理；脚本另外校验整个输入、条数和最终输出哈希，不是接受任意 APNIC 文件的更新器。

```sh
mkdir -p work/data-inputs
curl -fL https://ftp.apnic.net/stats/apnic/2026/delegated-apnic-20261021.gz \
  -o work/data-inputs/delegated-apnic-20261021.gz
python3 script/build_cn_ipv4.py \
  --source work/data-inputs/delegated-apnic-20261021.gz \
  --output work/data-inputs/rebuilt-cn-ipv4.txt
cmp Sources/RouteWeaver/Resources/cn-ipv4.txt work/data-inputs/rebuilt-cn-ipv4.txt
```

脚本不会下载、更新应用数据或修改路由，输出路径须尚不存在。应用内更新仍使用 `delegated-apnic-latest`，因此用户缓存可能不同于这个固定内置版本。

## 国内域名

来源为 [domain-list-community](https://github.com/v2fly/domain-list-community/tree/e8f6d1e5c4a01cda943c0784ffa834340eeab5ae)，固定提交 `e8f6d1e5c4a01cda943c0784ffa834340eeab5ae`。从 `geolocation-cn` 展开，保留 domain 后缀，排除公共后缀、部分国际厂商及共享云命名空间，再折叠冗余子域，得到 7,726 条；不代表覆盖全部国内网站。

[data/domestic-domains](../data/domestic-domains/) 保存清单、相对来源、筛选记录和元数据；运行时内容位于 `Sources/RouteDNS/DomesticDomains.swift`。匹配域名本身及带点分隔的子域，不把精确匹配或正则扩大为后缀。父域可能包含海外子服务，最终仍需检查解析结果是否在直连计划内。

名单 SHA-256：`a714c11aa381eff872ef7dc93af5f69deb8e429ab94da42a5e50adf3029fc321`。

离线重建需要固定上游源码及 Public Suffix List 文件（Python 3.9+）。固定 PSL 是官网导出版本 `2026-10-20_08-40-56_UTC`，对应 [publicsuffix/list 提交 `5dd321ffe02039e2431382a095cf80e27ff5eb94`](https://github.com/publicsuffix/list/tree/5dd321ffe02039e2431382a095cf80e27ff5eb94)。官网导出额外包含 VERSION/COMMIT 两行，直接使用 Git 原文件会触发哈希不匹配。

| PSL 输入 | SHA-256 |
| --- | --- |
| 固定提交的 `public_suffix_list.dat` | `9b4827a9e428a0192a9ea0a6b7804a4cc653d5f39a03456d3b17447b86d78de9` |
| 官网导出 / 重建后的文件 | `8228e4bdac6024c058a1e67859157e468a2613b826b53de0e5cae298e1b70755` |

`prepare_public_suffix_list.py` 仅恢复这两行版本注释，保留原规则与 MPL notice，并验证重建结果恰好匹配官网导出哈希。即使官网 latest 更新，仍可从固定提交还原输入：

```sh
mkdir -p work/data-inputs
curl -fL https://codeload.github.com/v2fly/domain-list-community/tar.gz/e8f6d1e5c4a01cda943c0784ffa834340eeab5ae \
  -o work/data-inputs/domain-list-community.tar.gz
tar -xzf work/data-inputs/domain-list-community.tar.gz -C work/data-inputs
curl -fL https://raw.githubusercontent.com/publicsuffix/list/5dd321ffe02039e2431382a095cf80e27ff5eb94/public_suffix_list.dat \
  -o work/data-inputs/public_suffix_list.git.dat
python3 script/prepare_public_suffix_list.py \
  --source work/data-inputs/public_suffix_list.git.dat \
  --output work/data-inputs/public_suffix_list.dat
python3 script/build_domestic_domains.py \
  --source work/data-inputs/domain-list-community-e8f6d1e5c4a01cda943c0784ffa834340eeab5ae \
  --psl work/data-inputs/public_suffix_list.dat \
  --output work/data-inputs/rebuilt-domains.txt
cmp data/domestic-domains/domains.txt work/data-inputs/rebuilt-domains.txt
```

上述 curl 命令负责下载；Python 脚本均离线运行。域名生成器校验整个上游 data 目录、MIT 许可文本、PSL 和输出哈希；使用 Git checkout 时还检查 HEAD。PSL 准备脚本的输出路径须尚不存在。更新数据需调整固定版本并检查生成结果。许可见 [第三方说明](../THIRD_PARTY_NOTICES.md)。
