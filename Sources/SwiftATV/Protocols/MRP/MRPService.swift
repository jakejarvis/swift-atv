import Foundation

final class MRPStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _volume: Float = 0
    private var _outputDevices: [OutputDevice] = []
    private var _powerState: PowerState = .unknown
    private var _currentApp: App?
    private var _artworkID = ""
    private var _hasVolumeState = false
    private var _hasOutputDevicesState = false
    private var _outputDevicesRevision = 0
    private var _hasPlayingSnapshot = false
    private var _clientUpdatesConfigured = false
    private var featureOverrides: [FeatureName: FeatureInfo] = [:]
    private var setupDiagnostics: [FeatureName: FeatureInfo] = [:]
    private var volumeContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var outputContinuations: [UUID: AsyncStream<[OutputDevice]>.Continuation] = [:]
    private var powerContinuations: [UUID: AsyncStream<PowerState>.Continuation] = [:]

    var volume: Float { lock.withLock { _volume } }
    var outputDevices: [OutputDevice] { lock.withLock { _outputDevices } }
    var powerState: PowerState { lock.withLock { _powerState } }
    var currentApp: App? { lock.withLock { _currentApp } }
    var artworkID: String { lock.withLock { _artworkID } }
    var hasVolumeState: Bool { lock.withLock { _hasVolumeState } }
    var hasOutputDevicesState: Bool { lock.withLock { _hasOutputDevicesState } }
    var outputDevicesRevision: Int { lock.withLock { _outputDevicesRevision } }
    var hasPlayingSnapshot: Bool { lock.withLock { _hasPlayingSnapshot } }
    var clientUpdatesConfigured: Bool { lock.withLock { _clientUpdatesConfigured } }

    func update(message: ProtocolMessageMessage) {
        switch message.type {
        case .volumeDidChangeMessage:
            setVolume(message.volumeDidChangeMessage.volume)
        case .getVolumeResultMessage:
            setVolume(message.getVolumeResultMessage.volume)
        case .updateOutputDeviceMessage:
            let update = message.updateOutputDeviceMessage
            let descriptors =
                update.clusterAwareOutputDevices.isEmpty
                ? update.outputDevices
                : update.clusterAwareOutputDevices
            setOutputDevices(descriptors)
        case .deviceInfoMessage, .deviceInfoUpdateMessage:
            setPower(.on)
            setOutputDevices(message.deviceInfoMessage)
        case .setStateMessage:
            lock.withLock { _hasPlayingSnapshot = true }
            updateCommandFeatures(message.setStateMessage.supportedCommands)
        case .setDefaultSupportedCommandsMessage:
            updateCommandFeatures(message.setDefaultSupportedCommandsMessage.supportedCommands)
        case .volumeControlAvailabilityMessage:
            lock.withLock {
                _hasVolumeState = message.volumeControlAvailabilityMessage.volumeControlAvailable
            }
        case .volumeControlCapabilitiesDidChangeMessage:
            lock.withLock { _hasVolumeState = true }
        default:
            return
        }
    }

    func featureInfo(_ feature: FeatureName) -> FeatureInfo? {
        lock.withLock { setupDiagnostics[feature] ?? featureOverrides[feature] }
    }

    func updateMetadata(app: App?, artworkID: String) {
        lock.withLock {
            _currentApp = app
            _artworkID = artworkID
            if app != nil || !artworkID.isEmpty {
                _hasPlayingSnapshot = true
            }
        }
    }

    func markClientUpdatesConfigured() {
        lock.withLock { _clientUpdatesConfigured = true }
    }

    func recordSetupFailure(_ message: String, affectedFeatures: Set<FeatureName>) {
        let info = FeatureInfo(state: .unavailable, options: ["diagnostic": message])
        lock.withLock {
            for feature in affectedFeatures {
                setupDiagnostics[feature] = info
            }
        }
    }

    func volumeStream() -> AsyncStream<Float> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                volumeContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.volumeContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func outputDevicesStream() -> AsyncStream<[OutputDevice]> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                outputContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.outputContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func powerStateStream() -> AsyncStream<PowerState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                powerContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.powerContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    private func setVolume(_ volume: Float) {
        let percent = volume * 100
        let continuations = lock.withLock {
            _volume = percent
            _hasVolumeState = true
            return Array(volumeContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(percent)
        }
    }

    private func setOutputDevices(_ descriptors: [AVOutputDeviceDescriptor]) {
        let devices = descriptors.compactMap { descriptor -> OutputDevice? in
            guard !descriptor.uniqueIdentifier.isEmpty else {
                return nil
            }
            return OutputDevice(
                identifier: descriptor.uniqueIdentifier,
                name: descriptor.hasName ? descriptor.name : nil,
                volume: descriptor.hasVolume ? descriptor.volume * 100 : 0
            )
        }
        let continuations = lock.withLock {
            _outputDevices = devices
            _hasOutputDevicesState = true
            _outputDevicesRevision += 1
            return Array(outputContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(devices)
        }
    }

    private func setOutputDevices(_ deviceInfo: DeviceInfoMessage) {
        var devices: [OutputDevice] = []
        if deviceInfo.isGroupLeader, !deviceInfo.isProxyGroupPlayer, !deviceInfo.uniqueIdentifier.isEmpty {
            devices.append(
                OutputDevice(
                    identifier: deviceInfo.uniqueIdentifier,
                    name: deviceInfo.hasName ? deviceInfo.name : nil
                )
            )
        }
        for groupedDevice in deviceInfo.groupedDevices where !groupedDevice.deviceUid.isEmpty {
            devices.append(
                OutputDevice(
                    identifier: groupedDevice.deviceUid,
                    name: groupedDevice.hasName ? groupedDevice.name : nil
                )
            )
        }

        guard !devices.isEmpty || deviceInfo.isGroupLeader || !deviceInfo.groupedDevices.isEmpty else {
            return
        }

        let continuations = lock.withLock {
            _outputDevices = devices
            _hasOutputDevicesState = true
            _outputDevicesRevision += 1
            return Array(outputContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(devices)
        }
    }

    private func setPower(_ state: PowerState) {
        let continuations = lock.withLock {
            _powerState = state
            return Array(powerContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(state)
        }
    }

    private func updateCommandFeatures(_ commands: SupportedCommands) {
        let mapped: [(FeatureName, FeatureInfo)] = commands.supportedCommands.compactMap { command in
            guard let feature = command.command.featureName else {
                return nil
            }
            return (feature, FeatureInfo(state: command.enabled ? .available : .unavailable))
        }
        lock.withLock {
            for (feature, info) in mapped {
                featureOverrides[feature] = info
            }
        }
    }
}

internal enum MRPAuthenticationMode: Sendable, Equatable {
    case directPairVerify
    case alreadySecure
}

internal enum MRPHeartbeatMode: Sendable, Equatable {
    case genericMessage
    case disabled
}

/// Setup and lifecycle management for MRP.
public final class MRPService: @unchecked Sendable {
    /// Bonjour service type for direct Media Remote Protocol.
    public static let serviceType = "_mediaremotetv._tcp"
    /// Default port for direct MRP.
    public static let defaultPort = 49152

    private let connection: any MRPTransport
    private let protocolHandler: MRPProtocolHandler
    private let playerState = MRPPlayerState()
    private let stateStore = MRPStateStore()
    private let lock = NSLock()
    private let settings: ATVSettings
    private let onConnectionClosed: (@Sendable (Error?) -> Void)?
    private var credentials: HAPCredentials?

    private var _remoteControl: MRPRemoteControl?
    private var _metadata: MRPMetadata?
    private var _pushUpdater: MRPPushUpdater?
    private var _power: MRPPower?
    private var _audio: MRPAudio?
    private var _features: MRPFeatures?

    /// Remote-control interface registered after setup.
    public var remoteControl: MRPRemoteControl? { lock.withLock { _remoteControl } }
    /// Metadata interface registered after setup.
    public var metadata: MRPMetadata? { lock.withLock { _metadata } }
    /// Push-updater interface registered after setup.
    public var pushUpdater: MRPPushUpdater? { lock.withLock { _pushUpdater } }
    /// Power interface registered after setup.
    public var power: MRPPower? { lock.withLock { _power } }
    /// Audio interface registered after setup.
    public var audio: MRPAudio? { lock.withLock { _audio } }
    /// Feature provider registered after setup.
    public var features: MRPFeatures? { lock.withLock { _features } }

    /// Create an MRP service for a host and port.
    public init(
        host: String,
        port: Int,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        let connection = MRPConnection(host: host, port: port)
        self.connection = connection
        self.protocolHandler = MRPProtocolHandler(
            connection: connection,
            playerState: playerState,
            stateStore: stateStore,
            authenticationMode: .directPairVerify,
            heartbeatMode: .genericMessage,
            onConnectionClosed: onConnectionClosed
        )
        self.credentials = credentials
        self.settings = settings
        self.onConnectionClosed = onConnectionClosed
        self.connection.delegate = protocolHandler
    }

    internal init(
        transport: any MRPTransport,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings,
        authenticationMode: MRPAuthenticationMode,
        heartbeatMode: MRPHeartbeatMode,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.connection = transport
        let handler = MRPProtocolHandler(
            connection: transport,
            playerState: playerState,
            stateStore: stateStore,
            authenticationMode: authenticationMode,
            heartbeatMode: heartbeatMode,
            onConnectionClosed: onConnectionClosed
        )
        self.protocolHandler = handler
        self.credentials = credentials
        self.settings = settings
        self.onConnectionClosed = onConnectionClosed
        self.connection.delegate = handler
    }

    /// Connect, authenticate if credentials are present, and initialize MRP.
    public func setup() async throws(ATVError) {
        try await protocolHandler.start(settings: settings, credentials: credentials)
        lock.withLock {
            _remoteControl = MRPRemoteControl(protocol: protocolHandler)
            _metadata = MRPMetadata(
                protocol: protocolHandler,
                playerState: playerState,
                stateStore: stateStore
            )
            _pushUpdater = MRPPushUpdater(playerState: playerState)
            _power = MRPPower(protocol: protocolHandler, stateStore: stateStore)
            _audio = MRPAudio(protocol: protocolHandler, stateStore: stateStore)
            _features = MRPFeatures(stateStore: stateStore)
        }
    }

    /// Close the MRP protocol connection.
    public func close() async {
        await protocolHandler.stop()
        await connection.close()
    }
}

actor MRPProtocolHandler: MRPConnectionDelegate, MRPProtocolHandling {
    private let connection: any MRPTransport
    private let playerState: MRPPlayerState
    private let stateStore: MRPStateStore
    private let authenticationMode: MRPAuthenticationMode
    private let heartbeatMode: MRPHeartbeatMode
    private let onConnectionClosed: (@Sendable (Error?) -> Void)?
    private var heartbeatTask: Task<Void, Never>?

    private static let clientUpdateDependentFeatures: Set<FeatureName> = [
        .pushUpdates,
        .volume, .setVolume, .volumeUp, .volumeDown,
        .outputDevices, .addOutputDevices, .removeOutputDevices, .setOutputDevices,
    ]

    init(
        connection: any MRPTransport,
        playerState: MRPPlayerState,
        stateStore: MRPStateStore,
        authenticationMode: MRPAuthenticationMode,
        heartbeatMode: MRPHeartbeatMode,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.connection = connection
        self.playerState = playerState
        self.stateStore = stateStore
        self.authenticationMode = authenticationMode
        self.heartbeatMode = heartbeatMode
        self.onConnectionClosed = onConnectionClosed
    }

    func start(settings: ATVSettings, credentials: HAPCredentials?) async throws(ATVError) {
        try await connection.connect()

        let deviceInfo = try await connection.sendAndReceive(
            MRPMessages.deviceInformation(settings: settings),
            responseType: .deviceInfoMessage
        )
        await playerState.process(deviceInfo)
        stateStore.update(message: deviceInfo)
        await syncMetadataSnapshot()

        if let credentials, authenticationMode == .directPairVerify {
            try await verify(credentials: credentials)
        }

        try await connection.send(MRPMessages.setConnectionState())
        do {
            _ = try await connection.sendAndReceive(
                MRPMessages.clientUpdatesConfig(),
                responseType: .clientUpdatesConfigMessage
            )
            stateStore.markClientUpdatesConfigured()
        } catch {
            stateStore.recordSetupFailure(
                "MRP client update subscription failed: \(String(describing: error))",
                affectedFeatures: Self.clientUpdateDependentFeatures
            )
        }
        do {
            _ = try await connection.sendAndReceive(
                MRPMessages.getKeyboardSession(),
                responseType: .getKeyboardSessionMessage
            )
        } catch {
            // MRP keyboard setup is optional and SwiftATV does not expose an
            // MRP keyboard interface yet, so no public features are downgraded.
        }
        if heartbeatMode == .genericMessage {
            startHeartbeat()
        }
    }

    func stop() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func send(_ message: ProtocolMessageMessage) async throws(ATVError) {
        try await connection.send(message)
    }

    func exchange(
        _ message: ProtocolMessageMessage,
        responseType: ProtocolMessageMessage.TypeEnum? = nil
    ) async throws(ATVError) -> ProtocolMessageMessage {
        try await connection.sendAndReceive(message, responseType: responseType)
    }

    func sendCommand(_ command: Command, options: CommandOptions? = nil) async throws(ATVError) {
        let path = await playerState.activePlayerPath
        let response = try await connection.sendAndReceive(
            MRPMessages.command(command, options: options, playerPath: path),
            responseType: .sendCommandResultMessage
        )
        try Self.validateCommandResult(response.sendCommandResultMessage, command: command)
    }

    func sendHID(usagePage: UInt16, usage: UInt16, action: InputAction) async throws(ATVError) {
        switch action {
        case .singleTap:
            try await send(MRPMessages.hidEvent(usagePage: usagePage, usage: usage, down: true))
            try await send(MRPMessages.hidEvent(usagePage: usagePage, usage: usage, down: false))
        case .doubleTap:
            try await sendHID(usagePage: usagePage, usage: usage, action: .singleTap)
            try await sendHID(usagePage: usagePage, usage: usage, action: .singleTap)
        case .hold:
            try await send(MRPMessages.hidEvent(usagePage: usagePage, usage: usage, down: true))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await send(MRPMessages.hidEvent(usagePage: usagePage, usage: usage, down: false))
        }
    }

    internal static func validateCommandResult(
        _ result: SendCommandResultMessage,
        command: Command? = nil
    ) throws(ATVError) {
        let commandDescription = command.map { " \($0)" } ?? ""
        guard result.sendError == .noError else {
            throw ATVError.protocolError(
                "MRP command\(commandDescription) failed with sendError=\(result.sendError)"
            )
        }
        guard result.handlerReturnStatus == .success else {
            throw ATVError.protocolError(
                "MRP command\(commandDescription) failed with handlerReturnStatus=\(result.handlerReturnStatus)"
            )
        }
        if result.hasCommandResult, result.commandResult.sendError != .noError {
            throw ATVError.protocolError(
                "MRP command\(commandDescription) failed with commandResult.sendError=\(result.commandResult.sendError)"
            )
        }
    }

    func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo? {
        let path = await playerState.activePlayerPath
        let response = try await exchange(
            MRPMessages.playbackQueueRequest(width: width, height: height, playerPath: path),
            responseType: .setStateMessage
        )
        guard let item = response.setStateMessage.playbackQueue.contentItems.first, item.hasArtworkData else {
            return nil
        }
        let metadata = item.metadata
        return ArtworkInfo(
            data: item.artworkData,
            mimetype: metadata.hasArtworkMimetype ? metadata.artworkMimetype : "image/jpeg",
            width: item.hasArtworkDataWidth ? Int(item.artworkDataWidth) : Int(metadata.artworkDataWidth),
            height: item.hasArtworkDataHeight ? Int(item.artworkDataHeight) : Int(metadata.artworkDataHeight)
        )
    }

    func refreshPlaying() async throws(ATVError) -> Playing {
        let path = await playerState.activePlayerPath
        let response = try await exchange(
            MRPMessages.playbackQueueRequest(width: nil, height: nil, playerPath: path),
            responseType: .setStateMessage
        )
        await playerState.process(response)
        stateStore.update(message: response)
        await syncMetadataSnapshot()
        return await playerState.currentPlaying
    }

    nonisolated func connectionDidReceiveMessage(_ message: ProtocolMessageMessage) async {
        await playerState.process(message)
        stateStore.update(message: message)
        await syncMetadataSnapshot()
    }

    nonisolated func connectionDidClose(error: Error?) async {
        onConnectionClosed?(error)
    }

    private func verify(credentials: HAPCredentials) async throws(ATVError) {
        let verifier = HAPPairVerifyHandler(credentials: credentials)
        let step1 = try verifier.step1()
        let step1Response = try await exchange(
            MRPMessages.cryptoPairing(step1),
            responseType: .cryptoPairingMessage
        )
        let step2 = try verifier.step2(step1Response.cryptoPairingMessage.pairingData)
        let step2Response = try await exchange(
            MRPMessages.cryptoPairing(step2),
            responseType: .cryptoPairingMessage
        )
        try Self.validatePairVerifyFinalResponse(
            step2Response.cryptoPairingMessage.pairingData
        )
        let keys = try verifier.deriveKeys()
        connection.enableEncryption(outputKey: keys.outputKey, inputKey: keys.inputKey)
    }

    internal static func validatePairVerifyFinalResponse(_ data: Data) throws(ATVError) {
        let tlv = try TLV8.decodeStrict(data)
        if let errorData = tlv[TLVTag.error.rawValue], !errorData.isEmpty {
            throw ATVError.authenticationFailed(
                "HAP pair-verify error code 0x\(String(errorData[0], radix: 16))"
            )
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    _ = try await self?.exchange(MRPMessages.generic(), responseType: .genericMessage)
                } catch {
                    await self?.connection.close()
                    return
                }
            }
        }
    }

    private func syncMetadataSnapshot() async {
        let app = await playerState.currentApp
        let artworkID = await playerState.artworkID
        stateStore.updateMetadata(app: app, artworkID: artworkID)
    }
}

extension Command {
    fileprivate var featureName: FeatureName? {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .togglePlayPause: return .playPause
        case .stop: return .stop
        case .nextTrack: return .next
        case .previousTrack: return .previous
        case .seekToPlaybackPosition: return .setPosition
        case .changeRepeatMode: return .setRepeat
        case .changeShuffleMode: return .setShuffle
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        default: return nil
        }
    }
}
