import Foundation

// Module-internal timeout primitives. Used by DefaultFBClient (start / identify / close)
// and future callers (closeAndJoin, insight drain). Not part of the public API surface.

/// Runs `operation`, returning its result, or `nil` if it does not complete within `seconds`.
///
/// Swift equivalent of Kotlin's `withTimeoutOrNull`. Structured concurrency joins both
/// children before returning: `cancelAll` marks the loser cancelled, and `withTaskGroup`
/// awaits it to completion so no task escapes the group. `Task.sleep` throws
/// `CancellationError` on cancel, which is swallowed by `try?` — the sleep child returns
/// `nil` on both natural expiration and cancellation.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Runs `operation`, returning its `Bool` result, or `false` if it does not complete
/// within `seconds`. Callers cannot distinguish "operation returned false" from "timed
/// out"; use the generic overload with `T = Bool` for `Bool?` semantics if that
/// distinction matters. Delegates to the generic overload via a `Bool?` wrapper to keep
/// the double-optional collapse airtight (timeout → outer nil → false; false-from-op →
/// inner .some(false) → false).
func withTimeout(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> Bool
) async -> Bool {
    let wrapped: @Sendable () async -> Bool? = { await operation() }
    let result: Bool?? = await withTimeout(seconds: seconds, wrapped)
    return (result ?? nil) ?? false
}
