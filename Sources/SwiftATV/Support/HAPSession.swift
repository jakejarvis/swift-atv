import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// HAP transport encryption used by AirPlay 2 control, event, and data channels.
///
/// The encrypted transport splits plaintext into 1024-byte chunks. Each chunk
/// is framed as `[length: UInt16LE][ciphertext][tag]`, where the two length
/// bytes are also used as ChaCha20-Poly1305 additional authenticated data.
internal final class HAPSession: @unchecked Sendable {
    private static let blockSize = 1024
    private static let tagSize = 16

    private let outputKey: SymmetricKey
    private let inputKey: SymmetricKey
    private var outputCounter: UInt64 = 0
    private var inputCounter: UInt64 = 0
    private var decryptBuffer = Data()

    init(outputKey: Data, inputKey: Data) {
        self.outputKey = SymmetricKey(data: outputKey)
        self.inputKey = SymmetricKey(data: inputKey)
    }

    func encrypt(_ data: Data) throws(ATVError) -> Data {
        var encrypted = Data()
        var offset = 0

        while offset < data.count {
            let chunkSize = min(Self.blockSize, data.count - offset)
            let end = offset + chunkSize
            let chunk = Data(data[offset..<end])
            let lengthBytes = Self.lengthBytes(chunkSize)
            let nonce = try Self.nonce(counter: outputCounter)
            outputCounter += 1

            do {
                let sealed = try ChaChaPoly.seal(
                    chunk,
                    using: outputKey,
                    nonce: nonce,
                    authenticating: lengthBytes
                )
                encrypted.append(lengthBytes)
                encrypted.append(sealed.ciphertext)
                encrypted.append(sealed.tag)
            } catch {
                throw ATVError.wrap(error)
            }

            offset = end
        }

        return encrypted
    }

    func decrypt(_ data: Data) throws(ATVError) -> Data {
        decryptBuffer.append(data)
        var plaintext = Data()

        while decryptBuffer.count >= 2 {
            let length = Int(decryptBuffer[0]) | (Int(decryptBuffer[1]) << 8)
            guard length <= Self.blockSize else {
                throw ATVError.invalidData("HAP encrypted block exceeds 1024-byte limit")
            }

            let totalLength = 2 + length + Self.tagSize
            guard decryptBuffer.count >= totalLength else {
                break
            }

            let lengthBytes = Data(decryptBuffer[0..<2])
            let ciphertext = Data(decryptBuffer[2..<(2 + length)])
            let tag = Data(decryptBuffer[(2 + length)..<totalLength])
            let nonce = try Self.nonce(counter: inputCounter)
            inputCounter += 1

            do {
                let sealed = try ChaChaPoly.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
                plaintext.append(
                    try ChaChaPoly.open(sealed, using: inputKey, authenticating: lengthBytes)
                )
            } catch {
                throw ATVError.wrap(error)
            }

            decryptBuffer = Data(decryptBuffer[totalLength...])
        }

        return plaintext
    }

    private static func lengthBytes(_ length: Int) -> Data {
        Data([
            UInt8(length & 0xFF),
            UInt8((length >> 8) & 0xFF),
        ])
    }

    private static func nonce(counter: UInt64) throws(ATVError) -> ChaChaPoly.Nonce {
        var nonce = Data(count: 12)
        var littleEndianCounter = counter.littleEndian
        withUnsafeBytes(of: &littleEndianCounter) { bytes in
            nonce.replaceSubrange(4..<12, with: bytes)
        }
        do {
            return try ChaChaPoly.Nonce(data: nonce)
        } catch {
            throw ATVError.wrap(error)
        }
    }
}
