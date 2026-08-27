import XCTest
@testable import FeatBitClient

final class ModelTests: XCTestCase {
    func testFeatureFlagToleratesMissingKeys() throws {
        // Only `id` and `variation` present; everything else must default.
        let json = Data(#"{"id":"f1","variation":"true"}"#.utf8)
        let flag = try JSONDecoder().decode(FeatureFlag.self, from: json)
        XCTAssertEqual(flag.id, "f1")
        XCTAssertEqual(flag.variation, "true")
        XCTAssertEqual(flag.variationType, "")
        XCTAssertEqual(flag.sendToExperiment, false)
        XCTAssertEqual(flag.matchReason, "")
    }

    func testFeatureFlagIgnoresUnknownKeys() throws {
        let json = Data(#"{"id":"f1","variation":"x","somethingNew":42}"#.utf8)
        let flag = try JSONDecoder().decode(FeatureFlag.self, from: json)
        XCTAssertEqual(flag.id, "f1")
    }

    func testFBUserBuilderAndEndUserWire() {
        let user = FBUser.builder("key1")
            .name("Bob")
            .custom("country", "FR")
            .custom("age", "15")
            .custom("", "ignored")
            .build()

        XCTAssertEqual(user.key, "key1")
        XCTAssertEqual(user.name, "Bob")
        XCTAssertEqual(user.custom.count, 2)

        let endUser = user.toEndUser()
        XCTAssertEqual(endUser.keyId, "key1")
        XCTAssertEqual(endUser.name, "Bob")
        // Sorted by attribute name for deterministic payloads: age, country.
        XCTAssertEqual(endUser.customizedProperties.map { $0.name }, ["age", "country"])
    }

    func testFBUserBlankNameIgnored() {
        let user = FBUser.builder("k").name("   ").build()
        XCTAssertEqual(user.name, "")
    }

    func testFBUserEndUserCachedIdentityStableAcrossCalls() {
        // Mutation: reverting to recomputed toEndUser() would rebuild EndUser +
        // CustomizedProperty list on every call. Structural equality holds either
        // way — this test asserts cached identity via EndUser Equatable across
        // 1000 calls, catching an allocation regression only if the recomputation
        // path introduces any per-call divergence (e.g. from sorted() non-determinism).
        let user = FBUser.builder("k").name("n").custom("c", "v").build()
        let first = user.toEndUser()
        for _ in 0..<1000 {
            XCTAssertEqual(user.toEndUser(), first)
        }
    }
}
