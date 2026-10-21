import Foundation
import Darwin
import RouteIPC

/// Only called by the explicitly authorized bundled helper; no privileged action is exposed over IPC.
enum ServiceInstaller {
    static func install(appBundlePath: String) throws -> String {
        try require(geteuid() == 0, "安装后台服务需要系统管理员授权")
        let app = URL(fileURLWithPath: appBundlePath).standardizedFileURL.path
        try require(app == appBundlePath && app.hasSuffix(".app") && app.hasPrefix("/") && !app.utf8.contains(0), "应用安装来源无效")
        var console = stat()
        try require(stat("/dev/console", &console) == 0 && console.st_uid >= 500, "请从当前登录用户的应用安装服务")
        let owner = console.st_uid
        let executable = app + "/Contents/MacOS/RouteWeaver"
        let helper = app + "/Contents/Helpers/RouteWeaverHelper"
        try validateUserExecutable(executable, owner: owner)
        try validateUserExecutable(helper, owner: owner)
        // Pin the exact authorized build. Ad-hoc signatures work without distributing a developer key.
        let appHash = try ServiceIdentity.staticHash(path: executable)
        let helperHash = try ServiceIdentity.staticHash(path: helper)
        let runningPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let runningHash = try ServiceIdentity.staticHash(path: runningPath)
        try require(runningHash == helperHash, "安装器与应用内后台程序不匹配")
        try secureDirectory("/Library/PrivilegedHelperTools", mode: 0o755)
        try secureDirectory("/Library/LaunchDaemons", mode: 0o755)
        try secureDirectory(ServicePaths.directory, mode: 0o700)
        let staged = "/Library/PrivilegedHelperTools/.routeweaver-" + UUID().uuidString
        defer { unlink(staged) }
        try copyExecutable(helper, to: staged, owner: owner)
        let stagedHash = try ServiceIdentity.staticHash(path: staged)
        try require(stagedHash == helperHash, "复制后的后台程序签名不匹配")
        let config = ServiceConfiguration(ownerUID: owner, appCodeHash: appHash, helperCodeHash: stagedHash)
        // Prepare all data before touching an existing service.
        let configData = try JSONEncoder().encode(config)
        let plist: [String: Any] = [
            "Label": ServicePaths.label,
            "ProgramArguments": [ServicePaths.executable, "serve"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "UserName": "root",
            "GroupName": "wheel",
            "Umask": 0o077,
            "ExitTimeOut": 30
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try stopService()
        try require(rename(staged, ServicePaths.executable) == 0, "无法安装后台程序")
        try atomicWrite(configData, path: ServicePaths.configuration, mode: 0o600)
        try atomicWrite(plistData, path: ServicePaths.launchDaemon, mode: 0o644)
        try runLaunchctl(["bootstrap", "system", ServicePaths.launchDaemon], requireSuccess: true)
        return "后台服务已安装并由系统启动；今后应用路由无需重复授权。"
    }
    static func stopService() throws {
        try require(geteuid() == 0, "停止后台服务需要系统管理员授权")
        try stopLaunchDaemon()
        // launchctl removal can precede process teardown. Wait until its journal flock is released.
        let lock = open("/private/var/db/com.routeweaver.routes/lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if lock < 0 { try require(errno == ENOENT, "无法检查后台服务操作锁"); return }
        defer { close(lock) }
        var info = stat()
        try require(fstat(lock, &info) == 0 && info.st_uid == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_mode & 0o077 == 0, "服务操作锁不安全")
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            try require(errno == EWOULDBLOCK || errno == EAGAIN, "无法检查后台服务退出状态")
            try require(DispatchTime.now().uptimeNanoseconds < deadline, "后台服务尚未退出；未替换或删除文件")
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = flock(lock, LOCK_UN)
    }
    private static func stopLaunchDaemon() throws {
        let label = "system/" + ServicePaths.label
        let before = try runLaunchctl(["print", label], requireSuccess: false)
        if before == 113 { return } // launchctl's explicit service-not-found status.
        try require(before == 0, "无法核验已有后台服务；未修改安装")
        let result = try runLaunchctl(["bootout", label], requireSuccess: false)
        var after = try runLaunchctl(["print", label], requireSuccess: false)
        // bootout can succeed before launchd removes the service registration.
        // Keep the same fail-closed check, but allow its asynchronous teardown.
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while after == 0 && DispatchTime.now().uptimeNanoseconds < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            after = try runLaunchctl(["print", label], requireSuccess: false)
        }
        try require(after == 113, "系统尚未卸载旧后台服务（bootout \(result)）；未替换文件")
    }
    static func uninstallFiles() throws {
        try require(geteuid() == 0, "移除后台服务需要系统管理员授权")
        try stopLaunchDaemon()
        for path in [ServicePaths.launchDaemon, ServicePaths.executable, ServicePaths.configuration, ServicePaths.directory + "/policy.json"] {
            var st = stat()
            if lstat(path, &st) == 0 {
                try require(st.st_uid == 0 && st.st_mode & S_IFMT == S_IFREG, "拒绝删除未知服务文件")
                try require(unlink(path) == 0, "无法移除服务文件")
            } else { try require(errno == ENOENT, "无法检查服务文件") }
        }
        var st = stat()
        if lstat(ServicePaths.socket, &st) == 0 {
            try require(st.st_mode & S_IFMT == S_IFSOCK, "服务地址不是套接字")
            try require(unlink(ServicePaths.socket) == 0, "无法移除服务地址")
        }
        _ = rmdir(ServicePaths.directory) // Unknown files are intentionally retained.
    }
    private static func validateUserExecutable(_ path: String, owner: uid_t) throws {
        var st = stat()
        try require(lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_uid == owner && st.st_nlink == 1 && st.st_mode & 0o022 == 0 && st.st_size > 0 && st.st_size < 100_000_000, "应用程序文件权限或所有者无效")
    }
    private static func secureDirectory(_ path: String, mode: mode_t) throws {
        // Every component must be a real root-owned directory, never a symlink or writable parent.
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var st = stat()
            if lstat(prefix, &st) != 0 {
                try require(errno == ENOENT && prefix == path && mkdir(prefix, mode) == 0, "无法创建系统服务目录")
                try require(chown(prefix, 0, 0) == 0 && chmod(prefix, mode) == 0 && lstat(prefix, &st) == 0, "无法保护系统服务目录")
            }
            try require(st.st_mode & S_IFMT == S_IFDIR && st.st_uid == 0 && st.st_mode & 0o022 == 0, "系统服务目录权限不安全")
        }
        if path == ServicePaths.directory { try require(chmod(path, mode) == 0, "无法保护服务配置目录") }
    }
    private static func copyExecutable(_ source: String, to destination: String, owner: uid_t) throws {
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        try require(input >= 0, "无法打开后台程序")
        defer { close(input) }
        var st = stat()
        try require(fstat(input, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_uid == owner && st.st_nlink == 1 && st.st_mode & 0o022 == 0 && st.st_size > 0 && st.st_size < 100_000_000, "后台程序文件不安全")
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        try require(output >= 0, "无法创建受保护的后台程序")
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var total = 0
        while true {
            let n = Darwin.read(input, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            try require(n >= 0, "后台程序读取失败")
            if n == 0 { break }
            total += n
            try require(total <= 100_000_000, "后台程序大小超出限制")
            try buffer.withUnsafeBytes { raw in try writeAll(output, bytes: raw.baseAddress!, count: n) }
        }
        try require(total == st.st_size && fchown(output, 0, 0) == 0 && fchmod(output, 0o755) == 0 && fsync(output) == 0, "后台程序复制未完成")
    }
    private static func atomicWrite(_ data: Data, path: String, mode: mode_t) throws {
        let temporary = path + "." + UUID().uuidString
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        try require(fd >= 0, "无法写入服务配置")
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { raw in try writeAll(fd, bytes: raw.baseAddress!, count: raw.count) }
        try require(fchown(fd, 0, 0) == 0 && fchmod(fd, mode) == 0 && fsync(fd) == 0 && rename(temporary, path) == 0, "无法保存服务配置")
    }
    private static func writeAll(_ fd: Int32, bytes: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, bytes.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            try require(n > 0, "服务文件写入失败")
            offset += n
        }
    }
    @discardableResult private static func runLaunchctl(_ arguments: [String], requireSuccess: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            throw HelperError("系统服务管理操作超时")
        }
        if requireSuccess { try require(process.terminationStatus == 0, "系统未能启动后台服务（launchctl \(process.terminationStatus)）") }
        return process.terminationStatus
    }
}
