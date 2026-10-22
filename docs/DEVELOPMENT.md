# 开发指南

[返回 README](../README.md) · [数据来源](DATA.md)

提交代码前请阅读 [贡献指南](../CONTRIBUTING.md)。自动检查范围见 [CI 工作流](../.github/workflows/ci.yml)，漏洞报告方式见 [安全政策](../SECURITY.md)。

## 构建环境

- Xcode 26 或更新版本，包含 macOS 26 SDK 和 Swift 6.2+。源码包含受系统版本保护的 `glassEffect`，旧 SDK 即使能解析包清单也无法编译该 API。
- 构建机需满足所选 Xcode 的系统要求；Xcode 26 需要 macOS 15.6 或更新版本，见 [Apple 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)。编译后的 App 最低运行版本仍为 macOS 14。
- 构建和测试会调用 `swift`、`clang`、`codesign`、`sips` 和 `iconutil`；请确保命令行工具选中了上述 Xcode，而非旧版本或独立 Command Line Tools。
- 无第三方 Swift 包依赖。
- 构建与单元测试不要求开启 Tailscale；实际运行分流时需要可用的 Tailscale exit node。

当前发布 ZIP 为 arm64；构建脚本按宿主架构编译，尚未验证 Intel Mac 的构建和运行。

```sh
git clone https://github.com/Hmmzzz/RouteWeaver.git
cd RouteWeaver
./script/build_and_run.sh --build-only
open dist/RouteWeaver.app
```

构建产物位于 `dist/`。Release 打包会在签名前移除两个可执行文件的调试符号，避免携带本地构建路径；Debug 构建保留调试符号。构建使用 ad-hoc 签名，更新签名身份后可能需要重新关联后台服务。

## 本地检查

公开文件检查需要 Python 3.9 或更新版本。

```sh
./script/test.sh
bash script/test_uninstall.sh
python3 script/check_publication.py
```

`test.sh` 运行 Swift 测试和路由快照 fixture；卸载 fixture 在隔离临时目录中验证清理逻辑。公开文件检查用于排查常见敏感内容，不能替代对暂存区、Git 历史、发布附件及新增截图的审阅。

`script/validate_live_*.py` 会真实修改网络，只在理解脚本且已关闭分流的测试环境中手动运行。

## 项目结构

| 目录 | 内容 |
| :--- | :--- |
| `Sources/` | 应用界面、路由、DNS 与后台服务 |
| `Tests/` | 单元测试与协议检查 |
| `Assets/` | 应用图标与生成说明 |
| `data/` | 数据来源与生成记录 |
| `script/` | 构建、测试与检查工具 |
| `docs/` | 使用、安全、数据说明与界面预览 |

## 提交前的隐私检查

`work/`、`dist/`、构建缓存、日志、凭据和本机配置已加入 Git 忽略。诊断结果保存在 `work/validation/`。不要用 `git add -f` 加入本地归档。

公开日志或截图前，移除设备名、Tailnet 域名、真实网络信息、用户路径和凭据。截图应使用示例数据；修改文档截图后，先完成像素和元数据审阅，再更新公开文件检查脚本内对应的摘要。
