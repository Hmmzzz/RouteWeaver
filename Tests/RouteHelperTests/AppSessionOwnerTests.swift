import XCTest
import Darwin
@testable import RouteHelper

private final class FakeAppProcessWatch: AppProcessWatching {
    let exited: () -> Void
    var cancelled = false
    init(exited: @escaping () -> Void) { self.exited = exited }
    func cancel() { cancelled = true }
}

final class AppSessionOwnerTests: XCTestCase {
    private let first = ServicePeer(pid: 101, auditToken: Data([1]))
    private let second = ServicePeer(pid: 102, auditToken: Data([2]))

    func testApplyRequiresExplicitAttachAndAnotherProcessCannotTakeOwnership() throws {
        var watches: [FakeAppProcessWatch] = []
        var cleanups = 0
        let owner = AppSessionOwner(watch: { _, exited in
            let watch = FakeAppProcessWatch(exited: exited); watches.append(watch); return watch
        }, ownerExited: { cleanups += 1 })
        XCTAssertThrowsError(try owner.requireAttached(first))
        try owner.attach(first)
        try owner.attach(first)
        XCTAssertEqual(watches.count, 1)
        XCTAssertNoThrow(try owner.requireAttached(first))
        XCTAssertThrowsError(try owner.requireAttached(second))
        XCTAssertThrowsError(try owner.attach(second))
        XCTAssertEqual(cleanups, 0)
        watches[0].exited()
        XCTAssertEqual(cleanups, 1)
        XCTAssertTrue(watches[0].cancelled)
        XCTAssertFalse(owner.isAttached(first))
    }

    func testStaleExitCallbackCannotStopNewOwnerIncludingReusedPID() throws {
        var watches: [FakeAppProcessWatch] = []
        var cleanups = 0
        let owner = AppSessionOwner(watch: { _, exited in
            let watch = FakeAppProcessWatch(exited: exited); watches.append(watch); return watch
        }, ownerExited: { cleanups += 1 })
        try owner.attach(first)
        let reused = ServicePeer(pid: first.pid, auditToken: Data([9]))
        XCTAssertThrowsError(try owner.attach(reused))
        watches[0].exited()
        try owner.attach(reused)
        watches[0].exited()
        XCTAssertEqual(cleanups, 1)
        XCTAssertTrue(owner.isAttached(reused))
        watches[1].exited()
        XCTAssertEqual(cleanups, 2)
    }

    func testScopedStopOnlyCleansOwnSessionOrUnownedLeftovers() throws {
        var stops = 0
        let owner = AppSessionOwner(watch: { _, exited in FakeAppProcessWatch(exited: exited) }, ownerExited: {})
        func stop() -> RecoveryStatus { stops += 1; return RecoveryStatus() }
        XCTAssertFalse(owner.hasOtherOwner(first))
        XCTAssertNotNil(owner.stopIfOwned(first, stop: stop))
        XCTAssertEqual(stops, 1)
        try owner.attach(first)
        XCTAssertTrue(owner.hasOtherOwner(second))
        XCTAssertNil(owner.stopIfOwned(second, stop: stop))
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(owner.isAttached(first))
        XCTAssertNotNil(owner.stopIfOwned(first, stop: stop))
        XCTAssertEqual(stops, 2)
        XCTAssertTrue(owner.isAttached(first))
    }

    func testRealProcessWatchObservesForcedExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let queue = DispatchQueue(label: "RouteWeaver.tests.owner")
        let cleanup = expectation(description: "Owner exit requests cleanup")
        let owner = AppSessionOwner(queue: queue) { cleanup.fulfill() }
        try queue.sync {
            try owner.attach(ServicePeer(pid: process.processIdentifier, auditToken: Data([3])))
        }
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        wait(for: [cleanup], timeout: 3)
        withExtendedLifetime(owner) {}
    }
}
