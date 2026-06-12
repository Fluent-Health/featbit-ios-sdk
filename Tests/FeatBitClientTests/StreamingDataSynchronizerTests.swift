import XCTest
@testable import FeatBitClient

#if canImport(Darwin)

final class StreamingDataSynchronizerTests: XCTestCase {
    // `URLSessionWebSocketTask` only accepts ws/wss URLs (CFNetwork throws NSGenericException for
    // http/https, unlike OkHttp on Android which requires the opposite). The streaming endpoint
    // must therefore normalize every accepted input form to ws(s).
    func testStreamingEndpointKeepsWsScheme() {
        XCTAssertEqual(
            StreamingDataSynchronizer.toStreamingWsURL("wss://eval.example.com").absoluteString,
            "wss://eval.example.com/streaming"
        )
        XCTAssertEqual(
            StreamingDataSynchronizer.toStreamingWsURL("ws://localhost:5100").absoluteString,
            "ws://localhost:5100/streaming"
        )
    }

    func testStreamingEndpointConvertsHttpSchemeToWs() {
        XCTAssertEqual(
            StreamingDataSynchronizer.toStreamingWsURL("https://eval.example.com").absoluteString,
            "wss://eval.example.com/streaming"
        )
        XCTAssertEqual(
            StreamingDataSynchronizer.toStreamingWsURL("http://localhost:5100").absoluteString,
            "ws://localhost:5100/streaming"
        )
    }
}

#endif
