import Foundation
import Network

/// Fixed-IP HTTPS avoids recursively resolving the resolver itself. Foundation
/// performs normal system TLS verification, including the IP certificate SAN.
final class DNSHTTPSUpstream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Request {
        var data = Data()
        var accepted = false
        let completion: (Data?) -> Void
    }
    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!
    private var stopped = false

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2.5
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0,
            "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        let delegateQueue = OperationQueue(); delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }
    func lookup(_ query: DNSQuestion, completion: @escaping (DNSAAnswer?) -> Void) {
        var request = URLRequest(url: URL(string: "https://223.5.5.5/dns-query")!)
        request.httpMethod = "POST"; request.httpBody = query.query(type: 1)
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        lock.lock()
        guard !stopped, requests.count < 64 else { lock.unlock(); completion(nil); return }
        let task = session.dataTask(with: request)
        requests[task.taskIdentifier] = Request(completion: { response in
            completion(response.flatMap { DNSWire.aAnswer($0, for: query) })
        })
        lock.unlock(); task.resume()
    }
    func stop() {
        lock.lock(); stopped = true
        let callbacks = requests.values.map(\.completion); requests.removeAll(); lock.unlock()
        session.invalidateAndCancel(); callbacks.forEach { $0(nil) }
    }
    private func finish(_ id: Int, result: Data?) {
        lock.lock(); let request = requests.removeValue(forKey: id); lock.unlock()
        request?.completion(result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.lowercased() == "application/dns-message",
              response.expectedContentLength <= DNSWire.maximumResponseSize else {
            completionHandler(.cancel); finish(dataTask.taskIdentifier, result: nil); return
        }
        lock.lock(); let present = requests[dataTask.taskIdentifier] != nil
        requests[dataTask.taskIdentifier]?.accepted = true; lock.unlock()
        completionHandler(present ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var record = requests[dataTask.taskIdentifier], record.accepted,
              record.data.count + data.count <= DNSWire.maximumResponseSize else {
            lock.unlock(); dataTask.cancel(); finish(dataTask.taskIdentifier, result: nil); return
        }
        record.data.append(data); requests[dataTask.taskIdentifier] = record; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let record = requests[task.taskIdentifier]; lock.unlock()
        finish(task.taskIdentifier, result: error == nil && record?.accepted == true ? record?.data : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); task.cancel(); finish(task.taskIdentifier, result: nil)
    }
}

/// Tiny transport boundary so UDP/TCP framing, deadlines and stop races can
/// be verified without opening any sockets. Callbacks run on start's queue.
enum DNSUpstreamConnectionState { case ready, failed, cancelled }
protocol DNSUpstreamConnection: AnyObject {
    var stateUpdateHandler: ((DNSUpstreamConnectionState) -> Void)? { get set }
    func start(queue: DispatchQueue)
    func send(_ data: Data, completion: @escaping (Bool) -> Void)
    func receiveDatagram(completion: @escaping (Data?, Bool) -> Void)
    func receiveStream(maximumLength: Int, completion: @escaping (Data?, Bool, Bool) -> Void)
    func cancel()
}

private final class NetworkDNSUpstreamConnection: DNSUpstreamConnection {
    private let connection: NWConnection
    var stateUpdateHandler: ((DNSUpstreamConnectionState) -> Void)?
    init(tcp: Bool) {
        // Numeric host, explicit port and no system resolver lookup: forwarding
        // cannot recurse through this helper's loopback default resolver.
        connection = NWConnection(host: "100.100.100.100", port: 53, using: tcp ? .tcp : .udp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.stateUpdateHandler?(.ready)
            case .failed: self?.stateUpdateHandler?(.failed)
            case .cancelled: self?.stateUpdateHandler?(.cancelled)
            default: break
            }
        }
    }
    func start(queue: DispatchQueue) { connection.start(queue: queue) }
    func send(_ data: Data, completion: @escaping (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0 == nil) })
    }
    func receiveDatagram(completion: @escaping (Data?, Bool) -> Void) {
        connection.receiveMessage { data, _, _, error in completion(data, error == nil) }
    }
    func receiveStream(maximumLength: Int, completion: @escaping (Data?, Bool, Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, complete, error in
            completion(data, complete, error == nil)
        }
    }
    func cancel() { connection.cancel() }
}

/// Requests not positively eligible for local direct DNS retain their original
/// complete DNS packet and use the existing Tailscale DNS service. Each request
/// has a unique socket and one deadline. Client TCP stays TCP; UDP TC responses
/// pass through so the client controls its TCP retry.
final class DNSOriginalUpstream {
    private let queue = DispatchQueue(label: "com.routeweaver.dns.original", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let makeConnection: (Bool) -> DNSUpstreamConnection
    private let timeout: TimeInterval
    private var jobs: [UUID: OriginalDNSJob] = [:]
    private var stopped = false
    init(timeout: TimeInterval = 3, makeConnection: @escaping (Bool) -> DNSUpstreamConnection = { NetworkDNSUpstreamConnection(tcp: $0) }) {
        self.timeout = timeout.isFinite ? min(max(timeout, 0.001), 3) : 3
        self.makeConnection = makeConnection
        queue.setSpecific(key: queueKey, value: 1)
    }
    func lookup(_ data: Data, transport: DNSClientTransport = .udp, completion: @escaping (Data?) -> Void) {
        guard DNSWire.isQueryMessage(data) else { completion(nil); return }
        queue.async { [self] in
            guard !self.stopped, self.jobs.count < 64 else { completion(nil); return }
            let id = UUID()
            let job = OriginalDNSJob(data: data, transport: transport, queue: self.queue, timeout: self.timeout, makeConnection: self.makeConnection) { [weak self] response in
                self?.jobs.removeValue(forKey: id); completion(response)
            }
            self.jobs[id] = job; job.start()
        }
    }
    func stop() {
        let stop = {
            self.stopped = true
            let jobs = Array(self.jobs.values); self.jobs.removeAll()
            jobs.forEach { $0.finish(nil) }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { stop() }
        else { queue.sync(execute: stop) }
    }
}

private final class OriginalDNSJob {
    let data: Data
    let transport: DNSClientTransport
    let queue: DispatchQueue
    let timeout: TimeInterval
    let makeConnection: (Bool) -> DNSUpstreamConnection
    let completion: (Data?) -> Void
    var connection: DNSUpstreamConnection?
    var timer: DispatchWorkItem?
    var finished = false
    var tcpBuffer = Data()

    init(data: Data, transport: DNSClientTransport, queue: DispatchQueue, timeout: TimeInterval,
         makeConnection: @escaping (Bool) -> DNSUpstreamConnection, completion: @escaping (Data?) -> Void) {
        self.data = data; self.transport = transport; self.queue = queue; self.timeout = timeout
        self.makeConnection = makeConnection; self.completion = completion
    }
    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timer = timeout; queue.asyncAfter(deadline: .now() + self.timeout, execute: timeout)
        connect(tcp: transport == .tcp || data.count > 65_507) // IPv4 UDP payload cannot carry a full 65,535-byte DNS frame.
    }
    private func connect(tcp: Bool) {
        let previous = connection; connection = nil; previous?.cancel()
        let connection = makeConnection(tcp)
        self.connection = connection
        if tcp { tcpBuffer.removeAll() }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection, !self.finished else { return }
            switch state {
            case .ready:
                var payload = self.data
                if tcp { var framed = Data(); framed.appendUInt16(UInt16(payload.count)); framed.append(payload); payload = framed }
                connection.send(payload) { [weak self, weak connection] success in
                    guard let self, let connection, self.connection === connection, !self.finished else { return }
                    if !success { self.finish(nil) }
                    else if tcp { self.receiveTCP(connection) }
                    else { self.receiveUDP(connection) }
                }
            case .failed, .cancelled: self.finish(nil)
            }
        }
        connection.start(queue: queue)
    }
    private func receiveUDP(_ connection: DNSUpstreamConnection) {
        connection.receiveDatagram { [weak self, weak connection] response, success in
            guard let self, let connection, !self.finished, self.connection === connection else { return }
            guard success else { self.finish(nil); return }
            guard let response, DNSWire.matchesResponse(response, request: self.data) else { self.receiveUDP(connection); return }
            self.finish(response)
        }
    }
    private func receiveTCP(_ connection: DNSUpstreamConnection) {
        connection.receiveStream(maximumLength: DNSWire.maximumResponseSize + 2 - tcpBuffer.count) { [weak self, weak connection] data, complete, success in
            guard let self, let connection, !self.finished, self.connection === connection else { return }
            if let data { self.tcpBuffer.append(data) }
            guard self.tcpBuffer.count <= DNSWire.maximumResponseSize + 2, success else { self.finish(nil); return }
            if self.tcpBuffer.count >= 2, let count = DNSWire.read16([UInt8](self.tcpBuffer), 0) {
                guard count >= 12 else { self.finish(nil); return }
                if self.tcpBuffer.count >= Int(count) + 2 {
                    let response = self.tcpBuffer.subdata(in: 2..<(Int(count) + 2))
                    self.finish(DNSWire.matchesResponse(response, request: self.data) ? response : nil); return
                }
            }
            if complete { self.finish(nil) } else { self.receiveTCP(connection) }
        }
    }
    func finish(_ result: Data?) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil
        connection?.cancel(); connection = nil
        completion(result)
    }
}
