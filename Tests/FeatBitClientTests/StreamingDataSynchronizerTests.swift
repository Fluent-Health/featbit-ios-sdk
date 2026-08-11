import XCTest
@testable import FeatBitClient

#if canImport(Darwin)

final class StreamingDataSynchronizerTests: XCTestCase {
    // `URLSessionWebSocketTask` only accepts ws/wss URLs (CFNetwork throws NSGenericException for
    // http/https, unlike OkHttp on Android which requires the opposite). The streaming endpoint
    // must therefore normalize every accepted input form to ws(s). Endpoint parsing lives in
    // `FBEndpoints.parseWS`; assert directly on the parsed `streamingWs` URL.
    func testStreamingEndpointKeepsWsScheme() throws {
        let wss = try FBEndpoints.from(
            pollingUri: "https://p.com",
            eventUri: "https://e.com",
            streamingUri: "wss://eval.example.com"
        )
        XCTAssertEqual(wss.streamingWs.absoluteString, "wss://eval.example.com/streaming")

        let ws = try FBEndpoints.from(
            pollingUri: "https://p.com",
            eventUri: "https://e.com",
            streamingUri: "ws://localhost:5100"
        )
        XCTAssertEqual(ws.streamingWs.absoluteString, "ws://localhost:5100/streaming")
    }

    func testStreamingEndpointConvertsHttpSchemeToWs() throws {
        let https = try FBEndpoints.from(
            pollingUri: "https://p.com",
            eventUri: "https://e.com",
            streamingUri: "https://eval.example.com"
        )
        XCTAssertEqual(https.streamingWs.absoluteString, "wss://eval.example.com/streaming")

        let http = try FBEndpoints.from(
            pollingUri: "https://p.com",
            eventUri: "https://e.com",
            streamingUri: "http://localhost:5100"
        )
        XCTAssertEqual(http.streamingWs.absoluteString, "ws://localhost:5100/streaming")
    }
}

#endif
