import Darwin
import Foundation
import Network
@testable import RouteDNS

/// The proxy needs the same loopback port for both transports. Keep both probe
/// sockets bound until startup, then retry only the unavoidable handoff race.
/// A failed proxy stops its processor, so every listener attempt needs a new one.
func startDNSProxy(
    maximumAttempts: Int = 5,
    reservePort: () throws -> DNSLoopbackPortReservation = { try DNSLoopbackPortReservation() },
    beforeStart: (UInt16) throws -> Void = { _ in },
    makeProcessor: () throws -> DNSProcessor
) throws -> (processor: DNSProcessor, proxy: ScopedDNSProxy) {
    try retryDNSAddressInUse(maximumAttempts: maximumAttempts) {
        let reservation = try reservePort()
        defer { reservation.release() }
        let processor = try makeProcessor()
        let proxy: ScopedDNSProxy
        do { proxy = try ScopedDNSProxy(port: reservation.port, processor: processor) }
        catch { processor.stop(); throw error }
        reservation.release()
        do {
            // Tests can deterministically occupy the port after the probe closes.
            try beforeStart(proxy.port)
            try waitForDNSProxyStartup(proxy)
            return (processor, proxy)
        } catch {
            proxy.stop()
            throw error
        }
    }
}

func retryDNSAddressInUse<Value>(maximumAttempts: Int = 5, _ operation: () throws -> Value) throws -> Value {
    precondition(maximumAttempts > 0)
    var attempt = 0
    while true {
        attempt += 1
        do { return try operation() }
        catch {
            guard isDNSAddressInUse(error), attempt < maximumAttempts else { throw error }
        }
    }
}

private func waitForDNSProxyStartup(_ proxy: ScopedDNSProxy) throws {
    let ready = DispatchSemaphore(value: 0), lock = NSLock()
    var result: Result<Void, Error>?
    proxy.start { value in
        lock.lock(); result = value; lock.unlock()
        ready.signal()
    }
    guard ready.wait(timeout: .now() + 4) == .success else { throw DNSProxyFixtureError.startupTimedOut }
    lock.lock(); defer { lock.unlock() }
    // A completion that never arrives is an error, never a successful startup.
    guard let result else { throw DNSProxyFixtureError.startupTimedOut }
    try result.get()
}

func isDNSAddressInUse(_ error: Error) -> Bool {
    if let error = error as? DNSProxyFixtureError, case .socket(_, let code) = error {
        return code == EADDRINUSE
    }
    if let error = error as? NWError, case .posix(.EADDRINUSE) = error { return true }
    let error = error as NSError
    return error.domain == NSPOSIXErrorDomain && error.code == Int(EADDRINUSE)
}

final class DNSLoopbackPortReservation {
    let tcp: DNSLoopbackSocket
    let udp: DNSLoopbackSocket
    var port: UInt16 { tcp.port }

    init(port: UInt16 = 0) throws {
        tcp = try DNSLoopbackSocket(type: SOCK_STREAM, port: port)
        udp = try DNSLoopbackSocket(type: SOCK_DGRAM, port: tcp.port)
    }
    func release() { tcp.close(); udp.close() }
}

/// No address reuse: a successful probe proves exclusive ownership of this
/// transport's loopback endpoint until close(), including in regression tests.
final class DNSLoopbackSocket {
    private(set) var descriptor: Int32
    let port: UInt16

    init(type: Int32, port: UInt16 = 0) throws {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw DNSProxyFixtureError.socket("socket", errno) }
        var address = dnsLoopbackAddress(port: port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno; Darwin.close(fd); throw DNSProxyFixtureError.socket("bind", code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else {
            let code = errno; Darwin.close(fd); throw DNSProxyFixtureError.socket("getsockname", code)
        }
        descriptor = fd; self.port = UInt16(bigEndian: address.sin_port)
    }
    deinit { close() }
    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
}

func dnsLoopbackAddress(port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

enum DNSProxyFixtureError: Error {
    case socket(String, Int32)
    case startupTimedOut
}
