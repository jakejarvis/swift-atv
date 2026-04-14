// swift-format-ignore-file: AlwaysUseLowerCamelCase
// SRP-6a uses single-letter uppercase names (N, g, A, B, S, K, M1, etc.)
// that match RFC 5054 and pyatv's hap_srp.py. Renaming them to camelCase
// would hurt readability and spec-traceability.

import BigInt
import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// SRP-6a client implementation for HAP pair-setup.
///
/// Matches the semantics of pyatv's `SRPAuthHandler` (which uses the
/// `srptools` library) so wire-level interop with Apple TVs is preserved.
///
/// Key conventions (these are the gotchas):
/// - `N`, `g`, `A`, `B`, `S` are serialized to bytes via **minimal**
///   big-endian (no padding) when hashed into `k`, `K`, `M1`, `M2`.
/// - `u = H(PAD(A) || PAD(B))` — A and B **are** padded to N.byteCount
///   when computing `u`. This is the one place padding differs.
/// - `K = H(S)` — single SHA-512 of the premaster secret's minimal bytes.
/// - Username is hashed in `x` and `M1` as raw UTF-8 bytes.
///
/// Reference:
/// - RFC 5054 §2.5 (SRP-6a)
/// - srptools `srptools/context.py` (pyatv's SRP dependency)
/// - pyatv `pyatv/auth/hap_srp.py`

// MARK: - Group constants

/// RFC 5054 Appendix A 3072-bit group used by HAP pair-setup.
enum SRPGroup {
    /// The 3072-bit safe prime from RFC 5054 Appendix A.
    /// Matches `srptools.constants.PRIME_3072`.
    static let N: BigUInt = BigUInt(
        """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6\
        3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245\
        E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411\
        7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F\
        83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08\
        CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9\
        DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D\
        04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8760273\
        3EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB31\
        43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """,
        radix: 16
    )!

    /// The generator value (always `5` for the 3072-bit group).
    static let g: BigUInt = 5

    /// Byte length of `N` for padding operations (384 bytes / 3072 bits).
    static let nByteCount: Int = 384
}

// MARK: - BigUInt serialization helpers

extension BigUInt {
    /// Minimal big-endian byte representation. Leading zero bytes stripped.
    /// Matches srptools' `int_to_bytes`. The `BigUInt.serialize()` already
    /// does this — `BigUInt(0).serialize()` returns an empty `Data`.
    fileprivate var minimalBytes: Data {
        serialize()
    }

    /// Big-endian byte representation left-padded with zeros to `byteCount`.
    /// Matches srptools' `SRPContext.pad(val)`.
    fileprivate func padded(to byteCount: Int) -> Data {
        let raw = serialize()
        if raw.count >= byteCount { return raw }
        return Data(repeating: 0, count: byteCount - raw.count) + raw
    }
}

// MARK: - SHA-512 helpers

/// SHA-512 hash of the concatenation of the given byte buffers.
private func sha512(_ parts: Data...) -> Data {
    var hasher = SHA512()
    for part in parts {
        hasher.update(data: part)
    }
    return Data(hasher.finalize())
}

/// Bytewise XOR of two buffers. Fatal error if lengths differ.
private func xorBytes(_ lhs: Data, _ rhs: Data) -> Data {
    precondition(lhs.count == rhs.count, "XOR requires equal-length buffers")
    var result = Data(count: lhs.count)
    for i in 0..<lhs.count {
        result[i] = lhs[lhs.startIndex + i] ^ rhs[rhs.startIndex + i]
    }
    return result
}

// MARK: - SRP client state machine

/// SRP-6a client. Not `Sendable` by itself — used only inside the
/// `HAPPairSetupHandler` state machine which is the Sendable boundary.
struct SRPClient {
    /// Username (the literal ASCII `"Pair-Setup"` for HAP pair-setup).
    let username: String

    /// Client private exponent `a` (random, 32+ bytes of entropy).
    private let a: BigUInt

    /// Client public value `A = g^a mod N`, cached as big-endian bytes.
    let publicKeyA: Data

    /// Cached session key `K = H(S)` — populated by `processChallenge`.
    /// 64 bytes (SHA-512 output).
    private(set) var sessionK: Data?

    /// Cached client proof `M1` — populated by `processChallenge`.
    /// 64 bytes.
    private(set) var clientProofM1: Data?

    // MARK: - Init

    /// Creates a new SRP client with a fresh random `a`.
    /// - Parameters:
    ///   - username: SRP username. For HAP pair-setup, always `"Pair-Setup"`.
    ///   - privateKey: Optional fixed private exponent `a`. Use **only** for
    ///     deterministic tests; production always wants a random value.
    init(username: String = "Pair-Setup", privateKey: BigUInt? = nil) {
        self.username = username
        let aValue: BigUInt
        if let privateKey {
            aValue = privateKey
        } else {
            // 256 bits of entropy, matching pyatv's 32-byte Ed25519 private
            // bytes reused as `a` (the exact entropy source is irrelevant
            // for wire compatibility — only `A = g^a mod N` is observed).
            let bytes = SymmetricKey(size: .init(bitCount: 256))
                .withUnsafeBytes { Data($0) }
            aValue = BigUInt(bytes)
        }
        self.a = aValue
        self.publicKeyA = SRPGroup.g.power(aValue, modulus: SRPGroup.N).padded(to: SRPGroup.nByteCount)
    }

    // MARK: - Processing

    /// Process the server challenge (salt + public key `B`) and compute
    /// the client proof `M1` and session key `K`.
    ///
    /// - Parameters:
    ///   - salt: Server-provided salt bytes.
    ///   - serverPublicB: Server's public value `B` in big-endian bytes.
    ///   - pin: The HAP pair-setup PIN (typically 4 digits).
    /// - Returns: `(M1, K)` tuple. Both are 64 bytes.
    /// - Throws: `ATVError.authenticationFailed` if `B % N == 0` or `u == 0`.
    mutating func processChallenge(
        salt: Data,
        serverPublicB: Data,
        pin: String
    ) throws(ATVError) -> (proofM1: Data, sessionK: Data) {
        let B = BigUInt(serverPublicB)
        guard B % SRPGroup.N != 0 else {
            throw ATVError.authenticationFailed("SRP: server public key B is invalid (B mod N == 0)")
        }

        // u = H(PAD(A) || PAD(B))
        let uHash = sha512(
            publicKeyA,  // already padded by init
            B.padded(to: SRPGroup.nByteCount)
        )
        let u = BigUInt(uHash)
        guard u != 0 else {
            throw ATVError.authenticationFailed("SRP: scrambling parameter u == 0")
        }

        // k = H(N || PAD(g))
        let kHash = sha512(
            SRPGroup.N.minimalBytes,
            SRPGroup.g.padded(to: SRPGroup.nByteCount)
        )
        let k = BigUInt(kHash)

        // x = H(salt || H(username || ":" || pin))
        let innerXHash = sha512(
            Data("\(username):\(pin)".utf8)
        )
        let xHash = sha512(salt, innerXHash)
        let x = BigUInt(xHash)

        // v = g^x mod N
        let v = SRPGroup.g.power(x, modulus: SRPGroup.N)

        // S = (B - k*v)^(a + u*x) mod N
        // Use positive-difference form: B - kv may be negative, so add N before reducing.
        let kv = (k * v) % SRPGroup.N
        let base = (B + SRPGroup.N - kv) % SRPGroup.N
        let exponent = a + u * x
        let S = base.power(exponent, modulus: SRPGroup.N)

        // K = H(S) — S is hashed with minimal (non-padded) bytes, matching srptools.
        let K = sha512(S.minimalBytes)

        // M1 = H( H(N) XOR H(g), H(username), salt, A, B, K )
        let hN = sha512(SRPGroup.N.minimalBytes)
        let hG = sha512(SRPGroup.g.minimalBytes)
        let hNxorHG = xorBytes(hN, hG)
        let hU = sha512(Data(username.utf8))

        let M1 = sha512(
            hNxorHG,
            hU,
            salt,
            publicKeyA,
            B.minimalBytes,  // unpadded — matches srptools
            K
        )

        // Cache for verifyServerProof.
        self.sessionK = K
        self.clientProofM1 = M1

        return (proofM1: M1, sessionK: K)
    }

    /// Verify the server's proof `M2 = H(A || M1 || K)`.
    /// - Throws: `ATVError.authenticationFailed` if proofs don't match or
    ///   `processChallenge` hasn't been called yet.
    func verifyServerProof(_ serverM2: Data) throws(ATVError) {
        guard let M1 = clientProofM1, let K = sessionK else {
            throw ATVError.invalidState("SRP: processChallenge must be called before verifyServerProof")
        }

        let expected = sha512(
            publicKeyA,
            M1,
            K
        )

        // Constant-time compare (length check + XOR accumulate).
        guard expected.count == serverM2.count else {
            throw ATVError.authenticationFailed("SRP: server proof M2 mismatch (length)")
        }
        var diff: UInt8 = 0
        for i in 0..<expected.count {
            diff |= expected[expected.startIndex + i] ^ serverM2[serverM2.startIndex + i]
        }
        guard diff == 0 else {
            throw ATVError.authenticationFailed("SRP: server proof M2 mismatch")
        }
    }
}
