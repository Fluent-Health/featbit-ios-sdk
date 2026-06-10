import XCTest
@testable import FeatBitClient

/// Full-stack E2E for **streaming** sync: a real ``DefaultFBClient`` in streaming mode connects over
/// a WebSocket to a real FeatBit evaluation server (via ``FeatBitStack``) and receives a
/// server-side flag change as a real-time push. Also covers the lifecycle-aware pause/resume
/// behavior (PR #6 port): background pauses (a server-side toggle is not received while paused),
/// foreground reconnects + resyncs.
///
/// Gated by `FEATBIT_E2E=1` (requires Docker), like ``FeatBitE2ETests``. Streaming additionally
/// requires a working `URLSessionWebSocketTask` (see HANDOVER.md) — verified on Apple platforms.
final class FeatBitStreamingE2ETests: XCTestCase {
    private static let enabled = ProcessInfo.processInfo.environment["FEATBIT_E2E"] == "1"
    private static var stack: FeatBitStack?
    private static var seed: FeatBitStack.SeedResult?

    override class func setUp() {
        super.setUp()
        guard enabled else { return }
        #if !canImport(Darwin)
        // Streaming relies on URLSessionWebSocketTask (Apple-only); don't even stand up the stack.
        return
        #else
        let s = FeatBitStack()
        do {
            try s.start()
            seed = try s.seed()
            stack = s
        } catch {
            XCTFail("E2E stack failed to start: \(error)")
        }
        #endif
    }

    override class func tearDown() {
        stack?.close()
        stack = nil
        seed = nil
        super.tearDown()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.enabled, "Set FEATBIT_E2E=1 (and have Docker) to run E2E tests")
        #if !canImport(Darwin)
        throw XCTSkip("Streaming requires URLSessionWebSocketTask (Apple platforms); skipped here.")
        #endif
    }

    func testStreamsSeededFlagAndReceivesServerSideChange() async throws {
        let seed = try XCTUnwrap(Self.seed)
        let stack = try XCTUnwrap(Self.stack)

        // evaluationBaseURL is http://host:port; streaming uses the ws:// form of the same host.
        let streamingURL = seed.evaluationBaseURL.replacingOccurrences(of: "http", with: "ws")

        let options = FBOptions.Builder(seed.clientSecret)
            .streaming(streamingURL)
            .event(seed.evaluationBaseURL)
            .backgroundGracePeriod(1)
            .build()
        let client = DefaultFBClient(options: options, user: FBUser.builder("e2e-stream-user").name("stream").build())
        defer { client.close() }

        let started = await client.start(timeout: 15)
        XCTAssertTrue(started, "streaming client should connect and initialize")
        XCTAssertTrue(client.initialized)

        let detail = client.boolVariationDetail(seed.flagKey, default: false)
        XCTAssertTrue(detail.value, "seeded flag should evaluate to true over streaming")
        XCTAssertEqual(detail.reason, "default")

        let changes = ChangeRecorder()
        let token = client.flagTracker.subscribe(key: seed.flagKey) { changes.append($0) }
        defer { token.cancel() }

        // Streaming should deliver the change as a push — well within this window.
        try stack.toggleFlag(enabled: false)
        let flipped = await awaitUntil(timeout: 15) { !client.boolVariation(seed.flagKey, default: true) }
        XCTAssertTrue(flipped, "streaming SDK should receive the server-side change")
        XCTAssertEqual(changes.events.last?.newValue, "false")
    }

    func testBackgroundPausesAndForegroundResyncs() async throws {
        let seed = try XCTUnwrap(Self.seed)
        let stack = try XCTUnwrap(Self.stack)

        let streamingURL = seed.evaluationBaseURL.replacingOccurrences(of: "http", with: "ws")
        let options = FBOptions.Builder(seed.clientSecret)
            .streaming(streamingURL)
            .event(seed.evaluationBaseURL)
            .backgroundGracePeriod(1)
            .build()
        let client = DefaultFBClient(options: options, user: FBUser.builder("e2e-bg-user").name("bg").build())
        defer { client.close() }

        // Reset the flag to enabled for a clean baseline, then connect.
        try stack.toggleFlag(enabled: true)
        let started = await client.start(timeout: 15)
        XCTAssertTrue(started)
        _ = await awaitUntil(timeout: 10) { client.boolVariation(seed.flagKey, default: false) }
        XCTAssertTrue(client.boolVariation(seed.flagKey, default: false))

        // Background: after the grace period the streaming socket is paused.
        client.setForeground(false)
        try await Task.sleep(nanoseconds: 2_500_000_000) // past the 1s grace

        // Toggle off while paused — must NOT be received.
        try stack.toggleFlag(enabled: false)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertTrue(client.boolVariation(seed.flagKey, default: false), "paused client should not receive the change")

        // Foreground: reconnect + resync should pick up the change.
        client.setForeground(true)
        let resynced = await awaitUntil(timeout: 15) { !client.boolVariation(seed.flagKey, default: true) }
        XCTAssertTrue(resynced, "foreground should reconnect and resync the server-side change")
    }
}
