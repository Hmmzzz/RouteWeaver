import XCTest
@testable import RouteWeaver

final class HelperAuthorizationTests: XCTestCase {
    private final class Service {
        var installed = true
        var reachable = true
        var probes = 0
        var installations = 0
        var delays = 0
        var recoverAfterDelay = false
        var rejectAuthorization = false

        var policy: HelperAuthorization {
            HelperAuthorization(
                probe: {
                    self.probes += 1
                    guard self.reachable else { throw AppFailure("Service unavailable") }
                },
                isInstalled: { self.installed },
                authorizeInstallation: {
                    self.installations += 1
                    if self.rejectAuthorization { throw AuthorizationCancelled() }
                    self.installed = true
                    self.reachable = true
                },
                retryDelay: {
                    self.delays += 1
                    if self.recoverAfterDelay { self.reachable = true }
                }
            )
        }
    }

    func testRepeatedUseAndRepairReuseAuthenticatedService() async throws {
        let service = Service()
        for _ in 0..<3 {
            try await service.policy.ensureAvailable(for: .enableRouting)
            try await service.policy.ensureAvailable(for: .explicitRepair)
        }
        XCTAssertEqual(service.probes, 6)
        XCTAssertEqual(service.installations, 0)
        XCTAssertEqual(service.delays, 0)
    }

    func testFirstExplicitEnableInstallsOnceThenReuses() async throws {
        let service = Service()
        service.installed = false; service.reachable = false
        try await service.policy.ensureAvailable(for: .enableRouting)
        try await service.policy.ensureAvailable(for: .enableRouting)
        XCTAssertEqual(service.installations, 1)
    }

    func testInstalledOfflineServiceDoesNotAutomaticallyReinstall() async {
        let service = Service()
        service.reachable = false
        do {
            try await service.policy.ensureAvailable(for: .enableRouting)
            XCTFail("Expected an explicit repair request")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("修复服务"))
        }
        XCTAssertEqual(service.probes, 3)
        XCTAssertEqual(service.delays, 2)
        XCTAssertEqual(service.installations, 0)
    }

    func testDaemonRestartRecoversWithoutAuthorization() async throws {
        let service = Service()
        service.reachable = false; service.recoverAfterDelay = true
        try await service.policy.ensureAvailable(for: .enableRouting)
        XCTAssertEqual(service.probes, 2)
        XCTAssertEqual(service.installations, 0)
    }

    func testExplicitRepairInstallsOnlyWhenServiceRemainsUnavailable() async throws {
        let service = Service()
        service.reachable = false
        try await service.policy.ensureAvailable(for: .explicitRepair)
        XCTAssertEqual(service.probes, 3)
        XCTAssertEqual(service.installations, 1)
    }

    func testCancelledAuthorizationIsNotRetried() async {
        let service = Service()
        service.installed = false; service.reachable = false; service.rejectAuthorization = true
        do {
            try await service.policy.ensureAvailable(for: .enableRouting)
            XCTFail("Expected cancellation")
        } catch is AuthorizationCancelled { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(service.installations, 1)
        XCTAssertFalse(service.installed)
    }
}
