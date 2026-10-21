import Foundation

/// A presentation-only projection of the last service observation. It never
/// infers a live route from a saved profile or from the user's switch intent.
struct ConnectionPresentation: Equatable, Sendable {
    enum Kind: String, Sendable {
        case checking, notInstalled, off, waitingNetwork, preparing, applying, on, stopping, recovering, unavailable
    }
    enum Tone: String, Sendable { case neutral, success, warning, error }
    enum Action: String, Sendable {
        case installService, repairService, retryConnection, openTailscale, applyChanges, retryStop, reviewRules
        var title: String {
            switch self {
            case .installService: "安装后台服务"
            case .repairService: "修复后台服务"
            case .retryConnection: "重新检查"
            case .openTailscale: "打开 Tailscale"
            case .applyChanges: "应用修改"
            case .retryStop: "重试关闭分流"
            case .reviewRules: "查看规则"
            }
        }
    }
    let kind: Kind
    let title: String
    let detail: String
    let symbol: String
    let tone: Tone
    var isTransitioning = false
    var primaryAction: Action?
    var secondaryAction: Action?

    static func make(_ state: ConnectionState) -> Self {
        if state.operation == .repairing {
            return .init(kind: .preparing, title: "正在准备后台服务", detail: "请在 macOS 授权窗口完成操作。连接验证通过后即可使用。", symbol: "gearshape.2", tone: .neutral, isTransitioning: true)
        }
        if state.operation == .applying {
            return .init(kind: .applying, title: "正在提交分流规则", detail: "正在核验连接并提交规则，完成后由后台确认实际路由。", symbol: "arrow.triangle.branch", tone: .neutral, isTransitioning: true)
        }
        if state.operation == .stopping {
            return .init(kind: .stopping, title: "正在关闭分流", detail: "正在停止自动恢复并撤销本应用的路由。", symbol: "arrow.uturn.backward", tone: .neutral, isTransitioning: true)
        }
        guard state.checked else {
            return .init(kind: .checking, title: "正在检查分流状态", detail: "读取本机连接和后台服务的实际状态。", symbol: "ellipsis.circle", tone: .neutral, isTransitioning: true)
        }
        guard state.reachable else {
            if !state.installed {
                return .init(kind: .notInstalled, title: "需要安装后台服务", detail: "首次启用需要 macOS 管理员授权。安装后，后台会自动处理网络变化。", symbol: "gearshape.badge.checkmark", tone: .neutral, primaryAction: .installService)
            }
            return .init(kind: .unavailable, title: "无法确认分流状态", detail: "后台服务暂时无法连接，已有路由可能仍在运行。可先重新检查；更新应用后需要修复服务。", symbol: "exclamationmark.triangle", tone: .error, primaryAction: .retryConnection, secondaryAction: .repairService)
        }
        if state.phase == "removing" {
            return .init(kind: .stopping, title: state.enabled ? "正在切换网络" : "正在关闭分流", detail: state.enabled ? "先清理旧网络的路由，待连接稳定后自动恢复。" : "正在撤销本应用的路由，完成后恢复原有流量去向。", symbol: "arrow.triangle.2.circlepath", tone: .neutral, isTransitioning: true)
        }
        if state.phase == "backingOff" || state.failed > 0 || (!state.enabled && (state.active > 0 || state.pending > 0)) {
            return .init(kind: .recovering, title: state.enabled ? "分流正在恢复" : "仍有路由需要清理", detail: state.enabled ? "后台会自动重试。你也可以关闭分流，停止恢复并清理路由。" : "自动恢复已关闭，但清理尚未完成。重试关闭分流不会添加新路由。", symbol: "exclamationmark.arrow.triangle.2.circlepath", tone: .warning, primaryAction: state.enabled ? .retryConnection : .retryStop, secondaryAction: state.enabled ? .retryStop : nil)
        }
        if !state.enabled && state.phase == "disabled" && state.active == 0 && state.pending == 0 && state.verified {
            return .init(kind: .off, title: "分流已关闭", detail: state.networkReady ? "连接已就绪。开启后，中国大陆 IPv4 直连，其他流量沿用出口节点。" : "当前沿用系统与 Tailscale 原有路由。连接出口节点后即可开启分流。", symbol: "power", tone: .neutral, primaryAction: state.networkReady ? nil : .openTailscale)
        }
        if state.enabled {
            switch state.phase {
            case "waitingNetwork":
                return .init(kind: .waitingNetwork, title: "等待网络连接", detail: "分流保持开启。连接可用的物理网络和在线出口节点后，后台会自动恢复。", symbol: "network", tone: .warning, primaryAction: state.networkReady ? .retryConnection : .openTailscale)
            case "stabilizing":
                return .init(kind: .preparing, title: "正在准备分流", detail: "等待网络稳定并核验出口连接，随后自动应用规则。", symbol: "network", tone: .neutral, isTransitioning: true)
            case "applying":
                return .init(kind: .applying, title: "正在应用分流规则", detail: "后台正在写入并核验路由，完成后会显示实际直连数量。", symbol: "arrow.triangle.branch", tone: .neutral, isTransitioning: true)
            case "active" where state.verified && state.pending == 0:
                if state.skipped > 0 {
                    return .init(kind: .on, title: "分流已启用 · 部分规则跳过", detail: "\(state.active.formatted()) 条直连路由已核验；保留了 \(state.skipped.formatted()) 条同前缀现有路由。", symbol: "checkmark.shield", tone: .warning, primaryAction: .reviewRules)
                }
                guard state.active > 0 else { break }
                return .init(kind: .on, title: "分流已启用", detail: "\(state.active.formatted()) 条直连路由已核验。网络变化时，后台会自动恢复。", symbol: "checkmark.shield.fill", tone: .success, primaryAction: state.hasUnappliedChanges ? .applyChanges : nil)
            case "active":
                return .init(kind: .recovering, title: "正在核验分流", detail: "尚未确认所有路由的实际状态。请重新检查或关闭分流后恢复。", symbol: "exclamationmark.shield", tone: .warning, primaryAction: .retryConnection, secondaryAction: .retryStop)
            default: break
            }
        }
        return .init(kind: .unavailable, title: "后台状态待确认", detail: "服务尚未返回可确认的分流状态，请重新检查。", symbol: "questionmark.circle", tone: .warning, primaryAction: .retryConnection, secondaryAction: .repairService)
    }
}

enum AppOperation: String, Sendable {
    case applying, stopping, repairing, updatingDataset
}

struct ConnectionState: Equatable, Sendable {
    var checked = false
    var reachable = false
    var installed = false
    var networkReady = false
    var enabled = false
    var phase = ""
    var verified = false
    var active = 0
    var pending = 0
    var failed = 0
    var skipped = 0
    var hasUnappliedChanges = false
    var operation: AppOperation?
}
