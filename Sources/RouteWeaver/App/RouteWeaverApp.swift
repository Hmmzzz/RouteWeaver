import SwiftUI
import AppKit
import RouteIPC

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    private var terminationPending = false

    // Closing the last window keeps the menu-bar session alive without a Dock icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        sender.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        let store = self.store ?? AppStore(loadPersistedState: false)
        terminationPending = true
        Task { @MainActor in
            let cleaned = await store.prepareForTermination()
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: cleaned)
            if !cleaned {
                sender.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "网络恢复尚未完成，已取消退出"
                alert.informativeText = store.lastError ?? "请检查后台服务后重试退出。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct RouteWeaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store: AppStore
    @State private var traffic: TrafficMonitor

    init() {
        // Diagnostic client uses the same signed executable and authorization as the UI.
        let args = CommandLine.arguments
        if args.count >= 2 && args[1] == "--service-session" {
            do {
                guard args.count == 2 else { throw IPCError("会话模式不接受额外参数") }
                try ServiceDiagnosticSession.runStandardIO()
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(2) }
        }
        if args.count >= 2 && args[1] == "--service-command" {
            do {
                guard args.count == 3, let data = Data(base64Encoded: args[2]) else { throw IPCError("无效的服务请求") }
                let request = try JSONDecoder().decode(ServiceRequest.self, from: data)
                let response = try RouteIPCClient.send(request, timeout: 120)
                print(String(decoding: try JSONEncoder().encode(response), as: UTF8.self))
                exit(response.failed == 0 ? 0 : 1)
            } catch { fputs("\(error)\n", stderr); exit(2) }
        }
        // Diagnostics must not load or write the interactive user's profile.
        _store = State(initialValue: AppStore())
        _traffic = State(initialValue: TrafficMonitor())
    }

    var body: some Scene {
        WindowGroup("RouteWeaver", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 960, minHeight: 650)
                .task { delegate.store = store; store.startup(); traffic.start(store: store) }
        }
        .defaultSize(width: 1180, height: 860)
        .windowToolbarStyle(.unified)
        .commands { RouteWeaverCommands(store: store) }
        MenuBarExtra {
            StatusPopover(store: store, traffic: traffic)
        } label: {
            MenuBarTrafficLabel(traffic: traffic)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct RouteWeaverCommands: Commands {
    let store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) { }
        CommandGroup(replacing: .appSettings) {
            Button("设置") { show(.settings) }.keyboardShortcut(",")
        }
        CommandMenu("分流") {
            Button(store.serviceEnabled ? "关闭分流" : "开启分流") {
                Task { await store.setRoutingEnabled(!store.serviceEnabled) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!store.canToggleRouting)
            Button("应用规则更改") { Task { await store.apply() } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(!store.canApply)
            Button("清理本应用路由") { Task { await store.rollback() } }
                .disabled(!store.canStop)
            Divider()
            Button("打开 Tailscale") { AppNavigation.openTailscale() }
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Button("连接") { show(.overview) }.keyboardShortcut("1")
            Button("分流规则") { show(.rules) }.keyboardShortcut("2")
            Button("活动记录") { show(.activity) }.keyboardShortcut("3")
            Button("设置") { show(.settings) }.keyboardShortcut("4")
        }
    }
    private func show(_ section: AppSection) {
        store.selection = section
        AppNavigation.revealMainWindow(openWindow: openWindow)
    }
}
