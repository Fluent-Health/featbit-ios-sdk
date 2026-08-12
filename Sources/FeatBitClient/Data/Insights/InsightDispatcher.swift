import Foundation

/// Bounded, batching insight pipeline.
///
/// Emit side is non-suspending (`offer(_:)`); consumer side batches up to 50 insights
/// or 1s (whichever comes first) and hands the batch to the injected
/// `TrackInsight.runBatch(_:)`.
///
/// Backpressure: when the internal buffer is full the OLDEST queued insight is dropped
/// (`AsyncStream.Continuation.BufferingPolicy.bufferingNewest(256)`), matching the
/// Kotlin `Channel(256, DROP_OLDEST)` behavior.
///
/// `closeAndDrain()` finishes the stream and awaits the consumer within a 2s budget.
final class InsightDispatcher: @unchecked Sendable {
    private let tracker: TrackInsight
    private let logger: FBLogger
    private let stream: AsyncStream<Insight>
    private let continuation: AsyncStream<Insight>.Continuation
    private let lock = NSLock()
    private var consumer: Task<Void, Never>?
    private var closed = false

    private static let bufferSize = 256
    private static let batchSize = 50
    private static let batchTimeoutNs: UInt64 = 1_000_000_000
    private static let drainBudgetSeconds: TimeInterval = 2.0

    init(tracker: TrackInsight, logger: FBLogger) {
        self.tracker = tracker
        self.logger = logger
        var cont: AsyncStream<Insight>.Continuation!
        self.stream = AsyncStream<Insight>(bufferingPolicy: .bufferingNewest(Self.bufferSize)) { c in
            cont = c
        }
        self.continuation = cont
    }

    /// Start the consumer. Safe to call once; second call is a no-op.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard consumer == nil, !closed else { return }
        consumer = Task { [weak self] in
            await self?.consumeLoop()
        }
    }

    /// Non-suspending emit. Called on the hot evaluation path.
    func offer(_ insight: Insight) {
        continuation.yield(insight)
    }

    /// Suspending drain: finish the continuation, then await the consumer within a 2s budget.
    func closeAndDrain() async {
        let toAwait: Task<Void, Never>? = {
            lock.lock(); defer { lock.unlock() }
            if closed { return nil }
            closed = true
            let t = consumer
            consumer = nil
            return t
        }()
        continuation.finish()
        guard let toAwait else { return }
        _ = await withTimeout(seconds: Self.drainBudgetSeconds) {
            _ = await toAwait.value
            return true
        }
    }

    /// Consumer loop. Reads from the stream via `for await` (no captured-var mutation
    /// hazard). Batches accumulate in a lock-guarded array with a size trigger; a
    /// separate timer Task flushes the pending batch every `batchTimeoutNs` even when
    /// no size trigger fires. Both size-triggered and timeout-triggered flushes go
    /// through the same `flush(tracker:)` helper.
    ///
    /// Design rationale: an earlier version raced `iterator.next()` against a sleep in
    /// a `withTaskGroup`, but capturing the iterator in an `@Sendable` closure trips
    /// Swift's strict-concurrency check ("mutation of captured var 'iterator' in
    /// concurrently-executing code"). The current design keeps the iterator on a
    /// single task and uses shared mutable state (lock-guarded pending array) as the
    /// synchronization point between the reader and the timer.
    private func consumeLoop() async {
        let stream = self.stream
        let tracker = self.tracker

        // Start the timer task. It runs alongside the for-await loop and flushes the
        // pending batch every batchTimeoutNs. Cancelled when the stream finishes.
        let timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.batchTimeoutNs)
                if Task.isCancelled { break }
                await self.flush(tracker: tracker)
            }
        }

        for await insight in stream {
            let shouldFlush: Bool = self.pendingLock.withLock {
                self.pending.append(insight)
                return self.pending.count >= Self.batchSize
            }
            if shouldFlush {
                await flush(tracker: tracker)
            }
        }

        // Stream finished. Cancel the timer and flush any remaining items.
        timer.cancel()
        await flush(tracker: tracker)
    }

    private let pendingLock = NSLock()
    private var pending: [Insight] = []

    private func flush(tracker: TrackInsight) async {
        let batch: [Insight] = pendingLock.withLock {
            let b = pending
            pending.removeAll(keepingCapacity: true)
            return b
        }
        if batch.isEmpty { return }
        await tracker.runBatch(batch)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
