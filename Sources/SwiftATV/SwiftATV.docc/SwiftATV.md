# ``SwiftATV``

A Swift library for discovering, pairing with, and controlling Apple TV and
AirPlay devices.

## Overview

SwiftATV is a Swift port of [pyatv](https://github.com/postlund/pyatv). It
exposes a unified ``AppleTVDevice`` interface that routes each command to the
highest-priority protocol that supports it. MRP provides protobuf-based direct
remote control, actively refreshed metadata, push updates, power, audio,
output-device mutation, and HAP pairing; AirPlay 2 can pair with HAP and tunnel
MRP traffic, including output-device mutation, when direct MRP is unavailable;
Companion provides modern app, keyboard text input/focus, best-effort touch,
power, audio-volume, and remote-control support. Connection setup is
deterministic for implemented control protocols (direct MRP, then
AirPlay-tunneled MRP, then Companion) and returns as soon as one usable protocol
connects unless ``ConnectStrategy/allAllowed`` is requested. Companion-only
discoveries with reusable HAP credentials can still attempt AirPlay-tunneled MRP
on the default AirPlay port. The result
describes the primary protocol, active protocols, setup attempts, and optional
setup diagnostics.

The facade tracks lifecycle per protocol. Closing or failing a non-primary
secondary protocol unregisters only that protocol; the device emits
`connectionLost` when the primary or last active protocol closes. Capability
availability is state-backed, so optional Companion and MRP surfaces are
reported unavailable until setup, events, or successful requests prove them
usable. Output-device list and mutation capabilities become available when direct
MRP or AirPlay-tunneled MRP reports route state.

``ATVSettings/clientIdentity`` describes the local controller or app identity
sent during pairing and protocol setup, including the stable Companion Rapport
identifier sent in `_systemInfo`. It must not be copied from the target Apple
TV's identifiers.

Discovery resolves Bonjour TXT records with each live service, merges services
by stable device identifiers, including Companion-only TXT identifiers, and can
optionally return scan diagnostics for non-fatal browser, resolver, or empty-TXT
failures. Filtered and unfiltered scans include sleep-proxy discovery so
sleeping devices can be marked with ``AppleTVConfiguration/deepSleep`` when
Bonjour provides a usable device identifier.

SwiftATV requires Swift 6.3 or newer.

All public methods are typed-throws (`async throws(ATVError)`), so you can
catch `ATVError` exhaustively without worrying about stray NIO or CryptoKit
errors leaking through.

```swift
import SwiftATV

let devices = try await ATVClient.scan(timeout: 5)
guard let device = devices.first else { return }

let connection = try await ATVClient.connect(device)
let atv = connection.device
try await atv.remoteControl.home()
try await atv.remoteControl.play()
await atv.close()
```

> Important: SwiftATV is pre-1.0. The API may change as protocol internals
> evolve. Pin a release version or exact revision in
> your `Package.swift` and review the [CHANGELOG](https://github.com/jakejarvis/swift-atv/blob/main/CHANGELOG.md)
> before upgrading.

## Topics

### Getting started

- ``ATVClient``
- ``ConnectOptions``
- ``ConnectStrategy``
- ``ConnectResult``
- ``ConnectAttempt``
- ``ProtocolSetupDiagnostic``
- ``defaultProtocolRequestTimeout``
- <doc:GettingStarted>

### Discovery

- ``ATVScanner``
- ``BonjourServiceType``
- ``ATVScanResult``
- ``ATVScanDiagnostic``
- ``ATVScanDiagnosticKind``
- ``AppleTVConfiguration``
- ``ServiceInfo``
- ``EffectivePairingStatus``
- ``ServiceConnectability``
- ``ServiceConnectabilityStatus``
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
- ``CapabilityProvider``
- ``MediaCommandController``
- ``Capability``
- ``CapabilityInfo``
- ``CapabilityState``
- ``RemoteCapability``
- ``MediaRemoteCommand``
- ``MediaCommandInfo``
- ``MediaCommandOptions``
- ``MetadataCapability``
- ``PushCapability``
- ``StreamCapability``
- ``PowerCapability``
- ``AudioCapability``
- ``AppsCapability``
- ``AccountsCapability``
- ``KeyboardCapability``
- ``TouchCapability``

### Pairing and authentication

- ``PairingHandler``
- ``PairingResult``
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
- ``ATVSettings``
- ``ClientIdentitySettings``
- ``ProtocolSettings``
- ``AirPlaySettings``
- ``CompanionSettings``
- ``MrpSettings``
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
- ``CompanionCapabilities``
- ``CompanionMediaCommands``
- ``MRPService``
- ``MRPConnection``
- ``MRPPlayerState``
- ``MRPRemoteControl``
- ``MRPMetadata``
- ``MRPPushUpdater``
- ``MRPPower``
- ``MRPAudio``
- ``MRPCapabilities``
- ``MRPMediaCommands``
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
- ``TimeoutContext``
- ``ConnectionAttemptError``
