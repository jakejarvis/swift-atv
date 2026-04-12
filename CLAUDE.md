# CLAUDE.md

## Project Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv), a Python library for controlling Apple TV and AirPlay devices. It uses a multi-protocol facade architecture to provide a unified interface across 5 communication protocols (MRP, DMAP, Companion, AirPlay, RAOP).

## Build & Test

```bash
swift build          # Build the library
swift test           # Run all tests (12 test files)
swift package clean  # Clean build artifacts
```

No special setup or environment variables needed. Requires Swift 6.1+ and macOS 13+/iOS 16+.

The package uses `swift-tools-version: 6.1` with strict concurrency enabled by default. Classes that manage mutable internal state use `@unchecked Sendable` with encapsulated synchronization. The `MessageDispatcher` and `CompanionProtocolHandler` use Swift actors for safe concurrency.

## Architecture

### Key Design Patterns

- **Facade**: `FacadeAppleTV` in `Core/Facade.swift` unifies all protocols behind `AppleTVDevice`
- **Relayer**: `Core/Relayer.swift` routes method calls to the highest-priority protocol (MRP > DMAP > Companion > AirPlay > RAOP)
- **Actor-based concurrency**: `MessageDispatcher` uses Swift actors for thread-safe pub-sub messaging
- **Async/await throughout**: All I/O and protocol communication is async

### Module Layout

- `Sources/SwiftATV/` -- Library source (23 files)
  - `Constants.swift` -- All enums (`ATVProtocol`, `FeatureName`, `DeviceState`, etc.)
  - `Interfaces.swift` -- Swift protocol definitions (`RemoteControl`, `AppleTVDevice`, etc.)
  - `Configuration.swift` -- `AppleTVConfiguration` and `ServiceInfo`
  - `Support/` -- Binary codecs: OPACK, TLV8, ChaCha20-Poly1305
  - `Core/` -- Relayer, Facade, Scanner (NWBrowser), MessageDispatcher
  - `Auth/` -- HAP credentials, SRP key exchange, pair-verify
  - `Protocols/Companion/` -- Full Companion protocol (TCP framing, OPACK messages, HID commands)
  - `Protocols/MRP/` -- MRP stub (message types defined, implementation pending)
- `Tests/SwiftATVTests/` -- Test suite (12 files, ported from pyatv's Python tests)

### Protocol Implementation Status

| Protocol | Status | Notes |
|----------|--------|-------|
| Companion | Complete | Connection, pairing, all interfaces |
| MRP | Stub | Types defined, needs protobuf compilation |
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
- `apple/swift-protobuf` -- For MRP protocol (protobuf messages)

## Test Sources

Tests are ported from pyatv's test suite. Key mappings:
- `ConstantsTests` <- `tests/test_convert.py`
- `ConfigurationTests` <- `tests/test_conf.py`
- `InterfaceTests` <- `tests/test_interface.py`
- `OPACKTests` <- `tests/support/test_opack.py`
- `TLV8Tests` <- `tests/auth/test_hap_tlv8.py`
- `ChaCha20Tests` <- `tests/support/test_chacha20.py`
- `DeviceInfoTests` <- `tests/support/test_device_info.py`
- `CompanionTests` <- `tests/protocols/companion/test_companion.py`
- `MRPPlayerStateTests` <- `tests/protocols/mrp/test_player_state.py`
