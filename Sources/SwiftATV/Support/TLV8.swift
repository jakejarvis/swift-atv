import Foundation

// MARK: - TLV Tags

/// TLV8 tags used in HAP authentication.
public enum TLVTag: UInt8, Sendable {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
    case separator = 0xFF
}

/// TLV8 error codes.
public enum TLVError: UInt8, Sendable {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

/// TLV8 pairing methods.
public enum TLVMethod: UInt8, Sendable {
    case pairSetup = 0x00
    case pairSetupWithAuth = 0x01
    case pairVerify = 0x02
    case addPairing = 0x03
    case removePairing = 0x04
    case listPairings = 0x05
}

// MARK: - TLV8 Encoding/Decoding

/// TLV8 binary format used in HAP authentication exchanges.
public enum TLV8 {

    /// A single TLV8 entry with a tag and data.
    public struct Entry: Sendable {
        public let tag: UInt8
        public let data: Data

        public init(tag: UInt8, data: Data) {
            self.tag = tag
            self.data = data
        }

        public init(tag: TLVTag, data: Data) {
            self.tag = tag.rawValue
            self.data = data
        }

        public init(tag: TLVTag, value: UInt8) {
            self.tag = tag.rawValue
            self.data = Data([value])
        }
    }

    /// Encode TLV8 entries to binary data.
    /// Values longer than 255 bytes are automatically split into multiple chunks.
    public static func encode(_ entries: [Entry]) -> Data {
        var result = Data()
        for entry in entries {
            let data = entry.data
            if data.isEmpty {
                result.append(entry.tag)
                result.append(0)
                continue
            }

            var offset = 0
            while offset < data.count {
                let chunkSize = min(255, data.count - offset)
                result.append(entry.tag)
                result.append(UInt8(chunkSize))
                result.append(data[data.startIndex + offset..<data.startIndex + offset + chunkSize])
                offset += chunkSize
            }
        }
        return result
    }

    /// Decode TLV8 binary data into a dictionary keyed by tag.
    /// Consecutive entries with the same tag are automatically reassembled.
    public static func decode(_ data: Data) -> [UInt8: Data] {
        var result = [UInt8: Data]()
        var offset = 0
        var lastTag: UInt8?

        while offset + 1 < data.count {
            let tag = data[offset]
            let length = Int(data[offset + 1])
            offset += 2

            guard offset + length <= data.count else { break }

            let chunk = data[offset..<offset + length]
            offset += length

            if tag == lastTag, var existing = result[tag] {
                // Reassemble multi-chunk values
                existing.append(chunk)
                result[tag] = existing
            } else {
                result[tag] = Data(chunk)
            }
            lastTag = tag
        }

        return result
    }

    /// Decode TLV8 binary data into an ordered array of entries.
    /// Consecutive entries with the same tag are automatically reassembled.
    public static func decodeEntries(_ data: Data) -> [Entry] {
        var entries = [Entry]()
        var offset = 0

        while offset + 1 < data.count {
            let tag = data[offset]
            let length = Int(data[offset + 1])
            offset += 2

            guard offset + length <= data.count else { break }

            let chunk = Data(data[offset..<offset + length])
            offset += length

            if let last = entries.last, last.tag == tag {
                // Reassemble: merge with previous
                var merged = last.data
                merged.append(chunk)
                entries[entries.count - 1] = Entry(tag: tag, data: merged)
            } else {
                entries.append(Entry(tag: tag, data: chunk))
            }
        }

        return entries
    }
}
