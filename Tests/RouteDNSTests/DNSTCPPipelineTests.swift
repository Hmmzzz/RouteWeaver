import Darwin
import XCTest
@testable import RouteDNS

/// Only loopback sockets are used. Upstream completions are released explicitly
/// so response ordering, capacity and cancellation do not depend on the network.
final class DNSTCPPipelineTests: XCTestCase {
    func testSlowQueryDoesNotBlockLaterResponsesAfterHalfClose() throws {
        let started = XCTestExpectation(description: "three queries admitted"); started.expectedFulfillmentCount = 3
        let gate = TCPOriginalGate(onStart: { _ in started.fulfill() })
        let (processor, proxy) = try startDNSProxy { try makeProcessor(gate) }
        defer { proxy.stop() }
        let client = try TCPTestClient(port: proxy.port)
        let queries = (1...3).map { query(UInt16($0)) }
        try client.send(queries)
        try client.halfClose()
        wait(for: [started], timeout: 2)

        // The first query remains outstanding while two later replies arrive.
        gate.complete(2)
        XCTAssertEqual(try client.readMessage(), tcpResponse(for: queries[1]))
        XCTAssertFalse(try client.hasReadableData(timeout: 100), "Half-close must not close with replies outstanding")
        gate.complete(3)
        XCTAssertEqual(try client.readMessage(), tcpResponse(for: queries[2]))
        XCTAssertEqual(processor.activitySnapshot.active, 1)
        gate.complete(1)
        XCTAssertEqual(try client.readMessage(), tcpResponse(for: queries[0]))
        try client.expectEOF()
    }

    func testCachedDomesticAnswerOvertakesSlowOriginalQuery() throws {
        let domestic = XCTestExpectation(description: "one cache fill"); domestic.assertForOverFulfill = true
        let slow = XCTestExpectation(description: "original query remains outstanding")
        let gate = TCPOriginalGate(onStart: { _ in slow.fulfill() })
        let (processor, proxy) = try startDNSProxy {
            try DNSProcessor(directCIDRs: ["101.4.0.0/14", "223.5.5.0/24"], directDomains: ["qq.com"],
                domesticLookup: { _, _, completion in
                    domestic.fulfill(); completion(.response(DNSAAnswer(addresses: [0x65060f82], ttl: 30)))
                    return DNSCancellation()
                }, originalLookup: gate.lookup)
        }
        defer { proxy.stop() }
        let seeded = XCTestExpectation(description: "cache filled")
        processor.process(query(10, name: "cached.qq.com")) { response in
            XCTAssertNotNil(response); seeded.fulfill()
        }
        wait(for: [domestic, seeded], timeout: 2)
        let client = try TCPTestClient(port: proxy.port)
        let first = query(11), cached = query(12, name: "cached.qq.com")
        try client.send([first, cached])
        wait(for: [slow], timeout: 2)

        let response = try client.readMessage()
        let question = try XCTUnwrap(DNSWire.question(cached))
        XCTAssertTrue(DNSWire.matchesResponse(response, query: question))
        XCTAssertEqual(DNSWire.aAnswer(response, for: question)?.addresses, [0x65060f82])
        XCTAssertEqual(processor.activitySnapshot.active, 1)
        gate.complete(11)
        XCTAssertEqual(try client.readMessage(), tcpResponse(for: first))
    }

    func testFullConnectionWindowBackpressuresBufferedQueriesUntilRepliesAreSent() throws {
        let firstWindow = XCTestExpectation(description: "first eight admitted"); firstWindow.expectedFulfillmentCount = 8
        let nextWindow = XCTestExpectation(description: "buffered queries later admitted"); nextWindow.expectedFulfillmentCount = 4
        let gate = TCPOriginalGate(onStart: { id in
            if id < 8 { firstWindow.fulfill() } else { nextWindow.fulfill() }
        })
        let (processor, proxy) = try startDNSProxy { try makeProcessor(gate) }
        defer { proxy.stop() }
        let client = try TCPTestClient(port: proxy.port)
        let queries = (0..<12).map { query(UInt16($0)) }
        try client.send(queries)
        try client.halfClose()
        wait(for: [firstWindow], timeout: 2)
        XCTAssertEqual(gate.startedCount, 8)
        XCTAssertEqual(processor.activitySnapshot.active, 8)

        for id in 0..<8 { gate.complete(UInt16(id)) }
        wait(for: [nextWindow], timeout: 2)
        for id in 8..<12 { gate.complete(UInt16(id)) }
        var expected = expectedResponses(queries)
        for _ in queries {
            let response = try client.readMessage()
            let id = try XCTUnwrap(DNSWire.read16([UInt8](response), 0))
            XCTAssertEqual(response, expected.removeValue(forKey: id), "Buffered queries must not become capacity failures")
        }
        XCTAssertTrue(expected.isEmpty)
        XCTAssertEqual(gate.startedCount, 12)
        XCTAssertLessThanOrEqual(gate.peakPendingCount, 8)
        try client.expectEOF()
    }

    func testOptimizationLimitKeepsOriginalSlotsAndStopCancelsAllOutstandingWork() throws {
        let domesticStarted = XCTestExpectation(description: "six domestic requests"); domesticStarted.expectedFulfillmentCount = 6
        let domesticCancelled = XCTestExpectation(description: "six domestic cancellations"); domesticCancelled.expectedFulfillmentCount = 6
        let originalStarted = XCTestExpectation(description: "two reserved original requests"); originalStarted.expectedFulfillmentCount = 2
        let originalCancelled = XCTestExpectation(description: "two original cancellations"); originalCancelled.expectedFulfillmentCount = 2
        domesticCancelled.assertForOverFulfill = true; originalCancelled.assertForOverFulfill = true
        let gate = TCPOriginalGate(onStart: { _ in originalStarted.fulfill() }, onCancel: { _ in originalCancelled.fulfill() })
        let (processor, proxy) = try startDNSProxy {
            try DNSProcessor(directCIDRs: ["223.5.5.0/24"], directDomains: ["qq.com"],
                domesticLookup: { _, _, _ in
                    domesticStarted.fulfill()
                    return DNSCancellation { domesticCancelled.fulfill() }
                }, originalLookup: gate.lookup)
        }
        defer { proxy.stop() }
        let client = try TCPTestClient(port: proxy.port)
        let optimization = (0..<8).map { query(UInt16($0), name: "n\($0).qq.com") }
        try client.send(optimization + [query(8), query(9)])
        wait(for: [domesticStarted, originalStarted], timeout: 2)
        XCTAssertEqual(processor.activitySnapshot.active, 8)
        XCTAssertEqual(processor.activitySnapshot.optimization, 6)
        var rejected: Set<UInt16> = [6, 7]
        for _ in 0..<2 {
            let response = try client.readMessage()
            let id = try XCTUnwrap(DNSWire.read16([UInt8](response), 0))
            XCTAssertNotNil(rejected.remove(id))
            XCTAssertEqual(DNSWire.read16([UInt8](response), 2)! & 15, 2)
        }
        proxy.stop(); proxy.stop()
        wait(for: [domesticCancelled, originalCancelled], timeout: 2)
        XCTAssertEqual(processor.activitySnapshot.active, 0)
    }

    func testResetCancelsEveryOutstandingQuery() throws {
        let started = XCTestExpectation(description: "eight original queries"); started.expectedFulfillmentCount = 8
        let cancelled = XCTestExpectation(description: "eight cancellations"); cancelled.expectedFulfillmentCount = 8
        cancelled.assertForOverFulfill = true
        let gate = TCPOriginalGate(onStart: { _ in started.fulfill() }, onCancel: { _ in cancelled.fulfill() })
        let (processor, proxy) = try startDNSProxy { try makeProcessor(gate) }
        defer { proxy.stop() }
        let client = try TCPTestClient(port: proxy.port)
        // Include an extra complete frame waiting behind the full window.
        try client.send((0..<9).map { query(UInt16($0)) })
        wait(for: [started], timeout: 2)
        try client.reset()
        wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(processor.activitySnapshot.active, 0)
        XCTAssertEqual(gate.startedCount, 8)
    }

    func testConcurrentLargeResponsesKeepCompleteFramesAndTransactionIDs() throws {
        let started = XCTestExpectation(description: "eight large responses pending"); started.expectedFulfillmentCount = 8
        let gate = TCPOriginalGate(onStart: { _ in started.fulfill() })
        let (_, proxy) = try startDNSProxy { try makeProcessor(gate) }
        defer { proxy.stop() }
        let client = try TCPTestClient(port: proxy.port)
        let queries = (100..<108).map { query(UInt16($0)) }
        try client.send(queries)
        try client.halfClose()
        wait(for: [started], timeout: 2)
        let expected = Dictionary(uniqueKeysWithValues: queries.map { packet in
            let question = DNSWire.question(packet)!
            let response = DNSWire.response(to: question, addresses: Array(repeating: UInt32(question.id), count: 4_000), ttl: 30)
            return (question.id, response)
        })
        DispatchQueue.concurrentPerform(iterations: queries.count) { index in
            let id = UInt16(107 - index)
            gate.complete(id, response: expected[id])
        }
        var remaining = expected
        for _ in queries {
            let response = try client.readMessage()
            let id = try XCTUnwrap(DNSWire.read16([UInt8](response), 0))
            XCTAssertEqual(response, remaining.removeValue(forKey: id))
        }
        XCTAssertTrue(remaining.isEmpty)
        try client.expectEOF()
    }

    private func makeProcessor(_ gate: TCPOriginalGate) throws -> DNSProcessor {
        try DNSProcessor(directCIDRs: [], directDomains: [],
            domesticLookup: { _, _, _ in XCTFail("Unexpected domestic lookup"); return DNSCancellation() },
            originalLookup: gate.lookup)
    }
    private func query(_ id: UInt16, name: String? = nil) -> Data {
        var packet = makeQuery(name ?? "q\(id).example.com")
        packet[0] = UInt8(id >> 8); packet[1] = UInt8(id & 255)
        return packet
    }
    private func expectedResponses(_ queries: [Data]) -> [UInt16: Data] {
        Dictionary(uniqueKeysWithValues: queries.map { (DNSWire.question($0)!.id, tcpResponse(for: $0)) })
    }
}

private final class TCPOriginalGate {
    private struct Pending { let packet: Data; let completion: (Data?) -> Void }
    private let lock = NSLock()
    private let onStart: (UInt16) -> Void
    private let onCancel: (UInt16) -> Void
    private var pending: [UInt16: Pending] = [:]
    private var starts = 0, peak = 0
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var peakPendingCount: Int { lock.lock(); defer { lock.unlock() }; return peak }
    init(onStart: @escaping (UInt16) -> Void, onCancel: @escaping (UInt16) -> Void = { _ in }) {
        self.onStart = onStart; self.onCancel = onCancel
    }
    func lookup(_ packet: Data, _ transport: DNSClientTransport, _ timeout: TimeInterval,
                _ completion: @escaping (Data?) -> Void) -> DNSCancellation {
        XCTAssertEqual(transport, .tcp)
        let id = DNSWire.question(packet)!.id
        lock.lock()
        pending[id] = Pending(packet: packet, completion: completion)
        starts += 1; peak = max(peak, pending.count)
        lock.unlock()
        onStart(id)
        return DNSCancellation { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.pending.removeValue(forKey: id); self.lock.unlock()
            self.onCancel(id)
        }
    }
    func complete(_ id: UInt16, response: Data? = nil) {
        lock.lock(); let request = pending.removeValue(forKey: id); lock.unlock()
        guard let request else { XCTFail("Missing pending request \(id)"); return }
        request.completion(response ?? tcpResponse(for: request.packet))
    }
}

private final class TCPTestClient {
    private var fd: Int32
    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TCPPipelineError.operation("socket", errno) }
        var noSignal: Int32 = 1, timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            let code = errno; Darwin.close(fd); fd = -1; throw TCPPipelineError.operation("setsockopt", code)
        }
        var address = tcpLoopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { let code = errno; Darwin.close(fd); fd = -1; throw TCPPipelineError.operation("connect", code) }
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
    func send(_ queries: [Data]) throws {
        var bytes = Data()
        for query in queries { bytes.appendUInt16(UInt16(query.count)); bytes.append(query) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TCPPipelineError.operation("send", errno) }
                offset += count
            }
        }
    }
    func halfClose() throws {
        guard shutdown(fd, SHUT_WR) == 0 else { throw TCPPipelineError.operation("shutdown", errno) }
    }
    func reset() throws {
        var reset = linger(l_onoff: 1, l_linger: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)) == 0 else {
            throw TCPPipelineError.operation("linger", errno)
        }
        Darwin.close(fd); fd = -1
    }
    func readMessage() throws -> Data {
        let prefix = try readExactly(2)
        let length = Int(DNSWire.read16([UInt8](prefix), 0)!)
        guard length >= 12 else { throw TCPPipelineError.invalidFrame }
        return try readExactly(length)
    }
    func hasReadableData(timeout: Int32) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeout)
        guard result >= 0 else { throw TCPPipelineError.operation("poll", errno) }
        return result > 0
    }
    func expectEOF(file: StaticString = #filePath, line: UInt = #line) throws {
        var byte: UInt8 = 0
        XCTAssertEqual(recv(fd, &byte, 1, 0), 0, file: file, line: line)
    }
    private func readExactly(_ length: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < length {
                let count = recv(fd, buffer.baseAddress!.advanced(by: offset), length - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TCPPipelineError.operation("recv", errno) }
                offset += count
            }
        }
        return Data(bytes)
    }
}

private func tcpLoopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}
private func tcpResponse(for packet: Data) -> Data {
    DNSWire.response(to: DNSWire.question(packet)!, addresses: [0xc0000201], ttl: 30)
}
private enum TCPPipelineError: Error { case operation(String, Int32), invalidFrame }
