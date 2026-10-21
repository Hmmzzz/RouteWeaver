import Foundation

/// Pure recovery decisions. The privileged service performs and acknowledges
/// each effect; a failed cleanup can never lead to a new installation.
public struct RecoveryStateMachine {
    public enum Phase: String, Codable, Sendable { case disabled, waitingNetwork, stabilizing, removing, applying, active, backingOff }
    public enum Action: Equatable { case none, rollback, apply }
    public private(set) var phase: Phase = .disabled
    public private(set) var enabled = false
    public private(set) var retryAt: TimeInterval = 0
    public private(set) var failures = 0
    private var needsCleanup = false
    private var applied: String?
    private var candidate: String?
    private var stableSince: TimeInterval = 0
    public let stabilityInterval: TimeInterval
    public init(stabilityInterval: TimeInterval = 2) { self.stabilityInterval = stabilityInterval }

    public mutating func enable() {
        enabled = true; needsCleanup = true; candidate = nil
        failures = 0; retryAt = 0; phase = .waitingNetwork
    }
    public mutating func disable() {
        enabled = false; needsCleanup = true; candidate = nil
        failures = 0; retryAt = 0; phase = .removing
    }
    public mutating func invalidateTopology() {
        if applied != nil { needsCleanup = true }
        candidate = nil; retryAt = 0
    }
    public mutating func observationFailed(now: TimeInterval) { fail(now: now) }
    public mutating func decide(fingerprint: String?, repairNeeded: Bool = false, now: TimeInterval) -> Action {
        if let applied, applied != fingerprint { needsCleanup = true }
        guard now >= retryAt else { phase = .backingOff; return .none }
        if needsCleanup { phase = .removing; return .rollback }
        guard enabled else { phase = .disabled; return .none }
        guard let fingerprint else { candidate = nil; phase = .waitingNetwork; return .none }
        if applied == fingerprint && !repairNeeded { phase = .active; return .none }
        if candidate != fingerprint {
            candidate = fingerprint; stableSince = now; phase = .stabilizing; return .none
        }
        guard now - stableSince >= stabilityInterval else { phase = .stabilizing; return .none }
        phase = .applying; return .apply
    }
    public mutating func didRollback(success: Bool, now: TimeInterval) {
        if success {
            needsCleanup = false; applied = nil; candidate = nil
            phase = enabled ? .waitingNetwork : .disabled
            // Preserve the apply failure backoff through successful cleanup.
        } else { fail(now: now) }
    }
    public mutating func didApply(fingerprint: String, success: Bool, now: TimeInterval) {
        if success {
            applied = fingerprint; candidate = fingerprint; failures = 0
            retryAt = 0; phase = .active
        } else {
            // A partial installation is treated as owned state requiring cleanup.
            applied = fingerprint; needsCleanup = true; candidate = nil; fail(now: now)
        }
    }
    private mutating func fail(now: TimeInterval) {
        failures += 1; retryAt = now + min(300, pow(2, Double(min(failures, 9))))
        phase = .backingOff
    }
}
