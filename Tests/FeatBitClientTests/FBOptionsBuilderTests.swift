import XCTest
@testable import FeatBitClient

final class FBOptionsBuilderTests: XCTestCase {
    func test_default_offline_bootstrap_succeeds() throws {
        _ = try FBOptions.Builder().offline(true).build()
    }

    func test_missing_secret_when_not_offline_throws() {
        XCTAssertThrowsError(try FBOptions.Builder().build()) { err in
            XCTAssertEqual(err as? FBOptionsError, .missingSecret)
        }
    }

    func test_zero_polling_interval_throws() {
        XCTAssertThrowsError(
            try FBOptions.Builder("secret").polling("https://p.com", interval: 0).build()
        ) { err in
            guard case FBOptionsError.invalidPollingInterval = err else {
                XCTFail("wrong error: \(err)"); return
            }
        }
    }

    func test_negative_grace_throws() {
        XCTAssertThrowsError(
            try FBOptions.Builder("secret")
                .polling("https://p.com")
                .backgroundGracePeriod(-1)
                .build()
        ) { err in
            guard case FBOptionsError.invalidGracePeriod = err else {
                XCTFail("wrong error: \(err)"); return
            }
        }
    }

    func test_malformed_polling_uri_throws() {
        XCTAssertThrowsError(
            try FBOptions.Builder("secret").polling("not a url").build()
        )
    }

    func test_valid_build_populates_endpoints() throws {
        let opts = try FBOptions.Builder("secret")
            .polling("https://poll.example.com")
            .event("https://event.example.com")
            .streaming("wss://stream.example.com")
            .build()
        XCTAssertEqual(opts.endpoints.polling.scheme, "https")
        XCTAssertEqual(opts.endpoints.event.scheme, "https")
        XCTAssertEqual(opts.endpoints.streamingWs.scheme, "wss")
        // Mutation: dropping .appendingPathComponent("streaming") in parseWS would slip
        // past a scheme-only assertion.
        XCTAssertTrue(opts.endpoints.streamingWs.absoluteString.hasSuffix("/streaming"))
    }
}
