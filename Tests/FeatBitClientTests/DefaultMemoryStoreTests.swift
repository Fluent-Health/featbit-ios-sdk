import XCTest
@testable import FeatBitClient

final class DefaultMemoryStoreTests: XCTestCase {
    private final class RecordingListener: FlagChangeListener {
        var events: [FlagValueChangedEvent] = []
        func onChange(_ event: FlagValueChangedEvent) { events.append(event) }
    }

    func testBootstrapIsAvailableImmediately() {
        let store = DefaultMemoryStore(bootstrap: [FeatureFlag(id: "f1", variation: "true")])
        XCTAssertEqual(store.get("f1")?.variation, "true")
        XCTAssertEqual(store.getAll().count, 1)
    }

    func testNewFlagEmitsChangeWithNilOldValue() {
        let store = DefaultMemoryStore()
        let listener = RecordingListener()
        store.addChangeListener(listener)

        store.upsert(FeatureFlag(id: "f1", variation: "true"))

        XCTAssertEqual(listener.events.count, 1)
        XCTAssertEqual(listener.events.first?.key, "f1")
        XCTAssertNil(listener.events.first?.oldValue)
        XCTAssertEqual(listener.events.first?.newValue, "true")
    }

    func testChangedVariationEmitsOldAndNew() {
        let store = DefaultMemoryStore(bootstrap: [FeatureFlag(id: "f1", variation: "true")])
        let listener = RecordingListener()
        store.addChangeListener(listener)

        store.upsert(FeatureFlag(id: "f1", variation: "false"))

        XCTAssertEqual(listener.events.count, 1)
        XCTAssertEqual(listener.events.first?.oldValue, "true")
        XCTAssertEqual(listener.events.first?.newValue, "false")
    }

    func testUnchangedVariationEmitsNothing() {
        let store = DefaultMemoryStore(bootstrap: [FeatureFlag(id: "f1", variation: "true")])
        let listener = RecordingListener()
        store.addChangeListener(listener)

        store.upsert(FeatureFlag(id: "f1", variation: "true", matchReason: "rule match"))

        XCTAssertTrue(listener.events.isEmpty)
        // The flag itself is still replaced (e.g. matchReason updated).
        XCTAssertEqual(store.get("f1")?.matchReason, "rule match")
    }

    func testRemovedListenerStopsReceiving() {
        let store = DefaultMemoryStore()
        let listener = RecordingListener()
        store.addChangeListener(listener)
        store.removeChangeListener(listener)

        store.upsert(FeatureFlag(id: "f1", variation: "true"))

        XCTAssertTrue(listener.events.isEmpty)
    }

    // MARK: Aggressive pinning (Task 10) — thread-safety + listener semantics.

    func testConcurrentUpsertsAreRaceFree() {
        // Mutation: removing the NSLock guard inside upsert would produce
        // torn-write crashes or dictionary corruption under 16-thread hammering.
        // Honest-scope: this catches "no crash + final state is one of the writers'".
        // It does NOT catch a lock removal that only produces wrong-but-plausible
        // final counts, because there's no invariant-count to check.
        let store = DefaultMemoryStore()
        let group = DispatchGroup()
        for t in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<250 {
                    store.upsert(FeatureFlag(id: "k", variation: "v-\(t)-\(i)"))
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let final = store.get("k")
        XCTAssertNotNil(final)
        XCTAssertTrue(final!.variation.hasPrefix("v-"))
    }

    func testListenerObservesJustWrittenValue() {
        // Mutation: notifying listener BEFORE `items[flag.id] = flag` would let the
        // listener's re-read via store.get() return the OLD value. Test pins the
        // happens-before between the items[] write and the listener callback.
        let store = DefaultMemoryStore()
        final class ReReader: FlagChangeListener {
            let store: MemoryStore
            var observed: [String] = []
            init(_ s: MemoryStore) { store = s }
            func onChange(_ event: FlagValueChangedEvent) {
                observed.append(store.get(event.key)?.variation ?? "nil")
            }
        }
        let listener = ReReader(store)
        store.addChangeListener(listener)
        store.upsert(FeatureFlag(id: "k", variation: "v1"))
        store.upsert(FeatureFlag(id: "k", variation: "v2"))
        XCTAssertEqual(listener.observed, ["v1", "v2"])
    }

    func testAddAndRemoveListenersDuringDispatchDoNotCorrupt() {
        // Mutation: iterating `listeners` directly (not the compactMap snapshot at
        // dispatch time) would either crash under Swift's exclusivity check or
        // silently include the just-added listener in the current dispatch.
        // Test asserts (a) no crash and (b) late-added listener does NOT fire for
        // the in-flight event but DOES fire for subsequent events.
        let store = DefaultMemoryStore()
        final class Late: FlagChangeListener {
            var fireCount = 0
            func onChange(_ event: FlagValueChangedEvent) { fireCount += 1 }
        }
        let late = Late()
        final class First: FlagChangeListener {
            let store: MemoryStore
            let late: Late
            init(_ s: MemoryStore, _ l: Late) { store = s; late = l }
            func onChange(_ event: FlagValueChangedEvent) {
                store.addChangeListener(late)
            }
        }
        let first = First(store, late)
        store.addChangeListener(first)
        store.upsert(FeatureFlag(id: "k", variation: "v1"))
        XCTAssertEqual(late.fireCount, 0, "late-added listener must not fire for the in-flight event")
        store.upsert(FeatureFlag(id: "k", variation: "v2"))
        XCTAssertEqual(late.fireCount, 1, "late-added listener fires on subsequent events")
    }

    func testAddChangeListenerIsIdempotent() {
        // Mutation: replacing the `removeAll` scan (line 58 in DefaultMemoryStore)
        // with plain `append` would let the same listener fire N times per event
        // after being added N times.
        let store = DefaultMemoryStore()
        final class Counter: FlagChangeListener {
            var fireCount = 0
            func onChange(_ event: FlagValueChangedEvent) { fireCount += 1 }
        }
        let l = Counter()
        store.addChangeListener(l)
        store.addChangeListener(l)  // re-add same instance
        store.addChangeListener(l)  // and again
        store.upsert(FeatureFlag(id: "k", variation: "v"))
        XCTAssertEqual(l.fireCount, 1, "re-adding same listener must not multiply fires")
    }

    // MARK: Aggressive pinning (Task 26) — upsertAll semantics.

    func testUpsertAllEmptyBatchIsNoOp() {
        // Mutation: dropping the `if flags.isEmpty { return }` short-circuit would
        // still take the lock + do nothing — harmless but wastes cycles. This test
        // guards the listener no-op contract: listeners must not receive a spurious
        // empty-batch signal.
        let store = DefaultMemoryStore()
        var fired = 0
        let listener = ObservingListener { _ in fired += 1 }
        store.addChangeListener(listener)
        store.upsertAll([])
        XCTAssertEqual(fired, 0)
    }

    func testUpsertAllNewFlagEventsFireInOrder() {
        // Mutation: replacing `events.append(...)` inside the loop with a set-based
        // dedupe would drop later events for the same key. Test asserts ORDER
        // matches input, one event per new flag.
        let store = DefaultMemoryStore()
        var order: [String] = []
        let listener = ObservingListener { order.append($0.key) }
        store.addChangeListener(listener)
        store.upsertAll([
            FeatureFlag(id: "a", variation: "1"),
            FeatureFlag(id: "b", variation: "2"),
            FeatureFlag(id: "c", variation: "3"),
        ])
        XCTAssertEqual(order, ["a", "b", "c"])
    }

    func testUpsertAllUnchangedFlagsSkipEvents() {
        // Mutation: emitting an event for unchanged variations would fire twice per
        // "no-op" upsert. Test uses a pre-populated store and asserts unchanged
        // flags don't fire.
        let store = DefaultMemoryStore(bootstrap: [FeatureFlag(id: "a", variation: "same")])
        var events: [FlagValueChangedEvent] = []
        let listener = ObservingListener { events.append($0) }
        store.addChangeListener(listener)
        store.upsertAll([
            FeatureFlag(id: "a", variation: "same"),   // unchanged
            FeatureFlag(id: "b", variation: "new"),    // new
        ])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.key, "b")
    }

    func testUpsertAllOldValueIsPreBatch() {
        // Mutation: computing oldValue AFTER the batch writes complete would report
        // the NEW value for the second flag in a batch that touches related keys.
        // Test: bootstrap has "a"=v1; upsertAll changes "a" to v2. Listener sees
        // oldValue==v1 (pre-batch), not v2.
        let store = DefaultMemoryStore(bootstrap: [FeatureFlag(id: "a", variation: "v1")])
        var reportedOld: String??
        let listener = ObservingListener { reportedOld = $0.oldValue }
        store.addChangeListener(listener)
        store.upsertAll([FeatureFlag(id: "a", variation: "v2")])
        XCTAssertEqual(reportedOld, "v1" as String?)
    }

    func testUpsertAllListenerSeesConsistentPostBatchSnapshot() {
        // Mutation: notifying listeners INSIDE the write lock (after each item)
        // would let the listener re-enter store.get("b") and see a not-yet-written
        // "b". This test's listener reads b when notified for a; b must be
        // present because the batch commits BOTH writes before notifying.
        let store = DefaultMemoryStore()
        var seenBWhenAFires: String?
        let listener = ObservingListener { event in
            if event.key == "a" { seenBWhenAFires = store.get("b")?.variation }
        }
        store.addChangeListener(listener)
        store.upsertAll([
            FeatureFlag(id: "a", variation: "va"),
            FeatureFlag(id: "b", variation: "vb"),
        ])
        XCTAssertEqual(seenBWhenAFires, "vb", "listener for a should observe post-batch state of b")
    }
}

private final class ObservingListener: FlagChangeListener {
    let onChangeCallback: (FlagValueChangedEvent) -> Void
    init(_ cb: @escaping (FlagValueChangedEvent) -> Void) { onChangeCallback = cb }
    func onChange(_ event: FlagValueChangedEvent) { onChangeCallback(event) }
}
