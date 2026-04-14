import Foundation
import NIOCore
import NIOPosix
import SwiftProtobuf

/// MRP (Media Remote Protocol) frame types.
///
/// Direct MRP uses protobuf messages framed by a varint payload length.
/// After pair-verify, the protobuf payload is encrypted with HAP-derived
/// ChaCha20-Poly1305 keys using the 8-byte nonce variant.
public enum MRPFrameType: UInt8, Sendable {
    case protocolMessage = 0
}

/// MRP message types as defined by pyatv's `ProtocolMessage.proto`.
public enum MRPMessageType: Int, Sendable {
    case unknownMessage = 0
    case sendCommandMessage = 1
    case sendCommandResultMessage = 2
    case getStateMessage = 3
    case setStateMessage = 4
    case setArtworkMessage = 5
    case registerHIDDeviceMessage = 6
    case registerHIDDeviceResultMessage = 7
    case sendHIDEventMessage = 8
    case notificationMessage = 11
    case deviceInfoMessage = 15
    case clientUpdatesConfigMessage = 16
    case volumeControlAvailabilityMessage = 17
    case keyboardMessage = 23
    case getKeyboardSessionMessage = 24
    case textInputMessage = 25
    case playbackQueueRequestMessage = 32
    case transactionMessage = 33
    case cryptoPairingMessage = 34
    case deviceInfoUpdateMessage = 37
    case setConnectionStateMessage = 38
    case sendButtonEventMessage = 39
    case setHiliteModeMessage = 40
    case wakeDeviceMessage = 41
    case genericMessage = 42
    case sendPackedVirtualTouchEventMessage = 43
    case setNowPlayingClientMessage = 46
    case setNowPlayingPlayerMessage = 47
    case modifyOutputContextRequestMessage = 48
    case getVolumeMessage = 49
    case getVolumeResultMessage = 50
    case setVolumeMessage = 51
    case volumeDidChangeMessage = 52
    case removeClientMessage = 53
    case removePlayerMessage = 54
    case updateClientMessage = 55
    case updateContentItemMessage = 56
    case updateContentItemArtworkMessage = 57
    case volumeControlCapabilitiesDidChangeMessage = 64
    case updateOutputDeviceMessage = 65
    case removeOutputDevicesMessage = 66
    case remoteTextInputMessage = 67
    case getRemoteTextInputSessionMessage = 68
    case removeOutputDevicesMessage2 = 69
    case setDefaultSupportedCommandsMessage = 72
    case setDiscoveryModeMessage = 101
    case updateEndPointsMessage = 102
    case removeEndpointsMessage = 103
    case playerClientPropertiesMessage = 104
    case originClientPropertiesMessage = 105
    case audioFadeMessage = 106
    case audioFadeResponseMessage = 107
    case configureConnectionMessage = 120
}

/// MRP connection state.
public enum MRPConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case ready
}

/// Varint encoder/decoder used by the MRP TCP framing layer.
public enum MRPVarint {
    /// Encode a non-negative integer as a protobuf-style unsigned varint.
    public static func encode(_ value: Int) -> Data {
        precondition(value >= 0, "MRP varints cannot encode negative values")
        var remaining = UInt64(value)
        var data = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remaining != 0
        return data
    }

    /// Decode one varint from `data`, advancing `offset` on success.
    ///
    /// Returns `nil` when more bytes are needed.
    public static func decode(_ data: Data, offset: inout Int) throws(ATVError) -> Int? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = offset

        while index < data.count {
            let byte = data[index]
            let chunk = UInt64(byte & 0x7F)
            guard shift < 63 || chunk <= 1 else {
                throw ATVError.invalidData("MRP varint overflows UInt64")
            }
            result |= chunk << shift
            index += 1

            if byte & 0x80 == 0 {
                offset = index
                guard result <= UInt64(Int.max) else {
                    throw ATVError.invalidData("MRP varint length overflows Int")
                }
                return Int(result)
            }

            shift += 7
            guard shift < 64 else {
                throw ATVError.invalidData("MRP varint is too long")
            }
        }

        return nil
    }
}

internal protocol MRPConnectionDelegate: AnyObject, Sendable {
    func connectionDidReceiveMessage(_ message: ProtocolMessageMessage) async
    func connectionDidClose(error: Error?) async
}

internal protocol MRPTransport: AnyObject, Sendable {
    var delegate: MRPConnectionDelegate? { get set }
    var messageStream: AsyncStream<ProtocolMessageMessage> { get }

    func connect() async throws(ATVError)
    func enableEncryption(outputKey: Data, inputKey: Data)
    func send(_ message: ProtocolMessageMessage) async throws(ATVError)
    func sendAndReceive(
        _ message: ProtocolMessageMessage,
        responseType: ProtocolMessageMessage.TypeEnum?,
        timeout: TimeInterval
    ) async throws(ATVError) -> ProtocolMessageMessage
    func close() async
}

extension MRPTransport {
    func sendAndReceive(
        _ message: ProtocolMessageMessage,
        responseType: ProtocolMessageMessage.TypeEnum? = nil
    ) async throws(ATVError) -> ProtocolMessageMessage {
        try await sendAndReceive(message, responseType: responseType, timeout: 5.0)
    }
}

private final class PendingMRPWaiter: @unchecked Sendable {
    let id = UUID()
    let continuation: CheckedContinuation<ProtocolMessageMessage, Error>
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<ProtocolMessageMessage, Error>) {
        self.continuation = continuation
    }
}

/// Low-level direct-MRP TCP connection.
///
/// The wire format is `[varint payload length][protobuf payload]`. Once
/// pair-verify succeeds, only the protobuf payload is encrypted, matching
/// pyatv's `protocols/mrp/connection.py`.
public final class MRPConnection: @unchecked Sendable, MRPTransport {
    private let host: String
    private let port: Int
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let lock = NSLock()

    private var channel: Channel?
    private var cipher: ChaCha20Cipher8ByteNonce?
    private var receiveBuffer = Data()
    private var waiters: [String: PendingMRPWaiter] = [:]
    private var messageContinuation: AsyncStream<ProtocolMessageMessage>.Continuation?
    private var _messageStream: AsyncStream<ProtocolMessageMessage>?
    private var isClosed = false
    private var didShutdownGroup = false
    private var state: MRPConnectionState = .disconnected

    internal weak var delegate: MRPConnectionDelegate?

    internal var messageStream: AsyncStream<ProtocolMessageMessage> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = _messageStream {
            return existing
        }
        let stream = AsyncStream<ProtocolMessageMessage> { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            if self.isClosed {
                continuation.finish()
                return
            }
            self.messageContinuation = continuation
        }
        _messageStream = stream
        return stream
    }

    public init(host: String, port: Int, group: EventLoopGroup? = nil) {
        self.host = host
        self.port = port
        if let group {
            self.group = group
            self.ownsGroup = false
        } else {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsGroup = true
        }
    }

    /// Connect to the MRP service.
    public func connect() async throws(ATVError) {
        let alreadyClosed = lock.withLock { isClosed }
        guard !alreadyClosed else {
            throw ATVError.connectionLost("Connection has been closed")
        }

        lock.withLock { state = .connecting }
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [self] channel in
                channel.pipeline.addHandler(MRPFrameHandler(connection: self))
            }

        let ch: Channel
        do {
            ch = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            lock.withLock { state = .disconnected }
            throw ATVError.wrap(error)
        }

        lock.withLock {
            if isClosed {
                _ = ch.close(mode: .all)
                return
            }
            channel = ch
            state = .connected
        }
        let stillOpen = lock.withLock { !isClosed && channel != nil }
        guard stillOpen else {
            throw ATVError.connectionLost("Connection has been closed")
        }
    }

    /// Enable MRP payload encryption after pair-verify.
    public func enableEncryption(outputKey: Data, inputKey: Data) {
        lock.withLock {
            cipher = ChaCha20Cipher8ByteNonce(encryptKey: outputKey, decryptKey: inputKey)
            state = .ready
        }
    }

    internal func send(_ message: ProtocolMessageMessage) async throws(ATVError) {
        let stateSnapshot: (Channel?, ChaCha20Cipher8ByteNonce?, Bool) = lock.withLock {
            (channel, cipher, isClosed)
        }
        guard !stateSnapshot.2 else {
            throw ATVError.connectionLost("Connection has been closed")
        }
        guard let channel = stateSnapshot.0 else {
            throw ATVError.connectionFailed("Not connected")
        }

        let payload: Data
        do {
            let serialized = try message.serializedData()
            if let cipher = stateSnapshot.1 {
                payload = try cipher.encrypt(serialized)
            } else {
                payload = serialized
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }

        let frame = MRPVarint.encode(payload.count) + payload
        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            let nowClosed = lock.withLock { isClosed }
            if nowClosed {
                throw ATVError.connectionLost("Connection closed during send")
            }
            throw ATVError.wrap(error)
        }
    }

    internal func sendAndReceive(
        _ message: ProtocolMessageMessage,
        responseType: ProtocolMessageMessage.TypeEnum? = nil,
        timeout: TimeInterval = 5.0
    ) async throws(ATVError) -> ProtocolMessageMessage {
        let timeoutNs = try timeoutNanoseconds(from: timeout, parameterName: "timeout")
        var outbound = message
        if !outbound.hasIdentifier {
            outbound.identifier = UUID().uuidString
        }

        let waitKey = Self.waiterKey(
            identifier: outbound.identifier,
            type: responseType ?? outbound.type
        )
        let messageToSend = outbound

        do {
            return try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ProtocolMessageMessage, Error>) in
                let waiter = PendingMRPWaiter(continuation)
                let waiterID = waiter.id

                switch installWaiter(key: waitKey, waiter: waiter) {
                case .closed:
                    continuation.resume(throwing: ATVError.connectionLost("Connection is closed"))
                    return
                case .duplicate:
                    continuation.resume(
                        throwing: ATVError.invalidState("MRP waiter already registered for \(waitKey)")
                    )
                    return
                case .installed:
                    break
                }

                let task = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.send(messageToSend)
                    } catch {
                        if let removed = self.removeWaiterIfOwned(key: waitKey, id: waiterID) {
                            removed.continuation.resume(throwing: error)
                        }
                        return
                    }

                    do {
                        try await Task.sleep(nanoseconds: timeoutNs)
                    } catch {
                        return
                    }

                    if let removed = self.removeWaiterIfOwned(key: waitKey, id: waiterID) {
                        removed.continuation.resume(
                            throwing: ATVError.operationTimeout("Timeout waiting for MRP \(waitKey)")
                        )
                    }
                }

                lock.withLock {
                    if waiters[waitKey]?.id == waiterID {
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

    /// Close the connection.
    public func close() async {
        let (ch, cont, drained) = lock.withLock {
            let ch = channel
            let cont = messageContinuation
            let drained = Array(waiters.values)
            channel = nil
            waiters.removeAll()
            isClosed = true
            state = .disconnected
            return (ch, cont, drained)
        }
        resume(drained, with: ATVError.connectionLost("Connection closed"))
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

    private enum WaiterInstallResult {
        case installed
        case duplicate
        case closed
    }

    private func installWaiter(key: String, waiter: PendingMRPWaiter) -> WaiterInstallResult {
        lock.withLock {
            if isClosed { return .closed }
            if waiters[key] != nil { return .duplicate }
            waiters[key] = waiter
            return .installed
        }
    }

    private func removeWaiterIfOwned(key: String, id: UUID) -> PendingMRPWaiter? {
        lock.withLock {
            guard let waiter = waiters[key], waiter.id == id else {
                return nil
            }
            return waiters.removeValue(forKey: key)
        }
    }

    private func resume(_ drained: [PendingMRPWaiter], with error: ATVError) {
        for waiter in drained {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }

    private static func waiterKey(identifier: String, type: ProtocolMessageMessage.TypeEnum) -> String {
        if !identifier.isEmpty {
            return "id:\(identifier)"
        }
        return "type:\(type.rawValue)"
    }

    internal func handleReceivedData(_ data: Data) {
        lock.lock()
        receiveBuffer.append(data)

        while !receiveBuffer.isEmpty {
            var offset = 0
            let length: Int?
            do {
                length = try MRPVarint.decode(receiveBuffer, offset: &offset)
            } catch {
                receiveBuffer.removeAll()
                lock.unlock()
                handleConnectionClosed(error: error)
                return
            }

            guard let payloadLength = length else { break }
            guard payloadLength <= receiveBuffer.count - offset else { break }

            var payload = Data(receiveBuffer[offset..<offset + payloadLength])
            receiveBuffer = Data(receiveBuffer[(offset + payloadLength)...])
            let currentCipher = cipher

            if let currentCipher {
                lock.unlock()
                do {
                    payload = try currentCipher.decrypt(payload)
                } catch {
                    handleConnectionClosed(error: error)
                    return
                }
                lock.lock()
            }

            let message: ProtocolMessageMessage
            do {
                message = try ProtocolMessageMessage(
                    serializedBytes: payload,
                    extensions: mrpProtocolExtensionMap
                )
            } catch {
                lock.unlock()
                handleConnectionClosed(error: error)
                return
            }

            let idKey = Self.waiterKey(identifier: message.identifier, type: message.type)
            let typeKey = Self.waiterKey(identifier: "", type: message.type)
            let waiter = waiters.removeValue(forKey: idKey) ?? waiters.removeValue(forKey: typeKey)
            let cont = messageContinuation
            lock.unlock()

            waiter?.timeoutTask?.cancel()
            waiter?.continuation.resume(returning: message)
            cont?.yield(message)
            Task { [weak self] in
                await self?.delegate?.connectionDidReceiveMessage(message)
            }

            lock.lock()
        }

        lock.unlock()
    }

    internal func handleConnectionClosed(error: Error?) {
        let drained: (AsyncStream<ProtocolMessageMessage>.Continuation?, [PendingMRPWaiter])? =
            lock.withLock {
                if isClosed { return nil }
                let cont = messageContinuation
                let drained = Array(waiters.values)
                channel = nil
                waiters.removeAll()
                isClosed = true
                state = .disconnected
                return (cont, drained)
            }
        guard let drained else { return }

        let closureError: ATVError =
            error.map { ATVError.connectionLost("Connection closed: \(String(describing: $0))") }
            ?? .connectionLost("Connection closed")
        resume(drained.1, with: closureError)
        drained.0?.finish()
        Task { [weak self] in
            await self?.delegate?.connectionDidClose(error: error)
        }
        Task { [weak self] in
            await self?.shutdownOwnedGroupIfNeeded()
        }
    }
}

private final class MRPFrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: MRPConnection

    init(connection: MRPConnection) {
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

internal let mrpProtocolExtensionMap: SwiftProtobuf.SimpleExtensionMap = [
    Extensions_audioFadeMessage,
    Extensions_audioFadeResponseMessage,
    Extensions_clientUpdatesConfigMessage,
    Extensions_configureConnectionMessage,
    Extensions_cryptoPairingMessage,
    Extensions_deviceInfoMessage,
    Extensions_genericMessage,
    Extensions_getKeyboardSessionMessage,
    Extensions_getRemoteTextInputSessionMessage,
    Extensions_getVolumeMessage,
    Extensions_getVolumeResultMessage,
    Extensions_keyboardMessage,
    Extensions_modifyOutputContextRequestMessage,
    Extensions_notificationMessage,
    Extensions_originClientPropertiesMessage,
    Extensions_playbackQueueRequestMessage,
    Extensions_playerClientPropertiesMessage,
    Extensions_registerForGameControllerEventsMessage,
    Extensions_registerHIDDeviceMessage,
    Extensions_registerHIDDeviceResultMessage,
    Extensions_registerVoiceInputDeviceMessage,
    Extensions_registerVoiceInputDeviceResponseMessage,
    Extensions_remoteTextInputMessage,
    Extensions_removeClientMessage,
    Extensions_removeEndpointsMessage,
    Extensions_removeOutputDevicesMessage,
    Extensions_removePlayerMessage,
    Extensions_sendButtonEventMessage,
    Extensions_sendCommandMessage,
    Extensions_sendCommandResultMessage,
    Extensions_sendHIDEventMessage,
    Extensions_sendPackedVirtualTouchEventMessage,
    Extensions_sendVoiceInputMessage,
    Extensions_setArtworkMessage,
    Extensions_setConnectionStateMessage,
    Extensions_setDefaultSupportedCommandsMessage,
    Extensions_setDiscoveryModeMessage,
    Extensions_setHiliteModeMessage,
    Extensions_setNowPlayingClientMessage,
    Extensions_setNowPlayingPlayerMessage,
    Extensions_setRecordingStateMessage,
    Extensions_setStateMessage,
    Extensions_setVolumeMessage,
    Extensions_textInputMessage,
    Extensions_transactionMessage,
    Extensions_updateClientMessage,
    Extensions_updateContentItemArtworkMessage,
    Extensions_updateContentItemMessage,
    Extensions_updateEndPointsMessage,
    Extensions_updateOutputDeviceMessage,
    Extensions_updatePlayerMessage,
    Extensions_volumeControlAvailabilityMessage,
    Extensions_volumeControlCapabilitiesDidChangeMessage,
    Extensions_volumeDidChangeMessage,
    Extensions_wakeDeviceMessage,
]
