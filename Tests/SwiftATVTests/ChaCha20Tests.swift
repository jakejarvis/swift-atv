import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/support/test_chacha20.py
final class ChaCha20Tests: XCTestCase {

    let fakeKey = Data(repeating: UInt8(ascii: "k"), count: 32)

    // MARK: - test_12_bytes_nonce

    func testEncryptDecrypt12ByteNonce() throws {
        let cipher = ChaCha20Cipher(
            encryptKey: fakeKey,
            decryptKey: fakeKey,
            nonceLength: 12
        )

        let plaintext = Data("test".utf8)
        let encrypted = try cipher.encrypt(plaintext)

        // Encrypted data should be plaintext + 16-byte tag
        XCTAssertEqual(encrypted.count, plaintext.count + 16)

        let decrypted = try cipher.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - test_8_bytes_nonce

    func testEncryptDecrypt8ByteNonce() throws {
        let cipher = ChaCha20Cipher8ByteNonce(
            encryptKey: fakeKey,
            decryptKey: fakeKey
        )

        let plaintext = Data("test".utf8)
        let encrypted = try cipher.encrypt(plaintext)

        XCTAssertEqual(encrypted.count, plaintext.count + 16)

        let decrypted = try cipher.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    // MARK: - Additional tests

    func testEncryptDecryptEmpty() throws {
        let cipher = ChaCha20Cipher(
            encryptKey: fakeKey,
            decryptKey: fakeKey
        )

        let encrypted = try cipher.encrypt(Data())
        let decrypted = try cipher.decrypt(encrypted)
        XCTAssertEqual(decrypted, Data())
    }

    func testEncryptDecryptLargeData() throws {
        let cipher = ChaCha20Cipher(
            encryptKey: fakeKey,
            decryptKey: fakeKey
        )

        let plaintext = Data(repeating: 0x42, count: 1024)
        let encrypted = try cipher.encrypt(plaintext)
        let decrypted = try cipher.decrypt(encrypted)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testMultipleEncryptDecrypt() throws {
        let cipher = ChaCha20Cipher(
            encryptKey: fakeKey,
            decryptKey: fakeKey
        )

        // Encrypt/decrypt multiple messages in sequence
        // (nonce auto-increments)
        for i in 0..<10 {
            let plaintext = Data("message \(i)".utf8)
            let encrypted = try cipher.encrypt(plaintext)
            let decrypted = try cipher.decrypt(encrypted)
            XCTAssertEqual(decrypted, plaintext, "Failed at message \(i)")
        }
    }

    func testEncryptWithAAD() throws {
        let cipher = ChaCha20Cipher(
            encryptKey: fakeKey,
            decryptKey: fakeKey
        )

        let plaintext = Data("test".utf8)
        let aad = Data("header".utf8)
        let encrypted = try cipher.encrypt(plaintext, aad: aad)
        let decrypted = try cipher.decrypt(encrypted, aad: aad)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testDecryptTooShort() {
        let cipher = ChaCha20Cipher(
            encryptKey: fakeKey,
            decryptKey: fakeKey
        )

        // Less than 16 bytes (minimum for auth tag)
        XCTAssertThrowsError(try cipher.decrypt(Data([0x01, 0x02])))
    }

    func testDifferentKeysFailDecrypt() throws {
        let key1 = Data(repeating: 0x01, count: 32)
        let key2 = Data(repeating: 0x02, count: 32)

        let encCipher = ChaCha20Cipher(
            encryptKey: key1,
            decryptKey: key1
        )
        let decCipher = ChaCha20Cipher(
            encryptKey: key2,
            decryptKey: key2  // Wrong key: encrypted with key1
        )

        let encrypted = try encCipher.encrypt(Data("secret".utf8))

        // This should fail because decCipher uses wrong key
        XCTAssertThrowsError(try decCipher.decrypt(encrypted))
    }
}
