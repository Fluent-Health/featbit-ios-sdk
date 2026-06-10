import Foundation

/// Drives a ``DataSynchronizer`` from app-lifecycle and network signals: the synchronizer is kept
/// "active" only while the app is foregrounded **and** the network is available. Transitions to
/// inactive are debounced by `graceSeconds` so brief app-switches or network blips don't tear the
/// connection down. Transitions are serialized by the actor.
///
/// Signals default to active (foreground + online), so a client whose hooks are never called
/// behaves exactly as before (always-on synchronization). Port of the Kotlin `LifecycleController`.
actor LifecycleController {
    private let graceSeconds: TimeInterval
    private let synchronizer: @Sendable () -> DataSynchronizer

    private var foreground = true
    private var online = true
    private var active = true
    private var pauseTask: Task<Void, Never>?

    init(graceSeconds: TimeInterval, synchronizer: @escaping @Sendable () -> DataSynchronizer) {
        self.graceSeconds = graceSeconds
        self.synchronizer = synchronizer
    }

    func onForegroundChanged(_ value: Bool) {
        foreground = value
        reconcile()
    }

    func onNetworkChanged(_ value: Bool) {
        online = value
        reconcile()
    }

    private func reconcile() {
        if foreground && online {
            // Became (or stayed) active: cancel any pending pause; resume if paused.
            pauseTask?.cancel()
            pauseTask = nil
            if !active {
                active = true
                synchronizer().resume()
            }
        } else if active && pauseTask == nil {
            // Became inactive: pause after a grace period unless we become active again.
            let grace = graceSeconds
            pauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.applyPauseIfStillInactive()
            }
        }
    }

    private func applyPauseIfStillInactive() {
        pauseTask = nil
        if !(foreground && online) {
            active = false
            synchronizer().pause()
        }
    }
}
