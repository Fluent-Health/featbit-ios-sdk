import Foundation

#if canImport(Combine)
import Combine
#endif

/// An opaque, cancellable token returned by ``FlagTracker`` subscriptions.
///
/// Keep a reference for as long as you want the subscription alive; call ``cancel()`` (or release
/// the token) to stop receiving events.
public final class FlagSubscription {
    private let onCancel: () -> Void
    private var cancelled = false
    private let lock = NSLock()

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let shouldCancel = !cancelled
        cancelled = true
        lock.unlock()
        if shouldCancel { onCancel() }
    }

    deinit { cancel() }
}

/// Observes feature-flag value changes.
///
/// Changes are delivered three ways, all fed from the same source: closure ``subscribe(_:)``
/// listeners, an `AsyncStream` via ``changes``, and — on Apple platforms — a Combine publisher via
/// `flagChanges`.
public protocol FlagTracker: AnyObject {
    /// Subscribes to changes for **all** flags. Returns a token; release or ``FlagSubscription/cancel()``
    /// it to unsubscribe.
    @discardableResult
    func subscribe(_ handler: @escaping (FlagValueChangedEvent) -> Void) -> FlagSubscription

    /// Subscribes to changes for a **specific** flag key.
    @discardableResult
    func subscribe(key: String, _ handler: @escaping (FlagValueChangedEvent) -> Void) -> FlagSubscription

    /// An `AsyncStream` of change events for all flags. Each access returns an independent stream.
    var changes: AsyncStream<FlagValueChangedEvent> { get }
}

#if canImport(Combine)
public extension FlagTracker {
    /// A Combine publisher of change events for all flags (Apple platforms only).
    var flagChanges: AnyPublisher<FlagValueChangedEvent, Never> {
        guard let impl = self as? FlagTrackerImpl else {
            return Empty(completeImmediately: false).eraseToAnyPublisher()
        }
        return impl.subject.eraseToAnyPublisher()
    }
}
#endif
