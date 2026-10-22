import Foundation

struct RecoveryCancelled: Error {}

/// Shared by the state queue and its serialized worker. Cancellation does not
/// take the worker's queue or wait for a subprocess to finish.
final class RecoveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func throwIfCancelled() throws { if isCancelled { throw RecoveryCancelled() } }
}
