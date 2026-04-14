import XCTest

@testable import SwiftATV

/// Tests for Settings types
final class SettingsTests: XCTestCase {

    // MARK: - ATVSettings

    func testSettingsDefaults() {
        let settings = ATVSettings()
        XCTAssertNil(settings.info.name)
        XCTAssertNil(settings.protocols.companion.credentials)
        XCTAssertNil(settings.protocols.mrp.credentials)
        XCTAssertNil(settings.protocols.airplay.credentials)
    }

    func testSettingsCodable() throws {
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "test-cred"
        settings.protocols.airplay.airPlayVersion = .v2
        settings.protocols.airplay.mrpTunnelMode = .force
        settings.info.name = "My Device"
        settings.info.model = .gen4K

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ATVSettings.self, from: data)

        XCTAssertEqual(decoded.protocols.companion.credentials, "test-cred")
        XCTAssertEqual(decoded.protocols.airplay.airPlayVersion, .v2)
        XCTAssertEqual(decoded.protocols.airplay.mrpTunnelMode, .force)
        XCTAssertEqual(decoded.info.name, "My Device")
        XCTAssertEqual(decoded.info.model, .gen4K)
    }

    // MARK: - Credentials accessor

    func testCredentialsGet() {
        var settings = ATVSettings()
        settings.protocols.mrp.credentials = "mrp-cred"
        settings.protocols.companion.credentials = "comp-cred"
        settings.protocols.airplay.credentials = "airplay-cred"

        XCTAssertEqual(settings.credentials(for: .mrp), "mrp-cred")
        XCTAssertEqual(settings.credentials(for: .companion), "comp-cred")
        XCTAssertEqual(settings.credentials(for: .airPlay), "airplay-cred")
    }

    func testCredentialsSet() {
        var settings = ATVSettings()
        settings.setCredentials("mrp-cred", for: .mrp)
        settings.setCredentials("comp-cred", for: .companion)

        XCTAssertEqual(settings.credentials(for: .mrp), "mrp-cred")
        XCTAssertEqual(settings.credentials(for: .companion), "comp-cred")
    }

    // MARK: - Protocol-specific settings

    func testAirPlaySettingsDefaults() {
        let settings = AirPlaySettings()
        XCTAssertNil(settings.identifier)
        XCTAssertNil(settings.credentials)
        XCTAssertNil(settings.password)
        XCTAssertEqual(settings.airPlayVersion, .auto)
        XCTAssertEqual(settings.mrpTunnelMode, .auto)
    }

    func testInfoSettingsRemotePairingID() {
        let settings = InfoSettings()
        // Remote pairing ID should be auto-generated
        XCTAssertNotNil(settings.remotePairingID)
    }

    // MARK: - AirPlayVersion and MrpTunnelMode codable

    func testAirPlayVersionCodable() throws {
        for version in [AirPlayVersion.auto, .v1, .v2] {
            let data = try JSONEncoder().encode(version)
            let decoded = try JSONDecoder().decode(AirPlayVersion.self, from: data)
            XCTAssertEqual(decoded, version)
        }
    }

    func testMrpTunnelModeCodable() throws {
        for mode in [MrpTunnelMode.auto, .force, .disable] {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(MrpTunnelMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
