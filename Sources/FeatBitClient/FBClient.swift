import Foundation

/// The client-side FeatBit SDK: evaluates feature flags for a single current user, keeps them in
/// sync (polling or streaming), tracks changes, and reports analytics insights.
///
/// Create a **single instance** for the lifetime of your app. Lifecycle (`start`/`identify`) is
/// asynchronous; flag evaluations are synchronous reads from the in-memory store.
public protocol FBClient: AnyObject {
    /// Whether the client has completed its first successful synchronization.
    var initialized: Bool { get }

    /// Observe flag value changes (listeners, `AsyncStream`, and Combine on Apple platforms).
    var flagTracker: FlagTracker { get }

    /// Starts synchronization and waits up to `timeout` seconds for the client to be ready.
    /// - Returns: `true` once initialized; `false` on timeout or fatal error.
    @discardableResult
    func start(timeout: TimeInterval) async -> Bool

    /// Switches the current evaluation user (e.g. after login) and re-synchronizes their flags.
    @discardableResult
    func identify(_ user: FBUser, timeout: TimeInterval) async -> Bool

    func boolVariation(_ key: String, default defaultValue: Bool) -> Bool
    func boolVariationDetail(_ key: String, default defaultValue: Bool) -> EvalDetail<Bool>
    func intVariation(_ key: String, default defaultValue: Int) -> Int
    func intVariationDetail(_ key: String, default defaultValue: Int) -> EvalDetail<Int>
    func floatVariation(_ key: String, default defaultValue: Float) -> Float
    func floatVariationDetail(_ key: String, default defaultValue: Float) -> EvalDetail<Float>
    func doubleVariation(_ key: String, default defaultValue: Double) -> Double
    func doubleVariationDetail(_ key: String, default defaultValue: Double) -> EvalDetail<Double>
    func stringVariation(_ key: String, default defaultValue: String) -> String
    func stringVariationDetail(_ key: String, default defaultValue: String) -> EvalDetail<String>

    /// A snapshot of all currently-known flags, keyed by flag id.
    func allFlags() -> [String: FeatureFlag]

    /// Lifecycle hooks (default active). Wire these from your app, or use `FBLifecycleConnector`
    /// from the `FeatBitLifecycle` module. A client that never calls them synchronizes as before.
    func setForeground(_ foreground: Bool)
    func setNetworkAvailable(_ available: Bool)

    /// Releases the synchronizer, tracker, and insight resources.
    func close()
}

// Convenience overloads with omitted arguments. These use distinct (fewer-parameter) signatures
// so they forward to — rather than recursively call — the protocol requirements.
public extension FBClient {
    /// Starts the client, waiting up to 3 seconds.
    @discardableResult
    func start() async -> Bool { await start(timeout: 3) }

    /// Switches user, waiting up to 3 seconds.
    @discardableResult
    func identify(_ user: FBUser) async -> Bool { await identify(user, timeout: 3) }

    func boolVariation(_ key: String) -> Bool { boolVariation(key, default: false) }
    func boolVariationDetail(_ key: String) -> EvalDetail<Bool> { boolVariationDetail(key, default: false) }
    func intVariation(_ key: String) -> Int { intVariation(key, default: 0) }
    func intVariationDetail(_ key: String) -> EvalDetail<Int> { intVariationDetail(key, default: 0) }
    func floatVariation(_ key: String) -> Float { floatVariation(key, default: 0) }
    func floatVariationDetail(_ key: String) -> EvalDetail<Float> { floatVariationDetail(key, default: 0) }
    func doubleVariation(_ key: String) -> Double { doubleVariation(key, default: 0) }
    func doubleVariationDetail(_ key: String) -> EvalDetail<Double> { doubleVariationDetail(key, default: 0) }
    func stringVariation(_ key: String) -> String { stringVariation(key, default: "") }
    func stringVariationDetail(_ key: String) -> EvalDetail<String> { stringVariationDetail(key, default: "") }
}
