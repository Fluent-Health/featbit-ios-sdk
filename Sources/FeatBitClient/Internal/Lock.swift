import Foundation

/// A small mutex wrapper exposing a synchronous `withLock`, so locking never happens directly in an
/// `async` scope (which Swift 6 forbids for `NSLock`). The critical section is always synchronous.
final class Lock: @unchecked Sendable {
    private let underlying = NSLock()

    func withLock<T>(_ body: () -> T) -> T {
        underlying.lock()
        defer { underlying.unlock() }
        return body()
    }
}
