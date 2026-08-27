import Foundation
@testable import FeatBitClient

/// `MemoryStore` decorator that blocks the FIRST upsert on a barrier + 10s deadline.
///
/// Used to prove `closeAndJoin` awaits in-flight upserts before returning.
final class BarrierStore: MemoryStore, @unchecked Sendable {
    private let inner: MemoryStore
    private let enter = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var firstDone = false

    init(_ inner: MemoryStore) { self.inner = inner }

    /// Signalled when the first upsert enters.
    func waitForEnter(timeout: TimeInterval) -> Bool {
        enter.wait(timeout: .now() + timeout) == .success
    }

    /// Release the blocked upsert.
    func releaseUpsert() { release.signal() }

    func get(_ id: String) -> FeatureFlag? { inner.get(id) }
    func getAll() -> [FeatureFlag] { inner.getAll() }

    func upsert(_ flag: FeatureFlag) {
        let shouldBlock: Bool = lock.withLock {
            if firstDone { return false }
            firstDone = true
            return true
        }
        if shouldBlock {
            enter.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        inner.upsert(flag)
    }

    func addChangeListener(_ listener: FlagChangeListener) { inner.addChangeListener(listener) }
    func removeChangeListener(_ listener: FlagChangeListener) { inner.removeChangeListener(listener) }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
