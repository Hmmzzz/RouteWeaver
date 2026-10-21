import XCTest
import Darwin
@testable import RouteIPC

final class RouteIPCTests: XCTestCase {
    private func withPair(_ body: (Int32, Int32) throws -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { descriptors.forEach { close($0) } }
        try descriptors.forEach { try IPCWire.prepare($0) }
        try body(descriptors[0], descriptors[1])
    }
    func testFrameRoundTripAndUnicode() throws {
        try withPair { a, b in
            let payload = Data("安全状态 / 10.0.0.0/8".utf8)
            try IPCWire.writeFrame(payload, fd: a, until: IPCWire.deadline(after: 1))
            XCTAssertEqual(try IPCWire.readFrame(fd: b, until: IPCWire.deadline(after: 1)), payload)
        }
    }
    func testOversizedHeaderRejectedBeforeBody() throws {
        try withPair { a, b in
            var size = UInt32(IPCWire.maximumFrame + 1).bigEndian
            withUnsafeBytes(of: &size) { XCTAssertEqual(Darwin.write(a, $0.baseAddress!, 4), 4) }
            XCTAssertThrowsError(try IPCWire.readFrame(fd: b, until: IPCWire.deadline(after: 0.1)))
        }
    }
    func testZeroFrameRejected() throws {
        try withPair { a, b in
            var size: UInt32 = 0
            withUnsafeBytes(of: &size) { XCTAssertEqual(Darwin.write(a, $0.baseAddress!, 4), 4) }
            XCTAssertThrowsError(try IPCWire.readFrame(fd: b, until: IPCWire.deadline(after: 0.1)))
        }
    }
    func testTruncatedHeaderCannotHoldConnectionIndefinitely() throws {
        try withPair { a, b in
            var byte: UInt8 = 1
            XCTAssertEqual(Darwin.write(a, &byte, 1), 1)
            let started = Date()
            XCTAssertThrowsError(try IPCWire.readFrame(fd: b, until: IPCWire.deadline(after: 0.04)))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        }
    }
    func testTruncatedBodyUsesSameAbsoluteDeadline() throws {
        try withPair { a, b in
            var size = UInt32(100).bigEndian
            withUnsafeBytes(of: &size) { XCTAssertEqual(Darwin.write(a, $0.baseAddress!, 4), 4) }
            XCTAssertThrowsError(try IPCWire.readFrame(fd: b, until: IPCWire.deadline(after: 0.04)))
        }
    }
    func testUnsupportedAndSmuggledRequestsRejected() throws {
        var request = ServiceRequest(command: .status)
        request.version = 999
        XCTAssertThrowsError(try request.validate())
        XCTAssertThrowsError(try ServiceRequest(command: .status, routes: ["1.1.1.1/32"]).validate())
        XCTAssertThrowsError(try ServiceRequest(command: .stop, routes: []).validate())
        XCTAssertThrowsError(try ServiceRequest(command: .attach, routes: []).validate())
        XCTAssertNoThrow(try ServiceRequest(command: .attach).validate())
        XCTAssertThrowsError(try ServiceRequest(command: .stopOwned, routes: []).validate())
        XCTAssertNoThrow(try ServiceRequest(command: .stopOwned).validate())
        XCTAssertThrowsError(try ServiceRequest(command: .apply, routes: []).validate())
        XCTAssertThrowsError(try ServiceRequest(command: .apply, routes: Array(repeating: "1.1.1.1/32", count: 20_001)).validate())
        XCTAssertThrowsError(try ServiceRequest(command: .apply, routes: [String(repeating: "a", count: 19)]).validate())
        XCTAssertNoThrow(try ServiceRequest(command: .apply, routes: ["1.1.1.1/32"]).validate())
    }
    func testClientRejectsOrdinaryFileBeforeConnecting() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try RouteIPCClient.send(ServiceRequest(command: .status), socketPath: path))
    }
    func testSocketAddressRejectsNULAndTruncation() {
        XCTAssertThrowsError(try IPCWire.address("/tmp/abc\0def"))
        XCTAssertThrowsError(try IPCWire.address("/tmp/" + String(repeating: "x", count: 120)))
    }
}
