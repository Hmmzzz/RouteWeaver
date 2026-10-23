import XCTest
@testable import RouteDNS

final class DNSOriginalUpstreamTests: XCTestCase {
    func testUDPForwardsDNSSECQueryAndResponseByteForByte() throws {
        let query = makeQuery("host.tail-example.ts.net", edns: true, dnssec: true)
        var response = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), addresses: [0x64400102], ttl: 31)
        response[3] |= 0x20
        let udp = FakeDNSConnection(); udp.datagrams = [response]
        let upstream = DNSOriginalUpstream(makeConnection: { tcp in XCTAssertFalse(tcp); return udp })
        XCTAssertEqual(lookup(upstream, query), response)
        upstream.stop()
        XCTAssertEqual(udp.sent, [query])
    }

    func testTruncatedUDPIsRelayedUnchangedWithoutOpeningTCP() throws {
        let query = makeQuery("www.google.com", edns: true, dnssec: true)
        let response = DNSWire.response(to: try XCTUnwrap(DNSWire.question(query)), truncated: true)
        let udp = FakeDNSConnection(); udp.datagrams = [response]
        var connections = 0
        let upstream = DNSOriginalUpstream(makeConnection: { tcp in
            connections += 1; XCTAssertFalse(tcp); return udp
        })
        XCTAssertEqual(lookup(upstream, query), response)
        upstream.stop()
        XCTAssertEqual(connections, 1); XCTAssertEqual(udp.sent, [query])
    }

    func testClientTCPStartsWithTCPAndHandlesFragmentedLargeDNSSECResponse() throws {
        var query = makeQuery("www.google.com", edns: true, dnssec: true)
        query[query.count - 8] = 2; query[query.count - 7] = 0 // Advertise 512-byte UDP limit.
        let question = try XCTUnwrap(DNSWire.question(query))
        let response = DNSWire.response(to: question, addresses: Array(repeating: 0xc6120001, count: 64), ttl: 13)
        XCTAssertGreaterThan(response.count, question.udpPayloadSize)
        let tcp = FakeDNSConnection()
        var framed = Data(); framed.appendUInt16(UInt16(response.count)); framed.append(response)
        tcp.chunks = [(framed.prefix(1), false), (framed.subdata(in: 1..<5), false), (framed.dropFirst(5), true)]
        var connections = 0
        let upstream = DNSOriginalUpstream(makeConnection: { useTCP in
            connections += 1; XCTAssertTrue(useTCP); return tcp
        })
        XCTAssertEqual(lookup(upstream, query, transport: .tcp), response)
        upstream.stop()
        var expected = Data(); expected.appendUInt16(UInt16(query.count)); expected.append(query)
        XCTAssertEqual(tcp.sent, [expected]); XCTAssertEqual(connections, 1)
        XCTAssertEqual(tcp.cancelCount, 1)
    }

    func testWrongUDPTransactionIsIgnoredBeforeAcceptingCorrectResponse() throws {
        let query = makeQuery("www.google.com"), question = try XCTUnwrap(DNSWire.question(query))
        let correct = DNSWire.response(to: question, addresses: [0xc6120001], ttl: 1)
        var wrong = correct; wrong[0] ^= 1
        let udp = FakeDNSConnection(); udp.datagrams = [wrong, correct]
        let upstream = DNSOriginalUpstream(makeConnection: { tcp in XCTAssertFalse(tcp); return udp })
        XCTAssertEqual(lookup(upstream, query), correct)
        upstream.stop()
    }

    func testPrematureTCPEOFReturnsFailureWithoutPartialResponse() throws {
        let query = makeQuery("www.google.com")
        let tcp = FakeDNSConnection()
        tcp.chunks = [(Data([0, 40, 1, 2, 3]), true)]
        let upstream = DNSOriginalUpstream(makeConnection: { useTCP in XCTAssertTrue(useTCP); return tcp })
        XCTAssertNil(lookup(upstream, query, transport: .tcp)); upstream.stop()
        XCTAssertEqual(tcp.cancelCount, 1)
    }

    func testDeadlineCoversStalledClientTCP() throws {
        let query = makeQuery("www.google.com")
        let tcp = FakeDNSConnection()
        let upstream = DNSOriginalUpstream(timeout: 0.02, makeConnection: { useTCP in XCTAssertTrue(useTCP); return tcp })
        XCTAssertNil(lookup(upstream, query, transport: .tcp)); upstream.stop()
        XCTAssertEqual(tcp.cancelCount, 1)
    }

    func testStopDrainsOutstandingRequestAndRejectsFurtherLookups() throws {
        let started = expectation(description: "connection started"), done = expectation(description: "stopped request")
        done.assertForOverFulfill = true
        let udp = FakeDNSConnection(); udp.onStart = { started.fulfill() }
        let upstream = DNSOriginalUpstream(makeConnection: { tcp in XCTAssertFalse(tcp); return udp })
        let query = makeQuery("host.tail-example.ts.net")
        upstream.lookup(query) { result in XCTAssertNil(result); done.fulfill() }
        wait(for: [started], timeout: 1)
        upstream.stop(); upstream.stop()
        wait(for: [done], timeout: 1)
        XCTAssertNil(lookup(upstream, query))
        XCTAssertEqual(udp.cancelCount, 1)
    }

    func testCancellationCancelsConnectionAndCompletesOnce() throws {
        let started = expectation(description: "original connection started")
        let done = expectation(description: "original cancelled"); done.assertForOverFulfill = true
        let tcp = FakeDNSConnection(); tcp.onStart = { started.fulfill() }
        let upstream = DNSOriginalUpstream(makeConnection: { _ in tcp })
        let cancellation = upstream.lookup(makeQuery("www.google.com"), transport: .tcp) { response in
            XCTAssertNil(response); done.fulfill()
        }
        wait(for: [started], timeout: 1)
        cancellation.cancel(); cancellation.cancel()
        wait(for: [done], timeout: 1)
        upstream.stop()
        XCTAssertEqual(tcp.cancelCount, 1)
    }

    func testPerRequestBudgetIsShorterThanInstanceTimeout() {
        let done = expectation(description: "short request deadline")
        let udp = FakeDNSConnection()
        let upstream = DNSOriginalUpstream(timeout: 3, makeConnection: { _ in udp })
        let start = ProcessInfo.processInfo.systemUptime
        upstream.lookup(makeQuery("www.google.com"), timeout: 0.03) { response in
            XCTAssertNil(response); done.fulfill()
        }
        wait(for: [done], timeout: 0.8)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.8)
        upstream.stop(); XCTAssertEqual(udp.cancelCount, 1)
    }

    func testExhaustedBudgetDoesNotCreateConnection() {
        let upstream = DNSOriginalUpstream(makeConnection: { _ in XCTFail("No budget must not open a socket"); return FakeDNSConnection() })
        for budget in [0, -1, Double.infinity, Double.nan] {
            let done = expectation(description: "invalid budget")
            upstream.lookup(makeQuery("www.google.com"), timeout: budget) { response in
                XCTAssertNil(response); done.fulfill()
            }
            wait(for: [done], timeout: 1)
        }
        upstream.stop()
    }

    func testCancellationReleasesAllUpstreamSlotsForNewWork() {
        let started = expectation(description: "all upstream slots occupied"); started.expectedFulfillmentCount = 64
        let nextStarted = expectation(description: "new work admitted after cancellation")
        var creations = 0
        let upstream = DNSOriginalUpstream(makeConnection: { _ in
            creations += 1
            let connection = FakeDNSConnection()
            connection.onStart = creations <= 64 ? { started.fulfill() } : { nextStarted.fulfill() }
            return connection
        })
        let done = expectation(description: "cancelled work")
        done.expectedFulfillmentCount = 64; done.assertForOverFulfill = true
        let handles = (0..<64).map { _ in upstream.lookup(makeQuery("www.google.com")) { response in
            XCTAssertNil(response); done.fulfill()
        } }
        wait(for: [started], timeout: 1)
        handles.forEach { $0.cancel() }
        wait(for: [done], timeout: 1)
        let next = expectation(description: "next request gets its short deadline")
        upstream.lookup(makeQuery("www.google.com"), timeout: 0.02) { response in
            XCTAssertNil(response); next.fulfill()
        }
        wait(for: [nextStarted, next], timeout: 1)
        upstream.stop()
    }

    func testOpaqueQueryAndHeaderOnlyFORMERRAreRelayedUnchanged() {
        var query = makeQuery("qq.com"); query[5] = 2; query.append(makeQuery("other.qq.com").dropFirst(12))
        var response = Data(); response.appendUInt16(0xabcd); response.appendUInt16(0x8181)
        for _ in 0..<4 { response.appendUInt16(0) }
        let udp = FakeDNSConnection(); udp.datagrams = [response]
        let upstream = DNSOriginalUpstream(makeConnection: { _ in udp })
        XCTAssertEqual(lookup(upstream, query), response)
        upstream.stop(); XCTAssertEqual(udp.sent, [query])
    }

    func testMaximumSizeQueryStartsWithTCPInsteadOfOversizedUDP() {
        var query = makeQuery("qq.com"); query.append(Data(repeating: 0, count: DNSWire.maximumQuerySize - query.count))
        var response = Data(); response.appendUInt16(0xabcd); response.appendUInt16(0x8181)
        for _ in 0..<4 { response.appendUInt16(0) }
        var framed = Data(); framed.appendUInt16(UInt16(response.count)); framed.append(response)
        let tcp = FakeDNSConnection(); tcp.chunks = [(framed, true)]
        let upstream = DNSOriginalUpstream(makeConnection: { useTCP in XCTAssertTrue(useTCP); return tcp })
        XCTAssertEqual(lookup(upstream, query), response)
        upstream.stop()
        XCTAssertEqual(tcp.sent.first?.prefix(2), Data([0xff, 0xff]))
        XCTAssertEqual(tcp.sent.first?.dropFirst(2), query)
    }

    private func lookup(_ upstream: DNSOriginalUpstream, _ data: Data, transport: DNSClientTransport = .udp) -> Data? {
        let done = expectation(description: "upstream completed")
        var result: Data?
        upstream.lookup(data, transport: transport) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 1)
        return result
    }
}

/// No sockets. All callbacks run on the upstream's serial queue, including a
/// synchronous cancellation callback to exercise replacement/stop reentrancy.
private final class FakeDNSConnection: DNSUpstreamConnection {
    var stateUpdateHandler: ((DNSUpstreamConnectionState) -> Void)?
    var datagrams: [Data] = []
    var chunks: [(Data, Bool)] = []
    var onStart: (() -> Void)?
    private var queue: DispatchQueue!
    private(set) var sent: [Data] = []
    private(set) var cancelCount = 0
    func start(queue: DispatchQueue) {
        self.queue = queue
        queue.async { self.onStart?(); self.stateUpdateHandler?(.ready) }
    }
    func send(_ data: Data, completion: @escaping (Bool) -> Void) {
        sent.append(data); queue.async { completion(true) }
    }
    func receiveDatagram(completion: @escaping (Data?, Bool) -> Void) {
        guard !datagrams.isEmpty else { return }
        let data = datagrams.removeFirst(); queue.async { completion(data, true) }
    }
    func receiveStream(maximumLength: Int, completion: @escaping (Data?, Bool, Bool) -> Void) {
        guard !chunks.isEmpty else { return }
        let (data, complete) = chunks.removeFirst()
        XCTAssertLessThanOrEqual(data.count, maximumLength)
        queue.async { completion(data, complete, true) }
    }
    func cancel() { cancelCount += 1; stateUpdateHandler?(.cancelled) }
}
