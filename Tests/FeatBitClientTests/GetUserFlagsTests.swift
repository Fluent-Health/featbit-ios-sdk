import XCTest
@testable import FeatBitClient

final class GetUserFlagsTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func makeClient() -> GetUserFlags {
        let options = FBOptions.Builder("secret")
            .polling("https://eval.example.com")
            .build()
        let user = FBUser.builder("u1").name("u").custom("country", "FR").build()
        return GetUserFlags(options: options, user: user, session: MockURLProtocol.session())
    }

    func testSuccessParsesFlagsAndPostsEndUser() async {
        MockURLProtocol.handler = { _ in
            let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"true","variationType":"boolean","matchReason":"default"}]}}"#
            return (200, Data(body.utf8))
        }

        let response = await makeClient().run(timestamp: 123)

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

    func testBlankBodyYieldsEmptyFlags() async {
        MockURLProtocol.handler = { _ in (200, Data()) }
        let response = await makeClient().run(timestamp: 0)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.flags.isEmpty)
    }

    func test401IsFatal() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let response = await makeClient().run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.isFatal)
    }

    func test500IsTransient() async {
        MockURLProtocol.handler = { _ in (500, Data()) }
        let response = await makeClient().run(timestamp: 0)
        XCTAssertTrue(response.isError)
        XCTAssertFalse(response.isFatal)
    }
}
