import XCTest
import Darwin
import RouteCore
@testable import RouteHelper

final class NetworkMonitorTests: XCTestCase {
    private let globalKey = NetworkTopologySnapshot.globalIPv4Key
    private let setupKey = NetworkTopologySnapshot.setupIPv4Key
    private let physicalKey = "State:/Network/Service/physical-a/IPv4"
    private let linkKey = "State:/Network/Interface/en0/Link"
    private func route(_ interface: String = "en0", gateway: String = "192.168.1.1", up: Bool = true) -> ExistingRoute {
        ExistingRoute(network: 0, mask: 0, gateway: IPv4CIDR.parseAddress(gateway), interface: interface,
                      index: interface == "en0" ? 4 : 5, flags: UInt32(RTF_GATEWAY | (up ? RTF_UP : 0)))
    }
    private func snapshot(_ edit: (inout [String: NSDictionary]) -> Void = { _ in },
                          routes: [ExistingRoute]? = nil) -> NetworkTopologySnapshot {
        var values: [String: NSDictionary] = [
            globalKey: ["PrimaryInterface": "utun6", "PrimaryService": "tailscale", "Router": "100.64.0.1"],
            setupKey: ["ServiceOrder": ["tailscale", "physical-a", "physical-b"]],
            physicalKey: ["InterfaceName": "en0", "Router": "192.168.1.1", "Addresses": ["192.168.1.2"], "SubnetMasks": ["255.255.255.0"]],
            "State:/Network/Service/physical-b/IPv4": ["InterfaceName": "en7", "Router": "10.0.0.1", "Addresses": ["10.0.0.2"], "SubnetMasks": ["255.255.255.0"]],
            "State:/Network/Service/tailscale/IPv4": ["InterfaceName": "utun6", "Router": "100.64.0.1", "Addresses": ["100.64.0.2"]],
            linkKey: ["Active": true], "State:/Network/Interface/en7/Link": ["Active": true]
        ]
        edit(&values)
        return NetworkTopologySnapshot(values: values, routes: routes ?? [route(), route("en7", gateway: "10.0.0.1"), route("utun6", gateway: "100.64.0.1")])
    }
    private func replacing(_ original: NSDictionary, _ field: String, _ value: Any) -> NSDictionary {
        let result = original.mutableCopy() as! NSMutableDictionary; result[field] = value; return result
    }
    func testDuplicateAndUnrelatedNotificationsOldWouldRebuildNewDoesNot() {
        let baseline = snapshot()
        XCTAssertNotNil(baseline.fingerprint)
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        let keys = [physicalKey, linkKey, setupKey, "State:/Network/Interface/en7/Link", "State:/Network/Service/physical-b/IPv4"]
        // The old tracker forwarded every non-global event even with identical
        // state; each item is a separate event/debounce cycle.
        let oldRebuilds = keys.filter { $0 != globalKey }.count
        var newRebuilds = 0
        for key in keys {
            XCTAssertFalse(tracker.observe(keys: [key], snapshot: baseline))
            if tracker.takePendingChange() { newRebuilds += 1 }
        }
        XCTAssertEqual(oldRebuilds, 5); XCTAssertEqual(newRebuilds, 0)
        XCTAssertFalse(tracker.observe(keys: [globalKey, physicalKey, linkKey], snapshot: baseline))
    }
    func testGlobalDictionaryOrderingDoesNotCountAsChange() {
        let baseline = snapshot(), reordered = snapshot {
            $0[self.globalKey] = ["Router": "100.64.0.1", "PrimaryService": "tailscale", "PrimaryInterface": "utun6"]
        }
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        XCTAssertFalse(tracker.observe(keys: [globalKey], snapshot: reordered))
        XCTAssertFalse(tracker.takePendingChange())
    }
    func testSelectedAddressAndSubnetChangesAlwaysRebuild() {
        for (field, value) in [("Addresses", ["192.168.1.8"]), ("SubnetMasks", ["255.255.0.0"])] {
            let changed = snapshot { $0[self.physicalKey] = self.replacing($0[self.physicalKey]!, field, value) }
            var tracker = NetworkTopologyChangeTracker(snapshot: snapshot())
            XCTAssertTrue(tracker.observe(keys: [physicalKey], snapshot: changed))
            XCTAssertTrue(tracker.takePendingChange())
            XCTAssertFalse(tracker.observe(keys: [physicalKey], snapshot: changed))
        }
    }
    func testSelectedGatewayAndInterfaceChangesAlwaysRebuild() {
        let gatewayChange = snapshot({ $0[self.physicalKey] = self.replacing($0[self.physicalKey]!, "Router", "192.168.1.254") },
                                     routes: [route(gateway: "192.168.1.254")])
        var tracker = NetworkTopologyChangeTracker(snapshot: snapshot())
        XCTAssertTrue(tracker.observe(keys: [physicalKey], snapshot: gatewayChange))
        XCTAssertTrue(tracker.takePendingChange())
        let interfaceChange = snapshot {
            $0[self.globalKey] = ["PrimaryInterface": "en7", "PrimaryService": "physical-b", "Router": "10.0.0.1"]
        }
        XCTAssertEqual(interfaceChange.fingerprint?.interface, "en7")
        XCTAssertTrue(tracker.observe(keys: [globalKey], snapshot: interfaceChange))
    }
    func testServicePriorityChangesAreRelevantEvenIfSelectedRouteStaysSame() {
        let changed = snapshot { $0[self.setupKey] = ["ServiceOrder": ["physical-a", "tailscale", "physical-b"]] }
        XCTAssertEqual(changed.fingerprint?.interface, "en0")
        var tracker = NetworkTopologyChangeTracker(snapshot: snapshot())
        XCTAssertTrue(tracker.observe(keys: [setupKey], snapshot: changed))
        let switchesPhysical = snapshot { $0[self.setupKey] = ["ServiceOrder": ["tailscale", "physical-b", "physical-a"]] }
        XCTAssertEqual(switchesPhysical.fingerprint?.interface, "en7")
        XCTAssertTrue(tracker.observe(keys: [setupKey], snapshot: switchesPhysical))
    }
    func testTailscaleGlobalPrimaryNeverBecomesPhysicalAndTunnelChangesRemainRelevant() {
        let baseline = snapshot()
        XCTAssertEqual(baseline.fingerprint?.interface, "en0")
        XCTAssertEqual(baseline.fingerprint?.gateway, IPv4CIDR.parseAddress("192.168.1.1"))
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        let changed = snapshot { $0[self.globalKey] = self.replacing($0[self.globalKey]!, "PrimaryInterface", "utun9") }
        XCTAssertEqual(changed.fingerprint?.interface, "en0")
        XCTAssertTrue(tracker.observe(keys: [globalKey], snapshot: changed))
        let tunnelOnly = snapshot(routes: [route("utun6", gateway: "100.64.0.1")])
        XCTAssertNil(tunnelOnly.fingerprint)
        XCTAssertTrue(tracker.observe(keys: [globalKey], snapshot: tunnelOnly))
    }
    func testGlobalPhysicalPrimaryWinsOverServiceOrder() {
        let baseline = snapshot { $0[self.globalKey] = ["PrimaryInterface": "en7", "PrimaryService": "physical-b", "Router": "10.0.0.1"] }
        XCTAssertEqual(baseline.fingerprint?.interface, "en7")
        XCTAssertEqual(baseline.fingerprint?.service, "physical-b")
    }
    func testLinkDownUpBeforeDebounceKeepsPendingDespiteFinalEqualTopology() {
        let baseline = snapshot(), down = snapshot { $0[self.linkKey] = ["Active": false] }
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        XCTAssertTrue(tracker.observe(keys: [linkKey], snapshot: down))
        XCTAssertTrue(tracker.observe(keys: [linkKey], snapshot: baseline))
        XCTAssertFalse(tracker.observe(keys: [globalKey], snapshot: baseline))
        XCTAssertTrue(tracker.takePendingChange())
        XCTAssertFalse(tracker.takePendingChange())
    }
    func testPhysicalRouteDownUpBeforeDebounceKeepsPending() {
        let baseline = snapshot(), down = snapshot(routes: [route(up: false)])
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        XCTAssertTrue(tracker.observe(keys: [physicalKey], snapshot: down))
        XCTAssertTrue(tracker.observe(keys: [physicalKey], snapshot: baseline))
        XCTAssertTrue(tracker.takePendingChange())
    }
    func testMissingOrMalformedEvidenceNeverSuppressesNotifications() {
        let baseline = snapshot()
        let incomplete: [NetworkTopologySnapshot?] = [nil,
            snapshot { $0.removeValue(forKey: self.globalKey) },
            snapshot { $0.removeValue(forKey: self.setupKey) },
            snapshot { $0.removeValue(forKey: self.physicalKey) },
            snapshot { $0.removeValue(forKey: self.linkKey) },
            snapshot { $0[self.linkKey] = ["Active": "unknown"] },
            snapshot { $0[self.physicalKey] = self.replacing($0[self.physicalKey]!, "Addresses", ["invalid"]) },
            snapshot { $0[self.physicalKey] = self.replacing($0[self.physicalKey]!, "SubnetMasks", []) }
        ]
        for state in incomplete {
            var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
            XCTAssertTrue(tracker.observe(keys: [globalKey], snapshot: state))
            XCTAssertTrue(tracker.observe(keys: [globalKey], snapshot: state))
            XCTAssertTrue(tracker.observe(keys: [globalKey], snapshot: baseline))
            XCTAssertTrue(tracker.takePendingChange())
        }
    }
    func testUnknownEmptyOrRemovedNotificationKeyRemainsConservative() {
        for keys in [[], ["State:/Network/Interface/en0/IPv6"], ["State:/Network/Service/missing/IPv4"], ["State:/Network/Interface//Link"]] {
            var tracker = NetworkTopologyChangeTracker(snapshot: snapshot())
            XCTAssertTrue(tracker.observe(keys: keys, snapshot: snapshot()))
            XCTAssertTrue(tracker.takePendingChange())
        }
    }
    func testAmbiguousPhysicalDefaultCannotBeTreatedAsDuplicate() {
        let ambiguous = snapshot({ $0[self.globalKey] = ["PrimaryInterface": "en0", "PrimaryService": "physical-a"] },
                                 routes: [route(), route(gateway: "192.168.1.254")])
        XCTAssertNil(ambiguous.fingerprint)
        var tracker = NetworkTopologyChangeTracker(snapshot: ambiguous)
        XCTAssertTrue(tracker.observe(keys: [physicalKey], snapshot: ambiguous))
    }
    func testUnselectedServiceChangesDoNotChangeProvenSelectedTopology() {
        let baseline = snapshot(), changed = snapshot {
            let key = "State:/Network/Service/physical-b/IPv4"
            $0[key] = self.replacing($0[key]!, "Addresses", ["10.0.0.12"])
        }
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        XCTAssertFalse(tracker.observe(keys: ["State:/Network/Service/physical-b/IPv4"], snapshot: changed))
    }
    func testTunnelAndUnknownServiceChangesCannotBeSuppressedByUnchangedGlobal() {
        let baseline = snapshot(), tunnelKey = "State:/Network/Service/tailscale/IPv4"
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        XCTAssertFalse(tracker.observe(keys: [tunnelKey], snapshot: baseline))
        let changed = snapshot { $0[tunnelKey] = self.replacing($0[tunnelKey]!, "Addresses", ["100.64.0.3"]) }
        XCTAssertTrue(tracker.observe(keys: [tunnelKey], snapshot: changed))
        XCTAssertTrue(tracker.observe(keys: [tunnelKey], snapshot: baseline))
        XCTAssertTrue(tracker.takePendingChange())
        let unidentified = snapshot { $0[tunnelKey] = ["Addresses": ["100.64.0.3"]] }
        XCTAssertTrue(tracker.observe(keys: [tunnelKey], snapshot: unidentified))
        XCTAssertTrue(tracker.observe(keys: [tunnelKey], snapshot: unidentified))
    }
    func testTunnelLinkDownUpKeepsPendingWithoutGlobalChange() {
        let tunnelLink = "State:/Network/Interface/utun6/Link"
        let baseline = snapshot { $0[tunnelLink] = ["Active": true] }
        let down = snapshot { $0[tunnelLink] = ["Active": false] }
        var tracker = NetworkTopologyChangeTracker(snapshot: baseline)
        XCTAssertFalse(tracker.observe(keys: [tunnelLink], snapshot: baseline))
        XCTAssertTrue(tracker.observe(keys: [tunnelLink], snapshot: down))
        XCTAssertTrue(tracker.observe(keys: [tunnelLink], snapshot: baseline))
        XCTAssertTrue(tracker.takePendingChange())
    }
    func testRawInvalidationPrecedesDebounceAndDuplicateDoesNotInvalidateAgain() {
        let queue = DispatchQueue(label: "NetworkMonitorTests"), done = expectation(description: "one debounced rebuild")
        var invalidations = 0
        let monitor = NetworkMonitor(queue: queue, onTopologyInvalidated: { invalidations += 1 }) { changed in
            XCTAssertTrue(changed); XCTAssertEqual(invalidations, 3); done.fulfill()
        }
        let baseline = snapshot(), down = snapshot { $0[self.linkKey] = ["Active": false] }
        queue.sync {
            monitor.receiveTopologyChange([globalKey], snapshot: baseline)
            XCTAssertEqual(invalidations, 1)
            monitor.receiveTopologyChange([linkKey], snapshot: baseline)
            XCTAssertEqual(invalidations, 1)
            monitor.receiveTopologyChange([linkKey], snapshot: down)
            XCTAssertEqual(invalidations, 2)
            monitor.receiveTopologyChange([linkKey], snapshot: baseline)
            XCTAssertEqual(invalidations, 3)
            monitor.receiveTopologyChange([physicalKey], snapshot: baseline)
            XCTAssertEqual(invalidations, 3)
        }
        wait(for: [done], timeout: 2)
        withExtendedLifetime(monitor) {}
    }
}
