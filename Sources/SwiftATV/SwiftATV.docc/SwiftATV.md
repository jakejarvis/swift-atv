# ``SwiftATV``

A Swift library for discovering, pairing with, and controlling Apple TV and
AirPlay devices.

## Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv). It
exposes a unified ``AppleTVDevice`` interface that routes each command to the
highest-priority protocol that supports it. MRP provides protobuf-based direct
remote control, actively refreshed metadata, push updates, power, audio, and
HAP pairing; AirPlay 2 can pair with HAP and tunnel MRP remote-control traffic
when direct MRP is unavailable; Companion provides modern app, keyboard text
input/focus, touch, power, audio-volume, and remote-control support. Connection
setup is deterministic for implemented control protocols (direct MRP, then
AirPlay-tunneled MRP, then Companion). AirPlay media streaming is still planned.

Discovery resolves Bonjour TXT records with each live service, merges services
by stable device identifiers, including Companion-only TXT identifiers, and can
optionally return scan diagnostics for non-fatal browser, resolver, or empty-TXT
failures.

SwiftATV requires Swift 6.3 or newer.

All public methods are typed-throws (`async throws(ATVError)`), so you can
catch `ATVError` exhaustively without worrying about stray NIO or CryptoKit
errors leaking through.

```swift
import SwiftATV

let devices = try await ATVClient.scan(timeout: 5)
guard let device = devices.first else { return }

let atv = try await ATVClient.connect(device)
try await atv.remoteControl.home()
try await atv.remoteControl.play()
await atv.close()
```

> Important: SwiftATV is pre-1.0. The API may change as AirPlay media streaming
> and protocol internals evolve. Pin a release version or exact revision in
> your `Package.swift` and review the [CHANGELOG](https://github.com/jakejarvis/swift-atv/blob/main/CHANGELOG.md)
> before upgrading.

## Topics

### Getting started

- ``ATVClient``
- <doc:GettingStarted>

### Discovery

- ``ATVScanner``
- ``ATVScanResult``
- ``ATVScanDiagnostic``
- ``ATVScanDiagnosticKind``
- ``AppleTVConfiguration``
- ``ServiceInfo``
- ``DeviceInfo``

### Device control

- ``AppleTVDevice``
- ``RemoteControl``
- ``PowerController``
- ``AudioController``
- ``ATVMetadata``
- ``PushUpdater``
- ``DeviceEvent``
- ``KeyboardController``
- ``TouchController``
- ``AppsController``
- ``UserAccountsController``
- ``FeatureProvider``

### Pairing and authentication

- ``PairingHandler``
- ``PairingCodeDirection``
- ``CompanionPairingHandler``
- ``CompanionPairVerifyHandler``
- ``MRPPairingHandler``
- ``AirPlayPairingHandler``
- ``HAPPairSetupHandler``
- ``HAPPairVerifyHandler``
- ``HAPCredentials``

### Protocols

- ``ATVProtocol``
- ``AirPlayVersion``
- ``MrpTunnelMode``
- ``CompanionService``
- ``CompanionProtocolHandler``
- ``CompanionConnection``
- ``CompanionKeyboard``
- ``CompanionRemoteControl``
- ``CompanionApps``
- ``CompanionUserAccounts``
- ``CompanionPower``
- ``CompanionAudio``
- ``CompanionTouch``
- ``CompanionFeatures``
- ``MRPService``
- ``MRPConnection``
- ``MRPPlayerState``
- ``MRPRemoteControl``
- ``MRPMetadata``
- ``MRPPushUpdater``
- ``MRPPower``
- ``MRPAudio``
- ``MRPFeatures``
- ``MRPFrameType``
- ``MRPMessageType``
- ``MRPConnectionState``
- ``MRPVarint``

### Support types

- ``OPACK``
- ``TLV8``
- ``ChaCha20Cipher``

### Errors

- ``ATVError``
