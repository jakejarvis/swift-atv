import Foundation
import NIOCore
import NIOPosix

private final class PendingAirPlayMRPWaiter: @unchecked Sendable {
    let id = UUID()
    let continuation: CheckedContinuation<ProtocolMessageMessage, Error>
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<ProtocolMessageMessage, Error>) {
        self.continuation = continuation
    }
}

private typealias AirPlayTunnelCloseDrain = (
    AsyncStream<ProtocolMessageMessage>.Continuation?,
    [PendingAirPlayMRPWaiter],
    AirPlayControlConnection?,
    AirPlayEventChannel?,
    AirPlayDataStreamChannel?
)

/// MRP transport carried over an AirPlay 2 remote-control data stream.
internal final class AirPlayMRPTunnelTransport: @unchecked Sendable, MRPTransport {
    private let host: String
    private let port: Int
    private let credentialCandidates: [HAPCredentials]
    private let settings: ATVSettings
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let lock = NSLock()

    private var controlConnection: AirPlayControlConnection?
    private var eventChannel: AirPlayEventChannel?
    private var dataChannel: AirPlayDataStreamChannel?
    private var feedbackTask: Task<Void, Never>?
    private var waiters: [String: PendingAirPlayMRPWaiter] = [:]
    private var messageContinuation: AsyncStream<ProtocolMessageMessage>.Continuation?
    private var _messageStream: AsyncStream<ProtocolMessageMessage>?
    private var isClosed = false
    private var didShutdownGroup = false

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

    init(
        host: String,
        port: Int,
        credentialCandidates: [HAPCredentials],
        settings: ATVSettings,
        group: EventLoopGroup? = nil
    ) {
        self.host = host
        self.port = port
        self.credentialCandidates = credentialCandidates
        self.settings = settings
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
        guard !credentialCandidates.isEmpty else {
            throw ATVError.noCredentials("AirPlay MRP tunnel requires HAP credentials")
        }

        do {
            let verified = try await connectAndVerifyControlChannel()
            let control = verified.control
            let verifier = verified.verifier

            let controlKeys = try verifier.deriveKeys(
                salt: "Control-Salt",
                outputInfo: "Control-Write-Encryption-Key",
                inputInfo: "Control-Read-Encryption-Key"
            )
            control.enableEncryption(outputKey: controlKeys.outputKey, inputKey: controlKeys.inputKey)

            let eventPort = try await control.setupEventChannel(settings: settings)
            let eventKeys = try verifier.deriveKeys(
                salt: "Events-Salt",
                outputInfo: "Events-Read-Encryption-Key",
                inputInfo: "Events-Write-Encryption-Key"
            )
            let event = AirPlayEventChannel(
                host: host,
                port: eventPort,
                outputKey: eventKeys.outputKey,
                inputKey: eventKeys.inputKey,
                group: group,
                onClose: { [weak self] error in
                    self?.handleConnectionClosed(error: error)
                }
            )
            try await event.connect()

            try await control.sendRecord()

            let seed = UInt64.random(in: 0...UInt64(Int.max))
            let dataPort = try await control.setupDataStream(seed: seed)
            let dataKeys = try verifier.deriveKeys(
                salt: "DataStream-Salt\(seed)",
                outputInfo: "DataStream-Output-Encryption-Key",
                inputInfo: "DataStream-Input-Encryption-Key"
            )
            let data = AirPlayDataStreamChannel(
                host: host,
                port: dataPort,
                outputKey: dataKeys.outputKey,
                inputKey: dataKeys.inputKey,
                group: group,
                onMessage: { [weak self] message in
                    self?.handleReceivedMessage(message)
                },
                onClose: { [weak self] error in
                    self?.handleConnectionClosed(error: error)
                }
            )
            try await data.connect()

            let shouldClose = lock.withLock {
                if isClosed {
                    return true
                }
                controlConnection = control
                eventChannel = event
                dataChannel = data
                return false
            }
            if shouldClose {
                await data.close()
                await event.close()
                await control.close()
                throw ATVError.connectionLost("Connection has been closed")
            }

            startFeedback()
        } catch let err as ATVError {
            await close()
            throw err
        } catch {
            await close()
            throw ATVError.wrap(error)
        }
    }

    func enableEncryption(outputKey _: Data, inputKey _: Data) {
        // AirPlay already encrypts the HAP transport before MRP starts.
    }

    func send(_ message: ProtocolMessageMessage) async throws(ATVError) {
        let channel = lock.withLock { dataChannel }
        guard let channel else {
            let closed = lock.withLock { isClosed }
            if closed {
                throw ATVError.connectionLost("Connection has been closed")
            }
            throw ATVError.connectionFailed("AirPlay MRP tunnel is not connected")
        }
        try await channel.sendProtobuf(message)
    }

    func sendAndReceive(
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
                let waiter = PendingAirPlayMRPWaiter(continuation)
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

    func close() async {
        let drained = lock.withLock {
            let control = controlConnection
            let event = eventChannel
            let data = dataChannel
            let continuation = messageContinuation
            let waiters = Array(self.waiters.values)
            let feedback = feedbackTask

            controlConnection = nil
            eventChannel = nil
            dataChannel = nil
            messageContinuation = nil
            self.waiters.removeAll()
            feedbackTask = nil
            isClosed = true

            return (control, event, data, continuation, waiters, feedback)
        }

        drained.5?.cancel()
        for waiter in drained.4 {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: ATVError.connectionLost("Connection closed"))
        }
        drained.3?.finish()
        await drained.2?.close()
        await drained.1?.close()
        await drained.0?.close()
        await shutdownGroupIfNeeded()
    }

    private func connectAndVerifyControlChannel() async throws(ATVError) -> (
        control: AirPlayControlConnection,
        verifier: HAPPairVerifyHandler
    ) {
        var bestError: ATVError?

        for credentials in credentialCandidates {
            let control = AirPlayControlConnection(host: host, port: port, group: group)
            do {
                try await control.connect()
                let verifier = try await control.pairVerify(credentials: credentials)
                return (control, verifier)
            } catch let err {
                await control.close()
                switch err {
                case .connectionFailed, .connectionLost, .internalError:
                    throw err
                default:
                    bestError = bestError ?? err
                }
            }
        }

        throw bestError ?? ATVError.invalidCredentials("AirPlay pair-verify failed")
    }

    private enum WaiterInstallResult {
        case installed
        case duplicate
        case closed
    }

    private func installWaiter(key: String, waiter: PendingAirPlayMRPWaiter) -> WaiterInstallResult {
        lock.withLock {
            if isClosed { return .closed }
            if waiters[key] != nil { return .duplicate }
            waiters[key] = waiter
            return .installed
        }
    }

    private func removeWaiterIfOwned(key: String, id: UUID) -> PendingAirPlayMRPWaiter? {
        lock.withLock {
            guard let waiter = waiters[key], waiter.id == id else {
                return nil
            }
            return waiters.removeValue(forKey: key)
        }
    }

    private func handleReceivedMessage(_ message: ProtocolMessageMessage) {
        let idKey = Self.waiterKey(identifier: message.identifier, type: message.type)
        let typeKey = Self.waiterKey(identifier: "", type: message.type)
        let delivery = lock.withLock {
            let waiter = waiters.removeValue(forKey: idKey) ?? waiters.removeValue(forKey: typeKey)
            return (waiter, messageContinuation)
        }

        delivery.0?.timeoutTask?.cancel()
        delivery.0?.continuation.resume(returning: message)
        delivery.1?.yield(message)
        Task { [weak self] in
            await self?.delegate?.connectionDidReceiveMessage(message)
        }
    }

    private func handleConnectionClosed(error: Error?) {
        let drained: AirPlayTunnelCloseDrain? = lock.withLock {
            if isClosed {
                return nil
            }
            let continuation = messageContinuation
            let waiters = Array(self.waiters.values)
            let control = controlConnection
            let event = eventChannel
            let data = dataChannel
            controlConnection = nil
            eventChannel = nil
            dataChannel = nil
            messageContinuation = nil
            self.waiters.removeAll()
            feedbackTask?.cancel()
            feedbackTask = nil
            isClosed = true
            return (continuation, waiters, control, event, data)
        }
        guard let drained else { return }

        let closeError =
            error.map { ATVError.connectionLost("Connection closed: \(String(describing: $0))") }
            ?? ATVError.connectionLost("Connection closed")
        for waiter in drained.1 {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume(throwing: closeError)
        }
        drained.0?.finish()
        Task { [weak self] in
            await drained.4?.close()
            await drained.3?.close()
            await drained.2?.close()
            await self?.delegate?.connectionDidClose(error: error)
            await self?.shutdownGroupIfNeeded()
        }
    }

    private func startFeedback() {
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let control = self.lock.withLock({ self.controlConnection }) else {
                        throw ATVError.connectionLost("AirPlay control connection is closed")
                    }
                    try await control.sendFeedback()
                } catch {
                    self.handleConnectionClosed(error: error)
                    return
                }
            }
        }
        lock.withLock {
            feedbackTask?.cancel()
            feedbackTask = task
        }
    }

    private func shutdownGroupIfNeeded() async {
        let shouldShutdown = lock.withLock {
            guard ownsGroup, !didShutdownGroup else { return false }
            didShutdownGroup = true
            return true
        }
        if shouldShutdown {
            try? await group.shutdownGracefully()
        }
    }

    private static func waiterKey(identifier: String, type: ProtocolMessageMessage.TypeEnum) -> String {
        if !identifier.isEmpty {
            return "id:\(identifier)"
        }
        return "type:\(type.rawValue)"
    }
}
