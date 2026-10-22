import Foundation
import Darwin
import SystemConfiguration
import RouteIPC

/// Removal is restricted to an audited manifest. Directory descriptors prevent
/// symlink traversal; an unexpected entry makes the operation fail visibly.
final class UninstallDirectory {
    let fd: Int32
    let owner: uid_t
    init(fd: Int32, owner: uid_t) throws {
        self.fd = fd; self.owner = owner
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == owner, info.st_mode & 0o022 == 0 else {
            close(fd); throw HelperError("卸载目录权限不安全")
        }
    }
    deinit { close(fd) }
    static func openSystem(_ path: String) throws -> UninstallDirectory? {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "无法打开系统目录")
        do {
            for component in path.split(separator: "/") {
                let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT { close(fd); return nil }
                try require(next >= 0, "卸载目录链不安全：\(path)")
                close(fd); fd = next
                var info = stat()
                try require(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0, "卸载目录链必须由 root 控制")
            }
        } catch { close(fd); throw error }
        return try UninstallDirectory(fd: fd, owner: 0)
    }
    func entries() throws -> [String] {
        // A fresh description avoids reusing a directory stream's offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try require(copy >= 0, "无法枚举卸载目录")
        guard let stream = fdopendir(copy) else { close(copy); throw HelperError("无法枚举卸载目录") }
        defer { closedir(stream) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            var value = entry.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: value)
            let name = withUnsafePointer(to: &value) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            errno = 0
        }
        try require(errno == 0, "卸载目录枚举失败")
        return result.sorted()
    }
    func validate(_ name: String, socketOwner: uid_t? = nil) throws {
        try require(!name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0), "卸载文件名无效")
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            try require(errno == ENOENT, "无法检查卸载文件：\(name)"); return
        }
        let expectedKind = socketOwner == nil ? S_IFREG : S_IFSOCK
        try require(info.st_mode & S_IFMT == expectedKind && info.st_uid == (socketOwner ?? owner) &&
                    info.st_nlink == 1 && info.st_mode & 0o022 == 0,
                    "拒绝删除归属或类型异常的文件：\(name)")
    }
    func remove(_ name: String, socketOwner: uid_t? = nil) throws {
        try validate(name, socketOwner: socketOwner)
        if unlinkat(fd, name, 0) != 0 { try require(errno == ENOENT, "无法删除：\(name)") }
        var info = stat()
        try require(fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT, "卸载后文件仍存在：\(name)")
    }
    func auditedEntries(allowed: (String) -> Bool) throws -> [String] {
        let names = try entries()
        for name in names {
            try require(allowed(name), "检测到未知文件，已保留并停止清理：\(name)")
            try validate(name)
        }
        return names
    }
    func removeChildDirectory(_ name: String, child: UninstallDirectory) throws {
        var expected = stat(), current = stat()
        try require(fstat(child.fd, &expected) == 0 && fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
                    expected.st_dev == current.st_dev && expected.st_ino == current.st_ino && current.st_mode & S_IFMT == S_IFDIR,
                    "卸载目录在清理过程中发生变化")
        try require(unlinkat(fd, name, AT_REMOVEDIR) == 0, "卸载目录仍有残留：\(name)")
    }
}

enum ServiceUninstaller {
    static func isStateFile(_ name: String, routes: Bool) -> Bool {
        if (routes ? ["journal.json", "lock"] : ["identity.json", "policy.json"]).contains(name) { return true }
        let prefix = routes ? "journal-" : "policy-"
        if name.hasPrefix(prefix), name.hasSuffix(".tmp"), UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil { return true }
        if !routes, name.hasPrefix("identity.json."), UUID(uuidString: String(name.dropFirst("identity.json.".count))) != nil { return true }
        return false
    }
    static func uninstall() throws -> Report {
        try ServiceInstaller.withLifecycleLock { try uninstallLocked() }
    }
    private static func uninstallLocked() throws -> Report {
        try require(geteuid() == 0, "卸载后台服务需要系统管理员授权")
        let socketOwner = try (try? ServiceConfiguration.load().ownerUID) ?? consoleUID()
        try ServiceInstaller.stopService()
        // Return from this scope before removing the journal/lock files.
        let report = try restoreRoutes()
        try verifyNetworkCleanup()
        try removeFiles(socketOwner: socketOwner)
        try verifyNetworkCleanup()
        var result = report
        result.verified = true
        result.message = "后台服务、通信套接字、路由恢复记录及策略文件已卸载，网络清理已核验。"
        return result
    }
    private static func restoreRoutes() throws -> Report {
        let engine = try Engine()
        let result = try engine.rollback()
        try require(result.verified && result.failed == 0 && result.active == 0 && result.pending == 0,
                    "路由尚未全部撤销，保留恢复日志和服务文件")
        return result
    }
    private static func verifyNetworkCleanup() throws {
        try require(ScopedDNSSystemVerifier(timeout: 5).waitUntilWithdrawn(port: ScopedDNSController.port), "系统仍引用本应用 DNS，保留卸载状态以便重试")
        guard let store = SCDynamicStoreCreate(nil, "RouteWeaver.uninstall" as CFString, nil, nil) else { throw HelperError("无法核验系统 DNS") }
        try require(SCDynamicStoreCopyValue(store, ScopedDNSController.storeKey as CFString) == nil, "本应用 DNS 注册项尚未撤销")
        let snapshot = try RouteTable.snapshot()
        try require(snapshot.allSatisfy { $0.flags & routeOwnershipFlags != routeOwnershipFlags }, "仍有本应用标记的路由，保留恢复文件")
        try verifyTCPListenerAbsent()
        // UDP has no TIME_WAIT state; exclusive binding proves the endpoint
        // is free without confusing recently closed TCP connections for listeners.
        for kind in [SOCK_DGRAM] {
            let fd = socket(AF_INET, kind, 0)
            try require(fd >= 0, "无法核验 DNS 监听端口")
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = ScopedDNSController.port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try require(result == 0, "本机 DNS 端口仍被占用，未确认完整卸载")
        }
    }
    private static func verifyTCPListenerAbsent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-iTCP@127.0.0.1:\(ScopedDNSController.port)", "-sTCP:LISTEN", "-F", "p"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 5) == .timedOut {
            process.terminate(); throw HelperError("DNS 监听核验超时，未确认完整卸载")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        try require(process.terminationStatus == 1 && data.isEmpty && errorData.isEmpty,
                    "DNS TCP 监听仍存在或无法完成核验，未确认完整卸载")
    }
    private static func removeFiles(socketOwner: uid_t) throws {
        let helper = try UninstallDirectory.openSystem("/Library/PrivilegedHelperTools")
        let daemons = try UninstallDirectory.openSystem("/Library/LaunchDaemons")
        let database = try UninstallDirectory.openSystem("/private/var/db")
        let service = try UninstallDirectory.openSystem(ServicePaths.directory)
        let routes = try UninstallDirectory.openSystem("/private/var/db/com.routeweaver.routes")
        let serviceNames = try service?.auditedEntries { isStateFile($0, routes: false) } ?? []
        let routeNames = try routes?.auditedEntries { isStateFile($0, routes: true) } ?? []
        let stagedHelpers = try helper?.entries().filter {
            $0.hasPrefix(".routeweaver-") && UUID(uuidString: String($0.dropFirst(".routeweaver-".count))) != nil
        } ?? []
        let stagedDaemons = try daemons?.entries().filter {
            $0.hasPrefix("com.routeweaver.helper.plist.") && UUID(uuidString: String($0.dropFirst("com.routeweaver.helper.plist.".count))) != nil
        } ?? []
        for name in stagedHelpers { try helper?.validate(name) }
        for name in stagedDaemons { try daemons?.validate(name) }
        try helper?.validate("com.routeweaver.helper")
        try helper?.validate("com.routeweaver.control.sock", socketOwner: socketOwner)
        try daemons?.validate("com.routeweaver.helper.plist")
        // Audit every entry before deleting any file; failures preserve the
        // installed helper and its recovery data for diagnosis and retry.
        for name in stagedHelpers { try helper?.remove(name) }
        for name in stagedDaemons { try daemons?.remove(name) }
        for name in routeNames { try routes?.remove(name) }
        for name in serviceNames { try service?.remove(name) }
        if let routes { try database?.removeChildDirectory("com.routeweaver.routes", child: routes) }
        if let service { try database?.removeChildDirectory("com.routeweaver.service", child: service) }
        try helper?.remove("com.routeweaver.control.sock", socketOwner: socketOwner)
        try daemons?.remove("com.routeweaver.helper.plist")
        try helper?.remove("com.routeweaver.helper")
        for path in [ServicePaths.executable, ServicePaths.launchDaemon, ServicePaths.socket, ServicePaths.directory, "/private/var/db/com.routeweaver.routes"] {
            var info = stat()
            try require(lstat(path, &info) != 0 && errno == ENOENT, "卸载后仍有残留：\(path)")
        }
    }
}
