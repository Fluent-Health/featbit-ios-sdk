import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The WebSocket runtime relies on `URLSessionWebSocketTask`, whose `send`/`receive` completion-handler
// API is unavailable on some Linux Foundation builds. Compile the real implementation only on Apple
// platforms; provide a stub elsewhere so the package builds everywhere.
#if canImport(Darwin)

/// Synchronizes feature flags in real time over a WebSocket to FeatBit's `/streaming` endpoint.
///
/// On connect it sends a `data-sync` message (with the current user and last-seen timestamp); the
/// server replies with a `full` snapshot and subsequently pushes `patch` updates whenever a flag
/// changes. Flags are upserted into the shared store, driving evaluation and the flag tracker
/// exactly as in polling mode. An application-level `ping` heartbeat plus exponential-backoff
/// reconnection keep the connection healthy. Port of the Kotlin `StreamingDataSynchronizer`.
final class StreamingDataSynchronizer: NSObject, DataSynchronizer, @unchecked Sendable {
    private let logger: FBLogger
    private let secret: String
    private let user: FBUser
    private let store: MemoryStore
    private let streamingEndpoint: URL
    private let session: URLSession

    private let startGate = StartGate()
    private let lock = Lock()
    private var _initialized = false
    private var timestamp: Int64 = 0
    private var webSocket: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var reconnecting = false
    private var paused = false
    private var closed = false

    private static let normalClosure = 1000
    private static let heartbeatIntervalNs: UInt64 = 20 * 1_000_000_000
    private static let baseBackoffMs: Int64 = 1_000
    private static let maxBackoffMs: Int64 = 30_000
    private static let pingMessage = #"{"messageType":"ping","data":{}}"#

    init(options: FBOptions, user: FBUser, store: MemoryStore, session: URLSession? = nil) {
        self.logger = options.logger
        self.secret = options.secret
        self.user = user
        self.store = store
        self.streamingEndpoint = options.endpoints.streamingWs
        self.session = session ?? URLSession(configuration: .ephemeral)
        super.init()
    }

    var initialized: Bool {
        lock.withLock { _initialized }
    }

    func start() async -> Bool {
        connect()
        return await startGate.wait()
    }

    private func connect() {
        let ts: Int64? = lock.withLock { closed ? nil : timestamp }
        guard let ts else { return }

        var components = URLComponents(url: streamingEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "client"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "token", value: ConnectionToken.encode(secret: secret)),
        ]
        guard let url = components.url else { return }
        logger.debug { "Opening streaming connection to \(url)" }

        let task = session.webSocketTask(with: url)
        lock.withLock { webSocket = task }
        task.resume()

        sendDataSync(task, timestamp: ts)
        startHeartbeat(task)
        receive(task)
    }

    private func sendDataSync(_ task: URLSessionWebSocketTask, timestamp: Int64) {
        let message = ClientMessage(messageType: "data-sync", data: DataSyncData(user: user.toEndUser(), timestamp: timestamp))
        guard let data = try? FbApiClient.encoder.encode(message), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { self?.scheduleReconnect(reason: "send data-sync failed: \(error)") }
        }
    }

    private func startHeartbeat(_ task: URLSessionWebSocketTask) {
        lock.withLock {
            heartbeatTask?.cancel()
            heartbeatTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: StreamingDataSynchronizer.heartbeatIntervalNs)
                    if Task.isCancelled { break }
                    task.send(.string(StreamingDataSynchronizer.pingMessage)) { _ in }
                }
            }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleMessage(text)
                case .data(let data): self.handleMessage(String(data: data, encoding: .utf8) ?? "")
                @unknown default: break
                }
                self.receive(task)
            case .failure(let error):
                self.scheduleReconnect(reason: "\(error)")
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let envelope = try FbApiClient.decoder.decode(ServerEnvelope.self, from: data)
            guard envelope.messageType == "data-sync", let payloadData = envelope.data else { return }
            let payload = try FbApiClient.decoder.decode(DataSyncPayload.self, from: payloadData)
            for flag in payload.featureFlags { store.upsert(flag) }

            let wasInitialized = lock.withLock { () -> Bool in
                timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                let was = _initialized
                _initialized = true
                return was
            }

            if !wasInitialized {
                startGate.complete(true)
                logger.info("Streaming data synchronizer initialized for user \(user.key).")
            }
        } catch {
            logger.error("Failed to handle streaming message.", error)
        }
    }

    private func scheduleReconnect(reason: String) {
        let attempt: Int? = lock.withLock { () -> Int? in
            if closed || paused { return nil }
            heartbeatTask?.cancel()
            if reconnecting { return nil }
            reconnecting = true
            reconnectAttempts += 1
            return reconnectAttempts
        }
        guard let attempt else { return }

        let shift = min(attempt, 6)
        let backoff = min(StreamingDataSynchronizer.maxBackoffMs, StreamingDataSynchronizer.baseBackoffMs << shift) + Int64.random(in: 0..<250)
        logger.warn("Streaming disconnected (\(reason)); reconnecting in \(backoff)ms (attempt \(attempt)).")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000)
            guard let self else { return }
            self.lock.withLock { self.reconnecting = false }
            self.connect()
        }
    }

    func pause() {
        var proceed = false
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            if closed || paused { return nil }
            paused = true
            reconnecting = false
            heartbeatTask?.cancel()
            proceed = true
            let t = webSocket
            webSocket = nil
            return t
        }
        guard proceed else { return }
        task?.cancel(with: .normalClosure, reason: "paused".data(using: .utf8))
        logger.debug { "Streaming paused." }
    }

    func resume() {
        let proceed = lock.withLock { () -> Bool in
            if closed || !paused { return false }
            paused = false
            reconnectAttempts = 0
            return true
        }
        guard proceed else { return }
        logger.debug { "Streaming resumed; reconnecting and resyncing." }
        connect()
    }

    func close() {
        let task = lock.withLock { () -> URLSessionWebSocketTask? in
            closed = true
            heartbeatTask?.cancel()
            let t = webSocket
            webSocket = nil
            return t
        }
        task?.cancel(with: .normalClosure, reason: nil)
        startGate.complete(false)
    }

    // MARK: Wire models

    private struct ClientMessage<T: Encodable>: Encodable {
        let messageType: String
        let data: T
    }

    private struct DataSyncData: Encodable {
        let user: EndUser
        let timestamp: Int64
    }

    private struct ServerEnvelope: Decodable {
        let messageType: String
        let data: Data?

        enum CodingKeys: String, CodingKey { case messageType, data }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            messageType = try c.decodeIfPresent(String.self, forKey: .messageType) ?? ""
            // Re-encode the nested `data` object so it can be decoded separately, mirroring the
            // Kotlin `JsonElement` two-step decode.
            if let nested = try c.decodeIfPresent(AnyDecodableJSON.self, forKey: .data) {
                data = nested.reencoded
            } else {
                data = nil
            }
        }
    }

    private struct DataSyncPayload: Decodable {
        let eventType: String
        let userKeyId: String
        let featureFlags: [FeatureFlag]

        enum CodingKeys: String, CodingKey { case eventType, userKeyId, featureFlags }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventType = try c.decodeIfPresent(String.self, forKey: .eventType) ?? ""
            userKeyId = try c.decodeIfPresent(String.self, forKey: .userKeyId) ?? ""
            featureFlags = try c.decodeIfPresent([FeatureFlag].self, forKey: .featureFlags) ?? []
        }
    }
}

/// Captures an arbitrary JSON value and re-encodes it to `Data`, so a nested object can be decoded
/// into a concrete type in a second step (the Codable analogue of kotlinx's `JsonElement`).
private struct AnyDecodableJSON: Decodable {
    let reencoded: Data?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(JSONValue.self) {
            reencoded = try? JSONEncoder().encode(value)
        } else {
            reencoded = nil
        }
    }
}

/// Minimal JSON value tree used to round-trip the streaming envelope's `data` object.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

#else

/// Streaming is unsupported on non-Apple platforms because `URLSessionWebSocketTask`'s
/// completion-handler API is incomplete in Linux Foundation. The stub keeps the package building;
/// `start()` reports failure so callers fall back / surface the misconfiguration.
final class StreamingDataSynchronizer: DataSynchronizer, @unchecked Sendable {
    private let logger: FBLogger

    init(options: FBOptions, user: FBUser, store: MemoryStore) {
        self.logger = options.logger
    }

    let initialized = false

    func start() async -> Bool {
        logger.error("Streaming sync is not supported on this platform (URLSessionWebSocketTask is unavailable). Use polling instead.", nil)
        return false
    }

    func close() {}
}

#endif
