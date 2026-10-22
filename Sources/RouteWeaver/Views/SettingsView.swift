import SwiftUI
import AppKit

/// Preferences remain a destination in the main window.
struct SettingsView: View {
    let store: AppStore
    @State private var showAdvanced = false
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版" }
    private var serviceColor: Color { store.serviceReachable ? WeaveStyle.accent : (store.serviceChecked ? .orange : .secondary) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeading(eyebrow: "PREFERENCES", title: "设置", subtitle: "让后台服务和路由规则保持就绪。")
                serviceSection
                dataSection
                    .padding(20)
                    .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
                behaviorSection
                    .padding(20)
                    .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
                uninstallSection
                AboutSection(version: version, author: "Hmmzzz", authorURL: URL(string: "https://github.com/Hmmzzz"))
                HStack {
                    Spacer()
                    Button("打开配置文件夹", systemImage: "folder") { NSWorkspace.shared.open(ProfileStorage.directory) }
                        .buttonStyle(WeaveActionStyle())
                }.padding(.top, 2)
            }
            .padding(28).frame(maxWidth: WeaveStyle.pageWidth).frame(maxWidth: .infinity)
        }
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 23, weight: .light)).foregroundStyle(serviceColor)
                    .frame(width: 44, height: 44)
                    .background(serviceColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(serviceColor.opacity(0.16)))
                VStack(alignment: .leading, spacing: 5) {
                    Text("后台服务").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(serviceTitle).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                    Text(serviceDescription).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if store.operation == .repairing { ProgressView().controlSize(.small) }
                Button(store.serviceReachable ? "检查授权" : (store.serviceInstalled ? "修复服务…" : "安装服务…")) { Task { await store.repairService() } }
                    .buttonStyle(WeaveActionStyle(prominent: !store.serviceInstalled)).disabled(store.isBusy)
            }
            HStack(alignment: .top, spacing: 24) {
                serviceFact("后台连接", value: store.serviceReachable ? "已连接" : (store.serviceChecked ? "未连接" : "正在检查…"), color: serviceColor)
                serviceFact("自动恢复", value: store.serviceEnabled ? "已启用" : "随分流开启", color: .primary)
                if let date = store.lastServiceCheck {
                    serviceFact("最近读取", value: date.formatted(.dateTime.hour().minute().second()), color: .primary)
                }
                Spacer(minLength: 0)
            }.padding(.leading, 58)
            Rectangle().fill(WeaveStyle.stroke).frame(height: 1)
            HStack(spacing: 8) {
                Button("重新检查", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isBusy || store.isRefreshing)
                Button("查看活动记录", systemImage: "arrow.up.right") { store.selection = .activity }
                Spacer()
                if store.canStop {
                    Button(store.serviceEnabled ? "关闭分流并清理路由" : "清理本应用路由") { Task { await store.rollback() } }.disabled(store.isBusy)
                }
            }.buttonStyle(WeaveActionStyle()).font(.system(size: 13))
            Text("首次安装授权后，同一版本的启动、分流开关和网络恢复均直接复用帮助程序。更换应用构建或修复服务时，可能需要重新授权。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [WeaveStyle.accent.opacity(0.06), WeaveStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.accent.opacity(0.15)))
    }

    private var serviceTitle: String {
        if !store.serviceChecked { return "正在检查服务" }
        if store.serviceReachable { return "已授权，可直接使用" }
        return store.serviceInstalled ? "需要检查后台连接" : "尚未安装后台服务"
    }
    private var serviceDescription: String {
        if store.serviceReachable { return "关闭窗口后仍通过状态栏运行；退出应用时恢复原网络。" }
        return store.serviceInstalled ? "分流状态暂时无法确认。先重新检查，仍无法连接时再修复服务。" : "用于执行路由操作和网络变化后的恢复；只需在首次安装时授权。"
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("规则数据", symbol: "globe.asia.australia", color: WeaveStyle.accent)
                Spacer()
                if store.operation == .updatingDataset { ProgressView().controlSize(.small) }
                Button(store.operation == .updatingDataset ? "正在更新…" : "检查数据更新", systemImage: "arrow.down.circle") { Task { await store.updateDataset() } }
                    .buttonStyle(WeaveActionStyle()).disabled(store.isBusy)
            }
            VStack(spacing: 12) {
                settingRow("数据来源", value: "APNIC · 中国大陆（CN）")
                settingRow("数据日期", value: store.datasetDate)
                settingRow("地址网段", value: "\(store.countryRoutes.count.formatted()) 条 IPv4 CIDR")
            }
            Text("更新只修改规则计划，应用更改后才会影响分流。地址分配地区不等同于服务实际位置；更新时仅连接 APNIC 官方服务器。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("运行方式与隐私", symbol: "lock.shield", color: WeaveStyle.accent)
            VStack(spacing: 12) {
                settingRow("关闭分流", value: "恢复原解析，并撤销本应用路由")
                settingRow("关闭窗口", value: "隐藏 Dock 图标，保留状态栏与分流")
                settingRow("退出应用", value: "先撤回 DNS 和路由，确认恢复后退出")
                settingRow("国内域名解析", value: store.serviceDNSActive ? "已开启 · \(store.serviceDNSDomainCount.formatted()) 个域名范围" : store.serviceDNSMessage)
                settingRow("IPv6", value: "已确认直连的域名使用 IPv4，其余沿用原设置")
            }.font(.system(size: 13))
            Label("国内白名单使用阿里公共 DNS 加密解析，其余查询交回 Tailscale。查询仅短暂缓存在内存，不保存访问历史。规则和活动记录保存在本机。", systemImage: "internaldrive")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 2)
            DisclosureGroup("高级与故障排查", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("遇到问题时，先在连接页查看具体状态。网络未就绪可打开 Tailscale；后台无法连接可重新检查或修复服务；仍有待恢复路由时使用“关闭分流并清理路由”。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("打开 Tailscale") { AppNavigation.openTailscale() }
                        Button("前往连接页") { store.selection = .overview }
                    }.buttonStyle(WeaveActionStyle())
                }.padding(.top, 12)
            }.font(.system(size: 13)).tint(WeaveStyle.accent)
        }
    }

    private var uninstallSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("卸载与清理", symbol: "trash", color: .secondary)
                Spacer()
                Button("卸载 RouteWeaver…") { store.openUninstaller() }
                    .buttonStyle(WeaveActionStyle()).disabled(store.isBusy || store.isQuitting)
            }
            Text("打开独立卸载工具，确认后恢复网络，并移除后台帮助程序、本机规则与活动记录、缓存及当前 App。删除前会请求管理员授权；无法完成的清理会明确列出。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("请先导出需要保留的规则。你自行导出的文件和项目源码不会被删除。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
    }

    private func settingRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 13)).frame(minHeight: 22)
    }
    private func serviceFact(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(color)
        }
    }
    private func sectionTitle(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).font(.system(size: 14, weight: .semibold))
        }
    }
}
