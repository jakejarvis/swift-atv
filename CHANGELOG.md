# Changelog

All notable changes to SwiftATV will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: minor version bumps may contain breaking changes.

## [Unreleased]

### Planned

- **Typed throws on the public API.** Protocols in `Interfaces.swift` currently use
  untyped `throws`. Moving them to `throws(ATVError)` requires wrapping NIO and
  SwiftCrypto errors at the Companion/MRP boundary first. Tracked for a future minor.

## [0.1.0] - 2026-04-12

Initial pre-release. API is unstable and will change before 1.0.

### Added

- Device discovery via Bonjour/mDNS (`ATVScanner`, `SwiftATV.scan`).
- Multi-protocol facade (`FacadeAppleTV`) routing commands to the highest-priority
  implementation via `Relayer`.
- Full **Companion** protocol implementation:
  - TCP frame connection with ChaCha20-Poly1305 encryption.
  - HAP pair-verify exchange and credential persistence.
  - Remote control, apps, user accounts, power, audio, keyboard, touch, features.
- HAP authentication primitives: TLV8 codec, SRP key exchange, Ed25519/X25519 + HKDF.
- OPACK binary serialization codec.
- MRP protocol type definitions (connection implementation pending).
- 212-test suite ported from pyatv covering codecs, crypto, configuration, relayer,
  settings, interfaces, device info, and Companion feature availability.
- Swift 6 language mode with strict concurrency.

### Known limitations

- **MRP, DMAP, AirPlay, RAOP** protocols are not yet implemented. Only Companion
  is functional end-to-end.
- Companion pairing (`CompanionPairingHandler.finish`) is a placeholder — it does
  not perform the full SRP proof exchange yet.
- No Linux CI coverage yet; the library builds on Darwin platforms.

[Unreleased]: https://github.com/jakejarvis/swift-atv/compare/0.1.0...HEAD
[0.1.0]: https://github.com/jakejarvis/swift-atv/releases/tag/0.1.0
