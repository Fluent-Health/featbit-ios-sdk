import Foundation

/// Configuration for an ``FBClient``. Build instances with ``Builder``.
public final class FBOptions: @unchecked Sendable {
    /// Whether the client is offline. When true, no network calls to FeatBit are made.
    public let offline: Bool
    /// Feature flags used as initial data before the first synchronization with FeatBit.
    public let bootstrap: [FeatureFlag]
    /// The SDK secret for your FeatBit environment.
    public let secret: String
    /// The data synchronization mode. Defaults to ``DataSyncMode/polling``.
    public let dataSyncMode: DataSyncMode
    /// The base URL of the polling (evaluation) service, e.g. `https://app-eval.featbit.co`.
    public let pollingUri: String
    /// The interval between polls, in seconds.
    public let pollingInterval: TimeInterval
    /// The base WebSocket URL of the streaming (evaluation) service, e.g. `wss://app-eval.featbit.co`.
    public let streamingUri: String
    /// The base URL of the event (insight) service, e.g. `https://app-eval.featbit.co`.
    public let eventUri: String
    /// How long to wait after the app backgrounds/goes offline before pausing streaming, in seconds.
    public let backgroundGracePeriod: TimeInterval
    /// The logger used by the SDK.
    public let logger: FBLogger
    /// Pre-parsed endpoints — single source of truth for URLs used at runtime.
    let endpoints: FBEndpoints

    init(
        offline: Bool,
        bootstrap: [FeatureFlag],
        secret: String,
        dataSyncMode: DataSyncMode,
        pollingUri: String,
        pollingInterval: TimeInterval,
        streamingUri: String,
        eventUri: String,
        backgroundGracePeriod: TimeInterval,
        logger: FBLogger,
        endpoints: FBEndpoints
    ) {
        self.offline = offline
        self.bootstrap = bootstrap
        self.secret = secret
        self.dataSyncMode = dataSyncMode
        self.pollingUri = pollingUri
        self.pollingInterval = pollingInterval
        self.streamingUri = streamingUri
        self.eventUri = eventUri
        self.backgroundGracePeriod = backgroundGracePeriod
        self.logger = logger
        self.endpoints = endpoints
    }

    /// Default URLs and intervals, matching the Android/Kotlin SDK.
    public enum Defaults {
        public static let uri = "http://localhost:5100"
        public static let streamingUri = "ws://localhost:5100"
        public static let pollingInterval: TimeInterval = 5 * 60
        public static let backgroundGracePeriod: TimeInterval = 20
    }

    /// Fluent builder for ``FBOptions``.
    ///
    /// - Parameter secret: your FeatBit environment secret. May be empty when `offline` is used
    ///   together with `bootstrap`.
    public final class Builder {
        private let secret: String
        private var offline = false
        private var bootstrap: [FeatureFlag] = []
        private var dataSyncMode: DataSyncMode = .polling
        private var pollingUri = Defaults.uri
        private var pollingInterval = Defaults.pollingInterval
        private var streamingUri = Defaults.streamingUri
        private var eventUri = Defaults.uri
        private var backgroundGracePeriod = Defaults.backgroundGracePeriod
        private var logger: FBLogger = DefaultLogger()

        public init(_ secret: String = "") {
            self.secret = secret
        }

        /// Configures polling synchronization against `pollingUri` at an optional `interval` (seconds).
        @discardableResult
        public func polling(_ pollingUri: String, interval: TimeInterval? = nil) -> Builder {
            dataSyncMode = .polling
            self.pollingUri = pollingUri
            if let interval { pollingInterval = interval }
            return self
        }

        /// Configures real-time streaming synchronization against `streamingUri`
        /// (a `ws://` or `wss://` URL, e.g. `wss://app-eval.featbit.co`).
        @discardableResult
        public func streaming(_ streamingUri: String) -> Builder {
            dataSyncMode = .streaming
            self.streamingUri = streamingUri
            return self
        }

        /// Sets the base URL of the event (insight) service.
        @discardableResult
        public func event(_ eventUri: String) -> Builder {
            self.eventUri = eventUri
            return self
        }

        /// Puts the client into offline mode.
        @discardableResult
        public func offline(_ offline: Bool) -> Builder {
            self.offline = offline
            return self
        }

        /// Provides feature flags to bootstrap the SDK before the first synchronization.
        @discardableResult
        public func bootstrap(_ bootstrap: [FeatureFlag]) -> Builder {
            self.bootstrap = bootstrap
            return self
        }

        /// Sets how long to wait after backgrounding/going offline before pausing streaming (seconds).
        @discardableResult
        public func backgroundGracePeriod(_ period: TimeInterval) -> Builder {
            backgroundGracePeriod = period
            return self
        }

        /// Sets the logger used by the SDK. Defaults to a ``DefaultLogger``.
        @discardableResult
        public func logger(_ logger: FBLogger) -> Builder {
            self.logger = logger
            return self
        }

        public func build() throws -> FBOptions {
            if !offline && secret.trimmingCharacters(in: .whitespaces).isEmpty {
                throw FBOptionsError.missingSecret
            }
            if pollingInterval <= 0 {
                throw FBOptionsError.invalidPollingInterval(pollingInterval)
            }
            if backgroundGracePeriod < 0 {
                throw FBOptionsError.invalidGracePeriod(backgroundGracePeriod)
            }
            let endpoints = try FBEndpoints.from(
                pollingUri: pollingUri,
                eventUri: eventUri,
                streamingUri: streamingUri
            )
            return FBOptions(
                offline: offline,
                bootstrap: bootstrap,
                secret: secret,
                dataSyncMode: dataSyncMode,
                pollingUri: pollingUri,
                pollingInterval: pollingInterval,
                streamingUri: streamingUri,
                eventUri: eventUri,
                backgroundGracePeriod: backgroundGracePeriod,
                logger: logger,
                endpoints: endpoints
            )
        }
    }
}
