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

    private let configuration: AppleTVConfiguration
    private let _settings: ATVSettings
    private let lock = NSLock()
    private var companionService: CompanionService?

    // Relayers for each interface (internally thread-safe)
    private let remoteControlRelayer = Relayer<RemoteControl>()
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

    public init(configuration: AppleTVConfiguration, settings: ATVSettings) {
        self.configuration = configuration
        self._settings = settings
    }

    // MARK: - AppleTVDevice

    public var settings: ATVSettings { _settings }

    public var deviceInfo: DeviceInfo { configuration.deviceInfo }

    public var remoteControl: RemoteControl {
        remoteControlRelayer.main ?? UnsupportedRemoteControl()
    }

    public var metadata: ATVMetadata {
        UnsupportedMetadata()
    }

    public var pushUpdater: PushUpdater {
        UnsupportedPushUpdater()
    }

    public var stream: StreamController {
        UnsupportedStream()
    }

    public var power: PowerController {
        powerRelayer.main ?? UnsupportedPower()
    }

    public var features: FeatureProvider {
        featureRelayer.main ?? UnsupportedFeatures()
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
        defer { lock.unlock() }
        if let existing = _deviceEvents { return existing }
        let stream = AsyncStream<DeviceEvent> { [weak self] continuation in
            self?.lock.lock()
            self?.eventContinuation = continuation
            self?.lock.unlock()
        }
        _deviceEvents = stream
        return stream
    }

    // MARK: - Setup

    /// Set up a protocol service for this device.
    public func setupProtocol(_ service: ServiceInfo) async throws {
        switch service.protocol {
        case .companion:
            try await setupCompanion(service)
        case .mrp, .dmap, .airPlay, .raop:
            // These protocols will be added in future phases
            break
        }
    }

    private func setupCompanion(_ service: ServiceInfo) async throws {
        // Parse credentials from settings
        var credentials: HAPCredentials?
        if let credStr = _settings.protocols.companion.credentials {
            credentials = try? HAPCredentials.parse(credStr)
        }

        let companion = CompanionService(
            host: configuration.address,
            port: service.port,
            credentials: credentials
        )
        try await companion.setup()
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

    // MARK: - Connect / Close

    public func connect() async throws {
        // Connection happens during setupProtocol for each protocol
    }

    public func close() async {
        let (service, cont) = lock.withLock {
            (companionService, eventContinuation)
        }
        await service?.close()
        cont?.finish()
    }
}

// MARK: - Unsupported Fallbacks

/// Fallback implementations that throw `.notSupported` for all methods.

private struct UnsupportedRemoteControl: RemoteControl {
    func up(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func down(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func left(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func right(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func play() async throws { throw ATVError.notSupported("Remote control not available") }
    func playPause() async throws { throw ATVError.notSupported("Remote control not available") }
    func pause() async throws { throw ATVError.notSupported("Remote control not available") }
    func stop() async throws { throw ATVError.notSupported("Remote control not available") }
    func next() async throws { throw ATVError.notSupported("Remote control not available") }
    func previous() async throws { throw ATVError.notSupported("Remote control not available") }
    func select(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func menu(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func volumeUp() async throws { throw ATVError.notSupported("Remote control not available") }
    func volumeDown() async throws { throw ATVError.notSupported("Remote control not available") }
    func home(action: InputAction) async throws { throw ATVError.notSupported("Remote control not available") }
    func homeHold() async throws { throw ATVError.notSupported("Remote control not available") }
    func topMenu() async throws { throw ATVError.notSupported("Remote control not available") }
    func suspend() async throws { throw ATVError.notSupported("Remote control not available") }
    func wakeUp() async throws { throw ATVError.notSupported("Remote control not available") }
    func skipForward(interval: TimeInterval) async throws { throw ATVError.notSupported("Remote control not available") }
    func skipBackward(interval: TimeInterval) async throws { throw ATVError.notSupported("Remote control not available") }
    func setPosition(_ position: Int) async throws { throw ATVError.notSupported("Remote control not available") }
    func setShuffle(_ state: ShuffleState) async throws { throw ATVError.notSupported("Remote control not available") }
    func setRepeat(_ state: RepeatState) async throws { throw ATVError.notSupported("Remote control not available") }
    func channelUp() async throws { throw ATVError.notSupported("Remote control not available") }
    func channelDown() async throws { throw ATVError.notSupported("Remote control not available") }
    func screensaver() async throws { throw ATVError.notSupported("Remote control not available") }
    func guide() async throws { throw ATVError.notSupported("Remote control not available") }
    func controlCenter() async throws { throw ATVError.notSupported("Remote control not available") }
}

private struct UnsupportedMetadata: ATVMetadata {
    var deviceID: String? { nil }
    var artworkID: String { "" }
    var currentApp: App? { nil }
    func artwork(width: Int?, height: Int?) async throws -> ArtworkInfo? { nil }
    func playing() async throws -> Playing { Playing() }
}

private struct UnsupportedPushUpdater: PushUpdater {
    var isActive: Bool { false }
    var playingStream: AsyncStream<Playing> { AsyncStream { $0.finish() } }
    func start(initialDelay: Int) async throws { throw ATVError.notSupported("Push updates not available") }
    func stop() async {}
}

private struct UnsupportedStream: StreamController {
    func playURL(_ url: URL) async throws { throw ATVError.notSupported("Streaming not available") }
    func streamFile(_ fileURL: URL, metadata: MediaMetadata?) async throws { throw ATVError.notSupported("Streaming not available") }
    func close() async {}
}

private struct UnsupportedPower: PowerController {
    var powerState: PowerState { get async { .unknown } }
    var powerStateStream: AsyncStream<PowerState> { AsyncStream { $0.finish() } }
    func turnOn(awaitNewState: Bool) async throws { throw ATVError.notSupported("Power control not available") }
    func turnOff(awaitNewState: Bool) async throws { throw ATVError.notSupported("Power control not available") }
}

private struct UnsupportedFeatures: FeatureProvider {
    func featureInfo(_ feature: FeatureName) -> FeatureInfo { FeatureInfo(state: .unsupported) }
    func allFeatures(includeUnsupported: Bool) -> [FeatureName: FeatureInfo] { [:] }
    func inState(_ states: [FeatureState], features: FeatureName...) -> Bool { false }
}

private struct UnsupportedApps: AppsController {
    func appList() async throws -> [App] { throw ATVError.notSupported("Apps not available") }
    func launchApp(bundleID: String) async throws { throw ATVError.notSupported("Apps not available") }
}

private struct UnsupportedUserAccounts: UserAccountsController {
    func accountList() async throws -> [UserAccount] { throw ATVError.notSupported("User accounts not available") }
    func switchAccount(_ accountID: String) async throws { throw ATVError.notSupported("User accounts not available") }
}

private struct UnsupportedAudio: AudioController {
    var volume: Float { get async { 0 } }
    var volumeStream: AsyncStream<Float> { AsyncStream { $0.finish() } }
    var outputDevices: [OutputDevice] { get async { [] } }
    var outputDevicesStream: AsyncStream<[OutputDevice]> { AsyncStream { $0.finish() } }
    func setVolume(_ level: Float, device: OutputDevice?) async throws { throw ATVError.notSupported("Audio not available") }
    func volumeUp() async throws { throw ATVError.notSupported("Audio not available") }
    func volumeDown() async throws { throw ATVError.notSupported("Audio not available") }
    func addOutputDevices(_ deviceIDs: [String]) async throws { throw ATVError.notSupported("Audio not available") }
    func removeOutputDevices(_ deviceIDs: [String]) async throws { throw ATVError.notSupported("Audio not available") }
    func setOutputDevices(_ deviceIDs: [String]) async throws { throw ATVError.notSupported("Audio not available") }
}

private struct UnsupportedKeyboard: KeyboardController {
    var textFocusState: KeyboardFocusState { get async { .unknown } }
    var focusStateStream: AsyncStream<KeyboardFocusState> { AsyncStream { $0.finish() } }
    func textGet() async throws -> String? { throw ATVError.notSupported("Keyboard not available") }
    func textClear() async throws { throw ATVError.notSupported("Keyboard not available") }
    func textAppend(_ text: String) async throws { throw ATVError.notSupported("Keyboard not available") }
    func textSet(_ text: String) async throws { throw ATVError.notSupported("Keyboard not available") }
}

private struct UnsupportedTouch: TouchController {
    func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) async throws { throw ATVError.notSupported("Touch not available") }
    func action(x: Int, y: Int, mode: TouchAction) async throws { throw ATVError.notSupported("Touch not available") }
    func click(action: InputAction) async throws { throw ATVError.notSupported("Touch not available") }
}
