import XCTest
import CryptoKit
@testable import RouteDNS

final class DNSDefaultForwardingTests: XCTestCase {
    private let networks = ["101.4.0.0/14", "223.5.5.0/24"]
    private let direct = DNSAAnswer(addresses: [0x65060f82], ttl: 30)

    func testFrozenFullListHasExactCandidateHashAndBoundaryDomainsMatch() throws {
        XCTAssertEqual(DomesticDomains.suffixes.count, 7_726)
        let bytes = Data((DomesticDomains.suffixes.joined(separator: "\n") + "\n").utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "a714c11aa381eff872ef7dc93af5f69deb8e429ab94da42a5e50adf3029fc321")
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: DomesticDomains.suffixes,
            domestic: { _, completion in completion(self.direct) },
            original: { _, _, completion in XCTFail("Known frozen suffix was not matched"); completion(nil) })
        defer { processor.stop() }
        for name in ["v.qq.com", "www.baidu.com", "v.qq.com.tdnsv6.com",
                     "www." + DomesticDomains.suffixes.first!, "www." + DomesticDomains.suffixes.last!] {
            let query = makeQuery(name)
            XCTAssertEqual(DNSWire.aAnswer(try resolve(processor, query), for: try XCTUnwrap(DNSWire.question(query))), direct)
        }
    }

    func testSupports200000SuffixesAndRejectsLargerPolicy() throws {
        let processor = try DNSProcessor(directCIDRs: networks,
            directDomains: (0..<200_000).map { "d\($0).example.cn" },
            domestic: { _, completion in completion(self.direct) },
            original: { _, _, completion in XCTFail("Last suffix was not matched"); completion(nil) })
        defer { processor.stop() }
        let query = makeQuery("www.d199999.example.cn")
        XCTAssertEqual(DNSWire.aAnswer(try resolve(processor, query), for: try XCTUnwrap(DNSWire.question(query))), direct)
        XCTAssertThrowsError(try DNSProcessor(directCIDRs: networks, directDomains: Array(repeating: "qq.com", count: 200_001),
            domestic: { _, _ in }, original: { _, _, _ in }))
    }

    func testFullListNeverLeaksForeignMagicDNSOrPrivateNamesToDomesticUpstream() throws {
        for name in ["www.google.com", "api.openai.com", "www.github.com", "www.apple.com.cn", "www.microsoft.cn",
                     "device.tail-example.ts.net", "my-macbook", "100.100.100.100.in-addr.arpa", "printer.local",
                     "bucket.myqcloud.com", "bucket.aliyuncs.com", "qq.com.attacker.example", "notqq.com"] {
            let query = makeQuery(name, edns: true)
            var original = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), addresses: [0x64400001], ttl: 91)
            original[3] |= 0x20 // Preserve the upstream's AD bit as well as all record bytes.
            let processor = try DNSProcessor(directCIDRs: networks, directDomains: DomesticDomains.suffixes,
                domestic: { _, completion in XCTFail("Protected/unmatched name leaked: \(name)"); completion(nil) },
                original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
            XCTAssertEqual(try resolve(processor, query), original, name)
            processor.stop()
        }
    }

    func testNoDomesticLookupUntilHTTPSResolverIsInActiveDirectPlan() throws {
        let query = makeQuery("v.qq.com"), original = DNSWire.failure(to: makeQuery("v.qq.com"), rcode: 3)
        for cidrs in [[], ["101.4.0.0/14"]] {
            let processor = try DNSProcessor(directCIDRs: cidrs, directDomains: DomesticDomains.suffixes,
                domestic: { _, completion in XCTFail("DoH was not directly routed"); completion(nil) },
                original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
            XCTAssertEqual(try resolve(processor, query), original)
            processor.stop()
        }
    }

    func testForeignAnswersAndDomesticErrorsPreserveAllRequestedTypes() throws {
        for type: UInt16 in [1, 28, 64, 65] {
            for answer: DNSAAnswer? in [nil, DNSAAnswer(addresses: [0x01010101], ttl: 10),
                                      DNSAAnswer(addresses: [0x65060f82, 0x01010101], ttl: 10)] {
                let query = makeQuery("v.qq.com", type: type, edns: true)
                let original = DNSWire.failure(to: query, rcode: 3)
                let processor = try DNSProcessor(directCIDRs: networks, directDomains: DomesticDomains.suffixes,
                    domestic: { _, completion in completion(answer) },
                    original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
                XCTAssertEqual(try resolve(processor, query), original)
                processor.stop()
            }
        }
    }

    func testRootNonINMultiQuestionEDNSOptionsAndUnusualFlagsRemainOpaque() throws {
        var root = makeQuery("x", type: 2); root.removeSubrange(12..<14)
        var nonIN = makeQuery("qq.com"); nonIN[nonIN.count - 1] = 3
        var multi = makeQuery("qq.com"); multi[5] = 2; multi.append(makeQuery("other.qq.com").dropFirst(12))
        var cookie = makeQuery("qq.com", edns: true); cookie[cookie.count - 1] = 4; cookie.append(contentsOf: [0, 10, 0, 0])
        var version = makeQuery("qq.com", edns: true); version[version.count - 5] = 1
        var reservedFlag = makeQuery("qq.com"); reservedFlag[3] |= 0x40
        var binary = makeQuery("x.qq.com"); binary[13] = 0xff
        for query in [root, nonIN, multi, cookie, version, reservedFlag, binary,
                      makeQuery("qq.com", edns: true, dnssec: true), makeQuery("qq.com", checkingDisabled: true),
                      makeQuery("qq.com", type: 15), makeQuery("qq.com", type: 16), makeQuery("qq.com", type: 255)] {
            var original = query; original[2] |= 0x80; original[3] |= 0x80
            let processor = try DNSProcessor(directCIDRs: networks, directDomains: DomesticDomains.suffixes,
                domestic: { _, completion in XCTFail("Opaque request reached domestic resolver"); completion(nil) },
                original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) })
            XCTAssertEqual(try resolve(processor, query), original)
            processor.stop()
        }
    }

    func testHeaderOnlyUpstreamErrorsArePreservedExactly() throws {
        let query = makeQuery("www.google.com")
        var original = Data(); original.appendUInt16(0xabcd); original.appendUInt16(0x8181)
        for _ in 0..<4 { original.appendUInt16(0) }
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: DomesticDomains.suffixes,
            domestic: { _, _ in XCTFail("Unexpected domestic lookup") }, original: { _, _, completion in completion(original) })
        XCTAssertEqual(try resolve(processor, query), original)
        processor.stop()
    }

    func testNetworkUpdateDiscardsOldInflightResultBeforeStartingNewGeneration() throws {
        let firstStarted = expectation(description: "first domestic lookup"), secondStarted = expectation(description: "new domestic lookup")
        let firstDone = expectation(description: "old lookup fell back"), secondDone = expectation(description: "new lookup completed")
        let gate = DomesticLookupGate(), query = makeQuery("v.qq.com"), original = DNSWire.failure(to: makeQuery("v.qq.com"), rcode: 3)
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: ["qq.com"], domestic: { _, completion in
            if gate.append(completion) == 0 { firstStarted.fulfill() } else { secondStarted.fulfill() }
        }, original: { _, _, completion in completion(original) })
        processor.process(query) { result in XCTAssertEqual(result, original); firstDone.fulfill() }
        wait(for: [firstStarted], timeout: 1)
        processor.update(directCIDRs: networks) // Same CIDRs, different physical network.
        wait(for: [firstDone], timeout: 1)
        processor.process(query) { result in
            XCTAssertEqual(result.flatMap { DNSWire.aAnswer($0, for: DNSWire.question(query)!) }?.addresses, [0x65060f83])
            secondDone.fulfill()
        }
        wait(for: [secondStarted], timeout: 1)
        gate.callback(0)(direct)
        gate.callback(1)(DNSAAnswer(addresses: [0x65060f83], ttl: 30))
        wait(for: [secondDone], timeout: 1)
        processor.stop()
    }

    func testDomesticDeadlineFallsBackAndOverallDeadlineCompletesSilentOriginal() throws {
        let query = makeQuery("v.qq.com"), original = DNSWire.failure(to: makeQuery("v.qq.com"), rcode: 3)
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: ["qq.com"],
            domestic: { _, _ in }, original: { packet, _, completion in XCTAssertEqual(packet, query); completion(original) },
            domesticTimeout: 0.01, requestTimeout: 0.2)
        XCTAssertEqual(try resolve(processor, query), original)
        processor.stop()
        let stalled = try DNSProcessor(directCIDRs: [], directDomains: ["qq.com"], domestic: { _, _ in }, original: { _, _, _ in },
            requestTimeout: 0.01)
        XCTAssertEqual(DNSWire.read16([UInt8](try resolve(stalled, query)), 2)! & 0xf, 2)
        stalled.stop()
    }

    func testStopCompletesPendingRequestsOnceAndLateResultsCannotRestart() throws {
        let started = expectation(description: "started"), done = expectation(description: "stopped")
        done.assertForOverFulfill = true
        let gate = DomesticLookupGate(), query = makeQuery("v.qq.com")
        let processor = try DNSProcessor(directCIDRs: networks, directDomains: ["qq.com"], domestic: { _, completion in
            _ = gate.append(completion); started.fulfill()
        }, original: { _, _, _ in XCTFail("Stopped processor must not initiate fallback") })
        processor.process(query) { result in
            XCTAssertEqual(result.flatMap { DNSWire.read16([UInt8]($0), 2) }! & 0xf, 2); done.fulfill()
        }
        wait(for: [started], timeout: 1)
        processor.stop(); gate.callback(0)(direct); processor.stop()
        wait(for: [done], timeout: 1)
        XCTAssertEqual(DNSWire.read16([UInt8](try resolve(processor, query)), 2)! & 0xf, 2)
    }

    private func resolve(_ processor: DNSProcessor, _ query: Data) throws -> Data {
        let done = expectation(description: "DNS response")
        var result: Data?
        processor.process(query) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return try XCTUnwrap(result)
    }
}

private final class DomesticLookupGate {
    private let lock = NSLock()
    private var callbacks: [(DNSAAnswer?) -> Void] = []
    func append(_ callback: @escaping (DNSAAnswer?) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        callbacks.append(callback); return callbacks.count - 1
    }
    func callback(_ index: Int) -> (DNSAAnswer?) -> Void {
        lock.lock(); defer { lock.unlock() }; return callbacks[index]
    }
}
