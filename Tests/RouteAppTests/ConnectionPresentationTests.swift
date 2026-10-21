import XCTest
@testable import RouteWeaver

final class ConnectionPresentationTests: XCTestCase {
    private func connected(enabled: Bool = true, phase: String = "active") -> ConnectionState {
        ConnectionState(checked: true, reachable: true, installed: true, networkReady: true,
                        enabled: enabled, phase: phase, verified: true, active: enabled ? 42 : 0)
    }
    func testInitialStateNeverClaimsOff() {
        let view = ConnectionPresentation.make(ConnectionState())
        XCTAssertEqual(view.kind, .checking)
        XCTAssertTrue(view.isTransitioning)
    }
    func testUninstalledServiceOffersInstallation() {
        let view = ConnectionPresentation.make(ConnectionState(checked: true))
        XCTAssertEqual(view.kind, .notInstalled)
        XCTAssertEqual(view.primaryAction, .installService)
    }
    func testDisconnectedInstalledServiceIsUnknownEvenWithSavedActiveRoutes() {
        var state = connected(); state.reachable = false
        let view = ConnectionPresentation.make(state)
        XCTAssertEqual(view.kind, .unavailable)
        XCTAssertEqual(view.tone, .error)
        XCTAssertEqual(view.primaryAction, .retryConnection)
        XCTAssertEqual(view.secondaryAction, .repairService)
    }
    func testDisconnectedServiceDoesNotClaimOffWhenLastIntentWasDisabled() {
        var state = connected(enabled: false, phase: "disabled"); state.reachable = false
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .unavailable)
    }
    func testCleanDisabledServiceIsOff() {
        let view = ConnectionPresentation.make(connected(enabled: false, phase: "disabled"))
        XCTAssertEqual(view.kind, .off)
        XCTAssertNil(view.primaryAction)
    }
    func testUnverifiedDisabledResponseDoesNotConfirmCleanup() {
        var state = connected(enabled: false, phase: "disabled"); state.verified = false
        XCTAssertNotEqual(ConnectionPresentation.make(state).kind, .off)
    }
    func testOffWithNetworkUnavailableOffersTailscale() {
        var state = connected(enabled: false, phase: "disabled"); state.networkReady = false
        XCTAssertEqual(ConnectionPresentation.make(state).primaryAction, .openTailscale)
    }
    func testWaitingNetworkRetainsEnabledIntent() {
        var state = connected(phase: "waitingNetwork"); state.active = 0; state.networkReady = false
        let view = ConnectionPresentation.make(state)
        XCTAssertEqual(view.kind, .waitingNetwork)
        XCTAssertFalse(view.isTransitioning)
        XCTAssertEqual(view.primaryAction, .openTailscale)
    }
    func testStabilizingIsNotAlreadyOn() {
        var state = connected(phase: "stabilizing"); state.active = 0
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .preparing)
        XCTAssertTrue(ConnectionPresentation.make(state).isTransitioning)
    }
    func testAcceptedApplyDoesNotClaimCompletion() {
        var state = connected(phase: "applying"); state.active = 0
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .applying)
        XCTAssertEqual(ConnectionPresentation.make(state).tone, .neutral)
    }
    func testOnlyVerifiedActiveRoutesProduceSuccess() {
        let view = ConnectionPresentation.make(connected())
        XCTAssertEqual(view.kind, .on)
        XCTAssertEqual(view.tone, .success)
        XCTAssertTrue(view.detail.contains("42"))
    }
    func testUnverifiedActiveResponseNeedsInspection() {
        var state = connected(); state.verified = false
        let view = ConnectionPresentation.make(state)
        XCTAssertEqual(view.kind, .recovering)
        XCTAssertEqual(view.secondaryAction, .retryStop)
    }
    func testPendingRoutesCannotProduceSuccess() {
        var state = connected(); state.pending = 1
        XCTAssertNotEqual(ConnectionPresentation.make(state).tone, .success)
    }
    func testZeroActiveWithoutConflictsCannotProduceSuccess() {
        var state = connected(); state.active = 0
        XCTAssertNotEqual(ConnectionPresentation.make(state).kind, .on)
    }
    func testConflictsAreVisibleWhileKeepingActualActiveCount() {
        var state = connected(); state.skipped = 3
        let view = ConnectionPresentation.make(state)
        XCTAssertEqual(view.kind, .on)
        XCTAssertEqual(view.tone, .warning)
        XCTAssertEqual(view.primaryAction, .reviewRules)
        XCTAssertTrue(view.detail.contains("42"))
        XCTAssertTrue(view.detail.contains("3"))
    }
    func testDirtyPolicyDoesNotTurnHealthyServiceIntoFailure() {
        var state = connected(); state.hasUnappliedChanges = true
        let view = ConnectionPresentation.make(state)
        XCTAssertEqual(view.kind, .on)
        XCTAssertEqual(view.tone, .success)
        XCTAssertEqual(view.primaryAction, .applyChanges)
    }
    func testCleanupFailureIsNotDisplayedAsOff() {
        var state = connected(enabled: false, phase: "backingOff"); state.pending = 2; state.failed = 1
        let view = ConnectionPresentation.make(state)
        XCTAssertEqual(view.kind, .recovering)
        XCTAssertEqual(view.primaryAction, .retryStop)
    }
    func testEnabledBackoffAllowsStopping() {
        let view = ConnectionPresentation.make(connected(phase: "backingOff"))
        XCTAssertEqual(view.kind, .recovering)
        XCTAssertEqual(view.secondaryAction, .retryStop)
        XCTAssertFalse(view.isTransitioning)
    }
    func testOldRoutesBeingRemovedDuringNetworkSwitchIsTransitional() {
        let view = ConnectionPresentation.make(connected(phase: "removing"))
        XCTAssertEqual(view.kind, .stopping)
        XCTAssertTrue(view.title.contains("切换"))
    }
    func testLocalStopImmediatelyShowsProgress() {
        var state = connected(); state.operation = .stopping
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .stopping)
    }
    func testLocalApplyImmediatelyShowsProgress() {
        var state = connected(enabled: false, phase: "disabled"); state.operation = .applying
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .applying)
    }
    func testServiceRepairHasDistinctProgress() {
        var state = ConnectionState(); state.operation = .repairing
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .preparing)
        XCTAssertTrue(ConnectionPresentation.make(state).title.contains("后台"))
    }
    func testDatasetUpdateDoesNotMasqueradeAsRoutingOperation() {
        var state = connected(); state.operation = .updatingDataset
        XCTAssertEqual(ConnectionPresentation.make(state).kind, .on)
        XCTAssertFalse(ConnectionPresentation.make(state).isTransitioning)
    }
    func testUnknownFutureProtocolStateDoesNotClaimSuccess() {
        XCTAssertEqual(ConnectionPresentation.make(connected(phase: "futureState")).kind, .unavailable)
    }

    @MainActor func testUnavailableStoreHidesLiveCountAndDisablesToggle() async {
        let store = AppStore(loadPersistedState: false)
        store.serviceInstalled = true; store.serviceChecked = true; store.serviceReachable = false
        store.serviceEnabled = true; store.lastAppliedCount = 42; store.serviceVerified = true
        XCTAssertNil(store.activeRouteCount)
        XCTAssertFalse(store.canToggleRouting)
        XCTAssertTrue(store.canStop)
        XCTAssertEqual(store.connection.kind, .unavailable)
    }
    @MainActor func testStopDoesNotDependOnNetworkBeingReady() async {
        let store = AppStore(loadPersistedState: false)
        store.serviceInstalled = true; store.serviceChecked = true; store.serviceReachable = true
        store.serviceEnabled = true; store.servicePhase = "waitingNetwork"
        XCTAssertFalse(store.network.ready)
        XCTAssertTrue(store.canStop)
        XCTAssertTrue(store.canToggleRouting)
    }
    @MainActor func testBusyStorePreventsDuplicateOperations() async {
        let store = AppStore(loadPersistedState: false)
        store.serviceInstalled = true; store.serviceChecked = true; store.serviceReachable = true
        store.serviceEnabled = true; store.isBusy = true
        XCTAssertFalse(store.canStop)
        XCTAssertFalse(store.canToggleRouting)
    }
    @MainActor func testNoPreviousProfileCountsAreReadForTestOrFreshState() async {
        let store = AppStore(loadPersistedState: false)
        XCTAssertFalse(store.serviceEnabled)
        XCTAssertFalse(store.serviceChecked)
        XCTAssertFalse(store.hasApplied)
        XCTAssertNil(store.activeRouteCount)
    }
    @MainActor func testConfirmedDaemonNetworkOverridesDifferentLocalCandidate() async {
        let store = AppStore(loadPersistedState: false)
        store.network.gateway = "192.168.1.1"; store.network.interface = "en0"
        store.serviceReachable = true; store.serviceEnabled = true
        store.serviceGateway = "10.0.0.1"; store.serviceInterface = "en7"
        XCTAssertTrue(store.usesConfirmedServiceNetwork)
        XCTAssertEqual(store.displayedGateway, "10.0.0.1")
        XCTAssertEqual(store.displayedInterface, "en7")
    }
    @MainActor func testDisconnectedServiceNetworkIsNotPresentedAsCurrent() async {
        let store = AppStore(loadPersistedState: false)
        store.network.gateway = "192.168.1.1"; store.network.interface = "en0"
        store.serviceReachable = false; store.serviceEnabled = true
        store.serviceGateway = "10.0.0.1"; store.serviceInterface = "en7"
        XCTAssertFalse(store.usesConfirmedServiceNetwork)
        XCTAssertEqual(store.displayedGateway, "192.168.1.1")
        XCTAssertEqual(store.displayedInterface, "en0")
    }
    @MainActor func testDisabledServiceNetworkDoesNotReplaceLocalPreview() async {
        let store = AppStore(loadPersistedState: false)
        store.network.gateway = "192.168.1.1"; store.network.interface = "en0"
        store.serviceReachable = true; store.serviceEnabled = false
        store.serviceGateway = "10.0.0.1"; store.serviceInterface = "en7"
        XCTAssertFalse(store.usesConfirmedServiceNetwork)
        XCTAssertEqual(store.displayedGateway, "192.168.1.1")
    }
    @MainActor func testIncompleteServiceNetworkNeverMixesTwoInterfaces() async {
        let store = AppStore(loadPersistedState: false)
        store.network.gateway = "192.168.1.1"; store.network.interface = "en0"
        store.serviceReachable = true; store.serviceEnabled = true
        store.serviceGateway = "10.0.0.1"; store.serviceInterface = nil
        XCTAssertFalse(store.usesConfirmedServiceNetwork)
        XCTAssertEqual(store.displayedGateway, "192.168.1.1")
        XCTAssertEqual(store.displayedInterface, "en0")
    }

}
