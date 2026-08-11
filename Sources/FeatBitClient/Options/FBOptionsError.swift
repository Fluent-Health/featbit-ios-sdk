import Foundation

/// Errors surfaced eagerly from `FBOptions.Builder.build()` — malformed configuration
/// fails at SDK init, not on first network call.
public enum FBOptionsError: Error, Equatable {
    /// The polling / streaming / event URI failed to parse or is missing a host.
    case invalidURL(field: String, value: String)
    /// `pollingInterval` must be > 0.
    case invalidPollingInterval(TimeInterval)
    /// `backgroundGracePeriod` must be >= 0.
    case invalidGracePeriod(TimeInterval)
    /// `secret` is empty and the client is not offline.
    case missingSecret
}
