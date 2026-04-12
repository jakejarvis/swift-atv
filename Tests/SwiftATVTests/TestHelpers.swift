import Foundation

// Shared across test files in the SwiftATVTests module.
// (HAPCredentials.swift has a throwing `Data(hexString:)` but tests want
// a non-throwing version that fits in hardcoded vector declarations.)

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init(hex: String) {
        var data = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            if let b = UInt8(hex[i..<j], radix: 16) {
                data.append(b)
            }
            i = j
        }
        self = data
    }
}
