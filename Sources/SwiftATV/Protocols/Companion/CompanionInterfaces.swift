import Foundation

/// Maps FeatureName to HIDCommand for remote control.
private let featureToHID: [FeatureName: HIDCommand] = [
    .up: .up,
    .down: .down,
    .left: .left,
    .right: .right,
    .menu: .menu,
    .select: .select,
    .home: .home,
    .volumeUp: .volumeUp,
    .volumeDown: .volumeDown,
    .playPause: .playPause,
    .channelUp: .channelIncrement,
    .channelDown: .channelDecrement,
    .screensaver: .screensaver,
    .guide: .guide,
]

/// Touchpad coordinate range.
private let touchpadWidth: Double = 1000.0
private let touchpadHeight: Double = 1000.0

/// Companion protocol implementation of RemoteControl.
public final class CompanionRemoteControl: RemoteControl, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
    }

    // MARK: - HID Commands

    private func sendHIDCommand(_ command: HIDCommand, action: InputAction) async throws {
        // Button down
        let downContent = OPACK.Value.dictionary([
            ("_hBtS", .uint(1)), // button state: down
            ("_hidC", .uint(UInt64(command.rawValue))),
        ])
        try await protocol_.sendEvent("_hidC", content: downContent)

        // For hold actions, add a delay
        if action == .hold {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second hold
        }

        // Button up
        let upContent = OPACK.Value.dictionary([
            ("_hBtS", .uint(2)), // button state: up
            ("_hidC", .uint(UInt64(command.rawValue))),
        ])
        try await protocol_.sendEvent("_hidC", content: upContent)

        // For double tap, repeat
        if action == .doubleTap {
            try await sendHIDCommand(command, action: .singleTap)
        }
    }

    public func up(action: InputAction) async throws {
        try await sendHIDCommand(.up, action: action)
    }

    public func down(action: InputAction) async throws {
        try await sendHIDCommand(.down, action: action)
    }

    public func left(action: InputAction) async throws {
        try await sendHIDCommand(.left, action: action)
    }

    public func right(action: InputAction) async throws {
        try await sendHIDCommand(.right, action: action)
    }

    public func play() async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.play.rawValue))),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
    }

    public func playPause() async throws {
        try await sendHIDCommand(.playPause, action: .singleTap)
    }

    public func pause() async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.pause.rawValue))),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
    }

    public func stop() async throws {
        try await pause()
    }

    public func next() async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.nextTrack.rawValue))),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
    }

    public func previous() async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.previousTrack.rawValue))),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
    }

    public func select(action: InputAction) async throws {
        try await sendHIDCommand(.select, action: action)
    }

    public func menu(action: InputAction) async throws {
        try await sendHIDCommand(.menu, action: action)
    }

    public func volumeUp() async throws {
        try await sendHIDCommand(.volumeUp, action: .singleTap)
    }

    public func volumeDown() async throws {
        try await sendHIDCommand(.volumeDown, action: .singleTap)
    }

    public func home(action: InputAction) async throws {
        try await sendHIDCommand(.home, action: action)
    }

    public func homeHold() async throws {
        try await sendHIDCommand(.home, action: .hold)
    }

    public func topMenu() async throws {
        try await sendHIDCommand(.menu, action: .singleTap)
    }

    public func suspend() async throws {
        try await sendHIDCommand(.sleep, action: .singleTap)
    }

    public func wakeUp() async throws {
        try await sendHIDCommand(.wake, action: .singleTap)
    }

    public func skipForward(interval: TimeInterval) async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.skipBy.rawValue))),
            ("_ski", .double(interval)),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
    }

    public func skipBackward(interval: TimeInterval) async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.skipBy.rawValue))),
            ("_ski", .double(-interval)),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
    }

    public func setPosition(_ position: Int) async throws {
        throw ATVError.notSupported("setPosition not supported via Companion")
    }

    public func setShuffle(_ state: ShuffleState) async throws {
        throw ATVError.notSupported("setShuffle not supported via Companion")
    }

    public func setRepeat(_ state: RepeatState) async throws {
        throw ATVError.notSupported("setRepeat not supported via Companion")
    }

    public func channelUp() async throws {
        try await sendHIDCommand(.channelIncrement, action: .singleTap)
    }

    public func channelDown() async throws {
        try await sendHIDCommand(.channelDecrement, action: .singleTap)
    }

    public func screensaver() async throws {
        try await sendHIDCommand(.screensaver, action: .singleTap)
    }

    public func guide() async throws {
        try await sendHIDCommand(.guide, action: .singleTap)
    }

    public func controlCenter() async throws {
        // Control center is typically accessed via home hold
        try await sendHIDCommand(.home, action: .hold)
    }
}

// MARK: - Apps

/// Companion protocol implementation of AppsController.
public final class CompanionApps: AppsController, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
    }

    public func appList() async throws -> [App] {
        let response = try await protocol_.sendRequest("FetchLaunchableApplicationsEvent")
        guard case .dict(let pairs) = response["_c"] else {
            return []
        }

        var apps: [App] = []
        for (key, value) in pairs {
            if let bundleID = key.stringValue, let name = value.stringValue {
                apps.append(App(name: name, identifier: bundleID))
            }
        }
        return apps
    }

    public func launchApp(bundleID: String) async throws {
        let content = OPACK.Value.dictionary([
            ("_bundleID", .string(bundleID)),
        ])
        _ = try await protocol_.sendRequest("_launchApp", content: content)
    }
}

// MARK: - User Accounts

/// Companion protocol implementation of UserAccountsController.
public final class CompanionUserAccounts: UserAccountsController, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
    }

    public func accountList() async throws -> [UserAccount] {
        let response = try await protocol_.sendRequest("FetchUserAccountsEvent")
        guard case .dict(let pairs) = response["_c"] else {
            return []
        }

        var accounts: [UserAccount] = []
        for (key, value) in pairs {
            if let id = key.stringValue, let name = value.stringValue {
                accounts.append(UserAccount(name: name, identifier: id))
            }
        }
        return accounts
    }

    public func switchAccount(_ accountID: String) async throws {
        let content = OPACK.Value.dictionary([
            ("SwitchAccountID", .string(accountID)),
        ])
        _ = try await protocol_.sendRequest("SwitchUserAccountEvent", content: content)
    }
}

// MARK: - Power

/// Companion protocol implementation of PowerController.
public final class CompanionPower: PowerController, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler
    private var currentPowerState: PowerState = .unknown
    private var continuation: AsyncStream<PowerState>.Continuation?
    private var _powerStream: AsyncStream<PowerState>?

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
    }

    public var powerState: PowerState {
        get async { currentPowerState }
    }

    public var powerStateStream: AsyncStream<PowerState> {
        if let existing = _powerStream { return existing }
        let stream = AsyncStream<PowerState> { continuation in
            self.continuation = continuation
        }
        _powerStream = stream
        return stream
    }

    public func turnOn(awaitNewState: Bool) async throws {
        try await protocol_.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(1)),
            ("_hidC", .uint(UInt64(HIDCommand.wake.rawValue))),
        ]))
        try await protocol_.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(2)),
            ("_hidC", .uint(UInt64(HIDCommand.wake.rawValue))),
        ]))
        updatePowerState(.on)
    }

    public func turnOff(awaitNewState: Bool) async throws {
        try await protocol_.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(1)),
            ("_hidC", .uint(UInt64(HIDCommand.sleep.rawValue))),
        ]))
        try await protocol_.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(2)),
            ("_hidC", .uint(UInt64(HIDCommand.sleep.rawValue))),
        ]))
        updatePowerState(.off)
    }

    private func updatePowerState(_ state: PowerState) {
        currentPowerState = state
        continuation?.yield(state)
    }
}

// MARK: - Audio

/// Companion protocol implementation of AudioController.
public final class CompanionAudio: AudioController, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler
    private var currentVolume: Float = 0
    private var currentOutputDevices: [OutputDevice] = []
    private var volumeContinuation: AsyncStream<Float>.Continuation?
    private var devicesContinuation: AsyncStream<[OutputDevice]>.Continuation?

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
    }

    public var volume: Float { get async { currentVolume } }

    public var volumeStream: AsyncStream<Float> {
        AsyncStream { continuation in
            self.volumeContinuation = continuation
        }
    }

    public var outputDevices: [OutputDevice] { get async { currentOutputDevices } }

    public var outputDevicesStream: AsyncStream<[OutputDevice]> {
        AsyncStream { continuation in
            self.devicesContinuation = continuation
        }
    }

    public func setVolume(_ level: Float, device: OutputDevice?) async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.setVolume.rawValue))),
            ("_vol", .double(Double(level))),
        ])
        _ = try await protocol_.sendRequest("_mcc", content: content)
        currentVolume = level
        volumeContinuation?.yield(level)
    }

    public func volumeUp() async throws {
        try await setVolume(min(currentVolume + 5, 100))
    }

    public func volumeDown() async throws {
        try await setVolume(max(currentVolume - 5, 0))
    }

    public func addOutputDevices(_ deviceIDs: [String]) async throws {
        throw ATVError.notSupported("addOutputDevices not yet implemented for Companion")
    }

    public func removeOutputDevices(_ deviceIDs: [String]) async throws {
        throw ATVError.notSupported("removeOutputDevices not yet implemented for Companion")
    }

    public func setOutputDevices(_ deviceIDs: [String]) async throws {
        throw ATVError.notSupported("setOutputDevices not yet implemented for Companion")
    }
}

// MARK: - Keyboard

/// Companion protocol implementation of KeyboardController.
public final class CompanionKeyboard: KeyboardController, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler
    private var currentFocusState: KeyboardFocusState = .unknown

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
    }

    public var textFocusState: KeyboardFocusState {
        get async { currentFocusState }
    }

    public var focusStateStream: AsyncStream<KeyboardFocusState> {
        AsyncStream { _ in }
    }

    public func textGet() async throws -> String? {
        throw ATVError.notSupported("textGet not yet implemented for Companion")
    }

    public func textClear() async throws {
        throw ATVError.notSupported("textClear not yet implemented for Companion")
    }

    public func textAppend(_ text: String) async throws {
        throw ATVError.notSupported("textAppend not yet implemented for Companion")
    }

    public func textSet(_ text: String) async throws {
        throw ATVError.notSupported("textSet not yet implemented for Companion")
    }
}

// MARK: - Touch

/// Companion protocol implementation of TouchController.
public final class CompanionTouch: TouchController, @unchecked Sendable {
    private let protocol_: CompanionProtocolHandler
    private var baseTimestamp: UInt64

    public init(protocol: CompanionProtocolHandler) {
        self.protocol_ = `protocol`
        self.baseTimestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    private var currentTimestamp: UInt64 {
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return now - baseTimestamp
    }

    public func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) async throws {
        let steps = max(durationMs / 16, 2) // 16ms per step
        let delayNs: UInt64 = 16_000_000

        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let x = Int(Double(startX) + progress * Double(endX - startX))
            let y = Int(Double(startY) + progress * Double(endY - startY))

            let phase: TouchAction
            if i == 0 {
                phase = .press
            } else if i == steps {
                phase = .release
            } else {
                phase = .hold
            }

            try await sendTouchEvent(x: x, y: y, phase: phase)
            if i < steps {
                try await Task.sleep(nanoseconds: delayNs)
            }
        }
    }

    public func action(x: Int, y: Int, mode: TouchAction) async throws {
        try await sendTouchEvent(x: x, y: y, phase: mode)
    }

    public func click(action: InputAction) async throws {
        try await sendTouchEvent(x: 500, y: 500, phase: .click)
    }

    private func sendTouchEvent(x: Int, y: Int, phase: TouchAction) async throws {
        let content = OPACK.Value.dictionary([
            ("_ns", .uint(currentTimestamp)),
            ("_tFg", .uint(1)),
            ("_cx", .uint(UInt64(x))),
            ("_cy", .uint(UInt64(y))),
            ("_tPh", .uint(UInt64(phase.rawValue))),
        ])
        try await protocol_.sendEvent("_hidT", content: content)
    }
}

// MARK: - Features

/// Companion protocol implementation of FeatureProvider.
public final class CompanionFeatures: FeatureProvider, @unchecked Sendable {
    private let isConnected: Bool

    /// Features supported by the Companion protocol.
    private static let supportedFeatures: Set<FeatureName> = [
        .up, .down, .left, .right,
        .play, .playPause, .pause, .stop,
        .next, .previous, .select, .menu,
        .volumeUp, .volumeDown, .home, .homeHold,
        .topMenu, .suspend, .wakeUp,
        .skipForward, .skipBackward,
        .channelUp, .channelDown,
        .screensaver, .guide, .controlCenter,
        .appList, .launchApp,
        .accountList, .switchAccount,
        .turnOn, .turnOff, .powerState,
        .swipe, .action, .click,
    ]

    public init(isConnected: Bool = true) {
        self.isConnected = isConnected
    }

    public func featureInfo(_ feature: FeatureName) -> FeatureInfo {
        if Self.supportedFeatures.contains(feature) {
            return FeatureInfo(state: isConnected ? .available : .unavailable)
        }
        return FeatureInfo(state: .unsupported)
    }

    public func allFeatures(includeUnsupported: Bool) -> [FeatureName: FeatureInfo] {
        var result: [FeatureName: FeatureInfo] = [:]
        for feature in FeatureName.allCases {
            let info = featureInfo(feature)
            if includeUnsupported || info.state != .unsupported {
                result[feature] = info
            }
        }
        return result
    }

    public func inState(_ states: [FeatureState], features: FeatureName...) -> Bool {
        features.allSatisfy { feature in
            states.contains(featureInfo(feature).state)
        }
    }
}
