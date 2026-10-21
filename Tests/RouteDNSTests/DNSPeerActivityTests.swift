import XCTest
@testable import RouteDNS

final class DNSPeerActivityTests: XCTestCase {
    func testUDPRemainsProtectedUntilEveryRequestAndSendCompletes() {
        var peer = DNSPeerActivity(isTCP: false)
        XCTAssertFalse(peer.canEvict) // Accepted connection still awaiting first datagram.
        peer.hasReceivedDatagram = true; peer.requests = 2
        XCTAssertFalse(peer.canEvict)
        peer.requests -= 1; peer.pendingSends += 1
        XCTAssertFalse(peer.canEvict)
        peer.pendingSends -= 1
        XCTAssertFalse(peer.canEvict) // Other same-port request is still running.
        peer.requests -= 1; peer.pendingSends += 1
        XCTAssertFalse(peer.canEvict) // Processing finished, but reply is not sent yet.
        peer.pendingSends -= 1
        XCTAssertTrue(peer.canEvict)
        peer.requests += 1 // Reusing the client socket immediately protects it again.
        XCTAssertFalse(peer.canEvict)
    }
    func testIdleTCPIsNeverEvictedForUDPPressure() {
        var peer = DNSPeerActivity(isTCP: true)
        peer.hasReceivedDatagram = true
        XCTAssertFalse(peer.canEvict)
    }
}
