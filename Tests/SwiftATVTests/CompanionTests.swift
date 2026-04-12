import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/protocols/companion/test_companion.py
/// and tests/protocols/companion/test_companion_interface.py
final class CompanionTests: XCTestCase {

    // MARK: - HID Command mapping (test_companion.py)

    func testHIDCommandValues() {
        XCTAssertEqual(HIDCommand.up.rawValue, 1)
        XCTAssertEqual(HIDCommand.down.rawValue, 2)
        XCTAssertEqual(HIDCommand.left.rawValue, 3)
        XCTAssertEqual(HIDCommand.right.rawValue, 4)
        XCTAssertEqual(HIDCommand.menu.rawValue, 5)
        XCTAssertEqual(HIDCommand.select.rawValue, 6)
        XCTAssertEqual(HIDCommand.home.rawValue, 7)
        XCTAssertEqual(HIDCommand.volumeUp.rawValue, 8)
        XCTAssertEqual(HIDCommand.volumeDown.rawValue, 9)
        XCTAssertEqual(HIDCommand.siri.rawValue, 10)
        XCTAssertEqual(HIDCommand.screensaver.rawValue, 11)
        XCTAssertEqual(HIDCommand.sleep.rawValue, 12)
        XCTAssertEqual(HIDCommand.wake.rawValue, 13)
        XCTAssertEqual(HIDCommand.playPause.rawValue, 14)
        XCTAssertEqual(HIDCommand.channelIncrement.rawValue, 15)
        XCTAssertEqual(HIDCommand.channelDecrement.rawValue, 16)
        XCTAssertEqual(HIDCommand.guide.rawValue, 17)
        XCTAssertEqual(HIDCommand.pageUp.rawValue, 18)
        XCTAssertEqual(HIDCommand.pageDown.rawValue, 19)
    }

    // MARK: - Media Control Command values

    func testMediaControlCommandValues() {
        XCTAssertEqual(MediaControlCommand.play.rawValue, 1)
        XCTAssertEqual(MediaControlCommand.pause.rawValue, 2)
        XCTAssertEqual(MediaControlCommand.nextTrack.rawValue, 3)
        XCTAssertEqual(MediaControlCommand.previousTrack.rawValue, 4)
        XCTAssertEqual(MediaControlCommand.getVolume.rawValue, 5)
        XCTAssertEqual(MediaControlCommand.setVolume.rawValue, 6)
        XCTAssertEqual(MediaControlCommand.skipBy.rawValue, 7)
    }

    // MARK: - Frame Type values

    func testCompanionFrameTypes() {
        XCTAssertEqual(CompanionFrameType.unknown.rawValue, 0)
        XCTAssertEqual(CompanionFrameType.noOp.rawValue, 1)
        XCTAssertEqual(CompanionFrameType.psStart.rawValue, 3)
        XCTAssertEqual(CompanionFrameType.psNext.rawValue, 4)
        XCTAssertEqual(CompanionFrameType.pvStart.rawValue, 5)
        XCTAssertEqual(CompanionFrameType.pvNext.rawValue, 6)
        XCTAssertEqual(CompanionFrameType.uOPACK.rawValue, 7)
        XCTAssertEqual(CompanionFrameType.eOPACK.rawValue, 8)
        XCTAssertEqual(CompanionFrameType.pOPACK.rawValue, 9)
    }

    // MARK: - Message Type values

    func testCompanionMessageTypes() {
        XCTAssertEqual(CompanionMessageType.event.rawValue, 1)
        XCTAssertEqual(CompanionMessageType.request.rawValue, 2)
        XCTAssertEqual(CompanionMessageType.response.rawValue, 3)
    }

    // MARK: - System Status values

    func testSystemStatusValues() {
        XCTAssertEqual(CompanionSystemStatus.asleep.rawValue, 1)
        XCTAssertEqual(CompanionSystemStatus.screensaver.rawValue, 2)
        XCTAssertEqual(CompanionSystemStatus.awake.rawValue, 3)
        XCTAssertEqual(CompanionSystemStatus.idle.rawValue, 4)
    }

    // MARK: - CompanionFeatures (test_companion_interface.py)

    func testCompanionFeaturesConnected() {
        let features = CompanionFeatures(isConnected: true)

        // Navigation features
        XCTAssertEqual(features.featureInfo(.up).state, .available)
        XCTAssertEqual(features.featureInfo(.down).state, .available)
        XCTAssertEqual(features.featureInfo(.left).state, .available)
        XCTAssertEqual(features.featureInfo(.right).state, .available)
        XCTAssertEqual(features.featureInfo(.select).state, .available)
        XCTAssertEqual(features.featureInfo(.menu).state, .available)
        XCTAssertEqual(features.featureInfo(.home).state, .available)

        // Playback
        XCTAssertEqual(features.featureInfo(.play).state, .available)
        XCTAssertEqual(features.featureInfo(.playPause).state, .available)
        XCTAssertEqual(features.featureInfo(.pause).state, .available)
        XCTAssertEqual(features.featureInfo(.stop).state, .available)
        XCTAssertEqual(features.featureInfo(.next).state, .available)
        XCTAssertEqual(features.featureInfo(.previous).state, .available)

        // Power
        XCTAssertEqual(features.featureInfo(.turnOn).state, .available)
        XCTAssertEqual(features.featureInfo(.turnOff).state, .available)
        XCTAssertEqual(features.featureInfo(.powerState).state, .available)

        // Apps
        XCTAssertEqual(features.featureInfo(.appList).state, .available)
        XCTAssertEqual(features.featureInfo(.launchApp).state, .available)

        // Accounts
        XCTAssertEqual(features.featureInfo(.accountList).state, .available)
        XCTAssertEqual(features.featureInfo(.switchAccount).state, .available)

        // Touch
        XCTAssertEqual(features.featureInfo(.swipe).state, .available)
        XCTAssertEqual(features.featureInfo(.action).state, .available)
        XCTAssertEqual(features.featureInfo(.click).state, .available)
    }

    func testCompanionFeaturesUnsupported() {
        let features = CompanionFeatures(isConnected: true)

        // MRP-only metadata features
        XCTAssertEqual(features.featureInfo(.title).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.artist).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.album).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.genre).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.artwork).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.totalTime).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.position).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.shuffle).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.repeatState).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.pushUpdates).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.playUrl).state, .unsupported)
        XCTAssertEqual(features.featureInfo(.streamFile).state, .unsupported)
    }

    func testCompanionFeaturesDisconnected() {
        let features = CompanionFeatures(isConnected: false)

        // Supported features become unavailable when disconnected
        XCTAssertEqual(features.featureInfo(.up).state, .unavailable)
        XCTAssertEqual(features.featureInfo(.home).state, .unavailable)
        XCTAssertEqual(features.featureInfo(.appList).state, .unavailable)

        // Unsupported features stay unsupported
        XCTAssertEqual(features.featureInfo(.title).state, .unsupported)
    }

    func testCompanionFeaturesIsAvailable() {
        let features = CompanionFeatures(isConnected: true)
        XCTAssertTrue(features.isAvailable(.play))
        XCTAssertTrue(features.isAvailable(.home))
        XCTAssertFalse(features.isAvailable(.title))
        XCTAssertFalse(features.isAvailable(.artwork))
    }

    func testCompanionFeaturesInState() {
        let features = CompanionFeatures(isConnected: true)

        XCTAssertTrue(features.inState([.available], features: .up, .down, .left, .right))
        XCTAssertFalse(features.inState([.available], features: .up, .title))
        XCTAssertTrue(features.inState([.unsupported, .available], features: .up, .title))
    }

    func testCompanionFeaturesAllFeaturesExcludeUnsupported() {
        let features = CompanionFeatures(isConnected: true)
        let all = features.allFeatures()

        for (_, info) in all {
            XCTAssertNotEqual(info.state, .unsupported)
        }
    }

    func testCompanionFeaturesAllFeaturesIncludeUnsupported() {
        let features = CompanionFeatures(isConnected: true)
        let all = features.allFeatures(includeUnsupported: true)

        XCTAssertEqual(all.count, FeatureName.allCases.count)
    }

    // MARK: - CompanionFrame

    func testCompanionFrameCreation() {
        let frame = CompanionFrame(type: .eOPACK, payload: Data([0x01, 0x02]))
        XCTAssertEqual(frame.type, .eOPACK)
        XCTAssertEqual(frame.payload, Data([0x01, 0x02]))
    }
}
