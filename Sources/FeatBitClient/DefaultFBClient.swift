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
    private let insightsEnabled: Bool
    private let insightDispatcher: InsightDispatcher

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
        self.insightsEnabled = !(self.trackInsight is NoopTrackInsight)
        self.insightDispatcher = InsightDispatcher(tracker: self.trackInsight, logger: options.logger)
        self.insightDispatcher.start()
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

        await old.closeAndJoin()

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
        evaluateValue(key, defaultValue, ValueConverters.bool)
    }

    public func boolVariationDetail(_ key: String, default defaultValue: Bool) -> EvalDetail<Bool> {
        evaluateCore(key, defaultValue, ValueConverters.bool)
    }

    public func intVariation(_ key: String, default defaultValue: Int) -> Int {
        evaluateValue(key, defaultValue, ValueConverters.int)
    }

    public func intVariationDetail(_ key: String, default defaultValue: Int) -> EvalDetail<Int> {
        evaluateCore(key, defaultValue, ValueConverters.int)
    }

    public func floatVariation(_ key: String, default defaultValue: Float) -> Float {
        evaluateValue(key, defaultValue, ValueConverters.float)
    }

    public func floatVariationDetail(_ key: String, default defaultValue: Float) -> EvalDetail<Float> {
        evaluateCore(key, defaultValue, ValueConverters.float)
    }

    public func doubleVariation(_ key: String, default defaultValue: Double) -> Double {
        evaluateValue(key, defaultValue, ValueConverters.double)
    }

    public func doubleVariationDetail(_ key: String, default defaultValue: Double) -> EvalDetail<Double> {
        evaluateCore(key, defaultValue, ValueConverters.double)
    }

    public func stringVariation(_ key: String, default defaultValue: String) -> String {
        evaluateValue(key, defaultValue, ValueConverters.string)
    }

    public func stringVariationDetail(_ key: String, default defaultValue: String) -> EvalDetail<String> {
        evaluateCore(key, defaultValue, ValueConverters.string)
    }

    public func allFlags() -> [String: FeatureFlag] {
        let snapshot = store.getAll()
        var out: [String: FeatureFlag] = [:]
        out.reserveCapacity(snapshot.count)
        for flag in snapshot { out[flag.id] = flag }
        return out
    }

    /// Alloc-free variation hot path — mirrors ``evaluateCore`` but skips the
    /// ``EvalDetail`` allocation because plain-value callers don't need a reason
    /// string. ``*VariationDetail`` callers stay on ``evaluateCore``.
    private func evaluateValue<T: Sendable>(_ key: String, _ defaultValue: T, _ converter: ValueConverter<T>) -> T {
        // Client not ready and no bootstrap data — always return the default value.
        if !initialized && options.bootstrap.isEmpty {
            return defaultValue
        }

        guard let flag = evaluator.evaluateValue(key) else {
            return defaultValue
        }

        // Fast-path insight emission — short-circuit when tracker is Noop so
        // offline mode allocates no Insight / EndUser graph per evaluation.
        if insightsEnabled {
            let currentUser = currentUserSnapshot()
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            insightDispatcher.offer(Insight.forEvaluation(user: currentUser, flag: flag, timestamp: ts))
        }

        return converter(flag.variation) ?? defaultValue
    }

    private func evaluateCore<T: Sendable>(_ key: String, _ defaultValue: T, _ converter: ValueConverter<T>) -> EvalDetail<T> {
        // Client not ready and no bootstrap data — always return the default value.
        if !initialized && options.bootstrap.isEmpty {
            return EvalDetail(reason: "client not ready", value: defaultValue)
        }

        let evalResult = evaluator.evaluate(key)
        guard case .found(let flag) = evalResult else {
            return EvalDetail(reason: evalResult.reason, value: defaultValue)
        }

        // Non-suspending emit onto the bounded batching pipeline. Skipped when
        // the underlying tracker is Noop (offline mode).
        if insightsEnabled {
            let currentUser = currentUserSnapshot()
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            insightDispatcher.offer(Insight.forEvaluation(user: currentUser, flag: flag, timestamp: ts))
        }

        if let typed = converter(flag.variation) {
            return EvalDetail(reason: flag.matchReason, value: typed)
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

    /// Fire-and-forget close. Returns immediately; teardown runs on a background Task.
    /// Callers migrating from the .NET / Kotlin SDKs should be aware this no longer
    /// blocks — use ``closeAndJoin()`` to await teardown.
    public func close() {
        Task { [weak self] in await self?.closeAndJoin() }
    }

    /// Per-phase 2s + 2s budget:
    ///
    /// - Phase A: synchronizer teardown (2s budget).
    /// - Phase B: insight dispatcher drain (2s budget).
    /// - Non-blocking tail: flagTrackerImpl.close() + trackInsight.close().
    ///
    /// The budget bounds **caller latency**, not underlying work completion:
    /// `sync.closeAndJoin()` awaits `Task<Void, Never>.value`, which does not honor
    /// `Task.cancel()` from the outer withTimeout. If a poll is mid-flight in a
    /// blocking URLSession round-trip that itself ignores cancellation, the caller
    /// still returns within ~2s, but the poll may continue in the background until
    /// its native timeout lands. This is acceptable for close because in-flight
    /// upserts land in a store that is about to be released; the leaked Task
    /// self-terminates when the poll returns. Regression pinned by Task 16
    /// (`testCloseBoundedWhenSyncTeardownBlocks`).
    public func closeAndJoin() async {
        let sync = currentSynchronizer
        _ = await withTimeout(seconds: 2.0) {
            await sync.closeAndJoin()
            return true
        }
        _ = await withTimeout(seconds: 2.0) { [insightDispatcher] in
            await insightDispatcher.closeAndDrain()
            return true
        }
        flagTrackerImpl.close()
        trackInsight.close()
    }
}
