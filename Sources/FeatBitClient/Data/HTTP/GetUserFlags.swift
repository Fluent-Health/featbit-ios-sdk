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
            let trimmed = result.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .ok([])
            }
            do {
                let data = Data(result.body.utf8)
                let envelope = try FbApiClient.decoder.decode(LatestAllEnvelope.self, from: data)
                return .ok(envelope.data.featureFlags)
            } catch {
                options.logger.error("Malformed latest-all payload; treating as transient error.", error)
                return .error(-1)
            }
        } catch {
            options.logger.error("Exception occurred while polling data.", error)
            return .error(-1)
        }
    }

    private struct LatestAllEnvelope: Decodable {
        let data: LatestAllData
    }

    private struct LatestAllData: Decodable {
        let featureFlags: [FeatureFlag]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            featureFlags = try c.decodeIfPresent([FeatureFlag].self, forKey: .featureFlags) ?? []
        }

        enum CodingKeys: String, CodingKey { case featureFlags }
    }
}

extension URL {
    /// Appends each `/`-separated segment of `path`, mirroring OkHttp's `addPathSegments`.
    func appendingPathComponents(_ path: String) -> URL {
        path.split(separator: "/").reduce(self) { $0.appendingPathComponent(String($1)) }
    }
}
