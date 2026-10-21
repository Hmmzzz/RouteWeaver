import Foundation
import Darwin

/// All identity fields come from the connected kernel peer, never the request.
struct ServicePeer: Equatable {
    let pid: pid_t
    let auditToken: Data

    static func read(from descriptor: Int32) throws -> ServicePeer {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        try require(getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0
                    && size == MemoryLayout<pid_t>.size && pid > 0, "无法读取客户端进程")
        var token = audit_token_t()
        size = socklen_t(MemoryLayout<audit_token_t>.size)
        try require(getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0
                    && size == MemoryLayout<audit_token_t>.size, "无法读取客户端进程标识")
        return ServicePeer(pid: pid, auditToken: withUnsafeBytes(of: &token) { Data($0) })
    }
}

protocol AppProcessWatching: AnyObject { func cancel() }

private final class AppProcessWatcher: AppProcessWatching {
    private let source: DispatchSourceProcess
    init(peer: ServicePeer, queue: DispatchQueue, exited: @escaping () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: peer.pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: exited)
        source.resume()
    }
    func cancel() { source.cancel() }
    deinit { source.cancel() }
}

/// Accessed only on the service request queue. A process watch also catches
/// Force Quit and crashes, where AppKit cannot run the normal stop handshake.
final class AppSessionOwner {
    typealias Watch = (ServicePeer, @escaping () -> Void) -> any AppProcessWatching
    private var owner: ServicePeer?
    private var watcher: (any AppProcessWatching)?
    private var generation: UInt64 = 0
    private let watch: Watch
    private let ownerExited: () -> Void

    convenience init(queue: DispatchQueue, ownerExited: @escaping () -> Void) {
        self.init(watch: { peer, exited in AppProcessWatcher(peer: peer, queue: queue, exited: exited) },
                  ownerExited: ownerExited)
    }
    init(watch: @escaping Watch, ownerExited: @escaping () -> Void) {
        self.watch = watch; self.ownerExited = ownerExited
    }
    func attach(_ peer: ServicePeer) throws {
        if let owner {
            try require(owner == peer, "另一个 RouteWeaver 实例正在管理分流，请先退出该应用")
            return
        }
        generation &+= 1
        let token = generation
        owner = peer
        watcher = watch(peer) { [weak self] in
            guard let self, self.generation == token, self.owner == peer else { return }
            self.generation &+= 1
            self.owner = nil
            self.watcher?.cancel(); self.watcher = nil
            self.ownerExited()
        }
    }
    func isAttached(_ peer: ServicePeer) -> Bool { owner == peer }
    func hasOtherOwner(_ peer: ServicePeer) -> Bool { owner.map { $0 != peer } ?? false }
    /// Closing a second GUI must not revoke the first GUI's network session.
    /// No owner still permits recovery of leftovers after a helper restart.
    func stopIfOwned(_ peer: ServicePeer, stop: () throws -> RecoveryStatus) rethrows -> RecoveryStatus? {
        guard !hasOtherOwner(peer) else { return nil }
        return try stop()
    }
    func requireAttached(_ peer: ServicePeer) throws {
        try require(isAttached(peer), "应用尚未连接后台会话；请重新检查服务后再开启分流")
    }
    deinit { watcher?.cancel() }
}
