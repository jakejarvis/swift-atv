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

    // MARK: - CompanionCapabilities (test_companion_interface.py)

    func testCompanionCapabilitiesConnected() {
        let capabilities = CompanionCapabilities(isConnected: true)

        // Navigation capabilities
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.up)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.down)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.left)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.right)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.select)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.menu)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.home)).state, .available)

        // Playback
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.play)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.playPause)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.pause)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.stop)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.nextTrack)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.previousTrack)).state, .unavailable)

        // Power
        XCTAssertEqual(capabilities.capabilityInfo(.power(.turnOn)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.power(.turnOff)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.power(.state)).state, .unavailable)

        // Audio
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .unavailable)

        // Apps
        XCTAssertEqual(capabilities.capabilityInfo(.apps(.list)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.apps(.launch)).state, .unavailable)

        // Accounts
        XCTAssertEqual(capabilities.capabilityInfo(.accounts(.list)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.accounts(.switchAccount)).state, .unavailable)

        // Keyboard
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.textGet)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.textClear)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.textAppend)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.textSet)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.focusState)).state, .unavailable)

        // Touch
        XCTAssertEqual(capabilities.capabilityInfo(.touch(.swipe)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.touch(.action)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.touch(.click)).state, .available)
    }

    func testCompanionCapabilitiesUnsupported() {
        let capabilities = CompanionCapabilities(isConnected: true)

        // MRP-only metadata capabilities
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.title)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.artist)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.album)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.genre)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.artwork)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.totalTime)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.position)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.shuffle)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.repeatState)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.push(.updates)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.stream(.playURL)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.stream(.streamFile)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.outputDevices)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.addOutputDevices)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.removeOutputDevices)).state, .unsupported)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setOutputDevices)).state, .unsupported)
    }

    func testCompanionAudioDoesNotSupportOutputDeviceMutation() async {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let handler = CompanionProtocolHandler(connection: connection)
        let audio = CompanionAudio(protocol: handler)

        await assertNotSupported(try await audio.addOutputDevices(["speaker"]))
        await assertNotSupported(try await audio.removeOutputDevices(["speaker"]))
        await assertNotSupported(try await audio.setOutputDevices(["speaker"]))
        await connection.close()
    }

    func testCompanionTouchUsesMonotonicElapsedTimestamp() {
        XCTAssertEqual(CompanionTouch.elapsedNanoseconds(since: 100, now: 250), 150)
        XCTAssertEqual(CompanionTouch.elapsedNanoseconds(since: 250, now: 100), 0)
    }

    func testCompanionTouchInterpolatedCoordinateClampsBeforeIntegerConversion() {
        XCTAssertEqual(CompanionTouch.interpolatedCoordinate(start: Int.min, end: Int.max, progress: 0), 0)
        XCTAssertEqual(CompanionTouch.interpolatedCoordinate(start: Int.min, end: Int.max, progress: 0.5), 0)
        XCTAssertEqual(CompanionTouch.interpolatedCoordinate(start: Int.min, end: Int.max, progress: 1), 1000)
        XCTAssertEqual(CompanionTouch.interpolatedCoordinate(start: 0, end: 1000, progress: 0.25), 250)
    }

    func testCompanionSessionIdentifierCombinesRemoteAndLocalSID() throws {
        let sessionID = try CompanionProtocolHandler.sessionIdentifier(localSID: 0x1234_5678, remoteSID: 0x90AB_CDEF)

        XCTAssertEqual(sessionID, 0x90AB_CDEF_1234_5678)
    }

    func testCompanionSessionIdentifierRejectsNegativeRemoteSID() {
        XCTAssertThrowsError(try CompanionProtocolHandler.sessionIdentifier(localSID: 1, remoteSID: -1))
    }

    func testCompanionSessionIdentifierRejectsOutOfRangeRemoteSID() {
        XCTAssertThrowsError(
            try CompanionProtocolHandler.sessionIdentifier(localSID: 1, remoteSID: Int64(UInt32.max) + 1)
        )
    }

    func testCompanionCapabilitiesReflectObservedState() {
        let stateStore = CompanionStateStore(isConnected: true, touchAvailable: true)
        let capabilities = CompanionCapabilities(stateStore: stateStore)

        stateStore.setMediaControlFlags([
            .play, .pause, .nextTrack, .previousTrack, .skipForward, .skipBackward, .volume,
        ])
        stateStore.setVolume(45)
        stateStore.setPowerState(.on)
        stateStore.markAppsAvailable()
        stateStore.markUserAccountsAvailable()
        stateStore.setTextFocusState(.focused)

        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.play)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.pause)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.nextTrack)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.previousTrack)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.skipForward)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.mediaCommand(.skipBackward)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.setVolume)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.audio(.volume)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.power(.state)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.power(.turnOn)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.apps(.list)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.accounts(.list)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.focusState)).state, .available)
        XCTAssertEqual(capabilities.capabilityInfo(.keyboard(.textGet)).state, .available)
    }

    private func assertNotSupported(
        _ expression: @autoclosure () async throws(ATVError) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected notSupported", file: file, line: line)
        } catch {
            guard case .notSupported = error else {
                XCTFail("Expected notSupported, got \(error)", file: file, line: line)
                return
            }
        }
    }

    func testCompanionCapabilitiesDisconnected() {
        let capabilities = CompanionCapabilities(isConnected: false)

        // Supported capabilities become unavailable when disconnected
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.up)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.remote(.home)).state, .unavailable)
        XCTAssertEqual(capabilities.capabilityInfo(.apps(.list)).state, .unavailable)

        // Unsupported capabilities stay unsupported
        XCTAssertEqual(capabilities.capabilityInfo(.metadata(.title)).state, .unsupported)
    }

    func testCompanionCapabilitiesIsAvailable() {
        let stateStore = CompanionStateStore(isConnected: true, touchAvailable: true)
        let capabilities = CompanionCapabilities(stateStore: stateStore)

        XCTAssertFalse(capabilities.isAvailable(.mediaCommand(.play)))
        stateStore.setMediaControlFlags([.play])
        XCTAssertTrue(capabilities.isAvailable(.mediaCommand(.play)))
        XCTAssertTrue(capabilities.isAvailable(.remote(.home)))
        XCTAssertFalse(capabilities.isAvailable(.metadata(.title)))
        XCTAssertFalse(capabilities.isAvailable(.metadata(.artwork)))
    }

    func testCompanionCapabilitiesInState() {
        let capabilities = CompanionCapabilities(isConnected: true)

        XCTAssertTrue(
            capabilities.inState(
                [.available],
                capabilities: .remote(.up), .remote(.down), .remote(.left), .remote(.right)
            )
        )
        XCTAssertFalse(capabilities.inState([.available], capabilities: .remote(.up), .metadata(.title)))
        XCTAssertTrue(capabilities.inState([.unsupported, .available], capabilities: .remote(.up), .metadata(.title)))
    }

    func testCompanionCapabilitiesAllCapabilitiesExcludeUnsupported() {
        let capabilities = CompanionCapabilities(isConnected: true)
        let all = capabilities.allCapabilities()

        for (_, info) in all {
            XCTAssertNotEqual(info.state, .unsupported)
        }
    }

    func testCompanionCapabilitiesAllCapabilitiesIncludeUnsupported() {
        let capabilities = CompanionCapabilities(isConnected: true)
        let all = capabilities.allCapabilities(includeUnsupported: true)

        XCTAssertEqual(all.count, Capability.allCases.count)
    }

    // MARK: - CompanionFrame

    func testCompanionFrameCreation() {
        let frame = CompanionFrame(type: .eOPACK, payload: Data([0x01, 0x02]))
        XCTAssertEqual(frame.type, .eOPACK)
        XCTAssertEqual(frame.payload, Data([0x01, 0x02]))
    }
}
