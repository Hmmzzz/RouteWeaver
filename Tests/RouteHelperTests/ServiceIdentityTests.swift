import XCTest
import Darwin
import RouteIPC
@testable import RouteHelper

final class ServiceIdentityTests: XCTestCase {
    private func withConnection(_ body: (Int32) throws -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            XCTFail("socketpair failed: \(errno)")
            return
        }
        defer { descriptors.forEach { close($0) } }
        try body(descriptors[0])
    }
    func testKernelAuditTokenAcceptsOnlyPinnedCodeHashAndOwner() throws {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let hash = try ServiceIdentity.staticHash(path: executable)
        try withConnection { peer in
            let exact = ServiceConfiguration(ownerUID: getuid(), appCodeHash: hash, helperCodeHash: hash)
            XCTAssertNoThrow(try ServiceIdentity.authenticate(fd: peer, configuration: exact))
            let wrongHash = ServiceConfiguration(ownerUID: getuid(), appCodeHash: Data(repeating: 0, count: hash.count), helperCodeHash: hash)
            XCTAssertThrowsError(try ServiceIdentity.authenticate(fd: peer, configuration: wrongHash))
            let wrongOwner = ServiceConfiguration(ownerUID: getuid() + 1, appCodeHash: hash, helperCodeHash: hash)
            XCTAssertThrowsError(try ServiceIdentity.authenticate(fd: peer, configuration: wrongOwner))
        }
    }
}
