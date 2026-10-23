import XCTest
import Darwin
import RouteCore
@testable import RouteHelper

final class EngineCancellationTests: XCTestCase {
    private func request(_ routes: [String] = ["223.5.5.0/24", "223.6.6.0/24"]) -> ApplyRequest {
        ApplyRequest(routes: routes, gateway: "192.168.1.1", interface: "en0", exitNodeID: "exit-node")
    }
    private func assertCancelled(_ work: () throws -> Report, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) { XCTAssertTrue($0 is RecoveryCancelled, file: file, line: line) }
    }
    func testPrecancelledApplyDoesNotReadOrWriteState() {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        token.cancel()
        assertCancelled { try Engine(store: store, table: table).apply(request(), cancellation: token) }
        XCTAssertEqual(store.loads, 0); XCTAssertEqual(table.snapshots, 0)
        XCTAssertTrue(store.saves.isEmpty); XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(table.removes.isEmpty)
    }
    func testFirstPreflightCancellationPreventsCleanupAndWrites() throws {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        let old = cancellationRecord("223.7.7.0/24")
        store.value.records = [old]; table.routes = [try cancellationKernel(old)]
        let engine = Engine(store: store, table: table, cancellablePreflight: { _, _, cancellation in cancellation.cancel() })
        assertCancelled { try engine.apply(request(), cancellation: token) }
        XCTAssertTrue(store.saves.isEmpty); XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(table.removes.isEmpty)
    }
    func testSecondPreflightIsIndependentAndCancellationCannotAddRoutes() throws {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        let old = cancellationRecord("223.7.7.0/24")
        store.value.records = [old]; table.routes = [try cancellationKernel(old)]
        var checks = 0
        let engine = Engine(store: store, table: table, cancellablePreflight: { _, snapshot, cancellation in
            checks += 1
            if checks == 1 { XCTAssertEqual(snapshot.count, 1) }
            if checks == 2 { XCTAssertTrue(snapshot.isEmpty); cancellation.cancel() }
        })
        assertCancelled { try engine.apply(request(), cancellation: token) }
        XCTAssertEqual(checks, 2); XCTAssertEqual(table.removes.count, 1)
        XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(store.value.records.isEmpty)
    }
    func testCancellationDuringAddCommitsOnlyAttemptedRoutesAndRollbackRemovesThem() throws {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        table.afterAdd = { token.cancel() }
        let engine = Engine(store: store, table: table)
        assertCancelled { try engine.apply(request(), cancellation: token) }
        XCTAssertEqual(table.adds.count, 1)
        XCTAssertEqual(store.value.records.map(\.cidr), ["223.5.5.0/24"])
        XCTAssertTrue(store.value.records.allSatisfy(\.confirmed))
        XCTAssertEqual(try engine.rollback().removed, 1)
        XCTAssertTrue(table.routes.isEmpty); XCTAssertTrue(store.value.records.isEmpty)
    }
    func testCancellationAfterWALSaveNeverAddsAndDropsUnattemptedIntents() throws {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        store.afterSave = { if store.saves.count == 2 { token.cancel() } }
        let engine = Engine(store: store, table: table)
        assertCancelled { try engine.apply(request(), cancellation: token) }
        XCTAssertEqual(store.saves[1].records.count, 2)
        XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(store.value.records.isEmpty)
    }
    func testCancellationDuringRemovalPersistsUnremovedOwnershipForRollback() throws {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        let old = [cancellationRecord("223.7.7.0/24"), cancellationRecord("223.8.8.0/24")]
        store.value.records = old; table.routes = try old.map(cancellationKernel)
        table.afterRemove = { token.cancel() }
        var checks = 0
        let engine = Engine(store: store, table: table, cancellablePreflight: { _, _, _ in checks += 1 })
        assertCancelled { try engine.apply(request(), cancellation: token) }
        XCTAssertEqual(checks, 1); XCTAssertEqual(table.removes.count, 1)
        XCTAssertEqual(store.value.records.map(\.cidr), ["223.8.8.0/24"])
        XCTAssertTrue(table.adds.isEmpty)
        XCTAssertEqual(try engine.rollback().removed, 1)
        XCTAssertTrue(table.routes.isEmpty); XCTAssertTrue(store.value.records.isEmpty)
    }
    func testCancelledAddWithFailedVerificationLeavesFullRecoverableWAL() throws {
        let store = CancellationJournal(), table = CancellationTable(), token = RecoveryCancellation()
        table.afterAdd = { token.cancel(); table.failSnapshot = true }
        let engine = Engine(store: store, table: table)
        XCTAssertThrowsError(try engine.apply(request(), cancellation: token))
        XCTAssertEqual(table.adds.count, 1)
        XCTAssertEqual(store.value.records.count, 2)
        XCTAssertTrue(store.value.records.allSatisfy { !$0.confirmed })
        table.failSnapshot = false
        XCTAssertEqual(try engine.rollback().removed, 1)
        XCTAssertTrue(table.routes.isEmpty); XCTAssertTrue(store.value.records.isEmpty)
    }
}

private final class CancellationJournal: JournalStoring {
    var value = Journal(), saves: [Journal] = []
    var loads = 0
    var afterSave: (() -> Void)?
    func load() throws -> Journal { loads += 1; return value }
    func save(_ journal: Journal) throws { value = journal; saves.append(journal); afterSave?() }
}
private final class CancellationTable: RouteTableOperating {
    var routes: [ExistingRoute] = []
    var adds: [RouteRecord] = [], removes: [RouteRecord] = []
    var snapshots = 0, failSnapshot = false
    var afterAdd: (() -> Void)?, afterRemove: (() -> Void)?
    func readSnapshot() throws -> [ExistingRoute] {
        snapshots += 1
        if failSnapshot { throw HelperError("snapshot failed") }
        return routes
    }
    func add(_ record: RouteRecord) throws -> Int32 {
        adds.append(record); routes.append(try cancellationKernel(record)); afterAdd?(); return 0
    }
    func remove(_ record: RouteRecord) throws -> Int32 {
        removes.append(record); routes.removeAll { $0.belongs(to: record) }; afterRemove?(); return 0
    }
}
private func cancellationRecord(_ cidr: String) -> RouteRecord {
    RouteRecord(cidr: cidr, gateway: "192.168.1.1", interface: "en0", confirmed: true, markerVersion: 1)
}
private func cancellationKernel(_ record: RouteRecord) throws -> ExistingRoute {
    let cidr = try IPv4CIDR(record.cidr)
    return ExistingRoute(network: cidr.network, mask: cidrMask(cidr), gateway: IPv4CIDR.parseAddress(record.gateway), interface: record.interface,
                         index: 4, flags: UInt32(RTF_UP | RTF_GATEWAY | RTF_STATIC) | routeOwnershipFlags)
}
