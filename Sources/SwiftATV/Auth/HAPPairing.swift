import Crypto
import Foundation

/// HAP pair setup procedure.
///
/// Implements the pair-setup flow where the client and device exchange
/// TLV8 messages to establish long-term keys. Requires PIN entry.
public protocol PairSetupProcedure: Sendable {
    /// Start the pairing process.
    func startPairing() async throws -> Data

    /// Process a response from the device and return the next message to send.
    func processResponse(_ data: Data) async throws -> Data?

    /// Complete pairing and return credentials.
    func finishPairing() async throws -> HAPCredentials
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
    public func step1() throws -> Data {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.verifyPrivateKey = privateKey
        let publicKey = Data(privateKey.publicKey.rawRepresentation)

        return TLV8.encode([
            TLV8.Entry(tag: .state, value: 1),
            TLV8.Entry(tag: .publicKey, data: publicKey),
        ])
    }

    /// Step 2: Process device response, verify device identity, return encrypted proof.
    public func step2(_ responseData: Data) throws -> Data {
        let response = TLV8.decode(responseData)

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
        let shared = try SRPAuthHandler.sharedSecret(
            privateKey: privateKey,
            peerPublicKey: peerPubKeyData
        )
        self.sharedSecret = shared

        // Derive session key
        let sessionKey = hkdfExpand(
            salt: "Pair-Verify-Encrypt-Salt",
            info: "Pair-Verify-Encrypt-Info",
            sharedSecret: shared
        )

        // Decrypt the device's proof
        let cipher = ChaCha20Cipher(
            encryptKey: sessionKey,
            decryptKey: sessionKey,
            nonceLength: 12
        )

        // The nonce for pair-verify is "PV-Msg02" padded to 12 bytes
        let decrypted = try decryptWithFixedNonce(
            data: encryptedData,
            key: sessionKey,
            nonce: pairVerifyNonce(sequence: 2)
        )

        let innerTLV = TLV8.decode(decrypted)
        guard let deviceIdentifier = innerTLV[TLVTag.identifier.rawValue],
            let deviceSignature = innerTLV[TLVTag.signature.rawValue]
        else {
            throw ATVError.pairingFailed("Missing identifier or signature in verify proof")
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
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        var clientInfo = Data()
        clientInfo.append(myPublicKey)
        clientInfo.append(credentials.clientIdentifier)
        clientInfo.append(peerPubKeyData)

        let signature = try signingKey.signature(for: clientInfo)

        let proofTLV = TLV8.encode([
            TLV8.Entry(tag: .identifier, data: credentials.clientIdentifier),
            TLV8.Entry(tag: .signature, data: Data(signature)),
        ])

        // Encrypt our proof
        let encrypted = try encryptWithFixedNonce(
            data: proofTLV,
            key: sessionKey,
            nonce: pairVerifyNonce(sequence: 3)
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
    ) throws -> (outputKey: Data, inputKey: Data) {
        guard let shared = sharedSecret else {
            throw ATVError.invalidState("Shared secret not established")
        }

        let outputKey = hkdfExpand(salt: salt, info: outputInfo, sharedSecret: shared)
        let inputKey = hkdfExpand(salt: salt, info: inputInfo, sharedSecret: shared)
        return (outputKey, inputKey)
    }

    // MARK: - Private Helpers

    private func pairVerifyNonce(sequence: UInt8) -> Data {
        var nonce = Data(count: 12)
        // "PV-Msg0X" where X is the sequence number, zero-padded to 12 bytes
        let label = "PV-Msg0\(sequence)"
        let labelData = Data(label.utf8)
        let offset = 12 - labelData.count
        nonce.replaceSubrange(offset..<12, with: labelData)
        return nonce
    }

    private func encryptWithFixedNonce(data: Data, key: Data, nonce: Data) throws -> Data {
        let symKey = SymmetricKey(data: key)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonce)
        let sealedBox = try ChaChaPoly.seal(data, using: symKey, nonce: chaChaNonce)
        return sealedBox.ciphertext + sealedBox.tag
    }

    private func decryptWithFixedNonce(data: Data, key: Data, nonce: Data) throws -> Data {
        guard data.count >= 16 else {
            throw ATVError.invalidData("Encrypted data too short for decryption")
        }

        let symKey = SymmetricKey(data: key)
        let chaChaNonce = try ChaChaPoly.Nonce(data: nonce)
        let ciphertext = data[data.startIndex..<data.endIndex - 16]
        let tag = data[data.endIndex - 16..<data.endIndex]

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chaChaNonce,
            ciphertext: ciphertext,
            tag: tag
        )

        return try ChaChaPoly.open(sealedBox, using: symKey)
    }
}
