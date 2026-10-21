import XCTest
@testable import RouteCore

final class RecoveryStateMachineTests: XCTestCase {
    private func ready() -> RecoveryStateMachine {
        var state = RecoveryStateMachine()
        state.enable()
        XCTAssertEqual(state.decide(fingerprint: "A", now: 0), .rollback)
        state.didRollback(success: true, now: 0)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 0), .none)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 2), .apply)
        state.didApply(fingerprint: "A", success: true, now: 2)
        return state
    }
    func testDisabledDoesNothing() {
        var state = RecoveryStateMachine()
        XCTAssertEqual(state.decide(fingerprint: "A", now: 0), .none)
        XCTAssertEqual(state.phase, .disabled)
    }
    func testEnableCleansBeforeDiscovery() {
        var state = RecoveryStateMachine(); state.enable()
        XCTAssertEqual(state.decide(fingerprint: nil, now: 0), .rollback)
        state.didRollback(success: true, now: 0)
        XCTAssertEqual(state.decide(fingerprint: nil, now: 1), .none)
        XCTAssertEqual(state.phase, .waitingNetwork)
    }
    func testRequiresTwoSecondsOfStability() {
        var state = RecoveryStateMachine(); state.enable(); state.didRollback(success: true, now: 0)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 1), .none)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 2.99), .none)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 3), .apply)
    }
    func testTopologyFlappingRestartsStability() {
        var state = RecoveryStateMachine(); state.enable(); state.didRollback(success: true, now: 0)
        _ = state.decide(fingerprint: "A", now: 0)
        _ = state.decide(fingerprint: "B", now: 1.5)
        XCTAssertEqual(state.decide(fingerprint: "B", now: 2), .none)
        XCTAssertEqual(state.decide(fingerprint: "B", now: 3.5), .apply)
    }
    func testHealthyActiveDoesNotWrite() {
        var state = ready()
        XCTAssertEqual(state.decide(fingerprint: "A", now: 100), .none)
        XCTAssertEqual(state.phase, .active)
    }
    func testOfflineRemovesBeforeWaiting() {
        var state = ready()
        XCTAssertEqual(state.decide(fingerprint: nil, now: 3), .rollback)
        state.didRollback(success: true, now: 3)
        XCTAssertEqual(state.decide(fingerprint: nil, now: 4), .none)
        XCTAssertEqual(state.phase, .waitingNetwork)
    }
    func testGatewayChangeMustRemoveThenStabilize() {
        var state = ready()
        XCTAssertEqual(state.decide(fingerprint: "B", now: 3), .rollback)
        state.didRollback(success: true, now: 3)
        XCTAssertEqual(state.decide(fingerprint: "B", now: 3), .none)
        XCTAssertEqual(state.decide(fingerprint: "B", now: 5), .apply)
    }
    func testExitIdentityAndTunnelArePartOfOpaqueFingerprint() {
        var state = ready()
        XCTAssertEqual(state.decide(fingerprint: "same-gateway|new-exit|utun9", now: 3), .rollback)
    }
    func testLostOwnedRoutesRepairWithoutRollback() {
        var state = ready()
        XCTAssertEqual(state.decide(fingerprint: "A", repairNeeded: true, now: 20), .apply)
    }
    func testFailedRollbackBlocksNewApply() {
        var state = ready()
        _ = state.decide(fingerprint: "B", now: 3)
        state.didRollback(success: false, now: 3)
        XCTAssertEqual(state.decide(fingerprint: "B", now: 4), .none)
        XCTAssertEqual(state.phase, .backingOff)
        XCTAssertEqual(state.decide(fingerprint: "B", now: 5), .rollback)
    }
    func testFailedApplyRequiresCleanupAndBackoff() {
        var state = ready()
        state.didApply(fingerprint: "A", success: false, now: 10)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 11), .none)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 12), .rollback)
    }
    func testBackoffExponentiallyIncreasesAndCaps() {
        var state = ready()
        for index in 1...15 {
            state.didRollback(success: false, now: 100)
            XCTAssertEqual(state.retryAt - 100, min(300, pow(2, Double(min(index, 9)))))
        }
    }
    func testStopKeepsDisabledAfterSuccessfulCleanup() {
        var state = ready(); state.disable()
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 3), .rollback)
        state.didRollback(success: true, now: 3)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 100), .none)
        XCTAssertEqual(state.phase, .disabled)
    }
    func testStopRetriesOnlyCleanupAfterFailure() {
        var state = ready(); state.disable(); state.didRollback(success: false, now: 3)
        XCTAssertFalse(state.enabled)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 5), .rollback)
    }
    func testTopologyEventInterruptsBackoffForCleanup() {
        var state = ready(); state.didApply(fingerprint: "A", success: false, now: 10)
        state.invalidateTopology()
        XCTAssertEqual(state.decide(fingerprint: nil, now: 10.1), .rollback)
    }
    func testReenableReplacesPolicyViaCleanup() {
        var state = ready(); state.enable()
        XCTAssertEqual(state.decide(fingerprint: "A", now: 3), .rollback)
    }
    func testTopologyEventResumesDiscoveryAfterEarlierFailure() {
        var state = RecoveryStateMachine(); state.enable(); state.didRollback(success: true, now: 0)
        state.observationFailed(now: 10)
        state.invalidateTopology()
        XCTAssertEqual(state.decide(fingerprint: "A", now: 10.1), .none)
        XCTAssertEqual(state.phase, .stabilizing)
        XCTAssertEqual(state.decide(fingerprint: "A", now: 12.1), .apply)
    }
}
