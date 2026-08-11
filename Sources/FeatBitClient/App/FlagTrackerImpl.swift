import Foundation

#if canImport(Combine)
import Combine
#endif

/// Default ``FlagTracker``. Registers a single ``FlagChangeListener`` with the store and fans every
/// change out to global subscribers, key-specific subscribers, the ``changes`` `AsyncStream`(s),
/// and (on Apple platforms) the Combine `flagChanges` publisher.
final class FlagTrackerImpl: FlagTracker, FlagChangeListener, @unchecked Sendable {
    private let lock = NSLock()
    private var globalHandlers: [UUID: (FlagValueChangedEvent) -> Void] = [:]
    private var keyedHandlers: [String: [UUID: (FlagValueChangedEvent) -> Void]] = [:]
    private var streamContinuations: [UUID: AsyncStream<FlagValueChangedEvent>.Continuation] = [:]

    private weak var store: MemoryStore?

    #if canImport(Combine)
    let subject = PassthroughSubject<FlagValueChangedEvent, Never>()
    #endif

    init(store: MemoryStore) {
        self.store = store
        store.addChangeListener(self)
    }

    // MARK: FlagChangeListener

    func onChange(_ event: FlagValueChangedEvent) {
        lock.lock()
        let globals = Array(globalHandlers.values)
        let keyed = Array((keyedHandlers[event.key] ?? [:]).values)
        let continuations = Array(streamContinuations.values)
        lock.unlock()

        for handler in globals { handler(event) }
        for handler in keyed { handler(event) }
        for continuation in continuations { continuation.yield(event) }
        #if canImport(Combine)
        subject.send(event)
        #endif
    }

    // MARK: FlagTracker

    @discardableResult
    func subscribe(_ handler: @escaping (FlagValueChangedEvent) -> Void) -> FlagSubscription {
        let id = UUID()
        lock.lock()
        globalHandlers[id] = handler
        lock.unlock()
        return FlagSubscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.globalHandlers[id] = nil
            self.lock.unlock()
        }
    }

    @discardableResult
    func subscribe(key: String, _ handler: @escaping (FlagValueChangedEvent) -> Void) -> FlagSubscription {
        let id = UUID()
        lock.lock()
        keyedHandlers[key, default: [:]][id] = handler
        lock.unlock()
        return FlagSubscription { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.keyedHandlers[key]?[id] = nil
            if self.keyedHandlers[key]?.isEmpty == true { self.keyedHandlers[key] = nil }
            self.lock.unlock()
        }
    }

    var changes: AsyncStream<FlagValueChangedEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            streamContinuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.streamContinuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        globalHandlers.removeAll()
        keyedHandlers.removeAll()
        let continuations = Array(streamContinuations.values)
        streamContinuations.removeAll()
        lock.unlock()
        for continuation in continuations { continuation.finish() }
        store?.removeChangeListener(self)
    }
}
