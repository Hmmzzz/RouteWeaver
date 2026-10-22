import XCTest
import Darwin
import RouteCore
@testable import RouteHelper

final class NetworkMonitorTests: XCTestCase {
    private let globalKey = NetworkTopologySnapshot.globalIPv4Key
    private let baseline: NSDictionary = ["PrimaryInterface": "utun6", "PrimaryService": "service-a", "Router": "100.64.0.1"]

    func testRepeatedIdenticalGlobalNotificationsDoNotTriggerCleanup() {
        var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
        for _ in 0..<5 { XCTAssertFalse(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline))) }
        XCTAssertFalse(changes.takePendingChange())
    }
    func testGlobalDictionaryKeyOrderDoesNotCountAsChange() {
        var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
        let reordered: NSDictionary = ["Router": "100.64.0.1", "PrimaryService": "service-a", "PrimaryInterface": "utun6"]
        XCTAssertFalse(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: reordered)))
        XCTAssertFalse(changes.takePendingChange())
    }
    func testEveryGlobalValueChangeStillTriggersCleanup() {
        for field in ["PrimaryInterface", "PrimaryService", "Router", "AdditionalField"] {
            var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
            let modified = baseline.mutableCopy() as! NSMutableDictionary
            modified[field] = "changed"
            XCTAssertTrue(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: modified)))
            XCTAssertTrue(changes.takePendingChange())
            XCTAssertFalse(changes.takePendingChange())
            XCTAssertFalse(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: modified)))
        }
    }
    func testGlobalChangeThenRestoreBeforeDebounceStillTriggersCleanup() {
        var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
        let changed: NSDictionary = ["PrimaryInterface": "en0", "PrimaryService": "service-b", "Router": "192.168.1.1"]
        XCTAssertTrue(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: changed)))
        XCTAssertTrue(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline)))
        XCTAssertFalse(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline)))
        XCTAssertTrue(changes.takePendingChange())
    }
    func testOtherUnchangedNotificationKeysDoNotTriggerCleanup() {
        for key in ["State:/Network/Interface/en0/Link", "State:/Network/Service/service-a/IPv4", "Setup:/Network/Global/IPv4"] {
            var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
            XCTAssertFalse(changes.observe(keys: [key], snapshot: snapshot(globalIPv4: baseline)))
            XCTAssertFalse(changes.takePendingChange())
        }
    }
    func testLinkDownUpAndDuplicateGlobalKeepCleanupPending() {
        var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
        let link = "State:/Network/Interface/en0/Link"
        XCTAssertTrue(changes.observe(keys: [link], snapshot: snapshot(globalIPv4: baseline, linkActive: false)))
        XCTAssertTrue(changes.observe(keys: [link], snapshot: snapshot(globalIPv4: baseline)))
        XCTAssertFalse(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline)))
        XCTAssertTrue(changes.takePendingChange())
    }
    func testMixedReadableNotificationsAreDeduplicatedButUnreadableRemainConservative() {
        for (keys, expected) in [([globalKey, "State:/Network/Interface/en0/Link"], false), ([], true)] {
            var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
            XCTAssertEqual(changes.observe(keys: keys, snapshot: snapshot(globalIPv4: baseline)), expected)
            XCTAssertEqual(changes.takePendingChange(), expected)
        }
    }
    func testMissingGlobalSnapshotAndRecoveryTriggerCleanup() {
        var changes = NetworkTopologyChangeTracker(snapshot: snapshot(globalIPv4: baseline))
        XCTAssertTrue(changes.observe(keys: [globalKey], snapshot: nil))
        XCTAssertTrue(changes.observe(keys: [globalKey], snapshot: nil))
        XCTAssertTrue(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline)))
        XCTAssertTrue(changes.takePendingChange())
        XCTAssertFalse(changes.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline)))
        var noBaseline = NetworkTopologyChangeTracker(snapshot: nil)
        XCTAssertTrue(noBaseline.observe(keys: [globalKey], snapshot: snapshot(globalIPv4: baseline)))
    }
    private func snapshot(globalIPv4: NSDictionary, linkActive: Bool = true) -> NetworkTopologySnapshot {
        NetworkTopologySnapshot(values: [
            globalKey: globalIPv4,
            NetworkTopologySnapshot.setupIPv4Key: ["ServiceOrder": ["service-a", "physical-a"]],
            "State:/Network/Service/service-a/IPv4": ["InterfaceName": "utun6", "Router": "100.64.0.1", "Addresses": ["100.64.0.2"]],
            "State:/Network/Service/physical-a/IPv4": ["InterfaceName": "en0", "Router": "192.168.1.1", "Addresses": ["192.168.1.2"], "SubnetMasks": ["255.255.255.0"]],
            "State:/Network/Interface/en0/Link": ["Active": linkActive]
        ], routes: [ExistingRoute(network: 0, mask: 0, gateway: IPv4CIDR.parseAddress("192.168.1.1"),
                                 interface: "en0", index: 4, flags: UInt32(RTF_GATEWAY | RTF_UP))])
    }
}
