import SwiftUI

struct RoutePreviewView: View {
    let routes: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedRoute: String?
    @State private var branch: RouteDemoBranch = .direct
    @State private var playing = true

    init(routes: [String]) {
        self.routes = routes
        _branch = State(initialValue: routes.isEmpty ? .exit : .direct)
    }

    var body: some View {
        let filtered = query.isEmpty ? routes : routes.filter { $0.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("ROUTE PLAN")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2).foregroundStyle(WeaveStyle.accent)
                    Text("路由计划").font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(WeaveActionStyle(prominent: true)).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(routes.count.formatted())
                    .font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WeaveStyle.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("条直连路由").font(.system(size: 13, weight: .medium))
                    Text("已合并重叠，并排除出口例外").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            flowDemonstration
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 IPv4 网段", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                    .accessibilityLabel("搜索路由计划")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 22, height: 22) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                        .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WeaveStyle.stroke))
            List(filtered, id: \.self) { route in
                Button {
                    selectedRoute = route
                    branch = .direct
                } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 1).fill(WeaveStyle.accent.opacity(0.65))
                        .frame(width: 2, height: 12)
                    Text(route).font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Text("DIRECT").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(1).foregroundStyle(WeaveStyle.accent.opacity(0.8))
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("演示直连网段 " + route)
                .accessibilityValue(selectedRoute == route && branch == .direct ? "已选中" : "")
                .listRowBackground(selectedRoute == route && branch == .direct ? WeaveStyle.accent.opacity(0.1) : Color.clear)
                .listRowSeparator(.hidden)
            }
            .frame(minHeight: 120)
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WeaveStyle.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                if filtered.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .light))
                            .foregroundStyle(WeaveStyle.accent.opacity(0.5))
                        Text(routes.isEmpty ? "当前计划没有直连路由" : "没有匹配的网段")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            Label("这是待应用计划。后台仍会检查网络和路由冲突。", systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640, idealHeight: 720)
        .background(WeaveStyle.background)
        .onChange(of: routes) { _, newRoutes in
            if newRoutes.isEmpty {
                branch = .exit
                selectedRoute = nil
            } else if let selectedRoute, !newRoutes.contains(selectedRoute) {
                self.selectedRoute = nil
            }
        }
    }

    private var flowDemonstration: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("规则流向演示 · 非实时流量")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                RouteDemoPlaybackButton(playing: $playing)
            }
            Picker("演示路径", selection: $branch) {
                Text("直连").tag(RouteDemoBranch.direct)
                Text("未匹配（经出口）").tag(RouteDemoBranch.exit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(routes.isEmpty)
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                ZStack {
                    RouteFlowAnimation(layout: .preview, focus: branch, playing: playing, directAvailable: !routes.isEmpty)
                    VStack(spacing: 5) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 24, weight: .light)).foregroundStyle(branch.color)
                        Text("这台 Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .position(x: 29, y: height * 0.48 + 8)
                    previewDestination(.direct, title: "本地网关", tag: "DIRECT")
                        .frame(width: width * 0.38).position(x: width * 0.79, y: height * 0.26)
                    previewDestination(.exit, title: "Tailscale 出口", tag: "EXIT NODE")
                        .frame(width: width * 0.38).position(x: width * 0.79, y: height * 0.74)
                }
            }
            .frame(height: 94)
            Text(branch == .exit ? "未匹配直连规则的地址" : (selectedRoute.map { "选中网段：" + $0 } ?? "点击下方直连网段，查看它的流向"))
                .font(.system(size: 11, design: branch == .direct && selectedRoute != nil ? .monospaced : .default))
                .foregroundStyle(branch.color.opacity(0.85)).lineLimit(1)
                .accessibilityLabel(branch == .exit ? "演示：未匹配直连规则的地址经出口节点" : (selectedRoute.map { "演示：" + $0 + " 经本地网关直连" } ?? "请选择下方直连网段"))
        }
        .padding(14)
        .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WeaveStyle.stroke))
    }

    private func previewDestination(_ target: RouteDemoBranch, title: String, tag: String) -> some View {
        Button { branch = target } label: {
            HStack(spacing: 8) {
                Image(systemName: target == .direct ? "arrow.up.right" : "network")
                    .font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(target.color)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(target.color.opacity(branch == target ? 0.1 : 0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(target.color.opacity(branch == target ? 0.35 : 0.1)))
            .opacity(branch == target ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(target == .direct && routes.isEmpty)
        .accessibilityLabel(title + "，" + tag)
        .accessibilityValue(branch == target ? "当前演示路径" : "")
    }
}
