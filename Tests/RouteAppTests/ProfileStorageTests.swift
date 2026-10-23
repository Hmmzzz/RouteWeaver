import XCTest
import Foundation
import Darwin
import RouteCore
import RouteIPC
@testable import RouteWeaver

final class ProfileStorageTests: XCTestCase {
    private func withStorage(_ check: (ProfileStorage) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routeweaver-profile-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // These tests exercise real files and locks, independently of whether
        // the host currently makes its data-protection key available.
        try check(ProfileStorage(directory: directory, writingOptions: [.atomic]))
    }

    private func profile(_ cidr: String) -> SavedProfile {
        SavedProfile(countryEnabled: false, rules: [RouteRule(cidr: cidr, action: .direct, note: "test")])
    }

    func testStaleSnapshotCannotReplaceAProfileCreatedByAnotherInstance() throws {
        try withStorage { storage in
            let first = try storage.load()
            let second = try storage.load()
            XCTAssertNil(first.profile)
            try storage.save(profile("223.5.5.0/24"), replacing: first.revision)
            XCTAssertThrowsError(try storage.save(profile("223.6.6.0/24"), replacing: second.revision)) {
                XCTAssertEqual($0 as? ProfileStorage.StorageError, .changed)
            }
            XCTAssertEqual(try storage.load().profile?.rules.map(\.cidr), ["223.5.5.0/24"])
        }
    }

    func testStaleSnapshotCannotReplaceAnUpdatedOrDeletedProfile() throws {
        try withStorage { storage in
            let initial = try storage.save(profile("223.5.5.0/24"), replacing: .missing)
            let stale = try storage.load()
            let current = try storage.save(profile("223.6.6.0/24"), replacing: initial)
            XCTAssertThrowsError(try storage.save(profile("223.7.7.0/24"), replacing: stale.revision)) {
                XCTAssertEqual($0 as? ProfileStorage.StorageError, .changed)
            }
            XCTAssertEqual(try storage.load().revision, current)
            try FileManager.default.removeItem(at: storage.location.appendingPathComponent("profile.json"))
            XCTAssertThrowsError(try storage.save(profile("223.7.7.0/24"), replacing: current)) {
                XCTAssertEqual($0 as? ProfileStorage.StorageError, .changed)
            }
            XCTAssertNil(try storage.load().profile)
        }
    }

    func testVersionOneProfileNeedsNoSchemaMigrationAndNewRevisionCanBeSavedAgain() throws {
        try withStorage { storage in
            try ProfileStorage.prepareDirectory(at: storage.location)
            let file = storage.location.appendingPathComponent("profile.json")
            try JSONEncoder().encode(profile("223.5.5.0/24")).write(to: file, options: .atomic)
            let loaded = try storage.load()
            XCTAssertEqual(loaded.profile?.version, 1)
            let revision = try storage.save(profile("223.6.6.0/24"), replacing: loaded.revision)
            XCTAssertEqual(try storage.load().revision, revision)
            try storage.save(profile("223.7.7.0/24"), replacing: revision)
            XCTAssertEqual(try storage.load().profile?.rules.map(\.cidr), ["223.7.7.0/24"])
        }
    }

    func testAnotherOpenDescriptorHoldingTheSaveLockPreventsWriting() throws {
        try withStorage { storage in
            let revision = try storage.save(profile("223.5.5.0/24"), replacing: .missing)
            let lock = storage.location.appendingPathComponent(".profile.lock")
            let descriptor = open(lock.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try storage.save(profile("223.6.6.0/24"), replacing: revision)) {
                XCTAssertEqual($0 as? ProfileStorage.StorageError, .busy)
            }
            XCTAssertEqual(try storage.load().revision, revision)
            var status = stat()
            XCTAssertEqual(fstat(descriptor, &status), 0)
            XCTAssertEqual(status.st_mode & 0o777, 0o600)
            XCTAssertEqual(status.st_nlink, 1)
        }
    }

    func testSymlinkOrHardLinkedLockIsRejectedWithoutTouchingItsTarget() throws {
        for hardLink in [false, true] {
            try withStorage { storage in
                try ProfileStorage.prepareDirectory(at: storage.location)
                let target = storage.location.appendingPathComponent("unrelated.txt")
                let lock = storage.location.appendingPathComponent(".profile.lock")
                let original = Data("Keep this file".utf8)
                try original.write(to: target)
                if hardLink { try FileManager.default.linkItem(at: target, to: lock) }
                else { try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target) }
                XCTAssertThrowsError(try storage.save(profile("223.5.5.0/24"), replacing: .missing)) {
                    XCTAssertEqual($0 as? ProfileStorage.StorageError, .unsafeLock)
                }
                XCTAssertEqual(try Data(contentsOf: target), original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: storage.location.appendingPathComponent("profile.json").path))
            }
        }
    }

    @MainActor
    func testStorePreservesDraftOnConflictAndExplicitReloadAllowsFurtherEdits() throws {
        try withStorage { storage in
            try storage.save(SavedProfile(countryEnabled: false), replacing: .missing)
            let first = AppStore(profileStorage: storage)
            var stopCalls = 0
            let second = AppStore(profileStorage: storage, stopService: {
                stopCalls += 1
                throw AppFailure("This test must never send a routing command")
            })
            try first.addRule(cidr: "223.5.5.0/24", action: .direct, note: "first")
            try second.addRule(cidr: "223.6.6.0/24", action: .direct, note: "draft")
            XCTAssertEqual(try storage.load().profile?.rules.map(\.cidr), ["223.5.5.0/24"])
            XCTAssertEqual(second.rules.map(\.cidr), ["223.6.6.0/24"])
            XCTAssertTrue(second.profileRecoveryMessage?.contains("另一实例") == true)
            let exported = try JSONDecoder().decode([RouteRule].self, from: Data(second.exportRules().utf8))
            XCTAssertEqual(exported.map(\.cidr), ["223.6.6.0/24"])
            second.dismissError()
            XCTAssertNotNil(second.profileRecoveryMessage, "Dismissing transient errors must not hide unsaved rules")

            second.network = NetworkSnapshot(tailscaleInstalled: true, tailscaleRunning: true,
                exitNodeID: "test", exitNodeOnline: true, gateway: "192.168.1.1", interface: "en0")
            second.serviceChecked = true
            second.serviceReachable = true
            XCTAssertFalse(second.canApply)
            XCTAssertTrue(second.canStop, "An unsaved profile must not block stopping the helper")
            second.reloadProfile()
            XCTAssertNil(second.profileRecoveryMessage)
            XCTAssertEqual(second.rules.map(\.cidr), ["223.5.5.0/24"])
            XCTAssertEqual(stopCalls, 0)
            XCTAssertFalse(second.serviceEnabled)
            XCTAssertTrue(second.canApply)

            try second.addRule(cidr: "223.7.7.0/24", action: .direct, note: "after reload")
            XCTAssertEqual(try storage.load().profile?.rules.map(\.cidr), ["223.5.5.0/24", "223.7.7.0/24"])
            XCTAssertNil(second.profileRecoveryMessage)
        }
    }

    @MainActor
    func testEmptyPlanCanStillStopAfterAProfileConflict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routeweaver-profile-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ProfileStorage(directory: directory, writingOptions: [.atomic])
        try storage.save(SavedProfile(countryEnabled: false), replacing: .missing)
        let first = AppStore(profileStorage: storage)
        var stopCalls = 0
        var response = ServiceResponse()
        response.verified = true
        response.dnsActive = false
        response.dnsWithdrawn = true
        let second = AppStore(profileStorage: storage, stopService: {
            stopCalls += 1
            return response
        })
        try first.addRule(cidr: "223.5.5.0/24", action: .direct, note: "saved")
        second.rebuildPlan()
        XCTAssertNotNil(second.profileRecoveryMessage)
        XCTAssertTrue(second.plannedRoutes.isEmpty)
        second.serviceChecked = true
        second.serviceReachable = true
        second.serviceEnabled = true
        XCTAssertTrue(second.canApply)

        await second.apply()

        XCTAssertEqual(stopCalls, 1)
        XCTAssertFalse(second.serviceEnabled)
        XCTAssertTrue(second.dnsRestorationConfirmed)
        XCTAssertNotNil(second.profileRecoveryMessage)
        XCTAssertEqual(try storage.load().profile?.rules.map(\.cidr), ["223.5.5.0/24"])
    }

    @MainActor
    func testFailedReloadKeepsDraftAndOriginalFileForRecovery() throws {
        try withStorage { storage in
            try storage.save(SavedProfile(countryEnabled: false), replacing: .missing)
            let store = AppStore(profileStorage: storage)
            try store.addRule(cidr: "223.5.5.0/24", action: .direct, note: "saved")
            let file = storage.location.appendingPathComponent("profile.json")
            let corrupt = Data("broken profile".utf8)
            try corrupt.write(to: file, options: .atomic)
            try store.addRule(cidr: "223.6.6.0/24", action: .direct, note: "draft")
            store.reloadProfile()
            XCTAssertNotNil(store.profileRecoveryMessage)
            XCTAssertEqual(store.rules.map(\.cidr), ["223.5.5.0/24", "223.6.6.0/24"])
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
        }
    }
}
