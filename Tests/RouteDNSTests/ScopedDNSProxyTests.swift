import Darwin
import XCTest
@testable import RouteDNS

/// Real loopback sockets exercise disconnects and framing without publishing a
/// resolver or changing any system network setting.
final class ScopedDNSProxyTests: XCTestCase {
    func testTCPResetCancelsOutstandingOriginalLookup() throws {
        let started = expectation(description: "lookup started")
        let cancelled = expectation(description: "reset cancels upstream")
        cancelled.assertForOverFulfill = true
        let processor = try DNSProcessor(directCIDRs: [], directDomains: [],
            domesticLookup: { _, _, _ in XCTFail("unexpected domestic lookup"); return DNSCancellation() },
            originalLookup: { _, _, _, _ in
                started.fulfill()
                return DNSCancellation { cancelled.fulfill() }
            })
        let proxy = try startProxy(processor); defer { proxy.stop() }
        let fd = try connectTCP(proxy.port)
        try sendAll(frame(makeQuery("www.example.com")), fd: fd)
        wait(for: [started], timeout: 2)
        var reset = linger(l_onoff: 1, l_linger: 0)
        XCTAssertEqual(setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, socklen_t(MemoryLayout<linger>.size)), 0)
        Darwin.close(fd)
        wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(processor.activitySnapshot.active, 0)
    }

    func testTCPHalfClosePreservesDelayedPipelinedResponses() throws {
        let processor = try DNSProcessor(directCIDRs: [], directDomains: [],
            domesticLookup: { _, _, _ in XCTFail("unexpected domestic lookup"); return DNSCancellation() },
            originalLookup: { data, transport, _, completion in
                XCTAssertEqual(transport, .tcp)
                let response = DNSWire.response(to: DNSWire.question(data)!, addresses: [0xc0000201], ttl: 30)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { completion(response) }
                return DNSCancellation()
            })
        let proxy = try startProxy(processor); defer { proxy.stop() }
        let fd = try connectTCP(proxy.port); defer { Darwin.close(fd) }
        let first = makeQuery("first.example.com")
        var second = makeQuery("second.example.com"); second[1] ^= 1
        let firstFrame = frame(first)
        try sendAll(firstFrame.prefix(1), fd: fd)
        try sendAll(firstFrame.dropFirst() + frame(second), fd: fd)
        XCTAssertEqual(shutdown(fd, SHUT_WR), 0)
        var expected = Dictionary(uniqueKeysWithValues: [first, second].map { query in
            let question = DNSWire.question(query)!
            return (question.id, DNSWire.response(to: question, addresses: [0xc0000201], ttl: 30))
        })
        for _ in 0..<2 {
            let length = try readExactly(2, fd: fd)
            let response = try readExactly(Int(DNSWire.read16([UInt8](length), 0)!), fd: fd)
            let id = try XCTUnwrap(DNSWire.read16([UInt8](response), 0))
            XCTAssertEqual(response, expected.removeValue(forKey: id))
        }
        XCTAssertTrue(expected.isEmpty)
        var byte: UInt8 = 0
        XCTAssertEqual(recv(fd, &byte, 1, 0), 0)
    }

    func testProxyStopCancelsOutstandingDomesticWork() throws {
        let started = expectation(description: "domestic lookup started")
        let cancelled = expectation(description: "stop cancels upstream")
        cancelled.assertForOverFulfill = true
        let processor = try DNSProcessor(directCIDRs: ["223.5.5.0/24"], directDomains: ["example.com"],
            domesticLookup: { _, _, _ in
                started.fulfill(); return DNSCancellation { cancelled.fulfill() }
            }, originalLookup: { _, _, _, _ in XCTFail("unexpected fallback"); return DNSCancellation() })
        let proxy = try startProxy(processor)
        let fd = try connectTCP(proxy.port); defer { Darwin.close(fd); proxy.stop() }
        try sendAll(frame(makeQuery("www.example.com")), fd: fd)
        wait(for: [started], timeout: 2)
        proxy.stop(); proxy.stop()
        wait(for: [cancelled], timeout: 2)
        XCTAssertEqual(processor.activitySnapshot.active, 0)
    }

    private func startProxy(_ processor: DNSProcessor) throws -> ScopedDNSProxy {
        // Ask the kernel for a free TCP port, then let the proxy bind TCP + UDP.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.operation(errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw SocketError.operation(errno) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        Darwin.close(fd)
        guard nameResult == 0 else { throw SocketError.operation(errno) }
        let proxy = try ScopedDNSProxy(port: UInt16(bigEndian: address.sin_port), processor: processor)
        let ready = expectation(description: "proxy ready")
        var failure: Error?
        proxy.start { result in if case .failure(let error) = result { failure = error }; ready.fulfill() }
        wait(for: [ready], timeout: 4)
        if let failure { proxy.stop(); throw failure }
        return proxy
    }

    private func connectTCP(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.operation(errno) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw SocketError.operation(errno) }
        return fd
    }
    private func frame(_ data: Data) -> Data {
        var output = Data(); output.appendUInt16(UInt16(data.count)); output.append(data); return output
    }
    private func sendAll(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw SocketError.operation(errno) }; offset += count
            }
        }
    }
    private func readExactly(_ length: Int, fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length), offset = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while offset < length {
                let count = recv(fd, buffer.baseAddress!.advanced(by: offset), length - offset, 0)
                guard count > 0 else { throw SocketError.operation(errno) }; offset += count
            }
        }
        return Data(bytes)
    }
    private enum SocketError: Error { case operation(Int32) }
}
