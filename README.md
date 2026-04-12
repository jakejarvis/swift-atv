# SwiftATV

A Swift library for discovering, pairing with, and controlling Apple TV and AirPlay devices. Port of the Python [pyatv](https://github.com/postlund/pyatv) library to idiomatic Swift.

## Features

- **Device Discovery** -- Scan the local network for Apple TV, HomePod, and AirPlay devices using Bonjour/mDNS
- **Remote Control** -- Send navigation, playback, and media commands (play, pause, menu, home, volume, etc.)
- **App Management** -- List installed apps and launch them by bundle ID
- **User Accounts** -- List and switch between user profiles
- **Power Control** -- Turn devices on/off and monitor power state
- **Audio Control** -- Adjust volume, manage output devices
- **Touch/Gesture Input** -- Send swipe, tap, and click gestures
- **Virtual Keyboard** -- Text input via the virtual keyboard
- **Encrypted Communication** -- HAP pair-verify with ChaCha20-Poly1305 encryption
- **Multi-Protocol** -- Unified interface across Companion, MRP, DMAP, AirPlay, and RAOP protocols

## Requirements

- Swift 6.3+
- macOS 13+ / iOS 16+ / tvOS 16+

## Installation

### Swift Package Manager

Add SwiftATV to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jakejarvis/swift-atv.git", branch: "main"),
]
```

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
try await handler.begin()

// Apple TV displays a PIN -- enter it:
try await handler.pin("1234")
try await handler.finish()

print("Paired: \(handler.hasPaired)")
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
| **Companion** | Modern control, apps, keyboard, touch | Implemented |
| **MRP** | Media Remote Protocol (protobuf-based) | Stub |
| **DMAP** | Legacy Digital Media Access Protocol | Planned |
| **AirPlay** | Audio/video streaming | Planned |
| **RAOP** | Remote Audio Output Protocol | Planned |

## Project Structure

```
Sources/SwiftATV/
├── SwiftATV.swift              # Public API: scan(), connect(), pair()
├── Constants.swift             # All enums (ATVProtocol, FeatureName, etc.)
├── Errors.swift                # ATVError enum
├── Interfaces.swift            # Swift protocols for all interfaces
├── Configuration.swift         # AppleTVConfiguration, ServiceInfo
├── Settings.swift              # Per-protocol settings (Codable)
├── DeviceInfo.swift            # Device model/OS lookup tables
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
│   ├── SRPAuth.swift           # Ed25519/X25519 + HKDF
│   └── HAPPairing.swift        # Pair-verify procedure
└── Protocols/
    ├── Companion/              # Full Companion protocol implementation
    │   ├── CompanionConnection.swift
    │   ├── CompanionProtocol.swift
    │   ├── CompanionPairing.swift
    │   ├── CompanionInterfaces.swift
    │   └── CompanionService.swift
    └── MRP/
        └── MRPProtocol.swift   # Message types + stub
```

## Testing

```bash
swift test
```

The test suite (12 files, 2400+ lines) is ported from pyatv's Python tests and covers:

- All enum raw values and descriptions
- OPACK binary serialization (encode/decode for every type)
- TLV8 encoding with chunk splitting/reassembly
- ChaCha20-Poly1305 encryption (12-byte and 8-byte nonce)
- Configuration and service merging
- Playing state equality across all fields
- Device model/OS lookup tables
- Settings Codable round-trips
- Relayer priority ordering and takeover
- Companion protocol feature availability
- HAP credential serialization
- MessageDispatcher actor behavior

## Credits

This project is a Swift port of [pyatv](https://github.com/postlund/pyatv) by [Pierre Ståhl](https://github.com/postlund). The original Python library's architecture, protocol implementations, and test cases served as the reference for this port.

## License

MIT License. See [LICENSE](LICENSE) for details.
