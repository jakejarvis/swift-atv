import Foundation

/// Message types in the Companion protocol.
public enum CompanionMessageType: Int, Sendable {
    case event = 1
    case request = 2
    case response = 3
}

/// HID button commands for the Companion protocol.
public enum HIDCommand: Int, Sendable {
    case up = 1
    case down = 2
    case left = 3
    case right = 4
    case menu = 5
    case select = 6
    case home = 7
    case volumeUp = 8
    case volumeDown = 9
    case siri = 10
    case screensaver = 11
    case sleep = 12
    case wake = 13
    case playPause = 14
    case channelIncrement = 15
    case channelDecrement = 16
    case guide = 17
    case pageUp = 18
    case pageDown = 19
}

/// Media control commands sent via the Companion protocol.
public enum MediaControlCommand: Int, Sendable {
    case play = 1
    case pause = 2
    case nextTrack = 3
    case previousTrack = 4
    case getVolume = 5
    case setVolume = 6
    case skipBy = 7
    case fastForwardBegin = 8
    case fastForwardEnd = 9
    case rewindBegin = 10
    case rewindEnd = 11
}

/// System status values from the Companion protocol.
public enum CompanionSystemStatus: Int, Sendable {
    case asleep = 1
    case screensaver = 2
    case awake = 3
    case idle = 4
}

/// Default timeout for Companion protocol requests.
private let defaultTimeout: TimeInterval = 5.0

/// High-level Companion protocol handler.
///
/// Manages OPACK message exchange over the CompanionConnection,
/// including request/response correlation via XID, event dispatching,
/// and the full connection lifecycle (pair-verify, system info, sessions).
public actor CompanionProtocolHandler {
    private let connection: CompanionConnection
    private var xid: Int
    private var pendingRequests: [Int: CheckedContinuation<OPACK.Value, Error>] = [:]
    private var eventContinuation: AsyncStream<(String, OPACK.Value)>.Continuation?
    private var _eventStream: AsyncStream<(String, OPACK.Value)>?
    private var sessionID: UInt64 = 0
    private var isRunning = false
    private var receiveTask: Task<Void, Never>?

    /// Stream of events received from the device.
    public var eventStream: AsyncStream<(String, OPACK.Value)> {
        if let existing = _eventStream { return existing }
        let stream = AsyncStream<(String, OPACK.Value)> { continuation in
            self.eventContinuation = continuation
        }
        _eventStream = stream
        return stream
    }

    public init(connection: CompanionConnection) {
        self.connection = connection
        self.xid = Int.random(in: 0..<65536)
    }

    /// Start processing incoming OPACK frames.
    public func startReceiving() {
        guard !isRunning else { return }
        isRunning = true

        receiveTask = Task { [weak self] in
            guard let self else { return }
            let stream = connection.frameStream
            for await frame in stream {
                await self.handleFrame(frame)
            }
        }
    }

    /// Stop processing.
    public func stop() {
        isRunning = false
        receiveTask?.cancel()
        receiveTask = nil
        eventContinuation?.finish()

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ATVError.connectionLost("Protocol stopped"))
        }
        pendingRequests.removeAll()
    }

    // MARK: - Sending Messages

    /// Send an OPACK request and wait for the response.
    public func sendRequest(
        _ identifier: String,
        content: OPACK.Value = .dict([]),
        timeout: TimeInterval = defaultTimeout
    ) async throws -> OPACK.Value {
        xid += 1
        let currentXID = xid

        let message = OPACK.Value.dict([
            (.string("_i"), .string(identifier)),
            (.string("_t"), .uint(UInt64(CompanionMessageType.request.rawValue))),
            (.string("_c"), content),
            (.string("_x"), .uint(UInt64(currentXID))),
        ])

        let data = OPACK.encode(message)
        try await connection.send(type: .eOPACK, payload: data)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[currentXID] = continuation

            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let waiter = self.pendingRequests.removeValue(forKey: currentXID) {
                    waiter.resume(throwing: ATVError.operationTimeout(
                        "Timeout waiting for response to \(identifier)"
                    ))
                }
            }
        }
    }

    /// Send an OPACK event (no response expected).
    public func sendEvent(
        _ identifier: String,
        content: OPACK.Value = .dict([])
    ) async throws {
        let message = OPACK.Value.dict([
            (.string("_i"), .string(identifier)),
            (.string("_t"), .uint(UInt64(CompanionMessageType.event.rawValue))),
            (.string("_c"), content),
        ])

        let data = OPACK.encode(message)
        try await connection.send(type: .eOPACK, payload: data)
    }

    // MARK: - Session Management

    /// Send system info to the device (required after pair-verify).
    public func sendSystemInfo(
        name: String = "SwiftATV",
        model: String = "iPhone14,2",
        remotePairingID: String? = nil,
        clientID: String? = nil,
        deviceID: String? = nil
    ) async throws {
        let rpID = remotePairingID ?? UUID().uuidString
        let idsID = clientID ?? UUID().uuidString
        let pubID = deviceID ?? UUID().uuidString

        let content = OPACK.Value.dictionary([
            ("_bf", .uint(0)),
            ("_cf", .uint(512)),
            ("_clFl", .uint(128)),
            ("_i", .string(rpID)),
            ("_idsID", .string(idsID)),
            ("_pubID", .string(pubID)),
            ("_sf", .uint(256)),
            ("_sv", .string("170.18")),
            ("model", .string(model)),
            ("name", .string(name)),
        ])

        _ = try await sendRequest("_systemInfo", content: content)
    }

    /// Start a session with the device.
    public func startSession() async throws {
        let localSID = UInt64.random(in: 0..<UInt64(UInt32.max))

        let content = OPACK.Value.dictionary([
            ("_srvT", .string("com.apple.tvremoteservices")),
            ("_sid", .uint(localSID)),
        ])

        let response = try await sendRequest("_sessionStart", content: content)
        if let remoteSID = response["_c"]?["_sid"]?.intValue {
            sessionID = (UInt64(remoteSID) << 32) | localSID
        }
    }

    /// Subscribe to events from the device.
    public func subscribeEvents(_ events: [String]) async throws {
        let content = OPACK.Value.dictionary([
            ("_regEvents", .array(events.map { .string($0) })),
        ])
        _ = try await sendRequest("_interest", content: content)
    }

    /// Initialize touchpad.
    public func startTouch() async throws {
        let content = OPACK.Value.dictionary([
            ("_height", .uint(1000)),
            ("_tFl", .uint(0)),
            ("_width", .uint(1000)),
        ])
        _ = try await sendRequest("_touchStart", content: content)
    }

    /// Stop touchpad.
    public func stopTouch() async throws {
        let content = OPACK.Value.dictionary([
            ("_i", .uint(1)),
        ])
        try await sendEvent("_touchStop", content: content)
    }

    // MARK: - Frame Handling

    private func handleFrame(_ frame: CompanionFrame) {
        guard frame.type == .eOPACK || frame.type == .uOPACK || frame.type == .pOPACK else {
            return
        }

        guard let message = try? OPACK.decode(frame.payload) else {
            return
        }

        // Check message type
        let messageType = message["_t"]?.intValue.flatMap { Int($0) }

        if messageType == CompanionMessageType.response.rawValue {
            // Response to a request
            if let xidVal = message["_x"]?.intValue {
                let xid = Int(xidVal)
                if let continuation = pendingRequests.removeValue(forKey: xid) {
                    // Check for error
                    if let errorMsg = message["_em"]?.stringValue {
                        continuation.resume(throwing: ATVError.protocolError(errorMsg))
                    } else {
                        continuation.resume(returning: message)
                    }
                }
            }
        } else if messageType == CompanionMessageType.event.rawValue {
            // Event from device
            if let identifier = message["_i"]?.stringValue {
                eventContinuation?.yield((identifier, message))
            }
        }
    }
}
