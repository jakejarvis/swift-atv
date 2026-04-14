# Changelog

All notable changes to SwiftATV will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Pre-1.0: minor version bumps may contain breaking changes.

## [Unreleased]

### Added

- `ATVClient.connect` now takes `ConnectOptions` and returns `ConnectResult`
  with the connected device, primary protocol, active protocols, protocol
  setup attempts, and optional setup diagnostics. `ConnectStrategy.allAllowed`
  can attach every usable allowed protocol instead of returning after the
  first success.
- `PairingHandler.finish()` now returns `PairingResult`, and
  `ATVSettings.apply(_:)` / `applying(_:)` persist the paired service
  identifier and credentials into the correct protocol settings bucket.
- `AppleTVConfiguration.connectability(settings:)`,
  `connectableProtocols(settings:protocols:)`, `preferredPairingService(...)`,
  and `ServiceInfo.effectivePairingStatus(settings:)` expose SwiftATV's local
  pairing/connectability policy to consumers. Connectable protocol results are
  returned in the requested protocol order.
- Discovery now scans `_sleep-proxy._udp` during both filtered and unfiltered
  scans and marks
  matching configurations as `deepSleep` when a sleep-proxy record can be
  associated with a device identifier.
- `ClientIdentitySettings.rapportIdentifier` stores the stable local
  Rapport-style identifier sent as Companion `_systemInfo._i`.

### Changed

- `ATVError.operationTimeout` now carries a structured `TimeoutContext`
  containing protocol, operation, request identifier, and duration instead of
  forcing callers to parse operation names from strings.
- MRP output-device mutation now mirrors pyatv by sending both legacy and
  cluster-aware output-context fields, uses AirPlay-tunneled MRP the same as
  direct MRP, and derives output-device capability state from both
  output-device updates and device-info group state.
- Removed the flat `FeatureName` / `FeatureProvider` API in favor of typed
  `Capability` values exposed through `AppleTVDevice.capabilities`.
- Added `AppleTVDevice.mediaCommands` with `MediaRemoteCommand`,
  `MediaCommandInfo`, and `MediaCommandOptions`; MRP maps `SupportedCommands`
  into command availability, while commands needing unmodeled queue, session,
  or language payloads remain explicitly unsupported.
- Relayed capability and media-command state now prefers `.available` over
  higher-priority `.unavailable`, so a lower-priority protocol can expose a
  usable feature that a higher-priority protocol reports as temporarily
  unavailable.

### Fixed

- Companion encryption now uses pyatv-compatible 12-byte nonce layout, so
  encrypted Companion sessions continue working after the first frame.
- OPACK now accepts and emits the canonical `0x07` representation for `-1`.
- Malformed AirPlay `Content-Length` values and Companion text-input UID
  indexes now throw protocol errors instead of risking parser traps.
- Non-finite MRP playback timestamps and durations are ignored instead of
  trapping while building now-playing metadata.
- Companion touch timestamps now use a monotonic clock, and swipe coordinates
  are clamped before integer conversion to avoid public-input traps.
- Malformed Companion session identifiers, huge MRP push initial delays, and
  invalid MRP message timestamp inputs now fail or clamp instead of trapping on
  integer conversion/overflow.
- AirPlay HTTP/RTSP setup now applies real TCP connect and response timeouts,
  preventing AirPlay services that accept TCP but never send a full response
  from hanging connection fallback.
- Direct MRP and Companion setup now apply `ConnectOptions.requestTimeout` to
  TCP connects and setup request/response exchanges, preventing a reachable
  host with a stalled protocol service from hanging connection fallback.
- AirPlay HTTP/RTSP response timeouts now cover the full response deadline
  instead of resetting after every partial socket read.
- `HAPCredentials.parse(_:)` now matches pyatv's two-component legacy
  credential format (`clientIdentifier:ltsk`), and
  `HAPCredentials.transient` now uses the pyatv-compatible sentinel layout.
- Companion request timeout tasks are cancelled when their request succeeds,
  matching the lower-level Companion and MRP waiter lifecycle and avoiding
  stale sleeper tasks.
- Companion-only metadata now throws `.notSupported("Metadata not available")`
  instead of returning an empty idle `Playing()` value.
- Companion setup now starts `_sessionStart` before best-effort `_touchStart`
  and treats a `_sessionStart` timeout as non-terminal, so basic Companion
  remote control can still connect when optional session setup stalls.
- Companion optional `_sessionStart` and `_touchStart` degradation is now
  surfaced in `ConnectResult.setupDiagnostics` and capability diagnostics for
  affected touch capabilities.
- Companion `_systemInfo` now sends a stable per-client Rapport identifier for
  `_i`, matching pyatv's tvOS 18.4+ connection fix.
- Duplicate sparse service records no longer erase discovered identifiers,
  TXT properties, credentials, or pairing requirements from existing services.
- Removing Companion as a secondary protocol now closes the removed Companion
  service instead of only unregistering it from facade relayers.
- MRP, AirPlay, and Companion pairing setup now close partially opened
  connections when handler creation or repeated AirPlay `begin()` calls fail.
- AirPlay MRP tunnel setup now closes partially opened control/event/data
  channels when setup fails before the tunnel is fully registered.
- Companion-only discoveries with reusable HAP credentials can now attempt the
  AirPlay MRP tunnel on the default AirPlay port, matching Apple TVs that only
  advertise `_companion-link._tcp` but still accept AirPlay control traffic.
- Companion connections now send periodic NoOp keepalive frames after setup.
- MRP HID event payloads now match pyatv's 60-byte layout for hardware-level
  key events such as mute.
- MRP playback queue requests now ask for content item assets so artwork can be
  returned with now-playing updates.
- MRP push streams now cancel their player-state bridge task when the consumer
  terminates the stream.

## [0.3.0] - 2026-04-14

### Added

- `ConnectionAttemptError` records every protocol attempted by auto-connect
  when no usable protocol connects.
- AirPlay 2 HAP pair-setup is now available via `ATVClient.pair(...,
  protocol: .airPlay, settings:)`, and AirPlay 2 MRP tunneling can carry MRP
  remote control, metadata, push, power, and audio over the AirPlay data
  stream. Default connection setup tries direct MRP first, then the AirPlay MRP
  tunnel when available, then Companion.
- Removed the unimplemented legacy/audio compatibility surface from public
  protocol enums, settings, scanner service mappings, connect validation,
  tests, and documentation.
- Companion `KeyboardController` now implements text get, clear, append, and
  set using the `_tiStart` / `_tiC` RTI text-input flow, including native UID
  binary-plist payloads for insert and atomic replace operations.

### Changed

- Installation snippets no longer hard-code the current release number, so
  release bumps only update `ATVClient.version` and changelog metadata.
- `FacadeAppleTV` now tracks protocol lifecycle per protocol. A failed or
  closed optional secondary protocol no longer tears down an already usable
  primary connection.
- Companion capability availability is now backed by observed Companion state.
  Media controls, volume, power, apps, accounts, keyboard focus, and touch are
  unavailable until setup, events, or successful requests prove them usable.
- Companion power and audio no longer mutate local state optimistically.
  Power waits for real status when requested, and volume up/down use HID volume
  buttons plus volume events instead of synthetic absolute volume changes.
- MRP capability availability is now more conservative for metadata, push, audio,
  output devices, and power state, and optional startup failures are exposed as
  capability diagnostics instead of being silently swallowed.
- Documentation now describes AirPlay support as the implemented AirPlay 2 MRP
  tunnel instead of as a broader AirPlay media surface.
- `ATVSettings.info` was replaced by `ATVSettings.clientIdentity`, which now
  has stable local controller defaults and is validated so callers do not send
  the Apple TV's own identifiers back as the controller identity.
- `ATVClient.connect` now returns after the first usable protocol connects
  instead of waiting for secondary protocol setup. If all automatic attempts
  fail, the final `connectionFailed` error includes every attempted protocol
  and its underlying error.
- Companion connections now fail fast with `noCredentials` when credentials
  are missing; Companion no longer attempts unauthenticated setup.

### Fixed

- Companion setup no longer fails the whole connection when `_touchStart`
  times out after pair-verify and `_systemInfo` succeed. Touch support is left
  unavailable, while remote control, apps, power, audio, and keyboard
  interfaces continue to register.

## [0.2.2] - 2026-04-13

### Added

- `ATVScanDiagnosticKind.emptyTXTRecord` reports Bonjour services that resolve
  without TXT metadata.

### Fixed

- Live Bonjour scans now resolve `.service` endpoints with `NetService` so TXT
  records are fetched with host and port data instead of relying on
  `NWBrowser.Result.metadata`. Companion services discovered in live scans now
  receive `rpMRtID` / `rpAD` / `rpHN` / `rpFl` / `rpMd` / `rpVr` TXT values,
  and `_device-info._tcp` resolution no longer opens TCP flows to port `0`.

## [0.2.1] - 2026-04-13

### Added

- `ATVClient.scanWithDiagnostics` / `ATVScanner.scanWithDiagnostics` return
  discovered devices together with non-fatal Bonjour browser and resolver
  diagnostics.

### Fixed

- Companion-only Bonjour discoveries now use `rpMRtID`, `rpAD`, `rpHN`, and
  `rpHI` TXT values as device/service identifiers, so
  `AppleTVConfiguration.mainIdentifier` is populated for `_companion-link._tcp`
  services. Companion `rpMd` and `rpVr` TXT metadata now populate device model
  and version information when no higher-priority metadata is present.

## [0.2.0] - 2026-04-13

### Added

- `PairingCodeDirection` and `PairingHandler.pairingCodeDirection`, with
  derived `deviceProvidesPin` and `clientPin` helpers, so pairing UI can
  distinguish device-displayed PIN flows from future client-displayed PIN
  flows without protocol-specific guesses.
- Consumer compile coverage proving `import SwiftATV` consumers can write
  module-qualified type references such as `SwiftATV.ATVProtocol` while using
  the renamed facade.

### Changed

- **Breaking:** Renamed the public facade enum from `SwiftATV` to `ATVClient`.
  This removes the type/module name collision that prevented consumers from
  qualifying public types as `SwiftATV.ATVProtocol`,
  `SwiftATV.AppleTVConfiguration`, and similar names. Facade calls are now
  `ATVClient.scan`, `ATVClient.connect`, and `ATVClient.pair`.
- Checked in the generated MRP protobuf Swift sources under
  `Sources/SwiftATV/Protocols/MRP/Generated/` and removed
  `SwiftProtobufPlugin` from the SwiftATV target. Xcode consumers no longer
  need `-skipPackagePluginValidation` for SwiftATV itself.
- Tightened package dependencies: Apple-platform builds use system
  `CryptoKit`; SwiftCrypto's `Crypto` product is now Linux-only,
  `_CryptoExtras` is removed, and the SwiftATV target depends only on the NIO
  products it imports (`NIOCore` and `NIOPosix`).
- Audited Xcode dependency-scan warnings from SwiftNIO. Remaining warnings come
  from SwiftNIO's own package graph in Xcode builds, not from SwiftATV linking
  redundant umbrella NIO products.

### Fixed

- Xcode app consumers no longer need a DerivedData symlink workaround for a
  missing `Crypto_..._PackageProduct.framework` executable. SwiftATV does not
  link SwiftCrypto's `Crypto` product on Apple platforms.

## [0.1.0] - 2026-04-13

Initial 0.1.0 release. SwiftATV remains pre-1.0, so API changes may still land
before 1.0.

### Changed

- `PairingHandler` now exposes protocol-agnostic `credentials` and
  `serializedCredentials`, so callers no longer have to downcast to
  `CompanionPairingHandler` or `MRPPairingHandler` before persisting HAP keys.
- `SwiftATV.connect` now uses deterministic setup order for implemented control
  protocols (MRP before Companion), falls back past failed unfiltered services,
  honors `ServiceInfo.credentials` when `ATVSettings` does not provide
  credentials, and fails mandatory-pairing services with `.noCredentials`
  before opening protocol sessions.
- Discovery now merges scan results by service identifiers before falling back
  to resolved address and exposes `AppleTVConfiguration.allIdentifiers` /
  `matchesIdentifier(_:)`; `scan(identifiers:)` matches any known service
  identifier.
- `MRPMetadata.playing()` now actively refreshes playback state with an MRP
  playback queue request before returning the current `Playing` value, and
  `FacadeAppleTV.deviceEvents` now reports protocol connection loss.
- `SwiftATV.pair` now validates service pairing state before opening a pairing
  connection and rejects disabled, unsupported, or not-needed services with
  typed errors.
- Raised the supported Swift toolchain baseline to Swift 6.3. CI now runs the
  package build and tests on `macos-26` and `swift:6.3-jammy`, and runs
  `swift format lint --strict` with Swift 6.3 so formatter behavior matches the
  supported toolchain.

### Fixed

- **Companion encrypted E_OPACK frames now authenticate the correct
  header.** The 3-byte frame length in the ChaCha20-Poly1305 AAD must
  be the on-wire ciphertext length (`plaintext + 16-byte tag`), not the
  plaintext length. The old ordering meant every encrypted request after
  pair-verify was authenticated against a different header than the one
  sent to the Apple TV.
- **Companion control messages now match pyatv's request/event split.**
  `_hidC` button presses and `_touchStop` are sent as request/response
  messages with XIDs, `_interest` subscriptions are sent as events, and
  all OPACK events now include an XID. Touch clicks now emit the select
  down/up requests plus the `_hidT` click event used by pyatv.
- **Companion discovery now parses the `rpfl` / `rpFl` pairing flags.**
  The scanner uses pyatv's Companion masks (`0x04` disabled,
  `0x4000` PIN pairing supported) instead of looking for a non-existent
  generic `flags` field.
- **MRP command failures are no longer swallowed.** Direct-MRP remote
  commands now inspect `SendCommandResultMessage.sendError`,
  `handlerReturnStatus`, and nested command-result errors, surfacing a
  `.protocolError` instead of returning success for rejected commands.
- **MRP HID holds now release the button.** Hold actions send a down
  event, wait one second, and then send the matching up event, matching
  pyatv's `_send_hid_key` behavior.
- **Audio volume uses percent at the public API boundary.** Companion
  and MRP now translate `0...100` API values to each protocol's native
  normalized `0...1` wire value, and MRP incoming volume updates are
  exposed as percentages.
- **Pair-verify is now actually functional.** Three bugs in
  `CompanionPairVerifyHandler.verify()` together meant it had never
  worked against a real Apple TV:
  1. It sent `.pvStart` and waited for another `.pvStart` frame, but the
     device replies to all auth `*_Start` frames on the corresponding
     `*_Next` channel. Now handled by
     `CompanionConnection.defaultResponseType(for:)`, which maps
     `.pvStart` → `.pvNext` / `.psStart` → `.psNext` as the default for
     `sendAndReceive`. Matches pyatv's `exchange_auth`.
  2. It sent raw TLV8 bytes on the wire instead of wrapping them in the
     Companion OPACK auth envelope `{_pd, _auTy: 4}` that pyatv's
     `CompanionPairVerifyProcedure` uses.
  3. It also wrongly kept `_auTy: 4` on the PV_Next frame even though
     pyatv drops the auth-type marker after PV_Start.
- **Race conditions in `sendAndReceive` / `sendRequest`.** Both now
  register their response waiter **before** performing the network
  send. Previously a fast device reply (one that landed between the
  send completing and the waiter being installed) could be silently
  dropped, causing spurious timeouts. Installation is synchronous under
  lock/actor isolation so the waiter is guaranteed to exist before any
  bytes hit the wire.
- **Facade routing now falls through only on explicit unsupported methods.**
  Remote-control calls try lower-priority protocol implementations when a
  higher-priority implementation throws `.notSupported`, so direct MRP no
  longer hides Companion-only commands such as channel, guide, and control
  center. Feature reporting now merges lower-priority providers for features
  the higher-priority provider marks unsupported, and public setup of
  unimplemented protocol services now fails fast instead of silently doing
  nothing.
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
- **Stale-timeout waiter theft.** A latent bug in the
  waiter-before-send fix that showed up on pair-setup's three-in-a-row
  `.psNext` waits: if the first call's timeout task had not yet woken
  up by the time the second call installed a new waiter for the same
  frame type, the stale timeout task would clobber the new waiter and
  resume it with `operationTimeout`. Fixed by wrapping each waiter in
  a reference-typed `PendingFrameWaiter` with a UUID identity:
  `handleReceivedData` now cancels the waiter's timeout task on
  delivery, and the timeout task itself performs an identity-checked
  removal so a stale task cannot resume a waiter it doesn't own.
  `Task.sleep` calls in the timeout body now use
  `do { try ... } catch { return }` instead of `try?` so cancellation
  actually stops the task. The same treatment is applied to both
  `sendAndReceive` and `waitForFrame`.
- **`CompanionConnection.close()` / connection-closed did not cancel
  pending frame waiters.** If the connection closed mid-handshake, the
  caller would hang on the waiter's continuation until its 5-second
  timeout fired, instead of unblocking immediately. Both the explicit
  `close()` path and the NIO-side `handleConnectionClosed` now drain
  `frameWaiters`, cancel their timeout tasks, and resume each
  continuation with `.connectionLost`.
- **`close()` resumed waiters *after* awaiting the channel close.**
  An earlier version of the close-cancels-waiters fix removed waiters
  from the dictionary synchronously but only resumed their continuations
  after `try? await ch?.close()`. If the NIO close future was slow or
  stalled, callers stayed suspended even though their dict entry was
  gone — and their now-orphaned timeout task would find nothing to
  resume on wake-up. Fixed by extracting a synchronous
  `drainAndResumeWaiters(error:)` helper that does dict removal and
  continuation resume in one uninterruptible step. `close()` calls it
  before any awaited I/O, guaranteeing waiters cannot be stranded
  behind a stuck channel close.
- **Install-after-close race could strand fresh waiters.** A
  `waitForFrame` / `sendAndReceive` call that started just before
  `close()` but hadn't yet reached its install step could install a
  waiter on a connection that had already drained — the waiter would
  then sit until its full timeout (60 seconds for pair-setup) instead
  of unblocking immediately. Fixed with a sticky `isClosed` flag set
  under the same lock as `drainAndResumeWaiters` and
  `handleConnectionClosed`. The install paths now check `isClosed`
  atomically and refuse to register, resuming the caller with
  `.connectionLost` instead. `connect()` is also blocked after close —
  closure is terminal; callers that need to reconnect should allocate
  a fresh `CompanionConnection`.
- **Peer-close left a dead channel installed.** `handleConnectionClosed`
  flipped `isClosed` and drained waiters but never cleared `channel`,
  so a fire-and-forget `send` (e.g. `CompanionProtocolHandler.sendEvent`)
  could still pass `channel != nil` and attempt a write against the
  dead pipe — surfacing a wrapped NIO error (`.internalError`) instead
  of the terminal `.connectionLost` that waiter-based callers see.
  Fixed by clearing `channel = nil` in `handleConnectionClosed` under
  the same lock, and gating `send()` on `isClosed` so it bails before
  touching any retained channel reference.
- **Pair-verify now validates the accessory identifier.** `HAPPairVerifyHandler`
  checks the signed device identifier against the stored ATV identifier when
  credentials include one, rejecting mismatched devices with
  `.authenticationFailed`.
- **OPACK decoding is now robust against real Companion payloads and
  malformed data.** The decoder now supports pyatv-style object
  references (`0xA0...0xC4`), rejects trailing bytes and missing endless
  container terminators, and handles `Int64.min` without trapping in
  negative integer encode/decode paths. Overlarge OPACK lengths and
  negative magnitudes now throw `.invalidData` instead of risking integer
  overflow.
- **HAP TLV8 auth paths now fail strictly on malformed payloads.** Public
  best-effort `TLV8.decode` remains source-compatible, but pair-setup and
  pair-verify now use strict TLV decoding so truncated auth data cannot be
  silently accepted as a partial dictionary.
- **MRP pair-verify now validates the final device response.** Direct MRP
  no longer enables encryption after the client proof if the Apple TV
  replies with a HAP error TLV. Malformed final TLVs now throw
  `.invalidData`; HAP error TLVs throw `.authenticationFailed`.
- **MRP varint and frame parsing no longer rely on overflowing integer
  arithmetic.** Invalid ten-byte varints with too many high bits now throw,
  and the frame assembler checks `payloadLength <= receiveBuffer.count -
  offset` instead of evaluating `offset + payloadLength`.
- **Public timeout inputs now throw instead of trapping.** Scanner,
  Companion request/wait APIs, and MRP waiters validate timeout values as
  finite, non-negative, and representable in nanoseconds before converting
  to `UInt64`.
- **`ChaCha20Cipher(nonceLength: 8)` no longer crashes.** The generic
  cipher now validates nonce length, supports the documented 8-byte
  counter form by constructing a 12-byte ChaCha20-Poly1305 nonce, and
  throws `.invalidData` for unsupported lengths instead of using `try!`.
- **`SwiftATV.connect` no longer returns an inert facade.** Requested
  protocols must have an enabled matching service, unsupported requested
  protocols throw `.notSupported`, and an unfiltered connection must set up
  at least one supported service before returning. Malformed stored HAP
  credentials now fail fast instead of being silently treated as missing.
- **Connection-owned NIO event loop groups are shut down on close.**
  Companion and MRP connections now track whether they created their own
  `MultiThreadedEventLoopGroup` and shut it down on explicit close or peer
  close, avoiding leaked NIO threads after failed pairing/connect attempts.

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
- Direct MRP implementation:
  - SwiftProtobuf generation from pyatv's MRP `.proto` files via
    `SwiftProtobufPlugin`.
  - Varint-framed TCP connection, protobuf extension dispatch, request/response
    waiters, HAP pair-verify, and ChaCha20-Poly1305 encryption using the
    8-byte nonce variant.
  - MRP HAP pair-setup through `MRPPairingHandler`, surfaced by
    `SwiftATV.pair(..., protocol: .mrp)`.
  - Remote control, metadata, push updates, power, audio/output-device
    controls, and feature availability registered into `FacadeAppleTV` with
    MRP priority over Companion.
  - `MRPPlayerState` actor for active client/player tracking, now-playing
    metadata, app/artwork IDs, shuffle/repeat state, and supported-command
    feature mapping.
- Swift 6 language mode with strict concurrency. `CompanionPower`,
  `CompanionAudio`, `CompanionKeyboard`, `MRPPlayerState`,
  `CompanionProtocolHandler`, and `MessageDispatcher` are actors;
  `CompanionConnection`, `FacadeAppleTV`, `ChaCha20Cipher`, and the HAP
  handlers use `@unchecked Sendable` with `NSLock`/`withLock` at NIO/crypto
  boundaries (documented inline).
- Linux CI coverage. `.github/workflows/ci.yml` runs `swift build` +
  `swift test` on `macos-26` and the `swift:6.3-jammy` container on
  `ubuntu-24.04`, plus a Swift 6.3 `swift format lint --strict` job.
- DocC catalog (`Sources/SwiftATV/SwiftATV.docc/`) with a landing page and
  Getting Started article.
- `.spi.yml` for Swift Package Index hosting.
- Test suite: 250 XCTest cases covering pyatv ports and SwiftATV-specific
  integration logic (codecs, crypto,
  configuration, relayer, settings, interfaces, device info, Companion
  feature availability, MRP framing/message/player-state behavior, scanner
  pairing flags and timeout validation, MRP volume/command-result and
  pair-verify-final-response behavior, connect-path validation, OPACK object
  references/malformed-data handling, TLV8 strict auth decoding, and timeout
  conversion behavior) plus 44
  Swift Testing cases covering SRP-6a, HAP pair-setup,
  `Playing.description`, Companion auth envelopes, and Companion connection
  race handling.

### Dependencies

- `apple/swift-nio` — TCP/UDP for protocol connections.
- `apple/swift-nio-ssl` — TLS support.
- `apple/swift-crypto` — Ed25519, X25519, ChaCha20-Poly1305, HKDF.
- `apple/swift-protobuf` — Generates and serializes direct-MRP protobuf
  messages from pyatv's `.proto` definitions.
- `attaswift/BigInt` — 3072-bit modular exponentiation for SRP-6a
  pair-setup. swift-crypto has no primitives for this.

### Known limitations

- Direct MRP and Companion are functional for control-oriented workflows.

[Unreleased]: https://github.com/jakejarvis/swift-atv/compare/0.3.0...HEAD
[0.3.0]: https://github.com/jakejarvis/swift-atv/compare/0.2.2...0.3.0
[0.2.2]: https://github.com/jakejarvis/swift-atv/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/jakejarvis/swift-atv/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/jakejarvis/swift-atv/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/jakejarvis/swift-atv/releases/tag/0.1.0
