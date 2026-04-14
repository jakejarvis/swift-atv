import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// ChaCha20-Poly1305 cipher with auto-incrementing nonce for encrypted communication.
///
/// Thread safety: Mutable nonce counters are protected by `NSLock`.
/// This class uses `@unchecked Sendable` because the lock-based synchronization
/// cannot be verified by the compiler.
public final class ChaCha20Cipher: @unchecked Sendable {
    private let encryptKey: SymmetricKey
    private let decryptKey: SymmetricKey
    private let nonceLength: Int
    private let lock = NSLock()
    private var encryptCounter: UInt64 = 0
    private var decryptCounter: UInt64 = 0

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
    public func encrypt(_ plaintext: Data, aad: Data? = nil) throws(ATVError) -> Data {
        lock.lock()
        let counter = encryptCounter
        encryptCounter += 1
        lock.unlock()

        do {
            let nonce = try makeNonce(counter: counter, length: nonceLength)
            let sealedBox: ChaChaPoly.SealedBox
            if let aad {
                sealedBox = try ChaChaPoly.seal(plaintext, using: encryptKey, nonce: nonce, authenticating: aad)
            } else {
                sealedBox = try ChaChaPoly.seal(plaintext, using: encryptKey, nonce: nonce)
            }
            return sealedBox.ciphertext + sealedBox.tag
        } catch {
            throw ATVError.wrap(error)
        }
    }

    /// Decrypt data with optional additional authenticated data.
    /// - Parameter data: Ciphertext concatenated with 16-byte Poly1305 tag.
    public func decrypt(_ data: Data, aad: Data? = nil) throws(ATVError) -> Data {
        lock.lock()
        let counter = decryptCounter
        decryptCounter += 1
        lock.unlock()

        guard data.count >= 16 else {
            throw ATVError.invalidData("Encrypted data too short (need at least 16 bytes for tag)")
        }

        do {
            let nonce = try makeNonce(counter: counter, length: nonceLength)
            let ciphertext = data[data.startIndex..<data.endIndex - 16]
            let tag = data[data.endIndex - 16..<data.endIndex]

            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            if let aad {
                return try ChaChaPoly.open(sealedBox, using: decryptKey, authenticating: aad)
            } else {
                return try ChaChaPoly.open(sealedBox, using: decryptKey)
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }
    }

    private func makeNonce(counter: UInt64, length: Int) throws(ATVError) -> ChaChaPoly.Nonce {
        guard length == 8 || length == 12 else {
            throw ATVError.invalidData("ChaCha20 nonce length must be 8 or 12 bytes")
        }

        var nonceData = Data(count: 12)
        var le = counter.littleEndian
        nonceData.replaceSubrange(4..<12, with: Data(bytes: &le, count: 8))

        do {
            return try ChaChaPoly.Nonce(data: nonceData)
        } catch {
            throw ATVError.wrap(error)
        }
    }
}

/// ChaCha20-Poly1305 cipher variant using 8-byte nonce (4 zero bytes + 8-byte counter).
///
/// Thread safety: Mutable nonce counters are protected by `NSLock`.
public final class ChaCha20Cipher8ByteNonce: @unchecked Sendable {
    private let encryptKey: SymmetricKey
    private let decryptKey: SymmetricKey
    private let lock = NSLock()
    private var encryptCounter: UInt64 = 0
    private var decryptCounter: UInt64 = 0

    public init(encryptKey: Data, decryptKey: Data) {
        self.encryptKey = SymmetricKey(data: encryptKey)
        self.decryptKey = SymmetricKey(data: decryptKey)
    }

    /// Encrypt data, returning ciphertext + tag.
    public func encrypt(_ plaintext: Data, aad: Data? = nil) throws(ATVError) -> Data {
        lock.lock()
        let counter = encryptCounter
        encryptCounter += 1
        lock.unlock()

        do {
            var nonceData = Data(count: 12)
            var le = counter.littleEndian
            nonceData.replaceSubrange(4..<12, with: Data(bytes: &le, count: 8))

            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let sealedBox: ChaChaPoly.SealedBox
            if let aad {
                sealedBox = try ChaChaPoly.seal(plaintext, using: encryptKey, nonce: nonce, authenticating: aad)
            } else {
                sealedBox = try ChaChaPoly.seal(plaintext, using: encryptKey, nonce: nonce)
            }
            return sealedBox.ciphertext + sealedBox.tag
        } catch {
            throw ATVError.wrap(error)
        }
    }

    /// Decrypt data (ciphertext + 16-byte tag).
    public func decrypt(_ data: Data, aad: Data? = nil) throws(ATVError) -> Data {
        lock.lock()
        let counter = decryptCounter
        decryptCounter += 1
        lock.unlock()

        guard data.count >= 16 else {
            throw ATVError.invalidData("Encrypted data too short")
        }

        do {
            var nonceData = Data(count: 12)
            var le = counter.littleEndian
            nonceData.replaceSubrange(4..<12, with: Data(bytes: &le, count: 8))

            let nonce = try ChaChaPoly.Nonce(data: nonceData)
            let ciphertext = data[data.startIndex..<data.endIndex - 16]
            let tag = data[data.endIndex - 16..<data.endIndex]
            let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

            if let aad {
                return try ChaChaPoly.open(sealedBox, using: decryptKey, authenticating: aad)
            } else {
                return try ChaChaPoly.open(sealedBox, using: decryptKey)
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }
    }
}
