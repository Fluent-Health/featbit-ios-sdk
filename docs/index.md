# FeatBit Swift/iOS SDK

A Swift/iOS client-side SDK for the open-source feature-flag platform
[FeatBit](https://github.com/featbit/featbit), built because FeatBit ships no native Swift SDK. Its
architecture and API are based on FeatBit's official
[.NET client SDK](https://github.com/featbit/featbit-dotnet-client-sdk); real-time streaming sync is
modeled on FeatBit's JS/React-Native SDK and `/streaming` wire protocol. It is a sibling port of the
[FeatBit Kotlin/Android SDK](https://github.com/Fluent-Health/featbit-android-sdk).

This is a **client-side** SDK for single-user contexts (mobile, desktop, embedded) — not for
multi-user systems such as web servers.

## Features

- Typed flag evaluation (`bool`/`string`/`int`/`float`/`double`, plus `*Detail` with reasons)
- **Polling** and real-time **WebSocket streaming** synchronization
- Lifecycle-aware streaming on iOS (pause on background/offline, resync on foreground)
- Flag-change tracking via listeners, an `AsyncStream`, and a Combine publisher (Apple platforms)
- Offline mode and bootstrap
- Built on Swift Concurrency, `URLSession`, and `Codable` — no third-party dependencies

## Modules

| Product | Purpose |
|---|---|
| `FeatBitClient` | The core SDK (UI-agnostic) |
| `FeatBitLifecycle` | Optional glue: `FBLifecycleConnector` wiring app lifecycle/network to the client |
| `FeatBitSwiftUI` | Optional SwiftUI helpers (`FeatBit` `ObservableObject`, `scenePhase` wiring) |

## Next steps

- [Usage](usage.md) — install, initialize, evaluate, track changes
- [Data synchronization](data-sync.md) — polling vs. streaming and lifecycle behavior
