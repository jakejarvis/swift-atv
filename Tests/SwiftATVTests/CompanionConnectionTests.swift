import Foundation
import Testing

@testable import SwiftATV

/// Lock-protected box for capturing the outcome of a fire-and-forget
/// waiter task without ever awaiting the task's continuation. Used in
/// regression tests where the bug-injected path leaves the waiter
/// permanently suspended (so `Task.value` would hang).
private final class WaiterOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: Result<Data, ATVError>?

    var result: Result<Data, ATVError>? {
        lock.withLock { _result }
    }

    func set(_ result: Result<Data, ATVError>) {
        lock.withLock { _result = result }
    }
}

/// Tests for `CompanionConnection`'s frame routing, specifically the
/// asymmetric pair-setup / pair-verify response channel.
///
/// Apple TVs always reply to `*_Start` auth frames on the corresponding
/// `*_Next` channel, so `sendAndReceive` must map `.pvStart` → `.pvNext`
/// (and `.psStart` → `.psNext`) when picking its default response type.
/// These tests lock in the mapping contract so it can't regress.
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

    /// Give a just-spawned waiter task enough time to reach its
    /// `withCheckedThrowingContinuation` body and install its entry into
    /// `frameWaiters`. `Task.yield()` isn't a deterministic synchronization
    /// on Linux's cooperative scheduler, so a short sleep is the
    /// race-free way to wait for the install step.
    private func waitForWaiterInstall() async {
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }

    @Test("waitForFrame(.pvNext) resumes when a PV_Next frame is injected")
    func pvNextFrameResumesWaiter() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let expectedPayload = Data([0xCA, 0xFE, 0xBA, 0xBE])

        let task = Task { try await connection.waitForFrame(type: .pvNext, timeout: 5) }
        await waitForWaiterInstall()
        connection.handleReceivedData(encodeFrame(type: .pvNext, payload: expectedPayload))
        #expect(try await task.value == expectedPayload)
    }

    @Test("sendAndReceive from pair-verify's perspective resumes on PV_Next")
    func pairVerifyStartResolvesOnPvNext() async throws {
        // Mirrors what `CompanionPairVerifyHandler.verify()` does at its
        // first step. Without a real TCP channel we can't call `send`,
        // so drive `waitForFrame(type: defaultResponseType(for: .pvStart))`
        // directly and confirm the injected PV_Next frame unblocks it.
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let responseType = CompanionConnection.defaultResponseType(for: .pvStart)
        #expect(responseType == .pvNext)

        let payload = Data([0x01, 0x02, 0x03])
        let task = Task { try await connection.waitForFrame(type: responseType, timeout: 5) }
        await waitForWaiterInstall()
        connection.handleReceivedData(encodeFrame(type: .pvNext, payload: payload))
        #expect(try await task.value == payload)
    }

    // MARK: - Stale-timeout regression

    /// Pair-setup waits on `.psNext` for M2, M4, and M6 in sequence. A
    /// previous implementation let the first call's timeout task wake up
    /// after its 5-second sleep and unconditionally remove
    /// `frameWaiters[.psNext]`, which by then belongs to the next waiter —
    /// resuming it with a spurious `operationTimeout` and failing an
    /// otherwise-healthy handshake. This test pins the combined cancel +
    /// identity-check invariant.
    ///
    /// Critical timing constraint: the SECOND waiter must be installed
    /// *immediately* after the first wait resolves and must remain pending
    /// past `firstTimeout`, so the stale-timeout firing window OVERLAPS
    /// with the second waiter being in the dict. If the test sleeps before
    /// installing the second waiter, the would-be stale timeout fires into
    /// an empty dict and the race is never reproduced.
    @Test(
        "Stale timeout from a previous wait cannot steal a later overlapping waiter",
        .timeLimit(.minutes(1))
    )
    func staleTimeoutDoesNotClobberLaterWaiter() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)

        // Short first-timeout so the would-be-stale task wakes up quickly
        // while the second waiter is still pending.
        let firstTimeout: TimeInterval = 0.3
        let firstPayload = Data([0xA1])
        let secondPayload = Data([0xB2])

        // --- First wait: resolved by the injected frame before its timeout.
        let firstTask = Task {
            try await connection.waitForFrame(type: .psNext, timeout: firstTimeout)
        }
        await waitForWaiterInstall()
        connection.handleReceivedData(encodeFrame(type: .psNext, payload: firstPayload))
        #expect(try await firstTask.value == firstPayload)

        // --- IMMEDIATELY install the second waiter. No sleep here: we
        //     want it sitting in `frameWaiters[.psNext]` while the first
        //     waiter's stale timeout task wakes up. This is the exact
        //     overlap window the bug would have exploited.
        let secondTask = Task {
            try await connection.waitForFrame(type: .psNext, timeout: 10)
        }
        await waitForWaiterInstall()

        // --- Sleep past `firstTimeout`. During this sleep, the first
        //     waiter's timeout task either:
        //       - was cancelled by `handleReceivedData` on delivery and
        //         exits via the catch-CancellationError branch, OR
        //       - wakes up at the end of its sleep, looks up
        //         `frameWaiters[.psNext]`, and `removeFrameWaiterIfOwned`
        //         rejects the removal because the stored waiter has a
        //         different UUID than the captured one.
        //     Either branch must leave the second waiter intact.
        try await Task.sleep(nanoseconds: UInt64(firstTimeout * 1.5 * 1_000_000_000))

        // --- Now deliver the second frame. With the bug, the second
        //     waiter would already have been removed and resumed with
        //     `operationTimeout` during the sleep, so this frame would
        //     hit an empty slot and `secondTask.value` would throw.
        connection.handleReceivedData(encodeFrame(type: .psNext, payload: secondPayload))
        #expect(try await secondTask.value == secondPayload)
    }

    /// Even harder scenario: the first timeout is actually *allowed* to
    /// fire (no frame ever delivered), and THEN a second waiter is
    /// installed. The first timeout task must not disturb the second.
    @Test(
        "Expired timeout from a previous wait cannot steal a later waiter",
        .timeLimit(.minutes(1))
    )
    func expiredTimeoutDoesNotClobberLaterWaiter() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)

        // First wait: short timeout, no frame. Expect it to throw.
        do {
            _ = try await connection.waitForFrame(type: .psNext, timeout: 0.1)
            Issue.record("First wait should have timed out")
        } catch {
            // Expected.
        }

        // Small gap so the first timeout task has definitely fully run.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Second wait on the same type; deliver the frame before its
        // timeout. This must resolve normally.
        let payload = Data([0xCD, 0xEF])
        let task = Task { try await connection.waitForFrame(type: .psNext, timeout: 5) }
        await waitForWaiterInstall()
        connection.handleReceivedData(encodeFrame(type: .psNext, payload: payload))
        #expect(try await task.value == payload)
    }

    /// Three-in-a-row resolution on the same frame type, matching the
    /// pair-setup `psStart -> psNext -> psNext -> psNext` pattern exactly.
    @Test("Three consecutive waits on .psNext all resolve correctly (pair-setup shape)")
    func threeConsecutivePsNextWaitsResolve() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)

        for (i, byte) in [UInt8(0x11), 0x22, 0x33].enumerated() {
            let expected = Data([byte])
            let task = Task { try await connection.waitForFrame(type: .psNext, timeout: 5) }
            await waitForWaiterInstall()
            connection.handleReceivedData(encodeFrame(type: .psNext, payload: expected))
            let got = try await task.value
            #expect(got == expected, "iteration \(i)")
        }
    }

    // MARK: - Close cancels pending waiters

    /// When the connection is closed while a frame waiter is pending, the
    /// caller must be resumed immediately with `.connectionLost` instead
    /// of hanging until the 5-second timeout. Regression test for the
    /// previously-missing waiter cleanup in `close()`.
    @Test(
        "close() cancels pending frame waiters with connectionLost",
        .timeLimit(.minutes(1))
    )
    func closeCancelsPendingWaiters() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)

        // Spawn the waiter on a detached Task and give it time to reach
        // the `frameWaiters[...] = waiter` step before we close.
        let waiterTask = Task { try await connection.waitForFrame(type: .psNext, timeout: 60) }
        await waitForWaiterInstall()

        // Close without ever delivering a frame. The waiter should
        // resolve promptly, not after 60 seconds.
        await connection.close()

        var thrown: ATVError?
        do {
            _ = try await waiterTask.value
            Issue.record("Expected waiter to be resumed with an error")
        } catch let err as ATVError {
            thrown = err
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        guard case .connectionLost = thrown else {
            Issue.record("Expected .connectionLost, got \(String(describing: thrown))")
            return
        }
    }

    /// `drainAndResumeWaiters` is the synchronous building block that
    /// `close()` and `handleConnectionClosed` rely on. It must resume
    /// every pending waiter's continuation **before it returns** — no
    /// async gap between dict removal and resume, so a stalled channel
    /// close cannot strand a caller.
    ///
    /// Test pattern: spawn the waiter as a fire-and-forget Task that
    /// records its outcome to a `Mutex`-style box. Then poll the box
    /// after a short bounded sleep. This deliberately avoids
    /// `Task.value` because:
    ///   - `withCheckedThrowingContinuation` is not cancellation-aware,
    ///     so a regression that skips the resume call leaves the
    ///     waiter task permanently suspended, and `await waiterTask.value`
    ///     would hang indefinitely.
    ///   - `withTaskGroup`'s cleanup also waits for all child tasks, so
    ///     racing the await against a deadline inside a task group
    ///     reproduces the same hang.
    /// The polled-flag pattern lets a regression be reported as a clean
    /// test failure within ~100ms instead of hanging the test runner.
    @Test(
        "drainAndResumeWaiters resumes waiters synchronously, before any I/O",
        .timeLimit(.minutes(1))
    )
    func drainAndResumeWaitersResumesBeforeReturning() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let outcome = WaiterOutcomeBox()

        // Spawn the waiter on a detached Task. We do NOT keep its
        // handle — `outcome.result` is the only thing we read.
        Task { [outcome] in
            do {
                let value = try await connection.waitForFrame(type: .psNext, timeout: 60)
                outcome.set(.success(value))
            } catch let err as ATVError {
                outcome.set(.failure(err))
            } catch {
                outcome.set(.failure(.internalError(String(describing: error))))
            }
        }
        await waitForWaiterInstall()

        // Call the synchronous helper directly.
        _ = connection.drainAndResumeWaiters(error: .connectionLost("test"))

        // The waiter task still has to be scheduled to actually exit
        // `waitForFrame` and reach the catch block. Give it a brief
        // bounded window. With the fix, this completes in microseconds.
        try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

        guard let result = outcome.result else {
            Issue.record(
                "drainAndResumeWaiters did not resume the waiter within 100ms — the synchronous-resume contract is broken"
            )
            return
        }

        switch result {
        case .success:
            Issue.record("Expected waiter to be resumed with an error")
        case .failure(let err):
            guard case .connectionLost = err else {
                Issue.record("Expected .connectionLost, got \(err)")
                return
            }
        }
    }

    /// Stronger version of the above using the public `close()` path:
    /// race the waiter against a 500ms deadline, and assert it resolves
    /// well within that — close() must not park the caller behind any
    /// slow channel-close work.
    @Test(
        "close() resumes waiters within 500ms even with no live channel",
        .timeLimit(.minutes(1))
    )
    func closeResumesWaitersBeforeDeadline() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)

        let waiterTask = Task { try await connection.waitForFrame(type: .psNext, timeout: 60) }
        await waitForWaiterInstall()

        // Kick off close() in the background and immediately race the
        // waiter against a deadline.
        let closeTask = Task { await connection.close() }

        let resolvedInTime: Bool = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                _ = try? await waiterTask.value
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return false
            }
            for await done in group {
                if let done {
                    group.cancelAll()
                    return done
                }
            }
            return false
        }

        await closeTask.value
        #expect(resolvedInTime, "Waiter must resolve within 500ms of close() starting")
    }

    /// Race `close()` against a freshly-spawned `waitForFrame` with NO
    /// pre-install sleep. Both interleavings must produce a prompt
    /// `.connectionLost`:
    ///
    /// - **install wins**: waiter is in the dict when `close()` runs;
    ///   `drainAndResumeWaiters` resumes it.
    /// - **close wins**: `drainAndResumeWaiters` flips `isClosed = true`
    ///   first; the waiter's install path then sees `isClosed`, refuses
    ///   to register, and resumes its continuation immediately with
    ///   `.connectionLost` instead of stranding it on a dead connection.
    ///
    /// Run in a tight loop to exercise both interleavings statistically.
    /// Without the `isClosed` flag, the close-wins interleaving would
    /// silently install a waiter on a closed connection that would only
    /// unblock when its 60-second timeout fired.
    @Test(
        "close() racing a brand-new waitForFrame resolves promptly in both interleavings",
        .timeLimit(.minutes(1))
    )
    func closeRacingWithInstallResolvesPromptly() async throws {
        let iterations = 40
        for i in 0..<iterations {
            let connection = CompanionConnection(host: "127.0.0.1", port: 0)

            // Kick off the waiter and the close on (effectively) the
            // same scheduler tick — no `waitForWaiterInstall()` here.
            let waiterTask = Task {
                try await connection.waitForFrame(type: .psNext, timeout: 60)
            }
            let closeTask = Task { await connection.close() }

            // The waiter should complete within a tight deadline (much
            // less than the 60-second timeout). Without the `isClosed`
            // guard, the close-wins interleaving would hang here.
            let resolvedInTime: Bool = await withTaskGroup(of: Bool?.self) { group in
                group.addTask {
                    _ = try? await waiterTask.value
                    return true
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    return false
                }
                for await done in group {
                    if let done {
                        group.cancelAll()
                        return done
                    }
                }
                return false
            }
            await closeTask.value

            #expect(resolvedInTime, "iteration \(i): waiter must resolve within 500ms")

            // And the result must be `.connectionLost`, not
            // `.operationTimeout`.
            var thrown: ATVError?
            do {
                _ = try await waiterTask.value
            } catch let err as ATVError {
                thrown = err
            } catch {
                Issue.record("iteration \(i): unexpected error type: \(error)")
            }
            guard case .connectionLost = thrown else {
                Issue.record(
                    "iteration \(i): expected .connectionLost, got \(String(describing: thrown))"
                )
                return
            }
        }
    }

    /// `waitForFrame` on a connection that has already been closed must
    /// throw `.connectionLost` immediately rather than registering a
    /// waiter that nothing will ever resolve.
    @Test("waitForFrame on a closed connection throws connectionLost")
    func waitForFrameOnClosedConnectionThrows() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        await connection.close()

        var thrown: ATVError?
        do {
            _ = try await connection.waitForFrame(type: .psNext, timeout: 60)
            Issue.record("Expected waitForFrame to throw")
        } catch let err as ATVError {
            thrown = err
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        guard case .connectionLost = thrown else {
            Issue.record("Expected .connectionLost, got \(String(describing: thrown))")
            return
        }
    }

    /// `connect()` on a connection that has already been closed must
    /// throw `.connectionLost`. Once closed, a `CompanionConnection` is
    /// terminal — callers that need to reconnect should allocate a
    /// fresh instance.
    @Test("connect() on a closed connection throws connectionLost")
    func connectOnClosedConnectionThrows() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        await connection.close()

        var thrown: ATVError?
        do {
            try await connection.connect()
            Issue.record("Expected connect to throw")
        } catch let err as ATVError {
            thrown = err
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        guard case .connectionLost = thrown else {
            Issue.record("Expected .connectionLost, got \(String(describing: thrown))")
            return
        }
    }

    /// After the NIO peer-close path fires (`handleConnectionClosed`),
    /// a fire-and-forget `send` (e.g. `CompanionProtocolHandler.sendEvent`)
    /// must surface `.connectionLost`, not silently attempt a write
    /// against the dead channel and surface a wrapped NIO error
    /// (`.internalError`). A previous implementation of
    /// `handleConnectionClosed` flipped `isClosed` but left `channel`
    /// installed, so `send`'s `channel != nil` check would still pass
    /// and write into a dead pipe.
    @Test("send() after peer-close throws connectionLost (not internalError)")
    func sendAfterPeerCloseThrowsConnectionLost() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)

        // Drive the peer-close path directly. (Without a real channel
        // installed, the only state to clear is `isClosed`, but the
        // contract still applies: `send` must read `isClosed` and bail
        // before touching `channel`.)
        connection.handleConnectionClosed(error: nil)

        var thrown: ATVError?
        do {
            try await connection.send(type: .eOPACK, payload: Data([0x01]))
            Issue.record("Expected send to throw")
        } catch let err as ATVError {
            thrown = err
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        guard case .connectionLost = thrown else {
            Issue.record("Expected .connectionLost, got \(String(describing: thrown))")
            return
        }
    }

    /// And the same on the explicit-close path: `send` after `close()`
    /// must surface `.connectionLost` rather than `.connectionFailed`.
    @Test("send() after explicit close() throws connectionLost (not connectionFailed)")
    func sendAfterExplicitCloseThrowsConnectionLost() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        await connection.close()

        var thrown: ATVError?
        do {
            try await connection.send(type: .eOPACK, payload: Data([0x01]))
            Issue.record("Expected send to throw")
        } catch let err as ATVError {
            thrown = err
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
        guard case .connectionLost = thrown else {
            Issue.record("Expected .connectionLost, got \(String(describing: thrown))")
            return
        }
    }

    /// `handleConnectionClosed` is idempotent under NIO's two-call
    /// disconnect sequence (`errorCaught` followed by `channelInactive`).
    /// Without the `isClosed` early-return, the second call would re-fire
    /// the close delegate with `error: nil`, masking the real error from
    /// the first call and double-notifying any observer.
    @Test("handleConnectionClosed is idempotent across NIO's errorCaught + channelInactive")
    func handleConnectionClosedIsIdempotent() async throws {
        final class CountingDelegate: CompanionConnectionDelegate, @unchecked Sendable {
            let lock = NSLock()
            private var _closeErrors: [Error?] = []
            var closeCount: Int { lock.withLock { _closeErrors.count } }
            var closeErrors: [Error?] { lock.withLock { _closeErrors } }

            func connectionDidReceiveFrame(_ frame: CompanionFrame) async {}
            func connectionDidClose(error: Error?) async {
                lock.withLock { _closeErrors.append(error) }
            }
        }

        let delegate = CountingDelegate()
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        connection.delegate = delegate

        struct FakeError: Error {}
        connection.handleConnectionClosed(error: FakeError())  // errorCaught
        connection.handleConnectionClosed(error: nil)  // channelInactive

        // Delegate notifications are dispatched on a Task, so let it
        // run before observing.
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(delegate.closeCount == 1)
        // The delegate must see the original error from the first call,
        // not the nil from the second.
        if let firstError = delegate.closeErrors.first {
            #expect(firstError is FakeError)
        }
    }

    /// `CompanionProtocolHandler.startReceiving()` consumes
    /// `CompanionConnection.frameStream`. Closing the connection must
    /// finish that stream so the receive task can leave its `for await`
    /// loop instead of leaking indefinitely.
    @Test(
        "startReceiving's receive loop exits when handleConnectionClosed fires",
        .timeLimit(.minutes(1))
    )
    func receiveLoopExitsOnHandleConnectionClosed() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let handler = CompanionProtocolHandler(connection: connection)
        await handler.startReceiving()
        try await Task.sleep(nanoseconds: 50_000_000)
        connection.handleConnectionClosed(error: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    /// Drives the drain path via the `_testInstallPendingRequest` test
    /// seam to avoid needing a live NIO channel. When the underlying
    /// connection is closed, any in-flight
    /// `CompanionProtocolHandler.sendRequest` that is parked in
    /// `pendingRequests` waiting for a response must be resumed promptly
    /// with `.connectionLost`. Without this, the post-pair-setup command
    /// path (remote control, apps, audio, etc.) would wait for its full
    /// 5-second timeout and surface `.operationTimeout` instead of the
    /// real failure cause.
    @Test(
        "Pending OPACK requests are drained when the connection closes",
        .timeLimit(.minutes(1))
    )
    func pendingRequestsDrainedOnConnectionClose() async throws {
        let connection = CompanionConnection(host: "127.0.0.1", port: 0)
        let handler = CompanionProtocolHandler(connection: connection)
        await handler.startReceiving()

        // Install a fake pending request directly. Records the outcome
        // to a fire-and-forget Box so a regression that fails to drain
        // doesn't hang the test on `Task.value`.
        let outcome = WaiterOutcomeBox()
        Task { [outcome] in
            do {
                _ = try await handler._testInstallPendingRequest(xid: 0xBEEF)
                outcome.set(.success(Data()))
            } catch let err as ATVError {
                outcome.set(.failure(err))
            } catch {
                outcome.set(.failure(.internalError(String(describing: error))))
            }
        }

        for _ in 0..<20 {
            if await handler._testPendingRequestCount() == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await handler._testPendingRequestCount() == 1)

        // Trigger the peer-close path on the connection. This finishes
        // the frame stream, the receive loop in `startReceiving` exits,
        // and the loop's drain step runs `failPendingRequests`.
        connection.handleConnectionClosed(error: nil)

        // Bounded poll.
        try await Task.sleep(nanoseconds: 200_000_000)

        guard let result = outcome.result else {
            Issue.record(
                "Pending request was not drained within 200ms — receive-loop-exit drain is not running"
            )
            return
        }
        switch result {
        case .success:
            Issue.record("Expected pending request to be resumed with an error")
        case .failure(let err):
            guard case .connectionLost = err else {
                Issue.record("Expected .connectionLost, got \(err)")
                return
            }
        }
    }
}
