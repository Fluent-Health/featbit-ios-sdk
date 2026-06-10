import XCTest
@testable import FeatBitClient

/// Verifies the connection-token encoding byte-for-byte. These vectors are derived from the same
/// algorithm the Android SDK (and FeatBit server) use, so a match guarantees wire compatibility.
final class ConnectionTokenTests: XCTestCase {
    func testEmptySecretVector() {
        // s = "" → position 0; ts "1234567890000" (len 13).
        // header = encode(0,3)="QQQ" + encode(13,2)="BS"; payload = obfuscated timestamp.
        let token = ConnectionToken.encode(secret: "", timestampMs: 1_234_567_890_000)
        XCTAssertEqual(token, "QQQBSBWSPHDXZUQQQQ")
    }

    func testNonEmptySecretSplicesTimestampAtPosition() {
        // secret "abcdefgh" (len 8), ts 1234567890123 → position = ts % 8 = 3.
        // header = encode(3,3)="QQS" + encode(13,2)="BS";
        // payload = "abc" + obfuscated(ts) + "defgh".
        let token = ConnectionToken.encode(secret: "abcdefgh", timestampMs: 1_234_567_890_123)
        XCTAssertEqual(token, "QQSBSabcBWSPHDXZUQBWSdefgh")
    }

    func testTrailingBase64PaddingIsStripped() {
        // Trailing '=' is dropped before splicing, so "abcdefgh==" behaves like "abcdefgh".
        let withPadding = ConnectionToken.encode(secret: "abcdefgh==", timestampMs: 1_234_567_890_123)
        let without = ConnectionToken.encode(secret: "abcdefgh", timestampMs: 1_234_567_890_123)
        XCTAssertEqual(withPadding, without)
    }

    func testHeaderIsFiveObfuscatedChars() {
        let token = ConnectionToken.encode(secret: "secret", timestampMs: 1_700_000_000_000)
        // First 5 chars encode position (3) + content-length (2); all map to the A–Z alphabet.
        let header = String(token.prefix(5))
        XCTAssertEqual(header.count, 5)
        XCTAssertTrue(header.allSatisfy { "QBWSPHDXZU".contains($0) })
    }
}
