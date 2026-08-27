import XCTest
@testable import FeatBitClient

final class PollingDataSynchronizerTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }
    override func tearDown() { MockURLProtocol.reset() }

    private func makeSynchronizer(store: MemoryStore) throws -> PollingDataSynchronizer {
        let options = try FBOptions.Builder("secret")
            .polling("https://eval.example.com", interval: 60)
            .build()
        let user = FBUser.builder("u1").build()
        let getUserFlags = GetUserFlags(options: options, user: user, session: MockURLProtocol.session())
        return PollingDataSynchronizer(options: options, user: user, store: store, getUserFlags: getUserFlags)
    }

    private func makeFastSynchronizer(store: MemoryStore, interval: TimeInterval) throws -> PollingDataSynchronizer {
        let options = try FBOptions.Builder("secret")
            .polling("https://eval.example.com", interval: interval)
            .build()
        let user = FBUser.builder("u1").build()
        let getUserFlags = GetUserFlags(options: options, user: user, session: MockURLProtocol.session())
        return PollingDataSynchronizer(options: options, user: user, store: store, getUserFlags: getUserFlags)
    }

    func testStartInitializesAndPopulatesStore() async throws {
        MockURLProtocol.handler = { _ in
            let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"true","matchReason":"default"}]}}"#
            return (200, Data(body.utf8))
        }
        let store = DefaultMemoryStore()
        let sync = try makeSynchronizer(store: store)

        let ready = await sync.start()

        XCTAssertTrue(ready)
        XCTAssertTrue(sync.initialized)
        XCTAssertEqual(store.get("f1")?.variation, "true")
        sync.close()
    }

    func testFatalErrorFailsStart() async throws {
        MockURLProtocol.handler = { _ in (401, Data()) }
        let store = DefaultMemoryStore()
        let sync = try makeSynchronizer(store: store)

        let ready = await sync.start()

        XCTAssertFalse(ready)
        XCTAssertFalse(sync.initialized)
    }

    func testCloseAndJoinAwaitsInFlightUpsert() async throws {
        // Mutation: replacing `_ = await task.value` with plain `task.cancel()` (no await)
        // would let closeAndJoin return before the barrier is released — this test would
        // then observe `didClose == true` before releaseUpsert() runs, catching the race.
        MockURLProtocol.reset()
        let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"true","matchReason":"default"}]}}"#
        MockURLProtocol.enqueue(status: 200, jsonBody: body)

        let inner = DefaultMemoryStore()
        let barrier = BarrierStore(inner)
        let sync = try makeSynchronizer(store: barrier)

        // Start returns after startGate completes (first successful poll) — but the barrier
        // blocks the first upsert, so start() will not complete until we release. Launch
        // start in a Task so we can drive close in parallel.
        let started = Task { await sync.start() }

        XCTAssertTrue(barrier.waitForEnter(timeout: 2), "first upsert did not enter barrier")

        // Use a plain shared flag flipped when closeAndJoin completes. Avoid awaiting the
        // closing task inside a TaskGroup — that starves Swift's cooperative pool while
        // the loop task is blocked on the synchronous semaphore.
        let didCloseLock = NSLock()
        nonisolated(unsafe) var didClose = false
        let closing = Task {
            await sync.closeAndJoin()
            didCloseLock.lock(); didClose = true; didCloseLock.unlock()
        }

        // Give closeAndJoin 200ms to prove it does NOT return before we release the barrier.
        try await Task.sleep(nanoseconds: 200_000_000)
        didCloseLock.lock()
        let closedEarly = didClose
        didCloseLock.unlock()
        XCTAssertFalse(closedEarly, "closeAndJoin returned before upsert completed — race window open")

        // Release the barrier. closeAndJoin should now progress.
        barrier.releaseUpsert()
        await closing.value
        _ = await started.value
        // start() may return true (first poll succeeded before close) or false
        // (closeAndJoin completed startGate first). Either is acceptable — the race pin
        // is that closeAndJoin blocked until upsert completed, not the start() outcome.
    }

    // MARK: Aggressive pinning (Task 12) — loop cadence + transient 5xx recovery.

    func testPollingLoopIssuesRepeatedRequestsAcrossInterval() async throws {
        // Mutation: removing the `while !Task.isCancelled` loop in pollingLoop
        // would produce exactly 1 request.
        MockURLProtocol.reset()
        let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"true","matchReason":"default"}]}}"#
        MockURLProtocol.handler = { _ in (200, Data(body.utf8)) }

        let store = DefaultMemoryStore()
        let sync = try makeFastSynchronizer(store: store, interval: 0.05)
        let started = Task { await sync.start() }
        // 500ms window at 50ms interval — CI runners under load see Task.sleep
        // jitter of ~50-150ms, so 200ms was too tight. 500ms comfortably covers
        // ≥3 polls even on slow shared runners.
        try await Task.sleep(nanoseconds: 500_000_000)
        await sync.closeAndJoin()
        _ = await started.value
        XCTAssertGreaterThanOrEqual(MockURLProtocol.requests.count, 3, "polling loop should issue ≥3 requests within 500ms at 50ms interval")
    }

    func testTransient500DoesNotStopLoopAndNext200Initializes() async throws {
        // Mutation: treating 500 as fatal (adding response.statusCode == 500 to
        // isFatal) would call close() inside safePoll, and start() would return false.
        MockURLProtocol.reset()
        let call = NSLock()
        var callCount = 0
        MockURLProtocol.handler = { _ in
            call.lock(); callCount += 1; let n = callCount; call.unlock()
            if n == 1 { return (500, Data()) }
            let body = #"{"data":{"featureFlags":[{"id":"f1","variation":"recovered","matchReason":"default"}]}}"#
            return (200, Data(body.utf8))
        }
        let store = DefaultMemoryStore()
        let sync = try makeFastSynchronizer(store: store, interval: 0.05)
        let ready = await withTimeout(seconds: 2.0) { await sync.start() }
        XCTAssertEqual(ready, true, "transient 500 should not stop the loop; next 200 should initialize")
        XCTAssertEqual(store.get("f1")?.variation, "recovered")
        await sync.closeAndJoin()
    }
}
