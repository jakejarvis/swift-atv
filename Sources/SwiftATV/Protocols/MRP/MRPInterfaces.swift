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
        let options = MRPMessages.commandOptions(position: interval)
        try await `protocol`.sendCommand(.skipForward, options: options)
    }

    public func skipBackward(interval: TimeInterval) async throws(ATVError) {
        let options = MRPMessages.commandOptions(position: interval)
        try await `protocol`.sendCommand(.skipBackward, options: options)
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

/// Metadata provider backed by direct MRP now-playing and playback-queue messages.
public final class MRPMetadata: @unchecked Sendable, ATVMetadata {
    private let `protocol`: MRPProtocolHandler
    private let playerState: MRPPlayerState
    private let stateStore: MRPStateStore

    init(protocol: MRPProtocolHandler, playerState: MRPPlayerState, stateStore: MRPStateStore) {
        self.protocol = `protocol`
        self.playerState = playerState
        self.stateStore = stateStore
    }

    public var deviceID: String? { nil }

    public var artworkID: String { stateStore.artworkID }

    public var currentApp: App? { stateStore.currentApp }

    public func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo? {
        try await `protocol`.artwork(width: width, height: height)
    }

    public func playing() async throws(ATVError) -> Playing {
        await playerState.currentPlaying
    }
}

/// Push updater that streams MRP now-playing changes from `MRPPlayerState`.
public final class MRPPushUpdater: @unchecked Sendable, PushUpdater {
    private let playerState: MRPPlayerState
    private let lock = NSLock()
    private var _isActive = false
    private var _stream: AsyncStream<Playing>?

    init(playerState: MRPPlayerState) {
        self.playerState = playerState
    }

    public var isActive: Bool { lock.withLock { _isActive } }

    public var playingStream: AsyncStream<Playing> {
        lock.lock()
        if let stream = _stream {
            lock.unlock()
            return stream
        }
        lock.unlock()
        let stream = AsyncStream<Playing> { continuation in
            Task {
                for await state in await self.playerState.pushStream() {
                    continuation.yield(state)
                }
                continuation.finish()
            }
        }
        lock.withLock {
            _stream = stream
        }
        return stream
    }

    public func start(initialDelay: Int) async throws(ATVError) {
        if initialDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(initialDelay) * 1_000_000_000)
        }
        lock.withLock { _isActive = true }
    }

    public func stop() async {
        lock.withLock { _isActive = false }
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

/// Audio controller backed by direct MRP volume and output-context messages.
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
        try await `protocol`.send(MRPMessages.setVolume(level, deviceID: device?.identifier))
    }

    public func volumeUp() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0xE9, action: .singleTap)
    }

    public func volumeDown() async throws(ATVError) {
        try await `protocol`.sendHID(usagePage: 12, usage: 0xEA, action: .singleTap)
    }

    public func addOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        try await `protocol`.send(MRPMessages.modifyOutputContext(adding: deviceIDs))
    }

    public func removeOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        try await `protocol`.send(MRPMessages.modifyOutputContext(removing: deviceIDs))
    }

    public func setOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        try await `protocol`.send(MRPMessages.modifyOutputContext(setting: deviceIDs))
    }
}

/// Feature provider for direct MRP interfaces and supported-command updates.
public final class MRPFeatures: @unchecked Sendable, FeatureProvider {
    private let stateStore: MRPStateStore

    init(stateStore: MRPStateStore) {
        self.stateStore = stateStore
    }

    public func featureInfo(_ feature: FeatureName) -> FeatureInfo {
        if let info = stateStore.featureInfo(feature) {
            return info
        }
        if Self.alwaysAvailable.contains(feature) {
            return FeatureInfo(state: .available)
        }
        if Self.metadata.contains(feature) {
            return FeatureInfo(state: .available)
        }
        return FeatureInfo(state: .unsupported)
    }

    public func allFeatures(includeUnsupported: Bool) -> [FeatureName: FeatureInfo] {
        Dictionary(
            uniqueKeysWithValues: FeatureName.allCases.compactMap { feature in
                let info = featureInfo(feature)
                if !includeUnsupported, info.state == .unsupported {
                    return nil
                }
                return (feature, info)
            })
    }

    public func inState(_ states: [FeatureState], features: FeatureName...) -> Bool {
        features.allSatisfy { states.contains(featureInfo($0).state) }
    }

    private static let alwaysAvailable: Set<FeatureName> = [
        .up, .down, .left, .right, .select, .menu, .home, .homeHold, .topMenu,
        .volumeUp, .volumeDown, .suspend, .wakeUp, .powerState, .turnOn, .turnOff,
        .pushUpdates, .volume, .setVolume, .outputDevices, .addOutputDevices,
        .removeOutputDevices, .setOutputDevices,
    ]

    private static let metadata: Set<FeatureName> = [
        .title, .artist, .album, .genre, .totalTime, .position, .artwork, .app,
        .seriesName, .seasonNumber, .episodeNumber, .contentIdentifier, .iTunesStoreIdentifier,
    ]
}
