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

/// Companion protocol implementation of RemoteControl.
/// Stateless wrapper -- all state managed by the actor.
public struct CompanionRemoteControl: RemoteControl, Sendable {
    private let handler: CompanionProtocolHandler

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    // MARK: - HID Commands

    private func sendHIDCommand(_ command: HIDCommand, action: InputAction) async throws {
        let downContent = OPACK.Value.dictionary([
            ("_hBtS", .uint(1)),
            ("_hidC", .uint(UInt64(command.rawValue))),
        ])
        try await handler.sendEvent("_hidC", content: downContent)

        if action == .hold {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let upContent = OPACK.Value.dictionary([
            ("_hBtS", .uint(2)),
            ("_hidC", .uint(UInt64(command.rawValue))),
        ])
        try await handler.sendEvent("_hidC", content: upContent)

        if action == .doubleTap {
            try await sendHIDCommand(command, action: .singleTap)
        }
    }

    public func up(action: InputAction) async throws { try await sendHIDCommand(.up, action: action) }
    public func down(action: InputAction) async throws { try await sendHIDCommand(.down, action: action) }
    public func left(action: InputAction) async throws { try await sendHIDCommand(.left, action: action) }
    public func right(action: InputAction) async throws { try await sendHIDCommand(.right, action: action) }

    public func play() async throws {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.play.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func playPause() async throws { try await sendHIDCommand(.playPause, action: .singleTap) }

    public func pause() async throws {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.pause.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func stop() async throws { try await pause() }

    public func next() async throws {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.nextTrack.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func previous() async throws {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.previousTrack.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func select(action: InputAction) async throws { try await sendHIDCommand(.select, action: action) }
    public func menu(action: InputAction) async throws { try await sendHIDCommand(.menu, action: action) }
    public func volumeUp() async throws { try await sendHIDCommand(.volumeUp, action: .singleTap) }
    public func volumeDown() async throws { try await sendHIDCommand(.volumeDown, action: .singleTap) }
    public func home(action: InputAction) async throws { try await sendHIDCommand(.home, action: action) }
    public func homeHold() async throws { try await sendHIDCommand(.home, action: .hold) }
    public func topMenu() async throws { try await sendHIDCommand(.menu, action: .singleTap) }
    public func suspend() async throws { try await sendHIDCommand(.sleep, action: .singleTap) }
    public func wakeUp() async throws { try await sendHIDCommand(.wake, action: .singleTap) }

    public func skipForward(interval: TimeInterval) async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.skipBy.rawValue))),
            ("_ski", .double(interval)),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func skipBackward(interval: TimeInterval) async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.skipBy.rawValue))),
            ("_ski", .double(-interval)),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
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

    public func channelUp() async throws { try await sendHIDCommand(.channelIncrement, action: .singleTap) }
    public func channelDown() async throws { try await sendHIDCommand(.channelDecrement, action: .singleTap) }
    public func screensaver() async throws { try await sendHIDCommand(.screensaver, action: .singleTap) }
    public func guide() async throws { try await sendHIDCommand(.guide, action: .singleTap) }
    public func controlCenter() async throws { try await sendHIDCommand(.home, action: .hold) }
}

// MARK: - Apps

/// Companion protocol implementation of AppsController.
/// Stateless wrapper -- all state managed by the actor.
public struct CompanionApps: AppsController, Sendable {
    private let handler: CompanionProtocolHandler

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    public func appList() async throws -> [App] {
        let response = try await handler.sendRequest("FetchLaunchableApplicationsEvent")
        guard case .dict(let pairs) = response["_c"] else { return [] }
        return pairs.compactMap { key, value in
            guard let bundleID = key.stringValue, let name = value.stringValue else { return nil }
            return App(name: name, identifier: bundleID)
        }
    }

    public func launchApp(bundleID: String) async throws {
        let content = OPACK.Value.dictionary([("_bundleID", .string(bundleID))])
        _ = try await handler.sendRequest("_launchApp", content: content)
    }
}

// MARK: - User Accounts

/// Companion protocol implementation of UserAccountsController.
/// Stateless wrapper -- all state managed by the actor.
public struct CompanionUserAccounts: UserAccountsController, Sendable {
    private let handler: CompanionProtocolHandler

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    public func accountList() async throws -> [UserAccount] {
        let response = try await handler.sendRequest("FetchUserAccountsEvent")
        guard case .dict(let pairs) = response["_c"] else { return [] }
        return pairs.compactMap { key, value in
            guard let id = key.stringValue, let name = value.stringValue else { return nil }
            return UserAccount(name: name, identifier: id)
        }
    }

    public func switchAccount(_ accountID: String) async throws {
        let content = OPACK.Value.dictionary([("SwitchAccountID", .string(accountID))])
        _ = try await handler.sendRequest("SwitchUserAccountEvent", content: content)
    }
}

// MARK: - Power

/// Companion protocol implementation of PowerController.
/// Uses NSLock to protect mutable power state.
public final class CompanionPower: PowerController, @unchecked Sendable {
    private let handler: CompanionProtocolHandler
    private let lock = NSLock()
    private var _powerState: PowerState = .unknown
    private var continuation: AsyncStream<PowerState>.Continuation?
    private var _powerStream: AsyncStream<PowerState>?

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    public var powerState: PowerState {
        get async {
            lock.lock()
            defer { lock.unlock() }
            return _powerState
        }
    }

    public var powerStateStream: AsyncStream<PowerState> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _powerStream { return existing }
        let stream = AsyncStream<PowerState> { [weak self] continuation in
            self?.lock.lock()
            self?.continuation = continuation
            self?.lock.unlock()
        }
        _powerStream = stream
        return stream
    }

    public func turnOn(awaitNewState: Bool) async throws {
        try await handler.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(1)),
            ("_hidC", .uint(UInt64(HIDCommand.wake.rawValue))),
        ]))
        try await handler.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(2)),
            ("_hidC", .uint(UInt64(HIDCommand.wake.rawValue))),
        ]))
        updatePowerState(.on)
    }

    public func turnOff(awaitNewState: Bool) async throws {
        try await handler.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(1)),
            ("_hidC", .uint(UInt64(HIDCommand.sleep.rawValue))),
        ]))
        try await handler.sendEvent("_hidC", content: OPACK.Value.dictionary([
            ("_hBtS", .uint(2)),
            ("_hidC", .uint(UInt64(HIDCommand.sleep.rawValue))),
        ]))
        updatePowerState(.off)
    }

    private func updatePowerState(_ state: PowerState) {
        lock.lock()
        _powerState = state
        let cont = continuation
        lock.unlock()
        cont?.yield(state)
    }
}

// MARK: - Audio

/// Companion protocol implementation of AudioController.
/// Uses NSLock to protect mutable volume/device state.
public final class CompanionAudio: AudioController, @unchecked Sendable {
    private let handler: CompanionProtocolHandler
    private let lock = NSLock()
    private var _volume: Float = 0
    private var _outputDevices: [OutputDevice] = []
    private var volumeContinuation: AsyncStream<Float>.Continuation?
    private var devicesContinuation: AsyncStream<[OutputDevice]>.Continuation?

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    public var volume: Float {
        get async {
            lock.lock()
            defer { lock.unlock() }
            return _volume
        }
    }

    public var volumeStream: AsyncStream<Float> {
        AsyncStream { [weak self] continuation in
            self?.lock.lock()
            self?.volumeContinuation = continuation
            self?.lock.unlock()
        }
    }

    public var outputDevices: [OutputDevice] {
        get async {
            lock.lock()
            defer { lock.unlock() }
            return _outputDevices
        }
    }

    public var outputDevicesStream: AsyncStream<[OutputDevice]> {
        AsyncStream { [weak self] continuation in
            self?.lock.lock()
            self?.devicesContinuation = continuation
            self?.lock.unlock()
        }
    }

    public func setVolume(_ level: Float, device: OutputDevice?) async throws {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.setVolume.rawValue))),
            ("_vol", .double(Double(level))),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
        lock.lock()
        _volume = level
        let cont = volumeContinuation
        lock.unlock()
        cont?.yield(level)
    }

    public func volumeUp() async throws {
        let current = await volume
        try await setVolume(min(current + 5, 100))
    }

    public func volumeDown() async throws {
        let current = await volume
        try await setVolume(max(current - 5, 0))
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
/// Uses NSLock to protect mutable focus state.
public final class CompanionKeyboard: KeyboardController, @unchecked Sendable {
    private let handler: CompanionProtocolHandler
    private let lock = NSLock()
    private var _focusState: KeyboardFocusState = .unknown

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    public var textFocusState: KeyboardFocusState {
        get async {
            lock.lock()
            defer { lock.unlock() }
            return _focusState
        }
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
/// Stateless wrapper -- timestamp is derived from clock, not mutable state.
public struct CompanionTouch: TouchController, Sendable {
    private let handler: CompanionProtocolHandler
    private let baseTimestamp: UInt64

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
        self.baseTimestamp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    private var currentTimestamp: UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1_000_000_000) - baseTimestamp
    }

    public func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) async throws {
        let steps = max(durationMs / 16, 2)
        let delayNs: UInt64 = 16_000_000

        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let x = Int(Double(startX) + progress * Double(endX - startX))
            let y = Int(Double(startY) + progress * Double(endY - startY))

            let phase: TouchAction
            if i == 0 { phase = .press }
            else if i == steps { phase = .release }
            else { phase = .hold }

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
        try await handler.sendEvent("_hidT", content: content)
    }
}

// MARK: - Features

/// Companion protocol implementation of FeatureProvider.
/// Immutable -- all properties are `let`. Naturally Sendable.
public struct CompanionFeatures: FeatureProvider, Sendable {
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
