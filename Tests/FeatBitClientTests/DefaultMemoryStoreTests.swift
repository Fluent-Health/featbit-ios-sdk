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
}
