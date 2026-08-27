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

    /// Fire-and-forget close. Cancels work and returns immediately.
    func close()

    /// Suspending close: cancels work AND awaits in-flight upserts / send-completion. Callers
    /// use this from `identify` and `close` phases to prevent old-user data landing after
    /// switch or leaking teardown threads.
    func closeAndJoin() async
}

extension DataSynchronizer {
    func pause() {}
    func resume() {}
    /// Default fallback: fire close and return. Overridden by synchronizers that own a Task.
    func closeAndJoin() async { close() }
}
