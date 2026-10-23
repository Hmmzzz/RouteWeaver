import XCTest
import Darwin
import RouteCore
@testable import RouteHelper

final class SkippedRouteRecoveryTests: XCTestCase {
    private let first = "223.5.5.0/24"
    private let second = "114.114.114.0/24"
    private let third = "223.6.6.0/24"

    func testHealthChecksDesiredAndOwnedRoutesFromOneReadOnlySnapshot() throws {
        let fixture = SkippedRouteFixture()
        let changed = "36.0.0.0/24"
        fixture.journal.value = Journal(records: [fixture.record(first), fixture.record(changed)])
        fixture.table.routes = [try fixture.route(first), try fixture.route(second, marked: false),
                                try fixture.route(changed, gateway: "192.168.1.2")]

        let health = try fixture.engine.inspectHealth(desiredRoutes: [first, second, third, changed, second])

        XCTAssertEqual(health.report.active, 1)
        XCTAssertEqual(health.report.pending, 1)
        XCTAssertEqual(health.report.skipped, 1)
        XCTAssertTrue(health.report.verified)
        XCTAssertFalse(health.hasMissingOwnedRoutes)
        XCTAssertTrue(health.hasMissingDesiredRoutes)
        XCTAssertTrue(health.needsRepair)
        XCTAssertEqual(fixture.journal.loads, 1)
        XCTAssertEqual(fixture.table.snapshots, 1)
        XCTAssertEqual(fixture.journal.saves, 0)
        XCTAssertTrue(fixture.table.additions.isEmpty)
        XCTAssertTrue(fixture.table.removals.isEmpty)
    }

    func testPersistentForeignPrefixesStaySkippedWithoutMutationOrAdoption() throws {
        let fixture = SkippedRouteFixture()
        fixture.table.routes = [try fixture.route(second, marked: false)]
        let coordinator = try fixture.coordinator()
        try fixture.activate(coordinator, routes: [first, second])
        let saves = fixture.journal.saves, writes = fixture.policy.writes

        for _ in 0..<3 { coordinator.refresh() }
        _ = try coordinator.apply(routes: [first, second])
        coordinator.refresh()

        XCTAssertEqual(coordinator.status().report.active, 1)
        XCTAssertEqual(coordinator.status().report.skipped, 1)
        XCTAssertEqual(fixture.table.additions.map(\.cidr), [first])
        XCTAssertTrue(fixture.table.removals.isEmpty)
        XCTAssertEqual(fixture.journal.value.records.map(\.cidr), [first])
        XCTAssertEqual(fixture.journal.saves, saves)
        XCTAssertEqual(fixture.policy.writes, writes)
        XCTAssertTrue(fixture.lastPublishedRoutes.isEmpty)
        _ = try coordinator.stop()
        XCTAssertEqual(fixture.table.removals.map(\.cidr), [first])
        XCTAssertEqual(fixture.table.routes.count, 1)
        XCTAssertEqual(fixture.table.routes.first?.network, try IPv4CIDR(second).network)
    }

    func testPartialThenCompleteConflictRemovalRepairsOnlyVacatedPrefixesAndRestoresDNSPlan() throws {
        let fixture = SkippedRouteFixture()
        let desired = [first, second, third].sorted()
        fixture.table.routes = [try fixture.route(second, marked: false), try fixture.route(third, marked: false)]
        let coordinator = try fixture.coordinator()
        try fixture.activate(coordinator, routes: desired)
        XCTAssertEqual(coordinator.status().report.active, 1)
        XCTAssertEqual(coordinator.status().report.skipped, 2)
        XCTAssertTrue(fixture.lastPublishedRoutes.isEmpty)

        try fixture.table.removeExternally(second)
        coordinator.refresh()
        XCTAssertEqual(coordinator.status().phase, .active)
        XCTAssertEqual(coordinator.status().report.active, 2)
        XCTAssertEqual(coordinator.status().report.skipped, 1)
        XCTAssertEqual(Set(fixture.table.additions.map(\.cidr)), Set([first, second]))
        XCTAssertTrue(fixture.table.removals.isEmpty)
        XCTAssertTrue(fixture.lastPublishedRoutes.isEmpty)
        coordinator.refresh()
        XCTAssertEqual(coordinator.status().report.skipped, 1)
        XCTAssertEqual(fixture.table.additions.count, 2)

        try fixture.table.removeExternally(third)
        coordinator.refresh()
        let repaired = coordinator.status()
        XCTAssertEqual(repaired.phase, .active)
        XCTAssertEqual(repaired.report.active, 3)
        XCTAssertEqual(repaired.report.skipped, 0)
        XCTAssertEqual(repaired.report.pending, 0)
        XCTAssertEqual(repaired.report.failed, 0)
        XCTAssertTrue(repaired.report.verified)
        XCTAssertEqual(fixture.table.additions.count, 3)
        XCTAssertTrue(fixture.table.removals.isEmpty)
        XCTAssertEqual(fixture.lastPublishedRoutes, desired)
        XCTAssertEqual(fixture.policy.writes, 1)
    }

    func testIdenticalApplyRepairsWhenEveryPreviouslySkippedPrefixDisappears() throws {
        let fixture = SkippedRouteFixture()
        let desired = [first, second].sorted()
        fixture.table.routes = try desired.map { try fixture.route($0, marked: false) }
        let coordinator = try fixture.coordinator(automaticScheduling: true)
        try fixture.activate(coordinator, routes: desired)
        XCTAssertEqual(coordinator.status().report.active, 0)
        XCTAssertEqual(coordinator.status().report.skipped, 2)
        XCTAssertTrue(fixture.journal.value.records.isEmpty)
        fixture.table.routes = []

        _ = try coordinator.apply(routes: desired)
        // No explicit refresh or topology event: identical apply must schedule
        // its own full-plan health check in the live coordinator configuration.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while coordinator.status().report.active != 2 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(coordinator.status().report.active, 2)
        coordinator.refresh()
        XCTAssertEqual(coordinator.status().report.skipped, 0)
        XCTAssertEqual(fixture.table.additions.count, 2)
        XCTAssertTrue(fixture.table.removals.isEmpty)
        XCTAssertEqual(fixture.lastPublishedRoutes, desired)
        XCTAssertEqual(fixture.policy.writes, 1)
    }

    func testOwnedRouteLossStillRepairsWithoutTouchingAnExistingForeignPrefix() throws {
        let fixture = SkippedRouteFixture()
        fixture.table.routes = [try fixture.route(second, marked: false)]
        let coordinator = try fixture.coordinator()
        try fixture.activate(coordinator, routes: [first, second])
        try fixture.table.removeExternally(first)

        let health = try fixture.engine.inspectHealth(desiredRoutes: [first, second])
        XCTAssertTrue(health.hasMissingOwnedRoutes)
        XCTAssertTrue(health.hasMissingDesiredRoutes)
        coordinator.refresh()

        XCTAssertEqual(coordinator.status().report.active, 1)
        XCTAssertEqual(coordinator.status().report.skipped, 1)
        XCTAssertEqual(fixture.table.additions.map(\.cidr), [first, first])
        XCTAssertTrue(fixture.table.removals.isEmpty)
        XCTAssertEqual(fixture.journal.value.records.map(\.cidr), [first])
        XCTAssertTrue(fixture.lastPublishedRoutes.isEmpty)
    }

    func testHealthUsesCompiledPlanInsteadOfReintroducingExcludedInputPrefixes() throws {
        let fixture = SkippedRouteFixture()
        fixture.table.routes = [try fixture.route(first, marked: false)]
        let coordinator = try fixture.coordinator(compiledRoutes: [first])
        try fixture.activate(coordinator, routes: [first, second])
        let saves = fixture.journal.saves
        for _ in 0..<3 { coordinator.refresh() }
        XCTAssertEqual(fixture.compilations, 1)
        XCTAssertEqual(fixture.journal.saves, saves)
        XCTAssertEqual(coordinator.status().report.skipped, 1)

        try fixture.table.removeExternally(first)
        coordinator.refresh()

        XCTAssertEqual(fixture.compilations, 2)
        XCTAssertEqual(coordinator.status().report.active, 1)
        XCTAssertEqual(coordinator.status().report.skipped, 0)
        XCTAssertEqual(fixture.table.additions.map(\.cidr), [first])
        XCTAssertEqual(fixture.lastPublishedRoutes, [first])
    }

    func testNetworkChangeCleansOldOwnershipBeforeRepairingVacatedForeignPrefix() throws {
        let fixture = SkippedRouteFixture()
        fixture.table.routes = [try fixture.route(second, marked: false)]
        let coordinator = try fixture.coordinator()
        try fixture.activate(coordinator, routes: [first, second])
        try fixture.table.removeExternally(second)
        fixture.network = NetworkContext(gateway: "192.168.2.1", interface: "en1", exitNodeID: "exit-b",
                                         exitNodeName: "B", tailscaleInterfaces: ["utun9"])

        coordinator.refresh()
        XCTAssertEqual(fixture.table.additions.count, 1)
        XCTAssertEqual(fixture.table.removals.map(\.cidr), [first])
        XCTAssertEqual(coordinator.status().report.active, 0)
        XCTAssertEqual(coordinator.status().phase, .stabilizing)
        XCTAssertTrue(fixture.lastPublishedRoutes.isEmpty)
        fixture.advanceTime(2)
        coordinator.refresh()

        XCTAssertEqual(coordinator.status().report.active, 2)
        XCTAssertEqual(coordinator.status().report.skipped, 0)
        XCTAssertEqual(Set(fixture.table.additions.suffix(2).map(\.gateway)), ["192.168.2.1"])
        XCTAssertEqual(fixture.lastPublishedRoutes, [first, second].sorted())
    }
}

private final class SkippedRouteFixture {
    let journal = SkippedRouteJournal(), table = SkippedRouteTable(), policy = SkippedRoutePolicy()
    lazy var engine = Engine(store: journal, table: table)
    private let lock = NSLock()
    private var currentTime: TimeInterval = 100
    private var currentNetwork = NetworkContext(gateway: "192.168.1.1", interface: "en0", exitNodeID: "exit-a",
                                                exitNodeName: "A", tailscaleInterfaces: ["utun7"])
    private var publishedRoutes: [String] = []
    private var compilationCount = 0
    var network: NetworkContext {
        get { lock.withLock { currentNetwork } }
        set { lock.withLock { currentNetwork = newValue } }
    }
    var lastPublishedRoutes: [String] { lock.withLock { publishedRoutes } }
    var compilations: Int { lock.withLock { compilationCount } }
    func advanceTime(_ seconds: TimeInterval) { lock.withLock { currentTime += seconds } }
    func coordinator(automaticScheduling: Bool = false, compiledRoutes: [String]? = nil) throws -> RecoveryCoordinator {
        try RecoveryCoordinator(ownerUID: 501, engine: engine, store: policy, discover: { self.network },
            monotonicTime: { self.lock.withLock { self.currentTime } }, automaticScheduling: automaticScheduling,
            compileRoutes: { routes, _ in
                self.lock.withLock { self.compilationCount += 1 }
                return compiledRoutes ?? routes
            }, networkRoutingStateChanged: { _, routes in self.lock.withLock { self.publishedRoutes = routes } })
    }
    func activate(_ coordinator: RecoveryCoordinator, routes: [String]) throws {
        _ = try coordinator.apply(routes: routes)
        coordinator.refresh(); advanceTime(2); coordinator.refresh()
        XCTAssertEqual(coordinator.status().phase, .active)
    }
    func record(_ cidr: String) -> RouteRecord {
        RouteRecord(cidr: cidr, gateway: "192.168.1.1", interface: "en0", confirmed: true)
    }
    func route(_ text: String, marked: Bool = true, gateway: String = "192.168.1.1") throws -> ExistingRoute {
        try SkippedRouteTable.kernel(RouteRecord(cidr: text, gateway: gateway, interface: "en0", confirmed: true), marked: marked)
    }
}

private final class SkippedRouteJournal: JournalStoring {
    private let lock = NSLock()
    private var journal = Journal()
    private var loadCount = 0, saveCount = 0
    var value: Journal {
        get { lock.withLock { journal } }
        set { lock.withLock { journal = newValue } }
    }
    var loads: Int { lock.withLock { loadCount } }
    var saves: Int { lock.withLock { saveCount } }
    func load() throws -> Journal { lock.withLock { loadCount += 1; return journal } }
    func save(_ value: Journal) throws { lock.withLock { saveCount += 1; journal = value } }
}

private final class SkippedRoutePolicy: PolicyStoring {
    private let lock = NSLock()
    private var policy = DesiredPolicy()
    private var writeCount = 0
    var writes: Int { lock.withLock { writeCount } }
    func load() throws -> DesiredPolicy { lock.withLock { policy } }
    func save(_ value: DesiredPolicy) throws { lock.withLock { writeCount += 1; policy = value } }
}

private final class SkippedRouteTable: RouteTableOperating {
    private let lock = NSLock()
    private var entries: [ExistingRoute] = []
    private var added: [RouteRecord] = [], removed: [RouteRecord] = []
    private var snapshotCount = 0
    var routes: [ExistingRoute] {
        get { lock.withLock { entries } }
        set { lock.withLock { entries = newValue } }
    }
    var additions: [RouteRecord] { lock.withLock { added } }
    var removals: [RouteRecord] { lock.withLock { removed } }
    var snapshots: Int { lock.withLock { snapshotCount } }
    func readSnapshot() throws -> [ExistingRoute] { lock.withLock { snapshotCount += 1; return entries } }
    func add(_ record: RouteRecord) throws -> Int32 {
        let route = try Self.kernel(record)
        return lock.withLock {
            added.append(record)
            guard !entries.contains(where: { $0.network == route.network && $0.mask == route.mask }) else { return EEXIST }
            entries.append(route); return 0
        }
    }
    func remove(_ record: RouteRecord) throws -> Int32 {
        lock.withLock { removed.append(record); entries.removeAll { $0.belongs(to: record) } }
        return 0
    }
    func removeExternally(_ text: String) throws {
        let cidr = try IPv4CIDR(text)
        lock.withLock { entries.removeAll { $0.matches(cidr) } }
    }
    static func kernel(_ record: RouteRecord, marked: Bool = true) throws -> ExistingRoute {
        let cidr = try IPv4CIDR(record.cidr)
        return ExistingRoute(network: cidr.network, mask: cidrMask(cidr), gateway: IPv4CIDR.parseAddress(record.gateway),
                             interface: record.interface, index: 4,
                             flags: UInt32(RTF_UP | RTF_STATIC | RTF_GATEWAY) | (marked ? routeOwnershipFlags : 0))
    }
}
