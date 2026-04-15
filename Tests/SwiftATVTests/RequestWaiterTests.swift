import Foundation
import Testing

@testable import SwiftATV

private final class CountingMRPDelegate: MRPConnectionDelegate, @unchecked Sendable {
    let lock = NSLock()
    private var _receiveCount = 0
    var receiveCount: Int { lock.withLock { _receiveCount } }

    func connectionDidReceiveMessage(_ message: ProtocolMessageMessage) async {
        lock.withLock { _receiveCount += 1 }
    }

    func connectionDidClose(error: Error?) async {}
}

@Suite("Request waiters")
struct RequestWaiterTests {
    private func waitForInstall() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func protocolMessage(
        type: ProtocolMessageMessage.TypeEnum,
        identifier: String? = nil
    ) -> ProtocolMessageMessage {
        var message = ProtocolMessageMessage()
        message.type = type
        if let identifier {
            message.identifier = identifier
        }
        return message
    }

    private func frame(_ message: ProtocolMessageMessage) throws -> Data {
        let payload = try message.serializedData()
        return MRPVarint.encode(payload.count) + payload
    }

    private func expectOperationCancelled<T>(
        _ task: Task<T, any Error>
    ) async {
        do {
            _ = try await task.value
            Issue.record("Expected operationCancelled")
        } catch let error as ATVError {
            guard case .operationCancelled = error else {
                Issue.record("Expected operationCancelled, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("direct MRP waiter requires matching identifier and response type")
    func directMRPWaiterMatchesIdentifierAndType() async throws {
        let connection = MRPConnection(host: "127.0.0.1", port: 0)
        let task = Task {
            try await connection._testWaitForResponse(
                identifier: "same-id",
                type: .sendCommandResultMessage,
                timeout: 5
            )
        }
        await waitForInstall()

        connection.handleReceivedData(
            try frame(protocolMessage(type: .deviceInfoMessage, identifier: "same-id"))
        )
        await waitForInstall()
        #expect(connection._testPendingWaiterCount == 1)

        connection.handleReceivedData(
            try frame(protocolMessage(type: .sendCommandResultMessage, identifier: "same-id"))
        )
        let response = try await task.value
        #expect(response.type == .sendCommandResultMessage)
        #expect(connection._testPendingWaiterCount == 0)
    }

    @Test("MRP crypto-pairing requests omit identifiers")
    func mrpCryptoPairingRequestsOmitIdentifiers() {
        let request = MRPMessages.cryptoPairing(Data([0x06, 0x01, 0x01]))
        let prepared = prepareMRPRequestForResponse(request, responseType: nil)
        let crypto = request.cryptoPairingMessage

        #expect(request.type == .cryptoPairingMessage)
        #expect(!request.hasIdentifier)
        #expect(request.hasUniqueIdentifier)
        #expect(crypto.hasIsRetrying)
        #expect(!crypto.isRetrying)
        #expect(crypto.hasIsUsingSystemPairing)
        #expect(!crypto.isUsingSystemPairing)
        #expect(crypto.hasState)
        #expect(crypto.state == 0)
        #expect(prepared.responseIdentifier == nil)
        #expect(prepared.responseType == .cryptoPairingMessage)
        #expect(!prepared.message.hasIdentifier)
        #expect(prepared.message.hasUniqueIdentifier)
    }

    @Test("MRP response preparation adds identifiers without dropping unique identifiers")
    func mrpResponsePreparationAddsIdentifiersWithoutDroppingUniqueIdentifiers() {
        let request = MRPMessages.generic()
        let prepared = prepareMRPRequestForResponse(request, responseType: nil)

        #expect(!request.hasIdentifier)
        #expect(request.hasUniqueIdentifier)
        #expect(prepared.message.hasIdentifier)
        #expect(prepared.responseIdentifier == prepared.message.identifier)
        #expect(prepared.message.uniqueIdentifier == request.uniqueIdentifier)
        #expect(prepared.responseType == .genericMessage)
    }

    @Test("MRP pair-setup start request uses pairing state")
    func mrpPairSetupStartRequestUsesPairingState() {
        let request = MRPMessages.cryptoPairing(Data([0x06, 0x01, 0x01]), isPairing: true)

        #expect(request.cryptoPairingMessage.hasState)
        #expect(request.cryptoPairingMessage.state == 2)
    }

    @Test("direct MRP type-only waiter matches identifierless crypto pairing response")
    func directMRPTypeOnlyWaiterMatchesIdentifierlessCryptoPairingResponse() async throws {
        let connection = MRPConnection(host: "127.0.0.1", port: 0)
        let task = Task {
            try await connection._testWaitForTypeResponse(
                type: .cryptoPairingMessage,
                timeout: 5
            )
        }
        await waitForInstall()

        connection.handleReceivedData(
            try frame(protocolMessage(type: .cryptoPairingMessage, identifier: "unexpected-id"))
        )
        await waitForInstall()
        #expect(connection._testPendingWaiterCount == 1)

        connection.handleReceivedData(
            try frame(protocolMessage(type: .cryptoPairingMessage))
        )
        let response = try await task.value
        #expect(response.type == .cryptoPairingMessage)
        #expect(!response.hasIdentifier)
        #expect(connection._testPendingWaiterCount == 0)
    }

    @Test("direct MRP ignores messages delivered after close")
    func directMRPIgnoresMessagesDeliveredAfterClose() async throws {
        let delegate = CountingMRPDelegate()
        let connection = MRPConnection(host: "127.0.0.1", port: 0)
        connection.delegate = delegate

        connection.handleConnectionClosed(error: nil)
        connection.handleReceivedData(try frame(protocolMessage(type: .genericMessage)))

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(delegate.receiveCount == 0)
    }

    @Test("AirPlay MRP tunnel waiter requires matching identifier and response type")
    func airPlayMRPWaiterMatchesIdentifierAndType() async throws {
        let transport = AirPlayMRPTunnelTransport(
            host: "127.0.0.1",
            port: 7000,
            credentialCandidates: [],
            settings: ATVSettings()
        )
        let task = Task {
            try await transport._testWaitForResponse(
                identifier: "same-id",
                type: .sendCommandResultMessage,
                timeout: 5
            )
        }
        await waitForInstall()

        transport._testHandleReceivedMessage(
            protocolMessage(type: .deviceInfoMessage, identifier: "same-id")
        )
        await waitForInstall()
        #expect(transport._testPendingWaiterCount == 1)

        transport._testHandleReceivedMessage(
            protocolMessage(type: .sendCommandResultMessage, identifier: "same-id")
        )
        let response = try await task.value
        #expect(response.type == .sendCommandResultMessage)
        #expect(transport._testPendingWaiterCount == 0)
    }

    @Test("AirPlay MRP tunnel type-only waiter matches identifierless crypto pairing response")
    func airPlayMRPTypeOnlyWaiterMatchesIdentifierlessCryptoPairingResponse() async throws {
        let transport = AirPlayMRPTunnelTransport(
            host: "127.0.0.1",
            port: 7000,
            credentialCandidates: [],
            settings: ATVSettings()
        )
        let task = Task {
            try await transport._testWaitForTypeResponse(
                type: .cryptoPairingMessage,
                timeout: 5
            )
        }
        await waitForInstall()

        transport._testHandleReceivedMessage(
            protocolMessage(type: .cryptoPairingMessage, identifier: "unexpected-id")
        )
        await waitForInstall()
        #expect(transport._testPendingWaiterCount == 1)

        transport._testHandleReceivedMessage(
            protocolMessage(type: .cryptoPairingMessage)
        )
        let response = try await task.value
        #expect(response.type == .cryptoPairingMessage)
        #expect(!response.hasIdentifier)
        #expect(transport._testPendingWaiterCount == 0)
    }

    @Test("AirPlay MRP tunnel ignores messages delivered after close")
    func airPlayMRPTunnelIgnoresMessagesDeliveredAfterClose() async throws {
        let delegate = CountingMRPDelegate()
        let transport = AirPlayMRPTunnelTransport(
            host: "127.0.0.1",
            port: 7000,
            credentialCandidates: [],
            settings: ATVSettings()
        )
        transport.delegate = delegate

        await transport.close()
        transport._testHandleReceivedMessage(protocolMessage(type: .genericMessage))

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(delegate.receiveCount == 0)
    }

    @Test("direct MRP waiter is cancellation-aware")
    func directMRPWaiterCancellationRemovesWaiter() async {
        let connection = MRPConnection(host: "127.0.0.1", port: 0)
        let task = Task {
            try await connection._testWaitForResponse(
                identifier: "cancel-id",
                type: .genericMessage,
                timeout: 60
            )
        }
        await waitForInstall()
        #expect(connection._testPendingWaiterCount == 1)

        task.cancel()
        await expectOperationCancelled(task)
        #expect(connection._testPendingWaiterCount == 0)
    }

    @Test("AirPlay MRP tunnel waiter is cancellation-aware")
    func airPlayMRPWaiterCancellationRemovesWaiter() async {
        let transport = AirPlayMRPTunnelTransport(
            host: "127.0.0.1",
            port: 7000,
            credentialCandidates: [],
            settings: ATVSettings()
        )
        let task = Task {
            try await transport._testWaitForResponse(
                identifier: "cancel-id",
                type: .genericMessage,
                timeout: 60
            )
        }
        await waitForInstall()
        #expect(transport._testPendingWaiterCount == 1)

        task.cancel()
        await expectOperationCancelled(task)
        #expect(transport._testPendingWaiterCount == 0)
    }

    @Test("AirPlay TCP receive waiter is cancellation-aware")
    func airPlayTCPReceiveCancellationRemovesWaiter() async {
        let connection = AirPlayTCPConnection(host: "127.0.0.1", port: 0)
        let task = Task { try await connection.receive(timeout: 60) }
        await waitForInstall()
        #expect(connection._testHasDataWaiter)

        task.cancel()
        await expectOperationCancelled(task)
        #expect(!connection._testHasDataWaiter)
    }

    @Test("Companion request waiter is cancellation-aware")
    func companionRequestCancellationRemovesWaiter() async {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let handler = CompanionProtocolHandler(connection: connection)
        let task = Task { try await handler._testInstallPendingRequest(xid: 42) }
        await waitForInstall()
        #expect(await handler._testPendingRequestCount() == 1)

        task.cancel()
        await expectOperationCancelled(task)
        #expect(await handler._testPendingRequestCount() == 0)
    }

    @Test("Companion frame waiter is cancellation-aware")
    func companionFrameWaiterCancellationRemovesWaiter() async {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let task = Task { try await connection.waitForFrame(type: .psNext, timeout: 60) }
        await waitForInstall()
        #expect(connection._testPendingFrameWaiterCount == 1)

        task.cancel()
        await expectOperationCancelled(task)
        #expect(connection._testPendingFrameWaiterCount == 0)
    }
}
