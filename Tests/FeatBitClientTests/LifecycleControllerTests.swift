import XCTest
@testable import FeatBitClient

/// Port of the Android `LifecycleControllerTest`. Uses a short real grace period rather than virtual
/// time (no Clock dependency), with generous waits so the assertions are timing-robust.
final class LifecycleControllerTests: XCTestCase {
    // Grace is generous (150ms) so CI runners under load still meet the timing
    // budgets. `sleepPastGrace()` waits 3x this — 450ms — which is comfortably
    // longer than macOS-CI Task.sleep jitter (~50-150ms on shared runners).
    private let grace: TimeInterval = 0.15

    private final class MockSynchronizer: DataSynchronizer, @unchecked Sendable {
        let initialized = true
        func start() async -> Bool { true }
        func close() {}

        private let lock = NSLock()
        private var _pauseCount = 0
        private var _resumeCount = 0
        var pauseCount: Int { lock.lock(); defer { lock.unlock() }; return _pauseCount }
        var resumeCount: Int { lock.lock(); defer { lock.unlock() }; return _resumeCount }
        func pause() { lock.lock(); _pauseCount += 1; lock.unlock() }
        func resume() { lock.lock(); _resumeCount += 1; lock.unlock() }
    }

    private func makeController(_ sync: MockSynchronizer) -> LifecycleController {
        LifecycleController(graceSeconds: grace) { sync }
    }

    private func sleepPastGrace() async {
        try? await Task.sleep(nanoseconds: UInt64(grace * 3 * 1_000_000_000))
    }

    func testBackgroundPausesAfterGrace() async {
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onForegroundChanged(false)
        await sleepPastGrace()

        XCTAssertEqual(sync.pauseCount, 1)
        XCTAssertEqual(sync.resumeCount, 0)
    }

    func testQuickReturnDoesNotChurn() async {
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onForegroundChanged(false)
        await controller.onForegroundChanged(true) // returns before grace elapses
        await sleepPastGrace()

        XCTAssertEqual(sync.pauseCount, 0)
        XCTAssertEqual(sync.resumeCount, 0)
    }

    func testResumeAfterPause() async {
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onForegroundChanged(false)
        await sleepPastGrace()
        await controller.onForegroundChanged(true)
        // Allow the resume transition to run.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(sync.pauseCount, 1)
        XCTAssertEqual(sync.resumeCount, 1)
    }

    func testNetworkLossAndRegain() async {
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onNetworkChanged(false)
        await sleepPastGrace()
        XCTAssertEqual(sync.pauseCount, 1)

        await controller.onNetworkChanged(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.resumeCount, 1)
    }

    // MARK: Aggressive pinning (Task 11) — flap/race semantics.

    func testForegroundFlapWithinGraceReanchorsPause() async {
        // Mutation: removing `pauseTask?.cancel(); pauseTask = nil` in reconcile()
        // when becoming (or staying) active would fire the pause on the original
        // schedule (T=grace after the first off) instead of anchoring to the
        // second off (T>=2*grace).
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onForegroundChanged(false)
        // Half-grace: still pending.
        try? await Task.sleep(nanoseconds: UInt64(grace * 0.5 * 1_000_000_000))
        await controller.onForegroundChanged(true)
        // Small gap so the cancel + reconcile settles.
        try? await Task.sleep(nanoseconds: UInt64(grace * 0.5 * 1_000_000_000))
        await controller.onForegroundChanged(false)

        // At T = grace after the ORIGINAL off, pause must NOT have fired
        // (the original schedule was cancelled).
        try? await Task.sleep(nanoseconds: UInt64(grace * 0.6 * 1_000_000_000))
        XCTAssertEqual(sync.pauseCount, 0, "pause fired on the cancelled original schedule")

        // Past the re-anchored deadline: pause must have fired exactly once.
        try? await Task.sleep(nanoseconds: UInt64(grace * 3 * 1_000_000_000))
        XCTAssertEqual(sync.pauseCount, 1, "pause did not fire on the re-anchored schedule")
    }

    func testNetworkOnWhileForegroundOffDoesNotResume() async {
        // Mutation: replacing `if foreground && online` with `if online` inside
        // reconcile would resume the synchronizer while the app is still
        // backgrounded.
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onForegroundChanged(false)
        await sleepPastGrace()
        XCTAssertEqual(sync.pauseCount, 1)

        // Network flap while foreground is still false — must NOT resume.
        await controller.onNetworkChanged(false)
        await controller.onNetworkChanged(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.resumeCount, 0, "resume fired while foreground was still off")

        // Now foreground back on — resume must fire.
        await controller.onForegroundChanged(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(sync.resumeCount, 1)
    }

    func testSecondInactiveSignalWhilePausePendingDoesNotDoubleSchedule() async {
        // Mutation: dropping the `pauseTask == nil` guard in reconcile() would
        // double-schedule the pause when foreground-off is followed by network-off
        // within the grace window — pauseCount would end up 2 instead of 1.
        let sync = MockSynchronizer()
        let controller = makeController(sync)

        await controller.onForegroundChanged(false)
        // Second inactive signal while the first is still pending.
        try? await Task.sleep(nanoseconds: UInt64(grace * 0.3 * 1_000_000_000))
        await controller.onNetworkChanged(false)

        try? await Task.sleep(nanoseconds: UInt64(grace * 3 * 1_000_000_000))
        XCTAssertEqual(sync.pauseCount, 1, "second inactive signal double-scheduled the pause")
    }
}
