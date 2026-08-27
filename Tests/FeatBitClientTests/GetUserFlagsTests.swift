import XCTest
@testable import FeatBitClient

final class GetUserFlagsTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func makeClient() throws -> GetUserFlags {
        let options = try FBOptions.Builder("secret")
            .polling("https://eval.example.com")
            .build()
        let user = FBUser.builder("u1").name("u").custom("country", "FR").build()
        return GetUserFlags(options: options, user: user, session: MockURLProtocol.session())
    }

    func testSuccessParsesFlagsAndPostsEndUser() async throws {
        MockURLProtocol.handler = { _ in
            let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"true","variationType":"boolean","matchReason":"default"}]}}"#
            return (200, Data(body.utf8))
        }

        let response = await (try makeClient()).run(timestamp: 123)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.isError)
        XCTAssertEqual(response.flags.count, 1)
        XCTAssertEqual(response.flags.first?.id, "f1")
        XCTAssertEqual(response.flags.first?.variation, "true")

        // Request shape: correct path, timestamp query, auth header, EndUser body.
        let request = MockURLProtocol.requests.first
        XCTAssertEqual(request?.url?.path, "/api/public/sdk/client/latest-all")
        XCTAssertEqual(request?.url?.query, "timestamp=123")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "secret")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "featbit-swift-client-sdk")

        if let body = MockURLProtocol.bodies.first,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            XCTAssertEqual(json["keyId"] as? String, "u1")
            let props = json["customizedProperties"] as? [[String: String]]
            XCTAssertEqual(props?.first?["name"], "country")
            XCTAssertEqual(props?.first?["value"], "FR")
        } else {
            XCTFail("expected an EndUser JSON body")
        }
    }

    func testBlankBodyYieldsEmptyFlags() async throws {
        MockURLProtocol.handler = { _ in (200, Data()) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.flags.isEmpty)
    }

    func test401IsFatal() async throws {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.isFatal)
    }

    func test500IsTransient() async throws {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertFalse(response.isFatal)
    }

    func testMissingDataFieldReturnsError() async throws {
        // Mutation: making `data` Optional and defaulting to nil would silently return .ok([]).
        MockURLProtocol.handler = { _ in (200, Data(#"{"other":"junk"}"#.utf8)) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertFalse(response.isFatal)
        XCTAssertEqual(response.statusCode, -1)
    }

    func testNullDataFieldReturnsError() async throws {
        // Mutation: same as above — explicit null on non-Optional Decodable field throws.
        MockURLProtocol.handler = { _ in (200, Data(#"{"data":null}"#.utf8)) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertEqual(response.statusCode, -1)
    }

    func testAbsentFeatureFlagsReturnsOkEmpty() async throws {
        // Backward-compat: absent inner list -> empty flag array, not error.
        MockURLProtocol.handler = { _ in (200, Data(#"{"data":{}}"#.utf8)) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.isError)
        XCTAssertTrue(response.flags.isEmpty)
    }

    func testMalformedJsonReturnsError() async throws {
        // Mutation: `try?` fallback to empty would let malformed JSON silently pass.
        MockURLProtocol.handler = { _ in (200, Data(#"{not valid json"#.utf8)) }
        let response = await (try makeClient()).run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertEqual(response.statusCode, -1)
    }
}
