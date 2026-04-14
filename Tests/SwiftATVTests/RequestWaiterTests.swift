import Foundation
import Testing

@testable import SwiftATV

@Suite("Request waiters")
struct RequestWaiterTests {
    private func waitForInstall() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func protocolMessage(
        type: ProtocolMessageMessage.TypeEnum,
        identifier: String
    ) -> ProtocolMessageMessage {
        var message = ProtocolMessageMessage()
        message.type = type
        message.identifier = identifier
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
}
