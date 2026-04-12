import Foundation

/// MRP (Media Remote Protocol) frame types.
///
/// MRP uses protobuf-encoded messages with varint length framing
/// over an encrypted TCP connection.
public enum MRPFrameType: UInt8, Sendable {
    case protocolMessage = 0
}

/// MRP message types as defined in the protobuf schema.
public enum MRPMessageType: Int, Sendable {
    case deviceInfoMessage = 1
    case cryptoPairingMessage = 4
    case notificationMessage = 7
    case setStateMessage = 8
    case sendCommandMessage = 10
    case keyboardMessage = 11
    case registerForGamepadEvents = 13
    case sendVoiceInputMessage = 14
    case playbackQueueRequest = 15
    case transactionMessage = 16
    case clientUpdatesConfigMessage = 17
    case volumeControlAvailabilityMessage = 18
    case nowPlayingMessage = 19
    case registerHIDDeviceMessage = 22
    case setNowPlayingClientMessage = 23
    case setNowPlayingPlayerMessage = 24
    case wakeDeviceMessage = 28
    case volumeControlMessage = 29
    case volumeDidChangeMessage = 30
    case setDefaultSupportedCommandsMessage = 32
    case playerClientPropertiesMessage = 33
    case modifyOutputContextRequestMessage = 34
    case sendHIDEventMessage = 38
    case removeClientMessage = 43
    case updateClientMessage = 44
    case updateContentItemMessage = 46
    case sendCommandResultMessage = 48
    case playerPathMessage = 50
    case setHiliteModeMessage = 51
    case sendButtonEvent = 52
    case sendPackedVirtualTouchEvent = 53
    case sendLyricsEvent = 54
    case playbackQueueCapabilities = 59
    case origin = 60
    case getKeyboardSessionMessage = 65
    case textInputMessage = 66
    case getVoiceInputDevicesMessage = 67
    case removeEndpointsMessage = 70
    case updateOutputDeviceMessage = 72
    case setConnectionStateMessage = 73
    case setSupportedCommands = 78
    case accessibilityModeChangedMessage = 79
}

/// MRP connection state.
public enum MRPConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case ready
}

/// Placeholder for MRP protocol connection.
///
/// The MRP protocol uses protobuf-encoded messages over TCP with
/// ChaCha20-Poly1305 encryption after pair-verify. Full implementation
/// requires compiling the .proto message definitions from pyatv.
///
/// Key differences from Companion:
/// - Uses protobuf instead of OPACK for serialization
/// - Varint length-prefixed framing instead of 4-byte header
/// - Different key derivation salt/info values
/// - Heartbeat mechanism for connection health
/// - Player state tracking across multiple clients/players
/// Thread safety: Mutable state protected by NSLock.
public final class MRPConnection: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let lock = NSLock()
    private var state: MRPConnectionState = .disconnected

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Connect to the MRP service.
    public func connect() async throws {
        // TODO: Implement MRP connection using SwiftNIO
        throw ATVError.notSupported("MRP protocol not yet implemented")
    }

    /// Close the connection.
    public func close() async {
        lock.withLock {
            state = .disconnected
        }
    }
}

/// Placeholder for MRP player state tracking.
///
/// Manages the state of multiple simultaneous media players/clients
/// on the device, tracking which client/player is active and
/// processing SET_STATE_MESSAGE updates.
public actor MRPPlayerState {
    private var activeClientBundleID: String?
    private var clients: [String: Playing] = [:]

    public init() {}

    /// The currently playing state from the active client.
    public var currentPlaying: Playing {
        guard let bundleID = activeClientBundleID else {
            return Playing()
        }
        return clients[bundleID] ?? Playing()
    }
}
