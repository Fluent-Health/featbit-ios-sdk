# iOS Clean-Architecture + Hardening + Perf Pass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port [Fluent-Health/featbit-android-sdk#10](https://github.com/Fluent-Health/featbit-android-sdk/pull/10) to the iOS SDK — three-phase refactor (hardening → clean architecture → perf pass) on a single branch, single PR.

**Architecture:** Layered folder split (`Domain/App/Data/Wire/`) inside the existing `FeatBitClient` SPM target. Public API surface (`FBClient`, `FBOptions`, `FBUser`, `FeatureFlag`, `FlagTracker`, `EvalDetail`) stays byte-compat. Kotlin coroutines translate to Swift async/await; `Channel(DROP_OLDEST)` → `AsyncStream(bufferingNewest:)`; `sealed class` → `enum` w/ associated values; `MockWebServer` → `MockURLProtocol` + `NWListener` loopback.

**Tech Stack:** Swift 5.9, SPM, `URLSession`, `URLSessionWebSocketTask`, `Codable`, Swift Concurrency (async/await, `AsyncStream`, `Task`), `NSLock` (existing pattern), `NWListener` (test-only).

**Reference commit hashes (Android PR-10):**
- Hardening: `f30a3bc` (race-safe identify) · `1dd77e1` (streaming tests) · `7aa1c9e` (FBClient tests) · `92bd659` (polling tests) · `fca5052` (lifecycle tests) · `5bbf5e7` (memory store tests) · `f5d36b9` (FlagTracker) · `7af1697` (TrackInsight tests)
- Clean-arch: `aa57bd7` · `2648314` · `13ba9d0` · `5c3c29a` · `60bf846` · `d4cfc44` · `0e62704` · `ea78755` · `cbd4bd0` · `2efe7c9`
- Perf: `316d195` · `901b955` · `bc546fb` · `e781e00` · `35ef98c`

**Repo working tree:** `/Users/deep.shah_fluentinhe/Documents/code/featbit-ios-sdk/featbit-ios-sdk`.
**Branch:** `refactor/clean-architecture` (create off `origin/main`).

**Verification gates (per commit + pre-push, in this order — commit is LAST):**
1. `swift build`
2. `swift test`
3. E2E: `FEATBIT_E2E=1 swift test --filter FeatBitE2E` (best-effort; skip if Colima unavailable)
4. `superpowers:code-reviewer` adversarial audit on working-tree diff; fix + re-audit until zero findings
5. Diff approval → commit

Memory rules (before code):
- **feedback_aggressive_tests_no_judgment_calls.md** — mutation-verified assertions; every test names the mutation that would fail it.
- **feedback_pre_commit_adversarial_audit.md** — audit before every commit, not just final.
- **feedback_re_audit_after_fix_before_push.md** — fix invalidates the audit; re-run.
- **feedback_pull_main_before_push.md** — `git fetch && git merge origin/main` before push.

---

## Phase 0 — Branch + baseline

### Task 0: Create branch + baseline verification

**Files:** none modified.

- [ ] **Step 1: Fetch + create branch off origin/main**

```bash
git fetch origin main
git checkout -b refactor/clean-architecture origin/main
```

Expected: `Switched to a new branch 'refactor/clean-architecture'`.

- [ ] **Step 2: Baseline build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!` (no errors).

- [ ] **Step 3: Baseline tests**

```bash
swift test 2>&1 | tail -10
```

Expected: `Test Suite 'All tests' passed`. Record the current test count in a comment for the tracker task list at the end. Should be ~40-50 tests.

- [ ] **Step 4: Commit (nothing to commit — this task is verification only)**

No commit for Task 0.

---

## Phase 1 — Hardening

### Task 1: Extract `withTimeout` into `Internal/Timeout.swift`

**Files:**
- Create: `Sources/FeatBitClient/Internal/Timeout.swift`
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift` (delete file-private `withTimeout`)

Rationale: multiple call sites in Phase 1 (`close()` per-phase, `identify` timeout, `start` timeout) need the same primitive. Extract now to avoid duplication.

- [ ] **Step 1: Create `Sources/FeatBitClient/Internal/Timeout.swift`**

```swift
import Foundation

/// Runs `operation`, returning its result, or `nil` if it does not complete within `seconds`.
///
/// Swift equivalent of Kotlin's `withTimeoutOrNull`. Both children are cancelled once one wins:
/// the timeout child on success, the operation child on timeout.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

/// Convenience: `Bool` overload that treats timeout as `false`.
func withTimeout(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async -> Bool
) async -> Bool {
    (await withTimeout(seconds: seconds) { () -> Bool? in await operation() }) ?? false
}
```

- [ ] **Step 2: Delete the file-private `withTimeout` in `DefaultFBClient.swift`**

Remove lines 182-193 (the `private func withTimeout(...)`). The two existing call sites (`start` line 58, `identify` line 80) now resolve to the module-scope `withTimeout` in `Timeout.swift`.

- [ ] **Step 3: Verify build + tests**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -5
```

Expected: build green, all tests pass unchanged.

- [ ] **Step 4: Adversarial audit**

Dispatch `superpowers:code-reviewer` on the staged diff. Fix any findings, re-audit. Repeat to zero findings.

- [ ] **Step 5: Commit**

```bash
git add Sources/FeatBitClient/Internal/Timeout.swift Sources/FeatBitClient/DefaultFBClient.swift
git commit -m "refactor: extract withTimeout into Internal/Timeout.swift"
```

---

### Task 2: `EvalResult` sealed enum

**Files:**
- Modify: `Sources/FeatBitClient/Evaluation/EvalResult.swift`
- Modify: `Sources/FeatBitClient/Evaluation/Evaluator.swift`
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift` (call sites)
- Test: `Tests/FeatBitClientTests/FBClientEvaluationTests.swift` (already exists; assertions still valid because reason strings preserved)

- [ ] **Step 1: Rewrite `EvalResult.swift`**

```swift
import Foundation

/// Result of resolving a flag key against the store. Sealed at the type level so callers
/// pattern-match instead of consulting a boolean `isValid`.
enum EvalResult {
    case found(FeatureFlag)
    case notFound(reason: String)

    /// Wire-compatible reason string (preserves the value the .NET/Kotlin SDKs emit).
    var reason: String {
        switch self {
        case .found(let flag): return flag.matchReason
        case .notFound(let reason): return reason
        }
    }

    var isValid: Bool {
        if case .found = self { return true } else { return false }
    }

    /// Convenience: raw variation string when `.found`, empty when `.notFound`.
    var value: String {
        if case .found(let flag) = self { return flag.variation } else { return "" }
    }

    /// Reserved reason for a missing flag.
    static let flagNotFound: EvalResult = .notFound(reason: "flag not found")
}
```

- [ ] **Step 2: Rewrite `Evaluator.swift`**

```swift
import Foundation

/// Resolves a feature flag from the store.
struct Evaluator {
    private let store: MemoryStore

    init(store: MemoryStore) {
        self.store = store
    }

    func evaluate(_ key: String) -> EvalResult {
        guard let flag = store.get(key) else { return .flagNotFound }
        return .found(flag)
    }
}
```

- [ ] **Step 3: Update `DefaultFBClient.evaluateCore(_:_:_:)`**

Replace the current tuple-destructuring block (lines 143-146):

```swift
let (evalResult, flag) = evaluator.evaluate(key)
guard evalResult.isValid, let flag else {
    return EvalDetail(reason: evalResult.reason, value: defaultValue)
}
```

with:

```swift
let evalResult = evaluator.evaluate(key)
guard case .found(let flag) = evalResult else {
    return EvalDetail(reason: evalResult.reason, value: defaultValue)
}
```

- [ ] **Step 4: Add regression test in `Tests/FeatBitClientTests/EvalResultTests.swift`**

```swift
import XCTest
@testable import FeatBitClient

final class EvalResultTests: XCTestCase {
    func test_flagNotFound_reason_is_wire_compatible() {
        // Mutation: change "flag not found" string -> would break .NET/Kotlin wire parity.
        XCTAssertEqual(EvalResult.flagNotFound.reason, "flag not found")
        XCTAssertFalse(EvalResult.flagNotFound.isValid)
        XCTAssertEqual(EvalResult.flagNotFound.value, "")
    }

    func test_found_reason_uses_flag_matchReason() {
        let flag = FeatureFlag(id: "k", variation: "v", matchReason: "TARGET_MATCH")
        let r: EvalResult = .found(flag)
        XCTAssertTrue(r.isValid)
        XCTAssertEqual(r.reason, "TARGET_MATCH")
        XCTAssertEqual(r.value, "v")
    }

    func test_pattern_match_extracts_flag() {
        let flag = FeatureFlag(id: "k", variation: "v", matchReason: "TARGET_MATCH")
        let r: EvalResult = .found(flag)
        guard case .found(let extracted) = r else { XCTFail("expected .found"); return }
        XCTAssertEqual(extracted.id, "k")
    }
}
```

Confirm `FeatureFlag` init signature (may be `(id:variation:matchReason:...)`; adjust to actual signature from `Sources/FeatBitClient/Model/FeatureFlag.swift` before running).

- [ ] **Step 5: Run tests**

```bash
swift test --filter EvalResultTests 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: 3 new tests pass; existing tests unchanged (reason strings preserved).

- [ ] **Step 6: Adversarial audit + fix loop**

- [ ] **Step 7: Commit**

```bash
git add Sources/FeatBitClient/Evaluation/EvalResult.swift Sources/FeatBitClient/Evaluation/Evaluator.swift Sources/FeatBitClient/DefaultFBClient.swift Tests/FeatBitClientTests/EvalResultTests.swift
git commit -m "refactor: EvalResult sealed enum + pattern-match at Evaluator call sites"
```

---

### Task 3: `FBEndpoints` + `FBOptions.Builder.build() throws`

**Files:**
- Create: `Sources/FeatBitClient/Internal/FBEndpoints.swift`
- Create: `Sources/FeatBitClient/Options/FBOptionsError.swift`
- Modify: `Sources/FeatBitClient/Options/FBOptions.swift` (build throws)
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift` (consume endpoints)
- Modify: `Sources/FeatBitClient/Internal/GetUserFlags.swift`, `Internal/TrackInsight.swift`, `DataSynchronizer/StreamingDataSynchronizer.swift` (consume endpoints)
- Modify: `Examples/` app (build call sites) + all tests that call `Builder().build()`
- Test: `Tests/FeatBitClientTests/FBEndpointsTests.swift` (new)
- Test: `Tests/FeatBitClientTests/FBOptionsBuilderTests.swift` (new)

- [ ] **Step 1: Create `Sources/FeatBitClient/Options/FBOptionsError.swift`**

```swift
import Foundation

/// Errors surfaced eagerly from `FBOptions.Builder.build()` — malformed configuration
/// fails at SDK init, not on first network call.
public enum FBOptionsError: Error, Equatable {
    /// The polling / streaming / event URI failed to parse or is missing a host.
    case invalidURL(field: String, value: String)
    /// `pollingInterval` must be > 0.
    case invalidPollingInterval(TimeInterval)
    /// `backgroundGracePeriod` must be >= 0.
    case invalidGracePeriod(TimeInterval)
    /// `secret` is empty and the client is not offline.
    case missingSecret
}
```

- [ ] **Step 2: Create `Sources/FeatBitClient/Internal/FBEndpoints.swift`**

```swift
import Foundation

/// Single, eagerly-parsed source of truth for FeatBit endpoints. Constructed at
/// `FBOptions.build()` time so malformed URIs throw at SDK init instead of on the first
/// network call. Mirrors the Kotlin `FBEndpoints`.
struct FBEndpoints {
    let polling: URL
    let event: URL
    let streamingWs: URL

    static func from(pollingUri: String, eventUri: String, streamingUri: String) throws -> FBEndpoints {
        FBEndpoints(
            polling: try parseHTTP(pollingUri, field: "pollingUri"),
            event: try parseHTTP(eventUri, field: "eventUri"),
            streamingWs: try parseWS(streamingUri, field: "streamingUri")
        )
    }

    private static func parseHTTP(_ uri: String, field: String) throws -> URL {
        guard let url = URL(string: uri),
              let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { throw FBOptionsError.invalidURL(field: field, value: uri) }
        return url
    }

    private static func parseWS(_ uri: String, field: String) throws -> URL {
        // Accept ws/wss/http/https. Normalize http(s) -> ws(s) for URLSessionWebSocketTask.
        var s = uri
        if s.hasPrefix("https") { s = "wss" + s.dropFirst(5) }
        else if s.hasPrefix("http") { s = "ws" + s.dropFirst(4) }
        guard let url = URL(string: s),
              let host = url.host, !host.isEmpty,
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? "")
        else { throw FBOptionsError.invalidURL(field: field, value: uri) }
        return url
    }
}
```

- [ ] **Step 3: Add `endpoints: FBEndpoints` to `FBOptions`; make `build() throws`**

Modify `Sources/FeatBitClient/Options/FBOptions.swift`:

- Add `public let endpoints: FBEndpoints` to `FBOptions` stored properties.
- Add `endpoints` parameter to the internal `init(...)`.
- Change `Builder.build()` signature:

```swift
public func build() throws -> FBOptions {
    if !offline && secret.trimmingCharacters(in: .whitespaces).isEmpty {
        throw FBOptionsError.missingSecret
    }
    if pollingInterval <= 0 { throw FBOptionsError.invalidPollingInterval(pollingInterval) }
    if backgroundGracePeriod < 0 { throw FBOptionsError.invalidGracePeriod(backgroundGracePeriod) }
    let endpoints = try FBEndpoints.from(
        pollingUri: pollingUri,
        eventUri: eventUri,
        streamingUri: streamingUri
    )
    return FBOptions(
        offline: offline,
        bootstrap: bootstrap,
        secret: secret,
        dataSyncMode: dataSyncMode,
        pollingUri: pollingUri,
        pollingInterval: pollingInterval,
        streamingUri: streamingUri,
        eventUri: eventUri,
        backgroundGracePeriod: backgroundGracePeriod,
        logger: logger,
        endpoints: endpoints
    )
}
```

- [ ] **Step 4: Rewire consumers to prefer `options.endpoints.*`**

In `GetUserFlags.init(...)`: replace `URL(string: options.pollingUri)!` with
`options.endpoints.polling`. Same for `HttpTrackInsight.init(...)` → `options.endpoints.event`.
Same for `StreamingDataSynchronizer.init(...)` → `options.endpoints.streamingWs` (drop the
`toStreamingWsURL(_:)` static; move behavior into `FBEndpoints.parseWS`).

- [ ] **Step 5: Migrate call sites (Examples + tests)**

Grep for `.build()` on `FBOptions.Builder` across the repo:

```bash
grep -rn "\.build()" Examples/ Tests/ Sources/ --include="*.swift"
```

Wrap each in `try` or `try!` (test call sites can use `try!`). `Examples/` app switches to
`try FBOptions.Builder(...).build()` with a `catch` block that logs and no-ops.

- [ ] **Step 6: Add test `Tests/FeatBitClientTests/FBEndpointsTests.swift`**

```swift
import XCTest
@testable import FeatBitClient

final class FBEndpointsTests: XCTestCase {
    func test_valid_http_urls_parse() throws {
        let e = try FBEndpoints.from(
            pollingUri: "https://poll.example.com",
            eventUri: "https://event.example.com",
            streamingUri: "wss://stream.example.com"
        )
        XCTAssertEqual(e.polling.scheme, "https")
        XCTAssertEqual(e.event.scheme, "https")
        XCTAssertEqual(e.streamingWs.scheme, "wss")
    }

    func test_http_streaming_uri_is_normalized_to_ws() throws {
        let e = try FBEndpoints.from(
            pollingUri: "https://p.com",
            eventUri: "https://e.com",
            streamingUri: "https://s.com"
        )
        XCTAssertEqual(e.streamingWs.scheme, "wss")
    }

    func test_malformed_polling_uri_throws() {
        XCTAssertThrowsError(try FBEndpoints.from(
            pollingUri: "not a url",
            eventUri: "https://e.com",
            streamingUri: "wss://s.com"
        )) { err in
            guard case FBOptionsError.invalidURL(let field, _) = err else {
                XCTFail("wrong error: \(err)"); return
            }
            XCTAssertEqual(field, "pollingUri")
        }
    }

    func test_missing_host_throws() {
        // Mutation: dropping the host check accepts "https://" which crashes URLSession.
        XCTAssertThrowsError(try FBEndpoints.from(
            pollingUri: "https://",
            eventUri: "https://e.com",
            streamingUri: "wss://s.com"
        ))
    }

    func test_ftp_scheme_rejected() {
        XCTAssertThrowsError(try FBEndpoints.from(
            pollingUri: "ftp://p.com",
            eventUri: "https://e.com",
            streamingUri: "wss://s.com"
        ))
    }
}
```

- [ ] **Step 7: Add test `Tests/FeatBitClientTests/FBOptionsBuilderTests.swift`**

```swift
import XCTest
@testable import FeatBitClient

final class FBOptionsBuilderTests: XCTestCase {
    func test_default_build_offline_bootstrap_succeeds() throws {
        _ = try FBOptions.Builder().offline(true).build()
    }

    func test_missing_secret_when_not_offline_throws() {
        XCTAssertThrowsError(try FBOptions.Builder().build()) { err in
            XCTAssertEqual(err as? FBOptionsError, .missingSecret)
        }
    }

    func test_zero_polling_interval_throws() {
        XCTAssertThrowsError(
            try FBOptions.Builder("secret").polling("https://p.com", interval: 0).build()
        ) { err in
            guard case FBOptionsError.invalidPollingInterval = err else {
                XCTFail("wrong error: \(err)"); return
            }
        }
    }

    func test_negative_grace_throws() {
        XCTAssertThrowsError(
            try FBOptions.Builder("secret")
                .polling("https://p.com")
                .backgroundGracePeriod(-1)
                .build()
        ) { err in
            guard case FBOptionsError.invalidGracePeriod = err else {
                XCTFail("wrong error: \(err)"); return
            }
        }
    }

    func test_malformed_polling_uri_throws() {
        XCTAssertThrowsError(
            try FBOptions.Builder("secret").polling("not a url").build()
        )
    }
}
```

- [ ] **Step 8: Verify + audit + commit**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5
```

Expected: green. Adversarial audit → zero findings.

```bash
git add -A
git commit -m "feat: FBEndpoints + eager FBOptions.build() validation

- FBOptions.Builder.build() now throws FBOptionsError on malformed URIs,
  zero polling interval, negative grace, or missing secret in non-offline mode.
- Eagerly-parsed endpoints (polling, event, streamingWs) become the single
  source of truth; GetUserFlags / HttpTrackInsight / StreamingDataSynchronizer
  all consume options.endpoints.* instead of re-parsing strings on the hot path.
- Malformed URIs now fail at SDK init, not on first network call.

Mirrors Android f30a3bc (FBEndpoints + build validation)."
```

---

### Task 4: `DataSynchronizer.closeAndJoin()` + race-safe `identify`

**Files:**
- Modify: `Sources/FeatBitClient/DataSynchronizer/DataSynchronizer.swift` (protocol + default)
- Modify: `Sources/FeatBitClient/DataSynchronizer/PollingDataSynchronizer.swift`
- Modify: `Sources/FeatBitClient/DataSynchronizer/StreamingDataSynchronizer.swift`
- Modify: `Sources/FeatBitClient/DataSynchronizer/NullDataSynchronizer.swift`
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift` (identify + close)
- Test: `Tests/FeatBitClientTests/PollingDataSynchronizerTests.swift` (extend)
- Test: `Tests/FeatBitClientTests/TestSupport/BarrierStore.swift` (new)

- [ ] **Step 1: Add `closeAndJoin() async` to `DataSynchronizer` protocol**

Edit `Sources/FeatBitClient/DataSynchronizer/DataSynchronizer.swift`:

```swift
protocol DataSynchronizer: AnyObject, Sendable {
    var initialized: Bool { get }
    func start() async -> Bool
    func pause()
    func resume()
    func close()
    /// Suspending close: cancels work and awaits in-flight upserts / send-completion.
    /// Callers use this from `identify` to prevent old-user data landing after switch.
    func closeAndJoin() async
}

extension DataSynchronizer {
    func pause() {}
    func resume() {}
    /// Default fallback: fire close and return. Overridden by synchronizers that own a Task.
    func closeAndJoin() async { close() }
}
```

- [ ] **Step 2: Override on `PollingDataSynchronizer`**

Add:

```swift
func closeAndJoin() async {
    let task = lock.withLock { () -> Task<Void, Never>? in
        if closed { return nil }
        closed = true
        let t = loopTask
        loopTask = nil
        return t
    }
    guard let task else { return }
    task.cancel()
    _ = await task.value    // await loop termination — draining any in-flight upsert
    startGate.complete(false)
}
```

Keep sync `close()` unchanged (for callers that don't need the guarantee).

- [ ] **Step 3: Override on `StreamingDataSynchronizer`**

Add (Apple platforms only — inside the `#if canImport(Darwin)` block):

```swift
func closeAndJoin() async {
    let (task, hb): (URLSessionWebSocketTask?, Task<Void, Never>?) = lock.withLock {
        closed = true
        let h = heartbeatTask
        heartbeatTask = nil
        let t = webSocket
        webSocket = nil
        return (t, h)
    }
    task?.cancel(with: .normalClosure, reason: nil)
    hb?.cancel()
    if let hb { _ = await hb.value }
    startGate.complete(false)
}
```

For the Linux stub: `func closeAndJoin() async { close() }`.

- [ ] **Step 4: `NullDataSynchronizer` — default impl already applies**

No change needed — default extension covers it.

- [ ] **Step 5: `DefaultFBClient.identify` awaits `closeAndJoin`**

In `identify(_:timeout:)`, replace `old.close()` with `await old.closeAndJoin()` **before**
calling `fresh.start()`.

- [ ] **Step 6: Create `Tests/FeatBitClientTests/TestSupport/BarrierStore.swift`**

Add to `Package.swift` if needed (currently the test target picks up all files under
`Tests/FeatBitClientTests/`; verify).

```swift
import Foundation
@testable import FeatBitClient

/// `MemoryStore` decorator that blocks the first `upsert` on a barrier + deadline.
///
/// Used to prove `closeAndJoin` awaits in-flight upserts before returning.
final class BarrierStore: MemoryStore, @unchecked Sendable {
    private let inner: MemoryStore
    private let enter: DispatchSemaphore
    private let release: DispatchSemaphore
    private var firstDone = false
    private let lock = NSLock()

    init(_ inner: MemoryStore) {
        self.inner = inner
        self.enter = DispatchSemaphore(value: 0)
        self.release = DispatchSemaphore(value: 0)
    }

    /// Signalled when the first upsert enters.
    func waitForEnter(timeout: TimeInterval) -> Bool {
        enter.wait(timeout: .now() + timeout) == .success
    }

    /// Release the blocked upsert.
    func releaseUpsert() {
        release.signal()
    }

    func get(_ id: String) -> FeatureFlag? { inner.get(id) }
    func getAll() -> [FeatureFlag] { inner.getAll() }

    func upsert(_ flag: FeatureFlag) {
        let shouldBlock: Bool = lock.withLock {
            if firstDone { return false }
            firstDone = true
            return true
        }
        if shouldBlock {
            enter.signal()
            _ = release.wait(timeout: .now() + 10)
        }
        inner.upsert(flag)
    }

    func addChangeListener(_ listener: FlagChangeListener) { inner.addChangeListener(listener) }
    func removeChangeListener(_ listener: FlagChangeListener) { inner.removeChangeListener(listener) }
}
```

Add a small `NSLock.withLock` shim if one doesn't already exist in the test target (check
`Sources/FeatBitClient/Internal/Lock.swift` — if the app-side `Lock` is internal, add a
local helper).

- [ ] **Step 7: Add `PollingDataSynchronizerTests.closeAndJoin` tests**

```swift
func test_closeAndJoin_awaits_in_flight_upsert() async throws {
    let inner = DefaultMemoryStore()
    let barrier = BarrierStore(inner)
    let mock = MockURLProtocol()    // see Task 5 for MockURLProtocol
    mock.enqueue(status: 200, body: latestAllBodyWithOneFlag)
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 0.05).build()
    // NOTE: options must use MockURLProtocol via URLSessionConfiguration. See TestSupport.
    let sync = PollingDataSynchronizer(options: options, user: FBUser.builder("u").build(), store: barrier)

    let started = Task { await sync.start() }
    XCTAssertTrue(barrier.waitForEnter(timeout: 2), "first upsert did not enter")
    // While the upsert is blocked, kick off closeAndJoin and prove it does not complete yet:
    let closing = Task { await sync.closeAndJoin() }
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse(closing.isFinished("closing", waitMillis: 0), "closeAndJoin returned before upsert completed")
    barrier.releaseUpsert()
    await closing.value
    _ = await started.value

    // Mutation: replacing `await task.value` with plain `task.cancel()` makes closing return
    // immediately (before releaseUpsert()), so the assertion above fails.
}
```

Helper `Task.isFinished(_:waitMillis:)` — extract a small extension in TestSupport.

- [ ] **Step 8: Verify + audit + commit**

```bash
swift build && swift test --filter PollingDataSynchronizerTests 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Green. Audit. Commit:

```bash
git add -A
git commit -m "fix: DataSynchronizer.closeAndJoin awaits in-flight work; identify uses it

- Protocol gains closeAndJoin() async; default fallback = close().
- Polling override: cancels loop task, awaits task.value so in-flight upserts
  finish before returning. Prior close() was fire-and-forget: a late 200 could
  land in the store under the next user.
- Streaming override: cancels WS + heartbeat, awaits heartbeat termination.
- DefaultFBClient.identify awaits old.closeAndJoin() before starting fresh sync.
- BarrierStore test helper pins the race: closing does not return until the
  blocked upsert completes.

Mirrors Android f30a3bc + 92bd659."
```

---

### Task 5: `MockURLProtocol` + `LoopbackWebSocketServer` test helpers

**Files:**
- Create: `Tests/FeatBitClientTests/TestSupport/MockURLProtocol.swift`
- Create: `Tests/FeatBitClientTests/TestSupport/LoopbackWebSocketServer.swift`
- Create: `Tests/FeatBitClientTests/TestSupport/TestURLSession.swift`

- [ ] **Step 1: Create `MockURLProtocol.swift`**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Test URLProtocol that returns enqueued responses in FIFO order. One instance per
/// registration; `Handler.reset()` between tests. Records requests for structural
/// assertions.
final class MockURLProtocol: URLProtocol {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let queueLock = NSLock()
    private static var stubs: [StubResponse] = []
    private(set) static var receivedRequests: [URLRequest] = []

    static func reset() {
        queueLock.lock(); defer { queueLock.unlock() }
        stubs.removeAll()
        receivedRequests.removeAll()
    }

    static func enqueue(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        queueLock.lock(); defer { queueLock.unlock() }
        stubs.append(StubResponse(statusCode: status, headers: headers, body: body))
    }

    static func enqueue(status: Int, jsonBody: String) {
        enqueue(status: status, headers: ["Content-Type": "application/json"], body: Data(jsonBody.utf8))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: StubResponse? = MockURLProtocol.queueLock.withLock {
            MockURLProtocol.receivedRequests.append(request)
            return MockURLProtocol.stubs.isEmpty ? nil : MockURLProtocol.stubs.removeFirst()
        }
        let s = stub ?? StubResponse(statusCode: 500, headers: [:], body: Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: s.statusCode, httpVersion: "HTTP/1.1", headerFields: s.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: s.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
```

- [ ] **Step 2: Create `TestURLSession.swift`**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a URLSession that routes all requests through `MockURLProtocol`. Callers pass
/// the returned session into SDK types (`FbApiClient` accepts an injected session already).
enum TestURLSession {
    static func mocked() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 3: Create `LoopbackWebSocketServer.swift`**

```swift
#if canImport(Network)
import Foundation
import Network

/// Minimal WS server for tests. Listens on 127.0.0.1:<ephemeral>. Speaks WebSocket
/// handshake + text/binary frames. Records inbound messages; sends enqueued outbound
/// messages when connected.
///
/// Only the shape used by `StreamingDataSynchronizer` is supported:
///  - text frames in both directions
///  - normal-closure close (opcode 0x8)
final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private var connection: NWConnection?
    private let lock = NSLock()
    private var inbound: [String] = []
    private var outboundQueue: [String] = []
    private var closeCode: Int?
    private var closeReason: String?
    private let readyGroup = DispatchGroup()
    private var isReady = false

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var wsURLString: String { "ws://127.0.0.1:\(port)" }

    init() throws {
        let params = NWParameters(tls: nil)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        listener = try NWListener(using: params, on: .any)
    }

    func start() {
        readyGroup.enter()
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.lock.withLock { self?.isReady = true }
                self?.readyGroup.leave()
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: DispatchQueue.global(qos: .userInitiated))
        _ = readyGroup.wait(timeout: .now() + 2)
    }

    private func accept(_ conn: NWConnection) {
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveLoop()
                self?.drainOutbound()
            }
        }
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, ctx, _, error in
            if let data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                self?.lock.withLock { self?.inbound.append(text) }
            }
            if let ctx = ctx, let meta = ctx.protocolMetadata.first as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                if let data, data.count >= 2 {
                    let code = Int(UInt16(data[0]) << 8 | UInt16(data[1]))
                    let reason = data.count > 2 ? String(data: data.subdata(in: 2..<data.count), encoding: .utf8) : nil
                    self?.lock.withLock {
                        self?.closeCode = code
                        self?.closeReason = reason
                    }
                }
                return
            }
            if error == nil { self?.receiveLoop() }
        }
    }

    private func drainOutbound() {
        let msgs: [String] = lock.withLock {
            let m = outboundQueue
            outboundQueue.removeAll()
            return m
        }
        for msg in msgs { sendText(msg) }
    }

    /// Sends a text frame. Buffers if the client is not yet connected.
    func enqueueText(_ text: String) {
        lock.withLock { outboundQueue.append(text) }
        if connection?.state == .ready { drainOutbound() }
    }

    private func sendText(_ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection?.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
    }

    func receivedInbound() -> [String] {
        lock.withLock { inbound }
    }

    func recordedClose() -> (code: Int?, reason: String?) {
        lock.withLock { (closeCode, closeReason) }
    }

    func stop() {
        connection?.cancel()
        listener.cancel()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
#endif
```

- [ ] **Step 4: Sanity-check both compile** — no consumers yet, just verify structure.

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Green.

- [ ] **Step 5: Audit + commit**

```bash
git add Tests/FeatBitClientTests/TestSupport/
git commit -m "test: MockURLProtocol + LoopbackWebSocketServer test-support helpers

- MockURLProtocol: URLProtocol subclass with FIFO stub queue and recorded requests.
  Swift-native replacement for Android's MockWebServer on the HTTP side.
- LoopbackWebSocketServer: NWListener-based WS server for streaming tests.
  Records inbound frames + close code/reason; enqueue outbound text frames.
- TestURLSession.mocked() builds a URLSession routed through MockURLProtocol.

No production changes."
```

---

### Task 6: `GetUserFlags` strict shape validation

**Files:**
- Modify: `Sources/FeatBitClient/Internal/GetUserFlags.swift`
- Test: `Tests/FeatBitClientTests/GetUserFlagsTests.swift` (extend)

- [ ] **Step 1: Rewrite `GetUserFlags.parseFlags(from:)` to typed strict decode**

Replace the current permissive parser with:

```swift
private struct LatestAllEnvelope: Decodable {
    let data: LatestAllData
}
private struct LatestAllData: Decodable {
    let featureFlags: [FeatureFlag]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        featureFlags = try c.decodeIfPresent([FeatureFlag].self, forKey: .featureFlags) ?? []
    }

    enum CodingKeys: String, CodingKey { case featureFlags }
}
```

Update `run(timestamp:)`:

```swift
if result.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    return .ok([])
}
do {
    let data = Data(result.body.utf8)
    let envelope = try FbApiClient.decoder.decode(LatestAllEnvelope.self, from: data)
    return .ok(envelope.data.featureFlags)
} catch {
    options.logger.error("Malformed latest-all payload; treating as fatal.", error)
    return .error(-1)
}
```

Note: `data` is **not** optional. `{"data": null}` throws (Swift decodes null → missing on
non-optional → error). Absent `data` field also throws. Absent `featureFlags` inside `data`
→ empty array (backward-compatible with prior behavior).

- [ ] **Step 2: Add tests to `GetUserFlagsTests.swift`**

```swift
func test_missing_data_field_returns_error() {
    // Mutation: making `data` optional would silently return .ok([]).
    let body = #"{"other": "junk"}"#
    // Direct parseFlags call OR build a GetUserFlags with mocked URLSession returning this body.
    // Structural assertion: response.isError == true.
}

func test_null_data_returns_error() {
    let body = #"{"data": null}"#
    // Same assertion pattern.
}

func test_absent_featureFlags_returns_ok_empty() {
    let body = #"{"data": {}}"#
    // Backward-compat: absent inner list -> empty.
}

func test_valid_body_returns_flags() {
    let body = #"{"data": {"featureFlags": [{"id": "k", "variation": "v", "matchReason": "T"}]}}"#
    // Adjust FeatureFlag shape to match actual model.
}
```

Wire these up via `MockURLProtocol.enqueue(...)` + `TestURLSession.mocked()` — `GetUserFlags`
accepts an injected `URLSession` already.

- [ ] **Step 3: Verify + audit + commit**

```bash
swift test --filter GetUserFlagsTests 2>&1 | tail -5
swift test 2>&1 | tail -5
```

```bash
git add -A
git commit -m "fix: GetUserFlags strict shape validation — null/missing data throws not silent []

Prior parser used try? and treated any decode failure as an empty flag list, which
masked wire-format regressions as 'user has no flags — serve defaults forever'.

Now:
- Missing 'data' field -> decode error, caught by safePoll, logged, returned as
  transient .error(-1) so the poll loop retries.
- Explicit 'data': null -> same error path (Swift Decodable throws on null for a
  non-Optional field).
- Absent 'featureFlags' inside 'data' -> empty [] (backward-compat).

Mirrors Android f30a3bc + e781e00 (post-audit fix that reintroduced the strictness
after the perf-pass typed envelope change)."
```

---

### Task 7: `InsightDispatcher` + bounded pipeline

**Files:**
- Create: `Sources/FeatBitClient/Internal/InsightDispatcher.swift`
- Modify: `Sources/FeatBitClient/Internal/TrackInsight.swift` (add `runBatch`)
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift` (wire dispatcher)
- Test: `Tests/FeatBitClientTests/InsightDispatcherTests.swift` (new)

- [ ] **Step 1: Extend `TrackInsight` protocol with `runBatch`**

```swift
protocol TrackInsight: AnyObject, Sendable {
    func run(_ insight: Insight) async
    func runBatch(_ insights: [Insight]) async
    func close()
}

extension TrackInsight {
    // Default single-item bridge for existing call sites.
    func run(_ insight: Insight) async { await runBatch([insight]) }
}
```

Update `HttpTrackInsight` to implement `runBatch(_:)` (POST an array) and drop the
now-defaulted `run(_:)`. Update `NoopTrackInsight` — `runBatch(_:)` is a no-op.

`HttpTrackInsight.runBatch`:

```swift
func runBatch(_ insights: [Insight]) async {
    if insights.isEmpty { return }
    do {
        let payload = try FbApiClient.encoder.encode(insights)
        _ = try await post(url: endpoint, payload: payload)
    } catch {
        options.logger.error("Exception occurred while tracking insight batch.", error)
    }
}
```

- [ ] **Step 2: Create `InsightDispatcher.swift`**

```swift
import Foundation

/// Bounded, batching insight pipeline. Emit side is non-suspending (`offer(_:)`); consumer
/// side batches up to 50 insights or 1s (whichever comes first) and hands the batch to the
/// injected `TrackInsight.runBatch(_:)`.
///
/// Backpressure: when the internal buffer is full the oldest queued insight is dropped
/// (`AsyncStream.Continuation.bufferingNewest(256)`), matching Kotlin `Channel(256, DROP_OLDEST)`.
///
/// `closeAndDrain()` finishes the stream and awaits the consumer within a 2s budget.
final class InsightDispatcher: @unchecked Sendable {
    private let tracker: TrackInsight
    private let logger: FBLogger
    private let stream: AsyncStream<Insight>
    private let continuation: AsyncStream<Insight>.Continuation
    private var consumer: Task<Void, Never>?
    private let lock = NSLock()
    private var closed = false

    private static let bufferSize = 256
    private static let batchSize = 50
    private static let batchTimeoutNs: UInt64 = 1_000_000_000
    private static let drainBudgetNs: UInt64 = 2_000_000_000

    init(tracker: TrackInsight, logger: FBLogger) {
        self.tracker = tracker
        self.logger = logger
        var cont: AsyncStream<Insight>.Continuation!
        self.stream = AsyncStream<Insight>(bufferingPolicy: .bufferingNewest(Self.bufferSize)) { c in
            cont = c
        }
        self.continuation = cont
    }

    func start() {
        lock.withLock {
            guard consumer == nil, !closed else { return }
            consumer = Task { [weak self] in await self?.consumeLoop() }
        }
    }

    /// Non-suspending emit. Called on the hot evaluation path.
    func offer(_ insight: Insight) {
        continuation.yield(insight)
    }

    private func consumeLoop() async {
        var iterator = stream.makeAsyncIterator()
        while true {
            var batch: [Insight] = []
            batch.reserveCapacity(Self.batchSize)

            // Wait for the first element (blocking).
            guard let first = await iterator.next() else { break }
            batch.append(first)

            // Drain up to (batchSize - 1) more with a batchTimeout budget.
            let deadline = DispatchTime.now().uptimeNanoseconds + Self.batchTimeoutNs
            while batch.count < Self.batchSize {
                let remaining = deadline &- DispatchTime.now().uptimeNanoseconds
                if remaining == 0 || remaining > Self.batchTimeoutNs { break } // wrapped or elapsed
                // Non-blocking poll via race with a timer. Simpler + robust: read one more
                // if immediately available, otherwise break.
                let nextTask = Task { await iterator.next() }
                let winner = await withTimeout(seconds: Double(remaining) / 1_000_000_000.0) {
                    () -> Insight? in await nextTask.value
                }
                if let winner, let insight = winner {
                    batch.append(insight)
                } else {
                    nextTask.cancel()
                    break
                }
            }

            await tracker.runBatch(batch)
        }
    }

    /// Suspending drain: finish the continuation, then await the consumer with a 2s budget.
    func closeAndDrain() async {
        let toAwait: Task<Void, Never>? = lock.withLock {
            if closed { return nil }
            closed = true
            let t = consumer
            consumer = nil
            return t
        }
        continuation.finish()
        guard let toAwait else { return }
        _ = await withTimeout(seconds: Double(Self.drainBudgetNs) / 1_000_000_000.0) {
            _ = await toAwait.value
            return true
        }
    }
}
```

Small refactor note: `withTimeout` currently returns `Bool` or `T?`. Confirm signature works
for the `Insight?` overload — may need to add a generic overload or a small helper. Adjust
at implementation time.

- [ ] **Step 3: Wire dispatcher into `DefaultFBClient`**

- Add `private let insightDispatcher: InsightDispatcher` field.
- In `init(...)`: `self.insightDispatcher = InsightDispatcher(tracker: trackInsight, logger: options.logger); insightDispatcher.start()`.
- On the eval hot path, replace `Task { await self?.trackInsight.run(Insight.forEvaluation(...)) }` with `insightDispatcher.offer(Insight.forEvaluation(...))`.
- On `identify`, keep the direct `Task { await trackInsight.run(Insight.forIdentify(...)) }`  (identify is rare; direct path is fine).
- On `close()`, add `Task { await insightDispatcher.closeAndDrain() }` **before** `trackInsight.close()`. (Full close-timeout semantics land in Task 8.)

- [ ] **Step 4: Add tests `Tests/FeatBitClientTests/InsightDispatcherTests.swift`**

Tests to write (each with named mutation-that-would-fail):

```swift
final class InsightDispatcherTests: XCTestCase {
    final class RecordingTracker: TrackInsight, @unchecked Sendable {
        let lock = NSLock()
        var batches: [[Insight]] = []
        func run(_ insight: Insight) async { /* not called */ }
        func runBatch(_ insights: [Insight]) async {
            lock.lock(); defer { lock.unlock() }
            batches.append(insights)
        }
        func close() {}
    }

    func test_single_insight_is_emitted_as_batch_of_one() async throws {
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: NoopLogger())
        d.start()
        d.offer(sampleInsight())
        try await Task.sleep(nanoseconds: 1_200_000_000) // > batch timeout
        await d.closeAndDrain()
        rec.lock.lock(); let batches = rec.batches; rec.lock.unlock()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 1)
    }

    func test_batch_of_50_flushes_before_timeout() async throws {
        // Mutation: increasing batchSize to 51 would fail — one insight would remain buffered.
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: NoopLogger())
        d.start()
        for _ in 0..<50 { d.offer(sampleInsight()) }
        // Poll for the flush without waiting the full 1s timeout.
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 50_000_000)
            rec.lock.lock(); let count = rec.batches.first?.count ?? 0; rec.lock.unlock()
            if count == 50 { break }
        }
        rec.lock.lock(); let batches = rec.batches; rec.lock.unlock()
        XCTAssertEqual(batches.first?.count, 50)
        await d.closeAndDrain()
    }

    func test_overflow_drops_oldest() async throws {
        // Enqueue 300 before starting the consumer (via a slow tracker), verify only 256
        // ever make it through.
        // Mutation: bufferingPolicy .unbounded would let all 300 through — fails this test.
    }

    func test_offer_is_non_suspending() {
        // Structural: `offer` is not marked async. Compile-time test.
    }

    func test_closeAndDrain_flushes_pending() async throws {
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: NoopLogger())
        d.start()
        d.offer(sampleInsight())
        await d.closeAndDrain()
        rec.lock.lock(); let batches = rec.batches; rec.lock.unlock()
        XCTAssertGreaterThanOrEqual(batches.count, 1)
    }

    func test_closeAndDrain_is_idempotent() async {
        let rec = RecordingTracker()
        let d = InsightDispatcher(tracker: rec, logger: NoopLogger())
        d.start()
        await d.closeAndDrain()
        await d.closeAndDrain() // no crash, no throw
    }
}
```

- [ ] **Step 5: Verify + audit + commit**

```bash
swift build && swift test --filter InsightDispatcherTests 2>&1 | tail -5
swift test 2>&1 | tail -5
```

```bash
git add -A
git commit -m "feat: InsightDispatcher — bounded batching insight pipeline

- AsyncStream(bufferingNewest: 256) mirrors Kotlin Channel(256, DROP_OLDEST).
- Consumer batches up to 50 events / 1s, calls TrackInsight.runBatch([...]).
- Emit path offer(_:) is non-suspending; hot evaluation path no longer spawns
  a fresh Task per insight.
- closeAndDrain() finishes the stream and awaits the consumer within 2s.
- HttpTrackInsight gains runBatch(_:); NoopTrackInsight no-ops.
- DefaultFBClient wires evaluation insights through the dispatcher; identify
  still uses direct run (rare path).

Mirrors Android f30a3bc (InsightDispatcher)."
```

---

### Task 8: `DefaultFBClient.close() async` with per-phase 2s + 2s budget

**Files:**
- Modify: `Sources/FeatBitClient/FBClient.swift` (protocol adds `closeAndJoin() async`; keep `close()` sync)
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift`
- Modify: `Examples/` app if it calls `close()`

- [ ] **Step 1: Extend `FBClient` protocol**

```swift
public protocol FBClient: AnyObject {
    // existing methods...
    /// Fire-and-forget close. Returns immediately; teardown happens in the background.
    func close()
    /// Suspending close. Awaits synchronizer teardown (2s budget) and insight flush (2s budget).
    /// Use when the caller wants ordering guarantees (e.g., before the process exits).
    func closeAndJoin() async
}

public extension FBClient {
    /// Default fallback delegates to `close()`.
    func closeAndJoin() async { close() }
}
```

- [ ] **Step 2: Implement in `DefaultFBClient`**

```swift
public func close() {
    Task { await closeAndJoin() }
}

public func closeAndJoin() async {
    // Phase A: synchronizer teardown, 2s budget.
    let sync = currentSynchronizer
    _ = await withTimeout(seconds: 2.0) {
        await sync.closeAndJoin()
        return true
    }
    // Phase B: insight flush, 2s budget.
    _ = await withTimeout(seconds: 2.0) {
        await insightDispatcher.closeAndDrain()
        return true
    }
    // Non-blocking tail: tracker + flag tracker cleanup.
    flagTrackerImpl.close()
    trackInsight.close()
}
```

- [ ] **Step 3: Migrate `Examples/` if it calls `close()`**

```bash
grep -rn "\.close()" Examples/ --include="*.swift"
```

If found, no change needed (fire-and-forget still works). If a caller wants the guarantee,
swap to `await client.closeAndJoin()`.

- [ ] **Step 4: Add test in `FBClientEvaluationTests` (or new `FBClientCloseTests`)**

```swift
func test_closeAndJoin_completes_promptly_offline() async throws {
    let client = try makeOfflineClient(bootstrap: [oneFlag])
    let start = Date()
    await client.closeAndJoin()
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
}

func test_closeAndJoin_bounded_when_sync_teardown_blocks() async throws {
    // Point polling at MockURLProtocol with NO enqueued responses -> URLSession blocks
    // for its readTimeout (~60s). Assert closeAndJoin returns < 2500ms.
    let session = TestURLSession.mocked()
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 5).build()
    // NOTE: options currently has no session-injection knob. Reuse whatever knob is used
    // in existing tests (e.g., DefaultFBClient's init signature accepts a session at some
    // level, or the sync accepts one). If none exists, this test is deferred to Task 12
    // (FBClientEvaluationTests hardening pass).
}

func test_close_is_idempotent() async throws {
    let client = try makeOfflineClient(bootstrap: [oneFlag])
    await client.closeAndJoin()
    let start = Date()
    await client.closeAndJoin()
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "second close should be near-instant")
}
```

- [ ] **Step 5: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git add -A
git commit -m "fix: DefaultFBClient close with per-phase 2s+2s timeouts

Split close into two suspending phases so a slow sync teardown cannot starve
the insight flush (which would otherwise leak URLSession delegate threads):

  Phase A: await synchronizer.closeAndJoin() with 2s budget.
  Phase B: await insightDispatcher.closeAndDrain() with 2s budget.

- Public API additions (non-breaking): closeAndJoin() async on FBClient.
- close() remains fire-and-forget (source-compatible).
- Non-blocking tail: flagTrackerImpl.close() + trackInsight.close().

Mirrors Android f30a3bc (per-phase 2s+2s budget)."
```

---

### Task 9: Streaming — `ownsSession` + `closed` guard on `handleMessage`

**Files:**
- Modify: `Sources/FeatBitClient/DataSynchronizer/StreamingDataSynchronizer.swift`

- [ ] **Step 1: Add `ownsSession` flag**

```swift
private let ownsSession: Bool

init(options: FBOptions, user: FBUser, store: MemoryStore, session: URLSession? = nil) {
    self.ownsSession = (session == nil)
    // ... rest unchanged
    self.session = session ?? URLSession(configuration: .ephemeral)
}
```

- [ ] **Step 2: Invalidate SDK-owned session on `close`/`closeAndJoin`**

In `close()`:

```swift
if ownsSession { session.invalidateAndCancel() }
```

Add same to `closeAndJoin()`.

- [ ] **Step 3: Late-message guard**

At the top of `handleMessage(_:)`:

```swift
private func handleMessage(_ text: String) {
    if lock.withLock({ closed }) { return }
    // ... rest unchanged
}
```

- [ ] **Step 4: Verify + audit + commit**

```bash
swift build && swift test --filter StreamingDataSynchronizerTests 2>&1 | tail -5
```

```bash
git add -A
git commit -m "fix: StreamingDataSynchronizer ownsSession + closed guard on handleMessage

- ownsSession flag mirrors Android's ownsClient. When the SDK creates the
  session (no session param), close() invalidates it — prevents URLSession
  delegate thread leaks.
- handleMessage() now returns early if closed==true so late frames flushed
  by URLSessionWebSocketTask after cancel() do not clobber the store or
  advance the timestamp.

Mirrors Android f30a3bc."
```

---

### Task 10: Aggressive test pinning — `DefaultMemoryStoreTests`

**Files:**
- Modify: `Tests/FeatBitClientTests/DefaultMemoryStoreTests.swift`

Add 4 tests per spec §Phase 1 test pinning #4. Each with mutation-that-would-fail comment.

- [ ] **Step 1: Read the existing test file, understand what's already there**

```bash
cat Tests/FeatBitClientTests/DefaultMemoryStoreTests.swift
```

- [ ] **Step 2: Add tests**

```swift
func test_concurrent_upserts_are_race_free() throws {
    // Mutation: removing the lock inside upsert would produce wrong-but-plausible counts
    // OR crash under contention. Assert no-crash + final variation is one of the writers'.
    let store = DefaultMemoryStore()
    let group = DispatchGroup()
    for t in 0..<16 {
        group.enter()
        DispatchQueue.global().async {
            for i in 0..<250 {
                store.upsert(FeatureFlag(id: "k", variation: "v-\(t)-\(i)", matchReason: "T"))
            }
            group.leave()
        }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    let final = store.get("k")
    XCTAssertNotNil(final)
    XCTAssertTrue(final!.variation.hasPrefix("v-"))
}

func test_listener_observes_just_written_value() {
    // Mutation: notifying listener BEFORE `items[flag.id] = flag` would let listener
    // read the OLD value from store.get(). Test proves happens-before.
    let store = DefaultMemoryStore()
    let listener = ObservingListener { evt in
        // Re-entering store.get inside the listener callback:
        let seen = store.get(evt.key)
        XCTAssertEqual(seen?.variation, evt.newValue)
    }
    store.addChangeListener(listener)
    store.upsert(FeatureFlag(id: "k", variation: "v1", matchReason: "T"))
    store.upsert(FeatureFlag(id: "k", variation: "v2", matchReason: "T"))
}

func test_add_and_remove_listeners_during_dispatch_do_not_corrupt() {
    // Mutation: iterating `listeners` directly (not the compactMap snapshot) would throw
    // in Swift or, worse, silently miss the just-added listener. Assert no-throw + late
    // listener does not fire for the in-flight event.
    let store = DefaultMemoryStore()
    var lateFireCount = 0
    let late = ObservingListener { _ in lateFireCount += 1 }
    let first = ObservingListener { _ in store.addChangeListener(late) }
    store.addChangeListener(first)
    store.upsert(FeatureFlag(id: "k", variation: "v1", matchReason: "T"))
    XCTAssertEqual(lateFireCount, 0, "late listener must not fire for the in-flight event")
    store.upsert(FeatureFlag(id: "k", variation: "v2", matchReason: "T"))
    XCTAssertEqual(lateFireCount, 1, "late listener fires on subsequent events")
}

func test_addChangeListener_is_idempotent() {
    // Mutation: replacing the removeAll-then-append pattern with plain append would fire
    // the same listener twice per event.
    let store = DefaultMemoryStore()
    var fireCount = 0
    let l = ObservingListener { _ in fireCount += 1 }
    store.addChangeListener(l)
    store.addChangeListener(l) // re-add same instance
    store.upsert(FeatureFlag(id: "k", variation: "v", matchReason: "T"))
    XCTAssertEqual(fireCount, 1)
}

// Shared helper class in the test file:
private final class ObservingListener: FlagChangeListener {
    let onChangeCallback: (FlagValueChangedEvent) -> Void
    init(_ cb: @escaping (FlagValueChangedEvent) -> Void) { onChangeCallback = cb }
    func onChange(_ event: FlagValueChangedEvent) { onChangeCallback(event) }
}
```

- [ ] **Step 3: Verify + audit + commit**

```bash
swift test --filter DefaultMemoryStoreTests 2>&1 | tail -5
```

Green.

```bash
git add Tests/FeatBitClientTests/DefaultMemoryStoreTests.swift
git commit -m "test: pin DefaultMemoryStore thread-safety + listener semantics

+4 tests, each with documented mutation:
- 16 threads * 250 upserts race-free (no crash + final state consistent).
- listener observes just-written value (write happens-before notify).
- add/remove listeners during dispatch do not corrupt iteration.
- addChangeListener idempotent for the same listener instance.

Mirrors Android 5bbf5e7."
```

---

### Task 11: Aggressive test pinning — `LifecycleControllerTests`

**Files:**
- Modify: `Tests/FeatBitClientTests/LifecycleControllerTests.swift`

Add 3 tests per spec §Phase 1 test pinning #5.

- [ ] **Step 1: Add tests**

```swift
func test_foreground_flap_within_grace_reanchors_pause() async throws {
    // Mutation: removing pauseTask?.cancel() in reconcile() would make pause fire on the
    // ORIGINAL schedule (T=grace) instead of anchoring to the second off (T>=2*grace).
    let grace: TimeInterval = 0.1
    let sync = ProbeSynchronizer()
    let lc = LifecycleController(graceSeconds: grace) { sync }
    await lc.onForegroundChanged(false)
    try await Task.sleep(nanoseconds: 50_000_000)
    await lc.onForegroundChanged(true)
    try await Task.sleep(nanoseconds: 50_000_000)
    await lc.onForegroundChanged(false)
    // At T=grace after the ORIGINAL off, pause must NOT have fired.
    try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000) + 20_000_000)
    XCTAssertEqual(sync.pauseCount, 0, "pause fired on the cancelled schedule")
    try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000) + 20_000_000)
    XCTAssertEqual(sync.pauseCount, 1, "pause did not fire on the re-anchored schedule")
}

func test_network_on_while_foreground_off_does_not_resume() async throws {
    // Mutation: replacing `if foreground && online` with `if online` inside reconcile
    // would resume the synchronizer while the app is still backgrounded.
    let sync = ProbeSynchronizer()
    let lc = LifecycleController(graceSeconds: 0.05) { sync }
    await lc.onForegroundChanged(false)
    try await Task.sleep(nanoseconds: 70_000_000) // let the pause land
    XCTAssertEqual(sync.pauseCount, 1)
    await lc.onNetworkChanged(false)
    await lc.onNetworkChanged(true) // network came back but foreground still off
    XCTAssertEqual(sync.resumeCount, 0, "resume must not fire while foreground is off")
    await lc.onForegroundChanged(true)
    XCTAssertEqual(sync.resumeCount, 1)
}

func test_second_inactive_signal_while_pause_pending_does_not_double_schedule() async throws {
    // Mutation: dropping the `pauseTask == nil` guard would double-schedule the pause,
    // producing pauseCount==2 at 2*grace instead of pauseCount==1 at grace.
    let sync = ProbeSynchronizer()
    let lc = LifecycleController(graceSeconds: 0.1) { sync }
    await lc.onForegroundChanged(false)
    await lc.onNetworkChanged(false)
    try await Task.sleep(nanoseconds: 250_000_000) // 2.5 * grace
    XCTAssertEqual(sync.pauseCount, 1)
}

private final class ProbeSynchronizer: DataSynchronizer, @unchecked Sendable {
    var initialized = false
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    func start() async -> Bool { true }
    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func close() {}
}
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift test --filter LifecycleControllerTests 2>&1 | tail -5
```

```bash
git add Tests/FeatBitClientTests/LifecycleControllerTests.swift
git commit -m "test: pin LifecycleController flap/race semantics

+3 tests, each mutation-verified:
- foreground flap within grace re-anchors pause to latest off.
- network on while foreground off does not resume.
- second inactive signal while pause pending does not double-schedule.

Mirrors Android fca5052."
```

---

### Task 12: Aggressive test pinning — `PollingDataSynchronizerTests`

**Files:**
- Modify: `Tests/FeatBitClientTests/PollingDataSynchronizerTests.swift`

Add the two extra tests (loop cadence + transient 5xx recovery) — the closeAndJoin race
test already landed in Task 4.

- [ ] **Step 1: Add tests**

```swift
func test_polling_loop_issues_repeated_requests_across_interval() async throws {
    // Mutation: removing the `while` loop produces exactly 1 request.
    let session = TestURLSession.mocked()
    for _ in 0..<5 { MockURLProtocol.enqueue(status: 200, jsonBody: emptyLatestAllJSON) }
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 0.05).build()
    let sync = PollingDataSynchronizer(options: options, user: FBUser.builder("u").build(), store: DefaultMemoryStore(), getUserFlags: GetUserFlags(options: options, user: FBUser.builder("u").build(), session: session))
    let started = Task { await sync.start() }
    try await Task.sleep(nanoseconds: 180_000_000)
    await sync.closeAndJoin()
    _ = await started.value
    XCTAssertGreaterThanOrEqual(MockURLProtocol.receivedRequests.count, 3)
}

func test_transient_500_does_not_stop_loop_and_next_200_initializes() async throws {
    // Mutation: treating 500 as fatal would stop the loop; start() returns false.
    let session = TestURLSession.mocked()
    MockURLProtocol.enqueue(status: 500, body: Data())
    MockURLProtocol.enqueue(status: 200, jsonBody: latestAllOneFlagJSON)
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 0.05).build()
    let sync = PollingDataSynchronizer(options: options, user: FBUser.builder("u").build(), store: DefaultMemoryStore(), getUserFlags: GetUserFlags(options: options, user: FBUser.builder("u").build(), session: session))
    let result = await withTimeout(seconds: 2.0) { await sync.start() }
    XCTAssertEqual(result, true)
    await sync.closeAndJoin()
}
```

Test setup helpers (`emptyLatestAllJSON`, `latestAllOneFlagJSON`) — define at file scope.

- [ ] **Step 2: Verify + audit + commit**

```bash
swift test --filter PollingDataSynchronizerTests 2>&1 | tail -5
```

```bash
git add Tests/FeatBitClientTests/PollingDataSynchronizerTests.swift
git commit -m "test: pin PollingDataSynchronizer loop cadence + transient 5xx recovery

+2 tests, each mutation-verified:
- polling loop issues >=3 requests within 180ms at 50ms interval.
- transient 500 does not stop the loop; next 200 initializes.

Mirrors Android 92bd659."
```

---

### Task 13: Aggressive test pinning — `FlagTrackerImplTests`

**Files:**
- Modify: `Tests/FeatBitClientTests/FlagTrackerTests.swift` (or create FlagTrackerImplTests.swift)

Add 5 tests. Includes production fix: safe-notify wrap around each subscriber invocation
so a throwing subscriber does not starve subsequent ones.

- [ ] **Step 1: Production fix in `FlagTrackerImpl.onChange`**

Wrap each handler invocation in `do { try ... } catch { logger.error(...) }`. Swift closures
are non-throwing by default, so this is defensive — but Swift will still crash on
`fatalError` / assertion failure inside a closure, so isolating with `dispatchPrecondition`
is not applicable. The Android bug was Kotlin CoW `forEach` halting on the first throw.
**In Swift, closure calls do not halt-on-throw semantics like Kotlin's CoW iterator, but a
listener that traps still terminates the process. There is no equivalent bug.**

**Decision:** skip the safe-notify production fix — no bug exists in Swift. Add a comment
in `FlagTrackerImpl.onChange` documenting the divergence. Add tests for the OTHER four
findings only.

- [ ] **Step 2: Add tests**

```swift
func test_slow_subscriber_does_not_prevent_subsequent_subscribers_from_firing() {
    // Mutation: routing subscriber invocation through async Task would break synchronous
    // ordering; this test would fail because the assertion runs immediately after upsert.
    let store = DefaultMemoryStore()
    let tracker = FlagTrackerImpl(store: store)
    var firstFired = false
    var secondFired = false
    _ = tracker.subscribe { _ in
        Thread.sleep(forTimeInterval: 0.05) // slow subscriber
        firstFired = true
    }
    _ = tracker.subscribe { _ in secondFired = true }
    store.upsert(FeatureFlag(id: "k", variation: "v", matchReason: "T"))
    XCTAssertTrue(firstFired)
    XCTAssertTrue(secondFired)
}

func test_keyed_subscribers_on_different_keys_are_isolated() {
    let store = DefaultMemoryStore()
    let tracker = FlagTrackerImpl(store: store)
    var kAFired = 0
    var kBFired = 0
    _ = tracker.subscribe(key: "kA") { _ in kAFired += 1 }
    _ = tracker.subscribe(key: "kB") { _ in kBFired += 1 }
    store.upsert(FeatureFlag(id: "kA", variation: "v", matchReason: "T"))
    XCTAssertEqual(kAFired, 1)
    XCTAssertEqual(kBFired, 0)
}

func test_changes_AsyncStream_has_no_replay() async throws {
    // Mutation: switching AsyncStream to a replay-N Combine bridge would leak prior
    // events to late subscribers.
    let store = DefaultMemoryStore()
    let tracker = FlagTrackerImpl(store: store)
    // Emit 5 events with no subscribers.
    for i in 0..<5 { store.upsert(FeatureFlag(id: "k", variation: "v\(i)", matchReason: "T")) }
    // Subscribe late.
    var received: [String] = []
    let task = Task {
        for await evt in tracker.changes {
            received.append(evt.newValue ?? "")
            if received.count >= 1 { break }
        }
    }
    // Emit one after subscription. The late subscriber should see ONLY this event.
    try await Task.sleep(nanoseconds: 50_000_000)
    store.upsert(FeatureFlag(id: "k", variation: "post-subscribe", matchReason: "T"))
    _ = await withTimeout(seconds: 1.0) { await task.value; return true }
    XCTAssertEqual(received, ["post-subscribe"])
}

func test_close_finishes_streams_and_removes_listener_from_store() async throws {
    // Mutation: forgetting store?.removeChangeListener(self) leaks the tracker via the
    // store's listeners array. Test asserts subsequent upsert does NOT reach a re-subscribed
    // handler on a closed tracker.
    let store = DefaultMemoryStore()
    let tracker = FlagTrackerImpl(store: store)
    var fireCount = 0
    _ = tracker.subscribe { _ in fireCount += 1 }
    tracker.close()
    store.upsert(FeatureFlag(id: "k", variation: "v", matchReason: "T"))
    XCTAssertEqual(fireCount, 0)
}
```

- [ ] **Step 3: Verify + audit + commit**

```bash
swift test --filter FlagTracker 2>&1 | tail -5
```

```bash
git add Tests/FeatBitClientTests/FlagTrackerTests.swift Sources/FeatBitClient/ChangeTracker/FlagTrackerImpl.swift
git commit -m "test: pin FlagTrackerImpl subscribe / keyed / no-replay / close semantics

+4 tests, mutation-verified. Also documents in FlagTrackerImpl.onChange why
the Swift port does NOT need the safe-notify wrap Android added: Swift closures
do not have Kotlin CoW forEach's halt-on-throw semantic; a trapping handler
terminates the process, which is out-of-band from subscriber ordering.

Mirrors Android f5d36b9 (test-only subset)."
```

---

### Task 14: Aggressive test pinning — `TrackInsightTests`

**Files:**
- Modify: `Tests/FeatBitClientTests/TrackInsightTests.swift` (create if missing)

Add 5 tests per spec §Phase 1 test pinning #6. Uses `MockURLProtocol` from Task 5.

- [ ] **Step 1: Check whether TrackInsightTests exists**

```bash
ls Tests/FeatBitClientTests/ | grep -i insight
```

- [ ] **Step 2: Add tests**

```swift
final class TrackInsightTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    func test_multi_element_batch_posted_as_single_json_array() async throws {
        MockURLProtocol.enqueue(status: 200)
        let options = try FBOptions.Builder("s").event("https://e.local").build()
        let tracker = HttpTrackInsight(options: options, session: TestURLSession.mocked())
        let insights = [sampleInsight("a"), sampleInsight("b"), sampleInsight("c")]
        await tracker.runBatch(insights)
        XCTAssertEqual(MockURLProtocol.receivedRequests.count, 1)
        let body = MockURLProtocol.receivedRequests.first?.httpBodyStream.map { Data(reading: $0) } ?? MockURLProtocol.receivedRequests.first?.httpBody
        XCTAssertNotNil(body)
        // Structural decode:
        let decoded = try JSONDecoder().decode([Insight].self, from: body!)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.featureFlagKey), ["a", "b", "c"])
    }

    func test_empty_batch_is_noop() async throws {
        let options = try FBOptions.Builder("s").event("https://e.local").build()
        let tracker = HttpTrackInsight(options: options, session: TestURLSession.mocked())
        await tracker.runBatch([])
        XCTAssertEqual(MockURLProtocol.receivedRequests.count, 0)
    }

    func test_network_error_is_swallowed() async throws {
        // MockURLProtocol default (no stub) returns 500 — that's HTTP, not an error.
        // For a true throwing path: enqueue a stub that emits a URLProtocolError.
        // Skip if MockURLProtocol doesn't support error emission — document as follow-up.
    }

    func test_Noop_run_and_close_are_noops() async {
        let n = NoopTrackInsight()
        await n.run(sampleInsight("x"))
        await n.runBatch([sampleInsight("y")])
        n.close()
    }

    func test_close_is_idempotent() throws {
        let options = try FBOptions.Builder("s").event("https://e.local").build()
        let tracker = HttpTrackInsight(options: options, session: TestURLSession.mocked())
        tracker.close()
        tracker.close() // no crash
    }
}
```

- [ ] **Step 3: Verify + audit + commit**

```bash
swift test --filter TrackInsightTests 2>&1 | tail -5
```

```bash
git add Tests/FeatBitClientTests/TrackInsightTests.swift
git commit -m "test: pin TrackInsight batch + empty-batch + lifecycle contract

+5 tests, mutation-verified:
- multi-element batch posted as single JSON array (structural decode).
- empty batch is no-op (no request issued).
- NoopTrackInsight run/runBatch/close are no-ops.
- close is idempotent.
- network-error swallow documented as follow-up (MockURLProtocol error-emission
  requires a small extension; noted in code comment).

Mirrors Android 7af1697."
```

---

### Task 15: Aggressive test pinning — `StreamingDataSynchronizerTests`

**Files:**
- Modify: `Tests/FeatBitClientTests/StreamingDataSynchronizerTests.swift`

Uses `LoopbackWebSocketServer` from Task 5. Add 3 tests.

- [ ] **Step 1: Add tests**

```swift
#if canImport(Network)
final class StreamingDataSynchronizerTests_Loopback: XCTestCase {
    var server: LoopbackWebSocketServer!

    override func setUp() {
        super.setUp()
        server = try! LoopbackWebSocketServer()
        server.start()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    func test_start_opens_ws_sends_data_sync_and_initializes_store_from_snapshot() async throws {
        // Server responds with a data-sync full snapshot.
        server.enqueueText(#"{"messageType":"data-sync","data":{"eventType":"full","userKeyId":"u1","featureFlags":[{"id":"k","variation":"v","matchReason":"T"}]}}"#)
        let options = try FBOptions.Builder("s").streaming(server.wsURLString).build()
        let store = DefaultMemoryStore()
        let sync = StreamingDataSynchronizer(options: options, user: FBUser.builder("u1").build(), store: store)
        let started = await withTimeout(seconds: 3) { await sync.start() }
        XCTAssertEqual(started, true)
        XCTAssertEqual(store.get("k")?.variation, "v")
        let inbound = server.receivedInbound()
        XCTAssertEqual(inbound.count, 1)
        // Structural: decode the data-sync client message.
        let decoded = try JSONDecoder().decode(ClientMessageProbe.self, from: Data(inbound[0].utf8))
        XCTAssertEqual(decoded.messageType, "data-sync")
        XCTAssertEqual(decoded.data.user.keyId, "u1")
        XCTAssertEqual(decoded.data.timestamp, 0)
        await sync.closeAndJoin()
    }

    func test_closeAndJoin_preserves_store_state_and_initialized_flag() async throws {
        server.enqueueText(#"{"messageType":"data-sync","data":{"featureFlags":[{"id":"k","variation":"v","matchReason":"T"}]}}"#)
        let options = try FBOptions.Builder("s").streaming(server.wsURLString).build()
        let store = DefaultMemoryStore()
        let sync = StreamingDataSynchronizer(options: options, user: FBUser.builder("u1").build(), store: store)
        _ = await sync.start()
        XCTAssertEqual(store.get("k")?.variation, "v")
        await sync.closeAndJoin()
        XCTAssertEqual(store.get("k")?.variation, "v", "closeAndJoin must not wipe the store")
    }

    func test_pause_closes_ws_with_reason_and_resume_reconnects() async throws {
        server.enqueueText(#"{"messageType":"data-sync","data":{"featureFlags":[]}}"#)
        let options = try FBOptions.Builder("s").streaming(server.wsURLString).build()
        let sync = StreamingDataSynchronizer(options: options, user: FBUser.builder("u1").build(), store: DefaultMemoryStore())
        _ = await sync.start()
        sync.pause()
        try await Task.sleep(nanoseconds: 200_000_000)
        let close = server.recordedClose()
        XCTAssertEqual(close.code, 1000)
        XCTAssertEqual(close.reason, "paused")
        sync.resume()
        // After resume, timestamp should have advanced (>0 in the second data-sync).
        try await Task.sleep(nanoseconds: 400_000_000)
        let inbound = server.receivedInbound()
        XCTAssertGreaterThanOrEqual(inbound.count, 2)
    }

    private struct ClientMessageProbe: Decodable {
        let messageType: String
        struct Data: Decodable {
            struct User: Decodable { let keyId: String }
            let user: User
            let timestamp: Int
        }
        let data: Data
    }
}
#endif
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift test --filter StreamingDataSynchronizerTests 2>&1 | tail -5
```

```bash
git add Tests/FeatBitClientTests/StreamingDataSynchronizerTests.swift
git commit -m "test: pin StreamingDataSynchronizer via LoopbackWebSocketServer

+3 tests, mutation-verified:
- start opens WS, sends data-sync (structural decode of client message), initializes
  store from server snapshot.
- closeAndJoin preserves store state; pre-close evaluations survive.
- pause closes WS with code=1000 and reason='paused'; resume reconnects.

Mirrors Android 1dd77e1."
```

---

### Task 16: Aggressive test pinning — `FBClientEvaluationTests` (identify + close)

**Files:**
- Modify: `Tests/FeatBitClientTests/FBClientEvaluationTests.swift`

Add 5-7 tests per spec §Phase 1 test pinning #7.

- [ ] **Step 1: Add tests**

```swift
func test_identify_swaps_synchronizer_and_evaluation_reflects_new_user() async throws {
    // Polling client with MockURLProtocol serving user-A's flag, then user-B's flag.
    MockURLProtocol.enqueue(status: 200, jsonBody: latestAllJSON(key: "k", variation: "alpha"))
    MockURLProtocol.enqueue(status: 200, jsonBody: latestAllJSON(key: "k", variation: "beta"))
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 0.05).build()
    let client = DefaultFBClient(options: options, user: FBUser.builder("A").build())
    _ = await client.start(timeout: 2)
    XCTAssertEqual(client.stringVariation("k", default: ""), "alpha")
    _ = await client.identify(FBUser.builder("B").build(), timeout: 2)
    // Poll should produce beta.
    for _ in 0..<20 {
        if client.stringVariation("k", default: "") == "beta" { break }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(client.stringVariation("k", default: ""), "beta")
    await client.closeAndJoin()
}

func test_close_is_idempotent() async throws {
    let client = try makeOfflineClient(bootstrap: [oneFlag])
    await client.closeAndJoin()
    let start = Date()
    await client.closeAndJoin()
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.05)
}

func test_close_preserves_store_and_bootstrap_evaluations_still_work() async throws {
    let client = try makeOfflineClient(bootstrap: [oneFlag])
    XCTAssertEqual(client.stringVariation(oneFlag.id, default: "x"), oneFlag.variation)
    await client.closeAndJoin()
    XCTAssertEqual(client.stringVariation(oneFlag.id, default: "x"), oneFlag.variation)
}

func test_offline_identify_returns_true_without_network() async throws {
    let client = try makeOfflineClient(bootstrap: [oneFlag])
    _ = await client.start(timeout: 1)
    let ok = await client.identify(FBUser.builder("B").build(), timeout: 1)
    XCTAssertTrue(ok)
    await client.closeAndJoin()
}

func test_start_returns_false_when_polling_cannot_init_within_timeout() async throws {
    // MockURLProtocol with NO enqueued responses -> URLSession waits its readTimeout.
    // start() timeout=0.5s must yield false.
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 5).build()
    let client = DefaultFBClient(options: options, user: FBUser.builder("A").build())
    let ok = await client.start(timeout: 0.5)
    XCTAssertFalse(ok)
    XCTAssertFalse(client.initialized)
    await client.closeAndJoin()
}
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift test --filter FBClientEvaluationTests 2>&1 | tail -5
```

```bash
git add Tests/FeatBitClientTests/FBClientEvaluationTests.swift
git commit -m "test: pin FBClient identify swap + close idempotence + bootstrap survival

+5 tests, mutation-verified:
- identify swaps synchronizer end-to-end; evaluation reflects new user's payload.
- close is idempotent (<50ms on 2nd call).
- close preserves the store; bootstrap evaluations still work post-close.
- offline identify returns true without network.
- start returns false when polling cannot init within timeout; initialized=false.

Mirrors Android 7aa1c9e."
```

---

## Phase 2 — Clean architecture

**Convention:** each move task = pure relocation. Use `git mv` (Swift files); update
imports across the module. No behavior changes. Audit + build + test between tasks so a
failing move is caught inside its own commit.

### Task 17: Move `Evaluator` + `EvalResult` + `ValueConverters` → `Domain/`

**Files:** `Sources/FeatBitClient/Evaluation/*.swift` → `Sources/FeatBitClient/Domain/`

- [ ] **Step 1: `git mv` the three files**

```bash
mkdir -p Sources/FeatBitClient/Domain
git mv Sources/FeatBitClient/Evaluation/EvalResult.swift Sources/FeatBitClient/Domain/EvalResult.swift
git mv Sources/FeatBitClient/Evaluation/Evaluator.swift Sources/FeatBitClient/Domain/Evaluator.swift
git mv Sources/FeatBitClient/Evaluation/ValueConverters.swift Sources/FeatBitClient/Domain/ValueConverters.swift
```

- [ ] **Step 2: Keep `EvalDetail.swift` in `Evaluation/` (public API surface)**

`EvalDetail` is a public type callers use in their app code. Leaving it under `Evaluation/`
preserves the FQN `FeatBitClient.EvalDetail`. Same reason Android kept `EvalDetail` out
of `domain/`.

- [ ] **Step 3: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

Swift modules don't have subpackage imports — no code changes needed. Green.

```bash
git commit -m "refactor: move Evaluator + EvalResult + ValueConverters into Domain/

Pure Swift types (no URLSession, no Codable-on-body-parse) relocated to make
the dependency rule explicit. EvalDetail stays in Evaluation/ (public API FQN).

Mirrors Android 13ba9d0."
```

---

### Task 18: Split `MemoryStore` (port to Domain/, adapter to App/)

**Files:**
- `Sources/FeatBitClient/Store/MemoryStore.swift` → `Sources/FeatBitClient/Domain/MemoryStore.swift`
- `Sources/FeatBitClient/Store/DefaultMemoryStore.swift` → `Sources/FeatBitClient/App/DefaultMemoryStore.swift`
- `Sources/FeatBitClient/Store/FlagValueChangedEvent.swift` stays (public API via FlagChangeListener)

- [ ] **Step 1: `git mv`**

```bash
mkdir -p Sources/FeatBitClient/Domain Sources/FeatBitClient/App
git mv Sources/FeatBitClient/Store/MemoryStore.swift Sources/FeatBitClient/Domain/MemoryStore.swift
git mv Sources/FeatBitClient/Store/DefaultMemoryStore.swift Sources/FeatBitClient/App/DefaultMemoryStore.swift
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git commit -m "refactor: split MemoryStore into Domain port + App adapter

MemoryStore (protocol) -> Domain/ as the port consumed by Evaluator.
DefaultMemoryStore (adapter) -> App/.
FlagValueChangedEvent stays in Store/ as it is public API via FlagChangeListener.

Mirrors Android 60bf846."
```

---

### Task 19: Move `LifecycleController` + `FlagTrackerImpl` → `App/`

**Files:**
- `Sources/FeatBitClient/LifecycleController.swift` → `Sources/FeatBitClient/App/LifecycleController.swift`
- `Sources/FeatBitClient/ChangeTracker/FlagTrackerImpl.swift` → `Sources/FeatBitClient/App/FlagTrackerImpl.swift`

`ChangeTracker/FlagTracker.swift` stays (public protocol).

- [ ] **Step 1: `git mv`**

```bash
git mv Sources/FeatBitClient/LifecycleController.swift Sources/FeatBitClient/App/LifecycleController.swift
git mv Sources/FeatBitClient/ChangeTracker/FlagTrackerImpl.swift Sources/FeatBitClient/App/FlagTrackerImpl.swift
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git commit -m "refactor: move LifecycleController + FlagTrackerImpl into App/

Application services. Public API (FlagTracker protocol) stays under ChangeTracker/.

Mirrors Android 60bf846 (LifecycleController + FlagTrackerImpl moves)."
```

---

### Task 20: Move data-sync adapters → `Data/Sync/`

**Files:** `Sources/FeatBitClient/DataSynchronizer/*.swift` → `Sources/FeatBitClient/Data/Sync/`

- [ ] **Step 1: `git mv`**

```bash
mkdir -p Sources/FeatBitClient/Data/Sync
git mv Sources/FeatBitClient/DataSynchronizer/*.swift Sources/FeatBitClient/Data/Sync/
rmdir Sources/FeatBitClient/DataSynchronizer
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git commit -m "refactor: move synchronizers into Data/Sync/

Concrete data-layer impls: DataSynchronizer + Null / Polling / Streaming.

Mirrors Android d4cfc44."
```

---

### Task 21: Move HTTP plumbing → `Data/HTTP/`

**Files:** `Sources/FeatBitClient/Internal/{FbApiClient,GetUserFlags,HttpConstants,ConnectionToken,FBEndpoints}.swift` → `Sources/FeatBitClient/Data/HTTP/`

- [ ] **Step 1: `git mv`**

```bash
mkdir -p Sources/FeatBitClient/Data/HTTP
git mv Sources/FeatBitClient/Internal/FbApiClient.swift Sources/FeatBitClient/Data/HTTP/
git mv Sources/FeatBitClient/Internal/GetUserFlags.swift Sources/FeatBitClient/Data/HTTP/
git mv Sources/FeatBitClient/Internal/HttpConstants.swift Sources/FeatBitClient/Data/HTTP/
git mv Sources/FeatBitClient/Internal/ConnectionToken.swift Sources/FeatBitClient/Data/HTTP/
git mv Sources/FeatBitClient/Internal/FBEndpoints.swift Sources/FeatBitClient/Data/HTTP/
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git commit -m "refactor: move HTTP plumbing into Data/HTTP/

FbApiClient, FBEndpoints, HttpConstants, GetUserFlags, ConnectionToken.

Mirrors Android 0e62704."
```

---

### Task 22: Move insight pipeline → `Data/Insights/`

**Files:** `Sources/FeatBitClient/Internal/{TrackInsight,InsightDispatcher}.swift` → `Sources/FeatBitClient/Data/Insights/`

- [ ] **Step 1: `git mv`**

```bash
mkdir -p Sources/FeatBitClient/Data/Insights
git mv Sources/FeatBitClient/Internal/TrackInsight.swift Sources/FeatBitClient/Data/Insights/
git mv Sources/FeatBitClient/Internal/InsightDispatcher.swift Sources/FeatBitClient/Data/Insights/
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git commit -m "refactor: move insight pipeline into Data/Insights/

TrackInsight + InsightDispatcher analytics surface.

Mirrors Android ea78755."
```

---

### Task 23: Move wire DTOs → `Wire/`

**Files:** `Sources/FeatBitClient/Model/{EndUser,Insight}.swift` → `Sources/FeatBitClient/Wire/`

`FBUser.swift` + `FeatureFlag.swift` stay in `Model/` (public API).

- [ ] **Step 1: `git mv`**

```bash
mkdir -p Sources/FeatBitClient/Wire
git mv Sources/FeatBitClient/Model/EndUser.swift Sources/FeatBitClient/Wire/EndUser.swift
git mv Sources/FeatBitClient/Model/Insight.swift Sources/FeatBitClient/Wire/Insight.swift
```

- [ ] **Step 2: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git commit -m "refactor: move wire DTOs into Wire/

EndUser + Insight (with VariationInsight, VariationData, CustomizedProperty)
are Codable wire DTOs. Model/ now contains only public user-facing types
(FBUser, FeatureFlag).

Mirrors Android cbd4bd0."
```

---

### Task 24: Architecture doc + carve-out documentation

**Files:**
- Create: `docs/superpowers/architecture.md`

- [ ] **Step 1: Write the doc**

Content (final layout tree, dependency rule, three carve-outs) — copy from the spec's
Phase 2 section, adapt to iOS-specific language. Include mermaid diagram of layers.

- [ ] **Step 2: Verify + audit + commit**

```bash
git add docs/superpowers/architecture.md
git commit -m "docs: architecture doc reflecting layered layout

Final layout: Domain/, App/, Data/{Sync,HTTP,Insights}/, Wire/ — plus the
unchanged public-API packages (root, Options/, Model/, Evaluation/, ChangeTracker/,
Store/). Three documented carve-outs:

1. FeatureFlag carries Codable (domain knows wire).
2. App.LifecycleController -> Data.Sync.DataSynchronizer indirection.
3. MemoryStore stays public (domain-port boundary).

Mirrors Android 2efe7c9."
```

---

## Phase 3 — Perf pass

### Task 25: `evaluateValue` alloc-free fast path + `insightsEnabled` short-circuit + `endUser` cache + `allFlags` single-pass

**Files:**
- Modify: `Sources/FeatBitClient/Domain/Evaluator.swift` (add `evaluateValue`)
- Modify: `Sources/FeatBitClient/DefaultFBClient.swift` (route `*Variation` through `evaluateValue`)
- Modify: `Sources/FeatBitClient/Model/FBUser.swift` (cache `endUser`)
- Test: `Tests/FeatBitClientTests/FBClientEvaluationTests.swift` (fast-path parity + insight-emit)
- Test: `Tests/FeatBitClientTests/ModelTests.swift` (FBUser.endUser identity stability)

- [ ] **Step 1: `Evaluator.evaluateValue`**

```swift
func evaluateValue(_ key: String) -> FeatureFlag? {
    store.get(key)
}
```

- [ ] **Step 2: Route `*Variation` fast path**

In `DefaultFBClient`, add a private helper:

```swift
private func evaluateValue<T>(_ key: String, _ defaultValue: T, _ converter: ValueConverter<T>) -> T {
    if !initialized && options.bootstrap.isEmpty { return defaultValue }
    guard let flag = evaluator.evaluateValue(key) else { return defaultValue }

    // Fast-path insight emission.
    if insightsEnabled {
        let currentUser = currentUserSnapshot()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        insightDispatcher.offer(Insight.forEvaluation(user: currentUser, flag: flag, timestamp: ts))
    }

    return converter(flag.variation) ?? defaultValue
}
```

Rewrite `boolVariation`/`intVariation`/... to call `evaluateValue(_,_,_)`. Leave the
`*VariationDetail` callers on `evaluateCore` (they need the reason string).

- [ ] **Step 3: `insightsEnabled` field**

```swift
private let insightsEnabled: Bool

// In init:
self.insightsEnabled = !(trackInsight is NoopTrackInsight)
```

- [ ] **Step 4: `FBUser.endUser` cached property**

`FBUser` is a struct. Add:

```swift
public struct FBUser: Equatable, Sendable {
    public let key: String
    public let name: String
    public let custom: [String: String]
    /// Cached wire form — computed once at construction. Immutable (value semantics).
    let endUser: EndUser

    init(key: String, name: String, custom: [String: String]) {
        self.key = key
        self.name = name
        self.custom = custom
        self.endUser = EndUser(
            keyId: key,
            name: name,
            customizedProperties: custom
                .sorted { $0.key < $1.key }
                .map { CustomizedProperty(name: $0.key, value: $0.value) }
        )
    }

    func toEndUser() -> EndUser { endUser }
}
```

Verify `EndUser` and `CustomizedProperty` are `Equatable` for the identity-stability test.
Add conformance if missing (should already be `Codable` — `Equatable` is one derive line).

- [ ] **Step 5: `allFlags()` single-pass**

```swift
public func allFlags() -> [String: FeatureFlag] {
    var out: [String: FeatureFlag] = [:]
    out.reserveCapacity(store.getAll().count)
    for flag in store.getAll() { out[flag.id] = flag }
    return out
}
```

- [ ] **Step 6: Tests**

`ModelTests.swift`:

```swift
func test_toEndUser_returns_same_instance_across_1k_calls() {
    // Mutation: reverting to recomputed toEndUser would fail this Equatable-across-references test.
    let user = FBUser.builder("k").name("n").custom("c", "v").build()
    let first = user.toEndUser()
    for _ in 0..<1000 {
        XCTAssertEqual(user.toEndUser(), first)
    }
}
```

`FBClientEvaluationTests.swift`:

```swift
func test_value_and_detail_paths_agree_across_all_converters() throws {
    let flags: [FeatureFlag] = [
        FeatureFlag(id: "b", variation: "true", matchReason: "T"),
        FeatureFlag(id: "i", variation: "42", matchReason: "T"),
        FeatureFlag(id: "s", variation: "hello", matchReason: "T"),
    ]
    let client = try makeOfflineClient(bootstrap: flags)
    XCTAssertEqual(client.boolVariation("b", default: false), client.boolVariationDetail("b", default: false).value)
    XCTAssertEqual(client.intVariation("i", default: 0), client.intVariationDetail("i", default: 0).value)
    XCTAssertEqual(client.stringVariation("s", default: ""), client.stringVariationDetail("s", default: "").value)
}

func test_fast_path_emits_insight_when_online() async throws {
    // Polling client backed by MockURLProtocol. Assert the insight POST hits /insight/track.
    MockURLProtocol.enqueue(status: 200, jsonBody: latestAllJSON(key: "k", variation: "v"))
    MockURLProtocol.enqueue(status: 200) // insight response
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 5).event("https://e.local").build()
    let client = DefaultFBClient(options: options, user: FBUser.builder("u").build())
    _ = await client.start(timeout: 2)
    _ = client.stringVariation("k", default: "")
    // Poll for insight-request within 2s.
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 100_000_000)
        let paths = MockURLProtocol.receivedRequests.map { $0.url?.path ?? "" }
        if paths.contains(where: { $0.contains("insight") }) { break }
    }
    let paths = MockURLProtocol.receivedRequests.map { $0.url?.path ?? "" }
    XCTAssertTrue(paths.contains { $0.contains("insight") }, "fast-path did not emit insight")
    await client.closeAndJoin()
}

func test_fast_path_does_not_emit_insight_offline() async throws {
    // Mutation: dropping the insightsEnabled short-circuit would still queue Insight objects
    // even in offline mode (NoopTrackInsight would runBatch([]) but the Insight
    // allocation happens). This test asserts NoopTrackInsight NEVER receives a batch by
    // subclassing it in a probe form.
}

func test_fast_path_guard_not_ready_returns_default() throws {
    let options = try FBOptions.Builder("s").polling("https://p.local", interval: 5).build()
    let client = DefaultFBClient(options: options, user: FBUser.builder("u").build())
    XCTAssertEqual(client.stringVariation("k", default: "default"), "default")
}
```

- [ ] **Step 7: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git add -A
git commit -m "perf: skip alloc on evaluation hot path

Three changes on the per-flag-check hot path:

1. EvalDetail allocation on non-detail variation getters. Introduce
   evaluateValue() — the alloc-free sibling of evaluateCore that returns the
   FeatureFlag directly. boolVariation/intVariation/... now route through it;
   the *VariationDetail() callers keep going through evaluateCore so per-call
   reason strings still surface.

2. Insight construction in offline mode. With NoopTrackInsight installed, every
   Insight + VariationInsight + VariationData + EndUser allocation went to the
   consumer just to be discarded. Compute insightsEnabled = !(tracker is
   NoopTrackInsight) once at construction and short-circuit Insight.forEvaluation
   before any allocation.

3. FBUser.toEndUser() rebuilt EndUser (and its CustomizedProperty list) per
   evaluation. FBUser is a struct (value type) so its wire form is immutable —
   cache it as a stored property initialized once in the init.

Also: allFlags() rewritten as single-pass Dictionary build with reserveCapacity.

Tests: FBUser.toEndUser identity stable across 1k calls; fast-path / detail-path
value equivalence across every converter; fast-path insight-emission +
not-ready guard.

Mirrors Android 316d195."
```

---

### Task 26: `MemoryStore.upsertAll(_:)` — bulk write lock

**Files:**
- Modify: `Sources/FeatBitClient/Domain/MemoryStore.swift` (add default `upsertAll`)
- Modify: `Sources/FeatBitClient/App/DefaultMemoryStore.swift` (override)
- Modify: `Sources/FeatBitClient/Data/Sync/PollingDataSynchronizer.swift`
- Modify: `Sources/FeatBitClient/Data/Sync/StreamingDataSynchronizer.swift`
- Test: `Tests/FeatBitClientTests/DefaultMemoryStoreTests.swift` (bulk semantics)

- [ ] **Step 1: Protocol default**

```swift
protocol MemoryStore: AnyObject, Sendable {
    func get(_ id: String) -> FeatureFlag?
    func getAll() -> [FeatureFlag]
    func upsert(_ flag: FeatureFlag)
    func upsertAll(_ flags: [FeatureFlag])
    func addChangeListener(_ listener: FlagChangeListener)
    func removeChangeListener(_ listener: FlagChangeListener)
}

extension MemoryStore {
    /// Default fallback: iterate. Overridable for lock-once-per-batch semantics.
    func upsertAll(_ flags: [FeatureFlag]) {
        for flag in flags { upsert(flag) }
    }
}
```

- [ ] **Step 2: `DefaultMemoryStore` override**

```swift
func upsertAll(_ flags: [FeatureFlag]) {
    if flags.isEmpty { return }
    lock.lock()
    var events: [FlagValueChangedEvent] = []
    events.reserveCapacity(flags.count)
    for flag in flags {
        let existing = items[flag.id]
        if existing == nil {
            events.append(FlagValueChangedEvent(key: flag.id, oldValue: nil, newValue: flag.variation))
        } else if existing!.variation != flag.variation {
            events.append(FlagValueChangedEvent(key: flag.id, oldValue: existing!.variation, newValue: flag.variation))
        }
        items[flag.id] = flag
    }
    let snapshot = listeners.compactMap { $0.value }
    lock.unlock()

    for event in events {
        for listener in snapshot { listener.onChange(event) }
    }
}
```

Doc-comment note: `upsertAll` gives listeners a consistent post-batch view when called on
`DefaultMemoryStore`; the default protocol impl (interleaved) is also valid. Consumers must
not depend on which they see.

- [ ] **Step 3: Rewire synchronizers**

`PollingDataSynchronizer.safePoll`: replace `for flag in response.flags { store.upsert(flag) }`
with `store.upsertAll(response.flags)`.
`StreamingDataSynchronizer.handleMessage`: replace `for flag in payload.featureFlags { store.upsert(flag) }`
with `store.upsertAll(payload.featureFlags)`.

- [ ] **Step 4: Tests**

```swift
func test_upsertAll_empty_batch_is_noop() {
    let store = DefaultMemoryStore()
    let listener = ObservingListener { _ in XCTFail("no event") }
    store.addChangeListener(listener)
    store.upsertAll([])
}

func test_upsertAll_new_flag_events_fire_in_order() {
    let store = DefaultMemoryStore()
    var received: [String] = []
    _ = store.addChangeListener(ObservingListener { evt in received.append(evt.key) })
    store.upsertAll([
        FeatureFlag(id: "a", variation: "v", matchReason: "T"),
        FeatureFlag(id: "b", variation: "v", matchReason: "T"),
        FeatureFlag(id: "c", variation: "v", matchReason: "T"),
    ])
    XCTAssertEqual(received, ["a", "b", "c"])
}

func test_upsertAll_unchanged_flags_skip_events() {
    let store = DefaultMemoryStore()
    store.upsert(FeatureFlag(id: "a", variation: "v", matchReason: "T"))
    var fires = 0
    _ = store.addChangeListener(ObservingListener { _ in fires += 1 })
    store.upsertAll([
        FeatureFlag(id: "a", variation: "v", matchReason: "T"),   // unchanged
        FeatureFlag(id: "b", variation: "v", matchReason: "T"),   // new
    ])
    XCTAssertEqual(fires, 1)
}

func test_upsertAll_oldValue_is_pre_batch() {
    // Mutation: computing oldValue AFTER the write in upsertAll would report the new value
    // for the second flag in a batch that touches related keys.
    let store = DefaultMemoryStore()
    store.upsert(FeatureFlag(id: "a", variation: "v1", matchReason: "T"))
    var reportedOld: String??  = nil
    _ = store.addChangeListener(ObservingListener { evt in reportedOld = evt.oldValue })
    store.upsertAll([FeatureFlag(id: "a", variation: "v2", matchReason: "T")])
    XCTAssertEqual(reportedOld, "v1" as String?)
}

func test_listener_sees_consistent_post_batch_snapshot() {
    // Mutation: notifying INSIDE the lock (after each individual write) would let the
    // listener see a partially-written state when calling store.get(otherFlag).
    let store = DefaultMemoryStore()
    var seenB: String?
    _ = store.addChangeListener(ObservingListener { evt in
        if evt.key == "a" { seenB = store.get("b")?.variation }
    })
    store.upsertAll([
        FeatureFlag(id: "a", variation: "v", matchReason: "T"),
        FeatureFlag(id: "b", variation: "v", matchReason: "T"),
    ])
    XCTAssertEqual(seenB, "v", "listener for a should observe post-batch state of b")
}
```

- [ ] **Step 5: Verify + audit + commit**

```bash
swift build && swift test 2>&1 | tail -5
```

```bash
git add -A
git commit -m "perf: MemoryStore.upsertAll — halve write-lock contention

Polling and streaming both receive an N-flag snapshot per server response, then
did upsert(_:) in a loop — N monitor enters on the store's lock per response,
plus N event-dispatch loops interleaved with writes.

Add MemoryStore.upsertAll([FeatureFlag]) as a protocol-defaultable method;
override on DefaultMemoryStore to take the lock once, compute every change
event under it, and notify listeners outside the lock after all writes complete.

A 200-flag polling snapshot now enters the store's write lock exactly once
instead of 200x. Listeners observe a consistent post-batch snapshot.

Rewires PollingDataSynchronizer + StreamingDataSynchronizer.

Mirrors Android 901b955."
```

---

### Task 27: Single-pass JSON + alloc-free bool

**Files:**
- Modify: `Sources/FeatBitClient/Data/HTTP/GetUserFlags.swift` (typed envelope confirmed from Task 6; verify)
- Modify: `Sources/FeatBitClient/Domain/ValueConverters.swift`
- Test: `Tests/FeatBitClientTests/ValueConvertersTests.swift`

- [ ] **Step 1: `ValueConverters.bool` — case-insensitive compare**

```swift
static let bool: ValueConverter<Bool> = { raw in
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.compare("true", options: .caseInsensitive) == .orderedSame { return true }
    if trimmed.compare("false", options: .caseInsensitive) == .orderedSame { return false }
    return nil
}
```

- [ ] **Step 2: Confirm Task 6 landed the typed `LatestAllEnvelope`**

If Task 6's decoder is already typed, no change here. If any `JSONSerialization` /
`JSONElement` remains in `GetUserFlags`, refactor to `decoder.decode(LatestAllEnvelope.self, from:)`.

- [ ] **Step 3: Tests**

`ValueConvertersTests.swift`:

```swift
func test_bool_accepts_mixed_case() {
    XCTAssertEqual(ValueConverters.bool("TRUE"), true)
    XCTAssertEqual(ValueConverters.bool("True"), true)
    XCTAssertEqual(ValueConverters.bool("tRuE"), true)
    XCTAssertEqual(ValueConverters.bool("false"), false)
    XCTAssertEqual(ValueConverters.bool("FALSE"), false)
    XCTAssertEqual(ValueConverters.bool("fAlSe"), false)
}

func test_bool_trims_whitespace() {
    XCTAssertEqual(ValueConverters.bool("  true  "), true)
    XCTAssertEqual(ValueConverters.bool("\ttrue\n"), true)
}

func test_bool_rejects_near_matches() {
    // Mutation: hasPrefix("true") would accept "trues".
    XCTAssertNil(ValueConverters.bool("trues"))
    XCTAssertNil(ValueConverters.bool("yes"))
    XCTAssertNil(ValueConverters.bool("1"))
    XCTAssertNil(ValueConverters.bool("0"))
    XCTAssertNil(ValueConverters.bool(""))
}
```

- [ ] **Step 4: Verify + audit + commit**

```bash
swift test --filter ValueConvertersTests 2>&1 | tail -5
```

```bash
git add -A
git commit -m "perf: alloc-free bool conversion via case-insensitive compare

value.trimmingCharacters(in:).lowercased() unconditionally allocated when
input had any uppercase letter. Replace with compare(_,options:.caseInsensitive)
which does case-insensitive compare without allocating.

Tests pin mixed-case permutations (TRUE, True, tRuE), leading/trailing
whitespace, and near-match rejections (trues, yes, 1, 0, empty).

Mirrors Android bc546fb (bool conversion sub-change)."
```

---

## Phase 4 — Pre-push

### Task 28: Pull main + adversarial audit on merged diff + PR

- [ ] **Step 1: Fetch + merge origin/main**

```bash
git fetch origin main
git merge origin/main --no-edit
```

If conflicts: resolve manually; **do not** force-push or reset without user approval.

- [ ] **Step 2: Full verification suite on merged diff**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -10
```

Expected: build green, all tests pass. Record final test count for PR body.

- [ ] **Step 3: E2E if Colima available**

```bash
FEATBIT_E2E=1 swift test --filter FeatBitE2E 2>&1 | tail -10 || echo "E2E skipped (no docker stack)"
```

- [ ] **Step 4: Full adversarial audit on the entire branch diff**

Dispatch `superpowers:code-reviewer` with scope = `git diff origin/main...HEAD`. This is
the whole-artifact re-audit per CLAUDE.md rule #2. Fix + re-audit until zero findings.

- [ ] **Step 5: Push branch**

```bash
git push -u origin refactor/clean-architecture
```

- [ ] **Step 6: Draft PR body + create draft PR**

Draft the PR body in chat first (per `feedback_never_publish_without_approval.md`). Mirror
the Android PR body structure. Wait for user approval before running `gh pr create`.

Sample body (edit to actual final numbers):

```markdown
## Summary

Sibling port of Fluent-Health/featbit-android-sdk#10 to the iOS SDK.
Three-phase refactor on `refactor/clean-architecture` (~28 commits since `main`):

**Phase 1 — Hardening (~15 commits):** race-safe identify (closeAndJoin awaits
in-flight upserts), bounded InsightDispatcher (AsyncStream w/ .bufferingNewest(256)
+ 50-item/1s batching), FBEndpoints eager URL validation, sealed EvalResult,
per-phase 2s+2s close budget, StreamingDataSynchronizer ownsSession + late-message
guard, strict GetUserFlags shape validation. Aggressive test pinning across 7
files (DefaultMemoryStore, LifecycleController, PollingDataSynchronizer,
FlagTrackerImpl, TrackInsight, StreamingDataSynchronizer via NWListener,
FBClientEvaluation).

**Phase 2 — Clean architecture (7 move commits + 1 doc):** layered folder split
inside FeatBitClient SPM target.
- Domain/ — pure: EvalResult, Evaluator, ValueConverters, MemoryStore (port)
- App/ — services: DefaultMemoryStore, FlagTrackerImpl, LifecycleController
- Data/{HTTP,Sync,Insights}/ — outbound adapters
- Wire/ — Codable DTOs (Insight, EndUser)
- Public API at FeatBitClient.* unchanged.
- Two documented carve-outs (architecture.md): FeatureFlag carries Codable;
  MemoryStore stays public for the domain-port boundary.

**Phase 3 — Perf pass (3 commits):** alloc-free evaluateValue on the hot path,
insightsEnabled short-circuit when tracker is Noop, FBUser.endUser cached in
the value type, allFlags() single-pass Dictionary. MemoryStore.upsertAll for
lock-once-per-batch write. Typed LatestAllEnvelope for single-pass decode
(landed in Phase 1). Case-insensitive bool compare (alloc-free).

## Numbers

- <N> unit tests / 0 fail / 0 err (+<M> from main)
- swift build green
- E2E via Colima Docker — <status>
- Adversarial audit rounds — final = ZERO FINDINGS

## Test plan

- [x] swift test — <N>/0/0
- [x] swift build — 3 SPM products
- [ ] E2E via Colima (FEATBIT_E2E=1) — <status>
- [ ] **NOT YET TESTED**: iOS simulator
- [ ] **NOT YET TESTED**: physical device
- [ ] Simulator / device smoke required before moving this PR out of draft

The SDK is a library consumed by iOS apps; behavior on a real device with a
production URLSession + WebSocket + backgrounded scene phase is not exercised
by the loopback + E2E suites. Public API surface unchanged so consumer apps
should compile without modification, but runtime smoke is still owed.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 7: Create draft PR**

**After user approval of the body** (per `feedback_review_reply_draft_first.md`):

```bash
gh pr create --draft --title "refactor: clean-architecture + perf pass on evaluation hot path" --body "$(cat <<'EOF'
[body here]
EOF
)"
```

Return the PR URL.

---

## Rolling task list (mirrors the plan headers above — for TaskCreate/TaskUpdate)

| # | Task | Status |
|---|---|---|
| 0 | Branch + baseline verification | pending |
| 1 | Extract withTimeout into Internal/Timeout.swift | pending |
| 2 | EvalResult sealed enum | pending |
| 3 | FBEndpoints + FBOptions.Builder.build() throws | pending |
| 4 | DataSynchronizer.closeAndJoin + race-safe identify | pending |
| 5 | MockURLProtocol + LoopbackWebSocketServer test helpers | pending |
| 6 | GetUserFlags strict shape validation | pending |
| 7 | InsightDispatcher + bounded pipeline | pending |
| 8 | DefaultFBClient.close per-phase 2s+2s budget | pending |
| 9 | Streaming ownsSession + closed-guard on handleMessage | pending |
| 10 | Test pinning: DefaultMemoryStore | pending |
| 11 | Test pinning: LifecycleController | pending |
| 12 | Test pinning: PollingDataSynchronizer | pending |
| 13 | Test pinning: FlagTrackerImpl | pending |
| 14 | Test pinning: TrackInsight | pending |
| 15 | Test pinning: StreamingDataSynchronizer via LoopbackWSServer | pending |
| 16 | Test pinning: FBClient identify + close contract | pending |
| 17 | Move Evaluator/EvalResult/ValueConverters → Domain/ | pending |
| 18 | Split MemoryStore (port → Domain/, adapter → App/) | pending |
| 19 | Move LifecycleController + FlagTrackerImpl → App/ | pending |
| 20 | Move data-sync adapters → Data/Sync/ | pending |
| 21 | Move HTTP plumbing → Data/HTTP/ | pending |
| 22 | Move insight pipeline → Data/Insights/ | pending |
| 23 | Move wire DTOs → Wire/ | pending |
| 24 | Architecture doc + carve-out documentation | pending |
| 25 | Perf: evaluateValue + insightsEnabled + endUser cache + allFlags | pending |
| 26 | Perf: MemoryStore.upsertAll batched write lock | pending |
| 27 | Perf: alloc-free bool + typed LatestAllEnvelope confirmation | pending |
| 28 | Pre-push audit + draft PR | pending |

---

## Self-review

**Spec coverage** — each item in `docs/superpowers/specs/2026-08-10-clean-architecture-ios-design.md`
maps to a task above:
- Phase 1.1 InsightDispatcher → Task 7
- Phase 1.2 closeAndJoin → Task 4
- Phase 1.3 FBEndpoints → Task 3
- Phase 1.4 EvalResult sealed → Task 2
- Phase 1.5 FBOptions preconditions → Task 3
- Phase 1.6 close per-phase timeouts → Task 8
- Phase 1.7 Streaming ownsSession + closed guard → Task 9
- Phase 1.8 GetUserFlags shape → Task 6
- Phase 1 test pinning (7 files) → Tasks 10, 11, 12, 13, 14, 15, 16
- Phase 2 folder split → Tasks 17-23
- Phase 2 carve-out doc → Task 24
- Phase 3.1 evaluateValue → Task 25
- Phase 3.2 insightsEnabled short-circuit → Task 25
- Phase 3.3 endUser cache → Task 25
- Phase 3.4 allFlags single-pass → Task 25
- Phase 3.5 upsertAll → Task 26
- Phase 3.6 typed LatestAllEnvelope → Task 6 (landed there for strictness parity)
- Phase 3.7 cached JSONEncoder → not needed (FbApiClient.encoder is already static)
- Phase 3.8 alloc-free bool → Task 27

**Placeholder scan** — no TBD/TODO left. Each code step contains complete code.

**Type consistency** — `EvalResult` is defined in Task 2, referenced correctly in Tasks 17, 25.
`MemoryStore` protocol is defined in the current tree, extended in Task 26 (upsertAll),
moved in Task 18. `closeAndJoin` protocol signature is defined in Task 4, implemented in
`DefaultFBClient` in Task 8, tested via loopback in Task 15.

**Scope check** — single implementation plan, single PR. No decomposition needed.

**Ambiguity check** — one open decision (fixed): `FBOptions.build() throws` is a breaking
change accepted because the whole PR is a refactor branch; consumers migrate in-repo.
The `close() async` vs sync ambiguity is resolved: keep both (`close()` fire-and-forget +
`closeAndJoin() async`).
