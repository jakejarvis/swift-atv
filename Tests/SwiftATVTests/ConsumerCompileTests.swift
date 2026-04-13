import Foundation
import SwiftATV
import XCTest

final class ConsumerCompileTests: XCTestCase {
    func testModuleQualifiedTypesCompileAlongsideFacadeName() {
        let protocolName: SwiftATV.ATVProtocol = .mrp
        let service = SwiftATV.ServiceInfo(
            protocol: protocolName,
            port: SwiftATV.ServiceInfo.defaultMRPPort
        )
        let config = SwiftATV.AppleTVConfiguration(
            address: "127.0.0.1",
            name: "Living Room",
            services: [service]
        )
        let settings = SwiftATV.ATVSettings()

        XCTAssertEqual(ATVClient.version, "0.2.2")
        XCTAssertEqual(config.service(for: protocolName)?.port, SwiftATV.ServiceInfo.defaultMRPPort)
        XCTAssertNil(settings.credentials(for: protocolName))
    }

    func testFacadeFunctionReferencesCompileForConsumers() {
        let connect:
            (
                SwiftATV.AppleTVConfiguration,
                SwiftATV.ATVProtocol?,
                SwiftATV.ATVSettings?
            ) async throws(SwiftATV.ATVError) -> any SwiftATV.AppleTVDevice = ATVClient.connect
        let pair:
            (
                SwiftATV.AppleTVConfiguration,
                SwiftATV.ATVProtocol
            ) async throws(SwiftATV.ATVError) -> any SwiftATV.PairingHandler = ATVClient.pair

        _ = connect
        _ = pair
    }

    #if canImport(Network)
        func testScanFunctionReferenceCompilesForConsumers() {
            let scan:
                (
                    TimeInterval,
                    Set<String>?,
                    Set<SwiftATV.ATVProtocol>?
                ) async throws(SwiftATV.ATVError) -> [SwiftATV.AppleTVConfiguration] = ATVClient.scan
            let scanWithDiagnostics:
                (
                    TimeInterval,
                    Set<String>?,
                    Set<SwiftATV.ATVProtocol>?
                ) async throws(SwiftATV.ATVError) -> SwiftATV.ATVScanResult =
                    ATVClient.scanWithDiagnostics
            let diagnostic = SwiftATV.ATVScanDiagnostic(
                serviceType: .companion,
                kind: .browserFailed,
                message: "example"
            )
            let result = SwiftATV.ATVScanResult(devices: [], diagnostics: [diagnostic])

            _ = scan
            _ = scanWithDiagnostics
            XCTAssertEqual(result.diagnostics.first?.kind, .browserFailed)
        }
    #endif
}
