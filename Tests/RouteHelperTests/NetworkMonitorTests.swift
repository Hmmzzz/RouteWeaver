import XCTest
@testable import RouteHelper

final class NetworkMonitorTests: XCTestCase {
    private let globalKey = NetworkTopologyChangeTracker.globalIPv4Key
    private let baseline: NSDictionary = ["PrimaryInterface": "utun6", "PrimaryService": "service-a", "Router": "100.64.0.1"]

    func testRepeatedIdenticalGlobalNotificationsDoNotTriggerCleanup() {
        var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
        for _ in 0..<5 { XCTAssertFalse(changes.observe(keys: [globalKey], globalIPv4: baseline)) }
        XCTAssertFalse(changes.takePendingChange())
    }
    func testGlobalDictionaryKeyOrderDoesNotCountAsChange() {
        var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
        let reordered: NSDictionary = ["Router": "100.64.0.1", "PrimaryService": "service-a", "PrimaryInterface": "utun6"]
        XCTAssertFalse(changes.observe(keys: [globalKey], globalIPv4: reordered))
        XCTAssertFalse(changes.takePendingChange())
    }
    func testEveryGlobalValueChangeStillTriggersCleanup() {
        for field in ["PrimaryInterface", "PrimaryService", "Router", "AdditionalField"] {
            var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
            let modified = baseline.mutableCopy() as! NSMutableDictionary
            modified[field] = "changed"
            XCTAssertTrue(changes.observe(keys: [globalKey], globalIPv4: modified))
            XCTAssertTrue(changes.takePendingChange())
            XCTAssertFalse(changes.takePendingChange())
            XCTAssertFalse(changes.observe(keys: [globalKey], globalIPv4: modified))
        }
    }
    func testGlobalChangeThenRestoreBeforeDebounceStillTriggersCleanup() {
        var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
        let changed: NSDictionary = ["PrimaryInterface": "en0", "PrimaryService": "service-b", "Router": "192.168.1.1"]
        XCTAssertTrue(changes.observe(keys: [globalKey], globalIPv4: changed))
        XCTAssertTrue(changes.observe(keys: [globalKey], globalIPv4: baseline))
        XCTAssertFalse(changes.observe(keys: [globalKey], globalIPv4: baseline))
        XCTAssertTrue(changes.takePendingChange())
    }
    func testOtherNotificationKeysAlwaysTriggerCleanupEvenWithIdenticalGlobal() {
        for key in ["State:/Network/Interface/en0/Link", "State:/Network/Service/service-a/IPv4", "Setup:/Network/Global/IPv4"] {
            var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
            XCTAssertTrue(changes.observe(keys: [key], globalIPv4: baseline))
            XCTAssertTrue(changes.takePendingChange())
        }
    }
    func testLinkDownUpAndDuplicateGlobalKeepCleanupPending() {
        var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
        let link = "State:/Network/Interface/en0/Link"
        XCTAssertTrue(changes.observe(keys: [link], globalIPv4: baseline))
        XCTAssertTrue(changes.observe(keys: [link], globalIPv4: baseline))
        XCTAssertFalse(changes.observe(keys: [globalKey], globalIPv4: baseline))
        XCTAssertTrue(changes.takePendingChange())
    }
    func testMixedOrUnreadableNotificationsCannotBeSuppressed() {
        for keys in [[globalKey, "State:/Network/Interface/en0/Link"], []] {
            var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
            XCTAssertTrue(changes.observe(keys: keys, globalIPv4: baseline))
            XCTAssertTrue(changes.takePendingChange())
        }
    }
    func testMissingGlobalSnapshotAndRecoveryTriggerCleanup() {
        var changes = NetworkTopologyChangeTracker(globalIPv4: baseline)
        XCTAssertTrue(changes.observe(keys: [globalKey], globalIPv4: nil))
        XCTAssertTrue(changes.observe(keys: [globalKey], globalIPv4: nil))
        XCTAssertTrue(changes.observe(keys: [globalKey], globalIPv4: baseline))
        XCTAssertTrue(changes.takePendingChange())
        XCTAssertFalse(changes.observe(keys: [globalKey], globalIPv4: baseline))
        var noBaseline = NetworkTopologyChangeTracker(globalIPv4: nil)
        XCTAssertTrue(noBaseline.observe(keys: [globalKey], globalIPv4: baseline))
    }
}
