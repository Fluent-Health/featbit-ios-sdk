# FeatBit iOS SDK — Architecture

## Layered layout

The `FeatBitClient` SPM target is organized as concentric layers. Higher layers
depend on lower layers; the reverse arrow is a violation.

```
Sources/FeatBitClient/
├── Domain/          # Pure Swift types (no URLSession, no Codable-on-body-parse).
│   ├── EvalResult.swift            — sealed enum result of a flag lookup
│   ├── Evaluator.swift             — resolves a flag from a MemoryStore
│   ├── ValueConverters.swift       — string → Bool/Int/Float/Double/String
│   └── MemoryStore.swift           — protocol port consumed by Evaluator
├── App/             # Application services (implement domain contracts).
│   ├── DefaultMemoryStore.swift    — NSLock-guarded dictionary adapter
│   ├── FlagTrackerImpl.swift       — listener/AsyncStream/Combine fan-out
│   └── LifecycleController.swift   — foreground + network → active/paused
├── Data/            # Outbound adapters (network + analytics).
│   ├── HTTP/
│   │   ├── ConnectionToken.swift   — secret → WebSocket token
│   │   ├── FBEndpoints.swift       — eagerly-parsed URLs
│   │   ├── FbApiClient.swift       — shared URLSession POST helper
│   │   ├── GetUserFlags.swift      — /latest-all poll + strict decode
│   │   └── HttpConstants.swift     — path/header constants
│   ├── Sync/
│   │   ├── DataSynchronizer.swift  — protocol
│   │   ├── NullDataSynchronizer.swift
│   │   ├── PollingDataSynchronizer.swift
│   │   └── StreamingDataSynchronizer.swift
│   └── Insights/
│       ├── InsightDispatcher.swift — bounded batching pipeline
│       └── TrackInsight.swift      — protocol + HTTP + Noop
├── Wire/            # Codable DTOs (Kotlin `@Serializable` analogue).
│   ├── EndUser.swift
│   └── Insight.swift
├── Model/           # Public user-facing value types.
│   ├── FBUser.swift
│   └── FeatureFlag.swift
├── Evaluation/      # Public typed evaluation surface.
│   └── EvalDetail.swift            — public API (kept out of Domain/)
├── ChangeTracker/   # Public change-observation surface.
│   ├── FlagChangeListener.swift
│   ├── FlagSubscription.swift
│   ├── FlagTracker.swift
│   └── FlagValueChangedEvent.swift
├── Options/
│   ├── DataSyncMode.swift
│   ├── FBOptions.swift
│   └── FBOptionsError.swift
├── Store/
│   └── FlagValueChangedEvent.swift — public API via FlagChangeListener
├── Internal/        # Cross-layer helpers.
│   ├── Lock.swift
│   ├── StartGate.swift
│   └── Timeout.swift               — withTimeout primitive
├── FBClient.swift                  — public protocol
├── DefaultFBClient.swift           — public impl; wires all layers
└── FBLogger.swift
```

## Dependency rule

`Data → App → Domain → Wire`

- Nothing in `Domain/` imports `Data/`, `App/`, or `Wire/`.
- `App/` may import `Domain/` and `Wire/`.
- `Data/` may import anything below it.
- `Wire/` is a leaf (Codable structs only).

Public API packages (`Model/`, `Evaluation/`, `ChangeTracker/`, `Options/`, root
`FBClient` + `DefaultFBClient`, `FBLogger`) are outside the layer hierarchy and
carry the byte-compat guarantee for consumers.

## Documented carve-outs

Three intentional rule relaxations, each accepted after weighing the
alternatives:

1. **`Model/FeatureFlag` carries `Codable`.** A pure domain would define
   `Domain.FeatureFlag` and a `Wire.FeatureFlagDTO` mirror plus a mapper. YAGNI:
   the wire shape and the domain shape are identical, so a mirror only adds
   allocation on every poll response. Accepted: the domain "knows" the wire
   format at the type level. If the wire ever diverges (e.g. server adds a
   field the SDK must not surface), split at that point.

2. **`App.LifecycleController` depends on `Data.Sync.DataSynchronizer`.**
   Lifecycle is an app service that drives a data-layer port. Strict
   ports/adapters would require a `Domain.SynchronizerControl` port with
   `pause()`/`resume()` and the data synchronizer would implement it. The
   `DataSynchronizer` protocol already sits in `Data/Sync/` (not `Domain/`) so
   `LifecycleController` reads a data-layer protocol from an app layer. This
   is a one-directional read of a stable protocol, not a leak of concrete
   types; accepted.

3. **`Domain.MemoryStore` stays a public protocol.** No consumer-facing
   injection point exists today, but the port/adapter boundary requires the
   port to be public for the adapter (`App.DefaultMemoryStore`) to conform.
   Accepted; the alternative (making the port internal) collapses the
   boundary and forces the adapter into the same file, defeating the split.

## Kotlin → Swift translation table (from the design spec)

| Kotlin | Swift | Notes |
|---|---|---|
| `sealed class EvalResult` | `enum EvalResult { case found(FeatureFlag); case notFound(reason: String) }` | Direct. |
| `Channel(256, DROP_OLDEST) + consumer coroutine` | `AsyncStream(bufferingPolicy: .bufferingNewest(256))` + consumer `Task` | Direct. |
| `CopyOnWriteArrayList` | `NSLock`-guarded `[T]` w/ snapshot-copy under lock | Preserves existing DefaultMemoryStore pattern. |
| `ReentrantReadWriteLock` | Existing `Lock` wrapper on `NSLock` | Read path is lock-free at call site; contention target is writes. |
| `kotlinx.serialization` | `Codable` + `JSONDecoder/Encoder` | Cached where possible (`FbApiClient.encoder/decoder` static). |
| `withTimeoutOrNull(2000L)` | Module-scope `withTimeout<T: Sendable>(seconds:_:) async -> T?` | `Internal/Timeout.swift`. |
| `cancelAndJoin()` | `task.cancel(); _ = await task.value` | Note: `Task<Void, Never>.value` does NOT honor cancellation propagation from outer `withTimeout` — see `DefaultFBClient.closeAndJoin` docstring for the caller-latency-vs-work-completion distinction. |
| `SharedFlow(replay=0, extraBufferCapacity=64)` | `AsyncStream` in `FlagTrackerImpl.changes` | Direct semantic. |
| `MockWebServer` | `MockURLProtocol` (existing) + FIFO stub-queue extension | Under `Tests/FeatBitClientTests/Support/`. |
| `MockWebServer.withWebSocketUpgrade` | `LoopbackWebSocketServer` via `NWListener` | Under `Tests/FeatBitClientTests/Support/`. |

## Verification gates (per commit + pre-push)

1. `swift build` — all 3 SPM products (`FeatBitClient`, `FeatBitLifecycle`, `FeatBitSwiftUI`).
2. `swift test` — all unit tests green.
3. E2E via `FEATBIT_E2E=1 swift test --filter FeatBitE2E` against Colima Docker
   (best-effort; not blocking in-session).
4. `superpowers:code-reviewer` adversarial audit on the working-tree diff.
5. User approval + commit.

## Known follow-ups (deferred outside this PR)

- **Session injection seam on `DefaultFBClient`.** Enables the 3 network-dependent
  test-pinning cases (identify swap over polling, start-timeout under hung
  server, closeAndJoin bounded under blocked sync) noted in `FBClientEvaluationTests`.
  `URLProtocol.registerClass` does not affect the ephemeral session the SDK
  constructs internally, so tests using that path hang on real DNS.
- **`closeAndJoin` caller-latency vs work-completion gap.** Documented on
  `DefaultFBClient.closeAndJoin`. Fix requires `Task.checkCancellation()` /
  `withTaskCancellationHandler` inside `PollingDataSynchronizer.closeAndJoin`.
- **`InsightDispatcher` batch-drain race.** The `withTaskGroup(next() vs sleep)`
  pattern can drop items mid-race; acceptable under the bounded-buffer contract
  but worth a `pending`-slot recovery pass in a future perf task.
