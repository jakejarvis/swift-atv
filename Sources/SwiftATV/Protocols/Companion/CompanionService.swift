import Foundation

/// Setup and lifecycle management for the Companion protocol.
///
/// Provides the entry point for creating a Companion connection,
/// performing pair-verify, and initializing protocol interfaces. Touch setup
/// is best-effort so devices that do not answer `_touchStart` can still expose
/// remote, app, power, audio, and keyboard functionality.
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
    private let touchStartTimeout: TimeInterval
    private var credentials: HAPCredentials?

    private var _remoteControl: CompanionRemoteControl?
    private var _apps: CompanionApps?
    private var _userAccounts: CompanionUserAccounts?
    private var _power: CompanionPower?
    private var _audio: CompanionAudio?
    private var _keyboard: CompanionKeyboard?
    private var _touch: CompanionTouch?
    private var _features: CompanionFeatures?

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
    public var features: CompanionFeatures? {
        lock.lock()
        defer { lock.unlock() }
        return _features
    }

    public convenience init(
        host: String,
        port: Int,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings = ATVSettings(),
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.init(
            host: host,
            port: port,
            credentials: credentials,
            settings: settings,
            touchStartTimeout: defaultCompanionTimeout,
            onConnectionClosed: onConnectionClosed
        )
    }

    internal init(
        host: String,
        port: Int,
        credentials: HAPCredentials? = nil,
        settings: ATVSettings = ATVSettings(),
        touchStartTimeout: TimeInterval,
        onConnectionClosed: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.connection = CompanionConnection(host: host, port: port)
        self.protocolHandler = CompanionProtocolHandler(connection: connection)
        self.credentials = credentials
        self.settings = settings
        self.touchStartTimeout = touchStartTimeout
        self.onConnectionClosed = onConnectionClosed
        self.connection.delegate = self
    }

    /// Connect and set up the Companion protocol.
    ///
    /// TCP connection, pair-verify, system info, session start, and event
    /// subscription are required. Touch setup is optional: a `_touchStart`
    /// timeout leaves touch unavailable but does not fail the connection.
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
        try await verifier.verify()

        try await protocolHandler.sendSystemInfo(
            name: settings.clientIdentity.name,
            model: settings.clientIdentity.model,
            pairingIdentifier: settings.clientIdentity.pairingIdentifier,
            clientID: Self.utf8String(from: credentials.clientIdentifier),
            deviceID: settings.clientIdentity.deviceID
        )
        let touchAvailable = try await startTouchIfAvailable()
        try await protocolHandler.startSession()
        try await protocolHandler.subscribeEvents(["_iMC"])

        lock.withLock {
            _remoteControl = CompanionRemoteControl(protocol: protocolHandler)
            _apps = CompanionApps(protocol: protocolHandler)
            _userAccounts = CompanionUserAccounts(protocol: protocolHandler)
            _power = CompanionPower(protocol: protocolHandler)
            _audio = CompanionAudio(protocol: protocolHandler)
            _keyboard = CompanionKeyboard(protocol: protocolHandler)
            _touch = touchAvailable ? CompanionTouch(protocol: protocolHandler) : nil
            _features = CompanionFeatures(isConnected: true, touchAvailable: touchAvailable)
        }
    }

    /// Close the Companion protocol connection.
    public func close() async {
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
            return false
        }
    }

    private static func isRecoverableTouchStartFailure(_ error: ATVError) -> Bool {
        if case .operationTimeout(let message) = error {
            return message.contains("_touchStart")
        }
        return false
    }

    private static func utf8String(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
