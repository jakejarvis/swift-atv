import Foundation

internal func timeoutNanoseconds(from seconds: TimeInterval, parameterName: String) throws(ATVError) -> UInt64 {
    guard seconds.isFinite, seconds >= 0 else {
        throw ATVError.invalidConfig("\(parameterName) must be a finite non-negative value")
    }

    let nanoseconds = seconds * 1_000_000_000
    guard nanoseconds < Double(UInt64.max) else {
        throw ATVError.invalidConfig("\(parameterName) is too large")
    }

    return UInt64(nanoseconds)
}

internal func isLikelyTimeoutError(_ error: Error) -> Bool {
    let description = String(describing: error).lowercased()
    return description.contains("timeout") || description.contains("timed out")
}
