import Foundation

/// Facade Apple TV device that unifies multiple protocol implementations
/// behind the `AppleTVDevice` interface.
///
/// Uses the `Relayer` pattern to route method calls to the highest-priority
/// protocol that supports each feature. Tracks protocol lifecycle separately so
/// secondary protocol teardown does not close a usable primary connection.
///
/// Thread safety: Mutable service/event state protected by `NSLock`.
/// Relayers have their own internal locking.
public final class FacadeAppleTV: @unchecked Sendable, AppleTVDevice {
    private typealias TerminalEventDrain = (
        CompanionService?,
        [MRPService],
        AsyncStream<DeviceEvent>.Continuation?
    )
    private typealias SecondaryProtocolDrain = (
        companion: CompanionService?,
        mrp: MRPService?
    )

    private let configuration: AppleTVConfiguration
    private let _settings: ATVSettings
    private let lock = NSLock()
    private var companionService: CompanionService?
    private var mrpServices: [ATVProtocol: MRPService] = [:]
    private var activeProtocols: Set<ATVProtocol> = []
    private var primaryProtocol: ATVProtocol?
    private let protocolPriority: [ATVProtocol]

    // Relayers for each interface (internally thread-safe)
    private let remoteControlRelayer: Relayer<RemoteControl>
    private let metadataRelayer: Relayer<ATVMetadata>
    private let pushUpdaterRelayer: Relayer<PushUpdater>
    private let appsRelayer: Relayer<AppsController>
    private let userAccountsRelayer: Relayer<UserAccountsController>
    private let powerRelayer: Relayer<PowerController>
    private let audioRelayer: Relayer<AudioController>
    private let keyboardRelayer: Relayer<KeyboardController>
    private let touchRelayer: Relayer<TouchController>
    private let capabilityRelayer: Relayer<CapabilityProvider>
    private let mediaCommandRelayer: Relayer<MediaCommandController>

    // Event stream
    private var eventContinuation: AsyncStream<DeviceEvent>.Continuation?
    private var _deviceEvents: AsyncStream<DeviceEvent>?
    private var pendingEvents: [DeviceEvent] = []
    private var eventStreamFinished = false

    public init(
        configuration: AppleTVConfiguration,
        settings: ATVSettings,
        protocolPriority: [ATVProtocol] = Relayer<RemoteControl>.defaultPriorities
    ) {
        self.configuration = configuration
        self._settings = settings
        self.protocolPriority = protocolPriority
        self.remoteControlRelayer = Relayer(priorities: protocolPriority)
        self.metadataRelayer = Relayer(priorities: protocolPriority)
        self.pushUpdaterRelayer = Relayer(priorities: protocolPriority)
        self.appsRelayer = Relayer(priorities: protocolPriority)
        self.userAccountsRelayer = Relayer(priorities: protocolPriority)
        self.powerRelayer = Relayer(priorities: protocolPriority)
        self.audioRelayer = Relayer(priorities: protocolPriority)
        self.keyboardRelayer = Relayer(priorities: protocolPriority)
        self.touchRelayer = Relayer(priorities: protocolPriority)
        self.capabilityRelayer = Relayer(priorities: protocolPriority)
        self.mediaCommandRelayer = Relayer(priorities: protocolPriority)
    }

    // MARK: - AppleTVDevice

    public var settings: ATVSettings { _settings }

    public var deviceInfo: DeviceInfo { configuration.deviceInfo }

    public var remoteControl: RemoteControl {
        RelayingRemoteControl(relayer: remoteControlRelayer)
    }

    public var metadata: ATVMetadata {
        metadataRelayer.main ?? UnsupportedMetadata()
    }

    public var pushUpdater: PushUpdater {
        pushUpdaterRelayer.main ?? UnsupportedPushUpdater()
    }

    public var stream: StreamController {
        UnsupportedStream()
    }

    public var power: PowerController {
        powerRelayer.main ?? UnsupportedPower()
    }

    public var capabilities: CapabilityProvider {
        RelayingCapabilities(relayer: capabilityRelayer)
    }

    public var mediaCommands: MediaCommandController {
        RelayingMediaCommands(relayer: mediaCommandRelayer)
    }

    public var apps: AppsController {
        appsRelayer.main ?? UnsupportedApps()
    }

    public var userAccounts: UserAccountsController {
        userAccountsRelayer.main ?? UnsupportedUserAccounts()
    }

    public var audio: AudioController {
        audioRelayer.main ?? UnsupportedAudio()
    }

    public var keyboard: KeyboardController {
        keyboardRelayer.main ?? UnsupportedKeyboard()
    }

    public var touch: TouchController {
        touchRelayer.main ?? UnsupportedTouch()
    }

    public var deviceEvents: AsyncStream<DeviceEvent> {
        let created:
            (
                stream: AsyncStream<DeviceEvent>,
                continuation: AsyncStream<DeviceEvent>.Continuation,
                events: [DeviceEvent],
                shouldFinish: Bool
            )? = lock.withLock {
                if _deviceEvents != nil {
                    return nil
                }

                var capturedContinuation: AsyncStream<DeviceEvent>.Continuation?
                let stream = AsyncStream<DeviceEvent> { continuation in
                    capturedContinuation = continuation
                }
                guard let continuation = capturedContinuation else {
                    return nil
                }

                self._deviceEvents = stream
                self.eventContinuation = continuation
                let events = self.pendingEvents
                self.pendingEvents.removeAll()
                return (stream, continuation, events, self.eventStreamFinished)
            }

        guard let created else {
            return lock.withLock { _deviceEvents! }
        }

        for event in created.events {
            created.continuation.yield(event)
        }
        if created.shouldFinish {
            created.continuation.finish()
        }
        return created.stream
    }

    private func finishWithTerminalEvent(_ event: DeviceEvent) async {
        let drained: TerminalEventDrain? = lock.withLock {
            guard !eventStreamFinished else {
                return nil
            }

            eventStreamFinished = true
            let companion = companionService
            let mrps = Array(mrpServices.values)
            companionService = nil
            mrpServices.removeAll()
            activeProtocols.removeAll()
            primaryProtocol = nil

            if eventContinuation == nil {
                pendingEvents.append(event)
            }

            return (companion, mrps, eventContinuation)
        }

        guard let (companion, mrps, continuation) = drained else {
            return
        }

        if let continuation {
            continuation.yield(event)
            continuation.finish()
        }

        unregisterAllProtocols()
        await companion?.close()
        for mrp in mrps {
            await mrp.close()
        }
    }

    private func protocolConnectionDidClose(_ error: Error?, protocol: ATVProtocol) {
        let shouldFinish = lock.withLock {
            guard activeProtocols.contains(`protocol`), !eventStreamFinished else {
                return false
            }
            return primaryProtocol == `protocol` || activeProtocols.count == 1
        }

        guard shouldFinish else {
            unregisterSecondaryProtocol(`protocol`)
            return
        }

        let event = DeviceEvent.connectionLost(
            ATVError.connectionLost(
                error.map { "\(`protocol`) connection closed: \(String(describing: $0))" }
                    ?? "\(`protocol`) connection closed"
            )
        )
        Task { [weak self] in
            await self?.finishWithTerminalEvent(event)
        }
    }

    internal func _testProtocolConnectionDidClose(error: Error?, protocol: ATVProtocol) {
        protocolConnectionDidClose(error, protocol: `protocol`)
    }

    internal func _testSetActiveProtocols(_ protocols: Set<ATVProtocol>, primary: ATVProtocol?) {
        lock.withLock {
            activeProtocols = protocols
            primaryProtocol = primary
        }
    }

    internal func _testSetCompanionService(_ service: CompanionService?) {
        lock.withLock {
            companionService = service
        }
    }

    internal var _testActiveProtocols: Set<ATVProtocol> {
        lock.withLock { activeProtocols }
    }

    internal var connectedPrimaryProtocol: ATVProtocol? {
        lock.withLock { primaryProtocol }
    }

    internal var connectedActiveProtocols: [ATVProtocol] {
        lock.withLock {
            protocolPriority.filter { activeProtocols.contains($0) }
        }
    }

    internal var protocolSetupDiagnostics: [ProtocolSetupDiagnostic] {
        lock.withLock {
            var diagnostics = mrpServices.flatMap { registrationProtocol, service in
                service.setupDiagnostics(protocol: registrationProtocol)
            }
            if let companionService {
                diagnostics.append(contentsOf: companionService.setupDiagnostics(protocol: .companion))
            }
            return diagnostics
        }
    }

    private func unregisterSecondaryProtocol(_ protocol: ATVProtocol) {
        let services = lock.withLock {
            guard activeProtocols.remove(`protocol`) != nil else {
                return SecondaryProtocolDrain(nil, nil)
            }
            if primaryProtocol == `protocol` {
                primaryProtocol = activeProtocols.first
            }
            switch `protocol` {
            case .companion:
                let companion = companionService
                companionService = nil
                return SecondaryProtocolDrain(companion, nil)
            case .mrp, .airPlay:
                return SecondaryProtocolDrain(nil, mrpServices.removeValue(forKey: `protocol`))
            }
        }

        unregisterProtocol(`protocol`)
        Task {
            await services.companion?.close()
            await services.mrp?.close()
        }
    }

    private func unregisterProtocol(_ protocol: ATVProtocol) {
        remoteControlRelayer.unregister(for: `protocol`)
        metadataRelayer.unregister(for: `protocol`)
        pushUpdaterRelayer.unregister(for: `protocol`)
        appsRelayer.unregister(for: `protocol`)
        userAccountsRelayer.unregister(for: `protocol`)
        powerRelayer.unregister(for: `protocol`)
        audioRelayer.unregister(for: `protocol`)
        keyboardRelayer.unregister(for: `protocol`)
        touchRelayer.unregister(for: `protocol`)
        capabilityRelayer.unregister(for: `protocol`)
        mediaCommandRelayer.unregister(for: `protocol`)
    }

    private func unregisterAllProtocols() {
        for `protocol` in ATVProtocol.allCases {
            unregisterProtocol(`protocol`)
        }
    }

    // MARK: - Setup

    /// Set up a protocol service for this device.
    public func setupProtocol(
        _ service: ServiceInfo,
        credentials resolvedCredentials: HAPCredentials? = nil,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        runtimeRequestTimeout: TimeInterval = defaultProtocolRequestTimeout
    ) async throws(ATVError) {
        try ATVClient.validateClientIdentity(settings: _settings, for: configuration)

        if service.protocol == .airPlay {
            let candidates =
                if let resolvedCredentials {
                    [resolvedCredentials]
                } else {
                    try ATVClient.resolvedAirPlayTunnelCredentialCandidates(
                        for: service,
                        configuration: configuration,
                        settings: _settings
                    )
                }
            try await setupAirPlayMRPTunnel(
                service,
                credentialCandidates: candidates,
                requestTimeout: requestTimeout,
                runtimeRequestTimeout: runtimeRequestTimeout
            )
            return
        }

        let credentials: HAPCredentials?
        if let resolvedCredentials {
            credentials = resolvedCredentials
        } else {
            credentials = try ATVClient.resolvedCredentials(
                for: service,
                settings: _settings
            )
        }
        if service.protocol == .companion, credentials == nil {
            throw ATVError.noCredentials("Companion requires pairing credentials")
        }
        if service.pairingRequirement == .mandatory, credentials == nil {
            throw ATVError.noCredentials(
                "\(service.protocol) service requires pairing credentials"
            )
        }

        switch service.protocol {
        case .companion:
            try await setupCompanion(
                service,
                credentials: credentials,
                requestTimeout: requestTimeout,
                runtimeRequestTimeout: runtimeRequestTimeout
            )
        case .mrp:
            try await setupMRP(
                service,
                credentials: credentials,
                requestTimeout: requestTimeout,
                runtimeRequestTimeout: runtimeRequestTimeout
            )
        case .airPlay:
            preconditionFailure("AirPlay setup is handled before credential resolution")
        }
    }

    private func setupCompanion(
        _ service: ServiceInfo,
        credentials: HAPCredentials?,
        requestTimeout: TimeInterval,
        runtimeRequestTimeout: TimeInterval
    ) async throws(ATVError) {
        let companion = CompanionService(
            host: configuration.address,
            port: service.port,
            credentials: credentials,
            settings: _settings,
            requestTimeout: requestTimeout,
            runtimeRequestTimeout: runtimeRequestTimeout,
            onConnectionClosed: { [weak self] error in
                self?.protocolConnectionDidClose(error, protocol: .companion)
            }
        )
        do {
            try await companion.setup()
        } catch {
            await companion.close()
            throw error
        }
        lock.withLock {
            self.companionService = companion
            self.activeProtocols.insert(.companion)
            if self.primaryProtocol == nil {
                self.primaryProtocol = .companion
            }
        }

        // Register Companion implementations with relayers
        if let rc = companion.remoteControl {
            remoteControlRelayer.register(rc, for: .companion)
        }
        if let apps = companion.apps {
            appsRelayer.register(apps, for: .companion)
        }
        if let accounts = companion.userAccounts {
            userAccountsRelayer.register(accounts, for: .companion)
        }
        if let pwr = companion.power {
            powerRelayer.register(pwr, for: .companion)
        }
        if let aud = companion.audio {
            audioRelayer.register(aud, for: .companion)
        }
        if let kb = companion.keyboard {
            keyboardRelayer.register(kb, for: .companion)
        }
        if let tch = companion.touch {
            touchRelayer.register(tch, for: .companion)
        }
        if let caps = companion.capabilities {
            capabilityRelayer.register(caps, for: .companion)
        }
        if let commands = companion.mediaCommands {
            mediaCommandRelayer.register(commands, for: .companion)
        }
    }

    internal func setupAirPlayMRPTunnel(
        _ service: ServiceInfo,
        credentialCandidates: [HAPCredentials],
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        runtimeRequestTimeout: TimeInterval = defaultProtocolRequestTimeout
    ) async throws(ATVError) {
        try ATVClient.validateClientIdentity(settings: _settings, for: configuration)

        guard _settings.protocols.airplay.mrpTunnelMode != .disable else {
            throw ATVError.notSupported("AirPlay MRP tunnel is disabled by settings")
        }
        let tunnel = AirPlayMRPTunnelTransport(
            host: configuration.address,
            port: service.port,
            credentialCandidates: credentialCandidates,
            settings: _settings,
            requestTimeout: requestTimeout
        )
        let mrp = MRPService(
            transport: tunnel,
            credentials: nil,
            settings: _settings,
            authenticationMode: .alreadySecure,
            heartbeatMode: .disabled,
            requestTimeout: requestTimeout,
            runtimeRequestTimeout: runtimeRequestTimeout,
            onConnectionClosed: { [weak self] error in
                self?.protocolConnectionDidClose(error, protocol: .airPlay)
            }
        )
        do {
            try await mrp.setup()
        } catch {
            await mrp.close()
            throw error
        }

        registerMRP(mrp, for: .airPlay)
    }

    private func setupMRP(
        _ service: ServiceInfo,
        credentials: HAPCredentials?,
        requestTimeout: TimeInterval,
        runtimeRequestTimeout: TimeInterval
    ) async throws(ATVError) {
        let mrp = MRPService(
            host: configuration.address,
            port: service.port,
            credentials: credentials,
            settings: _settings,
            requestTimeout: requestTimeout,
            runtimeRequestTimeout: runtimeRequestTimeout,
            onConnectionClosed: { [weak self] error in
                self?.protocolConnectionDidClose(error, protocol: .mrp)
            }
        )
        do {
            try await mrp.setup()
        } catch {
            await mrp.close()
            throw error
        }
        registerMRP(mrp, for: .mrp)
    }

    private func registerMRP(_ mrp: MRPService, for registrationProtocol: ATVProtocol) {
        lock.withLock {
            self.mrpServices[registrationProtocol] = mrp
            self.activeProtocols.insert(registrationProtocol)
            if self.primaryProtocol == nil {
                self.primaryProtocol = registrationProtocol
            }
        }

        if let rc = mrp.remoteControl {
            remoteControlRelayer.register(rc, for: registrationProtocol)
        }
        if let metadata = mrp.metadata {
            metadataRelayer.register(metadata, for: registrationProtocol)
        }
        if let push = mrp.pushUpdater {
            pushUpdaterRelayer.register(push, for: registrationProtocol)
        }
        if let pwr = mrp.power {
            powerRelayer.register(pwr, for: registrationProtocol)
        }
        if let aud = mrp.audio {
            audioRelayer.register(aud, for: registrationProtocol)
        }
        if let caps = mrp.capabilities {
            capabilityRelayer.register(caps, for: registrationProtocol)
        }
        if let commands = mrp.mediaCommands {
            mediaCommandRelayer.register(commands, for: registrationProtocol)
        }
    }

    // MARK: - Connect / Close

    public func connect() async throws(ATVError) {
        // Connection happens during setupProtocol for each protocol
    }

    public func close() async {
        await finishWithTerminalEvent(.connectionClosed)
    }
}

// MARK: - Relayed and Unsupported Fallbacks

/// Facade-level wrappers and fallback implementations for unavailable interfaces.

struct RelayingRemoteControl: RemoteControl {
    let relayer: Relayer<RemoteControl>

    private func call(_ action: (RemoteControl) async throws -> Void) async throws(ATVError) {
        var lastUnsupported: ATVError?
        for implementation in relayer.all {
            do {
                try await action(implementation)
                return
            } catch let error as ATVError {
                if case .notSupported = error {
                    lastUnsupported = error
                    continue
                }
                throw error
            } catch {
                throw ATVError.wrap(error)
            }
        }
        throw lastUnsupported ?? ATVError.notSupported("Remote control not available")
    }

    func up(action: InputAction) async throws(ATVError) { try await call { try await $0.up(action: action) } }
    func down(action: InputAction) async throws(ATVError) { try await call { try await $0.down(action: action) } }
    func left(action: InputAction) async throws(ATVError) { try await call { try await $0.left(action: action) } }
    func right(action: InputAction) async throws(ATVError) { try await call { try await $0.right(action: action) } }
    func play() async throws(ATVError) { try await call { try await $0.play() } }
    func playPause() async throws(ATVError) { try await call { try await $0.playPause() } }
    func pause() async throws(ATVError) { try await call { try await $0.pause() } }
    func stop() async throws(ATVError) { try await call { try await $0.stop() } }
    func next() async throws(ATVError) { try await call { try await $0.next() } }
    func previous() async throws(ATVError) { try await call { try await $0.previous() } }
    func select(action: InputAction) async throws(ATVError) { try await call { try await $0.select(action: action) } }
    func menu(action: InputAction) async throws(ATVError) { try await call { try await $0.menu(action: action) } }
    func volumeUp() async throws(ATVError) { try await call { try await $0.volumeUp() } }
    func volumeDown() async throws(ATVError) { try await call { try await $0.volumeDown() } }
    func home(action: InputAction) async throws(ATVError) { try await call { try await $0.home(action: action) } }
    func homeHold() async throws(ATVError) { try await call { try await $0.homeHold() } }
    func topMenu() async throws(ATVError) { try await call { try await $0.topMenu() } }
    func suspend() async throws(ATVError) { try await call { try await $0.suspend() } }
    func wakeUp() async throws(ATVError) { try await call { try await $0.wakeUp() } }
    func skipForward(interval: TimeInterval) async throws(ATVError) {
        try await call { try await $0.skipForward(interval: interval) }
    }
    func skipBackward(interval: TimeInterval) async throws(ATVError) {
        try await call { try await $0.skipBackward(interval: interval) }
    }
    func setPosition(_ position: Int) async throws(ATVError) { try await call { try await $0.setPosition(position) } }
    func setShuffle(_ state: ShuffleState) async throws(ATVError) { try await call { try await $0.setShuffle(state) } }
    func setRepeat(_ state: RepeatState) async throws(ATVError) { try await call { try await $0.setRepeat(state) } }
    func channelUp() async throws(ATVError) { try await call { try await $0.channelUp() } }
    func channelDown() async throws(ATVError) { try await call { try await $0.channelDown() } }
    func screensaver() async throws(ATVError) { try await call { try await $0.screensaver() } }
    func guide() async throws(ATVError) { try await call { try await $0.guide() } }
    func controlCenter() async throws(ATVError) { try await call { try await $0.controlCenter() } }
}

struct RelayingMediaCommands: MediaCommandController {
    let relayer: Relayer<MediaCommandController>

    func commandInfo(_ command: MediaRemoteCommand) -> MediaCommandInfo {
        let infos = relayer.all.map { $0.commandInfo(command) }
        return infos.max { lhs, rhs in
            lhs.state.mergeRank < rhs.state.mergeRank
        } ?? MediaCommandInfo(state: .unsupported, diagnostic: "Media commands not available")
    }

    func allCommands(includeUnsupported: Bool) -> [MediaRemoteCommand: MediaCommandInfo] {
        var result: [MediaRemoteCommand: MediaCommandInfo] = [:]
        for command in MediaRemoteCommand.allCases {
            let info = commandInfo(command)
            if includeUnsupported || info.state != .unsupported {
                result[command] = info
            }
        }
        return result
    }

    func send(_ command: MediaRemoteCommand, options: MediaCommandOptions) async throws(ATVError) {
        var lastUnsupported: ATVError?
        for implementation in relayer.all {
            do {
                try await implementation.send(command, options: options)
                return
            } catch let error {
                if case .notSupported = error {
                    lastUnsupported = error
                    continue
                }
                throw error
            }
        }
        throw lastUnsupported ?? ATVError.notSupported("Media commands not available")
    }
}

struct RelayingCapabilities: CapabilityProvider {
    let relayer: Relayer<CapabilityProvider>

    func capabilityInfo(_ capability: Capability) -> CapabilityInfo {
        let infos = relayer.all.map { $0.capabilityInfo(capability) }
        return infos.max { lhs, rhs in
            lhs.state.mergeRank < rhs.state.mergeRank
        } ?? CapabilityInfo(state: .unsupported)
    }

    func allCapabilities(includeUnsupported: Bool) -> [Capability: CapabilityInfo] {
        var result: [Capability: CapabilityInfo] = [:]
        for capability in Capability.allCases {
            let info = capabilityInfo(capability)
            if includeUnsupported || info.state != .unsupported {
                result[capability] = info
            }
        }
        return result
    }

    func inState(_ states: [CapabilityState], capabilities: Capability...) -> Bool {
        capabilities.allSatisfy { states.contains(capabilityInfo($0).state) }
    }
}

extension CapabilityState {
    fileprivate var mergeRank: Int {
        switch self {
        case .available: return 3
        case .unavailable: return 2
        case .unknown: return 1
        case .unsupported: return 0
        }
    }
}

private struct UnsupportedMetadata: ATVMetadata {
    var deviceID: String? { nil }
    var artworkID: String { "" }
    var currentApp: App? { nil }
    func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo? {
        throw ATVError.notSupported("Metadata not available")
    }
    func playing() async throws(ATVError) -> Playing {
        throw ATVError.notSupported("Metadata not available")
    }
}

private struct UnsupportedPushUpdater: PushUpdater {
    var isActive: Bool { false }
    var playingStream: AsyncStream<Playing> { AsyncStream { $0.finish() } }
    func start(initialDelay: Int) async throws(ATVError) { throw ATVError.notSupported("Push updates not available") }
    func stop() async {}
}

private struct UnsupportedStream: StreamController {
    func playURL(_ url: URL) async throws(ATVError) { throw ATVError.notSupported("Streaming not available") }
    func streamFile(_ fileURL: URL, metadata: MediaMetadata?) async throws(ATVError) {
        throw ATVError.notSupported("Streaming not available")
    }
    func close() async {}
}

private struct UnsupportedPower: PowerController {
    var powerState: PowerState { get async { .unknown } }
    var powerStateStream: AsyncStream<PowerState> { AsyncStream { $0.finish() } }
    func turnOn(awaitNewState: Bool) async throws(ATVError) {
        throw ATVError.notSupported("Power control not available")
    }
    func turnOff(awaitNewState: Bool) async throws(ATVError) {
        throw ATVError.notSupported("Power control not available")
    }
}

private struct UnsupportedApps: AppsController {
    func appList() async throws(ATVError) -> [App] { throw ATVError.notSupported("Apps not available") }
    func launchApp(bundleID: String) async throws(ATVError) { throw ATVError.notSupported("Apps not available") }
}

private struct UnsupportedUserAccounts: UserAccountsController {
    func accountList() async throws(ATVError) -> [UserAccount] {
        throw ATVError.notSupported("User accounts not available")
    }
    func switchAccount(_ accountID: String) async throws(ATVError) {
        throw ATVError.notSupported("User accounts not available")
    }
}

private struct UnsupportedAudio: AudioController {
    var volume: Float { get async { 0 } }
    var volumeStream: AsyncStream<Float> { AsyncStream { $0.finish() } }
    var outputDevices: [OutputDevice] { get async { [] } }
    var outputDevicesStream: AsyncStream<[OutputDevice]> { AsyncStream { $0.finish() } }
    func setVolume(_ level: Float, device: OutputDevice?) async throws(ATVError) {
        throw ATVError.notSupported("Audio not available")
    }
    func volumeUp() async throws(ATVError) { throw ATVError.notSupported("Audio not available") }
    func volumeDown() async throws(ATVError) { throw ATVError.notSupported("Audio not available") }
    func addOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("Audio not available")
    }
    func removeOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("Audio not available")
    }
    func setOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("Audio not available")
    }
}

private struct UnsupportedKeyboard: KeyboardController {
    var textFocusState: KeyboardFocusState { get async { .unknown } }
    var focusStateStream: AsyncStream<KeyboardFocusState> { AsyncStream { $0.finish() } }
    func textGet() async throws(ATVError) -> String? { throw ATVError.notSupported("Keyboard not available") }
    func textClear() async throws(ATVError) { throw ATVError.notSupported("Keyboard not available") }
    func textAppend(_ text: String) async throws(ATVError) { throw ATVError.notSupported("Keyboard not available") }
    func textSet(_ text: String) async throws(ATVError) { throw ATVError.notSupported("Keyboard not available") }
}

private struct UnsupportedTouch: TouchController {
    func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) async throws(ATVError) {
        throw ATVError.notSupported("Touch not available")
    }
    func action(x: Int, y: Int, mode: TouchAction) async throws(ATVError) {
        throw ATVError.notSupported("Touch not available")
    }
    func click(action: InputAction) async throws(ATVError) { throw ATVError.notSupported("Touch not available") }
}
