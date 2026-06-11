#if canImport(UIKit) && canImport(Network)
import Foundation
import UIKit
import Network
import FeatBitClient

/// Wires iOS app-lifecycle and network signals into an ``FBClient``. With this connector, a
/// streaming client drops its WebSocket shortly after the app is backgrounded or goes offline, and
/// re-establishes it (with an immediate resync) on foreground / when connectivity returns.
///
/// This is the optional platform glue for the neutral hooks on ``FBClient``
/// (``FBClient/setForeground(_:)`` / ``FBClient/setNetworkAvailable(_:)``); apps that don't use it
/// pay no UIKit/Network dependency on the core module. iOS analogue of the Android
/// `FBLifecycleConnector` (`ProcessLifecycleOwner` + `ConnectivityManager`).
///
/// ```swift
/// // e.g. in your App init or AppDelegate
/// let connector = FBLifecycleConnector(client: fbClient)
/// connector.start()
/// ```
public final class FBLifecycleConnector {
    private let client: FBClient
    private let backgroundGracePeriod: TimeInterval
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "co.featbit.lifecycle.network")
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var backgroundHold: UIBackgroundTaskIdentifier = .invalid

    /// How long past the grace period the background hold lasts, covering pause + socket teardown.
    private static let holdBuffer: TimeInterval = 5

    /// - Parameter backgroundGracePeriod: must match `FBOptions.backgroundGracePeriod` so the
    ///   process is kept alive exactly long enough for the client's grace timer to pause streaming.
    public init(client: FBClient, backgroundGracePeriod: TimeInterval = FBOptions.Defaults.backgroundGracePeriod) {
        self.client = client
        self.backgroundGracePeriod = backgroundGracePeriod
    }

    /// Registers lifecycle + network observers. Call on the main thread.
    public func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundHold()
            self?.client.setForeground(true)
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.client.setForeground(false)
            // Unlike Android, iOS suspends the process shortly after backgrounding, freezing the
            // client's grace timer before it can pause streaming (the pause would otherwise fire
            // only on foreground thaw). Hold background execution just long enough for the timer
            // to fire and the socket to close cleanly. iOS caps this allowance (~30s): grace
            // periods beyond the cap degrade to pausing on the next foreground instead.
            self?.beginBackgroundHold()
        })

        monitor.pathUpdateHandler = { [weak client] path in
            client?.setNetworkAvailable(path.status == .satisfied)
        }
        monitor.start(queue: monitorQueue)
    }

    /// Unregisters observers. Call when the client is no longer used.
    public func stop() {
        guard started else { return }
        started = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        monitor.cancel()
        endBackgroundHold()
    }

    private func beginBackgroundHold() {
        endBackgroundHold()
        backgroundHold = UIApplication.shared.beginBackgroundTask(withName: "co.featbit.streaming-grace") { [weak self] in
            self?.endBackgroundHold()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + backgroundGracePeriod + Self.holdBuffer) { [weak self] in
            self?.endBackgroundHold()
        }
    }

    private func endBackgroundHold() {
        guard backgroundHold != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundHold)
        backgroundHold = .invalid
    }

    deinit { stop() }
}
#endif
