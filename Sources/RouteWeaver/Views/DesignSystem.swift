import SwiftUI
import AppKit
import RouteCore

// System materials, typography and controls carry the interface; color only
// identifies a route direction or a state which also has a text label.
enum WeaveStyle {
    static let accent = Color(red: 0.43, green: 0.67, blue: 1.0)
    static let blue = Color(red: 0.63, green: 0.55, blue: 1.0)
    static let background = Color(red: 0.035, green: 0.045, blue: 0.070)
    static let surface = Color(red: 0.070, green: 0.085, blue: 0.115)
    static let sidebar = Color(red: 0.050, green: 0.064, blue: 0.090)
    static let stroke = Color.white.opacity(0.085)
    static let pageWidth: CGFloat = 1120
    static let pageInset: CGFloat = 28
    static let sectionGap: CGFloat = 18
}

struct WeaveCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WeaveStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WeaveStyle.stroke))
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
}

struct StatusBadge: View {
    let text: String
    var color: Color = WeaveStyle.accent
    var body: some View {
        Label { Text(text).font(.caption.weight(.medium)) } icon: {
            Circle().fill(color).frame(width: 6, height: 6)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }
}

struct PageHeading: View {
    var eyebrow: String = ""
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.6)
                Spacer(minLength: 8)
                if !eyebrow.isEmpty {
                    Text(eyebrow).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.1).foregroundStyle(.tertiary)
                }
            }
            if !subtitle.isEmpty { Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct InlineNotice: View {
    let title: String
    let symbol: String
    var color: Color = .orange
    var body: some View {
        Label { Text(title).font(.callout).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension RuleAction {
    var displayName: String { self == .direct ? "本地直连" : "通过出口节点" }
    var symbol: String { self == .direct ? "arrow.up.right" : "network" }
    var tint: Color { self == .direct ? WeaveStyle.accent : WeaveStyle.blue }
}

extension ConnectionPresentation.Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .success: return WeaveStyle.accent
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct ConnectionActionButton: View {
    let action: ConnectionPresentation.Action
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(action.title) {
            if action == .openTailscale { AppNavigation.openTailscale() }
            else if action == .reviewRules {
                store.selection = .rules
                AppNavigation.revealMainWindow(openWindow: openWindow)
            }
            else { Task { await AppNavigation.perform(action, store: store) } }
        }
        .disabled(store.isBusy)
    }
}

@MainActor
enum AppNavigation {
    static func revealMainWindow(openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        // This application has a single main-window role; panels are transient.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
    }
    static func perform(_ action: ConnectionPresentation.Action, store: AppStore) async {
        switch action {
        case .installService, .repairService: await store.repairService()
        case .retryConnection: await store.refresh()
        case .applyChanges: await store.apply()
        case .retryStop: await store.rollback()
        case .reviewRules: store.selection = .rules
        case .openTailscale: openTailscale()
        }
    }
    static func openTailscale() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") ??
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            let url = URL(fileURLWithPath: "/Applications/Tailscale.app")
            if FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        }
    }
}

// Shared timing stays local to controls; navigation and list changes remain instant.
enum WeaveMotion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let feedback = Animation.easeOut(duration: 0.16)
}

struct WeaveActionStyle: ButtonStyle {
    var prominent = false
    var tint: Color = WeaveStyle.accent
    func makeBody(configuration: Configuration) -> some View {
        WeaveActionBody(label: configuration.label, isPressed: configuration.isPressed, prominent: prominent, tint: tint)
    }
}

private struct WeaveActionBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let prominent: Bool
    let tint: Color
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var highlighted: Bool { hovered && enabled }
    var body: some View {
        label.font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(prominent ? WeaveStyle.background : tint)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(prominent ? tint.opacity(isPressed ? 0.74 : highlighted ? 1 : 0.9) : tint.opacity(isPressed ? 0.18 : highlighted ? 0.12 : 0.065), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prominent ? .clear : tint.opacity(highlighted ? 0.25 : 0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.40)
            .animation(reduceMotion ? nil : WeaveMotion.hover, value: hovered)
            .animation(highlighted && !reduceMotion ? WeaveMotion.feedback : nil, value: isPressed)
            .onHover { hovered = $0 }
    }
}

/// For already laid-out navigation rows and compact icon controls.
struct WeaveQuietStyle: ButtonStyle {
    var cornerRadius: CGFloat = 10
    func makeBody(configuration: Configuration) -> some View {
        WeaveQuietBody(label: configuration.label, isPressed: configuration.isPressed, cornerRadius: cornerRadius)
    }
}

private struct WeaveQuietBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let cornerRadius: CGFloat
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        label
            .background(.white.opacity(enabled && hovered ? (isPressed ? 0.065 : 0.035) : 0), in: RoundedRectangle(cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(isPressed && enabled ? 0.82 : 1)
            .scaleEffect(isPressed && hovered && enabled && !reduceMotion ? 0.99 : 1)
            .animation(reduceMotion ? nil : WeaveMotion.hover, value: hovered)
            .animation(hovered && !reduceMotion ? WeaveMotion.feedback : nil, value: isPressed)
            .onHover { hovered = $0 }
    }
}
