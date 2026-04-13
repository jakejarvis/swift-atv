import Foundation

/// Handles direct-MRP pairing using HAP pair-setup TLVs transported inside
/// `CRYPTO_PAIRING_MESSAGE` protobuf messages.
public final class MRPPairingHandler: @unchecked Sendable, PairingHandler {
    private let config: AppleTVConfiguration
    private let _service: ServiceInfo
    private let connection: MRPConnection
    private let setup: HAPPairSetupHandler
    private let settings: ATVSettings
    private let lock = NSLock()
    private var _pin: String?
    private var _hasPaired = false
    private var m2ResponseData: Data?

    public var service: ServiceInfo { _service }
    public var pairingCodeDirection: PairingCodeDirection { .deviceProvided }
    public var hasPaired: Bool { lock.withLock { _hasPaired } }

    /// The credentials produced by successful MRP pair-setup.
    public var credentials: HAPCredentials? { setup.credentials }

    private init(
        config: AppleTVConfiguration,
        service: ServiceInfo,
        connection: MRPConnection,
        settings: ATVSettings
    ) {
        self.config = config
        self._service = service
        self.connection = connection
        self.setup = HAPPairSetupHandler()
        self.settings = settings
    }

    /// Create a direct-MRP pairing handler.
    public static func create(
        config: AppleTVConfiguration,
        service: ServiceInfo,
        settings: ATVSettings = ATVSettings()
    ) async throws(ATVError) -> MRPPairingHandler {
        let connection = MRPConnection(host: config.address, port: service.port)
        try await connection.connect()
        _ = try await connection.sendAndReceive(
            MRPMessages.deviceInformation(settings: settings),
            responseType: .deviceInfoMessage
        )
        return MRPPairingHandler(
            config: config,
            service: service,
            connection: connection,
            settings: settings
        )
    }

    public func pin(_ pin: String) async throws(ATVError) {
        lock.withLock { _pin = pin }
    }

    public func begin() async throws(ATVError) {
        let m1 = try setup.m1()
        let response = try await exchange(m1)
        lock.withLock { m2ResponseData = response }
    }

    public func finish() async throws(ATVError) {
        let (pin, m2Data) = lock.withLock { (_pin, m2ResponseData) }
        guard let pin else {
            throw ATVError.pairingFailed("PIN not set. Call pin() before finish().")
        }
        guard let m2Data else {
            throw ATVError.invalidState("finish() called before begin()")
        }

        let m3 = try setup.m3(fromResponse: m2Data, pin: pin)
        let m4 = try await exchange(m3)
        let m5 = try setup.m5(fromResponse: m4, displayName: settings.info.name)
        let m6 = try await exchange(m5)
        try setup.finish(fromResponse: m6)

        lock.withLock { _hasPaired = true }
    }

    public func close() async {
        await connection.close()
    }

    private func exchange(_ pairingData: Data) async throws(ATVError) -> Data {
        let response = try await connection.sendAndReceive(
            MRPMessages.cryptoPairing(pairingData),
            responseType: .cryptoPairingMessage
        )
        let crypto = response.cryptoPairingMessage
        if crypto.hasStatus, crypto.status != 0 {
            throw ATVError.pairingFailed("MRP crypto pairing failed with status \(crypto.status)")
        }
        return crypto.pairingData
    }
}
