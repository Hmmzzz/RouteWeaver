import Foundation
import Darwin
import RouteCore
import SystemConfiguration

func consoleUID() throws -> uid_t {
    var info = stat()
    try require(stat("/dev/console", &info) == 0 && info.st_uid >= 500, "需要一个已登录的普通 macOS 用户")
    return info.st_uid
}
func readRequestFile(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    try require(fd >= 0, "无法安全打开请求文件")
    defer { close(fd) }
    var info = stat()
    let user = try consoleUID()
    try require(fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == user && info.st_nlink == 1 && info.st_mode & 0o077 == 0, "请求必须是当前用户独占的普通文件（0600）")
    try require(info.st_size > 0 && info.st_size <= 1024 * 1024, "请求文件大小不合法")
    return try readAll(fd, maximum: 1024 * 1024)
}
func validatedRoutes(_ request: ApplyRequest) throws -> [IPv4CIDR] {
    try require(request.routes.count <= 20_000 && !request.routes.isEmpty, "路由数量必须在 1–20,000 之间")
    try require(IPv4CIDR.parseAddress(request.gateway) != nil, "无效的物理网关")
    try require(request.interface.hasPrefix("en") && request.interface.count > 2 && request.interface.count < 16 && request.interface.dropFirst(2).allSatisfy { $0 >= "0" && $0 <= "9" }, "仅支持明确的以太网或 Wi-Fi 物理接口")
    try require(!request.exitNodeID.isEmpty && request.exitNodeID.utf8.count <= 128, "缺少 exit node 身份")
    return try Set(request.routes.map { text in
        let cidr = try IPv4CIDR(text)
        try cidr.validateForBypass()
        try require(!cidr.contains(request.gateway) && !cidr.contains("8.8.8.8"), "路由不得覆盖物理网关或诊断地址")
        return cidr
    }).sorted()
}

/// A private process group includes launchctl/sudo and the actual CLI. Polling
/// both output and cancellation on the worker avoids an orphaned blocking pipe
/// reader when a child inherits stdout or ignores SIGTERM.
func runRecoveryCommand(executable: String, arguments: [String], cancellation: RecoveryCancellation? = nil,
                        timeout: TimeInterval = 8, maximumOutputBytes: Int = 4 * 1024 * 1024) throws -> Data {
    try cancellation?.throwIfCancelled()
    try require(timeout.isFinite && timeout > 0 && maximumOutputBytes > 0, "状态检查参数无效")
    var descriptors: [Int32] = [0, 0]
    try require(pipe(&descriptors) == 0, "无法创建状态输出管道")
    // A launch daemon can start with a standard descriptor closed. Keep pipe
    // descriptors away from 0/1/2 before constructing ordered spawn actions.
    for index in descriptors.indices where descriptors[index] < 3 {
        let replacement = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
        if replacement < 0 { descriptors.forEach { close($0) }; throw HelperError("无法配置状态输出管道") }
        close(descriptors[index]); descriptors[index] = replacement
    }
    let reader = descriptors[0], writer = descriptors[1]
    defer { close(reader) }
    var writerOpen = true
    defer { if writerOpen { close(writer) } }
    try require(fcntl(reader, F_SETFD, FD_CLOEXEC) == 0 && fcntl(writer, F_SETFD, FD_CLOEXEC) == 0 &&
                fcntl(reader, F_SETFL, O_NONBLOCK) == 0, "无法配置状态输出管道")
    var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
    try require(posix_spawn_file_actions_init(&actions) == 0, "无法创建状态检查进程")
    defer { posix_spawn_file_actions_destroy(&actions) }
    try require(posix_spawnattr_init(&attributes) == 0, "无法配置状态检查进程")
    defer { posix_spawnattr_destroy(&attributes) }
    try require(posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO) == 0 &&
                posix_spawn_file_actions_addclose(&actions, reader) == 0 &&
                posix_spawn_file_actions_addclose(&actions, writer) == 0 &&
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0 &&
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0 &&
                // Do not leak the helper's privileged route socket or service
                // descriptors into a third-party CLI, even without FD_CLOEXEC.
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 &&
                posix_spawnattr_setpgroup(&attributes, 0) == 0, "无法隔离状态检查进程")
    let argv = ([executable] + arguments).map { strdup($0) }
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    defer { argv.forEach { free($0) }; environment.forEach { free($0) } }
    var argvPointers = argv + [nil], environmentPointers = environment + [nil]
    var pid: pid_t = 0
    try cancellation?.throwIfCancelled()
    let launched = posix_spawn(&pid, executable, &actions, &attributes, &argvPointers, &environmentPointers)
    try require(launched == 0, "无法启动状态检查：\(String(cString: strerror(launched)))")
    close(writer); writerOpen = false
    // Keep the leader unreaped until cleanup, preventing reuse of the process
    // group identifier while cancellation may still need to kill descendants.
    defer {
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
    var eof = false
    while !eof {
        try cancellation?.throwIfCancelled()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Tailscale 状态查询超时")
        // Bound each read turn so an endless writer cannot starve cancellation.
        let count = read(reader, &buffer, buffer.count)
        if count > 0 {
            try require(data.count <= maximumOutputBytes - count, "Tailscale 状态输出超限")
            data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 { eof = true }
        else if errno != EAGAIN && errno != EINTR { throw HelperError("Tailscale 状态输出读取失败") }
        else {
            var descriptor = pollfd(fd: reader, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 20)
        }
    }
    // stdout may close before the process exits. waitid(WNOWAIT) observes exit
    // without reaping the leader until the process-group cleanup above.
    var info = siginfo_t()
    while true {
        try cancellation?.throwIfCancelled()
        try require(ProcessInfo.processInfo.systemUptime < deadline, "Tailscale 状态查询超时")
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 && info.si_pid == pid { break }
        if result < 0 && errno != EINTR { throw HelperError("无法读取状态检查退出结果") }
        usleep(20_000)
    }
    try require(info.si_code == CLD_EXITED && info.si_status == 0, "Tailscale 状态查询失败")
    return data
}

private func tailscaleStatus(ownerUID user: uid_t, cancellation: RecoveryCancellation? = nil) throws -> [String: Any] {
    let paths = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
    guard let executable = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw HelperError("找不到 Tailscale CLI，无法独立验证 exit node") }
    let command: String, arguments: [String]
    // A read-only preflight runs directly as the logged-in user. An authorized
    // root invocation drops privilege before running third-party CLI code.
    if geteuid() == user {
        command = "/usr/bin/env"
        arguments = ["TAILSCALE_BE_CLI=1", executable, "status", "--json"]
    } else {
        try require(geteuid() == 0, "必须由当前登录用户或已授权的管理员执行检查")
        command = "/bin/launchctl"
        arguments = ["asuser", String(user), "/usr/bin/sudo", "-n", "-u", "#\(user)", "--", "/usr/bin/env", "TAILSCALE_BE_CLI=1", executable, "status", "--json"]
    }
    let output = try runRecoveryCommand(executable: command, arguments: arguments, cancellation: cancellation)
    try cancellation?.throwIfCancelled()
    guard let json = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw HelperError("Tailscale 状态格式无效") }
    return json
}
private func tailscaleInterfaces(_ json: [String: Any]) throws -> Set<String> {
    let selfNode = json["Self"] as? [String: Any]
    let ips = Set((selfNode?["TailscaleIPs"] as? [String] ?? json["TailscaleIPs"] as? [String] ?? []).compactMap(IPv4CIDR.parseAddress))
    var addresses: UnsafeMutablePointer<ifaddrs>?
    try require(getifaddrs(&addresses) == 0, "无法验证 Tailscale 隧道接口")
    defer { freeifaddrs(addresses) }
    var cursor = addresses
    var interfaces = Set<String>()
    while let entry = cursor {
        defer { cursor = entry.pointee.ifa_next }
        guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
        let name = String(cString: entry.pointee.ifa_name)
        if name.hasPrefix("utun") && ips.contains(ip) { interfaces.insert(name) }
    }
    try require(!interfaces.isEmpty, "无法将 Tailscale 身份映射到系统隧道；拒绝猜测其他 VPN 的接口")
    return interfaces
}
func verifyTailscale(_ request: ApplyRequest, cancellation: RecoveryCancellation? = nil) throws -> Set<String> {
    let user = try consoleUID()
    let json = try tailscaleStatus(ownerUID: user, cancellation: cancellation)
    try cancellation?.throwIfCancelled()
    let currentUser = try consoleUID()
    try require(currentUser == user, "当前登录用户已经变化")
    guard json["BackendState"] as? String == "Running",
          let exit = json["ExitNodeStatus"] as? [String: Any],
          exit["ID"] as? String == request.exitNodeID, exit["Online"] as? Bool == true else {
        throw HelperError("所选 Tailscale exit node 未在线，或连接已变化")
    }
    return try tailscaleInterfaces(json)
}

struct NetworkContext: Codable, Equatable {
    let gateway: String
    let interface: String
    let exitNodeID: String
    let exitNodeName: String
    let tailscaleInterfaces: Set<String>
    var fingerprint: String { ([gateway, interface, exitNodeID] + tailscaleInterfaces.sorted()).joined(separator: "|") }
}

/// The daemon derives all network identity itself; the GUI submits only CIDRs.
func discoverNetwork(ownerUID: uid_t, cancellation: RecoveryCancellation? = nil) throws -> NetworkContext? {
    try cancellation?.throwIfCancelled()
    guard (try? consoleUID()) == ownerUID else { return nil }
    // Avoid invoking the CLI while no physical uplink exists, but never retain
    // this early observation across the potentially slow CLI query.
    guard physicalDefault(snapshot: try RouteTable.snapshot()) != nil else { return nil }
    let json = try tailscaleStatus(ownerUID: ownerUID, cancellation: cancellation)
    try cancellation?.throwIfCancelled()
    guard (try? consoleUID()) == ownerUID else { return nil }
    let snapshot = try RouteTable.snapshot()
    guard let physical = physicalDefault(snapshot: snapshot), let physicalGateway = physical.gateway else { return nil }
    guard json["BackendState"] as? String == "Running",
          let exit = json["ExitNodeStatus"] as? [String: Any],
          let id = exit["ID"] as? String, !id.isEmpty,
          exit["Online"] as? Bool == true else { return nil }
    try require(id.utf8.count <= 128, "Tailscale exit node 身份长度异常")
    let interfaces = try tailscaleInterfaces(json)
    let gateway = IPv4CIDR.formatAddress(physicalGateway)
    let request = ApplyRequest(routes: [], gateway: gateway, interface: physical.interface, exitNodeID: id)
    try verifyGateway(request, snapshot: snapshot, tailscaleInterfaces: interfaces)
    let peers = json["Peer"] as? [String: [String: Any]] ?? [:]
    let peer = peers.values.first { $0["ID"] as? String == id }
    return NetworkContext(gateway: gateway, interface: physical.interface, exitNodeID: id,
                          exitNodeName: String((peer?["HostName"] as? String ?? id).prefix(255)), tailscaleInterfaces: interfaces)
}

private func physicalDefault(snapshot: [ExistingRoute]) -> ExistingRoute? {
    let candidates = snapshot.filter { route in
        route.network == 0 && route.mask == 0 && route.gateway != nil && route.gateway != 0 &&
        route.interface.hasPrefix("en") && !route.interface.dropFirst(2).isEmpty &&
        route.interface.dropFirst(2).allSatisfy { $0 >= "0" && $0 <= "9" } && route.flags & UInt32(RTF_UP) != 0
    }
    guard let store = SCDynamicStoreCreate(nil, "RouteWeaver.discovery" as CFString, nil, nil) else { return nil }
    let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    if let primary = global?["PrimaryInterface"] as? String,
       let route = candidates.first(where: { $0.interface == primary }) { return route }
    let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any]
    let order = setup?["ServiceOrder"] as? [String] ?? []
    for service in order {
        guard let state = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
              let interface = state["InterfaceName"] as? String,
              let router = state["Router"] as? String,
              let address = IPv4CIDR.parseAddress(router) else { continue }
        if let route = candidates.first(where: { $0.interface == interface && $0.gateway == address }) { return route }
    }
    // Ambiguity is unsafe: never choose the first arbitrary routing-table entry.
    return candidates.count == 1 ? candidates.first : nil
}

func verifyGateway(_ request: ApplyRequest, snapshot: [ExistingRoute], tailscaleInterfaces: Set<String>) throws {
    let gateway = IPv4CIDR.parseAddress(request.gateway)!
    try require(snapshot.contains { $0.network == 0 && $0.mask == 0 && $0.gateway == gateway && $0.interface == request.interface && $0.flags & UInt32(RTF_UP) != 0 }, "物理网关已经变化，请重新预览")
    // macOS clients may install a tunnel default or two /1 routes. Accept
    // either only on an interface independently mapped to Tailscale's own IP.
    let low = snapshot.filter { $0.network == 0 && $0.mask == 0x8000_0000 && tailscaleInterfaces.contains($0.interface) }
    let hasPair = low.contains { first in snapshot.contains { $0.network == 0x8000_0000 && $0.mask == 0x8000_0000 && $0.interface == first.interface } }
    let hasDefault = snapshot.contains { $0.network == 0 && $0.mask == 0 && tailscaleInterfaces.contains($0.interface) && $0.flags & UInt32(RTF_IFSCOPE) == 0 }
    try require(hasPair || hasDefault, "未发现完整的 IPv4 exit node 路由，拒绝修改网络")
    let probe: UInt32 = 0x0808_0808
    let effective = snapshot.filter { ($0.network == (probe & $0.mask)) && $0.flags & UInt32(RTF_UP) != 0 && $0.flags & UInt32(RTF_IFSCOPE) == 0 }.max { $0.mask.nonzeroBitCount < $1.mask.nonzeroBitCount }
    try require(effective.map { tailscaleInterfaces.contains($0.interface) } == true, "诊断流量正由其他接口接管，拒绝绕过另一个 VPN")
}
