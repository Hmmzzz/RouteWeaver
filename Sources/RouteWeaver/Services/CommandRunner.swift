import Foundation
import Darwin

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let errorOutput: String
}

struct CommandTimeout: LocalizedError {
    var errorDescription: String? { "操作超时，执行结果尚未确认。若已开始路由操作，请检查活动记录并使用撤销恢复。" }
}

enum CommandRunner {
    /// Output goes to private files instead of pipes: a grandchild retaining a
    /// pipe must not hold the application past its timeout. Commands are fixed
    /// executable paths, never shell fragments supplied by rules.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8) async throws -> CommandResult {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routeweaver-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let stdout = directory.appendingPathComponent("stdout")
            let stderr = directory.appendingPathComponent("stderr")
            for path in [stdout, stderr] {
                guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw AppFailure("无法创建命令输出文件。") }
            }
            let out = try FileHandle(forWritingTo: stdout)
            let err = try FileHandle(forWritingTo: stderr)
            defer { try? out.close(); try? err.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TAILSCALE_BE_CLI": "1"]
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            var timedOut = false
            var oversized = false
            while process.isRunning {
                if ContinuousClock.now >= deadline { timedOut = true; break }
                let size = try [stdout, stderr].reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                if size > 32 * 1024 * 1024 { oversized = true; break }
                usleep(20_000)
            }
            if timedOut || oversized {
                process.terminate()
                let stopDeadline = ContinuousClock.now.advanced(by: .milliseconds(200))
                while process.isRunning && ContinuousClock.now < stopDeadline { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // Do not infer that privileged descendants stopped; journal
                // recovery, not parent process termination, determines state.
                if oversized { throw AppFailure("命令输出超过 32 MiB，操作结果需重新检查。") }
                throw CommandTimeout()
            }
            process.waitUntilExit()
            let outSize = try stdout.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let errSize = try stderr.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard outSize + errSize <= 32 * 1024 * 1024 else { throw AppFailure("命令输出过大。") }
            return CommandResult(status: process.terminationStatus,
                output: String(decoding: try Data(contentsOf: stdout), as: UTF8.self),
                errorOutput: String(decoding: try Data(contentsOf: stderr), as: UTF8.self))
        }.value
    }
}
