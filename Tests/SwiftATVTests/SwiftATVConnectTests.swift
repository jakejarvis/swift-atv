import XCTest

@testable import SwiftATV

final class SwiftATVConnectTests: XCTestCase {
    func testConnectRequestedMissingProtocolThrowsNoService() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .airPlay, port: 7000))

        do {
            _ = try await SwiftATV.connect(config, protocol: .mrp)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.noService = error else {
                XCTFail("Expected noService, got \(error)")
                return
            }
        }
    }

    func testConnectRequestedUnsupportedProtocolThrowsNotSupported() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .airPlay, port: 7000))

        do {
            _ = try await SwiftATV.connect(config, protocol: .airPlay)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.notSupported = error else {
                XCTFail("Expected notSupported, got \(error)")
                return
            }
        }
    }

    func testConnectOnlyUnsupportedServicesThrowsNoService() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .airPlay, port: 7000))

        do {
            _ = try await SwiftATV.connect(config)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.noService = error else {
                XCTFail("Expected noService, got \(error)")
                return
            }
        }
    }

    func testConnectCompanionWithMalformedCredentialsThrowsInvalidCredentials() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .companion, port: 49153))
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "not-valid-hap-credentials"

        do {
            _ = try await SwiftATV.connect(config, protocol: .companion, settings: settings)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.invalidCredentials = error else {
                XCTFail("Expected invalidCredentials, got \(error)")
                return
            }
        }
    }

    func testConnectMRPWithMalformedCredentialsThrowsInvalidCredentials() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152))
        var settings = ATVSettings()
        settings.protocols.mrp.credentials = "not-valid-hap-credentials"

        do {
            _ = try await SwiftATV.connect(config, protocol: .mrp, settings: settings)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.invalidCredentials = error else {
                XCTFail("Expected invalidCredentials, got \(error)")
                return
            }
        }
    }
}
