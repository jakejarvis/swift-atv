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
    .package(url: "https://github.com/jakejarvis/swift-atv.git", branch: "main")
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

For production apps, replace `branch: "main"` with a tagged release version or
exact revision and review the changelog before upgrading.

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
reported by `_companion-link._tcp`. Unfiltered scans also include
`_sleep-proxy._udp`, which can mark configurations as ``AppleTVConfiguration/deepSleep``
when the sleep-proxy service name carries a matching device identifier:

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

The first time your app talks to an Apple TV over Companion, direct MRP, or
AirPlay 2, you must exchange a PIN. The Apple TV displays the PIN on screen;
your app submits it back to complete the handshake. SwiftATV runs the full HAP
SRP-6a pair-setup handshake for you; all you need is the `begin` → `pin` →
`finish` flow.

```swift
var settings = ATVSettings()
settings.clientIdentity.name = "Clicker"

let handler = try await ATVClient.pair(
    device,
    protocol: .companion,
    settings: settings
)

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

let pairing = try await handler.finish()
settings.apply(pairing)

if let identifier = device.mainIdentifier {
    try keychain.store(settings, for: identifier)
}

await handler.close()
```

Store the updated settings under one of the device's identifiers
(``AppleTVConfiguration/mainIdentifier`` or ``AppleTVConfiguration/allIdentifiers``)
so you can restore the protocol credentials on the next connection.

To pair through direct MRP, request `.mrp` and store the credentials for
`.mrp`:

```swift
var settings = ATVSettings()
let handler = try await ATVClient.pair(device, protocol: .mrp, settings: settings)

try await handler.begin()
try await handler.pin(userEnteredPIN)
let pairing = try await handler.finish()
settings.apply(pairing)

if let identifier = device.mainIdentifier {
    try keychain.store(settings, for: identifier)
}

await handler.close()
```

To pair for the AirPlay 2 MRP tunnel, request `.airPlay` and store the
credentials for `.airPlay`:

```swift
var settings = ATVSettings()
settings.clientIdentity.name = "Clicker"
settings.protocols.airplay.airPlayVersion = .v2

let handler = try await ATVClient.pair(
    device,
    protocol: .airPlay,
    settings: settings
)

try await handler.begin()
try await handler.pin(userEnteredPIN)
let pairing = try await handler.finish()
settings.apply(pairing)

if let identifier = device.mainIdentifier {
    try keychain.store(settings, for: identifier)
}

await handler.close()
```

## Connect and issue commands

Once paired, connect by loading the stored credentials into
``ATVSettings`` and calling ``ATVClient/connect(_:options:settings:)``:

```swift
var settings = ATVSettings()
settings.clientIdentity.name = "Clicker"
settings.setCredentials(storedCredentialsString, for: .companion)
// Use `.mrp` here when you stored credentials from MRPPairingHandler.

let connection = try await ATVClient.connect(device, settings: settings)
let atv = connection.device

print("Connected with \(connection.primaryProtocol)")

// Remote control
try await atv.remoteControl.home()
try await atv.remoteControl.select()
try await atv.remoteControl.play()

// Apps
let apps = try await atv.apps.appList()
try await atv.apps.launchApp(bundleID: "com.apple.TVMovies")

// Power
try await atv.power.turnOff()

// Keyboard text entry, when a text field is focused on the Apple TV
if atv.capabilities.isAvailable(.keyboard(.textSet)) {
    try await atv.keyboard.textSet("Movie title")
}

// Always close the connection when you're done.
await atv.close()
```

``ATVClient/connect(_:options:settings:)`` tries enabled services in
``ConnectOptions/protocols`` order and returns ``ConnectResult`` when a usable
protocol connects. The default order is direct MRP first, then the AirPlay 2
MRP tunnel, then Companion. Use `ConnectOptions(protocols: [.mrp])` for strict
direct MRP, or `ConnectOptions(strategy: .allAllowed)` to attach every usable
allowed protocol before returning.

Credentials in ``ATVSettings`` take precedence. If settings do not contain
credentials for a protocol, SwiftATV falls back to the matching
``ServiceInfo/credentials`` value from an enriched scan result. The AirPlay MRP
tunnel tries AirPlay credentials first, then Companion credentials when AirPlay
credentials are absent. Companion connections always require credentials.

Use ``AppleTVConfiguration/connectableProtocols(settings:)``,
``AppleTVConfiguration/preferredPairingService(settings:protocols:)``, and
``ServiceInfo/effectivePairingStatus(settings:)`` to apply SwiftATV's protocol
policy before opening connect or pairing UI.

``ATVSettings/clientIdentity`` describes your local app or controller. Do not
copy identifiers from the scanned Apple TV into this field; SwiftATV validates
that the local client identity does not match the target device before pairing
or connecting. Persist the full settings value so the generated Companion
Rapport identifier stays stable across launches.

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

## Check capability availability

Not every protocol implements every capability. Use ``CapabilityProvider`` to check
what's available on a connected device before calling it. Availability can
change after protocol events or a successful request. Companion media controls,
volume, power, apps, accounts, and keyboard focus start unavailable until the
Apple TV reports or proves that state; Companion touch gestures can also be
unavailable even when the rest of Companion setup succeeds. Output-device list
and mutation capabilities become available when direct MRP or AirPlay-tunneled MRP
reports route state:

```swift
if atv.capabilities.inState(
    [.available],
    capabilities: .mediaCommand(.play), .mediaCommand(.pause), .mediaCommand(.nextTrack)
) {
    // Full playback control is supported.
}

if atv.capabilities.isAvailable(.audio(.setOutputDevices)) {
    let speakers = await atv.audio.outputDevices
    try await atv.audio.setOutputDevices(speakers.map(\.identifier))
}

if atv.mediaCommands.commandInfo(.play).state == .available {
    try await atv.mediaCommands.send(.play)
}
```

## Next steps

- Browse the individual interfaces under **Device control** on the main page.
- Read the [CHANGELOG](https://github.com/jakejarvis/swift-atv/blob/main/CHANGELOG.md)
  to see what's changed.
- File issues or contribute on [GitHub](https://github.com/jakejarvis/swift-atv).
