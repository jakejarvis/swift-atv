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

    private let host: String
    private let port: Int
    private let group: EventLoopGroup
    private let lock = NSLock()

    // Protected by lock
    private var channel: Channel?
    private var cipher: ChaCha20Cipher?
    private var receiveBuffer = Data()
    private var frameWaiters: [UInt8: CheckedContinuation<Data, Error>] = [:]
    private var frameContinuation: AsyncStream<CompanionFrame>.Continuation?
    private var _frameStream: AsyncStream<CompanionFrame>?

    public weak var delegate: CompanionConnectionDelegate?

    /// Stream of received frames.
    public var frameStream: AsyncStream<CompanionFrame> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _frameStream { return existing }
        let stream = AsyncStream<CompanionFrame> { [weak self] continuation in
            self?.lock.lock()
            self?.frameContinuation = continuation
            self?.lock.unlock()
        }
        _frameStream = stream
        return stream
    }

    public init(host: String, port: Int, group: EventLoopGroup? = nil) {
        self.host = host
        self.port = port
        self.group = group ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    /// Connect to the device.
    public func connect() async throws(ATVError) {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [self] channel in
                channel.pipeline.addHandler(CompanionFrameHandler(connection: self))
            }

        let ch: Channel
        do {
            ch = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw ATVError.wrap(error)
        }
        lock.withLock {
            self.channel = ch
        }
    }

    /// Send a frame to the device.
    public func send(type: CompanionFrameType, payload: Data = Data()) async throws(ATVError) {
        let channelAndCipher: (Channel, ChaCha20Cipher?)? = lock.withLock {
            guard let channel = self.channel else { return nil }
            return (channel, cipher)
        }
        guard let (channel, currentCipher) = channelAndCipher else {
            throw ATVError.connectionFailed("Not connected")
        }

        var header = Data(count: Self.headerLength)
        header[0] = type.rawValue
        let length = UInt32(payload.count)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        var frameData: Data
        if let currentCipher, !payload.isEmpty {
            let encrypted = try currentCipher.encrypt(payload, aad: header)
            let encLen = UInt32(encrypted.count)
            header[1] = UInt8((encLen >> 16) & 0xFF)
            header[2] = UInt8((encLen >> 8) & 0xFF)
            header[3] = UInt8(encLen & 0xFF)
            frameData = header + encrypted
        } else {
            frameData = header + payload
        }

        var buffer = channel.allocator.buffer(capacity: frameData.count)
        buffer.writeBytes(frameData)
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            throw ATVError.wrap(error)
        }
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
    /// Race safety: the response waiter is installed **before** the send so a
    /// fast device reply (landing between the send completing and the
    /// waiter being registered) cannot be silently dropped. The alternative
    /// ordering ("send then wait") causes occasional false timeouts when
    /// the Apple TV responds on the same event-loop tick as the write.
    public func sendAndReceive(
        type: CompanionFrameType,
        payload: Data = Data(),
        waitType: CompanionFrameType? = nil,
        timeout: TimeInterval = 5.0
    ) async throws(ATVError) -> Data {
        let responseType = waitType ?? Self.defaultResponseType(for: type)

        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                // 1. Install the waiter synchronously before any async work.
                let alreadyRegistered: Bool = lock.withLock {
                    if frameWaiters[responseType.rawValue] != nil { return true }
                    frameWaiters[responseType.rawValue] = continuation
                    return false
                }
                if alreadyRegistered {
                    continuation.resume(
                        throwing: ATVError.invalidState(
                            "Frame waiter for type \(responseType) already registered"
                        ))
                    return
                }
                // 2. Kick off the send + timeout in a child Task so the
                //    withCheckedThrowingContinuation body stays sync.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.send(type: type, payload: payload)
                    } catch {
                        let waiter = self.lock.withLock {
                            self.frameWaiters.removeValue(forKey: responseType.rawValue)
                        }
                        waiter?.resume(throwing: error)
                        return
                    }
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    let waiter = self.lock.withLock {
                        self.frameWaiters.removeValue(forKey: responseType.rawValue)
                    }
                    waiter?.resume(
                        throwing: ATVError.operationTimeout(
                            "Timeout waiting for frame type \(responseType)"
                        ))
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
    /// `.invalidState`. In practice only pair-setup and pair-verify use
    /// this API, and they both drive sequential message exchanges, so this
    /// constraint is a guard against future misuse rather than a current
    /// limitation.
    public func waitForFrame(type: CompanionFrameType, timeout: TimeInterval = 5.0) async throws(ATVError) -> Data {
        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                let alreadyRegistered: Bool = lock.withLock {
                    if frameWaiters[type.rawValue] != nil { return true }
                    frameWaiters[type.rawValue] = continuation
                    return false
                }
                if alreadyRegistered {
                    continuation.resume(
                        throwing: ATVError.invalidState(
                            "Frame waiter for type \(type) already registered"
                        ))
                    return
                }

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard let self else { return }
                    let waiter = lock.withLock {
                        frameWaiters.removeValue(forKey: type.rawValue)
                    }
                    waiter?.resume(
                        throwing: ATVError.operationTimeout(
                            "Timeout waiting for frame type \(type)"
                        ))
                }
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }
    }

    /// Enable encryption using derived keys from pair-verify.
    public func enableEncryption(outputKey: Data, inputKey: Data) {
        lock.lock()
        cipher = ChaCha20Cipher(encryptKey: outputKey, decryptKey: inputKey)
        lock.unlock()
    }

    /// Close the connection.
    public func close() async {
        let (ch, cont): (Channel?, AsyncStream<CompanionFrame>.Continuation?) = lock.withLock {
            let ch = channel
            let cont = frameContinuation
            channel = nil
            return (ch, cont)
        }
        try? await ch?.close()
        cont?.finish()
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
                    lock.lock()
                    continue
                }
                lock.lock()
            }

            let frame = CompanionFrame(type: frameType, payload: payload)

            let waiter = frameWaiters.removeValue(forKey: frameType.rawValue)
            let cont = frameContinuation
            lock.unlock()

            waiter?.resume(returning: payload)
            cont?.yield(frame)

            Task { [weak self] in
                await self?.delegate?.connectionDidReceiveFrame(frame)
            }

            lock.lock()
        }

        lock.unlock()
    }

    fileprivate func handleConnectionClosed(error: Error?) {
        lock.lock()
        let cont = frameContinuation
        lock.unlock()

        Task { [weak self] in
            await self?.delegate?.connectionDidClose(error: error)
        }
        cont?.finish()
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
