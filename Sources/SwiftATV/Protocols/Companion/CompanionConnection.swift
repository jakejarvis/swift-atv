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

/// Header length for Companion protocol frames.
private let headerLength = 4

/// Authentication tag length for encrypted frames.
private let authTagLength = 16

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
public final class CompanionConnection: @unchecked Sendable {
    private let host: String
    private let port: Int
    private var channel: Channel?
    private let group: EventLoopGroup
    private var cipher: ChaCha20Cipher?
    private var receiveBuffer = Data()

    public weak var delegate: CompanionConnectionDelegate?

    /// Continuation-based frame receivers keyed by frame type (for auth) or stored generically.
    private var frameWaiters: [UInt8: CheckedContinuation<Data, Error>] = []
    private var frameContinuation: AsyncStream<CompanionFrame>.Continuation?
    private var _frameStream: AsyncStream<CompanionFrame>?

    /// Stream of received frames.
    public var frameStream: AsyncStream<CompanionFrame> {
        if let existing = _frameStream { return existing }
        let stream = AsyncStream<CompanionFrame> { continuation in
            self.frameContinuation = continuation
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
            .channelInitializer { channel in
                channel.pipeline.addHandler(CompanionFrameHandler(connection: self))
            }

        let channel = try await bootstrap.connect(host: host, port: port).get()
        self.channel = channel
    }

    /// Send a frame to the device.
    public func send(type: CompanionFrameType, payload: Data = Data()) async throws {
        guard let channel else {
            throw ATVError.connectionFailed("Not connected")
        }

        var header = Data(count: headerLength)
        header[0] = type.rawValue
        let length = UInt32(payload.count)
        header[1] = UInt8((length >> 16) & 0xFF)
        header[2] = UInt8((length >> 8) & 0xFF)
        header[3] = UInt8(length & 0xFF)

        var frameData: Data
        if let cipher, !payload.isEmpty {
            // Encrypt payload with header as AAD
            let encrypted = try cipher.encrypt(payload, aad: header)
            // Update length in header to include auth tag
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
            frameWaiters[type.rawValue] = continuation

            // Set up timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let waiter = self.frameWaiters.removeValue(forKey: type.rawValue) {
                    waiter.resume(throwing: ATVError.operationTimeout(
                        "Timeout waiting for frame type \(type)"
                    ))
                }
            }
        }
    }

    /// Enable encryption using derived keys from pair-verify.
    public func enableEncryption(outputKey: Data, inputKey: Data) {
        cipher = ChaCha20Cipher(encryptKey: outputKey, decryptKey: inputKey)
    }

    /// Close the connection.
    public func close() async {
        try? await channel?.close()
        channel = nil
        frameContinuation?.finish()
    }

    // MARK: - Internal Frame Processing

    fileprivate func handleReceivedData(_ data: Data) {
        receiveBuffer.append(data)

        while receiveBuffer.count >= headerLength {
            let payloadLength = (Int(receiveBuffer[1]) << 16)
                | (Int(receiveBuffer[2]) << 8)
                | Int(receiveBuffer[3])

            let totalLength = headerLength + payloadLength
            guard receiveBuffer.count >= totalLength else { break }

            let header = Data(receiveBuffer[0..<headerLength])
            var payload = Data(receiveBuffer[headerLength..<totalLength])
            receiveBuffer = Data(receiveBuffer[totalLength...])

            let frameType = CompanionFrameType(rawValue: header[0]) ?? .unknown

            // Decrypt if encryption is enabled and payload is non-empty
            if let cipher, !payload.isEmpty {
                do {
                    payload = try cipher.decrypt(payload, aad: header)
                } catch {
                    continue
                }
            }

            let frame = CompanionFrame(type: frameType, payload: payload)

            // Check if there's a waiter for this frame type
            if let waiter = frameWaiters.removeValue(forKey: frameType.rawValue) {
                waiter.resume(returning: payload)
            }

            // Also emit to the frame stream
            frameContinuation?.yield(frame)

            // Notify delegate
            Task {
                await delegate?.connectionDidReceiveFrame(frame)
            }
        }
    }

    fileprivate func handleConnectionClosed(error: Error?) {
        Task {
            await delegate?.connectionDidClose(error: error)
        }
        frameContinuation?.finish()
    }
}

/// NIO channel handler for the Companion protocol.
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
