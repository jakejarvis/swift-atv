import Foundation

// MARK: - AirPlay Settings

/// AirPlay-specific version selection.
public enum AirPlayVersion: Int, Codable, Sendable {
    case auto = 0
    case v1 = 1
    case v2 = 2
}

/// MRP tunnel mode for AirPlay connections.
public enum MrpTunnelMode: Int, Codable, Sendable {
    case auto = 0
    case force = 1
    case disable = 2
}

/// Settings for the AirPlay protocol.
public struct AirPlaySettings: Codable, Sendable {
    public var identifier: String?
    public var credentials: String?
    public var password: String?
    public var airPlayVersion: AirPlayVersion
    public var mrpTunnelMode: MrpTunnelMode

    public init(
        identifier: String? = nil,
        credentials: String? = nil,
        password: String? = nil,
        airPlayVersion: AirPlayVersion = .auto,
        mrpTunnelMode: MrpTunnelMode = .auto
    ) {
        self.identifier = identifier
        self.credentials = credentials
        self.password = password
        self.airPlayVersion = airPlayVersion
        self.mrpTunnelMode = mrpTunnelMode
    }
}

// MARK: - Companion Settings

/// Settings for the Companion protocol.
public struct CompanionSettings: Codable, Sendable {
    public var identifier: String?
    public var credentials: String?

    public init(identifier: String? = nil, credentials: String? = nil) {
        self.identifier = identifier
        self.credentials = credentials
    }
}

// MARK: - MRP Settings

/// Settings for the MRP protocol.
public struct MrpSettings: Codable, Sendable {
    public var identifier: String?
    public var credentials: String?

    public init(identifier: String? = nil, credentials: String? = nil) {
        self.identifier = identifier
        self.credentials = credentials
    }
}

// MARK: - Client Identity Settings

/// Local controller identity sent to Apple TV protocols.
///
/// These values describe the app or controller running SwiftATV, not the
/// target Apple TV. They are used in Companion `_systemInfo`, MRP device-info
/// messages, AirPlay client-info payloads, and pair-setup display names.
public struct ClientIdentitySettings: Codable, Sendable {
    public static let defaultName = "SwiftATV"
    public static let defaultMacAddress = "02:73:77:69:66:74"
    public static let defaultModel = "iPhone10,6"
    public static let defaultDeviceID = "FF:70:79:61:74:76"
    public static let defaultOperatingSystemName = "iPhone OS"
    public static let defaultOperatingSystemBuild = "18G82"
    public static let defaultOperatingSystemVersion = "14.7.1"

    public var name: String
    public var macAddress: String
    public var model: String
    public var deviceID: String
    public var pairingIdentifier: String
    /// Stable Rapport-style identifier used as Companion `_systemInfo._i`.
    public var rapportIdentifier: String
    public var operatingSystemName: String
    public var operatingSystemBuild: String
    public var operatingSystemVersion: String

    public init(
        name: String = ClientIdentitySettings.defaultName,
        macAddress: String = ClientIdentitySettings.defaultMacAddress,
        model: String = ClientIdentitySettings.defaultModel,
        deviceID: String = ClientIdentitySettings.defaultDeviceID,
        pairingIdentifier: String? = nil,
        rapportIdentifier: String? = nil,
        operatingSystemName: String = ClientIdentitySettings.defaultOperatingSystemName,
        operatingSystemBuild: String = ClientIdentitySettings.defaultOperatingSystemBuild,
        operatingSystemVersion: String = ClientIdentitySettings.defaultOperatingSystemVersion
    ) {
        self.name = name
        self.macAddress = macAddress
        self.model = model
        self.deviceID = deviceID
        self.pairingIdentifier = pairingIdentifier ?? UUID().uuidString
        self.rapportIdentifier = rapportIdentifier ?? Self.makeRapportIdentifier()
        self.operatingSystemName = operatingSystemName
        self.operatingSystemBuild = operatingSystemBuild
        self.operatingSystemVersion = operatingSystemVersion
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case macAddress
        case model
        case deviceID
        case pairingIdentifier
        case rapportIdentifier
        case operatingSystemName
        case operatingSystemBuild
        case operatingSystemVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? Self.defaultName
        self.macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress) ?? Self.defaultMacAddress
        self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.defaultModel
        self.deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? Self.defaultDeviceID
        self.pairingIdentifier =
            try container.decodeIfPresent(String.self, forKey: .pairingIdentifier)
            ?? UUID().uuidString
        self.rapportIdentifier =
            try container.decodeIfPresent(String.self, forKey: .rapportIdentifier)
            ?? Self.makeRapportIdentifier()
        self.operatingSystemName =
            try container.decodeIfPresent(String.self, forKey: .operatingSystemName)
            ?? Self.defaultOperatingSystemName
        self.operatingSystemBuild =
            try container.decodeIfPresent(String.self, forKey: .operatingSystemBuild)
            ?? Self.defaultOperatingSystemBuild
        self.operatingSystemVersion =
            try container.decodeIfPresent(String.self, forKey: .operatingSystemVersion)
            ?? Self.defaultOperatingSystemVersion
    }

    static func makeRapportIdentifier() -> String {
        (0..<6)
            .map { _ in String(format: "%02x", Int.random(in: 0...255)) }
            .joined()
    }
}

// MARK: - Protocol Settings

/// Container for all protocol-specific settings.
public struct ProtocolSettings: Codable, Sendable {
    public var airplay: AirPlaySettings
    public var companion: CompanionSettings
    public var mrp: MrpSettings

    public init(
        airplay: AirPlaySettings = AirPlaySettings(),
        companion: CompanionSettings = CompanionSettings(),
        mrp: MrpSettings = MrpSettings()
    ) {
        self.airplay = airplay
        self.companion = companion
        self.mrp = mrp
    }
}

// MARK: - ATV Settings

/// Top-level settings for a device, combining local controller identity and protocol settings.
public struct ATVSettings: Codable, Sendable {
    public var clientIdentity: ClientIdentitySettings
    public var protocols: ProtocolSettings

    public init(
        clientIdentity: ClientIdentitySettings = ClientIdentitySettings(),
        protocols: ProtocolSettings = ProtocolSettings()
    ) {
        self.clientIdentity = clientIdentity
        self.protocols = protocols
    }

    private enum CodingKeys: String, CodingKey {
        case clientIdentity
        case protocols
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.clientIdentity =
            try container.decodeIfPresent(ClientIdentitySettings.self, forKey: .clientIdentity)
            ?? ClientIdentitySettings()
        self.protocols =
            try container.decodeIfPresent(ProtocolSettings.self, forKey: .protocols)
            ?? ProtocolSettings()
    }

    /// Get credentials for a specific protocol.
    public func credentials(for protocol: ATVProtocol) -> String? {
        switch `protocol` {
        case .airPlay: return protocols.airplay.credentials
        case .companion: return protocols.companion.credentials
        case .mrp: return protocols.mrp.credentials
        }
    }

    /// Set credentials for a specific protocol.
    public mutating func setCredentials(_ credentials: String?, for protocol: ATVProtocol) {
        switch `protocol` {
        case .airPlay: protocols.airplay.credentials = credentials
        case .companion: protocols.companion.credentials = credentials
        case .mrp: protocols.mrp.credentials = credentials
        }
    }

    /// Return a copy of these settings with a pairing result applied.
    public func applying(_ pairing: PairingResult) -> ATVSettings {
        var copy = self
        copy.apply(pairing)
        return copy
    }

    /// Persist credentials and service identifier from a pairing result.
    public mutating func apply(_ pairing: PairingResult) {
        setCredentials(pairing.serializedCredentials, for: pairing.service.protocol)
        switch pairing.service.protocol {
        case .airPlay:
            protocols.airplay.identifier = pairing.service.identifier
        case .companion:
            protocols.companion.identifier = pairing.service.identifier
        case .mrp:
            protocols.mrp.identifier = pairing.service.identifier
        }
    }
}
