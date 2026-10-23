import XCTest
@testable import RouteDNS

final class DNSResilienceTests: XCTestCase {
    private let networks = ["101.4.0.0/14", "223.5.5.0/24"]
    private func processor(_ gate: ResilienceGate, clock: ResilienceClock = ResilienceClock(),
                           domesticTimeout: TimeInterval = 1.25, requestTimeout: TimeInterval = 4.5) throws -> DNSProcessor {
        try DNSProcessor(directCIDRs: networks, directDomains: ["qq.com"],
            domesticLookup: { _, budget, completion in gate.domestic(budget, completion) },
            originalLookup: { packet, _, budget, completion in gate.original(packet, budget, completion) },
            time: { clock.now }, domesticTimeout: domesticTimeout, requestTimeout: requestTimeout)
    }
    private func drain(_ processor: DNSProcessor) { _ = processor.activitySnapshot }

    func testDomesticFallbackKeepsItsClassAndReservesSixteenOriginalSlots() throws {
        let gate = ResilienceGate(), p = try processor(gate); defer { p.stop() }
        for i in 0..<48 { p.process(makeQuery("n\(i).qq.com")) { _ in } }
        drain(p)
        XCTAssertEqual(p.activitySnapshot.active, 48)
        XCTAssertEqual(p.activitySnapshot.domesticSubscribers, 32)
        XCTAssertEqual(gate.domesticCount, 32)
        XCTAssertEqual(gate.originalCount, 16)
        for i in 0..<32 { gate.completeDomestic(i, .response(nil)) }
        drain(p)
        XCTAssertEqual(p.activitySnapshot.optimization, 48)
        XCTAssertEqual(gate.originalCount, 48)
        let rejected = expectation(description: "optimization rejected")
        p.process(makeQuery("overflow.qq.com")) { result in
            XCTAssertEqual(result.flatMap { DNSWire.read16([UInt8]($0), 2) }! & 15, 2); rejected.fulfill()
        }
        for i in 0..<16 { p.process(makeQuery("n\(i).example.com")) { _ in } }
        drain(p)
        XCTAssertEqual(p.activitySnapshot.active, 64)
        XCTAssertEqual(gate.originalCount, 64)
        wait(for: [rejected], timeout: 1)
    }
    func testOnePeerReservesTwoSlotsAndOtherPeersRemainIndependent() throws {
        let gate = ResilienceGate(), p = try processor(gate), peer = UUID(); defer { p.stop() }
        for i in 0..<6 { p.process(makeQuery("n\(i).qq.com"), peerID: peer) { _ in } }
        let rejected = expectation(description: "peer domestic full")
        p.process(makeQuery("overflow.qq.com"), peerID: peer) { result in
            XCTAssertEqual(result.flatMap { DNSWire.read16([UInt8]($0), 2) }! & 15, 2); rejected.fulfill()
        }
        for i in 0..<2 { p.process(makeQuery("n\(i).example.com"), peerID: peer) { _ in } }
        p.process(makeQuery("other.qq.com"), peerID: UUID()) { _ in }
        drain(p)
        XCTAssertEqual(p.activitySnapshot.active, 9)
        XCTAssertEqual(gate.originalCount, 2)
        wait(for: [rejected], timeout: 1)
    }
    func testSharedFailureCountsOnceAndOpenCircuitBypassesDomestic() throws {
        let gate = ResilienceGate(), p = try processor(gate); defer { p.stop() }
        for _ in 0..<32 { p.process(makeQuery("shared.qq.com")) { _ in } }
        drain(p); XCTAssertEqual(gate.domesticCount, 1)
        gate.completeDomestic(0, .failure); drain(p)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 1)
        p.process(makeQuery("second.qq.com")) { _ in }; drain(p)
        gate.completeDomestic(1, .failure); drain(p)
        XCTAssertTrue(p.activitySnapshot.coolingDown)
        p.process(makeQuery("third.qq.com")) { _ in }; drain(p)
        XCTAssertEqual(gate.domesticCount, 2)
        XCTAssertEqual(gate.originalCount, 34)
    }
    func testHalfOpenAllowsOneProbeAndOldSuccessCannotCloseIt() throws {
        let gate = ResilienceGate(), clock = ResilienceClock(), p = try processor(gate, clock: clock); defer { p.stop() }
        for name in ["old", "one", "two"] { p.process(makeQuery("\(name).qq.com")) { _ in } }
        drain(p)
        gate.completeDomestic(1, .failure); gate.completeDomestic(2, .failure); drain(p)
        XCTAssertTrue(p.activitySnapshot.coolingDown)
        clock.advance(6)
        p.process(makeQuery("probe.qq.com")) { _ in }; drain(p)
        XCTAssertTrue(p.activitySnapshot.probing)
        gate.completeDomestic(0, .response(nil)); drain(p)
        XCTAssertTrue(p.activitySnapshot.probing)
        p.process(makeQuery("bypass.qq.com")) { _ in }; drain(p)
        XCTAssertEqual(gate.domesticCount, 4)
        gate.completeDomestic(3, .response(nil)); drain(p)
        XCTAssertFalse(p.activitySnapshot.probing)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 0)
        p.process(makeQuery("healthy.qq.com")) { _ in }; drain(p)
        XCTAssertEqual(gate.domesticCount, 5)
    }
    func testCancelOnlyLastSubscriberCancelsSharedLookupAndReleasesCapacity() throws {
        let gate = ResilienceGate(), p = try processor(gate); defer { p.stop() }
        let done = expectation(description: "cancelled subscriptions"); done.expectedFulfillmentCount = 2
        let first = p.process(makeQuery("shared.qq.com")) { result in XCTAssertNil(result); done.fulfill() }
        let second = p.process(makeQuery("shared.qq.com")) { result in XCTAssertNil(result); done.fulfill() }
        drain(p); XCTAssertEqual(gate.domesticCount, 1)
        first.cancel(); drain(p)
        XCTAssertEqual(gate.domesticCancellationCount, 0)
        XCTAssertEqual(p.activitySnapshot.domesticSubscribers, 1)
        second.cancel(); second.cancel(); drain(p)
        XCTAssertEqual(gate.domesticCancellationCount, 1)
        XCTAssertEqual(p.activitySnapshot.active, 0)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 0)
        gate.completeDomestic(0, .failure); drain(p)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 0)
        wait(for: [done], timeout: 1)
    }
    func testUpdateCancelsOldGenerationAndLateFailureCannotAffectNewLookup() throws {
        let gate = ResilienceGate(), p = try processor(gate); defer { p.stop() }
        p.process(makeQuery("same.qq.com")) { _ in }; drain(p)
        p.update(directCIDRs: networks)
        XCTAssertEqual(gate.domesticCancellationCount, 1)
        XCTAssertEqual(gate.originalCount, 1)
        p.process(makeQuery("same.qq.com")) { _ in }; drain(p)
        gate.completeDomestic(0, .failure); drain(p)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 0)
        XCTAssertEqual(p.activitySnapshot.domesticLookups, 1)
        gate.completeDomestic(1, .unavailable); drain(p)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 0)
    }
    func testValidEmptyAndNonDirectResponsesResetFailuresButUnavailableDoesNot() throws {
        let gate = ResilienceGate(), p = try processor(gate); defer { p.stop() }
        let results: [DNSDomesticResult] = [.failure, .unavailable, .response(nil), .failure,
            .response(DNSAAnswer(addresses: [0x08080808], ttl: 30))]
        let expectedFailures = [1, 1, 0, 1, 0]
        for (index, result) in results.enumerated() {
            p.process(makeQuery("n\(index).qq.com")) { _ in }; drain(p)
            gate.completeDomestic(index, result); drain(p)
            XCTAssertEqual(p.activitySnapshot.consecutiveFailures, expectedFailures[index])
            XCTAssertFalse(p.activitySnapshot.coolingDown)
        }
        XCTAssertEqual(gate.originalCount, 5)
    }
    func testCachedDirectAnswerStillWorksDuringCooldown() throws {
        let gate = ResilienceGate(), p = try processor(gate); defer { p.stop() }
        let cached = expectation(description: "cached response while circuit open")
        p.process(makeQuery("cached.qq.com")) { _ in }; drain(p)
        gate.completeDomestic(0, .response(DNSAAnswer(addresses: [0x65040401], ttl: 30))); drain(p)
        for index in 1...2 {
            p.process(makeQuery("failure\(index).qq.com")) { _ in }; drain(p)
            gate.completeDomestic(index, .failure); drain(p)
        }
        XCTAssertTrue(p.activitySnapshot.coolingDown)
        p.process(makeQuery("cached.qq.com")) { response in
            XCTAssertEqual(response.flatMap { DNSWire.read16([UInt8]($0), 2) }! & 15, 0)
            cached.fulfill()
        }
        drain(p)
        XCTAssertEqual(gate.domesticCount, 3)
        XCTAssertEqual(gate.originalCount, 2)
        XCTAssertTrue(p.activitySnapshot.coolingDown)
        wait(for: [cached], timeout: 1)
    }
    func testOriginalResponseAfterAbsoluteDeadlineCannotWinTimerRace() throws {
        let gate = ResilienceGate(), clock = ResilienceClock(), p = try processor(gate, clock: clock)
        defer { p.stop() }
        let done = expectation(description: "late original response becomes failure")
        let packet = makeQuery("example.com")
        p.process(packet) { response in
            XCTAssertEqual(response.flatMap { DNSWire.read16([UInt8]($0), 2) }! & 15, 2)
            done.fulfill()
        }
        drain(p); clock.advance(5)
        gate.completeOriginal(0, DNSWire.response(to: DNSWire.question(packet)!, addresses: [0x08080808], ttl: 30))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(p.activitySnapshot.active, 0)
        XCTAssertEqual(gate.originalCancellationCount, 1)
    }
    func testDomesticDeadlineCancelsWorkAndPreservesOriginalBudget() throws {
        let gate = ResilienceGate(), p = try processor(gate, domesticTimeout: 0.01, requestTimeout: 0.12)
        let done = expectation(description: "overall deadline")
        p.process(makeQuery("slow.qq.com")) { result in
            XCTAssertEqual(result.flatMap { DNSWire.read16([UInt8]($0), 2) }! & 15, 2); done.fulfill()
        }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(gate.domesticCancellationCount, 1)
        XCTAssertEqual(gate.originalCancellationCount, 1)
        XCTAssertEqual(p.activitySnapshot.active, 0)
        XCTAssertEqual(p.activitySnapshot.consecutiveFailures, 1)
        XCTAssertLessThanOrEqual(gate.domesticBudgets[0], 0.01)
        XCTAssertGreaterThanOrEqual(gate.originalBudgets[0], 0.08)
        p.stop()
    }
}

private final class ResilienceClock {
    private let lock = NSLock(); private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: TimeInterval) { lock.lock(); value += amount; lock.unlock() }
}
private final class ResilienceGate {
    private let lock = NSLock()
    private var callbacks: [(DNSDomesticResult) -> Void] = []
    private var originalCallbacks: [(Data?) -> Void] = []
    private var domesticCancelled = 0, originalCancelled = 0
    private var budgets: [TimeInterval] = [], fallbackBudgets: [TimeInterval] = []
    var domesticCount: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    var originalCount: Int { lock.lock(); defer { lock.unlock() }; return originalCallbacks.count }
    var domesticCancellationCount: Int { lock.lock(); defer { lock.unlock() }; return domesticCancelled }
    var originalCancellationCount: Int { lock.lock(); defer { lock.unlock() }; return originalCancelled }
    var domesticBudgets: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return budgets }
    var originalBudgets: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return fallbackBudgets }
    func domestic(_ budget: TimeInterval, _ completion: @escaping (DNSDomesticResult) -> Void) -> DNSCancellation {
        lock.lock(); callbacks.append(completion); budgets.append(budget); lock.unlock()
        return DNSCancellation { self.lock.lock(); self.domesticCancelled += 1; self.lock.unlock() }
    }
    func original(_ data: Data, _ budget: TimeInterval, _ completion: @escaping (Data?) -> Void) -> DNSCancellation {
        lock.lock(); originalCallbacks.append(completion); fallbackBudgets.append(budget); lock.unlock()
        return DNSCancellation { self.lock.lock(); self.originalCancelled += 1; self.lock.unlock() }
    }
    func completeDomestic(_ index: Int, _ result: DNSDomesticResult) {
        lock.lock(); let completion = callbacks[index]; lock.unlock(); completion(result)
    }
    func completeOriginal(_ index: Int, _ response: Data?) {
        lock.lock(); let completion = originalCallbacks[index]; lock.unlock(); completion(response)
    }
}
