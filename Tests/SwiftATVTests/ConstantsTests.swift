import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/test_convert.py
/// Tests all enum raw values and string descriptions.
final class ConstantsTests: XCTestCase {

    // MARK: - Protocol (test_convert.py::test_protocol_str)

    func testProtocolRawValues() {
        XCTAssertEqual(ATVProtocol.dmap.rawValue, 1)
        XCTAssertEqual(ATVProtocol.mrp.rawValue, 2)
        XCTAssertEqual(ATVProtocol.airPlay.rawValue, 3)
        XCTAssertEqual(ATVProtocol.companion.rawValue, 4)
        XCTAssertEqual(ATVProtocol.raop.rawValue, 5)
    }

    func testProtocolDescription() {
        XCTAssertEqual(ATVProtocol.mrp.description, "MRP")
        XCTAssertEqual(ATVProtocol.dmap.description, "DMAP")
        XCTAssertEqual(ATVProtocol.airPlay.description, "AirPlay")
        XCTAssertEqual(ATVProtocol.companion.description, "Companion")
        XCTAssertEqual(ATVProtocol.raop.description, "RAOP")
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

    // MARK: - FeatureName raw values

    func testFeatureNameRawValues() {
        // Navigation
        XCTAssertEqual(FeatureName.up.rawValue, 0)
        XCTAssertEqual(FeatureName.down.rawValue, 1)
        XCTAssertEqual(FeatureName.left.rawValue, 2)
        XCTAssertEqual(FeatureName.right.rawValue, 3)

        // Playback
        XCTAssertEqual(FeatureName.play.rawValue, 4)
        XCTAssertEqual(FeatureName.playPause.rawValue, 5)
        XCTAssertEqual(FeatureName.pause.rawValue, 6)
        XCTAssertEqual(FeatureName.stop.rawValue, 7)
        XCTAssertEqual(FeatureName.next.rawValue, 8)
        XCTAssertEqual(FeatureName.previous.rawValue, 9)

        // Control
        XCTAssertEqual(FeatureName.select.rawValue, 10)
        XCTAssertEqual(FeatureName.menu.rawValue, 11)
        XCTAssertEqual(FeatureName.volumeUp.rawValue, 12)
        XCTAssertEqual(FeatureName.volumeDown.rawValue, 13)
        XCTAssertEqual(FeatureName.home.rawValue, 14)
        XCTAssertEqual(FeatureName.homeHold.rawValue, 15)
        XCTAssertEqual(FeatureName.topMenu.rawValue, 16)
        XCTAssertEqual(FeatureName.suspend.rawValue, 17)
        XCTAssertEqual(FeatureName.wakeUp.rawValue, 18)

        // Playback control
        XCTAssertEqual(FeatureName.setPosition.rawValue, 19)
        XCTAssertEqual(FeatureName.setShuffle.rawValue, 20)
        XCTAssertEqual(FeatureName.setRepeat.rawValue, 21)

        // Metadata
        XCTAssertEqual(FeatureName.title.rawValue, 22)
        XCTAssertEqual(FeatureName.artist.rawValue, 23)
        XCTAssertEqual(FeatureName.album.rawValue, 24)
        XCTAssertEqual(FeatureName.genre.rawValue, 25)
        XCTAssertEqual(FeatureName.totalTime.rawValue, 26)
        XCTAssertEqual(FeatureName.position.rawValue, 27)
        XCTAssertEqual(FeatureName.shuffle.rawValue, 28)
        XCTAssertEqual(FeatureName.repeatState.rawValue, 29)

        // Media
        XCTAssertEqual(FeatureName.artwork.rawValue, 30)
        XCTAssertEqual(FeatureName.playUrl.rawValue, 31)
        XCTAssertEqual(FeatureName.powerState.rawValue, 32)
        XCTAssertEqual(FeatureName.turnOn.rawValue, 33)
        XCTAssertEqual(FeatureName.turnOff.rawValue, 34)
        XCTAssertEqual(FeatureName.app.rawValue, 35)
        XCTAssertEqual(FeatureName.skipForward.rawValue, 36)
        XCTAssertEqual(FeatureName.skipBackward.rawValue, 37)

        // Apps
        XCTAssertEqual(FeatureName.appList.rawValue, 38)
        XCTAssertEqual(FeatureName.launchApp.rawValue, 39)

        // Series
        XCTAssertEqual(FeatureName.seriesName.rawValue, 40)
        XCTAssertEqual(FeatureName.seasonNumber.rawValue, 41)
        XCTAssertEqual(FeatureName.episodeNumber.rawValue, 42)

        // Push/Stream/Volume
        XCTAssertEqual(FeatureName.pushUpdates.rawValue, 43)
        XCTAssertEqual(FeatureName.streamFile.rawValue, 44)
        XCTAssertEqual(FeatureName.volume.rawValue, 45)
        XCTAssertEqual(FeatureName.setVolume.rawValue, 46)
        XCTAssertEqual(FeatureName.contentIdentifier.rawValue, 47)

        // Channel
        XCTAssertEqual(FeatureName.channelUp.rawValue, 48)
        XCTAssertEqual(FeatureName.channelDown.rawValue, 49)

        // iTunes
        XCTAssertEqual(FeatureName.iTunesStoreIdentifier.rawValue, 50)

        // Keyboard
        XCTAssertEqual(FeatureName.textGet.rawValue, 51)
        XCTAssertEqual(FeatureName.textClear.rawValue, 52)
        XCTAssertEqual(FeatureName.textAppend.rawValue, 53)
        XCTAssertEqual(FeatureName.textSet.rawValue, 54)

        // Accounts
        XCTAssertEqual(FeatureName.accountList.rawValue, 55)
        XCTAssertEqual(FeatureName.switchAccount.rawValue, 56)

        // Focus/Screen
        XCTAssertEqual(FeatureName.textFocusState.rawValue, 57)
        XCTAssertEqual(FeatureName.screensaver.rawValue, 58)

        // Output
        XCTAssertEqual(FeatureName.outputDevices.rawValue, 59)
        XCTAssertEqual(FeatureName.addOutputDevices.rawValue, 60)
        XCTAssertEqual(FeatureName.removeOutputDevices.rawValue, 61)
        XCTAssertEqual(FeatureName.setOutputDevices.rawValue, 62)

        // Touch
        XCTAssertEqual(FeatureName.swipe.rawValue, 63)
        XCTAssertEqual(FeatureName.action.rawValue, 64)
        XCTAssertEqual(FeatureName.click.rawValue, 65)

        // Guide
        XCTAssertEqual(FeatureName.guide.rawValue, 66)

        // Control Center
        XCTAssertEqual(FeatureName.controlCenter.rawValue, 68)
    }

    func testFeatureNameAllCases() {
        XCTAssertTrue(FeatureName.allCases.count >= 60)
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

    func testFeatureNameCodable() throws {
        let original = FeatureName.artwork
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeatureName.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
