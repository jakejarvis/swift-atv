import Foundation

/// Errors that can occur when interacting with Apple TV devices.
public enum ATVError: Error, LocalizedError, Sendable {
    /// No service found for the requested protocol.
    case noService(String)

    /// Failed to establish connection to device.
    case connectionFailed(String)

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
    case operationTimeout(String)

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
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .connectionLost(let msg): return "Connection lost: \(msg)"
        case .pairingFailed(let msg): return "Pairing failed: \(msg)"
        case .authenticationFailed(let msg): return "Authentication failed: \(msg)"
        case .notSupported(let msg): return "Not supported: \(msg)"
        case .invalidCredentials(let msg): return "Invalid credentials: \(msg)"
        case .noCredentials(let msg): return "No credentials: \(msg)"
        case .operationTimeout(let msg): return "Operation timeout: \(msg)"
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
}
