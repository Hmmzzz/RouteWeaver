import XCTest
import RouteIPC
@testable import RouteWeaver

final class CommandRunnerTests: XCTestCase {
    func testKeepsJSONSeparateFromDiagnostics() async throws {
        let result = try await CommandRunner.run("/bin/sh", ["-c", "printf '{\"ok\":true}'; printf 'warning' >&2"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "{\"ok\":true}")
        XCTAssertEqual(result.errorOutput, "warning")
    }
    func testPreservesNonzeroExitStatus() async throws {
        let result = try await CommandRunner.run("/bin/sh", ["-c", "printf 'failed' >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.errorOutput, "failed")
    }
    func testTimeoutDoesNotWaitForDescendantHoldingOutput() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await CommandRunner.run("/bin/sh", ["-c", "(trap '' TERM; sleep 2) & wait"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch is CommandTimeout { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }
    func testTailscaleForcedToCLI() async throws {
        let result = try await CommandRunner.run("/usr/bin/printenv", ["TAILSCALE_BE_CLI"])
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }
    func testPartialHelperReportRetainsRecoveryCounts() throws {
        let data = Data("""
        {"version":1,"enabled":true,"phase":"backingOff","durationMilliseconds":1,"verified":false,"detailsOmitted":0,"added":2,"removed":0,"skipped":1,"failed":1,"active":2,"pending":1,"message":"partial","details":[{"cidr":"223.5.5.0/24","action":"add","result":"failed"}]}
        """.utf8)
        let report = try JSONDecoder().decode(ServiceResponse.self, from: data)
        XCTAssertEqual(report.active, 2)
        XCTAssertEqual(report.pending, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.details.count, 1)
    }
}
