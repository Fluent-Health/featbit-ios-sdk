import SwiftUI
import FeatBitSwiftUI

/// Shows a feature flag's value live. Toggle the `game-runner` flag in your FeatBit dashboard and
/// watch this view update in real time (streaming) without any manual refresh.
struct ContentView: View {
    @EnvironmentObject private var featBit: FeatBit

    private let flagKey = "game-runner"

    var body: some View {
        VStack(spacing: 24) {
            Text("FeatBit iOS Example")
                .font(.title2).bold()

            VStack(spacing: 8) {
                Text("flag '\(flagKey)'")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(featBit.bool(flagKey) ? "ON" : "OFF")
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundColor(featBit.bool(flagKey) ? .green : .red)
            }

            Text("Toggle the flag in FeatBit — this updates live over streaming.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
    }
}
