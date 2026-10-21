import SwiftUI
import RouteCore

/// The inspector edits a draft; only Save touches the user's rule plan.
struct RuleEditor: View {
    let store: AppStore
    let existing: RouteRule?
    let onCancel: () -> Void
    let onSave: (UUID?) -> Void
    @State private var address: String
    @State private var action: RuleAction
    @State private var note: String
    @State private var saveError: String?
    @FocusState private var addressFocused: Bool

    init(store: AppStore, existing: RouteRule?, onCancel: @escaping () -> Void, onSave: @escaping (UUID?) -> Void) {
        self.store = store; self.existing = existing; self.onCancel = onCancel; self.onSave = onSave
        _address = State(initialValue: existing?.cidr ?? "")
        _action = State(initialValue: existing?.action ?? .exitNode)
        _note = State(initialValue: existing?.note ?? "")
    }

    private var input: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var normalized: Result<IPv4CIDR, Error> {
        Result {
            let value = try IPv4CIDR(input.contains("/") ? input : input + "/32")
            if action == .direct { try value.validateForBypass() }
            guard !store.rules.contains(where: { $0.id != existing?.id && $0.cidr == value.description && $0.action == action }) else {
                throw AppFailure("已存在相同网段和流向的规则。请编辑已有规则。")
            }
            return value
        }
    }
    private var validationMessage: String? {
        guard !input.isEmpty, case .failure(let error) = normalized else { return nil }
        return error.localizedDescription
    }
    private var canSave: Bool { !input.isEmpty && (try? normalized.get()) != nil && !store.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("ROUTE EDITOR")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.6).foregroundStyle(WeaveStyle.accent)
                    Text(existing == nil ? "添加规则" : "编辑规则")
                        .font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                        .frame(width: 12)
                }
                .buttonStyle(WeaveActionStyle()).help("关闭编辑器")
                .accessibilityLabel("关闭规则编辑器")
            }.padding(20)
            Rectangle().fill(WeaveStyle.stroke).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("目标地址", detail: "IPv4 / CIDR")
                        TextField("223.5.5.5 或 223.5.5.0/24", text: $address)
                            .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                            .padding(12)
                            .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(validationMessage != nil ? Color.red.opacity(0.6) : (addressFocused ? WeaveStyle.accent.opacity(0.7) : WeaveStyle.stroke)))
                            .focused($addressFocused).accessibilityLabel("IPv4 地址或 CIDR 网段")
                            .onChange(of: address) { _, _ in saveError = nil }
                        if let validationMessage {
                            Label(validationMessage, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        } else if !input.isEmpty, let cidr = try? normalized.get() {
                            Label(cidr.description, systemImage: "checkmark.circle")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(WeaveStyle.accent)
                        } else {
                            Text("单个地址会保存为 /32 网段。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("流量去向", detail: "DESTINATION")
                        Picker("流量去向", selection: $action) {
                            Label("通过出口节点", systemImage: "arrow.triangle.branch")
                                .foregroundStyle(WeaveStyle.blue).tag(RuleAction.exitNode)
                            Label("本地直连", systemImage: "arrow.up.right")
                                .foregroundStyle(WeaveStyle.accent).tag(RuleAction.direct)
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WeaveStyle.stroke))
                        .onChange(of: action) { _, _ in saveError = nil }
                        Text(action == .exitNode ? "保留 Tailscale 出口路由。这条例外会优先于所有直连规则。" : "通过本地 Wi-Fi 或以太网访问。私有地址和系统保留网段不可设为直连。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("备注", detail: "可选")
                        TextField("记录这条规则的用途…", text: $note, axis: .vertical)
                            .lineLimit(3...5).textFieldStyle(.plain).font(.system(size: 13))
                            .padding(12)
                            .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WeaveStyle.stroke))
                    }
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20)
            }
            Rectangle().fill(WeaveStyle.stroke).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                Label("保存到计划，应用后生效。", systemImage: "circle.dashed")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button("取消", action: onCancel)
                        .buttonStyle(WeaveActionStyle()).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存规则", action: save)
                        .buttonStyle(WeaveActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }.padding(20)
        }
        .background(WeaveStyle.background)
        .onAppear { addressFocused = true }
    }

    private func fieldLabel(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.5).foregroundStyle(.tertiary)
        }
    }

    private func save() {
        do {
            let cidr = try normalized.get().description
            if let existing { try store.updateRule(id: existing.id, cidr: cidr, action: action, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            else { try store.addRule(cidr: cidr, action: action, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            onSave(existing?.id ?? store.rules.first(where: { $0.cidr == cidr && $0.action == action })?.id)
        } catch { saveError = error.localizedDescription }
    }
}
