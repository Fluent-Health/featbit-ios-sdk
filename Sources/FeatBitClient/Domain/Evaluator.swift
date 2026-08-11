import Foundation

/// Resolves a feature flag from the store.
struct Evaluator {
    private let store: MemoryStore

    init(store: MemoryStore) {
        self.store = store
    }

    func evaluate(_ key: String) -> EvalResult {
        guard let flag = store.get(key) else { return .flagNotFound }
        return .found(flag)
    }
}
