import XCTest
import RouteCore
@testable import RouteHelper

private final class MemoryPolicy: PolicyStoring {
    var policy = DesiredPolicy()
    var writes = 0
    var rejectSave = false
    func load() throws -> DesiredPolicy { policy }
    func save(_ policy: DesiredPolicy) throws {
        if rejectSave { throw HelperError("simulated write failure") }
        self.policy = policy; writes += 1
    }
}
private final class RecoveryTestEngine: RecoveryEngine {
    var adds = 0, removals = 0, inspections = 0
    var active = 0
    var missing = false
    var rejectRollback = false
    var beforeRollback: (() -> Void)?
    var reportTransform: (Report) -> Report = { $0 }
    var requests: [ApplyRequest] = []
    func apply(_ request: ApplyRequest) throws -> Report {
        adds += 1; requests.append(request); active = request.routes.count; missing = false
        var report = Report(); report.active = active; report.verified = true; return reportTransform(report)
    }
    func rollback() throws -> Report {
        removals += 1
        beforeRollback?()
        if rejectRollback { throw HelperError("simulated rollback failure") }
        active = 0; return Report()
    }
    func status() throws -> Report { var report = Report(); report.active = active; report.verified = true; return reportTransform(report) }
    func inspectHealth() throws -> RouteHealth {
        inspections += 1
        return RouteHealth(report: try status(), hasMissingOwnedRoutes: missing)
    }
}
private final class RecoveryEnvironment {
    var time: TimeInterval = 100
    var network: NetworkContext? = .init(gateway: "192.168.1.1", interface: "en0", exitNodeID: "exit-a", exitNodeName: "A", tailscaleInterfaces: ["utun7"])
    var rejectDiscovery = false
    var compilations = 0
    let engine = RecoveryTestEngine()
    let policy = MemoryPolicy()
    func coordinator(networkRoutingStateChanged: @escaping (NetworkContext?, [String]) -> Void = { _, _ in }) throws -> RecoveryCoordinator {
        try RecoveryCoordinator(ownerUID: 501, engine: engine, store: policy, discover: {
            if self.rejectDiscovery { throw HelperError("simulated CLI failure") }
            return self.network
        }, monotonicTime: { self.time }, automaticScheduling: false, compileRoutes: { routes, network in
            self.compilations += 1
            return try PolicyCompiler.compile(countryCIDRs: routes, rules: [], excludedAddresses: [network.gateway, "8.8.8.8"]).map(\.description)
        }, networkRoutingStateChanged: networkRoutingStateChanged)
    }
    func activate(_ coordinator: RecoveryCoordinator) throws {
        _ = try coordinator.apply(routes: ["223.5.5.0/24"])
        coordinator.refresh(); time += 2; coordinator.refresh()
        XCTAssertEqual(coordinator.status().phase, .active)
    }
}

final class RecoveryCoordinatorTests: XCTestCase {
    func testActiveRefreshUsesOneHealthObservationForDecisionAndReport() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        let before = environment.engine.inspections
        coordinator.refresh()
        XCTAssertEqual(environment.engine.inspections, before + 1)
        XCTAssertEqual(coordinator.status().report.active, 1)
        XCTAssertEqual(routes, ["223.5.5.0/24"])
    }
    func testPendingOwnershipConflictWithdrawsDNSWithoutRepairingForeignRoute() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        environment.engine.reportTransform = { original in
            var report = original; report.active = 0; report.pending = 1; return report
        }
        let before = environment.engine.inspections
        coordinator.refresh()
        XCTAssertEqual(environment.engine.inspections, before + 1)
        XCTAssertEqual(coordinator.status().report.pending, 1)
        XCTAssertEqual(environment.engine.adds, 1)
        XCTAssertTrue(routes.isEmpty)
    }
    func testTopologyRollbackDiscardsEarlierHealthObservation() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        let before = environment.engine.inspections
        environment.network = .init(gateway: "192.168.2.1", interface: "en1", exitNodeID: "exit-b", exitNodeName: "B", tailscaleInterfaces: ["utun9"])
        coordinator.refresh()
        XCTAssertEqual(environment.engine.inspections, before + 2)
        XCTAssertEqual(coordinator.status().report.active, 0)
        XCTAssertTrue(routes.isEmpty)
    }
    func testHealthPublishesAndIdenticalApplyReuseCompiledPlan() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        XCTAssertEqual(environment.compilations, 0)
        try environment.activate(coordinator)
        for _ in 0..<5 { coordinator.refresh() }
        _ = try coordinator.apply(routes: ["223.5.5.0/24"])
        coordinator.refresh()
        XCTAssertEqual(environment.compilations, 1)
        XCTAssertEqual(routes, environment.engine.requests.last?.routes)
    }
    func testReplacingPolicyWithdrawsOldPlanUntilNewPlanIsApplied() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        _ = try coordinator.apply(routes: ["114.114.114.0/24"])
        XCTAssertTrue(routes.isEmpty)
        coordinator.refresh()
        XCTAssertTrue(routes.isEmpty)
        environment.time += 2; coordinator.refresh()
        XCTAssertEqual(routes, ["114.114.114.0/24"])
        XCTAssertEqual(environment.compilations, 2)
    }
    func testTopologyChangeCannotPublishOldPlanWhenRollbackFails() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        environment.engine.rejectRollback = true
        environment.network = .init(gateway: "192.168.2.1", interface: "en1", exitNodeID: "exit-b", exitNodeName: "B", tailscaleInterfaces: ["utun9"])
        coordinator.refresh(); environment.time += 2; coordinator.refresh()
        XCTAssertTrue(routes.isEmpty)
        XCTAssertEqual(environment.compilations, 1)
    }
    func testStopThenReenableMustApplyFreshPlan() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        _ = try coordinator.stop()
        _ = try coordinator.apply(routes: ["223.5.5.0/24"])
        XCTAssertTrue(routes.isEmpty)
        coordinator.refresh()
        XCTAssertTrue(routes.isEmpty)
        environment.time += 2; coordinator.refresh()
        XCTAssertEqual(routes, ["223.5.5.0/24"])
        XCTAssertEqual(environment.compilations, 2)
    }
    func testFailedRepairCannotRepublishPreviouslyAppliedPlan() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        environment.engine.missing = true
        environment.engine.reportTransform = { original in var report = original; report.failed = 1; return report }
        coordinator.refresh()
        XCTAssertTrue(routes.isEmpty)
        XCTAssertEqual(environment.compilations, 2)
    }
    func testDependentConfigurationStaysOffUntilVerifiedActiveRoutes() throws {
        let environment = RecoveryEnvironment()
        var events: [(NetworkContext?, [String])] = []
        let coordinator = try environment.coordinator { events.append(($0, $1)) }
        XCTAssertEqual(events.map(\.1), [[]])
        XCTAssertNil(events.first?.0)
        _ = try coordinator.apply(routes: ["223.5.5.0/24"])
        coordinator.refresh()
        XCTAssertFalse(events.contains { !$0.1.isEmpty })
        environment.time += 2; coordinator.refresh()
        XCTAssertEqual(events.last?.1, ["223.5.5.0/24"])
        XCTAssertEqual(events.last?.0, environment.network)
    }
    func testDependentConfigurationUsesCompiledRoutes() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        _ = try coordinator.apply(routes: ["223.5.5.0/25", "223.5.5.128/25"])
        coordinator.refresh(); environment.time += 2; coordinator.refresh()
        XCTAssertEqual(environment.engine.requests.last?.routes, ["223.5.5.0/24"])
        XCTAssertEqual(routes, ["223.5.5.0/24"])
    }
    func testDependentConfigurationRejectsIncompleteOrUnverifiedRouteReports() throws {
        let invalidReports: [(inout Report) -> Void] = [
            { $0.verified = false }, { $0.failed = 1 }, { $0.pending = 1 },
            { $0.skipped = 1 }, { $0.active = 0 }, { $0.active = 2 }
        ]
        for invalidate in invalidReports {
            let environment = RecoveryEnvironment()
            environment.engine.reportTransform = { original in var report = original; invalidate(&report); return report }
            var events: [[String]] = []
            let coordinator = try environment.coordinator { _, ready in events.append(ready) }
            _ = try coordinator.apply(routes: ["223.5.5.0/24"])
            coordinator.refresh(); environment.time += 2; coordinator.refresh()
            XCTAssertFalse(events.contains { !$0.isEmpty })
        }
    }
    func testStopWithdrawsDependentConfigurationAfterPersistenceBeforeRollback() throws {
        let environment = RecoveryEnvironment()
        var events: [String] = []
        let coordinator = try environment.coordinator { _, ready in
            events.append(!ready.isEmpty ? "ready" : "off")
        }
        try environment.activate(coordinator); events.removeAll()
        environment.engine.beforeRollback = {
            XCTAssertFalse(environment.policy.policy.enabled)
            XCTAssertEqual(events, ["off"])
            events.append("rollback")
        }
        _ = try coordinator.stop()
        XCTAssertEqual(events, ["off", "rollback", "off"])
    }
    func testNetworkLossWithdrawsDependentConfigurationBeforeRollback() throws {
        let environment = RecoveryEnvironment()
        var events: [String] = []
        let coordinator = try environment.coordinator { _, ready in events.append(!ready.isEmpty ? "ready" : "off") }
        try environment.activate(coordinator); events.removeAll()
        environment.engine.beforeRollback = {
            XCTAssertEqual(events, ["off"])
            events.append("rollback")
        }
        environment.network = nil; coordinator.refresh()
        XCTAssertEqual(events, ["off", "rollback", "off"])
    }
    func testDiscoveryFailureCannotLeaveDependentConfigurationEnabled() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        XCTAssertFalse(routes.isEmpty)
        environment.engine.beforeRollback = { XCTAssertTrue(routes.isEmpty) }
        environment.rejectDiscovery = true; coordinator.refresh()
        XCTAssertTrue(routes.isEmpty)
    }
    func testShutdownCannotRepublishReadyEvenIfRollbackFails() throws {
        let environment = RecoveryEnvironment()
        var events: [[String]] = []
        let coordinator = try environment.coordinator { _, ready in events.append(ready) }
        try environment.activate(coordinator); events.removeAll()
        environment.engine.rejectRollback = true
        environment.engine.beforeRollback = { XCTAssertEqual(events, [[]]) }
        coordinator.shutdown()
        coordinator.refresh()
        XCTAssertTrue(environment.policy.policy.enabled, "Shutdown must retain saved restore intent")
        XCTAssertFalse(events.contains { !$0.isEmpty })
        XCTAssertEqual(environment.engine.adds, 1)
    }
    func testDependentConfigurationCallbackCanReadPublishedStatus() throws {
        let environment = RecoveryEnvironment()
        var coordinator: RecoveryCoordinator?
        defer { coordinator = nil }
        var observed: RecoveryStatus?
        coordinator = try environment.coordinator { _, _ in observed = coordinator?.status() }
        try environment.activate(coordinator!)
        XCTAssertEqual(observed?.phase, .active)
        XCTAssertEqual(observed?.report.active, 1)
    }
    func testDependentConfigurationWithdrawnOnFailedHealthVerification() throws {
        let environment = RecoveryEnvironment()
        var routes: [String] = []
        let coordinator = try environment.coordinator { _, value in routes = value }
        try environment.activate(coordinator)
        XCTAssertFalse(routes.isEmpty)
        environment.engine.reportTransform = { original in var report = original; report.verified = false; return report }
        coordinator.refresh()
        XCTAssertTrue(routes.isEmpty)
    }
    func testIdenticalApplyPreservesLiveRoutesAndAvoidsPolicyWrite() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        let removals = environment.engine.removals
        let before = coordinator.status().lastCheck
        _ = try coordinator.apply(routes: ["223.5.5.0/24", "223.5.5.8/24"])
        coordinator.refresh()
        XCTAssertEqual(environment.engine.adds, 1)
        XCTAssertEqual(environment.engine.removals, removals)
        XCTAssertEqual(environment.policy.writes, 1)
        XCTAssertNotNil(before)
    }
    func testPersistenceFailureDoesNotEnableOrMutateRoutes() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        environment.policy.rejectSave = true
        XCTAssertThrowsError(try coordinator.apply(routes: ["223.5.5.0/24"]))
        XCTAssertFalse(coordinator.status().enabled)
        XCTAssertEqual(environment.engine.adds, 0)
    }
    func testInvalidPolicyRejectedBeforePersistence() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        XCTAssertThrowsError(try coordinator.apply(routes: ["10.0.0.0/8"]))
        XCTAssertEqual(environment.policy.writes, 0)
    }
    func testOfflineRollsBackAndClearsReportedActiveCount() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        environment.network = nil; coordinator.refresh()
        XCTAssertEqual(coordinator.status().report.active, 0)
        XCTAssertEqual(coordinator.status().phase, .waitingNetwork)
        XCTAssertTrue(coordinator.status().enabled)
        XCTAssertEqual(environment.engine.adds, 1)
    }
    func testStopPersistsDisabledEvenWhenRollbackFails() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        environment.engine.rejectRollback = true
        let status = try coordinator.stop()
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(environment.policy.policy.enabled)
        XCTAssertNil(status.desiredRoutesDigest)
        environment.time += 2; coordinator.refresh()
        XCTAssertEqual(environment.engine.adds, 1)
    }
    func testSessionStartupCleanupNeverRestoresPersistedEnabledPolicy() throws {
        let environment = RecoveryEnvironment()
        environment.policy.policy = DesiredPolicy(enabled: true, routes: ["223.5.5.0/24"])
        environment.engine.active = 1
        let coordinator = try environment.coordinator()
        _ = try coordinator.stop() // Same ordering as helper startup, before server.start().
        coordinator.refresh(); environment.time += 100; coordinator.refresh()
        XCTAssertFalse(coordinator.status().enabled)
        XCTAssertFalse(environment.policy.policy.enabled)
        XCTAssertEqual(environment.engine.active, 0)
        XCTAssertEqual(environment.engine.adds, 0)
    }
    func testOwnerExitCleansRoutesEvenWhenSavingDisabledPolicyFails() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        environment.policy.rejectSave = true
        let result = try coordinator.stop()
        XCTAssertFalse(result.enabled)
        XCTAssertEqual(environment.engine.active, 0)
        XCTAssertGreaterThan(result.report.failed, 0)
        environment.time += 2; coordinator.refresh()
        XCTAssertEqual(environment.engine.adds, 1)
        environment.policy.rejectSave = false
        environment.time += 100; coordinator.refresh()
        XCTAssertFalse(environment.policy.policy.enabled)
        XCTAssertEqual(coordinator.status().phase, .disabled)
        XCTAssertEqual(coordinator.status().report.failed, 0)
    }
    func testDiscoveryFailureCleansUpThenBacksOff() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        environment.rejectDiscovery = true; coordinator.refresh()
        XCTAssertEqual(coordinator.status().report.active, 0)
        XCTAssertEqual(coordinator.status().phase, .backingOff)
        XCTAssertEqual(environment.engine.adds, 1)
    }
    func testLostOwnedRoutesAreRestoredAfterResume() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        environment.engine.active = 0; environment.engine.missing = true
        let inspections = environment.engine.inspections
        environment.time += 3600; coordinator.refresh()
        XCTAssertEqual(environment.engine.inspections, inspections + 1)
        XCTAssertEqual(environment.engine.adds, 2)
        XCTAssertEqual(coordinator.status().report.active, 1)
    }
    func testPersistedEnabledIntentRestoresAfterRestart() throws {
        let environment = RecoveryEnvironment()
        environment.policy.policy = DesiredPolicy(enabled: true, routes: ["223.5.5.0/24"])
        let coordinator = try environment.coordinator()
        XCTAssertNotNil(coordinator.status().desiredRoutesDigest)
        XCTAssertNil(coordinator.status().lastCheck)
        coordinator.refresh(); environment.time += 2; coordinator.refresh()
        XCTAssertEqual(environment.engine.adds, 1)
        XCTAssertEqual(coordinator.status().phase, .active)
    }
    func testGatewayChangeNeverAddsBeforeSuccessfulCleanup() throws {
        let environment = RecoveryEnvironment(), coordinator = try environment.coordinator()
        try environment.activate(coordinator)
        environment.engine.rejectRollback = true
        environment.network = .init(gateway: "192.168.2.1", interface: "en1", exitNodeID: "exit-b", exitNodeName: "B", tailscaleInterfaces: ["utun9"])
        coordinator.refresh(); environment.time += 2; coordinator.refresh()
        XCTAssertEqual(environment.engine.adds, 1)
        XCTAssertEqual(coordinator.status().phase, .backingOff)
    }
}
