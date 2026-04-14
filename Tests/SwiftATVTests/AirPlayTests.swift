import Foundation
import Testing

@testable import SwiftATV

@Suite("AirPlay support")
struct AirPlaySupportTests {
    @Test("AirPlay split feature strings parse upper and lower words")
    func parseSplitFeatureString() throws {
        let flags = try AirPlayFeatureFlags.parse("0x0,0x40")
        #expect(flags.contains(.supportsUnifiedMediaControl))
    }

    @Test("AirPlay pairing requirement uses status flags, not password flag")
    func pairingRequirementUsesStatusFlags() {
        #expect(AirPlaySupport.pairingRequirement(from: ["sf": "0x208"]) == .mandatory)
        #expect(AirPlaySupport.pairingRequirement(from: ["pw": "true"]) == .notNeeded)
        #expect(AirPlaySupport.pairingRequirement(from: ["acl": "1"]) == .disabled)
        #expect(AirPlaySupport.pairingRequirement(from: ["act": "2"]) == .unsupported)
    }

    @Test("AirPlay auto tunnel requires AirPlay 2 Apple TV with credentials")
    func remoteControlHeuristic() throws {
        let service = ServiceInfo(
            protocol: .airPlay,
            port: 7000,
            properties: ["features": "0x0,0x40", "model": "AppleTV11,1", "osvers": "16.0"]
        )
        let credentials = try HAPCredentials.parse("01:02:03:04")
        #expect(
            AirPlaySupport.supportsRemoteControlTunnel(
                service: service,
                credentials: credentials,
                settings: ATVSettings()
            )
        )
        #expect(
            !AirPlaySupport.supportsRemoteControlTunnel(
                service: service,
                credentials: nil,
                settings: ATVSettings()
            )
        )
    }

    @Test("AirPlay pairing handler can be created with forced AirPlay 2 settings")
    func airPlayPairingHandlerCreation() async throws {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .airPlay, port: 7000, pairingRequirement: .notNeeded))
        var settings = ATVSettings()
        settings.protocols.airplay.airPlayVersion = .v2

        let handler = try await ATVClient.pair(config, protocol: .airPlay, settings: settings)

        #expect(handler.service.protocol == .airPlay)
        await handler.close()
    }
}

@Suite("AirPlay HTTP parser")
struct AirPlayHTTPParserTests {
    @Test("Response parser rejects negative Content-Length")
    func responseRejectsNegativeContentLength() {
        var buffer = Data("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n".utf8)

        #expect(throws: ATVError.self) {
            _ = try AirPlayHTTPParser.parseResponse(from: &buffer)
        }
    }

    @Test("Request parser rejects invalid Content-Length")
    func requestRejectsInvalidContentLength() {
        var buffer = Data("POST /event HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)

        #expect(throws: ATVError.self) {
            _ = try AirPlayHTTPParser.parseRequest(from: &buffer)
        }
    }
}

@Suite("AirPlay HAP session")
struct AirPlayHAPSessionTests {
    @Test("HAP session encrypts, chunks, and decrypts partial input")
    func encryptDecryptPartialInput() throws {
        let clientWriteKey = Data(repeating: 0x11, count: 32)
        let serverWriteKey = Data(repeating: 0x22, count: 32)
        let client = HAPSession(outputKey: clientWriteKey, inputKey: serverWriteKey)
        let server = HAPSession(outputKey: serverWriteKey, inputKey: clientWriteKey)
        let plaintext = Data((0..<2500).map { UInt8($0 % 251) })

        let encrypted = try client.encrypt(plaintext)
        #expect(encrypted.count == plaintext.count + (3 * (2 + 16)))

        let split = encrypted.index(encrypted.startIndex, offsetBy: 700)
        #expect(try server.decrypt(Data(encrypted[..<split])).isEmpty)
        let decrypted = try server.decrypt(Data(encrypted[split...]))
        #expect(decrypted == plaintext)
    }

    @Test("HAP session rejects bad authentication tag")
    func rejectsBadTag() throws {
        let keyA = Data(repeating: 0x11, count: 32)
        let keyB = Data(repeating: 0x22, count: 32)
        let client = HAPSession(outputKey: keyA, inputKey: keyB)
        let server = HAPSession(outputKey: keyB, inputKey: keyA)
        var encrypted = try client.encrypt(Data("hello".utf8))
        encrypted[encrypted.count - 1] ^= 0xFF

        #expect(throws: ATVError.self) {
            _ = try server.decrypt(encrypted)
        }
    }
}

@Suite("AirPlay data stream")
struct AirPlayDataStreamTests {
    @Test("Data stream extracts varint-prefixed protobuf payload")
    func extractsVarintPrefixedProtobuf() throws {
        let message = MRPMessages.generic()
        let serialized = try message.serializedData()
        let dataField = MRPVarint.encode(serialized.count) + serialized
        let payload = try binaryPlist(["params": ["data": dataField]])

        let messages = try AirPlayDataStreamChannel.messages(fromPayload: payload)

        #expect(messages.count == 1)
        #expect(messages[0].type == .genericMessage)
    }

    @Test("Data stream accepts bare protobuf payload")
    func acceptsBareProtobuf() throws {
        let message = MRPMessages.generic()
        let serialized = try message.serializedData()

        let messages = try AirPlayDataStreamChannel.messages(fromDataField: serialized)

        #expect(messages.count == 1)
        #expect(messages[0].type == .genericMessage)
    }

    @Test("Data stream frame builder writes big-endian header")
    func frameBuilderHeader() {
        let payload = Data([0xAA, 0xBB])
        let frame = AirPlayDataStreamChannel.buildFrame(
            type: Data("sync".utf8),
            command: Data("comm".utf8),
            sequenceNumber: 0x0102_0304_0506_0708,
            payload: payload
        )

        #expect(frame.count == 34)
        #expect(Array(frame[0..<4]) == [0, 0, 0, 34])
        #expect(Data(frame[4..<8]) == Data("sync".utf8))
        #expect(Data(frame[16..<20]) == Data("comm".utf8))
        #expect(Array(frame[20..<28]) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(Data(frame[32..<34]) == payload)
    }

    private func binaryPlist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }
}
