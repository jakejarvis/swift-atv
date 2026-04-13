import Foundation

enum DiscoveryIdentifiers {
    private static let orderedKeys = [
        "UniqueIdentifier",
        "deviceid",
        "DACP-ID",
        "hg",
        "gid",
        "rpMRtID",
        "rpAD",
        "rpHN",
        "rpHI",
    ]

    static func all(from properties: [String: String]) -> Set<String> {
        Set(orderedValues(from: properties))
    }

    static func preferred(from properties: [String: String]) -> String? {
        orderedValues(from: properties).first
    }

    private static func orderedValues(from properties: [String: String]) -> [String] {
        orderedKeys.compactMap { key in
            guard let value = property(properties, key: key) else {
                return nil
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func property(_ properties: [String: String], key: String) -> String? {
        if let value = properties[key] {
            return value
        }

        for (propertyKey, value) in properties {
            if key.caseInsensitiveCompare(propertyKey) == .orderedSame {
                return value
            }
        }
        return nil
    }
}
