import Crypto
import Foundation
import _CryptoExtras

/// HKDF-SHA512 key derivation.
public func hkdfExpand(
    salt: String,
    info: String,
    sharedSecret: Data,
    length: Int = 32
) -> Data {
    let key = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: sharedSecret),
        salt: Data(salt.utf8),
        info: Data(info.utf8),
        outputByteCount: length
    )
    return key.withUnsafeBytes { Data($0) }
}

/// SRP authentication handler for HAP pairing.
///
/// Implements the Secure Remote Password (SRP) protocol used during
/// Apple TV pairing, combined with Ed25519 for signing and
/// X25519 for key exchange during pair-verify.
///
/// Instances are immutable after initialization. The unchecked Sendable
/// conformance bridges older Swift 6 toolchains where CryptoKit key types are
/// not annotated as Sendable.
public final class SRPAuthHandler: @unchecked Sendable {

    /// Ed25519 signing key pair (generated during initialize).
    private let signingKey: Curve25519.Signing.PrivateKey

    /// Client identifier for pairing.
    public let identifier: Data

    public init(identifier: Data? = nil) {
        self.signingKey = Curve25519.Signing.PrivateKey()
        self.identifier = identifier ?? UUID().uuidString.data(using: .utf8)!
    }

    /// The public signing key (Ed25519).
    public var publicKey: Data {
        Data(signingKey.publicKey.rawRepresentation)
    }

    /// Sign data with the Ed25519 key.
    public func sign(_ data: Data) throws -> Data {
        try Data(signingKey.signature(for: data))
    }

    // MARK: - Pair Verify

    /// Generate an X25519 key pair for pair-verify.
    public func generateVerifyKeys() -> (
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Data
    ) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return (key, Data(key.publicKey.rawRepresentation))
    }

    /// Perform X25519 key agreement.
    public static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Data
    ) throws -> Data {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return shared.withUnsafeBytes { Data($0) }
    }

    /// Verify an Ed25519 signature.
    public static func verifySignature(
        _ signature: Data,
        message: Data,
        publicKey: Data
    ) throws -> Bool {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        return key.isValidSignature(signature, for: message)
    }

    /// Derive encryption keys from shared secret for pair-verify.
    public static func deriveKeys(
        sharedSecret: Data,
        writeInfo: String = "ServerEncrypt-main",
        readInfo: String = "ClientEncrypt-main"
    ) -> (encryptKey: Data, decryptKey: Data) {
        let encryptKey = hkdfExpand(
            salt: "MediaRemote-Salt",
            info: writeInfo,
            sharedSecret: sharedSecret
        )
        let decryptKey = hkdfExpand(
            salt: "MediaRemote-Salt",
            info: readInfo,
            sharedSecret: sharedSecret
        )
        return (encryptKey, decryptKey)
    }
}
