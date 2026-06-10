import XCTest
@testable import FeatBitClient

/// Full-stack end-to-end test: a real ``DefaultFBClient`` driven against a real FeatBit evaluation
/// server (stood up via Docker in ``FeatBitStack``).
///
/// Gated by `FEATBIT_E2E=1` so the default unit-test pass never requires Docker. Mirrors the
/// Android `FeatBitE2ETest`.
final class FeatBitE2ETests: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["FEATBIT_E2E"] == "1"
    private static var stack: FeatBitStack?
    private static var seed: FeatBitStack.SeedResult?

    override class func setUp() {
        super.setUp()
        guard enabled else { return }
        let s = FeatBitStack()
        do {
            try s.start()
            seed = try s.seed()
            stack = s
        } catch {
            XCTFail("E2E stack failed to start: \(error)")
        }
    }

    override class func tearDown() {
        stack?.close()
        stack = nil
        seed = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.enabled, "Set FEATBIT_E2E=1 (and have Docker) to run E2E tests")
    }

    func testStartEvaluateObserveChangeAndIdentify() async throws {
        let seed = try XCTUnwrap(Self.seed)
        let stack = try XCTUnwrap(Self.stack)

        let options = FBOptions.Builder(seed.clientSecret)
            .polling(seed.evaluationBaseURL, interval: 1)
            .event(seed.evaluationBaseURL)
            .build()
        let client = DefaultFBClient(options: options, user: FBUser.builder("e2e-user").name("e2e").build())
        defer { client.close() }

        let started = await client.start(timeout: 15)
        XCTAssertTrue(started, "client should start within timeout")
        XCTAssertTrue(client.initialized)

        // Seeded flag is enabled -> serves the "true" variation via the real eval server.
        let detail = client.boolVariationDetail(seed.flagKey, default: false)
        XCTAssertTrue(detail.value, "seeded flag should evaluate to true")
        XCTAssertEqual(detail.reason, "default")

        let changes = ChangeRecorder()
        let token = client.flagTracker.subscribe(key: seed.flagKey) { changes.append($0) }
        defer { token.cancel() }

        // Flip the flag off server-side; the polling SDK must observe it.
        try stack.toggleFlag(enabled: false)
        let flipped = await awaitUntil(timeout: 20) { !client.boolVariation(seed.flagKey, default: true) }
        XCTAssertTrue(flipped, "SDK should observe the server-side flag change via polling")
        XCTAssertFalse(changes.events.isEmpty, "a flag-change event should have fired")
        XCTAssertEqual(changes.events.last?.newValue, "false")

        // Switching the evaluation user still works end-to-end.
        let identified = await client.identify(FBUser.builder("another-user").name("another").build(), timeout: 15)
        XCTAssertTrue(identified, "identify should succeed")
    }
}

/// Thread-safe recorder for flag-change events delivered from background callbacks.
final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [FlagValueChangedEvent] = []
    var events: [FlagValueChangedEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func append(_ event: FlagValueChangedEvent) { lock.lock(); _events.append(event); lock.unlock() }
}

extension XCTestCase {
    /// Polls `predicate` until it is true or `timeout` elapses.
    func awaitUntil(timeout: TimeInterval, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return predicate()
    }
}
