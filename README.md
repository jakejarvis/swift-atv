# SwiftATV

A Swift library for discovering, pairing with, and controlling Apple TV and AirPlay devices. Port of the Python [pyatv](https://github.com/postlund/pyatv) library to idiomatic Swift.

## Features

- **Device Discovery** -- Scan the local network for Apple TV, HomePod, and AirPlay devices using Bonjour/mDNS, including live TXT resolution, Companion-only identifiers, sleep-proxy deep-sleep discovery, and optional scan diagnostics
- **Pairing** -- Full HAP SRP-6a pair-setup (PIN entry) and pair-verify over Companion, direct MRP, and AirPlay 2 links, with protocol-agnostic pairing code direction metadata and pairing results
- **Credential Persistence** -- Pairing results can be applied directly to `ATVSettings`, and connection setup can use credentials from settings or enriched services
- **Connect Metadata** -- `ConnectOptions` and `ConnectResult` expose protocol order, setup strategy, primary protocol, active protocols, per-protocol attempts, and setup diagnostics
- **Preflight Helpers** -- Query effective pairing status, connectable protocols, and the preferred pairing service before opening network connections
- **Remote Control** -- Send navigation, playback, and media commands (play, pause, menu, home, volume, etc.)
- **Metadata and Push Updates** -- Refresh now-playing metadata on demand, read artwork/current app, and subscribe to direct or tunneled MRP push updates
- **Connection Events** -- Observe primary connection loss and explicit-close events from the unified device facade
- **App Management** -- List installed apps and launch them by bundle ID
- **User Accounts** -- List and switch between user profiles
- **Power Control** -- Turn devices on/off and monitor power state
- **Audio Control** -- Adjust volume when protocol state confirms volume control, and manage output devices over direct or AirPlay-tunneled MRP
- **Touch/Gesture Input** -- Send swipe, tap, and click gestures when Companion touch setup is available
- **Virtual Keyboard Input** -- Read, clear, append, and replace text in focused Apple TV text fields over Companion
- **Encrypted Communication** -- ChaCha20-Poly1305 over Companion, MRP, and AirPlay 2 HAP-encrypted links
- **Local Client Identity** -- Configure the controller/app identity sent during pairing and protocol setup with `ATVSettings.clientIdentity`, including the stable Companion Rapport identifier
- **State-backed Capabilities** -- Typed capability availability reflects protocol state and diagnostics instead of assuming every connected interface is ready
- **Broad Media Commands** -- Query and send supported MediaRemote commands through `mediaCommands`
- **Typed throws** -- Every public method is `async throws(ATVError)` so you get exhaustive error matching, including structured timeout context
- **Multi-Protocol** -- Unified facade across direct MRP, AirPlay-tunneled MRP, and Companion, including Companion-derived AirPlay tunnel attempts for Apple TV discoveries with only Companion advertised

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

> SwiftATV is pre-1.0; API may change in minor releases. For production apps,
> replace `branch: "main"` with a tagged release version or exact revision and
> review the [CHANGELOG](CHANGELOG.md) before upgrading.

Then add it as a dependency to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SwiftATV", package: "swift-atv"),
    ]
),
```

### Xcode App Consumers

Xcode apps can add SwiftATV through **Package Dependencies** or use the same
package URL from an Xcode-managed project. SwiftATV checks in the generated MRP
protobuf Swift sources, so app consumers do not need to approve or skip the
SwiftProtobuf package plugin for SwiftATV itself.

```bash
xcodebuild -project YourApp.xcodeproj -scheme YourScheme -destination 'platform=macOS' test
```

No `Crypto_..._PackageProduct` DerivedData symlink workaround is expected on
Apple platforms: SwiftATV uses system `CryptoKit` there and only depends on
SwiftCrypto's `Crypto` product for Linux builds.

Some Xcode versions still emit dependency-scan warnings from SwiftNIO targets
such as `NIOCore`, `NIOPosix`, `Atomics`, and related internal helper modules.
SwiftATV's manifest only links the NIO products it imports directly, so those
warnings are upstream package graph noise rather than a SwiftATV dependency on
unused umbrella products.

The top-level facade is `ATVClient`, so module-qualified type references remain
available in consumers:

```swift
import SwiftATV

let protocolName: SwiftATV.ATVProtocol = .mrp
let devices = try await ATVClient.scan(protocols: [protocolName])
```

## Quick Start

### Discover Devices

```swift
import SwiftATV

let devices = try await ATVClient.scan(timeout: 5.0)

for device in devices {
    print("\(device.name) at \(device.address)")
    print("  Identifier: \(device.mainIdentifier ?? "unknown")")
    print("  Model: \(device.deviceInfo.model)")
    print("  Services: \(device.services.map(\.protocol))")
}
```

Use `ATVClient.scanWithDiagnostics` when a caller needs to distinguish a clean
"no devices found" scan from non-fatal Bonjour browser, resolver, or empty-TXT
failures:

```swift
let result = try await ATVClient.scanWithDiagnostics(timeout: 5.0)
for diagnostic in result.diagnostics {
    print("\(diagnostic.serviceType): \(diagnostic.message)")
}
```

### Connect and Control

```swift
// Connect to a discovered device
let connection = try await ATVClient.connect(device)
let atv = connection.device

print("Connected with \(connection.primaryProtocol)")

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

// Keyboard text entry, when a text field is focused on the Apple TV
if atv.capabilities.isAvailable(.keyboard(.textSet)) {
    try await atv.keyboard.textSet("Movie title")
}

// Clean up
await atv.close()
```

### Pair with a Device

```swift
var settings = ATVSettings()
settings.clientIdentity.name = "Clicker"

let handler = try await ATVClient.pair(
    device,
    protocol: .companion,
    settings: settings
)

// Start the handshake. Current Companion and MRP flows display a PIN on screen.
try await handler.begin()

// Build the right UI from the protocol-agnostic pairing direction.
switch handler.pairingCodeDirection {
case .deviceProvided:
    print("Enter the PIN shown on \(device.name).")
    try await handler.pin(userEnteredPIN)
case .clientProvided(let pin):
    print("Enter this PIN on \(device.name): \(pin)")
}

// Complete pair-setup and persist the result into the matching protocol bucket.
let pairing = try await handler.finish()
settings.apply(pairing)

if let identifier = device.mainIdentifier {
    try keychain.store(settings, for: identifier)
}

await handler.close()
```

Use `.mrp` instead of `.companion` to pair against the direct Media Remote
Protocol service. Use `.airPlay` to pair for AirPlay 2 HAP credentials used by
the MRP tunnel. `settings.apply(pairing)` copies the paired service identifier
and HAP credentials into the correct protocol settings.

`ATVClient.connect` tries enabled services in the `ConnectOptions.protocols`
order and returns `ConnectResult` when a usable protocol connects. The default
order is direct MRP, then the AirPlay 2 MRP tunnel, then Companion. Pass
`ConnectOptions(protocols: [.mrp])` for strict direct MRP, or
`ConnectOptions(strategy: .allAllowed)` when you want SwiftATV to attach every
usable allowed protocol before returning. The tunnel uses AirPlay credentials
first, then Companion credentials when AirPlay credentials are absent.
When discovery only returns Companion but reusable HAP credentials are
available, SwiftATV can still try the AirPlay MRP tunnel on the default AirPlay
port.
Companion always requires credentials. When both settings and a service contain
credentials for the same protocol, `ATVSettings` wins. When auto-connect
exhausts all options, the thrown `ATVError.connectionFailed` contains
`ConnectionAttemptError` entries for every attempted protocol.

Use `device.connectableProtocols(settings:)`,
`device.preferredPairingService(settings:)`, and
`service.effectivePairingStatus(settings:)` to apply SwiftATV's protocol policy
before starting pairing or connect UI.

### Check Capability Availability

Not every protocol implements every capability. Availability can change after
protocol events or a successful request. Companion media controls, volume,
power, apps, accounts, and keyboard focus start unavailable until the Apple TV
reports or proves that state; Companion touch can also be unavailable even when
the rest of Companion setup succeeds. Output-device list and mutation capabilities
become available when MRP or AirPlay-tunneled MRP reports route state.

```swift
if atv.capabilities.isAvailable(.keyboard(.textSet)) {
    try await atv.keyboard.textSet("Movie title")
}

// Check multiple capabilities at once
if atv.capabilities.inState(
    [.available],
    capabilities: .mediaCommand(.play), .mediaCommand(.pause), .mediaCommand(.nextTrack)
) {
    // Full playback control is available
}

if atv.capabilities.isAvailable(.audio(.setOutputDevices)) {
    let speakers = await atv.audio.outputDevices
    try await atv.audio.setOutputDevices(speakers.map(\.identifier))
}

let playInfo = atv.mediaCommands.commandInfo(.play)
if playInfo.state == .available {
    try await atv.mediaCommands.send(.play)
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
             │   ├─ capabilities   │
             │   └─ mediaCommands  │
             └──────────┬──────────┘
                        │
                   ┌────┴────┐
                   │ Relayer │  (priority routing)
                   └────┬────┘
                        │
              ┌───────┼───────┐
              │       │       │
             MRP   AirPlay Companion
           (high)          (low)
```

**Relayer priority order**: MRP > AirPlay > Companion.
Connection setup is driven by `ConnectOptions`: by default it returns after
the first usable protocol connects, trying direct MRP first,
AirPlay-tunneled MRP next, then Companion. `ConnectStrategy.allAllowed`
continues attaching lower-priority protocols and returns metadata for every
attempt. Companion-only discoveries with reusable HAP credentials can still
attempt AirPlay-tunneled MRP on the default AirPlay port. If a non-primary
protocol later closes or fails optional setup, the
facade unregisters that protocol without emitting a terminal device-close
event. A primary or last-active protocol close still emits `connectionLost`.

### Protocols

| Protocol | Purpose | Status |
|----------|---------|--------|
| **MRP** | Media Remote Protocol: direct protobuf TCP connection, pair-setup/pair-verify, remote control, metadata, push updates, power, audio, output-device mutation | Implemented |
| **Companion** | Modern control, apps, keyboard text input/focus, best-effort touch, and NoOp keepalive. Full pair-setup (SRP-6a) and pair-verify | Implemented, except output-device mutation |
| **AirPlay** | AirPlay 2 HAP pairing and MRP remote-control tunnel, including timeout-bounded HTTP/RTSP setup and MRP output-device mutation | Tunnel implemented |

## Project Structure

```
Sources/SwiftATV/
├── ATVClient.swift              # Public API: scan(), scanWithDiagnostics(), ConnectOptions/Result, pair()
├── Constants.swift              # Enums (ATVProtocol, Capability, MediaRemoteCommand, etc.)
├── Errors.swift                 # ATVError, TimeoutContext, ConnectionAttemptError + wrap() factory
├── Interfaces.swift             # Swift protocols (all throws(ATVError))
├── Configuration.swift          # AppleTVConfiguration, ServiceInfo, connectability helpers
├── Settings.swift               # Local client identity, pairing apply helper, per-protocol settings
├── DeviceInfo.swift             # Device model/OS lookup tables
├── DiscoveryIdentifiers.swift   # Bonjour TXT identifier lookup priority
├── SwiftATV.docc/               # DocC catalog
├── Support/
│   ├── BinaryPlistArchive.swift # Binary plist writer with native UID support
│   ├── OPACK.swift             # OPACK binary serialization codec
│   ├── TLV8.swift              # TLV8 encoding for HAP auth
│   ├── ChaCha20Cipher.swift    # ChaCha20-Poly1305 encryption
│   └── HAPSession.swift        # AirPlay 2 HAP transport encryption
├── Core/
│   ├── Relayer.swift           # Priority-based protocol routing
│   ├── Facade.swift            # FacadeAppleTV unified implementation
│   ├── MessageDispatcher.swift # Generic actor-based pub-sub
│   └── Scanner.swift           # Bonjour/mDNS discovery, TXT resolution, sleep-proxy discovery
├── Auth/
│   ├── HAPCredentials.swift    # Credential storage/serialization
│   ├── SRPAuth.swift           # Ed25519/X25519 + HKDF primitives
│   ├── SRP.swift               # SRP-6a client (pyatv/srptools compatible)
│   └── HAPPairing.swift        # HAPPairSetupHandler + HAPPairVerifyHandler
└── Protocols/
    ├── AirPlay/                # AirPlay 2 HAP pairing + MRP tunnel transport
    │   ├── AirPlayHTTP.swift
    │   ├── AirPlayTCPConnection.swift
    │   ├── AirPlayChannels.swift
    │   ├── AirPlayMRPTunnelTransport.swift
    │   ├── AirPlayPairing.swift
    │   └── AirPlaySupport.swift
    ├── Companion/              # Full Companion protocol implementation
    │   ├── CompanionConnection.swift
    │   ├── CompanionProtocol.swift
    │   ├── CompanionTextInputSession.swift # RTI text-input archive codec
    │   ├── CompanionPairing.swift     # OPACK-wrapped PS_Start/PS_Next flow
    │   ├── CompanionInterfaces.swift
    │   └── CompanionService.swift
    └── MRP/
        ├── Protobuf/           # pyatv MRP .proto definitions, excluded from compilation
        ├── Generated/          # checked-in SwiftProtobuf output
        ├── MRPProtocol.swift    # Transport abstraction, TCP framing, protobuf dispatch
        ├── MRPMessages.swift    # Outbound MRP message builders, including output context changes
        ├── MRPPlayerState.swift # Now-playing state actor
        ├── MRPInterfaces.swift  # Remote, metadata, push, power, audio, capabilities, media commands
        ├── MRPPairing.swift     # MRP HAP pair-setup flow
        └── MRPService.swift     # MRP lifecycle and facade registration
```

## Testing

```bash
swift test
```

The test suite runs 316 XCTest cases covering pyatv ports and SwiftATV-specific
integration logic, plus 57 Swift Testing cases:

**Ported from pyatv** (XCTest) — all enum raw values, OPACK encode/decode for
every type, TLV8 chunk splitting/reassembly, ChaCha20-Poly1305 (12-byte and
8-byte nonce), configuration/service merging, `Playing` state equality,
device model lookups, settings Codable round-trips, relayer priority and
takeover, Companion capability availability, HAP credential serialization,
MRP varint framing, MRP protobuf message construction, MRP player-state
metadata and active metadata refresh, MRP volume/command-result handling,
MRP output-device mutation/state updates, MRP optional setup diagnostics and capability gating,
Bonjour pairing flag parsing, Companion Bonjour identifiers, live TXT
resolution, scan diagnostics, sleep-proxy deep-sleep discovery, identity
merging, deterministic first-usable connect, all-allowed multi-protocol
connect, connect-result metadata, aggregate connection errors, credential
selection including AirPlay tunnel ordering, pairing-result settings
persistence, preflight connectability helpers, structured timeout context,
unsupported metadata errors, Companion touch-start timeout resilience, facade
device events including secondary-protocol close isolation, timeout conversion,
strict TLV8 auth decoding,
OPACK object-reference/malformed-data handling, consumer-style module-qualified
imports, pairing code direction, and `MessageDispatcher` actor behavior.

**SwiftATV additions** (Swift Testing) — SRP-6a client verified against a
canned pyatv vector (rejects `B == 0`, rejects `u == 0`, verifies server M2,
and matches A/M1/K byte-for-byte), HAP pair-setup state machine (M1 encoding,
M3 output against canned M2, error-TLV surfacing, state ordering),
`Playing.description` edge cases, Companion auth envelopes, Companion encrypted
frame AAD, Companion connection race handling, Companion RTI text-input
binary-plist encoding/decoding, AirPlay feature/pairing parsing, HAP transport
encryption, and AirPlay DataStream MRP frame extraction.

CI runs the full suite on `macos-26` (Swift 6.3) and `swift:6.3-jammy`
on `ubuntu-24.04`, plus a Swift 6.3 `swift format lint --strict` job on
macOS.

## Credits

This project is a Swift port of [pyatv](https://github.com/postlund/pyatv) by [Pierre Ståhl](https://github.com/postlund). The original Python library's architecture, protocol implementations, and test cases served as the reference for this port.

## License

MIT License. See [LICENSE](LICENSE) for details.
