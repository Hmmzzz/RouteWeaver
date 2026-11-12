import XCTest
@testable import RouteDNS

final class DNSBypassCacheTests: XCTestCase {
    private let networks = ["101.4.0.0/14", "223.5.5.0/24"]

    func testNonDirectDecisionSkipsProbeButForwardsEveryOriginalPacketAndTransport() throws {
        for answer: DNSAAnswer? in [nil, DNSAAnswer(addresses: [0x08080808], ttl: 30),
                                   DNSAAnswer(addresses: [0x65060f82, 0x08080808], ttl: 30)] {
            let gate = BypassLookupGate(result: .response(answer)), processor = try makeProcessor(gate)
            defer { processor.stop() }
            for (index, type) in [UInt16(1), 28, 64, 65].enumerated() {
                var packet = makeQuery("cdn.qq.com", type: type, edns: true)
                packet[1] = UInt8(index)
                let transport: DNSClientTransport = index.isMultiple(of: 2) ? .udp : .tcp
                XCTAssertEqual(try resolve(processor, packet, transport: transport), bypassResponse(packet))
                XCTAssertEqual(gate.lastOriginalPacket, packet)
                XCTAssertEqual(gate.lastOriginalTransport, transport)
            }
            XCTAssertEqual(gate.domesticCount, 1)
            XCTAssertEqual(gate.originalCount, 4)
        }
    }

    func testBypassExpiresAtFiveSecondsOrShorterAnswerTTL() throws {
        for (answer, lifetime): (DNSAAnswer?, TimeInterval) in [(nil, 5),
                (DNSAAnswer(addresses: [0x08080808], ttl: 2), 2)] {
            let clock = BypassClock(), gate = BypassLookupGate(result: .response(answer))
            let processor = try makeProcessor(gate, clock: clock); defer { processor.stop() }
            let packet = makeQuery("cdn.qq.com")
            _ = try resolve(processor, packet)
            clock.advance(lifetime - 0.01)
            _ = try resolve(processor, packet)
            XCTAssertEqual(gate.domesticCount, 1)
            clock.advance(0.01)
            _ = try resolve(processor, packet)
            XCTAssertEqual(gate.domesticCount, 2)
        }
    }

    func testZeroTTLTransportFailureAndCancellationNeverCacheBypass() throws {
        for result: DNSDomesticResult in [.response(DNSAAnswer(addresses: [0x08080808], ttl: 0)), .failure, .unavailable] {
            let gate = BypassLookupGate(result: result), processor = try makeProcessor(gate)
            defer { processor.stop() }
            for _ in 0..<2 { _ = try resolve(processor, makeQuery("cdn.qq.com")) }
            XCTAssertEqual(gate.domesticCount, 2)
            XCTAssertEqual(gate.originalCount, 2)
        }
    }

    func testNetworkBarrierClearsBypassEvenWhenCIDRsStayTheSame() throws {
        let gate = BypassLookupGate(result: .response(nil)), processor = try makeProcessor(gate)
        defer { processor.stop() }
        _ = try resolve(processor, makeQuery("cdn.qq.com"))
        processor.update(directCIDRs: networks)
        _ = try resolve(processor, makeQuery("cdn.qq.com"))
        XCTAssertEqual(gate.domesticCount, 2)
    }

    func testCoalescedProbeCachesOneDecisionAndEachSubscriberUsesOriginalResolver() throws {
        let gate = BypassLookupGate(result: nil), processor = try makeProcessor(gate)
        defer { processor.stop() }
        let done = expectation(description: "all subscribers receive their own original response")
        done.expectedFulfillmentCount = 8
        for id in 0..<8 {
            var packet = makeQuery("cdn.qq.com"); packet[1] = UInt8(id)
            let expected = bypassResponse(packet)
            processor.process(packet) { response in XCTAssertEqual(response, expected); done.fulfill() }
        }
        _ = processor.activitySnapshot
        XCTAssertEqual(gate.domesticCount, 1)
        gate.completeDomestic(0, .response(nil))
        wait(for: [done], timeout: 2)
        _ = try resolve(processor, makeQuery("cdn.qq.com"))
        XCTAssertEqual(gate.domesticCount, 1)
        XCTAssertEqual(gate.originalCount, 9)
    }

    func testLateOldNetworkResultCannotInstallBypassInNewNetwork() throws {
        let gate = BypassLookupGate(result: nil), processor = try makeProcessor(gate)
        defer { processor.stop() }
        let packet = makeQuery("cdn.qq.com")
        let old = expectation(description: "old generation falls back")
        processor.process(packet) { response in XCTAssertEqual(response, bypassResponse(packet)); old.fulfill() }
        _ = processor.activitySnapshot
        processor.update(directCIDRs: networks)
        wait(for: [old], timeout: 1)
        gate.completeDomestic(0, .response(nil))
        let fresh = expectation(description: "new generation probes")
        processor.process(packet) { response in XCTAssertEqual(response, bypassResponse(packet)); fresh.fulfill() }
        _ = processor.activitySnapshot
        XCTAssertEqual(gate.domesticCount, 2)
        gate.completeDomestic(1, .response(nil))
        wait(for: [fresh], timeout: 1)
    }

    func testBypassDecisionsAreBoundedWithOldestEviction() throws {
        let clock = BypassClock(), gate = BypassLookupGate(result: .response(nil))
        let processor = try makeProcessor(gate, clock: clock); defer { processor.stop() }
        let oldest = makeQuery("first.qq.com")
        _ = try resolve(processor, oldest)
        for index in 0..<DNSProcessor.maximumCacheEntries {
            clock.advance(0.001)
            _ = try resolve(processor, makeQuery("n\(index).qq.com"))
        }
        let count = gate.domesticCount
        _ = try resolve(processor, makeQuery("n\(DNSProcessor.maximumCacheEntries - 1).qq.com"))
        XCTAssertEqual(gate.domesticCount, count)
        _ = try resolve(processor, oldest)
        XCTAssertEqual(gate.domesticCount, count + 1, "Oldest decision must be evicted at the shared capacity")
    }

    private func makeProcessor(_ gate: BypassLookupGate, clock: BypassClock = BypassClock()) throws -> DNSProcessor {
        try DNSProcessor(directCIDRs: networks, directDomains: ["qq.com"],
            domesticLookup: gate.domestic, originalLookup: gate.original, time: { clock.now })
    }
    private func resolve(_ processor: DNSProcessor, _ packet: Data, transport: DNSClientTransport = .udp) throws -> Data {
        let done = expectation(description: "response")
        var value: Data?
        processor.process(packet, transport: transport) { value = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return try XCTUnwrap(value)
    }
}

private final class BypassClock {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ amount: TimeInterval) { lock.lock(); value += amount; lock.unlock() }
}

private final class BypassLookupGate {
    private let lock = NSLock()
    private let result: DNSDomesticResult?
    private var callbacks: [(DNSDomesticResult) -> Void] = []
    private var originals: [(Data, DNSClientTransport)] = []
    init(result: DNSDomesticResult?) { self.result = result }
    var domesticCount: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
    var originalCount: Int { lock.lock(); defer { lock.unlock() }; return originals.count }
    var lastOriginalPacket: Data? { lock.lock(); defer { lock.unlock() }; return originals.last?.0 }
    var lastOriginalTransport: DNSClientTransport? { lock.lock(); defer { lock.unlock() }; return originals.last?.1 }
    func domestic(_ query: DNSQuestion, _ timeout: TimeInterval,
                  _ completion: @escaping (DNSDomesticResult) -> Void) -> DNSCancellation {
        lock.lock(); callbacks.append(completion); lock.unlock()
        if let result { completion(result) }
        return DNSCancellation()
    }
    func original(_ packet: Data, _ transport: DNSClientTransport, _ timeout: TimeInterval,
                  _ completion: @escaping (Data?) -> Void) -> DNSCancellation {
        lock.lock(); originals.append((packet, transport)); lock.unlock()
        completion(bypassResponse(packet)); return DNSCancellation()
    }
    func completeDomestic(_ index: Int, _ result: DNSDomesticResult) {
        lock.lock(); let completion = callbacks[index]; lock.unlock(); completion(result)
    }
}

private func bypassResponse(_ packet: Data) -> Data {
    var response = DNSWire.response(to: DNSWire.question(packet)!, rcode: 3)
    response[3] |= 0x20 // The original resolver's flags and bytes must survive.
    return response
}
