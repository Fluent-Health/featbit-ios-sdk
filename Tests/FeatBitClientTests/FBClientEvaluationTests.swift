import XCTest
@testable import FeatBitClient

final class FBClientEvaluationTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func offlineClient(_ flags: [FeatureFlag]) throws -> DefaultFBClient {
        let options = try FBOptions.Builder()
            .offline(true)
            .bootstrap(flags)
            .build()
        return DefaultFBClient(options: options, user: FBUser.builder("u1").build())
    }

    func testBootstrapEvaluation() async throws {
        let client = try offlineClient([
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

    func testUnknownFlagReturnsDefaultWithReason() async throws {
        let client = try offlineClient([])
        _ = await client.start(timeout: 1)
        let detail = client.boolVariationDetail("missing", default: true)
        XCTAssertTrue(detail.value)
        XCTAssertEqual(detail.reason, "flag not found")
        client.close()
    }

    func testTypeMismatchReturnsDefault() async throws {
        let client = try offlineClient([
            FeatureFlag(id: "str-flag", variation: "not-a-bool", variationType: "string", matchReason: "default"),
        ])
        _ = await client.start(timeout: 1)
        let detail = client.boolVariationDetail("str-flag", default: false)
        XCTAssertFalse(detail.value)
        XCTAssertEqual(detail.reason, "type mismatch")
        client.close()
    }

    func testClientNotReadyReturnsDefault() throws {
        // Online client (polling), never started, no bootstrap → "client not ready" without any network.
        let options = try FBOptions.Builder("secret").polling("https://eval.example.com").build()
        let client = DefaultFBClient(options: options, user: FBUser.builder("u1").build())
        let detail = client.boolVariationDetail("any", default: false)
        XCTAssertEqual(detail.reason, "client not ready")
        client.close()
    }

    func testAllFlagsSnapshot() async throws {
        let client = try offlineClient([
            FeatureFlag(id: "a", variation: "1"),
            FeatureFlag(id: "b", variation: "2"),
        ])
        _ = await client.start(timeout: 1)
        let all = client.allFlags()
        XCTAssertEqual(Set(all.keys), ["a", "b"])
        client.close()
    }

    func testCloseAndJoinIsIdempotent() async throws {
        let client = try offlineClient([])
        _ = await client.start(timeout: 1)
        await client.closeAndJoin()
        let start = Date()
        await client.closeAndJoin()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "second closeAndJoin should be near-instant")
    }

    func testCloseAndJoinCompletesPromptlyOffline() async throws {
        let client = try offlineClient([])
        _ = await client.start(timeout: 1)
        let start = Date()
        await client.closeAndJoin()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "offline closeAndJoin should complete in under 500ms")
    }

    // MARK: Aggressive pinning (Task 16) — identify + close contract.
    //
    // Network-dependent tests (identify swap over polling, start-timeout under
    // hung server, closeAndJoin bounded under blocked sync) require URLSession
    // injection into DefaultFBClient — a knob the SDK does not yet expose. The
    // MockURLProtocol test helper only intercepts URLSession instances explicitly
    // configured with it; `URLProtocol.registerClass` does NOT affect ephemeral
    // sessions that the SDK constructs internally, so tests using that path hang
    // on real DNS. Deferred to a future task that adds a session-injection seam
    // on DefaultFBClient. Two coverage points that DO work offline are captured
    // here.

    func testClosePreservesStoreAndBootstrapEvaluationsSurvive() async throws {
        // Mutation: a close() that wiped the store would fail — bootstrap flags
        // must remain queryable after teardown.
        let flag = FeatureFlag(id: "f", variation: "v", matchReason: "default")
        let client = try offlineClient([flag])
        _ = await client.start(timeout: 1)
        XCTAssertEqual(client.stringVariation("f", default: "x"), "v")
        await client.closeAndJoin()
        XCTAssertEqual(client.stringVariation("f", default: "x"), "v", "close must not wipe the store")
    }

    func testOfflineIdentifyReturnsTrueWithoutNetwork() async throws {
        // Mutation: identify wiring up an online synchronizer in offline mode would
        // hit real DNS and time out. NullDataSynchronizer.start returns true
        // vacuously; identify must resolve true.
        let client = try offlineClient([])
        _ = await client.start(timeout: 1)
        let ok = await client.identify(FBUser.builder("B").build(), timeout: 1)
        XCTAssertTrue(ok, "offline identify must be true — Null synchronizer is vacuously ready")
        await client.closeAndJoin()
    }

    func testValueAndDetailPathsAgreeAcrossConverters() async throws {
        let flags: [FeatureFlag] = [
            FeatureFlag(id: "b", variation: "true", matchReason: "T"),
            FeatureFlag(id: "i", variation: "42", matchReason: "T"),
            FeatureFlag(id: "s", variation: "hello", matchReason: "T"),
        ]
        let client = try offlineClient(flags)
        _ = await client.start(timeout: 1)
        XCTAssertEqual(client.boolVariation("b", default: false), client.boolVariationDetail("b", default: false).value)
        XCTAssertEqual(client.intVariation("i", default: 0), client.intVariationDetail("i", default: 0).value)
        XCTAssertEqual(client.stringVariation("s", default: ""), client.stringVariationDetail("s", default: "").value)
        await client.closeAndJoin()
    }

    func testFastPathGuardNotReadyReturnsDefault() async throws {
        // Mutation: dropping the `if !initialized && options.bootstrap.isEmpty` guard
        // in evaluateValue would let evaluations skip past the not-ready check.
        let options = try FBOptions.Builder("secret").polling("https://p.example.com").build()
        let client = DefaultFBClient(options: options, user: FBUser.builder("u").build())
        XCTAssertEqual(client.stringVariation("k", default: "default"), "default")
        client.close()
    }
}
