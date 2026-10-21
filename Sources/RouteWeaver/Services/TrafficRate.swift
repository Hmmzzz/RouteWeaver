import Foundation

struct TrafficRateReading: Equatable, Sendable {
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var detail: String
    static func unknown(_ detail: String) -> Self {
        .init(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil, detail: detail)
    }
}

struct TrafficByteCounters: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64
}

/// Compare each source separately: a reset in one route must not be hidden by
/// an increase in another. ContinuousClock timestamps exclude wall-clock jumps.
struct TrafficRateSampler {
    private var previous: (values: [String: TrafficByteCounters], time: ContinuousClock.Instant)?
    mutating func reset() { previous = nil }
    mutating func sample(_ values: [String: TrafficByteCounters], at time: ContinuousClock.Instant, detail: String) -> TrafficRateReading {
        defer { previous = (values, time) }
        guard !values.isEmpty, let previous, previous.values.keys == values.keys else {
            return .unknown("正在建立速率基线。" + detail)
        }
        let duration = previous.time.duration(to: time).components
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        guard seconds > 0, seconds <= 15 else { return .unknown("采样间隔改变，正在重新采样。" + detail) }
        var received = 0.0, sent = 0.0
        for (key, value) in values {
            guard let old = previous.values[key], value.received >= old.received, value.sent >= old.sent else {
                return .unknown("计数器已重置，正在重新采样。" + detail)
            }
            received += Double(value.received - old.received)
            sent += Double(value.sent - old.sent)
        }
        return .init(downloadBytesPerSecond: received / seconds, uploadBytesPerSecond: sent / seconds, detail: detail)
    }
}
