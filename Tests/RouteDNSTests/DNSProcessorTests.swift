import XCTest
@testable import RouteDNS

final class DNSProcessorTests: XCTestCase {
    private let networks = ["101.4.0.0/14", "223.5.5.0/24"]
    private let scope = ["qq.com", "tsinghua.edu.cn"]

    func testVerifiedDirectAIsFlattenedToOriginalName() throws {
        let processor = try makeProcessor(answer: DNSAAnswer(addresses: [0x65060f82], ttl: 25))
        let data = makeQuery("v.qq.com")
        let result = try resolve(processor, data)
        let query = try XCTUnwrap(DNSWire.question(data))
        XCTAssertEqual(DNSWire.aAnswer(result, for: query), DNSAAnswer(addresses: [0x65060f82], ttl: 25))
        XCTAssertEqual(DNSWire.question(result, response: true)?.name, "v.qq.com")
    }
    func testAAAAAndHTTPSAreEmptyOnlyForVerifiedDirectIPv4() throws {
        for type: UInt16 in [28, 64, 65] {
            let processor = try makeProcessor(answer: DNSAAnswer(addresses: [0x65060f82], ttl: 20))
            let result = try resolve(processor, makeQuery("v.qq.com", type: type))
            XCTAssertEqual(DNSWire.read16([UInt8](result), 6), 0)
            XCTAssertEqual(DNSWire.read16([UInt8](result), 2)! & 0xf, 0)
        }
    }
    func testForeignOrMixedAddressesPreserveOriginalResponseExactly() throws {
        for addresses: [UInt32] in [[0x01010101], [0x65060f82, 0x01010101]] {
            let query = makeQuery("v.qq.com")
            let original = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), addresses: [0xc6120001], ttl: 1)
            let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
                domestic: { _, completion in completion(DNSAAnswer(addresses: addresses, ttl: 60)) },
                original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
            XCTAssertEqual(try resolve(processor, query), original)
        }
    }
    func testOutOfScopeSuffixLookalikeAndTailnetNeverQueryDomesticUpstream() throws {
        for name in ["www.google.com", "notqq.com", "qq.com.attacker.example", "host.tail-example.ts.net"] {
            let query = makeQuery(name)
            let original = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), addresses: [0xc6120001], ttl: 1)
            let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
                domestic: { _, _ in XCTFail("Out-of-scope name reached domestic upstream") },
                original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
            XCTAssertEqual(try resolve(processor, query), original)
        }
    }
    func testDOAndCDQueriesAreForwardedUnchanged() throws {
        for query in [makeQuery("v.qq.com", edns: true, dnssec: true), makeQuery("v.qq.com", checkingDisabled: true)] {
            let original = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), addresses: [0xc6120001], ttl: 1)
            let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
                domestic: { _, _ in XCTFail("DNSSEC query was synthesized") },
                original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
            XCTAssertEqual(try resolve(processor, query), original)
        }
    }
    func testOtherRecordTypesAreForwardedWithoutDomesticLookup() throws {
        let query = makeQuery("qq.com", type: 15)
        let original = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)))
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
            domestic: { _, _ in XCTFail("MX query should retain original semantics") },
            original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
        XCTAssertEqual(try resolve(processor, query), original)
    }
    func testUpstreamFailureProducesSERVFAILWhenFallbackAlsoFails() throws {
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
            domestic: { _, completion in completion(nil) }, original: { _, _, completion in completion(nil) })
        let result = try resolve(processor, makeQuery("v.qq.com"))
        XCTAssertEqual(DNSWire.read16([UInt8](result), 2)! & 0xf, 2)
    }
    func testInvalidFallbackIDIsRejected() throws {
        let query = makeQuery("v.qq.com")
        var original = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), addresses: [0xc6120001], ttl: 1)
        original[0] ^= 1
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
            domestic: { _, completion in completion(nil) }, original: { _, _, completion in completion(original) })
        let result = try resolve(processor, query)
        XCTAssertEqual(DNSWire.read16([UInt8](result), 2)! & 0xf, 2)
    }
    func testCacheUsesRemainingTTLAndExpires() throws {
        let clock = TestClock(), counter = TestCounter()
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
            domestic: { _, completion in counter.increment(); completion(DNSAAnswer(addresses: [0x65060f82], ttl: 60)) },
            original: { _, _, _ in XCTFail("Unexpected fallback") }, time: { clock.now })
        let packet = makeQuery("v.qq.com"), query = try XCTUnwrap(DNSWire.question(packet))
        XCTAssertEqual(DNSWire.aAnswer(try resolve(processor, packet), for: query)?.ttl, 60)
        clock.set(59)
        XCTAssertEqual(DNSWire.aAnswer(try resolve(processor, packet), for: query)?.ttl, 1)
        XCTAssertEqual(counter.count, 1)
        clock.set(61)
        XCTAssertEqual(DNSWire.aAnswer(try resolve(processor, packet), for: query)?.ttl, 60)
        XCTAssertEqual(counter.count, 2)
    }
    func testPolicyUpdatePreventsReuseOfPreviouslyDirectAnswer() throws {
        let packet = makeQuery("v.qq.com"), query = try XCTUnwrap(DNSWire.question(packet))
        let original = DNSWire.response(to: query, addresses: [0xc6120001], ttl: 1)
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
            domestic: { _, completion in completion(DNSAAnswer(addresses: [0x65060f82], ttl: 60)) },
            original: { _, _, completion in completion(original) })
        XCTAssertNotEqual(try resolve(processor, packet), original)
        processor.update(directCIDRs: [])
        XCTAssertEqual(try resolve(processor, packet), original)
    }
    func testInvalidPolicyAndBroadOrTailnetScopeAreRejected() {
        XCTAssertThrowsError(try DNSDirectNetworks(["0.0.0.0/0"]))
        XCTAssertThrowsError(try DNSDirectNetworks(["100.64.0.0/10"]))
        for domains in [["com"], ["ts.net"], ["tail-example.ts.net"], ["*.qq.com"], ["bad..cn"]] {
            XCTAssertThrowsError(try DNSProcessor(directCIDRs: networks, directDomains: domains,
                domestic: { _, _ in }, original: { _, _, _ in }))
        }
    }
    func testProductScopePassesModuleValidation() throws {
        _ = try DNSProcessor(directCIDRs: networks, directDomains: DomesticDomains.suffixes,
            domestic: { _, _ in }, original: { _, _, _ in })
    }
    func testMergedNetworksCoverAdjacencyButNotGap() throws {
        let policy = try DNSDirectNetworks(["101.6.15.0/25", "101.6.15.128/25", "101.6.17.0/24"])
        XCTAssertTrue(policy.contains(0x65060fff))
        XCTAssertTrue(policy.contains(0x65061101))
        XCTAssertFalse(policy.contains(0x65061001))
    }
    func testTCPTransportSurvivesDirectAndDomesticFailureFallback() throws {
        for name in ["www.google.com", "v.qq.com"] {
            let query = makeQuery(name, edns: true)
            let response = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), rcode: 3)
            let done = expectation(description: "TCP fallback")
            let processor = try DNSProcessor(directCIDRs: networks, directDomains: scope,
                domestic: { _, completion in completion(nil) },
                original: { packet, transport, completion in
                    XCTAssertEqual(packet, query); XCTAssertEqual(transport, .tcp); completion(response)
                })
            processor.process(query, transport: .tcp) { result in
                XCTAssertEqual(result, response); done.fulfill()
            }
            wait(for: [done], timeout: 2); processor.stop()
        }
    }
    func testTransportDoesNotChangeDomesticProbeOrEDNSLocalAnswer() throws {
        let query = makeQuery("v.qq.com", edns: true)
        let processor = try makeProcessor(answer: DNSAAnswer(addresses: [0x65060f82], ttl: 25))
        let done = expectation(description: "TCP domestic")
        processor.process(query, transport: .tcp) { response in
            XCTAssertEqual(response.flatMap { DNSWire.read16([UInt8]($0), 10) }, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 2); processor.stop()
    }
    private func makeProcessor(answer: DNSAAnswer) throws -> DNSProcessor {
        try DNSProcessor(directCIDRs: networks, directDomains: scope,
            domestic: { _, completion in completion(answer) }, original: { _, _, completion in XCTFail("Unexpected fallback"); completion(nil) })
    }
    private func resolve(_ processor: DNSProcessor, _ query: Data) throws -> Data {
        let done = expectation(description: "DNS resolved")
        var result: Data?
        processor.process(query) { response in result = response; done.fulfill() }
        wait(for: [done], timeout: 2)
        return try XCTUnwrap(result)
    }
}

private final class TestClock {
    private let lock = NSLock(); private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
}
private final class TestCounter {
    private let lock = NSLock(); private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
