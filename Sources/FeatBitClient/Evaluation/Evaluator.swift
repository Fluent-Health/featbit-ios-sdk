import Foundation

/// Resolves a feature flag from the store, returning the lookup ``EvalResult`` alongside the
/// matched ``FeatureFlag`` (or `nil` when the flag is unknown).
struct Evaluator {
    private let store: MemoryStore

    init(store: MemoryStore) {
        self.store = store
    }

    func evaluate(_ key: String) -> (EvalResult, FeatureFlag?) {
        guard let flag = store.get(key) else {
            return (.flagNotFound, nil)
        }
        return (.of(flag), flag)
    }
}
