import XCTest

@testable import SwiftATV

final class SwiftATVConnectTests: XCTestCase {
    private final class AttemptRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _protocols: [ATVProtocol] = []
        private var _credentials: [ATVProtocol: String] = [:]

        var protocols: [ATVProtocol] {
            lock.withLock { _protocols }
        }

        func append(_ service: ServiceInfo, credentials: HAPCredentials?) {
            lock.withLock {
                _protocols.append(service.protocol)
                if let credentials {
                    _credentials[service.protocol] = credentials.serialize()
                }
            }
        }

        func credentials(for `protocol`: ATVProtocol) -> String? {
            lock.withLock { _credentials[`protocol`] }
        }
    }

    private static func recordSuccessfulSetup(
        on facade: FacadeAppleTV,
        service: ServiceInfo,
        credentials: HAPCredentials?,
        recorder: AttemptRecorder
    ) {
        recorder.append(service, credentials: credentials)
        facade._testSetActiveProtocols(Set(recorder.protocols), primary: recorder.protocols.first)
    }

    func testConnectRequestedMissingProtocolThrowsNoService() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .airPlay, port: 7000))

        do {
            _ = try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]))
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
            _ = try await ATVClient.connect(
                config,
                options: ConnectOptions(protocols: [.companion]),
                settings: settings
            )
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
            _ = try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]), settings: settings)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.invalidCredentials = error else {
                XCTFail("Expected invalidCredentials, got \(error)")
                return
            }
        }
    }

    func testConnectUsesDeterministicProtocolPriority() async throws {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        let recorder = AttemptRecorder()

        let result = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                Self.recordSuccessfulSetup(
                    on: facade,
                    service: service,
                    credentials: credentials,
                    recorder: recorder
                )
            },
            operation: {
                try await ATVClient.connect(config)
            }
        )

        XCTAssertEqual(recorder.protocols, [.mrp])
        XCTAssertEqual(result.primaryProtocol, .mrp)
        XCTAssertEqual(result.activeProtocols, [.mrp])
        XCTAssertEqual(result.attempts.map(\.protocol), [.mrp])
        XCTAssertTrue(result.attempts.allSatisfy(\.succeeded))
    }

    func testConnectFallsBackAfterSupportedProtocolFailure() async throws {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "01:02:03:04"
        let recorder = AttemptRecorder()

        _ = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                recorder.append(service, credentials: credentials)
                if service.protocol == .mrp {
                    throw ATVError.connectionFailed(message: "MRP failed")
                }
                facade._testSetActiveProtocols(Set(recorder.protocols), primary: recorder.protocols.first)
            },
            operation: {
                try await ATVClient.connect(config, settings: settings)
            }
        )

        XCTAssertEqual(recorder.protocols, [.mrp, .companion])
    }

    func testConnectAllAllowedAttachesEveryUsableProtocol() async throws {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.protocols.companion.credentials = "01:02:03:04"
        let recorder = AttemptRecorder()

        let result = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                Self.recordSuccessfulSetup(
                    on: facade,
                    service: service,
                    credentials: credentials,
                    recorder: recorder
                )
            },
            operation: {
                try await ATVClient.connect(
                    config,
                    options: ConnectOptions(strategy: .allAllowed),
                    settings: settings
                )
            }
        )

        XCTAssertEqual(recorder.protocols, [.mrp, .companion])
        XCTAssertEqual(result.primaryProtocol, .mrp)
        XCTAssertEqual(result.activeProtocols, [.mrp, .companion])
        XCTAssertEqual(result.attempts.map(\.protocol), [.mrp, .companion])
        XCTAssertTrue(result.attempts.allSatisfy(\.succeeded))
    }

    func testConnectAttemptsAirPlayTunnelBeforeCompanionAfterMRPFailure() async throws {
        let credentials = "01:02:03:04"
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        config.addService(
            ServiceInfo(
                protocol: .airPlay,
                port: 7000,
                properties: ["features": "0x4000000000", "model": "AppleTV11,1", "osvers": "16.0"]
            ))
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.protocols.airplay.credentials = credentials
        let recorder = AttemptRecorder()

        _ = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                recorder.append(service, credentials: credentials)
                if service.protocol == .mrp {
                    throw ATVError.connectionFailed(message: "MRP failed")
                }
                facade._testSetActiveProtocols(Set(recorder.protocols), primary: recorder.protocols.first)
            },
            operation: {
                try await ATVClient.connect(config, settings: settings)
            }
        )

        XCTAssertEqual(recorder.protocols, [.mrp, .airPlay])
        XCTAssertEqual(recorder.credentials(for: .airPlay), credentials)
    }

    func testConnectSkipsAirPlayTunnelAfterDirectMRPSucceeds() async throws {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        config.addService(
            ServiceInfo(
                protocol: .airPlay,
                port: 7000,
                properties: ["features": "0x4000000000", "model": "AppleTV11,1", "osvers": "16.0"]
            ))
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.protocols.airplay.credentials = "01:02:03:04"
        let recorder = AttemptRecorder()

        _ = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                Self.recordSuccessfulSetup(
                    on: facade,
                    service: service,
                    credentials: credentials,
                    recorder: recorder
                )
            },
            operation: {
                try await ATVClient.connect(config, settings: settings)
            }
        )

        XCTAssertEqual(recorder.protocols, [.mrp])
    }

    func testExplicitAirPlayUsesCompanionCredentialFallback() async throws {
        let companionCredentials = "01:02:03:04"
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(
            ServiceInfo(
                protocol: .airPlay,
                port: 7000,
                properties: ["features": "0x4000000000", "model": "AppleTV11,1", "osvers": "16.0"]
            ))
        config.addService(
            ServiceInfo(
                protocol: .companion,
                port: 49153,
                credentials: companionCredentials,
                pairingRequirement: .mandatory
            ))
        let recorder = AttemptRecorder()

        _ = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                Self.recordSuccessfulSetup(
                    on: facade,
                    service: service,
                    credentials: credentials,
                    recorder: recorder
                )
            },
            operation: {
                try await ATVClient.connect(config, options: ConnectOptions(protocols: [.airPlay]))
            }
        )

        XCTAssertEqual(recorder.protocols, [.airPlay])
        XCTAssertEqual(recorder.credentials(for: .airPlay), companionCredentials)
    }

    func testConnectRequestedProtocolDoesNotFallBack() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        let recorder = AttemptRecorder()

        do {
            _ = try await ATVClient.withProtocolSetupOverride(
                { _, service, credentials in
                    recorder.append(service, credentials: credentials)
                    throw ATVError.connectionFailed(message: "requested protocol failed")
                },
                operation: {
                    try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]))
                }
            )
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }

        XCTAssertEqual(recorder.protocols, [.mrp])
    }

    func testAutoConnectAggregatesProtocolFailures() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        let recorder = AttemptRecorder()

        do {
            _ = try await ATVClient.withProtocolSetupOverride(
                { _, service, credentials in
                    recorder.append(service, credentials: credentials)
                    throw ATVError.connectionFailed(message: "\(service.protocol) failed")
                },
                operation: {
                    try await ATVClient.connect(config)
                }
            )
            XCTFail("Expected connect to throw")
        } catch let error as ATVError {
            guard case ATVError.connectionFailed(let message, let attempts) = error else {
                XCTFail("Expected aggregate connectionFailed, got \(error)")
                return
            }
            XCTAssertEqual(message, "No usable protocol connected")
            XCTAssertEqual(attempts.map(\.protocol), [ATVProtocol.mrp, .companion])
            guard case .connectionFailed = attempts[0].error else {
                XCTFail("Expected MRP connectionFailed, got \(attempts[0].error)")
                return
            }
            guard case .noCredentials = attempts[1].error else {
                XCTFail("Expected Companion noCredentials, got \(attempts[1].error)")
                return
            }
            XCTAssertTrue(error.localizedDescription.contains("MRP"))
            XCTAssertTrue(error.localizedDescription.contains("Companion"))
        } catch {
            XCTFail("Expected ATVError, got \(error)")
        }

        XCTAssertEqual(recorder.protocols, [.mrp])
    }

    func testConnectCompanionWithoutCredentialsFailsBeforeSetup() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .optional))
        let recorder = AttemptRecorder()

        do {
            _ = try await ATVClient.withProtocolSetupOverride(
                { _, service, credentials in
                    recorder.append(service, credentials: credentials)
                },
                operation: {
                    try await ATVClient.connect(config, options: ConnectOptions(protocols: [.companion]))
                }
            )
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.noCredentials = error else {
                XCTFail("Expected noCredentials, got \(error)")
                return
            }
        }

        XCTAssertEqual(recorder.protocols, [])
    }

    func testConnectUsesServiceCredentialsWhenSettingsAreMissing() async throws {
        let serviceCredentials = "01:02:03:04"
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(
            ServiceInfo(
                protocol: .mrp,
                port: 49152,
                credentials: serviceCredentials,
                pairingRequirement: .mandatory
            ))
        let recorder = AttemptRecorder()

        _ = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                Self.recordSuccessfulSetup(
                    on: facade,
                    service: service,
                    credentials: credentials,
                    recorder: recorder
                )
            },
            operation: {
                try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]))
            }
        )

        XCTAssertEqual(recorder.credentials(for: .mrp), serviceCredentials)
    }

    func testConnectSettingsCredentialsOverrideServiceCredentials() async throws {
        let serviceCredentials = "01:02:03:04"
        let settingsCredentials = "0a:0b:0c:0d"
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(
            ServiceInfo(
                protocol: .mrp,
                port: 49152,
                credentials: serviceCredentials,
                pairingRequirement: .mandatory
            ))
        var settings = ATVSettings()
        settings.protocols.mrp.credentials = settingsCredentials
        let recorder = AttemptRecorder()

        _ = try await ATVClient.withProtocolSetupOverride(
            { facade, service, credentials in
                Self.recordSuccessfulSetup(
                    on: facade,
                    service: service,
                    credentials: credentials,
                    recorder: recorder
                )
            },
            operation: {
                try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]), settings: settings)
            }
        )

        XCTAssertEqual(recorder.credentials(for: .mrp), settingsCredentials)
    }

    func testConnectMandatoryPairingWithoutCredentialsFailsBeforeSetup() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .mandatory))
        let recorder = AttemptRecorder()

        do {
            _ = try await ATVClient.withProtocolSetupOverride(
                { _, service, credentials in
                    recorder.append(service, credentials: credentials)
                },
                operation: {
                    try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]))
                }
            )
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.noCredentials = error else {
                XCTFail("Expected noCredentials, got \(error)")
                return
            }
        }

        XCTAssertEqual(recorder.protocols, [])
    }

    func testServiceCredentialsMalformedCredentialsThrowInvalidCredentials() async {
        var config = AppleTVConfiguration(address: "127.0.0.1", name: "Test")
        config.addService(
            ServiceInfo(
                protocol: .mrp,
                port: 49152,
                credentials: "not-valid-hap-credentials",
                pairingRequirement: .mandatory
            ))

        do {
            _ = try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]))
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.invalidCredentials = error else {
                XCTFail("Expected invalidCredentials, got \(error)")
                return
            }
        }
    }

    func testConnectRejectsTargetIdentityAsClientIdentity() async {
        var config = AppleTVConfiguration(
            address: "127.0.0.1",
            name: "Test",
            identifier: "target-device"
        )
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.clientIdentity.deviceID = "target-device"

        do {
            _ = try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]), settings: settings)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.settingsError = error else {
                XCTFail("Expected settingsError, got \(error)")
                return
            }
        }
    }

    func testConnectRejectsMacLikeTargetIdentityCaseInsensitively() async {
        let config = AppleTVConfiguration(
            address: "127.0.0.1",
            name: "Test",
            services: [
                ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional)
            ],
            deviceInfo: DeviceInfo(macAddress: "AA:BB:CC:DD:EE:FF")
        )
        var settings = ATVSettings()
        settings.clientIdentity.macAddress = "aa-bb-cc-dd-ee-ff"

        do {
            _ = try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]), settings: settings)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.settingsError = error else {
                XCTFail("Expected settingsError, got \(error)")
                return
            }
        }
    }

    func testPairRejectsTargetIdentityAsClientIdentity() async {
        var config = AppleTVConfiguration(
            address: "127.0.0.1",
            name: "Test",
            identifier: "target-device"
        )
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.clientIdentity.pairingIdentifier = "target-device"

        do {
            _ = try await ATVClient.pair(config, protocol: .mrp, settings: settings)
            XCTFail("Expected pair to throw")
        } catch let error {
            guard case ATVError.settingsError = error else {
                XCTFail("Expected settingsError, got \(error)")
                return
            }
        }
    }

    func testConnectRejectsTargetIdentityAsRapportIdentifier() async {
        var config = AppleTVConfiguration(
            address: "127.0.0.1",
            name: "Test",
            identifier: "target-device"
        )
        config.addService(ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional))
        var settings = ATVSettings()
        settings.clientIdentity.rapportIdentifier = "target-device"

        do {
            _ = try await ATVClient.connect(config, options: ConnectOptions(protocols: [.mrp]), settings: settings)
            XCTFail("Expected connect to throw")
        } catch let error {
            guard case ATVError.settingsError = error else {
                XCTFail("Expected settingsError, got \(error)")
                return
            }
        }
    }

    func testPairingServiceValidationRejectsUnavailableStates() {
        XCTAssertNoThrow(
            try ATVClient.validatePairingService(
                ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .optional)
            )
        )
        XCTAssertNoThrow(
            try ATVClient.validatePairingService(
                ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .mandatory)
            )
        )

        XCTAssertThrowsError(
            try ATVClient.validatePairingService(
                ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .disabled)
            )
        ) { error in
            guard case ATVError.pairingFailed = error else {
                XCTFail("Expected pairingFailed, got \(error)")
                return
            }
        }
        XCTAssertThrowsError(
            try ATVClient.validatePairingService(
                ServiceInfo(protocol: .mrp, port: 49152, pairingRequirement: .unsupported)
            )
        ) { error in
            guard case ATVError.notSupported = error else {
                XCTFail("Expected notSupported, got \(error)")
                return
            }
        }
        XCTAssertThrowsError(
            try ATVClient.validatePairingService(
                ServiceInfo(protocol: .companion, port: 49153, pairingRequirement: .notNeeded)
            )
        ) { error in
            guard case ATVError.notSupported = error else {
                XCTFail("Expected notSupported, got \(error)")
                return
            }
        }
        XCTAssertNoThrow(
            try ATVClient.validatePairingService(
                ServiceInfo(protocol: .airPlay, port: 7000, pairingRequirement: .notNeeded)
            )
        )
    }
}
