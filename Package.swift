// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FeatBit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14),
        .watchOS(.v7),
    ],
    products: [
        // Core, UI-agnostic SDK.
        .library(name: "FeatBitClient", targets: ["FeatBitClient"]),
        // SwiftUI conveniences (ObservableObject wrapper, ScenePhase wiring).
        .library(name: "FeatBitSwiftUI", targets: ["FeatBitSwiftUI"]),
        // Opt-in app-lifecycle + connectivity glue (UIKit + Network).
        .library(name: "FeatBitLifecycle", targets: ["FeatBitLifecycle"]),
    ],
    targets: [
        .target(name: "FeatBitClient"),
        .target(name: "FeatBitSwiftUI", dependencies: ["FeatBitClient"]),
        .target(name: "FeatBitLifecycle", dependencies: ["FeatBitClient"]),
        .testTarget(
            name: "FeatBitClientTests",
            dependencies: ["FeatBitClient"],
            resources: [.copy("Resources/e2e")]
        ),
    ]
)
