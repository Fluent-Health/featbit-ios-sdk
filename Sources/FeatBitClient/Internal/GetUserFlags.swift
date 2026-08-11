import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outcome of a `latest-all` poll. A 401 is fatal (bad secret) and stops polling; any other
/// non-2xx is a transient error that is retried on the next interval.
struct GetUserFlagsResponse {
    let statusCode: Int
    let flags: [FeatureFlag]

    var isError: Bool { statusCode != 200 }
    var isFatal: Bool { statusCode == 401 }

    static func ok(_ flags: [FeatureFlag]) -> GetUserFlagsResponse {
        GetUserFlagsResponse(statusCode: 200, flags: flags)
    }

    static func error(_ statusCode: Int) -> GetUserFlagsResponse {
        GetUserFlagsResponse(statusCode: statusCode, flags: [])
    }
}

/// Fetches the latest feature flags for a user from the FeatBit evaluation server.
/// POSTs the end-user payload to `api/public/sdk/client/latest-all?timestamp=...`.
final class GetUserFlags: FbApiClient {
    private let endpoint: URL
    private let payload: Data

    init(options: FBOptions, user: FBUser, session: URLSession? = nil) {
        self.endpoint = options.endpoints.polling
            .appendingPathComponents(HttpConstants.latestAllPath)
        self.payload = (try? FbApiClient.encoder.encode(user.toEndUser())) ?? Data()
        super.init(options: options, session: session)
    }

    func run(timestamp: Int64) async -> GetUserFlagsResponse {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return .error(-1)
        }
        components.queryItems = [URLQueryItem(name: "timestamp", value: String(timestamp))]
        guard let url = components.url else { return .error(-1) }

        do {
            let result = try await post(url: url, payload: payload)
            guard result.isSuccessful else {
                return .error(result.code)
            }
            if result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .ok([])
            }
            let flags = parseFlags(from: result.body)
            return .ok(flags)
        } catch {
            options.logger.error("Exception occurred while polling data.", error)
            return .error(-1)
        }
    }

    private func parseFlags(from body: String) -> [FeatureFlag] {
        guard let data = body.data(using: .utf8) else { return [] }
        struct Envelope: Decodable { let data: Payload? }
        struct Payload: Decodable { let featureFlags: [FeatureFlag]? }
        let envelope = try? FbApiClient.decoder.decode(Envelope.self, from: data)
        return envelope?.data?.featureFlags ?? []
    }
}

extension URL {
    /// Appends each `/`-separated segment of `path`, mirroring OkHttp's `addPathSegments`.
    func appendingPathComponents(_ path: String) -> URL {
        path.split(separator: "/").reduce(self) { $0.appendingPathComponent(String($1)) }
    }
}
