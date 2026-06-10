#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import Combine
import FeatBitClient

/// A SwiftUI-friendly wrapper around an ``FBClient``. It republishes flag changes via
/// `objectWillChange`, so any SwiftUI view that reads a flag through this object re-renders the
/// moment the flag's value changes.
///
/// ```swift
/// @StateObject private var featBit = FeatBit(client)
///
/// var body: some View {
///     if featBit.bool("new-checkout") { NewCheckout() } else { OldCheckout() }
/// }
/// ```
@MainActor
public final class FeatBit: ObservableObject {
    /// The underlying client, for evaluation calls not covered by the convenience accessors.
    public let client: FBClient
    private var subscription: FlagSubscription?

    public init(_ client: FBClient) {
        self.client = client
        subscription = client.flagTracker.subscribe { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    public func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        client.boolVariation(key, default: defaultValue)
    }

    public func string(_ key: String, default defaultValue: String = "") -> String {
        client.stringVariation(key, default: defaultValue)
    }

    public func int(_ key: String, default defaultValue: Int = 0) -> Int {
        client.intVariation(key, default: defaultValue)
    }

    public func double(_ key: String, default defaultValue: Double = 0) -> Double {
        client.doubleVariation(key, default: defaultValue)
    }
}

private struct FeatBitEnvironmentKey: EnvironmentKey {
    static let defaultValue: FeatBit? = nil
}

public extension EnvironmentValues {
    /// The ``FeatBit`` instance injected via ``SwiftUI/View/featBit(_:)``.
    var featBit: FeatBit? {
        get { self[FeatBitEnvironmentKey.self] }
        set { self[FeatBitEnvironmentKey.self] = newValue }
    }
}

public extension View {
    /// Injects a ``FeatBit`` into the environment for descendant views.
    func featBit(_ featBit: FeatBit) -> some View {
        environment(\.featBit, featBit)
    }

    /// Drives the client's foreground hook from SwiftUI's `scenePhase` — a lightweight alternative
    /// to `FBLifecycleConnector` for SwiftUI-first apps. Combine with network signals as needed.
    @available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
    func featBitScenePhase(_ client: FBClient) -> some View {
        modifier(FeatBitScenePhaseModifier(client: client))
    }
}

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
private struct FeatBitScenePhaseModifier: ViewModifier {
    let client: FBClient
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { phase in
            client.setForeground(phase == .active)
        }
    }
}
#endif
