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
}
