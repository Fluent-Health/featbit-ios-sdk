import Foundation

/// Represents a feature flag and its current evaluation result for the current user.
///
/// This is the data returned by the FeatBit evaluation server and stored in the SDK's
/// in-memory store. Field names map directly to the server's camelCase JSON payload.
public struct FeatureFlag: Codable, Equatable, Sendable {
    /// The unique key of the feature flag.
    public let id: String
    /// The string representation of the evaluated variation value.
    public let variation: String
    /// The declared type of the variation (e.g. `boolean`, `string`, `number`, `json`).
    public let variationType: String
    /// The id of the evaluated variation.
    public let variationId: String
    /// Whether evaluations of this flag should be sent to experimentation.
    public let sendToExperiment: Bool
    /// A human-readable description of why this variation was returned.
    public let matchReason: String

    public init(
        id: String = "",
        variation: String = "",
        variationType: String = "",
        variationId: String = "",
        sendToExperiment: Bool = false,
        matchReason: String = ""
    ) {
        self.id = id
        self.variation = variation
        self.variationType = variationType
        self.variationId = variationId
        self.sendToExperiment = sendToExperiment
        self.matchReason = matchReason
    }

    // Tolerant decoding: every field defaults when absent, mirroring the Kotlin
    // `Json { ignoreUnknownKeys = true }` + default-valued data class behavior.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        variation = try c.decodeIfPresent(String.self, forKey: .variation) ?? ""
        variationType = try c.decodeIfPresent(String.self, forKey: .variationType) ?? ""
        variationId = try c.decodeIfPresent(String.self, forKey: .variationId) ?? ""
        sendToExperiment = try c.decodeIfPresent(Bool.self, forKey: .sendToExperiment) ?? false
        matchReason = try c.decodeIfPresent(String.self, forKey: .matchReason) ?? ""
    }
}
