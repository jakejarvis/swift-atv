# AGENTS.md

## Project Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv), a Python library for controlling Apple TV and AirPlay devices. It uses a multi-protocol facade architecture to provide a unified interface across 5 communication protocols (MRP, DMAP, Companion, AirPlay, RAOP).

## Build & Test

```bash
swift build          # Build the library
swift test           # Run all tests (XCTest + Swift Testing)
swift package clean  # Clean build artifacts

# Lint (CI runs the same command with --strict)
swift format lint --recursive Sources Tests
```

No special setup or environment variables needed. Requires Swift 6.0+ and macOS 13+/iOS 16+.

The package uses `swift-tools-version: 6.0` with Swift 6 language mode (`swiftLanguageModes: [.v6]`) and strict concurrency enabled. All public protocol methods in `Interfaces.swift` are typed-throws (`async throws(ATVError)`); NIO, CryptoKit, and SwiftProtobuf errors are wrapped into `ATVError` at the Companion / MRP / ChaCha20Cipher / HAPPairing boundaries. Classes that manage mutable internal state use `@unchecked Sendable` with encapsulated synchronization. The `MessageDispatcher`, `CompanionProtocolHandler`, `MRPProtocolHandler`, `CompanionPower`/`Audio`/`Keyboard`, and `MRPPlayerState` use Swift actors for safe concurrency.

## Architecture

### Key Design Patterns

- **Facade**: `FacadeAppleTV` in `Core/Facade.swift` unifies all protocols behind `AppleTVDevice`
- **Relayer**: `Core/Relayer.swift` routes method calls to the highest-priority protocol (MRP > DMAP > Companion > AirPlay > RAOP)
- **Actor-based concurrency**: `MessageDispatcher` uses Swift actors for thread-safe pub-sub messaging
- **Async/await throughout**: All I/O and protocol communication is async

### Module Layout

- `Sources/SwiftATV/` -- Library source
  - `Constants.swift` -- All enums (`ATVProtocol`, `FeatureName`, `DeviceState`, etc.)
  - `Interfaces.swift` -- Swift protocol definitions (`RemoteControl`, `AppleTVDevice`, etc.)
  - `Configuration.swift` -- `AppleTVConfiguration` and `ServiceInfo`
  - `Errors.swift` -- `ATVError` (all public API is `throws(ATVError)`)
  - `Support/` -- Binary codecs: OPACK, TLV8, ChaCha20-Poly1305
  - `Core/` -- Relayer, Facade, Scanner (NWBrowser), MessageDispatcher
  - `Auth/`
    - `HAPCredentials.swift` -- Long-term key storage/serialization
    - `SRPAuth.swift` -- Ed25519/X25519/HKDF primitives
    - `SRP.swift` -- SRP-6a client matching pyatv's srptools conventions
    - `HAPPairing.swift` -- Stepwise `HAPPairSetupHandler` + `HAPPairVerifyHandler`
  - `Protocols/Companion/` -- Full Companion protocol (TCP framing, OPACK messages, HID commands, SRP pair-setup, pair-verify)
  - `Protocols/MRP/` -- Direct MRP implementation (SwiftProtobuf-generated pyatv messages, TCP framing, pair-setup/pair-verify, interfaces, player-state actor)
  - `SwiftATV.docc/` -- DocC catalog (landing page + Getting Started)
- `Tests/SwiftATVTests/` -- Test suite (XCTest ported from pyatv + Swift Testing for new features)

### Protocol Implementation Status

| Protocol | Status | Notes |
|----------|--------|-------|
| Companion | Complete | Connection, pair-setup (SRP-6a), pair-verify, all interfaces |
| MRP | Implemented | Direct TCP/protobuf connection, pair-setup, pair-verify, remote, metadata, push, power, audio. AirPlay tunnel/streaming not included |
| DMAP | Not started | Legacy protocol |
| AirPlay | Not started | Streaming |
| RAOP | Not started | Audio streaming |

## Code Conventions

- Swift protocols map to Python ABCs (e.g., `RemoteControl`, `AppleTVDevice`)
- `ATVProtocol` avoids collision with Swift's `Protocol` keyword
- All public types conform to `Sendable`
- Enum raw values match pyatv's `const.py` exactly (important for wire compatibility)
- `Codable` on all settings/config types for JSON persistence
- `AsyncStream` replaces Python callback-based listeners

## Dependencies

- `apple/swift-nio` -- TCP/UDP for protocol connections
- `apple/swift-nio-ssl` -- TLS support
- `apple/swift-crypto` -- Ed25519, X25519, ChaCha20-Poly1305, HKDF
- `apple/swift-protobuf` -- Generates and serializes MRP protobuf messages from pyatv `.proto` files
- `attaswift/BigInt` -- 3072-bit modular exponentiation for SRP-6a pair-setup

## Docs stay in sync with the code (required)

Any change that touches public API, adds a feature, adds/removes a
dependency, or shifts build requirements **must** be reflected in all of the
following in the same change:

- `CHANGELOG.md` — add a bullet under the appropriate heading. 0.1.0 is
  unreleased, so new work goes into `## [0.1.0] - unreleased` until it's
  tagged; after that it goes under `## [Unreleased]`.
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

Treat this as a pre-commit checklist, not a polish pass. Docs that drift
from the code are worse than no docs — they silently mislead.

## Test Sources

Most tests are ported from pyatv's test suite (XCTest):
- `ConstantsTests` <- `tests/test_convert.py`
- `ConfigurationTests` <- `tests/test_conf.py`
- `InterfaceTests` <- `tests/test_interface.py`
- `OPACKTests` <- `tests/support/test_opack.py`
- `TLV8Tests` <- `tests/auth/test_hap_tlv8.py`
- `ChaCha20Tests` <- `tests/support/test_chacha20.py`
- `DeviceInfoTests` <- `tests/support/test_device_info.py`
- `CompanionTests` <- `tests/protocols/companion/test_companion.py`
- `ScannerTests.swift` -- SwiftATV Bonjour TXT pairing requirement parsing
- `MRPPlayerStateTests` <- `tests/protocols/mrp/test_player_state.py` plus SwiftATV MRP framing/message, volume, and command-result coverage

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
- `TestHelpers.swift` -- shared `Data(hex:)` / `.hex` helpers.
