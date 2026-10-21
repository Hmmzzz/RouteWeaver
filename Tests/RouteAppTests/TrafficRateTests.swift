import XCTest
import RouteCore
@testable import RouteWeaver

final class TrafficRateTests: XCTestCase {

    func testRateUsesElapsedTimeAndIdleIsMeasuredZero() {
        var sampler = TrafficRateSampler()
        let start = ContinuousClock.now
        XCTAssertNil(sampler.sample(["a": .init(received: 100, sent: 20)], at: start, detail: "").downloadBytesPerSecond)
        let next = sampler.sample(["a": .init(received: 800, sent: 160)], at: start.advanced(by: .milliseconds(3500)), detail: "")
        XCTAssertEqual(next.downloadBytesPerSecond, 200)
        XCTAssertEqual(next.uploadBytesPerSecond, 40)
        let idle = sampler.sample(["a": .init(received: 800, sent: 160)], at: start.advanced(by: .milliseconds(5500)), detail: "")
        XCTAssertEqual(idle.downloadBytesPerSecond, 0)
    }

    func testPerRouteResetCannotBeHiddenByAnotherRoutesIncrease() {
        var sampler = TrafficRateSampler()
        let start = ContinuousClock.now
        _ = sampler.sample(["a": .init(received: 100, sent: 20), "b": .init(received: 100, sent: 20)], at: start, detail: "")
        let reset = sampler.sample(["a": .init(received: 50, sent: 20), "b": .init(received: 1000, sent: 20)], at: start.advanced(by: .seconds(2)), detail: "")
        XCTAssertNil(reset.downloadBytesPerSecond)
        XCTAssertNil(reset.uploadBytesPerSecond)
    }

    func testIdentityChangeAndWakeFromSleepNeedFreshBaseline() {
        var sampler = TrafficRateSampler()
        let start = ContinuousClock.now
        _ = sampler.sample(["utun3:12": .init(received: 100, sent: 20)], at: start, detail: "")
        XCTAssertNil(sampler.sample(["utun3:15": .init(received: 500, sent: 20)], at: start.advanced(by: .seconds(2)), detail: "").downloadBytesPerSecond)
        XCTAssertNil(sampler.sample(["utun3:15": .init(received: 1500, sent: 20)], at: start.advanced(by: .seconds(60)), detail: "").downloadBytesPerSecond)
        sampler.reset()
        XCTAssertNil(sampler.sample(["utun3:15": .init(received: 1800, sent: 20)], at: start.advanced(by: .seconds(62)), detail: "").downloadBytesPerSecond)
    }

    func testMissingSourceInvalidatesWholeSample() {
        var sampler = TrafficRateSampler()
        let start = ContinuousClock.now
        _ = sampler.sample(["a": .init(received: 100, sent: 10), "b": .init(received: 100, sent: 10)], at: start, detail: "")
        XCTAssertNil(sampler.sample(["a": .init(received: 200, sent: 20)], at: start.advanced(by: .seconds(2)), detail: "").downloadBytesPerSecond)
    }

    func testDisplayedRateSeparatesUnknownFromZeroAndUsesBinaryUnits() {
        XCTAssertEqual(TrafficRateFormat.compact(.unknown("missing")), "—")
        XCTAssertEqual(TrafficRateFormat.compact(.init(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0, detail: "")), "0B")
        XCTAssertEqual(TrafficRateFormat.compact(.init(downloadBytesPerSecond: 1024, uploadBytesPerSecond: 512, detail: "")), "1.5K")
        XCTAssertEqual(TrafficRateFormat.full(.init(downloadBytesPerSecond: 1024, uploadBytesPerSecond: 512, detail: "")), "↓ 1.0 KiB/s  ↑ 512 B/s")
        XCTAssertEqual(TrafficRateFormat.compact(.init(downloadBytesPerSecond: .infinity, uploadBytesPerSecond: 0, detail: "")), "—")
    }
}
