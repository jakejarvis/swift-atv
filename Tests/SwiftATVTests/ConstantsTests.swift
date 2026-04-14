import XCTest

@testable import SwiftATV

/// Ported from pyatv tests/test_convert.py
/// Tests all enum raw values and string descriptions.
final class ConstantsTests: XCTestCase {

    // MARK: - Protocol (test_convert.py::test_protocol_str)

    func testProtocolRawValues() {
        XCTAssertEqual(ATVProtocol.mrp.rawValue, 1)
        XCTAssertEqual(ATVProtocol.airPlay.rawValue, 2)
        XCTAssertEqual(ATVProtocol.companion.rawValue, 3)
    }

    func testProtocolDescription() {
        XCTAssertEqual(ATVProtocol.mrp.description, "MRP")
        XCTAssertEqual(ATVProtocol.airPlay.description, "AirPlay")
        XCTAssertEqual(ATVProtocol.companion.description, "Companion")
    }

    // MARK: - MediaType (test_convert.py::test_media_type_to_string)

    func testMediaTypeDescription() {
        XCTAssertEqual(MediaType.unknown.description, "Unknown")
        XCTAssertEqual(MediaType.video.description, "Video")
        XCTAssertEqual(MediaType.music.description, "Music")
        XCTAssertEqual(MediaType.tv.description, "TV")
    }

    func testMediaTypeRawValues() {
        XCTAssertEqual(MediaType.unknown.rawValue, 0)
        XCTAssertEqual(MediaType.video.rawValue, 1)
        XCTAssertEqual(MediaType.music.rawValue, 2)
        XCTAssertEqual(MediaType.tv.rawValue, 3)
    }

    // MARK: - DeviceState (test_convert.py::test_device_state_str)

    func testDeviceStateDescription() {
        XCTAssertEqual(DeviceState.idle.description, "Idle")
        XCTAssertEqual(DeviceState.loading.description, "Loading")
        XCTAssertEqual(DeviceState.stopped.description, "Stopped")
        XCTAssertEqual(DeviceState.paused.description, "Paused")
        XCTAssertEqual(DeviceState.playing.description, "Playing")
        XCTAssertEqual(DeviceState.seeking.description, "Seeking")
    }

    func testDeviceStateRawValues() {
        XCTAssertEqual(DeviceState.idle.rawValue, 0)
        XCTAssertEqual(DeviceState.loading.rawValue, 1)
        XCTAssertEqual(DeviceState.paused.rawValue, 2)
        XCTAssertEqual(DeviceState.playing.rawValue, 3)
        XCTAssertEqual(DeviceState.stopped.rawValue, 4)
        XCTAssertEqual(DeviceState.seeking.rawValue, 5)
    }

    // MARK: - RepeatState (test_convert.py::test_repeat_str)

    func testRepeatStateDescription() {
        XCTAssertEqual(RepeatState.off.description, "Off")
        XCTAssertEqual(RepeatState.track.description, "Track")
        XCTAssertEqual(RepeatState.all.description, "All")
    }

    // MARK: - ShuffleState (test_convert.py::test_shuffle_str)

    func testShuffleStateDescription() {
        XCTAssertEqual(ShuffleState.off.description, "Off")
        XCTAssertEqual(ShuffleState.albums.description, "Albums")
        XCTAssertEqual(ShuffleState.songs.description, "Songs")
    }

    // MARK: - DeviceModel (test_convert.py::test_model_str)

    func testDeviceModelDescription() {
        XCTAssertEqual(DeviceModel.gen1.description, "Apple TV (1st gen)")
        XCTAssertEqual(DeviceModel.gen2.description, "Apple TV (2nd gen)")
        XCTAssertEqual(DeviceModel.gen3.description, "Apple TV (3rd gen)")
        XCTAssertEqual(DeviceModel.gen4.description, "Apple TV (4th gen)")
        XCTAssertEqual(DeviceModel.gen4K.description, "Apple TV 4K")
        XCTAssertEqual(DeviceModel.homePod.description, "HomePod")
        XCTAssertEqual(DeviceModel.homePodMini.description, "HomePod Mini")
        XCTAssertEqual(DeviceModel.airPortExpress.description, "AirPort Express (1st gen)")
        XCTAssertEqual(DeviceModel.airPortExpressGen2.description, "AirPort Express (2nd gen)")
        XCTAssertEqual(DeviceModel.gen4K2.description, "Apple TV 4K (2nd gen)")
        XCTAssertEqual(DeviceModel.music.description, "Music/iTunes")
        XCTAssertEqual(DeviceModel.gen4K3.description, "Apple TV 4K (3rd gen)")
        XCTAssertEqual(DeviceModel.homePod2.description, "HomePod (2nd gen)")
    }

    // MARK: - Capabilities

    func testCapabilityIdentifiers() throws {
        XCTAssertEqual(Capability.remote(.up).identifier, "remote.up")
        XCTAssertEqual(Capability.mediaCommand(.play).identifier, "mediaCommand.play")
        XCTAssertEqual(Capability.metadata(.title).identifier, "metadata.title")
        XCTAssertEqual(Capability.audio(.setOutputDevices).identifier, "audio.setOutputDevices")

        XCTAssertEqual(try Capability(identifier: "remote.up"), .remote(.up))
        XCTAssertEqual(try Capability(identifier: "mediaCommand.play"), .mediaCommand(.play))
    }

    func testCapabilityAllCases() {
        XCTAssertTrue(Capability.allCases.contains(.remote(.up)))
        XCTAssertTrue(Capability.allCases.contains(.mediaCommand(.seekToPlaybackPosition)))
        XCTAssertTrue(Capability.allCases.contains(.keyboard(.textSet)))
        XCTAssertTrue(Capability.allCases.contains(.touch(.click)))
    }

    // MARK: - PairingRequirement

    func testPairingRequirementRawValues() {
        XCTAssertEqual(PairingRequirement.unsupported.rawValue, 1)
        XCTAssertEqual(PairingRequirement.disabled.rawValue, 2)
        XCTAssertEqual(PairingRequirement.notNeeded.rawValue, 3)
        XCTAssertEqual(PairingRequirement.optional.rawValue, 4)
        XCTAssertEqual(PairingRequirement.mandatory.rawValue, 5)
    }

    // MARK: - TouchAction

    func testTouchActionRawValues() {
        XCTAssertEqual(TouchAction.press.rawValue, 1)
        XCTAssertEqual(TouchAction.hold.rawValue, 3)
        XCTAssertEqual(TouchAction.release.rawValue, 4)
        XCTAssertEqual(TouchAction.click.rawValue, 5)
    }

    // MARK: - InputAction

    func testInputActionRawValues() {
        XCTAssertEqual(InputAction.singleTap.rawValue, 0)
        XCTAssertEqual(InputAction.doubleTap.rawValue, 1)
        XCTAssertEqual(InputAction.hold.rawValue, 2)
    }

    // MARK: - PowerState

    func testPowerStateRawValues() {
        XCTAssertEqual(PowerState.unknown.rawValue, 0)
        XCTAssertEqual(PowerState.off.rawValue, 1)
        XCTAssertEqual(PowerState.on.rawValue, 2)
    }

    // MARK: - OperatingSystem

    func testOperatingSystemRawValues() {
        XCTAssertEqual(OperatingSystem.unknown.rawValue, 0)
        XCTAssertEqual(OperatingSystem.legacy.rawValue, 1)
        XCTAssertEqual(OperatingSystem.tvOS.rawValue, 2)
        XCTAssertEqual(OperatingSystem.airPortOS.rawValue, 3)
        XCTAssertEqual(OperatingSystem.macOS.rawValue, 4)
    }

    // MARK: - Codable Round-trip

    func testProtocolCodable() throws {
        let original = ATVProtocol.companion
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ATVProtocol.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCapabilityCodable() throws {
        let original = Capability.metadata(.artwork)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Capability.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
