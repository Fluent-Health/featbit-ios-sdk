import Foundation

/// In-memory store of the current user's feature flags.
///
/// Reads are synchronous (and lock-free at the read site, mirroring the Kotlin
/// `ConcurrentHashMap`) so flag evaluation can run from a SwiftUI `body` without `await`.
protocol MemoryStore: AnyObject, Sendable {
    func get(_ id: String) -> FeatureFlag?
    func getAll() -> [FeatureFlag]
    func upsert(_ flag: FeatureFlag)
    func upsertAll(_ flags: [FeatureFlag])
    func addChangeListener(_ listener: FlagChangeListener)
    func removeChangeListener(_ listener: FlagChangeListener)
}

extension MemoryStore {
    /// Default: iterate and dispatch to `upsert(_:)`. Overrides on concrete
    /// impls can lock-once + notify-after-lock for lower contention. Consumers
    /// must not depend on which ordering they see — both are valid.
    func upsertAll(_ flags: [FeatureFlag]) {
        for flag in flags { upsert(flag) }
    }
}
