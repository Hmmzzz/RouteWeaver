import Foundation
import RouteCore

/// A destination must be in the currently active IPv4 plan. The processor below
/// matches the complete local suffix set itself and otherwise forwards the
/// original DNS packet. System resolver publication belongs to the helper owner.
struct DNSDirectNetworks {
    private let ranges: [(UInt32, UInt32)]
    init(_ cidrs: [String]) throws {
        guard cidrs.count <= 20_000 else { throw DNSProxyError.invalidPolicy }
        let networks = try cidrs.map { value -> IPv4CIDR in
            let network = try IPv4CIDR(value); try network.validateForBypass(); return network
        }.sorted()
        var merged: [(UInt32, UInt32)] = []
        for network in networks {
            if let last = merged.last, UInt64(network.network) <= UInt64(last.1) + 1 {
                merged[merged.count - 1].1 = max(last.1, network.lastAddress)
            } else { merged.append((network.network, network.lastAddress)) }
        }
        ranges = merged
    }
    func contains(_ address: UInt32) -> Bool {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].0 <= address { low = mid + 1 } else { high = mid }
        }
        return low > 0 && address <= ranges[low - 1].1
    }
}

enum DNSClientTransport: Equatable { case udp, tcp }

final class DNSProcessor {
    static let maximumRequestsPerPeer = 8
    typealias DomesticLookup = (DNSQuestion, @escaping (DNSAAnswer?) -> Void) -> Void
    typealias OriginalLookup = (Data, DNSClientTransport, @escaping (Data?) -> Void) -> Void
    typealias CancellableDomesticLookup = (DNSQuestion, TimeInterval, @escaping (DNSDomesticResult) -> Void) -> DNSCancellation
    typealias CancellableOriginalLookup = (Data, DNSClientTransport, TimeInterval, @escaping (Data?) -> Void) -> DNSCancellation
    private let queue = DispatchQueue(label: "com.routeweaver.dns.processor", qos: .utility)
    private let completionQueue = DispatchQueue(label: "com.routeweaver.dns.completions", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let domestic: CancellableDomesticLookup
    private let original: CancellableOriginalLookup
    private let time: () -> TimeInterval
    private let domesticTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private var networks: DNSDirectNetworks
    private let domains: Set<String>
    private var stopped = false
    private struct Cache { let answer: DNSAAnswer; let expires: TimeInterval }
    private final class Pending {
        let id: UUID
        let circuitEpoch: UInt64
        let timer: DispatchWorkItem
        var subscribers: Set<UUID>
        var cancellation: DNSCancellation?
        init(id: UUID, circuitEpoch: UInt64, timer: DispatchWorkItem, subscriber: UUID) {
            self.id = id; self.circuitEpoch = circuitEpoch; self.timer = timer; subscribers = [subscriber]
        }
    }
    private final class Request {
        let data: Data
        let question: DNSQuestion?
        let transport: DNSClientTransport
        let peerID: UUID?
        // Fixed at admission, including time spent forwarding to the original
        // resolver. A domestic outage cannot consume the reserved original slots.
        let optimization: Bool
        let deadline: TimeInterval
        let timer: DispatchWorkItem
        let completion: (Data?) -> Void
        var domesticName: String?
        var originalStarted = false
        var originalCancellation: DNSCancellation?
        init(data: Data, question: DNSQuestion?, transport: DNSClientTransport, peerID: UUID?, optimization: Bool,
             deadline: TimeInterval, timer: DispatchWorkItem, completion: @escaping (Data?) -> Void) {
            self.data = data; self.question = question; self.transport = transport; self.peerID = peerID
            self.optimization = optimization; self.deadline = deadline; self.timer = timer; self.completion = completion
        }
    }
    struct ActivitySnapshot {
        let active: Int
        let optimization: Int
        let domesticSubscribers: Int
        let domesticLookups: Int
        let consecutiveFailures: Int
        let coolingDown: Bool
        let probing: Bool
    }
    var activitySnapshot: ActivitySnapshot {
        serialized {
            ActivitySnapshot(active: requests.count, optimization: requests.values.filter(\.optimization).count,
                domesticSubscribers: pending.values.reduce(0) { $0 + $1.subscribers.count }, domesticLookups: pending.count,
                consecutiveFailures: consecutiveFailures, coolingDown: cooldownUntil.map { $0 > time() } ?? false,
                probing: halfOpenID != nil)
        }
    }
    private var cache: [String: Cache] = [:]
    private var pending: [String: Pending] = [:]
    private var requests: [UUID: Request] = [:]
    private var consecutiveFailures = 0
    private var cooldownUntil: TimeInterval?
    private var halfOpenID: UUID?
    private var circuitEpoch: UInt64 = 0

    convenience init(directCIDRs: [String], directDomains: [String], domestic: @escaping DomesticLookup, original: @escaping OriginalLookup,
                     time: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     domesticTimeout: TimeInterval = 1.25, requestTimeout: TimeInterval = 4.5) throws {
        try self.init(directCIDRs: directCIDRs, directDomains: directDomains,
            domesticLookup: { query, _, completion in domestic(query) { completion(.response($0)) }; return DNSCancellation() },
            originalLookup: { data, transport, _, completion in original(data, transport, completion); return DNSCancellation() },
            time: time, domesticTimeout: domesticTimeout, requestTimeout: requestTimeout)
    }
    init(directCIDRs: [String], directDomains: [String], domesticLookup: @escaping CancellableDomesticLookup,
         originalLookup: @escaping CancellableOriginalLookup,
         time: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         domesticTimeout: TimeInterval = 1.25, requestTimeout: TimeInterval = 4.5) throws {
        networks = try DNSDirectNetworks(directCIDRs)
        guard directDomains.count <= 200_000, domesticTimeout > 0, domesticTimeout.isFinite,
              requestTimeout > 0, requestTimeout.isFinite else { throw DNSProxyError.invalidPolicy }
        let normalized = directDomains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        guard normalized.allSatisfy({ domain in
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            return !domain.isEmpty && domain.utf8.count <= 253 && (["cn", "xn--fiqs8s"].contains(domain) || labels.count >= 2) &&
                !Self.isProtectedName(domain) &&
                labels.allSatisfy { label in !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                    label.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 } }
        }) else { throw DNSProxyError.invalidPolicy }
        domains = Set(normalized)
        domestic = domesticLookup; original = originalLookup; self.time = time
        self.domesticTimeout = domesticTimeout; self.requestTimeout = requestTimeout
        queue.setSpecific(key: queueKey, value: 1)
    }
    /// A synchronous policy barrier invalidates domestic work and health state,
    /// including when a new network happens to have the same direct CIDRs.
    func update(directCIDRs: [String]) {
        let replacement = (try? DNSDirectNetworks(directCIDRs)) ?? (try! DNSDirectNetworks([]))
        serialized {
            networks = replacement; cache.removeAll()
            circuitEpoch &+= 1; consecutiveFailures = 0; cooldownUntil = nil; halfOpenID = nil
            let old = Array(pending.values); pending.removeAll()
            let subscribers = old.flatMap { $0.subscribers }
            subscribers.forEach { requests[$0]?.domesticName = nil }
            old.forEach { $0.timer.cancel(); $0.cancellation?.cancel() }
            subscribers.forEach { fallback($0) }
        }
    }
    func stop() {
        serialized {
            guard !stopped else { return }
            stopped = true; cache.removeAll(); circuitEpoch &+= 1; halfOpenID = nil
            for id in Array(requests.keys) {
                if let request = requests[id] { finish(id, DNSWire.failure(to: request.data)) }
            }
        }
    }
    private func serialized<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return operation() }
        return queue.sync(execute: operation)
    }
    /// Admission is a short synchronous operation with no I/O. All completions,
    /// including rejection, run on another queue and never under admission state.
    @discardableResult
    func process(_ data: Data, transport: DNSClientTransport = .udp, peerID: UUID? = nil,
                 completion: @escaping (Data?) -> Void) -> DNSCancellation {
        let id = UUID(), entered = time()
        let cancellation = DNSCancellation { [weak self] in
            self?.queue.async { [weak self] in self?.finish(id, nil) }
        }
        guard DNSWire.isQueryMessage(data) else { completionQueue.async { completion(nil) }; return cancellation }
        let query = DNSWire.question(data)
        serialized {
            let optimization = eligible(query)
            let peerRequests = peerID.map { peer in requests.values.filter { $0.peerID == peer } } ?? []
            guard !stopped, requests.count < 64,
                  !optimization || requests.values.filter(\.optimization).count < 48,
                  peerID == nil || (peerRequests.count < Self.maximumRequestsPerPeer && (!optimization || peerRequests.filter(\.optimization).count < 6)) else {
                completionQueue.async { completion(DNSWire.failure(to: data)) }; return
            }
            let timer = DispatchWorkItem { [weak self] in self?.finish(id, DNSWire.failure(to: data)) }
            let request = Request(data: data, question: query, transport: transport, peerID: peerID, optimization: optimization,
                deadline: entered + requestTimeout, timer: timer, completion: completion)
            requests[id] = request
            queue.asyncAfter(deadline: .now() + max(0, request.deadline - time()), execute: timer)
            queue.async { [weak self] in self?.begin(id) }
        }
        return cancellation
    }
    private func eligible(_ query: DNSQuestion?) -> Bool {
        guard let query else { return false }
        return query.synthesisAllowed && !query.dnssecRequested && [1, 28, 64, 65].contains(query.type) &&
            matchesScope(query.name) && networks.contains(0xdf050505)
    }
    private func begin(_ id: UUID) {
        guard let request = requests[id], !stopped else { return }
        // Recheck the live policy after asynchronous admission. Classification
        // remains fixed, even if a policy update now requires original forwarding.
        guard request.optimization, eligible(request.question), let query = request.question else { fallback(id); return }
        lookup(query, subscriber: id)
    }
    private static func isProtectedName(_ name: String) -> Bool {
        ["ts.net", "tailscale.com", "tailscale.io", "arpa", "local", "localhost", "onion", "invalid"].contains {
            name == $0 || name.hasSuffix("." + $0)
        }
    }
    private func matchesScope(_ name: String) -> Bool {
        guard name.contains("."), !Self.isProtectedName(name) else { return false }
        var suffix = name[...]
        while !suffix.isEmpty {
            if domains.contains(String(suffix)) { return true }
            guard let dot = suffix.firstIndex(of: ".") else { break }
            suffix = suffix[suffix.index(after: dot)...]
        }
        return false
    }
    private func fallback(_ id: UUID) {
        guard let request = requests[id], !stopped, !request.originalStarted else { return }
        let remaining = request.deadline - time()
        guard remaining > 0 else { finish(id, DNSWire.failure(to: request.data)); return }
        request.originalStarted = true
        request.originalCancellation = original(request.data, request.transport, min(3, remaining)) { [weak self] response in
            self?.queue.async { [weak self] in
                guard let self, let request = self.requests[id], !self.stopped else { return }
                guard request.deadline > self.time() else {
                    self.finish(id, DNSWire.failure(to: request.data)); return
                }
                self.finish(id, response.flatMap { DNSWire.matchesResponse($0, request: request.data) ? $0 : nil } ?? DNSWire.failure(to: request.data))
            }
        }
    }
    private func finish(_ id: UUID, _ response: Data?) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.timer.cancel()
        if let name = request.domesticName, let waiting = pending[name] {
            waiting.subscribers.remove(id)
            if waiting.subscribers.isEmpty {
                pending.removeValue(forKey: name); waiting.timer.cancel(); waiting.cancellation?.cancel()
                if halfOpenID == waiting.id { halfOpenID = nil }
            }
        }
        request.originalCancellation?.cancel()
        completionQueue.async { request.completion(response) }
    }
    private func lookup(_ query: DNSQuestion, subscriber: UUID) {
        guard let request = requests[subscriber] else { return }
        if let entry = cache[query.name], entry.expires > time() {
            let remaining = UInt32(max(0, floor(entry.expires - time())))
            accept(DNSAAnswer(addresses: entry.answer.addresses, ttl: min(remaining, entry.answer.ttl)), for: subscriber); return
        }
        cache.removeValue(forKey: query.name)
        guard pending.values.reduce(0, { $0 + $1.subscribers.count }) < 32 else { fallback(subscriber); return }
        if let until = cooldownUntil, time() < until { fallback(subscriber); return }
        if let probe = halfOpenID, pending[query.name]?.id != probe { fallback(subscriber); return }
        if let waiting = pending[query.name] {
            // An earlier circuit generation must not become the half-open probe.
            guard waiting.circuitEpoch == circuitEpoch else { fallback(subscriber); return }
            waiting.subscribers.insert(subscriber); request.domesticName = query.name; return
        }
        let reserve = min(3, requestTimeout * 2 / 3)
        let budget = min(domesticTimeout, request.deadline - time() - reserve)
        guard budget > 0 else { fallback(subscriber); return }
        let id = UUID()
        if cooldownUntil != nil { halfOpenID = id }
        let timer = DispatchWorkItem { [weak self] in self?.completeLookup(query.name, id: id, result: .failure) }
        let waiting = Pending(id: id, circuitEpoch: circuitEpoch, timer: timer, subscriber: subscriber)
        pending[query.name] = waiting; request.domesticName = query.name
        queue.asyncAfter(deadline: .now() + budget, execute: timer)
        waiting.cancellation = domestic(query, budget) { [weak self] result in
            self?.queue.async { [weak self] in self?.completeLookup(query.name, id: id, result: result) }
        }
    }
    private func accept(_ answer: DNSAAnswer?, for id: UUID) {
        guard let request = requests[id], let query = request.question, !stopped else { return }
        guard request.deadline > time() else { finish(id, DNSWire.failure(to: request.data)); return }
        guard let answer, !answer.addresses.isEmpty, answer.addresses.count <= 64,
              answer.addresses.allSatisfy(networks.contains) else { fallback(id); return }
        finish(id, DNSWire.response(to: query, addresses: query.type == 1 ? answer.addresses : [], ttl: answer.ttl))
    }
    private func completeLookup(_ name: String, id: UUID, result: DNSDomesticResult) {
        guard let waiting = pending[name], waiting.id == id, !stopped else { return }
        pending.removeValue(forKey: name); waiting.timer.cancel(); waiting.cancellation?.cancel()
        let answer: DNSAAnswer?
        switch result {
        case .response(let response): answer = response
        case .failure, .unavailable: answer = nil
        }
        if waiting.circuitEpoch == circuitEpoch {
            switch result {
            case .response:
                consecutiveFailures = 0; cooldownUntil = nil; halfOpenID = nil
            case .failure:
                consecutiveFailures += 1
                if consecutiveFailures >= 2 {
                    circuitEpoch &+= 1; cooldownUntil = time() + 5; halfOpenID = nil
                }
            case .unavailable:
                if halfOpenID == id { halfOpenID = nil }
            }
        }
        if let answer, answer.ttl > 0, !answer.addresses.isEmpty, answer.addresses.count <= 64,
           answer.addresses.allSatisfy(networks.contains) {
            if cache.count >= 512 { cache = cache.filter { $0.value.expires > time() } }
            if cache.count >= 512, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key { cache.removeValue(forKey: oldest) }
            cache[name] = Cache(answer: answer, expires: time() + Double(min(answer.ttl, 60)))
        }
        for subscriber in waiting.subscribers {
            requests[subscriber]?.domesticName = nil
            accept(answer, for: subscriber)
        }
    }
}

public enum DNSProxyError: Error, LocalizedError {
    case invalidPolicy
    case stopped
    case listener(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: return "DNS 直连策略无效"
        case .stopped: return "DNS 服务已经停止"
        case .listener(let message): return "DNS 本机监听失败：\(message)"
        }
    }
}
