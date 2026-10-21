import XCTest
@testable import RouteCore

final class APNICParserTests: XCTestCase {
    func testFiltersCountryTypeAndStatusAndCoalesces() throws {
        let source = """
        # Delegated APNIC statistics
        2|apnic|20261020|100|20261020|20261020|+0000
        apnic|*|ipv4|*|2|summary
        apnic|CN|ipv4|1.2.0.0|256|20261020|allocated
        apnic|CN|ipv4|1.2.1.0|256|20261020|assigned
        apnic|JP|ipv4|8.8.8.0|256|20261020|allocated
        apnic|CN|ipv6|2400::|32|20261020|allocated
        apnic|CN|asn|12345|1|20261020|allocated
        apnic|CN|ipv4|9.0.0.0|256|20261020|reserved
        """
        XCTAssertEqual(try APNICParser.chinaIPv4(from: source).map(\.description), ["1.2.0.0/23"])
    }

    func testArbitraryCountAndUnalignedStartAreExactlyCovered() throws {
        let result = try APNICParser.chinaIPv4(from: "apnic|CN|ipv4|1.2.3.1|6|20261020|allocated")
        XCTAssertEqual(result.map(\.description), ["1.2.3.1/32", "1.2.3.2/31", "1.2.3.4/31", "1.2.3.6/32"])
    }

    func testWindowsLineEndingsAndExtendedRows() throws {
        let result = try APNICParser.chinaIPv4(from: "apnic|CN|ipv4|223.5.5.0|256|20261020|allocated|opaque-id\r\n")
        XCTAssertEqual(result.map(\.description), ["223.5.5.0/24"])
    }

    func testMalformedCNRowAbortsEntireDataset() {
        let good = "apnic|CN|ipv4|1.2.3.0|256|20261020|allocated\n"
        for malformed in [
            "apnic|CN|ipv4|1.2.3.0",
            "apnic|CN|ipv4|bad|256|20261020|allocated",
            "apnic|CN|ipv4|1.2.3.0|0|20261020|allocated",
            "apnic|CN|ipv4|1.2.3.0|-1|20261020|allocated",
            "apnic|CN|ipv4|1.2.3.0|+256|20261020|allocated",
            "apnic|CN|ipv4|255.255.255.255|2|20261020|allocated",
            "apnic|CN|ipv4|1.2.3.0|99999999999999999999|20261020|allocated",
            "apnic|CN|ipv4|10.0.0.0|256|20261020|allocated",
            "other|CN|ipv4|1.2.3.0|256|20261020|allocated"
        ] {
            XCTAssertThrowsError(try APNICParser.chinaIPv4(from: good + malformed), malformed)
        }
    }

    func testEmptyOrWrongCountryDatasetRejected() {
        XCTAssertThrowsError(try APNICParser.chinaIPv4(from: ""))
        XCTAssertThrowsError(try APNICParser.chinaIPv4(from: "apnic|JP|ipv4|1.2.3.0|256|20261020|allocated"))
    }

    func testRangeConversionAtUInt32Boundary() {
        XCTAssertEqual(AddressRange(lower: 0, upper: UInt64(UInt32.max)).cidrs().map(\.description), ["0.0.0.0/0"])
        XCTAssertEqual(AddressRange(lower: UInt64(UInt32.max), upper: UInt64(UInt32.max)).cidrs().map(\.description), ["255.255.255.255/32"])
    }

    func testExclusionSpanningSeveralInputRanges() {
        let sources = [AddressRange(lower: 0, upper: 5), AddressRange(lower: 10, upper: 15), AddressRange(lower: 20, upper: 25)]
        let result = AddressRange.subtract([AddressRange(lower: 3, upper: 22)], from: sources)
        XCTAssertEqual(result.map { [$0.lower, $0.upper] }, [[0, 2], [23, 25]])
    }
}
