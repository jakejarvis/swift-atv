# Changelog

All notable changes to SwiftATV will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: minor version bumps may contain breaking changes.

## [Unreleased]

## [0.1.0] - unreleased

Initial pre-release. API is unstable and will change before 1.0.

### Fixed during the 0.1.0 development cycle (pre-tag)

- **Pair-verify is now actually functional.** Three bugs in
  `CompanionPairVerifyHandler.verify()` together meant it had never
  worked against a real Apple TV:
  1. It sent `.pvStart` and waited for another `.pvStart` frame, but the
     device replies to all auth `*_Start` frames on the corresponding
     `*_Next` channel. Caught by Codex adversarial review.
     Now handled by `CompanionConnection.defaultResponseType(for:)`,
     which maps `.pvStart` → `.pvNext` / `.psStart` → `.psNext` as the
     default for `sendAndReceive`. Matches pyatv's `exchange_auth`.
  2. It sent raw TLV8 bytes on the wire instead of wrapping them in the
     Companion OPACK auth envelope `{_pd, _auTy: 4}` that pyatv's
     `CompanionPairVerifyProcedure` uses. Caught while verifying (1).
  3. It also wrongly kept `_auTy: 4` on the PV_Next frame even though
     pyatv drops the auth-type marker after PV_Start. Caught while
     verifying (2).
- **Race conditions in `sendAndReceive` / `sendRequest`.** Both now
  register their response waiter **before** performing the network
  send. Previously a fast device reply (one that landed between the
  send completing and the waiter being installed) could be silently
  dropped, causing spurious timeouts. Installation is synchronous under
  lock/actor isolation so the waiter is guaranteed to exist before any
  bytes hit the wire.
- **Double-waiter guard on `CompanionConnection.waitForFrame`.**
  Attempts to register a second concurrent waiter for the same frame
  type now throw `.invalidState` instead of silently clobbering the
  first continuation.
- **Pair-setup `Name` TLV tag.** `HAPPairSetupHandler.m5(displayName:)`
  was emitting the display-name dictionary under `.flags` (0x13)
  instead of the correct `.name` (0x11). Added `.name` to `TLVTag` and
  fixed `m5` to use it. This only affected callers that passed a
  display name to be shown in the Apple TV's Settings > Users &
  Accounts entry.

Supporting changes that landed with the fixes above:
- `CompanionConnection.defaultResponseType(for:)` — public static
  mapping that exposes the auth-frame asymmetry. Callers who need the
  old symmetric behavior can still pass an explicit `waitType:` override.
- Shared `wrapCompanionAuthEnvelope` / `unwrapCompanionAuthEnvelope`
  helpers at the top of `CompanionPairing.swift`, used by both
  `CompanionPairingHandler` and `CompanionPairVerifyHandler`. The
  auth-type entry is optional so PV_Next can omit `_auTy` while
  PS_Next keeps `_pwTy`.
- `CompanionConnection.handleReceivedData` is now `internal` (was
  `fileprivate`) so the new frame-injection tests can drive it without
  a real NIO channel.
- New regression tests:
  - `CompanionConnectionTests` — pins the frame-type mapping
    (`.psStart → .psNext`, etc.) and exercises the full round-trip via
    `waitForFrame` + injected synthetic frames.
  - `CompanionAuthEnvelopeTests` — pins the exact OPACK envelope bytes
    for PS_Start / PV_Start / PV_Next, and exercises error-TLV surfacing
    through `unwrapCompanionAuthEnvelope`.

### Added

- Device discovery via Bonjour/mDNS (`ATVScanner`, `SwiftATV.scan`).
- Multi-protocol facade (`FacadeAppleTV`) routing commands to the
  highest-priority implementation via `Relayer`.
- **Typed throws** on all public protocol requirements
  (`async throws(ATVError)`). NIO and CryptoKit errors are wrapped into
  `ATVError` at the Companion / ChaCha20Cipher / HAPPairing boundaries
  (~20 wrap sites). Consumers get exhaustive `catch` matching.
- **Full Companion protocol** implementation:
  - TCP frame connection with ChaCha20-Poly1305 encryption.
  - **HAP SRP-6a pair-setup** end-to-end. `SwiftATV.pair` drives the full
    6-step handshake; `CompanionPairingHandler` surfaces credentials via
    `handler.credentials` after `finish()`, and the caller is responsible
    for persisting them into `ATVSettings.protocols.companion.credentials`.
    The `CompanionPairingHandler.begin` / `.finish` methods wrap each
    inner TLV in the Companion OPACK envelope `{_pd: tlv8, _pwTy: 1}` and
    send over `PS_Start` / `PS_Next` with the asymmetric framing pyatv's
    `CompanionProtocol.exchange_auth` uses.
  - HAP pair-verify exchange and credential persistence.
  - Remote control, apps, user accounts, power, audio, keyboard, touch,
    features.
- `HAPPairSetupHandler` state machine (`Auth/HAPPairing.swift`) with the
  stepwise API `m1()` → `m3(fromResponse:pin:)` → `m5(fromResponse:)` →
  `finish(fromResponse:)`. Verifies the accessory's Ed25519 signature in M6
  (a divergence from pyatv, which has an explicit `TODO: verify signature`
  in `hap_srp.py::step4`).
- `SRPClient` (`Auth/SRP.swift`) implementing SRP-6a against the RFC 5054
  Appendix A 3072-bit group with SHA-512. Byte-level compatible with pyatv's
  `srptools` dependency — the padding conventions are subtly non-standard
  (`u` is computed on `PAD(A) || PAD(B)` but `M1` and `K` use minimal
  big-endian bytes). Verified against a canned pyatv-produced vector.
- HAP authentication primitives: TLV8 codec, Ed25519/X25519 + HKDF-SHA512,
  ChaCha20-Poly1305 with fixed-nonce entry points shared between the
  pair-setup and pair-verify handlers.
- OPACK binary serialization codec.
- MRP protocol type definitions and a `MRPPlayerState` actor (connection
  implementation pending).
- Swift 6 language mode with strict concurrency. `CompanionPower`,
  `CompanionAudio`, `CompanionKeyboard`, `MRPPlayerState`,
  `CompanionProtocolHandler`, and `MessageDispatcher` are actors;
  `CompanionConnection`, `FacadeAppleTV`, `ChaCha20Cipher`, and the HAP
  handlers use `@unchecked Sendable` with `NSLock`/`withLock` at NIO/crypto
  boundaries (documented inline).
- Linux CI coverage. `.github/workflows/ci.yml` runs `swift build` +
  `swift test` on `macos-15` and the `swift:6.0-jammy` / `swift:6.1-jammy`
  containers on `ubuntu-latest` (Swift 6.0 and 6.1), plus a
  `swift format lint --strict` job. Verified locally via Docker.
- DocC catalog (`Sources/SwiftATV/SwiftATV.docc/`) with a landing page and
  Getting Started article.
- `.spi.yml` for Swift Package Index hosting.
- Test suite: 212 XCTest cases ported from pyatv (codecs, crypto,
  configuration, relayer, settings, interfaces, device info, Companion
  feature availability) plus 16 Swift Testing cases covering SRP-6a (6),
  HAP pair-setup (6), and `Playing.description` (4).

### Dependencies

- `apple/swift-nio` — TCP/UDP for protocol connections.
- `apple/swift-nio-ssl` — TLS support.
- `apple/swift-crypto` — Ed25519, X25519, ChaCha20-Poly1305, HKDF.
- `apple/swift-protobuf` — For MRP protocol (protobuf messages, future).
- `attaswift/BigInt` — 3072-bit modular exponentiation for SRP-6a
  pair-setup. swift-crypto has no primitives for this.

### Known limitations

- **MRP, DMAP, AirPlay, RAOP** protocols are not yet implemented. Only
  Companion is functional end-to-end — which is sufficient for remote
  control, apps, power, audio, keyboard, and touch. Metadata, streaming,
  and real-time audio are future work.

[Unreleased]: https://github.com/jakejarvis/swift-atv/compare/0.1.0...HEAD
[0.1.0]: https://github.com/jakejarvis/swift-atv/releases/tag/0.1.0
