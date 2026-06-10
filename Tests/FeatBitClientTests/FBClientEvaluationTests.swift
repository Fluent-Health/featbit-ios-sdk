import XCTest
@testable import FeatBitClient

final class FBClientEvaluationTests: XCTestCase {
    private func offlineClient(_ flags: [FeatureFlag]) -> DefaultFBClient {
        let options = FBOptions.Builder()
            .offline(true)
            .bootstrap(flags)
            .build()
        return DefaultFBClient(options: options, user: FBUser.builder("u1").build())
    }

    func testBootstrapEvaluation() async {
        let client = offlineClient([
            FeatureFlag(id: "bool-flag", variation: "true", variationType: "boolean", matchReason: "default"),
            FeatureFlag(id: "str-flag", variation: "hello", variationType: "string", matchReason: "rule match"),
            FeatureFlag(id: "int-flag", variation: "42", variationType: "number", matchReason: "default"),
        ])
        let ready = await client.start(timeout: 1)
        XCTAssertTrue(ready) // offline is ready immediately

        XCTAssertTrue(client.boolVariation("bool-flag", default: false))
        XCTAssertEqual(client.stringVariation("str-flag", default: ""), "hello")
        XCTAssertEqual(client.intVariation("int-flag", default: 0), 42)

        let detail = client.stringVariationDetail("str-flag", default: "")
        XCTAssertEqual(detail.value, "hello")
        XCTAssertEqual(detail.reason, "rule match")
        client.close()
    }

    func testUnknownFlagReturnsDefaultWithReason() async {
        let client = offlineClient([])
        _ = await client.start(timeout: 1)
        let detail = client.boolVariationDetail("missing", default: true)
        XCTAssertTrue(detail.value)
        XCTAssertEqual(detail.reason, "flag not found")
        client.close()
    }

    func testTypeMismatchReturnsDefault() async {
        let client = offlineClient([
            FeatureFlag(id: "str-flag", variation: "not-a-bool", variationType: "string", matchReason: "default"),
        ])
        _ = await client.start(timeout: 1)
        let detail = client.boolVariationDetail("str-flag", default: false)
        XCTAssertFalse(detail.value)
        XCTAssertEqual(detail.reason, "type mismatch")
        client.close()
    }

    func testClientNotReadyReturnsDefault() {
        // Online client (polling), never started, no bootstrap → "client not ready" without any network.
        let options = FBOptions.Builder("secret").polling("https://eval.example.com").build()
        let client = DefaultFBClient(options: options, user: FBUser.builder("u1").build())
        let detail = client.boolVariationDetail("any", default: false)
        XCTAssertEqual(detail.reason, "client not ready")
        client.close()
    }

    func testAllFlagsSnapshot() async {
        let client = offlineClient([
            FeatureFlag(id: "a", variation: "1"),
            FeatureFlag(id: "b", variation: "2"),
        ])
        _ = await client.start(timeout: 1)
        let all = client.allFlags()
        XCTAssertEqual(Set(all.keys), ["a", "b"])
        client.close()
    }
}
