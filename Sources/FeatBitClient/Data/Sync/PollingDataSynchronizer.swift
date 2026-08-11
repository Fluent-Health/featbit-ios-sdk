import Foundation

/// Periodically polls the FeatBit evaluation server for the current user's feature flags and
/// upserts them into the store. The Swift analogue of the Kotlin/.NET `PollingDataSynchronizer`,
/// with the background loop running as a detached `Task`.
final class PollingDataSynchronizer: DataSynchronizer, @unchecked Sendable {
    private let logger: FBLogger
    private let pollingInterval: TimeInterval
    private let userKey: String
    private let store: MemoryStore
    private let getUserFlags: GetUserFlags

    private let startGate = StartGate()
    private let lock = Lock()
    private var _initialized = false
    private var timestamp: Int64 = 0
    private var loopTask: Task<Void, Never>?
    private var closed = false

    init(options: FBOptions, user: FBUser, store: MemoryStore, getUserFlags: GetUserFlags? = nil) {
        self.logger = options.logger
        self.pollingInterval = options.pollingInterval
        self.userKey = user.key
        self.store = store
        self.getUserFlags = getUserFlags ?? GetUserFlags(options: options, user: user)
    }

    var initialized: Bool {
        lock.withLock { _initialized }
    }

    func start() async -> Bool {
        let task = Task { [weak self] () -> Void in
            await self?.pollingLoop()
        }
        lock.withLock { loopTask = task }
        return await startGate.wait()
    }

    private func pollingLoop() async {
        while !Task.isCancelled {
            await safePoll()
            if Task.isCancelled { break }
            logger.debug { "Waiting for the next polling interval of \(pollingInterval)s." }
            try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
        }
    }

    private func safePoll() async {
        let ts = lock.withLock { timestamp }
        let response = await getUserFlags.run(timestamp: ts)

        if response.isFatal {
            logger.error("Polling data synchronizer encountered fatal HTTP error \(response.statusCode). Stop polling...")
            startGate.complete(false)
            close()
            return
        }

        if response.isError {
            logger.warn("Polling data synchronizer encountered transient HTTP error \(response.statusCode).")
            return
        }

        lock.withLock { timestamp = Int64(Date().timeIntervalSince1970 * 1000) }
        logger.debug { "Polling received \(response.flags.count) flags." }

        for flag in response.flags { store.upsert(flag) }

        let wasInitialized = lock.withLock { () -> Bool in
            let was = _initialized
            _initialized = true
            return was
        }
        if !wasInitialized {
            startGate.complete(true)
            logger.info("Polling data synchronizer initialized for user \(userKey).")
        }
    }

    func close() {
        var shouldComplete = false
        let task = lock.withLock { () -> Task<Void, Never>? in
            if closed { return nil }
            closed = true
            shouldComplete = true
            let t = loopTask
            loopTask = nil
            return t
        }
        guard shouldComplete else { return }
        task?.cancel()
        startGate.complete(false)
    }

    func closeAndJoin() async {
        var task: Task<Void, Never>?
        let shouldComplete: Bool = lock.withLock {
            if closed { return false }
            closed = true
            task = loopTask
            loopTask = nil
            return true
        }
        guard shouldComplete else { return }
        task?.cancel()
        if let task { _ = await task.value }
        startGate.complete(false)
    }
}
