import XCTest
@testable import FeatBitClient

final class TrackInsightTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func makeTracker() throws -> HttpTrackInsight {
        let options = try FBOptions.Builder("secret").event("https://events.example.com").build()
        return HttpTrackInsight(options: options, session: MockURLProtocol.session())
    }

    func testEvaluationInsightPostsSingleElementArray() async throws {
        MockURLProtocol.handler = { _ in (200, Data()) }
        let user = FBUser.builder("u1").name("u").build()
        let flag = FeatureFlag(id: "f1", variation: "true", variationId: "v1", sendToExperiment: true)

        await (try makeTracker()).run(.forEvaluation(user: user, flag: flag, timestamp: 999))

        let request = MockURLProtocol.requests.first
        XCTAssertEqual(request?.url?.path, "/api/public/insight/track")

        guard let body = MockURLProtocol.bodies.first,
              let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return XCTFail("expected a JSON array body")
        }
        XCTAssertEqual(array.count, 1)
        let variations = array.first?["variations"] as? [[String: Any]]
        XCTAssertEqual(variations?.count, 1)
        XCTAssertEqual(variations?.first?["featureFlagKey"] as? String, "f1")
        XCTAssertEqual(variations?.first?["sendToExperiment"] as? Bool, true)
        let variation = variations?.first?["variation"] as? [String: String]
        XCTAssertEqual(variation?["id"], "v1")
        XCTAssertEqual(variation?["value"], "true")
    }

    func testIdentifyInsightHasEmptyVariations() async throws {
        MockURLProtocol.handler = { _ in (200, Data()) }
        await (try makeTracker()).run(.forIdentify(user: FBUser.builder("u2").build()))

        guard let body = MockURLProtocol.bodies.first,
              let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return XCTFail("expected a JSON array body")
        }
        let variations = array.first?["variations"] as? [[String: Any]]
        XCTAssertEqual(variations?.count, 0)
    }

    // MARK: Aggressive pinning (Task 14) — batch + lifecycle contract.

    func testMultiElementBatchPostedAsSingleJsonArray() async throws {
        // Mutation: shipping batches as multiple single-item requests (regressing to
        // pre-Task-7 behavior) would fail the "1 request, 3-element array" assertion.
        MockURLProtocol.handler = { _ in (200, Data()) }
        let userA = FBUser.builder("uA").build()
        let userB = FBUser.builder("uB").build()
        let userC = FBUser.builder("uC").build()
        let tracker = try makeTracker()
        let insights: [Insight] = [
            .forIdentify(user: userA),
            .forIdentify(user: userB),
            .forIdentify(user: userC),
        ]
        await tracker.runBatch(insights)

        XCTAssertEqual(MockURLProtocol.requests.count, 1, "batch must be posted as ONE request")
        guard let body = MockURLProtocol.bodies.first,
              let array = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            return XCTFail("expected a JSON array body")
        }
        XCTAssertEqual(array.count, 3, "batch must contain 3 elements")
        let keyIds = array.compactMap { ($0["user"] as? [String: Any])?["keyId"] as? String }
        XCTAssertEqual(keyIds, ["uA", "uB", "uC"])
    }

    func testEmptyBatchIsNoOp() async throws {
        // Mutation: removing the `if insights.isEmpty { return }` guard in
        // HttpTrackInsight.runBatch would issue a request with an empty JSON array.
        MockURLProtocol.handler = { _ in (200, Data()) }
        await (try makeTracker()).runBatch([])
        XCTAssertEqual(MockURLProtocol.requests.count, 0, "empty batch must not issue a network request")
    }

    func testNoopTrackInsightIsNoOp() async {
        // Mutation: adding any side effect to Noop.run/runBatch/close would violate
        // the offline-mode contract. This test guards the "install as offline sink"
        // invariant — Noop must never spawn network work.
        MockURLProtocol.handler = { _ in (200, Data()) }
        let noop = NoopTrackInsight()
        await noop.run(.forIdentify(user: FBUser.builder("u").build()))
        await noop.runBatch([.forIdentify(user: FBUser.builder("u").build())])
        noop.close()
        XCTAssertEqual(MockURLProtocol.requests.count, 0, "NoopTrackInsight must never touch the network")
    }

    func testCloseIsIdempotent() throws {
        // Mutation: adding non-idempotent teardown to close() would crash on second
        // call. Today's impl is a no-op, so second call is trivially safe — this
        // test guards against future regressions.
        let tracker = try makeTracker()
        tracker.close()
        tracker.close() // no crash
    }
}
