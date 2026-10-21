import SwiftUI
import AppKit

struct ActivityView: View {
    let store: AppStore
    @State private var selection: ActivityEvent.ID?
    @State private var query = ""
    @State private var onlyIssues = false
    private var filtered: [ActivityEvent] {
        store.events.filter { event in
            (!onlyIssues || event.kind == .error || event.kind == .warning) &&
            (query.isEmpty || event.title.localizedCaseInsensitiveContains(query) || event.detail.localizedCaseInsensitiveContains(query))
        }
    }
    private var selectedEvent: ActivityEvent? { store.events.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "ACTIVITY LOG", title: "活动记录", subtitle: "每次操作与状态变化，都有迹可循。")
                HStack(spacing: 16) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索活动", text: $query).textFieldStyle(.plain).accessibilityLabel("搜索活动记录")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).help("清除搜索")
                        }
                    }
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WeaveStyle.stroke))
                    Toggle("只看异常", isOn: $onlyIssues).toggleStyle(.checkbox).tint(WeaveStyle.accent).fixedSize()
                }.font(.system(size: 13))
            }.padding(28)
            if store.events.isEmpty {
                ContentUnavailableView("还没有活动", systemImage: "waveform.path", description: Text("规则修改、分流操作和错误会记录在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("结果 / 活动")
                    Spacer()
                    Text("发生时间")
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
                .padding(.horizontal, 44).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { event in
                            eventRow(event)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 16)
                }.accessibilityLabel("活动记录列表")
            }
            if let event = selectedEvent { detailPanel(event) }
            HStack {
                Text("\(filtered.count) 条记录 · 最多保留最近 200 条")
                Spacer()
                Label("仅记录操作，不记录流量内容", systemImage: "lock")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 28).padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(WeaveStyle.stroke).frame(height: 1) }
        }
    }

    private func eventRow(_ event: ActivityEvent) -> some View {
        let isSelected = selection == event.id
        return Button { selection = event.id } label: {
            HStack(spacing: 14) {
                Image(systemName: event.kind.symbol)
                    .font(.system(size: 15)).foregroundStyle(event.kind.color)
                    .frame(width: 34, height: 34)
                    .background(event.kind.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(event.kind.title).font(.system(size: 11)).foregroundStyle(event.kind.color)
                }
                Spacer(minLength: 12)
                Text(event.date, format: .dateTime.month().day().hour().minute().second())
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? WeaveStyle.accent : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? WeaveStyle.accent.opacity(0.065) : Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? WeaveStyle.accent.opacity(0.2) : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(ActivityRowStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu { Button("复制详情") { copy(event) } }
    }

    private func detailPanel(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: event.kind.symbol).foregroundStyle(event.kind.color)
                Text(event.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("复制详情", systemImage: "doc.on.doc") { copy(event) }.buttonStyle(WeaveActionStyle())
                Button { selection = nil } label: { Image(systemName: "xmark").font(.caption.weight(.medium)).frame(width: 32, height: 32) }
                    .buttonStyle(WeaveQuietStyle(cornerRadius: 8)).help("收起详情")
                    .accessibilityLabel("收起活动详情")
            }
            ScrollView {
                Text(event.detail).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: 125)
        }
        .padding(.horizontal, 28).padding(.vertical, 18).background(WeaveStyle.surface)
        .overlay(alignment: .top) { Rectangle().fill(WeaveStyle.accent.opacity(0.25)).frame(height: 1) }
    }

    private func copy(_ event: ActivityEvent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(event.title)\n\(event.date.formatted())\n\(event.detail)", forType: .string)
    }
}

/// Hover and press change only paint; keyboard selection and list layout stay immediate.
private struct ActivityRowStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(isHovered ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : WeaveMotion.hover, value: isHovered)
            .animation(isHovered && !reduceMotion ? WeaveMotion.feedback : nil, value: configuration.isPressed)
    }
}

private extension EventKind {
    var title: String { switch self { case .info: "信息"; case .success: "完成"; case .warning: "注意"; case .error: "失败" } }
    var symbol: String { switch self { case .info: "info.circle"; case .success: "checkmark.circle"; case .warning: "exclamationmark.triangle"; case .error: "xmark.circle" } }
    var color: Color { switch self { case .info: WeaveStyle.accent; case .success: WeaveStyle.accent; case .warning: .orange; case .error: .red } }
}
