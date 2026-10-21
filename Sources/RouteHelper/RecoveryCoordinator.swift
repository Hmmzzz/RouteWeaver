import Foundation
import Darwin
import RouteCore
import CryptoKit

struct RecoveryStatus: Codable {
    var enabled = false
    var phase = RecoveryStateMachine.Phase.disabled
    var network: NetworkContext?
    var report = Report()
    var lastCheck: Date?
    var desiredRoutesDigest: String?
}

struct DesiredPolicy: Codable {
    var version = 1
    var enabled = false
    var routes: [String] = []
}

protocol RecoveryEngine {
    func apply(_ request: ApplyRequest) throws -> Report
    func rollback() throws -> Report
    func inspectHealth() throws -> RouteHealth
}
extension Engine: RecoveryEngine {}
protocol PolicyStoring {
    func load() throws -> DesiredPolicy
    func save(_ policy: DesiredPolicy) throws
}

final class RecoveryCoordinator {
    private let queue = DispatchQueue(label: "com.routeweaver.recovery", qos: .utility)
    private let cacheLock = NSLock()
    private var cached = RecoveryStatus()
    private let ownerUID: uid_t
    private let engine: any RecoveryEngine
    private let store: any PolicyStoring
    private let discover: () throws -> NetworkContext?
    private let monotonicTime: () -> TimeInterval
    private let automaticScheduling: Bool
    private let compileRoutes: ([String], NetworkContext) throws -> [String]
    private var appliedPlan: (fingerprint: String, routes: [String])?
    private let networkRoutingStateChanged: (NetworkContext?, [String]) -> Void
    private var policy: DesiredPolicy
    private var machine = RecoveryStateMachine()
    private var monitor: NetworkMonitor?
    private var wakeup: DispatchWorkItem?
    private var currentNetwork: NetworkContext?
    private var report = Report()
    private var checkedAt: Date?
    private var shuttingDown = false
    private var disableNeedsPersistence = false

    convenience init(ownerUID: uid_t, engine: Engine,
                     networkRoutingStateChanged: @escaping (NetworkContext?, [String]) -> Void = { _, _ in }) throws {
        try self.init(ownerUID: ownerUID, engine: engine, store: PolicyStore(), discover: { try discoverNetwork(ownerUID: ownerUID) },
                      networkRoutingStateChanged: networkRoutingStateChanged)
    }
    init(ownerUID: uid_t, engine: any RecoveryEngine, store: any PolicyStoring,
         discover: @escaping () throws -> NetworkContext?, monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticScheduling: Bool = true,
         compileRoutes: @escaping ([String], NetworkContext) throws -> [String] = { routes, network in
             try PolicyCompiler.compile(countryCIDRs: routes, rules: [], excludedAddresses: [network.gateway, "8.8.8.8"]).map(\.description)
         },
         networkRoutingStateChanged: @escaping (NetworkContext?, [String]) -> Void = { _, _ in }) throws {
        self.ownerUID = ownerUID; self.engine = engine
        self.store = store; policy = try store.load()
        self.discover = discover; self.monotonicTime = monotonicTime; self.automaticScheduling = automaticScheduling
        self.compileRoutes = compileRoutes
        self.networkRoutingStateChanged = networkRoutingStateChanged
        policy.routes = try Self.validate(policy.routes, allowEmpty: !policy.enabled)
        if policy.enabled { machine.enable() } else { machine.disable() }
        publish()
    }
    func start() {
        queue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.monitor = NetworkMonitor(queue: self.queue) { [weak self] changed in
                guard let self else { return }
                if changed { self.appliedPlan = nil; self.machine.invalidateTopology() }
                self.reconcile()
            }
            self.monitor?.start(); self.reconcile()
        }
    }
    func status() -> RecoveryStatus {
        cacheLock.lock(); defer { cacheLock.unlock() }; return cached
    }
    func apply(routes: [String]) throws -> RecoveryStatus {
        let validated = try Self.validate(routes, allowEmpty: false)
        return try queue.sync {
            if policy.enabled && policy.routes == validated {
                if automaticScheduling { queue.async { [weak self] in self?.reconcile() } }
                return status()
            }
            let next = DesiredPolicy(enabled: true, routes: validated)
            try store.save(next); policy = next; disableNeedsPersistence = false; appliedPlan = nil; machine.enable()
            report.message = "规则已保存，正在等待网络稳定后自动应用"
            publish(); let result = status()
            if automaticScheduling { queue.async { [weak self] in self?.reconcile() } }
            return result
        }
    }
    func stop() throws -> RecoveryStatus {
        queue.sync {
            var next = policy; next.enabled = false
            // A disk error must not keep routing alive after the owner exits.
            // Disable in memory immediately, and retry the durable write while
            // remaining disabled. Startup also stops before accepting requests.
            policy = next; appliedPlan = nil; machine.disable()
            var persistenceError: Error?
            do { try store.save(next); disableNeedsPersistence = false }
            catch { disableNeedsPersistence = true; persistenceError = error }
            networkRoutingStateChanged(currentNetwork, [])
            wakeup?.cancel(); wakeup = nil
            do {
                report = try engine.rollback()
                checkedAt = Date()
                machine.didRollback(success: persistenceError == nil && report.failed == 0 && report.pending == 0 && report.active == 0, now: now)
            } catch {
                report.message = "自动恢复已关闭；撤销失败：\(error)"; report.failed += 1
                machine.didRollback(success: false, now: now)
            }
            if let persistenceError {
                report.failed += 1
                report.message = "已停止本次分流，正在重试保存关闭状态：\(persistenceError)"
            }
            publish(); scheduleIfNeeded(); return status()
        }
    }
    /// Termination removes live routes while retaining the user's saved intent.
    func shutdown() {
        queue.sync {
            shuttingDown = true; appliedPlan = nil
            networkRoutingStateChanged(currentNetwork, [])
            monitor = nil; wakeup?.cancel(); wakeup = nil
            do { report = try engine.rollback() }
            catch { report.message = "退出时撤销失败：\(error)" }
            publish()
        }
    }
    /// Serialized explicit refresh also permits deterministic injected checks.
    func refresh() { queue.sync { reconcile() } }
    private var now: TimeInterval { monotonicTime() }
    private func reconcile() {
        guard !shuttingDown else { publish(); return }
        wakeup?.cancel(); wakeup = nil
        if disableNeedsPersistence {
            guard now >= machine.retryAt else { publish(); scheduleIfNeeded(); return }
            do {
                try store.save(policy); disableNeedsPersistence = false
                // Reconfirm cleanup and replace any stale persistence failure
                // in the published status before reporting a clean shutdown.
                machine.disable()
            }
            catch {
                // Disk persistence and kernel cleanup are independent. Keep
                // retrying removal even while the disabled flag cannot be saved.
                performRollback()
                report.failed = max(1, report.failed)
                report.message = "分流保持关闭，保存关闭状态失败：\(error)"
                machine.observationFailed(now: now)
                publish(); scheduleIfNeeded(); return
            }
        }
        // Startup, policy replacement and topology events always clean old
        // ownership before waiting for an external CLI or selecting a gateway.
        if machine.decide(fingerprint: currentNetwork?.fingerprint, now: now) == .rollback {
            performRollback()
        }
        if machine.phase == .backingOff && now < machine.retryAt { publish(); scheduleIfNeeded(); return }
        guard machine.enabled else { publish(); scheduleIfNeeded(); return }
        do {
            let previousFingerprint = currentNetwork?.fingerprint
            currentNetwork = try discover()
            checkedAt = Date()
            if previousFingerprint != currentNetwork?.fingerprint { appliedPlan = nil; machine.invalidateTopology() }
            var health: RouteHealth? = nil
            if currentNetwork != nil && machine.phase == .active { health = try engine.inspectHealth() }
            var action = machine.decide(fingerprint: currentNetwork?.fingerprint, repairNeeded: health?.hasMissingOwnedRoutes ?? false, now: now)
            if action == .rollback {
                performRollback()
                health = nil // A pre-rollback snapshot cannot describe the remaining routes.
                action = machine.decide(fingerprint: currentNetwork?.fingerprint, now: now)
            }
            if action == .apply, let network = currentNetwork {
                appliedPlan = nil
                publish()
                do {
                    let routes = try compileRoutes(policy.routes, network)
                    try require(!routes.isEmpty, "当前网络下没有可应用的直连规则")
                    let request = ApplyRequest(routes: routes, gateway: network.gateway, interface: network.interface, exitNodeID: network.exitNodeID)
                    report = try engine.apply(request)
                    checkedAt = Date()
                    let succeeded = report.failed == 0 && report.pending == 0
                    if succeeded { appliedPlan = (network.fingerprint, routes) }
                    machine.didApply(fingerprint: network.fingerprint, success: succeeded, now: now)
                } catch {
                    report.failed += 1; report.message = "应用失败，稍后重试：\(error)"
                    machine.didApply(fingerprint: network.fingerprint, success: false, now: now)
                }
            } else {
                // A cached success must not keep advertising routes which the
                // kernel removed while the daemon or machine was suspended.
                let healthReport: Report
                if let health { healthReport = health.report }
                else { healthReport = try engine.inspectHealth().report }
                report.active = healthReport.active; report.pending = healthReport.pending; report.verified = healthReport.verified
                checkedAt = Date()
                if currentNetwork == nil { report.message = "等待物理网络与在线 exit node；已停止自动添加路由" }
            }
        } catch {
            appliedPlan = nil
            if currentNetwork != nil { machine.invalidateTopology() }
            currentNetwork = nil
            report.message = "网络检查未通过：\(error)"
            if machine.decide(fingerprint: nil, now: now) == .rollback { performRollback() }
            machine.observationFailed(now: now)
        }
        publish(); scheduleIfNeeded()
    }
    private func performRollback() {
        // Withdraw dependent network configuration before removing its routes,
        // including when the following ownership-safe rollback fails.
        appliedPlan = nil
        networkRoutingStateChanged(currentNetwork, [])
        do {
            report = try engine.rollback()
            checkedAt = Date()
            machine.didRollback(success: report.failed == 0 && report.active == 0 && report.pending == 0, now: now)
        } catch {
            report.failed += 1; report.message = "旧路由撤销失败，停止添加新路由：\(error)"
            machine.didRollback(success: false, now: now)
        }
    }
    private func scheduleIfNeeded() {
        guard automaticScheduling && !shuttingDown else { return }
        let delay: Double
        if machine.phase == .stabilizing { delay = machine.stabilityInterval }
        else if machine.phase == .backingOff { delay = max(0.2, machine.retryAt - now) }
        else { return }
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        wakeup = item; queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func publish() {
        let digest = policy.enabled ? SHA256.hash(data: Data(policy.routes.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined() : nil
        cacheLock.lock()
        cached = RecoveryStatus(enabled: policy.enabled, phase: machine.phase, network: currentNetwork, report: report, lastCheck: checkedAt, desiredRoutesDigest: digest)
        cacheLock.unlock()
        // Callbacks may read status(); never invoke them under cacheLock.
        networkRoutingStateChanged(currentNetwork, verifiedRoutesForDependentConfiguration)
    }
    private var verifiedRoutesForDependentConfiguration: [String] {
        guard !shuttingDown, policy.enabled, machine.phase == .active,
              report.verified, report.failed == 0, report.pending == 0, report.skipped == 0,
              let network = currentNetwork,
              let plan = appliedPlan, plan.fingerprint == network.fingerprint,
              !plan.routes.isEmpty, report.active == plan.routes.count else { return [] }
        return plan.routes
    }
    private static func validate(_ routes: [String], allowEmpty: Bool) throws -> [String] {
        try require(routes.count <= 20_000 && (allowEmpty || !routes.isEmpty), "规则数量必须在 1–20,000 之间")
        return try Set(routes.map { text in let cidr = try IPv4CIDR(text); try cidr.validateForBypass(); return cidr.description }).sorted()
    }
}

/// Root-private policy is deliberately separate from the ownership journal:
/// disabling restoration survives daemon restarts even if rollback fails.
private final class PolicyStore: PolicyStoring {
    private var directory: Int32 = -1
    init() throws {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try require(fd >= 0, "无法打开策略目录")
        do {
            for part in ["private", "var", "db", "com.routeweaver.service"] {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                try require(next >= 0, "服务策略目录未安装或不安全")
                close(fd); fd = next
                var info = stat()
                try require(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_mode & 0o022 == 0, "服务策略目录必须由 root 控制")
                if part == "com.routeweaver.service" { try require(info.st_mode & 0o077 == 0, "策略目录必须为 0700") }
            }
            directory = fd
        } catch { close(fd); throw error }
    }
    deinit { if directory >= 0 { close(directory) } }
    func load() throws -> DesiredPolicy {
        let fd = openat(directory, "policy.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return DesiredPolicy() }
        try require(fd >= 0, "无法读取恢复策略")
        defer { close(fd) }
        var info = stat()
        try require(fstat(fd, &info) == 0 && info.st_uid == 0 && info.st_nlink == 1 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o077 == 0 && info.st_size >= 0 && info.st_size <= 1024 * 1024, "恢复策略文件权限或大小异常")
        let policy = try JSONDecoder().decode(DesiredPolicy.self, from: readAll(fd, maximum: 1024 * 1024))
        try require(policy.version == 1, "不支持的恢复策略版本")
        return policy
    }
    func save(_ policy: DesiredPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        try require(data.count <= 1024 * 1024, "恢复策略超过大小限制")
        let name = "policy-\(UUID().uuidString).tmp"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(fd >= 0, "无法创建恢复策略")
        defer { close(fd); unlinkat(directory, name, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                try require(count > 0, "恢复策略写入失败"); offset += count
            }
        }
        try require(fsync(fd) == 0, "恢复策略同步失败")
        try require(renameat(directory, name, directory, "policy.json") == 0 && fsync(directory) == 0, "恢复策略提交失败")
    }
}
