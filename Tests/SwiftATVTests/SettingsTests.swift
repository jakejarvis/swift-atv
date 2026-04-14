import XCTest

@testable import SwiftATV

/// Tests for Settings types
final class SettingsTests: XCTestCase {

    // MARK: - ATVSettings

    func testSettingsDefaults() {
        let settings = ATVSettings()
        XCTAssertEqual(settings.clientIdentity.name, "SwiftATV")
        XCTAssertEqual(settings.clientIdentity.macAddress, "02:73:77:69:66:74")
        XCTAssertEqual(settings.clientIdentity.model, "iPhone10,6")
        XCTAssertEqual(settings.clientIdentity.deviceID, "FF:70:79:61:74:76")
        XCTAssertFalse(settings.clientIdentity.pairingIdentifier.isEmpty)
        XCTAssertTrue(settings.clientIdentity.rapportIdentifier.isLowercaseHexIdentifier)
        XCTAssertNil(settings.protocols.companion.credentials)
        XCTAssertNil(settings.protocols.mrp.credentials)
        XCTAssertNil(settings.protocols.airplay.credentials)
    }

    func testSettingsCodable() throws {
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "test-cred"
        settings.protocols.airplay.airPlayVersion = .v2
        settings.protocols.airplay.mrpTunnelMode = .force
        settings.clientIdentity.name = "My Device"
        settings.clientIdentity.model = "iPhone15,2"
        settings.clientIdentity.pairingIdentifier = "remote-id"
        settings.clientIdentity.rapportIdentifier = "abcdef123456"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ATVSettings.self, from: data)

        XCTAssertEqual(decoded.protocols.companion.credentials, "test-cred")
        XCTAssertEqual(decoded.protocols.airplay.airPlayVersion, .v2)
        XCTAssertEqual(decoded.protocols.airplay.mrpTunnelMode, .force)
        XCTAssertEqual(decoded.clientIdentity.name, "My Device")
        XCTAssertEqual(decoded.clientIdentity.model, "iPhone15,2")
        XCTAssertEqual(decoded.clientIdentity.pairingIdentifier, "remote-id")
        XCTAssertEqual(decoded.clientIdentity.rapportIdentifier, "abcdef123456")
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

    func testApplyPairingResultStoresProtocolCredentialsAndIdentifier() {
        let credentials = HAPCredentials(
            ltpk: Data([0x01]),
            ltsk: Data([0x02]),
            atvIdentifier: Data([0x03]),
            clientIdentifier: Data([0x04])
        )
        let service = ServiceInfo(protocol: .companion, port: 49153, identifier: "companion-id")
        let result = PairingResult(service: service, credentials: credentials)

        var settings = ATVSettings()
        settings.apply(result)

        XCTAssertEqual(settings.protocols.companion.credentials, "01:02:03:04")
        XCTAssertEqual(settings.protocols.companion.identifier, "companion-id")
        XCTAssertEqual(settings.applying(result).protocols.companion.credentials, "01:02:03:04")
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

    func testClientIdentitySettingsPairingIdentifier() {
        let settings = ClientIdentitySettings()
        XCTAssertFalse(settings.pairingIdentifier.isEmpty)
        XCTAssertTrue(settings.rapportIdentifier.isLowercaseHexIdentifier)
    }

    func testClientIdentityDefaultsWhenDecodingMissingFields() throws {
        let data = "{}".data(using: .utf8)!
        let settings = try JSONDecoder().decode(ClientIdentitySettings.self, from: data)

        XCTAssertEqual(settings.name, "SwiftATV")
        XCTAssertEqual(settings.macAddress, "02:73:77:69:66:74")
        XCTAssertEqual(settings.deviceID, "FF:70:79:61:74:76")
        XCTAssertFalse(settings.pairingIdentifier.isEmpty)
        XCTAssertTrue(settings.rapportIdentifier.isLowercaseHexIdentifier)
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

extension String {
    fileprivate var isLowercaseHexIdentifier: Bool {
        range(of: #"^[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }
}
