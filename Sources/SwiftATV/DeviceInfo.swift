import Foundation

/// Information about a discovered Apple TV device.
public struct DeviceInfo: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Operating system running on the device.
    public var operatingSystem: OperatingSystem
    /// OS version string (e.g. "15.0").
    public var version: String?
    /// Build number string (e.g. "19J346").
    public var buildNumber: String?
    /// Device model.
    public var model: DeviceModel
    /// Raw model identifier string (e.g. "AppleTV6,2").
    public var modelString: String?
    /// MAC address of the device.
    public var macAddress: String?

    public init(
        operatingSystem: OperatingSystem = .unknown,
        version: String? = nil,
        buildNumber: String? = nil,
        model: DeviceModel = .unknown,
        modelString: String? = nil,
        macAddress: String? = nil
    ) {
        self.operatingSystem = operatingSystem
        self.version = version
        self.buildNumber = buildNumber
        self.model = model
        self.modelString = modelString
        self.macAddress = macAddress
    }

    public var description: String {
        var parts: [String] = []
        parts.append("Model: \(model)")
        parts.append("OS: \(operatingSystem)")
        if let version { parts.append("Version: \(version)") }
        if let macAddress { parts.append("MAC: \(macAddress)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Model Identifier Lookup

extension DeviceInfo {
    /// Known model identifier strings to DeviceModel mapping.
    private static let modelIdentifiers: [String: DeviceModel] = [
        "AppleTV2,1": .gen2,
        "AppleTV3,1": .gen3,
        "AppleTV3,2": .gen3,
        "AppleTV5,3": .gen4,
        "AppleTV6,2": .gen4K,
        "AppleTV11,1": .gen4K2,
        "AppleTV14,1": .gen4K3,
        "AudioAccessory1,1": .homePod,
        "AudioAccessory1,2": .homePod,
        "AudioAccessory5,1": .homePodMini,
        "AudioAccessory6,1": .homePod2,
        "AirPort10,1": .airPortExpressGen2,
    ]

    /// Internal model name strings to DeviceModel mapping.
    private static let internalNames: [String: DeviceModel] = [
        "J33AP": .gen4,
        "J42dAP": .gen4K,
        "J255AP": .gen4K2,
        "J305AP": .gen4K3,
        "B238AP": .homePod,
        "B520AP": .homePodMini,
        "B620AP": .homePod2,
    ]

    /// OS string to OperatingSystem mapping.
    private static let osMap: [String: OperatingSystem] = [
        "TvOS": .tvOS,
        "tvOS": .tvOS,
        "MacOSX": .macOS,
        "macOS": .macOS,
        "AirPortOS": .airPortOS,
    ]

    /// Look up a DeviceModel from a model identifier string (e.g. "AppleTV6,2").
    public static func lookupModel(identifier: String) -> DeviceModel {
        return modelIdentifiers[identifier] ?? .unknown
    }

    /// Look up a DeviceModel from an internal name string (e.g. "J42dAP").
    public static func lookupModel(internalName: String) -> DeviceModel {
        return internalNames[internalName] ?? .unknown
    }

    /// Look up an OperatingSystem from an OS name string.
    public static func lookupOS(name: String) -> OperatingSystem {
        return osMap[name] ?? .unknown
    }

    /// Create DeviceInfo from mDNS TXT record properties.
    ///
    /// Recognizes common AirPlay/MRP/device-info keys and Companion `rpMd`,
    /// `rpVr`, and `rpMac` metadata. TXT key lookup is case-insensitive.
    public static func fromProperties(_ properties: [String: String]) -> DeviceInfo {
        var info = DeviceInfo()

        if let modelStr = property(properties, keys: ["model", "am"]) {
            info.modelString = modelStr
            info.model = lookupModel(identifier: modelStr)
        }

        if let internalName = property(properties, keys: ["internalName"]), info.model == .unknown {
            info.model = lookupModel(internalName: internalName)
        }

        if let companionModel = property(properties, keys: ["rpMd"]), !companionModel.isEmpty {
            let model = lookupModel(identifier: companionModel)
            if info.modelString == nil || (info.model == .unknown && model != .unknown) {
                info.modelString = companionModel
            }
            if info.model == .unknown {
                info.model = model
            }
        }

        if let osStr = property(properties, keys: ["osvers", "OSVersion"]) {
            info.version = osStr
        } else if let companionVersion = property(properties, keys: ["rpVr"]), !companionVersion.isEmpty {
            info.version = companionVersion
        }

        if let buildStr = property(properties, keys: ["srcvers", "SystemBuildVersion"]) {
            info.buildNumber = buildStr
        }

        if let osName = property(properties, keys: ["OSName", "os"]) {
            info.operatingSystem = lookupOS(name: osName)
        }

        if let mac = property(properties, keys: ["macAddress", "macaddress", "deviceid", "rpMac"]) {
            info.macAddress = mac
        }

        return info
    }

    private static func property(_ properties: [String: String], keys: [String]) -> String? {
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
}
