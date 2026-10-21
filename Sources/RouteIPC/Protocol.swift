import Foundation
import Darwin

public enum ServiceCommand: String, Codable, Sendable { case status, attach, apply, stop, stopOwned }
public struct ServiceRequest: Codable, Sendable {
    public var version: Int = 1
    public var command: ServiceCommand
    public var routes: [String]?
    public init(command: ServiceCommand, routes: [String]? = nil) { self.command = command; self.routes = routes }
    public func validate() throws {
        guard version == 1 else { throw IPCError("不支持的服务协议版本") }
        if command == .apply {
            guard let routes, !routes.isEmpty, routes.count <= 20_000,
                  routes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 18 }) else { throw IPCError("路由计划无效或超出限制") }
        } else if routes != nil { throw IPCError("此操作不接受路由计划") }
    }
}
public struct ServiceDetail: Codable, Sendable {
    public var cidr: String; public var action: String; public var result: String
    public init(cidr: String, action: String, result: String) { self.cidr = cidr; self.action = action; self.result = result }
}
public struct ServiceResponse: Codable, Sendable {
    public var version = 1
    public var active = 0; public var pending = 0
    public var added = 0; public var removed = 0; public var skipped = 0; public var failed = 0
    public var durationMilliseconds = 0; public var verified = false
    public var detailsOmitted = 0
    public var message = ""; public var details: [ServiceDetail] = []
    public var enabled = false; public var phase = "idle"
    public var gateway: String?; public var interface: String?; public var exitNodeID: String?
    public var desiredRoutesDigest: String?
    public var dnsActive: Bool?
    public var dnsDomainCount: Int?
    public var dnsMessage: String?
    /// True only after the resolver publication is withdrawn and its listener stopped.
    public var dnsWithdrawn: Bool?
    /// The authenticated requesting process owns this helper session.
    public var sessionAttached: Bool?
    /// Another authenticated GUI owns the live session; a scoped stop is inert.
    public var anotherSessionActive: Bool?
    public init() {}
}
public struct IPCError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}
public enum ServicePaths {
    public static let label = "com.routeweaver.helper"
    public static let executable = "/Library/PrivilegedHelperTools/com.routeweaver.helper"
    public static let launchDaemon = "/Library/LaunchDaemons/com.routeweaver.helper.plist"
    public static let directory = "/private/var/db/com.routeweaver.service"
    public static let configuration = directory + "/identity.json"
    public static let socket = "/Library/PrivilegedHelperTools/com.routeweaver.control.sock"
}

/// One bounded JSON frame per connection. Deadlines include all partial reads/writes.
public enum IPCWire {
    public static let maximumFrame = 1_048_576
    public static func prepare(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw IPCError("无法配置服务连接") }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    public static func deadline(after seconds: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0.01, min(seconds, 300)) * 1_000_000_000)
    }
    public static func wait(_ fd: Int32, event: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw IPCError("后台服务响应超时") }
            var p = pollfd(fd: fd, events: event, revents: 0)
            let ms = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
            let result = poll(&p, 1, ms)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw IPCError("后台服务响应超时或连接失效") }
            if p.revents & event != 0 { return }
            throw IPCError("后台服务连接已关闭")
        }
    }
    private static func receive(_ count: Int, fd: Int32, until deadline: UInt64) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                try wait(fd, event: Int16(POLLIN), until: deadline)
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { throw IPCError("服务消息不完整") }
                offset += n
            }
        }
        return data
    }
    public static func readFrame(fd: Int32, until deadline: UInt64) throws -> Data {
        let header = try receive(4, fd: fd, until: deadline)
        let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size > 0, size <= maximumFrame else { throw IPCError("服务消息大小无效") }
        return try receive(Int(size), fd: fd, until: deadline)
    }
    public static func writeFrame(_ data: Data, fd: Int32, until deadline: UInt64) throws {
        guard !data.isEmpty, data.count <= maximumFrame else { throw IPCError("服务消息超出限制") }
        var length = UInt32(data.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(data)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < frame.count {
                try wait(fd, event: Int16(POLLOUT), until: deadline)
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), frame.count - offset)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard n > 0 else { throw IPCError("无法发送服务消息") }
                offset += n
            }
        }
    }
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw IPCError("服务地址无效") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.utf8.enumerated() { raw[i] = byte }
        }
        return address
    }
}

public enum RouteIPCClient {
    public static func send(_ request: ServiceRequest, socketPath: String = ServicePaths.socket, timeout: TimeInterval = 45) throws -> ServiceResponse {
        try request.validate()
        var st = stat()
        guard lstat(socketPath, &st) == 0, st.st_mode & S_IFMT == S_IFSOCK,
              st.st_uid == getuid(), st.st_mode & 0o777 == 0o600 else { throw IPCError("后台服务未安装、未启动或不属于当前用户") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError("无法创建服务连接") }
        defer { close(fd) }
        try IPCWire.prepare(fd)
        let deadline = IPCWire.deadline(after: timeout)
        var address = try IPCWire.address(socketPath)
        let connected = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw IPCError("无法连接后台服务") }
            try IPCWire.wait(fd, event: Int16(POLLOUT), until: deadline)
            var error: Int32 = 0; var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw IPCError("后台服务连接失败") }
        }
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else { throw IPCError("拒绝非系统后台服务") }
        try IPCWire.writeFrame(JSONEncoder().encode(request), fd: fd, until: deadline)
        let result = try JSONDecoder().decode(ServiceResponse.self, from: IPCWire.readFrame(fd: fd, until: deadline))
        guard result.version == 1 else { throw IPCError("后台服务版本不兼容，请重新安装") }
        return result
    }
}
