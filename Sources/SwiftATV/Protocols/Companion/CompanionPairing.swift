import Crypto
import Foundation

// MARK: - Shared OPACK envelope helpers (pair-setup and pair-verify)

/// Wrap an inner TLV8 payload in the OPACK envelope that the Companion
/// protocol uses for auth handshakes. An optional `authTypeKey`/
/// `authTypeValue` entry (e.g. `_pwTy: 1` or `_auTy: 4`) is included only
/// when both are provided — pair-verify PV_Next omits it.
///
/// Wire-format matrix (matches pyatv's `protocols/companion/auth.py`):
/// - PS_Start  → `{_pd, _pwTy: 1}`
/// - PS_Next   → `{_pd, _pwTy: 1}` (pair-setup keeps _pwTy on every frame)
/// - PV_Start  → `{_pd, _auTy: 4}`
/// - PV_Next   → `{_pd}`            (pair-verify drops _auTy after Start)
internal func wrapCompanionAuthEnvelope(
    innerTLV: Data,
    authTypeKey: String? = nil,
    authTypeValue: UInt64? = nil
) -> Data {
    var entries: [(String, OPACK.Value)] = [("_pd", .data(innerTLV))]
    if let authTypeKey, let authTypeValue {
        entries.append((authTypeKey, .uint(authTypeValue)))
    }
    return OPACK.encode(.dictionary(entries))
}

/// Extract the inner TLV8 payload from a Companion auth response. Throws
/// `ATVError.invalidResponse` if the response isn't an OPACK dict with a
/// `_pd` data entry, or `ATVError.authenticationFailed` if the inner TLV
/// contains a HAP error tag (matches pyatv's `_get_pairing_data`).
internal func unwrapCompanionAuthEnvelope(_ responseBytes: Data) throws(ATVError) -> Data {
    let decoded: OPACK.Value
    do {
        decoded = try OPACK.decode(responseBytes)
    } catch {
        throw ATVError.wrap(error)
    }

    guard let pdValue = decoded["_pd"] else {
        throw ATVError.invalidResponse("Companion auth response missing _pd field")
    }
    guard case .data(let tlv) = pdValue else {
        throw ATVError.invalidResponse("Companion auth _pd has unexpected type")
    }

    let inner = try TLV8.decodeStrict(tlv)
    if let errorData = inner[TLVTag.error.rawValue], !errorData.isEmpty {
        throw ATVError.authenticationFailed(
            "HAP auth error code 0x\(String(errorData[0], radix: 16))"
        )
    }

    return tlv
}

// MARK: - Pair-Verify

/// Handles Companion protocol pair-verify using HAP credentials.
///
/// Exchanges HAP TLV8 messages — wrapped in the Companion OPACK auth
/// envelope (`{_pd, _auTy: 4}`) — over `PV_Start` / `PV_Next` frame types
/// to establish ChaCha20 encryption on the connection.
///
/// Mirrors `pyatv/protocols/companion/auth.py::CompanionPairVerifyProcedure`.
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
    public func verify() async throws(ATVError) {
        // Step 1: PV_Start carries `{_pd, _auTy: 4}`. Device replies with
        // its public key + encrypted proof on PV_Next.
        let step1TLV = try hapVerifier.step1()
        let step1Payload = wrapCompanionAuthEnvelope(
            innerTLV: step1TLV,
            authTypeKey: "_auTy",
            authTypeValue: 4
        )
        let step1ResponseBytes = try await connection.sendAndReceive(
            type: .pvStart,
            payload: step1Payload
        )
        let step1Response = try unwrapCompanionAuthEnvelope(step1ResponseBytes)

        // Step 2: PV_Next carries just `{_pd}` — pyatv drops _auTy here
        // (see `pyatv/protocols/companion/auth.py::CompanionPairVerifyProcedure`).
        let step2TLV = try hapVerifier.step2(step1Response)
        let step2Payload = wrapCompanionAuthEnvelope(innerTLV: step2TLV)
        let step2ResponseBytes = try await connection.sendAndReceive(
            type: .pvNext,
            payload: step2Payload
        )
        // Inner TLV is checked for error in unwrap; nothing else to do.
        _ = try unwrapCompanionAuthEnvelope(step2ResponseBytes)

        // Derive encryption keys and enable encryption.
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
///
/// Drives a `HAPPairSetupHandler` state machine and wraps each TLV message
/// in the OPACK envelope `{_pd: <tlv>, _pwTy: 1}` that the Companion protocol
/// expects, sending over PS_Start / PS_Next frames. Response frames for both
/// PS_Start and PS_Next arrive as PS_Next frames (asymmetric — same behavior
/// as pyatv's `CompanionProtocol.exchange_auth`).
///
/// On successful `finish()`, the returned credentials are persisted to
/// `config.settings.protocols.companion.credentials` so the caller can
/// save them and use pair-verify on subsequent connections.
public final class CompanionPairingHandler: @unchecked Sendable, PairingHandler {
    private let config: AppleTVConfiguration
    private let _service: ServiceInfo
    private let connection: CompanionConnection
    private let setup: HAPPairSetupHandler
    private let lock = NSLock()
    private var _pin: String?
    private var _hasPaired = false
    private var m2ResponseData: Data?  // raw inner TLV from the M2 response

    public var service: ServiceInfo { _service }
    public var deviceProvidesPin: Bool { true }
    public var hasPaired: Bool {
        lock.withLock { _hasPaired }
    }

    /// The credentials produced by a successful pair-setup, or `nil` if
    /// `finish()` has not yet been called or failed.
    public var credentials: HAPCredentials? {
        setup.credentials
    }

    private init(config: AppleTVConfiguration, service: ServiceInfo, connection: CompanionConnection) {
        self.config = config
        self._service = service
        self.connection = connection
        self.setup = HAPPairSetupHandler()
    }

    /// Create a pairing handler for the Companion protocol.
    public static func create(
        config: AppleTVConfiguration,
        service: ServiceInfo
    ) async throws(ATVError) -> CompanionPairingHandler {
        let connection = CompanionConnection(host: config.address, port: service.port)
        try await connection.connect()
        return CompanionPairingHandler(config: config, service: service, connection: connection)
    }

    /// Set the PIN displayed on the Apple TV.
    public func pin(_ pin: String) async throws(ATVError) {
        lock.withLock {
            self._pin = pin
        }
    }

    /// Begin the pairing process.
    /// The Apple TV will display a PIN code on screen once this returns.
    public func begin() async throws(ATVError) {
        // M1: state=1, method=pairSetup(0). Wrapped in OPACK envelope.
        let m1TLV = try setup.m1()
        let m2Response = try await exchangeAuth(.psStart, innerTLV: m1TLV)
        lock.withLock { self.m2ResponseData = m2Response }
    }

    /// Complete the pairing process using the entered PIN.
    /// After success, read `credentials` for the long-term HAP keys and
    /// persist them (e.g. into `ATVSettings.protocols.companion.credentials`).
    public func finish() async throws(ATVError) {
        let (pin, m2Data) = lock.withLock { (_pin, m2ResponseData) }
        guard let pin else {
            throw ATVError.pairingFailed("PIN not set. Call pin() before finish().")
        }
        guard let m2Data else {
            throw ATVError.invalidState("finish() called before begin()")
        }

        // M3: publicKey=A, proof=M1. Device responds with M4 on psNext.
        let m3TLV = try setup.m3(fromResponse: m2Data, pin: pin)
        let m4Response = try await exchangeAuth(.psNext, innerTLV: m3TLV)

        // M5: encrypted controller identity. Device responds with M6 on psNext.
        let m5TLV = try setup.m5(fromResponse: m4Response)
        let m6Response = try await exchangeAuth(.psNext, innerTLV: m5TLV)

        // M6: decrypt accessory identity, verify signature, store credentials.
        try setup.finish(fromResponse: m6Response)

        // The caller is responsible for persisting `self.credentials` into
        // `ATVSettings.protocols.companion.credentials` (matches pyatv's
        // contract where the handler produces credentials and the caller
        // stores them).

        lock.withLock {
            _hasPaired = true
        }
    }

    /// Close the pairing handler.
    public func close() async {
        await connection.close()
    }

    // MARK: - OPACK envelope helpers

    /// OPACK auth-type marker used by Companion for pair-setup.
    /// Matches pyatv (`"_pwTy": 1`).
    private static let authTypeKey = "_pwTy"
    private static let authTypeValue: UInt64 = 1

    /// Send a pair-setup TLV inside an OPACK envelope and return the inner
    /// TLV payload from the response. Both `psStart` requests and `psNext`
    /// requests receive their responses on the `psNext` channel —
    /// `CompanionConnection.sendAndReceive` handles that mapping by default
    /// via `defaultResponseType(for:)`.
    ///
    /// Matches `pyatv/protocols/companion/auth.py::_get_pairing_data` and
    /// `CompanionProtocol.exchange_auth`.
    private func exchangeAuth(
        _ frameType: CompanionFrameType,
        innerTLV: Data
    ) async throws(ATVError) -> Data {
        let payload = wrapCompanionAuthEnvelope(
            innerTLV: innerTLV,
            authTypeKey: Self.authTypeKey,
            authTypeValue: Self.authTypeValue
        )
        let responseBytes = try await connection.sendAndReceive(
            type: frameType,
            payload: payload
        )
        return try unwrapCompanionAuthEnvelope(responseBytes)
    }
}
