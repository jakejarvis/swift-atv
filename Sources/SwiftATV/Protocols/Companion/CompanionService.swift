import Foundation
import NIOPosix

/// Setup and lifecycle management for the Companion protocol.
///
/// Provides the entry point for creating a Companion connection,
/// performing pair-verify, and initializing all protocol interfaces.
///
/// Thread safety: Mutable interface references protected by `NSLock`.
public final class CompanionService: @unchecked Sendable {
    /// Bonjour service type for Companion protocol.
    public static let serviceType = "_companion-link._tcp"
    /// Default port for Companion protocol.
    public static let defaultPort = 49153

    private let connection: CompanionConnection
    private let protocolHandler: CompanionProtocolHandler
    private let lock = NSLock()
    private var credentials: HAPCredentials?

    private var _remoteControl: CompanionRemoteControl?
    private var _apps: CompanionApps?
    private var _userAccounts: CompanionUserAccounts?
    private var _power: CompanionPower?
    private var _audio: CompanionAudio?
    private var _keyboard: CompanionKeyboard?
    private var _touch: CompanionTouch?
    private var _features: CompanionFeatures?

    public var remoteControl: CompanionRemoteControl? { lock.lock(); defer { lock.unlock() }; return _remoteControl }
    public var apps: CompanionApps? { lock.lock(); defer { lock.unlock() }; return _apps }
    public var userAccounts: CompanionUserAccounts? { lock.lock(); defer { lock.unlock() }; return _userAccounts }
    public var power: CompanionPower? { lock.lock(); defer { lock.unlock() }; return _power }
    public var audio: CompanionAudio? { lock.lock(); defer { lock.unlock() }; return _audio }
    public var keyboard: CompanionKeyboard? { lock.lock(); defer { lock.unlock() }; return _keyboard }
    public var touch: CompanionTouch? { lock.lock(); defer { lock.unlock() }; return _touch }
    public var features: CompanionFeatures? { lock.lock(); defer { lock.unlock() }; return _features }

    public init(host: String, port: Int, credentials: HAPCredentials? = nil) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.connection = CompanionConnection(host: host, port: port, group: group)
        self.protocolHandler = CompanionProtocolHandler(connection: connection)
        self.credentials = credentials
    }

    /// Connect and set up the Companion protocol.
    public func setup() async throws {
        try await connection.connect()
        await protocolHandler.startReceiving()

        if let credentials {
            let verifier = CompanionPairVerifyHandler(
                connection: connection,
                credentials: credentials
            )
            try await verifier.verify()
        }

        try await protocolHandler.sendSystemInfo()
        try await protocolHandler.startTouch()
        try await protocolHandler.startSession()
        try await protocolHandler.subscribeEvents(["_iMC"])

        lock.lock()
        _remoteControl = CompanionRemoteControl(protocol: protocolHandler)
        _apps = CompanionApps(protocol: protocolHandler)
        _userAccounts = CompanionUserAccounts(protocol: protocolHandler)
        _power = CompanionPower(protocol: protocolHandler)
        _audio = CompanionAudio(protocol: protocolHandler)
        _keyboard = CompanionKeyboard(protocol: protocolHandler)
        _touch = CompanionTouch(protocol: protocolHandler)
        _features = CompanionFeatures(isConnected: true)
        lock.unlock()
    }

    /// Close the Companion protocol connection.
    public func close() async {
        await protocolHandler.stop()
        await connection.close()
    }
}
