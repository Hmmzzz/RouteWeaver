# 数据来源

## IPv4 网段

`Sources/RouteWeaver/Resources/cn-ipv4.txt` 来自 [APNIC 官方分配统计](https://ftp.apnic.net/stats/apnic/delegated-apnic-latest) 的 CN IPv4 记录，获取日期见文件头。地址分配地区不等同于实际使用地点，也不能保证覆盖所有中国服务。可在应用中更新，应用规则后才影响路由。

## 国内域名

来源为 [domain-list-community](https://github.com/v2fly/domain-list-community/tree/e8f6d1e5c4a01cda943c0784ffa834340eeab5ae)，固定提交 `e8f6d1e5c4a01cda943c0784ffa834340eeab5ae`。从 `geolocation-cn` 展开，保留 domain 后缀，排除公共后缀、部分国际厂商及共享云命名空间，再折叠冗余子域，得到 7,726 条；不代表覆盖全部国内网站。

[data/domestic-domains](../data/domestic-domains/) 保存清单、相对来源、筛选记录和元数据；运行时内容位于 `Sources/RouteDNS/DomesticDomains.swift`。匹配域名本身及带点分隔的子域，不把精确匹配或正则扩大为后缀。父域可能包含海外子服务，最终仍需检查解析结果是否在直连计划内。

名单 SHA-256：`a714c11aa381eff872ef7dc93af5f69deb8e429ab94da42a5e50adf3029fc321`。

离线重建需要固定上游源码及 Public Suffix List 文件（Python 3.9+）：

```sh
mkdir -p work
python3 script/build_domestic_domains.py \
  --source /path/to/domain-list-community \
  --psl /path/to/public_suffix_list.dat \
  --output work/rebuilt-domains.txt
```

脚本校验输入和输出哈希，不自动下载或更新。更新数据需显式调整固定版本并检查生成结果。许可见 [第三方说明](../THIRD_PARTY_NOTICES.md)。
