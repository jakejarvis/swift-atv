import Crypto
import Foundation

/// ChaCha20-Poly1305 cipher with auto-incrementing nonce for encrypted communication.
public final class ChaCha20Cipher: @unchecked Sendable {
    private let encryptKey: SymmetricKey
    private let decryptKey: SymmetricKey
    private var encryptCounter: UInt64 = 0
    private var decryptCounter: UInt64 = 0
    private let nonceLength: Int

    /// Initialize with separate encrypt and decrypt keys.
    /// - Parameters:
    ///   - encryptKey: Key used for encrypting outgoing data.
    ///   - decryptKey: Key used for decrypting incoming data.
    ///   - nonceLength: Nonce length in bytes (8 or 12). Default is 12.
    public init(encryptKey: Data, decryptKey: Data, nonceLength: Int = 12) {
        self.encryptKey = SymmetricKey(data: encryptKey)
        self.decryptKey = SymmetricKey(data: decryptKey)
        self.nonceLength = nonceLength
    }

    /// Encrypt data with optional additional authenticated data.
    public func encrypt(_ plaintext: Data, aad: Data? = nil) throws -> Data {
        let nonce = makeNonce(counter: encryptCounter, length: nonceLength)
        encryptCounter += 1

        let sealedBox: ChaChaPoly.SealedBox
        if let aad {
            sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: encryptKey,
                nonce: nonce,
                authenticating: aad
            )
        } else {
            sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: encryptKey,
                nonce: nonce
            )
        }

        // Return ciphertext + tag (no nonce prefix since receiver knows the counter)
        return sealedBox.ciphertext + sealedBox.tag
    }

    /// Decrypt data with optional additional authenticated data.
    /// - Parameter data: Ciphertext concatenated with 16-byte Poly1305 tag.
    public func decrypt(_ data: Data, aad: Data? = nil) throws -> Data {
        let nonce = makeNonce(counter: decryptCounter, length: nonceLength)
        decryptCounter += 1

        guard data.count >= 16 else {
            throw ATVError.invalidData("Encrypted data too short (need at least 16 bytes for tag)")
        }

        let ciphertext = data[data.startIndex..<data.endIndex - 16]
        let tag = data[data.endIndex - 16..<data.endIndex]

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )

        if let aad {
            return try ChaChaPoly.open(sealedBox, using: decryptKey, authenticating: aad)
        } else {
            return try ChaChaPoly.open(sealedBox, using: decryptKey)
        }
    }

    private func makeNonce(counter: UInt64, length: Int) -> ChaChaPoly.Nonce {
        var nonceData = Data(count: length)
        // Counter is placed at the end in little-endian
        var le = counter.littleEndian
        let counterSize = min(8, length)
        let counterOffset = length - counterSize
        nonceData.replaceSubrange(
            counterOffset..<counterOffset + counterSize,
            with: Data(bytes: &le, count: counterSize)
        )
        // swiftlint:disable:next force_try
        return try! ChaChaPoly.Nonce(data: nonceData)
    }
}

/// ChaCha20-Poly1305 cipher variant using 8-byte nonce.
public final class ChaCha20Cipher8ByteNonce: @unchecked Sendable {
    private let encryptKey: SymmetricKey
    private let decryptKey: SymmetricKey
    private var encryptCounter: UInt64 = 0
    private var decryptCounter: UInt64 = 0

    public init(encryptKey: Data, decryptKey: Data) {
        self.encryptKey = SymmetricKey(data: encryptKey)
        self.decryptKey = SymmetricKey(data: decryptKey)
    }

    /// Encrypt data, returning nonce + ciphertext + tag.
    public func encrypt(_ plaintext: Data, aad: Data? = nil) throws -> Data {
        // Build 12-byte nonce: 4 zero bytes + 8-byte counter
        var nonceData = Data(count: 12)
        var le = encryptCounter.littleEndian
        nonceData.replaceSubrange(4..<12, with: Data(bytes: &le, count: 8))
        encryptCounter += 1

        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealedBox: ChaChaPoly.SealedBox
        if let aad {
            sealedBox = try ChaChaPoly.seal(plaintext, using: encryptKey, nonce: nonce, authenticating: aad)
        } else {
            sealedBox = try ChaChaPoly.seal(plaintext, using: encryptKey, nonce: nonce)
        }
        return sealedBox.ciphertext + sealedBox.tag
    }

    /// Decrypt data (ciphertext + 16-byte tag).
    public func decrypt(_ data: Data, aad: Data? = nil) throws -> Data {
        var nonceData = Data(count: 12)
        var le = decryptCounter.littleEndian
        nonceData.replaceSubrange(4..<12, with: Data(bytes: &le, count: 8))
        decryptCounter += 1

        guard data.count >= 16 else {
            throw ATVError.invalidData("Encrypted data too short")
        }

        let ciphertext = data[data.startIndex..<data.endIndex - 16]
        let tag = data[data.endIndex - 16..<data.endIndex]

        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        if let aad {
            return try ChaChaPoly.open(sealedBox, using: decryptKey, authenticating: aad)
        } else {
            return try ChaChaPoly.open(sealedBox, using: decryptKey)
        }
    }
}
