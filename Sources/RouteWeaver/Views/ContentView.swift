import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showProfileExport = false
    @State private var showProfileReloadConfirmation = false
    @State private var profileExportDocument = RulesDocument(text: "")
    @State private var profileExportError: String?
    @FocusState private var focusedPage: AppSection?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 24, weight: .regular)).foregroundStyle(WeaveStyle.accent)
                        .frame(width: 40, height: 40)
                        .background(WeaveStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RouteWeaver").font(.system(size: 17, weight: .semibold)).tracking(-0.5)
                        Text("LOCAL FIRST. OPEN WORLD.")
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 19).padding(.top, 24).padding(.bottom, 26)
                VStack(alignment: .leading, spacing: 8) {
                    Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.40)).padding(.horizontal, 13).padding(.bottom, 5)
                    navigationItem(.overview, title: "连接总览", symbol: "square.grid.2x2")
                    navigationItem(.rules, title: "分流规则", symbol: "line.3.horizontal.decrease")
                    navigationItem(.activity, title: "活动记录", symbol: "waveform.path")
                    Rectangle().fill(.white.opacity(0.055)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 14)
                    navigationItem(.settings, title: "设置", symbol: "slider.horizontal.3")
                }.padding(.horizontal, 14)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Circle().fill(store.connection.tone.color).frame(width: 5, height: 5)
                        Text(store.connection.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    }
                    Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                    HStack {
                        Text("ON YOUR MAC").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.6)
                        Spacer()
                        Image(systemName: "lock.shield").font(.system(size: 11))
                    }.foregroundStyle(.tertiary)
                }.padding(20)
            }
            .background(WeaveStyle.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } detail: {
            VStack(spacing: 0) {
                if let message = store.profileRecoveryMessage { profileRecoveryBanner(message) }
                if let error = store.lastError, error != store.profileRecoveryMessage { errorBanner(error) }
                Group {
                    switch store.selection {
                    case .overview: OverviewView(store: store)
                    case .rules: RulesView(store: store)
                    case .activity: ActivityView(store: store)
                    case .settings: SettingsView(store: store)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(WeaveStyle.background)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { Task { await store.refresh() } } label: {
                        if store.isRefreshing { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                        else { Label("刷新状态", systemImage: "arrow.clockwise") }
                    }
                    .disabled(store.isRefreshing || store.isBusy)
                    .help("刷新连接和后台状态（⌘R）").keyboardShortcut("r")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(WeaveStyle.accent)
        .preferredColorScheme(.dark)
        .defaultFocus($focusedPage, .overview)
        .toolbarBackground(WeaveStyle.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .fileExporter(isPresented: $showProfileExport, document: profileExportDocument,
                      contentType: .json, defaultFilename: "routeweaver-unsaved-rules.json") { result in
            if case .failure(let error) = result {
                let cocoaError = error as NSError
                if cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError {
                    profileExportError = error.localizedDescription
                }
            }
        }
        .confirmationDialog("读取磁盘上的最新配置？", isPresented: $showProfileReloadConfirmation, titleVisibility: .visible) {
            Button("读取磁盘版本", role: .destructive) { store.reloadProfile() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("这会替换窗口中尚未保存的规则和活动记录。请先导出需要保留的规则。读取配置不会应用路由。")
        }
    }

    private func navigationItem(_ section: AppSection, title: String, symbol: String) -> some View {
        Button { store.selection = section } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 20)
                Text(title).font(.system(size: 13, weight: store.selection == section ? .semibold : .medium))
                Spacer(minLength: 0)
                if store.selection == section { Circle().fill(WeaveStyle.accent).frame(width: 4, height: 4) }
            }
            .foregroundStyle(store.selection == section ? WeaveStyle.accent : .white.opacity(0.56))
            .padding(.horizontal, 13).padding(.vertical, 12)
            .background(store.selection == section ? WeaveStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(store.selection == section ? WeaveStyle.accent.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(WeaveQuietStyle(cornerRadius: 12)).accessibilityLabel(title)
        .accessibilityAddTraits(store.selection == section ? [.isSelected] : [])
        .focused($focusedPage, equals: section)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("操作未完成").font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("查看活动") { store.selection = .activity }.buttonStyle(WeaveActionStyle(tint: .orange))
            Button { store.dismissError() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .buttonStyle(WeaveQuietStyle(cornerRadius: 8)).foregroundStyle(.secondary).help("收起提示")
                .accessibilityLabel("收起错误提示")
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(.orange.opacity(0.08))
    }

    private func profileRecoveryBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("本机配置尚未保存", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Text("当前规则保留在这个窗口中。请先导出需要保留的规则，再读取磁盘版本继续编辑。")
                .font(.caption).foregroundStyle(.secondary)
            if let profileExportError {
                Text("导出失败：" + profileExportError).font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                Button("导出当前规则…") {
                    profileExportError = nil
                    profileExportDocument = RulesDocument(text: store.exportRules())
                    showProfileExport = true
                }
                Button("读取磁盘版本…") { showProfileReloadConfirmation = true }
            }
            .buttonStyle(WeaveActionStyle(tint: .orange))
            .disabled(store.isBusy || store.isQuitting)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(.orange.opacity(0.08))
    }
}
