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
    .package(url: "https://github.com/jakejarvis/swift-atv.git", from: "0.2.2")
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

For Xcode app targets, add `https://github.com/jakejarvis/swift-atv.git` in
**Package Dependencies** and link the `SwiftATV` product to the app target and
any test target that imports it. SwiftATV checks in its generated MRP protobuf
Swift sources, so Xcode consumers do not need `-skipPackagePluginValidation`
for SwiftATV itself.

```bash
xcodebuild -project YourApp.xcodeproj -scheme YourScheme -destination 'platform=macOS' test
```

## Discover devices

``ATVClient/scan(timeout:identifiers:protocols:)`` performs Bonjour/mDNS
discovery and returns an array of ``AppleTVConfiguration`` values, one per
device found on the local network.

```swift
import SwiftATV

let devices = try await ATVClient.scan(timeout: 5)
for device in devices {
    print("\(device.name) at \(device.address)")
    print("  Identifier: \(device.mainIdentifier ?? "unknown")")
    print("  Model: \(device.deviceInfo.model)")
    print("  Services: \(device.services.map(\.protocol))")
}
```

You can narrow the scan to specific protocols or device identifiers to avoid
paying for protocol probes you don't need. Identifier filtering matches any
identifier reported by the device's services, not just the preferred display
identifier. Companion-only discoveries use the stable Companion TXT identifiers
reported by `_companion-link._tcp`:

```swift
let companionOnly = try await ATVClient.scan(
    timeout: 3,
    protocols: [.companion]
)
```

Use ``ATVClient/scanWithDiagnostics(timeout:identifiers:protocols:)`` when the
app needs Bonjour failure context, including services that resolved without TXT
metadata, while still keeping any devices that were successfully discovered:

```swift
let result = try await ATVClient.scanWithDiagnostics(timeout: 5)
for diagnostic in result.diagnostics {
    print("\(diagnostic.serviceType): \(diagnostic.message)")
}
```

## Pair with a device

The first time your app talks to an Apple TV over Companion or MRP, you must
exchange a PIN. The Apple TV displays the PIN on screen; your app submits it
back to complete the handshake. SwiftATV runs the full HAP SRP-6a pair-setup
handshake for you; all you need is the `begin` → `pin` → `finish` flow.

```swift
let handler = try await ATVClient.pair(device, protocol: .companion)

// begin() starts the handshake. Current Companion and MRP flows display a
// 4-digit PIN on the Apple TV screen.
try await handler.begin()

switch handler.pairingCodeDirection {
case .deviceProvided:
    print("Enter the PIN shown on \(device.name).")
    try await handler.pin(userEnteredPIN)
case .clientProvided(let pin):
    print("Enter this PIN on \(device.name): \(pin)")
}

try await handler.finish()

// Pull out the resulting HAP long-term credentials from the protocol-agnostic
// PairingHandler.
if let identifier = device.mainIdentifier,
   let credentials = handler.serializedCredentials
{
    try keychain.store(credentials, for: identifier)
}

await handler.close()
```

Store the serialized credentials under one of the device's identifiers
(``AppleTVConfiguration/mainIdentifier`` or ``AppleTVConfiguration/allIdentifiers``)
so you can restore them on the next connection.

To pair through direct MRP, request `.mrp` and store the credentials for
`.mrp`:

```swift
let handler = try await ATVClient.pair(device, protocol: .mrp)

try await handler.begin()
try await handler.pin(userEnteredPIN)
try await handler.finish()

if let identifier = device.mainIdentifier,
   let credentials = handler.serializedCredentials
{
    try keychain.store(credentials, for: identifier)
}

await handler.close()
```

## Connect and issue commands

Once paired, connect by loading the stored credentials into
``ATVSettings`` and calling ``ATVClient/connect(_:protocol:settings:)``:

```swift
var settings = ATVSettings()
settings.setCredentials(storedCredentialsString, for: .companion)
// Use `.mrp` here when you stored credentials from MRPPairingHandler.

let atv = try await ATVClient.connect(device, settings: settings)

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

``ATVClient/connect(_:protocol:settings:)`` tries enabled services in a
deterministic order for implemented control protocols: MRP first, then
Companion. If you do not request a specific protocol, setup falls back past
failed or missing-credential services until one usable protocol connects. If
you do request a specific protocol, that protocol's error is returned directly.

Credentials in ``ATVSettings`` take precedence. If settings do not contain
credentials for a protocol, SwiftATV falls back to the matching
``ServiceInfo/credentials`` value from an enriched scan result.

You can observe connection lifecycle events from the connected facade:

```swift
Task {
    for await event in atv.deviceEvents {
        switch event {
        case .connectionLost(let error):
            print("Connection lost: \(error)")
        case .connectionClosed:
            print("Connection closed")
        }
    }
}
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
