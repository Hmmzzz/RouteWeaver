import XCTest
@testable import RouteWeaver

/// These lifecycle tests stay on the main actor without suspending until stop().
/// The queued sampler is cancelled before it can run: no network or IPC is used.
final class TrafficMonitorDemandTests: XCTestCase {
    /// UserDefaults keeps empty suite plists even after removing their domain.
    /// Keep these isolated lifecycle tests entirely in memory.
    private final class MemoryDefaults: UserDefaults {
        private var values: [String: Any] = [:]
        override func object(forKey defaultName: String) -> Any? { values[defaultName] }
        override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
        override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    }

    @MainActor
    private func withMonitor(menuRates: Bool? = nil, _ check: (TrafficMonitor, AppStore, UserDefaults) throws -> Void) throws {
        let defaults = MemoryDefaults()
        if let menuRates { defaults.set(menuRates, forKey: "trafficMonitoringEnabled") }
        let monitor = TrafficMonitor(defaults: defaults)
        let store = AppStore(loadPersistedState: false)
        defer {
            monitor.stop()
        }
        try check(monitor, store, defaults)
    }

    @MainActor
    func testOpeningPanelSamplesEvenWhenMenuBarRatesAreHidden() throws {
        try withMonitor(menuRates: false) { monitor, store, defaults in
            monitor.start(store: store)
            XCTAssertFalse(monitor.isSampling)
            monitor.setPopoverVisible(true)
            XCTAssertTrue(monitor.isSampling)
            XCTAssertFalse(monitor.showsMenuBarRates)
            XCTAssertFalse(defaults.bool(forKey: "trafficMonitoringEnabled"))
            monitor.setPopoverVisible(false)
            XCTAssertFalse(monitor.isSampling)
            monitor.setPopoverVisible(true)
            XCTAssertTrue(monitor.isSampling)
            XCTAssertFalse(monitor.showsMenuBarRates)
        }
    }

    @MainActor
    func testHidingMenuBarRatesDoesNotClearOpenPanelOrStopItsSampler() throws {
        try withMonitor(menuRates: true) { monitor, store, defaults in
            monitor.start(store: store)
            monitor.setPopoverVisible(true)
            let directBefore = monitor.direct
            let tunnelBefore = monitor.tailscale
            monitor.setShowsMenuBarRates(false)
            XCTAssertTrue(monitor.isSampling)
            XCTAssertFalse(monitor.showsMenuBarRates)
            XCTAssertEqual(monitor.direct.detail, directBefore.detail)
            XCTAssertEqual(monitor.tailscale.detail, tunnelBefore.detail)
            XCTAssertFalse(defaults.bool(forKey: "trafficMonitoringEnabled"))
            monitor.setPopoverVisible(false)
            XCTAssertFalse(monitor.isSampling)
        }
    }

    @MainActor
    func testClosingPanelKeepsSamplingForVisibleMenuBarRates() throws {
        try withMonitor(menuRates: false) { monitor, store, _ in
            monitor.start(store: store)
            monitor.setPopoverVisible(true)
            monitor.setShowsMenuBarRates(true)
            monitor.setPopoverVisible(false)
            XCTAssertTrue(monitor.isSampling)
            XCTAssertTrue(monitor.showsMenuBarRates)
            monitor.setShowsMenuBarRates(false)
            XCTAssertFalse(monitor.isSampling)
        }
    }

    @MainActor
    func testPanelCanAppearBeforeMainWindowStartsTheMonitor() throws {
        try withMonitor(menuRates: false) { monitor, store, _ in
            monitor.setPopoverVisible(true)
            XCTAssertFalse(monitor.isSampling)
            monitor.start(store: store)
            XCTAssertTrue(monitor.isSampling)
        }
    }

    @MainActor
    func testStopCannotBeUndoneByLateViewLifecycleOrPreferenceCallbacks() throws {
        try withMonitor(menuRates: false) { monitor, store, _ in
            monitor.start(store: store)
            monitor.setPopoverVisible(true)
            monitor.stop()
            XCTAssertFalse(monitor.isSampling)
            monitor.setPopoverVisible(false)
            monitor.setShowsMenuBarRates(true)
            monitor.setPopoverVisible(true)
            XCTAssertFalse(monitor.isSampling)
            // Only a deliberate start may attach a store and restart the loop.
            monitor.start(store: store)
            XCTAssertTrue(monitor.isSampling)
        }
    }

    @MainActor
    func testDefaultAndPersistedDisplayChoiceRemainCompatible() throws {
        try withMonitor { monitor, _, defaults in
            XCTAssertTrue(monitor.showsMenuBarRates)
            monitor.setShowsMenuBarRates(false)
            let reopened = TrafficMonitor(defaults: defaults)
            XCTAssertFalse(reopened.showsMenuBarRates)
            XCTAssertFalse(reopened.isSampling)
            reopened.setPopoverVisible(true)
            XCTAssertFalse(defaults.bool(forKey: "trafficMonitoringEnabled"))
            reopened.stop()
        }
    }
}
