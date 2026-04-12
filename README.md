# SwiftATV

A Swift library for discovering, pairing with, and controlling Apple TV and AirPlay devices. Port of the Python [pyatv](https://github.com/postlund/pyatv) library to idiomatic Swift.

## Features

- **Device Discovery** -- Scan the local network for Apple TV, HomePod, and AirPlay devices using Bonjour/mDNS
- **Pairing** -- Full HAP SRP-6a pair-setup (PIN entry) and pair-verify over the Companion link
- **Remote Control** -- Send navigation, playback, and media commands (play, pause, menu, home, volume, etc.)
- **App Management** -- List installed apps and launch them by bundle ID
- **User Accounts** -- List and switch between user profiles
- **Power Control** -- Turn devices on/off and monitor power state
- **Audio Control** -- Adjust volume, manage output devices
- **Touch/Gesture Input** -- Send swipe, tap, and click gestures
- **Virtual Keyboard** -- Text input via the virtual keyboard
- **Encrypted Communication** -- ChaCha20-Poly1305 over the Companion link
- **Typed throws** -- Every public method is `async throws(ATVError)` so you get exhaustive error matching
- **Multi-Protocol** -- Unified facade across Companion (implemented), MRP, DMAP, AirPlay, and RAOP (planned)

## Requirements

- Swift 6.0+
- macOS 13+ / iOS 16+ / tvOS 16+

## Installation

### Swift Package Manager

Add SwiftATV to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jakejarvis/swift-atv.git", from: "0.1.0"),
]
```

> SwiftATV is pre-1.0. The first tagged release is `0.1.0`; until then,
> pin to `branch: "main"`. API may change in minor releases — review the
> [CHANGELOG](CHANGELOG.md) before upgrading.

Then add it as a dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SwiftATV", package: "swift-atv"),
    ]
),
```

## Quick Start

### Discover Devices

```swift
import SwiftATV

let devices = try await SwiftATV.scan(timeout: 5.0)

for device in devices {
    print("\(device.name) at \(device.address)")
    print("  Model: \(device.deviceInfo.model)")
    print("  Services: \(device.services.map(\.protocol))")
}
```

### Connect and Control

```swift
// Connect to a discovered device
let atv = try await SwiftATV.connect(device)

// Remote control
try await atv.remoteControl.home()
try await atv.remoteControl.select()
try await atv.remoteControl.play()
try await atv.remoteControl.volumeUp()

// Navigate
try await atv.remoteControl.up()
try await atv.remoteControl.down()
try await atv.remoteControl.left()
try await atv.remoteControl.right()

// Apps
let apps = try await atv.apps.appList()
try await atv.apps.launchApp(bundleID: "com.apple.TVMovies")

// Power
try await atv.power.turnOff()

// Clean up
await atv.close()
```

### Pair with a Device

```swift
let handler = try await SwiftATV.pair(device, protocol: .companion)

// Start the handshake. The Apple TV now displays a 4-digit PIN on screen.
try await handler.begin()

// Prompt the user for the PIN, then complete pair-setup:
try await handler.pin(userEnteredPIN)
try await handler.finish()

// Pull the HAP long-term credentials and persist them. On the next
// connection, load them into ATVSettings so SwiftATV uses pair-verify
// instead of pair-setup.
if let creds = (handler as? CompanionPairingHandler)?.credentials {
    try keychain.store(creds.serialize(), for: device.mainIdentifier)
}

await handler.close()
```

### Check Feature Availability

```swift
if atv.features.isAvailable(.appList) {
    let apps = try await atv.apps.appList()
}

// Check multiple features at once
if atv.features.inState([.available], features: .play, .pause, .next) {
    // Full playback control is available
}
```

## Architecture

SwiftATV uses a **multi-protocol facade** architecture, routing each command to the highest-priority protocol that supports it:

```
             ┌─────────────────────┐
             │   AppleTVDevice     │  (unified interface)
             │   ├─ remoteControl  │
             │   ├─ apps           │
             │   ├─ power          │
             │   ├─ audio          │
             │   ├─ keyboard       │
             │   ├─ touch          │
             │   └─ features       │
             └──────────┬──────────┘
                        │
                   ┌────┴────┐
                   │ Relayer │  (priority routing)
                   └────┬────┘
                        │
        ┌───────┬───────┼───────┬───────┐
        │       │       │       │       │
       MRP    DMAP  Companion AirPlay  RAOP
     (high)                          (low)
```

**Priority order**: MRP > DMAP > Companion > AirPlay > RAOP

### Protocols

| Protocol | Purpose | Status |
|----------|---------|--------|
| **Companion** | Modern control, apps, keyboard, touch. Full pair-setup (SRP-6a) and pair-verify | Implemented |
| **MRP** | Media Remote Protocol (protobuf-based) | Stub |
| **DMAP** | Legacy Digital Media Access Protocol | Planned |
| **AirPlay** | Audio/video streaming | Planned |
| **RAOP** | Remote Audio Output Protocol | Planned |

## Project Structure

```
Sources/SwiftATV/
├── SwiftATV.swift              # Public API: scan(), connect(), pair()
├── Constants.swift             # All enums (ATVProtocol, FeatureName, etc.)
├── Errors.swift                # ATVError + wrap() factory
├── Interfaces.swift            # Swift protocols (all throws(ATVError))
├── Configuration.swift         # AppleTVConfiguration, ServiceInfo
├── Settings.swift              # Per-protocol settings (Codable)
├── DeviceInfo.swift            # Device model/OS lookup tables
├── SwiftATV.docc/              # DocC catalog
├── Support/
│   ├── OPACK.swift             # OPACK binary serialization codec
│   ├── TLV8.swift              # TLV8 encoding for HAP auth
│   └── ChaCha20Cipher.swift    # ChaCha20-Poly1305 encryption
├── Core/
│   ├── Relayer.swift           # Priority-based protocol routing
│   ├── Facade.swift            # FacadeAppleTV unified implementation
│   ├── MessageDispatcher.swift # Generic actor-based pub-sub
│   └── Scanner.swift           # Bonjour/mDNS device discovery
├── Auth/
│   ├── HAPCredentials.swift    # Credential storage/serialization
│   ├── SRPAuth.swift           # Ed25519/X25519 + HKDF primitives
│   ├── SRP.swift               # SRP-6a client (pyatv/srptools compatible)
│   └── HAPPairing.swift        # HAPPairSetupHandler + HAPPairVerifyHandler
└── Protocols/
    ├── Companion/              # Full Companion protocol implementation
    │   ├── CompanionConnection.swift
    │   ├── CompanionProtocol.swift
    │   ├── CompanionPairing.swift     # OPACK-wrapped PS_Start/PS_Next flow
    │   ├── CompanionInterfaces.swift
    │   └── CompanionService.swift
    └── MRP/
        └── MRPProtocol.swift   # Message types + MRPPlayerState actor
```

## Testing

```bash
swift test
```

The test suite runs 212 XCTest cases ported from pyatv plus 16 Swift Testing
cases for SwiftATV-specific logic:

**Ported from pyatv** (XCTest) — all enum raw values, OPACK encode/decode for
every type, TLV8 chunk splitting/reassembly, ChaCha20-Poly1305 (12-byte and
8-byte nonce), configuration/service merging, `Playing` state equality,
device model lookups, settings Codable round-trips, relayer priority and
takeover, Companion feature availability, HAP credential serialization,
`MessageDispatcher` actor behavior.

**SwiftATV additions** (Swift Testing) — SRP-6a client verified against a
canned pyatv vector (rejects `B == 0`, rejects `u == 0`, verifies server M2,
and matches A/M1/K byte-for-byte), HAP pair-setup state machine (M1 encoding,
M3 output against canned M2, error-TLV surfacing, state ordering),
`Playing.description` edge cases.

CI runs the full suite on `macos-15` (Swift 6.0, 6.1) and
`swift:6.0-jammy` / `swift:6.1-jammy` on `ubuntu-latest`, plus a
`swift format lint --strict` job on macOS.

## Credits

This project is a Swift port of [pyatv](https://github.com/postlund/pyatv) by [Pierre Ståhl](https://github.com/postlund). The original Python library's architecture, protocol implementations, and test cases served as the reference for this port.

## License

MIT License. See [LICENSE](LICENSE) for details.
