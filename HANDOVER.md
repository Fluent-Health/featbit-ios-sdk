# Handover — FeatBit Swift/iOS SDK

This SDK was scaffolded and implemented on **Linux**, where the pure-Foundation core builds and is
fully unit-tested, but Apple-only frameworks (SwiftUI, UIKit, Network, Combine, the WebSocket
runtime) **cannot be compiled**. This document hands the remaining macOS/Xcode work to an iOS
developer. The architecture, public API, and wire protocol are a deliberate port of the
[FeatBit Kotlin/Android SDK](https://github.com/Fluent-Health/featbit-android-sdk) — keep them in
sync.

## TL;DR

- **Done & verified on Linux:** the entire `FeatBitClient` core + 38 unit tests (incl. wire-format
  vectors) pass with `swift test`.
- **Authored, needs macOS verification:** `FeatBitSwiftUI`, `FeatBitLifecycle`, the
  `StreamingDataSynchronizer` WebSocket runtime, the Combine publisher, the E2E tests, and the
  example app's Xcode project.
- **Your job:** open the package on a Mac, run `swift test`, build the example app, run the E2E
  suite against Docker, and resolve any platform-specific gaps (expected to be small).

## Status matrix

| Component | Status |
|---|---|
| `Package.swift` (3 products) | ✅ Done |
| Models, `Codable`, `FBUser`/`EndUser`/`Insight` | ✅ Done & unit-tested (Linux) |
| `ConnectionToken` | ✅ Done & unit-tested against hard-coded wire vectors |
| `FBOptions` + builder, `DataSyncMode` | ✅ Done |
| `FBLogger` / `DefaultLogger` (OSLog) | ✅ Done (OSLog path compiles; verify formatting on device) |
| Store, evaluator, value converters | ✅ Done & unit-tested |
| `FlagTracker` (listeners + `AsyncStream`) | ✅ Done & unit-tested |
| `FlagTracker` Combine `flagChanges` | ⚠️ Authored, `#if canImport(Combine)` — **verify on macOS** |
| `GetUserFlags` / `TrackInsight` (polling + insights) | ✅ Done & unit-tested (URLProtocol stubs) |
| `PollingDataSynchronizer` | ✅ Done & unit-tested |
| `LifecycleController` + hooks | ✅ Done & unit-tested |
| `StreamingDataSynchronizer` (WebSocket) | ⚠️ Authored, compiles on Linux but **runtime unverified** — `URLSessionWebSocketTask` is unreliable on Linux Foundation. **Verify on macOS.** |
| `FeatBitSwiftUI` (`FeatBit` ObservableObject, `scenePhase`) | ⚠️ Authored, guarded — **compile/run on macOS** |
| `FeatBitLifecycle` (`FBLifecycleConnector`) | ⚠️ Authored, guarded — **compile/run on macOS** |
| Unit tests | ✅ 38 passing on Linux |
| E2E (`FeatBitStack` + polling/streaming tests) | ⚠️ Authored & compiles; **never executed** — needs Docker + macOS for streaming |
| Example app sources | ✅ Written; ⚠️ **`.xcodeproj` must be created** (see `Examples/FeatBitExampleApp/README.md`) |
| Docs / Backstage / OSS scaffolding | ✅ Done |

## Environment setup (Mac)

- Xcode 15.4+ (Swift 5.9+). The package also builds with a standalone Swift toolchain.
- Open the package: `open Package.swift` (or **File ▸ Open** the repo folder in Xcode).
- Docker Desktop (for the E2E suite).

## Commands

```bash
swift build                                   # build all targets
swift test                                    # full unit suite (on macOS this also compiles
                                              #   SwiftUI/UIKit/Combine/streaming targets)
swift test --filter FlagTrackerTests          # a subset
FEATBIT_E2E=1 swift test --filter E2E         # full-stack E2E (needs Docker)

# Example app (after you create the .xcodeproj — see Examples/FeatBitExampleApp/README.md)
xcodebuild -project Examples/FeatBitExampleApp/FeatBitExampleApp.xcodeproj \
  -scheme FeatBitExampleApp -destination 'generic/platform=iOS' build
```

## macOS-only TODO checklist

- [ ] `swift build` + `swift test` on macOS — confirm the `#if canImport` Apple paths compile
      (`FeatBitSwiftUI`, `FeatBitLifecycle`, the Combine `flagChanges`).
- [ ] **Streaming runtime:** exercise `StreamingDataSynchronizer` on a device/simulator against a
      real FeatBit env. Confirm connect → `data-sync` → flag updates, the 20s heartbeat, and
      exponential-backoff reconnect.
- [ ] **Lifecycle:** confirm `FBLifecycleConnector` drops the socket on background and resyncs on
      foreground; confirm `NWPathMonitor` toggles `setNetworkAvailable`.
- [ ] **SwiftUI:** confirm `FeatBit` re-renders views on flag change; confirm
      `.featBitScenePhase(_:)`.
- [ ] **Example app:** create `FeatBitExampleApp.xcodeproj` (see its README), run on a simulator,
      toggle a flag in FeatBit and watch it update live.
- [ ] **E2E:** run `FEATBIT_E2E=1 swift test --filter E2E` with Docker. Decide CI placement (see
      Risks); GitHub `macos-*` runners lack Docker, so streaming E2E may need `colima` on macOS or
      stays a local/manual check while CI keeps unit-level streaming coverage.
- [ ] Once green on macOS, tag an initial version (e.g. `0.1.0`) so SPM `from:` resolves.

## Known risks / spikes

- **`URLSessionWebSocketTask` on Linux:** incomplete in Linux Foundation, so the streaming runtime
  and streaming E2E are unverified here. They are written to the documented FeatBit `/streaming`
  protocol; verify behavior on Apple platforms first.
- **E2E in CI:** `FeatBitStack` shells out to the Docker CLI (the strategy mirrors the Android
  Testcontainers stack). It pulls `postgres:15.10`, `featbit/featbit-api-server:latest`, and
  `featbit/featbit-evaluation-server:latest` and seeds via the management API. It has **not been run
  end-to-end yet** — budget time to debug container/seed timing on first run. The `.github/workflows/ci.yml`
  `e2e` job runs it on `ubuntu-latest` (Docker present); confirm `URLSessionWebSocketTask` works on
  the CI Linux toolchain or move streaming E2E to macOS.
- **Change-observation API:** the portable surface is closure listeners + `AsyncStream`; Combine is
  an Apple-only addition. If you standardize on Combine internally, keep the `#if canImport` guards.

## Wire-protocol contract (do not break)

The SDK must stay byte-compatible with the FeatBit server **and** the Android SDK. The source of
truth is the "Wire protocol" section of the implementation plan and the Android repo. Key points:

- **Connection token** (`ConnectionToken.swift`): the digit→char obfuscation + header/splice scheme.
  `ConnectionTokenTests` pins exact outputs — if those change, you've broken compatibility.
- **Streaming** (`StreamingDataSynchronizer.swift`): `/streaming?type=client&version=2&token=…`;
  send `{"messageType":"data-sync","data":{"user":…,"timestamp":…}}`; 20s `{"messageType":"ping",…}`
  heartbeat; inbound `data-sync` envelope → `{eventType,userKeyId,featureFlags:[…]}`.
- **Polling** (`GetUserFlags.swift`): `POST …/api/public/sdk/client/latest-all?timestamp=…`,
  `Authorization: <secret>`, 401 = fatal.
- **Insights** (`TrackInsight.swift`): `POST …/api/public/insight/track`, single-element array.
- **Wire shapes:** `EndUser {keyId,name,customizedProperties:[{name,value}]}`,
  `FeatureFlag {id,variation,variationType,variationId,sendToExperiment,matchReason}` (camelCase).

## Follow-ups (org / publication)

- **Backstage discovery:** register this descriptor as a `Location` target in the org-root
  `catalog-info.yaml` (backstage repo) so it's picked up — mirror how `featbit-android-sdk` was
  registered.
- **OSS publication (pending CTO approval — see the OSS Publication Request issue):** once approved,
  a maintainer flips the repo to public, enables secret scanning + Dependabot security updates + a
  `main` ruleset, and updates `fluentinhealth.com/oss` in `catalog-info.yaml` from `pending` to
  `published`.
