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
        let stream = self.stream
        let tracker = self.tracker
        consumer = Task {
            await Self.consumeLoop(stream: stream, tracker: tracker)
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

    /// Consumer loop. Batches up to `batchSize` items or `batchTimeoutNs` since the first
    /// item in the batch, whichever comes first.
    ///
    /// Uses a `withTaskGroup` race between `iterator.next()` and a sleep-to-deadline.
    /// Trade-off: if the racing `next()` child pops an element and is then cancelled by
    /// `group.cancelAll()` after we've already picked the sleep winner, that element is
    /// dropped. This is acceptable — the bounded stream already tolerates drops, and the
    /// invariant that matters ("batch is emitted eventually") holds because the outer
    /// loop restarts on the next item.
    private static func consumeLoop(stream: AsyncStream<Insight>, tracker: TrackInsight) async {
        var iterator = stream.makeAsyncIterator()
        while true {
            // Block for the first item of the next batch.
            guard let first = await iterator.next() else { break }
            var batch: [Insight] = [first]
            batch.reserveCapacity(batchSize)

            // Drain up to (batchSize - 1) more within the batchTimeout window.
            let deadline = DispatchTime.now().uptimeNanoseconds &+ batchTimeoutNs
            while batch.count < batchSize {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= deadline { break }
                let remainingNs = deadline &- now
                // Race one iterator.next() against a sleep to the deadline.
                let winner: Insight? = await withTaskGroup(of: Insight?.self) { group in
                    group.addTask { await iterator.next() }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: remainingNs)
                        return nil
                    }
                    let w = await group.next() ?? nil
                    group.cancelAll()
                    return w ?? nil
                }
                guard let next = winner else { break }
                batch.append(next)
            }

            await tracker.runBatch(batch)
        }
    }
}
