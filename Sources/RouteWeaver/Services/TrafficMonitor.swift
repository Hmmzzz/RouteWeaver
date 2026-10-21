import AppKit
import Foundation
import Observation

/// A counter-source failure only delays another attempt for the same verified
/// service context. No route snapshot or counter baseline is reused while waiting.
struct DirectTrafficBackoff {
    struct Context: Equatable {
        var gateway: String
        var interface: String
        var routeCount: Int
    }
    private var failure: (context: Context, retryAfter: ContinuousClock.Instant)?

    mutating func recordFailure(in context: Context, at now: ContinuousClock.Instant) {
        failure = (context, now.advanced(by: .seconds(30)))
    }

    mutating func shouldWait(in context: Context, at now: ContinuousClock.Instant) -> Bool {
        guard let failure else { return false }
        guard failure.context == context, now < failure.retryAfter else {
            reset()
            return false
        }
        return true
    }

    mutating func reset() { failure = nil }
}

@MainActor @Observable
final class TrafficMonitor {
    private(set) var direct = TrafficRateReading.unknown("等待已验证的直连路由。")
    private(set) var tailscale = TrafficRateReading.unknown("等待识别 Tailscale 接口。")
    // This preference controls only the status-item label. The open panel is
    // an independent consumer of the same sampler.
    private(set) var showsMenuBarRates: Bool
    private(set) var isSampling = false
    private var isPopoverVisible = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let routeSource = RouteTrafficSource()
    @ObservationIgnored private var routes: OwnedTrafficRoutes?
    @ObservationIgnored private var directSampler = TrafficRateSampler()
    @ObservationIgnored private var tailscaleSampler = TrafficRateSampler()
    @ObservationIgnored private var identity: TailscaleTrafficIdentity?
    @ObservationIgnored private var identityReadAt: ContinuousClock.Instant?
    @ObservationIgnored private var directBackoff = DirectTrafficBackoff()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Retain the existing choice while narrowing its meaning to the menu bar.
        showsMenuBarRates = defaults.object(forKey: "trafficMonitoringEnabled") as? Bool ?? true
    }

    func start(store: AppStore) {
        self.store = store
        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
        reconcileSampling()
    }

    func setShowsMenuBarRates(_ visible: Bool) {
        guard visible != showsMenuBarRates else { return }
        showsMenuBarRates = visible
        defaults.set(visible, forKey: "trafficMonitoringEnabled")
        reconcileSampling()
    }

    func setPopoverVisible(_ visible: Bool) {
        guard visible != isPopoverVisible else { return }
        isPopoverVisible = visible
        reconcileSampling()
    }

    func stop() {
        // An application stop must not be reversed by a late panel disappearance.
        store = nil
        pauseSampling()
    }

    private func reconcileSampling() {
        guard store != nil, showsMenuBarRates || isPopoverVisible else {
            if isSampling { pauseSampling() }
            return
        }
        // Keep baselines and in-flight reads when either surface still needs them.
        guard loop == nil else { return }
        isSampling = true
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private func pauseSampling() {
        isSampling = false
        loop?.cancel(); loop = nil
        resetDirect()
        identity = nil; identityReadAt = nil; tailscaleSampler.reset()
        direct = .unknown("等待新的直连速率采样。")
        tailscale = .unknown("等待新的 Tailscale 速率采样。")
    }

    private func resetDirect() {
        generation = UUID()
        routeSource.stop(); routes = nil
        directSampler.reset()
        directBackoff.reset()
    }

    private func tick() async {
        guard isSampling, !Task.isCancelled, let store else { return }
        await sampleDirect(store)
        guard isSampling, !Task.isCancelled else { return }
        let now = ContinuousClock.now
        if identityReadAt == nil || identityReadAt!.duration(to: now) >= .seconds(30) {
            let refreshed = await TailscaleTrafficIdentity.read()
            guard isSampling, !Task.isCancelled else { return }
            identity = refreshed
            identityReadAt = .now
        }
        guard let identity, let (name, index) = identity.interface(), let counters = InterfaceTrafficCounters.read(index: index) else {
            tailscaleSampler.reset()
            tailscale = .unknown("无法确认 Tailscale 接口或读取计数；不以其他 VPN 接口代替。")
            return
        }
        // Including both name and index prevents reusing a baseline on a new interface.
        tailscale = tailscaleSampler.sample(["\(name):\(index):\(identity.addresses.sorted().joined(separator: ","))": counters], at: .now,
            detail: "Tailscale 接口 \(name) 的总流量，包含 Tailnet 与 IPv4/IPv6；不等于仅 exit node 流量。")
    }

    private func sampleDirect(_ store: AppStore) async {
        if store.serviceReachable, store.serviceVerified, !store.serviceEnabled,
           store.servicePhase == "disabled", store.activeRouteCount == 0, store.pendingRouteCount == 0 {
            resetDirect()
            direct = .init(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0, detail: "已确认分流关闭，没有 RouteWeaver 直连路由。")
            return
        }
        guard store.serviceReachable, store.serviceVerified, store.serviceEnabled, store.servicePhase == "active",
              store.pendingRouteCount == 0, let count = store.activeRouteCount, count > 0,
              let gateway = store.serviceGateway, let interface = store.serviceInterface else {
            resetDirect()
            direct = .unknown("直连路由状态尚未验证；不将物理网卡流量视为国内直连。")
            return
        }
        let context = DirectTrafficBackoff.Context(gateway: gateway, interface: interface, routeCount: count)
        if directBackoff.shouldWait(in: context, at: .now) {
            direct = .unknown("系统未提供完整且可验证的直连计数，稍后重试。")
            return
        }
        let owned = await Task.detached(priority: .utility) {
            OwnedTrafficRoutes.read(gateway: gateway, interface: interface, expectedCount: count)
        }.value
        guard !Task.isCancelled, isSampling else { return }
        guard store.serviceReachable, store.serviceVerified, store.serviceEnabled, store.servicePhase == "active",
              store.pendingRouteCount == 0, store.activeRouteCount == count, store.serviceGateway == gateway, store.serviceInterface == interface else {
            resetDirect(); direct = .unknown("路由状态已改变，正在重新采样。")
            return
        }
        guard let owned else {
            resetDirect()
            direct = .unknown("内核直连路由与服务状态不一致，暂不统计。")
            return
        }
        if let routes, routes != owned { resetDirect() }
        routes = owned
        let token = generation
        let values = await routeSource.read(owned.targets)
        guard token == generation, !Task.isCancelled, isSampling else { return }
        guard store.serviceReachable, store.serviceVerified, store.serviceEnabled, store.servicePhase == "active",
              store.pendingRouteCount == 0, store.activeRouteCount == count,
              store.serviceGateway == gateway, store.serviceInterface == interface else {
            resetDirect(); direct = .unknown("路由状态已改变，正在重新采样。")
            return
        }
        guard let values, values.count == owned.targets.count else {
            resetDirect(); directBackoff.recordFailure(in: context, at: .now)
            direct = .unknown("系统未提供完整且可验证的直连计数，稍后重试。")
            return
        }
        directBackoff.reset()
        direct = directSampler.sample(values, at: .now,
            detail: "已核验直连 IPv4 路由的内核计数，包含自定义直连规则；不含 Tailscale 隧道开销。")
    }
}
