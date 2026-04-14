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
        let identity = SwiftATV.ClientIdentitySettings(name: "Clicker")
        let settings = SwiftATV.ATVSettings(clientIdentity: identity)

        XCTAssertFalse(ATVClient.version.isEmpty)
        XCTAssertNotNil(
            ATVClient.version.range(
                of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#,
                options: .regularExpression
            )
        )
        XCTAssertEqual(config.service(for: protocolName)?.port, SwiftATV.ServiceInfo.defaultMRPPort)
        XCTAssertNil(settings.credentials(for: protocolName))
        XCTAssertEqual(settings.clientIdentity.name, "Clicker")
    }

    func testCapabilityTypesCompileForConsumers() {
        let capability: SwiftATV.Capability = .mediaCommand(.play)
        let info = SwiftATV.CapabilityInfo(state: .available)
        let options = SwiftATV.MediaCommandOptions(skipInterval: 15)
        let commandInfo = SwiftATV.MediaCommandInfo(
            state: .available,
            preferredIntervals: [15, 30],
            localizedTitle: "Skip"
        )

        XCTAssertEqual(capability.identifier, "mediaCommand.play")
        XCTAssertEqual(info.state, .available)
        XCTAssertEqual(options.skipInterval, 15)
        XCTAssertEqual(commandInfo.preferredIntervals, [15, 30])
    }

    func testFacadeFunctionReferencesCompileForConsumers() {
        let connect:
            (
                SwiftATV.AppleTVConfiguration,
                SwiftATV.ConnectOptions,
                SwiftATV.ATVSettings?
            ) async throws(SwiftATV.ATVError) -> SwiftATV.ConnectResult = ATVClient.connect
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
