import Foundation

internal enum AirPlayProtocolVersion: Sendable {
    case v1
    case v2
}

internal struct AirPlayFeatureFlags: OptionSet, Sendable {
    let rawValue: UInt64

    static let supportsUnifiedMediaControl = AirPlayFeatureFlags(rawValue: 1 << 38)
    static let supportsSystemPairing = AirPlayFeatureFlags(rawValue: 1 << 43)
    static let supportsHKPairingAndAccessControl = AirPlayFeatureFlags(rawValue: 1 << 46)
    static let supportsCoreUtilsPairingAndEncryption = AirPlayFeatureFlags(rawValue: 1 << 48)
    static let supportsAirPlayVideoV2 = AirPlayFeatureFlags(rawValue: 1 << 49)

    static func parse(_ raw: String?) throws(ATVError) -> AirPlayFeatureFlags {
        guard let raw else {
            return []
        }

        let trimmedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty else {
            return []
        }

        let parts = trimmedRaw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 1 || parts.count == 2 else {
            throw Self.invalidFeatureString(raw)
        }

        let lower = try Self.hexDigits(parts[0], raw: raw)
        let combined: String
        switch parts.count {
        case 1:
            combined = lower
        case 2:
            let upper = try Self.hexDigits(parts[1], raw: raw)
            guard lower.count <= 8, upper.count <= 8 else {
                throw Self.invalidFeatureString(raw)
            }
            combined = upper + lower.leftPadded(to: 8, with: "0")
        default:
            throw Self.invalidFeatureString(raw)
        }

        guard let value = UInt64(combined, radix: 16) else {
            throw Self.invalidFeatureString(raw)
        }
        return AirPlayFeatureFlags(rawValue: value)
    }

    private static func hexDigits(_ raw: String, raw original: String) throws(ATVError) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        guard !hex.isEmpty, hex.unicodeScalars.allSatisfy(Self.isHexDigit(_:)) else {
            throw Self.invalidFeatureString(original)
        }
        return hex
    }

    private static func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }

    private static func invalidFeatureString(_ raw: String) -> ATVError {
        ATVError.invalidData("Invalid AirPlay feature string: \(raw)")
    }
}

extension String {
    fileprivate func leftPadded(to count: Int, with character: Character) -> String {
        guard self.count < count else { return self }
        return String(repeating: String(character), count: count - self.count) + self
    }
}

internal enum AirPlaySupport {
    static let userAgent = "AirPlay/550.10"
    static let sourceVersion = "550.10"
    static let dataStreamClientTypeUUID = "1910A70F-DBC0-4242-AF95-115DB30604E1"
    static let companionDerivedServiceProperty = "_swiftatvCompanionDerivedAirPlay"

    static let pairingRequiredMask: UInt64 = 0x208
    static let accessControlCurrentUser = "2"

    static func protocolVersion(service: ServiceInfo, preferred: AirPlayVersion) -> AirPlayProtocolVersion {
        switch preferred {
        case .v1:
            return .v1
        case .v2:
            return .v2
        case .auto:
            let featureString = property(service.properties, keys: ["ft", "features"])
            let flags = (try? AirPlayFeatureFlags.parse(featureString)) ?? []
            if flags.contains(.supportsUnifiedMediaControl)
                || flags.contains(.supportsCoreUtilsPairingAndEncryption)
            {
                return .v2
            }
            return .v1
        }
    }

    static func supportsRemoteControlTunnel(
        service: ServiceInfo,
        credentials: HAPCredentials?,
        settings: ATVSettings
    ) -> Bool {
        guard settings.protocols.airplay.mrpTunnelMode != .disable else {
            return false
        }
        if settings.protocols.airplay.mrpTunnelMode == .force {
            return credentials != nil
        }
        guard credentials != nil else {
            return false
        }
        let isCompanionDerived = isCompanionDerivedService(service)
        if !isCompanionDerived {
            let version = protocolVersion(
                service: service,
                preferred: settings.protocols.airplay.airPlayVersion
            )
            guard version == .v2 else {
                return false
            }
        }

        guard isAppleTVService(service) else {
            return false
        }
        let majorVersion =
            property(service.properties, keys: ["osvers", "rpVr"])
            .flatMap { $0.split(separator: ".", maxSplits: 1).first }
            .flatMap { Double($0) }
            ?? 0
        return isCompanionDerived || majorVersion >= 13
    }

    static func isCompanionDerivedService(_ service: ServiceInfo) -> Bool {
        property(service.properties, keys: [companionDerivedServiceProperty]) == "true"
    }

    static func isAppleTVService(_ service: ServiceInfo) -> Bool {
        let model = property(service.properties, keys: ["model", "am", "rpMd"]) ?? ""
        return model.hasPrefix("AppleTV")
    }

    static func pairingRequirement(from properties: [String: String]) -> PairingRequirement {
        if property(properties, keys: ["acl"]) == "1" {
            return .disabled
        }
        if property(properties, keys: ["act"]) == accessControlCurrentUser {
            return .unsupported
        }
        let flags = airPlayStatusFlags(from: properties)
        if flags & pairingRequiredMask != 0 {
            return .mandatory
        }
        return .notNeeded
    }

    static func clientInfo(settings: ATVSettings) -> [String: Any] {
        [
            "isRemoteControlOnly": true,
            "qualifier": ["txtAirPlay"],
            "timingProtocol": "None",
            "name": settings.clientIdentity.name,
            "deviceID": settings.clientIdentity.deviceID,
            "macAddress": settings.clientIdentity.macAddress,
            "model": settings.clientIdentity.model,
            "sourceVersion": sourceVersion,
            "osName": settings.clientIdentity.operatingSystemName,
            "osVersion": settings.clientIdentity.operatingSystemVersion,
            "osBuildVersion": settings.clientIdentity.operatingSystemBuild,
        ]
    }

    static func property(_ properties: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = properties[key] {
                return value
            }
        }
        for (propertyKey, value) in properties {
            if keys.contains(where: { $0.caseInsensitiveCompare(propertyKey) == .orderedSame }) {
                return value
            }
        }
        return nil
    }

    private static func airPlayStatusFlags(from properties: [String: String]) -> UInt64 {
        guard let raw = property(properties, keys: ["sf", "flags"]) else {
            return 0
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("0x") {
            return UInt64(trimmed.dropFirst(2), radix: 16) ?? 0
        }
        return UInt64(trimmed) ?? UInt64(trimmed, radix: 16) ?? 0
    }
}
