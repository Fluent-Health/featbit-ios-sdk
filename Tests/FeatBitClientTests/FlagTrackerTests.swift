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
}
