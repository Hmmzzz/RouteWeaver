import Foundation
import XCTest
import RouteCore
@testable import RouteWeaver

final class RulesArchiveTests: XCTestCase {
    @MainActor
    private func emptyStore() -> AppStore {
        let store = AppStore(loadPersistedState: false)
        store.countryEnabled = false
        store.rebuildPlan()
        return store
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("routeweaver-archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    @MainActor
    func testTwentyThousandRulesRoundTripThroughTheFileImporterReader() throws {
        let original = emptyStore()
        let text = (0..<20_000).map { "223.5.\($0 / 256).\($0 % 256)/32" }.joined(separator: "\n")
        try original.importRules(text: text)
        XCTAssertEqual(original.rules.count, 20_000)
        let exported = try original.exportRules()
        XCTAssertGreaterThan(exported.utf8.count, 2 * 1024 * 1024, "Exercise the former export/import mismatch")
        XCTAssertLessThanOrEqual(exported.utf8.count, RulesArchive.maximumBytes)
        try withDirectory { directory in
            let file = directory.appendingPathComponent("rules.json")
            try Data(exported.utf8).write(to: file)
            let restored = emptyStore()
            try restored.importRules(text: RulesArchive.readText(at: file))
            XCTAssertEqual(restored.rules.map(\.cidr), original.rules.map(\.cidr))
            XCTAssertEqual(restored.plannedRoutes, original.plannedRoutes)
            XCTAssertEqual(restored.rules.map(\.action), original.rules.map(\.action))
        }
    }

    @MainActor
    func testLongUnicodeAndEscapedNotesRoundTripWithoutLoss() throws {
        let note = String(repeating: "备注🙂\n\"\\", count: 250_000)
        let original = emptyStore()
        try original.addRule(cidr: "223.5.5.5/32", action: .direct, note: note)
        original.toggleRule(id: try XCTUnwrap(original.rules.first?.id))
        let restored = emptyStore()
        try restored.importRules(text: original.exportRules())
        XCTAssertEqual(restored.rules.first?.note, note)
        XCTAssertEqual(restored.rules.first?.enabled, false)
        XCTAssertEqual(restored.rules.first?.cidr, "223.5.5.5/32")
        XCTAssertEqual(restored.rules.first?.action, .direct)
    }

    @MainActor
    func testShorterTextWhoseJSONExpansionExceedsBudgetIsRejectedAtomically() throws {
        let store = emptyStore()
        try store.addRule(cidr: "223.6.6.6/32", action: .direct, note: "keep")
        let before = store.rules
        let events = store.events.count
        let text = "223.5.5.5/32 # " + String(repeating: "\"", count: RulesArchive.maximumBytes / 2)
        XCTAssertLessThan(text.utf8.count, RulesArchive.maximumBytes)
        XCTAssertThrowsError(try store.importRules(text: text))
        XCTAssertEqual(store.rules, before)
        XCTAssertEqual(store.events.count, events)
        XCTAssertEqual(store.plannedRoutes, ["223.6.6.6/32"])
    }

    @MainActor
    func testMergedImportsCannotExceedTheCombinedBackupBudget() throws {
        let store = emptyStore()
        let note = String(repeating: "a", count: RulesArchive.maximumBytes / 2)
        try store.addRule(cidr: "223.5.5.5/32", action: .direct, note: note)
        let incoming = [RouteRule(cidr: "223.6.6.6/32", action: .direct, note: note)]
        let text = String(decoding: try RulesArchive.encode(incoming), as: UTF8.self)
        XCTAssertLessThan(text.utf8.count, RulesArchive.maximumBytes)
        XCTAssertThrowsError(try store.importRules(text: text))
        XCTAssertEqual(store.rules.count, 1)
        XCTAssertEqual(store.rules.first?.note, note)
    }

    @MainActor
    func testExactBudgetIsRecoverableAndToggleCannotGrowItPastTheLimit() throws {
        let store = emptyStore()
        let rule = RouteRule(cidr: "223.5.5.5/32", action: .direct)
        let overhead = try RulesArchive.encode([rule]).count
        let note = String(repeating: "a", count: RulesArchive.maximumBytes - overhead)
        try store.addRule(cidr: rule.cidr, action: rule.action, note: note)
        let exported = try store.exportRules()
        XCTAssertEqual(exported.utf8.count, RulesArchive.maximumBytes)
        let restored = emptyStore()
        try restored.importRules(text: exported)
        XCTAssertEqual(restored.rules.first?.note, note)
        let id = try XCTUnwrap(store.rules.first?.id)
        store.toggleRule(id: id) // JSON false needs one more byte than true.
        XCTAssertEqual(store.rules.first?.enabled, true)
        XCTAssertNotNil(store.lastError)
        XCTAssertThrowsError(try store.updateRule(id: id, cidr: rule.cidr, action: rule.action, note: note + "a"))
        XCTAssertEqual(store.rules.first?.note, note)
    }

    func testFileReaderRejectsOversizedOrInvalidUTF8Files() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("rules.json")
            try Data(repeating: 97, count: RulesArchive.maximumBytes + 1).write(to: file)
            XCTAssertThrowsError(try RulesArchive.readText(at: file))
            try Data([0xff]).write(to: file)
            XCTAssertThrowsError(try RulesArchive.readText(at: file))
        }
    }

    @MainActor
    func testLegacyOversizedProfileRemainsLosslessAndCanOnlyShrink() throws {
        try withDirectory { directory in
            let storage = ProfileStorage(directory: directory, writingOptions: [.atomic])
            let note = String(repeating: "a", count: RulesArchive.maximumBytes + 100)
            let rule = RouteRule(cidr: "223.5.5.5/32", action: .direct, note: note)
            try storage.save(SavedProfile(countryEnabled: false, rules: [rule]), replacing: .missing)
            let store = AppStore(profileStorage: storage)
            XCTAssertNil(store.profileRecoveryMessage)
            XCTAssertEqual(store.rules.first?.note, note)
            let exported = try store.exportRules()
            XCTAssertNotNil(RulesArchive.migrationWarning(for: exported))
            let decoded = try JSONDecoder().decode([RouteRule].self, from: Data(exported.utf8))
            XCTAssertEqual(decoded, [rule])
            XCTAssertThrowsError(try store.updateRule(id: rule.id, cidr: rule.cidr, action: rule.action, note: note + "a"))
            XCTAssertEqual(try storage.load().profile?.rules, [rule])
            let reduced = String(note.dropLast())
            try store.updateRule(id: rule.id, cidr: rule.cidr, action: rule.action, note: reduced)
            XCTAssertEqual(try storage.load().profile?.rules.first?.note, reduced)
            try store.updateRule(id: rule.id, cidr: rule.cidr, action: rule.action, note: "migrated")
            XCTAssertNil(RulesArchive.migrationWarning(for: try store.exportRules()))
            let restored = emptyStore()
            try restored.importRules(text: store.exportRules())
            XCTAssertEqual(restored.rules.first?.note, "migrated")
        }
    }
}
