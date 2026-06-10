import Foundation

/// The data synchronization mode used by the SDK.
///
/// ``polling`` periodically fetches flags over HTTP. ``streaming`` keeps a WebSocket open to the
/// evaluation server and receives flag changes in real time (as the JS/RN SDKs do).
public enum DataSyncMode: Sendable {
    case polling
    case streaming
}
