import Foundation

/// An analytics event reported to the FeatBit insight endpoint.
///
/// Two flavours exist, mirroring the .NET SDK:
///  - a flag-evaluation insight carrying a single ``VariationInsight``;
///  - a user-identify insight carrying an empty ``variations`` list.
struct Insight: Codable, Equatable, Sendable {
    let user: EndUser
    let variations: [VariationInsight]

    static func forEvaluation(user: FBUser, flag: FeatureFlag, timestamp: Int64) -> Insight {
        Insight(user: user.toEndUser(), variations: [VariationInsight.of(flag: flag, timestamp: timestamp)])
    }

    static func forIdentify(user: FBUser) -> Insight {
        Insight(user: user.toEndUser(), variations: [])
    }
}

struct VariationInsight: Codable, Equatable, Sendable {
    let featureFlagKey: String
    let variation: VariationData
    let sendToExperiment: Bool
    let timestamp: Int64

    static func of(flag: FeatureFlag, timestamp: Int64) -> VariationInsight {
        VariationInsight(
            featureFlagKey: flag.id,
            variation: VariationData(id: flag.variationId, value: flag.variation),
            sendToExperiment: flag.sendToExperiment,
            timestamp: timestamp
        )
    }
}

struct VariationData: Codable, Equatable, Sendable {
    let id: String
    let value: String
}
