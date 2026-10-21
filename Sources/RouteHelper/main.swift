import Foundation
import Darwin
import RouteIPC

func emit(_ report: Report) {
    if let data = try? JSONEncoder().encode(report), let text = String(data: data, encoding: .utf8) { print(text) }
}
func serviceResponse(_ state: RecoveryStatus, dns: (active: Bool, domainCount: Int, message: String, withdrawn: Bool)? = nil) -> ServiceResponse {
    var response = ServiceResponse()
    let report = state.report
    response.active = report.active; response.pending = report.pending
    response.added = report.added; response.removed = report.removed
    response.skipped = report.skipped; response.failed = report.failed
    response.durationMilliseconds = report.durationMilliseconds; response.verified = report.verified
    response.message = report.message
    response.detailsOmitted = report.detailsOmitted
    response.details = report.details.map { ServiceDetail(cidr: $0.cidr, action: $0.action, result: $0.result) }
    response.enabled = state.enabled; response.phase = state.phase.rawValue
    response.gateway = state.network?.gateway; response.interface = state.network?.interface
    response.exitNodeID = state.network?.exitNodeID
    response.desiredRoutesDigest = state.desiredRoutesDigest
    response.dnsActive = dns?.active; response.dnsDomainCount = dns?.domainCount; response.dnsMessage = dns?.message
    response.dnsWithdrawn = dns?.withdrawn
    return response
}
// Root is checked before opening journal files or route sockets. A normal app
// launch can never create privileged state or accidentally modify the network.
do {
    let args = CommandLine.arguments
    try require(args.count >= 2, "用法：RouteWeaverHelper apply <base64 JSON> | apply-file <private JSON path> | check-file <private JSON path> | rollback")
    let action = args[1]
    if ["serve", "install-service", "uninstall-service"].contains(action) {
        try require(geteuid() == 0, "后台服务管理需要系统管理员授权")
        if action == "install-service" {
            try require(args.count == 3, "需要完整应用路径")
            print(try ServiceInstaller.install(appBundlePath: args[2]))
            exit(0)
        }
        if action == "uninstall-service" {
            try require(args.count == 2, "卸载不接受额外参数")
            try ServiceInstaller.stopService()
            let result = try Engine().rollback()
            emit(result)
            try require(result.failed == 0 && result.active == 0 && result.pending == 0, "路由尚未全部撤销，保留恢复日志和服务文件")
            try ServiceInstaller.uninstallFiles()
            exit(0)
        }
        try require(args.count == 2, "服务不接受额外参数")
        let config = try ServiceConfiguration.load()
        let installedHash = try ServiceIdentity.staticHash(path: ServicePaths.executable)
        try require(installedHash == config.helperCodeHash, "后台程序版本不匹配")
        let dns = ScopedDNSController()
        let coordinator = try RecoveryCoordinator(ownerUID: config.ownerUID, engine: Engine(), networkRoutingStateChanged: { _, routes in
            dns.update(directCIDRs: routes)
        })
        let queue = DispatchQueue(label: "com.routeweaver.service.requests")
        // A new helper never resurrects an earlier GUI's enabled policy. First
        // disable it durably and recover owned leftovers; attach itself is inert.
        _ = try coordinator.stop()
        let owner = AppSessionOwner(queue: queue) {
            _ = try? coordinator.stop()
        }
        let server = ServiceServer(config: config, queue: queue) { request, peer in
            do {
                let state: RecoveryStatus
                switch request.command {
                case .status: state = coordinator.status()
                case .attach:
                    try owner.attach(peer)
                    state = coordinator.status()
                case .apply:
                    try owner.requireAttached(peer)
                    state = try coordinator.apply(routes: request.routes ?? [])
                case .stop: state = try coordinator.stop()
                case .stopOwned:
                    state = try owner.stopIfOwned(peer) { try coordinator.stop() } ?? coordinator.status()
                }
                var response = serviceResponse(state, dns: dns.status())
                response.sessionAttached = owner.isAttached(peer)
                response.anotherSessionActive = owner.hasOtherOwner(peer)
                return response
            } catch {
                var response = serviceResponse(coordinator.status(), dns: dns.status())
                response.sessionAttached = owner.isAttached(peer)
                response.anotherSessionActive = owner.hasOtherOwner(peer)
                response.failed += 1; response.message = String(describing: error)
                return response
            }
        }
        try server.start()
        coordinator.start()
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        let shutdown = { dns.shutdown(); coordinator.shutdown(); exit(0) }
        term.setEventHandler(handler: shutdown); interrupt.setEventHandler(handler: shutdown)
        term.resume(); interrupt.resume()
        withExtendedLifetime((server, coordinator, dns, owner, term, interrupt)) { dispatchMain() }
    }
    try require(action == "apply" || action == "apply-file" || action == "check-file" || action == "rollback", "不支持的操作")
    var request: ApplyRequest?
    if action != "rollback" {
        try require(args.count == 3, "缺少路由计划")
        let data: Data
        if action == "apply" {
            try require(args[2].utf8.count <= 1_400_000, "路由计划过大")
            guard let decoded = Data(base64Encoded: args[2]) else { throw HelperError("路由计划编码无效") }
            data = decoded
        } else { data = try readRequestFile(args[2]) }
        request = try JSONDecoder().decode(ApplyRequest.self, from: data)
        _ = try validatedRoutes(request!)
    } else { try require(args.count == 2, "撤销不接受额外参数") }
    if action == "check-file", let request {
        let routes = try validatedRoutes(request)
        let interfaces = try verifyTailscale(request)
        let snapshot = try RouteTable.snapshot()
        try verifyGateway(request, snapshot: snapshot, tailscaleInterfaces: interfaces)
        let existing = Set(snapshot.map { "\($0.network)/\($0.mask)" })
        var report = Report()
        report.skipped = routes.filter { existing.contains("\($0.network)/\(cidrMask($0))") }.count
        report.message = "只读预检通过：\(routes.count) 条计划，\(report.skipped) 条同前缀现存路由；应用时将再次核验归属。未修改系统路由。"
        emit(report)
        exit(0)
    }
    try require(geteuid() == 0, "需要通过 RouteWeaver 界面的系统管理员授权执行；未修改任何路由")
    let engine = try Engine()
    let report = try request.map { try engine.apply($0) } ?? engine.rollback()
    emit(report)
    exit(report.failed == 0 ? 0 : 1)
} catch {
    var report = Report()
    report.failed = 1
    report.message = String(describing: error)
    emit(report)
    exit(2)
}
