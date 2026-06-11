# FeatBit iOS Example App

A minimal SwiftUI app demonstrating the FeatBit Swift SDK: streaming sync, a `FeatBit`
`ObservableObject` driving live UI, and `FBLifecycleConnector` for background-pause/foreground-resync.

The app **sources** live in `Sources/` (`FeatBitExampleApp.swift`, `ContentView.swift`). To keep the
repository toolchain-agnostic, the Xcode project is not committed — create one in a few steps.

## Running it (on a Mac)

1. In Xcode: **File ▸ New ▸ Project ▸ App** (SwiftUI lifecycle). Name it `FeatBitExampleApp`, save it
   here (`Examples/FeatBitExampleApp/`).
2. Delete the generated `App`/`ContentView` and add the files from `Sources/` to the target.
3. **File ▸ Add Package Dependencies… ▸ Add Local…** and select the repository root, adding the
   `FeatBitClient`, `FeatBitSwiftUI`, and `FeatBitLifecycle` products to the app target.
4. Set your environment `secret` and evaluation-server URLs in `FeatBitExampleApp.swift`.
5. Run on a simulator, then toggle the `game-runner` flag in FeatBit and watch the UI update live.

(Or generate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) / Tuist for a
reproducible setup.)
