import XCTest
@testable import RouteCore

final class PolicyCompilerTests: XCTestCase {
    func testCoalescesDuplicatesOverlapsAndAdjacentNetworks() throws {
        let result = try PolicyCompiler.compile(
            countryCIDRs: ["1.2.0.0/25", "1.2.0.128/25", "1.2.0.0/24", "1.2.1.0/24"],
            rules: [.init(cidr: "1.2.0.1/32", action: .direct)], excludedAddresses: [])
        XCTAssertEqual(result.map(\.description), ["1.2.0.0/23"])
    }

    func testExitNodeExceptionAlwaysWinsIndependentOfOrder() throws {
        let rules: [RouteRule] = [
            .init(cidr: "1.2.0.0/24", action: .exitNode),
            .init(cidr: "1.2.0.1/32", action: .direct)
        ]
        let country = ["1.2.0.0/23"]
        let result = try PolicyCompiler.compile(countryCIDRs: country, rules: rules, excludedAddresses: [])
        XCTAssertEqual(result.map(\.description), ["1.2.1.0/24"])
        XCTAssertEqual(result, try PolicyCompiler.compile(countryCIDRs: country, rules: rules.reversed(), excludedAddresses: []))
    }

    func testBroadExitNodeExclusionIsSafeAndCreatesNoRoute() throws {
        let result = try PolicyCompiler.compile(countryCIDRs: ["223.5.5.0/24"],
            rules: [.init(cidr: "0.0.0.0/0", action: .exitNode)], excludedAddresses: [])
        XCTAssertEqual(result, [])
    }

    func testRemovesSingleProbeAndGatewayWithoutLosingNeighbors() throws {
        let result = try PolicyCompiler.compile(countryCIDRs: ["1.2.3.0/29"], rules: [],
                                               excludedAddresses: ["1.2.3.3", "1.2.3.7", "192.168.1.1"])
        XCTAssertEqual(result.map(\.description), ["1.2.3.0/31", "1.2.3.2/32", "1.2.3.4/31", "1.2.3.6/32"])
        XCTAssertFalse(result.contains(where: { $0.contains("1.2.3.3") }))
        XCTAssertFalse(result.contains(where: { $0.contains("1.2.3.7") }))
    }

    func testDisabledRulesDoNotChangePolicy() throws {
        let result = try PolicyCompiler.compile(countryCIDRs: ["1.2.3.0/24"], rules: [
            .init(cidr: "1.2.3.0/24", action: .exitNode, enabled: false),
            .init(cidr: "8.8.8.0/24", action: .direct, enabled: false)
        ], excludedAddresses: [])
        XCTAssertEqual(result.map(\.description), ["1.2.3.0/24"])
    }

    func testRejectsInvalidAndUnsafeInputs() {
        XCTAssertThrowsError(try PolicyCompiler.compile(countryCIDRs: ["10.0.0.0/8"], rules: [], excludedAddresses: []))
        XCTAssertThrowsError(try PolicyCompiler.compile(countryCIDRs: [], rules: [.init(cidr: "100.64.0.0/10", action: .direct)], excludedAddresses: []))
        XCTAssertThrowsError(try PolicyCompiler.compile(countryCIDRs: [], rules: [.init(cidr: "::/0", action: .exitNode)], excludedAddresses: []))
        XCTAssertThrowsError(try PolicyCompiler.compile(countryCIDRs: [], rules: [], excludedAddresses: ["bad"]))
        XCTAssertThrowsError(try PolicyCompiler.compile(countryCIDRs: [], rules: [.init(cidr: "invalid", action: .direct, enabled: false)], excludedAddresses: []))
    }

    func testEmptyPolicy() throws {
        XCTAssertEqual(try PolicyCompiler.compile(countryCIDRs: [], rules: [], excludedAddresses: []), [])
    }

    func testCountLimitAfterCompilation() {
        let routes = (0...20_000).map { value in
            let address = UInt32(0x01000000 + value * 2)
            return "\(IPv4CIDR.formatAddress(address))/32"
        }
        XCTAssertThrowsError(try PolicyCompiler.compile(countryCIDRs: routes, rules: [], excludedAddresses: [])) { error in
            guard case RouteCoreError.tooManyRoutes = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCountLimitAppliesToCompiledNotRawRoutes() throws {
        let result = try PolicyCompiler.compile(countryCIDRs: Array(repeating: "223.5.5.0/24", count: 20_001),
                                                rules: [], excludedAddresses: [])
        XCTAssertEqual(result.map(\.description), ["223.5.5.0/24"])
    }

    func testSubtractionMatchesNaiveOracleOverDeterministicCases() throws {
        // Exercise interval boundaries, multiple spanning exclusions, and touching intervals.
        for seed in 0..<40 {
            var intended = Set<UInt32>()
            var country: [String] = []
            var rules: [RouteRule] = []
            for index in 0..<16 {
                let prefix = 28 + ((seed + index) % 5)
                let address = UInt32(0x01020300 + ((seed * 17 + index * 31) % 256))
                let cidr = IPv4CIDR(network: address, prefix: prefix)
                country.append(cidr.description)
                for value in cidr.network...cidr.lastAddress { intended.insert(value) }
            }
            for index in 0..<8 {
                let address = UInt32(0x01020300 + ((seed * 11 + index * 23) % 256))
                let cidr = IPv4CIDR(network: address, prefix: 29 + index % 4)
                rules.append(.init(cidr: cidr.description, action: .exitNode))
                for value in cidr.network...cidr.lastAddress { intended.remove(value) }
            }
            let compiled = try PolicyCompiler.compile(countryCIDRs: country, rules: rules, excludedAddresses: [])
            for address in UInt32(0x01020300)...UInt32(0x010203ff) {
                XCTAssertEqual(compiled.contains(where: { $0.contains(address) }), intended.contains(address), "seed \(seed), address \(address)")
            }
            for (left, right) in zip(compiled, compiled.dropFirst()) {
                XCTAssertLessThan(left.lastAddress, right.network)
            }
        }
    }

    func testTenThousandRoutesAndExclusionsPerformance() throws {
        let routes = (0..<10_000).map { value in
            "\(IPv4CIDR.formatAddress(UInt32(0x01000000 + value * 512)))/24"
        }
        let rules = stride(from: 0, to: 10_000, by: 4).map { value in
            RouteRule(cidr: routes[value], action: .exitNode)
        }
        let start = Date()
        let result = try PolicyCompiler.compile(countryCIDRs: routes, rules: rules, excludedAddresses: [])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.count, 7_500)
        // Loose regression budget, not a claim about kernel installation performance.
        XCTAssertLessThan(elapsed, 5.0)
        print("RouteCore benchmark: 10,000 networks + 2,500 exclusions -> \(result.count) routes in \(String(format: "%.2f", elapsed * 1_000)) ms (debug)")
    }
}
