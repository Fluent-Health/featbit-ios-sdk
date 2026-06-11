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
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "co.featbit.lifecycle.network")
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public init(client: FBClient) {
        self.client = client
    }

    /// Registers lifecycle + network observers. Call on the main thread.
    public func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak client] _ in
            client?.setForeground(true)
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak client] _ in
            client?.setForeground(false)
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
    }

    deinit { stop() }
}
#endif
