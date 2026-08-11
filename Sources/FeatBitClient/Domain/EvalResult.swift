import Foundation

/// Internal result of looking a flag up in the store, prior to type conversion.
///
/// Sealed enum: callers pattern-match instead of consulting a boolean `isValid`.
/// Wire-compatible `reason` strings preserved.
enum EvalResult: Equatable {
    case found(FeatureFlag)
    case notFound(reason: String)

    /// Wire-compatible reason string (matches what the .NET / Kotlin SDKs emit).
    var reason: String {
        switch self {
        case .found(let flag): return flag.matchReason
        case .notFound(let reason): return reason
        }
    }

    /// True when the result carries a matched flag. Retained for test ergonomics;
    /// production callers pattern-match on the case instead.
    var isValid: Bool {
        if case .found = self { return true } else { return false }
    }

    /// Raw variation string when `.found`, empty otherwise. Retained for test
    /// ergonomics; production callers extract `flag.variation` via pattern match.
    var value: String {
        if case .found(let flag) = self { return flag.variation } else { return "" }
    }

    /// Reserved reason for a missing flag.
    static let flagNotFound: EvalResult = .notFound(reason: "flag not found")
}
