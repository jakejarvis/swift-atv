import XCTest
@testable import SwiftATV

final class ConstantsTests: XCTestCase {
    func testProtocolRawValues() {
        XCTAssertEqual(ATVProtocol.dmap.rawValue, 1)
        XCTAssertEqual(ATVProtocol.mrp.rawValue, 2)
        XCTAssertEqual(ATVProtocol.airPlay.rawValue, 3)
        XCTAssertEqual(ATVProtocol.companion.rawValue, 4)
        XCTAssertEqual(ATVProtocol.raop.rawValue, 5)
    }

    func testDeviceStateRawValues() {
        XCTAssertEqual(DeviceState.idle.rawValue, 0)
        XCTAssertEqual(DeviceState.loading.rawValue, 1)
        XCTAssertEqual(DeviceState.paused.rawValue, 2)
        XCTAssertEqual(DeviceState.playing.rawValue, 3)
        XCTAssertEqual(DeviceState.stopped.rawValue, 4)
        XCTAssertEqual(DeviceState.seeking.rawValue, 5)
    }

    func testFeatureNameRawValues() {
        XCTAssertEqual(FeatureName.up.rawValue, 0)
        XCTAssertEqual(FeatureName.setPosition.rawValue, 19)
        XCTAssertEqual(FeatureName.setShuffle.rawValue, 20)
        XCTAssertEqual(FeatureName.setRepeat.rawValue, 21)
        XCTAssertEqual(FeatureName.title.rawValue, 22)
        XCTAssertEqual(FeatureName.artwork.rawValue, 30)
        XCTAssertEqual(FeatureName.skipForward.rawValue, 36)
        XCTAssertEqual(FeatureName.appList.rawValue, 38)
        XCTAssertEqual(FeatureName.pushUpdates.rawValue, 43)
        XCTAssertEqual(FeatureName.volume.rawValue, 45)
        XCTAssertEqual(FeatureName.contentIdentifier.rawValue, 47)
        XCTAssertEqual(FeatureName.textGet.rawValue, 51)
        XCTAssertEqual(FeatureName.accountList.rawValue, 55)
        XCTAssertEqual(FeatureName.outputDevices.rawValue, 59)
        XCTAssertEqual(FeatureName.swipe.rawValue, 63)
        XCTAssertEqual(FeatureName.guide.rawValue, 66)
        XCTAssertEqual(FeatureName.controlCenter.rawValue, 68)
    }

    func testPairingRequirementRawValues() {
        XCTAssertEqual(PairingRequirement.unsupported.rawValue, 1)
        XCTAssertEqual(PairingRequirement.disabled.rawValue, 2)
        XCTAssertEqual(PairingRequirement.mandatory.rawValue, 5)
    }

    func testTouchActionRawValues() {
        XCTAssertEqual(TouchAction.press.rawValue, 1)
        XCTAssertEqual(TouchAction.hold.rawValue, 3)
        XCTAssertEqual(TouchAction.release.rawValue, 4)
        XCTAssertEqual(TouchAction.click.rawValue, 5)
    }

    func testProtocolDescription() {
        XCTAssertEqual(ATVProtocol.mrp.description, "MRP")
        XCTAssertEqual(ATVProtocol.companion.description, "Companion")
    }

    func testDeviceModelDescription() {
        XCTAssertEqual(DeviceModel.gen4K.description, "Apple TV 4K")
        XCTAssertEqual(DeviceModel.homePodMini.description, "HomePod Mini")
    }

    func testFeatureNameAllCases() {
        // Verify we have all expected features
        XCTAssertTrue(FeatureName.allCases.count >= 60)
    }
}

final class ConfigurationTests: XCTestCase {
    func testServiceInfoCreation() {
        let service = ServiceInfo(
            protocol: .companion,
            port: 49153,
            identifier: "test-id"
        )
        XCTAssertEqual(service.protocol, .companion)
        XCTAssertEqual(service.port, 49153)
        XCTAssertEqual(service.identifier, "test-id")
        XCTAssertTrue(service.enabled)
    }

    func testAppleTVConfigurationAddService() {
        var config = AppleTVConfiguration(
            address: "192.168.1.100",
            name: "Living Room"
        )
        XCTAssertTrue(config.services.isEmpty)

        let mrpService = ServiceInfo(protocol: .mrp, port: 49152)
        config.addService(mrpService)
        XCTAssertEqual(config.services.count, 1)

        let companionService = ServiceInfo(protocol: .companion, port: 49153)
        config.addService(companionService)
        XCTAssertEqual(config.services.count, 2)

        // Adding same protocol should merge
        let updatedMRP = ServiceInfo(protocol: .mrp, port: 49152, identifier: "new-id")
        config.addService(updatedMRP)
        XCTAssertEqual(config.services.count, 2)
        XCTAssertEqual(config.service(for: .mrp)?.identifier, "new-id")
    }

    func testDeviceInfoLookup() {
        let model = DeviceInfo.lookupModel(identifier: "AppleTV6,2")
        XCTAssertEqual(model, .gen4K)

        let model2 = DeviceInfo.lookupModel(identifier: "AudioAccessory5,1")
        XCTAssertEqual(model2, .homePodMini)

        let unknown = DeviceInfo.lookupModel(identifier: "Unknown123")
        XCTAssertEqual(unknown, .unknown)
    }

    func testDeviceInfoFromProperties() {
        let props = [
            "model": "AppleTV11,1",
            "OSName": "tvOS",
            "osvers": "16.0",
        ]
        let info = DeviceInfo.fromProperties(props)
        XCTAssertEqual(info.model, .gen4K2)
        XCTAssertEqual(info.operatingSystem, .tvOS)
        XCTAssertEqual(info.version, "16.0")
    }
}

final class OPACKTests: XCTestCase {
    func testEncodeDecodeNull() throws {
        let encoded = OPACK.encode(.null)
        let decoded = try OPACK.decode(encoded)
        if case .null = decoded {} else { XCTFail("Expected null") }
    }

    func testEncodeDecodeBool() throws {
        let trueEncoded = OPACK.encode(.bool(true))
        let trueDecoded = try OPACK.decode(trueEncoded)
        XCTAssertEqual(trueDecoded.boolValue, true)

        let falseEncoded = OPACK.encode(.bool(false))
        let falseDecoded = try OPACK.decode(falseEncoded)
        XCTAssertEqual(falseDecoded.boolValue, false)
    }

    func testEncodeDecodeInlineInt() throws {
        // Inline integers: 0-39
        for i: UInt64 in [0, 1, 10, 39] {
            let encoded = OPACK.encode(.uint(i))
            let decoded = try OPACK.decode(encoded)
            XCTAssertEqual(decoded.intValue, Int64(i), "Failed for inline int \(i)")
        }
    }

    func testEncodeDecodeExtendedInt() throws {
        let testValues: [UInt64] = [40, 255, 256, 65535, 65536, 1_000_000]
        for v in testValues {
            let encoded = OPACK.encode(.uint(v))
            let decoded = try OPACK.decode(encoded)
            XCTAssertEqual(decoded.intValue, Int64(v), "Failed for int \(v)")
        }
    }

    func testEncodeDecodeNegativeInt() throws {
        let encoded = OPACK.encode(.int(-42))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.intValue, -42)
    }

    func testEncodeDecodeString() throws {
        let shortStr = "hello"
        let encoded1 = OPACK.encode(.string(shortStr))
        let decoded1 = try OPACK.decode(encoded1)
        XCTAssertEqual(decoded1.stringValue, shortStr)

        let longStr = String(repeating: "x", count: 100)
        let encoded2 = OPACK.encode(.string(longStr))
        let decoded2 = try OPACK.decode(encoded2)
        XCTAssertEqual(decoded2.stringValue, longStr)
    }

    func testEncodeDecodeData() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = OPACK.encode(.data(data))
        let decoded = try OPACK.decode(encoded)
        XCTAssertEqual(decoded.dataValue, data)
    }

    func testEncodeDecodeArray() throws {
        let arr: OPACK.Value = .array([.uint(1), .string("two"), .bool(true)])
        let encoded = OPACK.encode(arr)
        let decoded = try OPACK.decode(encoded)

        XCTAssertEqual(decoded[0]?.intValue, 1)
        XCTAssertEqual(decoded[1]?.stringValue, "two")
        XCTAssertEqual(decoded[2]?.boolValue, true)
    }

    func testEncodeDecodeDict() throws {
        let dict: OPACK.Value = .dictionary([
            ("key1", .uint(42)),
            ("key2", .string("value")),
        ])
        let encoded = OPACK.encode(dict)
        let decoded = try OPACK.decode(encoded)

        XCTAssertEqual(decoded["key1"]?.intValue, 42)
        XCTAssertEqual(decoded["key2"]?.stringValue, "value")
    }

    func testEncodeDecodeUUID() throws {
        let uuid = UUID()
        let encoded = OPACK.encode(.uuid(uuid))
        let decoded = try OPACK.decode(encoded)
        if case .uuid(let decodedUUID) = decoded {
            XCTAssertEqual(decodedUUID, uuid)
        } else {
            XCTFail("Expected UUID")
        }
    }

    func testEncodeDecodeFloat() throws {
        let encoded = OPACK.encode(.float(3.14))
        let decoded = try OPACK.decode(encoded)
        if case .float(let v) = decoded {
            XCTAssertEqual(v, 3.14, accuracy: 0.01)
        } else {
            XCTFail("Expected float")
        }
    }

    func testEncodeDecodeDouble() throws {
        let encoded = OPACK.encode(.double(3.14159265))
        let decoded = try OPACK.decode(encoded)
        if case .double(let v) = decoded {
            XCTAssertEqual(v, 3.14159265, accuracy: 0.0001)
        } else {
            XCTFail("Expected double")
        }
    }
}

final class TLV8Tests: XCTestCase {
    func testEncodeDecodeSimple() {
        let entries = [
            TLV8.Entry(tag: .state, value: 1),
            TLV8.Entry(tag: .method, value: 0),
        ]
        let encoded = TLV8.encode(entries)
        let decoded = TLV8.decode(encoded)

        XCTAssertEqual(decoded[TLVTag.state.rawValue], Data([1]))
        XCTAssertEqual(decoded[TLVTag.method.rawValue], Data([0]))
    }

    func testEncodeDecodeLargeValue() {
        // Value larger than 255 bytes should be split into chunks
        let largeData = Data(repeating: 0xAB, count: 300)
        let entries = [TLV8.Entry(tag: .publicKey, data: largeData)]
        let encoded = TLV8.encode(entries)
        let decoded = TLV8.decode(encoded)

        XCTAssertEqual(decoded[TLVTag.publicKey.rawValue]?.count, 300)
        XCTAssertEqual(decoded[TLVTag.publicKey.rawValue], largeData)
    }

    func testEncodeDecodeMultipleEntries() {
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
}

final class HAPCredentialsTests: XCTestCase {
    func testSerializeAndParse() throws {
        let creds = HAPCredentials(
            ltpk: Data([0x01, 0x02, 0x03]),
            ltsk: Data([0x04, 0x05, 0x06]),
            atvIdentifier: Data([0x07, 0x08]),
            clientIdentifier: Data([0x09, 0x0A])
        )

        let serialized = creds.serialize()
        let parsed = try HAPCredentials.parse(serialized)

        XCTAssertEqual(parsed.ltpk, creds.ltpk)
        XCTAssertEqual(parsed.ltsk, creds.ltsk)
        XCTAssertEqual(parsed.atvIdentifier, creds.atvIdentifier)
        XCTAssertEqual(parsed.clientIdentifier, creds.clientIdentifier)
    }

    func testHexConversions() throws {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let hex = data.hexEncodedString()
        XCTAssertEqual(hex, "deadbeef")

        let back = try Data(hexString: hex)
        XCTAssertEqual(back, data)
    }
}

final class RelayerTests: XCTestCase {
    func testRelayerPriority() {
        let relayer = Relayer<String>()

        relayer.register("companion-impl", for: .companion)
        relayer.register("mrp-impl", for: .mrp)

        // MRP has higher priority than Companion
        XCTAssertEqual(relayer.main, "mrp-impl")

        // Can get specific protocol
        XCTAssertEqual(relayer.get(for: .companion), "companion-impl")
    }

    func testRelayerTakeover() {
        let relayer = Relayer<String>()

        relayer.register("mrp-impl", for: .mrp)
        relayer.register("companion-impl", for: .companion)

        XCTAssertEqual(relayer.main, "mrp-impl")

        // Takeover forces companion
        let release = relayer.takeover(.companion)
        XCTAssertEqual(relayer.main, "companion-impl")

        // Release restores priority
        release()
        XCTAssertEqual(relayer.main, "mrp-impl")
    }
}

final class SettingsTests: XCTestCase {
    func testSettingsCodable() throws {
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "test-cred"
        settings.protocols.airplay.airPlayVersion = .v2
        settings.info.name = "My Device"

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ATVSettings.self, from: data)

        XCTAssertEqual(decoded.protocols.companion.credentials, "test-cred")
        XCTAssertEqual(decoded.protocols.airplay.airPlayVersion, .v2)
        XCTAssertEqual(decoded.info.name, "My Device")
    }

    func testCredentialsAccessor() {
        var settings = ATVSettings()
        settings.setCredentials("mrp-cred", for: .mrp)
        settings.setCredentials("comp-cred", for: .companion)

        XCTAssertEqual(settings.credentials(for: .mrp), "mrp-cred")
        XCTAssertEqual(settings.credentials(for: .companion), "comp-cred")
        XCTAssertNil(settings.credentials(for: .dmap))
    }
}

final class PlayingTests: XCTestCase {
    func testPlayingDefaults() {
        let playing = Playing()
        XCTAssertEqual(playing.mediaType, .unknown)
        XCTAssertEqual(playing.deviceState, .idle)
        XCTAssertNil(playing.title)
        XCTAssertNil(playing.artist)
    }

    func testPlayingDescription() {
        let playing = Playing(
            mediaType: .music,
            deviceState: .playing,
            title: "Test Song",
            artist: "Test Artist",
            totalTime: 300,
            position: 120
        )
        let desc = playing.description
        XCTAssertTrue(desc.contains("Playing"))
        XCTAssertTrue(desc.contains("Music"))
        XCTAssertTrue(desc.contains("Test Song"))
    }
}

final class CompanionFeaturesTests: XCTestCase {
    func testSupportedFeatures() {
        let features = CompanionFeatures(isConnected: true)

        XCTAssertEqual(features.featureInfo(.up).state, .available)
        XCTAssertEqual(features.featureInfo(.home).state, .available)
        XCTAssertEqual(features.featureInfo(.appList).state, .available)
        XCTAssertEqual(features.featureInfo(.turnOn).state, .available)
    }

    func testUnsupportedFeatures() {
        let features = CompanionFeatures(isConnected: true)

        // MRP-only features
        XCTAssertEqual(features.featureInfo(.title).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.artist).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.artwork).state, .unsupported)
    }

    func testDisconnectedFeatures() {
        let features = CompanionFeatures(isConnected: false)

        // Supported but unavailable when disconnected
        XCTAssertEqual(features.featureInfo(.up).state, .unavailable)
        XCTAssertEqual(features.featureInfo(.home).state, .unavailable)
    }

    func testIsAvailable() {
        let features = CompanionFeatures(isConnected: true)
        XCTAssertTrue(features.isAvailable(.play))
        XCTAssertFalse(features.isAvailable(.title))
    }

    func testInState() {
        let features = CompanionFeatures(isConnected: true)
        XCTAssertTrue(features.inState([.available], features: .up, .down, .left, .right))
        XCTAssertFalse(features.inState([.available], features: .up, .title))
    }
}
