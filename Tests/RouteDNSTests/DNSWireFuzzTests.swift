import XCTest
@testable import RouteDNS

final class DNSWireFuzzTests: XCTestCase {
    func testEveryTruncatedQueryAndAnswerIsRejectedBeforeUse() throws {
        for packet in [makeQuery("a.qq.com"), makeQuery("a.qq.com", edns: true),
                       makeQuery("a.qq.com", edns: true, dnssec: true)] {
            for size in 0..<packet.count {
                XCTAssertNil(DNSWire.question(Data(packet.prefix(size))), "Truncated query length \(size)")
            }
            let question = try XCTUnwrap(DNSWire.question(packet))
            let answer = DNSWire.response(to: question, addresses: [0x65060f82], ttl: 30)
            for size in 0..<answer.count {
                XCTAssertNil(DNSWire.aAnswer(Data(answer.prefix(size)), for: question), "Truncated answer length \(size)")
            }
        }
    }

    func testInvalidRecordAndEDNSLengthsCannotBecomeDirectAnswers() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("a.qq.com")))
        let valid = DNSWire.response(to: question, addresses: [0x65060f82], ttl: 30)
        for count in [UInt16(2), 256, 257, 65_535] {
            var packet = valid
            packet[6] = UInt8(count >> 8); packet[7] = UInt8(count & 255)
            XCTAssertNil(DNSWire.aAnswer(packet, for: question))
        }
        for length in [UInt16(1), 3, 5, 65_535] {
            var packet = valid
            packet[packet.count - 6] = UInt8(length >> 8); packet[packet.count - 5] = UInt8(length & 255)
            XCTAssertNil(DNSWire.aAnswer(packet, for: question))
            var edns = makeQuery("a.qq.com", edns: true)
            edns[edns.count - 2] = UInt8(length >> 8); edns[edns.count - 1] = UInt8(length & 255)
            XCTAssertNil(DNSWire.question(edns))
        }
    }

    func testSeededWireMutationsRemainBoundedAndParsedQuestionsRoundTrip() throws {
        let question = try XCTUnwrap(DNSWire.question(makeQuery("a.qq.com")))
        let corpus = [makeQuery("a.qq.com"), makeQuery("a.qq.com", edns: true, dnssec: true),
                      DNSWire.response(to: question, addresses: [0x65060f82], ttl: 30),
                      cnameResponse(query: question, terminal: "cdn.example.cn", aliasTTL: 5, addressTTL: 30),
                      Data(repeating: 0xff, count: 512), Data(repeating: 0, count: 512)]
        var random = DNSWireRandom(state: 0x726f757465646e73)
        for iteration in 0..<6_000 {
            var packet = corpus[random.next(corpus.count)]
            switch random.next(4) {
            case 0:
                packet = Data(packet.prefix(random.next(packet.count + 1)))
            case 1:
                for _ in 0..<(1 + random.next(8)) { packet[random.next(packet.count)] = UInt8(random.next(256)) }
            case 2:
                packet.append(contentsOf: (0..<random.next(256)).map { _ in UInt8(random.next(256)) })
            default:
                let offset = random.next(packet.count - 1)
                packet[offset] = 0xc0 | UInt8(random.next(64))
                packet[offset + 1] = UInt8(random.next(256))
            }
            _ = DNSWire.isQueryMessage(packet)
            _ = DNSWire.matchesResponse(packet, request: corpus[0])
            _ = DNSWire.aAnswer(packet, for: question)
            let error = DNSWire.failure(to: packet)
            XCTAssertLessThanOrEqual(error.count, 512, "Iteration \(iteration)")
            XCTAssertEqual(DNSWire.read16([UInt8](error), 2)! & 0x800f, 0x8002)
            for response in [false, true] {
                if let parsed = DNSWire.question(packet, response: response) {
                    XCTAssertLessThanOrEqual(parsed.labels.reduce(1) { $0 + $1.count + 1 }, 255)
                    XCTAssertTrue(parsed.labels.allSatisfy { !$0.isEmpty && $0.count <= 63 })
                    let rebuilt = DNSWire.response(to: parsed)
                    XCTAssertTrue(DNSWire.matchesResponse(rebuilt, query: parsed), "Iteration \(iteration)")
                }
            }
            var cursor = random.next(packet.count + 1)
            _ = DNSWire.readName([UInt8](packet), offset: &cursor)
        }
    }
}

private struct DNSWireRandom {
    var state: UInt64
    mutating func next(_ limit: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 32) % UInt64(limit))
    }
}
