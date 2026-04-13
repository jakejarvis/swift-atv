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
                _ = try await SwiftATV.scan(timeout: -1)
                XCTFail("Expected scan to throw")
            } catch let error {
                guard case ATVError.invalidConfig = error else {
                    XCTFail("Expected invalidConfig, got \(error)")
                    return
                }
            }
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
