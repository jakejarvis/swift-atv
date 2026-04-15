import XCTest

@testable import SwiftATV

final class FacadeEventTests: XCTestCase {
    func testUnsupportedMetadataThrowsNotSupported() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )

        do {
            _ = try await facade.metadata.playing()
            XCTFail("Expected playing() to throw")
        } catch let error {
            guard case ATVError.notSupported(let message) = error else {
                XCTFail("Expected notSupported, got \(error)")
                return
            }
            XCTAssertEqual(message, "Metadata not available")
        }

        do {
            _ = try await facade.metadata.artwork()
            XCTFail("Expected artwork() to throw")
        } catch let error {
            guard case ATVError.notSupported(let message) = error else {
                XCTFail("Expected notSupported, got \(error)")
                return
            }
            XCTAssertEqual(message, "Metadata not available")
        }
    }

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

    func testLateDeviceEventsSubscriberReceivesTerminalEventAndFinish() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )

        await facade.close()

        var iterator = facade.deviceEvents.makeAsyncIterator()
        guard let event = await iterator.next() else {
            XCTFail("Expected pending terminal event")
            return
        }
        guard case .connectionClosed = event else {
            XCTFail("Expected connectionClosed, got \(event)")
            return
        }
        let next = await iterator.next()
        XCTAssertNil(next)
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

    func testSecondaryCompanionCloseClosesRemovedService() async {
        let facade = FacadeAppleTV(
            configuration: AppleTVConfiguration(address: "127.0.0.1", name: "Test"),
            settings: ATVSettings()
        )
        let companion = CompanionService(
            host: "127.0.0.1",
            port: 0,
            settings: ATVSettings(),
            touchStartTimeout: 0.05
        )
        facade._testSetActiveProtocols([.mrp, .companion], primary: .mrp)
        facade._testSetCompanionService(companion)

        facade._testProtocolConnectionDidClose(error: nil, protocol: .companion)

        let didClose = await eventually(timeoutNanoseconds: 500_000_000) {
            !companion._testIsConnected
        }
        XCTAssertTrue(didClose)
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

    private func eventually(
        timeoutNanoseconds: UInt64,
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
