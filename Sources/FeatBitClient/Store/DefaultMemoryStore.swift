import Foundation

/// Default ``MemoryStore`` backed by a dictionary guarded by a lock.
///
/// The "compute change event then store" sequence is atomic under the lock, matching the .NET /
/// Kotlin `DefaultMemoryStore`. Change listeners are notified outside the lock. Listeners are held
/// weakly so a tracker/store pair does not form a retain cycle.
final class DefaultMemoryStore: MemoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: FeatureFlag] = [:]
    private var listeners: [WeakListener] = []

    private final class WeakListener {
        weak var value: FlagChangeListener?
        init(_ value: FlagChangeListener) { self.value = value }
    }

    init(bootstrap: [FeatureFlag] = []) {
        for flag in bootstrap {
            items[flag.id] = flag
        }
    }

    func get(_ id: String) -> FeatureFlag? {
        lock.lock(); defer { lock.unlock() }
        return items[id]
    }

    func getAll() -> [FeatureFlag] {
        lock.lock(); defer { lock.unlock() }
        return Array(items.values)
    }

    func upsert(_ flag: FeatureFlag) {
        lock.lock()
        let existing = items[flag.id]
        let event: FlagValueChangedEvent?
        if existing == nil {
            event = FlagValueChangedEvent(key: flag.id, oldValue: nil, newValue: flag.variation)
        } else if existing!.variation != flag.variation {
            event = FlagValueChangedEvent(key: flag.id, oldValue: existing!.variation, newValue: flag.variation)
        } else {
            event = nil
        }
        items[flag.id] = flag
        let snapshot = listeners.compactMap { $0.value }
        lock.unlock()

        if let event {
            for listener in snapshot {
                listener.onChange(event)
            }
        }
    }

    func addChangeListener(_ listener: FlagChangeListener) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeAll { $0.value == nil || $0.value === listener }
        listeners.append(WeakListener(listener))
    }

    func removeChangeListener(_ listener: FlagChangeListener) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeAll { $0.value == nil || $0.value === listener }
    }
}
