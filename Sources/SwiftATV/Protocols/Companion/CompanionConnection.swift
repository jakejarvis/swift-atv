import Foundation
import NIOCore
import NIOPosix

/// Frame types used in the Companion protocol.
public enum CompanionFrameType: UInt8, Sendable {
    case unknown = 0
    case noOp = 1
    case psStart = 3
    case psNext = 4
    case pvStart = 5
    case pvNext = 6
    case uOPACK = 7
    case eOPACK = 8
    case pOPACK = 9
    case paReq = 10
    case paRsp = 11
    case sessionStartRequest = 16
    case sessionStartResponse = 17
    case sessionData = 18
    case familyIdentityRequest = 32
    case familyIdentityResponse = 33
    case familyIdentityUpdate = 34
}

/// A Companion protocol frame with type and payload.
public struct CompanionFrame: Sendable {
    public let type: CompanionFrameType
    public let payload: Data

    public init(type: CompanionFrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

/// Delegate for receiving Companion protocol events.
public protocol CompanionConnectionDelegate: AnyObject, Sendable {
    func connectionDidReceiveFrame(_ frame: CompanionFrame) async
    func connectionDidClose(error: Error?) async
}

/// A pending waiter for a specific Companion frame type.
///
/// UUID-based identity prevents a stale timeout task from stealing a
/// later waiter on the same frame type (easy to trigger for pair-setup:
/// M2, M4, and M6 all arrive on the same `.psNext` channel in sequence).
/// The timeout task only captures the waiter's `id`, not the waiter
/// reference itself, so the closure can stay `@Sendable`.
///
/// `@unchecked Sendable` because:
/// - `id` is immutable after init.
/// - `continuation` is immutable after init and is resumed exactly once
///   (guaranteed by the single owner of the dictionary slot).
/// - `timeoutTask` is mutated once, immediately after install, under the
///   owning `CompanionConnection.lock` — the same lock every subsequent
///   reader holds, so the mutation is published safely.
private final class PendingFrameWaiter: @unchecked Sendable {
    let id: UUID
    let continuation: CheckedContinuation<Data, Error>
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.id = UUID()
        self.continuation = continuation
    }
}

/// Low-level TCP connection for the Companion protocol.
///
/// Handles frame encoding/decoding with the wire format:
/// `[FrameType: 1 byte][Length: 3 bytes big-endian][Payload: variable]`
///
/// Supports enabling ChaCha20-Poly1305 encryption after pair-verify.
///
/// Thread safety: All mutable state (channel, cipher, buffers, waiters)
/// is protected by `NSLock`. NIO callbacks arrive on the event loop thread
/// and must synchronize with async callers.
public final class CompanionConnection: @unchecked Sendable {
    private static let headerLength = 4
    private static let authTagLength = 16

    private let host: String
    private let port: Int
    private let connectTimeout: TimeInterval
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let lock = NSLock()

    // Protected by lock
    private var channel: Channel?
    private var cipher: ChaCha20Cipher?
    private var receiveBuffer = Data()
    private var frameWaiters: [UInt8: PendingFrameWaiter] = [:]
    private var frameContinuation: AsyncStream<CompanionFrame>.Continuation?
    private var _frameStream: AsyncStream<CompanionFrame>?
    /// Sticky terminal state. Set the moment the connection starts being
    /// closed (either explicitly via `close()` or by the NIO peer-close
    /// path) and never cleared. Checked under the lock by every install
    /// path so a `waitForFrame` / `sendAndReceive` call that races with
    /// `close()` can't register a waiter that the (now empty) drain has
    /// already missed.
    private var isClosed = false
    private var didShutdownGroup = false

    public weak var delegate: CompanionConnectionDelegate?

    /// Stream of received frames.
    ///
    /// If the connection is already closed when `frameStream` is first
    /// accessed, the returned stream is finished immediately so any
    /// `for await frame in stream` consumer exits its loop right away
    /// — without this, a late subscriber on a closed connection would
    /// hang forever waiting for frames that will never arrive.
    public var frameStream: AsyncStream<CompanionFrame> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _frameStream { return existing }
        let stream = AsyncStream<CompanionFrame> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            // `AsyncStream` invokes this builder synchronously during
            // initialization. `frameStream` already holds `lock` here, so
            // do not lock again: `NSLock` is not recursive, and taking it
            // from this closure deadlocks the receive task before it can
            // subscribe.
            if self.isClosed {
                continuation.finish()
                return
            }
            self.frameContinuation = continuation
        }
        _frameStream = stream
        return stream
    }

    /// Create a low-level Companion TCP connection.
    ///
    /// - Parameters:
    ///   - host: Device host name or IP address.
    ///   - port: Companion service port.
    ///   - connectTimeout: Maximum time to wait for the TCP connect.
    ///   - group: Optional NIO event-loop group. If omitted, the connection owns one.
    public init(
        host: String,
        port: Int,
        connectTimeout: TimeInterval = defaultProtocolRequestTimeout,
        group: EventLoopGroup? = nil
    ) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    /// Connect to the device.
    ///
    /// `close()` is terminal: a connection that has been closed cannot
    /// be reopened. Calling `connect()` on a closed connection throws
    /// `.connectionLost`. (Callers that need to reconnect should
    /// allocate a fresh `CompanionConnection`.)
    public func connect() async throws(ATVError) {
        let alreadyClosed = lock.withLock { isClosed }
        guard !alreadyClosed else {
            throw ATVError.connectionLost("Connection has been closed")
        }
        let timeoutNs = try timeoutNanoseconds(from: connectTimeout, parameterName: "connectTimeout")
        let timeoutMs = Int64(timeoutNs / 1_000_000)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.connectTimeout, value: .milliseconds(timeoutMs))
            .channelInitializer { [self] channel in
                channel.pipeline.addHandler(CompanionFrameHandler(connection: self))
            }

        let ch: Channel
        do {
            ch = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            if isLikelyTimeoutError(error) {
                throw ATVError.operationTimeout(
                    TimeoutContext(
                        protocol: .companion,
                        operation: "connect",
                        requestID: "tcp",
                        duration: connectTimeout
                    )
                )
            }
            throw ATVError.wrap(error)
        }
        lock.withLock {
            // Race: if `close()` ran while we were awaiting the
            // bootstrap, we now hold a fresh channel against a closed
            // connection. Tear it down immediately and signal the
            // caller.
            if isClosed {
                _ = ch.close(mode: .all)
                return
            }
            self.channel = ch
        }
        // Re-check after the lock so we can throw at the boundary.
        let stillOpen = lock.withLock { !isClosed && self.channel != nil }
        guard stillOpen else {
            throw ATVError.connectionLost("Connection has been closed")
        }
    }

    /// Send a frame to the device.
    ///
    /// Fails terminally with `.connectionLost` if the connection has
    /// been closed (either via explicit `close()` or by NIO peer-close).
    /// This matches the behaviour of `waitForFrame` / `sendAndReceive`
    /// so that one-way `sendEvent` callers see the same error class as
    /// waiter-based callers — there is no path that retains a stale
    /// `channel` reference past the close boundary.
    public func send(type: CompanionFrameType, payload: Data = Data()) async throws(ATVError) {
        let state: SendChannelState = lock.withLock {
            if isClosed { return .closed }
            guard let channel = self.channel else { return .notConnected }
            return .ready(channel, cipher)
        }
        let channel: Channel
        let currentCipher: ChaCha20Cipher?
        switch state {
        case .closed:
            throw ATVError.connectionLost("Connection has been closed")
        case .notConnected:
            throw ATVError.connectionFailed(message: "Not connected")
        case .ready(let ch, let cph):
            channel = ch
            currentCipher = cph
        }

        let frameData = try Self.encodeFrame(
            type: type,
            payload: payload,
            cipher: currentCipher
        )

        var buffer = channel.allocator.buffer(capacity: frameData.count)
        buffer.writeBytes(frameData)
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            // Race: between the snapshot above and this write, `close()`
            // or `handleConnectionClosed` may have flipped `isClosed` and
            // cleared the connection state from under us. Re-check under
            // the lock and surface `.connectionLost` for that case so the
            // contract ("post-close sends throw connectionLost") holds
            // across the snapshot/write window.
            let nowClosed = lock.withLock { isClosed }
            if nowClosed {
                throw ATVError.connectionLost("Connection closed during send")
            }
            throw ATVError.wrap(error)
        }
    }

    /// Encode a Companion frame using the `[type][24-bit length][payload]`
    /// wire format.
    ///
    /// When encryption is enabled, the frame header must contain the
    /// ciphertext length (`plaintext + 16-byte Poly1305 tag`) before it is
    /// passed as ChaCha20-Poly1305 AAD. The receiver authenticates the
    /// on-wire header, so authenticating a plaintext-length header and then
    /// sending a ciphertext-length header makes every encrypted frame fail.
    internal static func encodeFrame(
        type: CompanionFrameType,
        payload: Data,
        cipher: ChaCha20Cipher?
    ) throws(ATVError) -> Data {
        let wireLength = payload.count + ((cipher != nil && !payload.isEmpty) ? authTagLength : 0)
        guard wireLength <= 0xFF_FF_FF else {
            throw ATVError.invalidData("Companion frame payload exceeds 24-bit length field")
        }

        var header = Data(count: headerLength)
        header[0] = type.rawValue
        header[1] = UInt8((wireLength >> 16) & 0xFF)
        header[2] = UInt8((wireLength >> 8) & 0xFF)
        header[3] = UInt8(wireLength & 0xFF)

        let wirePayload: Data
        if let cipher, !payload.isEmpty {
            wirePayload = try cipher.encrypt(payload, aad: header)
        } else {
            wirePayload = payload
        }
        return header + wirePayload
    }

    /// Send a frame and wait for the expected response frame.
    ///
    /// If `waitType` is omitted, the response type is inferred via
    /// `defaultResponseType(for:)`. That default handles the asymmetric
    /// auth handshake: a `PS_Start` / `PV_Start` request is always answered
    /// on the corresponding `PS_Next` / `PV_Next` channel for the full
    /// duration of pair-setup / pair-verify. Matches pyatv's
    /// `CompanionProtocol.exchange_auth` contract.
    ///
    /// For non-auth frame types the default is the same type as sent.
    ///
    /// Race safety: the response waiter is installed **before** the send so
    /// a fast device reply (landing between the send completing and the
    /// waiter being registered) cannot be silently dropped. Each waiter is
    /// identity-checked on timeout/delivery so a stale timeout from a
    /// previous call can't steal a later waiter on the same frame type —
    /// pair-setup waits on `.psNext` three times in a row, so this matters.
    public func sendAndReceive(
        type: CompanionFrameType,
        payload: Data = Data(),
        waitType: CompanionFrameType? = nil,
        timeout: TimeInterval = 5.0
    ) async throws(ATVError) -> Data {
        let timeoutNs = try timeoutNanoseconds(from: timeout, parameterName: "timeout")
        let responseType = waitType ?? Self.defaultResponseType(for: type)

        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                let waiter = PendingFrameWaiter(continuation)
                let waiterID = waiter.id  // Sendable capture for the Task below

                // 1. Install the waiter synchronously before any async work.
                //    The install path also enforces the closed-state check
                //    so a `close()` racing with this call cannot strand us.
                switch tryInstallWaiter(type: responseType, waiter: waiter) {
                case .connectionClosed:
                    continuation.resume(
                        throwing: ATVError.connectionLost("Connection is closed")
                    )
                    return
                case .alreadyRegistered:
                    continuation.resume(
                        throwing: ATVError.invalidState(
                            "Frame waiter for type \(responseType) already registered"
                        ))
                    return
                case .installed:
                    break
                }

                // 2. Kick off the send + timeout in a child Task so the
                //    withCheckedThrowingContinuation body stays synchronous.
                let task = Task { [weak self] in
                    guard let self else { return }

                    // 2a. Send. If the send throws, surface it on the
                    //     waiter — but only if our specific waiter is
                    //     still the one registered for this frame type.
                    do {
                        try await self.send(type: type, payload: payload)
                    } catch {
                        if let removed = self.removeFrameWaiterIfOwned(
                            type: responseType,
                            id: waiterID
                        ) {
                            removed.continuation.resume(throwing: error)
                        }
                        return
                    }

                    // 2b. Timeout sleep. `Task.sleep` throws
                    //     `CancellationError` when `handleReceivedData`
                    //     cancels us after delivery, at which point we
                    //     exit without touching the dict.
                    do {
                        try await Task.sleep(nanoseconds: timeoutNs)
                    } catch {
                        return
                    }

                    // 2c. Identity-checked removal — only surface timeout
                    //     if our specific waiter is still the one registered.
                    if let removed = self.removeFrameWaiterIfOwned(
                        type: responseType,
                        id: waiterID
                    ) {
                        removed.continuation.resume(
                            throwing: ATVError.operationTimeout(
                                TimeoutContext(
                                    protocol: .companion,
                                    operation: "frame",
                                    requestID: "\(responseType)",
                                    duration: timeout
                                )
                            )
                        )
                    }
                }
                // Publish the task handle under the same lock every other
                // reader holds, so `handleReceivedData` sees a consistent
                // view when it cancels on frame delivery.
                lock.withLock {
                    if frameWaiters[responseType.rawValue]?.id == waiterID {
                        waiter.timeoutTask = task
                    }
                }
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }
    }

    /// Map a request frame type to the frame type the device uses to reply.
    ///
    /// `PS_Start` and `PV_Start` are only used for the first message of a
    /// handshake — every subsequent message (including the *response* to
    /// `*_Start`) travels on the corresponding `*_Next` channel. See the
    /// comment in pyatv's `protocols/companion/protocol.py::exchange_auth`
    /// ("`_Start` is only used for first message, then `_Next` is used for
    /// remaining message (even response to first message)").
    ///
    /// All other frame types map to themselves.
    public static func defaultResponseType(for requestType: CompanionFrameType) -> CompanionFrameType {
        switch requestType {
        case .psStart: return .psNext
        case .pvStart: return .pvNext
        default: return requestType
        }
    }

    /// Wait for the next frame of the given type.
    ///
    /// Only one waiter at a time may be registered for a given frame type;
    /// attempting to register a second concurrent waiter throws
    /// `.invalidState`. Each waiter is identity-checked on timeout so a
    /// stale timeout from a previous wait cannot steal this one.
    public func waitForFrame(type: CompanionFrameType, timeout: TimeInterval = 5.0) async throws(ATVError) -> Data {
        let timeoutNs = try timeoutNanoseconds(from: timeout, parameterName: "timeout")
        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                let waiter = PendingFrameWaiter(continuation)
                let waiterID = waiter.id

                switch tryInstallWaiter(type: type, waiter: waiter) {
                case .connectionClosed:
                    continuation.resume(
                        throwing: ATVError.connectionLost("Connection is closed")
                    )
                    return
                case .alreadyRegistered:
                    continuation.resume(
                        throwing: ATVError.invalidState(
                            "Frame waiter for type \(type) already registered"
                        ))
                    return
                case .installed:
                    break
                }

                let task = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNs)
                    } catch {
                        return
                    }
                    guard let self else { return }
                    if let removed = self.removeFrameWaiterIfOwned(type: type, id: waiterID) {
                        removed.continuation.resume(
                            throwing: ATVError.operationTimeout(
                                TimeoutContext(
                                    protocol: .companion,
                                    operation: "frame",
                                    requestID: "\(type)",
                                    duration: timeout
                                )
                            )
                        )
                    }
                }
                lock.withLock {
                    if frameWaiters[type.rawValue]?.id == waiterID {
                        waiter.timeoutTask = task
                    }
                }
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }
    }

    /// Atomically remove `frameWaiters[type]` only if the currently-stored
    /// waiter has the given UUID. Used by timeout tasks and error paths so
    /// they can't accidentally resume a waiter that was installed by a
    /// later call for the same frame type.
    private func removeFrameWaiterIfOwned(
        type: CompanionFrameType,
        id: UUID
    ) -> PendingFrameWaiter? {
        lock.withLock {
            if let waiter = frameWaiters[type.rawValue], waiter.id == id {
                return frameWaiters.removeValue(forKey: type.rawValue)
            }
            return nil
        }
    }

    /// Snapshot of the channel state observed under the lock by `send`.
    /// Lets the caller decide which terminal error (if any) to surface
    /// without holding the lock across `channel.writeAndFlush`.
    private enum SendChannelState {
        case ready(Channel, ChaCha20Cipher?)
        case notConnected
        case closed
    }

    /// Result of attempting to install a frame waiter under the lock.
    /// All three states are mutually exclusive and observed atomically.
    private enum WaiterInstallResult {
        /// The waiter was successfully installed in the dictionary.
        case installed
        /// Another waiter is already registered for this frame type.
        /// Only one concurrent waiter is allowed per type.
        case alreadyRegistered
        /// The connection has already been closed (or is mid-close).
        /// The caller should resume immediately with `.connectionLost`
        /// instead of registering a waiter that nothing will ever
        /// resolve. This guard is what makes the install/close race
        /// safe — `close()` sets `isClosed = true` under the same
        /// lock that this check reads it under.
        case connectionClosed
    }

    /// Atomically attempt to install a frame waiter for `type`, honouring
    /// the close state and the one-waiter-per-type invariant. The result
    /// tells the caller exactly which path to take next.
    private func tryInstallWaiter(
        type: CompanionFrameType,
        waiter: PendingFrameWaiter
    ) -> WaiterInstallResult {
        lock.withLock {
            if isClosed { return .connectionClosed }
            if frameWaiters[type.rawValue] != nil { return .alreadyRegistered }
            frameWaiters[type.rawValue] = waiter
            return .installed
        }
    }

    /// Enable encryption using derived keys from pair-verify.
    public func enableEncryption(outputKey: Data, inputKey: Data) {
        lock.lock()
        cipher = ChaCha20Cipher(encryptKey: outputKey, decryptKey: inputKey)
        lock.unlock()
    }

    /// Close the connection.
    ///
    /// Any pending frame waiters are resumed with `.connectionLost`
    /// **before** any awaited I/O so that in-flight pair-setup /
    /// pair-verify callers unblock immediately even if the underlying
    /// NIO channel close future is slow, stalled, or blocked behind
    /// event-loop work. The contract is enforced by the synchronous
    /// `drainAndResumeWaiters` helper — there is no async gap between
    /// removing a waiter from `frameWaiters` and resuming its
    /// continuation, so the caller can never be stranded behind a
    /// stuck channel close.
    public func close() async {
        let (ch, cont) = drainAndResumeWaiters(error: .connectionLost("Connection closed"))
        try? await ch?.close()
        cont?.finish()
        await shutdownOwnedGroupIfNeeded()
    }

    private func shutdownOwnedGroupIfNeeded() async {
        let shouldShutdown = lock.withLock {
            guard ownsGroup, !didShutdownGroup else { return false }
            didShutdownGroup = true
            return true
        }
        if shouldShutdown {
            try? await group.shutdownGracefully()
        }
    }

    /// Atomically: snapshot+clear `channel` and `frameWaiters` under the
    /// lock, then immediately resume every drained waiter with `error`
    /// (cancelling their timeout tasks). Returns the channel and frame
    /// stream continuation so the caller can finish them at their leisure
    /// — those don't have callers blocked on them, so they can't strand.
    ///
    /// Synchronous from the caller's perspective: by the time this
    /// function returns, every previously-pending waiter's continuation
    /// has had `resume(throwing: error)` called on it.
    ///
    /// Exposed as `internal` so tests can drive the contract directly
    /// without needing a slow-closing channel to prove the ordering.
    internal func drainAndResumeWaiters(
        error: ATVError
    ) -> (Channel?, AsyncStream<CompanionFrame>.Continuation?) {
        let (ch, cont, waiters):
            (
                Channel?,
                AsyncStream<CompanionFrame>.Continuation?,
                [PendingFrameWaiter]
            ) = lock.withLock {
                let ch = channel
                let cont = frameContinuation
                let waiters = Array(frameWaiters.values)
                channel = nil
                frameWaiters.removeAll()
                // Mark closed under the same lock that install paths
                // check, so a concurrent waiter that hasn't yet reached
                // its install step will see the closed state and refuse
                // to register instead of being silently stranded.
                isClosed = true
                return (ch, cont, waiters)
            }
        resumeWaiters(waiters, with: error)
        return (ch, cont)
    }

    /// Resume every waiter with the same error and cancel their timeout
    /// tasks so they don't linger.
    private func resumeWaiters(_ waiters: [PendingFrameWaiter], with error: ATVError) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    // MARK: - Internal Frame Processing (called from NIO event loop)

    /// Feed raw bytes into the frame assembler. Called by the NIO pipeline
    /// handler on the event loop thread. Also `internal` so tests can inject
    /// synthesized frames without a live TCP connection.
    internal func handleReceivedData(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)

        while receiveBuffer.count >= Self.headerLength {
            let payloadLength =
                (Int(receiveBuffer[1]) << 16)
                | (Int(receiveBuffer[2]) << 8)
                | Int(receiveBuffer[3])

            let totalLength = Self.headerLength + payloadLength
            guard receiveBuffer.count >= totalLength else { break }

            let header = Data(receiveBuffer[0..<Self.headerLength])
            var payload = Data(receiveBuffer[Self.headerLength..<totalLength])
            receiveBuffer = Data(receiveBuffer[totalLength...])

            let frameType = CompanionFrameType(rawValue: header[0]) ?? .unknown
            let currentCipher = cipher

            // Decrypt outside lock if possible, but cipher is thread-safe
            if let currentCipher, !payload.isEmpty {
                // Unlock for potentially slow crypto
                lock.unlock()
                do {
                    payload = try currentCipher.decrypt(payload, aad: header)
                } catch {
                    handleConnectionClosed(error: error)
                    return
                }
                lock.lock()
            }

            let frame = CompanionFrame(type: frameType, payload: payload)

            let waiter = frameWaiters.removeValue(forKey: frameType.rawValue)
            let cont = frameContinuation
            lock.unlock()

            // Cancel the waiter's timeout task before resuming so the stale
            // timeout can't race against a later waiter for the same frame
            // type. The identity check in `removeFrameWaiterIfOwned` is a
            // belt-and-braces guard in case cancellation doesn't stick.
            waiter?.timeoutTask?.cancel()
            waiter?.continuation.resume(returning: payload)
            cont?.yield(frame)

            Task { [weak self] in
                await self?.delegate?.connectionDidReceiveFrame(frame)
            }

            lock.lock()
        }

        lock.unlock()
    }

    /// Called by the NIO pipeline (or directly by tests) when the
    /// underlying channel goes away — either because the peer closed
    /// it, the local end errored, or `errorCaught` fired. Mirrors the
    /// state changes that explicit `close()` makes via
    /// `drainAndResumeWaiters`: pending waiters are resumed with
    /// `.connectionLost`, the dead channel is cleared, and `isClosed`
    /// is set so subsequent `send` / `waitForFrame` / `connect` calls
    /// fail terminally instead of touching the inactive channel.
    ///
    /// Idempotent: NIO calls `errorCaught` followed by `channelInactive`
    /// for the same disconnect, and both call this function. The first
    /// call performs the cleanup and emits exactly one delegate
    /// notification; subsequent calls observe `isClosed` under the
    /// lock and return early. This guarantees the original error from
    /// `errorCaught` is the one observers see, not the `nil` from the
    /// follow-up `channelInactive`.
    ///
    /// Exposed as `internal` so tests can drive the peer-close path
    /// without a live TCP socket.
    internal func handleConnectionClosed(error: Error?) {
        // Snapshot + clear under the lock, then resume waiters outside
        // the lock so their continuations don't run while we're holding
        // it. The lock body returns `nil` if the connection was already
        // closed — that early-return is what makes the function
        // idempotent against NIO's two-call disconnect sequence.
        let drained:
            (
                cont: AsyncStream<CompanionFrame>.Continuation?,
                waiters: [PendingFrameWaiter]
            )? = lock.withLock {
                if isClosed { return nil }
                let cont = frameContinuation
                let waiters = Array(frameWaiters.values)
                frameWaiters.removeAll()
                channel = nil
                isClosed = true
                return (cont, waiters)
            }

        // Already closed → nothing to do. The first caller already
        // resumed waiters, fired the delegate, and finished the stream.
        guard let drained else { return }

        let closureError: ATVError =
            error.map { ATVError.connectionLost("Connection closed: \(String(describing: $0))") }
            ?? .connectionLost("Connection closed")
        resumeWaiters(drained.waiters, with: closureError)

        Task { [weak self] in
            await self?.delegate?.connectionDidClose(error: error)
        }
        drained.cont?.finish()
        Task { [weak self] in
            await self?.shutdownOwnedGroupIfNeeded()
        }
    }
}

/// NIO channel handler for the Companion protocol.
/// Forwards raw bytes to CompanionConnection for frame assembly.
private final class CompanionFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: CompanionConnection

    init(connection: CompanionConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            connection.handleReceivedData(Data(bytes))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection.handleConnectionClosed(error: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.handleConnectionClosed(error: nil)
    }
}
