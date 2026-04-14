import Foundation

/// Structured context for an operation that exceeded its timeout.
public struct TimeoutContext: Sendable, Hashable {
    /// Protocol involved in the operation, when known.
    public let `protocol`: ATVProtocol?
    /// Stable operation category, such as `connect`, `request`, or `waitForState`.
    public let operation: String
    /// Request, frame, message, or state identifier involved in the timeout.
    public let requestID: String?
    /// Timeout duration in seconds.
    public let duration: TimeInterval

    public init(
        protocol: ATVProtocol? = nil,
        operation: String,
        requestID: String? = nil,
        duration: TimeInterval
    ) {
        self.protocol = `protocol`
        self.operation = operation
        self.requestID = requestID
        self.duration = duration
    }
}

/// A protocol setup failure recorded during automatic connection fallback.
public struct ConnectionAttemptError: Sendable {
    public let `protocol`: ATVProtocol
    public let port: Int
    public let serviceIdentifier: String?
    public let isDerivedAirPlayTunnel: Bool
    public let credentialSource: ConnectCredentialSource
    public let preflightStatus: ServiceConnectabilityStatus?
    public let preflightDiagnostic: String?
    public let error: ATVError

    public init(
        protocol: ATVProtocol,
        port: Int,
        serviceIdentifier: String? = nil,
        isDerivedAirPlayTunnel: Bool = false,
        credentialSource: ConnectCredentialSource = .none,
        preflightStatus: ServiceConnectabilityStatus? = nil,
        preflightDiagnostic: String? = nil,
        error: ATVError
    ) {
        self.protocol = `protocol`
        self.port = port
        self.serviceIdentifier = serviceIdentifier
        self.isDerivedAirPlayTunnel = isDerivedAirPlayTunnel
        self.credentialSource = credentialSource
        self.preflightStatus = preflightStatus
        self.preflightDiagnostic = preflightDiagnostic
        self.error = error
    }
}

/// Errors that can occur when interacting with Apple TV devices.
public indirect enum ATVError: Error, LocalizedError, Sendable {
    /// No service found for the requested protocol.
    case noService(String)

    /// Failed to establish connection to device.
    ///
    /// `attempts` is populated when automatic connection setup exhausts every
    /// usable protocol without connecting.
    case connectionFailed(message: String, attempts: [ConnectionAttemptError] = [])

    /// Connection to device was lost.
    case connectionLost(String)

    /// Pairing with device failed.
    case pairingFailed(String)

    /// Authentication with device failed.
    case authenticationFailed(String)

    /// The requested operation is not supported.
    case notSupported(String)

    /// Invalid credentials provided.
    case invalidCredentials(String)

    /// No credentials available for the operation.
    case noCredentials(String)

    /// Operation timed out.
    case operationTimeout(TimeoutContext)

    /// Operation was cancelled before it completed.
    case operationCancelled(TimeoutContext)

    /// Device is in an invalid state for this operation.
    case invalidState(String)

    /// Device is in a blocked state.
    case blocked(String)

    /// Received an invalid response from the device.
    case invalidResponse(String)

    /// HTTP error with status code.
    case http(statusCode: Int, message: String)

    /// Protocol-level error.
    case protocolError(String)

    /// Settings-related error.
    case settingsError(String)

    /// Invalid configuration.
    case invalidConfig(String)

    /// Invalid data received.
    case invalidData(String)

    /// Back-off requested; retry later.
    case backOff(String)

    /// Wrapping case for non-ATVError errors bubbled up from NIO, CryptoKit,
    /// SwiftProtobuf, or other lower-level frameworks. Used at boundaries to
    /// preserve typed `throws(ATVError)` contracts on public APIs.
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .noService(let msg): return "No service: \(msg)"
        case .connectionFailed(let msg, let attempts):
            if attempts.isEmpty {
                return "Connection failed: \(msg)"
            }
            let details = attempts.map(Self.describeAttempt).joined(separator: "; ")
            return "Connection failed: \(msg) (\(details))"
        case .connectionLost(let msg): return "Connection lost: \(msg)"
        case .pairingFailed(let msg): return "Pairing failed: \(msg)"
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .notSupported(let msg): return "Not supported: \(msg)"
        case .invalidCredentials(let msg): return "Invalid credentials: \(msg)"
        case .noCredentials(let msg): return "No credentials: \(msg)"
        case .operationTimeout(let context): return "Operation timeout: \(Self.describeTimeout(context))"
        case .operationCancelled(let context): return "Operation cancelled: \(Self.describeTimeout(context))"
        case .invalidState(let msg): return "Invalid state: \(msg)"
        case .blocked(let msg): return "Blocked: \(msg)"
        case .invalidResponse(let msg): return "Invalid response: \(msg)"
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .settingsError(let msg): return "Settings error: \(msg)"
        case .invalidConfig(let msg): return "Invalid config: \(msg)"
        case .invalidData(let msg): return "Invalid data: \(msg)"
        case .backOff(let msg): return "Back off: \(msg)"
        case .internalError(let msg): return "Internal error: \(msg)"
        }
    }

    /// Wrap an arbitrary error into an `ATVError`. If the error is already
    /// an `ATVError`, it is returned as-is; otherwise it becomes
    /// `.internalError` with a description.
    public static func wrap(_ error: Error) -> ATVError {
        if let atv = error as? ATVError { return atv }
        return .internalError(String(describing: error))
    }

    private static func describeAttempt(_ attempt: ConnectionAttemptError) -> String {
        let message = attempt.error.errorDescription ?? String(describing: attempt.error)
        return "\(attempt.protocol): \(message)"
    }

    private static func describeTimeout(_ context: TimeoutContext) -> String {
        var parts: [String] = []
        if let `protocol` = context.protocol {
            parts.append("\(`protocol`)")
        }
        parts.append(context.operation)
        if let requestID = context.requestID, !requestID.isEmpty {
            parts.append(requestID)
        }
        parts.append("\(context.duration)s")
        return parts.joined(separator: " ")
    }
}
