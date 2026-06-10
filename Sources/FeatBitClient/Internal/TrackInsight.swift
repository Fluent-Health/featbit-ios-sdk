import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends analytics insight events to FeatBit.
protocol TrackInsight: AnyObject, Sendable {
    func run(_ insight: Insight) async
    func close()
}

/// No-op tracker used in offline mode.
final class NoopTrackInsight: TrackInsight {
    func run(_ insight: Insight) async {}
    func close() {}
}

/// Default tracker: POSTs a single-element insight array to `api/public/insight/track`.
final class HttpTrackInsight: FbApiClient, TrackInsight, @unchecked Sendable {
    private let endpoint: URL

    override init(options: FBOptions, session: URLSession? = nil) {
        self.endpoint = URL(string: options.eventUri)!
            .appendingPathComponents(HttpConstants.insightTrackPath)
        super.init(options: options, session: session)
    }

    func run(_ insight: Insight) async {
        do {
            let payload = try FbApiClient.encoder.encode([insight])
            _ = try await post(url: endpoint, payload: payload)
        } catch {
            options.logger.error("Exception occurred while tracking insight.", error)
        }
    }

    func close() {}
}
