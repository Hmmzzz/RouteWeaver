import Foundation
import Darwin
import RouteCore

private struct RouteKey: Hashable { let network: UInt32; let mask: UInt32 }
private typealias RouteIndex = [RouteKey: [ExistingRoute]]

/// One journal and kernel observation shared by recovery decisions and status.
struct RouteHealth {
    let report: Report
    let hasMissingOwnedRoutes: Bool
}

/// All callers must serialize operations. SecureJournal additionally holds an
/// interprocess lock for this Engine's lifetime. No route mutations occur before
/// preflight and durable intent persistence have succeeded.
final class Engine {
    private let store: any JournalStoring
    private let table: any RouteTableOperating
    private let preflight: (ApplyRequest, [ExistingRoute]) throws -> Void
    init() throws {
        store = try SecureJournal(); table = try RouteTable()
        preflight = { request, snapshot in
            let interfaces = try verifyTailscale(request)
            try verifyGateway(request, snapshot: snapshot, tailscaleInterfaces: interfaces)
        }
    }
    init(store: any JournalStoring, table: any RouteTableOperating,
         preflight: @escaping (ApplyRequest, [ExistingRoute]) throws -> Void = { _, _ in }) {
        self.store = store; self.table = table; self.preflight = preflight
    }
    func apply(_ request: ApplyRequest) throws -> Report {
        let start = Date()
        let routes = try validatedRoutes(request)
        var journal = try store.load()
        try validateJournal(journal)
        var snapshot = try table.readSnapshot()
        try preflight(request, snapshot)
        let desired = Set(routes.map(\.description))
        var report = Report()
        try removeRecords(&journal, snapshot: snapshot, report: &report) {
            !desired.contains($0.cidr) || $0.gateway != request.gateway || $0.interface != request.interface
        }
        if report.failed > 0 {
            try summarize(journal, report: &report)
            report.message = "旧路由未完全撤销，停止应用新规则；恢复记录已保留"
            report.durationMilliseconds = elapsed(start); return report
        }
        snapshot = try table.readSnapshot()
        try preflight(request, snapshot)
        let index = makeIndex(snapshot)
        let old = Dictionary(uniqueKeysWithValues: journal.records.map { ($0.cidr, $0) })
        var retained: [RouteRecord] = [], additions: [RouteRecord] = []
        for cidr in routes {
            let exact = index[RouteKey(network: cidr.network, mask: cidrMask(cidr))] ?? []
            if var record = old[cidr.description], !exact.isEmpty {
                if owns(exact, record) {
                    record.confirmed = true; retained.append(record)
                } else {
                    retained.append(record)
                    fail(&report, cidr.description, "add", "路由归属变化，保留恢复记录并等待处理")
                }
            } else if !exact.isEmpty {
                report.skipped += 1
                detail(&report, cidr.description, "add", "保留系统已有路由，未覆盖")
            } else {
                additions.append(RouteRecord(cidr: cidr.description, gateway: request.gateway, interface: request.interface, confirmed: false))
            }
        }
        journal.version = 2
        journal.records = retained + additions
        // The full write-ahead batch is durable before the first add. Marker
        // flags allow an interrupted successful add to be recovered next time.
        try store.save(journal)
        var successful = Set<String>(), uncertain = Set<String>()
        for record in additions {
            do {
                let result = try table.add(record)
                if result == 0 { successful.insert(record.cidr) }
                else {
                    // Kernel route mutation can precede a later message error.
                    // EEXIST alone proves this call did not create the route.
                    if result != EEXIST { uncertain.insert(record.cidr) }
                    fail(&report, record.cidr, "add", String(cString: strerror(result)))
                }
            } catch {
                // A transport/verification exception can follow a kernel change.
                // Retain its durable intent until a snapshot resolves ownership.
                uncertain.insert(record.cidr)
                fail(&report, record.cidr, "add", String(describing: error))
            }
        }
        let final = makeIndex(try table.readSnapshot())
        journal.records = retained
        for var record in additions {
            let exact = try matching(final, record)
            if (successful.contains(record.cidr) || uncertain.contains(record.cidr)) && owns(exact, record) {
                record.confirmed = true; journal.records.append(record)
                report.added += 1
                detail(&report, record.cidr, "add", "已添加并核验")
            } else if successful.contains(record.cidr) || uncertain.contains(record.cidr) {
                if !exact.isEmpty { journal.records.append(record) }
                if successful.contains(record.cidr) { fail(&report, record.cidr, "verify", "内核路由与写入结果不符") }
            }
        }
        try store.save(journal)
        summarize(journal, index: final, report: &report)
        report.durationMilliseconds = elapsed(start)
        report.message = report.failed == 0 ? "路由计划已应用并核验；已有冲突路由保持不变" : "部分路由失败；恢复记录已保留，可重试或撤销"
        return report
    }
    func rollback() throws -> Report {
        let start = Date()
        var journal = try store.load()
        try validateJournal(journal)
        var report = Report()
        try removeRecords(&journal, snapshot: table.readSnapshot(), report: &report, shouldRemove: { _ in true })
        try summarize(journal, report: &report)
        report.durationMilliseconds = elapsed(start)
        report.message = report.failed == 0 ? "已撤销 RouteWeaver 记录的路由" : "部分路由无法安全撤销；恢复记录已保留"
        return report
    }
    func status() throws -> Report {
        let journal = try store.load()
        try validateJournal(journal)
        var report = Report()
        try summarize(journal, report: &report)
        report.message = report.pending == 0 ? "已核验内核路由状态" : "部分恢复记录与内核路由不一致"
        return report
    }
    func hasMissingOwnedRoutes() throws -> Bool {
        let journal = try store.load()
        try validateJournal(journal)
        let index = makeIndex(try table.readSnapshot())
        return try journal.records.contains { try matching(index, $0).isEmpty }
    }
    func inspectHealth() throws -> RouteHealth {
        let journal = try store.load()
        try validateJournal(journal)
        let index = makeIndex(try table.readSnapshot())
        var report = Report()
        summarize(journal, index: index, report: &report)
        report.message = report.pending == 0 ? "已核验内核路由状态" : "部分恢复记录与内核路由不一致"
        // An existing route with changed ownership is pending, not missing;
        // never use a health check as permission to replace someone else's route.
        let missing = try journal.records.contains { try matching(index, $0).isEmpty }
        return RouteHealth(report: report, hasMissingOwnedRoutes: missing)
    }
    private func validateJournal(_ journal: Journal) throws {
        try require((1...2).contains(journal.version) && journal.records.count <= 20_000, "不支持的恢复日志格式或条目超限")
        var seen = Set<String>()
        for record in journal.records {
            let cidr = try IPv4CIDR(record.cidr)
            try cidr.validateForBypass()
            try require(record.cidr == cidr.description && seen.insert(record.cidr).inserted, "恢复日志存在重复或未规范化条目")
            let suffix = record.interface.dropFirst(2)
            try require(IPv4CIDR.parseAddress(record.gateway) != nil && record.interface.hasPrefix("en") && !suffix.isEmpty && suffix.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && (0...1).contains(record.markerVersion), "恢复日志中存在无效记录")
        }
    }
    private func removeRecords(_ journal: inout Journal, snapshot: [ExistingRoute], report: inout Report, shouldRemove: (RouteRecord) -> Bool) throws {
        let index = makeIndex(snapshot)
        var keep: [RouteRecord] = [], attempted: [RouteRecord] = []
        for record in journal.records {
            guard shouldRemove(record) else { keep.append(record); continue }
            let exact = try matching(index, record)
            if exact.isEmpty { continue }
            guard owns(exact, record) else {
                keep.append(record)
                fail(&report, record.cidr, "remove", "归属不明或路由已被其他程序修改，保留并停止自动删除")
                continue
            }
            do {
                let result = try table.remove(record)
                if result == 0 || result == ESRCH { attempted.append(record) }
                else { keep.append(record); fail(&report, record.cidr, "remove", String(cString: strerror(result))) }
            } catch {
                keep.append(record); fail(&report, record.cidr, "remove", String(describing: error))
            }
        }
        if !attempted.isEmpty {
            // Do not discard durable records based only on write() returning 0.
            let after = makeIndex(try table.readSnapshot())
            for record in attempted {
                if try matching(after, record).isEmpty {
                    report.removed += 1
                    detail(&report, record.cidr, "remove", "已撤销并核验")
                } else {
                    keep.append(record); fail(&report, record.cidr, "remove", "删除后仍存在路由，保留恢复记录")
                }
            }
        }
        journal.records = keep
        try store.save(journal)
    }
    private func summarize(_ journal: Journal, report: inout Report) throws {
        summarize(journal, index: makeIndex(try table.readSnapshot()), report: &report)
    }
    private func summarize(_ journal: Journal, index: RouteIndex, report: inout Report) {
        report.active = journal.records.reduce(0) { count, record in
            count + (((try? matching(index, record)).map { owns($0, record) } ?? false) ? 1 : 0)
        }
        report.pending = journal.records.count - report.active
        report.verified = true
    }
    private func owns(_ exact: [ExistingRoute], _ record: RouteRecord) -> Bool {
        (record.confirmed || record.markerVersion == 1) && exact.count == 1 && exact[0].belongs(to: record)
    }
    private func makeIndex(_ routes: [ExistingRoute]) -> RouteIndex {
        Dictionary(grouping: routes, by: { RouteKey(network: $0.network, mask: $0.mask) })
    }
    private func matching(_ index: RouteIndex, _ record: RouteRecord) throws -> [ExistingRoute] {
        let cidr = try IPv4CIDR(record.cidr)
        return index[RouteKey(network: cidr.network, mask: cidrMask(cidr))] ?? []
    }
    private func fail(_ report: inout Report, _ cidr: String, _ action: String, _ message: String) {
        report.failed += 1; detail(&report, cidr, action, message)
    }
    private func detail(_ report: inout Report, _ cidr: String, _ action: String, _ message: String) {
        // A 20,000-route batch must still fit the bounded IPC response frame.
        if report.details.count < 512 { report.details.append(.init(cidr: cidr, action: action, result: String(message.prefix(512)))) }
        else { report.detailsOmitted += 1 }
    }
    private func elapsed(_ start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1000)) }
}
