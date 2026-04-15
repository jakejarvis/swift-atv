import XCTest

@testable import SwiftATV

/// Ported from pyatv tests/test_conf.py
final class ConfigurationTests: XCTestCase {

    let address1 = "127.0.0.1"
    let address2 = "192.168.0.1"
    let deviceName = "Alice"
    let port1 = 1234
    let port2 = 5678
    let port3 = 1111
    let port4 = 5555
    let identifier1 = "id1"
    let identifier2 = "id2"
    let identifier3 = "id3"
    let identifier4 = "id4"
    let credentials1 = "cred1"
    let password1 = "password1"

    func makeConfig() -> AppleTVConfiguration {
        AppleTVConfiguration(address: address1, name: deviceName, deepSleep: true)
    }

    func mrpService() -> ServiceInfo {
        ServiceInfo(protocol: .mrp, port: port2, identifier: identifier2, properties: ["foo": "bar"])
    }

    func airPlayService() -> ServiceInfo {
        ServiceInfo(protocol: .airPlay, port: port1, identifier: identifier3)
    }

    func companionService() -> ServiceInfo {
        ServiceInfo(protocol: .companion, port: port3, identifier: identifier1)
    }

    // MARK: - test_address_and_name

    func testAddressAndName() {
        let config = makeConfig()
        XCTAssertEqual(config.address, address1)
        XCTAssertEqual(config.name, deviceName)
    }

    // MARK: - test_add_services_and_get

    func testAddServicesAndGet() {
        var config = makeConfig()
        config.addService(mrpService())
        config.addService(airPlayService())
        config.addService(companionService())

        XCTAssertEqual(config.services.count, 3)

        XCTAssertNotNil(config.service(for: .mrp))
        XCTAssertNotNil(config.service(for: .airPlay))
        XCTAssertNotNil(config.service(for: .companion))

        XCTAssertEqual(config.service(for: .mrp)?.port, port2)
        XCTAssertEqual(config.service(for: .airPlay)?.port, port1)
        XCTAssertEqual(config.service(for: .companion)?.port, port3)
    }

    // MARK: - test_identifier_order

    func testIdentifierOrder() {
        var config = makeConfig()

        XCTAssertNil(config.mainIdentifier)

        config.addService(companionService())
        XCTAssertEqual(config.mainIdentifier, identifier1)

        config.addService(airPlayService())
        // Before MRP is present, the first service identifier is returned.
        XCTAssertNotNil(config.mainIdentifier)

        config.addService(mrpService())
        // MRP identifier is preferred
        XCTAssertEqual(config.mainIdentifier, identifier2)
    }

    // MARK: - test_identifier_missing_for_service

    func testIdentifierMissingForService() {
        var config = makeConfig()
        config.addService(companionService())
        config.addService(ServiceInfo(protocol: .mrp, port: 0))

        // MRP identifier is nil, should fall back
        XCTAssertNotNil(config.mainIdentifier)
    }

    func testAllIdentifiersIncludesDeviceAndServiceIdentifiers() {
        var config = AppleTVConfiguration(address: address1, name: deviceName, identifier: "device-id")
        config.addService(ServiceInfo(protocol: .mrp, port: port2, identifier: "mrp-id"))
        config.addService(ServiceInfo(protocol: .companion, port: port3, identifier: "companion-id"))

        XCTAssertEqual(config.allIdentifiers, ["device-id", "mrp-id", "companion-id"])
        XCTAssertTrue(config.matchesIdentifier("companion-id"))
        XCTAssertFalse(config.matchesIdentifier("missing-id"))
    }

    func testEffectivePairingStatusUsesSavedCredentials() {
        let service = ServiceInfo(
            protocol: .mrp,
            port: port2,
            pairingRequirement: .mandatory
        )
        var settings = ATVSettings()

        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .credentialsMissing)

        settings.protocols.mrp.credentials = "01:02:03:04"
        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .paired)
    }

    func testAirPlayNotNeededPairingStatusReflectsTunnelCredentials() {
        let service = ServiceInfo(
            protocol: .airPlay,
            port: port1,
            pairingRequirement: .notNeeded
        )
        var settings = ATVSettings()

        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .credentialsMissing)

        settings.protocols.airplay.credentials = "01:02:03:04"
        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .paired)

        settings.protocols.airplay.credentials = nil
        settings.protocols.companion.credentials = "01:02:03:04"
        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .paired)
    }

    func testAirPlayTunnelPairingStatusRequiresReusableHAPCredentials() {
        let service = ServiceInfo(
            protocol: .airPlay,
            port: port1,
            pairingRequirement: .notNeeded
        )
        var settings = ATVSettings()

        settings.protocols.airplay.credentials = HAPCredentials.none.serialize()
        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .credentialsMissing)

        settings.protocols.airplay.credentials = HAPCredentials.transient.serialize()
        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .credentialsMissing)

        settings.protocols.airplay.credentials = ":aa::bb"
        XCTAssertEqual(service.effectivePairingStatus(settings: settings), .credentialsMissing)
    }

    func testConnectabilityAndPreferredPairingHelpers() {
        var config = makeConfig()
        config.addService(ServiceInfo(protocol: .mrp, port: port2, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .companion, port: port3, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .airPlay, port: port1, enabled: false))

        let preflight = config.connectability()
        XCTAssertEqual(preflight.map(\.service.protocol), [.mrp, .companion, .airPlay])
        XCTAssertEqual(preflight.map(\.status), [.connectable, .missingCredentials, .disabled])
        XCTAssertEqual(config.connectableProtocols(), [.mrp])
        XCTAssertEqual(
            config.preferredPairingService(protocols: [.companion, .mrp])?.protocol,
            .companion
        )
        XCTAssertNil(config.preferredPairingService(protocols: [.airPlay]))

        var settings = ATVSettings()
        settings.protocols.companion.credentials = "01:02:03:04"
        XCTAssertEqual(config.connectableProtocols(settings: settings), [.mrp, .companion])
        XCTAssertEqual(config.preferredPairingService(settings: settings)?.protocol, .mrp)
    }

    func testAirPlayPreferredPairingFollowsTunnelPreflight() {
        var config = makeConfig()
        config.addService(
            ServiceInfo(
                protocol: .airPlay,
                port: port1,
                properties: ["features": "0x4000000000", "model": "AppleTV11,1", "osvers": "16.0"],
                pairingRequirement: .notNeeded
            )
        )

        XCTAssertEqual(config.connectability().map(\.status), [.missingCredentials])
        XCTAssertEqual(config.preferredPairingService(protocols: [.airPlay])?.protocol, .airPlay)

        var settings = ATVSettings()
        settings.protocols.companion.credentials = "01:02:03:04"

        XCTAssertEqual(config.connectability(settings: settings).map(\.status), [.connectable])
        XCTAssertNil(config.preferredPairingService(settings: settings, protocols: [.airPlay]))
    }

    func testAirPlayTunnelConnectabilityRequiresReusableHAPCredentials() {
        var config = makeConfig()
        config.addService(
            ServiceInfo(
                protocol: .airPlay,
                port: port1,
                properties: ["features": "0x4000000000", "model": "AppleTV11,1", "osvers": "16.0"],
                pairingRequirement: .notNeeded
            )
        )
        var settings = ATVSettings()

        settings.protocols.airplay.credentials = HAPCredentials.none.serialize()
        XCTAssertEqual(config.connectability(settings: settings).map(\.status), [.missingCredentials])

        settings.protocols.airplay.credentials = HAPCredentials.transient.serialize()
        XCTAssertEqual(config.connectability(settings: settings).map(\.status), [.missingCredentials])

        settings.protocols.airplay.credentials = ":aa::bb"
        XCTAssertEqual(config.connectability(settings: settings).map(\.status), [.missingCredentials])
    }

    func testCompanionDerivedAirPlayRequiresReusableHAPCredentials() {
        var config = makeConfig()
        config.deviceInfo = DeviceInfo(version: "18.4", model: .gen4K2, modelString: "AppleTV11,1")
        config.addService(
            ServiceInfo(
                protocol: .companion,
                port: port3,
                properties: ["rpMd": "AppleTV11,1", "rpVr": "18.4"],
                pairingRequirement: .mandatory
            )
        )
        var settings = ATVSettings()

        settings.protocols.companion.credentials = HAPCredentials.none.serialize()
        XCTAssertNil(
            ATVClient.companionDerivedAirPlayServiceIfAvailable(
                from: config,
                requestedProtocols: [.airPlay],
                settings: settings
            )
        )

        settings.protocols.companion.credentials = "01:02:03:04"
        XCTAssertNotNil(
            ATVClient.companionDerivedAirPlayServiceIfAvailable(
                from: config,
                requestedProtocols: [.airPlay],
                settings: settings
            )
        )
    }

    func testConnectableProtocolsUsesRequestedProtocolOrder() {
        var config = makeConfig()
        config.addService(ServiceInfo(protocol: .companion, port: port3, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .mrp, port: port2, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "01:02:03:04"

        XCTAssertEqual(config.connectableProtocols(settings: settings), [.mrp, .companion])
        XCTAssertEqual(
            config.connectableProtocols(settings: settings, protocols: [.companion, .mrp]),
            [.companion, .mrp]
        )
        XCTAssertEqual(
            config.connectableProtocols(settings: settings, protocols: [.companion, .companion]),
            [.companion]
        )
    }

    // MARK: - test_add_airplay_service

    func testAddAirplayService() {
        var config = makeConfig()
        config.addService(airPlayService())

        let airplay = config.service(for: .airPlay)
        XCTAssertEqual(airplay?.protocol, .airPlay)
        XCTAssertEqual(airplay?.port, port1)
    }

    // MARK: - test_set_credentials_for_missing_service

    func testSetCredentialsMissing() {
        let config = makeConfig()
        // No service to set credentials on
        XCTAssertNil(config.service(for: .mrp))
    }

    // MARK: - test_set_credentials

    func testSetCredentials() {
        var config = makeConfig()
        config.addService(companionService())

        XCTAssertNil(config.service(for: .companion)?.credentials)

        // Merge a new service with credentials
        var updated = companionService()
        updated.credentials = "dummy"
        config.addService(updated)

        XCTAssertEqual(config.service(for: .companion)?.credentials, "dummy")
    }

    // MARK: - test_to_str

    func testDescription() {
        var config = makeConfig()
        config.addService(
            ServiceInfo(
                protocol: .companion, port: port3, identifier: identifier1, credentials: "LOGIN_ID"
            ))
        config.addService(ServiceInfo(protocol: .mrp, port: port2, identifier: identifier2))

        let output = config.description
        XCTAssertTrue(output.contains(address1))
        XCTAssertTrue(output.contains(deviceName))
    }

    // MARK: - test_service_merge_password

    func testServiceMergePasswordFirstHas() {
        let service1 = ServiceInfo(protocol: .airPlay, port: 0, identifier: "id1", password: "pass1")
        let service2 = ServiceInfo(protocol: .airPlay, port: 0, identifier: "id2")

        // Merge service2 into config containing service1
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        // Password from service1 should be preserved since service2 has none
        XCTAssertEqual(config.service(for: .airPlay)?.password, "pass1")
    }

    func testServiceMergePasswordSecondHas() {
        let service1 = ServiceInfo(protocol: .airPlay, port: 0, identifier: "id1")
        let service2 = ServiceInfo(protocol: .airPlay, port: 0, identifier: "id2", password: "pass2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        XCTAssertEqual(config.service(for: .airPlay)?.password, "pass2")
    }

    func testServiceMergePasswordBothHave() {
        let service1 = ServiceInfo(protocol: .airPlay, port: 0, identifier: "id1", password: "pass1")
        let service2 = ServiceInfo(protocol: .airPlay, port: 0, identifier: "id2", password: "pass2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        // Second merge overwrites but preserves password if new one is nil
        config.addService(service2)

        // The newer service's password takes precedence
        XCTAssertEqual(config.service(for: .airPlay)?.password, "pass2")
    }

    // MARK: - test_service_merge_credentials

    func testServiceMergeCredentialsFirstHas() {
        let service1 = ServiceInfo(protocol: .companion, port: 0, identifier: "id1", credentials: "creds1")
        let service2 = ServiceInfo(protocol: .companion, port: 0, identifier: "id2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        XCTAssertEqual(config.service(for: .companion)?.credentials, "creds1")
    }

    func testServiceMergeCredentialsSecondHas() {
        let service1 = ServiceInfo(protocol: .companion, port: 0, identifier: "id1")
        let service2 = ServiceInfo(protocol: .companion, port: 0, identifier: "id2", credentials: "creds2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        XCTAssertEqual(config.service(for: .companion)?.credentials, "creds2")
    }

    func testServiceMergePreservesDiscoveryMetadataWhenDuplicateIsSparse() {
        let richService = ServiceInfo(
            protocol: .companion,
            port: port3,
            identifier: "companion-id",
            properties: ["rpFl": "0x4000", "rpMac": "AA:BB:CC:DD:EE:FF"],
            pairingRequirement: .mandatory
        )
        let sparseService = ServiceInfo(protocol: .companion, port: port3)

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(richService)
        config.addService(sparseService)

        let merged = config.service(for: .companion)
        XCTAssertEqual(merged?.identifier, "companion-id")
        XCTAssertEqual(merged?.properties["rpFl"], "0x4000")
        XCTAssertEqual(merged?.properties["rpMac"], "AA:BB:CC:DD:EE:FF")
        XCTAssertEqual(merged?.pairingRequirement, .mandatory)
    }

    // MARK: - Deep sleep

    func testDeepSleep() {
        let config = makeConfig()
        XCTAssertTrue(config.deepSleep)

        let config2 = AppleTVConfiguration(address: "1.2.3.4", name: "test")
        XCTAssertFalse(config2.deepSleep)
    }

    // MARK: - Service enabled

    func testServiceDisabled() {
        var config = makeConfig()
        var service = companionService()
        service.enabled = false
        config.addService(service)

        XCTAssertFalse(config.service(for: .companion)!.enabled)
    }

    // MARK: - Codable round-trip

    func testConfigurationCodable() throws {
        var config = makeConfig()
        config.addService(companionService())
        config.addService(mrpService())

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppleTVConfiguration.self, from: data)

        XCTAssertEqual(decoded.address, config.address)
        XCTAssertEqual(decoded.name, config.name)
        XCTAssertEqual(decoded.deepSleep, config.deepSleep)
        XCTAssertEqual(decoded.services.count, config.services.count)
    }
}
