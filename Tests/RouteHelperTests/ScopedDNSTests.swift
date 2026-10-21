import XCTest
import RouteDNS
@testable import RouteHelper

private enum ScopedDNSTestError: Error { case expected }
private final class ScopedDNSTestLog { var events: [String] = [] }
private final class ScopedDNSTestSession: ScopedDNSResolverSession {
    let log: ScopedDNSTestLog
    // External writes revoke session ownership even if the value is identical.
    var value: NSDictionary? { didSet { ownsValue = false } }
    private var ownsValue = false
    private var closed = false
    var afterAdd: (() -> Void)?
    var beforeClose: (() -> Void)?
    var afterClose: (() -> Void)?
    var additions = 0, withdrawals = 0, closes = 0
    init(log: ScopedDNSTestLog) { self.log = log }
    func currentValue() -> NSDictionary? { closed ? nil : value }
    func add(_ value: NSDictionary) throws {
        log.events.append("store.add")
        guard !closed, self.value == nil else { throw ScopedDNSTestError.expected }
        self.value = value; ownsValue = true; additions += 1; afterAdd?()
    }
    func close() {
        guard !closed else { return }
        beforeClose?()
        log.events.append("session.close")
        closed = true; closes += 1
        if ownsValue { value = nil; withdrawals += 1 }
        afterClose?()
    }
}
private final class ScopedDNSTestProxy: ScopedDNSProxyServing {
    let log: ScopedDNSTestLog
    let domains: [String]
    var stopped = false
    var updates: [[String]] = []
    var completion: ((Result<Void, Error>) -> Void)?
    var failure: ((Error) -> Void)?
    init(log: ScopedDNSTestLog, domains: [String]) { self.log = log; self.domains = domains }
    func start(completion: @escaping (Result<Void, Error>) -> Void, onFailure: @escaping (Error) -> Void) {
        log.events.append("proxy.start"); self.completion = completion; failure = onFailure
    }
    func update(directCIDRs: [String]) { updates.append(directCIDRs); log.events.append(directCIDRs.isEmpty ? "policy.empty" : "policy.update") }
    func stop() { log.events.append("proxy.stop"); stopped = true }
}
private final class ScopedDNSTestVerifier: ScopedDNSResolverVerifying {
    let log: ScopedDNSTestLog
    var adopted = true, withdrawn = true, underlyingTailscale = true
    var withdrawalSnapshot: (() throws -> String)?
    init(log: ScopedDNSTestLog) { self.log = log }
    func isAdopted(port: UInt16, order: Int) -> Bool {
        XCTAssertEqual(port, 53535); XCTAssertEqual(order, 100)
        log.events.append("verify.adopted"); return adopted
    }
    func hasTailscaleDefaultExcludingRootResolver(port: UInt16, order: Int) -> Bool { underlyingTailscale }
    func waitUntilWithdrawn(port: UInt16) -> Bool {
        XCTAssertEqual(port, 53535); log.events.append("verify.withdrawn")
        if let withdrawalSnapshot {
            return ScopedDNSSystemVerifier(snapshot: withdrawalSnapshot, timeout: 0).waitUntilWithdrawn(port: port)
        }
        return withdrawn
    }
}
private final class ScopedDNSTestEnvironment {
    let log = ScopedDNSTestLog()
    lazy var session = ScopedDNSTestSession(log: log)
    lazy var verifier = ScopedDNSTestVerifier(log: log)
    var servers = ["100.100.100.100"]
    var globalDNS: [String: Any]?
    var proxies: [ScopedDNSTestProxy] = []
    var healthy = true
    var clock: TimeInterval = 100
    func controller(domains: [String] = ["qq.com", "cn"]) -> ScopedDNSController {
        ScopedDNSController(domains: domains, defaultDNS: { self.globalDNS ?? ["ServerAddresses": self.servers] },
            makeSession: { self.log.events.append("session.make"); return self.session },
            makeProxy: { port, cidrs, domains in
                XCTAssertEqual(port, 53535); XCTAssertTrue(cidrs.contains("223.5.5.0/24"))
                self.log.events.append("proxy.make")
                let proxy = ScopedDNSTestProxy(log: self.log, domains: domains); self.proxies.append(proxy); return proxy
            }, verifier: verifier, healthCheck: { _ in self.log.events.append("health"); return self.healthy },
            time: { self.clock }, automaticRetries: false)
    }
    func begin(_ controller: ScopedDNSController) {
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(proxies.count, 1)
    }
    func finish(_ controller: ScopedDNSController) {
        proxies.last?.completion?(.success(())); _ = controller.status()
    }
    func activate(_ controller: ScopedDNSController) {
        begin(controller); finish(controller); XCTAssertTrue(controller.status().active)
    }
}

final class ScopedDNSTests: XCTestCase {
    func testOwnResolverPromotionIntoGlobalDNSStaysActiveAcrossUpdates() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.session.afterAdd = { env.globalDNS = Self.ownGlobalDNS }
        env.activate(controller)
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertTrue(controller.status().active)
        XCTAssertEqual(env.proxies.count, 1)
        XCTAssertEqual(env.session.additions, 1)
    }
    func testInitialLoopbackGlobalDoesNotAuthorizeTakingOverDNS() {
        let env = ScopedDNSTestEnvironment(); env.globalDNS = Self.ownGlobalDNS
        let controller = env.controller()
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        XCTAssertTrue(env.proxies.isEmpty)
    }
    func testUnderlyingTailscaleDisappearanceWithdrawsOwnGlobalResolver() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.session.afterAdd = { env.globalDNS = Self.ownGlobalDNS }
        env.activate(controller)
        env.verifier.underlyingTailscale = false
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        XCTAssertNil(env.session.value)
        XCTAssertTrue(env.proxies[0].stopped)
    }
    func testUnderlyingDNSChangeDuringPublicationRemovesNewResolver() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.session.afterAdd = { env.globalDNS = Self.ownGlobalDNS; env.verifier.underlyingTailscale = false }
        env.begin(controller); env.finish(controller)
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(env.session.additions, 1)
        XCTAssertNil(env.session.value)
        XCTAssertTrue(env.proxies[0].stopped)
    }
    func testForeignGlobalDNSWithdrawsEvenWhenTailscaleFallbackRemains() {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["ServerAddresses"] = ["9.9.9.9"] },
            { $0["ServerAddresses"] = ["127.0.0.1", "8.8.8.8"] },
            { $0["ServerPort"] = 53534 }, { $0["SearchOrder"] = 99 },
            { $0["__CONFIGURATION_ID__"] = "Supplemental: other 0" },
            { $0.removeValue(forKey: "__CONFIGURATION_ID__") }
        ]
        for mutate in mutations {
            let env = ScopedDNSTestEnvironment(), controller = env.controller()
            env.session.afterAdd = { env.globalDNS = Self.ownGlobalDNS }
            env.activate(controller)
            var changed = Self.ownGlobalDNS; mutate(&changed); env.globalDNS = changed
            controller.update(directCIDRs: ["223.5.5.0/24"])
            XCTAssertFalse(controller.status().active)
            XCTAssertNil(env.session.value)
        }
    }
    func testOwnGlobalCannotAuthorizeReplacedSessionKey() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.session.afterAdd = { env.globalDNS = Self.ownGlobalDNS }
        env.activate(controller)
        let foreign: NSDictionary = ["ServerAddresses": ["9.9.9.9"]]
        env.session.value = foreign
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(env.session.value, foreign)
        XCTAssertEqual(env.session.withdrawals, 0)
    }
    func testUnderlyingDefaultVerifierSelectsLowestRemainingUnscopedRoot() {
        let ownRoot = Self.rootSnapshot.components(separatedBy: "DNS configuration (for scoped queries)")[0]
        let tailscale = "\nresolver #2\n  nameserver[0] : 100.100.100.100\n  nameserver[1] : fd7a:115c:a1e0::53\n  order : 101400\n"
        let base = ownRoot + tailscale
        XCTAssertTrue(ScopedDNSSystemVerifier.snapshotHasTailscaleDefaultExcludingRootResolver(base, port: 53535, order: 100))
        let laterForeign = base + "\nresolver #3\n  nameserver[0] : 192.168.1.1\n  order : 200000\n"
        XCTAssertTrue(ScopedDNSSystemVerifier.snapshotHasTailscaleDefaultExcludingRootResolver(laterForeign, port: 53535, order: 100))
        for order in [101399, 101400] {
            let foreign = base + "\nresolver #3\n  nameserver[0] : 192.168.1.1\n  order : \(order)\n"
            XCTAssertFalse(ScopedDNSSystemVerifier.snapshotHasTailscaleDefaultExcludingRootResolver(foreign, port: 53535, order: 100))
        }
        for changed in [base.replacingOccurrences(of: "100.100.100.100", with: "9.9.9.9"),
                        base.replacingOccurrences(of: "  nameserver[0] : 100.100.100.100\n", with: ""),
                        base.replacingOccurrences(of: "order : 101400", with: "port : 5353\n  order : 101400"),
                        base.replacingOccurrences(of: "order : 101400", with: ""),
                        base.replacingOccurrences(of: "resolver #2", with: "resolver #2\n  domain : ts.net"),
                        base.replacingOccurrences(of: "resolver #2", with: "resolver #2\n  flags : Scoped"),
                        Self.rootSnapshot, ownRoot, "", "No DNS configuration available"] {
            XCTAssertFalse(ScopedDNSSystemVerifier.snapshotHasTailscaleDefaultExcludingRootResolver(changed, port: 53535, order: 100))
        }
    }
    func testUnderlyingDefaultVerifierFailsClosedOnSnapshotFailure() {
        let verifier = ScopedDNSSystemVerifier(snapshot: { throw ScopedDNSTestError.expected }, timeout: 0)
        XCTAssertFalse(verifier.hasTailscaleDefaultExcludingRootResolver(port: 53535, order: 100))
    }
    private static let ownGlobalDNS: [String: Any] = [
        "ServerAddresses": ["127.0.0.1"], "ServerPort": NSNumber(value: 53535),
        "SearchOrder": NSNumber(value: 100),
        "__CONFIGURATION_ID__": "Supplemental: com.routeweaver.domestic-dns 0"
    ]
    func testStartsBothListenersAndChecksHealthBeforePublishingSingleRootResolver() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.begin(controller)
        XCTAssertNil(env.session.value)
        XCTAssertEqual(env.log.events, ["proxy.make", "proxy.start"])
        env.finish(controller)
        XCTAssertTrue(controller.status().active)
        XCTAssertEqual(env.log.events, ["proxy.make", "proxy.start", "health", "session.make", "store.add", "verify.adopted"])
        XCTAssertEqual(env.session.value?["SupplementalMatchDomains"] as? [String], [""])
        XCTAssertEqual(env.session.value?["SupplementalMatchOrders"] as? [Int], [100])
        XCTAssertEqual(env.session.value?["SupplementalMatchDomainsNoSearch"] as? NSNumber, NSNumber(value: 1))
        XCTAssertEqual(env.session.value?["ServerAddresses"] as? [String], ["127.0.0.1"])
        XCTAssertEqual(env.session.value?["ServerPort"] as? UInt16, 53535)
        XCTAssertEqual(controller.status().domainCount, 2)
    }
    func testLargeDomainListStaysInsideProxyAndDoesNotExpandSystemResolver() {
        let env = ScopedDNSTestEnvironment()
        let domains = (0..<8000).map { "site\($0).cn" }
        let controller = env.controller(domains: domains)
        env.activate(controller)
        XCTAssertEqual(env.proxies[0].domains.count, 8000)
        XCTAssertEqual(controller.status().domainCount, 8000)
        XCTAssertEqual(env.session.value?["SupplementalMatchDomains"] as? [String], [""])
    }
    func testCurrentNonTailscaleOrMixedDNSIsNeverTakenOver() {
        for servers in [[], ["192.168.1.1"], ["100.100.100.100", "8.8.8.8"]] as [[String]] {
            let env = ScopedDNSTestEnvironment(); env.servers = servers
            let controller = env.controller(); controller.update(directCIDRs: ["223.5.5.0/24"])
            XCTAssertFalse(controller.status().active)
            XCTAssertTrue(env.proxies.isEmpty); XCTAssertNil(env.session.value)
        }
    }
    func testNoProxyWhenVerifiedPlanDoesNotContainDoHEndpoint() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        for routes in [["1.2.3.0/24"], ["223.5.5.6/32"], ["10.0.0.0/8"], ["invalid"]] {
            controller.update(directCIDRs: routes); XCTAssertFalse(controller.status().active)
        }
        XCTAssertTrue(env.proxies.isEmpty)
    }
    func testListenerFailureBeforeReadyNeverPublishesResolver() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.begin(controller); env.proxies[0].completion?(.failure(ScopedDNSTestError.expected))
        XCTAssertFalse(controller.status().active); XCTAssertNil(env.session.value)
        XCTAssertTrue(env.proxies[0].stopped)
    }
    func testHealthFailureNeverPublishesResolver() {
        let env = ScopedDNSTestEnvironment(); env.healthy = false
        let controller = env.controller(); env.begin(controller); env.finish(controller)
        XCTAssertFalse(controller.status().active); XCTAssertEqual(env.session.additions, 0)
        XCTAssertTrue(env.proxies[0].stopped)
    }
    func testDNSChangesDuringStartupPreventPublishing() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.begin(controller); env.servers = ["1.1.1.1"]; env.finish(controller)
        XCTAssertFalse(controller.status().active); XCTAssertEqual(env.session.additions, 0)
    }
    func testFailedSystemAdoptionRemovesOwnKeyBeforeClosingProxy() {
        let env = ScopedDNSTestEnvironment(); env.verifier.adopted = false
        let controller = env.controller(); env.begin(controller); env.finish(controller)
        XCTAssertFalse(controller.status().active)
        XCTAssertNil(env.session.value)
        XCTAssertEqual(Array(env.log.events.suffix(4)), ["policy.empty", "session.close", "verify.withdrawn", "proxy.stop"])
    }
    func testStopWithdrawsResolverAndWaitsForReadbackBeforeListenerStop() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller); env.log.events.removeAll(); controller.stop()
        XCTAssertFalse(controller.status().active)
        XCTAssertTrue(controller.status().withdrawn)
        XCTAssertEqual(env.log.events, ["policy.empty", "session.close", "verify.withdrawn", "proxy.stop"])
    }
    func testFailedReadbackKeepsFallbackListenerAliveUntilRetrySucceeds() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller)
        env.verifier.withdrawalSnapshot = { throw ScopedDNSTestError.expected }
        controller.stop()
        XCTAssertFalse(controller.status().active)
        XCTAssertFalse(controller.status().withdrawn)
        XCTAssertFalse(env.proxies[0].stopped)
        XCTAssertEqual(env.proxies[0].updates.last, [])
        XCTAssertNil(env.session.value)
        XCTAssertEqual(env.session.closes, 1)
        XCTAssertTrue(controller.status().message.contains("等待系统撤销"))
        // A second failed readback must retain the marker even without a session.
        controller.stop()
        XCTAssertFalse(env.proxies[0].stopped)
        env.verifier.withdrawalSnapshot = { "No DNS configuration available" }
        controller.stop()
        XCTAssertTrue(env.proxies[0].stopped)
        XCTAssertTrue(controller.status().withdrawn)
        XCTAssertEqual(env.session.closes, 1)
    }
    func testReadbackLagKeepsListenerAliveAfterKeyRemoval() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller); env.verifier.withdrawn = false; controller.stop()
        XCTAssertNil(env.session.value); XCTAssertFalse(env.proxies[0].stopped)
        XCTAssertFalse(controller.status().active)
        env.verifier.withdrawn = true; controller.stop()
        XCTAssertTrue(env.proxies[0].stopped)
    }
    func testReenableAfterWithdrawalCreatesFreshSessionAndIgnoresOldCallbacks() throws {
        let log = ScopedDNSTestLog(), verifier = ScopedDNSTestVerifier(log: log)
        var sessions: [ScopedDNSTestSession] = []
        var proxies: [ScopedDNSTestProxy] = []
        let tailscaleDNS: [String: Any] = ["ServerAddresses": ["100.100.100.100"]]
        var globalDNS = tailscaleDNS
        let controller = ScopedDNSController(domains: ["cn"], defaultDNS: { globalDNS },
            makeSession: {
                // A new publisher may not overlap an older session's live key.
                XCTAssertTrue(sessions.allSatisfy { $0.value == nil })
                let session = ScopedDNSTestSession(log: log)
                session.afterAdd = { globalDNS = Self.ownGlobalDNS }
                session.afterClose = { globalDNS = tailscaleDNS }
                sessions.append(session)
                return session
            }, makeProxy: { _, _, domains in
                let proxy = ScopedDNSTestProxy(log: log, domains: domains)
                proxies.append(proxy)
                return proxy
            }, verifier: verifier, healthCheck: { _ in true }, automaticRetries: false)
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        let oldProxy = try XCTUnwrap(proxies.first)
        oldProxy.completion?(.success(()))
        XCTAssertTrue(controller.status().active)
        let oldSession = try XCTUnwrap(sessions.first)
        let oldSessionID = oldSession.value?["RouteWeaverSession"] as? String

        verifier.withdrawn = false
        controller.stop()
        XCTAssertEqual(oldSession.closes, 1)
        XCTAssertNil(oldSession.value)
        XCTAssertFalse(oldProxy.stopped)
        XCTAssertEqual(oldProxy.updates.last, [])
        oldProxy.completion?(.success(())); oldProxy.failure?(ScopedDNSTestError.expected)
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(sessions.count, 1)
        verifier.withdrawn = true
        controller.stop()
        XCTAssertTrue(oldProxy.stopped)

        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(proxies.count, 2)
        let newProxy = try XCTUnwrap(proxies.last)
        XCTAssertFalse(newProxy === oldProxy)
        oldProxy.completion?(.success(())); oldProxy.failure?(ScopedDNSTestError.expected)
        XCTAssertFalse(controller.status().active)
        XCTAssertFalse(newProxy.stopped)
        XCTAssertEqual(sessions.count, 1)
        newProxy.completion?(.success(()))
        XCTAssertTrue(controller.status().active)
        XCTAssertEqual(sessions.count, 2)
        let newSession = try XCTUnwrap(sessions.last)
        XCTAssertFalse(newSession === oldSession)
        XCTAssertEqual(oldSession.additions, 1)
        XCTAssertEqual(oldSession.closes, 1)
        XCTAssertEqual(newSession.additions, 1)
        XCTAssertEqual(newSession.closes, 0)
        XCTAssertNotEqual(newSession.value?["RouteWeaverSession"] as? String, oldSessionID)

        oldProxy.completion?(.success(())); oldProxy.failure?(ScopedDNSTestError.expected)
        XCTAssertTrue(controller.status().active)
        XCTAssertFalse(newProxy.stopped)
        XCTAssertNotNil(newSession.value)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(newSession.closes, 0)
        controller.shutdown()
    }
    func testChangedForeignValueIsNeverRemoved() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller)
        let foreign: NSDictionary = ["ServerAddresses": ["9.9.9.9"], "RouteWeaverSession": "another-session"]
        env.session.value = foreign; controller.stop()
        XCTAssertEqual(env.session.withdrawals, 0)
        XCTAssertEqual(env.session.value, foreign)
    }
    func testForeignSamePortTakeoverImmediatelyBeforeCloseIsPreserved() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller)
        let foreign = ScopedDNSController.resolverValue(sessionID: "foreign-before-close")
        env.session.beforeClose = { env.session.value = foreign }
        env.verifier.withdrawalSnapshot = { Self.rootSnapshot }
        controller.stop()
        XCTAssertEqual(env.session.value, foreign)
        XCTAssertEqual(env.session.withdrawals, 0)
        XCTAssertEqual(env.session.closes, 1)
        XCTAssertFalse(env.proxies[0].stopped)
        XCTAssertEqual(env.proxies[0].updates.last, [])
        controller.stop()
        XCTAssertEqual(env.session.value, foreign)
        XCTAssertEqual(env.session.closes, 1)
        XCTAssertFalse(env.proxies[0].stopped)
    }
    func testForeignSamePortTakeoverImmediatelyAfterCloseIsPreserved() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller)
        let foreign = ScopedDNSController.resolverValue(sessionID: "foreign-after-close")
        env.session.afterClose = { env.session.value = foreign }
        env.verifier.withdrawalSnapshot = { Self.rootSnapshot }
        controller.stop()
        XCTAssertEqual(env.session.value, foreign)
        XCTAssertEqual(env.session.withdrawals, 1)
        XCTAssertEqual(env.session.closes, 1)
        XCTAssertFalse(env.proxies[0].stopped)
        XCTAssertEqual(env.proxies[0].updates.last, [])
        // Subsequent withdrawal checks must never modify the replacement key.
        controller.stop()
        XCTAssertEqual(env.session.value, foreign)
        XCTAssertEqual(env.session.withdrawals, 1)
        XCTAssertFalse(env.proxies[0].stopped)
    }
    func testIdenticalExternalRewriteBeforeCloseRevokesSessionOwnership() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller)
        let replacement = env.session.value
        env.session.beforeClose = { env.session.value = replacement }
        env.verifier.withdrawalSnapshot = { Self.rootSnapshot }
        controller.stop()
        XCTAssertEqual(env.session.value, replacement)
        XCTAssertEqual(env.session.withdrawals, 0)
        XCTAssertFalse(env.proxies[0].stopped)
    }
    func testCreateOnlyCollisionNeverOverwritesExistingResolver() {
        let env = ScopedDNSTestEnvironment()
        let foreign: NSDictionary = ["ServerAddresses": ["9.9.9.9"]]
        env.session.value = foreign
        let controller = env.controller(); env.begin(controller); env.finish(controller)
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(env.session.value, foreign); XCTAssertEqual(env.session.withdrawals, 0)
        XCTAssertTrue(env.proxies[0].stopped)
    }
    func testStopInvalidatesLateStartupCallback() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.begin(controller); controller.stop(); env.finish(controller)
        XCTAssertFalse(controller.status().active); XCTAssertEqual(env.session.additions, 0)
    }
    func testShutdownPermanentlyPreventsReopeningIncludingLateCallbacks() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.begin(controller); controller.shutdown(); env.finish(controller)
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active); XCTAssertEqual(env.proxies.count, 1)
        XCTAssertEqual(env.session.additions, 0)
    }
    func testRepeatedShutdownClosesSessionOnceAndRetainsListenerUntilReadback() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller); env.log.events.removeAll()
        env.verifier.withdrawn = false
        controller.shutdown(); controller.shutdown()
        XCTAssertEqual(env.session.closes, 1)
        XCTAssertEqual(env.session.withdrawals, 1)
        XCTAssertFalse(env.proxies[0].stopped)
        XCTAssertEqual(env.proxies[0].updates.last, [])
        XCTAssertEqual(env.log.events.filter { $0 == "session.close" }.count, 1)
        env.verifier.withdrawn = true
        controller.shutdown(); controller.shutdown()
        XCTAssertEqual(env.log.events.filter { $0 == "proxy.stop" }.count, 1)
        XCTAssertEqual(env.session.closes, 1)
        controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertFalse(controller.status().active)
        XCTAssertEqual(env.proxies.count, 1)
        XCTAssertEqual(env.session.additions, 1)
    }
    func testRepeatedVerifiedPolicyIsIdempotent() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller); controller.update(directCIDRs: ["223.5.5.0/24"])
        XCTAssertTrue(controller.status().active)
        XCTAssertEqual(env.proxies.count, 1); XCTAssertEqual(env.session.additions, 1)
    }
    func testRuntimeFailureWithdrawsPublishedResolver() {
        let env = ScopedDNSTestEnvironment(), controller = env.controller()
        env.activate(controller); env.proxies[0].failure?(ScopedDNSTestError.expected)
        XCTAssertFalse(controller.status().active)
        XCTAssertNil(env.session.value); XCTAssertTrue(env.proxies[0].stopped)
    }
    func testOnlyExclusiveTailscaleGlobalDNSAllowsProxy() {
        XCTAssertTrue(ScopedDNSController.usesTailscaleDefaultDNS(["ServerAddresses": ["100.100.100.100"]]))
        XCTAssertTrue(ScopedDNSController.usesTailscaleDefaultDNS(["ServerAddresses": ["100.100.100.100", "fd7a:115c:a1e0::53"]]))
        XCTAssertFalse(ScopedDNSController.usesTailscaleDefaultDNS(["ServerAddresses": ["fd7a:115c:a1e0::53"]]))
        XCTAssertFalse(ScopedDNSController.usesTailscaleDefaultDNS(nil))
        XCTAssertFalse(ScopedDNSController.usesTailscaleDefaultDNS(["ServerAddresses": "100.100.100.100"]))
    }
    func testDomainPolicySupportsFullListButRejectsUnsafeScopes() throws {
        XCTAssertEqual(try ScopedDNSController.validatedDomains(["qq.com", "cn", "qq.com"]), ["cn", "qq.com"])
        XCTAssertFalse(try ScopedDNSController.validatedDomains(DomesticDomains.suffixes).isEmpty)
        for value in ["", ".", "com", "ts.net", "x.ts.net", "tailscale.com", "a.arpa", "local", "QQ.COM", "a..cn", "127.0.0.1"] {
            XCTAssertThrowsError(try ScopedDNSController.validatedDomains([value]), value)
        }
        XCTAssertThrowsError(try ScopedDNSController.validatedDomains(Array(repeating: "qq.com", count: 200_001)))
    }
    func testVerifierRequiresAdoptedRootPortOrderAndUnscopedSection() {
        let fixture = Self.rootSnapshot
        XCTAssertTrue(ScopedDNSSystemVerifier.snapshotAdoptsRootResolver(fixture, port: 53535, order: 100))
        XCTAssertTrue(ScopedDNSSystemVerifier.snapshotContainsLoopbackResolver(fixture, port: 53535))
        for changed in [fixture.replacingOccurrences(of: "53535", with: "53"),
                        fixture.replacingOccurrences(of: "order    : 100", with: "order    : 200"),
                        fixture.replacingOccurrences(of: "resolver #1", with: "resolver #1\n  domain : qq.com"),
                        fixture.replacingOccurrences(of: "DNS configuration", with: "DNS configuration (for scoped queries)")] {
            XCTAssertFalse(ScopedDNSSystemVerifier.snapshotAdoptsRootResolver(changed, port: 53535, order: 100))
        }
    }
    func testWithdrawalVerificationFailsClosedOnUnavailableOrMalformedSnapshot() {
        let throwing = ScopedDNSSystemVerifier(snapshot: { throw ScopedDNSTestError.expected }, timeout: 0)
        XCTAssertFalse(throwing.waitUntilWithdrawn(port: 53535))
        let malformed = ScopedDNSSystemVerifier(snapshot: { "" }, timeout: 0)
        XCTAssertFalse(malformed.waitUntilWithdrawn(port: 53535))
        let absent = ScopedDNSSystemVerifier(snapshot: { "No DNS configuration available" }, timeout: 0)
        XCTAssertTrue(absent.waitUntilWithdrawn(port: 53535))
        let stillPresent = ScopedDNSSystemVerifier(snapshot: { Self.rootSnapshot }, timeout: 0)
        XCTAssertFalse(stillPresent.waitUntilWithdrawn(port: 53535))
    }
    func testPresenceDoesNotCountAsAdoptionWhenAnotherRootResolverHasPriority() {
        let rootOnly = Self.rootSnapshot.components(separatedBy: "DNS configuration (for scoped queries)")[0]
        for order in [50, 100] {
            let competing = rootOnly + "\nresolver #2\n  nameserver[0] : 9.9.9.9\n  order : \(order)\n"
            XCTAssertFalse(ScopedDNSSystemVerifier.snapshotAdoptsRootResolver(competing, port: 53535, order: 100))
        }
        let fallback = rootOnly + "\nresolver #2\n  nameserver[0] : 100.100.100.100\n  order : 200000\n"
        XCTAssertTrue(ScopedDNSSystemVerifier.snapshotAdoptsRootResolver(fallback, port: 53535, order: 100))
    }
    private static let rootSnapshot = """
    DNS configuration

    resolver #1
      nameserver[0] : 127.0.0.1
      port     : 53535
      flags    : Supplemental, Request A records
      order    : 100

    DNS configuration (for scoped queries)
    resolver #1
      nameserver[0] : 100.100.100.100
      flags    : Scoped, Request A records
    """
}
