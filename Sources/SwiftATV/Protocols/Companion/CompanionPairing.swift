import Crypto
import Foundation

/// Handles Companion protocol pair-verify using HAP credentials.
///
/// Exchanges TLV8 messages over PV_Start/PV_Next frame types
/// to establish ChaCha20 encryption on the connection.
public final class CompanionPairVerifyHandler: @unchecked Sendable {
    private let connection: CompanionConnection
    private let credentials: HAPCredentials
    private let hapVerifier: HAPPairVerifyHandler

    public init(connection: CompanionConnection, credentials: HAPCredentials) {
        self.connection = connection
        self.credentials = credentials
        self.hapVerifier = HAPPairVerifyHandler(credentials: credentials)
    }

    /// Perform the full pair-verify exchange.
    /// On success, encryption is enabled on the connection.
    public func verify() async throws {
        // Step 1: Send verify start
        let step1Data = try hapVerifier.step1()
        let step1Response = try await connection.sendAndReceive(
            type: .pvStart,
            payload: step1Data
        )

        // Step 2: Process response and send proof
        let step2Data = try hapVerifier.step2(step1Response)
        let step2Response = try await connection.sendAndReceive(
            type: .pvNext,
            payload: step2Data
        )

        // Verify step 2 response
        let responseTLV = TLV8.decode(step2Response)
        if let errorData = responseTLV[TLVTag.error.rawValue], !errorData.isEmpty {
            throw ATVError.authenticationFailed("Pair-verify failed with error code \(errorData[0])")
        }

        // Derive encryption keys and enable encryption
        let (outputKey, inputKey) = try hapVerifier.deriveKeys(
            salt: "",
            outputInfo: "ClientEncrypt-main",
            inputInfo: "ServerEncrypt-main"
        )

        connection.enableEncryption(outputKey: outputKey, inputKey: inputKey)
    }
}

/// Handles Companion protocol pairing (pair-setup + pair-verify).
///
/// Implements the `PairingHandler` protocol for use with `SwiftATV.pair()`.
public final class CompanionPairingHandler: @unchecked Sendable, PairingHandler {
    private let config: AppleTVConfiguration
    private let _service: ServiceInfo
    private let connection: CompanionConnection
    private var pin: String?
    private var _hasPaired = false

    public var service: ServiceInfo { _service }
    public var deviceProvidesPin: Bool { true }
    public var hasPaired: Bool { _hasPaired }

    private init(config: AppleTVConfiguration, service: ServiceInfo, connection: CompanionConnection) {
        self.config = config
        self._service = service
        self.connection = connection
    }

    /// Create a pairing handler for the Companion protocol.
    public static func create(
        config: AppleTVConfiguration,
        service: ServiceInfo
    ) async throws -> CompanionPairingHandler {
        let connection = CompanionConnection(host: config.address, port: service.port)
        try await connection.connect()
        return CompanionPairingHandler(config: config, service: service, connection: connection)
    }

    /// Set the PIN displayed on the Apple TV.
    public func pin(_ pin: String) async throws {
        self.pin = pin
    }

    /// Begin the pairing process.
    /// The Apple TV will display a PIN code on screen.
    public func begin() async throws {
        // Send pair-setup start with method = 0 (SRP)
        let startTLV = TLV8.encode([
            TLV8.Entry(tag: .method, value: 0),
            TLV8.Entry(tag: .state, value: 1),
        ])

        _ = try await connection.sendAndReceive(type: .psStart, payload: startTLV)
    }

    /// Complete the pairing process using the entered PIN.
    public func finish() async throws {
        guard let pin else {
            throw ATVError.pairingFailed("PIN not set. Call pin() before finish().")
        }

        // In a full implementation, this would:
        // 1. Use the PIN to compute the SRP proof
        // 2. Exchange PS_Next messages for SRP verification
        // 3. Derive session keys
        // 4. Exchange encrypted credentials
        // For now, this is a placeholder for the SRP exchange

        // Send state 3 with PIN proof (simplified)
        let nextTLV = TLV8.encode([
            TLV8.Entry(tag: .state, value: 3),
            TLV8.Entry(tag: .proof, data: Data(pin.utf8)),
        ])

        let response = try await connection.sendAndReceive(type: .psNext, payload: nextTLV)
        let responseTLV = TLV8.decode(response)

        if let errorData = responseTLV[TLVTag.error.rawValue], !errorData.isEmpty {
            throw ATVError.pairingFailed("Pairing failed with error code \(errorData[0])")
        }

        _hasPaired = true
    }

    /// Close the pairing handler.
    public func close() async {
        await connection.close()
    }
}
