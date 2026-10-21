import SwiftUI
import UniformTypeIdentifiers
import RouteCore

struct RulesView: View {
    @Bindable var store: AppStore
    @State private var selectedRuleID: UUID?
    @State private var filter = RuleFilter.all
    @State private var showEditor = false
    @State private var editingRule: RouteRule?
    @State private var editorSession = UUID()
    @State private var pendingDeletion: RouteRule?
    @State private var showImport = false
    @State private var showExport = false
    @State private var showPreview = false
    @State private var fileError: String?
    @State private var document = RulesDocument(text: "")

    private var selectedRule: RouteRule? { store.rules.first { $0.id == selectedRuleID } }
    private var filteredRules: [RouteRule] {
        let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.rules.filter { rule in
            filter.includes(rule) && (query.isEmpty || rule.cidr.localizedCaseInsensitiveContains(query) || rule.note.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let visibleRules = filteredRules
        VStack(alignment: .leading, spacing: 18) {
            pageHeader
            countrySection
            VStack(alignment: .leading, spacing: 0) {
                ruleControls.padding(14)
                if let fileError {
                    HStack(alignment: .top, spacing: 10) {
                        Label(fileError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button { self.fileError = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("关闭文件操作提示")
                    }.padding(.horizontal, 18).padding(.bottom, 12)
                }
                Rectangle().fill(WeaveStyle.stroke).frame(height: 1)
                rulesTable(visibleRules)
                HStack {
                    Text("\(visibleRules.count) / \(store.rules.count) 条规则")
                        .monospacedDigit()
                    Spacer()
                    Label("出口例外优先", systemImage: "arrow.up.right.and.arrow.down.left")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.vertical, 10)
            }
            .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(WeaveStyle.stroke))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            planStatus
        }
        .padding(28)
        .background(WeaveStyle.background)
        .inspector(isPresented: $showEditor) {
            RuleEditor(store: store, existing: editingRule, onCancel: { showEditor = false }) { id in
                selectedRuleID = id
                showEditor = false
            }
            .id(editorSession)
            .inspectorColumnWidth(min: 280, ideal: 310, max: 360)
        }
        .confirmationDialog("删除这条规则？", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible) {
            if let rule = pendingDeletion {
                Button("删除 \(rule.cidr)", role: .destructive) {
                    store.deleteRule(id: rule.id)
                    if selectedRuleID == rule.id { selectedRuleID = nil }
                    if editingRule?.id == rule.id { showEditor = false }
                    pendingDeletion = nil
                }.disabled(store.isBusy)
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("只从规则计划中删除。正在运行的分流会在你应用更改后更新。")
        }
        .sheet(isPresented: $showPreview) { RoutePreviewView(routes: store.plannedRoutes) }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.plainText, .json], allowsMultipleSelection: false, onCompletion: importFile)
        .fileExporter(isPresented: $showExport, document: document, contentType: .json, defaultFilename: "routeweaver-rules.json") { result in
            if case .failure(let error) = result, !isUserCancellation(error) { fileError = error.localizedDescription }
        }
        .onChange(of: filter) { _, _ in selectedRuleID = nil }
        .onChange(of: store.searchText) { _, _ in selectedRuleID = nil }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("分流规则").font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                Text("IPv4").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(WeaveStyle.stroke.opacity(0.7), in: Capsule())
                Spacer(minLength: 8)
                if !showEditor {
                    Text("TRAFFIC POLICIES")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.1).foregroundStyle(.tertiary)
                }
            }
            Text("为每个地址，选择合适的路径。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var countrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(WeaveStyle.accent.opacity(0.09))
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(WeaveStyle.accent.opacity(0.22))
                    Image(systemName: "globe.asia.australia")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(WeaveStyle.accent)
                }.frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("中国大陆 IPv4")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(store.countryEnabled ? WeaveStyle.accent : Color.secondary)
                            .frame(width: 5, height: 5)
                        Text(store.countryEnabled ? "本地直连 · 已加入计划" : "本地直连 · 未加入计划")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if !showEditor {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(store.countryRoutes.count.formatted())
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text("IP 网段").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.trailing, 6)
                }
                Toggle("中国大陆 IPv4 直连", isOn: Binding(
                    get: { store.countryEnabled },
                    set: { store.countryEnabled = $0; store.rebuildPlan() }
                ))
                .toggleStyle(.switch).labelsHidden().disabled(store.isBusy)
                .help("修改规则计划，应用后生效")
            }
            HStack(spacing: 8) {
                Text("APNIC").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(WeaveStyle.accent.opacity(0.8))
                Text("·  \(store.datasetDate)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button { Task { await store.updateDataset() } } label: {
                    Label("更新数据", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(WeaveActionStyle())
                .disabled(store.isBusy || store.isRefreshing)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [WeaveStyle.accent.opacity(0.10), WeaveStyle.blue.opacity(0.055), WeaveStyle.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.accent.opacity(0.16)))
        .help("地区按地址分配识别，可能与服务实际位置不同。更改计划并应用后生效。")
    }

    private var ruleControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    ruleSectionTitle
                    Spacer(minLength: 8)
                    ruleActions
                }
                VStack(alignment: .leading, spacing: 12) {
                    ruleSectionTitle
                    ruleActions
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    TextField("搜索网段或备注", text: $store.searchText)
                        .textFieldStyle(.plain).font(.system(size: 13)).accessibilityLabel("搜索自定义规则")
                    if !store.searchText.isEmpty {
                        Button { store.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 20, height: 22)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 11).frame(height: 34)
                .background(WeaveStyle.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WeaveStyle.stroke))
                Picker("筛选", selection: $filter) {
                    ForEach(RuleFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 118, height: 34)
                .accessibilityLabel("筛选规则")
            }
        }
    }

    private var ruleSectionTitle: some View {
        HStack(spacing: 8) {
            Text("自定义路由").font(.system(size: 14, weight: .semibold))
            Text(store.rules.count.formatted())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(WeaveStyle.stroke.opacity(0.7), in: Capsule())
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var ruleActions: some View {
        HStack(spacing: 6) {
            Button { edit(nil) } label: { Label("添加", systemImage: "plus") }
                .buttonStyle(WeaveActionStyle(prominent: true))
                .keyboardShortcut("n", modifiers: .command)
                .disabled(store.isBusy).help("添加规则（⌘N）")
            Button { if let selectedRule { edit(selectedRule) } } label: { Label("编辑", systemImage: "pencil") }
                .buttonStyle(WeaveActionStyle())
                .disabled(selectedRule == nil || store.isBusy).help("编辑所选规则，也可双击行")
            Button { pendingDeletion = selectedRule } label: { Label("删除", systemImage: "trash") }
                .buttonStyle(WeaveActionStyle())
                .disabled(selectedRule == nil || store.isBusy).help("删除所选规则")
                .accessibilityLabel("删除所选规则")
            Menu {
                Button("导入规则…", systemImage: "square.and.arrow.down") { fileError = nil; showImport = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("导出规则…", systemImage: "square.and.arrow.up") { exportFile() }
                    .disabled(store.rules.isEmpty).keyboardShortcut("e", modifiers: [.command, .shift])
            } label: {
                Image(systemName: "ellipsis").frame(width: 12)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(WeaveActionStyle())
            .fixedSize()
            .disabled(store.isBusy).help("导入或导出规则")
            .accessibilityLabel("导入和导出规则")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func rulesTable(_ rows: [RouteRule]) -> some View {
        Table(rows, selection: $selectedRuleID) {
            TableColumn("启用") { rule in
                Toggle("启用 \(rule.cidr)", isOn: Binding(
                    get: { rule.enabled }, set: { _ in store.toggleRule(id: rule.id) }
                ))
                .toggleStyle(.checkbox).labelsHidden().disabled(store.isBusy)
            }.width(42)
            TableColumn("IPv4 / 网段") { rule in
                Text(rule.cidr).font(.system(.body, design: .monospaced))
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
            }.width(min: 135, ideal: 160)
            TableColumn("流量去向") { rule in
                Label(rule.action == .direct ? "本地直连" : "出口节点", systemImage: rule.action == .direct ? "arrow.up.right" : "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rule.enabled ? (rule.action == .direct ? WeaveStyle.accent : WeaveStyle.blue) : Color.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background((rule.action == .direct ? WeaveStyle.accent : WeaveStyle.blue).opacity(rule.enabled ? 0.09 : 0.025), in: Capsule())
                    .help(rule.action == .direct ? "通过本地物理网关" : "从直连计划中排除，保留 Tailscale 出口路由")
            }.width(min: 115, ideal: 130)
            TableColumn("备注") { rule in
                Text(rule.note.isEmpty ? "—" : rule.note)
                    .foregroundStyle(.secondary).lineLimit(1).help(rule.note)
            }.width(min: 70, ideal: 180)
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 42)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let rule = store.rules.first(where: { $0.id == id }) {
                Button("编辑规则") { edit(rule) }.disabled(store.isBusy)
                Button(rule.enabled ? "停用规则" : "启用规则") { store.toggleRule(id: id) }.disabled(store.isBusy)
                Divider()
                Button("删除规则…", role: .destructive) { pendingDeletion = rule }.disabled(store.isBusy)
            } else {
                Button("添加规则") { edit(nil) }.disabled(store.isBusy)
            }
        } primaryAction: { ids in
            if !store.isBusy, let id = ids.first, let rule = store.rules.first(where: { $0.id == id }) { edit(rule) }
        }
        .onDeleteCommand { if !store.isBusy { pendingDeletion = selectedRule } }
        .overlay {
            if rows.isEmpty {
                ViewThatFits(in: .vertical) {
                    emptyRulesState(compact: false)
                    emptyRulesState(compact: true)
                }
            }
        }
        .frame(minHeight: 140)
    }

    private func emptyRulesState(compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 10) {
            if !compact {
                ZStack {
                    Circle().strokeBorder(WeaveStyle.accent.opacity(0.12)).frame(width: 50, height: 50)
                    Circle().fill(WeaveStyle.accent.opacity(0.05)).frame(width: 38, height: 38)
                    Image(systemName: store.rules.isEmpty ? "arrow.triangle.branch" : "magnifyingglass")
                        .font(.system(size: 20, weight: .light)).foregroundStyle(WeaveStyle.accent.opacity(0.8))
                }
            }
            Text(store.rules.isEmpty ? "还没有自定义规则" : "没有匹配的规则")
                .font(.system(size: compact ? 14 : 16, weight: .medium))
            Text(store.rules.isEmpty ? (compact ? "添加规则，为个别地址指定不同路径。" : "默认地区规则已为你准备好。\n添加规则，为个别地址指定不同路径。") : "更换筛选条件，或尝试其他关键词。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(3).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if store.rules.isEmpty {
                Button("添加第一条规则") { edit(nil) }
                    .buttonStyle(WeaveActionStyle()).disabled(store.isBusy)
            } else {
                Button("显示全部规则") { filter = .all; store.searchText = "" }
                    .buttonStyle(WeaveActionStyle())
            }
        }
        .padding(compact ? 14 : 20).frame(maxWidth: 360)
    }

    private var planStatus: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                planSummary
                Spacer(minLength: 8)
                planActions
            }
            VStack(alignment: .leading, spacing: 12) {
                planSummary
                HStack { Spacer(minLength: 0); planActions }
            }
        }
        .padding(14)
        .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
    }

    private var planSummary: some View {
        HStack(spacing: 11) {
            Image(systemName: store.hasUnappliedChanges ? "circle.dashed" : "checkmark.circle")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(store.hasUnappliedChanges ? WeaveStyle.blue : WeaveStyle.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(store.hasUnappliedChanges ? "规则更改尚未应用" : (store.serviceEnabled ? "规则已提交给后台" : "规则计划已就绪"))
                    .font(.system(size: 13, weight: .medium))
                Text("\(store.plannedRoutes.count.formatted()) 条直连路由 · 应用后生效")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var planActions: some View {
        HStack(spacing: 8) {
            Button("预览计划") { showPreview = true }
                .buttonStyle(WeaveActionStyle()).disabled(store.isBusy)
            if store.hasUnappliedChanges || (!store.serviceEnabled && !store.plannedRoutes.isEmpty) {
                Button(store.plannedRoutes.isEmpty ? "关闭分流" : (store.serviceEnabled ? "应用更改" : "启用并应用")) { Task { await store.apply() } }
                    .buttonStyle(WeaveActionStyle(prominent: true)).disabled(!store.canApply)
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private func edit(_ rule: RouteRule?) {
        editingRule = rule; editorSession = UUID(); showEditor = true
    }
    private func exportFile() {
        fileError = nil
        document = RulesDocument(text: store.exportRules()); showExport = true
    }
    private func importFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw ImportError.invalidFile }
            let data = try Data(contentsOf: url)
            guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8) else { throw ImportError.invalidFile }
            try store.importRules(text: text)
            filter = .all; store.searchText = ""; fileError = nil
        } catch { if !isUserCancellation(error) { fileError = error.localizedDescription } }
    }
    private func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
    private enum ImportError: LocalizedError {
        case invalidFile
        var errorDescription: String? { "请选择小于 2 MB 的 UTF-8 规则文件。支持文本或 JSON。" }
    }
}

private enum RuleFilter: String, CaseIterable, Identifiable {
    case all, direct, exit, disabled
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部规则"; case .direct: "本地直连"; case .exit: "出口例外"; case .disabled: "已停用" } }
    func includes(_ rule: RouteRule) -> Bool {
        switch self { case .all: true; case .direct: rule.action == .direct; case .exit: rule.action == .exitNode; case .disabled: !rule.enabled }
    }
}

private struct RulesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
