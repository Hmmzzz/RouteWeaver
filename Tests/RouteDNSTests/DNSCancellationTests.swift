import XCTest
@testable import RouteDNS

final class DNSCancellationTests: XCTestCase {
    func testCancellationBeforeHandlerInstallationIsDeliveredOnceOutsideLock() {
        let token = DNSCancellation()
        token.cancel(); token.cancel()
        var calls = 0
        token.setHandler {
            XCTAssertTrue(token.isCancelled)
            token.cancel()
            calls += 1
        }
        token.setHandler { XCTFail("Cancellation delivered twice") }
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentCancellationAndHandlerInstallationAreIdempotent() {
        let token = DNSCancellation(), counter = LockedCancellationCount()
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            if index.isMultiple(of: 2) { token.cancel() }
            else { token.setHandler { counter.increment(); token.cancel() } }
        }
        XCTAssertEqual(counter.value, 1)
        XCTAssertTrue(token.isCancelled)
    }

    func testInitialHandlerMayCancelReentrantly() {
        var token: DNSCancellation!
        var calls = 0
        token = DNSCancellation { calls += 1; token.cancel() }
        token.cancel(); token.cancel()
        XCTAssertEqual(calls, 1)
    }
}

private final class LockedCancellationCount {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
