import SwiftUI

struct OverviewView: View {
    @Bindable var store: AppStore
    @State private var lookupIP = ""
    @State private var lookupResult: String?
    @State private var showPreview = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WeaveStyle.sectionGap) {
                hero
                connectionContext
                if store.hasUnappliedChanges && store.serviceEnabled { pendingChanges }
                RouteFlowView(store: store)
                metrics
                lowerWorkspace
                if let notice = store.notice, store.lastError == nil, store.serviceReachable {
                    Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(WeaveStyle.pageInset).frame(maxWidth: WeaveStyle.pageWidth).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showPreview) { RoutePreviewView(routes: store.plannedRoutes) }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Rectangle().fill(WeaveStyle.accent).frame(width: 18, height: 2)
                    Text("CONNECTION OVERVIEW").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.8).foregroundStyle(WeaveStyle.accent.opacity(0.8))
                }
                Text("让流量，各行其道。")
                    .font(.system(size: 30, weight: .semibold)).tracking(-0.6)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .fixedSize(horizontal: false, vertical: true)
                Text("本地直连，与世界保持连接。")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            connectionControl
        }
        .padding(.top, 4).padding(.bottom, 6)
    }

    private var connectionControl: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("智能分流")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                HStack(spacing: 7) {
                    if store.connection.isTransitioning {
                        ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(store.connection.tone.color).frame(width: 6, height: 6)
                    }
                    Text(store.connection.title)
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : WeaveMotion.feedback, value: store.connection.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(WeaveStyle.stroke).frame(width: 1, height: 28)
            Toggle("启用分流", isOn: Binding(
                get: { store.operation == .applying || store.serviceEnabled },
                set: { value in Task { await store.setRoutingEnabled(value) } }
            ))
                .labelsHidden().toggleStyle(.switch).controlSize(.regular)
                .tint(WeaveStyle.accent)
                .disabled(!store.canToggleRouting)
                .accessibilityLabel("启用分流")
                .accessibilityHint(store.connection.title)
                .help(store.serviceEnabled ? "关闭自动恢复并撤销本应用路由" : "启用当前规则计划")
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
        .frame(width: 250)
        .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
    }

    private var connectionContext: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 20) {
                Text(store.connection.detail)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.connection.primaryAction != nil || store.connection.secondaryAction != nil {
                    HStack(spacing: 8) {
                        if let action = store.connection.primaryAction {
                            ConnectionActionButton(action: action, store: store).buttonStyle(WeaveActionStyle())
                        }
                        if let action = store.connection.secondaryAction {
                            ConnectionActionButton(action: action, store: store).buttonStyle(WeaveActionStyle(tint: .secondary))
                        }
                    }.fixedSize()
                }
            }
            if store.connection.kind == .unavailable || store.connection.kind == .recovering {
                DisclosureGroup("诊断详情") {
                    Text(store.serviceMessage).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.top, 5)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 0) {
            metric(label: "已核验直连路由", value: store.activeRouteCount.map { $0.formatted() } ?? "待确认", footnote: "当前计划 \(store.plannedRoutes.count.formatted()) 条", symbol: "square.stack.3d.up", color: WeaveStyle.accent, large: true)
            Rectangle().fill(WeaveStyle.stroke).frame(width: 1).padding(.vertical, 7)
            metric(label: store.usesConfirmedServiceNetwork ? "正在使用的本地网关" : "本地网络", value: store.displayedGateway ?? "等待连接", footnote: store.usesConfirmedServiceNetwork ? "后台确认 · \(store.displayedInterface ?? "")" : "物理接口 · \(store.displayedInterface ?? "—")", symbol: "wifi", color: WeaveStyle.accent)
            Rectangle().fill(WeaveStyle.stroke).frame(width: 1).padding(.vertical, 7)
            metric(label: "TAILSCALE 出口", value: store.network.exitNodeName ?? "未选择节点", footnote: store.network.tailscaleRunning && store.network.exitNodeOnline ? "节点在线" : "等待连接", symbol: "network", color: WeaveStyle.blue)
        }
        .padding(.vertical, 16)
        .background(WeaveStyle.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(WeaveStyle.stroke))
    }

    private func metric(label: String, value: String, footnote: String, symbol: String, color: Color, large: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.53)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: symbol).font(.system(size: 13, weight: .light)).foregroundStyle(color.opacity(0.6))
            }
            Text(value).font(.system(size: large ? 27 : 18, weight: .medium, design: large ? .rounded : .default))
                .tracking(large ? -0.5 : -0.3).lineLimit(1).minimumScaleFactor(0.75).frame(height: 29, alignment: .leading).textSelection(.enabled)
                .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
            Text(footnote).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).help(footnote)
        }.padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lowerWorkspace: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("当前策略").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("POLICY").font(.system(size: 10, design: .monospaced)).tracking(1.8).foregroundStyle(.tertiary)
                }
                HStack(spacing: 11) {
                    Image(systemName: "globe.asia.australia").font(.system(size: 25, weight: .light)).foregroundStyle(WeaveStyle.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.countryEnabled ? "中国大陆 IPv4 直连" : "仅使用自定义规则").font(.system(size: 12, weight: .medium))
                        Text("APNIC · \(store.datasetDate)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { store.selection = .rules } label: { Label("管理规则", systemImage: "arrow.up.right") }.buttonStyle(WeaveActionStyle())
                    Spacer()
                    Button("预览计划") { showPreview = true }.buttonStyle(WeaveActionStyle(tint: .secondary))
                }.font(.system(size: 11, weight: .medium)).padding(.top, 0)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WeaveStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(WeaveStyle.stroke))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("这个 IP 会走哪里？").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 12)).foregroundStyle(WeaveStyle.blue)
                }
                HStack(spacing: 8) {
                    TextField("输入 IPv4 地址", text: $lookupIP).textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced)).onSubmit(lookup)
                        .accessibilityLabel("查询 IPv4 地址")
                    Button(action: lookup) { Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
                        .buttonStyle(WeaveQuietStyle(cornerRadius: 7)).foregroundStyle(lookupIP.isEmpty ? .secondary : WeaveStyle.accent)
                        .disabled(lookupIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("查询")
                }.padding(.horizontal, 12).padding(.vertical, 6)
                .background(WeaveStyle.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WeaveStyle.stroke))
                Text(lookupResult ?? "按当前规则预览，不代表实时连通性。")
                    .font(.system(size: 11)).foregroundStyle(lookupResult == nil ? .white.opacity(0.5) : WeaveStyle.accent.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(WeaveStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(WeaveStyle.stroke))
        }
        // Measure the row at its natural height, then let both card surfaces
        // fill the taller content. Query results can still wrap and grow.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lookup() { lookupResult = store.classify(lookupIP) }

    private var pendingChanges: some View {
        HStack(spacing: 12) {
            Circle().fill(.orange).frame(width: 5, height: 5)
            Text("有未应用的更改").font(.system(size: 12, weight: .medium))
            Text("当前仍使用上次规则").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("应用更改") { Task { await store.apply() } }.disabled(!store.canApply).buttonStyle(WeaveActionStyle(tint: .orange))
        }.padding(15).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
