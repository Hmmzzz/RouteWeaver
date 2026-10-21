import XCTest
import Darwin
import RouteCore
@testable import RouteHelper

private final class MemoryJournal: JournalStoring {
    var value = Journal()
    var saves: [Journal] = []
    var loads = 0
    var failSaveNumber: Int?
    func load() throws -> Journal { loads += 1; return value }
    func save(_ journal: Journal) throws {
        if saves.count + 1 == failSaveNumber { throw HelperError("disk full") }
        saves.append(journal); value = journal
    }
}
private final class MemoryTable: RouteTableOperating {
    var routes: [ExistingRoute] = []
    var adds: [RouteRecord] = [], deletes: [RouteRecord] = []
    var addErrors: [String: Int32] = [:], deleteErrors: [String: Int32] = [:]
    var throwAdd: Set<String> = [], throwAfterAdd: Set<String> = []
    var throwDelete: Set<String> = []
    var pretendAdd = false, pretendDelete = false
    var errnoAfterAdd: Int32?
    var snapshotCount = 0, failSnapshotNumber: Int?
    var beforeAdd: ((RouteRecord) -> Void)?
    func readSnapshot() throws -> [ExistingRoute] {
        snapshotCount += 1
        if snapshotCount == failSnapshotNumber { throw HelperError("snapshot failed") }
        return routes
    }
    func add(_ record: RouteRecord) throws -> Int32 {
        adds.append(record); beforeAdd?(record)
        if throwAdd.contains(record.cidr) { throw HelperError("interface vanished") }
        if let error = addErrors[record.cidr] { return error }
        if !pretendAdd { routes.append(try kernel(record)) }
        if throwAfterAdd.contains(record.cidr) { throw HelperError("interrupted after write") }
        return errnoAfterAdd ?? 0
    }
    func remove(_ record: RouteRecord) throws -> Int32 {
        deletes.append(record)
        if throwDelete.contains(record.cidr) { throw HelperError("delete interrupted") }
        if let error = deleteErrors[record.cidr] { return error }
        if !pretendDelete { routes.removeAll { $0.belongs(to: record) } }
        return 0
    }
}
private func makeRecord(_ cidr: String = "223.5.5.0/24", confirmed: Bool = true, marker: Int = 1, gateway: String = "192.168.1.1") -> RouteRecord {
    RouteRecord(cidr: cidr, gateway: gateway, interface: "en0", confirmed: confirmed, markerVersion: marker)
}
private func kernel(_ record: RouteRecord, marked: Bool = true) throws -> ExistingRoute {
    let cidr = try IPv4CIDR(record.cidr)
    return ExistingRoute(network: cidr.network, mask: cidrMask(cidr), gateway: IPv4CIDR.parseAddress(record.gateway), interface: record.interface, index: 4,
                         flags: UInt32(RTF_UP | RTF_GATEWAY | RTF_STATIC) | (marked ? routeOwnershipFlags : 0))
}
private func request(_ routes: [String] = ["223.5.5.0/24"], gateway: String = "192.168.1.1") -> ApplyRequest {
    ApplyRequest(routes: routes, gateway: gateway, interface: "en0", exitNodeID: "exit-node")
}
final class EngineTests: XCTestCase {
    func testHealthInspectionSharesOneJournalReadAndKernelSnapshot() throws {
        let store = MemoryJournal(), table = MemoryTable()
        store.value.records = [makeRecord()]; table.routes = [try kernel(makeRecord())]
        let health = try Engine(store: store, table: table).inspectHealth()
        XCTAssertEqual(store.loads, 1)
        XCTAssertEqual(table.snapshotCount, 1)
        XCTAssertEqual(health.report.active, 1)
        XCTAssertEqual(health.report.pending, 0)
        XCTAssertTrue(health.report.verified)
        XCTAssertFalse(health.hasMissingOwnedRoutes)
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(table.deletes.isEmpty)
    }
    func testHealthInspectionDistinguishesMissingRoutesFromOwnershipChanges() throws {
        let store = MemoryJournal(), table = MemoryTable()
        let absent = makeRecord(), changed = makeRecord("223.6.6.0/24")
        store.value.records = [absent, changed]
        table.routes = [try kernel(makeRecord("223.6.6.0/24", gateway: "192.168.1.2"))]
        let engine = Engine(store: store, table: table)
        let missing = try engine.inspectHealth()
        XCTAssertTrue(missing.hasMissingOwnedRoutes)
        XCTAssertEqual(missing.report.active, 0); XCTAssertEqual(missing.report.pending, 2)
        table.routes.append(try kernel(absent))
        let conflict = try engine.inspectHealth()
        XCTAssertFalse(conflict.hasMissingOwnedRoutes)
        XCTAssertEqual(conflict.report.active, 1); XCTAssertEqual(conflict.report.pending, 1)
        XCTAssertTrue(conflict.report.verified)
        XCTAssertEqual(store.loads, 2); XCTAssertEqual(table.snapshotCount, 2)
        XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(table.deletes.isEmpty)
    }
    func testScopedRouteCannotCountAsGlobalActiveOrBeDeletedAsOwned() throws {
        let store = MemoryJournal(), table = MemoryTable()
        store.value.records = [makeRecord()]
        let original = try kernel(makeRecord())
        table.routes = [ExistingRoute(network: original.network, mask: original.mask, gateway: original.gateway, interface: original.interface, index: original.index, flags: original.flags | UInt32(RTF_IFSCOPE))]
        let engine = Engine(store: store, table: table)
        let health = try engine.inspectHealth()
        XCTAssertEqual(health.report.active, 0); XCTAssertEqual(health.report.pending, 1)
        XCTAssertFalse(health.hasMissingOwnedRoutes)
        let rollback = try engine.rollback()
        XCTAssertEqual(rollback.failed, 1); XCTAssertEqual(rollback.pending, 1)
        XCTAssertTrue(table.deletes.isEmpty)
        XCTAssertEqual(store.value.records.count, 1)
    }
    func testWriteAheadIntentsPrecedeEveryMutation() throws {
        let store = MemoryJournal(), table = MemoryTable()
        table.beforeAdd = { row in XCTAssertTrue(store.value.records.contains { $0.cidr == row.cidr && !$0.confirmed }) }
        let result = try Engine(store: store, table: table).apply(request())
        XCTAssertEqual(result.added, 1); XCTAssertEqual(result.active, 1); XCTAssertTrue(result.verified)
        XCTAssertTrue(store.value.records.allSatisfy(\.confirmed))
    }
    func testPreflightFailurePerformsNoMutationOrSave() {
        let store = MemoryJournal(), table = MemoryTable()
        let engine = Engine(store: store, table: table, preflight: { _, _ in throw HelperError("disconnected") })
        XCTAssertThrowsError(try engine.apply(request()))
        XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(store.saves.isEmpty)
    }
    func testUnsafeRequestIsRejectedBeforeSnapshot() {
        let store = MemoryJournal(), table = MemoryTable()
        XCTAssertThrowsError(try Engine(store: store, table: table).apply(request(["0.0.0.0/0"])))
        XCTAssertEqual(table.snapshotCount, 0)
    }
    func testWriteAheadSaveFailurePreventsAdd() {
        let store = MemoryJournal(), table = MemoryTable(); store.failSaveNumber = 2
        XCTAssertThrowsError(try Engine(store: store, table: table).apply(request()))
        XCTAssertTrue(table.adds.isEmpty)
    }
    func testCommitFailureLeavesRecoverableMarkedIntent() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.failSaveNumber = 3
        let engine = Engine(store: store, table: table)
        XCTAssertThrowsError(try engine.apply(request()))
        XCTAssertEqual(store.value.records.count, 1); XCTAssertFalse(store.value.records[0].confirmed)
        store.failSaveNumber = nil
        XCTAssertEqual(try engine.rollback().removed, 1); XCTAssertTrue(table.routes.isEmpty)
    }
    func testAddThrowDoesNotLoseOtherSuccesses() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.throwAdd = ["223.5.5.0/24"]
        let result = try Engine(store: store, table: table).apply(request(["223.5.5.0/24", "223.6.6.0/24"]))
        XCTAssertEqual(result.failed, 1); XCTAssertEqual(result.added, 1); XCTAssertEqual(result.active, 1)
        XCTAssertEqual(store.value.records.map(\.cidr), ["223.6.6.0/24"])
    }
    func testThrowAfterKernelAddIsRecoveredFromSnapshot() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.throwAfterAdd = ["223.5.5.0/24"]
        let result = try Engine(store: store, table: table).apply(request())
        XCTAssertEqual(result.failed, 1); XCTAssertEqual(result.active, 1)
        XCTAssertTrue(store.value.records[0].confirmed)
    }
    func testErrnoAfterKernelMutationKeepsOwnedRouteRecoverable() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.errnoAfterAdd = ENOBUFS
        let engine = Engine(store: store, table: table)
        let result = try engine.apply(request())
        XCTAssertEqual(result.failed, 1); XCTAssertEqual(result.active, 1)
        XCTAssertEqual(store.value.records.count, 1)
        XCTAssertEqual(try engine.rollback().removed, 1)
    }
    func testErrnoFailureDropsUncreatedIntent() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.addErrors["223.5.5.0/24"] = ENETUNREACH
        let result = try Engine(store: store, table: table).apply(request())
        XCTAssertEqual(result.failed, 1); XCTAssertTrue(store.value.records.isEmpty)
    }
    func testFalseAddSuccessFailsVerification() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.pretendAdd = true
        let result = try Engine(store: store, table: table).apply(request())
        XCTAssertEqual(result.failed, 1); XCTAssertEqual(result.active, 0); XCTAssertEqual(result.added, 0)
    }
    func testExistingForeignRouteIsNeverAdoptedOrOverwritten() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.routes = [try kernel(makeRecord(), marked: false)]
        let result = try Engine(store: store, table: table).apply(request())
        XCTAssertEqual(result.skipped, 1); XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(store.value.records.isEmpty)
    }
    func testMarkedUnconfirmedCrashIntentIsRecoveredWithoutAdd() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord(confirmed: false)]
        table.routes = [try kernel(makeRecord())]
        let result = try Engine(store: store, table: table).apply(request())
        XCTAssertEqual(result.active, 1); XCTAssertTrue(table.adds.isEmpty); XCTAssertTrue(store.value.records[0].confirmed)
    }
    func testLegacyUnconfirmedIntentIsNotDeleted() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value = Journal(version: 1, records: [makeRecord(confirmed: false, marker: 0)])
        table.routes = [try kernel(makeRecord(), marked: false)]
        let result = try Engine(store: store, table: table).rollback()
        XCTAssertEqual(result.failed, 1); XCTAssertTrue(table.deletes.isEmpty); XCTAssertEqual(result.pending, 1)
    }
    func testModifiedGatewayIsNotDeleted() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        table.routes = [try kernel(makeRecord(gateway: "192.168.1.2"))]
        let result = try Engine(store: store, table: table).rollback()
        XCTAssertEqual(result.failed, 1); XCTAssertTrue(table.deletes.isEmpty); XCTAssertEqual(store.value.records.count, 1)
    }
    func testMissingMarkerIsNotDeletedEvenWithSameGateway() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        table.routes = [try kernel(makeRecord(), marked: false)]
        XCTAssertEqual(try Engine(store: store, table: table).rollback().failed, 1)
        XCTAssertTrue(table.deletes.isEmpty)
    }
    func testAmbiguousDuplicateKernelRoutesAreNotDeleted() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        table.routes = [try kernel(makeRecord()), try kernel(makeRecord())]
        XCTAssertEqual(try Engine(store: store, table: table).rollback().failed, 1)
        XCTAssertTrue(table.deletes.isEmpty)
    }
    func testDeleteFailureRetainsJournalAndBlocksReplacement() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        table.routes = [try kernel(makeRecord())]; table.deleteErrors["223.5.5.0/24"] = EACCES
        let result = try Engine(store: store, table: table).apply(request(gateway: "192.168.1.2"))
        XCTAssertEqual(result.failed, 1); XCTAssertTrue(table.adds.isEmpty); XCTAssertEqual(store.value.records.count, 1)
    }
    func testFalseDeleteSuccessRetainsJournal() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        table.routes = [try kernel(makeRecord())]; table.pretendDelete = true
        let result = try Engine(store: store, table: table).rollback()
        XCTAssertEqual(result.failed, 1); XCTAssertEqual(result.removed, 0); XCTAssertEqual(store.value.records.count, 1)
    }
    func testMissingRouteClearsStaleJournalOnRollback() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        XCTAssertEqual(try Engine(store: store, table: table).rollback().pending, 0)
        XCTAssertTrue(store.value.records.isEmpty); XCTAssertTrue(table.deletes.isEmpty)
    }
    func testStatusReflectsKernelLossAndHealthDetectsMissing() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        let engine = Engine(store: store, table: table)
        XCTAssertEqual(try engine.status().active, 0); XCTAssertTrue(try engine.hasMissingOwnedRoutes())
        table.routes = [try kernel(makeRecord(gateway: "192.168.1.2"))]
        XCTAssertFalse(try engine.hasMissingOwnedRoutes())
    }
    func testStatusDoesNotCountDownOrRejectRouteAsActive() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord()]
        let original = try kernel(makeRecord())
        table.routes = [ExistingRoute(network: original.network, mask: original.mask, gateway: original.gateway, interface: original.interface, index: original.index, flags: original.flags | UInt32(RTF_REJECT))]
        let result = try Engine(store: store, table: table).status()
        XCTAssertEqual(result.active, 0); XCTAssertEqual(result.pending, 1)
    }
    func testInvalidDuplicateJournalFailsBeforeMutation() throws {
        let store = MemoryJournal(), table = MemoryTable(); store.value.records = [makeRecord(), makeRecord()]
        XCTAssertThrowsError(try Engine(store: store, table: table).rollback())
        XCTAssertTrue(table.deletes.isEmpty); XCTAssertTrue(store.saves.isEmpty)
    }
    func testSnapshotFailureAfterAddPreservesWriteAheadRecord() throws {
        let store = MemoryJournal(), table = MemoryTable(); table.failSnapshotNumber = 3
        XCTAssertThrowsError(try Engine(store: store, table: table).apply(request()))
        XCTAssertEqual(store.value.records.count, 1); XCTAssertFalse(store.value.records[0].confirmed)
    }
    func testJournalV1DecodesWithoutMarker() throws {
        let data = Data(#"{"version":1,"records":[{"cidr":"223.5.5.0/24","gateway":"192.168.1.1","interface":"en0","confirmed":true}]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Journal.self, from: data).records[0].markerVersion, 0)
    }
    func testBatchUsesConstantSnapshotAndJournalWriteCounts() throws {
        let store = MemoryJournal(), table = MemoryTable()
        let rows = (0..<2000).map { "36.\($0 / 256).\($0 % 256).0/24" }
        let result = try Engine(store: store, table: table).apply(request(rows))
        XCTAssertEqual(result.active, 2000); XCTAssertEqual(table.snapshotCount, 3); XCTAssertEqual(store.saves.count, 3)
        XCTAssertEqual(result.details.count, 512); XCTAssertEqual(result.detailsOmitted, 1488)
        XCTAssertLessThan(try JSONEncoder().encode(result).count, 1_048_576)
    }
}
