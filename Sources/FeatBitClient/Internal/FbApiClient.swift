import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Base class for the SDK's FeatBit HTTP endpoints. Centralizes the `URLSession`, authentication
/// headers, JSON configuration, and POST plumbing — the Swift analogue of the Kotlin/.NET
/// `FbApiClient`.
class FbApiClient {
    let options: FBOptions
    private let session: URLSession
    private let logger: FBLogger

    /// - Parameter session: optional session override, primarily for testing (e.g. a `URLProtocol` stub).
    init(options: FBOptions, session: URLSession? = nil) {
        self.options = options
        self.logger = options.logger
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 8
            self.session = URLSession(configuration: config)
        }
    }

    struct HttpResult {
        let code: Int
        let body: String
        var isSuccessful: Bool { (200..<300).contains(code) }
    }

    func post(url: URL, payload: Data) async throws -> HttpResult {
        logger.debug { "HTTP POST \(url) with \(String(data: payload, encoding: .utf8) ?? "")" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(options.secret, forHTTPHeaderField: "Authorization")
        request.setValue(HttpConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let (data, response) = try await session.dataAsync(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.debug { "Api call response status \(code). Body: \(body)" }
        return HttpResult(code: code, body: body)
    }

    /// Shared JSON configuration (camelCase keys, lenient decoding), matching the Kotlin SDK's
    /// "Web" defaults.
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

extension URLSession {
    /// `URLSession.data(for:)` is iOS 15+/unavailable on some Linux Foundation builds, so wrap the
    /// completion-handler API in a continuation for iOS 14 + cross-platform support.
    func dataAsync(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = self.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }
}
