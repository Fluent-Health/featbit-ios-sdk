import Foundation

/// Builds the short-lived connection token FeatBit's streaming endpoint expects on the
/// `?token=` query parameter. This is the inverse of the server's `Domain.Shared.Token` decoder:
/// the timestamp's decimal digits are obfuscated through a fixed character map and spliced into
/// the secret at a chosen position; a 5-char header records that position (3 chars) and the
/// timestamp length (2 chars).
///
/// The server rejects tokens older than ~30s, so a fresh token must be generated for every
/// (re)connect. Port of the Kotlin `ConnectionToken`.
enum ConnectionToken {
    // Digit -> obfuscation char, matching the server's `TokenNumber.CharacterMap`.
    private static let digitToChar: [Character: Character] = [
        "0": "Q", "1": "B", "2": "W", "3": "S", "4": "P",
        "5": "H", "6": "D", "7": "X", "8": "Z", "9": "U",
    ]

    static func encode(secret: String, timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> String {
        var s = Substring(secret)
        while s.hasSuffix("=") { s = s.dropLast() }
        let trimmed = String(s)

        let timestampDigits = String(timestampMs)
        let contentLength = timestampDigits.count
        let position = trimmed.isEmpty ? 0 : Int(timestampMs % Int64(trimmed.count))

        let header = encodeNumber(position, width: 3) + encodeNumber(contentLength, width: 2)
        let encodedTimestamp = String(timestampDigits.map { digitToChar[$0]! })

        let splitIndex = trimmed.index(trimmed.startIndex, offsetBy: position)
        let payload = String(trimmed[trimmed.startIndex..<splitIndex]) + encodedTimestamp + String(trimmed[splitIndex...])

        return header + payload
    }

    private static func encodeNumber(_ value: Int, width: Int) -> String {
        let padded = String(value).leftPadded(to: width, with: "0")
        return String(padded.map { digitToChar[$0]! })
    }
}

private extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
