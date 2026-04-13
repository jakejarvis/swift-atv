import XCTest

@testable import SwiftATV

final class FacadeEventTests: XCTestCase {
    func testExplicitCloseEmitsConnectionClosed() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )
        let stream = facade.deviceEvents
        let eventTask = Task { () -> DeviceEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await facade.close()

        guard let event = await eventTask.value else {
            XCTFail("Expected a device event")
            return
        }
        guard case .connectionClosed = event else {
            XCTFail("Expected connectionClosed, got \(event)")
            return
        }
    }

    func testProtocolCloseEmitsConnectionLost() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )
        let stream = facade.deviceEvents
        let eventTask = Task { () -> DeviceEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        facade._testProtocolConnectionDidClose(error: nil, protocol: .mrp)

        guard let event = await eventTask.value else {
            XCTFail("Expected a device event")
            return
        }
        guard case .connectionLost = event else {
            XCTFail("Expected connectionLost, got \(event)")
            return
        }
    }
}
