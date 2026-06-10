import XCTest
@testable import FeatBitClient

/// Port of the Android `LifecycleControllerTest`. Uses a short real grace period rather than virtual
/// time (no Clock dependency), with generous waits so the assertions are timing-robust.
final class LifecycleControllerTests: XCTestCase {
    private let grace: TimeInterval = 0.05

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
}
