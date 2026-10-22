# 第三方代码来源

原创代码采用 MIT；第三方代码、数据与素材的许可范围见 [第三方说明](../THIRD_PARTY_NOTICES.md)。

## tailscale-routes

本项目在阅读 [tailscale-routes](https://github.com/leolovenet/tailscale-routes/tree/1993cc44571d709d74e8d44a2270eafd3ceec387) 后重写为 Swift App 与 C 路由库，参考了更具体的 IPv4 前缀、物理网关直连、PF_ROUTE 批量修改与网络变化恢复方案。

参考版本为 `1993cc44571d709d74e8d44a2270eafd3ceec387`，主要文件包括 `route-helper.c`、`tailscale-routes.py`、`install.sh` 和 `uninstall.sh`。该版本未声明许可证，本项目也未取得额外授权；上游源码不因本项目采用 MIT 而获得再分发许可。引入其代码前应先确认授权，保留真实来源与适用声明。

## Apple XNU 路由统计 ABI

`Sources/CRouteStatistics/NetworkStatisticsABI.h` 根据 XNU 的 [`bsd/net/ntstat.h`](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/ntstat.h) 改编，固定上游提交为 `f6217f891ac0bb64f3d375211650a4c1ff8ca1ea`，按 [APSL 2.0](../LICENSES/APSL-2.0.txt) 提供。头文件保留 Apple 版权、许可及修改说明；其余原创实现采用 MIT。

| 本项目声明 | 上游对应接口 |
| --- | --- |
| `StatsHeader` | `nstat_msg_hdr` 的 context/type/length/flags 顺序与宽度 |
| `AddRequest` | `nstat_msg_add_src_header` 与 `nstat_route_add_param` 的组合布局 |
| `QueryRequest` | 查询/描述请求的消息头和 source reference |
| `RouteDescription` | `nstat_route_descriptor` 的三个 ID、地址、接口和 flags 布局 |
| 消息类型及 flags | `NSTAT_MSG_TYPE_*`、`NSTAT_PROVIDER_ROUTE`、aggregate/continuation 常量 |

这些属于系统私有 ABI，macOS 更新可能影响兼容性。App 随包提供修改后的组件源码、构建说明、APSL 全文和第三方说明，具体路径见 [第三方说明](../THIRD_PARTY_NOTICES.md)。

再分发时须保留版权、许可和修改记录，并按 APSL 2.0 提供对应修改源码，至少持续至分发结束或首次外部分发后 12 个月（取更长者）；二进制应显著说明源码获取方式。完整条件及适用专利许可见许可全文。

## Apple configd DNS 行为

DNS 控制器参考了 configd 提交 [`585b7f2fca293f4642d21d15c5daf187f63c4796`](https://github.com/apple-oss-distributions/configd/blob/585b7f2fca293f4642d21d15c5daf187f63c4796/Plugins/IPMonitor/dns-configuration.c) 的 supplemental resolver、search order 与 server port 行为。该上游文件采用 APSL 2.0；本项目没有包含该 C 源文件，而是通过 Swift 和 SystemConfiguration 发布、核验会话 DNS 配置。

## 数据与设计参考

数据来源、固定版本和重建命令见 [数据来源](DATA.md)；其他设计与技术参考见 [第三方说明](../THIRD_PARTY_NOTICES.md)。
