import XCTest

@testable import SwiftATV

/// Ported from pyatv tests/support/test_device_info.py
final class DeviceInfoTests: XCTestCase {

    // MARK: - test_lookup_model (test_device_info.py)

    func testLookupModelAppleTV6_2() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AppleTV6,2"), .gen4K)
    }

    func testLookupModelHomePodMini() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AudioAccessory5,1"), .homePodMini)
    }

    func testLookupModelBad() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "bad_model"), .unknown)
    }

    func testLookupModelAppleTV5_3() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AppleTV5,3"), .gen4)
    }

    func testLookupModelAppleTV11_1() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AppleTV11,1"), .gen4K2)
    }

    func testLookupModelAppleTV14_1() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AppleTV14,1"), .gen4K3)
    }

    func testLookupModelHomePod() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AudioAccessory1,1"), .homePod)
    }

    func testLookupModelHomePod2() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AudioAccessory6,1"), .homePod2)
    }

    func testLookupModelAirPortExpress() {
        XCTAssertEqual(DeviceInfo.lookupModel(identifier: "AirPort10,1"), .airPortExpressGen2)
    }

    // MARK: - test_lookup_internal_name (test_device_info.py)

    func testLookupInternalNameGen4K() {
        XCTAssertEqual(DeviceInfo.lookupModel(internalName: "J42dAP"), .gen4K)
    }

    func testLookupInternalNameBad() {
        XCTAssertEqual(DeviceInfo.lookupModel(internalName: "bad_name"), .unknown)
    }

    func testLookupInternalNameGen4() {
        XCTAssertEqual(DeviceInfo.lookupModel(internalName: "J33AP"), .gen4)
    }

    func testLookupInternalNameHomePodMini() {
        XCTAssertEqual(DeviceInfo.lookupModel(internalName: "B520AP"), .homePodMini)
    }

    // MARK: - test_lookup_os (test_device_info.py)

    func testLookupOSTvOS() {
        XCTAssertEqual(DeviceInfo.lookupOS(name: "tvOS"), .tvOS)
        XCTAssertEqual(DeviceInfo.lookupOS(name: "TvOS"), .tvOS)
        XCTAssertEqual(DeviceInfo.lookupOS(name: "tvos"), .tvOS)
    }

    func testLookupOSMacOS() {
        XCTAssertEqual(DeviceInfo.lookupOS(name: "macOS"), .macOS)
        XCTAssertEqual(DeviceInfo.lookupOS(name: "MacOSX"), .macOS)
        XCTAssertEqual(DeviceInfo.lookupOS(name: "macosx"), .macOS)
    }

    func testLookupOSAirPortOS() {
        XCTAssertEqual(DeviceInfo.lookupOS(name: "AirPortOS"), .airPortOS)
        XCTAssertEqual(DeviceInfo.lookupOS(name: "airportos"), .airPortOS)
    }

    func testLookupOSBad() {
        XCTAssertEqual(DeviceInfo.lookupOS(name: "bad"), .unknown)
    }

    // MARK: - test_device_info_from_properties (test_interface.py)

    func testFromPropertiesEmpty() {
        let info = DeviceInfo.fromProperties([:])
        XCTAssertEqual(info.operatingSystem, .unknown)
        XCTAssertNil(info.version)
        XCTAssertNil(info.buildNumber)
        XCTAssertEqual(info.model, .unknown)
        XCTAssertNil(info.macAddress)
    }

    func testFromPropertiesFull() {
        let props = [
            "model": "AppleTV6,2",
            "OSName": "tvOS",
            "osvers": "16.0",
            "srcvers": "19A123",
            "macAddress": "AA:BB:CC:DD:EE:FF",
        ]
        let info = DeviceInfo.fromProperties(props)
        XCTAssertEqual(info.model, .gen4K)
        XCTAssertEqual(info.operatingSystem, .tvOS)
        XCTAssertEqual(info.version, "16.0")
        XCTAssertEqual(info.buildNumber, "19A123")
        XCTAssertEqual(info.macAddress, "AA:BB:CC:DD:EE:FF")
    }

    func testFromPropertiesAlternateKeys() {
        let props = [
            "am": "AppleTV11,1",
            "OSVersion": "15.0",
            "SystemBuildVersion": "19K100",
            "deviceid": "11:22:33:44:55:66",
            "os": "TvOS",
        ]
        let info = DeviceInfo.fromProperties(props)
        XCTAssertEqual(info.model, .gen4K2)
        XCTAssertEqual(info.version, "15.0")
        XCTAssertEqual(info.buildNumber, "19K100")
        XCTAssertEqual(info.macAddress, "11:22:33:44:55:66")
        XCTAssertEqual(info.operatingSystem, .tvOS)
    }

    func testFromPropertiesCompanionModelAndVersion() {
        let props = [
            "rpMd": "AppleTV11,1",
            "rpVr": "715.2",
        ]

        let info = DeviceInfo.fromProperties(props)

        XCTAssertEqual(info.model, .gen4K2)
        XCTAssertEqual(info.modelString, "AppleTV11,1")
        XCTAssertEqual(info.version, "715.2")
    }

    func testFromPropertiesCompanionMacAddress() {
        let info = DeviceInfo.fromProperties(["rpMac": "aabbccddeeff"])

        XCTAssertEqual(info.macAddress, "aabbccddeeff")
    }

    func testFromPropertiesUsesCaseInsensitiveKeys() {
        let props = [
            "MODEL": "AppleTV6,2",
            "systembuildversion": "21K69",
            "macaddress": "AA:BB:CC:DD:EE:FF",
            "osname": "tvOS",
        ]

        let info = DeviceInfo.fromProperties(props)

        XCTAssertEqual(info.model, .gen4K)
        XCTAssertEqual(info.buildNumber, "21K69")
        XCTAssertEqual(info.macAddress, "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(info.operatingSystem, .tvOS)
    }

    func testFromPropertiesKeepsBetterVersionOverCompanionVersion() {
        let props = [
            "osvers": "17.0",
            "rpVr": "715.2",
        ]

        let info = DeviceInfo.fromProperties(props)

        XCTAssertEqual(info.version, "17.0")
    }

    func testFromPropertiesInternalNameFallback() {
        let props = [
            "internalName": "J42dAP"
        ]
        let info = DeviceInfo.fromProperties(props)
        XCTAssertEqual(info.model, .gen4K)
    }

    // MARK: - DeviceInfo description (test_interface.py)

    func testDeviceInfoDescription() {
        let info = DeviceInfo(
            operatingSystem: .tvOS,
            version: "16.0",
            model: .gen4K,
            macAddress: "AA:BB:CC:DD:EE:FF"
        )
        let desc = info.description
        XCTAssertTrue(desc.contains("Apple TV 4K"))
        XCTAssertTrue(desc.contains("tvOS"))
        XCTAssertTrue(desc.contains("16.0"))
    }

    func testDeviceInfoUnknownDescription() {
        let info = DeviceInfo()
        let desc = info.description
        XCTAssertTrue(desc.contains("Unknown"))
    }

    // MARK: - Codable

    func testDeviceInfoCodable() throws {
        let info = DeviceInfo(
            operatingSystem: .tvOS,
            version: "16.0",
            buildNumber: "19K100",
            model: .gen4K2,
            modelString: "AppleTV11,1",
            macAddress: "AA:BB:CC:DD:EE:FF"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(DeviceInfo.self, from: data)

        XCTAssertEqual(decoded.operatingSystem, info.operatingSystem)
        XCTAssertEqual(decoded.version, info.version)
        XCTAssertEqual(decoded.buildNumber, info.buildNumber)
        XCTAssertEqual(decoded.model, info.model)
        XCTAssertEqual(decoded.modelString, info.modelString)
        XCTAssertEqual(decoded.macAddress, info.macAddress)
    }
}
