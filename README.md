<div align="center">

<img src="Assets/AppIcon.png" width="112" alt="RouteWeaver 应用图标">

# RouteWeaver

**让国内连接直达，让其余流量继续走 Tailscale。**

原生 macOS IPv4 分流工具 · 连接状态一目了然 · 规则与恢复都在本机完成

<p>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B-24292F?style=flat&amp;logo=apple&amp;logoColor=white" alt="macOS 14 及以上"></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6.0%2B-F05138?style=flat&amp;logo=swift&amp;logoColor=white" alt="Swift 6.0 及以上工具链"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-34A853?style=flat" alt="MIT License"></a>
  <a href="#开始使用"><img src="https://img.shields.io/badge/Version-1.0.2-4185F4?style=flat" alt="版本 1.0.2"></a>
</p>

[界面预览](#界面预览) · [功能](#功能) · [开始使用](#开始使用) · [安全与隐私](docs/SECURITY.md) · [许可与致谢](#许可与致谢)

</div>

---

## 界面预览

连接总览集中呈现分流状态、直连与出口路径，以及 IP 的规则去向。

<p align="center">
  <img src="docs/images/overview.png" width="1040" alt="RouteWeaver 连接总览：分流状态、两路路径和路由查询">
</p>

<details>
<summary><strong>查看设置界面</strong> · 后台服务、运行方式与隐私</summary>

<p align="center">
  <img src="docs/images/settings.png" width="1040" alt="RouteWeaver 设置：后台服务、规则数据与运行方式">
</p>

</details>

<sub>界面使用示例数据展示，不包含真实节点、私人网络或访问记录。</sub>

## 功能

| | |
| :--- | :--- |
| **国内直连**<br>内置 APNIC 中国大陆 IPv4 网段，经本地 Wi-Fi / 以太网网关直连。 | **保留出口**<br>其余 IPv4 流量沿用 Tailscale exit node，无需切换日常连接方式。 |
| **规则可控**<br>支持自定义直连、出口例外，以及规则导入与导出。 | **状态可见**<br>菜单栏与弹窗显示两路实时速率，连接页可查询 IP 的规则去向。 |
| **自动恢复**<br>跟随网络变化恢复分流；关闭窗口后继续在菜单栏运行。 | **退出清理**<br>退出时撤回本应用的 DNS 设置和路由，恢复原网络。 |

国内域名白名单可使用阿里公共 DNS 解析，其余查询交回原有解析路径。具体行为和数据范围见 [安全与隐私](docs/SECURITY.md) 与 [数据来源](docs/DATA.md)。

## 开始使用

**准备环境**

- macOS 14 或更新版本。
- Swift 6.0 或更新版本的工具链；无需第三方 Swift 包。
- 已连接 exit node 的 [Tailscale](https://tailscale.com/)。

**构建并打开**

在项目目录运行：

```sh
./script/build_and_run.sh --build-only
open dist/RouteWeaver.app
```

构建后的 App 与 ZIP 位于 `dist/`。首次启用分流时，授权安装系统后台帮助程序；同一构建后续启动、开关分流和网络恢复均复用该服务，无需重复管理员授权。设置中的安装/修复也会先检查并复用可连接的服务。更新或重新签名 App 后，若签名身份变化，需要明确授权重新关联；应用不会放宽身份校验来跳过这一步。

> **适用范围**：只管理 IPv4 分流，不提供按应用分流；IPv6 仍由系统和 Tailscale 管理。构建采用本地 ad-hoc 签名，未做 Developer ID 公证。

## 开发与维护

```sh
./script/test.sh
bash script/test_uninstall.sh
python3 script/check_publication.py
```

<details>
<summary><strong>项目结构与提交检查</strong></summary>

| 目录 | 内容 |
| :--- | :--- |
| `Sources/` | 应用界面、路由、DNS 与后台服务 |
| `Tests/` | 单元测试与协议检查 |
| `Assets/` | 应用图标 |
| `data/` | 数据来源与生成记录 |
| `script/` | 构建、测试与检查工具 |
| `docs/` | 安全说明、数据说明与界面预览 |

`work/`、`dist/`、构建缓存、日志、凭据和本机配置已加入 Git 忽略。诊断结果保存在 `work/validation/`。提交前运行公开文件检查；不要用 `git add -f` 加入本地归档。检查工具不能替代对新增文件的人工审阅。

`validate_live_*.py` 会真实修改网络，只在理解脚本且已关闭分流的测试环境中手动运行。

</details>

<details>
<summary><strong>完整卸载与清理</strong></summary>

在设置中打开完整卸载工具。工具会在终端列出删除范围，输入 `UNINSTALL` 并完成管理员授权后，按顺序执行：

1. 授权成功后退出该 App，防止清理期间再次写入配置或启动安装。
2. 撤销 RouteWeaver 的路由和 DNS，核验网络恢复完成，再移除后台服务、启动项、通信套接字，以及服务配置和路由恢复日志。
3. 删除本机规则、活动记录、偏好、缓存、窗口状态和命令临时文件，最后删除该 App。
4. 检查上述文件是否仍存在；任何检查或清理失败都会明确报错，不会显示完成。

不会删除 Tailscale 配置、手动导出的文件、源码目录或独立诊断归档。发现未知文件、符号链接或不安全的权限时会保留并报告；请按提示处理后重试。不要仅将 App 拖入废纸篓，这不会自动移除系统帮助程序。

也可从源码目录针对指定安装位置运行（不要对整个脚本使用 `sudo`）：

```sh
bash script/uninstall.sh --app /Applications/RouteWeaver.app
```

只读检查用户数据和 App 的删除范围，不请求管理员权限或改变网络：

```sh
bash script/uninstall.sh --app /Applications/RouteWeaver.app --check
```

如果只需卸载系统后台服务、保留 App 和用户数据，可运行当前 App 内的帮助程序：

```sh
sudo /Applications/RouteWeaver.app/Contents/Helpers/RouteWeaverHelper uninstall-service
```

</details>

## 许可与致谢

原创代码采用 [MIT License](LICENSE)，第三方数据保留各自许可。

分流思路与 `PF_ROUTE` 批量路由方案参考了 **[leolovenet/tailscale-routes](https://github.com/leolovenet/tailscale-routes)**，特别感谢原作者。

| 参考范围 | 项目与来源 |
| :--- | :--- |
| 地址与域名数据 | [APNIC](https://ftp.apnic.net/stats/apnic/) · [domain-list-community](https://github.com/v2fly/domain-list-community) |
| 界面与交互参考 | [Stats](https://github.com/exelban/stats) · [Ice](https://github.com/jordanbaird/Ice) · [CodeEdit](https://github.com/CodeEditApp/CodeEdit) · [Xcodes](https://github.com/XcodesOrg/XcodesApp) · [Pearcleaner](https://github.com/alienator88/Pearcleaner) |

各项目的使用范围、许可及其他技术参考见 [第三方说明](THIRD_PARTY_NOTICES.md)。
