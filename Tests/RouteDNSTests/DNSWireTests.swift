import XCTest
@testable import RouteDNS

final class DNSWireTests: XCTestCase {
    func testParsesCaseAndPreservesOriginalQuestionBytes() throws {
        let data = makeQuery("V.QQ.com", type: 1)
        let query = try XCTUnwrap(DNSWire.question(data))
        XCTAssertEqual(query.name, "v.qq.com")
        XCTAssertEqual(query.questionBytes, data.dropFirst(12))
        XCTAssertEqual(query.udpPayloadSize, 512)
        XCTAssertFalse(query.dnssecRequested)
    }
    func testRejectsMalformedQuestionCountsAndLengths() {
        XCTAssertNil(DNSWire.question(Data(repeating: 0, count: 11)))
        XCTAssertNil(DNSWire.question(Data(repeating: 0, count: 65_536)))
        var multi = makeQuery("v.qq.com"); multi[5] = 2
        XCTAssertNil(DNSWire.question(multi))
        var extra = makeQuery("v.qq.com"); extra.append(0)
        XCTAssertNil(DNSWire.question(extra))
        var response = makeQuery("v.qq.com"); response[2] |= 0x80
        XCTAssertNil(DNSWire.question(response))
        var nonIN = makeQuery("v.qq.com"); nonIN[nonIN.count - 1] = 3
        XCTAssertFalse(DNSWire.question(nonIN)?.synthesisAllowed ?? true)
    }
    func testCompressionCycleAndOutsidePointerAreRejected() {
        var cyclic = Array(makeQuery("v.qq.com")); cyclic[12] = 0xc0; cyclic[13] = 0x0c
        var cursor = 12
        XCTAssertNil(DNSWire.readName(cyclic, offset: &cursor))
        cyclic[13] = 0xff; cursor = 12
        XCTAssertNil(DNSWire.readName(cyclic, offset: &cursor))
        cyclic[13] = 0x02; cursor = 12
        XCTAssertNil(DNSWire.readName(cyclic, offset: &cursor))
    }
    func testRejectsOversizedLabelsAndExpandedName() {
        XCTAssertNil(DNSWire.question(makeQuery(String(repeating: "a", count: 64) + ".com")))
        XCTAssertNil(DNSWire.question(makeQuery(Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: "."))))
    }
    func testEDNSPayloadAndDOAreValidated() throws {
        var data = makeQuery("v.qq.com", edns: true, dnssec: true)
        let query = try XCTUnwrap(DNSWire.question(data))
        XCTAssertTrue(query.dnssecRequested)
        XCTAssertEqual(query.udpPayloadSize, 1232)
        data[data.count - 1] = 4 // RDLENGTH now claims absent bytes.
        XCTAssertNil(DNSWire.question(data))
        var options = makeQuery("v.qq.com", edns: true)
        options[options.count - 1] = 4
        options.append(contentsOf: [0, 10, 0, 4]) // Cookie option has no value.
        XCTAssertNil(DNSWire.question(options))
    }
    func testLocalEDNSAnswersErrorsAndTruncationContainValidOPT() throws {
        for dnssec in [false, true] {
            let packet = makeQuery("v.qq.com", edns: true, dnssec: dnssec)
            let query = try XCTUnwrap(DNSWire.question(packet))
            XCTAssertTrue(query.hasEDNS)
            let responses = [DNSWire.response(to: query, addresses: [0x65060f82], ttl: 20),
                             DNSWire.response(to: query), DNSWire.failure(to: packet),
                             DNSWire.failure(to: packet, rcode: 0, truncated: true)]
            for response in responses {
                let bytes = [UInt8](response), opt = bytes.count - 11
                XCTAssertEqual(DNSWire.read16(bytes, 10), 1)
                XCTAssertEqual(bytes[opt], 0)
                XCTAssertEqual(DNSWire.read16(bytes, opt + 1), 41)
                XCTAssertEqual(DNSWire.read16(bytes, opt + 3), 1232)
                XCTAssertEqual(DNSWire.read32(bytes, opt + 5), dnssec ? 0x8000 : 0)
                XCTAssertEqual(DNSWire.read16(bytes, opt + 9), 0)
                XCTAssertEqual(DNSWire.read16(bytes, 2)! & 0x20, 0)
            }
        }
    }
    func testNonEDNSResponseDoesNotInventOPT() throws {
        let query = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        XCTAssertFalse(query.hasEDNS)
        let response = DNSWire.response(to: query)
        XCTAssertEqual(DNSWire.read16([UInt8](response), 10), 0)
        XCTAssertEqual(response.count, 12 + query.questionBytes.count)
    }
    func testResponseRequiresMatchingIDNameTypeAndClass() throws {
        let query = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        var response = DNSWire.response(to: query, addresses: [0x65060f82], ttl: 60)
        XCTAssertTrue(DNSWire.matchesResponse(response, query: query))
        response[0] ^= 1
        XCTAssertFalse(DNSWire.matchesResponse(response, query: query))
        let other = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com", type: 28)))
        XCTAssertFalse(DNSWire.matchesResponse(DNSWire.response(to: other), query: query))
    }
    func testCNAMEChainResolvesTerminalOnlyAndCapsMinimumTTL() throws {
        let query = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        let response = cnameResponse(query: query, terminal: "cdn.example.cn", aliasTTL: 11, addressTTL: 100)
        XCTAssertEqual(DNSWire.aAnswer(response, for: query), DNSAAnswer(addresses: [0x65060f82], ttl: 11))
        let flat = DNSWire.response(to: query, addresses: [0x65060f82], ttl: 90)
        XCTAssertEqual(DNSWire.aAnswer(flat, for: query)?.ttl, 60)
        XCTAssertEqual(DNSWire.read16([UInt8](flat), 2)! & 0x0020, 0) // AD must be clear.
    }
    func testCNAMECyclesAndTruncatedAnswersAreNotUsed() throws {
        let query = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com")))
        var cycle = cnameResponse(query: query, terminal: "v.qq.com", aliasTTL: 10, addressTTL: 10)
        XCTAssertNil(DNSWire.aAnswer(cycle, for: query)) // CNAME+A same owner is invalid.
        cycle = DNSWire.response(to: query, addresses: [0x65060f82], ttl: 10, truncated: true)
        XCTAssertNil(DNSWire.aAnswer(cycle, for: query))
        XCTAssertNil(DNSWire.aAnswer(cycle.dropLast(), for: query))
    }
    func testEmptyAndFailureResponsesAreDistinct() throws {
        let query = try XCTUnwrap(DNSWire.question(makeQuery("v.qq.com", type: 28)))
        let empty = DNSWire.response(to: query)
        let failure = DNSWire.response(to: query, rcode: 2)
        XCTAssertEqual(DNSWire.read16([UInt8](empty), 2)! & 0xf, 0)
        XCTAssertEqual(DNSWire.read16([UInt8](failure), 2)! & 0xf, 2)
        XCTAssertEqual(DNSWire.read16([UInt8](empty), 6), 0)
    }
}

func makeQuery(_ name: String, type: UInt16 = 1, edns: Bool = false, dnssec: Bool = false, checkingDisabled: Bool = false) -> Data {
    var result = Data()
    result.appendUInt16(0xabcd); result.appendUInt16(0x0100 | (checkingDisabled ? 0x0010 : 0))
    result.appendUInt16(1); result.appendUInt16(0); result.appendUInt16(0); result.appendUInt16(edns ? 1 : 0)
    for label in name.split(separator: ".", omittingEmptySubsequences: false) {
        result.append(UInt8(label.utf8.count)); result.append(contentsOf: label.utf8)
    }
    result.append(0); result.appendUInt16(type); result.appendUInt16(1)
    if edns {
        result.append(0); result.appendUInt16(41); result.appendUInt16(1232)
        result.appendUInt32(dnssec ? 0x8000 : 0); result.appendUInt16(0)
    }
    return result
}

func cnameResponse(query: DNSQuestion, terminal: String, aliasTTL: UInt32, addressTTL: UInt32) -> Data {
    var result = DNSWire.response(to: query)
    result[7] = 2
    var target = Data()
    for label in terminal.split(separator: ".") { target.append(UInt8(label.count)); target.append(contentsOf: label.utf8) }
    target.append(0)
    result.appendUInt16(0xc00c); result.appendUInt16(5); result.appendUInt16(1); result.appendUInt32(aliasTTL)
    result.appendUInt16(UInt16(target.count)); result.append(target)
    result.append(target); result.appendUInt16(1); result.appendUInt16(1); result.appendUInt32(addressTTL)
    result.appendUInt16(4); result.appendUInt32(0x65060f82)
    return result
}
