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

## For an AI agent (Claude Code) picking this up

1. Read [`CLAUDE.md`](./CLAUDE.md) (guardrails + run/verify loop) and this file.
2. Orient with `swift build` then `swift test` — expect `0 failures` (3 E2E tests skip without
   `FEATBIT_E2E`). That confirms your toolchain matches the Linux baseline.
3. Work the **macOS-only TODO checklist** below top-to-bottom; each item lists its acceptance
   criterion. Mark a task done only when its stated command is green and you can quote it.
4. **Don't fabricate runtime verification.** Live streaming/polling needs a real FeatBit env secret
   + evaluation URL, and E2E needs Docker. If you lack those, complete the compile/test items, and
   clearly report which runtime items remain unverified rather than guessing.
5. Stay within the guardrails in `CLAUDE.md` — wire compatibility, platform `#if` guards, Apache-2.0,
   and **do not make the repo public**.

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

Each item names its **acceptance criterion** (AC). Mark done only when the AC is met.

- [ ] **Compile + test on macOS.** `swift build` then `swift test`.
      *AC:* both succeed with `0 failures`; the SwiftUI/UIKit/streaming/Combine targets compile (they
      only build under `#if canImport(Darwin/…)`). *(Already green on CI `macos-14`.)*
- [ ] **Streaming runtime:** exercise `StreamingDataSynchronizer` on a simulator/device against a
      real FeatBit env (needs an env secret + eval URL).
      *AC:* `client.start()` returns `true` in streaming mode; toggling a flag server-side pushes a
      change within seconds; the 20s heartbeat and backoff-reconnect behave (watch logs).
- [ ] **Lifecycle:** with `FBLifecycleConnector` started, background the app and foreground it.
      *AC:* socket drops after `backgroundGracePeriod` on background and reconnects+resyncs on
      foreground; `NWPathMonitor` toggling flips `setNetworkAvailable`.
- [ ] **SwiftUI:** a view reading `featBit.bool(...)` re-renders when the flag changes.
      *AC:* live UI update without manual refresh; `.featBitScenePhase(_:)` drives foreground.
- [ ] **Example app:** create `FeatBitExampleApp.xcodeproj` (see `Examples/FeatBitExampleApp/README.md`).
      *AC:* `xcodebuild -project … -scheme FeatBitExampleApp -destination 'generic/platform=iOS' build`
      succeeds; running it on a simulator shows the flag value updating live. Then the CI `macos` job's
      example-app step (currently skipped when the project is absent) actually builds it.
- [ ] **E2E:** `FEATBIT_E2E=1 swift test --filter E2E` with Docker.
      *AC:* polling + streaming E2E pass. Then flip the `e2e` CI job from `continue-on-error: true` to
      blocking (`.github/workflows/ci.yml`). Note: GitHub `macos-*` runners lack Docker — if you want
      streaming E2E in CI, provision Docker on macOS via `colima`, else keep streaming E2E as a
      local/manual check and let CI run polling E2E on `ubuntu-latest`.
- [ ] **Tag a version.** Once green on macOS, tag `0.1.0` so SPM `from:` resolves.
      *AC:* `git tag 0.1.0 && git push --tags` and a consumer can `.package(url:…, from: "0.1.0")`.

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

The SDK must stay byte-compatible with the FeatBit server **and** the Android SDK. The sources of
truth are the contract below, the SDK source itself (`Sources/FeatBitClient/Internal/` and
`DataSynchronizer/`), and the [Android repo](https://github.com/Fluent-Health/featbit-android-sdk)
(compare behavior there when unsure). Key points:

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
