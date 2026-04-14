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

private let companionStateWaitIntervalNanoseconds: UInt64 = 50_000_000

internal struct CompanionMediaControlFlags: OptionSet, Sendable {
    internal let rawValue: Int64

    internal static let play = Self(rawValue: 0x0001)
    internal static let pause = Self(rawValue: 0x0002)
    internal static let nextTrack = Self(rawValue: 0x0004)
    internal static let previousTrack = Self(rawValue: 0x0008)
    internal static let fastForward = Self(rawValue: 0x0010)
    internal static let rewind = Self(rawValue: 0x0020)
    internal static let volume = Self(rawValue: 0x0100)
    internal static let skipForward = Self(rawValue: 0x0200)
    internal static let skipBackward = Self(rawValue: 0x0400)
}

internal final class CompanionStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _isConnected: Bool
    private var _touchAvailable: Bool
    private var _mediaControlFlags: CompanionMediaControlFlags?
    private var _volume: Float = 0
    private var _hasVolume = false
    private var _volumeRevision = 0
    private var _powerState: PowerState = .unknown
    private var _hasPowerState = false
    private var _focusState: KeyboardFocusState = .unknown
    private var _hasKeyboardFocus = false
    private var _appsAvailable = false
    private var _accountsAvailable = false
    private var volumeContinuations: [UUID: AsyncStream<Float>.Continuation] = [:]
    private var powerContinuations: [UUID: AsyncStream<PowerState>.Continuation] = [:]
    private var focusContinuations: [UUID: AsyncStream<KeyboardFocusState>.Continuation] = [:]

    internal init(isConnected: Bool = true, touchAvailable: Bool = true) {
        self._isConnected = isConnected
        self._touchAvailable = touchAvailable
    }

    internal var isConnected: Bool { lock.withLock { _isConnected } }
    internal var touchAvailable: Bool { lock.withLock { _touchAvailable } }
    internal var mediaControlFlags: CompanionMediaControlFlags? { lock.withLock { _mediaControlFlags } }
    internal var volume: Float { lock.withLock { _volume } }
    internal var hasVolume: Bool { lock.withLock { _hasVolume } }
    internal var volumeRevision: Int { lock.withLock { _volumeRevision } }
    internal var hasVolumeControl: Bool {
        lock.withLock { _mediaControlFlags?.contains(.volume) ?? false }
    }
    internal var powerState: PowerState { lock.withLock { _powerState } }
    internal var hasPowerState: Bool { lock.withLock { _hasPowerState } }
    internal var textFocusState: KeyboardFocusState { lock.withLock { _focusState } }
    internal var hasKeyboardFocus: Bool { lock.withLock { _hasKeyboardFocus } }

    internal func setConnected(_ isConnected: Bool) {
        lock.withLock { _isConnected = isConnected }
    }

    internal func setTouchAvailable(_ touchAvailable: Bool) {
        lock.withLock { _touchAvailable = touchAvailable }
    }

    internal func setMediaControlFlags(_ flags: CompanionMediaControlFlags) {
        lock.withLock { _mediaControlFlags = flags }
    }

    internal func setVolume(_ volume: Float) {
        let percent = max(0, min(volume, 100))
        let continuations = lock.withLock {
            _volume = percent
            _hasVolume = true
            _volumeRevision += 1
            return Array(volumeContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(percent)
        }
    }

    internal func clearVolume() {
        let continuations = lock.withLock {
            _volume = 0
            _hasVolume = false
            _volumeRevision += 1
            return Array(volumeContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(0)
        }
    }

    internal func setPowerState(_ state: PowerState) {
        let continuations = lock.withLock {
            _powerState = state
            _hasPowerState = true
            return Array(powerContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(state)
        }
    }

    internal func setTextFocusState(_ state: KeyboardFocusState) {
        let continuations = lock.withLock {
            _focusState = state
            _hasKeyboardFocus = true
            return Array(focusContinuations.values)
        }
        for continuation in continuations {
            continuation.yield(state)
        }
    }

    internal func markAppsAvailable() {
        lock.withLock { _appsAvailable = true }
    }

    internal func markUserAccountsAvailable() {
        lock.withLock { _accountsAvailable = true }
    }

    internal func volumeStream() -> AsyncStream<Float> {
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

    internal func powerStateStream() -> AsyncStream<PowerState> {
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

    internal func focusStateStream() -> AsyncStream<KeyboardFocusState> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                focusContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock {
                    self?.focusContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    internal func featureInfo(_ feature: FeatureName) -> FeatureInfo {
        lock.withLock {
            guard _isConnected else {
                if Self.supportedFeatures.contains(feature) || Self.touchFeatures.contains(feature) {
                    return FeatureInfo(state: .unavailable)
                }
                return FeatureInfo(state: .unsupported)
            }

            if Self.touchFeatures.contains(feature) {
                return FeatureInfo(state: _touchAvailable ? .available : .unavailable)
            }
            if Self.hidFeatures.contains(feature) {
                return FeatureInfo(state: .available)
            }
            if let flag = Self.mediaControlMap[feature] {
                return FeatureInfo(state: _mediaControlFlags?.contains(flag) == true ? .available : .unavailable)
            }
            if Self.volumeFeatures.contains(feature) {
                return FeatureInfo(
                    state: _mediaControlFlags?.contains(.volume) == true && _hasVolume ? .available : .unavailable
                )
            }
            if Self.powerFeatures.contains(feature) {
                return FeatureInfo(state: _hasPowerState ? .available : .unavailable)
            }
            if feature == .textFocusState {
                return FeatureInfo(state: _hasKeyboardFocus ? .available : .unavailable)
            }
            if Self.textInputFeatures.contains(feature) {
                return FeatureInfo(state: _focusState == .focused ? .available : .unavailable)
            }
            if Self.appFeatures.contains(feature) {
                return FeatureInfo(state: _appsAvailable ? .available : .unavailable)
            }
            if Self.accountFeatures.contains(feature) {
                return FeatureInfo(state: _accountsAvailable ? .available : .unavailable)
            }
            return FeatureInfo(state: .unsupported)
        }
    }

    private static let hidFeatures: Set<FeatureName> = [
        .up, .down, .left, .right,
        .playPause, .select, .menu,
        .volumeUp, .volumeDown, .home, .homeHold,
        .topMenu, .suspend, .wakeUp,
        .channelUp, .channelDown,
        .screensaver, .guide, .controlCenter,
    ]

    private static let mediaControlMap: [FeatureName: CompanionMediaControlFlags] = [
        .play: .play,
        .pause: .pause,
        .stop: .pause,
        .next: .nextTrack,
        .previous: .previousTrack,
        .skipForward: .skipForward,
        .skipBackward: .skipBackward,
    ]

    private static let volumeFeatures: Set<FeatureName> = [
        .volume, .setVolume,
    ]

    private static let powerFeatures: Set<FeatureName> = [
        .turnOn, .turnOff, .powerState,
    ]

    private static let textInputFeatures: Set<FeatureName> = [
        .textGet, .textClear, .textAppend, .textSet,
    ]

    private static let appFeatures: Set<FeatureName> = [
        .appList, .launchApp,
    ]

    private static let accountFeatures: Set<FeatureName> = [
        .accountList, .switchAccount,
    ]

    private static let touchFeatures: Set<FeatureName> = [
        .swipe, .action, .click,
    ]

    private static let supportedFeatures =
        hidFeatures
        .union(Set(mediaControlMap.keys))
        .union(volumeFeatures)
        .union(powerFeatures)
        .union(textInputFeatures)
        .union(appFeatures)
        .union(accountFeatures)
        .union([.textFocusState])
}

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
/// Marks app features available after a successful app request.
public struct CompanionApps: AppsController, Sendable {
    private let handler: CompanionProtocolHandler
    private let stateStore: CompanionStateStore

    public init(protocol handler: CompanionProtocolHandler) {
        self.init(protocol: handler, stateStore: CompanionStateStore())
    }

    internal init(protocol handler: CompanionProtocolHandler, stateStore: CompanionStateStore) {
        self.handler = handler
        self.stateStore = stateStore
    }

    public func appList() async throws(ATVError) -> [App] {
        let response = try await handler.sendRequest("FetchLaunchableApplicationsEvent")
        guard case .dict(let pairs) = response["_c"] else { return [] }
        stateStore.markAppsAvailable()
        return pairs.compactMap { key, value in
            guard let bundleID = key.stringValue, let name = value.stringValue else { return nil }
            return App(name: name, identifier: bundleID)
        }
    }

    public func launchApp(bundleID: String) async throws(ATVError) {
        let content = OPACK.Value.dictionary([("_bundleID", .string(bundleID))])
        _ = try await handler.sendRequest("_launchApp", content: content)
        stateStore.markAppsAvailable()
    }
}

// MARK: - User Accounts

/// Companion protocol implementation of UserAccountsController.
/// Marks account features available after a successful account request.
public struct CompanionUserAccounts: UserAccountsController, Sendable {
    private let handler: CompanionProtocolHandler
    private let stateStore: CompanionStateStore

    public init(protocol handler: CompanionProtocolHandler) {
        self.init(protocol: handler, stateStore: CompanionStateStore())
    }

    internal init(protocol handler: CompanionProtocolHandler, stateStore: CompanionStateStore) {
        self.handler = handler
        self.stateStore = stateStore
    }

    public func accountList() async throws(ATVError) -> [UserAccount] {
        let response = try await handler.sendRequest("FetchUserAccountsEvent")
        guard case .dict(let pairs) = response["_c"] else { return [] }
        stateStore.markUserAccountsAvailable()
        return pairs.compactMap { key, value in
            guard let id = key.stringValue, let name = value.stringValue else { return nil }
            return UserAccount(name: name, identifier: id)
        }
    }

    public func switchAccount(_ accountID: String) async throws(ATVError) {
        let content = OPACK.Value.dictionary([("SwitchAccountID", .string(accountID))])
        _ = try await handler.sendRequest("SwitchUserAccountEvent", content: content)
        stateStore.markUserAccountsAvailable()
    }
}

// MARK: - Power

/// Companion protocol implementation of PowerController backed by observed
/// Companion system-status state.
public actor CompanionPower: PowerController {
    private let handler: CompanionProtocolHandler
    private let stateStore: CompanionStateStore
    public nonisolated let powerStateStream: AsyncStream<PowerState>

    public init(protocol handler: CompanionProtocolHandler) {
        self.init(protocol: handler, stateStore: CompanionStateStore())
    }

    internal init(protocol handler: CompanionProtocolHandler, stateStore: CompanionStateStore) {
        self.handler = handler
        self.stateStore = stateStore
        self.powerStateStream = stateStore.powerStateStream()
    }

    public var powerState: PowerState { stateStore.powerState }

    public func turnOn(awaitNewState: Bool) async throws(ATVError) {
        try await sendHIDCommand(.wake)
        if awaitNewState {
            try await waitForPowerState(.on)
        }
    }

    public func turnOff(awaitNewState: Bool) async throws(ATVError) {
        try await sendHIDCommand(.sleep)
        if awaitNewState {
            try await waitForPowerState(.off)
        }
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

    private func waitForPowerState(_ expected: PowerState, timeout: TimeInterval = 5) async throws(ATVError) {
        let deadline = Date().addingTimeInterval(timeout)
        while stateStore.powerState != expected {
            if Date() >= deadline {
                throw ATVError.operationTimeout("Timeout waiting for Companion power state \(expected)")
            }
            try? await Task.sleep(nanoseconds: companionStateWaitIntervalNanoseconds)
        }
    }
}

// MARK: - Audio

/// Companion protocol implementation of AudioController backed by observed
/// Companion media-control and volume events. Output-device mutation is handled
/// by MRP or AirPlay-tunneled MRP, not Companion.
public actor CompanionAudio: AudioController {
    private let handler: CompanionProtocolHandler
    private let stateStore: CompanionStateStore
    public nonisolated let volumeStream: AsyncStream<Float>
    public nonisolated let outputDevicesStream: AsyncStream<[OutputDevice]>

    public init(protocol handler: CompanionProtocolHandler) {
        self.init(protocol: handler, stateStore: CompanionStateStore())
    }

    internal init(protocol handler: CompanionProtocolHandler, stateStore: CompanionStateStore) {
        self.handler = handler
        self.stateStore = stateStore
        self.volumeStream = stateStore.volumeStream()
        self.outputDevicesStream = AsyncStream { $0.finish() }
    }

    public var volume: Float { stateStore.volume }

    public var outputDevices: [OutputDevice] { [] }

    public func setVolume(_ level: Float, device: OutputDevice?) async throws(ATVError) {
        guard stateStore.hasVolumeControl else {
            throw ATVError.notSupported("Companion volume control is not available")
        }
        let clamped = max(0, min(level, 100))
        let revision = stateStore.volumeRevision
        let content = OPACK.Value.dictionary([
            ("_mcc", .uint(UInt64(MediaControlCommand.setVolume.rawValue))),
            ("_vol", .double(Double(clamped / 100))),
        ])
        _ = try await handler.sendRequest("_mcc", content: content)
        try await waitForVolumeUpdate(after: revision)
    }

    public func volumeUp() async throws(ATVError) {
        try await sendVolumeButton(.volumeUp)
    }

    public func volumeDown() async throws(ATVError) {
        try await sendVolumeButton(.volumeDown)
    }

    public func addOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("Output-device mutation is only supported over MRP or AirPlay-tunneled MRP")
    }

    public func removeOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("Output-device mutation is only supported over MRP or AirPlay-tunneled MRP")
    }

    public func setOutputDevices(_ deviceIDs: [String]) async throws(ATVError) {
        throw ATVError.notSupported("Output-device mutation is only supported over MRP or AirPlay-tunneled MRP")
    }

    private func sendVolumeButton(_ command: HIDCommand) async throws(ATVError) {
        guard stateStore.hasVolumeControl else {
            throw ATVError.notSupported("Companion volume control is not available")
        }
        let revision = stateStore.volumeRevision
        for state in [UInt64(1), UInt64(2)] {
            _ = try await handler.sendRequest(
                "_hidC",
                content: OPACK.Value.dictionary([
                    ("_hBtS", .uint(state)),
                    ("_hidC", .uint(UInt64(command.rawValue))),
                ]))
        }
        try await waitForVolumeUpdate(after: revision)
    }

    private func waitForVolumeUpdate(after revision: Int, timeout: TimeInterval = 5) async throws(ATVError) {
        let deadline = Date().addingTimeInterval(timeout)
        while stateStore.volumeRevision <= revision {
            if Date() >= deadline {
                throw ATVError.operationTimeout("Timeout waiting for Companion volume update")
            }
            try? await Task.sleep(nanoseconds: companionStateWaitIntervalNanoseconds)
        }
    }
}

// MARK: - Keyboard

/// Companion protocol implementation of `KeyboardController`.
///
/// Uses Companion RTI text-input messages (`_tiStart`, `_tiC`, `_tiStop`) and
/// binary keyed archives to mutate the text field currently focused on the
/// Apple TV.
public actor CompanionKeyboard: KeyboardController {
    private let handler: CompanionProtocolHandler
    private let stateStore: CompanionStateStore
    private var sessionUUID: Data?
    private var currentText: String = ""
    public nonisolated let focusStateStream: AsyncStream<KeyboardFocusState>

    public init(protocol handler: CompanionProtocolHandler) {
        self.init(protocol: handler, stateStore: CompanionStateStore())
    }

    internal init(protocol handler: CompanionProtocolHandler, stateStore: CompanionStateStore) {
        self.handler = handler
        self.stateStore = stateStore
        self.focusStateStream = stateStore.focusStateStream()
    }

    public var textFocusState: KeyboardFocusState { stateStore.textFocusState }

    public func textGet() async throws(ATVError) -> String? {
        try await refreshSession()?.currentText
    }

    public func textClear() async throws(ATVError) {
        let state = try await requireSession()
        try await sendTextPayload(
            CompanionTextInputSession.encodeReplaceText("", sessionUUID: state.sessionUUID)
        )
        currentText = ""
    }

    public func textAppend(_ text: String) async throws(ATVError) {
        guard !text.isEmpty else { return }
        let state = try await requireSession()
        try await sendTextPayload(
            CompanionTextInputSession.encodeInsertText(text, sessionUUID: state.sessionUUID)
        )
        currentText += text
    }

    public func textSet(_ text: String) async throws(ATVError) {
        guard let state = try await refreshSession() else {
            throw ATVError.invalidState("No active Companion text input session")
        }
        if text.hasPrefix(currentText) {
            let suffix = String(text.dropFirst(currentText.count))
            if !suffix.isEmpty {
                try await sendTextPayload(
                    CompanionTextInputSession.encodeInsertText(suffix, sessionUUID: state.sessionUUID)
                )
            }
        } else {
            try await sendTextPayload(
                CompanionTextInputSession.encodeReplaceText(text, sessionUUID: state.sessionUUID)
            )
        }
        currentText = text
    }

    internal func stopTextInput() async throws(ATVError) {
        guard sessionUUID != nil else {
            updateFocusState(.unfocused)
            return
        }
        try await handler.sendRequestWithoutResponse("_tiStop")
        sessionUUID = nil
        currentText = ""
        updateFocusState(.unfocused)
    }

    private func requireSession() async throws(ATVError) -> CompanionTextInputSession.State {
        if let sessionUUID {
            return CompanionTextInputSession.State(sessionUUID: sessionUUID, currentText: currentText)
        }
        guard let state = try await refreshSession() else {
            throw ATVError.invalidState("No active Companion text input session")
        }
        return state
    }

    private func refreshSession() async throws(ATVError) -> CompanionTextInputSession.State? {
        let response = try await handler.sendRequest("_tiStart")
        guard let payload = response["_c"]?["_tiD"]?.dataValue else {
            sessionUUID = nil
            currentText = ""
            updateFocusState(.unfocused)
            return nil
        }

        let state = try CompanionTextInputSession.decodeStartResponse(payload)
        sessionUUID = state.sessionUUID
        currentText = state.currentText
        updateFocusState(.focused)
        return state
    }

    private func sendTextPayload(_ payload: Data) async throws(ATVError) {
        try await handler.sendEvent(
            "_tiC",
            content: OPACK.Value.dictionary([
                ("_tiV", .uint(1)),
                ("_tiD", .data(payload)),
            ])
        )
    }

    private func updateFocusState(_ state: KeyboardFocusState) {
        stateStore.setTextFocusState(state)
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
///
/// Feature availability is backed by observed Companion state. Navigation HID
/// commands are available after connect, while media controls, power state,
/// volume, keyboard focus, apps, accounts, and touch are gated by setup or
/// events that prove each surface is usable.
public final class CompanionFeatures: @unchecked Sendable, FeatureProvider {
    private let stateStore: CompanionStateStore

    public init(isConnected: Bool = true, touchAvailable: Bool = true) {
        self.stateStore = CompanionStateStore(isConnected: isConnected, touchAvailable: touchAvailable)
    }

    internal init(stateStore: CompanionStateStore) {
        self.stateStore = stateStore
    }

    public func featureInfo(_ feature: FeatureName) -> FeatureInfo {
        stateStore.featureInfo(feature)
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
