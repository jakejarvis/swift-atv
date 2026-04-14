import XCTest

@testable import SwiftATV

/// Tests for HAP credentials and hex utilities.
final class HAPCredentialsTests: XCTestCase {

    // MARK: - Hex encoding/decoding

    func testHexEncodedString() {
        XCTAssertEqual(Data().hexEncodedString(), "")
        XCTAssertEqual(Data([0xDE, 0xAD, 0xBE, 0xEF]).hexEncodedString(), "deadbeef")
        XCTAssertEqual(Data([0x00, 0x01, 0xFF]).hexEncodedString(), "0001ff")
    }

    func testDataFromHexString() throws {
        let data = try Data(hexString: "deadbeef")
        XCTAssertEqual(data, Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let empty = try Data(hexString: "")
        XCTAssertEqual(empty, Data())

        let zeros = try Data(hexString: "0001ff")
        XCTAssertEqual(zeros, Data([0x00, 0x01, 0xFF]))
    }

    func testDataFromHexStringBadLength() {
        XCTAssertThrowsError(try Data(hexString: "abc"))
    }

    func testDataFromHexStringBadChars() {
        XCTAssertThrowsError(try Data(hexString: "gggg"))
    }

    // MARK: - Serialize/Parse round-trip

    func testSerializeAndParse4Component() throws {
        let creds = HAPCredentials(
            ltpk: Data([0x01, 0x02, 0x03]),
            ltsk: Data([0x04, 0x05, 0x06]),
            atvIdentifier: Data([0x07, 0x08]),
            clientIdentifier: Data([0x09, 0x0A])
        )

        let serialized = creds.serialize()
        XCTAssertEqual(serialized, "010203:040506:0708:090a")

        let parsed = try HAPCredentials.parse(serialized)
        XCTAssertEqual(parsed.ltpk, creds.ltpk)
        XCTAssertEqual(parsed.ltsk, creds.ltsk)
        XCTAssertEqual(parsed.atvIdentifier, creds.atvIdentifier)
        XCTAssertEqual(parsed.clientIdentifier, creds.clientIdentifier)
    }

    func testSerializeAndParse2Component() throws {
        // Legacy pyatv format: clientIdentifier:ltsk.
        let serialized = "aabbcc:ddeeff"
        let parsed = try HAPCredentials.parse(serialized)

        XCTAssertEqual(parsed.ltpk, Data())
        XCTAssertEqual(parsed.ltsk, Data([0xDD, 0xEE, 0xFF]))
        XCTAssertEqual(parsed.atvIdentifier, Data())
        XCTAssertEqual(parsed.clientIdentifier, Data([0xAA, 0xBB, 0xCC]))
    }

    func testParseBadComponentCount() {
        XCTAssertThrowsError(try HAPCredentials.parse("abc"))
        XCTAssertThrowsError(try HAPCredentials.parse("a:b:c"))
        XCTAssertThrowsError(try HAPCredentials.parse("a:b:c:d:e"))
    }

    // MARK: - Sentinel values

    func testNoCredentials() {
        let none = HAPCredentials.none
        XCTAssertEqual(none.ltpk, Data())
        XCTAssertEqual(none.ltsk, Data())
    }

    func testTransientCredentials() {
        let transient = HAPCredentials.transient
        XCTAssertEqual(transient.ltpk, Data("transient".utf8))
        XCTAssertEqual(transient.ltsk, Data())
        XCTAssertEqual(transient.atvIdentifier, Data())
        XCTAssertEqual(transient.clientIdentifier, Data())
    }

    // MARK: - Codable

    func testCredentialsCodable() throws {
        let creds = HAPCredentials(
            ltpk: Data([0x01, 0x02]),
            ltsk: Data([0x03, 0x04]),
            atvIdentifier: Data([0x05]),
            clientIdentifier: Data([0x06])
        )

        let data = try JSONEncoder().encode(creds)
        let decoded = try JSONDecoder().decode(HAPCredentials.self, from: data)

        XCTAssertEqual(decoded.ltpk, creds.ltpk)
        XCTAssertEqual(decoded.ltsk, creds.ltsk)
        XCTAssertEqual(decoded.atvIdentifier, creds.atvIdentifier)
        XCTAssertEqual(decoded.clientIdentifier, creds.clientIdentifier)
    }

    // MARK: - Description

    func testCredentialsDescription() {
        let creds = HAPCredentials(
            ltpk: Data(repeating: 0, count: 32),
            ltsk: Data(repeating: 0, count: 64),
            atvIdentifier: Data(),
            clientIdentifier: Data()
        )
        let desc = creds.description
        XCTAssertTrue(desc.contains("32B"))
        XCTAssertTrue(desc.contains("64B"))
    }
}
