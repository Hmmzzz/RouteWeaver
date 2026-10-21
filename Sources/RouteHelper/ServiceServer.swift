import Foundation
import Darwin
import RouteIPC

/// Kernel peer credentials + audit-token signature pin authenticate before parsing requests.
final class ServiceServer {
    private let configuration: ServiceConfiguration
    private let queue: DispatchQueue
    private let handler: (ServiceRequest, ServicePeer) -> ServiceResponse
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let clients = DispatchSemaphore(value: 8)
    private let acceptQueue = DispatchQueue(label: "com.routeweaver.ipc.accept")
    private let workers = DispatchQueue(label: "com.routeweaver.ipc.clients", attributes: .concurrent)
    init(config: ServiceConfiguration, queue: DispatchQueue, handler: @escaping (ServiceRequest, ServicePeer) -> ServiceResponse) {
        configuration = config; self.queue = queue; self.handler = handler
    }
    func start() throws {
        try require(geteuid() == 0, "服务必须由系统启动")
        var parent = stat()
        try require(lstat("/Library/PrivilegedHelperTools", &parent) == 0 && parent.st_mode & S_IFMT == S_IFDIR && parent.st_uid == 0 && parent.st_mode & 0o022 == 0, "服务地址目录权限不安全")
        var old = stat()
        if lstat(ServicePaths.socket, &old) == 0 {
            try require(old.st_mode & S_IFMT == S_IFSOCK, "服务地址被未知文件占用")
            // Only root can create entries in this verified parent. A stale socket can belong
            // to the previous console user after an explicitly authorized reinstall.
            // launchd guarantees one running service instance.
            try require(unlink(ServicePaths.socket) == 0, "无法清理过期服务地址")
        } else { try require(errno == ENOENT, "无法检查服务地址") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try require(fd >= 0, "无法创建服务监听端口")
        var success = false
        defer { if !success { close(fd) } }
        try IPCWire.prepare(fd)
        var address = try IPCWire.address(ServicePaths.socket)
        let previousMask = umask(0o177)
        let result = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        try require(result == 0, "无法绑定服务地址")
        try require(chown(ServicePaths.socket, configuration.ownerUID, 0) == 0 && chmod(ServicePaths.socket, 0o600) == 0 && listen(fd, 8) == 0, "无法限制服务连接权限")
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.setCancelHandler { close(fd) }
        self.source = source
        success = true
        source.resume()
    }
    private func acceptClients() {
        while true {
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { return }
            guard clients.wait(timeout: .now()) == .success else { close(client); continue }
            workers.async { [self] in
                defer { close(client); clients.signal() }
                do {
                    try IPCWire.prepare(client)
                    try ServiceIdentity.authenticate(fd: client, configuration: configuration)
                    let data = try IPCWire.readFrame(fd: client, until: IPCWire.deadline(after: 5))
                    let request = try JSONDecoder().decode(ServiceRequest.self, from: data)
                    try request.validate()
                    // Recheck after input, binding the authority to this live peer rather than a PID lookup.
                    try ServiceIdentity.authenticate(fd: client, configuration: configuration)
                    let peer = try ServicePeer.read(from: client)
                    var response = queue.sync { handler(request, peer) }
                    if response.details.count > 2000 {
                        response.detailsOmitted += response.details.count - 2000
                        response.details = Array(response.details.prefix(2000))
                    }
                    try IPCWire.writeFrame(JSONEncoder().encode(response), fd: client, until: IPCWire.deadline(after: 10))
                } catch {
                    // No unauthenticated error detail or work is exposed. Client sees a closed connection.
                }
            }
        }
    }
    deinit { source?.cancel() }
}
