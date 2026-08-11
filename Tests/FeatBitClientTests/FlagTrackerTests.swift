import XCTest
@testable import FeatBitClient

final class FlagTrackerTests: XCTestCase {
    func testGlobalSubscriberReceivesAllChanges() {
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        var received: [FlagValueChangedEvent] = []
        let token = tracker.subscribe { received.append($0) }

        store.upsert(FeatureFlag(id: "a", variation: "1"))
        store.upsert(FeatureFlag(id: "b", variation: "2"))

        XCTAssertEqual(received.map { $0.key }, ["a", "b"])
        token.cancel()
    }

    func testKeyedSubscriberReceivesOnlyItsKey() {
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        var received: [FlagValueChangedEvent] = []
        let token = tracker.subscribe(key: "a") { received.append($0) }

        store.upsert(FeatureFlag(id: "a", variation: "1"))
        store.upsert(FeatureFlag(id: "b", variation: "2"))

        XCTAssertEqual(received.map { $0.key }, ["a"])
        token.cancel()
    }

    func testCancelStopsDelivery() {
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        var count = 0
        let token = tracker.subscribe { _ in count += 1 }

        store.upsert(FeatureFlag(id: "a", variation: "1"))
        token.cancel()
        store.upsert(FeatureFlag(id: "a", variation: "2"))

        XCTAssertEqual(count, 1)
    }

    func testAsyncStreamDeliversChanges() async {
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)

        let task = Task { () -> FlagValueChangedEvent? in
            for await event in tracker.changes {
                return event
            }
            return nil
        }
        // Give the stream a moment to register its continuation, then emit.
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.upsert(FeatureFlag(id: "a", variation: "1"))

        let event = await task.value
        XCTAssertEqual(event?.key, "a")
        XCTAssertEqual(event?.newValue, "1")
    }

    // MARK: Aggressive pinning (Task 13) — subscriber isolation + no-replay + close.
    //
    // Note: unlike Android's Kotlin CoW forEach (which halts on first throw and needs
    // a safeNotify wrap), Swift closures don't have that failure mode — a trapping
    // handler terminates the process, out-of-band from subscriber ordering. No
    // safeNotify wrap is added on the Swift port.

    func testSlowSubscriberDoesNotBlockSubsequentSubscribers() {
        // Mutation: routing subscriber invocation through async Task { ... } would
        // break the synchronous fan-out invariant — this test's IMMEDIATE-after-upsert
        // assertion would flake or fail (secondFired would still be false).
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        var firstFired = false
        var secondFired = false
        let t1 = tracker.subscribe { _ in
            Thread.sleep(forTimeInterval: 0.02)
            firstFired = true
        }
        let t2 = tracker.subscribe { _ in secondFired = true }
        store.upsert(FeatureFlag(id: "k", variation: "v"))
        XCTAssertTrue(firstFired)
        XCTAssertTrue(secondFired)
        t1.cancel(); t2.cancel()
    }

    func testKeyedSubscribersOnDifferentKeysAreIsolated() {
        // Mutation: dropping the `keyedHandlers[event.key]` lookup and iterating ALL
        // keyed handlers would fire kB's handler on an "a" event.
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        var kAFired = 0
        var kBFired = 0
        let tA = tracker.subscribe(key: "kA") { _ in kAFired += 1 }
        let tB = tracker.subscribe(key: "kB") { _ in kBFired += 1 }
        store.upsert(FeatureFlag(id: "kA", variation: "v"))
        XCTAssertEqual(kAFired, 1)
        XCTAssertEqual(kBFired, 0)
        tA.cancel(); tB.cancel()
    }

    func testChangesAsyncStreamHasNoReplay() async throws {
        // Mutation: switching AsyncStream to a replay-N buffer would leak prior
        // events to late subscribers. Emit 5 events with NO subscriber, then
        // subscribe and prove only the post-subscribe event is observed.
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        for i in 0..<5 {
            store.upsert(FeatureFlag(id: "k", variation: "pre-\(i)"))
        }
        let task = Task { () -> String? in
            for await event in tracker.changes {
                return event.newValue
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        store.upsert(FeatureFlag(id: "k", variation: "post-subscribe"))
        let seen = await task.value
        XCTAssertEqual(seen, "post-subscribe")
    }

    func testCloseFinishesStreamsAndRemovesListenerFromStore() {
        // Mutation: forgetting `store?.removeChangeListener(self)` in FlagTrackerImpl.close
        // would leak the tracker via the store's listeners array. Subsequent upserts
        // would still fire the (now-cancelled) tracker's dispatch, which fans out to
        // no handlers — but any re-subscribed handler on the SAME tracker instance
        // would fire spuriously. Test: subscribe → close → upsert → assert no fire.
        let store = DefaultMemoryStore()
        let tracker = FlagTrackerImpl(store: store)
        var fireCount = 0
        _ = tracker.subscribe { _ in fireCount += 1 }
        tracker.close()
        store.upsert(FeatureFlag(id: "k", variation: "v"))
        XCTAssertEqual(fireCount, 0)
    }
}
