import Foundation

/// Handles AirPlay 2 HAP pair-setup over `/pair-pin-start` and `/pair-setup`.
public final class AirPlayPairingHandler: @unchecked Sendable, PairingHandler {
    private let config: AppleTVConfiguration
    private let _service: ServiceInfo
    private let settings: ATVSettings
    private let setup: HAPPairSetupHandler
    private let lock = NSLock()

    private var connection: AirPlayControlConnection?
    private var _pin: String?
    private var _hasPaired = false
    private var m2ResponseData: Data?

    public var service: ServiceInfo { _service }
    public var pairingCodeDirection: PairingCodeDirection { .deviceProvided }
    public var hasPaired: Bool { lock.withLock { _hasPaired } }
    public var credentials: HAPCredentials? { setup.credentials }

    private init(config: AppleTVConfiguration, service: ServiceInfo, settings: ATVSettings) {
        self.config = config
        self._service = service
        self.settings = settings
        self.setup = HAPPairSetupHandler(
            clientIdentifier: Data(settings.clientIdentity.pairingIdentifier.utf8)
        )
    }

    /// Create an AirPlay 2 pairing handler.
    public static func create(
        config: AppleTVConfiguration,
        service: ServiceInfo,
        settings: ATVSettings = ATVSettings()
    ) async throws(ATVError) -> AirPlayPairingHandler {
        let version = AirPlaySupport.protocolVersion(
            service: service,
            preferred: settings.protocols.airplay.airPlayVersion
        )
        guard version == .v2 else {
            throw ATVError.notSupported("AirPlay pairing is only implemented for AirPlay 2 HAP")
        }
        return AirPlayPairingHandler(config: config, service: service, settings: settings)
    }

    public func pin(_ pin: String) async throws(ATVError) {
        lock.withLock {
            _pin = normalizedPairingPIN(pin)
        }
    }

    public func begin() async throws(ATVError) {
        let existing = lock.withLock {
            let current = connection
            connection = nil
            m2ResponseData = nil
            _hasPaired = false
            return current
        }
        await existing?.close()

        let control = AirPlayControlConnection(host: config.address, port: _service.port)
        do {
            try await control.connect()
            let response = try await control.beginPairSetup(setup)
            lock.withLock {
                connection = control
                m2ResponseData = response
                _hasPaired = false
            }
        } catch {
            await control.close()
            throw error
        }
    }

    public func finish() async throws(ATVError) -> PairingResult {
        let (control, pin, m2Data) = lock.withLock { (connection, _pin, m2ResponseData) }
        guard let control else {
            throw ATVError.invalidState("finish() called before begin()")
        }
        guard let pin else {
            throw ATVError.pairingFailed("PIN not set. Call pin() before finish().")
        }
        guard let m2Data else {
            throw ATVError.invalidState("finish() called before begin()")
        }

        let m3 = try setup.m3(fromResponse: m2Data, pin: pin)
        let m4 = try await control.pairSetupExchange(m3)
        let m5 = try setup.m5(fromResponse: m4, displayName: settings.clientIdentity.name)
        let m6 = try await control.pairSetupExchange(m5)
        try setup.finish(fromResponse: m6)
        guard let credentials = setup.credentials else {
            throw ATVError.pairingFailed("Pairing completed without credentials")
        }

        lock.withLock {
            _hasPaired = true
        }
        return PairingResult(service: _service, credentials: credentials)
    }

    public func close() async {
        let control = lock.withLock {
            let current = connection
            connection = nil
            return current
        }
        await control?.close()
    }
}
