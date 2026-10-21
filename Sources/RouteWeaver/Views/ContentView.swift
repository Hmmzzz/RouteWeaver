import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all
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
                if let error = store.lastError { errorBanner(error) }
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
}
