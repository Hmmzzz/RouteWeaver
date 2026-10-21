import Foundation
import SystemConfiguration
import Darwin
import RouteCore
import RouteDNS

protocol ScopedDNSProxyServing: AnyObject {
    func start(completion: @escaping (Result<Void, Error>) -> Void, onFailure: @escaping (Error) -> Void)
    func update(directCIDRs: [String])
    func stop()
}
extension ScopedDNSProxy: ScopedDNSProxyServing {}

protocol ScopedDNSResolverSession: AnyObject {
    func currentValue() -> NSDictionary?
    func add(_ value: NSDictionary) throws
    /// Idempotently release the session; configd withdraws only its owned keys.
    func close()
}

protocol ScopedDNSResolverVerifying {
    func isAdopted(port: UInt16, order: Int) -> Bool
    func waitUntilWithdrawn(port: UInt16) -> Bool
    func hasTailscaleDefaultExcludingRootResolver(port: UInt16, order: Int) -> Bool
}

/// Session-owned loopback resolver. The system receives one root scope; the
/// full domain set is classified inside the existing helper's proxy.
final class ScopedDNSController {
    static let storeKey = "State:/Network/Service/com.routeweaver.domestic-dns/DNS"
    static let maximumDomainCount = 200_000
    static let port: UInt16 = 53535
    private let queue = DispatchQueue(label: "RouteWeaver.scoped-dns", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let domains: [String]
    private let defaultDNS: () -> [String: Any]?
    private let makeSession: () throws -> any ScopedDNSResolverSession
    private let makeProxy: (UInt16, [String], [String]) throws -> any ScopedDNSProxyServing
    private let verifier: any ScopedDNSResolverVerifying
    private let healthCheck: (UInt16) -> Bool
    private let time: () -> TimeInterval
    private let automaticRetries: Bool
    private var session: (any ScopedDNSResolverSession)?
    private var publishedValue: NSDictionary?
    private var proxy: (any ScopedDNSProxyServing)?
    private var generation: UInt64 = 0
    private var requestedCIDRs: [String] = []
    private var active = false
    private var starting = false
    private var closed = false
    private var deinitializing = false
    private var domainCount = 0
    private var message = "国内域名直连解析未启用"
    private var retryAfter: TimeInterval = 0
    private var withdrawalRetry: DispatchWorkItem?

    init(domains: [String] = DomesticDomains.suffixes,
         defaultDNS: @escaping () -> [String: Any]? = ScopedDNSController.readDefaultDNS,
         makeSession: @escaping () throws -> any ScopedDNSResolverSession = { try ScopedDNSSession() },
         makeProxy: @escaping (UInt16, [String], [String]) throws -> any ScopedDNSProxyServing = {
             try ScopedDNSProxy(port: $0, directCIDRs: $1, directDomains: $2)
         }, verifier: any ScopedDNSResolverVerifying = ScopedDNSSystemVerifier(),
         healthCheck: @escaping (UInt16) -> Bool = ScopedDNSLoopbackHealth.check,
         time: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticRetries: Bool = true) {
        self.domains = domains; self.defaultDNS = defaultDNS; self.makeSession = makeSession
        self.makeProxy = makeProxy; self.verifier = verifier; self.healthCheck = healthCheck
        self.time = time; self.automaticRetries = automaticRetries
        queue.setSpecific(key: queueKey, value: 1)
    }

    func update(directCIDRs: [String]) {
        guard !directCIDRs.isEmpty else { stop(); return }
        let policy = Array(Set(directCIDRs)).sorted()
        queue.async { [weak self] in self?.updateOnQueue(policy) }
    }
    func stop() {
        synchronized {
            generation &+= 1; requestedCIDRs = []; retryAfter = 0
            message = "国内域名直连解析未启用"
            _ = tearDownOnQueue()
        }
    }
    func shutdown() {
        synchronized {
            closed = true; generation &+= 1; requestedCIDRs = []; retryAfter = 0
            message = "国内域名直连解析已关闭"
            _ = tearDownOnQueue()
        }
    }
    func status() -> (active: Bool, domainCount: Int, message: String, withdrawn: Bool) {
        synchronized { (active, active ? domainCount : 0, message,
                         !active && !starting && session == nil && publishedValue == nil && proxy == nil) }
    }
    private func synchronized<T>(_ action: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return action() }
        return queue.sync(execute: action)
    }

    private func updateOnQueue(_ policy: [String]) {
        guard !closed else { return }
        guard defaultDNSIsEligible() else {
            generation &+= 1; requestedCIDRs = policy; retryAfter = 0
            message = "当前默认 DNS 不由 Tailscale 管理，沿用现有系统解析"
            _ = tearDownOnQueue(); return
        }
        do {
            guard policy.count <= 20_000 else { throw ScopedDNSControllerError.missingUpstreamRoute }
            let networks = try policy.map { value -> IPv4CIDR in
                let network = try IPv4CIDR(value); try network.validateForBypass(); return network
            }
            guard networks.contains(where: { $0.contains("223.5.5.5") }) else {
                throw ScopedDNSControllerError.missingUpstreamRoute
            }
        } catch {
            generation &+= 1; requestedCIDRs = policy
            message = "国内解析上游没有已核验的直连路由，保留原解析方式"
            _ = tearDownOnQueue(); return
        }
        if policy == requestedCIDRs {
            if starting { return }
            if active && publishedValueIsCurrent() && verifier.isAdopted(port: Self.port, order: 100) { return }
            guard time() >= retryAfter else { return }
        }
        generation &+= 1
        let token = generation
        requestedCIDRs = policy
        guard tearDownOnQueue() else { return }
        starting = true; message = "正在准备国内域名直连解析"
        do {
            let validated = try Self.validatedDomains(domains)
            let candidate = try makeProxy(Self.port, policy, validated)
            proxy = candidate
            candidate.start(completion: { [weak self] result in
                self?.queue.async { [weak self] in
                    guard let self, !self.closed, token == self.generation, self.starting else { return }
                    switch result {
                    case .success:
                        guard self.healthCheck(Self.port) else {
                            self.failOnQueue("本机 DNS 监听自检失败，保留原解析方式"); return
                        }
                        do {
                            try self.publishOnQueue()
                            self.starting = false; self.active = true; self.retryAfter = 0
                            self.domainCount = validated.count
                            self.message = "国内域名直连解析已启用（\(validated.count) 个域名范围）"
                        } catch { self.failOnQueue("国内解析配置未能启用：\(error.localizedDescription)") }
                    case .failure(let error):
                        self.failOnQueue("国内解析监听未能启动：\(error.localizedDescription)")
                    }
                }
            }, onFailure: { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, !self.closed, token == self.generation else { return }
                    self.failOnQueue("国内解析监听失效：\(error.localizedDescription)")
                }
            })
        } catch { failOnQueue("国内解析未能准备：\(error.localizedDescription)") }
    }

    private func publishOnQueue() throws {
        guard !closed, defaultDNSIsEligible() else { throw ScopedDNSControllerError.differentDefaultDNS }
        let candidate = try makeSession()
        let value = Self.resolverValue(sessionID: UUID().uuidString)
        // Create-only: another writer's existing key is never overwritten.
        try candidate.add(value)
        session = candidate; publishedValue = value
        guard publishedValueIsCurrent(), verifier.isAdopted(port: Self.port, order: 100),
              defaultDNSIsEligible() else { throw ScopedDNSControllerError.notAdopted }
    }
    static func resolverValue(sessionID: String) -> NSDictionary {
        ["ServerAddresses": ["127.0.0.1"], "ServerPort": NSNumber(value: port),
         "ServerTimeout": NSNumber(value: 5), "SupplementalMatchDomains": [""],
         "SupplementalMatchOrders": [NSNumber(value: 100)],
         "SupplementalMatchDomainsNoSearch": NSNumber(value: 1), "RouteWeaverSession": sessionID]
    }
    private func defaultDNSIsEligible() -> Bool {
        let current = defaultDNS()
        guard publishedValue != nil else { return Self.usesTailscaleDefaultDNS(current) }
        guard publishedValueIsCurrent() else { return false }
        // macOS promotes the winning supplemental root into Global/DNS. Once
        // ours wins, verify the remaining root resolvers instead of rejecting
        // our own loopback address as an external DNS change.
        guard Self.usesTailscaleDefaultDNS(current) || Self.isOwnGlobalDNS(current) else { return false }
        return verifier.hasTailscaleDefaultExcludingRootResolver(port: Self.port, order: 100)
    }
    static func isOwnGlobalDNS(_ value: [String: Any]?) -> Bool {
        let service = storeKey.dropFirst("State:/Network/Service/".count).dropLast("/DNS".count)
        return value?["ServerAddresses"] as? [String] == ["127.0.0.1"] &&
            value?["ServerPort"] as? UInt16 == port &&
            value?["SearchOrder"] as? Int == 100 &&
            value?["__CONFIGURATION_ID__"] as? String == "Supplemental: \(service) 0"
    }
    private func publishedValueIsCurrent() -> Bool {
        guard let publishedValue, let current = session?.currentValue() else { return false }
        return current.isEqual(publishedValue)
    }
    private func failOnQueue(_ reason: String) {
        generation &+= 1; message = reason; retryAfter = time() + 5
        _ = tearDownOnQueue()
    }

    /// An unconfirmed withdrawal must retain a live fallback listener. Its
    /// direct policy is cleared immediately, before callers remove IP routes.
    @discardableResult
    private func tearDownOnQueue() -> Bool {
        withdrawalRetry?.cancel(); withdrawalRetry = nil
        active = false; starting = false; domainCount = 0
        proxy?.update(directCIDRs: [])
        // Closing a session lets configd atomically remove only keys it still
        // owns. A read-then-RemoveValue sequence could delete another writer's
        // replacement, including a byte-identical value with different ownership.
        session?.close(); session = nil
        if publishedValue != nil {
            // Keep the publication marker after closing the session so retries
            // still require readback before stopping the fallback listener.
            guard verifier.waitUntilWithdrawn(port: Self.port) else {
                message = "等待系统撤销本机解析配置；监听暂时保留以免中断 DNS"
                scheduleWithdrawalRetry(); return false
            }
        }
        publishedValue = nil
        proxy?.stop(); proxy = nil
        return true
    }
    private func scheduleWithdrawalRetry() {
        guard automaticRetries && !deinitializing else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.tearDownOnQueue() {
                self.message = self.closed ? "国内域名直连解析已关闭" : "本机解析配置已撤销"
            }
        }
        withdrawalRetry = work; queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    static func readDefaultDNS() -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "RouteWeaver.dns-check" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
    }
    static func usesTailscaleDefaultDNS(_ value: [String: Any]?) -> Bool {
        guard let servers = value?["ServerAddresses"] as? [String], servers.contains("100.100.100.100") else { return false }
        let allowed = Set(["100.100.100.100", "fd7a:115c:a1e0::53"])
        return servers.allSatisfy { allowed.contains($0.lowercased()) }
    }
    static func validatedDomains(_ values: [String]) throws -> [String] {
        guard !values.isEmpty, values.count <= maximumDomainCount else { throw ScopedDNSControllerError.invalidDomains }
        let domains = Array(Set(values)).sorted()
        let forbidden = Set(["com", "net", "org", "edu", "gov", "io", "app", "dev", "local", "localhost", "arpa", "ts.net", "tailscale.com"])
        for domain in domains {
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            guard !domain.isEmpty, domain.utf8.count <= 253, domain == domain.lowercased(),
                  ["cn", "xn--fiqs8s"].contains(domain) || labels.count >= 2,
                  !forbidden.contains(domain), !domain.hasSuffix(".ts.net"), !domain.hasSuffix(".arpa"), !domain.hasSuffix(".tailscale.com"),
                  labels.allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                      label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                  }), labels.last?.allSatisfy({ $0.isNumber }) == false else { throw ScopedDNSControllerError.invalidDomains }
        }
        return domains
    }
    deinit {
        synchronized {
            closed = true; deinitializing = true; withdrawalRetry?.cancel(); withdrawalRetry = nil
            // Session deallocation also withdraws its own keys on process exit.
            _ = tearDownOnQueue()
            withdrawalRetry?.cancel()
        }
    }
}

private enum ScopedDNSControllerError: LocalizedError {
    case invalidDomains, missingUpstreamRoute, differentDefaultDNS, notAdopted, configuration(Int32)
    var errorDescription: String? {
        switch self {
        case .invalidDomains: return "国内域名列表无效或超出限制"
        case .missingUpstreamRoute: return "解析上游缺少直连路由"
        case .differentDefaultDNS: return "默认 DNS 已变化"
        case .notAdopted: return "系统未采用本机解析配置"
        case .configuration(let code): return "系统配置请求失败（\(code)）"
        }
    }
}

private final class ScopedDNSSession: ScopedDNSResolverSession {
    private var store: SCDynamicStore?
    init() throws {
        let options = [kSCDynamicStoreUseSessionKeys as String: true] as CFDictionary
        guard let session = SCDynamicStoreCreateWithOptions(nil, "RouteWeaver.domestic-dns" as CFString, options, nil, nil) else {
            throw ScopedDNSControllerError.configuration(SCError())
        }
        store = session
    }
    func currentValue() -> NSDictionary? {
        guard let store else { return nil }
        return SCDynamicStoreCopyValue(store, ScopedDNSController.storeKey as CFString) as? NSDictionary
    }
    func add(_ value: NSDictionary) throws {
        guard let store else { throw ScopedDNSControllerError.notAdopted }
        guard SCDynamicStoreAddValue(store, ScopedDNSController.storeKey as CFString, value) else {
            throw ScopedDNSControllerError.configuration(SCError())
        }
    }
    func close() { store = nil }
}

struct ScopedDNSSystemVerifier: ScopedDNSResolverVerifying {
    let snapshot: () throws -> String
    let timeout: TimeInterval
    init(snapshot: @escaping () throws -> String = ScopedDNSSystemVerifier.readSnapshot, timeout: TimeInterval = 2) {
        self.snapshot = snapshot; self.timeout = timeout
    }
    func isAdopted(port: UInt16, order: Int) -> Bool {
        wait { Self.snapshotAdoptsRootResolver($0, port: port, order: order) }
    }
    func waitUntilWithdrawn(port: UInt16) -> Bool {
        wait { ($0.contains("DNS configuration") || $0.contains("No DNS configuration available")) &&
            !Self.snapshotContainsLoopbackResolver($0, port: port) }
    }
    func hasTailscaleDefaultExcludingRootResolver(port: UInt16, order: Int) -> Bool {
        wait { Self.snapshotHasTailscaleDefaultExcludingRootResolver($0, port: port, order: order) }
    }
    private func wait(_ accepts: (String) -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if let text = try? snapshot(), accepts(text) { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
    }
    static func snapshotAdoptsRootResolver(_ text: String, port: UInt16, order: Int) -> Bool {
        let roots = resolvers(text).filter { $0.rootSection && !$0.scoped && ($0.domain == nil || $0.domain == "" || $0.domain == ".") }
        let matches: (Resolver) -> Bool = { $0.servers == ["127.0.0.1"] && $0.port == Int(port) && $0.order == order }
        // Mere presence is insufficient if another root resolver precedes it.
        return roots.contains(where: matches) && roots.allSatisfy {
            matches($0) || ($0.order.map { $0 > order } ?? false)
        }
    }
    static func snapshotHasTailscaleDefaultExcludingRootResolver(_ text: String, port: UInt16, order: Int) -> Bool {
        let roots = resolvers(text).filter { $0.rootSection && !$0.scoped && ($0.domain == nil || $0.domain == "" || $0.domain == ".") }
        let isOwn: (Resolver) -> Bool = { $0.servers == ["127.0.0.1"] && $0.port == Int(port) && $0.order == order }
        guard roots.contains(where: isOwn) else { return false }
        let remaining = roots.filter { !isOwn($0) }
        guard !remaining.isEmpty, remaining.allSatisfy({ $0.order != nil }),
              let priority = remaining.compactMap(\.order).min() else { return false }
        return remaining.filter { $0.order == priority }.allSatisfy {
            $0.port == 53 && ScopedDNSController.usesTailscaleDefaultDNS(["ServerAddresses": $0.servers])
        }
    }
    static func snapshotContainsLoopbackResolver(_ text: String, port: UInt16) -> Bool {
        resolvers(text).contains { $0.port == Int(port) && $0.servers.contains(where: { $0 == "127.0.0.1" || $0 == "::1" }) }
    }
    private struct Resolver {
        var rootSection = true
        var servers: [String] = []
        var port = 53
        var order: Int?
        var domain: String?
        var scoped = false
    }
    private static func resolvers(_ text: String) -> [Resolver] {
        var result: [Resolver] = [], current: Resolver?, rootSection = true
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration") {
                if let current { result.append(current) }; current = nil
                rootSection = !line.contains("(")
            } else if line.hasPrefix("resolver #") {
                if let current { result.append(current) }
                current = Resolver(rootSection: rootSection)
            } else if current != nil {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces), value = parts[1].trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("nameserver[") { current?.servers.append(value) }
                else if key == "port" { current?.port = Int(value) ?? 53 }
                else if key == "order" { current?.order = Int(value) }
                else if key == "domain" { current?.domain = value }
                else if key == "flags", value.contains("Scoped") { current?.scoped = true }
            }
        }
        if let current { result.append(current) }
        return result
    }
    static func readSnapshot() throws -> String {
        let process = Process(), pipe = Pipe(), output = ScopedDNSOutput(), done = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil"); process.arguments = ["--dns"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }; output.append(data)
            }
            done.signal()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 0.05); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw ScopedDNSControllerError.notAdopted }
        guard done.wait(timeout: .now() + 0.5) == .success, process.terminationStatus == 0,
              let text = output.text, text.contains("DNS configuration") || text.contains("No DNS configuration available") else {
            throw ScopedDNSControllerError.notAdopted
        }
        return text
    }
}

private final class ScopedDNSOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var exceeded = false
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; if data.count + chunk.count <= 2 * 1024 * 1024 { data.append(chunk) } else { exceeded = true } }
    var text: String? { lock.lock(); defer { lock.unlock() }; return exceeded ? nil : String(data: data, encoding: .utf8) }
}

/// Read-only loopback queries prove both listeners can process a framed DNS
/// request before any system resolver points at them. No application name is
/// queried and any well-formed DNS response code is acceptable for this check.
private enum ScopedDNSLoopbackHealth {
    static func check(port: UInt16) -> Bool { probe(port: port, tcp: false) && probe(port: port, tcp: true) }
    private static func probe(port: UInt16, tcp: Bool) -> Bool {
        let fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return false }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { return false }
        let query: [UInt8] = [0x52, 0x57, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 9] + Array("localhost".utf8) + [0, 0, 1, 0, 1]
        let payload = tcp ? [UInt8(query.count >> 8), UInt8(query.count & 255)] + query : query
        guard payload.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == payload.count else { return false }
        var response: [UInt8]
        if tcp {
            guard let prefix = read(fd, count: 2) else { return false }
            let length = Int(prefix[0]) * 256 + Int(prefix[1])
            guard (12...4096).contains(length), let packet = read(fd, count: length) else { return false }
            response = packet
        } else {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count >= 12 else { return false }; response = Array(buffer.prefix(count))
        }
        return response.count >= 12 && response[0] == 0x52 && response[1] == 0x57 && response[2] & 0x80 != 0
    }
    private static func read(_ fd: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count), offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            if received < 0 && errno == EINTR { continue }
            guard received > 0 else { return nil }; offset += received
        }
        return bytes
    }
}
