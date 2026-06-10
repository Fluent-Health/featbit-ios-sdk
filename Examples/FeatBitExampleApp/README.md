# FeatBit iOS Example App

A minimal SwiftUI app demonstrating the FeatBit Swift SDK: streaming sync, a `FeatBit`
`ObservableObject` driving live UI, and `FBLifecycleConnector` for background-pause/foreground-resync.

## Status

The app **sources** live in `Sources/` (`FeatBitExampleApp.swift`, `ContentView.swift`). The Xcode
project (`FeatBitExampleApp.xcodeproj`) is **not** committed — an iOS developer creates it on a Mac
(see the repository [`HANDOVER.md`](../../HANDOVER.md)). CI's macOS job expects that project.

## Creating the project (on a Mac)

1. In Xcode: **File ▸ New ▸ Project ▸ App** (SwiftUI lifecycle). Name it `FeatBitExampleApp`, save it
   here (`Examples/FeatBitExampleApp/`).
2. Delete the generated `App`/`ContentView` and add the files from `Sources/` to the target.
3. **File ▸ Add Package Dependencies… ▸ Add Local…** and select the repository root, adding the
   `FeatBitClient`, `FeatBitSwiftUI`, and `FeatBitLifecycle` products to the app target.
4. Set your environment `secret` and evaluation-server URLs in `FeatBitExampleApp.swift`.
5. Run on a simulator, then toggle the `game-runner` flag in FeatBit and watch the UI update live.

(Or generate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen) / Tuist for a
reproducible setup.)
