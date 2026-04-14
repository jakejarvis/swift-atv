import Foundation
import NIOCore
import SwiftProtobuf

internal final class AirPlayEventChannel: @unchecked Sendable {
    private let socket: AirPlayTCPConnection
    private let requestTimeout: TimeInterval
    private let onClose: (@Sendable (Error?) -> Void)?
    private var receiveTask: Task<Void, Never>?
    private var buffer = Data()

    init(
        host: String,
        port: Int,
        outputKey: Data,
        inputKey: Data,
        group: EventLoopGroup,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        onClose: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.socket = AirPlayTCPConnection(host: host, port: port, group: group)
        self.socket.enableEncryption(outputKey: outputKey, inputKey: inputKey)
        self.requestTimeout = requestTimeout
        self.onClose = onClose
    }

    func connect() async throws(ATVError) {
        try await socket.connect(
            timeout: requestTimeout,
            timeoutContext: TimeoutContext(
                protocol: .airPlay,
                operation: "connect",
                requestID: "event-channel",
                duration: requestTimeout
            )
        )
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        await socket.close()
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let data = try await socket.receive()
                try await handle(data)
            } catch {
                if !Task.isCancelled {
                    onClose?(error)
                }
                return
            }
        }
    }

    private func handle(_ data: Data) async throws(ATVError) {
        buffer.append(data)
        while let request = try AirPlayHTTPParser.parseRequest(from: &buffer) {
            var response = "\(request.protocolVersion) 200 OK\r\n"
            response += "Content-Length: 0\r\n"
            response += "Audio-Latency: 0\r\n"
            if let server = request.headers["server"], !server.isEmpty {
                response += "Server: \(server)\r\n"
            }
            if let cSeq = request.headers["cseq"], !cSeq.isEmpty {
                response += "CSeq: \(cSeq)\r\n"
            }
            response += "\r\n"
            try await socket.send(Data(response.utf8))
        }
    }
}

internal final class AirPlayDataStreamChannel: @unchecked Sendable {
    private static let headerSize = 32
    private static let syncType = paddedType("sync")
    private static let replyType = paddedType("rply")
    private static let command = Data("comm".utf8)
    private static let zeroCommand = Data(count: 4)

    private let socket: AirPlayTCPConnection
    private let requestTimeout: TimeInterval
    private let onMessage: @Sendable (ProtocolMessageMessage) -> Void
    private let onClose: (@Sendable (Error?) -> Void)?
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var buffer = Data()
    private var sendSequenceNumber = UInt64.random(in: 0x1_0000_0000...0x1_FFFF_FFFF)

    init(
        host: String,
        port: Int,
        outputKey: Data,
        inputKey: Data,
        group: EventLoopGroup,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout,
        onMessage: @escaping @Sendable (ProtocolMessageMessage) -> Void,
        onClose: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.socket = AirPlayTCPConnection(host: host, port: port, group: group)
        self.socket.enableEncryption(outputKey: outputKey, inputKey: inputKey)
        self.requestTimeout = requestTimeout
        self.onMessage = onMessage
        self.onClose = onClose
    }

    func connect() async throws(ATVError) {
        try await socket.connect(
            timeout: requestTimeout,
            timeoutContext: TimeoutContext(
                protocol: .airPlay,
                operation: "connect",
                requestID: "data-stream",
                duration: requestTimeout
            )
        )
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        await socket.close()
    }

    func sendProtobuf(_ message: ProtocolMessageMessage) async throws(ATVError) {
        let serialized: Data
        do {
            serialized = try message.serializedData()
        } catch {
            throw ATVError.wrap(error)
        }

        let payload = try Self.binaryPlist([
            "params": [
                "data": MRPVarint.encode(serialized.count) + serialized
            ]
        ])
        let sequenceNumber = lock.withLock {
            let current = sendSequenceNumber
            sendSequenceNumber += 1
            return current
        }
        let frame = Self.buildFrame(
            type: Self.syncType,
            command: Self.command,
            sequenceNumber: sequenceNumber,
            payload: payload
        )
        try await socket.send(frame)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let data = try await socket.receive()
                try await handle(data)
            } catch {
                if !Task.isCancelled {
                    onClose?(error)
                }
                return
            }
        }
    }

    private func handle(_ data: Data) async throws(ATVError) {
        let frameResult: Result<[AirPlayDataStreamFrame], ATVError> = lock.withLock {
            var frames: [AirPlayDataStreamFrame] = []
            buffer.append(data)
            do {
                while let frame = try Self.parseFrame(from: &buffer) {
                    frames.append(frame)
                }
                return .success(frames)
            } catch let err as ATVError {
                return .failure(err)
            } catch {
                return .failure(ATVError.wrap(error))
            }
        }
        let frames = try frameResult.get()

        for frame in frames {
            if frame.type.starts(with: Data("sync".utf8)) {
                try await sendReply(sequenceNumber: frame.sequenceNumber)
            }
            for message in try Self.messages(fromPayload: frame.payload) {
                onMessage(message)
            }
        }
    }

    private func sendReply(sequenceNumber: UInt64) async throws(ATVError) {
        let frame = Self.buildFrame(
            type: Self.replyType,
            command: Self.zeroCommand,
            sequenceNumber: sequenceNumber,
            payload: Data()
        )
        try await socket.send(frame)
    }

    internal static func messages(fromPayload payload: Data) throws(ATVError) -> [ProtocolMessageMessage] {
        guard !payload.isEmpty else {
            return []
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil)
                as? [String: Any],
            let params = plist["params"] as? [String: Any],
            let data = params["data"] as? Data
        else {
            return []
        }
        return try messages(fromDataField: data)
    }

    internal static func messages(fromDataField data: Data) throws(ATVError) -> [ProtocolMessageMessage] {
        var messages: [ProtocolMessageMessage] = []
        var offset = 0

        while offset < data.count {
            if data[offset] == 0x08 {
                do {
                    messages.append(
                        try ProtocolMessageMessage(
                            serializedBytes: Data(data[offset...]),
                            extensions: mrpProtocolExtensionMap
                        )
                    )
                } catch {
                    throw ATVError.wrap(error)
                }
                break
            }

            let lengthOffset = offset
            guard let length = try MRPVarint.decode(data, offset: &offset) else {
                throw ATVError.invalidData("AirPlay data stream has incomplete MRP varint")
            }
            guard data.count - offset >= length else {
                throw ATVError.invalidData("AirPlay data stream has incomplete MRP payload")
            }

            let messageData = Data(data[offset..<(offset + length)])
            offset += length
            guard offset > lengthOffset else {
                throw ATVError.invalidData("AirPlay data stream parser made no progress")
            }

            do {
                messages.append(
                    try ProtocolMessageMessage(
                        serializedBytes: messageData,
                        extensions: mrpProtocolExtensionMap
                    )
                )
            } catch {
                throw ATVError.wrap(error)
            }
        }

        return messages
    }

    internal static func buildFrame(
        type: Data,
        command: Data,
        sequenceNumber: UInt64,
        payload: Data
    ) -> Data {
        var frame = Data(count: headerSize)
        writeUInt32BE(&frame, offset: 0, value: UInt32(headerSize + payload.count))
        frame.replaceSubrange(4..<16, with: padded(type, count: 12))
        frame.replaceSubrange(16..<20, with: padded(command, count: 4))
        writeUInt64BE(&frame, offset: 20, value: sequenceNumber)
        frame.append(payload)
        return frame
    }

    private static func parseFrame(from buffer: inout Data) throws(ATVError) -> AirPlayDataStreamFrame? {
        guard buffer.count >= headerSize else {
            return nil
        }
        let totalSize = Int(readUInt32BE(buffer, offset: 0))
        guard totalSize >= headerSize else {
            throw ATVError.invalidData("AirPlay data stream frame is smaller than its header")
        }
        guard buffer.count >= totalSize else {
            return nil
        }
        let frame = AirPlayDataStreamFrame(
            type: Data(buffer[4..<16]),
            command: Data(buffer[16..<20]),
            sequenceNumber: readUInt64BE(buffer, offset: 20),
            payload: Data(buffer[headerSize..<totalSize])
        )
        buffer = Data(buffer[totalSize...])
        return frame
    }

    private static func binaryPlist(_ value: Any) throws(ATVError) -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: value,
                format: .binary,
                options: 0
            )
        } catch {
            throw ATVError.wrap(error)
        }
    }

    private static func paddedType(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(Data(count: 12 - data.count))
        return data
    }

    private static func padded(_ data: Data, count: Int) -> Data {
        if data.count == count {
            return data
        }
        if data.count > count {
            return Data(data.prefix(count))
        }
        return data + Data(count: count - data.count)
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private static func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[offset + index])
        }
        return value
    }

    private static func writeUInt32BE(_ data: inout Data, offset: Int, value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeUInt64BE(_ data: inout Data, offset: Int, value: UInt64) {
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> (56 - index * 8)) & 0xFF)
        }
    }
}

private struct AirPlayDataStreamFrame: Sendable {
    let type: Data
    let command: Data
    let sequenceNumber: UInt64
    let payload: Data
}
