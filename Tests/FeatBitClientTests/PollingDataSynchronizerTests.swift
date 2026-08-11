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
}
