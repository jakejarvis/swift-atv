# Getting Started

Discover, pair, and control an Apple TV from a Swift application.

## Overview

Using SwiftATV is a three-step flow:

1. **Scan** for devices on the local network.
2. **Pair** with a device (first-time only; credentials are stored in your
   app's settings).
3. **Connect** and issue commands.

## Add SwiftATV to your package

```swift
dependencies: [
    .package(url: "https://github.com/jakejarvis/swift-atv.git", from: "0.1.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "SwiftATV", package: "swift-atv")
        ]
    )
]
```

## Discover devices

``ATVScanner/scan(timeout:identifiers:protocols:)`` performs Bonjour/mDNS
discovery and returns an array of ``AppleTVConfiguration`` values, one per
device found on the local network.

```swift
import SwiftATV

let devices = try await ATVScanner.scan(timeout: 5)
for device in devices {
    print("\(device.name) at \(device.address)")
    print("  Model: \(device.deviceInfo.model)")
    print("  Services: \(device.services.map(\.protocol))")
}
```

You can narrow the scan to specific protocols or device identifiers to avoid
paying for protocol probes you don't need:

```swift
let companionOnly = try await ATVScanner.scan(
    timeout: 3,
    protocols: [.companion]
)
```

## Pair with a device

The first time your app talks to an Apple TV, you must exchange a PIN. The
Apple TV displays the PIN on screen; your app submits it back to complete
the handshake.

```swift
let handler = try await SwiftATV.pair(device, protocol: .companion)
try await handler.begin()

// Apple TV now displays a 4-digit PIN. Prompt the user for it.
try await handler.pin(userEnteredPIN)
try await handler.finish()

// Persist the resulting credentials somewhere safe.
let credentialsString = handler.credentials?.serialized
try keychain.store(credentialsString, for: device.mainIdentifier)

await handler.close()
```

Store the serialized credentials under the device's
``AppleTVConfiguration/mainIdentifier`` so you can restore them on the next
connection.

## Connect and issue commands

Once paired, connect by loading the stored credentials into
``ATVSettings`` and calling ``SwiftATV/connect(_:settings:)``:

```swift
let settings = ATVSettings()
settings.protocols.companion.credentials = storedCredentialsString

let atv = try await SwiftATV.connect(device, settings: settings)

// Remote control
try await atv.remoteControl.home()
try await atv.remoteControl.select()
try await atv.remoteControl.play()

// Apps
let apps = try await atv.apps.appList()
try await atv.apps.launchApp(bundleID: "com.apple.TVMovies")

// Power
try await atv.power.turnOff()

// Always close the connection when you're done.
await atv.close()
```

## Check feature availability

Not every protocol implements every feature. Use ``FeatureProvider`` to check
what's available on a connected device before calling it:

```swift
if atv.features.inState([.available], features: .play, .pause, .next) {
    // Full playback control is supported.
}
```

## Next steps

- Browse the individual interfaces under **Device control** on the main page.
- Read the [CHANGELOG](https://github.com/jakejarvis/swift-atv/blob/main/CHANGELOG.md)
  to see what's implemented and what's planned.
- File issues or contribute on [GitHub](https://github.com/jakejarvis/swift-atv).
