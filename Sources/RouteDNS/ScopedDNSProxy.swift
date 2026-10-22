import Foundation
import Network

/// Loopback-only default DNS forwarder hosted inside the existing helper.
/// Owning code must publish its loopback resolver only after both listeners are ready,
/// and remove that configuration before calling stop(). No system settings are
/// written here. A stopped instance is not restartable; construct a new one.
public final class ScopedDNSProxy {
    public let port: UInt16
    private let queue = DispatchQueue(label: "com.routeweaver.dns.listener", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let https: DNSHTTPSUpstream
    private let original: DNSOriginalUpstream
    private let processor: DNSProcessor
    private var udp: NWListener?
    private var tcp: NWListener?
    private var ready = Set<String>()
    private var started = false
    private var stopped = false
    private var failureReported = false
    private var startupCompletion: ((Result<Void, Error>) -> Void)?
    private var failure: ((Error) -> Void)?
    private var startupTimeout: DispatchWorkItem?
    private var peers: [UUID: DNSPeer] = [:]

    public init(port: UInt16 = 53535, directCIDRs: [String], directDomains: [String]) throws {
        guard port > 0 else { throw DNSProxyError.listener("无效的端口") }
        self.port = port
        let https = DNSHTTPSUpstream(), original = DNSOriginalUpstream()
        self.https = https; self.original = original
        do {
            processor = try DNSProcessor(directCIDRs: directCIDRs, directDomains: directDomains,
                domesticLookup: { query, timeout, completion in https.lookup(query, timeout: timeout, completion: completion) },
                originalLookup: { query, transport, timeout, completion in original.lookup(query, transport: transport, timeout: timeout, completion: completion) })
        } catch { https.stop(); original.stop(); throw error }
        queue.setSpecific(key: queueKey, value: 1)
    }
    /// Dependency boundary for loopback integration tests. The caller supplies
    /// the same processor used in production, with controlled upstreams.
    init(port: UInt16, processor: DNSProcessor) throws {
        guard port > 0 else { throw DNSProxyError.listener("无效的端口") }
        self.port = port; self.processor = processor
        https = DNSHTTPSUpstream(); original = DNSOriginalUpstream()
        queue.setSpecific(key: queueKey, value: 1)
    }
    public func start(completion: @escaping (Result<Void, Error>) -> Void,
                      onFailure: @escaping (Error) -> Void = { _ in }) {
        queue.async { [self] in
            guard !self.started, !self.stopped else { completion(.failure(DNSProxyError.stopped)); return }
            self.started = true; self.startupCompletion = completion; self.failure = onFailure
            do {
                let udpParameters = NWParameters.udp
                udpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.port)!)
                let tcpParameters = NWParameters.tcp
                tcpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: self.port)!)
                self.udp = try NWListener(using: udpParameters)
                self.tcp = try NWListener(using: tcpParameters)
                self.configure(self.udp!, kind: "udp")
                self.configure(self.tcp!, kind: "tcp")
                let timeout = DispatchWorkItem { [weak self] in self?.fail(DNSProxyError.listener("启动超时")) }
                self.startupTimeout = timeout; self.queue.asyncAfter(deadline: .now() + 3, execute: timeout)
                self.udp!.start(queue: self.queue); self.tcp!.start(queue: self.queue)
            } catch { self.fail(error) }
        }
    }
    public func update(directCIDRs: [String]) {
        let update = { self.processor.update(directCIDRs: self.failureReported || self.stopped ? [] : directCIDRs) }
        if DispatchQueue.getSpecific(key: queueKey) != nil { update() }
        else { queue.sync(execute: update) }
    }
    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { shutdown() }
        else { queue.sync { self.shutdown() } }
    }
    deinit { udp?.cancel(); tcp?.cancel(); https.stop(); original.stop() }

    private func configure(_ listener: NWListener, kind: String) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.ready.insert(kind)
                if self.ready.count == 2, let completion = self.startupCompletion {
                    self.startupTimeout?.cancel(); self.startupTimeout = nil
                    self.startupCompletion = nil; completion(.success(()))
                }
            case .failed(let error): self.fail(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            if self.peers.count >= 128,
               let idle = self.peers.values.filter({ $0.activity.canEvict }).min(by: { $0.activity.lastActivity < $1.activity.lastActivity }) {
                self.close(idle)
            }
            guard self.peers.count < 128 else { connection.cancel(); return }
            let peer = DNSPeer(connection: connection, isTCP: kind == "tcp")
            self.peers[peer.id] = peer
            connection.stateUpdateHandler = { [weak self, weak peer] state in
                guard let self, let peer, self.peers[peer.id] != nil else { return }
                switch state {
                case .ready:
                    self.touch(peer)
                    if peer.isTCP { self.advanceTCP(peer) } else { self.receiveUDP(peer) }
                case .failed, .cancelled: self.close(peer)
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
    }
    private func fail(_ error: Error) {
        guard !stopped else { return }
        let wasReady = ready.count == 2
        if wasReady {
            guard !failureReported else { return }; failureReported = true
            // Keep any surviving listener serving the original resolver while
            // the owner withdraws the system configuration. Notify off-queue so
            // the owner's synchronous stop() cannot deadlock this listener.
            processor.update(directCIDRs: [])
            let failure = self.failure
            DispatchQueue.global(qos: .utility).async { failure?(error) }
            return
        }
        let completion = startupCompletion
        startupCompletion = nil
        shutdown()
        if let completion { completion(.failure(error)) }
    }
    private func shutdown() {
        guard !stopped else { return }; stopped = true
        let completion = startupCompletion; startupCompletion = nil
        startupTimeout?.cancel(); startupTimeout = nil
        udp?.cancel(); tcp?.cancel(); udp = nil; tcp = nil
        let peers = Array(peers.values); self.peers.removeAll()
        for peer in peers {
            peer.requests.values.forEach { $0.cancel() }; peer.requests.removeAll()
            peer.idle?.cancel(); peer.connection.cancel()
        }
        processor.stop(); https.stop(); original.stop()
        completion?(.failure(DNSProxyError.stopped))
    }
    private func touch(_ peer: DNSPeer) {
        peer.activity.lastActivity = ProcessInfo.processInfo.systemUptime
        peer.idle?.cancel()
        let idle = DispatchWorkItem { [weak self, weak peer] in if let peer { self?.close(peer) } }
        peer.idle = idle; queue.asyncAfter(deadline: .now() + 10, execute: idle)
    }
    private func close(_ peer: DNSPeer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        peer.requests.values.forEach { $0.cancel() }; peer.requests.removeAll()
        peer.idle?.cancel(); peer.connection.cancel()
    }
    private func receiveUDP(_ peer: DNSPeer) {
        guard peers[peer.id] != nil, !stopped else { return }
        peer.connection.receiveMessage { [weak self, weak peer] data, _, _, error in
            guard let self, let peer, self.peers[peer.id] != nil, !self.stopped else { return }
            guard error == nil else { self.close(peer); return }
            self.touch(peer)
            peer.activity.hasReceivedDatagram = true
            if let data, DNSWire.isQueryMessage(data) {
                let query = DNSWire.question(data)
                self.process(data, peer: peer) { [weak self, weak peer] response in
                    guard let self, let peer, self.peers[peer.id] != nil else { return }
                    var packet = response
                    if packet.count > (query?.udpPayloadSize ?? 512) {
                        let flags = DNSWire.read16([UInt8](packet), 2) ?? 0
                        packet = DNSWire.failure(to: data, rcode: flags & 0xf, truncated: true)
                    }
                    peer.activity.pendingSends += 1
                    peer.connection.send(content: packet, completion: .contentProcessed { [weak self, weak peer] error in
                        guard let self, let peer, self.peers[peer.id] != nil else { return }
                        peer.activity.pendingSends -= 1
                        if error != nil { self.close(peer) }
                        else { self.touch(peer) }
                    })
                }
            }
            self.receiveUDP(peer)
        }
    }
    private func advanceTCP(_ peer: DNSPeer) {
        guard peers[peer.id] != nil, !stopped else { return }
        if peer.processing { receiveTCP(peer); return }
        if peer.buffer.count >= 2, let size = DNSWire.read16([UInt8](peer.buffer), 0) {
            guard size >= 12, size <= DNSWire.maximumQuerySize else { close(peer); return }
            if peer.buffer.count >= Int(size) + 2 {
                let data = Data(peer.buffer.dropFirst(2).prefix(Int(size)))
                // Data.removeFirst preserves a nonzero startIndex. Rebase the
                // remainder before parsing another frame on this connection.
                peer.buffer = Data(peer.buffer.dropFirst(Int(size) + 2))
                guard DNSWire.isQueryMessage(data) else { close(peer); return }
                peer.processing = true; touch(peer)
                process(data, peer: peer) { [weak self, weak peer] response in
                    guard let self, let peer, self.peers[peer.id] != nil else { return }
                    var framed = Data(); framed.appendUInt16(UInt16(response.count)); framed.append(response)
                    peer.connection.send(content: framed, completion: .contentProcessed { [weak self, weak peer] error in
                        guard let self, let peer, self.peers[peer.id] != nil else { return }
                        if error != nil { self.close(peer); return }
                        peer.processing = false
                        if peer.receivedEOF && peer.buffer.isEmpty { self.close(peer) }
                        else { self.advanceTCP(peer) }
                    })
                }
                // Keep a bounded read pending so a reset can cancel upstream
                // work even while its DNS response is outstanding. A clean
                // write half-close still permits the pending response.
                receiveTCP(peer)
                return
            }
        }
        guard !peer.receivedEOF else { close(peer); return }
        receiveTCP(peer)
    }
    private func receiveTCP(_ peer: DNSPeer) {
        let room = DNSWire.maximumQuerySize + 2 - peer.buffer.count
        guard peers[peer.id] != nil, !stopped, !peer.receiving, !peer.receivedEOF, room > 0 else { return }
        peer.receiving = true
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: min(8192, room)) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, self.peers[peer.id] != nil, !self.stopped else { return }
            peer.receiving = false
            if let data { peer.buffer.append(data) }
            guard error == nil, peer.buffer.count <= DNSWire.maximumQuerySize + 2 else { self.close(peer); return }
            peer.receivedEOF = complete; self.touch(peer); self.advanceTCP(peer)
        }
    }
    private func process(_ data: Data, peer: DNSPeer, completion: @escaping (Data) -> Void) {
        // The processor owns both global and per-peer admission. A separate
        // listener gate would let slow optimization requests consume the slots
        // reserved for original-only queries before that policy can run.
        let requestID = UUID()
        peer.activity.requests += 1
        let cancellation = processor.process(data, transport: peer.isTCP ? .tcp : .udp, peerID: peer.id) { [weak self, weak peer] response in
            guard let self else { return }
            self.queue.async {
                guard let peer else { return }; peer.activity.requests = max(0, peer.activity.requests - 1)
                peer.requests.removeValue(forKey: requestID)
                guard !self.stopped, self.peers[peer.id] != nil else { return }
                self.touch(peer)
                completion(response ?? DNSWire.failure(to: data))
            }
        }
        peer.requests[requestID] = cancellation
    }
}

private final class DNSPeer {
    let id = UUID()
    let connection: NWConnection
    let isTCP: Bool
    var idle: DispatchWorkItem?
    var buffer = Data()
    var processing = false
    var receiving = false
    var receivedEOF = false
    var requests: [UUID: DNSCancellation] = [:]
    var activity: DNSPeerActivity
    init(connection: NWConnection, isTCP: Bool) {
        self.connection = connection; self.isTCP = isTCP
        self.activity = DNSPeerActivity(isTCP: isTCP)
    }
}

/// A pending receive alone is normal for a reusable UDP peer. Only completed,
/// quiescent UDP peers may yield their slot under pressure; TCP and active work
/// retain their connection. Kept separate for socket-free regression tests.
struct DNSPeerActivity {
    let isTCP: Bool
    var hasReceivedDatagram = false
    var requests = 0
    var pendingSends = 0
    var lastActivity: TimeInterval = 0
    var canEvict: Bool { !isTCP && hasReceivedDatagram && requests == 0 && pendingSends == 0 }
}
