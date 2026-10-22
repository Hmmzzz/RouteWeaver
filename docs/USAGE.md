# 使用指南

[返回 README](../README.md) · [安全与隐私](SECURITY.md)

## 安装与首次启动

已发布的 App 适用于 Apple Silicon（arm64）Mac，要求 macOS 14 或更新版本。直接下载使用不需要安装 Swift 或 Xcode。

1. 安装并连接 Tailscale，选择一个可用的 exit node。
2. 从本仓库的 [Releases](https://github.com/Hmmzzz/RouteWeaver/releases/latest) 下载 App ZIP，解压并将 `RouteWeaver.app` 放入“应用程序”。Release 更新说明中附有该 ZIP 的 SHA-256，可用于核对下载文件。
3. 打开 RouteWeaver，确认本地网关和 Tailscale 出口已识别，然后开启分流。
4. 首次使用时，按系统提示授权安装后台服务。服务需要管理员权限来管理路由和临时 DNS 设置。

### macOS 提示无法验证开发者

当前安装包采用 ad-hoc 签名，尚未进行 Developer ID 签名或 Apple 公证，因此下载后的首次打开可能被系统拦截。

确认文件来自本仓库且未被改动后，可按 [Apple 官方的 App 打开说明](https://support.apple.com/zh-cn/102445)，在“系统设置 → 隐私与安全性”中处理该 App 的提示。不同提醒含义不同，若系统提示文件损坏或包含恶意内容，应先核对下载文件与提示原因。

## 后台服务与更新授权

同一构建后续启动、开关分流和网络恢复均复用已安装服务，无需重复管理员授权。设置中的安装/修复也会先检查并复用可连接的服务。

更新或重新签名 App 后，若签名身份变化，需要明确授权重新关联。应用不会放宽身份校验来跳过这一步。

## 关闭窗口、停止分流与退出

- **关闭窗口**：继续在菜单栏运行，分流保持启用。
- **关闭分流**：撤回本应用的 DNS 设置与路由，App 保持运行。
- **退出应用**：等待清理完成后退出；清理出现问题时按应用提示处理。

分流只作用于 IPv4。IPv6 由系统和 Tailscale 管理，不提供按应用分流或防泄漏保证。权限、DNS 上游和并发边界见 [安全与隐私](SECURITY.md)。

## 完整卸载与清理

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
