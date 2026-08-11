import Foundation

/// Wire representation of an ``FBUser`` as expected by the FeatBit evaluation and insight
/// endpoints. Mirrors the shape produced by `FbUser.AsEndUser()` in the .NET SDK.
struct EndUser: Codable, Equatable, Sendable {
    let keyId: String
    let name: String
    let customizedProperties: [CustomizedProperty]
}

struct CustomizedProperty: Codable, Equatable, Sendable {
    let name: String
    let value: String
}
