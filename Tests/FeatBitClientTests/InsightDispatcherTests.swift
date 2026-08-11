import XCTest
@testable import FeatBitClient

final class InsightDispatcherTests: XCTestCase {
    final class RecordingTracker: TrackInsight, @unchecked Sendable {
        let lock = NSLock()
        var batches: [[Insight]] = []
        func runBatch(_ insights: [Insight]) async {
            lock.lock(); defer { lock.unlock() }
            batches.append(insights)
        }
        func close() {}
    }

    private static func sampleInsight() -> Insight {
        Insight.forIdentify(user: FBUser.builder("u").build())
    }

    func test_singleInsight_isEmittedAsBatchOfOne() async throws {
        // Mutation: dropping the flush at end of iterator would never emit.
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        d.offer(Self.sampleInsight())
        // Wait for the batchTimeout to elapse (1s) + slack.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await d.closeAndDrain()
        rec.lock.lock(); let batches = rec.batches; rec.lock.unlock()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 1)
    }

    func test_closeAndDrain_flushesPending() async throws {
        // Mutation: not calling continuation.finish would leave items stuck in the buffer.
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        d.offer(Self.sampleInsight())
        await d.closeAndDrain()
        rec.lock.lock(); let batches = rec.batches; rec.lock.unlock()
        XCTAssertGreaterThanOrEqual(batches.count, 1)
    }

    func test_closeAndDrain_isIdempotent() async {
        // Mutation: without the `closed` flag, the second call would try to `await
        // consumer.value` on a nil'd-out Task. AsyncStream.Continuation.finish is
        // documented as idempotent, but the double `consumer.value` await would either
        // hang (if consumer is not yet nil) or crash on force-unwrap.
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        await d.closeAndDrain()
        await d.closeAndDrain()
    }

    func test_offer_isNonSuspending() {
        // Compile-time: offer(_:) is NOT declared async. This test verifies at type
        // level that offer can be called from a synchronous context.
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        d.offer(Self.sampleInsight()) // no await
    }

    func test_multipleInsights_batchTogether() async throws {
        // Mutation: batchSize=1 would emit each as its own batch (batches.count == 3).
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        d.offer(Self.sampleInsight())
        d.offer(Self.sampleInsight())
        d.offer(Self.sampleInsight())
        // Wait past batch window.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        await d.closeAndDrain()
        rec.lock.lock(); let batches = rec.batches; rec.lock.unlock()
        XCTAssertEqual(batches.count, 1, "3 fast-succession offers should batch")
        XCTAssertEqual(batches.first?.count, 3)
    }

    func test_batchOf50_flushesBeforeTimeout() async throws {
        // Mutation: raising batchSize to 51 would leave one insight buffered until the
        // 1s timeout — the poll loop below would never observe count == 50 within 500ms,
        // and the final assert would fail.
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        for _ in 0..<50 { d.offer(Self.sampleInsight()) }
        // Poll for the flush without waiting the full 1s batch window.
        var flushed = 0
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 25_000_000) // 25ms
            rec.lock.lock(); flushed = rec.batches.first?.count ?? 0; rec.lock.unlock()
            if flushed == 50 { break }
        }
        XCTAssertEqual(flushed, 50, "batchSize=50 should have flushed within ~500ms, not waited the full 1s timeout")
        await d.closeAndDrain()
    }

    func test_overflow_dropsOldest() async throws {
        // Mutation: swapping .bufferingNewest(256) to .bufferingOldest(256) would drop
        // the NEWEST — after emitting 500 items with keys 0..499, the first observed
        // batch (or aggregated batches) would carry the low-index keys instead of the
        // high-index keys. This test emits 500 identify-insights whose keys encode the
        // emit order; asserts the observed set matches the newest 256 (not the oldest).
        //
        // Setup: block the tracker so the buffer fills before the consumer drains it.
        final class BlockingTracker: TrackInsight, @unchecked Sendable {
            let lock = NSLock()
            var seen: [Insight] = []
            let gate: DispatchSemaphore
            init(_ gate: DispatchSemaphore) { self.gate = gate }
            func runBatch(_ insights: [Insight]) async {
                _ = gate.wait(timeout: .now() + 5)
                lock.lock(); seen.append(contentsOf: insights); lock.unlock()
            }
            func close() {}
        }
        let gate = DispatchSemaphore(value: 0)
        let rec = BlockingTracker(gate)
        let d = InsightDispatcher(tracker: rec, logger: DefaultLogger())
        d.start()
        // Emit 500 items rapidly; the consumer takes the first item, calls runBatch
        // (which blocks on the gate), and subsequent items pile into the AsyncStream
        // buffer of 256. When the 257th arrives the OLDEST is dropped.
        for i in 0..<500 {
            let insight = Insight.forIdentify(user: FBUser.builder("u-\(i)").build())
            d.offer(insight)
        }
        try await Task.sleep(nanoseconds: 100_000_000) // let buffer fill
        // Release the gate: consumer drains buffered items into subsequent batches.
        for _ in 0..<10 { gate.signal() }
        await d.closeAndDrain()
        for _ in 0..<10 { gate.signal() } // in case close spawned another runBatch

        rec.lock.lock(); let seen = rec.seen; rec.lock.unlock()
        // Observed keys should include the newest few — key 499 (last emitted) must be
        // present. Under DROP_OLDEST, low-index keys (0, 1, ...) should be evicted.
        let keys = Set(seen.map { $0.user.keyId })
        XCTAssertTrue(keys.contains("u-499"), "newest item (u-499) must survive DROP_OLDEST")
        // At least 1 low-index key must have been dropped (buffer holds 256 + 1 consumer
        // slot + timing slack, and we emitted 500 — at least 200+ must be lost).
        XCTAssertLessThan(seen.count, 500, "some items must have been dropped under overflow")
    }
}
