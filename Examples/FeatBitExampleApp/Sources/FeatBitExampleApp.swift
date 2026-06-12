import SwiftUI
import FeatBitClient
import FeatBitSwiftUI
import FeatBitLifecycle

/// Minimal SwiftUI app demonstrating the FeatBit Swift SDK end-to-end:
/// streaming sync, a `FeatBit` `ObservableObject` driving live UI updates, and the
/// `FBLifecycleConnector` so backgrounding pauses streaming and foregrounding resyncs.
///
/// Replace `secret` and the URLs with your FeatBit environment values.
@main
struct FeatBitExampleApp: App {
    @StateObject private var featBit: FeatBit
    private let connector: FBLifecycleConnector
    private let client: FBClient

    init() {
        // TODO: replace with your environment secret + evaluation-server URLs.
        let secret = "<replace-with-your-env-secret>"
        let options = FBOptions.Builder(secret)
            .streaming("wss://app-eval.featbit.co")
            .event("https://app-eval.featbit.co")
            .build()

        let user = FBUser.builder("example-user").name("Example").custom("platform", "ios").build()
        let client = DefaultFBClient(options: options, user: user)
        self.client = client
        _featBit = StateObject(wrappedValue: FeatBit(client))

        // Auto-wire lifecycle + connectivity so streaming pauses/resumes with the app.
        self.connector = FBLifecycleConnector(client: client)
        connector.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(featBit)
                // .onAppear, not .task: the latter is iOS 15+ and the app targets the SDK's iOS 14 floor.
                .onAppear { [client] in Task { await client.start(timeout: 5) } }
        }
    }
}
