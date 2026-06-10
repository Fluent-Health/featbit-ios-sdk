# Usage

## Installation

Swift Package Manager. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Fluent-Health/featbit-ios-sdk.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "FeatBitClient", package: "featbit-ios-sdk"),
        .product(name: "FeatBitSwiftUI", package: "featbit-ios-sdk"),   // optional
        .product(name: "FeatBitLifecycle", package: "featbit-ios-sdk"), // optional
    ]),
]
```

Or in Xcode: **File ▸ Add Package Dependencies…**. Supports iOS 14+, macOS 11+, tvOS 14+, watchOS 7+.

## Quick start

```swift
import FeatBitClient

let options = FBOptions.Builder("<env-secret>")
    .polling("https://app-eval.featbit.co", interval: 5 * 60)
    .event("https://app-eval.featbit.co")
    .build()

let user = FBUser.builder("anonymous").name("anonymous").custom("role", "visitor").build()
let client = DefaultFBClient(options: options, user: user)

let ready = await client.start(timeout: 3)

// switch users after login
await client.identify(FBUser.builder("bob-key").name("bob").custom("country", "FR").build())

// evaluate
let enabled = client.boolVariation("game-runner", default: false)
let detail = client.boolVariationDetail("game-runner", default: false) // .value, .reason

client.close()
```

## Evaluating flags

For each type there is a `*Variation` (value) and a `*VariationDetail` (`value` + `reason`):
`bool`, `string`, `int`, `float`, `double`. For JSON flags, use `stringVariation` to obtain the JSON
string.

## Tracking flag changes

```swift
// listener API — keep the returned token to stay subscribed
let token = client.flagTracker.subscribe(key: "game-runner") { e in
    print(e.key, e.oldValue ?? "nil", e.newValue)
}

// or as an AsyncStream
for await e in client.flagTracker.changes { /* ... */ }

// or, on Apple platforms, as a Combine publisher
// client.flagTracker.flagChanges.sink { e in /* ... */ }
```

## Identifying users

The client always has a single current user. Set it at construction and change it with
`identify(...)` (e.g. on login). All evaluations refer to the current user.

## Offline mode & bootstrapping

```swift
let options = FBOptions.Builder()
    .offline(true)
    .bootstrap(savedFlags) // [FeatureFlag]
    .build()
```

Use `client.allFlags()` to snapshot flags for later bootstrap.

## SwiftUI

```swift
import SwiftUI
import FeatBitSwiftUI

struct ContentView: View {
    @StateObject var featBit: FeatBit

    var body: some View {
        VStack {
            if featBit.bool("new-checkout") { NewCheckout() } else { OldCheckout() }
        }
    }
}
```

`FeatBit` republishes flag changes via `objectWillChange`, so views re-render automatically.

## Logging

Provide an `FBLogger` via `FBOptions.Builder.logger(...)`; the default writes to `os.Logger` on Apple
platforms (stdout/stderr elsewhere).
