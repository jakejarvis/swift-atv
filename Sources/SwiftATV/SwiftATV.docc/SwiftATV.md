# ``SwiftATV``

A Swift library for discovering, pairing with, and controlling Apple TV and
AirPlay devices.

## Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv). It
exposes a unified ``AppleTVDevice`` interface that routes each command to the
highest-priority protocol that supports it. MRP provides protobuf-based direct
remote control, metadata, push updates, power, audio, and HAP pairing; Companion
provides modern app, keyboard-focus, touch, power, audio-volume, and
remote-control support. Companion text entry and output-device mutation, plus
DMAP, AirPlay, and RAOP, are planned.

All public methods are typed-throws (`async throws(ATVError)`), so you can
catch `ATVError` exhaustively without worrying about stray NIO or CryptoKit
errors leaking through.

```swift
import SwiftATV

let devices = try await SwiftATV.scan(timeout: 5)
guard let device = devices.first else { return }

let atv = try await SwiftATV.connect(device)
try await atv.remoteControl.home()
try await atv.remoteControl.play()
await atv.close()
```

> Important: SwiftATV is pre-1.0. The API will change as DMAP, AirPlay, and
> RAOP protocols come online. Pin to a specific minor version in
> your `Package.swift` and review the [CHANGELOG](https://github.com/jakejarvis/swift-atv/blob/main/CHANGELOG.md)
> before upgrading.

## Topics

### Getting started

- <doc:GettingStarted>

### Discovery

- ``ATVScanner``
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
- ``KeyboardController``
- ``TouchController``
- ``AppsController``
- ``UserAccountsController``
- ``FeatureProvider``

### Pairing and authentication

- ``PairingHandler``
- ``CompanionPairingHandler``
- ``CompanionPairVerifyHandler``
- ``MRPPairingHandler``
- ``HAPPairSetupHandler``
- ``HAPPairVerifyHandler``
- ``HAPCredentials``

### Protocols

- ``ATVProtocol``
- ``CompanionService``
- ``CompanionProtocolHandler``
- ``CompanionConnection``
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
