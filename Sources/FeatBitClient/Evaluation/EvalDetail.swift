import Foundation

/// Describes the result of a feature flag evaluation: the resolved ``value`` (a flag variation or
/// the supplied default) and a ``reason`` describing the main factor that influenced it.
public struct EvalDetail<T: Sendable>: Sendable {
    /// A human-readable description of why this value was returned.
    public let reason: String
    /// The evaluated flag value, or the caller's default value.
    public let value: T

    public init(reason: String, value: T) {
        self.reason = reason
        self.value = value
    }
}

extension EvalDetail: Equatable where T: Equatable {}
