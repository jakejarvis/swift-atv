#if canImport(Network)
    import XCTest

    @testable import SwiftATV

    final class ScannerTests: XCTestCase {
        func testCompanionPairingRequirementUsesRpflMask() {
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["rpfl": "0x36782"],
                    for: .companion
                ),
                .mandatory
            )
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["rpFl": "0x627B6"],
                    for: .companion
                ),
                .disabled
            )
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["flags": "512"],
                    for: .companion
                ),
                .unsupported
            )
        }

        func testMRPPairingRequirementUsesAllowPairing() {
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["AllowPairing": "YES"],
                    for: .mrp
                ),
                .optional
            )
            XCTAssertEqual(
                ATVScanner.pairingRequirement(
                    from: ["allowpairing": "no"],
                    for: .mrp
                ),
                .disabled
            )
        }

        func testScanRejectsNegativeTimeout() async {
            do {
                _ = try await ATVClient.scan(timeout: -1)
                XCTFail("Expected scan to throw")
            } catch let error {
                guard case ATVError.invalidConfig = error else {
                    XCTFail("Expected invalidConfig, got \(error)")
                    return
                }
            }
        }

        func testCompanionOnlyRpMRtIDProducesMainIdentifier() {
            let services = [
                DiscoveredService(
                    serviceType: .companion,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 49153,
                    txtRecord: ["rpMRtID": "AE83CCCA-18A3-46E0-A0FF-19734889F37B"]
                )
            ]

            let configs = ATVScanner.configurations(from: services)

            XCTAssertEqual(configs.count, 1)
            XCTAssertEqual(
                configs[0].identifier,
                "AE83CCCA-18A3-46E0-A0FF-19734889F37B"
            )
            XCTAssertEqual(
                configs[0].mainIdentifier,
                "AE83CCCA-18A3-46E0-A0FF-19734889F37B"
            )
            XCTAssertEqual(
                configs[0].service(for: .companion)?.identifier,
                "AE83CCCA-18A3-46E0-A0FF-19734889F37B"
            )
            XCTAssertEqual(
                configs[0].allIdentifiers,
                ["AE83CCCA-18A3-46E0-A0FF-19734889F37B"]
            )
        }

        func testCompanionOnlyIdentifiersFallBackToRpADOrRpHN() throws {
            let rpADServices = [
                DiscoveredService(
                    serviceType: .companion,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 49153,
                    txtRecord: [
                        "rpMRtID": "",
                        "rpAD": "8df5532cf728",
                        "rpHN": "158599555ae3",
                    ]
                )
            ]
            let rpHNServices = [
                DiscoveredService(
                    serviceType: .companion,
                    name: "Master Bedroom",
                    host: "192.168.1.11",
                    port: 49153,
                    txtRecord: [
                        "rpAD": " ",
                        "rpHN": "158599555ae3",
                    ]
                )
            ]

            let rpADConfig = try XCTUnwrap(ATVScanner.configurations(from: rpADServices).first)
            let rpHNConfig = try XCTUnwrap(ATVScanner.configurations(from: rpHNServices).first)

            XCTAssertEqual(rpADConfig.mainIdentifier, "8df5532cf728")
            XCTAssertEqual(rpADConfig.service(for: .companion)?.identifier, "8df5532cf728")
            XCTAssertEqual(rpADConfig.allIdentifiers, ["8df5532cf728", "158599555ae3"])
            XCTAssertEqual(rpHNConfig.mainIdentifier, "158599555ae3")
            XCTAssertEqual(rpHNConfig.service(for: .companion)?.identifier, "158599555ae3")
        }

        func testCompanionIdentifierLookupIsCaseInsensitive() throws {
            let services = [
                DiscoveredService(
                    serviceType: .companion,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 49153,
                    txtRecord: ["rpmrtid": "AE83CCCA-18A3-46E0-A0FF-19734889F37B"]
                )
            ]

            let config = try XCTUnwrap(ATVScanner.configurations(from: services).first)

            XCTAssertEqual(
                config.mainIdentifier,
                "AE83CCCA-18A3-46E0-A0FF-19734889F37B"
            )
        }

        func testConfigurationsMergeBySharedServiceIdentifierAcrossAddresses() {
            let services = [
                DiscoveredService(
                    serviceType: .mrp,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 49152,
                    txtRecord: ["UniqueIdentifier": "device-1", "model": "AppleTV6,2"]
                ),
                DiscoveredService(
                    serviceType: .companion,
                    name: "Living Room",
                    host: "fe80::1",
                    port: 49153,
                    txtRecord: ["UniqueIdentifier": "device-1", "rpfl": "0x4000"]
                ),
                DiscoveredService(
                    serviceType: .deviceInfo,
                    name: "Living Room",
                    host: "fe80::2",
                    port: 0,
                    txtRecord: ["deviceid": "device-1", "model": "AppleTV6,2"]
                ),
            ]

            let configs = ATVScanner.configurations(from: services)

            XCTAssertEqual(configs.count, 1)
            XCTAssertEqual(Set(configs[0].services.map(\.protocol)), [.mrp, .companion])
            XCTAssertEqual(configs[0].allIdentifiers, ["device-1"])
            XCTAssertEqual(configs[0].deviceInfo.model, .gen4K)
        }

        func testConfigurationsMergeBySharedCompanionIdentifierAcrossAddresses() {
            let services = [
                DiscoveredService(
                    serviceType: .mrp,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 49152,
                    txtRecord: ["UniqueIdentifier": "8df5532cf728"]
                ),
                DiscoveredService(
                    serviceType: .companion,
                    name: "Living Room",
                    host: "fe80::1",
                    port: 49153,
                    txtRecord: [
                        "rpMRtID": "AE83CCCA-18A3-46E0-A0FF-19734889F37B",
                        "rpAD": "8df5532cf728",
                    ]
                ),
            ]

            let configs = ATVScanner.configurations(from: services)

            XCTAssertEqual(configs.count, 1)
            XCTAssertEqual(Set(configs[0].services.map(\.protocol)), [.mrp, .companion])
            XCTAssertEqual(
                configs[0].allIdentifiers,
                ["8df5532cf728", "AE83CCCA-18A3-46E0-A0FF-19734889F37B"]
            )
        }

        func testExistingMRPAndAirPlayIdentifierBehaviorDoesNotRegress() throws {
            let services = [
                DiscoveredService(
                    serviceType: .mrp,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 49152,
                    txtRecord: ["UniqueIdentifier": "mrp-id"]
                ),
                DiscoveredService(
                    serviceType: .airPlay,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 7000,
                    txtRecord: ["deviceid": "AA:BB:CC:DD:EE:FF"]
                ),
            ]

            let config = try XCTUnwrap(ATVScanner.configurations(from: services).first)

            XCTAssertEqual(config.service(for: .mrp)?.identifier, "mrp-id")
            XCTAssertEqual(config.service(for: .airPlay)?.identifier, "AA:BB:CC:DD:EE:FF")
            XCTAssertEqual(config.mainIdentifier, "mrp-id")
            XCTAssertEqual(config.allIdentifiers, ["mrp-id", "AA:BB:CC:DD:EE:FF"])
        }

        func testScanResultPreservesDiagnosticsWhenNoDevicesWereFound() {
            let diagnostic = ATVScanDiagnostic(
                serviceType: .companion,
                kind: .browserFailed,
                message: "NoAuth"
            )

            let result = ATVScanner.scanResult(
                from: [],
                diagnostics: [diagnostic]
            )

            XCTAssertTrue(result.devices.isEmpty)
            XCTAssertEqual(result.diagnostics, [diagnostic])
        }

        func testConfigurationsMergeByAddressWhenIdentifiersAreMissing() {
            let services = [
                DiscoveredService(
                    serviceType: .airPlay,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 7000,
                    txtRecord: [:]
                ),
                DiscoveredService(
                    serviceType: .raop,
                    name: "Living Room",
                    host: "192.168.1.10",
                    port: 7000,
                    txtRecord: [:]
                ),
            ]

            let configs = ATVScanner.configurations(from: services)

            XCTAssertEqual(configs.count, 1)
            XCTAssertEqual(Set(configs[0].services.map(\.protocol)), [.airPlay, .raop])
        }
    }
#endif
