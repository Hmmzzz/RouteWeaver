import Darwin
import Network
import XCTest
@testable import RouteDNS

/// Hold transport completions while using real loopback clients. No system DNS
/// settings or external upstreams are used by these pressure tests.
final class DNSUDPBackpressureTests: XCTestCase {
    func testSlowPeerIsBoundedOtherPeerProgressesAndSendCompletionRestoresCapacity() throws {
        let firstWindow = XCTestExpectation(description: "eight replies awaiting send")
        firstWindow.expectedFulfillmentCount = 8
        let premature = XCTestExpectation(description: "ninth reply must wait for send capacity")
        premature.isInverted = true
        let nextWindow = XCTestExpectation(description: "four buffered queries resume")
        nextWindow.expectedFulfillmentCount = 4
        let gate = UDPReplyGate(first: firstWindow, premature: premature, next: nextWindow)
        let (_, proxy) = try startDNSProxy(sendUDP: gate.send) { try self.makeProcessor() }
        defer { proxy.stop() }
        let slow = try UDPTestClient(port: proxy.port), other = try UDPTestClient(port: proxy.port)
        for id in 0..<12 { try slow.send(query(UInt16(id))) }
        wait(for: [firstWindow], timeout: 2)
        try other.send(query(100))
        XCTAssertEqual(try other.receive(), reply(query(100)), "Another peer must progress while one sender is full")
        wait(for: [premature], timeout: 0.15)
        XCTAssertEqual(gate.heldCount, 8)

        gate.allowNextWindow()
        for id in 0..<4 { gate.release(UInt16(id)) }
        wait(for: [nextWindow], timeout: 2)
        XCTAssertEqual(gate.heldCount, 8)
        XCTAssertLessThanOrEqual(gate.peakHeldCount, 8)
        for id in 4..<12 { gate.release(UInt16(id)) }
        var ids = Set(0..<12)
        for _ in 0..<12 {
            let packet = try slow.receive()
            let id = Int(try XCTUnwrap(DNSWire.read16([UInt8](packet), 0)))
            XCTAssertNotNil(ids.remove(id))
            XCTAssertEqual(packet, reply(query(UInt16(id))))
        }
        XCTAssertTrue(ids.isEmpty)
        gate.passThrough()
        try slow.send(query(12))
        XCTAssertEqual(try slow.receive(), reply(query(12)), "A drained connection must remain reusable")
    }

    func testLateSendCompletionsAfterStopAreHarmless() throws {
        let full = XCTestExpectation(description: "eight outstanding sends"); full.expectedFulfillmentCount = 8
        let unused = XCTestExpectation(description: "no second window"); unused.isInverted = true
        let gate = UDPReplyGate(first: full, premature: unused, next: unused)
        let (processor, proxy) = try startDNSProxy(sendUDP: gate.send) { try self.makeProcessor() }
        defer { proxy.stop() }
        let client = try UDPTestClient(port: proxy.port)
        for id in 0..<8 { try client.send(query(UInt16(id))) }
        wait(for: [full], timeout: 2)
        proxy.stop()
        gate.failAll()
        proxy.stop() // Also drains any late callbacks queued by the fake sender.
        XCTAssertEqual(processor.activitySnapshot.active, 0)
        XCTAssertEqual(gate.heldCount, 0)
    }

    func testMalformedBurstBeyondWindowCannotStallLaterValidQuery() throws {
        let (_, proxy) = try startDNSProxy { try self.makeProcessor() }
        defer { proxy.stop() }
        let client = try UDPTestClient(port: proxy.port)
        for id in 0..<12 {
            var nonQuery = query(UInt16(id)); nonQuery[2] |= 0x80
            try client.send(nonQuery) // Dropped before processor admission.
            try client.send(Data(query(UInt16(id)).dropLast())) // Forwarded as an opaque query.
        }
        try client.send(query(100))
        var ids = Set((0..<12).map(UInt16.init) + [100])
        for _ in 0..<13 {
            let packet = try client.receive()
            let id = try XCTUnwrap(DNSWire.read16([UInt8](packet), 0))
            XCTAssertNotNil(ids.remove(id))
            if id == 100 { XCTAssertEqual(packet, reply(query(100))) }
            else { XCTAssertEqual(DNSWire.read16([UInt8](packet), 2)! & 15, 3) }
        }
        XCTAssertTrue(ids.isEmpty)
    }

    private func makeProcessor() throws -> DNSProcessor {
        try DNSProcessor(directCIDRs: [], directDomains: [], domestic: { _, _ in XCTFail("Unexpected domestic lookup") },
            original: { packet, transport, completion in
                XCTAssertEqual(transport, .udp); completion(self.reply(packet))
            })
    }
    private func query(_ id: UInt16) -> Data {
        var packet = makeQuery("q\(id).example.com")
        packet[0] = UInt8(id >> 8); packet[1] = UInt8(id & 255)
        return packet
    }
    private func reply(_ packet: Data) -> Data {
        guard let question = DNSWire.question(packet) else { return DNSWire.failure(to: packet, rcode: 3) }
        return DNSWire.response(to: question, addresses: [0xc0000201], ttl: 30)
    }
}

private final class UDPReplyGate {
    private struct Pending {
        let connection: NWConnection
        let packet: Data
        let completion: (NWError?) -> Void
    }
    private let lock = NSLock()
    private var pending: [UInt16: Pending] = [:]
    private var releaseAllowed = false, passing = false, peak = 0
    private let first: XCTestExpectation, premature: XCTestExpectation, next: XCTestExpectation
    init(first: XCTestExpectation, premature: XCTestExpectation, next: XCTestExpectation) {
        self.first = first; self.premature = premature; self.next = next
    }
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    var peakHeldCount: Int { lock.lock(); defer { lock.unlock() }; return peak }
    func send(_ connection: NWConnection, _ packet: Data, completion: @escaping (NWError?) -> Void) {
        let id = DNSWire.read16([UInt8](packet), 0)!
        lock.lock()
        if passing || id >= 100 {
            lock.unlock(); ScopedDNSProxy.sendDatagram(connection, packet, completion: completion); return
        }
        pending[id] = Pending(connection: connection, packet: packet, completion: completion)
        peak = max(peak, pending.count)
        let allowed = releaseAllowed
        lock.unlock()
        if id < 8 { first.fulfill() }
        else if allowed { next.fulfill() }
        else { premature.fulfill() }
    }
    func allowNextWindow() { lock.lock(); releaseAllowed = true; lock.unlock() }
    func passThrough() { lock.lock(); passing = true; lock.unlock() }
    func release(_ id: UInt16) {
        lock.lock(); let item = pending.removeValue(forKey: id); lock.unlock()
        guard let item else { return XCTFail("Missing UDP reply \(id)") }
        ScopedDNSProxy.sendDatagram(item.connection, item.packet, completion: item.completion)
    }
    func failAll() {
        lock.lock(); let items = Array(pending.values); pending.removeAll(); lock.unlock()
        items.forEach { $0.completion(.posix(.ECANCELED)) }
    }
}

private final class UDPTestClient {
    private let socket: DNSLoopbackSocket
    init(port: UInt16) throws {
        socket = try DNSLoopbackSocket(type: SOCK_DGRAM)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(socket.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw DNSProxyFixtureError.socket("setsockopt", errno)
        }
        var address = dnsLoopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket.descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw DNSProxyFixtureError.socket("connect", errno) }
    }
    func send(_ packet: Data) throws {
        let count = packet.withUnsafeBytes { Darwin.send(socket.descriptor, $0.baseAddress, $0.count, 0) }
        guard count == packet.count else { throw DNSProxyFixtureError.socket("send", errno) }
    }
    func receive() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65_535)
        let count = recv(socket.descriptor, &bytes, bytes.count, 0)
        guard count > 0 else { throw DNSProxyFixtureError.socket("recv", errno) }
        return Data(bytes.prefix(count))
    }
}
