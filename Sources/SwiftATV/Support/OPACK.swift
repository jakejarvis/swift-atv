import Foundation

/// OPACK binary serialization format used by the Companion protocol.
public enum OPACK {

    // MARK: - Constants

    private static let terminator: UInt8 = 0x03
    private static let trueValue: UInt8 = 0x01
    private static let falseValue: UInt8 = 0x02
    private static let nilValue: UInt8 = 0x04
    private static let uuidValue: UInt8 = 0x05
    private static let absoluteTime: UInt8 = 0x06

    // Integer ranges
    private static let inlineIntBase: UInt8 = 0x08
    private static let inlineIntMax: UInt8 = 0x2F  // 0-39 inline
    private static let int8Tag: UInt8 = 0x30
    private static let int16Tag: UInt8 = 0x31
    private static let int32Tag: UInt8 = 0x32
    private static let int64Tag: UInt8 = 0x33

    // Negative integer tags
    private static let negInt8Tag: UInt8 = 0x38
    private static let negInt16Tag: UInt8 = 0x39
    private static let negInt32Tag: UInt8 = 0x3A
    private static let negInt64Tag: UInt8 = 0x3B

    // Float
    private static let float32Tag: UInt8 = 0x35
    private static let float64Tag: UInt8 = 0x36

    // String (inline 0x40-0x60, extended 0x61-0x64)
    private static let inlineStringBase: UInt8 = 0x40
    private static let inlineStringMax: UInt8 = 0x60  // 0-32 inline
    private static let string8Tag: UInt8 = 0x61
    private static let string16Tag: UInt8 = 0x62
    private static let string24Tag: UInt8 = 0x63
    private static let string32Tag: UInt8 = 0x64

    // Data (inline 0x70-0x90, extended 0x91-0x94)
    private static let inlineDataBase: UInt8 = 0x70
    private static let inlineDataMax: UInt8 = 0x90  // 0-32 inline
    private static let data8Tag: UInt8 = 0x91
    private static let data16Tag: UInt8 = 0x92
    private static let data32Tag: UInt8 = 0x93
    private static let data64Tag: UInt8 = 0x94

    // Lists (0xD0-0xDE fixed, 0xDF endless)
    private static let listBase: UInt8 = 0xD0
    private static let endlessList: UInt8 = 0xDF

    // Dicts (0xE0-0xEE fixed, 0xEF endless)
    private static let dictBase: UInt8 = 0xE0
    private static let endlessDict: UInt8 = 0xEF

    // MARK: - OPACKValue

    /// Represents any value that can be encoded/decoded in OPACK format.
    public enum Value: Sendable, CustomStringConvertible {
        case null
        case bool(Bool)
        case int(Int64)
        case uint(UInt64)
        case float(Float)
        case double(Double)
        case string(String)
        case data(Data)
        case uuid(UUID)
        case array([Value])
        case dict([(Value, Value)])

        public var description: String {
            switch self {
            case .null: return "null"
            case .bool(let v): return "\(v)"
            case .int(let v): return "\(v)"
            case .uint(let v): return "\(v)"
            case .float(let v): return "\(v)"
            case .double(let v): return "\(v)"
            case .string(let v): return "\"\(v)\""
            case .data(let v): return "<\(v.count) bytes>"
            case .uuid(let v): return v.uuidString
            case .array(let v): return "[\(v.count) items]"
            case .dict(let v): return "{\(v.count) pairs}"
            }
        }

        /// Helper to get as String.
        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        /// Helper to get as Int64.
        public var intValue: Int64? {
            switch self {
            case .int(let v): return v
            case .uint(let v): return Int64(exactly: v)
            default: return nil
            }
        }

        /// Helper to get as Data.
        public var dataValue: Data? {
            if case .data(let d) = self { return d }
            return nil
        }

        /// Helper to get as Bool.
        public var boolValue: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        /// Helper to get dict value by string key.
        public subscript(key: String) -> Value? {
            guard case .dict(let pairs) = self else { return nil }
            for (k, v) in pairs {
                if case .string(let s) = k, s == key { return v }
            }
            return nil
        }

        /// Helper to get array element by index.
        public subscript(index: Int) -> Value? {
            guard case .array(let arr) = self, index >= 0, index < arr.count else { return nil }
            return arr[index]
        }
    }

    // MARK: - Encoding

    /// Encode a value to OPACK binary format.
    public static func encode(_ value: Value) -> Data {
        var data = Data()
        encodeValue(value, into: &data)
        return data
    }

    private static func encodeValue(_ value: Value, into data: inout Data) {
        switch value {
        case .null:
            data.append(nilValue)

        case .bool(let v):
            data.append(v ? trueValue : falseValue)

        case .int(let v):
            if v >= 0 {
                encodeUInt(UInt64(v), into: &data)
            } else {
                encodeNegInt(v, into: &data)
            }

        case .uint(let v):
            encodeUInt(v, into: &data)

        case .float(let v):
            data.append(float32Tag)
            var le = v.bitPattern.littleEndian
            data.append(Data(bytes: &le, count: 4))

        case .double(let v):
            data.append(float64Tag)
            var le = v.bitPattern.littleEndian
            data.append(Data(bytes: &le, count: 8))

        case .string(let s):
            let bytes = Array(s.utf8)
            let len = bytes.count
            if len <= 32 {
                data.append(inlineStringBase + UInt8(len))
            } else if len <= 0xFF {
                data.append(string8Tag)
                data.append(UInt8(len))
            } else if len <= 0xFFFF {
                data.append(string16Tag)
                var le = UInt16(len).littleEndian
                data.append(Data(bytes: &le, count: 2))
            } else {
                data.append(string32Tag)
                var le = UInt32(len).littleEndian
                data.append(Data(bytes: &le, count: 4))
            }
            data.append(contentsOf: bytes)

        case .data(let d):
            let len = d.count
            if len <= 32 {
                data.append(inlineDataBase + UInt8(len))
            } else if len <= 0xFF {
                data.append(data8Tag)
                data.append(UInt8(len))
            } else if len <= 0xFFFF {
                data.append(data16Tag)
                var le = UInt16(len).littleEndian
                data.append(Data(bytes: &le, count: 2))
            } else {
                data.append(data32Tag)
                var le = UInt32(len).littleEndian
                data.append(Data(bytes: &le, count: 4))
            }
            data.append(d)

        case .uuid(let u):
            data.append(uuidValue)
            let uuid = u.uuid
            data.append(contentsOf: [
                uuid.0, uuid.1, uuid.2, uuid.3,
                uuid.4, uuid.5, uuid.6, uuid.7,
                uuid.8, uuid.9, uuid.10, uuid.11,
                uuid.12, uuid.13, uuid.14, uuid.15,
            ])

        case .array(let arr):
            let count = arr.count
            if count <= 14 {
                data.append(listBase + UInt8(count))
            } else {
                data.append(endlessList)
            }
            for item in arr {
                encodeValue(item, into: &data)
            }
            if count > 14 {
                data.append(terminator)
            }

        case .dict(let pairs):
            let count = pairs.count
            if count <= 14 {
                data.append(dictBase + UInt8(count))
            } else {
                data.append(endlessDict)
            }
            for (key, val) in pairs {
                encodeValue(key, into: &data)
                encodeValue(val, into: &data)
            }
            if count > 14 {
                data.append(terminator)
            }
        }
    }

    private static func encodeUInt(_ value: UInt64, into data: inout Data) {
        if value <= 39 {
            data.append(inlineIntBase + UInt8(value))
        } else if value <= 0xFF {
            data.append(int8Tag)
            data.append(UInt8(value))
        } else if value <= 0xFFFF {
            data.append(int16Tag)
            var le = UInt16(value).littleEndian
            data.append(Data(bytes: &le, count: 2))
        } else if value <= 0xFFFFFFFF {
            data.append(int32Tag)
            var le = UInt32(value).littleEndian
            data.append(Data(bytes: &le, count: 4))
        } else {
            data.append(int64Tag)
            var le = value.littleEndian
            data.append(Data(bytes: &le, count: 8))
        }
    }

    private static func encodeNegInt(_ value: Int64, into data: inout Data) {
        let absVal = UInt64(abs(value))
        if absVal <= 0xFF {
            data.append(negInt8Tag)
            data.append(UInt8(absVal))
        } else if absVal <= 0xFFFF {
            data.append(negInt16Tag)
            var le = UInt16(absVal).littleEndian
            data.append(Data(bytes: &le, count: 2))
        } else if absVal <= 0xFFFFFFFF {
            data.append(negInt32Tag)
            var le = UInt32(absVal).littleEndian
            data.append(Data(bytes: &le, count: 4))
        } else {
            data.append(negInt64Tag)
            var le = absVal.littleEndian
            data.append(Data(bytes: &le, count: 8))
        }
    }

    // MARK: - Decoding

    /// Decode an OPACK binary payload into a Value.
    public static func decode(_ data: Data) throws -> Value {
        var offset = 0
        return try decodeValue(data, offset: &offset)
    }

    private static func decodeValue(_ data: Data, offset: inout Int) throws -> Value {
        guard offset < data.count else {
            throw ATVError.invalidData("OPACK: unexpected end of data")
        }

        let tag = data[offset]
        offset += 1

        switch tag {
        case nilValue:
            return .null

        case trueValue:
            return .bool(true)

        case falseValue:
            return .bool(false)

        case uuidValue:
            guard offset + 16 <= data.count else {
                throw ATVError.invalidData("OPACK: not enough data for UUID")
            }
            let bytes = data[offset..<offset + 16]
            offset += 16
            let uuid = UUID(uuid: (
                bytes[bytes.startIndex], bytes[bytes.startIndex + 1],
                bytes[bytes.startIndex + 2], bytes[bytes.startIndex + 3],
                bytes[bytes.startIndex + 4], bytes[bytes.startIndex + 5],
                bytes[bytes.startIndex + 6], bytes[bytes.startIndex + 7],
                bytes[bytes.startIndex + 8], bytes[bytes.startIndex + 9],
                bytes[bytes.startIndex + 10], bytes[bytes.startIndex + 11],
                bytes[bytes.startIndex + 12], bytes[bytes.startIndex + 13],
                bytes[bytes.startIndex + 14], bytes[bytes.startIndex + 15]
            ))
            return .uuid(uuid)

        case absoluteTime:
            guard offset + 8 <= data.count else {
                throw ATVError.invalidData("OPACK: not enough data for absolute time")
            }
            let val = data.loadLittleEndian(at: offset, as: UInt64.self)
            offset += 8
            return .uint(val)

        // Inline integers (0-39)
        case inlineIntBase...inlineIntMax:
            return .uint(UInt64(tag - inlineIntBase))

        // Unsigned integers
        case int8Tag:
            let val = try readUInt8(data, offset: &offset)
            return .uint(UInt64(val))
        case int16Tag:
            let val = try readUInt16LE(data, offset: &offset)
            return .uint(UInt64(val))
        case int32Tag:
            let val = try readUInt32LE(data, offset: &offset)
            return .uint(UInt64(val))
        case int64Tag:
            let val = try readUInt64LE(data, offset: &offset)
            return .uint(val)

        // Negative integers
        case negInt8Tag:
            let val = try readUInt8(data, offset: &offset)
            return .int(-Int64(val))
        case negInt16Tag:
            let val = try readUInt16LE(data, offset: &offset)
            return .int(-Int64(val))
        case negInt32Tag:
            let val = try readUInt32LE(data, offset: &offset)
            return .int(-Int64(val))
        case negInt64Tag:
            let val = try readUInt64LE(data, offset: &offset)
            return .int(-Int64(val))

        // Floats
        case float32Tag:
            guard offset + 4 <= data.count else {
                throw ATVError.invalidData("OPACK: not enough data for float32")
            }
            let bits = data.loadLittleEndian(at: offset, as: UInt32.self)
            offset += 4
            return .float(Float(bitPattern: bits))

        case float64Tag:
            guard offset + 8 <= data.count else {
                throw ATVError.invalidData("OPACK: not enough data for float64")
            }
            let bits = data.loadLittleEndian(at: offset, as: UInt64.self)
            offset += 8
            return .double(Double(bitPattern: bits))

        // Inline strings (0-32 bytes)
        case inlineStringBase...inlineStringMax:
            let len = Int(tag - inlineStringBase)
            return try readString(data, offset: &offset, length: len)

        // Extended strings
        case string8Tag:
            let len = Int(try readUInt8(data, offset: &offset))
            return try readString(data, offset: &offset, length: len)
        case string16Tag:
            let len = Int(try readUInt16LE(data, offset: &offset))
            return try readString(data, offset: &offset, length: len)
        case string24Tag:
            let b0 = try readUInt8(data, offset: &offset)
            let b1 = try readUInt8(data, offset: &offset)
            let b2 = try readUInt8(data, offset: &offset)
            let len = Int(b0) | (Int(b1) << 8) | (Int(b2) << 16)
            return try readString(data, offset: &offset, length: len)
        case string32Tag:
            let len = Int(try readUInt32LE(data, offset: &offset))
            return try readString(data, offset: &offset, length: len)

        // Inline data (0-32 bytes)
        case inlineDataBase...inlineDataMax:
            let len = Int(tag - inlineDataBase)
            return try readData(data, offset: &offset, length: len)

        // Extended data
        case data8Tag:
            let len = Int(try readUInt8(data, offset: &offset))
            return try readData(data, offset: &offset, length: len)
        case data16Tag:
            let len = Int(try readUInt16LE(data, offset: &offset))
            return try readData(data, offset: &offset, length: len)
        case data32Tag:
            let len = Int(try readUInt32LE(data, offset: &offset))
            return try readData(data, offset: &offset, length: len)
        case data64Tag:
            let len = Int(try readUInt64LE(data, offset: &offset))
            return try readData(data, offset: &offset, length: len)

        // Fixed-size lists
        case listBase...0xDE:
            let count = Int(tag - listBase)
            var arr = [Value]()
            arr.reserveCapacity(count)
            for _ in 0..<count {
                arr.append(try decodeValue(data, offset: &offset))
            }
            return .array(arr)

        // Endless list
        case endlessList:
            var arr = [Value]()
            while offset < data.count && data[offset] != terminator {
                arr.append(try decodeValue(data, offset: &offset))
            }
            if offset < data.count { offset += 1 } // skip terminator
            return .array(arr)

        // Fixed-size dicts
        case dictBase...0xEE:
            let count = Int(tag - dictBase)
            var pairs = [(Value, Value)]()
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try decodeValue(data, offset: &offset)
                let val = try decodeValue(data, offset: &offset)
                pairs.append((key, val))
            }
            return .dict(pairs)

        // Endless dict
        case endlessDict:
            var pairs = [(Value, Value)]()
            while offset < data.count && data[offset] != terminator {
                let key = try decodeValue(data, offset: &offset)
                let val = try decodeValue(data, offset: &offset)
                pairs.append((key, val))
            }
            if offset < data.count { offset += 1 } // skip terminator
            return .dict(pairs)

        default:
            throw ATVError.invalidData("OPACK: unknown tag 0x\(String(tag, radix: 16))")
        }
    }

    // MARK: - Read Helpers

    private static func readUInt8(_ data: Data, offset: inout Int) throws -> UInt8 {
        guard offset < data.count else {
            throw ATVError.invalidData("OPACK: unexpected end of data reading uint8")
        }
        let val = data[offset]
        offset += 1
        return val
    }

    private static func readUInt16LE(_ data: Data, offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw ATVError.invalidData("OPACK: unexpected end of data reading uint16")
        }
        let val = data.loadLittleEndian(at: offset, as: UInt16.self)
        offset += 2
        return val
    }

    private static func readUInt32LE(_ data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw ATVError.invalidData("OPACK: unexpected end of data reading uint32")
        }
        let val = data.loadLittleEndian(at: offset, as: UInt32.self)
        offset += 4
        return val
    }

    private static func readUInt64LE(_ data: Data, offset: inout Int) throws -> UInt64 {
        guard offset + 8 <= data.count else {
            throw ATVError.invalidData("OPACK: unexpected end of data reading uint64")
        }
        let val = data.loadLittleEndian(at: offset, as: UInt64.self)
        offset += 8
        return val
    }

    private static func readString(_ data: Data, offset: inout Int, length: Int) throws -> Value {
        guard offset + length <= data.count else {
            throw ATVError.invalidData("OPACK: not enough data for string of length \(length)")
        }
        guard let str = String(data: data[offset..<offset + length], encoding: .utf8) else {
            throw ATVError.invalidData("OPACK: invalid UTF-8 string")
        }
        offset += length
        return .string(str)
    }

    private static func readData(_ data: Data, offset: inout Int, length: Int) throws -> Value {
        guard offset + length <= data.count else {
            throw ATVError.invalidData("OPACK: not enough data for blob of length \(length)")
        }
        let d = Data(data[offset..<offset + length])
        offset += length
        return .data(d)
    }
}

// MARK: - Data Extension for Little-Endian Loading

extension Data {
    func loadLittleEndian<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        var value: T = 0
        let size = MemoryLayout<T>.size
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest, from: offset..<offset + size)
        }
        return T(littleEndian: value)
    }
}

// MARK: - Convenience Builders

extension OPACK.Value {
    /// Build a dict from string-keyed pairs.
    public static func dictionary(_ pairs: [(String, OPACK.Value)]) -> OPACK.Value {
        .dict(pairs.map { (.string($0.0), $0.1) })
    }
}
