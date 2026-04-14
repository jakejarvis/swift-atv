# AGENTS.md

## Project Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv), a Python library for controlling Apple TV and AirPlay devices. It uses a multi-protocol facade architecture to provide a unified interface across direct MRP, AirPlay-tunneled MRP, and Companion.

## Build & Test

```bash
swift build          # Build the library
swift test           # Run all tests (XCTest + Swift Testing)
swift package clean  # Clean build artifacts

# Lint (CI runs the same command with --strict)
swift format lint --recursive Sources Tests
```

No special setup or environment variables needed. Requires Swift 6.3+ and macOS 13+/iOS 16+.

The package uses `swift-tools-version: 6.3` with Swift 6 language mode (`swiftLanguageModes: [.v6]`) and strict concurrency enabled. All public protocol methods in `Interfaces.swift` are typed-throws (`async throws(ATVError)`); NIO, CryptoKit, and SwiftProtobuf errors are wrapped into `ATVError` at the Companion / MRP / ChaCha20Cipher / HAPPairing boundaries. Classes that manage mutable internal state use `@unchecked Sendable` with encapsulated synchronization. The `MessageDispatcher`, `CompanionProtocolHandler`, `MRPProtocolHandler`, `CompanionPower`/`Audio`/`Keyboard`, and `MRPPlayerState` use Swift actors for safe concurrency.

## Architecture

### Key Design Patterns

- **Facade**: `FacadeAppleTV` in `Core/Facade.swift` unifies all protocols behind `AppleTVDevice` and surfaces connection lifecycle events
- **Per-protocol lifecycle**: The facade tracks active and primary protocols separately. Secondary protocol setup/close failures unregister only that protocol; primary or last-active closes emit terminal device events.
- **Relayer**: `Core/Relayer.swift` routes method calls to the highest-priority protocol (MRP > AirPlay > Companion)
- **Connect setup priority**: `ATVClient.connect` takes `ConnectOptions`, attempts implemented control protocols deterministically by option order (default direct MRP > AirPlay-tunneled MRP > Companion), can derive an AirPlay tunnel attempt on port 7000 from a Companion-only discovery when reusable HAP credentials exist, returns `ConnectResult` with primary/active protocols and attempts, and aggregates per-protocol errors if none connect. Single-protocol options stay strict; `ConnectStrategy.allAllowed` attaches every usable allowed protocol.
- **Pairing/settings persistence**: `PairingHandler.finish()` returns `PairingResult`; `ATVSettings.apply(_:)` copies the paired service identifier and credentials into the correct protocol bucket.
- **Preflight policy helpers**: `AppleTVConfiguration.connectability(settings:)`, `connectableProtocols(settings:)`, `preferredPairingService(...)`, and `ServiceInfo.effectivePairingStatus(settings:)` expose local pairing/connectability policy for apps before opening network sessions.
- **State-backed capabilities**: Companion and MRP capability providers report unavailable until setup, protocol events, or successful requests prove optional/stateful surfaces are usable. MRP output-device list and mutation capabilities become available after route state arrives from direct MRP or AirPlay-tunneled MRP. Optional setup failures are exposed with capability diagnostics when a public capability is affected. Relayed state prefers `.available` over `.unavailable` across protocols.
- **Media commands**: `MediaCommandController` exposes broad MediaRemote command discovery and sending. Direct MRP maps `SupportedCommands` into `MediaCommandInfo`; commands requiring unmodeled queue/session/language payloads stay unsupported.
- **Diagnostic discovery**: `ATVClient.scanWithDiagnostics` preserves discovered devices while exposing non-fatal Bonjour browser/resolver failures and empty TXT records. Unfiltered scans include `_sleep-proxy._udp` and mark matching configurations `deepSleep`.
- **Structured timeouts**: `ATVError.operationTimeout` carries `TimeoutContext` with protocol, operation, request identifier, and duration.
- **Actor-based concurrency**: `MessageDispatcher` uses Swift actors for thread-safe pub-sub messaging
- **Async/await throughout**: All I/O and protocol communication is async

### Module Layout

- `Sources/SwiftATV/` -- Library source
  - `ATVClient.swift` -- Public facade API: `scan`, `scanWithDiagnostics`, `ConnectOptions`/`ConnectResult`, and `pair`
  - `Constants.swift` -- All enums (`ATVProtocol`, `Capability`, `MediaRemoteCommand`, `DeviceState`, etc.)
  - `Interfaces.swift` -- Swift protocol definitions (`RemoteControl`, `CapabilityProvider`, `MediaCommandController`, `AppleTVDevice`, etc.)
  - `Configuration.swift` -- `AppleTVConfiguration`, `ServiceInfo`, pairing status, and connectability helpers
  - `DiscoveryIdentifiers.swift` -- Bonjour TXT identifier lookup priority
  - `Errors.swift` -- `ATVError`, `TimeoutContext`, and `ConnectionAttemptError` (all public API is `throws(ATVError)`)
  - `Settings.swift` -- `ATVSettings`, local `ClientIdentitySettings`, pairing-result apply helper, and protocol-specific credential settings
  - `Support/` -- Binary codecs: OPACK, TLV8, BinaryPlistArchive, ChaCha20-Poly1305, AirPlay HAP session encryption
  - `Core/` -- Relayer, Facade, Scanner (NWBrowser plus NetService TXT resolution, sleep-proxy discovery, identifier-first merge, and diagnostics), MessageDispatcher
  - `Auth/`
    - `HAPCredentials.swift` -- Long-term key storage/serialization
    - `SRPAuth.swift` -- Ed25519/X25519/HKDF primitives
    - `SRP.swift` -- SRP-6a client matching pyatv's srptools conventions
    - `HAPPairing.swift` -- Stepwise `HAPPairSetupHandler` + `HAPPairVerifyHandler`
  - `Protocols/AirPlay/` -- AirPlay 2 support (HAP pair-setup, pair-verify over `/pair-verify`, encrypted control/event/data channels, RTSP SETUP/RECORD, DataStream MRP tunnel, feedback keepalive)
  - `Protocols/Companion/` -- Companion protocol (TCP framing, OPACK messages, HID commands, SRP pair-setup, pair-verify, apps, event-driven capability/state store, selected media commands, best-effort touch, power, audio volume, RTI text entry, connection-lost propagation; output-device mutation is intentionally handled by MRP/AirPlay-tunneled MRP)
  - `Protocols/MRP/` -- MRP implementation (checked-in SwiftProtobuf-generated pyatv messages in `Generated/`, source `.proto` files in `Protobuf/`, transport abstraction, direct TCP framing, pair-setup/pair-verify, interfaces, broad media commands, active playback refresh, player-state actor, output-device state and mutation, optional setup diagnostics, connection-lost propagation)
  - `SwiftATV.docc/` -- DocC catalog (landing page + Getting Started)
- `Tests/SwiftATVTests/` -- Test suite (XCTest ported from pyatv + Swift Testing for new features)

### Protocol Implementation Status

| Protocol | Status | Notes |
|----------|--------|-------|
| Companion | Implemented | Connection, pair-setup (SRP-6a), pair-verify, NoOp keepalive, remote, apps, users, selected media commands, event-backed power/audio/media-control/keyboard state, best-effort touch, connection-lost events, Bonjour identifiers/metadata. Output-device mutation is intentionally MRP/AirPlay-tunneled MRP only |
| MRP | Implemented | Direct TCP/protobuf connection plus AirPlay 2 DataStream tunnel transport, pair-setup, pair-verify for direct MRP, remote, broad MediaRemote command query/send, actively refreshed metadata, push, power, audio, output-device state/mutation, optional setup diagnostics, connection-lost events |
| AirPlay | Implemented | AirPlay 2 HAP pair-setup, pair-verify, encrypted control/event/data channels, timeout-bounded HTTP/RTSP setup, and MRP tunneling including output-device mutation |

## Code Conventions

- Swift protocols map to Python ABCs (e.g., `RemoteControl`, `AppleTVDevice`)
- `ATVProtocol` avoids collision with Swift's `Protocol` keyword
- The public facade is `ATVClient`; do not add a public type named `SwiftATV`,
  because consumers use `SwiftATV` as the module qualifier.
- All public types conform to `Sendable`
- `ATVProtocol` only contains supported connection/pairing surfaces; do not add compatibility-only protocol cases without implementation
- `ATVSettings.clientIdentity` is the local controller/app identity sent to Apple TV protocols, including the stable Companion Rapport identifier used in `_systemInfo`. Do not copy the target Apple TV's identifiers into it; connect and pair validate against that mistake.
- `Codable` on all settings/config types for JSON persistence
- `AsyncStream` replaces Python callback-based listeners

## Dependencies

- `apple/swift-nio` -- `NIOCore` and `NIOPosix` for TCP protocol connections
- `CryptoKit` -- Ed25519, X25519, ChaCha20-Poly1305, HKDF on Apple platforms
- `apple/swift-crypto` -- Linux-only fallback for CryptoKit-compatible primitives
- `apple/swift-protobuf` -- Runtime serialization for checked-in MRP protobuf Swift sources. `SwiftProtobufPlugin` is not used by consumers.
- `attaswift/BigInt` -- 3072-bit modular exponentiation for SRP-6a pair-setup

## Docs stay in sync with the code (required)

Any change that touches public API, adds a feature, adds/removes a
dependency, or shifts build requirements **must** be reflected in all of the
following in the same change:

- `CHANGELOG.md` — add a bullet under the appropriate heading. New work goes
  under `## [Unreleased]` until the next release section is cut.
- `README.md` — update the Features list, Requirements, Installation
  snippet, Quick Start examples, Protocol status table, Project Structure
  tree, and Testing section as applicable.
- `Sources/SwiftATV/SwiftATV.docc/SwiftATV.md` — keep the overview blurb
  and the `## Topics` lists in sync with the public types that actually
  exist. Every public type should appear under one of the Topics headings.
- `Sources/SwiftATV/SwiftATV.docc/GettingStarted.md` — if the new work
  changes how a caller scans, pairs, or connects, update the walkthrough
  and the code snippets. Snippets must compile against the current API
  (e.g. `ATVSettings` is a struct, so examples use `var settings` and
  `settings.setCredentials(_:for:)`, not `let`).
- `AGENTS.md` (this file) — update the Module Layout, Protocol
  Implementation Status, Dependencies, and any architecture notes.
- The source-level DocC `///` comments on any type you changed.

Release version bumps should update `ATVClient.version` in
`Sources/SwiftATV/ATVClient.swift` and the changelog release heading/compare
links. README and DocC installation snippets intentionally avoid hard-coded
release numbers.

Treat this as a pre-commit checklist, not a polish pass. Docs that drift
from the code are worse than no docs — they silently mislead.

## Test Sources

Most tests are ported from pyatv's test suite (XCTest):
- `ConstantsTests` <- `tests/test_convert.py`
- `ConfigurationTests` <- `tests/test_conf.py`
- `InterfaceTests` <- `tests/test_interface.py`
- `OPACKTests` <- `tests/support/test_opack.py` plus SwiftATV object-reference,
  strict-consumption, and integer-overflow regression coverage.
- `TLV8Tests` <- `tests/auth/test_hap_tlv8.py` plus strict auth-path
  malformed-input regression coverage.
- `ChaCha20Tests` <- `tests/support/test_chacha20.py` plus generic
  `nonceLength` validation coverage.
- `DeviceInfoTests` <- `tests/support/test_device_info.py` plus Companion TXT
  model/version metadata coverage.
- `CompanionTests` <- `tests/protocols/companion/test_companion.py`
- `CompanionServiceTests.swift` -- Companion setup resilience when optional
  `_sessionStart` / `_touchStart` requests time out after credentialed
  pair-verify and required setup succeeds, plus Companion NoOp keepalive.
- `ScannerTests.swift` -- SwiftATV Bonjour TXT pairing requirement parsing,
  Companion identifier extraction, NetService TXT resolver path, scan timeout
  validation, diagnostics, sleep-proxy deep-sleep discovery, and
  identifier-first scan-result merging.
- `SwiftATVConnectTests.swift` -- connect-path validation for requested,
  malformed-credential, deterministic first-usable priority, service-credential,
  mandatory-credential, Companion credential requirements, all-allowed strategy,
  Companion-derived AirPlay tunnel attempts, connect-result metadata, aggregate
  failures, and client-identity collision checks.
- `FacadeEventTests.swift` -- facade connection-closed, connection-lost, and
  per-protocol primary/secondary close behavior plus unsupported metadata
  errors.
- `ErrorsTests.swift` -- structured `ATVError.operationTimeout` context.
- `SettingsTests.swift` -- settings Codable/accessors and pairing-result
  persistence helpers.
- `TimingTests.swift` -- shared timeout-to-nanoseconds conversion guards.
- `MRPPlayerStateTests` <- `tests/protocols/mrp/test_player_state.py` plus
  SwiftATV MRP framing/message, volume, command-result, varint overflow,
  active metadata refresh, optional setup diagnostics, capability-state gating,
  output-device mutation/state ingestion, and pair-verify-final-response
  coverage.
- `ConsumerCompileTests.swift` -- consumer-style imports proving
  module-qualified types such as `SwiftATV.ATVProtocol`, typed capabilities,
  media command options, and scan diagnostics compile alongside `ATVClient`
  facade calls.

New work uses Swift Testing (`import Testing`, `@Test`, `@Suite`) — both
frameworks coexist in the same target. Current Swift Testing suites:
- `SRPTests.swift` -- SRP-6a primitives, canned vector generated by running
  pyatv's `srptools` dependency. Regenerate with the Python script in
  `CHANGELOG.md`'s commit history if the SRP math ever changes.
- `HAPPairSetupTests.swift` -- HAP pair-setup state machine (M1/M3/error
  TLV handling + ordering checks). Uses the internal `init(clientIdentifier:,
  srpPrivateKey:)` test seam for determinism.
- `PlayingDescriptionTests.swift` -- `Playing.description` edge cases.
- `CompanionAuthEnvelopeTests.swift` -- Companion pair-setup/pair-verify
  OPACK envelope shape and auth error surfacing.
- `CompanionConnectionTests.swift` -- Companion auth frame routing,
  encrypted-frame AAD, close/drain races, and pending-request drain behavior.
- `CompanionTextInputSessionTests.swift` -- Companion RTI text-input
  binary-plist encoding/decoding for `_tiStart` and `_tiC` payloads.
- `AirPlayTests.swift` -- Swift Testing coverage for AirPlay feature parsing,
  pairing requirement parsing, pairing handler creation, HAP session
  chunking/authentication, and DataStream protobuf payload parsing.
- `TestHelpers.swift` -- shared `Data(hex:)` / `.hex` helpers.
