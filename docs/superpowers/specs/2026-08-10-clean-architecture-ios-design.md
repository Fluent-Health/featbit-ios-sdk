# iOS Clean-Architecture + Hardening + Perf Pass — Design Spec

**Date:** 2026-08-10
**Scope:** Sibling port of [Fluent-Health/featbit-android-sdk#10](https://github.com/Fluent-Health/featbit-android-sdk/pull/10)
**Target repo:** `Fluent-Health/featbit-ios-sdk`
**Target branch:** `refactor/clean-architecture`

## Goal

Bring the iOS SDK to the same hardened, layered, performance-tuned state as the Android SDK
after PR-10. Single branch, single PR, three-phase commit sequence:

1. **Phase 1 — Hardening.** Race-safe `identify`, bounded insight pipeline, eager URL/config
   validation, per-phase close timeouts, sealed `EvalResult`, strict `Codable` shape validation
   in `GetUserFlags`, and aggressive test pinning across the same 7 files Android pinned.
2. **Phase 2 — Clean architecture.** Layered folder split (`Domain/` + `App/` + `Data/HTTP/`
   + `Data/Sync/` + `Data/Insights/` + `Wire/`). Public API surface unchanged.
3. **Phase 3 — Perf pass.** Alloc-free `evaluateValue` fast path, insights-enabled
   short-circuit, cached `endUser`, single-pass `allFlags()` build, `MemoryStore.upsertAll(_:)`
   for lock-once-per-batch, typed `LatestAllEnvelope`, cached `JSONEncoder`, alloc-free bool
   conversion.

## Non-goals

- No new third-party dependencies. Test harness = URLProtocol + NWListener helper.
- No changes to public API FQNs / method signatures. `FBClient`, `FBOptions`, `FBUser`,
  `FeatureFlag`, `FlagTracker`, `EvalDetail` all stay where they are.
- No changes to the `FeatBitLifecycle` or `FeatBitSwiftUI` targets (glue crates unchanged).
- No SPM target reorganization — folder-only moves inside `Sources/FeatBitClient/`.
- No Combine bridge changes.

## Kotlin → Swift Translation Table

The biggest structural risk is naive 1:1 replay. Bindings we adopt:

| Kotlin construct | Swift equivalent | Notes |
|---|---|---|
| `sealed class EvalResult` w/ `Found(flag)` / `NotFound` | `enum EvalResult { case found(FeatureFlag), case notFound(reason: String) }` | Direct. |
| `Channel(256, DROP_OLDEST) + consumer coroutine` | `AsyncStream` w/ `.bufferingNewest(256)` + `Task { for await batch in stream }` | Direct. |
| `CopyOnWriteArrayList` | `NSLock`-guarded `[T]`, snapshot-copy under lock | Preserves existing pattern in `DefaultMemoryStore`. |
| `ReentrantReadWriteLock` | Existing `Lock` (`NSLock` wrapper) — no reader/writer split needed | Contention target is write path; reads are already lock-free at call site. |
| `kotlinx.serialization` `@Serializable` | `Codable` + `JSONDecoder/Encoder` | Cached static encoder/decoder. |
| `withTimeoutOrNull(2000L)` | Task-group race helper (already exists as `withTimeout` in `DefaultFBClient.swift`); extract into `Internal/Timeout.swift`. | Extract so multiple call sites can share. |
| `cancelAndJoin()` | `task.cancel(); await task.value` (Task inference) | Wrap in helper if used > once. |
| `SharedFlow(replay = 0, extraBufferCapacity = 64)` | `AsyncStream` w/ `.bufferingNewest(64)` | Direct semantic. |
| Android `MockWebServer` | Swift `URLProtocol` custom subclass for HTTP; `NWListener`-based loopback server for WebSocket. | New test helpers under `Tests/FeatBitClientTests/TestSupport/`. |
| `OkHttp WebSocket.withWebSocketUpgrade` | `NWListener` on `127.0.0.1:<ephemeral>` speaking WS handshake + text frames | Small; see Test Infrastructure below. |
| `-Xjvm-default=all-compatibility` | Swift protocol defaults are inline (no bridge needed) | N/A. Protocol default implementations are directly in the vtable. |

## Phase 1 — Hardening (production changes)

### 1.1 `InsightDispatcher`

New file: `Sources/FeatBitClient/Internal/InsightDispatcher.swift`.

Wraps a bounded, drop-oldest `AsyncStream<Insight>` continuation on the emit side, and a
detached `Task` on the consume side that batches up to 50 events or 1s (whichever comes
first) and hands the batch to the injected `TrackInsight.runBatch(_:)`.

- Emit path: **non-suspending**. `offer(_ insight:)` calls `continuation.yield(insight)` and
  returns immediately. On buffer overflow the oldest queued insight is dropped (mirror
  `DROP_OLDEST`).
- Buffer size: 256.
- Batch size: 50. Batch timeout: 1s.
- `closeAndDrain()` (async): stops accepting, flushes pending events within a 2s budget,
  then finishes the continuation.

`HttpTrackInsight` gains `func runBatch(_ insights: [Insight]) async` that POSTs the array
in one request. `run(_:)` becomes `runBatch([insight])` for callers that still emit one at
a time (identify insight, tests). `DefaultFBClient` gets an `InsightDispatcher` field and
routes evaluation insights through `dispatcher.offer(_:)` instead of a fresh `Task`.

### 1.2 `DataSynchronizer.closeAndJoin()` (suspending close)

- Add `func closeAndJoin() async` to the `DataSynchronizer` protocol (default impl = `close()`).
- Override on `PollingDataSynchronizer` and `StreamingDataSynchronizer` to await the loop
  Task (`task.cancel(); await task.value`) before returning.
- `DefaultFBClient.identify(_:timeout:)` awaits `old.closeAndJoin()` **before** starting
  `fresh.start()` — so a late poll response from the previous user cannot land in the store
  under the new user. Direct port of Android hardening #2.

### 1.3 `FBEndpoints` — eager URL validation

New file: `Sources/FeatBitClient/Internal/FBEndpoints.swift`.

Single struct holding pre-parsed `URL`s for `polling`, `event`, and `streaming` (WS)
endpoints. Constructed once at `FBOptions.build()` time; malformed URIs surface as
`FBOptionsError.invalidURL(String)` from `build()` — not from the first network call.

`FBOptions.Builder.build()` becomes `throws`. Existing callers get a compile break;
`Examples/` app + Tests updated.

### 1.4 `EvalResult` — sealed enum

Replace the current `struct EvalResult { isValid, reason, value }` with:

```swift
enum EvalResult {
    case found(FeatureFlag)
    case notFound(reason: String)

    var reason: String { ... }
    var isValid: Bool { ... }
    var value: String { ... }
}
```

Wire-compatible `reason` strings preserved (`"flag not found"`, `flag.matchReason`).
`Evaluator.evaluate(_:)` returns `EvalResult` (drop the tuple `(EvalResult, FeatureFlag?)`
form; the flag is inside `.found`).

### 1.5 `FBOptions.build()` — eager preconditions

Validation additions inside `build() throws -> FBOptions`:

- `pollingInterval > 0` (throws `FBOptionsError.invalidPollingInterval`)
- `backgroundGracePeriod >= 0` (throws `FBOptionsError.invalidGracePeriod`)
- URLs parse via `URLComponents` w/ non-empty host (throws `FBOptionsError.invalidURL`)
- In non-offline mode: `secret` non-blank (throws `FBOptionsError.missingSecret`)

### 1.6 `DefaultFBClient.close()` — per-phase 2s + 2s timeouts

Split the current single-timeout close into two phases: (a) sync teardown budget = 2s,
(b) insight flush budget = 2s. A slow sync close cannot starve the insight flush.

`close()` becomes `close() async`; call sites (`DefaultFBClient.identify` recycles the old
synchronizer via `closeAndJoin`, external callers call `await client.close()`).
Public API break — bump to major (or provide sync façade). **Decision below in "Open decisions".**

### 1.7 `StreamingDataSynchronizer` — ownsSession + closed guard

- Add `ownsSession: Bool` flag (default true when session param is nil, false when injected).
- On `close()`: invalidate session iff `ownsSession` (mirror Android's `ownsClient`).
- Late messages after close: existing `closed` flag already guards `connect()` but not
  `handleMessage()`. Add `if closed { return }` guard at the top of `handleMessage(_:)`.

### 1.8 `GetUserFlags` — strict shape validation

Replace the current permissive `try?`-then-empty parser with:

```swift
private struct LatestAllEnvelope: Decodable {
    let data: LatestAllData      // NOT optional
}
private struct LatestAllData: Decodable {
    let featureFlags: [FeatureFlag] = []
}
```

Missing fields → decode error caught by `safePoll` and logged (not silent `[]`).
Explicit `{"data": null}` → decode error (mirror Android's `explicitNulls = false`
carve-out — but Swift `Decodable` throws on null-for-non-optional by default, so we get
this for free).

## Phase 1 — Test Pinning (7 files)

For each: mutation-verified assertions, documented mutation-that-would-fail-it in every
test's KDoc, adversarial audit loop until zero findings before commit.

Target test files (renamed to match production layout after Phase 2):

1. `StreamingDataSynchronizerTests.swift` — 3 tests via `NWListener` loopback WS server:
   - opens WS, sends `data-sync`, initializes store from server snapshot
   - `closeAndJoin` preserves store state + initialized flag
   - `pause` closes WS w/ reason=`"paused"`, `resume` reconnects w/ advanced timestamp
2. `PollingDataSynchronizerTests.swift` — BarrierStore + 3 tests:
   - `closeAndJoin` awaits in-flight upsert; loop terminates after
   - polling loop issues repeated requests across interval
   - transient 500 does not stop loop; next 200 initializes
3. `FlagTrackerImplTests.swift` — subscriber isolation + 5 tests:
   - AsyncStream buffer caps under hung-collector burst (mirrors SharedFlow test)
   - slow subscriber does not block subsequent subscribers
   - subscriber exception does not starve others (safe-notify wrap)
   - keyed subscribers on different keys are isolated
   - AsyncStream has no replay — late subscribers do not see prior events
4. `DefaultMemoryStoreTests.swift` — thread-safety + listener semantics + 4 tests:
   - 16 threads × 250 upserts race-free (final state consistent, no crash)
   - listener observes just-written value (write-happens-before-notify)
   - add/remove listeners during dispatch does not corrupt iteration
   - `addChangeListener` idempotent (existing test — but pin exact semantic under audit)
5. `LifecycleControllerTests.swift` — flap/race + 3 tests:
   - foreground flap within grace re-anchors pause to latest off
   - network-on-while-foreground-off does not resume
   - second inactive signal while pause pending does not double-schedule
6. `TrackInsightTests.swift` — batch + error + lifecycle + 6 tests:
   - multi-element batch posted as single JSON array (structural decode)
   - empty batch is no-op (no request issued)
   - network error swallowed, does not propagate
   - `NoopTrackInsight.run/close` are no-ops
   - `close` completes without throw + is idempotent
   - cancellation contract (documented behavior of the URLSession blocking path)
7. `FBClientEvaluationTests.swift` (a.k.a. FBClientImplTest) — identify + close + 7 tests:
   - identify swaps synchronizer, new user's payload reflected in evaluation
   - close is idempotent
   - close completes promptly when offline
   - close bounded when sync teardown blocks (< 2500ms)
   - close preserves store + bootstrap evaluations still work
   - offline identify returns true without network
   - start returns false when polling sync cannot initialize within timeout

## Phase 2 — Clean-architecture folder split

**Rule of thumb (dependency direction):** `Data → App → Domain → Wire`. Nothing in
`Domain/` imports `Data/` or `App/`.

Target folder layout (moves only, no rewrites):

```
Sources/FeatBitClient/
├── Domain/
│   ├── EvalResult.swift               (moved from Evaluation/)
│   ├── Evaluator.swift                (moved from Evaluation/)
│   ├── ValueConverters.swift          (moved from Evaluation/)
│   └── MemoryStore.swift              (moved from Store/, becomes port)
├── App/
│   ├── DefaultMemoryStore.swift       (moved from Store/, becomes adapter)
│   ├── FlagTrackerImpl.swift          (moved from ChangeTracker/)
│   └── LifecycleController.swift      (moved from root)
├── Data/
│   ├── HTTP/
│   │   ├── ConnectionToken.swift      (moved from Internal/)
│   │   ├── FBEndpoints.swift          (new, from Phase 1)
│   │   ├── FbApiClient.swift          (moved from Internal/)
│   │   ├── GetUserFlags.swift         (moved from Internal/)
│   │   └── HttpConstants.swift        (moved from Internal/)
│   ├── Sync/
│   │   ├── DataSynchronizer.swift     (moved from DataSynchronizer/)
│   │   ├── NullDataSynchronizer.swift (moved from DataSynchronizer/)
│   │   ├── PollingDataSynchronizer.swift
│   │   └── StreamingDataSynchronizer.swift
│   └── Insights/
│       ├── InsightDispatcher.swift    (new, from Phase 1)
│       └── TrackInsight.swift         (moved from Internal/)
├── Wire/
│   ├── EndUser.swift                  (moved from Model/)
│   └── Insight.swift                  (moved from Model/)
├── Options/
│   ├── DataSyncMode.swift             (unchanged)
│   └── FBOptions.swift                (unchanged public API)
├── ChangeTracker/
│   ├── FlagTracker.swift              (unchanged — public API)
│   └── FlagChangeListener.swift       (extracted if needed — public API)
├── Store/
│   └── FlagValueChangedEvent.swift    (unchanged — public API)
├── Model/
│   ├── FBUser.swift                   (unchanged — public API)
│   └── FeatureFlag.swift              (unchanged — public API; @Serializable carve-out)
├── FBClient.swift                     (unchanged — public API)
├── DefaultFBClient.swift              (unchanged public API; internal wiring updated)
├── FBLogger.swift                     (unchanged)
├── Internal/
│   ├── Lock.swift                     (unchanged)
│   ├── StartGate.swift                (unchanged)
│   └── Timeout.swift                  (new — extracted withTimeout helper)
```

**Two documented carve-outs** (in `docs/superpowers/architecture.md`, mirror Android):

1. `Model/FeatureFlag.swift` carries `Codable`. Domain "knows" the wire format. Accepted:
   moving it into `Wire/` would break public API FQNs; keeping domain-pure would require
   a `Wire.FeatureFlagDTO` mirror + mapping — YAGNI.
2. `MemoryStore` stays a public protocol even though no consumer-facing injection point
   exists today. Kept public for the domain-port boundary (mirror Android).

## Phase 3 — Perf pass

### 3.1 `evaluateValue` — alloc-free hot path

Add method `Evaluator.evaluateValue<T>(_ key: String, converter: ValueConverter<T>) -> T?`
that returns the typed value directly and does **not** allocate `EvalResult` /
`EvalDetail`. `boolVariation`/`intVariation`/... route through it. `*VariationDetail()`
callers still go through the old `evaluateCore` so per-call reason strings surface.

### 3.2 `insightsEnabled` short-circuit

In `DefaultFBClient.init`, compute `let insightsEnabled = !(trackInsight is NoopTrackInsight)`
and store as `let`. On the hot path, guard the insight dispatch with `if insightsEnabled`.
Skips allocation of the `Insight` + `EndUser` graph entirely in offline mode.

### 3.3 `FBUser.endUser` cache

Cache the wire-form `EndUser` on the `FBUser` value type. Because `FBUser` is a `struct`
(value type), a stored `let endUser: EndUser` computed at init-time is safe and cheap. One
alloc per identify, not per evaluation.

**Nit-safety:** wrap the cached `customizedProperties` list in a defensively immutable
form. Swift arrays are already value types — no `Collections.unmodifiableList` needed.
Nothing to do.

### 3.4 `allFlags()` — single-pass Dictionary

Existing impl already looks single-pass but constructs an intermediate array via
`store.getAll().map`. Replace with direct dict build inside store, or a `getAllAsMap()`
protocol method. Minor. Not load-bearing.

### 3.5 `MemoryStore.upsertAll(_:)` — batched write lock

- Protocol default: iterate and call `upsert` (backward compat for any custom impl).
- `DefaultMemoryStore` override: single lock acquire, compute all events under lock,
  notify listeners after lock release. Listener sees consistent post-batch snapshot.
- `PollingDataSynchronizer.safePoll()` and `StreamingDataSynchronizer.handleMessage(_:)`
  call `store.upsertAll(response.flags)` instead of the `for flag in ... { upsert(flag) }`
  loop. N monitor enters → 1.

### 3.6 `GetUserFlags` — typed single-pass decode

Replace inline `Envelope?` / `Payload?` structs with a **file-private** typed pair:

```swift
private struct LatestAllEnvelope: Decodable { let data: LatestAllData }
private struct LatestAllData: Decodable { let featureFlags: [FeatureFlag] = [] }
```

`decode(LatestAllEnvelope.self, from: bodyData)` in one pass — no `JSONSerialization` AST
walk, no double decode. Shape mismatch → throws (caught by `safePoll` per §1.8).

### 3.7 `HttpTrackInsight` — cached `JSONEncoder`

`FbApiClient.encoder` is already a static `let` — verify. If not, hoist. Mirror Android's
`ListSerializer` cache. (Swift's `JSONEncoder` is not thread-safe; use a per-thread /
lock-guarded instance, or accept per-call allocation. Recommend accepting per-call — the
alloc cost is one struct with no captured state. Confirm during implementation.)

### 3.8 `ValueConverters.bool` — alloc-free case-insensitive compare

Replace `value.trimmingCharacters(in:).lowercased() == "true"` with
`trimmed.compare("true", options: .caseInsensitive) == .orderedSame`. Same for "false".
No allocation for the lowercased copy.

## Test Infrastructure

**New test helpers under `Tests/FeatBitClientTests/TestSupport/`:**

1. `MockURLProtocol.swift` — custom `URLProtocol` subclass. Enqueue `(status, headers, body)`
   responses. Records requests. Replaces `MockWebServer` for HTTP.
2. `LoopbackWebSocketServer.swift` — `NWListener` on `127.0.0.1:<ephemeral>`. Speaks WS
   upgrade handshake + text frames. Enqueue outbound messages, record inbound. Small
   (~150-200 LOC). Replaces `MockWebServer.withWebSocketUpgrade` for streaming tests.
3. `BarrierStore.swift` — `MemoryStore` decorator with `CompletableDeferred`-style
   barrier for testing the closeAndJoin race pin.

## Verification Gates (in order, commit is LAST)

Per commit and pre-push:

1. `swift build` green — all 3 SPM products (`FeatBitClient`, `FeatBitLifecycle`, `FeatBitSwiftUI`).
2. `swift test` green — all unit tests.
3. E2E via `FEATBIT_E2E=1 swift test --filter FeatBitE2E` against Colima Docker (best-effort;
   PR gets marked draft if E2E harness cannot be spun up in-session).
4. Manual simulator smoke — **explicitly deferred** to the PR reviewer. PR opens as **draft**
   with a "NOT YET TESTED on simulator/device" checkbox, mirroring the Android PR.
5. `superpowers:code-reviewer` adversarial audit on the working-tree diff. Fix → re-audit
   → repeat until zero findings.
6. Diff approval by user → commit.

Rules from `~/.claude/CLAUDE.md` binding:
- Audit every checkpoint commit, not just final pre-push.
- Re-audit reviews the **whole artifact from scratch**, not delta.
- Loop ends on a zero-finding pass; any fix invalidates that pass.
- `git fetch && git merge origin/main` before push, then adversarial audit on merged diff.

## Open decisions

1. **`close()` sync-vs-async.** Android's `close()` is a suspending function. iOS current
   `close()` is sync. Options:
   - (a) Make `func close() async` — API break, but semantically correct (per-phase timeouts
     need `await`). Callers in `Examples/` app must migrate.
   - (b) Keep `func close()` sync + spawn a detached `Task { await closeAsync() }` internally
     — no API break, but caller cannot observe "close finished" (loses parity with Android).
   - (c) Add both — `func close()` (fire-and-forget) + `func closeAndJoin() async` (awaitable).

   **Recommend (c)** — preserves source-compat + adds the strong guarantee for consumers who
   care. Mirror the pattern already used inside the SDK for `DataSynchronizer`.

2. **`FBOptions.Builder.build() throws`.** Existing API returns `FBOptions` non-throwing.
   Options:
   - (a) `build() throws -> FBOptions` — API break.
   - (b) `build() -> FBOptions?` + `buildOrThrow() throws -> FBOptions` — messy.
   - (c) `build() throws -> FBOptions` (breaking) since we're already opening a refactor PR.

   **Recommend (c)** — the refactor branch is the right place for one clean break. Examples
   app + tests migrate in the same PR.

3. **E2E in-session.** Colima docker may not be available in the shell that runs this plan.
   If not, mark E2E as "not run in session, needs reviewer follow-up" in the PR body — same
   as the Android PR did for emulator smoke.

## Rollback plan

Each commit is independently review-clean per CLAUDE.md rule #4. If any phase regresses,
`git revert <sha>` per commit; branch stays on the last-clean SHA. No commit rewrites `main`
history — PR is squash-optional at merge time (reviewer's call).
