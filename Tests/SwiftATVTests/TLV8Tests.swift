import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/auth/test_hap_tlv8.py
final class TLV8Tests: XCTestCase {

    // MARK: - Write (encode) tests

    func testWriteSingleKey() {
        // {10: b"123"} -> b"\x0a\x03\x31\x32\x33"
        let entries = [TLV8.Entry(tag: 10, data: Data("123".utf8))]
        let encoded = TLV8.encode(entries)
        XCTAssertEqual(encoded, Data([0x0A, 0x03, 0x31, 0x32, 0x33]))
    }

    func testWriteTwoKeys() {
        // OrderedDict([(1, b"111"), (4, b"222")])
        let entries = [
            TLV8.Entry(tag: 1, data: Data("111".utf8)),
            TLV8.Entry(tag: 4, data: Data("222".utf8)),
        ]
        let encoded = TLV8.encode(entries)
        XCTAssertEqual(encoded, Data([
            0x01, 0x03, 0x31, 0x31, 0x31,
            0x04, 0x03, 0x32, 0x32, 0x32,
        ]))
    }

    func testWriteKeyLargerThan255Bytes() {
        // {2: b"\x31" * 256} -> b"\x02\xff" + b"\x31" * 255 + b"\x02\x01\x31"
        let data = Data(repeating: 0x31, count: 256)
        let entries = [TLV8.Entry(tag: 2, data: data)]
        let encoded = TLV8.encode(entries)

        var expected = Data([0x02, 0xFF])
        expected.append(Data(repeating: 0x31, count: 255))
        expected.append(Data([0x02, 0x01, 0x31]))

        XCTAssertEqual(encoded, expected)
    }

    // MARK: - Read (decode) tests

    func testReadSingleKey() {
        let data = Data([0x0A, 0x03, 0x31, 0x32, 0x33])
        let decoded = TLV8.decode(data)
        XCTAssertEqual(decoded[10], Data("123".utf8))
    }

    func testReadTwoKeys() {
        let data = Data([
            0x01, 0x03, 0x31, 0x31, 0x31,
            0x04, 0x03, 0x32, 0x32, 0x32,
        ])
        let decoded = TLV8.decode(data)
        XCTAssertEqual(decoded[1], Data("111".utf8))
        XCTAssertEqual(decoded[4], Data("222".utf8))
    }

    func testReadKeyLargerThan255Bytes() {
        var data = Data([0x02, 0xFF])
        data.append(Data(repeating: 0x31, count: 255))
        data.append(Data([0x02, 0x01, 0x31]))

        let decoded = TLV8.decode(data)
        XCTAssertEqual(decoded[2]?.count, 256)
        XCTAssertEqual(decoded[2], Data(repeating: 0x31, count: 256))
    }

    // MARK: - Round-trip tests

    func testRoundTripSimple() {
        let entries = [
            TLV8.Entry(tag: .state, value: 1),
            TLV8.Entry(tag: .method, value: 0),
        ]
        let encoded = TLV8.encode(entries)
        let decoded = TLV8.decode(encoded)

        XCTAssertEqual(decoded[TLVTag.state.rawValue], Data([1]))
        XCTAssertEqual(decoded[TLVTag.method.rawValue], Data([0]))
    }

    func testRoundTripLargeValue() {
        let largeData = Data(repeating: 0xAB, count: 300)
        let entries = [TLV8.Entry(tag: .publicKey, data: largeData)]
        let encoded = TLV8.encode(entries)
        let decoded = TLV8.decode(encoded)

        XCTAssertEqual(decoded[TLVTag.publicKey.rawValue]?.count, 300)
        XCTAssertEqual(decoded[TLVTag.publicKey.rawValue], largeData)
    }

    func testRoundTripMultipleEntries() {
        let entries = [
            TLV8.Entry(tag: .state, value: 3),
            TLV8.Entry(tag: .identifier, data: Data("test-id".utf8)),
            TLV8.Entry(tag: .signature, data: Data(repeating: 0xFF, count: 64)),
        ]
        let encoded = TLV8.encode(entries)
        let decoded = TLV8.decode(encoded)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[TLVTag.state.rawValue], Data([3]))
        XCTAssertEqual(decoded[TLVTag.identifier.rawValue], Data("test-id".utf8))
        XCTAssertEqual(decoded[TLVTag.signature.rawValue]?.count, 64)
    }

    // MARK: - Decode entries ordered

    func testDecodeEntries() {
        let entries = [
            TLV8.Entry(tag: .state, value: 1),
            TLV8.Entry(tag: .method, value: 2),
            TLV8.Entry(tag: .error, value: 5),
        ]
        let encoded = TLV8.encode(entries)
        let decoded = TLV8.decodeEntries(encoded)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].tag, TLVTag.state.rawValue)
        XCTAssertEqual(decoded[0].data, Data([1]))
        XCTAssertEqual(decoded[1].tag, TLVTag.method.rawValue)
        XCTAssertEqual(decoded[1].data, Data([2]))
        XCTAssertEqual(decoded[2].tag, TLVTag.error.rawValue)
        XCTAssertEqual(decoded[2].data, Data([5]))
    }

    func testDecodeEntriesReassembly() {
        // Manually create chunked data: tag 0x03 with 300 bytes
        let fullData = Data(repeating: 0xBB, count: 300)
        var encoded = Data()
        // Chunk 1: 255 bytes
        encoded.append(0x03)
        encoded.append(0xFF)
        encoded.append(fullData[0..<255])
        // Chunk 2: 45 bytes
        encoded.append(0x03)
        encoded.append(45)
        encoded.append(fullData[255..<300])

        let decoded = TLV8.decodeEntries(encoded)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].data.count, 300)
        XCTAssertEqual(decoded[0].data, fullData)
    }

    // MARK: - Empty data

    func testEncodeEmptyData() {
        let entries = [TLV8.Entry(tag: .state, data: Data())]
        let encoded = TLV8.encode(entries)
        XCTAssertEqual(encoded, Data([TLVTag.state.rawValue, 0x00]))
    }

    func testDecodeEmptyData() {
        let decoded = TLV8.decode(Data())
        XCTAssertTrue(decoded.isEmpty)
    }
}
