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
    typealias DomesticLookup = (DNSQuestion, @escaping (DNSAAnswer?) -> Void) -> Void
    typealias OriginalLookup = (Data, DNSClientTransport, @escaping (Data?) -> Void) -> Void
    private let queue = DispatchQueue(label: "com.routeweaver.dns.processor", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let domestic: DomesticLookup
    private let original: OriginalLookup
    private let time: () -> TimeInterval
    private let domesticTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private var networks: DNSDirectNetworks
    private let domains: Set<String>
    private var stopped = false
    private struct Cache { let answer: DNSAAnswer; let expires: TimeInterval }
    private struct Pending {
        let id: UUID
        let timer: DispatchWorkItem
        var callbacks: [(DNSAAnswer?) -> Void]
    }
    private struct Request {
        let data: Data
        let timer: DispatchWorkItem
        let completion: (Data?) -> Void
    }
    private var cache: [String: Cache] = [:]
    private var pending: [String: Pending] = [:]
    private var requests: [UUID: Request] = [:]

    init(directCIDRs: [String], directDomains: [String], domestic: @escaping DomesticLookup, original: @escaping OriginalLookup,
         time: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         domesticTimeout: TimeInterval = 3.2, requestTimeout: TimeInterval = 7) throws {
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
        self.domestic = domestic; self.original = original; self.time = time
        self.domesticTimeout = domesticTimeout; self.requestTimeout = requestTimeout
        queue.setSpecific(key: queueKey, value: 1)
    }
    /// Synchronous policy barrier. Every call flushes both cached and in-flight
    /// domestic decisions, including when the network changes but CIDRs do not.
    func update(directCIDRs: [String]) {
        let replacement = (try? DNSDirectNetworks(directCIDRs)) ?? (try! DNSDirectNetworks([]))
        serialized {
            self.networks = replacement; self.cache.removeAll()
            let old = Array(self.pending.values); self.pending.removeAll()
            old.forEach { $0.timer.cancel() }
            old.flatMap(\.callbacks).forEach { $0(nil) }
        }
    }
    func stop() {
        serialized {
            guard !self.stopped else { return }
            self.stopped = true; self.cache.removeAll()
            self.pending.values.forEach { $0.timer.cancel() }; self.pending.removeAll()
            for id in Array(self.requests.keys) {
                if let request = self.requests[id] { self.finish(id, DNSWire.failure(to: request.data)) }
            }
        }
    }
    private func serialized(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { operation() }
        else { queue.sync(execute: operation) }
    }
    func process(_ data: Data, transport: DNSClientTransport = .udp, completion: @escaping (Data?) -> Void) {
        guard DNSWire.isQueryMessage(data) else { completion(nil); return }
        let query = DNSWire.question(data)
        queue.async { [self] in
            guard !self.stopped, self.requests.count < 256 else { completion(DNSWire.failure(to: data)); return }
            let id = UUID()
            let timer = DispatchWorkItem { [weak self] in self?.finish(id, DNSWire.failure(to: data)) }
            self.requests[id] = Request(data: data, timer: timer, completion: completion)
            self.queue.asyncAfter(deadline: .now() + self.requestTimeout, execute: timer)
            guard let query, query.synthesisAllowed, !query.dnssecRequested,
                  [1, 28, 64, 65].contains(query.type), self.matchesScope(query.name),
                  self.networks.contains(0xdf050505) else { // 223.5.5.5 must itself be directly routed.
                self.fallback(data, transport: transport, id: id); return
            }
            self.lookup(query) { answer in
                guard self.requests[id] != nil, !self.stopped else { return }
                guard let answer, !answer.addresses.isEmpty, answer.addresses.count <= 64,
                      answer.addresses.allSatisfy(self.networks.contains) else {
                    self.fallback(data, transport: transport, id: id); return
                }
                // Flatten the validated chain to the original question. Only a
                // fully direct A result allows suppression of IPv6/service hints.
                self.finish(id, DNSWire.response(to: query, addresses: query.type == 1 ? answer.addresses : [], ttl: answer.ttl))
            }
        }
    }
    private static func isProtectedName(_ name: String) -> Bool {
        ["ts.net", "tailscale.com", "tailscale.io", "arpa", "local", "localhost", "onion", "invalid"].contains {
            name == $0 || name.hasSuffix("." + $0)
        }
    }
    private func matchesScope(_ name: String) -> Bool {
        guard name.contains("."), !Self.isProtectedName(name) else { return false }
        // Hash lookups over at most the hostname's label count; never scan the
        // full domain list per request (the production list has 7,726 entries).
        var suffix = name[...]
        while !suffix.isEmpty {
            if domains.contains(String(suffix)) { return true }
            guard let dot = suffix.firstIndex(of: ".") else { break }
            suffix = suffix[suffix.index(after: dot)...]
        }
        return false
    }
    private func fallback(_ data: Data, transport: DNSClientTransport, id: UUID) {
        guard requests[id] != nil, !stopped else { return }
        original(data, transport) { response in
            self.queue.async {
                guard self.requests[id] != nil, !self.stopped else { return }
                self.finish(id, response.flatMap { DNSWire.matchesResponse($0, request: data) ? $0 : nil } ?? DNSWire.failure(to: data))
            }
        }
    }
    private func finish(_ id: UUID, _ response: Data) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.timer.cancel(); request.completion(response)
    }
    private func lookup(_ query: DNSQuestion, completion: @escaping (DNSAAnswer?) -> Void) {
        if let entry = cache[query.name], entry.expires > time() {
            let remaining = UInt32(max(0, floor(entry.expires - time())))
            completion(DNSAAnswer(addresses: entry.answer.addresses, ttl: min(remaining, entry.answer.ttl))); return
        }
        cache.removeValue(forKey: query.name)
        if var waiting = pending[query.name] {
            guard waiting.callbacks.count < 64 else { completion(nil); return }
            waiting.callbacks.append(completion); pending[query.name] = waiting; return
        }
        guard pending.count < 64 else { completion(nil); return }
        let id = UUID()
        let timer = DispatchWorkItem { [weak self] in self?.completeLookup(query.name, id: id, answer: nil) }
        pending[query.name] = Pending(id: id, timer: timer, callbacks: [completion])
        queue.asyncAfter(deadline: .now() + domesticTimeout, execute: timer)
        domestic(query) { answer in
            self.queue.async { self.completeLookup(query.name, id: id, answer: answer) }
        }
    }
    private func completeLookup(_ name: String, id: UUID, answer: DNSAAnswer?) {
        // A late result from a previous network must not complete a new lookup
        // for the same name, or refill its cache after an update/stop barrier.
        guard let waiting = pending[name], waiting.id == id, !stopped else { return }
        pending.removeValue(forKey: name); waiting.timer.cancel()
        if let answer, answer.ttl > 0, !answer.addresses.isEmpty, answer.addresses.count <= 64,
           answer.addresses.allSatisfy(networks.contains) {
            if cache.count >= 512 { cache = cache.filter { $0.value.expires > time() } }
            if cache.count >= 512, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key {
                cache.removeValue(forKey: oldest)
            }
            cache[name] = Cache(answer: answer, expires: time() + Double(min(answer.ttl, 60)))
        }
        waiting.callbacks.forEach { $0(answer) }
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
