import Foundation
import NIOPosix

/// Setup and lifecycle management for the Companion protocol.
///
/// Provides the entry point for creating a Companion connection,
/// performing pair-verify, and initializing all protocol interfaces.
public final class CompanionService: @unchecked Sendable {
    /// Bonjour service type for Companion protocol.
    public static let serviceType = "_companion-link._tcp"
    /// Default port for Companion protocol.
    public static let defaultPort = 49153

    private let connection: CompanionConnection
    private let protocolHandler: CompanionProtocolHandler
    private var credentials: HAPCredentials?

    public private(set) var remoteControl: CompanionRemoteControl?
    public private(set) var apps: CompanionApps?
    public private(set) var userAccounts: CompanionUserAccounts?
    public private(set) var power: CompanionPower?
    public private(set) var audio: CompanionAudio?
    public private(set) var keyboard: CompanionKeyboard?
    public private(set) var touch: CompanionTouch?
    public private(set) var features: CompanionFeatures?

    public init(host: String, port: Int, credentials: HAPCredentials? = nil) {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.connection = CompanionConnection(host: host, port: port, group: group)
        self.protocolHandler = CompanionProtocolHandler(connection: connection)
        self.credentials = credentials
    }

    /// Connect and set up the Companion protocol.
    public func setup() async throws {
        // 1. Connect TCP
        try await connection.connect()

        // 2. Start receiving frames
        await protocolHandler.startReceiving()

        // 3. Pair-verify if credentials are available
        if let credentials {
            let verifier = CompanionPairVerifyHandler(
                connection: connection,
                credentials: credentials
            )
            try await verifier.verify()
        }

        // 4. Send system info
        try await protocolHandler.sendSystemInfo()

        // 5. Start touch
        try await protocolHandler.startTouch()

        // 6. Start session
        try await protocolHandler.startSession()

        // 7. Subscribe to events
        try await protocolHandler.subscribeEvents(["_iMC"])

        // 8. Create interface implementations
        remoteControl = CompanionRemoteControl(protocol: protocolHandler)
        apps = CompanionApps(protocol: protocolHandler)
        userAccounts = CompanionUserAccounts(protocol: protocolHandler)
        power = CompanionPower(protocol: protocolHandler)
        audio = CompanionAudio(protocol: protocolHandler)
        keyboard = CompanionKeyboard(protocol: protocolHandler)
        touch = CompanionTouch(protocol: protocolHandler)
        features = CompanionFeatures(isConnected: true)
    }

    /// Close the Companion protocol connection.
    public func close() async {
        await protocolHandler.stop()
        await connection.close()
    }
}
