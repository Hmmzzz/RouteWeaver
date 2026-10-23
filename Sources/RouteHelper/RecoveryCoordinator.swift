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
    func apply(_ request: ApplyRequest, cancellation: RecoveryCancellation) throws -> Report
    func rollback() throws -> Report
    func inspectHealth(desiredRoutes: [String]) throws -> RouteHealth
}
extension RecoveryEngine {
    func apply(_ request: ApplyRequest, cancellation: RecoveryCancellation) throws -> Report {
        try cancellation.throwIfCancelled()
        return try apply(request)
    }
    func inspectHealth() throws -> RouteHealth { try inspectHealth(desiredRoutes: []) }
}
extension Engine: RecoveryEngine {}
protocol PolicyStoring {
    func load() throws -> DesiredPolicy
    func save(_ policy: DesiredPolicy) throws
}

final class RecoveryCoordinator {
    // State and event admission never wait for an external command. All engine
    // and journal operations, including rollback, share one serialized worker.
    private let queue = DispatchQueue(label: "com.routeweaver.recovery", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let worker = DispatchQueue(label: "com.routeweaver.recovery.worker", qos: .utility)
    private let completions = DispatchQueue(label: "com.routeweaver.recovery.completions", qos: .utility, attributes: .concurrent)
    private let cacheLock = NSLock()
    private var cached = RecoveryStatus()
    private let ownerUID: uid_t
    private let engine: any RecoveryEngine
    private let store: any PolicyStoring
    private let discover: (RecoveryCancellation) throws -> NetworkContext?
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
    private var generation: UInt64 = 0
    private enum WorkKind { case discovery, health, apply, rollback, topologyRollback }
    private struct Work {
        let id = UUID()
        let generation: UInt64
        let kind: WorkKind
        let cancellation = RecoveryCancellation()
    }
    private var work: Work?
    private var cycleRunning = false
    private var refreshPending = false
    private var topologyDebouncing = false
    // An interrupted first apply can have durable effects even though the state
    // machine has never recorded a successful applied fingerprint.
    private var mustCleanup = false
    private var cycleWaiters: [() -> Void] = []
    private var pendingWaiters: [() -> Void] = []
    private enum ControlCleanup { case stop(Error?), shutdown }
    private var controlCleanup: ControlCleanup?
    private var stopWaiters: [(RecoveryStatus) -> Void] = []
    private var shutdownWaiters: [() -> Void] = []

    convenience init(ownerUID: uid_t, engine: Engine,
                     networkRoutingStateChanged: @escaping (NetworkContext?, [String]) -> Void = { _, _ in }) throws {
        try self.init(ownerUID: ownerUID, engine: engine, store: PolicyStore(),
            discoverCancellable: { try discoverNetwork(ownerUID: ownerUID, cancellation: $0) },
            networkRoutingStateChanged: networkRoutingStateChanged)
    }
    convenience init(ownerUID: uid_t, engine: any RecoveryEngine, store: any PolicyStoring,
         discover: @escaping () throws -> NetworkContext?, monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticScheduling: Bool = true,
         compileRoutes: @escaping ([String], NetworkContext) throws -> [String] = { routes, network in
             try PolicyCompiler.compile(countryCIDRs: routes, rules: [], excludedAddresses: [network.gateway, "8.8.8.8"]).map(\.description)
         },
         networkRoutingStateChanged: @escaping (NetworkContext?, [String]) -> Void = { _, _ in }) throws {
        try self.init(ownerUID: ownerUID, engine: engine, store: store,
            discoverCancellable: { token in try token.throwIfCancelled(); return try discover() },
            monotonicTime: monotonicTime, automaticScheduling: automaticScheduling,
            compileRoutes: compileRoutes, networkRoutingStateChanged: networkRoutingStateChanged)
    }
    init(ownerUID: uid_t, engine: any RecoveryEngine, store: any PolicyStoring,
         discoverCancellable: @escaping (RecoveryCancellation) throws -> NetworkContext?,
         monotonicTime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         automaticScheduling: Bool = true,
         compileRoutes: @escaping ([String], NetworkContext) throws -> [String] = { routes, network in
             try PolicyCompiler.compile(countryCIDRs: routes, rules: [], excludedAddresses: [network.gateway, "8.8.8.8"]).map(\.description)
         },
         networkRoutingStateChanged: @escaping (NetworkContext?, [String]) -> Void = { _, _ in }) throws {
        self.ownerUID = ownerUID; self.engine = engine
        self.store = store; policy = try store.load()
        discover = discoverCancellable; self.monotonicTime = monotonicTime; self.automaticScheduling = automaticScheduling
        self.compileRoutes = compileRoutes
        self.networkRoutingStateChanged = networkRoutingStateChanged
        policy.routes = try Self.validate(policy.routes, allowEmpty: !policy.enabled)
        if policy.enabled { machine.enable() } else { machine.disable() }
        queue.setSpecific(key: queueKey, value: 1)
        publish()
    }
    func start() {
        queue.async { [weak self] in
            guard let self, !self.shuttingDown, self.monitor == nil else { return }
            self.monitor = NetworkMonitor(queue: self.queue, onTopologyInvalidated: { [weak self] in
                self?.networkTopologyInvalidated()
            }) { [weak self] changed in
                guard let self else { return }
                if changed { self.networkTopologySettled() }
                else { self.requestRefresh() }
            }
            self.monitor?.start(); self.requestRefresh()
        }
    }
    func status() -> RecoveryStatus {
        cacheLock.lock(); defer { cacheLock.unlock() }; return cached
    }
    func apply(routes: [String]) throws -> RecoveryStatus {
        let validated = try Self.validate(routes, allowEmpty: false)
        return try serialized {
            try require(!shuttingDown && controlCleanup == nil, "正在停止后台操作，请稍后重试")
            if policy.enabled && policy.routes == validated {
                if automaticScheduling { requestRefresh() }
                return status()
            }
            let next = DesiredPolicy(enabled: true, routes: validated)
            try store.save(next)
            invalidateWork()
            policy = next; disableNeedsPersistence = false; appliedPlan = nil; machine.enable()
            report.message = "规则已保存，正在等待网络稳定后自动应用"
            publish()
            if automaticScheduling { requestRefresh() }
            return status()
        }
    }
    func stop() throws -> RecoveryStatus {
        let finished = DispatchSemaphore(value: 0)
        var result = RecoveryStatus()
        queue.async { [self] in
            stopWaiters.append { result = $0; finished.signal() }
            // A concurrent shutdown preserves saved intent; an explicit stop
            // must still persist disabled intent before joining its cleanup.
            if case .stop = controlCleanup { return }
            invalidateWork()
            var next = policy; next.enabled = false
            policy = next; appliedPlan = nil; machine.disable()
            var persistenceError: Error?
            do { try store.save(next); disableNeedsPersistence = false }
            catch { disableNeedsPersistence = true; persistenceError = error }
            topologyDebouncing = false
            networkRoutingStateChanged(currentNetwork, [])
            wakeup?.cancel(); wakeup = nil
            publish(notifyDependentConfiguration: false)
            controlCleanup = .stop(persistenceError)
            drive()
        }
        // The IPC caller waits for actual cleanup, never the state/event queue.
        finished.wait()
        return result
    }
    /// Termination removes live routes while retaining the user's saved intent.
    func shutdown() {
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            shutdownWaiters.append { finished.signal() }
            invalidateWork()
            shuttingDown = true; appliedPlan = nil; topologyDebouncing = false
            networkRoutingStateChanged(currentNetwork, [])
            monitor = nil; wakeup?.cancel(); wakeup = nil
            publish(notifyDependentConfiguration: false)
            controlCleanup = .shutdown
            drive()
        }
        finished.wait()
    }
    /// Synchronous callers/tests can wait for one full observation without
    /// preventing stop or topology events from cancelling that observation.
    func refresh() {
        let finished = DispatchSemaphore(value: 0)
        refreshAsync { finished.signal() }
        finished.wait()
    }
    func refreshAsync(completion: @escaping () -> Void = {}) {
        queue.async { [self] in requestRefresh(completion: completion) }
    }
    /// Called for each meaningful raw event, before the monitor's debounce.
    /// It invalidates old results immediately; rediscovery waits for settling.
    func networkTopologyInvalidated() {
        serialized {
            guard !shuttingDown, policy.enabled else { return }
            invalidateWork()
            if !topologyDebouncing { mustCleanup = true }
            topologyDebouncing = true; appliedPlan = nil
            machine.invalidateTopology()
            wakeup?.cancel(); wakeup = nil
            networkRoutingStateChanged(currentNetwork, [])
            publish(notifyDependentConfiguration: false)
            drive()
        }
    }
    func networkTopologySettled() {
        serialized { topologyDebouncing = false; requestRefresh() }
    }
    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try queue.sync(execute: body)
    }
    private var now: TimeInterval { monotonicTime() }
    private func invalidateWork() {
        generation &+= 1
        if work?.kind == .apply { mustCleanup = true }
        // Cleanup is serialized and remains valid across further topology
        // events. Only discovery and applying need their result invalidated.
        if work?.kind != .topologyRollback { work?.cancellation.cancel() }
    }
    private func requestRefresh(completion: (() -> Void)? = nil) {
        if let completion { pendingWaiters.append(completion) }
        refreshPending = true
        drive()
    }
    private func drive() {
        guard work == nil else { return }
        if let cleanup = controlCleanup { beginControlCleanup(cleanup); return }
        guard !cycleRunning else { return }
        if shuttingDown { finishCycle(); return }
        if topologyDebouncing && mustCleanup && now >= machine.retryAt {
            performRollback(kind: .topologyRollback) { [self] in
                publish(); drive()
            }
            return
        }
        guard !topologyDebouncing, refreshPending else { return }
        refreshPending = false; cycleRunning = true
        cycleWaiters.append(contentsOf: pendingWaiters); pendingWaiters.removeAll()
        reconcile()
    }
    private func runWork<T>(_ kind: WorkKind, operation: @escaping (RecoveryCancellation) throws -> T,
                            completion: @escaping (Result<T, Error>) -> Void) {
        precondition(work == nil)
        let job = Work(generation: generation, kind: kind)
        work = job
        worker.async { [self] in
            let result = Result { try job.cancellation.throwIfCancelled(); return try operation(job.cancellation) }
            queue.async { [self] in
                guard work?.id == job.id else { return }
                work = nil
                guard job.kind == .topologyRollback || (job.generation == generation && !job.cancellation.isCancelled) else {
                    cycleRunning = false
                    pendingWaiters.append(contentsOf: cycleWaiters); cycleWaiters.removeAll()
                    if !pendingWaiters.isEmpty { refreshPending = true }
                    drive()
                    return
                }
                completion(result)
            }
        }
    }
    private func reconcile() {
        wakeup?.cancel(); wakeup = nil
        if disableNeedsPersistence {
            guard now >= machine.retryAt else { finishCycle(); return }
            do { try store.save(policy); disableNeedsPersistence = false; machine.disable() }
            catch {
                performRollback { [self] in
                    report.failed = max(1, report.failed)
                    report.message = "分流保持关闭，保存关闭状态失败：\(error)"
                    machine.observationFailed(now: now)
                    finishCycle()
                }
                return
            }
        }
        // Topology events and policy replacement still clean ownership first.
        // The rule-update behavior is deliberately unchanged by this work.
        if now < machine.retryAt { finishCycle(); return }
        if mustCleanup || machine.decide(fingerprint: currentNetwork?.fingerprint, now: now) == .rollback {
            performRollback { [self] in afterInitialCleanup() }
        } else { afterInitialCleanup() }
    }
    private func afterInitialCleanup() {
        if machine.phase == .backingOff && now < machine.retryAt { finishCycle(); return }
        guard machine.enabled, !topologyDebouncing else { finishCycle(); return }
        runWork(.discovery, operation: discover) { [self] result in
            do {
                let previous = currentNetwork?.fingerprint
                currentNetwork = try result.get(); checkedAt = Date()
                if previous != currentNetwork?.fingerprint { appliedPlan = nil; machine.invalidateTopology() }
                if currentNetwork != nil && machine.phase == .active {
                    let desired = appliedPlan.flatMap { $0.fingerprint == currentNetwork?.fingerprint ? $0.routes : nil } ?? []
                    runWork(.health, operation: { [engine] _ in try engine.inspectHealth(desiredRoutes: desired) }) { [self] result in
                        do { evaluateAction(health: try result.get()) }
                        catch { observationFailed(error) }
                    }
                } else { evaluateAction(health: nil) }
            } catch { observationFailed(error) }
        }
    }
    private func evaluateAction(health: RouteHealth?) {
        let action = machine.decide(fingerprint: currentNetwork?.fingerprint,
                                    repairNeeded: health?.needsRepair ?? false, now: now)
        if let health { publishHealth(health.report) }
        if action == .rollback {
            performRollback { [self] in evaluateAction(health: nil) }
        } else if action == .apply, let network = currentNetwork {
            appliedPlan = nil; publish()
            let desired = policy.routes
            runWork(.apply, operation: { [engine, compileRoutes] token in
                let routes = try compileRoutes(desired, network)
                try require(!routes.isEmpty, "当前网络下没有可应用的直连规则")
                try token.throwIfCancelled()
                let request = ApplyRequest(routes: routes, gateway: network.gateway,
                                           interface: network.interface, exitNodeID: network.exitNodeID)
                return (try engine.apply(request, cancellation: token), routes)
            }) { [self] result in
                do {
                    let (updated, routes) = try result.get()
                    report = updated; checkedAt = Date()
                    let succeeded = report.failed == 0 && report.pending == 0
                    if succeeded { appliedPlan = (network.fingerprint, routes) }
                    machine.didApply(fingerprint: network.fingerprint, success: succeeded, now: now)
                } catch {
                    report.failed += 1; report.message = "应用失败，稍后重试：\(error)"
                    machine.didApply(fingerprint: network.fingerprint, success: false, now: now)
                }
                finishCycle()
            }
        } else if health != nil {
            finishCycle()
        } else {
            runWork(.health, operation: { [engine] _ in try engine.inspectHealth() }) { [self] result in
                do { publishHealth(try result.get().report); finishCycle() }
                catch { observationFailed(error) }
            }
        }
    }
    private func publishHealth(_ health: Report) {
        report.active = health.active; report.pending = health.pending; report.verified = health.verified
        report.skipped = health.skipped
        checkedAt = Date()
        if currentNetwork == nil { report.message = "等待物理网络与在线 exit node；已停止自动添加路由" }
    }
    private func observationFailed(_ error: Error) {
        appliedPlan = nil
        if currentNetwork != nil { machine.invalidateTopology() }
        currentNetwork = nil
        report.message = "网络检查未通过：\(error)"
        let finish = { [self] in machine.observationFailed(now: now); finishCycle() }
        if mustCleanup || machine.decide(fingerprint: nil, now: now) == .rollback {
            performRollback(completion: finish)
        } else { finish() }
    }
    private func performRollback(kind: WorkKind = .rollback, completion: @escaping () -> Void) {
        appliedPlan = nil
        networkRoutingStateChanged(currentNetwork, [])
        runWork(kind, operation: { [engine] _ in try engine.rollback() }) { [self] result in
            switch result {
            case .success(let updated):
                report = updated; checkedAt = Date()
                let succeeded = report.failed == 0 && report.active == 0 && report.pending == 0
                mustCleanup = !succeeded
                machine.didRollback(success: succeeded, now: now)
            case .failure(let error):
                report.failed += 1; report.message = "旧路由撤销失败，停止添加新路由：\(error)"
                mustCleanup = true; machine.didRollback(success: false, now: now)
            }
            completion()
        }
    }
    private func beginControlCleanup(_ intent: ControlCleanup) {
        runWork(.rollback, operation: { [engine] _ in try engine.rollback() }) { [self] result in
            let persistenceError: Error?
            switch intent { case .stop(let error): persistenceError = error; case .shutdown: persistenceError = nil }
            switch result {
            case .success(let updated):
                report = updated; checkedAt = Date()
                let succeeded = report.failed == 0 && report.pending == 0 && report.active == 0
                mustCleanup = !succeeded
                if case .stop = intent { machine.didRollback(success: succeeded && persistenceError == nil, now: now) }
            case .failure(let error):
                report.message = "撤销失败：\(error)"; report.failed += 1; mustCleanup = true
                if case .stop = intent { machine.didRollback(success: false, now: now) }
            }
            if let persistenceError {
                report.failed += 1
                report.message = "已停止本次分流，正在重试保存关闭状态：\(persistenceError)"
            }
            controlCleanup = nil; cycleRunning = false; refreshPending = false
            publish(); scheduleIfNeeded()
            let status = status(), stops = stopWaiters, shutdowns = shutdownWaiters
            stopWaiters.removeAll(); shutdownWaiters.removeAll()
            let waits = cycleWaiters + pendingWaiters
            cycleWaiters.removeAll(); pendingWaiters.removeAll()
            completions.async { stops.forEach { $0(status) }; shutdowns.forEach { $0() }; waits.forEach { $0() } }
        }
    }
    private func finishCycle() {
        cycleRunning = false
        publish(); scheduleIfNeeded()
        let waits = cycleWaiters
        cycleWaiters.removeAll()
        // A shutdown refresh is also completed without starting any worker.
        let extra = shuttingDown ? pendingWaiters : []
        if shuttingDown { pendingWaiters.removeAll(); refreshPending = false }
        completions.async { waits.forEach { $0() }; extra.forEach { $0() } }
        if refreshPending { queue.async { [weak self] in self?.drive() } }
    }
    private func scheduleIfNeeded() {
        guard automaticScheduling && !shuttingDown && !topologyDebouncing else { return }
        let delay: Double
        if machine.phase == .stabilizing { delay = machine.stabilityInterval }
        else if machine.phase == .backingOff { delay = max(0.2, machine.retryAt - now) }
        else { return }
        wakeup?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.requestRefresh() }
        wakeup = item; queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func publish(notifyDependentConfiguration: Bool = true) {
        let digest = policy.enabled ? SHA256.hash(data: Data(policy.routes.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined() : nil
        cacheLock.lock()
        cached = RecoveryStatus(enabled: policy.enabled, phase: machine.phase, network: currentNetwork, report: report, lastCheck: checkedAt, desiredRoutesDigest: digest)
        cacheLock.unlock()
        if notifyDependentConfiguration { networkRoutingStateChanged(currentNetwork, verifiedRoutesForDependentConfiguration) }
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
