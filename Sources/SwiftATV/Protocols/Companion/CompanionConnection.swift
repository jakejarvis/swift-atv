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
    public func connect() async throws {
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [self] channel in
                channel.pipeline.addHandler(CompanionFrameHandler(connection: self))
            }

        let ch = try await bootstrap.connect(host: host, port: port).get()
        lock.lock()
        self.channel = ch
        lock.unlock()
    }

    /// Send a frame to the device.
    public func send(type: CompanionFrameType, payload: Data = Data()) async throws {
        lock.lock()
        guard let channel else {
            lock.unlock()
            throw ATVError.connectionFailed("Not connected")
        }
        let currentCipher = cipher
        lock.unlock()

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
        try await channel.writeAndFlush(buffer)
    }

    /// Send a frame and wait for a response with the matching frame type.
    public func sendAndReceive(
        type: CompanionFrameType,
        payload: Data = Data(),
        timeout: TimeInterval = 5.0
    ) async throws -> Data {
        try await send(type: type, payload: payload)
        return try await waitForFrame(type: type, timeout: timeout)
    }

    /// Wait for a specific frame type.
    public func waitForFrame(type: CompanionFrameType, timeout: TimeInterval = 5.0) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            frameWaiters[type.rawValue] = continuation
            lock.unlock()

            Task { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.lock.lock()
                let waiter = self?.frameWaiters.removeValue(forKey: type.rawValue)
                self?.lock.unlock()
                waiter?.resume(throwing: ATVError.operationTimeout(
                    "Timeout waiting for frame type \(type)"
                ))
            }
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
        lock.lock()
        let ch = channel
        let cont = frameContinuation
        channel = nil
        lock.unlock()
        try? await ch?.close()
        cont?.finish()
    }

    // MARK: - Internal Frame Processing (called from NIO event loop)

    fileprivate func handleReceivedData(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)

        while receiveBuffer.count >= Self.headerLength {
            let payloadLength = (Int(receiveBuffer[1]) << 16)
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
