import Foundation

/// Single, eagerly-parsed source of truth for FeatBit endpoints. Constructed at
/// `FBOptions.build()` time so malformed URIs throw at SDK init instead of on the
/// first network call.
struct FBEndpoints: Sendable {
    let polling: URL
    let event: URL
    let streamingWs: URL

    static func from(pollingUri: String, eventUri: String, streamingUri: String) throws -> FBEndpoints {
        FBEndpoints(
            polling: try parseHTTP(pollingUri, field: "pollingUri"),
            event: try parseHTTP(eventUri, field: "eventUri"),
            streamingWs: try parseWS(streamingUri, field: "streamingUri")
        )
    }

    private static func parseHTTP(_ uri: String, field: String) throws -> URL {
        guard let url = URL(string: uri),
              let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { throw FBOptionsError.invalidURL(field: field, value: uri) }
        return url
    }

    /// Accepts `ws(s)://` or `http(s)://` (case-insensitive per RFC 3986) and returns
    /// the WS-scheme URL that `URLSessionWebSocketTask` requires. Appends the
    /// `/streaming` path.
    private static func parseWS(_ uri: String, field: String) throws -> URL {
        var normalized = uri
        let lower = uri.lowercased()
        if lower.hasPrefix("https") {
            normalized = "wss" + uri.dropFirst(5)
        } else if lower.hasPrefix("http") {
            normalized = "ws" + uri.dropFirst(4)
        }
        guard let url = URL(string: normalized),
              let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme)
        else { throw FBOptionsError.invalidURL(field: field, value: uri) }
        return url.appendingPathComponent("streaming")
    }
}
