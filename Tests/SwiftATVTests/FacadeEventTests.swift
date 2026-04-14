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
        facade._testSetActiveProtocols([.mrp], primary: .mrp)
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

    func testUnregisteredProtocolCloseDoesNotEmitConnectionLost() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )
        let stream = facade.deviceEvents

        facade._testProtocolConnectionDidClose(error: nil, protocol: .companion)

        let event = await nextEvent(from: stream, timeoutNanoseconds: 50_000_000)
        XCTAssertNil(event)
        XCTAssertTrue(facade._testActiveProtocols.isEmpty)
    }

    func testSecondaryProtocolCloseDoesNotEmitConnectionLost() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )
        facade._testSetActiveProtocols([.mrp, .companion], primary: .mrp)
        let stream = facade.deviceEvents

        facade._testProtocolConnectionDidClose(error: nil, protocol: .companion)

        let event = await nextEvent(from: stream, timeoutNanoseconds: 50_000_000)
        XCTAssertNil(event)
        XCTAssertEqual(facade._testActiveProtocols, [.mrp])
    }

    func testPrimaryProtocolCloseEmitsConnectionLost() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )
        facade._testSetActiveProtocols([.mrp, .companion], primary: .mrp)
        let stream = facade.deviceEvents

        facade._testProtocolConnectionDidClose(error: nil, protocol: .mrp)

        guard let event = await nextEvent(from: stream, timeoutNanoseconds: 500_000_000) else {
            XCTFail("Expected a device event")
            return
        }
        guard case .connectionLost = event else {
            XCTFail("Expected connectionLost, got \(event)")
            return
        }
    }

    private func nextEvent(
        from stream: AsyncStream<DeviceEvent>,
        timeoutNanoseconds: UInt64
    ) async -> DeviceEvent? {
        await withTaskGroup(of: DeviceEvent?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let event = await group.next()!
            group.cancelAll()
            return event
        }
    }
}
