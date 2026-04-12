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

    private func sendHIDCommand(_ command: HIDCommand, action: InputAction) async throws(ATVError) {
        let tapCount = action == .doubleTap ? 2 : 1
        for tapIndex in 0..<tapCount {
            try await sendHIDButton(command, down: true)

            if action == .hold {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }

            try await sendHIDButton(command, down: false)

            if tapIndex + 1 < tapCount {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    private func sendHIDButton(_ command: HIDCommand, down: Bool) async throws(ATVError) {
        let downContent = OPACK.Value.dictionary([
            ("_hBtS", .uint(down ? 1 : 2)),
            ("_hidC", .uint(UInt64(command.rawValue))),
        ])
        _ = try await handler.sendRequest("_hidC", content: downContent)
    }

    public func up(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.up, action: action) }
    public func down(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.down, action: action) }
    public func left(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.left, action: action) }
    public func right(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.right, action: action) }

    public func play() async throws(ATVError) {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.play.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func playPause() async throws(ATVError) { try await sendHIDCommand(.playPause, action: .singleTap) }

    public func pause() async throws(ATVError) {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.pause.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func stop() async throws(ATVError) { try await pause() }

    public func next() async throws(ATVError) {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.nextTrack.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func previous() async throws(ATVError) {
        let content = OPACK.Value.dictionary([("_mcc", .uint(UInt64(MediaControlCommand.previousTrack.rawValue)))])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func select(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.select, action: action) }
    public func menu(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.menu, action: action) }
    public func volumeUp() async throws(ATVError) { try await sendHIDCommand(.volumeUp, action: .singleTap) }
    public func volumeDown() async throws(ATVError) { try await sendHIDCommand(.volumeDown, action: .singleTap) }
    public func home(action: InputAction) async throws(ATVError) { try await sendHIDCommand(.home, action: action) }
    public func homeHold() async throws(ATVError) { try await sendHIDCommand(.home, action: .hold) }
    public func topMenu() async throws(ATVError) { try await sendHIDCommand(.menu, action: .singleTap) }
    public func suspend() async throws(ATVError) { try await sendHIDCommand(.sleep, action: .singleTap) }
    public func wakeUp() async throws(ATVError) { try await sendHIDCommand(.wake, action: .singleTap) }

    public func skipForward(interval: TimeInterval) async throws(ATVError) {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.skipBy.rawValue))),
            ("_ski", .double(interval)),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func skipBackward(interval: TimeInterval) async throws(ATVError) {
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.skipBy.rawValue))),
            ("_ski", .double(-interval)),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
    }

    public func setPosition(_ position: Int) async throws(ATVError) {
        throw ATVError.notSupported("setPosition not supported via Companion")
    }

    public func setShuffle(_ state: ShuffleState) async throws(ATVError) {
        throw ATVError.notSupported("setShuffle not supported via Companion")
    }

    public func setRepeat(_ state: RepeatState) async throws(ATVError) {
        throw ATVError.notSupported("setRepeat not supported via Companion")
    }

    public func channelUp() async throws(ATVError) { try await sendHIDCommand(.channelIncrement, action: .singleTap) }
    public func channelDown() async throws(ATVError) { try await sendHIDCommand(.channelDecrement, action: .singleTap) }
    public func screensaver() async throws(ATVError) { try await sendHIDCommand(.screensaver, action: .singleTap) }
    public func guide() async throws(ATVError) { try await sendHIDCommand(.guide, action: .singleTap) }
    public func controlCenter() async throws(ATVError) { try await sendHIDCommand(.pageDown, action: .singleTap) }
}

// MARK: - Apps

/// Companion protocol implementation of AppsController.
/// Stateless wrapper -- all state managed by the actor.
public struct CompanionApps: AppsController, Sendable {
    private let handler: CompanionProtocolHandler

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
    }

    public func appList() async throws(ATVError) -> [App] {
        let response = try await handler.sendRequest("FetchLaunchableApplicationsEvent")
        guard case .dict(let pairs) = response["_c"] else { return [] }
        return pairs.compactMap { key, value in
            guard let bundleID = key.stringValue, let name = value.stringValue else { return nil }
            return App(name: name, identifier: bundleID)
        }
    }

    public func launchApp(bundleID: String) async throws(ATVError) {
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

    public func accountList() async throws(ATVError) -> [UserAccount] {
        let response = try await handler.sendRequest("FetchUserAccountsEvent")
        guard case .dict(let pairs) = response["_c"] else { return [] }
        return pairs.compactMap { key, value in
            guard let id = key.stringValue, let name = value.stringValue else { return nil }
            return UserAccount(name: name, identifier: id)
        }
    }

    public func switchAccount(_ accountID: String) async throws(ATVError) {
        let content = OPACK.Value.dictionary([("SwitchAccountID", .string(accountID))])
        _ = try await handler.sendRequest("SwitchUserAccountEvent", content: content)
    }
}

// MARK: - Power

/// Companion protocol implementation of PowerController.
public actor CompanionPower: PowerController {
    private let handler: CompanionProtocolHandler
    private var _powerState: PowerState = .unknown
    public nonisolated let powerStateStream: AsyncStream<PowerState>
    private nonisolated let continuation: AsyncStream<PowerState>.Continuation

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
        let (stream, cont) = AsyncStream<PowerState>.makeStream()
        self.powerStateStream = stream
        self.continuation = cont
    }

    public var powerState: PowerState { _powerState }

    public func turnOn(awaitNewState: Bool) async throws(ATVError) {
        try await sendHIDCommand(.wake)
        _powerState = .on
        continuation.yield(.on)
    }

    public func turnOff(awaitNewState: Bool) async throws(ATVError) {
        try await sendHIDCommand(.sleep)
        _powerState = .off
        continuation.yield(.off)
    }

    private func sendHIDCommand(_ command: HIDCommand) async throws(ATVError) {
        for state in [UInt64(1), UInt64(2)] {
            _ = try await handler.sendRequest(
                "_hidC",
                content: OPACK.Value.dictionary([
                    ("_hBtS", .uint(state)),
                    ("_hidC", .uint(UInt64(command.rawValue))),
                ]))
        }
    }
}

// MARK: - Audio

/// Companion protocol implementation of AudioController.
public actor CompanionAudio: AudioController {
    private let handler: CompanionProtocolHandler
    private var _volume: Float = 0
    private var _outputDevices: [OutputDevice] = []
    public nonisolated let volumeStream: AsyncStream<Float>
    private nonisolated let volumeContinuation: AsyncStream<Float>.Continuation
    public nonisolated let outputDevicesStream: AsyncStream<[OutputDevice]>
    private nonisolated let devicesContinuation: AsyncStream<[OutputDevice]>.Continuation

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
        let (vs, vc) = AsyncStream<Float>.makeStream()
        self.volumeStream = vs
        self.volumeContinuation = vc
        let (ds, dc) = AsyncStream<[OutputDevice]>.makeStream()
        self.outputDevicesStream = ds
        self.devicesContinuation = dc
    }

    public var volume: Float { _volume }

    public var outputDevices: [OutputDevice] { _outputDevices }

    public func setVolume(_ level: Float, device: OutputDevice?) async throws(ATVError) {
        let clamped = max(0, min(level, 100))
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.setVolume.rawValue))),
            ("_vol", .double(Double(clamped / 100))),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
        _volume = clamped
        volumeContinuation.yield(clamped)
    }

    public func volumeUp() async throws(ATVError) {
        try await setVolume(min(_volume + 5, 100), device: nil)
    }

    public func volumeDown() async throws(ATVError) {
        try await setVolume(max(_volume - 5, 0), device: nil)
    }

    public func addOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("addOutputDevices not yet implemented for Companion")
    }

    public func removeOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("removeOutputDevices not yet implemented for Companion")
    }

    public func setOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("setOutputDevices not yet implemented for Companion")
    }
}

// MARK: - Keyboard

/// Companion protocol implementation of KeyboardController.
public actor CompanionKeyboard: KeyboardController {
    private let handler: CompanionProtocolHandler
    private var _focusState: KeyboardFocusState = .unknown
    public nonisolated let focusStateStream: AsyncStream<KeyboardFocusState>
    private nonisolated let continuation: AsyncStream<KeyboardFocusState>.Continuation

    public init(protocol handler: CompanionProtocolHandler) {
        self.handler = handler
        let (stream, cont) = AsyncStream<KeyboardFocusState>.makeStream()
        self.focusStateStream = stream
        self.continuation = cont
    }

    public var textFocusState: KeyboardFocusState { _focusState }

    public func textGet() async throws(ATVError) -> String? {
        throw ATVError.notSupported("textGet not yet implemented for Companion")
    }

    public func textClear() async throws(ATVError) {
        throw ATVError.notSupported("textClear not yet implemented for Companion")
    }

    public func textAppend(_ text: String) async throws(ATVError) {
        throw ATVError.notSupported("textAppend not yet implemented for Companion")
    }

    public func textSet(_ text: String) async throws(ATVError) {
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

    public func swipe(startX: Int, startY: Int, endX: Int, endY: Int, durationMs: Int) async throws(ATVError) {
        let steps = max(durationMs / 16, 2)
        let delayNs: UInt64 = 16_000_000

        for i in 0...steps {
            let progress = Double(i) / Double(steps)
            let x = Int(Double(startX) + progress * Double(endX - startX))
            let y = Int(Double(startY) + progress * Double(endY - startY))

            let phase: TouchAction
            if i == 0 { phase = .press } else if i == steps { phase = .release } else { phase = .hold }

            try await sendTouchEvent(x: x, y: y, phase: phase)
            if i < steps {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
    }

    public func action(x: Int, y: Int, mode: TouchAction) async throws(ATVError) {
        try await sendTouchEvent(x: x, y: y, phase: mode)
    }

    public func click(action: InputAction) async throws(ATVError) {
        switch action {
        case .singleTap, .doubleTap:
            let count = action == .doubleTap ? 2 : 1
            for _ in 0..<count {
                try await sendSelectButton(down: true)
                try? await Task.sleep(nanoseconds: 20_000_000)
                try await sendSelectButton(down: false)
                try await sendTouchEvent(x: 1000, y: 1000, phase: .click)
            }
        case .hold:
            try await sendSelectButton(down: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await sendSelectButton(down: false)
            try await sendTouchEvent(x: 1000, y: 1000, phase: .click)
        }
    }

    private func sendTouchEvent(x: Int, y: Int, phase: TouchAction) async throws(ATVError) {
        let clampedX = min(max(x, 0), 1000)
        let clampedY = min(max(y, 0), 1000)
        let content = OPACK.Value.dictionary([
            ("_ns", .uint(currentTimestamp)),
            ("_tFg", .uint(1)),
            ("_cx", .uint(UInt64(clampedX))),
            ("_cy", .uint(UInt64(clampedY))),
            ("_tPh", .uint(UInt64(phase.rawValue))),
        ])
        try await handler.sendEvent("_hidT", content: content)
    }

    private func sendSelectButton(down: Bool) async throws(ATVError) {
        _ = try await handler.sendRequest(
            "_hidC",
            content: OPACK.Value.dictionary([
                ("_hBtS", .uint(down ? 1 : 2)),
                ("_hidC", .uint(UInt64(HIDCommand.select.rawValue))),
            ]))
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
        .setVolume,
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
