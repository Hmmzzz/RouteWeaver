import XCTest
@testable import RouteCore

final class IPv4CIDRTests: XCTestCase {
    func testNormalizesHostBits() throws {
        let cidr = try IPv4CIDR("223.5.5.7/24")
        XCTAssertEqual(cidr.description, "223.5.5.0/24")
        XCTAssertEqual(cidr.network, 0xdf050500)
        XCTAssertEqual(cidr.lastAddress, 0xdf0505ff)
        XCTAssertTrue(cidr.contains("223.5.5.0"))
        XCTAssertTrue(cidr.contains("223.5.5.255"))
        XCTAssertFalse(cidr.contains("223.5.6.0"))
    }

    func testEntireAddressSpaceAndHostRoutes() throws {
        let all = try IPv4CIDR("128.1.2.3/0")
        XCTAssertEqual(all.description, "0.0.0.0/0")
        XCTAssertEqual(all.lastAddress, .max)
        XCTAssertTrue(all.contains("0.0.0.0"))
        XCTAssertTrue(all.contains("255.255.255.255"))
        let host = try IPv4CIDR("255.255.255.255/32")
        XCTAssertEqual(host.network, .max)
        XCTAssertEqual(host.lastAddress, .max)
        XCTAssertFalse(host.contains("255.255.255.254"))
    }

    func testRejectsMalformedAndAmbiguousInput() {
        for invalid in ["", "1.2.3.4", "::/0", "2001:db8::/32", "1.2.3/24",
                        "1.2.3.4.5/24", "256.1.1.1/24", "01.2.3.4/24",
                        "1.2.3.4/-1", "1.2.3.4/+24", "1.2.3.4/33", "1.2.3.4/",
                        "1.2.3.4/2x", "1.2.3.4/24/0", "1.2.3.4/24 ",
                        " 1.2.3.4/24", "1..3.4/24", "1.2.3.４/24"] {
            XCTAssertThrowsError(try IPv4CIDR(invalid), invalid)
        }
    }

    func testOverlapAndOrdering() throws {
        let small = try IPv4CIDR("1.2.3.0/24")
        let large = try IPv4CIDR("1.2.0.0/16")
        let separate = try IPv4CIDR("2.0.0.0/8")
        XCTAssertTrue(small.overlaps(large))
        XCTAssertTrue(large.overlaps(small))
        XCTAssertFalse(small.overlaps(separate))
        XCTAssertEqual([separate, small, large].sorted(), [large, small, separate])
    }

    func testSpecialUseProtection() throws {
        for unsafe in ["0.0.0.0/0", "128.0.0.0/1", "0.0.0.0/8", "10.0.0.0/8",
                       "100.64.0.0/10", "127.0.0.1/32", "169.254.1.2/32", "172.16.0.0/12",
                       "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
                       "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
                       "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
                       "100.0.0.0/8", "192.0.0.0/8"] {
            XCTAssertThrowsError(try IPv4CIDR(unsafe).validateForBypass(), unsafe)
        }
        for safe in ["1.0.0.0/8", "8.8.8.8/32", "114.114.114.0/24", "223.5.5.0/24"] {
            XCTAssertNoThrow(try IPv4CIDR(safe).validateForBypass(), safe)
        }
    }

    func testCodableValidatesUntrustedInput() throws {
        let original = try IPv4CIDR("223.5.5.9/24")
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(IPv4CIDR.self, from: encoded), original)
        XCTAssertThrowsError(try JSONDecoder().decode(IPv4CIDR.self, from: Data("\"1.2.3.4/33\"".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(IPv4CIDR.self, from: Data("{\"network\":0,\"prefix\":64}".utf8)))
    }

    func testAddressFormattingRoundTrip() {
        for address: UInt32 in [0, 1, 0x01020304, 0x7fffffff, 0xffffffff] {
            XCTAssertEqual(IPv4CIDR.parseAddress(IPv4CIDR.formatAddress(address)), address)
        }
    }
}
