# FeatBit Client-Side SDK for Swift (iOS)

## Introduction

This is a Swift/iOS client-side SDK for the 100% open-source feature flags management platform
[FeatBit](https://github.com/featbit/featbit), built because FeatBit does not currently ship a
native Swift SDK. Its architecture and API are based on the official
[.NET Client-Side SDK](https://github.com/featbit/featbit-dotnet-client-sdk); real-time streaming
sync is modeled on FeatBit's JS/React-Native SDK and `/streaming` wire protocol. It is a sibling
port of the [FeatBit Kotlin/Android SDK](https://github.com/Fluent-Health/featbit-android-sdk) and
speaks the same wire protocol.

Be aware, this is a **client-side** SDK intended for use in a single-user context — mobile,
desktop, or embedded applications. It is **not** intended for multi-user systems such as web
servers. For server-side use, see FeatBit's server SDKs.

## Getting Started

### Installation

Add the package with Swift Package Manager. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Fluent-Health/featbit-ios-sdk.git", from: "0.1.0"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "FeatBitClient", package: "featbit-ios-sdk"),
        // optional SwiftUI helpers:
        .product(name: "FeatBitSwiftUI", package: "featbit-ios-sdk"),
        // optional lifecycle/network auto-wiring:
        .product(name: "FeatBitLifecycle", package: "featbit-ios-sdk"),
    ]),
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and enter the repository URL.

The package supports **iOS 14+** (and macOS 11+, tvOS 14+, watchOS 7+).

### Prerequisite

Before using the SDK, obtain your environment secret and SDK URLs:

- [How to get the environment secret](https://docs.featbit.co/sdk/faq#how-to-get-the-environment-secret)
- [How to get the SDK URLs](https://docs.featbit.co/sdk/faq#how-to-get-the-sdk-urls)

> The polling URL is the streaming URL with the protocol swapped:
> `ws(s)://<host>` → `http(s)://<host>`. Both resolve to the same evaluation server.

### Quick Start

```swift
import FeatBitClient

// setup SDK options
let options = FBOptions.Builder("<replace-with-your-env-secret>")
    .polling("https://app-eval.featbit.co", interval: 5 * 60)
    .event("https://app-eval.featbit.co")
    .build()

// use an anonymous user as the initial user
let anonymous = FBUser.builder("anonymous")
    .name("anonymous")
    .custom("role", "visitor")
    .build()

let client = DefaultFBClient(options: options, user: anonymous)

// start and wait up to 3 seconds for the client to be ready
let success = await client.start(timeout: 3)
if !success {
    print("FBClient failed to initialize. Variation calls will use fallback values.")
}

// after the user logs in, switch users and fetch their flags
let bob = FBUser.builder("a-unique-key-of-bob")
    .name("bob")
    .custom("country", "FR")
    .build()
await client.identify(bob)

// evaluate a boolean flag
let enabled = client.boolVariation("game-runner", default: false)

// evaluate with reason
let detail = client.boolVariationDetail("game-runner", default: false)
print("flag 'game-runner' = \(detail.value) (reason: \(detail.reason))")

// subscribe to flag changes
let token = client.flagTracker.subscribe(key: "game-runner") { e in
    print("'\(e.key)' changed from '\(e.oldValue ?? "nil")' to '\(e.newValue)'")
}

// ...or consume them as an AsyncStream
// for await e in client.flagTracker.changes { /* ... */ }

client.close()
```

A runnable SwiftUI example lives in [`Examples/FeatBitExampleApp/`](./Examples/FeatBitExampleApp).

## SDK

### Async model

This SDK aligns with the FeatBit JS/React-Native SDK model (a promise-like `waitUntilReady()` plus
an update event stream), expressed idiomatically in Swift:

- `start(...)` and `identify(...)` are **async** functions.
- Flag evaluations (`boolVariation`, etc.) are **synchronous** reads from the in-memory store, so
  they can be called directly from a SwiftUI `body`.
- Flag changes are delivered via the `FlagTracker` listener API, an `AsyncStream`, **and** — on
  Apple platforms — a Combine `flagChanges` publisher.

### Data synchronization

The SDK supports two modes:

- **Polling** (default) — fetches flags over HTTP at an interval (ported from the .NET client SDK):
  ```swift
  FBOptions.Builder(secret).polling("https://app-eval.featbit.co", interval: 5 * 60)
  ```
- **Streaming** — keeps a WebSocket open and receives flag changes in real time (modeled on the
  JS/RN SDK and FeatBit's `/streaming` protocol):
  ```swift
  FBOptions.Builder(secret).streaming("wss://app-eval.featbit.co")
  ```

Both feed the same in-memory store, so evaluation, `FlagTracker`, `changes`, and `flagChanges`
behave identically regardless of mode. The synchronizer retries with exponential backoff and an
application-level heartbeat.

### Lifecycle-aware streaming (iOS)

WebSockets don't survive iOS backgrounding/suspension, and reconnecting blindly wastes battery. The
SDK exposes neutral hooks so a streaming connection is dropped when the app backgrounds or goes
offline and re-established (with an immediate resync) on foreground / reconnect:

```swift
client.setForeground(true /* or false */)
client.setNetworkAvailable(true /* or false */)
```

Transitions to inactive are debounced by `FBOptions.Builder.backgroundGracePeriod(...)`
(default 20s) so brief app-switches/blips don't churn. Defaults are foreground + online, so a
client whose hooks are never called streams as before.

The optional **`FeatBitLifecycle`** product wires these hooks to `UIApplication` lifecycle
notifications + `NWPathMonitor` automatically — the core gains no UIKit/Network dependency:

```swift
import FeatBitLifecycle

// e.g. in your App init or AppDelegate, on the main thread
let connector = FBLifecycleConnector(client: fbClient)
connector.start()
```

SwiftUI-first apps can instead drive the foreground hook from `scenePhase` via the
`FeatBitSwiftUI` modifier `.featBitScenePhase(client)`.

### FBClient

`FBClient` is the heart of the SDK. Create a **single instance** for the lifetime of your app
(e.g. inject it through your environment / DI).

### FBUser

`FBUser` describes the user that flags are evaluated for. The only mandatory attribute is `key`. Add
any number of custom string attributes with `custom(_:_:)`:

```swift
let bob = FBUser.builder("a-unique-key-of-bob")
    .name("bob")
    .custom("age", "15")
    .custom("country", "FR")
    .build()
```

### Evaluating flags

For each type there is a `*Variation` method returning the value and a `*VariationDetail` returning
an `EvalDetail` (`value` + `reason`):

- `boolVariation` / `boolVariationDetail`
- `stringVariation` / `stringVariationDetail`
- `intVariation` / `intVariationDetail`
- `floatVariation` / `floatVariationDetail`
- `doubleVariation` / `doubleVariationDetail`

> For JSON flags, use `stringVariation` to obtain the JSON string (a typed `jsonVariation` is on the
> roadmap).

### Tracking flag changes

```swift
// all flags
let token = client.flagTracker.subscribe { e in /* ... */ }
// a specific flag
let keyed = client.flagTracker.subscribe(key: "game-runner") { e in /* ... */ }
// cancel the returned token (or let it deinit) to unsubscribe
```

### Offline mode & bootstrapping

```swift
let options = FBOptions.Builder()
    .offline(true)
    .bootstrap(savedFlags) // [FeatureFlag]
    .build()
```

In offline mode no network calls are made; evaluations use bootstrap data (or fallback values). Use
`client.allFlags()` to snapshot the current flags for later bootstrap.

### Logging

Provide an `FBLogger` via `FBOptions.Builder.logger(...)` to route SDK logs into your app. The
default `DefaultLogger` writes to the unified logging system (`os.Logger`) on Apple platforms,
falling back to stdout/stderr elsewhere.

### SwiftUI

The `FeatBitSwiftUI` product offers a `FeatBit` `ObservableObject` that republishes flag changes so
views re-render automatically:

```swift
import SwiftUI
import FeatBitSwiftUI

struct ContentView: View {
    @StateObject var featBit: FeatBit

    var body: some View {
        if featBit.bool("new-checkout") { NewCheckout() } else { OldCheckout() }
    }
}
```

## Building

```bash
swift build
swift test           # unit tests (no network/Docker required)
```

The `FeatBitClient` core builds on Linux and macOS. The `FeatBitSwiftUI`/`FeatBitLifecycle` products
and the real-time WebSocket streaming runtime are Apple-only (guarded with `#if canImport(...)`), so
build them with macOS + Xcode.

## End-to-end tests

A full-stack E2E (`Tests/FeatBitClientTests/E2E/`) drives a real `FBClient` against a **real FeatBit
stack** (Postgres + api-server + evaluation-server) started via the Docker CLI. It seeds a flag via
FeatBit's management API, then asserts the SDK evaluates it, observes a server-side toggle (polling
and streaming), and that streaming pauses on background and resyncs on foreground.

It is **gated by `FEATBIT_E2E=1`** so the default test run never requires Docker:

```bash
FEATBIT_E2E=1 swift test --filter E2E
```

Requirements: a reachable Docker daemon. FeatBit's Postgres schema is vendored under
`Tests/FeatBitClientTests/Resources/e2e/initdb/` (Apache-2.0, from `featbit/featbit`).

## Supported versions

- iOS 14+, macOS 11+, tvOS 14+, watchOS 7+.
- Swift 5.9+ toolchain.

## Backstage

This repository is [Backstage](https://backstage.io)-compatible: `catalog-info.yaml` registers it
as a Component, and this documentation is published via **TechDocs** (`mkdocs.yml` + `docs/`).

> `catalog-info.yaml` encodes organization-specific Backstage conventions — the `owner`, custom
> annotations, and the assumption that the descriptor is registered in an org root catalog. **Adapt
> or remove these to match your own Backstage instance** (or drop `catalog-info.yaml`/`mkdocs.yml`
> entirely if you don't use Backstage) — just as you supply your own FeatBit environment secret and
> evaluation-server URLs.

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md). To report a security issue,
see [SECURITY.md](./SECURITY.md).

## License

Apache-2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE). FeatBit and the FeatBit SDKs are works
of the FeatBit project; this is an independent derivative port of their .NET and React Native client
SDKs and is not affiliated with or endorsed by FeatBit.

Maintained by [Fluent Health](https://github.com/Fluent-Health).
