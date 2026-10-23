import Foundation
import Observation
import Network
import RouteCore
import RouteIPC
import CryptoKit
import AppKit

@MainActor @Observable
final class AppStore {
    var selection: AppSection = .overview
    var rules: [RouteRule] = []
    var countryRoutes: [String] = []
    var countryEnabled = true
    var isBusy = false
    private(set) var isQuitting = false
    var isRefreshing = false
    var network = NetworkSnapshot()
    var plannedRoutes: [String] = []
    var events: [ActivityEvent] = []
    var lastError: String?
    private(set) var profileRecoveryMessage: String?
    var notice: String?
    var searchText = ""
    var datasetDate = "读取中"
    var lastAppliedCount = 0
    var hasApplied = false
    var serviceEnabled = false
    var servicePhase = ""
    var serviceMessage = "尚未读取后台服务状态"
    var serviceDNSActive: Bool?
    var serviceDNSWithdrawn: Bool?
    var serviceDNSDomainCount = 0
    var serviceDNSMessage = "国内域名解析状态尚未确认"
    var serviceReachable = false
    var serviceChecked = false
    var serviceInstalled = false
    var serviceVerified = false
    var serviceGateway: String?
    var serviceInterface: String?
    var pendingRouteCount = 0
    var lastServiceCheck: Date?
    var operation: AppOperation?
    var planMilliseconds = 0.0

    /// Nil is intentional: a failed connection cannot establish a live count.
    var activeRouteCount: Int? { serviceReachable && serviceVerified ? lastAppliedCount : nil }
    /// The daemon uses SystemConfiguration service priority; the local preview
    /// can find a different default route when multiple adapters are connected.
    var usesConfirmedServiceNetwork: Bool {
        serviceReachable && serviceEnabled && serviceGateway != nil && serviceInterface != nil
    }
    var displayedGateway: String? { usesConfirmedServiceNetwork ? serviceGateway : network.gateway }
    var displayedInterface: String? { usesConfirmedServiceNetwork ? serviceInterface : network.interface }
    var dnsRestorationConfirmed: Bool { serviceReachable && serviceDNSActive == false && serviceDNSWithdrawn == true }
    var dnsStatusText: String {
        guard serviceReachable else { return "待确认" }
        if serviceDNSActive == true { return "已启用" }
        if dnsRestorationConfirmed { return "未启用" }
        if !serviceEnabled && serviceDNSWithdrawn == false { return "撤回中" }
        return "待确认"
    }
    var configurationDirectory: URL { profileStorage.location }
    var hasUnappliedChanges: Bool { serviceEnabled && appliedDigest.map { $0 != planDigest } == true }
    var requiresReapply: Bool { hasUnappliedChanges }
    var canApply: Bool {
        guard !isBusy, !isQuitting, planValid else { return false }
        if plannedRoutes.isEmpty { return canStop }
        guard profileRecoveryMessage == nil else { return false }
        return network.ready && serviceChecked && (serviceReachable || !serviceInstalled)
    }
    var canStop: Bool {
        !isBusy && !isQuitting && serviceChecked && (serviceInstalled || serviceReachable)
    }
    var canToggleRouting: Bool {
        guard !isBusy, !isQuitting, serviceChecked else { return false }
        if !serviceReachable { return !serviceInstalled && canApply && !plannedRoutes.isEmpty }
        return serviceEnabled ? canStop : canApply && !plannedRoutes.isEmpty
    }
    var connection: ConnectionPresentation {
        .make(ConnectionState(checked: serviceChecked, reachable: serviceReachable,
            installed: serviceInstalled, networkReady: network.ready, enabled: serviceEnabled,
            phase: servicePhase, verified: serviceVerified, active: lastAppliedCount,
            pending: pendingRouteCount, failed: serviceFailed, skipped: serviceSkipped,
            hasUnappliedChanges: hasUnappliedChanges, dnsActive: serviceDNSActive,
            dnsWithdrawn: serviceDNSWithdrawn, operation: operation))
    }
    private var planValid = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private let stopService: () async throws -> ServiceResponse
    @ObservationIgnored private let stopForExit: () async throws -> ServiceResponse
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var compiled: [IPv4CIDR] = []
    @ObservationIgnored private var persistenceBlocked = false
    @ObservationIgnored private let profileStorage: ProfileStorage
    @ObservationIgnored private var profileRevision = ProfileStorage.Revision.missing
    private var appliedDigest: String?
    private var planDigest = ""
    private var serviceFailed = 0
    private var serviceSkipped = 0
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var errorSource: ErrorSource?
    private enum ErrorSource: Equatable { case profile, rules, routing, installation, dataset }

    /// Tests can opt out of all user files and background work.
    init(loadPersistedState: Bool = true,
         profileStorage: ProfileStorage = ProfileStorage(),
         stopService: @escaping () async throws -> ServiceResponse = { try await PrivilegedClient.stop() },
         stopForExit: (() async throws -> ServiceResponse)? = nil) {
        self.profileStorage = profileStorage
        self.stopService = stopService
        self.stopForExit = stopForExit ?? { try await PrivilegedClient.stopForExit() }
        serviceInstalled = FileManager.default.fileExists(atPath: ServicePaths.executable)
        guard loadPersistedState else { persistenceBlocked = true; return }
        do {
            let snapshot = try profileStorage.load()
            profileRevision = snapshot.revision
            if let saved = snapshot.profile {
                rules = saved.rules
                countryEnabled = saved.countryEnabled
                // Saved counts are history, never evidence of current routes.
                events = saved.events
            }
        } catch {
            persistenceBlocked = true
            reportProfileFailure("读取配置失败，原文件未覆盖：\(error.localizedDescription)")
        }
        loadDataset()
        compilePlan()
    }

    func startup() {
        guard !started else { return }
        started = true
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        monitor.start(queue: DispatchQueue(label: "com.routeweaver.network"))
        pathMonitor = monitor
        monitorTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                await self?.refresh(includeNetwork: ticks % 6 == 0)
                ticks += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func refresh(includeNetwork: Bool = true) async {
        guard !isRefreshing, !isBusy, !isQuitting else { return }
        isRefreshing = true
        let generation = operationGeneration
        defer { isRefreshing = false }
        let current = includeNetwork ? await NetworkInspector.inspect() : network
        guard !isBusy, !isQuitting, generation == operationGeneration else { return }
        let gatewayChanged = network.gateway != current.gateway
        network = current
        if gatewayChanged { compilePlan() }
        do {
            let result = try await PrivilegedClient.attachedStatus()
            guard !isBusy, !isQuitting, generation == operationGeneration else { return }
            updateService(result)
        } catch {
            guard !isBusy, !isQuitting, generation == operationGeneration else { return }
            serviceUnavailable(error)
        }
    }

    func rebuildPlan() {
        compilePlan()
        persist()
    }

    private func compilePlan() {
        let start = ContinuousClock.now
        do {
            compiled = try PolicyCompiler.compile(countryCIDRs: countryEnabled ? countryRoutes : [], rules: rules,
                excludedAddresses: ["8.8.8.8", "1.1.1.1"] + [network.gateway].compactMap { $0 })
            plannedRoutes = compiled.map(\.description)
            planDigest = Self.digest(plannedRoutes)
            planValid = !countryEnabled || !countryRoutes.isEmpty
            if planValid { clearError(from: .rules) }
            let elapsed = start.duration(to: .now).components
            planMilliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        } catch {
            compiled = []
            plannedRoutes = []
            planValid = false
            planDigest = ""
            setError("规则校验失败：\(error.localizedDescription)", source: .rules)
        }
    }

    func addRule(cidr: String, action: RuleAction, note: String) throws {
        guard !isBusy else { throw AppFailure("请等待当前操作完成。") }
        let parsed = try IPv4CIDR(cidr.trimmingCharacters(in: .whitespacesAndNewlines))
        if action == .direct { try parsed.validateForBypass() }
        guard !rules.contains(where: { $0.cidr == parsed.description && $0.action == action }) else { throw AppFailure("相同规则已存在。") }
        let rule = RouteRule(cidr: parsed.description, action: action, note: note)
        try validate(rules + [rule])
        rules.append(rule)
        record("添加自定义规则", "\(parsed) · \(action == .direct ? "直连" : "Exit node")", .info)
        rebuildPlan()
    }

    func updateRule(id: UUID, cidr: String, action: RuleAction, note: String) throws {
        guard !isBusy, let index = rules.firstIndex(where: { $0.id == id }) else { throw AppFailure("当前无法编辑此规则。") }
        let parsed = try IPv4CIDR(cidr.trimmingCharacters(in: .whitespacesAndNewlines))
        if action == .direct { try parsed.validateForBypass() }
        var candidate = rules
        candidate[index].cidr = parsed.description
        candidate[index].action = action
        candidate[index].note = note
        try validate(candidate)
        rules = candidate
        record("更新自定义规则", parsed.description, .info)
        rebuildPlan()
    }

    func deleteRule(id: UUID) { guard !isBusy, !isQuitting else { return }; rules.removeAll { $0.id == id }; rebuildPlan() }
    func toggleRule(id: UUID) {
        guard !isBusy, let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled.toggle()
        rebuildPlan()
    }

    func importRules(text: String) throws {
        guard !isBusy, text.utf8.count <= 2 * 1024 * 1024 else { throw AppFailure("导入文件过大或当前正在执行操作。") }
        var imported: [RouteRule]
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            imported = try JSONDecoder().decode([RouteRule].self, from: Data(text.utf8))
        } else {
            imported = try text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                let pieces = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let fields = pieces[0].split(whereSeparator: \.isWhitespace)
                guard !fields.isEmpty else { return nil }
                let action: RuleAction
                let cidr: String
                if fields.count == 1 { action = .direct; cidr = String(fields[0]) }
                else if fields.count == 2, ["direct", "exit", "exitNode"].contains(String(fields[0])) {
                    action = fields[0] == "direct" ? .direct : .exitNode; cidr = String(fields[1])
                } else { throw AppFailure("第 \(index + 1) 行格式无效。应为 CIDR，或 direct/exit CIDR。") }
                return RouteRule(cidr: cidr, action: action, note: pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : "")
            }
        }
        for index in imported.indices {
            let parsed = try IPv4CIDR(imported[index].cidr)
            if imported[index].action == .direct { try parsed.validateForBypass() }
            imported[index].cidr = parsed.description
            imported[index].id = UUID()
        }
        let existing = Set(rules.map { "\($0.action.rawValue):\($0.cidr)" })
        var seen = existing
        imported = imported.filter { seen.insert("\($0.action.rawValue):\($0.cidr)").inserted }
        try validate(rules + imported)
        rules += imported
        record("导入规则", "新增 \(imported.count) 条；重复项已跳过。", .success)
        rebuildPlan()
    }

    func exportRules() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(rules)) ?? Data("[]".utf8), as: UTF8.self)
    }

    func classify(_ ip: String) -> String {
        guard let address = IPv4CIDR.parseAddress(ip.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "请输入 IPv4 地址，例如 223.5.5.5。" }
        let normalized = "\(address >> 24).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
        if let cidr = try? IPv4CIDR(normalized + "/32"), !cidr.isPublic { return "保留 / 内网地址 · 保持系统及 Tailscale 原有路由" }
        return compiled.contains(where: { $0.contains(normalized) }) ? "计划直连 · 通过本地物理网关（按 IP 规则匹配）" : "沿用 Tailscale 路由 · exit node 连接时经出口节点"
    }

    func setRoutingEnabled(_ enabled: Bool) async {
        if enabled { await apply() } else { await rollback() }
    }

    func apply() async {
        guard !isBusy, !isQuitting else { return }
        if planValid && plannedRoutes.isEmpty { await rollback(); return }
        if let profileRecoveryMessage {
            setError(profileRecoveryMessage, source: .profile)
            return
        }
        begin(.applying)
        defer { endOperation() }
        guard planValid else {
            setError("规则计划无效，请先检查规则或更新地址数据。", source: .rules)
            return
        }
        guard serviceChecked && (serviceReachable || !serviceInstalled) else {
            setError("后台服务尚未连接。请重新检查，或在设置中修复后台服务。", source: .routing)
            return
        }
        let current = await NetworkInspector.inspect()
        let gatewayChanged = current.gateway != network.gateway
        network = current
        if gatewayChanged { compilePlan() }
        guard network.ready, planValid else {
            setError(network.detail, source: .routing)
            return
        }
        do {
            let result = try await PrivilegedClient.perform(routes: plannedRoutes, network: network)
            updateService(result)
            // The live status card owns progress; a retained submission notice
            // would become stale as soon as the daemon confirms the routes.
            notice = nil
            if result.failed > 0 { setError(result.message, source: .routing) }
            else { clearError(from: .routing) }
            let details = result.details.filter { $0.result != "已添加" && $0.result != "已撤销" }.prefix(20).map { "\($0.cidr): \($0.result)" }.joined(separator: "\n")
            record(result.failed > 0 ? "分流规则提交未完成" : "分流规则已提交",
                "\(result.message)\n新增 \(result.added) · 移除 \(result.removed) · 跳过 \(result.skipped) · 失败 \(result.failed)。\n\(details)",
                result.failed > 0 ? .error : .info)
            persist()
        } catch is AuthorizationCancelled {
            notice = "已取消授权，分流状态未更改。"
            clearError(from: .routing)
        } catch {
            serviceUnavailable(error)
            setError(error.localizedDescription, source: .routing)
            record("分流操作未完成", error.localizedDescription, .error)
        }
    }

    func rollback() async {
        guard !isBusy, !isQuitting else { return }
        begin(.stopping)
        defer { endOperation() }
        do {
            // A stop attempt must never silently install or replace a service.
            // Missing/unreachable service recovery is an explicit Settings action.
            let result = try await stopService()
            updateService(result)
            notice = Self.cleanupConfirmed(result) ? "分流已关闭，已恢复原 DNS 并清理本应用路由。" : nil
            if !Self.cleanupConfirmed(result) {
                setError(result.message + "；" + (result.dnsMessage ?? "DNS 撤销状态未知"), source: .routing)
            } else { clearError(from: .routing) }
            record(Self.cleanupConfirmed(result) ? "分流已关闭" : "网络恢复仍需确认",
                   "移除 \(result.removed) 条。\(result.message)", Self.cleanupConfirmed(result) ? .success : .error)
            persist()
        } catch {
            serviceUnavailable(error)
            setError("未能确认路由已撤销：\(error)。请修复后台服务后重试关闭分流。", source: .routing)
            record("关闭分流未完成", error.localizedDescription, .error)
        }
    }

    static func cleanupConfirmed(_ result: ServiceResponse) -> Bool {
        !result.enabled && result.verified && result.active == 0 && result.pending == 0 &&
        result.failed == 0 && result.dnsActive == false && result.dnsWithdrawn == true
    }

    /// Reject new changes, let an in-flight operation settle, then persist OFF
    /// and verify withdrawal before AppKit receives permission to terminate.
    func prepareForTermination() async -> Bool {
        guard !isQuitting else { return false }
        isQuitting = true
        operationGeneration += 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while isBusy && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !isBusy else {
            isQuitting = false
            setError("当前操作尚未完成，已取消退出。请稍后重试。", source: .routing)
            return false
        }
        // A never-installed app has never had authority to alter the network.
        if !serviceInstalled && !serviceReachable && !hasApplied &&
            !FileManager.default.fileExists(atPath: ServicePaths.executable) &&
            !FileManager.default.fileExists(atPath: ServicePaths.socket) { return true }
        begin(.stopping)
        notice = "正在恢复原 DNS 并撤销本应用路由…"
        defer { endOperation() }
        do {
            var result = try await stopForExit()
            if result.anotherSessionActive == true && result.sessionAttached == false {
                // This instance never owned the other GUI's session. Closing it
                // must not stop that GUI or claim its network has been cleared.
                return true
            }
            updateService(result)
            // configd withdrawal can finish slightly after route cleanup.
            // Retry a bounded number of idempotent stops, never assume success.
            for _ in 0..<5 where !Self.cleanupConfirmed(result) && result.failed == 0 {
                try await Task.sleep(for: .milliseconds(400))
                result = try await stopForExit()
                updateService(result)
            }
            guard Self.cleanupConfirmed(result) else {
                throw AppFailure("尚未确认网络恢复完成：\(result.message)；\(result.dnsMessage ?? "DNS 撤销状态未知")")
            }
            monitorTask?.cancel(); monitorTask = nil
            pathMonitor?.cancel(); pathMonitor = nil
            notice = "已恢复原 DNS，已清理本应用路由。"
            record("退出前已恢复网络", "自动恢复已关闭；路由和本机 DNS 配置均已确认撤销。", .success)
            return true
        } catch {
            isQuitting = false
            setError("退出已取消：\(error.localizedDescription)。请检查或修复后台服务后重试。", source: .routing)
            record("退出清理未完成", String(describing: error), .error)
            return false
        }
    }

    private func updateService(_ result: ServiceResponse) {
        let previousPhase = servicePhase
        let previouslyReachable = serviceReachable
        serviceChecked = true
        serviceReachable = true
        serviceInstalled = true
        lastServiceCheck = Date()
        serviceEnabled = result.enabled
        servicePhase = result.phase
        serviceMessage = result.message
        serviceDNSActive = result.dnsActive
        serviceDNSWithdrawn = result.dnsWithdrawn
        serviceDNSDomainCount = result.dnsDomainCount ?? 0
        serviceDNSMessage = result.dnsMessage ?? "后台尚不支持国内域名解析，请更新后台服务"
        serviceVerified = result.verified
        serviceGateway = result.gateway
        serviceInterface = result.interface
        serviceFailed = result.failed
        serviceSkipped = result.skipped
        pendingRouteCount = result.pending
        lastAppliedCount = result.active
        hasApplied = result.enabled || result.active > 0 || result.pending > 0 || result.dnsActive == true || result.dnsWithdrawn == false
        appliedDigest = result.desiredRoutesDigest
        if previouslyReachable && previousPhase != result.phase && result.phase == "active" && result.verified && result.failed == 0 {
            record("分流已就绪", "已核验 \(result.active.formatted()) 条直连路由。\(result.skipped > 0 ? "保留 \(result.skipped) 条系统已有路由。" : "")", result.skipped > 0 ? .warning : .success)
        }
    }

    private func serviceUnavailable(_ error: Error) {
        serviceChecked = true
        serviceReachable = false
        serviceDNSActive = nil
        serviceDNSWithdrawn = nil
        serviceDNSMessage = "无法读取国内域名解析状态"
        serviceInstalled = FileManager.default.fileExists(atPath: ServicePaths.executable)
        serviceVerified = false
        servicePhase = "unavailable"
        serviceMessage = String(describing: error)
        // Preserve the last known intent/count for recovery; presentation treats
        // it as unknown instead of claiming that existing routes are disabled.
    }

    private static func digest(_ routes: [String]) -> String {
        SHA256.hash(data: Data(routes.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func begin(_ operation: AppOperation) {
        operationGeneration += 1
        isBusy = true
        self.operation = operation
        notice = nil
    }
    private func endOperation() { operation = nil; isBusy = false }
    private func setError(_ message: String, source: ErrorSource) { lastError = message; errorSource = source }
    private func clearError(from source: ErrorSource) {
        guard errorSource == source else { return }
        lastError = nil; errorSource = nil
    }
    func dismissError() { lastError = nil; errorSource = nil }

    func repairService() async {
        guard !isBusy, !isQuitting else { return }
        begin(.repairing)
        defer { endOperation() }
        do {
            try await PrivilegedClient.install()
            updateService(try await PrivilegedClient.attachedStatus())
            notice = "帮助程序已授权并连接，可直接使用。"
            clearError(from: .installation)
        } catch is AuthorizationCancelled {
            notice = "已取消系统授权，现有分流状态未更改。"
            clearError(from: .installation)
        } catch {
            serviceUnavailable(error)
            setError(error.localizedDescription, source: .installation)
        }
    }

    func openUninstaller() {
        guard !isBusy, !isQuitting else { return }
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Uninstall RouteWeaver.command")
        guard FileManager.default.isExecutableFile(atPath: tool.path), NSWorkspace.shared.open(tool) else {
            setError("无法打开独立卸载工具。请使用完整应用包，或按 README 中的说明卸载。", source: .installation)
            return
        }
        notice = "卸载工具已打开，请在终端查看清理范围并确认。"
    }

    func updateDataset() async {
        guard !isBusy, !isQuitting else { return }
        begin(.updatingDataset)
        defer { endOperation() }
        do {
            var request = URLRequest(url: URL(string: "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest")!)
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", response.url?.host == "ftp.apnic.net", data.count < 16 * 1024 * 1024 else { throw AppFailure("APNIC 数据响应无效，已保留原规则集。") }
            let text = String(decoding: data, as: UTF8.self)
            let cidrs = try APNICParser.chinaIPv4(from: text)
            guard cidrs.count > 1000 else { throw AppFailure("APNIC 网段数量异常，已保留原规则集。") }
            let strings = cidrs.map(\.description)
            _ = try PolicyCompiler.compile(countryCIDRs: strings, rules: rules, excludedAddresses: [])
            let date = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let output = "# APNIC CN IPv4\n# Source: https://ftp.apnic.net/stats/apnic/delegated-apnic-latest\n# Retrieved: \(date)\n" + strings.joined(separator: "\n") + "\n"
            try ProfileStorage.prepareDirectory(at: configurationDirectory)
            try Data(output.utf8).write(to: configurationDirectory.appendingPathComponent("cn-ipv4.txt"), options: .atomic)
            countryRoutes = strings
            datasetDate = date
            clearError(from: .dataset)
            record("国内规则集已更新", "APNIC · \(cidrs.count) 个 IPv4 网段；需要应用后才改变系统路由。", .success)
            rebuildPlan()
        } catch { setError(error.localizedDescription, source: .dataset); record("规则集更新失败", error.localizedDescription, .error) }
    }

    private func loadDataset() {
        let cached = configurationDirectory.appendingPathComponent("cn-ipv4.txt")
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("RouteWeaver_RouteWeaver.bundle")
        let resourceBundle = packaged.flatMap { Bundle(url: $0) }
        let bundled = resourceBundle?.url(forResource: "cn-ipv4", withExtension: "txt") ?? Bundle.module.url(forResource: "cn-ipv4", withExtension: "txt")
        for file in [cached, bundled].compactMap({ $0 }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            let values = lines.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !values.isEmpty, (try? PolicyCompiler.compile(countryCIDRs: values, rules: [], excludedAddresses: [])) != nil else { continue }
            countryRoutes = values
            datasetDate = lines.first(where: { $0.hasPrefix("# Retrieved:") }).map { $0.replacingOccurrences(of: "# Retrieved:", with: "").trimmingCharacters(in: .whitespaces) } ?? "随应用附带"
            return
        }
        setError("未找到有效的国内规则集，请点击更新地址数据。", source: .dataset)
    }

    private func validate(_ candidate: [RouteRule]) throws {
        guard candidate.count <= 20000 else { throw AppFailure("自定义规则最多 20,000 条。") }
        _ = try PolicyCompiler.compile(countryCIDRs: countryEnabled ? countryRoutes : [], rules: candidate, excludedAddresses: [])
    }

    private func record(_ title: String, _ detail: String, _ kind: EventKind) {
        events.insert(ActivityEvent(title: title, detail: detail, kind: kind), at: 0)
        events = Array(events.prefix(200))
        persist()
    }
    private func persist() {
        guard !persistenceBlocked else { return }
        do {
            profileRevision = try profileStorage.save(SavedProfile(countryEnabled: countryEnabled, rules: rules,
                lastAppliedCount: lastAppliedCount, hasApplied: hasApplied, events: events), replacing: profileRevision)
        } catch {
            // Keep the draft available for export. Background activity must not
            // retry an old snapshot after another instance has changed the file.
            persistenceBlocked = true
            reportProfileFailure("配置未保存：\(error.localizedDescription)")
        }
    }

    private func reportProfileFailure(_ message: String) {
        profileRecoveryMessage = message
        setError(message, source: .profile)
    }

    /// Explicit recovery replaces only the local plan and event history. It
    /// never applies routes or sends a command to the privileged service.
    func reloadProfile() {
        guard !isBusy, !isQuitting else { return }
        do {
            let snapshot = try profileStorage.load()
            let saved = snapshot.profile ?? SavedProfile()
            rules = saved.rules
            countryEnabled = saved.countryEnabled
            events = saved.events
            profileRevision = snapshot.revision
            persistenceBlocked = false
            profileRecoveryMessage = nil
            clearError(from: .profile)
            compilePlan()
        } catch {
            persistenceBlocked = true
            reportProfileFailure("读取最新配置失败，当前规则仍保留在窗口中：\(error.localizedDescription)")
        }
    }
}
