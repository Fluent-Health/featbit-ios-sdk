# CLAUDE.md — agent orientation for featbit-ios-sdk

You are continuing work on the **FeatBit client-side feature-flag SDK for Swift/iOS**. Read
[`HANDOVER.md`](./HANDOVER.md) first — it is the source of truth for what's done, what's left, and
how to verify. This file is the quick orientation + guardrails.

## What this is

A Swift Package port of [`Fluent-Health/featbit-android-sdk`](https://github.com/Fluent-Health/featbit-android-sdk)
(Kotlin) — itself a port of FeatBit's .NET + React Native client SDKs. It must speak the **exact
same wire protocol** as the Android SDK and FeatBit server so they interoperate. Three products:
`FeatBitClient` (core, UI-agnostic), `FeatBitSwiftUI`, `FeatBitLifecycle`.

The package was built on Linux; the core is unit-tested there. **Your job (on a Mac) is to verify
and finish the Apple-only parts** — see the HANDOVER checklist.

## Run / verify loop

```bash
swift build            # all targets
swift test             # full unit suite — expect "0 failures"; E2E auto-skips without FEATBIT_E2E
swift test --filter <ClassName>          # a subset
FEATBIT_E2E=1 swift test --filter E2E    # full-stack E2E (needs Docker)
```

"Done" for a task = the relevant `swift test` / `xcodebuild` is green and you can state the command
+ output. Do not claim a runtime behavior works unless you actually exercised it.

## Guardrails (do not violate)

- **Wire compatibility is sacred.** Do not change JSON field names/shapes, the connection-token
  algorithm, or the streaming/polling/insight endpoints without matching the Android SDK and the
  FeatBit server. `ConnectionTokenTests` pins exact token bytes — if it fails, you broke compat.
  The contract is documented in `HANDOVER.md` ("Wire-protocol contract") and in the source
  (`Sources/FeatBitClient/Internal/ConnectionToken.swift`, `DataSynchronizer/*`).
- **Keep the platform guards.** Apple-only code is wrapped in `#if canImport(Darwin/UIKit/Network/SwiftUI/Combine)`
  so the package still builds on Linux. The Linux build is the floor (CI pins Swift 6.0, where
  `URLSessionWebSocketTask`'s completion-handler API is absent — hence the streaming guard + Linux
  stub). Don't remove guards to "simplify."
- **License/OSS:** Apache-2.0 (derivative of FeatBit). The repo is **internal**;
  `catalog-info.yaml` has `fluentinhealth.com/oss: pending`. **Do not make the repo public** — that
  waits on CTO approval (issue #2). Don't commit secrets; the example app uses placeholder
  secret/URLs.
- **CI:** the `e2e` job is intentionally `continue-on-error: true` until validated on a Docker host.

## What you'll need (may block full verification)

- **macOS + Xcode 15.4+** for the SwiftUI/UIKit/streaming targets and the example app.
- **A real FeatBit environment** (env secret + evaluation-server URL) to verify streaming/polling at
  runtime. Unit tests don't need it; live streaming verification does. If you don't have one, say so
  rather than guessing.
- **Docker** for the `FEATBIT_E2E=1` suite.

## Pointers

- PR: #1 (`feat/ios-sdk` → `main`). OSS approval: issue #2.
- Reference implementation: the Android repo above — when unsure about behavior, compare to it.
