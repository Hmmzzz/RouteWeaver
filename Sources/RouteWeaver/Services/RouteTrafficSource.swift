import Foundation
import CRouteStatistics

struct RouteTrafficTarget: Equatable, Sendable {
    var key: String
    var network: UInt32
    var mask: UInt32
    var gateway: UInt32
    var interfaceIndex: UInt32
}

/// All blocking kernel I/O is serialized away from the main actor. No helper,
/// child process, packet capture, or persistent traffic history is involved.
final class RouteTrafficSource: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RouteWeaver.route-statistics", qos: .utility)
    private let generationLock = NSLock()
    private var generation: UInt64 = 0
    // Accessed only on `queue`; pending closures retain self until I/O ends.
    private var handle: OpaquePointer?
    private var connectedTargets: [RouteTrafficTarget] = []

    deinit { if let handle { rw_stats_close(handle) } }

    func read(_ targets: [RouteTrafficTarget]) async -> [String: TrafficByteCounters]? {
        guard !Task.isCancelled else { return nil }
        let token = currentGeneration()
        guard !targets.isEmpty, targets.count <= 20_000,
              Set(targets.map(\.key)).count == targets.count else { return nil }
        let ordered = targets.sorted { $0.key < $1.key }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard token == currentGeneration() else { continuation.resume(returning: nil); return }
                if connectedTargets != ordered { closeOnQueue() }
                if handle == nil {
                    let specifications = ordered.map {
                        RWStatsTarget(network: $0.network, mask: $0.mask, gateway: $0.gateway, interface_index: $0.interfaceIndex)
                    }
                    var error: Int32 = 0
                    handle = specifications.withUnsafeBufferPointer {
                        rw_stats_open($0.baseAddress, $0.count, 2_000, &error)
                    }
                    guard handle != nil else { continuation.resume(returning: nil); return }
                    connectedTargets = ordered
                }
                var values = [RWStatsCounters](repeating: RWStatsCounters(received: 0, sent: 0), count: ordered.count)
                let result = values.withUnsafeMutableBufferPointer {
                    rw_stats_read(handle, $0.baseAddress, $0.count, 1_000)
                }
                guard result == 0, token == currentGeneration() else {
                    closeOnQueue()
                    continuation.resume(returning: nil)
                    return
                }
                var counters: [String: TrafficByteCounters] = [:]
                counters.reserveCapacity(ordered.count)
                for index in ordered.indices {
                    counters[ordered[index].key] = .init(received: values[index].received, sent: values[index].sent)
                }
                continuation.resume(returning: counters)
            }
        }
    }

    /// Invalidates queued/in-flight results immediately; descriptor shutdown is
    /// serialized after the bounded operation, never races close against recv.
    func stop() {
        generationLock.lock()
        generation &+= 1
        generationLock.unlock()
        queue.async { [self] in closeOnQueue() }
    }

    private func currentGeneration() -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    private func closeOnQueue() {
        if let handle { rw_stats_close(handle) }
        handle = nil
        connectedTargets = []
    }
}
