import Foundation

/// Synchronizes feature flag data from FeatBit into the SDK's store.
protocol DataSynchronizer: AnyObject, Sendable {
    /// Whether the synchronizer has completed its first successful synchronization.
    var initialized: Bool { get }

    /// Starts synchronization and returns once the first synchronization completes (`true`), or
    /// `false` if a fatal error stopped synchronization.
    func start() async -> Bool

    /// Temporarily stops network activity (e.g. app backgrounded or offline) while preserving
    /// already-synced data. Safe to call repeatedly. Default: no-op.
    func pause()

    /// Resumes synchronization after a ``pause()`` and forces an immediate resync. Safe to call
    /// repeatedly. Default: no-op.
    func resume()

    func close()
}

extension DataSynchronizer {
    func pause() {}
    func resume() {}
}
