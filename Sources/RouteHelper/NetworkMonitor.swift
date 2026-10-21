import Foundation
import SystemConfiguration

/// Event driven wakeups plus one low-frequency CLI check for changes that
/// Tailscale does not publish through SystemConfiguration.
final class NetworkMonitor {
    private let queue: DispatchQueue
    private let callback: (Bool) -> Void
    private var store: SCDynamicStore?
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var changes = NetworkTopologyChangeTracker(globalIPv4: nil)
    init(queue: DispatchQueue, callback: @escaping (Bool) -> Void) { self.queue = queue; self.callback = callback }
    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "RouteWeaver.network" as CFString, { _, keys, info in
            guard let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().changed(keys as? [String] ?? [])
        }, &context)
        if let store {
            let patterns = ["State:/Network/Global/IPv4", "Setup:/Network/Global/IPv4", "State:/Network/Service/.*/IPv4", "State:/Network/Interface/.*/Link"]
            SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray)
            changes = NetworkTopologyChangeTracker(globalIPv4: SCDynamicStoreCopyValue(store, NetworkTopologyChangeTracker.globalIPv4Key as CFString) as? NSDictionary)
            SCDynamicStoreSetDispatchQueue(store, queue)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.callback(false) }
        self.timer = timer; timer.resume()
    }
    private func changed(_ keys: [String]) {
        let globalIPv4 = store.flatMap { SCDynamicStoreCopyValue($0, NetworkTopologyChangeTracker.globalIPv4Key as CFString) as? NSDictionary }
        // DNS publication can notify Global/IPv4 without changing any value.
        // Read each raw event, before debounce, so a real down/up stays pending.
        guard changes.observe(keys: keys, globalIPv4: globalIPv4) else { return }
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

/// Only the observed duplicate Global/IPv4 notification is suppressed. Link,
/// service and setup notifications retain their conservative cleanup behavior.
struct NetworkTopologyChangeTracker {
    static let globalIPv4Key = "State:/Network/Global/IPv4"
    private var previousGlobalIPv4: NSDictionary?
    private var pendingChange = false
    init(globalIPv4: NSDictionary?) { previousGlobalIPv4 = globalIPv4?.copy() as? NSDictionary }
    /// Returns whether this event should schedule/restart the debounce timer.
    mutating func observe(keys: [String], globalIPv4: NSDictionary?) -> Bool {
        let globalOnly = !keys.isEmpty && keys.allSatisfy { $0 == Self.globalIPv4Key }
        let unchanged = globalIPv4.map { previousGlobalIPv4?.isEqual($0) == true } ?? false
        previousGlobalIPv4 = globalIPv4?.copy() as? NSDictionary
        guard !globalOnly || !unchanged else { return false }
        pendingChange = true
        return true
    }
    mutating func takePendingChange() -> Bool {
        let result = pendingChange; pendingChange = false; return result
    }
}
