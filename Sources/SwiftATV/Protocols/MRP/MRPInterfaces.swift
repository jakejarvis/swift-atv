import Foundation

/// Remote-control implementation backed by direct MRP commands and HID events.
public final class MRPRemoteControl: @unchecked Sendable, RemoteControl {
    private let `protocol`: MRPProtocolHandler

    init(protocol: MRPProtocolHandler) {
        self.protocol = `protocol`
    }

    public func up(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x8C, action: action)
    }

    public func down(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x8D, action: action)
    }

    public func left(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x8B, action: action)
    }

    public func right(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x8A, action: action)
    }

    public func play() async throws(ATVError) { try await `protocol`.sendCommand(.play) }
    public func playPause() async throws(ATVError) { try await `protocol`.sendCommand(.togglePlayPause) }
    public func pause() async throws(ATVError) { try await `protocol`.sendCommand(.pause) }
    public func stop() async throws(ATVError) { try await `protocol`.sendCommand(.stop) }
    public func next() async throws(ATVError) { try await `protocol`.sendCommand(.nextTrack) }
    public func previous() async throws(ATVError) { try await `protocol`.sendCommand(.previousTrack) }

    public func select(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x89, action: action)
    }

    public func menu(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x86, action: action)
    }

    public func volumeUp() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0xE9, action: .singleTap)
    }

    public func volumeDown() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0xEA, action: .singleTap)
    }

    public func home(action: InputAction) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0x40, action: action)
    }

    public func homeHold() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0x40, action: .hold)
    }

    public func topMenu() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0x60, action: .singleTap)
    }

    public func suspend() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x82, action: .singleTap)
    }

    public func wakeUp() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x83, action: .singleTap)
    }

    public func skipForward(interval: TimeInterval) async throws(ATVError) {
        let options = MRPMessages.commandOptions(skipInterval: interval)
        try await `protocol`.sendCommand(
            .skipForward,
            options: options.hasSendableMRPFields ? options : nil
        )
    }

    public func skipBackward(interval: TimeInterval) async throws(ATVError) {
        let options = MRPMessages.commandOptions(skipInterval: interval)
        try await `protocol`.sendCommand(
            .skipBackward,
            options: options.hasSendableMRPFields ? options : nil
        )
    }

    public func setPosition(_ position: Int) async throws(ATVError) {
        let options = MRPMessages.commandOptions(position: TimeInterval(position))
        try await `protocol`.sendCommand(.seekToPlaybackPosition, options: options)
    }

    public func setShuffle(_ state: ShuffleState) async throws(ATVError) {
        let options = MRPMessages.commandOptions(shuffle: state)
        try await `protocol`.sendCommand(.changeShuffleMode, options: options)
    }

    public func setRepeat(_ state: RepeatState) async throws(ATVError) {
        let options = MRPMessages.commandOptions(repeatState: state)
        try await `protocol`.sendCommand(.changeRepeatMode, options: options)
    }

    public func channelUp() async throws(ATVError) {
        throw ATVError.notSupported("Channel up is not supported by direct MRP")
    }

    public func channelDown() async throws(ATVError) {
        throw ATVError.notSupported("Channel down is not supported by direct MRP")
    }

    public func screensaver() async throws(ATVError) {
        throw ATVError.notSupported("Screensaver is not supported by direct MRP")
    }

    public func guide() async throws(ATVError) {
        throw ATVError.notSupported("Guide is not supported by direct MRP")
    }

    public func controlCenter() async throws(ATVError) {
        throw ATVError.notSupported("Control Center is not supported by direct MRP")
    }
}

protocol MRPProtocolHandling: Sendable {
    func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo?
    func refreshPlaying() async throws(ATVError) -> Playing
}

/// Metadata provider backed by direct MRP now-playing and playback-queue messages.
///
/// `playing()` actively refreshes the playback queue over MRP before returning
/// the current snapshot.
public final class MRPMetadata: @unchecked Sendable, ATVMetadata {
    private let protocolHandler: any MRPProtocolHandling
    private let stateStore: MRPStateStore

    init(protocol protocolHandler: any MRPProtocolHandling, playerState: MRPPlayerState, stateStore: MRPStateStore) {
        self.protocolHandler = protocolHandler
        self.stateStore = stateStore
    }

    public var deviceID: String? { nil }

    public var artworkID: String { stateStore.artworkID }

    public var currentApp: App? { stateStore.currentApp }

    public func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo? {
        try await protocolHandler.artwork(width: width, height: height)
    }

    public func playing() async throws(ATVError) -> Playing {
        try await protocolHandler.refreshPlaying()
    }
}

/// Push updater that streams MRP now-playing changes from `MRPPlayerState`.
public final class MRPPushUpdater: @unchecked Sendable, PushUpdater {
    private let playerState: MRPPlayerState
    private let lock = NSLock()
    private var _isActive = false
    private var continuations: [UUID: AsyncStream<Playing>.Continuation] = [:]
    private var forwardTask: Task<Void, Never>?

    init(playerState: MRPPlayerState) {
        self.playerState = playerState
    }

    deinit {
        forwardTask?.cancel()
    }

    public var isActive: Bool { lock.withLock { _isActive } }

    public var playingStream: AsyncStream<Playing> {
        AsyncStream<Playing> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            let id = UUID()
            let shouldReplay = lock.withLock {
                continuations[id] = continuation
                return _isActive
            }
            if shouldReplay {
                Task { [weak self] in
                    await self?.publishCurrentPlayingIfActive(to: id)
                }
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func start(initialDelay: Int) async throws(ATVError) {
        if initialDelay > 0 {
            let duration = TimeInterval(initialDelay)
            let delay = try timeoutNanoseconds(from: duration, parameterName: "initialDelay")
            let context = TimeoutContext(
                protocol: .mrp,
                operation: "startPushUpdates",
                requestID: "initialDelay",
                duration: duration
            )
            do {
                try await Task.sleep(nanoseconds: delay)
            } catch is CancellationError {
                throw ATVError.operationCancelled(context)
            } catch {
                throw ATVError.wrap(error)
            }
        }
        let shouldPublishInitial = lock.withLock {
            let wasActive = _isActive
            _isActive = true
            if forwardTask == nil {
                forwardTask = Task { [weak self, playerState] in
                    for await state in await playerState.pushStream() {
                        self?.publishIfActive(state)
                    }
                }
            }
            return !wasActive
        }
        if shouldPublishInitial {
            await publishCurrentPlayingIfActive()
        }
    }

    public func stop() async {
        let task = lock.withLock {
            _isActive = false
            let task = forwardTask
            forwardTask = nil
            return task
        }
        task?.cancel()
    }

    private func publishCurrentPlayingIfActive() async {
        let playing = await playerState.currentPlaying
        publishIfActive(playing)
    }

    private func publishCurrentPlayingIfActive(to id: UUID) async {
        let playing = await playerState.currentPlaying
        let continuation = lock.withLock { _isActive ? continuations[id] : nil }
        continuation?.yield(playing)
    }

    private func publishIfActive(_ playing: Playing) {
        let targets = lock.withLock {
            _isActive ? Array(continuations.values) : []
        }
        for continuation in targets {
            continuation.yield(playing)
        }
    }
}

/// Power controller backed by direct MRP wake and suspend commands.
public final class MRPPower: @unchecked Sendable, PowerController {
    private let `protocol`: MRPProtocolHandler
    private let stateStore: MRPStateStore

    init(protocol: MRPProtocolHandler, stateStore: MRPStateStore) {
        self.protocol = `protocol`
        self.stateStore = stateStore
    }

    public var powerState: PowerState { get async { stateStore.powerState } }
    public var powerStateStream: AsyncStream<PowerState> { stateStore.powerStateStream() }

    public func turnOn(awaitNewState: Bool) async throws(ATVError) {
        try await `protocol`.send(MRPMessages.wakeDevice())
    }

    public func turnOff(awaitNewState: Bool) async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 1, usage: 0x82, action: .singleTap)
    }
}

/// Audio controller backed by MRP volume and output-context messages.
public final class MRPAudio: @unchecked Sendable, AudioController {
    private let `protocol`: MRPProtocolHandler
    private let stateStore: MRPStateStore

    init(protocol: MRPProtocolHandler, stateStore: MRPStateStore) {
        self.protocol = `protocol`
        self.stateStore = stateStore
    }

    public var volume: Float { get async { stateStore.volume } }
    public var volumeStream: AsyncStream<Float> { stateStore.volumeStream() }
    public var outputDevices: [OutputDevice] { get async { stateStore.outputDevices } }
    public var outputDevicesStream: AsyncStream<[OutputDevice]> { stateStore.outputDevicesStream() }

    public func setVolume(_ level: Float, device: OutputDevice?) async throws(ATVError) {
        guard let deviceID = device?.identifier ?? stateStore.volumeDeviceID else {
            throw ATVError.protocolError("MRP volume target is unavailable")
        }
        try await `protocol`.send(MRPMessages.setVolume(level, deviceID: deviceID))
    }

    public func volumeUp() async throws(ATVError) {
        if stateStore.supportsAbsoluteVolume, !stateStore.supportsRelativeVolume {
            try await setVolume(min(stateStore.volume + 5, 100), device: nil)
            return
        }
        try await `protocol`.sendHID(usagePage: 12, usage: 0xE9, action: .singleTap, flush: false)
    }

    public func volumeDown() async throws(ATVError) {
        if stateStore.supportsAbsoluteVolume, !stateStore.supportsRelativeVolume {
            try await setVolume(max(stateStore.volume - 5, 0), device: nil)
            return
        }
        try await `protocol`.sendHID(usagePage: 12, usage: 0xEA, action: .singleTap, flush: false)
    }

    public func addOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        let revision = stateStore.outputDevicesRevision
        try await `protocol`.send(MRPMessages.modifyOutputContext(adding: deviceIDs))
        try await waitForOutputDevicesUpdate(after: revision)
    }

    public func removeOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        let revision = stateStore.outputDevicesRevision
        try await `protocol`.send(MRPMessages.modifyOutputContext(removing: deviceIDs))
        try await waitForOutputDevicesUpdate(after: revision)
    }

    public func setOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        let revision = stateStore.outputDevicesRevision
        try await `protocol`.send(MRPMessages.modifyOutputContext(setting: deviceIDs))
        try await waitForOutputDevicesUpdate(after: revision)
    }

    private func waitForOutputDevicesUpdate(after revision: Int, timeout: TimeInterval = 5) async throws(ATVError) {
        let deadline = Date().addingTimeInterval(timeout)
        let context = TimeoutContext(
            protocol: .mrp,
            operation: "waitForState",
            requestID: "outputDevices",
            duration: timeout
        )
        while stateStore.outputDevicesRevision <= revision {
            if Date() >= deadline {
                return
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch is CancellationError {
                throw ATVError.operationCancelled(context)
            } catch {
                throw ATVError.wrap(error)
            }
        }
    }
}

/// Media command controller backed by direct MRP SendCommand messages.
public final class MRPMediaCommands: @unchecked Sendable, MediaCommandController {
    private let `protocol`: MRPProtocolHandler
    private let stateStore: MRPStateStore

    init(protocol: MRPProtocolHandler, stateStore: MRPStateStore) {
        self.protocol = `protocol`
        self.stateStore = stateStore
    }

    public func commandInfo(_ command: MediaRemoteCommand) -> MediaCommandInfo {
        if !command.isSendableOverMRP {
            return MediaCommandInfo(
                state: .unsupported,
                diagnostic: "Media command \(command) requires options SwiftATV does not model yet"
            )
        }
        return stateStore.commandInfo(command) ?? MediaCommandInfo(state: .unavailable)
    }

    public func allCommands(includeUnsupported: Bool) -> [MediaRemoteCommand: MediaCommandInfo] {
        Dictionary(
            uniqueKeysWithValues: MediaRemoteCommand.allCases.compactMap { command in
                let info = commandInfo(command)
                if !includeUnsupported, info.state == .unsupported {
                    return nil
                }
                return (command, info)
            })
    }

    public func send(_ command: MediaRemoteCommand, options: MediaCommandOptions) async throws(ATVError) {
        guard command.isSendableOverMRP else {
            throw ATVError.notSupported("Media command \(command) requires options SwiftATV does not model yet")
        }
        guard let mrpCommand = command.mrpCommand else {
            throw ATVError.notSupported("Media command \(command) is not supported by MRP")
        }
        let options = MRPMessages.commandOptions(options)
        let commandOptions = options.hasSendableMRPFields ? options : nil
        try await `protocol`.sendCommand(mrpCommand, options: commandOptions)
    }
}

extension CommandOptions {
    fileprivate var hasSendableMRPFields: Bool {
        hasPlaybackPosition
            || hasSkipInterval
            || hasPlaybackRate
            || hasRating
            || hasNegative
            || hasShuffleMode
            || hasRepeatMode
    }
}

/// Capability provider for direct MRP interfaces, supported-command updates,
/// and optional setup diagnostics.
public final class MRPCapabilities: @unchecked Sendable, CapabilityProvider {
    private let stateStore: MRPStateStore

    init(stateStore: MRPStateStore) {
        self.stateStore = stateStore
    }

    public func capabilityInfo(_ capability: Capability) -> CapabilityInfo {
        if case .mediaCommand(let command) = capability {
            if !command.isSendableOverMRP {
                return MRPMediaCommandsPlaceholder.commandInfo(command).capabilityInfo
            }
            return stateStore.capabilityInfo(capability)
                ?? MRPMediaCommandsPlaceholder.commandInfo(command).capabilityInfo
        }
        if let info = stateStore.capabilityInfo(capability) {
            return info
        }
        if Self.remoteHIDCapabilities.contains(capability) {
            return CapabilityInfo(state: .available)
        }
        if Self.powerCapabilities.contains(capability) {
            return CapabilityInfo(state: stateStore.powerState == .unknown ? .unavailable : .available)
        }
        if capability == .push(.updates) {
            return CapabilityInfo(state: stateStore.clientUpdatesConfigured ? .available : .unavailable)
        }
        if case .audio(let audioCapability) = capability, Self.audioCapabilities.contains(capability) {
            return CapabilityInfo(state: audioCapabilityState(audioCapability))
        }
        if Self.outputDeviceCapabilities.contains(capability) {
            return CapabilityInfo(state: stateStore.hasOutputDevicesState ? .available : .unavailable)
        }
        if Self.metadataCapabilities.contains(capability) {
            return CapabilityInfo(state: stateStore.hasPlayingSnapshot ? .available : .unavailable)
        }
        return CapabilityInfo(state: .unsupported)
    }

    public func allCapabilities(includeUnsupported: Bool) -> [Capability: CapabilityInfo] {
        Dictionary(
            uniqueKeysWithValues: Capability.allCases.compactMap { capability in
                let info = capabilityInfo(capability)
                if !includeUnsupported, info.state == .unsupported {
                    return nil
                }
                return (capability, info)
            })
    }

    public func inState(_ states: [CapabilityState], capabilities: Capability...) -> Bool {
        capabilities.allSatisfy { states.contains(capabilityInfo($0).state) }
    }

    private func audioCapabilityState(_ capability: AudioCapability) -> CapabilityState {
        switch capability {
        case .volume:
            return stateStore.hasVolumeState ? .available : .unavailable
        case .setVolume:
            return stateStore.supportsAbsoluteVolume ? .available : .unavailable
        case .volumeUp, .volumeDown:
            return stateStore.supportsVolumeStep ? .available : .unavailable
        case .outputDevices, .addOutputDevices, .removeOutputDevices, .setOutputDevices:
            return stateStore.hasOutputDevicesState ? .available : .unavailable
        }
    }

    private static let remoteHIDCapabilities: Set<Capability> = [
        .remote(.up), .remote(.down), .remote(.left), .remote(.right), .remote(.select), .remote(.menu),
        .remote(.home), .remote(.homeHold), .remote(.topMenu), .remote(.suspend), .remote(.wakeUp),
    ]

    private static let powerCapabilities: Set<Capability> = [
        .power(.state), .power(.turnOn), .power(.turnOff),
    ]

    private static let audioCapabilities: Set<Capability> = [
        .audio(.volume), .audio(.setVolume), .audio(.volumeUp), .audio(.volumeDown),
    ]

    private static let outputDeviceCapabilities: Set<Capability> = [
        .audio(.outputDevices), .audio(.addOutputDevices), .audio(.removeOutputDevices), .audio(.setOutputDevices),
    ]

    private static let metadataCapabilities: Set<Capability> = [
        .metadata(.currentApp), .metadata(.artwork), .metadata(.artworkID),
        .metadata(.playing), .metadata(.title), .metadata(.artist), .metadata(.album),
        .metadata(.genre), .metadata(.totalTime), .metadata(.position),
        .metadata(.shuffle), .metadata(.repeatState), .metadata(.seriesName),
        .metadata(.seasonNumber), .metadata(.episodeNumber), .metadata(.contentIdentifier),
        .metadata(.iTunesStoreIdentifier),
    ]
}

private enum MRPMediaCommandsPlaceholder {
    static func commandInfo(_ command: MediaRemoteCommand) -> MediaCommandInfo {
        if command.isSendableOverMRP {
            return MediaCommandInfo(state: .unavailable)
        }
        return MediaCommandInfo(
            state: .unsupported,
            diagnostic: "Media command \(command) requires options SwiftATV does not model yet"
        )
    }
}
