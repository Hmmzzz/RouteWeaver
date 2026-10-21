import Foundation
import RouteIPC

struct AuthorizationCancelled: Error {}

enum PrivilegedClient {
    static func status() async throws -> ServiceResponse {
        try await send(ServiceRequest(command: .status), timeout: 15)
    }

    static func attachedStatus() async throws -> ServiceResponse {
        let current = try await status()
        guard current.sessionAttached != true else { return current }
        let attached = try await send(ServiceRequest(command: .attach), timeout: 30)
        guard attached.sessionAttached == true, attached.failed == 0 else {
            throw AppFailure(attached.message.isEmpty ? "无法关联应用与后台服务，请更新或修复服务。" : attached.message)
        }
        return attached
    }

    static func stopForExit() async throws -> ServiceResponse {
        try await send(ServiceRequest(command: .stopOwned), timeout: 120)
    }

    static func stop() async throws -> ServiceResponse {
        try await send(ServiceRequest(command: .stop), timeout: 120)
    }

    static func perform(routes: [String]? = nil, network: NetworkSnapshot? = nil) async throws -> ServiceResponse {
        if !FileManager.default.fileExists(atPath: ServicePaths.socket) { try await install() }
        if routes != nil { _ = try await attachedStatus() }
        return try await send(ServiceRequest(command: routes == nil ? .stop : .apply, routes: routes), timeout: 120)
    }

    static func install() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RouteWeaverHelper")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AppFailure("应用缺少后台服务。请重新构建完整应用包。")
        }
        let command = [helper.path, "install-service", Bundle.main.bundlePath].map(shellQuote).joined(separator: " ")
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        let result = try await CommandRunner.run("/usr/bin/osascript", ["-e", script], timeout: 300)
        guard result.status == 0 else {
            if result.errorOutput.contains("-128") { throw AuthorizationCancelled() }
            throw AppFailure("后台服务安装失败：\(result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        for _ in 0..<30 {
            if (try? await status()) != nil { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw AppFailure("安装命令已完成，但尚未确认后台服务可连接。请检查服务状态。")
    }

    private static func send(_ request: ServiceRequest, timeout: TimeInterval) async throws -> ServiceResponse {
        do { return try await Task.detached(priority: .userInitiated) { try RouteIPCClient.send(request, timeout: timeout) }.value }
        catch { throw AppFailure("\(error)；可在设置中安装或修复后台服务。") }
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
