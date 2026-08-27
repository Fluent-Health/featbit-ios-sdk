import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends analytics insight events to FeatBit.
protocol TrackInsight: AnyObject, Sendable {
    /// Sends a batch of insights as a single JSON array to the insight endpoint. Empty
    /// batches must be no-ops (no network request).
    func runBatch(_ insights: [Insight]) async
    func close()
}

extension TrackInsight {
    /// Single-item bridge for callers that emit one at a time (identify insight, tests).
    func run(_ insight: Insight) async { await runBatch([insight]) }
}

/// No-op tracker used in offline mode.
final class NoopTrackInsight: TrackInsight {
    func runBatch(_ insights: [Insight]) async {}
    func close() {}
}

/// Default tracker: POSTs a JSON array of insights to `api/public/insight/track`.
final class HttpTrackInsight: FbApiClient, TrackInsight, @unchecked Sendable {
    private let endpoint: URL

    override init(options: FBOptions, session: URLSession? = nil) {
        self.endpoint = options.endpoints.event
            .appendingPathComponents(HttpConstants.insightTrackPath)
        super.init(options: options, session: session)
    }

    func runBatch(_ insights: [Insight]) async {
        if insights.isEmpty { return }
        do {
            let payload = try FbApiClient.encoder.encode(insights)
            _ = try await post(url: endpoint, payload: payload)
        } catch {
            options.logger.error("Exception occurred while tracking insight batch.", error)
        }
    }

    func close() {}
}
