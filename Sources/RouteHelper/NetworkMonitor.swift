import Foundation
import SystemConfiguration
import RouteCore

/// Event driven wakeups plus one low-frequency CLI check for changes that
/// Tailscale does not publish through SystemConfiguration.
final class NetworkMonitor {
    private let queue: DispatchQueue
    private let callback: (Bool) -> Void
    private let onTopologyInvalidated: (() -> Void)?
    private var store: SCDynamicStore?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var changes = NetworkTopologyChangeTracker(snapshot: nil)
    init(queue: DispatchQueue, onTopologyInvalidated: (() -> Void)? = nil, callback: @escaping (Bool) -> Void) {
        self.queue = queue; self.callback = callback; self.onTopologyInvalidated = onTopologyInvalidated
    }
    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "RouteWeaver.network" as CFString, { _, keys, info in
            guard let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().changed(keys as? [String] ?? [])
        }, &context)
        if let store {
            SCDynamicStoreSetNotificationKeys(store, nil, NetworkTopologySnapshot.patterns as CFArray)
            changes = NetworkTopologyChangeTracker(snapshot: NetworkTopologySnapshot.read(store))
            SCDynamicStoreSetDispatchQueue(store, queue)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.callback(false) }
        self.timer = timer; timer.resume()
    }
    private func changed(_ keys: [String]) {
        receiveTopologyChange(keys, snapshot: store.flatMap(NetworkTopologySnapshot.read))
    }
    func receiveTopologyChange(_ keys: [String], snapshot: NetworkTopologySnapshot?) {
        // Sample each raw event before debounce. A real down/up must stay
        // pending even when the final topology matches the initial topology.
        guard changes.observe(keys: keys, snapshot: snapshot) else { return }
        onTopologyInvalidated?()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.changes.takePendingChange() else { return }
            self.pending = nil; self.callback(true)
        }
        pending = work; queue.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }
    deinit {
        pending?.cancel(); timer?.cancel()
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}

/// Read-only evidence for deciding whether an event warrants rediscovery. This
/// never chooses a route for installation; Preflight remains the authority.
struct NetworkTopologySnapshot {
    static let globalIPv4Key = "State:/Network/Global/IPv4"
    static let setupIPv4Key = "Setup:/Network/Global/IPv4"
    static let patterns = [globalIPv4Key, setupIPv4Key, "State:/Network/Service/.*/IPv4", "State:/Network/Interface/.*/Link"]
    let values: [String: NSDictionary]
    let routes: [ExistingRoute]
    init(values: [String: NSDictionary], routes: [ExistingRoute]) {
        self.values = values.mapValues { $0.copy() as! NSDictionary }; self.routes = routes
    }
    static func read(_ store: SCDynamicStore) -> NetworkTopologySnapshot? {
        guard let values = SCDynamicStoreCopyMultiple(store, nil, patterns as CFArray) as? [String: Any],
              let routes = try? RouteTable.snapshot() else { return nil }
        return NetworkTopologySnapshot(values: values.compactMapValues { $0 as? NSDictionary }, routes: routes)
    }
    static func knownKey(_ key: String) -> Bool {
        if key == globalIPv4Key || key == setupIPv4Key { return true }
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "State:", parts[1] == "Network", !parts[3].isEmpty else { return false }
        return (parts[2] == "Service" && parts[4] == "IPv4") || (parts[2] == "Interface" && parts[4] == "Link")
    }
    func hasReadableNotification(_ key: String) -> Bool {
        guard Self.knownKey(key), let value = values[key] else { return false }
        if key.hasPrefix("State:/Network/Service/") {
            guard let interface = value["InterfaceName"] as? String, !interface.isEmpty,
                  let addresses = value["Addresses"] as? [String], !addresses.isEmpty else { return false }
            return addresses.allSatisfy { IPv4CIDR.parseAddress($0) != nil }
        }
        if key.hasPrefix("State:/Network/Interface/") { return value["Active"] as? Bool != nil }
        return true
    }
    var fingerprint: NetworkTopologyFingerprint? {
        guard let global = values[Self.globalIPv4Key], let primary = global["PrimaryInterface"] as? String, !primary.isEmpty,
              let order = values[Self.setupIPv4Key]?["ServiceOrder"] as? [String], !order.isEmpty,
              Set(order).count == order.count, order.allSatisfy({ !$0.isEmpty }) else { return nil }
        let candidates = routes.filter {
            $0.network == 0 && $0.mask == 0 && $0.gateway != nil && $0.gateway != 0 &&
            Self.physicalInterface($0.interface) && $0.flags & UInt32(RTF_UP) != 0
        }
        guard candidates.allSatisfy({ route in
            order.contains { service in
                guard let state = values["State:/Network/Service/\(service)/IPv4"],
                      state["InterfaceName"] as? String == route.interface,
                      let router = state["Router"] as? String else { return false }
                return IPv4CIDR.parseAddress(router) == route.gateway
            }
        }) else { return nil }
        let selected: ExistingRoute
        let primaryRoutes = candidates.filter { $0.interface == primary }
        if !primaryRoutes.isEmpty {
            guard primaryRoutes.count == 1 else { return nil }
            selected = primaryRoutes[0]
        } else {
            // Match physicalDefault's service ordering when Tailscale owns the
            // global primary interface. A tunnel service cannot select enN.
            var orderedRoute: ExistingRoute?
            for service in order {
                guard let state = values["State:/Network/Service/\(service)/IPv4"],
                      let interface = state["InterfaceName"] as? String,
                      let router = state["Router"] as? String, let address = IPv4CIDR.parseAddress(router) else { continue }
                let matches = candidates.filter { $0.interface == interface && $0.gateway == address }
                if !matches.isEmpty {
                    guard matches.count == 1 else { return nil }
                    orderedRoute = matches[0]; break
                }
            }
            if let orderedRoute { selected = orderedRoute }
            else { guard candidates.count == 1 else { return nil }; selected = candidates[0] }
        }
        // The selected route must have complete service and link evidence.
        // Missing or partial store updates cannot be treated as duplicates.
        let matchingServices = order.filter { service in
            guard let state = values["State:/Network/Service/\(service)/IPv4"],
                  state["InterfaceName"] as? String == selected.interface,
                  let router = state["Router"] as? String else { return false }
            return IPv4CIDR.parseAddress(router) == selected.gateway
        }
        let primaryService = global["PrimaryService"] as? String
        guard let service = primaryService.flatMap({ matchingServices.contains($0) ? $0 : nil }) ?? matchingServices.first,
              let state = values["State:/Network/Service/\(service)/IPv4"],
              let addresses = state["Addresses"] as? [String], !addresses.isEmpty,
              addresses.allSatisfy({ IPv4CIDR.parseAddress($0) != nil }),
              let masks = state["SubnetMasks"] as? [String], masks.count == addresses.count,
              masks.allSatisfy({ IPv4CIDR.parseAddress($0) != nil }),
              let link = values["State:/Network/Interface/\(selected.interface)/Link"],
              link["Active"] as? Bool == true else { return nil }
        // A tunnel can change its IPv4 identity or link while Global/IPv4 is
        // unchanged. Only proven physical secondary interfaces are irrelevant;
        // virtual or unidentified service state stays conservative.
        let virtualState = values.filter { key, value in
            guard Self.knownKey(key), key != Self.globalIPv4Key, key != Self.setupIPv4Key else { return false }
            if key.hasPrefix("State:/Network/Service/") {
                guard let interface = value["InterfaceName"] as? String else { return true }
                return !Self.physicalInterface(interface)
            }
            let interface = key.split(separator: "/")[3]
            return !Self.physicalInterface(String(interface))
        }
        return NetworkTopologyFingerprint(global: global, virtualState: virtualState, serviceOrder: order, service: service, ipv4: state, link: link,
            interface: selected.interface, interfaceIndex: selected.index, gateway: selected.gateway!, routeFlags: selected.flags)
    }
    private static func physicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") && !name.dropFirst(2).isEmpty && name.dropFirst(2).allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}

struct NetworkTopologyFingerprint: Equatable {
    let global: NSDictionary
    let virtualState: [String: NSDictionary]
    let serviceOrder: [String]
    let service: String
    let ipv4: NSDictionary
    let link: NSDictionary
    let interface: String
    let interfaceIndex: UInt16
    let gateway: UInt32
    let routeFlags: UInt32
}

/// A complete equal topology suppresses duplicate and unrelated notifications.
/// Unreadable evidence always keeps the existing conservative cleanup behavior.
struct NetworkTopologyChangeTracker {
    private var previous: NetworkTopologyFingerprint?
    private var pendingChange = false
    init(snapshot: NetworkTopologySnapshot?) { previous = snapshot?.fingerprint }
    /// Returns whether this event should schedule/restart the debounce timer.
    mutating func observe(keys: [String], snapshot: NetworkTopologySnapshot?) -> Bool {
        let current = snapshot?.fingerprint
        let readableKeys = !keys.isEmpty && keys.allSatisfy { snapshot?.hasReadableNotification($0) == true }
        let unchanged = current.map { previous == $0 } ?? false
        previous = current
        guard !readableKeys || !unchanged else { return false }
        pendingChange = true
        return true
    }
    mutating func takePendingChange() -> Bool {
        let result = pendingChange; pendingChange = false; return result
    }
}
