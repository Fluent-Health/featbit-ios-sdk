import Foundation

/// In-memory store of the current user's feature flags.
///
/// Reads are synchronous (and lock-free at the read site, mirroring the Kotlin
/// `ConcurrentHashMap`) so flag evaluation can run from a SwiftUI `body` without `await`.
protocol MemoryStore: AnyObject, Sendable {
    func get(_ id: String) -> FeatureFlag?
    func getAll() -> [FeatureFlag]
    func upsert(_ flag: FeatureFlag)
    func addChangeListener(_ listener: FlagChangeListener)
    func removeChangeListener(_ listener: FlagChangeListener)
}
