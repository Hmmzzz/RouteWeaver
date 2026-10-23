import XCTest
import RouteCore
@testable import RouteHelper

final class RecoveryCoordinatorAsyncTests: XCTestCase {
    func testStopCancelsDiscoveryWithoutWaitingForItsTimeout() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate()
        defer { gate.release() }
        let coordinator = try fixture.coordinator { token in try gate.wait(token: token); return fixture.network }
        _ = try coordinator.apply(routes: fixture.routes)
        let refreshDone = expectation(description: "cancelled refresh released")
        coordinator.refreshAsync { refreshDone.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        let stopped = expectation(description: "stop completed")
        let start = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().async {
            do { let status = try coordinator.stop(); XCTAssertFalse(status.enabled) } catch { XCTFail("\(error)") }
            stopped.fulfill()
        }
        wait(for: [stopped, refreshDone], timeout: 1)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
        XCTAssertEqual(fixture.engine.adds, 0)
        XCTAssertEqual(fixture.engine.active, 0)
        XCTAssertFalse(fixture.store.policy.enabled)
    }

    func testLateUncooperativeDiscoveryCannotReviveStoppedGeneration() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate()
        defer { gate.release() }
        let coordinator = try fixture.coordinator { _ in try gate.wait(); return fixture.network }
        _ = try coordinator.apply(routes: fixture.routes)
        let refreshDone = expectation(description: "stale refresh released")
        coordinator.refreshAsync { refreshDone.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        let stopped = expectation(description: "stop after stale completion")
        DispatchQueue.global().async {
            do { _ = try coordinator.stop() } catch { XCTFail("\(error)") }
            stopped.fulfill()
        }
        XCTAssertTrue(eventually { !coordinator.status().enabled })
        gate.release()
        wait(for: [stopped, refreshDone], timeout: 1)
        XCTAssertNil(coordinator.status().network)
        XCTAssertEqual(fixture.engine.adds, 0)
        XCTAssertFalse(fixture.publications.containsReady)
    }

    func testLateApplyEffectsAreRolledBackBeforeStopCompletes() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate()
        defer { gate.release() }
        let coordinator = try fixture.coordinator()
        _ = try coordinator.apply(routes: fixture.routes)
        coordinator.refresh(); fixture.clock.advance(2)
        fixture.engine.applyHook = { _ in try gate.wait() }
        let refreshDone = expectation(description: "interrupted apply released")
        coordinator.refreshAsync { refreshDone.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        let stopped = expectation(description: "cleanup follows apply")
        DispatchQueue.global().async {
            do {
                let status = try coordinator.stop()
                XCTAssertFalse(status.enabled); XCTAssertEqual(status.report.active, 0)
            } catch { XCTFail("\(error)") }
            stopped.fulfill()
        }
        XCTAssertTrue(eventually { !coordinator.status().enabled })
        gate.release()
        wait(for: [stopped, refreshDone], timeout: 1)
        XCTAssertEqual(fixture.engine.adds, 1)
        XCTAssertEqual(fixture.engine.active, 0)
        XCTAssertFalse(fixture.publications.containsReady)
    }

    func testRefreshFloodCoalescesIntoOneFollowingObservationAndReleasesAllWaiters() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate()
        defer { gate.release() }
        let coordinator = try fixture.coordinator { token in
            if fixture.discoveryCount == 1 { try gate.wait(token: token) }
            return fixture.network
        }
        _ = try coordinator.apply(routes: fixture.routes)
        let done = expectation(description: "all refresh callbacks"); done.expectedFulfillmentCount = 101
        coordinator.refreshAsync { done.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        for _ in 0..<100 { coordinator.refreshAsync { done.fulfill() } }
        // Identical policy is a state-queue barrier without another refresh in
        // this deterministic scheduling mode.
        _ = try coordinator.apply(routes: fixture.routes)
        XCTAssertEqual(fixture.discoveryCount, 1)
        gate.release()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fixture.discoveryCount, 2)
        XCTAssertEqual(fixture.engine.adds, 0)
    }

    func testRefreshCompletionCanSynchronouslyStopWithoutDeadlock() throws {
        let fixture = AsyncRecoveryFixture(), coordinator = try fixture.coordinator()
        _ = try coordinator.apply(routes: fixture.routes)
        let done = expectation(description: "reentrant stop")
        coordinator.refreshAsync {
            do { let status = try coordinator.stop(); XCTAssertFalse(status.enabled) } catch { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(fixture.engine.active, 0)
    }

    func testContinuousRawInvalidationsCleanRoutesBeforeSettlingWithoutRediscovery() throws {
        let fixture = AsyncRecoveryFixture(), coordinator = try fixture.coordinator()
        try fixture.activate(coordinator)
        let discoveries = fixture.discoveryCount, adds = fixture.engine.adds, removals = fixture.engine.rollbacks
        for _ in 0..<6 {
            coordinator.networkTopologyInvalidated()
            usleep(10_000)
        }
        XCTAssertTrue(eventually { fixture.engine.active == 0 && fixture.engine.rollbacks > removals })
        XCTAssertEqual(fixture.discoveryCount, discoveries)
        XCTAssertEqual(fixture.engine.adds, adds)
        XCTAssertTrue(fixture.publications.lastRoutes.isEmpty)
    }

    func testShutdownCancelsDiscoveryButRetainsSavedEnableIntent() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate()
        defer { gate.release() }
        let coordinator = try fixture.coordinator { token in try gate.wait(token: token); return fixture.network }
        _ = try coordinator.apply(routes: fixture.routes)
        let refreshDone = expectation(description: "shutdown refresh released")
        coordinator.refreshAsync { refreshDone.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        let shutdownDone = expectation(description: "shutdown finished")
        DispatchQueue.global().async { coordinator.shutdown(); shutdownDone.fulfill() }
        wait(for: [shutdownDone, refreshDone], timeout: 1)
        XCTAssertTrue(fixture.store.policy.enabled)
        XCTAssertEqual(fixture.engine.active, 0)
        XCTAssertEqual(fixture.engine.adds, 0)
        let discoveries = fixture.discoveryCount
        coordinator.refresh()
        XCTAssertEqual(fixture.discoveryCount, discoveries)
        XCTAssertFalse(fixture.publications.containsReady)
    }

    func testStopJoiningShutdownStillPersistsDisabledIntent() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate(), coordinator = try fixture.coordinator()
        defer { gate.release() }
        try fixture.activate(coordinator)
        let priorRollbacks = fixture.engine.rollbacks
        fixture.engine.rollbackHook = {
            if fixture.engine.rollbacks == priorRollbacks + 1 { try gate.wait() }
        }
        let shutdownDone = expectation(description: "joined shutdown finished")
        DispatchQueue.global().async { coordinator.shutdown(); shutdownDone.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        let stopped = expectation(description: "joined stop finished")
        DispatchQueue.global().async {
            do { let status = try coordinator.stop(); XCTAssertFalse(status.enabled) } catch { XCTFail("\(error)") }
            stopped.fulfill()
        }
        XCTAssertTrue(eventually { !coordinator.status().enabled })
        gate.release()
        wait(for: [stopped, shutdownDone], timeout: 1)
        XCTAssertFalse(fixture.store.policy.enabled)
        XCTAssertEqual(fixture.engine.active, 0)
        XCTAssertTrue(fixture.publications.lastRoutes.isEmpty)
    }

    func testPolicyReplacementDiscardsOldDiscoveryAndReleasesOriginalRefreshWaiter() throws {
        let fixture = AsyncRecoveryFixture(), gate = AsyncRecoveryGate()
        defer { gate.release() }
        let coordinator = try fixture.coordinator { _ in
            if fixture.discoveryCount == 1 { try gate.wait() }
            return fixture.network
        }
        _ = try coordinator.apply(routes: fixture.routes)
        let done = expectation(description: "replacement refresh finished")
        coordinator.refreshAsync { done.fulfill() }
        XCTAssertTrue(gate.waitUntilEntered())
        let replacement = ["114.114.114.0/24"]
        _ = try coordinator.apply(routes: replacement)
        gate.release()
        wait(for: [done], timeout: 1)
        XCTAssertEqual(fixture.discoveryCount, 2)
        XCTAssertEqual(fixture.engine.adds, 0)
        XCTAssertEqual(fixture.store.policy.routes, replacement)
        fixture.clock.advance(2); coordinator.refresh()
        XCTAssertEqual(fixture.engine.lastAppliedRoutes, replacement)
        XCTAssertEqual(fixture.engine.adds, 1)
        XCTAssertEqual(fixture.publications.lastRoutes, replacement)
    }

    func testFailedTopologyCleanupHonorsBackoffAcrossRefreshes() throws {
        let fixture = AsyncRecoveryFixture(), coordinator = try fixture.coordinator()
        try fixture.activate(coordinator)
        fixture.engine.rejectRollback = true
        let before = fixture.engine.rollbacks
        coordinator.networkTopologyInvalidated()
        XCTAssertTrue(eventually { fixture.engine.rollbacks > before && coordinator.status().phase == .backingOff })
        let failures = fixture.engine.rollbacks
        coordinator.networkTopologySettled()
        for _ in 0..<3 { coordinator.refresh() }
        XCTAssertEqual(fixture.engine.rollbacks, failures)
        fixture.clock.advance(1); coordinator.refresh()
        XCTAssertEqual(fixture.engine.rollbacks, failures)
        fixture.clock.advance(2); coordinator.refresh()
        XCTAssertEqual(fixture.engine.rollbacks, failures + 1)
        XCTAssertEqual(fixture.engine.adds, 1)
        XCTAssertTrue(fixture.publications.lastRoutes.isEmpty)
    }

    private func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            if predicate() { return true }
            usleep(1_000)
        }
        return predicate()
    }
}

private final class AsyncRecoveryFixture {
    let routes = ["223.5.5.0/24"]
    let network = NetworkContext(gateway: "192.168.1.1", interface: "en0", exitNodeID: "exit-a", exitNodeName: "A", tailscaleInterfaces: ["utun7"])
    let engine = AsyncRecoveryEngine(), store = AsyncRecoveryStore(), clock = AsyncRecoveryClock(), publications = AsyncRecoveryPublications()
    private let lock = NSLock()
    private var discoveries = 0
    var discoveryCount: Int { lock.withValue { discoveries } }
    func coordinator(discover: ((RecoveryCancellation) throws -> NetworkContext?)? = nil) throws -> RecoveryCoordinator {
        try RecoveryCoordinator(ownerUID: 501, engine: engine, store: store, discoverCancellable: { token in
            self.lock.withValue { self.discoveries += 1 }
            if let discover { return try discover(token) }
            return self.network
        }, monotonicTime: { self.clock.now }, automaticScheduling: false,
            compileRoutes: { routes, _ in routes },
            networkRoutingStateChanged: { _, routes in self.publications.append(routes) })
    }
    func activate(_ coordinator: RecoveryCoordinator) throws {
        _ = try coordinator.apply(routes: routes)
        coordinator.refresh(); clock.advance(2); coordinator.refresh()
        XCTAssertEqual(coordinator.status().phase, .active)
        XCTAssertEqual(engine.active, 1)
    }
}
private final class AsyncRecoveryGate {
    private let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 1) == .success }
    func release() { released.signal() }
    func wait(token: RecoveryCancellation? = nil) throws {
        entered.signal()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while released.wait(timeout: .now() + .milliseconds(5)) != .success {
            try token?.throwIfCancelled()
            if ProcessInfo.processInfo.systemUptime >= deadline { throw HelperError("fixture gate timed out") }
        }
        try token?.throwIfCancelled()
    }
}
private final class AsyncRecoveryClock {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    var now: TimeInterval { lock.withValue { value } }
    func advance(_ amount: TimeInterval) { lock.withValue { value += amount } }
}
private final class AsyncRecoveryStore: PolicyStoring {
    private let lock = NSLock()
    private var value = DesiredPolicy()
    var policy: DesiredPolicy { lock.withValue { value } }
    func load() throws -> DesiredPolicy { policy }
    func save(_ policy: DesiredPolicy) throws { lock.withValue { value = policy } }
}
private final class AsyncRecoveryPublications {
    private let lock = NSLock()
    private var values: [[String]] = []
    var lastRoutes: [String] { lock.withValue { values.last ?? [] } }
    var containsReady: Bool { lock.withValue { values.contains { !$0.isEmpty } } }
    func append(_ routes: [String]) { lock.withValue { values.append(routes) } }
}
private final class AsyncRecoveryEngine: RecoveryEngine {
    private let lock = NSLock()
    private var activeValue = 0, addsValue = 0, rollbacksValue = 0
    private var lastAppliedRoutesValue: [String] = []
    private var rejectRollbackValue = false
    private var applyHookValue: ((RecoveryCancellation) throws -> Void)?
    private var rollbackHookValue: (() throws -> Void)?
    var active: Int { lock.withValue { activeValue } }
    var adds: Int { lock.withValue { addsValue } }
    var rollbacks: Int { lock.withValue { rollbacksValue } }
    var lastAppliedRoutes: [String] { lock.withValue { lastAppliedRoutesValue } }
    var rejectRollback: Bool {
        get { lock.withValue { rejectRollbackValue } }
        set { lock.withValue { rejectRollbackValue = newValue } }
    }
    var applyHook: ((RecoveryCancellation) throws -> Void)? {
        get { lock.withValue { applyHookValue } }
        set { lock.withValue { applyHookValue = newValue } }
    }
    var rollbackHook: (() throws -> Void)? {
        get { lock.withValue { rollbackHookValue } }
        set { lock.withValue { rollbackHookValue = newValue } }
    }
    func apply(_ request: ApplyRequest) throws -> Report { try apply(request, cancellation: RecoveryCancellation()) }
    func apply(_ request: ApplyRequest, cancellation: RecoveryCancellation) throws -> Report {
        try cancellation.throwIfCancelled()
        let hook = lock.withValue { addsValue += 1; return applyHookValue }
        try hook?(cancellation)
        return lock.withValue {
            activeValue = request.routes.count; lastAppliedRoutesValue = request.routes
            var report = Report(); report.active = activeValue; report.verified = true; return report
        }
    }
    func rollback() throws -> Report {
        let (reject, hook) = lock.withValue { rollbacksValue += 1; return (rejectRollbackValue, rollbackHookValue) }
        try hook?()
        if reject { throw HelperError("fixture rollback failed") }
        return lock.withValue { activeValue = 0; return Report() }
    }
    func inspectHealth(desiredRoutes: [String]) throws -> RouteHealth {
        lock.withValue {
            var report = Report(); report.active = activeValue; report.verified = true
            return RouteHealth(report: report, hasMissingOwnedRoutes: false)
        }
    }
}
private extension NSLock {
    func withValue<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
