import Darwin
import XCTest
@testable import RouteDNS

final class DNSProxyTestFixtureTests: XCTestCase {
    func testReservationKeepsBothTransportsBoundUntilRelease() throws {
        let reservation = try reservePort()
        defer { reservation.release() }
        for type in [SOCK_STREAM, SOCK_DGRAM] {
            XCTAssertThrowsError(try DNSLoopbackSocket(type: type, port: reservation.port)) {
                XCTAssertTrue(isDNSAddressInUse($0))
            }
        }
        reservation.release()
        let reclaimed = try DNSLoopbackPortReservation(port: reservation.port)
        reclaimed.release()
    }

    func testUDPConflictDuringPortSelectionRetriesBeforeCreatingProcessor() throws {
        let occupied = try reservePort()
        occupied.tcp.close() // TCP is free, but UDP still exclusively owns this port.
        defer { occupied.release() }
        var probes = 0, processors = 0
        let (_, proxy) = try startDNSProxy(reservePort: {
            probes += 1
            return try DNSLoopbackPortReservation(port: probes == 1 ? occupied.port : 0)
        }, makeProcessor: {
            XCTAssertGreaterThan(probes, 1, "UDP conflicts must be found while selecting the port")
            processors += 1
            return try self.makeProcessor()
        })
        defer { proxy.stop() }
        XCTAssertGreaterThanOrEqual(probes, 2)
        XCTAssertGreaterThanOrEqual(processors, 1)
        XCTAssertNotEqual(proxy.port, occupied.port)
        try assertUDPResponse(port: proxy.port)
    }

    func testPortClaimedAfterProbeRetriesWithFreshProcessor() throws {
        var blocker: DNSLoopbackSocket?
        defer { blocker?.close() }
        var processors: [DNSProcessor] = []
        let (processor, proxy) = try startDNSProxy(beforeStart: { port in
            if blocker == nil { blocker = try DNSLoopbackSocket(type: SOCK_DGRAM, port: port) }
        }, makeProcessor: {
            let processor = try self.makeProcessor()
            processors.append(processor)
            return processor
        })
        defer { proxy.stop() }
        XCTAssertGreaterThanOrEqual(processors.count, 2)
        XCTAssertFalse(processors[0] === processor, "A failed start permanently stops its processor")
        XCTAssertNotEqual(proxy.port, blocker?.port)
        let stopped = XCTestExpectation(description: "failed attempt's processor is stopped")
        let query = makeQuery("fixture.example.com")
        processors[0].process(query) { response in
            XCTAssertEqual(response, DNSWire.failure(to: query)); stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
        try assertUDPResponse(port: proxy.port)
    }

    func testRepeatedPortClaimsStopAtAttemptLimit() throws {
        var blockers: [DNSLoopbackSocket] = []
        defer { blockers.forEach { $0.close() } }
        var processors = 0
        XCTAssertThrowsError(try startDNSProxy(maximumAttempts: 3,
            // Reserve retries only select the fixture's free candidate. Every
            // listener attempt below is deterministically made to collide.
            reservePort: { try self.reservePort() },
            beforeStart: { blockers.append(try DNSLoopbackSocket(type: SOCK_DGRAM, port: $0)) },
            makeProcessor: { processors += 1; return try self.makeProcessor() })) {
                XCTAssertTrue(isDNSAddressInUse($0))
        }
        XCTAssertEqual(processors, 3)
        XCTAssertEqual(blockers.count, 3)
    }

    func testOtherErrorsAndTimeoutsAreNotRetried() throws {
        let errors: [Error] = [DNSProxyFixtureError.socket("bind", EACCES),
                               DNSProxyError.listener("启动超时"), DNSProxyFixtureError.startupTimedOut]
        for error in errors {
            var attempts = 0
            XCTAssertThrowsError(try retryDNSAddressInUse {
                attempts += 1
                throw error
            })
            XCTAssertEqual(attempts, 1)
        }
    }

    private func reservePort() throws -> DNSLoopbackPortReservation {
        try retryDNSAddressInUse { try DNSLoopbackPortReservation() }
    }
    private func makeProcessor() throws -> DNSProcessor {
        try DNSProcessor(directCIDRs: [], directDomains: [],
            domesticLookup: { _, _, _ in XCTFail("Unexpected domestic lookup"); return DNSCancellation() },
            originalLookup: { query, _, _, completion in
                completion(DNSWire.response(to: DNSWire.question(query)!, addresses: [0xc0000201], ttl: 30))
                return DNSCancellation()
            })
    }
    private func assertUDPResponse(port: UInt16, file: StaticString = #filePath, line: UInt = #line) throws {
        let client = try DNSLoopbackSocket(type: SOCK_DGRAM)
        defer { client.close() }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(client.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw DNSProxyFixtureError.socket("setsockopt", errno)
        }
        var address = dnsLoopbackAddress(port: port)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client.descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw DNSProxyFixtureError.socket("connect", errno) }
        let query = makeQuery("fixture.example.com")
        let sent = query.withUnsafeBytes { Darwin.send(client.descriptor, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, query.count, file: file, line: line)
        var bytes = [UInt8](repeating: 0, count: 512)
        let received = recv(client.descriptor, &bytes, bytes.count, 0)
        guard received > 0 else { throw DNSProxyFixtureError.socket("recv", errno) }
        let expected = DNSWire.response(to: DNSWire.question(query)!, addresses: [0xc0000201], ttl: 30)
        XCTAssertEqual(Data(bytes.prefix(received)), expected, file: file, line: line)
    }
}
