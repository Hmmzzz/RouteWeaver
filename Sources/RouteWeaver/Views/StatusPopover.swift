import AppKit
import SwiftUI

/// A compact, native status surface. All values come from the existing stores;
/// opening this panel does not start another sampler or background task.
struct StatusPopover: View {
    var store: AppStore
    var traffic: TrafficMonitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var directColor: Color { colorScheme == .dark ? WeaveStyle.accent : Color(red: 0.10, green: 0.36, blue: 0.76) }
    private var tunnelColor: Color { colorScheme == .dark ? WeaveStyle.blue : Color(red: 0.45, green: 0.32, blue: 0.77) }
    private var stateColor: Color {
        store.connection.tone == .success ? directColor : store.connection.tone.color
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                connection
                trafficDashboard
                routingDetails
                if let action = store.connection.primaryAction {
                    Button(action.title) { perform(action) }
                        .buttonStyle(StatusPanelButtonStyle(tint: directColor))
                        .disabled(store.isBusy)
                }
            }
            .padding(16)
            Divider()
            actions
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(StatusPanelWindowSizing(onVisibilityChange: traffic.setPopoverVisible))
        .modifier(StatusPanelSurface())
        .tint(directColor)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(directColor)
                .frame(width: 28, height: 28)
                .background(directColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            Text("RouteWeaver").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { show(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(StatusPanelQuietStyle())
            .foregroundStyle(.secondary)
            .help("打开设置")
            .accessibilityLabel("打开设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var connection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label(store.connection.title, systemImage: store.connection.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .lineLimit(2)
                Text(connectionSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Toggle("启用分流", isOn: Binding(
                get: { store.serviceEnabled },
                set: { enabled in Task { await store.setRoutingEnabled(enabled) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!store.canToggleRouting)
            .help(store.serviceEnabled ? "关闭分流并恢复原有网络" : "开启国内 IPv4 本机直连")
        }
        .accessibilityElement(children: .contain)
    }

    private var connectionSubtitle: String {
        switch store.connection.kind {
        case .on: return "国内本机直连 · 其他流量沿用原路由"
        case .off: return "当前沿用系统与 Tailscale 原有路由"
        case .stopping: return "正在撤回本应用的 DNS 与路由"
        default: return store.connection.detail
        }
    }

    private var trafficDashboard: some View {
        HStack(alignment: .top, spacing: 0) {
            PathTrafficColumn(title: "国内直连", symbol: "arrow.up.right", color: directColor,
                              reading: traffic.direct)
            Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
                .padding(.vertical, 14)
            PathTrafficColumn(title: "Tailscale", symbol: "network", color: tunnelColor,
                              reading: traffic.tailscale)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.05)))
    }

    private var routingDetails: some View {
        VStack(spacing: 8) {
            detailRow("直连规则", value: store.activeRouteCount.map { "\($0.formatted()) 条已核验" } ?? "待确认")
            detailRow("国内解析", value: store.serviceReachable ? (store.serviceDNSActive ? "已启用" : "未启用") : "待确认")
            detailRow("物理出口", value: store.usesConfirmedServiceNetwork ? (store.serviceInterface ?? "待确认") : "—")
            if store.hasUnappliedChanges {
                HStack {
                    Label("规则有未应用的更改", systemImage: "circle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Spacer()
                    Button("应用") { Task { await store.apply() } }
                        .buttonStyle(StatusPanelButtonStyle(tint: directColor))
                        .disabled(!store.canApply)
                }
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("实时速率").font(.system(size: 11, weight: .medium))
                    Toggle("在菜单栏显示实时速率", isOn: Binding(
                        get: { traffic.showsMenuBarRates },
                        set: { traffic.setShowsMenuBarRates($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("仅控制菜单栏数字；弹窗始终显示实时速率")
                }
                .fixedSize()
                Button { show(.overview) } label: {
                    Label("打开主窗口", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                Button { show(.rules) } label: {
                    Label("分流规则", systemImage: "line.3.horizontal.decrease")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(StatusPanelButtonStyle(tint: directColor, compact: true))
            Divider()
            Button { NSApp.terminate(nil) } label: {
                HStack {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text("退出并恢复网络")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(StatusPanelQuietStyle())
            .help("撤回本应用的 DNS 和路由，确认清理完成后退出")
        }
        .padding(14)
    }

    private func show(_ section: AppSection) {
        dismiss()
        store.selection = section
        AppNavigation.revealMainWindow(openWindow: openWindow)
    }
    private func perform(_ action: ConnectionPresentation.Action) {
        if action == .reviewRules { show(.rules) }
        else if action == .openTailscale { dismiss(); AppNavigation.openTailscale() }
        else { Task { await AppNavigation.perform(action, store: store) } }
    }
}

/// A single lightweight control surface over the window's glass material.
/// Hover/press only repaint; the menu layout and labels remain stationary.
private struct StatusPanelButtonStyle: ButtonStyle {
    let tint: Color
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(minHeight: 34)
            .background(tint.opacity(configuration.isPressed ? 0.17 : hovered && enabled ? 0.12 : 0.075), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(hovered && enabled ? 0.23 : 0.13)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : WeaveMotion.hover, value: hovered)
    }
}

private struct StatusPanelQuietStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.09 : hovered ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : WeaveMotion.hover, value: hovered)
    }
}

private struct PathTrafficColumn: View {
    let title: String
    let symbol: String
    let color: Color
    let reading: TrafficRateReading

    private var total: Double? {
        guard let down = reading.downloadBytesPerSecond, let up = reading.uploadBytesPerSecond,
              down.isFinite, up.isFinite, down >= 0, up >= 0 else { return nil }
        return down + up
    }
    var body: some View {
        let amount = TrafficRateFormat.measurement(total)
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(amount.value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                Text(amount.unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
            VStack(spacing: 5) {
                rateRow("下载", symbol: "arrow.down", value: reading.downloadBytesPerSecond)
                rateRow("上传", symbol: "arrow.up", value: reading.uploadBytesPerSecond)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .help(reading.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + "，收发速率")
        .accessibilityValue(TrafficRateFormat.full(reading))
    }
    private func rateRow(_ title: String, symbol: String, value: Double?) -> some View {
        let amount = TrafficRateFormat.measurement(value)
        return HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Text(amount.value + (amount.unit.isEmpty ? "" : " " + amount.unit)).monospacedDigit()
        }
        .font(.system(size: 10))
    }
}

/// MenuBarExtra owns the rounded window and its outer content margins. Paint
/// the enclosing window, not just the inner VStack, so its top/bottom margins
/// use the same material as the content. Keep only one material layer.
private struct StatusPanelSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.containerBackground(for: .window) {
                Rectangle()
                    .fill(.clear)
                    .glassEffect(.regular, in: Rectangle())
                    .ignoresSafeArea()
            }
        } else if #available(macOS 15.0, *) {
            content.containerBackground(.regularMaterial, for: .window)
        } else {
            // macOS 14 already supplies the native MenuBarExtra material.
            // An extra content background would expose mismatched outer strips.
            content
        }
    }
}
