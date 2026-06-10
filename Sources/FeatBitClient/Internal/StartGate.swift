import Foundation

/// A one-shot async signal resolving to a `Bool`, the Swift analogue of Kotlin's
/// `CompletableDeferred<Boolean>`. Safe to `complete` before or after `wait`, and idempotent.
final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func wait() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(returning: result)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func complete(_ value: Bool) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
