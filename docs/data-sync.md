# Data synchronization

The SDK supports two modes; both feed the same in-memory store, so evaluation, `FlagTracker`,
`changes`, and `flagChanges` behave identically regardless of mode.

## Polling (default)

Fetches flags over HTTP at an interval (ported from the .NET client SDK):

```swift
FBOptions.Builder(secret).polling("https://app-eval.featbit.co", interval: 5 * 60)
```

## Streaming

Keeps a WebSocket open and receives flag changes in real time (modeled on the JS/RN SDK and
FeatBit's `/streaming` protocol):

```swift
FBOptions.Builder(secret).streaming("wss://app-eval.featbit.co")
```

The synchronizer retries with exponential backoff and an application-level heartbeat.

## Lifecycle-aware streaming (iOS)

WebSockets don't survive backgrounding/suspension, and reconnecting blindly wastes battery. The SDK
exposes neutral hooks so a streaming connection is dropped when the app backgrounds or goes offline
and re-established (with an immediate resync) on foreground / reconnect:

```swift
client.setForeground(true /* or false */)
client.setNetworkAvailable(true /* or false */)
```

Transitions to inactive are debounced by `FBOptions.Builder.backgroundGracePeriod(...)`
(default 20s). Defaults are foreground + online, so a client whose hooks are never called streams as
before.

The optional `FeatBitLifecycle` product wires these hooks to `UIApplication` lifecycle notifications
+ `NWPathMonitor` automatically:

```swift
import FeatBitLifecycle

// e.g. in your App init or AppDelegate, on the main thread
let connector = FBLifecycleConnector(client: fbClient)
connector.start()
```

SwiftUI-first apps can instead drive the foreground hook from `scenePhase`:

```swift
import FeatBitSwiftUI

someView.featBitScenePhase(client)
```
