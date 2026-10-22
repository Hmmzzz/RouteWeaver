# 参与贡献

欢迎提交可复现的问题、文档修正和代码改进。构建环境、目录结构及调试说明见[开发指南](docs/DEVELOPMENT.md)。涉及漏洞、权限绕过或敏感数据泄露时，请先阅读[安全报告说明](SECURITY.md)，不要在公开 Issue 或 PR 中附上利用细节。

## 报告问题与提出建议

先搜索现有 Issue。问题报告请注明 RouteWeaver、macOS 和 Tailscale 的版本、Mac 架构、复现步骤、预期行为和实际结果。功能建议请描述使用场景和希望解决的问题；较大的改动建议先开 Issue 讨论。

日志和截图只保留排查所需内容，移除设备名、Tailnet 域名、真实 IP、用户名路径和凭据。不要上传 `work/`、`dist/`、构建缓存或完整诊断归档。

## 提交改动

从最新 `main` 创建分支，每个 PR 尽量聚焦一个问题。说明改动原因、行为变化和验证结果；行为修复应补充能复现问题的测试。新增或更新第三方代码、数据、字体、图片时，同时记录来源、版本及许可，更新相关声明。

在 macOS 上执行：

```sh
./script/test.sh
bash script/test_uninstall.sh
python3 script/check_publication.py
./script/build_and_run.sh --build-only
```

`test.sh` 包含 Swift 测试和模拟路由快照测试；卸载 fixture 使用隔离临时目录。`--build-only` 只生成应用和 ZIP，不启动应用。纯文档改动至少执行公开文件检查并检查链接；未运行的检查请在 PR 中说明。

`script/validate_live_*.py` 会真实修改网络，只能在理解脚本及影响的测试环境中手动运行。单元测试通过不代表真实分流、系统权限或 Helper 安装流程已验证。

## CI 范围

[CI 工作流](.github/workflows/ci.yml) 在 `main` 推送、PR 和手动触发时，使用 GitHub 的 `macos-15` arm64 runner 检查脚本语法、公开文件、Swift 测试、路由快照与卸载 fixture，并构建 Release 应用及验证 ad-hoc 签名。工作流不启动应用、不安装 Helper、不执行实时网络验证，也不上传发布包。

当前 CI 只覆盖 arm64；Intel Mac 与实际网络场景仍需单独验证。每次运行结果见仓库 Actions 页面。

原创代码改动按项目 [MIT 许可证](LICENSE) 提供；`Sources/CRouteStatistics/NetworkStatisticsABI.h` 的修改按 [APSL 2.0](LICENSES/APSL-2.0.txt) 提供，并保留适用的版权、许可与修改记录。其他第三方材料仍须遵守各自许可。请保持讨论具体、友善，并尊重其他人的时间与隐私。
