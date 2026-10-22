import Foundation

/// A cancellation request may arrive before an asynchronous owner installs its
/// handler. Deliver it exactly once, always outside the lock so cancellation
/// handlers may safely call back into the request owner or this handle.
final class DNSCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    private var cancelled = false
    private var delivered = false

    init(_ handler: (() -> Void)? = nil) { self.handler = handler }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func setHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            let shouldDeliver = !delivered
            delivered = true
            lock.unlock()
            if shouldDeliver { handler() }
        } else {
            self.handler = handler
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let handler = self.handler
        self.handler = nil
        if handler != nil { delivered = true }
        lock.unlock()
        handler?()
    }
}

/// A valid DNS answer need not qualify for direct routing. Keep that distinct
/// from an unreachable or broken DoH service, and from local cancellation or
/// admission limits, so only actual upstream failures affect its health.
enum DNSDomesticResult {
    case response(DNSAAnswer?)
    case failure
    case unavailable
}
