import Foundation

/// Default ``FBClient`` implementation. Wires together the store, evaluator, flag tracker, insight
/// tracker, lifecycle controller, and data synchronizer — mirroring the Kotlin/.NET `FbClient`.
public final class DefaultFBClient: FBClient, @unchecked Sendable {
    private let options: FBOptions
    private let logger: FBLogger
    private let store: MemoryStore
    private let evaluator: Evaluator
    private let flagTrackerImpl: FlagTrackerImpl
    private let trackInsight: TrackInsight

    private let lock = Lock()
    private var user: FBUser
    private var dataSynchronizer: DataSynchronizer
    private var lifecycle: LifecycleController!

    /// - Parameters:
    ///   - options: the client configuration.
    ///   - user: the initial evaluation user; change it later with ``identify(_:timeout:)``.
    public init(options: FBOptions, user: FBUser) {
        self.options = options
        self.logger = options.logger
        let store = DefaultMemoryStore(bootstrap: options.bootstrap)
        self.store = store
        self.evaluator = Evaluator(store: store)
        self.flagTrackerImpl = FlagTrackerImpl(store: store)
        self.trackInsight = options.offline ? NoopTrackInsight() : HttpTrackInsight(options: options)
        self.user = user
        self.dataSynchronizer = DefaultFBClient.newDataSynchronizer(options: options, user: user, store: store)
        self.lifecycle = LifecycleController(graceSeconds: options.backgroundGracePeriod) { [weak self] in
            self?.currentSynchronizer ?? NullDataSynchronizer()
        }
    }

    private var currentSynchronizer: DataSynchronizer {
        lock.withLock { dataSynchronizer }
    }

    private static func newDataSynchronizer(options: FBOptions, user: FBUser, store: MemoryStore) -> DataSynchronizer {
        if options.offline {
            return NullDataSynchronizer()
        }
        switch options.dataSyncMode {
        case .streaming:
            return StreamingDataSynchronizer(options: options, user: user, store: store)
        case .polling:
            return PollingDataSynchronizer(options: options, user: user, store: store)
        }
    }

    public var initialized: Bool { currentSynchronizer.initialized }

    public var flagTracker: FlagTracker { flagTrackerImpl }

    public func start(timeout: TimeInterval) async -> Bool {
        logger.info("Waiting up to \(timeout)s for FBClient to start...")
        let success = await withTimeout(seconds: timeout) { [weak self] in
            await self?.currentSynchronizer.start() ?? false
        }
        if success {
            logger.info("FBClient successfully started.")
        } else {
            logger.error("FBClient failed to start within \(timeout)s. This usually indicates a connection issue with FeatBit or an invalid secret. Double-check your secret and URLs.")
        }
        return success
    }

    public func identify(_ user: FBUser, timeout: TimeInterval) async -> Bool {
        let (old, fresh) = lock.withLock { () -> (DataSynchronizer, DataSynchronizer) in
            self.user = user
            let old = dataSynchronizer
            let fresh = DefaultFBClient.newDataSynchronizer(options: options, user: user, store: store)
            dataSynchronizer = fresh
            return (old, fresh)
        }

        old.close()

        let success = await withTimeout(seconds: timeout) {
            await fresh.start()
        }

        // Fire-and-forget the identify insight.
        let insightUser = user
        Task { [weak self] in await self?.trackInsight.run(Insight.forIdentify(user: insightUser)) }

        return success
    }

    // MARK: Evaluation

    public func boolVariation(_ key: String, default defaultValue: Bool) -> Bool {
        evaluateCore(key, defaultValue, ValueConverters.bool).value
    }

    public func boolVariationDetail(_ key: String, default defaultValue: Bool) -> EvalDetail<Bool> {
        evaluateCore(key, defaultValue, ValueConverters.bool)
    }

    public func intVariation(_ key: String, default defaultValue: Int) -> Int {
        evaluateCore(key, defaultValue, ValueConverters.int).value
    }

    public func intVariationDetail(_ key: String, default defaultValue: Int) -> EvalDetail<Int> {
        evaluateCore(key, defaultValue, ValueConverters.int)
    }

    public func floatVariation(_ key: String, default defaultValue: Float) -> Float {
        evaluateCore(key, defaultValue, ValueConverters.float).value
    }

    public func floatVariationDetail(_ key: String, default defaultValue: Float) -> EvalDetail<Float> {
        evaluateCore(key, defaultValue, ValueConverters.float)
    }

    public func doubleVariation(_ key: String, default defaultValue: Double) -> Double {
        evaluateCore(key, defaultValue, ValueConverters.double).value
    }

    public func doubleVariationDetail(_ key: String, default defaultValue: Double) -> EvalDetail<Double> {
        evaluateCore(key, defaultValue, ValueConverters.double)
    }

    public func stringVariation(_ key: String, default defaultValue: String) -> String {
        evaluateCore(key, defaultValue, ValueConverters.string).value
    }

    public func stringVariationDetail(_ key: String, default defaultValue: String) -> EvalDetail<String> {
        evaluateCore(key, defaultValue, ValueConverters.string)
    }

    public func allFlags() -> [String: FeatureFlag] {
        Dictionary(store.getAll().map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func evaluateCore<T: Sendable>(_ key: String, _ defaultValue: T, _ converter: ValueConverter<T>) -> EvalDetail<T> {
        // Client not ready and no bootstrap data — always return the default value.
        if !initialized && options.bootstrap.isEmpty {
            return EvalDetail(reason: "client not ready", value: defaultValue)
        }

        let (evalResult, flag) = evaluator.evaluate(key)
        guard evalResult.isValid, let flag else {
            return EvalDetail(reason: evalResult.reason, value: defaultValue)
        }

        // Fire-and-forget the evaluation insight.
        let currentUser = currentUserSnapshot()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        Task { [weak self] in await self?.trackInsight.run(Insight.forEvaluation(user: currentUser, flag: flag, timestamp: ts)) }

        if let typed = converter(evalResult.value) {
            return EvalDetail(reason: evalResult.reason, value: typed)
        } else {
            return EvalDetail(reason: "type mismatch", value: defaultValue)
        }
    }

    private func currentUserSnapshot() -> FBUser {
        lock.withLock { user }
    }

    // MARK: Lifecycle hooks

    public func setForeground(_ foreground: Bool) {
        Task { await lifecycle.onForegroundChanged(foreground) }
    }

    public func setNetworkAvailable(_ available: Bool) {
        Task { await lifecycle.onNetworkChanged(available) }
    }

    public func close() {
        currentSynchronizer.close()
        flagTrackerImpl.close()
        trackInsight.close()
    }
}

/// Runs `operation`, returning its result, or `false` if it does not complete within `seconds`.
private func withTimeout(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}
