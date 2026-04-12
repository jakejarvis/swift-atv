import XCTest

@testable import SwiftATV

/// Ported from pyatv tests/support/test_opack.py
final class OPACKTests: XCTestCase {

    // MARK: - Primitives

    func testEncodeDecodeNull() throws {
        let encoded = OPACK.encode(.null)
        XCTAssertEqual(encoded, Data([0x04]))
        let decoded = try OPACK.decode(encoded)
        if case .null = decoded {} else { XCTFail("Expected null") }
    }

    func testEncodeDecodeTrue() throws {
        let encoded = OPACK.encode(.bool(true))
        XCTAssertEqual(encoded, Data([0x01]))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.boolValue, true)
    }

    func testEncodeDecodeFalse() throws {
        let encoded = OPACK.encode(.bool(false))
        XCTAssertEqual(encoded, Data([0x02]))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.boolValue, false)
    }

    // MARK: - Integers (inline: 0-39)

    func testEncodeInlineIntegers() throws {
        for i: UInt64 in 0...39 {
            let encoded = OPACK.encode(.uint(i))
            XCTAssertEqual(encoded.count, 1, "Inline int \(i) should be 1 byte")
            XCTAssertEqual(encoded[0], 0x08 + UInt8(i))

            let decoded = try OPACK.decode(encoded)
            XCTAssertEqual(decoded.intValue, Int64(i), "Failed for inline int \(i)")
        }
    }

    // MARK: - Integers (extended)

    func testEncodeUInt8() throws {
        let encoded = OPACK.encode(.uint(40))
        XCTAssertEqual(encoded[0], 0x30)  // int8 tag
        XCTAssertEqual(encoded[1], 40)
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, 40)
    }

    func testEncodeUInt8Max() throws {
        let encoded = OPACK.encode(.uint(255))
        XCTAssertEqual(encoded[0], 0x30)
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, 255)
    }

    func testEncodeUInt16() throws {
        let encoded = OPACK.encode(.uint(256))
        XCTAssertEqual(encoded[0], 0x31)  // int16 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, 256)
    }

    func testEncodeUInt16Max() throws {
        let encoded = OPACK.encode(.uint(65535))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, 65535)
    }

    func testEncodeUInt32() throws {
        let encoded = OPACK.encode(.uint(65536))
        XCTAssertEqual(encoded[0], 0x32)  // int32 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, 65536)
    }

    func testEncodeUInt64() throws {
        let big: UInt64 = 0x1_0000_0000
        let encoded = OPACK.encode(.uint(big))
        XCTAssertEqual(encoded[0], 0x33)  // int64 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, Int64(big))
    }

    // MARK: - Negative integers

    func testEncodeNegativeInt8() throws {
        let encoded = OPACK.encode(.int(-1))
        XCTAssertEqual(encoded[0], 0x38)  // neg int8 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, -1)
    }

    func testEncodeNegativeInt42() throws {
        let encoded = OPACK.encode(.int(-42))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, -42)
    }

    func testEncodeNegativeInt16() throws {
        let encoded = OPACK.encode(.int(-256))
        XCTAssertEqual(encoded[0], 0x39)  // neg int16 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, -256)
    }

    func testEncodeNegativeInt32() throws {
        let encoded = OPACK.encode(.int(-100000))
        XCTAssertEqual(encoded[0], 0x3A)  // neg int32 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, -100000)
    }

    func testEncodeNegativeInt64Min() throws {
        let encoded = OPACK.encode(.int(Int64.min))
        XCTAssertEqual(encoded[0], 0x3B)  // neg int64 tag

        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, Int64.min)
    }

    // MARK: - Floats

    func testEncodeDecodeFloat32() throws {
        let encoded = OPACK.encode(.float(3.14))
        XCTAssertEqual(encoded[0], 0x35)  // float32 tag
        let decoded = try OPACK.decode(encoded)
        if case .float(let v) = decoded {
            XCTAssertEqual(v, 3.14, accuracy: 0.01)
        } else {
            XCTFail("Expected float")
        }
    }

    func testEncodeDecodeFloat64() throws {
        let encoded = OPACK.encode(.double(3.14159265358979))
        XCTAssertEqual(encoded[0], 0x36)  // float64 tag
        let decoded = try OPACK.decode(encoded)
        if case .double(let v) = decoded {
            XCTAssertEqual(v, 3.14159265358979, accuracy: 0.0000001)
        } else {
            XCTFail("Expected double")
        }
    }

    // MARK: - Strings

    func testEncodeEmptyString() throws {
        let encoded = OPACK.encode(.string(""))
        XCTAssertEqual(encoded, Data([0x40]))  // inline string, length 0
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.stringValue, "")
    }

    func testEncodeShortString() throws {
        let encoded = OPACK.encode(.string("hello"))
        XCTAssertEqual(encoded[0], 0x40 + 5)  // inline, length 5
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testEncodeString32Bytes() throws {
        let s = String(repeating: "a", count: 32)
        let encoded = OPACK.encode(.string(s))
        XCTAssertEqual(encoded[0], 0x40 + 32)  // inline, length 32
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testEncodeString33Bytes() throws {
        let s = String(repeating: "b", count: 33)
        let encoded = OPACK.encode(.string(s))
        XCTAssertEqual(encoded[0], 0x61)  // string8 tag (extended)
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testEncodeLongString() throws {
        let s = String(repeating: "x", count: 300)
        let encoded = OPACK.encode(.string(s))
        XCTAssertEqual(encoded[0], 0x62)  // string16 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.stringValue, s)
    }

    func testEncodeUTF8String() throws {
        let s = "Hello 🌍"
        let encoded = OPACK.encode(.string(s))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.stringValue, s)
    }

    // MARK: - Data

    func testEncodeEmptyData() throws {
        let encoded = OPACK.encode(.data(Data()))
        XCTAssertEqual(encoded, Data([0x70]))  // inline data, length 0
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.dataValue, Data())
    }

    func testEncodeShortData() throws {
        let d = Data([0x01, 0x02, 0x03])
        let encoded = OPACK.encode(.data(d))
        XCTAssertEqual(encoded[0], 0x70 + 3)
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.dataValue, d)
    }

    func testEncodeData32Bytes() throws {
        let d = Data(repeating: 0xAB, count: 32)
        let encoded = OPACK.encode(.data(d))
        XCTAssertEqual(encoded[0], 0x70 + 32)
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.dataValue, d)
    }

    func testEncodeData33Bytes() throws {
        let d = Data(repeating: 0xCD, count: 33)
        let encoded = OPACK.encode(.data(d))
        XCTAssertEqual(encoded[0], 0x91)  // data8 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.dataValue, d)
    }

    func testEncodeLargeData() throws {
        let d = Data(repeating: 0xEF, count: 300)
        let encoded = OPACK.encode(.data(d))
        XCTAssertEqual(encoded[0], 0x92)  // data16 tag
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.dataValue, d)
    }

    // MARK: - UUID

    func testEncodeDecodeUUID() throws {
        let uuid = UUID()
        let encoded = OPACK.encode(.uuid(uuid))
        XCTAssertEqual(encoded[0], 0x05)  // UUID tag
        XCTAssertEqual(encoded.count, 17)  // 1 tag + 16 bytes
        let decoded = try OPACK.decode(encoded)
        if case .uuid(let decodedUUID) = decoded {
            XCTAssertEqual(decodedUUID, uuid)
        } else {
            XCTFail("Expected UUID")
        }
    }

    // MARK: - Arrays

    func testEncodeEmptyArray() throws {
        let encoded = OPACK.encode(.array([]))
        XCTAssertEqual(encoded, Data([0xD0]))  // fixed list, 0 items
        let decoded = try OPACK.decode(encoded)
        if case .array(let arr) = decoded {
            XCTAssertEqual(arr.count, 0)
        } else {
            XCTFail("Expected array")
        }
    }

    func testEncodeSmallArray() throws {
        let arr: OPACK.Value = .array([.uint(1), .string("two"), .bool(true)])
        let encoded = OPACK.encode(arr)
        XCTAssertEqual(encoded[0], 0xD3)  // fixed list, 3 items
        let decoded = try OPACK.decode(encoded)

        XCTAssertEqual(decoded[0]?.intValue, 1)
        XCTAssertEqual(decoded[1]?.stringValue, "two")
        XCTAssertEqual(decoded[2]?.boolValue, true)
    }

    func testEncodeArray14Items() throws {
        let items = (0..<14).map { OPACK.Value.uint(UInt64($0)) }
        let encoded = OPACK.encode(.array(items))
        XCTAssertEqual(encoded[0], 0xDE)  // fixed list, 14 items
        let decoded = try OPACK.decode(encoded)
        if case .array(let arr) = decoded {
            XCTAssertEqual(arr.count, 14)
        } else {
            XCTFail("Expected array")
        }
    }

    func testEncodeArray15ItemsEndless() throws {
        let items = (0..<15).map { OPACK.Value.uint(UInt64($0)) }
        let encoded = OPACK.encode(.array(items))
        XCTAssertEqual(encoded[0], 0xDF)  // endless list
        // Last byte should be terminator
        XCTAssertEqual(encoded[encoded.count - 1], 0x03)

        let decoded = try OPACK.decode(encoded)
        if case .array(let arr) = decoded {
            XCTAssertEqual(arr.count, 15)
        } else {
            XCTFail("Expected array")
        }
    }

    // MARK: - Dictionaries

    func testEncodeEmptyDict() throws {
        let encoded = OPACK.encode(.dict([]))
        XCTAssertEqual(encoded, Data([0xE0]))  // fixed dict, 0 pairs
        let decoded = try OPACK.decode(encoded)
        if case .dict(let pairs) = decoded {
            XCTAssertEqual(pairs.count, 0)
        } else {
            XCTFail("Expected dict")
        }
    }

    func testEncodeSmallDict() throws {
        let dict: OPACK.Value = .dictionary([
            ("key1", .uint(42)),
            ("key2", .string("value")),
        ])
        let encoded = OPACK.encode(dict)
        XCTAssertEqual(encoded[0], 0xE2)  // fixed dict, 2 pairs

        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded["key1"]?.intValue, 42)
        XCTAssertEqual(decoded["key2"]?.stringValue, "value")
    }

    func testEncodeDict14Pairs() throws {
        let pairs = (0..<14).map { i -> (String, OPACK.Value) in
            ("k\(i)", .uint(UInt64(i)))
        }
        let encoded = OPACK.encode(.dictionary(pairs))
        XCTAssertEqual(encoded[0], 0xEE)  // fixed dict, 14 pairs
        let decoded = try OPACK.decode(encoded)
        if case .dict(let dp) = decoded {
            XCTAssertEqual(dp.count, 14)
        } else {
            XCTFail("Expected dict")
        }
    }

    func testEncodeDict15PairsEndless() throws {
        let pairs = (0..<15).map { i -> (String, OPACK.Value) in
            ("k\(i)", .uint(UInt64(i)))
        }
        let encoded = OPACK.encode(.dictionary(pairs))
        XCTAssertEqual(encoded[0], 0xEF)  // endless dict
        XCTAssertEqual(encoded[encoded.count - 1], 0x03)  // terminator

        let decoded = try OPACK.decode(encoded)
        if case .dict(let dp) = decoded {
            XCTAssertEqual(dp.count, 15)
        } else {
            XCTFail("Expected dict")
        }
    }

    // MARK: - Nested Structures

    func testNestedArrayInDict() throws {
        let val: OPACK.Value = .dictionary([
            ("list", .array([.uint(1), .uint(2), .uint(3)])),
            ("name", .string("test")),
        ])
        let encoded = OPACK.encode(val)
        let decoded = try OPACK.decode(encoded)

        XCTAssertEqual(decoded["name"]?.stringValue, "test")
        XCTAssertEqual(decoded["list"]?[0]?.intValue, 1)
        XCTAssertEqual(decoded["list"]?[1]?.intValue, 2)
        XCTAssertEqual(decoded["list"]?[2]?.intValue, 3)
    }

    func testNestedDictInArray() throws {
        let inner: OPACK.Value = .dictionary([("a", .uint(1))])
        let val: OPACK.Value = .array([inner, .string("b")])

        let encoded = OPACK.encode(val)
        let decoded = try OPACK.decode(encoded)

        XCTAssertEqual(decoded[0]?["a"]?.intValue, 1)
        XCTAssertEqual(decoded[1]?.stringValue, "b")
    }

    // MARK: - Object references

    func testDecodeInlineObjectReference() throws {
        let data = Data([0xD2, 0x45, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0xA0])
        let decoded = try OPACK.decode(data)

        XCTAssertEqual(decoded[0]?.stringValue, "hello")
        XCTAssertEqual(decoded[1]?.stringValue, "hello")
    }

    func testDecodeExtendedObjectReference() throws {
        var data = Data([0xDF])
        for index in 0..<34 {
            let string = String(format: "v%02d", index)
            let bytes = Array(string.utf8)
            data.append(0x40 + UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(contentsOf: [0xC1, 0x21])
        data.append(0x03)

        let decoded = try OPACK.decode(data)
        XCTAssertEqual(decoded[33]?.stringValue, "v33")
        XCTAssertEqual(decoded[34]?.stringValue, "v33")
    }

    // MARK: - Round-trip complex

    func testRoundTripComplex() throws {
        let value: OPACK.Value = .dictionary([
            ("_i", .string("_systemInfo")),
            ("_t", .uint(2)),
            ("_x", .uint(12345)),
            (
                "_c",
                .dictionary([
                    ("_bf", .uint(0)),
                    ("_cf", .uint(512)),
                    ("model", .string("iPhone14,2")),
                    ("name", .string("SwiftATV")),
                    ("nested", .array([.bool(true), .null, .int(-1)])),
                ])
            ),
        ])

        let encoded = OPACK.encode(value)
        let decoded = try OPACK.decode(encoded)

        XCTAssertEqual(decoded["_i"]?.stringValue, "_systemInfo")
        XCTAssertEqual(decoded["_t"]?.intValue, 2)
        XCTAssertEqual(decoded["_x"]?.intValue, 12345)
        XCTAssertEqual(decoded["_c"]?["_bf"]?.intValue, 0)
        XCTAssertEqual(decoded["_c"]?["model"]?.stringValue, "iPhone14,2")
        XCTAssertEqual(decoded["_c"]?["name"]?.stringValue, "SwiftATV")
        XCTAssertEqual(decoded["_c"]?["nested"]?[0]?.boolValue, true)
        if case .null = decoded["_c"]?["nested"]?[1] {} else { XCTFail("Expected null") }
        XCTAssertEqual(decoded["_c"]?["nested"]?[2]?.intValue, -1)
    }

    // MARK: - Error cases

    func testDecodeEmptyData() {
        XCTAssertThrowsError(try OPACK.decode(Data()))
    }

    func testDecodeUnknownTag() {
        XCTAssertThrowsError(try OPACK.decode(Data([0xFF])))
    }

    func testDecodeTruncatedString() {
        // Tag says 5-byte string but only 3 bytes available
        let data = Data([0x45, 0x41, 0x42, 0x43])
        XCTAssertThrowsError(try OPACK.decode(data))
    }

    func testDecodeTruncatedInt16() {
        // Tag says uint16 but only 1 byte available
        let data = Data([0x31, 0x01])
        XCTAssertThrowsError(try OPACK.decode(data))
    }

    func testDecodeTrailingBytes() {
        XCTAssertThrowsError(try OPACK.decode(Data([0x01, 0x02])))
    }

    func testDecodeMissingEndlessListTerminator() {
        XCTAssertThrowsError(try OPACK.decode(Data([0xDF, 0x01])))
    }

    func testDecodeMissingEndlessDictTerminator() {
        XCTAssertThrowsError(try OPACK.decode(Data([0xEF, 0x41, 0x61, 0x01])))
    }

    func testDecodeNegativeInt64MagnitudeOverflow() {
        let data = Data([0x3B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try OPACK.decode(data))
    }

    func testDecodeData64LengthOverflow() {
        let data = Data([0x94, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try OPACK.decode(data))
    }
}
