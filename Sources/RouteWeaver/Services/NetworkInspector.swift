import Foundation
import RouteCore

enum NetworkInspector {
    static let cliPaths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    static func inspect() async -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        if let table = try? await CommandRunner.run("/usr/sbin/netstat", ["-rnf", "inet"]), table.status == 0 {
            for line in table.output.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 4, fields[0] == "default", fields[3].hasPrefix("en"), IPv4CIDR.parseAddress(fields[1]) != nil else { continue }
                snapshot.gateway = fields[1]
                snapshot.interface = fields[3]
                break
            }
        }
        guard let cli = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            snapshot.detail = "未找到 Tailscale。请安装官方 macOS 客户端，连接并选择一个 exit node。"
            return snapshot
        }
        snapshot.tailscaleInstalled = true
        do {
            let result = try await CommandRunner.run(cli, ["status", "--json"])
            guard result.status == 0, let data = result.output.data(using: .utf8) else {
                snapshot.detail = "暂时无法读取 Tailscale 状态。请打开客户端并登录。"
                return snapshot
            }
            guard result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
                snapshot.detail = "Tailscale CLI 未返回状态数据。请打开 Tailscale 后重试：\(result.output.prefix(180).trimmingCharacters(in: .whitespacesAndNewlines))"
                return snapshot
            }
            let status = try JSONDecoder().decode(TailscaleStatus.self, from: data)
            snapshot.tailscaleRunning = status.BackendState == "Running"
            snapshot.exitNodeID = status.ExitNodeStatus?.ID
            snapshot.exitNodeOnline = status.ExitNodeStatus?.Online ?? false
            if let id = snapshot.exitNodeID {
                let peer = status.Peer?.values.first(where: { $0.ID == id })
                snapshot.exitNodeName = peer?.HostName ?? peer?.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? id
            }
            if !snapshot.tailscaleRunning { snapshot.detail = "Tailscale 尚未连接。请在 Tailscale 中完成连接。" }
            else if snapshot.exitNodeID == nil { snapshot.detail = "Tailscale 已连接。请选择一个 exit node，之后即可应用国内直连规则。" }
            else if !snapshot.exitNodeOnline { snapshot.detail = "所选 exit node 当前离线。暂不允许应用分流规则。" }
            else if snapshot.gateway == nil { snapshot.detail = "未找到 Wi-Fi 或以太网的 IPv4 网关。请检查网络连接。" }
            else { snapshot.detail = "Exit node 已就绪。应用后，中国大陆 IPv4 网段将通过本地网关直连。" }
        } catch {
            snapshot.detail = "Tailscale 状态读取失败：\(error.localizedDescription)"
        }
        return snapshot
    }

    private struct TailscaleStatus: Decodable {
        var BackendState: String?
        var ExitNodeStatus: ExitStatus?
        var Peer: [String: PeerStatus]?
    }
    private struct ExitStatus: Decodable { var ID: String; var Online: Bool }
    private struct PeerStatus: Decodable { var ID: String?; var HostName: String?; var DNSName: String? }
}
