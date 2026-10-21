import XCTest
import RouteIPC
@testable import RouteWeaver

final class TerminationTests: XCTestCase {
    private func clean() -> ServiceResponse {
        var result = ServiceResponse()
        result.verified = true
        result.dnsActive = false
        result.dnsWithdrawn = true
        return result
    }

    @MainActor
    func testExitRequiresExplicitRouteAndDNSWithdrawalEvidence() {
        let baseline = clean()
        XCTAssertTrue(AppStore.cleanupConfirmed(baseline))
        let incomplete: [(inout ServiceResponse) -> Void] = [
            { $0.enabled = true }, { $0.verified = false },
            { $0.active = 1 }, { $0.pending = 1 }, { $0.failed = 1 },
            { $0.dnsActive = true }, { $0.dnsActive = nil },
            { $0.dnsWithdrawn = false }, { $0.dnsWithdrawn = nil }
        ]
        for change in incomplete {
            var response = baseline
            change(&response)
            XCTAssertFalse(AppStore.cleanupConfirmed(response))
        }
    }

    @MainActor
    func testQuitWaitsForInflightOperationAndBlocksNewApply() async {
        var stops = 0
        let result = clean()
        let store = AppStore(loadPersistedState: false, stopForExit: {
            stops += 1
            return result
        })
        store.serviceInstalled = true
        store.isBusy = true
        let quitting = Task { await store.prepareForTermination() }
        await Task.yield()
        XCTAssertTrue(store.isQuitting)
        XCTAssertEqual(stops, 0)
        XCTAssertFalse(store.canApply)
        XCTAssertFalse(store.canToggleRouting)
        store.isBusy = false
        await store.apply()
        XCTAssertNil(store.operation)
        let success = await quitting.value
        XCTAssertTrue(success)
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(store.serviceEnabled)
        XCTAssertEqual(store.activeRouteCount, 0)
    }

    @MainActor
    func testFailedCleanupCancelsExitAndAllowsRetry() async {
        var attempts = 0
        let result = clean()
        let store = AppStore(loadPersistedState: false, stopForExit: {
            attempts += 1
            if attempts == 1 { throw IPCError("test service unavailable") }
            return result
        })
        store.serviceInstalled = true
        let first = await store.prepareForTermination()
        XCTAssertFalse(first)
        XCTAssertFalse(store.isQuitting)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(store.lastError?.contains("退出已取消") == true)
        let second = await store.prepareForTermination()
        XCTAssertTrue(second)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testClosingUnattachedSecondInstanceDoesNotStopOtherOwner() async {
        var result = clean()
        result.enabled = true
        result.active = 42
        result.dnsActive = true
        result.dnsWithdrawn = false
        result.sessionAttached = false
        result.anotherSessionActive = true
        let store = AppStore(loadPersistedState: false, stopForExit: { result })
        store.serviceInstalled = true
        let success = await store.prepareForTermination()
        XCTAssertTrue(success)
        XCTAssertFalse(store.events.contains { $0.title == "退出前已恢复网络" })
    }

    @MainActor
    func testPendingDNSWithdrawalIsRetriedBeforeExit() async {
        var attempts = 0
        let result = clean()
        let store = AppStore(loadPersistedState: false, stopForExit: {
            attempts += 1
            var response = result
            response.dnsWithdrawn = attempts > 1
            return response
        })
        store.serviceInstalled = true
        let success = await store.prepareForTermination()
        XCTAssertTrue(success)
        XCTAssertEqual(attempts, 2)
    }
}
