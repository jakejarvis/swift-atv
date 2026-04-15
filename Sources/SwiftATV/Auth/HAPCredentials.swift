import Foundation

/// Type of authentication used during pairing.
public enum AuthenticationType: Int, Codable, Sendable {
    case null = 0
    case legacy = 1
    case hap = 2
    case transient = 3
}

/// HAP credentials obtained from pairing with a device.
public struct HAPCredentials: Codable, Sendable, CustomStringConvertible {
    /// Long-term public key (Ed25519).
    public let ltpk: Data
    /// Long-term secret key (Ed25519).
    public let ltsk: Data
    /// Apple TV's identifier.
    public let atvIdentifier: Data
    /// Client's identifier.
    public let clientIdentifier: Data

    public init(ltpk: Data, ltsk: Data, atvIdentifier: Data, clientIdentifier: Data) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.atvIdentifier = atvIdentifier
        self.clientIdentifier = clientIdentifier
    }

    /// Sentinel for no credentials.
    public static let none = HAPCredentials(
        ltpk: Data(),
        ltsk: Data(),
        atvIdentifier: Data(),
        clientIdentifier: Data()
    )

    /// Sentinel for transient credentials (no persistent pairing).
    public static let transient = HAPCredentials(
        ltpk: Data([0x74, 0x72, 0x61, 0x6E, 0x73, 0x69, 0x65, 0x6E, 0x74]),  // "transient"
        ltsk: Data(),
        atvIdentifier: Data(),
        clientIdentifier: Data()
    )

    /// Serialize to a colon-separated hex string (compatible with pyatv format).
    public func serialize() -> String {
        [ltpk, ltsk, atvIdentifier, clientIdentifier]
            .map { $0.hexEncodedString() }
            .joined(separator: ":")
    }

    /// Parse from a colon-separated hex string.
    ///
    /// Four-component strings use the modern pyatv format:
    /// `ltpk:ltsk:atvIdentifier:clientIdentifier`. Two-component strings
    /// use pyatv's legacy format: `clientIdentifier:ltsk`.
    public static func parse(_ string: String) throws -> HAPCredentials {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        let credentials: HAPCredentials
        if parts.count == 4 {
            credentials = HAPCredentials(
                ltpk: try Data(hexString: parts[0]),
                ltsk: try Data(hexString: parts[1]),
                atvIdentifier: try Data(hexString: parts[2]),
                clientIdentifier: try Data(hexString: parts[3])
            )
        } else if parts.count == 2 {
            // Legacy pyatv format: clientIdentifier:ltsk.
            credentials = HAPCredentials(
                ltpk: Data(),
                ltsk: try Data(hexString: parts[1]),
                atvIdentifier: Data(),
                clientIdentifier: try Data(hexString: parts[0])
            )
        } else {
            throw ATVError.invalidCredentials("Expected 2 or 4 colon-separated hex components")
        }

        guard credentials.authenticationType != nil else {
            throw ATVError.invalidCredentials("Invalid HAP credential component layout")
        }
        return credentials
    }

    public var description: String {
        "HAPCredentials(ltpk: \(ltpk.count)B, ltsk: \(ltsk.count)B)"
    }
}

extension HAPCredentials {
    var authenticationType: AuthenticationType? {
        if ltpk.isEmpty, ltsk.isEmpty, atvIdentifier.isEmpty, clientIdentifier.isEmpty {
            return .null
        }
        if ltpk == Data("transient".utf8) {
            return .transient
        }
        if ltpk.isEmpty, !ltsk.isEmpty, atvIdentifier.isEmpty, !clientIdentifier.isEmpty {
            return .legacy
        }
        if !ltpk.isEmpty, !ltsk.isEmpty, !atvIdentifier.isEmpty, !clientIdentifier.isEmpty {
            return .hap
        }
        return nil
    }
}

// MARK: - Data Hex Extensions

extension Data {
    /// Convert data to a lowercase hex string.
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Initialize from a hex string.
    init(hexString: String) throws {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count % 2 == 0 else {
            throw ATVError.invalidData("Hex string must have even length")
        }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw ATVError.invalidData("Invalid hex character")
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
