import Foundation

/// Setup and lifecycle management for the Companion protocol.
///
/// Provides the entry point for creating a Companion connection,
/// performing pair-verify, and initializing protocol interfaces. Session and
/// touch setup are best-effort so devices that do not answer `_sessionStart` or
/// `_touchStart` can still expose basic Companion functionality. Subscribed
/// Companion events feed a shared state store used by controllers and capability
/// reporting.
///
/// Thread safety: Mutable interface references protected by `NSLock`.
public final class CompanionService: @unchecked Sendable, CompanionConnectionDelegate {
    /// Bonjour service type for Companion protocol.
    public static let serviceType = "_companion-link._tcp"
    /// Default port for Companion protocol.
    public static let defaultPort = 49153

    private let connection: CompanionConnection
    private let protocolHandler: CompanionProtocolHandler
    private let lock = NSLock()
    private let settings: ATVSettings
    private let onConnectionClosed: (@Sendable (Error?) -> Void)?
    private let requestTimeout: TimeInterval
    private let touchStartTimeout: TimeInterval
    private let keepAliveInterval: TimeInterval
    private let stateStore = CompanionStateStore()
    private var credentials: HAPCredentials?
    private var eventTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?

    private var _remoteControl: CompanionRemoteControl?
    private var _apps: CompanionApps?
    private var _userAccounts: CompanionUserAccounts?
    private var _power: CompanionPower?
    private var _audio: CompanionAudio?
    private var _keyboard: CompanionKeyboard?
    private var _touch: CompanionTouch?
    private var _capabilities: CompanionCapabilities?
    private var _mediaCommands: CompanionMediaCommands?

    public var remoteControl: CompanionRemoteControl? {
        lock.lock()
        defer { lock.unlock() }
        return _remoteControl
    }
    public var apps: CompanionApps? {
        lock.lock()
        defer { lock.unlock() }
        return _apps
    }
    public var userAccounts: CompanionUserAccounts? {
        lock.lock()
        defer { lock.unlock() }
        return _userAccounts
    }
    public var power: CompanionPower? {
        lock.lock()
        defer { lock.unlock() }
        return _power
    }
    public var audio: CompanionAudio? {
        lock.lock()
        defer { lock.unlock() }
        return _audio
    }
    public var keyboard: CompanionKeyboard? {
        lock.lock()
        defer { lock.unlock() }
        return _keyboard
    }
    public var touch: CompanionTouch? {
        lock.lock()
        defer { lock.unlock() }
        return _touch
    }
    public var capabilities: CompanionCapabilities? {
        lock.lock()
        defer { lock.unlock() }
        return _capabilities
    }
    public var mediaCommands: CompanionMediaCommands? {
        lock.lock()
        defer { lock.unlock() }
        return _mediaCommands
    }

    internal var _testIsConnected: Bool {
        stateStore.isConnected
    }

    func setupDiagnostics(protocol registrationProtocol: ATVProtocol) -> [ProtocolSetupDiagnostic] {
        stateStore.setupDiagnosticEntries().map { capability, info in
            ProtocolSetupDiagnostic(
                protocol: registrationProtocol,
                capability: capability,
                info: info
            )
        }
    }

    /// Create a Companion service for a host and port.
    ///
    /// - Parameter requestTimeout: Maximum time for the TCP connect, pair-verify
    ///   frames, and required setup request/response exchanges.
    public convenience init(
        host: String,
        port: Int,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings = ATVSettings(),
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.init(
            host: host,
            port: port,
            credentials: credentials,
            settings: settings,
            requestTimeout: requestTimeout,
            touchStartTimeout: requestTimeout,
            onConnectionClosed: onConnectionClosed
        )
    }

    internal init(
        host: String,
        port: Int,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings = ATVSettings(),
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        touchStartTimeout: TimeInterval,
        keepAliveInterval: TimeInterval = 30,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.connection = CompanionConnection(host: host, port: port, connectTimeout: requestTimeout)
        self.protocolHandler = CompanionProtocolHandler(connection: connection)
        self.credentials = credentials
        self.settings = settings
        self.requestTimeout = requestTimeout
        self.touchStartTimeout = touchStartTimeout
        self.keepAliveInterval = keepAliveInterval
        self.onConnectionClosed = onConnectionClosed
        self.connection.delegate = self
    }

    /// Connect and set up the Companion protocol.
    ///
    /// TCP connection, pair-verify, system info, and event subscription are
    /// required. Session and touch setup are optional: a `_sessionStart` or
    /// `_touchStart` timeout leaves dependent surfaces unavailable but does not
    /// fail the connection.
    public func setup() async throws(ATVError) {
        guard let credentials else {
            throw ATVError.noCredentials("Companion requires pairing credentials")
        }

        try await connection.connect()
        await protocolHandler.startReceiving()

        let verifier = CompanionPairVerifyHandler(
            connection: connection,
            credentials: credentials
        )
        try await verifier.verify(timeout: requestTimeout)

        try await protocolHandler.sendSystemInfo(
            name: settings.clientIdentity.name,
            model: settings.clientIdentity.model,
            rapportIdentifier: settings.clientIdentity.rapportIdentifier,
            clientID: Self.utf8String(from: credentials.clientIdentifier),
            deviceID: settings.clientIdentity.deviceID,
            timeout: requestTimeout
        )
        let sessionStarted = try await startSessionIfAvailable()
        let touchAvailable = sessionStarted ? try await startTouchIfAvailable() : false
        stateStore.setTouchAvailable(touchAvailable)
        startEventLoop()
        try await protocolHandler.subscribeEvents(["_iMC"])
        for optionalEvent in ["SystemStatus", "TVSystemStatus", "_tiStarted", "_tiStopped"] {
            try? await protocolHandler.subscribeEvents([optionalEvent])
        }
        await initializeState()
        startKeepAlive()

        lock.withLock {
            _remoteControl = CompanionRemoteControl(protocol: protocolHandler)
            _apps = CompanionApps(protocol: protocolHandler, stateStore: stateStore)
            _userAccounts = CompanionUserAccounts(protocol: protocolHandler, stateStore: stateStore)
            _power = CompanionPower(protocol: protocolHandler, stateStore: stateStore)
            _audio = CompanionAudio(protocol: protocolHandler, stateStore: stateStore)
            _keyboard = CompanionKeyboard(protocol: protocolHandler, stateStore: stateStore)
            _touch = touchAvailable ? CompanionTouch(protocol: protocolHandler) : nil
            _capabilities = CompanionCapabilities(stateStore: stateStore)
            _mediaCommands = CompanionMediaCommands(protocol: protocolHandler, stateStore: stateStore)
        }
    }

    /// Close the Companion protocol connection.
    public func close() async {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        eventTask?.cancel()
        eventTask = nil
        stateStore.setConnected(false)
        let keyboard = lock.withLock { _keyboard }
        try? await keyboard?.stopTextInput()
        await protocolHandler.stop()
        await connection.close()
    }

    public func connectionDidReceiveFrame(_ frame: CompanionFrame) async {}

    public func connectionDidClose(error: Error?) async {
        onConnectionClosed?(error)
    }

    private func startTouchIfAvailable() async throws(ATVError) -> Bool {
        do {
            try await protocolHandler.startTouch(timeout: touchStartTimeout)
            return true
        } catch let error {
            guard Self.isRecoverableTouchStartFailure(error) else {
                throw error
            }
            recordTouchSetupFailure(error)
            return false
        }
    }

    private func startSessionIfAvailable() async throws(ATVError) -> Bool {
        do {
            try await protocolHandler.startSession(timeout: requestTimeout)
            return true
        } catch let error {
            guard Self.isRecoverableSessionStartFailure(error) else {
                throw error
            }
            recordTouchSetupFailure(error)
            return false
        }
    }

    private func recordTouchSetupFailure(_ error: ATVError) {
        stateStore.recordSetupFailure(
            error.errorDescription ?? String(describing: error),
            affectedCapabilities: CompanionStateStore.touchCapabilities
        )
    }

    private static func isRecoverableSessionStartFailure(_ error: ATVError) -> Bool {
        if case .operationTimeout(let context) = error {
            return context.protocol == .companion
                && context.operation == "request"
                && context.requestID == "_sessionStart"
        }
        return false
    }

    private static func isRecoverableTouchStartFailure(_ error: ATVError) -> Bool {
        if case .operationTimeout(let context) = error {
            return context.protocol == .companion
                && context.operation == "request"
                && context.requestID == "_touchStart"
        }
        return false
    }

    private func startEventLoop() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await protocolHandler.eventStream
            for await (identifier, message) in stream {
                if Task.isCancelled { break }
                await handleEvent(identifier: identifier, message: message)
            }
        }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        guard
            let intervalNs = try? timeoutNanoseconds(
                from: keepAliveInterval,
                parameterName: "keepAliveInterval"
            ),
            intervalNs > 0
        else {
            keepAliveTask = nil
            return
        }

        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                    try await connection.send(type: .noOp)
                } catch is CancellationError {
                    return
                } catch {
                    await connection.close()
                    return
                }
            }
        }
    }

    private func initializeState() async {
        await refreshPowerState()
    }

    private func handleEvent(identifier: String, message: OPACK.Value) async {
        let content = message["_c"] ?? message
        switch identifier {
        case "_iMC":
            await handleMediaControlEvent(content)
        case "SystemStatus", "TVSystemStatus":
            handleSystemStatusEvent(content)
        case "_tiStarted":
            stateStore.setTextFocusState(.focused)
        case "_tiStopped":
            stateStore.setTextFocusState(.unfocused)
        default:
            break
        }
    }

    private func handleMediaControlEvent(_ content: OPACK.Value) async {
        guard let rawFlags = content["_mcF"]?.intValue else {
            return
        }
        let flags = CompanionMediaControlFlags(rawValue: rawFlags)
        stateStore.setMediaControlFlags(flags)
        if flags.contains(.volume) {
            await refreshVolume()
        } else {
            stateStore.clearVolume()
        }
    }

    private func handleSystemStatusEvent(_ content: OPACK.Value) {
        guard
            let rawState = content["state"]?.intValue,
            let status = CompanionSystemStatus(rawValue: Int(rawState))
        else {
            return
        }
        stateStore.setPowerState(Self.powerState(from: status))
    }

    private func refreshPowerState() async {
        do {
            let response = try await protocolHandler.sendRequest("FetchAttentionState")
            let content = response["_c"] ?? response
            handleSystemStatusEvent(content)
        } catch {
            // Power remains unavailable until a status event arrives.
        }
    }

    private func refreshVolume() async {
        do {
            let content = OPACK.Value.dictionary([
                ("_mcc", .uint(UInt64(MediaControlCommand.getVolume.rawValue)))
            ])
            let response = try await protocolHandler.sendRequest("_mcc", content: content)
            guard let normalized = Self.numericValue(response["_c"]?["_vol"]) else {
                return
            }
            stateStore.setVolume(Float(normalized * 100))
        } catch {
            stateStore.clearVolume()
        }
    }

    private static func powerState(from status: CompanionSystemStatus) -> PowerState {
        switch status {
        case .asleep:
            return .off
        case .screensaver, .awake, .idle:
            return .on
        }
    }

    private static func numericValue(_ value: OPACK.Value?) -> Double? {
        guard let value else {
            return nil
        }
        switch value {
        case .double(let double):
            return double
        case .float(let float):
            return Double(float)
        case .int(let int):
            return Double(int)
        case .uint(let uint):
            return Double(uint)
        default:
            return nil
        }
    }

    private static func utf8String(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
