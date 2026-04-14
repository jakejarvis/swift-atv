import Foundation
import NIOCore
import NIOPosix

private final class PendingAirPlayDataWaiter: @unchecked Sendable {
    let continuation: CheckedContinuation<Data, Error>

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }
}

/// Raw TCP connection used by AirPlay control, event, and data channels.
///
/// The connection can switch to HAP transport encryption after pair-verify.
/// Received data is exposed as decrypted chunks via `receive()`.
internal final class AirPlayTCPConnection: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let lock = NSLock()

    private var channel: Channel?
    private var hapSession: HAPSession?
    private var pendingData: [Data] = []
    private var dataWaiter: PendingAirPlayDataWaiter?
    private var isClosed = false
    private var didShutdownGroup = false

    init(host: String, port: Int, group: EventLoopGroup? = nil) {
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

    func connect() async throws(ATVError) {
        let alreadyClosed = lock.withLock { isClosed }
        guard !alreadyClosed else {
            throw ATVError.connectionLost("Connection has been closed")
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { [self] channel in
                channel.pipeline.addHandler(AirPlayTCPHandler(connection: self))
            }

        let connected: Channel
        do {
            connected = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            throw ATVError.wrap(error)
        }

        lock.withLock {
            if isClosed {
                _ = connected.close(mode: .all)
                return
            }
            channel = connected
        }

        let stillOpen = lock.withLock { !isClosed && channel != nil }
        guard stillOpen else {
            throw ATVError.connectionLost("Connection has been closed")
        }
    }

    func enableEncryption(outputKey: Data, inputKey: Data) {
        lock.withLock {
            hapSession = HAPSession(outputKey: outputKey, inputKey: inputKey)
        }
    }

    func send(_ data: Data) async throws(ATVError) {
        let prepared: Result<(Channel, Data), ATVError> = lock.withLock {
            guard !isClosed else {
                return .failure(ATVError.connectionLost("Connection has been closed"))
            }
            guard let channel = self.channel else {
                return .failure(ATVError.connectionFailed(message: "Not connected"))
            }
            if let hapSession {
                do {
                    return .success((channel, try hapSession.encrypt(data)))
                } catch let err as ATVError {
                    return .failure(err)
                } catch {
                    return .failure(ATVError.wrap(error))
                }
            }
            return .success((channel, data))
        }
        let (channel, wireData) = try prepared.get()

        var buffer = channel.allocator.buffer(capacity: wireData.count)
        buffer.writeBytes(wireData)
        do {
            try await channel.writeAndFlush(buffer)
        } catch {
            let closed = lock.withLock { isClosed }
            if closed {
                throw ATVError.connectionLost("Connection closed during send")
            }
            throw ATVError.wrap(error)
        }
    }

    func receive() async throws(ATVError) -> Data {
        if let data = lock.withLock({ pendingData.isEmpty ? nil : pendingData.removeFirst() }) {
            return data
        }

        do {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if isClosed {
                    lock.unlock()
                    continuation.resume(throwing: ATVError.connectionLost("Connection has been closed"))
                    return
                }
                if let data = pendingData.isEmpty ? nil : pendingData.removeFirst() {
                    lock.unlock()
                    continuation.resume(returning: data)
                    return
                }
                if dataWaiter != nil {
                    lock.unlock()
                    continuation.resume(
                        throwing: ATVError.invalidState("AirPlay receive already has a waiter")
                    )
                    return
                }
                dataWaiter = PendingAirPlayDataWaiter(continuation)
                lock.unlock()
            }
        } catch let err as ATVError {
            throw err
        } catch {
            throw ATVError.wrap(error)
        }
    }

    func close() async {
        let drained = lock.withLock {
            let ch = channel
            let waiter = dataWaiter
            channel = nil
            dataWaiter = nil
            pendingData.removeAll()
            isClosed = true
            hapSession = nil
            return (ch, waiter)
        }
        drained.1?.continuation.resume(throwing: ATVError.connectionLost("Connection closed"))
        try? await drained.0?.close()
        await shutdownOwnedGroupIfNeeded()
    }

    internal func handleReceivedData(_ data: Data) {
        let delivery: (PendingAirPlayDataWaiter, Data)?
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }

        let decrypted: Data
        if let hapSession {
            do {
                decrypted = try hapSession.decrypt(data)
            } catch {
                lock.unlock()
                handleConnectionClosed(error: error)
                return
            }
        } else {
            decrypted = data
        }

        guard !decrypted.isEmpty else {
            lock.unlock()
            return
        }

        if let waiter = dataWaiter {
            dataWaiter = nil
            delivery = (waiter, decrypted)
        } else {
            pendingData.append(decrypted)
            delivery = nil
        }
        lock.unlock()

        delivery?.0.continuation.resume(returning: delivery?.1 ?? Data())
    }

    internal func handleConnectionClosed(error: Error?) {
        let drained = lock.withLock {
            if isClosed { return nil as (PendingAirPlayDataWaiter?, Channel?)? }
            let waiter = dataWaiter
            let ch = channel
            dataWaiter = nil
            pendingData.removeAll()
            channel = nil
            isClosed = true
            hapSession = nil
            return (waiter, ch)
        }
        guard let drained else { return }
        let closeError =
            error.map { ATVError.connectionLost("Connection closed: \(String(describing: $0))") }
            ?? ATVError.connectionLost("Connection closed")
        drained.0?.continuation.resume(throwing: closeError)
        Task { [weak self] in
            try? await drained.1?.close()
            await self?.shutdownOwnedGroupIfNeeded()
        }
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
}

private final class AirPlayTCPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: AirPlayTCPConnection

    init(connection: AirPlayTCPConnection) {
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
