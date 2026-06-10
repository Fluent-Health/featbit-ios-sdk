import Foundation

/// Internal result of looking a flag up in the store, prior to type conversion.
struct EvalResult {
    let isValid: Bool
    let reason: String
    let value: String

    /// The caller provided a key that did not match any known flag.
    static let flagNotFound = EvalResult(isValid: false, reason: "flag not found", value: "")

    static func of(_ flag: FeatureFlag) -> EvalResult {
        EvalResult(isValid: true, reason: flag.matchReason, value: flag.variation)
    }
}
