import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a URLSession routed through `MockURLProtocol`. Callers pass the returned
/// session into SDK types that accept an injected `URLSession` (FbApiClient and
/// its subclasses HttpTrackInsight + GetUserFlags; StreamingDataSynchronizer).
///
/// Use this instead of `MockURLProtocol.session()` for new tests that consume the
/// FIFO stub-queue API (`enqueue(status:jsonBody:)` + `receivedRequests`).
enum TestURLSession {
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}
