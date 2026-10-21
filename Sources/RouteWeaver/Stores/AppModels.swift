import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case overview, rules, activity, settings
    var id: String { rawValue }
    var title: String { switch self { case .overview: "连接"; case .rules: "分流规则"; case .activity: "活动记录"; case .settings: "设置" } }
    var symbol: String { switch self { case .overview: "square.grid.2x2"; case .rules: "arrow.triangle.branch"; case .activity: "clock.arrow.circlepath"; case .settings: "gearshape" } }
}

struct NetworkSnapshot: Equatable, Sendable {
    var tailscaleInstalled = false
    var tailscaleRunning = false
    var exitNodeID: String?
    var exitNodeName: String?
    var exitNodeOnline = false
    var gateway: String?
    var interface: String?
    var detail = "正在读取本机网络状态…"
    var ready: Bool { tailscaleRunning && exitNodeID != nil && exitNodeOnline && gateway != nil && interface != nil }
}

enum EventKind: String, Codable, Sendable { case info, success, warning, error }

struct ActivityEvent: Identifiable, Codable, Sendable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
    var kind: EventKind
}

struct AppFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
