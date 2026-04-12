# ``SwiftATV``

A Swift library for discovering, pairing with, and controlling Apple TV and
AirPlay devices.

## Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv). It
exposes a unified ``AppleTVDevice`` interface that routes each command to the
highest-priority protocol that supports it — Companion is the primary backend
today, with MRP, DMAP, AirPlay, and RAOP planned.

```swift
import SwiftATV

let devices = try await SwiftATV.scan(timeout: 5)
guard let device = devices.first else { return }

let atv = try await SwiftATV.connect(device)
try await atv.remoteControl.home()
try await atv.remoteControl.play()
await atv.close()
```

> Important: SwiftATV is pre-1.0. The API will change as the MRP, DMAP,
> AirPlay, and RAOP protocols come online. Pin to a specific minor version in
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
- ``KeyboardController``
- ``TouchController``
- ``AppsController``
- ``UserAccountsController``
- ``FeatureProvider``

### Pairing and authentication

- ``PairingHandler``
- ``HAPCredentials``

### Protocols

- ``ATVProtocol``
- ``CompanionService``
- ``CompanionProtocolHandler``
- ``CompanionConnection``

### Support types

- ``OPACK``
- ``TLV8``
- ``ChaCha20Cipher``

### Errors

- ``ATVError``
