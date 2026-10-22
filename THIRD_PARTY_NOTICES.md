# 第三方来源与致谢

本项目的 MIT 许可适用于原创代码；下列数据与外部项目保留原有许可和权利。

## Apple 路由统计 ABI 组件与源码

`Sources/CRouteStatistics/NetworkStatisticsABI.h` 是根据 Apple XNU 的 `bsd/net/ntstat.h` 提取并调整的 ABI 声明与常量，采用 [Apple Public Source License 2.0](LICENSES/APSL-2.0.txt)，不在本项目 MIT 许可范围内。上游固定提交为 [`f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/ntstat.h)，Copyright (c) 2010–2024 Apple Inc. All rights reserved. 本地修改日期为 2026-10-21，包含类型重命名、请求布局组合、固定宽度类型及 ABI 大小/偏移校验；没有包含 XNU 函数实现。

App 内的 `Contents/Resources/Licenses/Source/NetworkStatisticsABI.h` 提供该组件的完整修改源码，`Contents/Resources/Licenses/LICENSES/APSL-2.0.txt` 提供 APSL 全文。同目录还附 C 实现、公开头文件、组件构建说明，以及 App 的包清单和构建脚本，可独立编译该 C 组件。源码接收者可按 APSL 2.0 使用该 ABI 组件；其余原创代码继续采用 MIT，作为 APSL 第 4 节所述的组合产品。对应版本源码也可通过发布标签获取。

## 分流实现参考

特别感谢 [leolovenet/tailscale-routes](https://github.com/leolovenet/tailscale-routes)：它是本项目最初的分流思路与 PF_ROUTE 批量路由方案参考，包括通过更具体的 IPv4 前缀绕过 exit node、使用物理网关直连以及网络变化后的路由恢复。

本项目在阅读上游后重写为 Swift App 与 C 路由库。参考版本 `1993cc44571d709d74e8d44a2270eafd3ceec387` 未声明许可证，也未取得上游额外授权；上游源码不因本项目采用 MIT 而获得再分发许可。具体来源见 [代码来源](docs/PROVENANCE.md)。

## 使用的数据

| 来源 | 使用方式 | 许可 / 条件 |
| --- | --- | --- |
| [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) | 固定提交 `e8f6d1e5c4a01cda943c0784ffa834340eeab5ae` 的国内域名，经筛选后嵌入 DNS 模块 | [MIT 全文](LICENSES/domain-list-community.txt)，Copyright (c) 2018–2019 V2Ray |
| [APNIC 分配统计](https://ftp.apnic.net/stats/apnic/delegated-apnic-latest) | 生成内置 CN IPv4 网段 | [APNIC 使用条件](https://ftp.apnic.net/stats/apnic/README.TXT)：允许下载使用，APNIC 不保证准确性、不承担使用损失；不由本项目 MIT 重新许可 |
| [Public Suffix List](https://publicsuffix.org/list/) | 离线生成名单时排除公共后缀的外部输入；仓库不包含原始 PSL | [MPL 2.0](https://github.com/publicsuffix/list/blob/main/LICENSE) |

版本、筛选方式与重建命令见 [数据来源](docs/DATA.md)。App / ZIP 打包时会附带本项目许可证及第三方说明。

## 设计与技术参考

以下项目提供了设计或技术参考，未作为包依赖：

- [Stats](https://github.com/exelban/stats)：菜单栏双行速率、数值对齐和弹窗分组。
- [Ice](https://github.com/jordanbaird/Ice)：原生侧栏和设置组织。
- [CodeEdit](https://github.com/CodeEditApp/CodeEdit)：列表编辑、工具栏和键盘交互。
- [Xcodes](https://github.com/XcodesOrg/XcodesApp)：操作状态与恢复动作。
- [Pearcleaner](https://github.com/alienator88/Pearcleaner)：后台组件设置的信息组织。
- [Apple XNU](https://github.com/apple-oss-distributions/xnu) 与 [configd](https://github.com/apple-oss-distributions/configd)：路由计数 ABI 与系统 DNS 行为；ABI 改编组件按上节 APSL 2.0 处理，configd 用于行为研究。具体版本与映射见 [代码来源](docs/PROVENANCE.md)。
- [gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip)：曾用于比较数据覆盖，未采用为运行数据，也未随公开源码分发其名单。

RouteWeaver 不是上述项目的官方产品，也不代表其认可或背书。
