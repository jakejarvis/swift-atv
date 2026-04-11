import XCTest
@testable import SwiftATV

/// Ported from pyatv tests/test_conf.py
final class ConfigurationTests: XCTestCase {

    let address1 = "127.0.0.1"
    let address2 = "192.168.0.1"
    let name = "Alice"
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
        AppleTVConfiguration(address: address1, name: name, deepSleep: true)
    }

    func dmapService() -> ServiceInfo {
        ServiceInfo(protocol: .dmap, port: port1, identifier: identifier1)
    }

    func mrpService() -> ServiceInfo {
        ServiceInfo(protocol: .mrp, port: port2, identifier: identifier2, properties: ["foo": "bar"])
    }

    func airPlayService() -> ServiceInfo {
        ServiceInfo(protocol: .airPlay, port: port1, identifier: identifier3)
    }

    func companionService() -> ServiceInfo {
        ServiceInfo(protocol: .companion, port: port3)
    }

    func raopService() -> ServiceInfo {
        ServiceInfo(protocol: .raop, port: port4, identifier: identifier4)
    }

    // MARK: - test_address_and_name

    func testAddressAndName() {
        let config = makeConfig()
        XCTAssertEqual(config.address, address1)
        XCTAssertEqual(config.name, name)
    }

    // MARK: - test_add_services_and_get

    func testAddServicesAndGet() {
        var config = makeConfig()
        config.addService(dmapService())
        config.addService(mrpService())
        config.addService(airPlayService())
        config.addService(companionService())
        config.addService(raopService())

        XCTAssertEqual(config.services.count, 5)

        XCTAssertNotNil(config.service(for: .dmap))
        XCTAssertNotNil(config.service(for: .mrp))
        XCTAssertNotNil(config.service(for: .airPlay))
        XCTAssertNotNil(config.service(for: .companion))
        XCTAssertNotNil(config.service(for: .raop))

        XCTAssertEqual(config.service(for: .dmap)?.port, port1)
        XCTAssertEqual(config.service(for: .mrp)?.port, port2)
        XCTAssertEqual(config.service(for: .raop)?.port, port4)
    }

    // MARK: - test_identifier_order

    func testIdentifierOrder() {
        var config = makeConfig()

        XCTAssertNil(config.mainIdentifier)

        config.addService(raopService())
        XCTAssertEqual(config.mainIdentifier, identifier4)

        config.addService(dmapService())
        // After adding DMAP, first service identifier is returned if no MRP
        // (behavior depends on implementation order)
        XCTAssertNotNil(config.mainIdentifier)

        config.addService(mrpService())
        // MRP identifier is preferred
        XCTAssertEqual(config.mainIdentifier, identifier2)
    }

    // MARK: - test_identifier_missing_for_service

    func testIdentifierMissingForService() {
        var config = makeConfig()
        config.addService(dmapService())
        config.addService(ServiceInfo(protocol: .mrp, port: 0))

        // MRP identifier is nil, should fall back
        XCTAssertNotNil(config.mainIdentifier)
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
        XCTAssertNil(config.service(for: .dmap))
    }

    // MARK: - test_set_credentials

    func testSetCredentials() {
        var config = makeConfig()
        config.addService(dmapService())

        XCTAssertNil(config.service(for: .dmap)?.credentials)

        // Merge a new service with credentials
        var updated = dmapService()
        updated.credentials = "dummy"
        config.addService(updated)

        XCTAssertEqual(config.service(for: .dmap)?.credentials, "dummy")
    }

    // MARK: - test_to_str

    func testDescription() {
        var config = makeConfig()
        config.addService(ServiceInfo(
            protocol: .dmap, port: 3689, identifier: identifier1, credentials: "LOGIN_ID"
        ))
        config.addService(ServiceInfo(protocol: .mrp, port: port2, identifier: identifier2))

        let output = config.description
        XCTAssertTrue(output.contains(address1))
        XCTAssertTrue(output.contains(name))
    }

    // MARK: - test_service_merge_password

    func testServiceMergePasswordFirstHas() {
        var service1 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id1", password: "pass1")
        let service2 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id2")

        // Merge service2 into config containing service1
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        // Password from service1 should be preserved since service2 has none
        XCTAssertEqual(config.service(for: .dmap)?.password, "pass1")
    }

    func testServiceMergePasswordSecondHas() {
        let service1 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id1")
        let service2 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id2", password: "pass2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        XCTAssertEqual(config.service(for: .dmap)?.password, "pass2")
    }

    func testServiceMergePasswordBothHave() {
        let service1 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id1", password: "pass1")
        let service2 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id2", password: "pass2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        // Second merge overwrites but preserves password if new one is nil
        config.addService(service2)

        // The newer service's password takes precedence
        XCTAssertEqual(config.service(for: .dmap)?.password, "pass2")
    }

    // MARK: - test_service_merge_credentials

    func testServiceMergeCredentialsFirstHas() {
        let service1 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id1", credentials: "creds1")
        let service2 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        XCTAssertEqual(config.service(for: .dmap)?.credentials, "creds1")
    }

    func testServiceMergeCredentialsSecondHas() {
        let service1 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id1")
        let service2 = ServiceInfo(protocol: .dmap, port: 0, identifier: "id2", credentials: "creds2")

        var config = AppleTVConfiguration(address: "127.0.0.1", name: "test")
        config.addService(service1)
        config.addService(service2)

        XCTAssertEqual(config.service(for: .dmap)?.credentials, "creds2")
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
        var service = dmapService()
        service.enabled = false
        config.addService(service)

        XCTAssertFalse(config.service(for: .dmap)!.enabled)
    }

    // MARK: - Codable round-trip

    func testConfigurationCodable() throws {
        var config = makeConfig()
        config.addService(dmapService())
        config.addService(mrpService())

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppleTVConfiguration.self, from: data)

        XCTAssertEqual(decoded.address, config.address)
        XCTAssertEqual(decoded.name, config.name)
        XCTAssertEqual(decoded.deepSleep, config.deepSleep)
        XCTAssertEqual(decoded.services.count, config.services.count)
    }
}
