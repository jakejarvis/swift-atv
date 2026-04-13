import Foundation

/// Facade Apple TV device that unifies multiple protocol implementations
/// behind the `AppleTVDevice` interface.
///
/// Uses the `Relayer` pattern to route method calls to the highest-priority
/// protocol that supports each feature.
///
/// Thread safety: Mutable service/event state protected by `NSLock`.
/// Relayers have their own internal locking.
public final class FacadeAppleTV: @unchecked Sendable, AppleTVDevice {
    private typealias TerminalEventDrain = (
        CompanionService?,
        MRPService?,
        AsyncStream<DeviceEvent>.Continuation?
    )

    private let configuration: AppleTVConfiguration
    private let _settings: ATVSettings
    private let lock = NSLock()
    private var companionService: CompanionService?
    private var mrpService: MRPService?

    // Relayers for each interface (internally thread-safe)
    private let remoteControlRelayer = Relayer<RemoteControl>()
    private let metadataRelayer = Relayer<ATVMetadata>()
    private let pushUpdaterRelayer = Relayer<PushUpdater>()
    private let appsRelayer = Relayer<AppsController>()
    private let userAccountsRelayer = Relayer<UserAccountsController>()
    private let powerRelayer = Relayer<PowerController>()
    private let audioRelayer = Relayer<AudioController>()
    private let keyboardRelayer = Relayer<KeyboardController>()
    private let touchRelayer = Relayer<TouchController>()
    private let featureRelayer = Relayer<FeatureProvider>()

    // Event stream
    private var eventContinuation: AsyncStream<DeviceEvent>.Continuation?
    private var _deviceEvents: AsyncStream<DeviceEvent>?
    private var pendingEvents: [DeviceEvent] = []
    private var eventStreamFinished = false

    public init(configuration: AppleTVConfiguration, settings: ATVSettings) {
        self.configuration = configuration
        self._settings = settings
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

    public var features: FeatureProvider {
        RelayingFeatures(relayer: featureRelayer)
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
        lock.lock()
        if let existing = _deviceEvents {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let stream = AsyncStream<DeviceEvent> { [weak self] continuation in
            self?.installEventContinuation(continuation)
        }

        lock.lock()
        if let existing = _deviceEvents {
            lock.unlock()
            return existing
        }
        _deviceEvents = stream
        lock.unlock()
        return stream
    }

    private func installEventContinuation(_ continuation: AsyncStream<DeviceEvent>.Continuation) {
        let (events, shouldFinish) = lock.withLock {
            self.eventContinuation = continuation
            let events = self.pendingEvents
            self.pendingEvents.removeAll()
            return (events, self.eventStreamFinished)
        }
        for event in events {
            continuation.yield(event)
        }
        if shouldFinish {
            continuation.finish()
        }
    }

    private func finishWithTerminalEvent(_ event: DeviceEvent) async {
        let drained: TerminalEventDrain? = lock.withLock {
            guard !eventStreamFinished else {
                return nil
            }

            eventStreamFinished = true
            let companion = companionService
            let mrp = mrpService
            companionService = nil
            mrpService = nil

            if eventContinuation == nil {
                pendingEvents.append(event)
            }

            return (companion, mrp, eventContinuation)
        }

        guard let (companion, mrp, continuation) = drained else {
            return
        }

        if let continuation {
            continuation.yield(event)
            continuation.finish()
        }

        await companion?.close()
        await mrp?.close()
    }

    private func protocolConnectionDidClose(_ error: Error?, protocol: ATVProtocol) {
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

    // MARK: - Setup

    /// Set up a protocol service for this device.
    public func setupProtocol(
        _ service: ServiceInfo,
        credentials resolvedCredentials: HAPCredentials? = nil
    ) async throws(ATVError) {
        let credentials: HAPCredentials?
        if let resolvedCredentials {
            credentials = resolvedCredentials
        } else {
            credentials = try ATVClient.resolvedCredentials(
                for: service,
                settings: _settings
            )
        }
        if service.pairingRequirement == .mandatory, credentials == nil {
            throw ATVError.noCredentials(
                "\(service.protocol) service requires pairing credentials"
            )
        }

        switch service.protocol {
        case .companion:
            try await setupCompanion(service, credentials: credentials)
        case .mrp:
            try await setupMRP(service, credentials: credentials)
        case .dmap, .airPlay, .raop:
            throw ATVError.notSupported("Connection not yet implemented for \(service.protocol)")
        }
    }

    private func setupCompanion(_ service: ServiceInfo, credentials: HAPCredentials?) async throws(ATVError) {
        let companion = CompanionService(
            host: configuration.address,
            port: service.port,
            credentials: credentials,
            settings: _settings,
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
        if let feat = companion.features {
            featureRelayer.register(feat, for: .companion)
        }
    }

    private func setupMRP(_ service: ServiceInfo, credentials: HAPCredentials?) async throws(ATVError) {
        let mrp = MRPService(
            host: configuration.address,
            port: service.port,
            credentials: credentials,
            settings: _settings,
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
        lock.withLock {
            self.mrpService = mrp
        }

        if let rc = mrp.remoteControl {
            remoteControlRelayer.register(rc, for: .mrp)
        }
        if let metadata = mrp.metadata {
            metadataRelayer.register(metadata, for: .mrp)
        }
        if let push = mrp.pushUpdater {
            pushUpdaterRelayer.register(push, for: .mrp)
        }
        if let pwr = mrp.power {
            powerRelayer.register(pwr, for: .mrp)
        }
        if let aud = mrp.audio {
            audioRelayer.register(aud, for: .mrp)
        }
        if let feat = mrp.features {
            featureRelayer.register(feat, for: .mrp)
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

struct RelayingFeatures: FeatureProvider {
    let relayer: Relayer<FeatureProvider>

    func featureInfo(_ feature: FeatureName) -> FeatureInfo {
        let infos = relayer.all.map { $0.featureInfo(feature) }
        return infos.first { $0.state != .unsupported } ?? infos.first ?? FeatureInfo(state: .unsupported)
    }

    func allFeatures(includeUnsupported: Bool) -> [FeatureName: FeatureInfo] {
        var result: [FeatureName: FeatureInfo] = [:]
        for feature in FeatureName.allCases {
            let info = featureInfo(feature)
            if includeUnsupported || info.state != .unsupported {
                result[feature] = info
            }
        }
        return result
    }

    func inState(_ states: [FeatureState], features: FeatureName...) -> Bool {
        features.allSatisfy { states.contains(featureInfo($0).state) }
    }
}

private struct UnsupportedMetadata: ATVMetadata {
    var deviceID: String? { nil }
    var artworkID: String { "" }
    var currentApp: App? { nil }
    func artwork(width: Int?, height: Int?) async throws(ATVError) -> ArtworkInfo? { nil }
    func playing() async throws(ATVError) -> Playing { Playing() }
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
