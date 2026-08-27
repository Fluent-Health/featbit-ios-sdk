import XCTest
@testable import FeatBitClient

final class FBEndpointsTests: XCTestCase {
    func test_valid_http_urls_parse() throws {
        let e = try FBEndpoints.from(
            pollingUri: "https://poll.example.com",
            eventUri: "https://event.example.com",
            streamingUri: "wss://stream.example.com"
        )
        XCTAssertEqual(e.polling.scheme, "https")
        XCTAssertEqual(e.event.scheme, "https")
        XCTAssertEqual(e.streamingWs.scheme, "wss")
        // Streaming URL gets the /streaming path appended (mirror URLSessionWebSocketTask input).
        XCTAssertTrue(e.streamingWs.path.hasSuffix("/streaming"))
    }

    func test_http_streaming_uri_is_normalized_to_ws() throws {
        let e = try FBEndpoints.from(
            pollingUri: "https://p.com",
            eventUri: "https://e.com",
            streamingUri: "https://s.com"
        )
        XCTAssertEqual(e.streamingWs.scheme, "wss")
        XCTAssertEqual(e.streamingWs.host, "s.com")
        XCTAssertTrue(e.streamingWs.path.hasSuffix("/streaming"))
    }

    func test_malformed_polling_uri_throws() {
        XCTAssertThrowsError(try FBEndpoints.from(
            pollingUri: "not a url",
            eventUri: "https://e.com",
            streamingUri: "wss://s.com"
        )) { err in
            guard case FBOptionsError.invalidURL(let field, _) = err else {
                XCTFail("wrong error: \(err)"); return
            }
            XCTAssertEqual(field, "pollingUri")
        }
    }

    func test_missing_host_throws() {
        // Mutation: dropping the host check accepts "https://" which crashes URLSession.
        XCTAssertThrowsError(try FBEndpoints.from(
            pollingUri: "https://",
            eventUri: "https://e.com",
            streamingUri: "wss://s.com"
        ))
    }

    func test_ftp_scheme_rejected() {
        // Mutation: dropping the scheme allowlist accepts arbitrary schemes.
        XCTAssertThrowsError(try FBEndpoints.from(
            pollingUri: "ftp://p.com",
            eventUri: "https://e.com",
            streamingUri: "wss://s.com"
        ))
    }

    func test_uppercase_https_streaming_normalizes_to_wss() throws {
        // RFC 3986: URI schemes are case-insensitive. parseHTTP already lowercases via
        // scheme?.lowercased(); parseWS must accept uppercase too to stay symmetric.
        // Mutation: reverting parseWS to case-sensitive hasPrefix("https") would reject
        // HTTPS://s.com as invalidURL, producing an asymmetry with parseHTTP.
        let e = try FBEndpoints.from(
            pollingUri: "HTTPS://p.com",
            eventUri: "HTTPS://e.com",
            streamingUri: "HTTPS://s.com"
        )
        XCTAssertEqual(e.streamingWs.scheme, "wss")
        XCTAssertEqual(e.streamingWs.host, "s.com")
        XCTAssertTrue(e.streamingWs.path.hasSuffix("/streaming"))
    }
}
