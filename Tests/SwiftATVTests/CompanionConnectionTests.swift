import Foundation
import Testing

@testable import SwiftATV

/// Tests for `CompanionConnection`'s frame routing, specifically the
/// asymmetric pair-setup / pair-verify response channel.
///
/// Regression context (caught by Codex adversarial review): prior to this
/// suite, `CompanionPairVerifyHandler.verify()` sent a `.pvStart` frame and
/// then `sendAndReceive` defaulted to waiting for another `.pvStart`. Apple
/// TVs always reply to `*_Start` auth frames on the corresponding `*_Next`
/// channel, so a real credentialed connection would have silently timed
/// out after pair-verify's first step. These tests lock in the mapping
/// contract so it can't regress.
@Suite("CompanionConnection auth frame routing")
struct CompanionConnectionTests {

    // MARK: - Static mapping contract

    @Test("PS_Start default response type is PS_Next")
    func psStartMapsToPsNext() {
        #expect(CompanionConnection.defaultResponseType(for: .psStart) == .psNext)
    }

    @Test("PV_Start default response type is PV_Next")
    func pvStartMapsToPvNext() {
        #expect(CompanionConnection.defaultResponseType(for: .pvStart) == .pvNext)
    }

    @Test("PS_Next default response type is PS_Next (mid-handshake is symmetric)")
    func psNextStaysOnPsNext() {
        #expect(CompanionConnection.defaultResponseType(for: .psNext) == .psNext)
    }

    @Test("PV_Next default response type is PV_Next (mid-handshake is symmetric)")
    func pvNextStaysOnPvNext() {
        #expect(CompanionConnection.defaultResponseType(for: .pvNext) == .pvNext)
    }

    @Test("Non-auth frame types map to themselves")
    func nonAuthFramesPassThrough() {
        #expect(CompanionConnection.defaultResponseType(for: .eOPACK) == .eOPACK)
        #expect(CompanionConnection.defaultResponseType(for: .uOPACK) == .uOPACK)
        #expect(CompanionConnection.defaultResponseType(for: .pOPACK) == .pOPACK)
        #expect(CompanionConnection.defaultResponseType(for: .noOp) == .noOp)
    }

    // MARK: - Round-trip via frame injection

    /// Build a well-formed Companion frame header + payload buffer.
    /// Wire format: `[type:1][len24-hi][len24-mid][len24-lo][payload...]`.
    private func encodeFrame(type: CompanionFrameType, payload: Data) -> Data {
        var data = Data()
        data.append(type.rawValue)
        let len = UInt32(payload.count)
        data.append(UInt8((len >> 16) & 0xFF))
        data.append(UInt8((len >> 8) & 0xFF))
        data.append(UInt8(len & 0xFF))
        data.append(payload)
        return data
    }

    @Test("waitForFrame(.pvNext) resumes when a PV_Next frame is injected")
    func pvNextFrameResumesWaiter() async throws {
        // Construct without connecting — we'll feed bytes through the
        // test-accessible `handleReceivedData` entry point instead.
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let expectedPayload = Data([0xCA, 0xFE, 0xBA, 0xBE])

        // Start the waiter on a child task.
        async let received: Data = connection.waitForFrame(type: .pvNext, timeout: 5)

        // Yield a couple of times so the child task runs far enough to
        // register its continuation inside `withCheckedThrowingContinuation`.
        await Task.yield()
        await Task.yield()

        // Inject a synthetic PV_Next frame.
        connection.handleReceivedData(encodeFrame(type: .pvNext, payload: expectedPayload))

        #expect(try await received == expectedPayload)
    }

    @Test("sendAndReceive from pair-verify's perspective resumes on PV_Next")
    func pairVerifyStartResolvesOnPvNext() async throws {
        // This mirrors what `CompanionPairVerifyHandler.verify()` does at
        // its first step. Without a real TCP channel we can't call `send`,
        // so drive `waitForFrame(type: defaultResponseType(for: .pvStart))`
        // directly and confirm the injected PV_Next frame unblocks it.
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let responseType = CompanionConnection.defaultResponseType(for: .pvStart)
        #expect(responseType == .pvNext)

        let payload = Data([0x01, 0x02, 0x03])
        async let received: Data = connection.waitForFrame(type: responseType, timeout: 5)
        await Task.yield()
        await Task.yield()
        connection.handleReceivedData(encodeFrame(type: .pvNext, payload: payload))

        #expect(try await received == payload)
    }
}
