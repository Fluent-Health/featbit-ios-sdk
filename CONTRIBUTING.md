# Contributing

Thanks for your interest in contributing to the FeatBit Swift/iOS SDK.

## Reporting bugs

Open an issue describing the problem, steps to reproduce, expected vs. actual behaviour, and the
SDK / Swift / Xcode / OS versions you're using.

## Proposing changes

1. Fork the repository.
2. Create a branch: `git checkout -b my-fix`.
3. Make your changes; ensure the build and tests pass.
4. Open a pull request against `main`.

## Building and testing

```bash
swift build
swift test                                  # unit tests (no network/Docker)
FEATBIT_E2E=1 swift test --filter E2E       # full-stack E2E (requires Docker)
```

The core (`FeatBitClient`) builds and unit-tests on Linux and macOS. The `FeatBitSwiftUI` and
`FeatBitLifecycle` products, the WebSocket streaming runtime, and the example app require macOS +
Xcode (their Apple-only code is guarded with `#if canImport(...)` and compiles to empty elsewhere).
To build the example app:

```bash
xcodebuild -scheme FeatBitExampleApp -destination 'generic/platform=iOS' build
```

## Code style

- Follow standard Swift API design guidelines; keep the public surface small and documented.
- Prefer `async`/`await` for asynchronous work and synchronous reads for evaluation.
- Wire-protocol changes must remain byte-compatible with the FeatBit server and the
  [Kotlin/Android SDK](https://github.com/Fluent-Health/featbit-android-sdk) — keep
  `ConnectionTokenTests` and the JSON shapes in sync.
- Add or update tests for behavioural changes.

## No CLA required

You do not need to sign a Contributor License Agreement. By submitting a pull request, you agree to
license your contribution under the repository's existing [LICENSE](./LICENSE) (Apache-2.0).
