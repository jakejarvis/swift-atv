import Foundation

final class MRPStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _volume: Float = 0
    private var _outputDevices: [OutputDevice] = []
    private var _powerState: PowerState = .unknown
    private var _currentApp: App?
    private var _artworkID = ""
    private var _hasVolumeState = false
    private var _volumeControlAvailable = false
    private var _volumeControlCapabilities: VolumeCapabilities.Enum = .none
    private var _volumeDeviceID: String?
    private var _hasOutputDevicesState = false
    private var _outputDevicesRevision = 0
    private var _hasPlayingSnapshot = false
    private var _clientUpdatesConfigured = false
    private var commandInfos: [MediaRemoteCommand: MediaCommandInfo] = [:]
    private var setupDiagnostics: [Capability: CapabilityInfo] = [:]
    private var volumeContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var outputContinuations: [UUID: AsyncStream<[OutputDevice]>.Continuation] = [:]
    private var powerContinuations: [UUID: AsyncStream<PowerState>.Continuation] = [:]

    var volume: Float { lock.withLock { _volume } }
    var outputDevices: [OutputDevice] { lock.withLock { _outputDevices } }
    var powerState: PowerState { lock.withLock { _powerState } }
    var currentApp: App? { lock.withLock { _currentApp } }
    var artworkID: String { lock.withLock { _artworkID } }
    var hasVolumeState: Bool { lock.withLock { _hasVolumeState } }
    var volumeDeviceID: String? { lock.withLock { _volumeDeviceID } }
    var supportsAbsoluteVolume: Bool {
        lock.withLock {
            _volumeControlAvailable && _volumeDeviceID != nil && _volumeControlCapabilities.supportsAbsoluteVolume
        }
    }

    var supportsRelativeVolume: Bool {
        lock.withLock {
            _volumeControlAvailable && _volumeDeviceID != nil && _volumeControlCapabilities.supportsRelativeVolume
        }
    }

    var supportsVolumeStep: Bool {
        lock.withLock {
            _volumeControlAvailable && _volumeDeviceID != nil
                && (_volumeControlCapabilities.supportsRelativeVolume
                    || _volumeControlCapabilities.supportsAbsoluteVolume)
        }
    }

    var hasOutputDevicesState: Bool { lock.withLock { _hasOutputDevicesState } }
    var outputDevicesRevision: Int { lock.withLock { _outputDevicesRevision } }
    var hasPlayingSnapshot: Bool { lock.withLock { _hasPlayingSnapshot } }
    var clientUpdatesConfigured: Bool { lock.withLock { _clientUpdatesConfigured } }

    func update(message: ProtocolMessageMessage) {
        switch message.type {
        case .volumeDidChangeMessage:
            setVolume(message.volumeDidChangeMessage)
        case .getVolumeResultMessage:
            guard let percent = Self.volumePercent(fromProtocolValue: message.getVolumeResultMessage.volume) else {
                return
            }
            setVolumePercent(percent)
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
            updateCommandInfos(message.setStateMessage.supportedCommands)
        case .setDefaultSupportedCommandsMessage:
            updateCommandInfos(message.setDefaultSupportedCommandsMessage.supportedCommands)
        case .volumeControlAvailabilityMessage:
            setVolumeControls(message.volumeControlAvailabilityMessage)
        case .volumeControlCapabilitiesDidChangeMessage:
            setVolumeControls(message.volumeControlCapabilitiesDidChangeMessage)
        default:
            return
        }
    }

    func capabilityInfo(_ capability: Capability) -> CapabilityInfo? {
        lock.withLock {
            if let diagnostic = setupDiagnostics[capability] {
                return diagnostic
            }
            if case .mediaCommand(let command) = capability, let info = commandInfos[command] {
                return info.capabilityInfo
            }
            return nil
        }
    }

    func commandInfo(_ command: MediaRemoteCommand) -> MediaCommandInfo? {
        lock.withLock { commandInfos[command] }
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

    func recordSetupFailure(_ message: String, affectedCapabilities: Set<Capability>) {
        let info = CapabilityInfo(state: .unavailable, options: ["diagnostic": message])
        lock.withLock {
            for capability in affectedCapabilities {
                setupDiagnostics[capability] = info
            }
        }
    }

    func setupDiagnosticEntries() -> [(Capability, CapabilityInfo)] {
        lock.withLock {
            setupDiagnostics.map { ($0.key, $0.value) }
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

    private static func volumePercent(fromProtocolValue volume: Float) -> Float? {
        guard volume.isFinite else {
            return nil
        }
        return max(0, min(volume, 1)) * 100
    }

    private func setVolumePercent(_ percent: Float) {
        let continuations = lock.withLock {
            _volume = percent
            _hasVolumeState = true
            return Array(volumeContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(percent)
        }
    }

    private func setVolume(_ message: VolumeDidChangeMessage) {
        guard let percent = Self.volumePercent(fromProtocolValue: message.volume) else {
            return
        }
        let deviceID = lock.withLock { _volumeDeviceID }
        let outputDeviceID =
            message.hasOutputDeviceUid && !message.outputDeviceUid.isEmpty
            ? message.outputDeviceUid : nil

        if let outputDeviceID, let deviceID, outputDeviceID != deviceID {
            updateOutputDeviceVolume(identifier: outputDeviceID, volume: percent)
            return
        }

        if let outputDeviceID, deviceID == nil {
            updateOutputDeviceVolume(identifier: outputDeviceID, volume: percent)
            return
        }

        setVolumePercent(percent)
    }

    private func setVolumeControls(_ message: VolumeControlAvailabilityMessage) {
        lock.withLock {
            _volumeControlAvailable = message.volumeControlAvailable
            _volumeControlCapabilities = message.volumeCapabilities
        }
    }

    private func setVolumeControls(_ message: VolumeControlCapabilitiesDidChangeMessage) {
        let shouldUpdate = lock.withLock {
            guard let deviceID = _volumeDeviceID else {
                return !message.hasOutputDeviceUid || message.outputDeviceUid.isEmpty
            }
            return !message.hasOutputDeviceUid || message.outputDeviceUid.isEmpty || message.outputDeviceUid == deviceID
        }
        guard shouldUpdate else {
            return
        }
        setVolumeControls(message.capabilities)
    }

    private func setOutputDevices(_ descriptors: [AVOutputDeviceDescriptor]) {
        let devices = descriptors.compactMap { descriptor -> OutputDevice? in
            guard !descriptor.uniqueIdentifier.isEmpty else {
                return nil
            }
            return OutputDevice(
                identifier: descriptor.uniqueIdentifier,
                name: descriptor.hasName ? descriptor.name : nil,
                volume: descriptor.hasVolume
                    ? Self.volumePercent(fromProtocolValue: descriptor.volume) ?? 0
                    : 0
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
            if let volumeDeviceID = deviceInfo.volumeControlDeviceID {
                _volumeDeviceID = volumeDeviceID
            }
            _outputDevices = devices
            _hasOutputDevicesState = true
            _outputDevicesRevision += 1
            return Array(outputContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(devices)
        }
    }

    private func updateOutputDeviceVolume(identifier: String, volume: Float) {
        typealias OutputDeviceVolumeUpdate = (
            devices: [OutputDevice],
            continuations: [AsyncStream<[OutputDevice]>.Continuation]
        )
        let update = lock.withLock { () -> OutputDeviceVolumeUpdate? in
            guard let index = _outputDevices.firstIndex(where: { $0.identifier == identifier }) else {
                return nil
            }
            _outputDevices[index] = OutputDevice(
                identifier: _outputDevices[index].identifier,
                name: _outputDevices[index].name,
                volume: volume
            )
            _hasOutputDevicesState = true
            _outputDevicesRevision += 1
            return (_outputDevices, Array(outputContinuations.values))
        }
        guard let update else {
            return
        }
        for continuation in update.continuations {
            continuation.yield(update.devices)
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

    private func updateCommandInfos(_ commands: SupportedCommands) {
        let mapped: [(MediaRemoteCommand, MediaCommandInfo)] = commands.supportedCommands.compactMap { command in
            guard let mediaCommand = command.command.mediaRemoteCommand else {
                return nil
            }
            return (mediaCommand, MediaCommandInfo(command))
        }
        lock.withLock {
            for (command, info) in mapped {
                commandInfos[command] = info
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
    private let requestTimeout: TimeInterval
    private let runtimeRequestTimeout: TimeInterval
    private var credentials: HAPCredentials?

    private var _remoteControl: MRPRemoteControl?
    private var _metadata: MRPMetadata?
    private var _pushUpdater: MRPPushUpdater?
    private var _power: MRPPower?
    private var _audio: MRPAudio?
    private var _capabilities: MRPCapabilities?
    private var _mediaCommands: MRPMediaCommands?

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
    /// Capability provider registered after setup.
    public var capabilities: MRPCapabilities? { lock.withLock { _capabilities } }
    /// Media command controller registered after setup.
    public var mediaCommands: MRPMediaCommands? { lock.withLock { _mediaCommands } }

    func setupDiagnostics(protocol registrationProtocol: ATVProtocol) -> [ProtocolSetupDiagnostic] {
        stateStore.setupDiagnosticEntries().map { capability, info in
            ProtocolSetupDiagnostic(
                protocol: registrationProtocol,
                capability: capability,
                info: info
            )
        }
    }

    /// Create an MRP service for a host and port.
    ///
    /// - Parameter requestTimeout: Maximum time for the TCP connect and setup
    ///   request/response exchanges.
    public init(
        host: String,
        port: Int,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        runtimeRequestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        let connection = MRPConnection(host: host, port: port, connectTimeout: requestTimeout)
        self.connection = connection
        self.protocolHandler = MRPProtocolHandler(
            connection: connection,
            playerState: playerState,
            stateStore: stateStore,
            authenticationMode: .directPairVerify,
            heartbeatMode: .genericMessage,
            runtimeRequestTimeout: runtimeRequestTimeout,
            onConnectionClosed: onConnectionClosed
        )
        self.credentials = credentials
        self.settings = settings
        self.onConnectionClosed = onConnectionClosed
        self.requestTimeout = requestTimeout
        self.runtimeRequestTimeout = runtimeRequestTimeout
        self.connection.delegate = protocolHandler
    }

    internal init(
        transport: any MRPTransport,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings,
        authenticationMode: MRPAuthenticationMode,
        heartbeatMode: MRPHeartbeatMode,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        runtimeRequestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.connection = transport
        let handler = MRPProtocolHandler(
            connection: transport,
            playerState: playerState,
            stateStore: stateStore,
            authenticationMode: authenticationMode,
            heartbeatMode: heartbeatMode,
            runtimeRequestTimeout: runtimeRequestTimeout,
            onConnectionClosed: onConnectionClosed
        )
        self.protocolHandler = handler
        self.credentials = credentials
        self.settings = settings
        self.onConnectionClosed = onConnectionClosed
        self.requestTimeout = requestTimeout
        self.runtimeRequestTimeout = runtimeRequestTimeout
        self.connection.delegate = handler
    }

    /// Connect, authenticate if credentials are present, and initialize MRP.
    public func setup() async throws(ATVError) {
        try await protocolHandler.start(
            settings: settings,
            credentials: credentials,
            requestTimeout: requestTimeout
        )
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
            _capabilities = MRPCapabilities(stateStore: stateStore)
            _mediaCommands = MRPMediaCommands(protocol: protocolHandler, stateStore: stateStore)
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
    private let runtimeRequestTimeout: TimeInterval
    private let onConnectionClosed: (@Sendable (Error?) -> Void)?
    private var heartbeatTask: Task<Void, Never>?

    private static let clientUpdateDependentCapabilities: Set<Capability> = [
        .push(.updates),
        .audio(.volume), .audio(.setVolume), .audio(.volumeUp), .audio(.volumeDown),
        .audio(.outputDevices), .audio(.addOutputDevices), .audio(.removeOutputDevices), .audio(.setOutputDevices),
    ]

    init(
        connection: any MRPTransport,
        playerState: MRPPlayerState,
        stateStore: MRPStateStore,
        authenticationMode: MRPAuthenticationMode,
        heartbeatMode: MRPHeartbeatMode,
        runtimeRequestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.connection = connection
        self.playerState = playerState
        self.stateStore = stateStore
        self.authenticationMode = authenticationMode
        self.heartbeatMode = heartbeatMode
        self.runtimeRequestTimeout = runtimeRequestTimeout
        self.onConnectionClosed = onConnectionClosed
    }

    func start(
        settings: ATVSettings,
        credentials: HAPCredentials?,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout
    ) async throws(ATVError) {
        try await connection.connect()

        let deviceInfo = try await connection.sendAndReceive(
            MRPMessages.deviceInformation(settings: settings),
            responseType: .deviceInfoMessage,
            timeout: requestTimeout
        )
        await playerState.process(deviceInfo)
        stateStore.update(message: deviceInfo)
        await syncMetadataSnapshot()

        if let credentials, authenticationMode == .directPairVerify {
            try await verify(credentials: credentials, requestTimeout: requestTimeout)
        }

        try await connection.send(MRPMessages.setConnectionState())
        do {
            _ = try await connection.sendAndReceive(
                MRPMessages.clientUpdatesConfig(),
                responseType: .clientUpdatesConfigMessage,
                timeout: requestTimeout
            )
            stateStore.markClientUpdatesConfigured()
        } catch let error {
            guard !Self.isTerminalOptionalSetupFailure(error) else {
                throw error
            }
            stateStore.recordSetupFailure(
                "MRP client update subscription failed: \(String(describing: error))",
                affectedCapabilities: Self.clientUpdateDependentCapabilities
            )
        }
        do {
            _ = try await connection.sendAndReceive(
                MRPMessages.getKeyboardSession(),
                responseType: .getKeyboardSessionMessage,
                timeout: requestTimeout
            )
        } catch let error {
            guard !Self.isTerminalOptionalSetupFailure(error) else {
                throw error
            }
            // MRP keyboard setup is optional and SwiftATV does not expose an
            // MRP keyboard interface yet, so no public capabilities are downgraded.
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
        try await connection.sendAndReceive(
            message,
            responseType: responseType,
            timeout: runtimeRequestTimeout
        )
    }

    func sendCommand(_ command: Command, options: CommandOptions? = nil) async throws(ATVError) {
        let path = await playerState.activePlayerPath
        let response = try await connection.sendAndReceive(
            MRPMessages.command(command, options: options, playerPath: path),
            responseType: .sendCommandResultMessage,
            timeout: runtimeRequestTimeout
        )
        try Self.validateCommandResult(response.sendCommandResultMessage, command: command)
    }

    func sendHID(
        usagePage: UInt16,
        usage: UInt16,
        action: InputAction,
        flush: Bool = true
    ) async throws(ATVError) {
        switch action {
        case .singleTap:
            try await sendHIDPress(usagePage: usagePage, usage: usage, hold: false, flush: flush)
        case .doubleTap:
            try await sendHIDPress(usagePage: usagePage, usage: usage, hold: false, flush: flush)
            try await sendHIDPress(usagePage: usagePage, usage: usage, hold: false, flush: flush)
        case .hold:
            try await sendHIDPress(usagePage: usagePage, usage: usage, hold: true, flush: flush)
        }
    }

    private func sendHIDPress(
        usagePage: UInt16,
        usage: UInt16,
        hold: Bool,
        flush: Bool
    ) async throws(ATVError) {
        try await send(MRPMessages.hidEvent(usagePage: usagePage, usage: usage, down: true))
        if hold {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try await send(MRPMessages.hidEvent(usagePage: usagePage, usage: usage, down: false))
        if flush {
            _ = try await exchange(MRPMessages.generic(), responseType: .genericMessage)
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

    private static func isTerminalOptionalSetupFailure(_ error: ATVError) -> Bool {
        switch error {
        case .connectionFailed, .connectionLost, .operationCancelled:
            return true
        default:
            return false
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

    private func verify(credentials: HAPCredentials, requestTimeout: TimeInterval) async throws(ATVError) {
        let verifier = HAPPairVerifyHandler(credentials: credentials)
        let step1 = try verifier.step1()
        let step1Response = try await connection.sendAndReceive(
            MRPMessages.cryptoPairing(step1),
            responseType: .cryptoPairingMessage,
            timeout: requestTimeout
        )
        let step2 = try verifier.step2(step1Response.cryptoPairingMessage.pairingData)
        let step2Response = try await connection.sendAndReceive(
            MRPMessages.cryptoPairing(step2),
            responseType: .cryptoPairingMessage,
            timeout: requestTimeout
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
                } catch is CancellationError {
                    return
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
    fileprivate var mediaRemoteCommand: MediaRemoteCommand? {
        switch self {
        case .unknown: return nil
        case .play: return .play
        case .pause: return .pause
        case .togglePlayPause: return .togglePlayPause
        case .stop: return .stop
        case .nextTrack: return .nextTrack
        case .previousTrack: return .previousTrack
        case .advanceShuffleMode: return .advanceShuffleMode
        case .advanceRepeatMode: return .advanceRepeatMode
        case .beginFastForward: return .beginFastForward
        case .endFastForward: return .endFastForward
        case .beginRewind: return .beginRewind
        case .endRewind: return .endRewind
        case .rewind15Seconds: return .rewind15Seconds
        case .fastForward15Seconds: return .fastForward15Seconds
        case .rewind30Seconds: return .rewind30Seconds
        case .fastForward30Seconds: return .fastForward30Seconds
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        case .changePlaybackRate: return .changePlaybackRate
        case .rateTrack: return .rateTrack
        case .likeTrack: return .likeTrack
        case .dislikeTrack: return .dislikeTrack
        case .bookmarkTrack: return .bookmarkTrack
        case .seekToPlaybackPosition: return .seekToPlaybackPosition
        case .changeRepeatMode: return .changeRepeatMode
        case .changeShuffleMode: return .changeShuffleMode
        case .enableLanguageOption: return .enableLanguageOption
        case .disableLanguageOption: return .disableLanguageOption
        case .nextChapter: return .nextChapter
        case .previousChapter: return .previousChapter
        case .nextAlbum: return .nextAlbum
        case .previousAlbum: return .previousAlbum
        case .nextPlaylist: return .nextPlaylist
        case .previousPlaylist: return .previousPlaylist
        case .banTrack: return .banTrack
        case .addTrackToWishList: return .addTrackToWishList
        case .removeTrackFromWishList: return .removeTrackFromWishList
        case .nextInContext: return .nextInContext
        case .previousInContext: return .previousInContext
        case .resetPlaybackTimeout: return .resetPlaybackTimeout
        case .setPlaybackQueue: return .setPlaybackQueue
        case .addNowPlayingItemToLibrary: return .addNowPlayingItemToLibrary
        case .createRadioStation: return .createRadioStation
        case .addItemToLibrary: return .addItemToLibrary
        case .insertIntoPlaybackQueue: return .insertIntoPlaybackQueue
        case .reorderPlaybackQueue: return .reorderPlaybackQueue
        case .removeFromPlaybackQueue: return .removeFromPlaybackQueue
        case .playItemInPlaybackQueue: return .playItemInPlaybackQueue
        case .prepareForSetQueue: return .prepareForSetQueue
        case .setPlaybackSession: return .setPlaybackSession
        case .preloadedPlaybackSession: return .preloadedPlaybackSession
        case .setPriorityForPlaybackSession: return .setPriorityForPlaybackSession
        case .discardPlaybackSession: return .discardPlaybackSession
        case .reshuffle: return .reshuffle
        case .changeQueueEndAction: return .changeQueueEndAction
        }
    }
}

extension VolumeCapabilities.Enum {
    fileprivate var supportsAbsoluteVolume: Bool {
        self == .absolute || self == .both
    }

    fileprivate var supportsRelativeVolume: Bool {
        self == .relative || self == .both
    }
}

extension DeviceInfoMessage {
    fileprivate var volumeControlDeviceID: String? {
        if hasClusterID, !clusterID.isEmpty {
            return clusterID
        }
        if hasDeviceUid, !deviceUid.isEmpty {
            return deviceUid
        }
        return nil
    }
}

extension MediaRemoteCommand {
    internal var mrpCommand: Command? {
        switch self {
        case .play: return .play
        case .pause: return .pause
        case .togglePlayPause: return .togglePlayPause
        case .stop: return .stop
        case .nextTrack: return .nextTrack
        case .previousTrack: return .previousTrack
        case .advanceShuffleMode: return .advanceShuffleMode
        case .advanceRepeatMode: return .advanceRepeatMode
        case .beginFastForward: return .beginFastForward
        case .endFastForward: return .endFastForward
        case .beginRewind: return .beginRewind
        case .endRewind: return .endRewind
        case .rewind15Seconds: return .rewind15Seconds
        case .fastForward15Seconds: return .fastForward15Seconds
        case .rewind30Seconds: return .rewind30Seconds
        case .fastForward30Seconds: return .fastForward30Seconds
        case .skipForward: return .skipForward
        case .skipBackward: return .skipBackward
        case .changePlaybackRate: return .changePlaybackRate
        case .rateTrack: return .rateTrack
        case .likeTrack: return .likeTrack
        case .dislikeTrack: return .dislikeTrack
        case .bookmarkTrack: return .bookmarkTrack
        case .nextChapter: return .nextChapter
        case .previousChapter: return .previousChapter
        case .nextAlbum: return .nextAlbum
        case .previousAlbum: return .previousAlbum
        case .nextPlaylist: return .nextPlaylist
        case .previousPlaylist: return .previousPlaylist
        case .banTrack: return .banTrack
        case .addTrackToWishList: return .addTrackToWishList
        case .removeTrackFromWishList: return .removeTrackFromWishList
        case .nextInContext: return .nextInContext
        case .previousInContext: return .previousInContext
        case .resetPlaybackTimeout: return .resetPlaybackTimeout
        case .seekToPlaybackPosition: return .seekToPlaybackPosition
        case .changeRepeatMode: return .changeRepeatMode
        case .changeShuffleMode: return .changeShuffleMode
        case .setPlaybackQueue: return .setPlaybackQueue
        case .addNowPlayingItemToLibrary: return .addNowPlayingItemToLibrary
        case .createRadioStation: return .createRadioStation
        case .addItemToLibrary: return .addItemToLibrary
        case .insertIntoPlaybackQueue: return .insertIntoPlaybackQueue
        case .enableLanguageOption: return .enableLanguageOption
        case .disableLanguageOption: return .disableLanguageOption
        case .reorderPlaybackQueue: return .reorderPlaybackQueue
        case .removeFromPlaybackQueue: return .removeFromPlaybackQueue
        case .playItemInPlaybackQueue: return .playItemInPlaybackQueue
        case .prepareForSetQueue: return .prepareForSetQueue
        case .setPlaybackSession: return .setPlaybackSession
        case .preloadedPlaybackSession: return .preloadedPlaybackSession
        case .setPriorityForPlaybackSession: return .setPriorityForPlaybackSession
        case .discardPlaybackSession: return .discardPlaybackSession
        case .reshuffle: return .reshuffle
        case .changeQueueEndAction: return .changeQueueEndAction
        }
    }

    internal var isSendableOverMRP: Bool {
        switch self {
        case .enableLanguageOption, .disableLanguageOption,
            .setPlaybackQueue, .insertIntoPlaybackQueue, .reorderPlaybackQueue,
            .removeFromPlaybackQueue, .playItemInPlaybackQueue, .prepareForSetQueue,
            .setPlaybackSession, .preloadedPlaybackSession, .setPriorityForPlaybackSession,
            .discardPlaybackSession, .changeQueueEndAction:
            return false
        default:
            return true
        }
    }
}

extension MediaCommandInfo {
    fileprivate init(_ info: CommandInfo) {
        self.init(
            state: info.enabled ? .available : .unavailable,
            active: info.hasActive ? info.active : false,
            preferredIntervals: info.preferredIntervals,
            localizedTitle: info.hasLocalizedTitle ? info.localizedTitle : nil,
            localizedShortTitle: info.hasLocalizedShortTitle ? info.localizedShortTitle : nil,
            supportedRates: info.supportedRates,
            preferredPlaybackRate: info.hasPreferredPlaybackRate ? info.preferredPlaybackRate : nil,
            skipInterval: info.hasSkipInterval ? Int(info.skipInterval) : nil,
            numberOfAvailableSkips: info.hasNumAvailableSkips ? Int(info.numAvailableSkips) : nil
        )
    }
}
