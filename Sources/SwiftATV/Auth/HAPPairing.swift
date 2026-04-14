import BigInt
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

// MARK: - Shared HAP helpers (used by both pair-setup and pair-verify)

/// Build a 12-byte HAP nonce by left-padding an ASCII label with zeros.
/// Matches `pyatv/support/chacha20.py::_pad_nonce` and `HAPPairVerifyHandler`'s
/// private `pairVerifyNonce`.
///
/// Examples:
/// - `"PS-Msg05"` → `\x00\x00\x00\x00PS-Msg05`
/// - `"PV-Msg02"` → `\x00\x00\x00\x00PV-Msg02`
func hapNonce(_ label: String) -> Data {
    var nonce = Data(count: 12)
    let labelBytes = Data(label.utf8)
    let offset = 12 - labelBytes.count
    nonce.replaceSubrange(offset..<12, with: labelBytes)
    return nonce
}

/// Encrypt `data` with a fixed 12-byte nonce using ChaCha20-Poly1305.
/// Returns `ciphertext || tag` (16-byte tag appended).
func hapEncrypt(_ data: Data, key: Data, nonce: Data) throws(ATVError) -> Data {
    do {
        let symKey = SymmetricKey(data: key)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonce)
        let sealedBox = try ChaChaPoly.seal(data, using: symKey, nonce: chaChaNonce)
        return sealedBox.ciphertext + sealedBox.tag
    } catch {
        throw ATVError.wrap(error)
    }
}

/// Decrypt `data` (expected as `ciphertext || 16-byte tag`) with a fixed
/// 12-byte nonce using ChaCha20-Poly1305.
func hapDecrypt(_ data: Data, key: Data, nonce: Data) throws(ATVError) -> Data {
    guard data.count >= 16 else {
        throw ATVError.invalidData("Encrypted data too short for decryption")
    }
    do {
        let symKey = SymmetricKey(data: key)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonce)
        let ciphertext = data[data.startIndex..<data.endIndex - 16]
        let tag = data[data.endIndex - 16..<data.endIndex]
        let sealedBox = try ChaChaPoly.SealedBox(nonce: chaChaNonce, ciphertext: ciphertext, tag: tag)
        return try ChaChaPoly.open(sealedBox, using: symKey)
    } catch let err as ATVError {
        throw err
    } catch {
        throw ATVError.wrap(error)
    }
}

/// HAP pair setup procedure.
///
/// Implements the pair-setup flow where the client and device exchange
/// TLV8 messages to establish long-term keys. Requires PIN entry.
public protocol PairSetupProcedure: Sendable {
    /// Start the pairing process.
    func startPairing() async throws(ATVError) -> Data

    /// Process a response from the device and return the next message to send.
    func processResponse(_ data: Data) async throws(ATVError) -> Data?

    /// Complete pairing and return credentials.
    func finishPairing() async throws(ATVError) -> HAPCredentials
}

/// HAP pair verify procedure.
///
/// Implements the pair-verify flow using existing credentials to
/// establish session encryption keys.
///
/// Thread safety: Steps must be called sequentially. Mutable state
/// is protected by `NSLock` for safety.
public final class HAPPairVerifyHandler: @unchecked Sendable {
    private let credentials: HAPCredentials
    private let lock = NSLock()
    private var verifyPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var sharedSecret: Data?
    private var peerPublicKey: Data?

    public init(credentials: HAPCredentials) {
        self.credentials = credentials
    }

    /// Step 1: Generate verify start message.
    /// Returns TLV8 data to send to device.
    public func step1() throws(ATVError) -> Data {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.verifyPrivateKey = privateKey
        let publicKey = Data(privateKey.publicKey.rawRepresentation)

        return TLV8.encode([
            TLV8.Entry(tag: .state, value: 1),
            TLV8.Entry(tag: .publicKey, data: publicKey),
        ])
    }

    /// Step 2: Process device response, verify device identity, return encrypted proof.
    public func step2(_ responseData: Data) throws(ATVError) -> Data {
        let response = try TLV8.decodeStrict(responseData)

        guard let peerPubKeyData = response[TLVTag.publicKey.rawValue],
            let encryptedData = response[TLVTag.encryptedData.rawValue]
        else {
            throw ATVError.pairingFailed("Missing public key or encrypted data in verify response")
        }

        self.peerPublicKey = peerPubKeyData

        guard let privateKey = verifyPrivateKey else {
            throw ATVError.invalidState("Verify private key not initialized")
        }

        // Compute shared secret via X25519
        let shared: Data
        do {
            shared = try SRPAuthHandler.sharedSecret(
                privateKey: privateKey,
                peerPublicKey: peerPubKeyData
            )
        } catch {
            throw ATVError.wrap(error)
        }
        self.sharedSecret = shared

        // Derive session key
        let sessionKey = hkdfExpand(
            salt: "Pair-Verify-Encrypt-Salt",
            info: "Pair-Verify-Encrypt-Info",
            sharedSecret: shared
        )

        // The nonce for pair-verify is "PV-Msg02" padded to 12 bytes
        let decrypted = try hapDecrypt(
            encryptedData,
            key: sessionKey,
            nonce: hapNonce("PV-Msg02")
        )

        let innerTLV = try TLV8.decodeStrict(decrypted)
        guard let deviceIdentifier = innerTLV[TLVTag.identifier.rawValue],
            let deviceSignature = innerTLV[TLVTag.signature.rawValue]
        else {
            throw ATVError.pairingFailed("Missing identifier or signature in verify proof")
        }
        if !credentials.atvIdentifier.isEmpty, deviceIdentifier != credentials.atvIdentifier {
            throw ATVError.authenticationFailed("Pair-verify response came from an unexpected device")
        }

        // Verify the device's signature
        let myPublicKey = Data(privateKey.publicKey.rawRepresentation)
        var deviceInfo = Data()
        deviceInfo.append(peerPubKeyData)
        deviceInfo.append(deviceIdentifier)
        deviceInfo.append(myPublicKey)

        guard
            (try? SRPAuthHandler.verifySignature(
                deviceSignature,
                message: deviceInfo,
                publicKey: credentials.ltpk
            )) == true
        else {
            throw ATVError.authenticationFailed("Device signature verification failed")
        }

        // Create our proof
        let signature: Data
        do {
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
            var clientInfo = Data()
            clientInfo.append(myPublicKey)
            clientInfo.append(credentials.clientIdentifier)
            clientInfo.append(peerPubKeyData)
            signature = Data(try signingKey.signature(for: clientInfo))
        } catch {
            throw ATVError.wrap(error)
        }

        let proofTLV = TLV8.encode([
            TLV8.Entry(tag: .identifier, data: credentials.clientIdentifier),
            TLV8.Entry(tag: .signature, data: signature),
        ])

        // Encrypt our proof
        let encrypted = try hapEncrypt(
            proofTLV,
            key: sessionKey,
            nonce: hapNonce("PV-Msg03")
        )

        return TLV8.encode([
            TLV8.Entry(tag: .state, value: 3),
            TLV8.Entry(tag: .encryptedData, data: encrypted),
        ])
    }

    /// Get the derived encryption keys after successful pair-verify.
    public func deriveKeys(
        salt: String = "MediaRemote-Salt",
        outputInfo: String = "MediaRemote-Write-Encryption-Key",
        inputInfo: String = "MediaRemote-Read-Encryption-Key"
    ) throws(ATVError) -> (outputKey: Data, inputKey: Data) {
        guard let shared = sharedSecret else {
            throw ATVError.invalidState("Shared secret not established")
        }

        let outputKey = hkdfExpand(salt: salt, info: outputInfo, sharedSecret: shared)
        let inputKey = hkdfExpand(salt: salt, info: inputInfo, sharedSecret: shared)
        return (outputKey, inputKey)
    }

}

// MARK: - HAP Pair-Setup State Machine

/// HAP pair-setup state machine implementing the 6-step SRP-6a exchange
/// with encrypted key + identity transport.
///
/// The caller (usually a protocol-specific driver like `CompanionPairingHandler`)
/// is responsible for wrapping and transporting the TLV8 bytes between steps.
/// Call order: `m1` → send → receive → `m3(_:pin:)` → send → receive →
/// `m5(_:)` → send → receive → `finish(_:)`. After `finish`, read
/// `credentials` for the persisted HAP long-term keys.
///
/// Reference: `pyatv/auth/hap_srp.py` `SRPAuthHandler.step1..step4`
/// (+ `pyatv/protocols/companion/auth.py` for the driver flow).
///
/// Thread safety: Intended for use from a single async caller driving the
/// state machine sequentially. `@unchecked Sendable` with an internal lock
/// mirrors `HAPPairVerifyHandler`.
public final class HAPPairSetupHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let clientIdentifier: Data
    private let signingKey: Curve25519.Signing.PrivateKey
    /// Optional deterministic SRP private exponent for test fixtures.
    /// Production code leaves this `nil` to use fresh randomness.
    private let srpPrivateKeyOverride: BigUInt?

    private var srp: SRPClient?
    private var sessionKey: Data?  // HKDF output for M5/M6 encryption
    private var srpSharedK: Data?  // full SHA-512(S), for signing HKDFs

    public private(set) var credentials: HAPCredentials?

    /// - Parameter clientIdentifier: The controller's pairing identifier.
    ///   Defaults to a fresh random UUID as ASCII lowercase hyphenated bytes
    ///   (matching pyatv's `str(uuid.uuid4()).encode()`).
    public init(
        clientIdentifier: Data = Data(UUID().uuidString.lowercased().utf8)
    ) {
        self.clientIdentifier = clientIdentifier
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.srpPrivateKeyOverride = nil
    }

    /// Test-only initializer that allows injecting deterministic keys.
    /// Use **only** for unit tests — production callers should use the
    /// public `init` with fresh randomness.
    internal init(
        clientIdentifier: Data,
        srpPrivateKey: BigUInt?,
        signingKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()
    ) {
        self.clientIdentifier = clientIdentifier
        self.signingKey = signingKey
        self.srpPrivateKeyOverride = srpPrivateKey
    }

    // MARK: - State machine

    /// Build the M1 TLV (`state=1, method=pairSetup(0)`). Send this over
    /// the protocol-specific pair-setup start frame (e.g. Companion PS_Start).
    public func m1() throws(ATVError) -> Data {
        TLV8.encode([
            TLV8.Entry(tag: .state, value: 1),
            TLV8.Entry(tag: .method, value: 0),
        ])
    }

    /// Process the M2 response (salt + server public key B) and return the
    /// M3 TLV (`state=3, publicKey=A, proof=M1proof`). Requires the PIN
    /// entered by the user after seeing it on the Apple TV screen.
    public func m3(fromResponse responseData: Data, pin: String) throws(ATVError) -> Data {
        let tlv = try TLV8.decodeStrict(responseData)
        try throwIfErrorTag(tlv)

        guard let salt = tlv[TLVTag.salt.rawValue] else {
            throw ATVError.pairingFailed("Missing salt in M2")
        }
        guard let serverB = tlv[TLVTag.publicKey.rawValue] else {
            throw ATVError.pairingFailed("Missing publicKey in M2")
        }

        var client = SRPClient(privateKey: srpPrivateKeyOverride)
        let (m1Proof, k) = try client.processChallenge(
            salt: salt,
            serverPublicB: serverB,
            pin: pin
        )

        lock.withLock {
            self.srp = client
            self.srpSharedK = k
        }

        return TLV8.encode([
            TLV8.Entry(tag: .state, value: 3),
            TLV8.Entry(tag: .publicKey, data: client.publicKeyA),
            TLV8.Entry(tag: .proof, data: m1Proof),
        ])
    }

    /// Process the M4 response (server proof M2), verify it, derive the
    /// pair-setup session key, and build the M5 TLV with the encrypted
    /// controller identity payload. `displayName` is optional — when set
    /// it shows up on the Apple TV's Settings > Users & Accounts entry.
    public func m5(fromResponse responseData: Data, displayName: String? = nil) throws(ATVError) -> Data {
        let tlv = try TLV8.decodeStrict(responseData)
        try throwIfErrorTag(tlv)

        guard let serverProof = tlv[TLVTag.proof.rawValue] else {
            throw ATVError.pairingFailed("Missing proof in M4")
        }

        let (client, k) = lock.withLock { (srp, srpSharedK) }
        guard let client, let k else {
            throw ATVError.invalidState("HAPPairSetupHandler.m5 called before m3")
        }

        try client.verifyServerProof(serverProof)

        // Derive the M5/M6 session key + the controller signing prefix.
        let sessionKey = hkdfExpand(
            salt: "Pair-Setup-Encrypt-Salt",
            info: "Pair-Setup-Encrypt-Info",
            sharedSecret: k
        )
        let iOSDeviceX = hkdfExpand(
            salt: "Pair-Setup-Controller-Sign-Salt",
            info: "Pair-Setup-Controller-Sign-Info",
            sharedSecret: k
        )

        // Sign iOSDeviceX || clientIdentifier || LTPK with our LTSK.
        let ltpk = Data(signingKey.publicKey.rawRepresentation)
        var deviceInfo = Data()
        deviceInfo.append(iOSDeviceX)
        deviceInfo.append(clientIdentifier)
        deviceInfo.append(ltpk)

        let signature: Data
        do {
            signature = Data(try signingKey.signature(for: deviceInfo))
        } catch {
            throw ATVError.wrap(error)
        }

        // Inner TLV: Identifier, PublicKey (LTPK), Signature. Optional Name.
        var innerEntries: [TLV8.Entry] = [
            TLV8.Entry(tag: .identifier, data: clientIdentifier),
            TLV8.Entry(tag: .publicKey, data: ltpk),
            TLV8.Entry(tag: .signature, data: signature),
        ]
        if let displayName {
            // pyatv uses OPACK-packed `{"name": displayName}` under
            // TlvValue.Name (0x11) for pair-setup M5. This is the label
            // the Apple TV shows in Settings > Users & Accounts.
            let nameDict = OPACK.Value.dictionary([("name", .string(displayName))])
            let nameData = OPACK.encode(nameDict)
            innerEntries.append(TLV8.Entry(tag: .name, data: nameData))
        }

        let innerTLV = TLV8.encode(innerEntries)
        let encrypted = try hapEncrypt(
            innerTLV,
            key: sessionKey,
            nonce: hapNonce("PS-Msg05")
        )

        lock.withLock {
            self.sessionKey = sessionKey
        }

        return TLV8.encode([
            TLV8.Entry(tag: .state, value: 5),
            TLV8.Entry(tag: .encryptedData, data: encrypted),
        ])
    }

    /// Process the M6 response (encrypted accessory identity). Decrypts,
    /// verifies the accessory's Ed25519 signature (a divergence from pyatv,
    /// which has a TODO to implement this check), and populates `credentials`.
    public func finish(fromResponse responseData: Data) throws(ATVError) {
        let outer = try TLV8.decodeStrict(responseData)
        try throwIfErrorTag(outer)

        guard let encrypted = outer[TLVTag.encryptedData.rawValue] else {
            throw ATVError.pairingFailed("Missing encryptedData in M6")
        }

        let (sessionKey, k) = lock.withLock { (self.sessionKey, self.srpSharedK) }
        guard let sessionKey, let k else {
            throw ATVError.invalidState("HAPPairSetupHandler.finish called before m5")
        }

        let decrypted = try hapDecrypt(
            encrypted,
            key: sessionKey,
            nonce: hapNonce("PS-Msg06")
        )

        let inner = try TLV8.decodeStrict(decrypted)
        guard let accessoryID = inner[TLVTag.identifier.rawValue],
            let accessoryLTPK = inner[TLVTag.publicKey.rawValue],
            let accessorySig = inner[TLVTag.signature.rawValue]
        else {
            throw ATVError.pairingFailed("Missing identifier/publicKey/signature in M6")
        }

        // Derive AccessoryX and verify the accessory's signature. pyatv's
        // `hap_srp.py::step4` has an explicit `TODO: verify signature here`
        // and skips this — we implement it because swift-crypto makes it
        // cheap and it's the correct behavior.
        let accessoryX = hkdfExpand(
            salt: "Pair-Setup-Accessory-Sign-Salt",
            info: "Pair-Setup-Accessory-Sign-Info",
            sharedSecret: k
        )
        var accessoryInfo = Data()
        accessoryInfo.append(accessoryX)
        accessoryInfo.append(accessoryID)
        accessoryInfo.append(accessoryLTPK)

        do {
            let accessoryPub = try Curve25519.Signing.PublicKey(rawRepresentation: accessoryLTPK)
            guard accessoryPub.isValidSignature(accessorySig, for: accessoryInfo) else {
                throw ATVError.authenticationFailed("accessory signature invalid")
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }

        // Persist credentials. Match pyatv's HapCredentials layout:
        // ltpk = accessoryLTPK, ltsk = signingKey.rawRepresentation,
        // atvIdentifier = accessoryID, clientIdentifier = self.clientIdentifier.
        let creds = HAPCredentials(
            ltpk: accessoryLTPK,
            ltsk: signingKey.rawRepresentation,
            atvIdentifier: accessoryID,
            clientIdentifier: clientIdentifier
        )
        lock.withLock { self.credentials = creds }
    }

    // MARK: - Helpers

    private func throwIfErrorTag(_ tlv: [UInt8: Data]) throws(ATVError) {
        guard let errorData = tlv[TLVTag.error.rawValue], !errorData.isEmpty else { return }
        // pyatv raises a generic AuthenticationError(stringify(tlv)) without
        // mapping per-code meanings. Match that for simplicity.
        throw ATVError.authenticationFailed("HAP pair-setup error code 0x\(String(errorData[0], radix: 16))")
    }
}
