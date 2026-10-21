import XCTest
@testable import RouteWeaver

final class TrafficBackoffTests: XCTestCase {
    private let context = DirectTrafficBackoff.Context(gateway: "192.168.1.1", interface: "en0", routeCount: 5500)

    func testFailureSkipsAttemptsUntilDeadlineWithoutExtendingIt() {
        var backoff = DirectTrafficBackoff()
        let start = ContinuousClock.now
        XCTAssertFalse(backoff.shouldWait(in: context, at: start))
        backoff.recordFailure(in: context, at: start)
        for seconds in stride(from: 0, through: 28, by: 2) {
            XCTAssertTrue(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(seconds))))
        }
        XCTAssertFalse(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(30))))
        XCTAssertFalse(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(32))))
    }

    func testEveryServiceContextChangeAllowsImmediateRetry() {
        let changes: [DirectTrafficBackoff.Context] = [
            .init(gateway: "192.168.2.1", interface: context.interface, routeCount: context.routeCount),
            .init(gateway: context.gateway, interface: "en7", routeCount: context.routeCount),
            .init(gateway: context.gateway, interface: context.interface, routeCount: context.routeCount + 1)
        ]
        let start = ContinuousClock.now
        for changed in changes {
            var backoff = DirectTrafficBackoff()
            backoff.recordFailure(in: context, at: start)
            XCTAssertFalse(backoff.shouldWait(in: changed, at: start.advanced(by: .seconds(2))))
            // Returning to the old context must not revive its failed attempt.
            XCTAssertFalse(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(4))))
        }
    }

    func testResetAllowsRetryWhenServiceRecoversWithSameContext() {
        var backoff = DirectTrafficBackoff()
        let start = ContinuousClock.now
        backoff.recordFailure(in: context, at: start)
        backoff.reset()
        XCTAssertFalse(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(2))))
    }

    func testNewFailureStartsItsOwnDeadline() {
        var backoff = DirectTrafficBackoff()
        let start = ContinuousClock.now
        backoff.recordFailure(in: context, at: start)
        XCTAssertFalse(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(30))))
        backoff.recordFailure(in: context, at: start.advanced(by: .seconds(30)))
        XCTAssertTrue(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(59))))
        XCTAssertFalse(backoff.shouldWait(in: context, at: start.advanced(by: .seconds(60))))
    }
}
