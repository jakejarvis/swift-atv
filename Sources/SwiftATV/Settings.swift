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

// MARK: - DMAP Settings

/// Settings for the DMAP protocol.
public struct DmapSettings: Codable, Sendable {
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

// MARK: - RAOP Settings

/// Settings for the RAOP protocol.
public struct RaopSettings: Codable, Sendable {
    public var identifier: String?
    public var credentials: String?
    public var password: String?
    public var airPlayVersion: AirPlayVersion
    public var timingServerPort: Int
    public var controlServerPort: Int

    public init(
        identifier: String? = nil,
        credentials: String? = nil,
        password: String? = nil,
        airPlayVersion: AirPlayVersion = .auto,
        timingServerPort: Int = 0,
        controlServerPort: Int = 0
    ) {
        self.identifier = identifier
        self.credentials = credentials
        self.password = password
        self.airPlayVersion = airPlayVersion
        self.timingServerPort = timingServerPort
        self.controlServerPort = controlServerPort
    }
}

// MARK: - Info Settings

/// General device identification settings.
public struct InfoSettings: Codable, Sendable {
    public var name: String?
    public var macAddress: String?
    public var model: DeviceModel?
    public var deviceID: String?
    public var remotePairingID: String?
    public var operatingSystem: OperatingSystem?

    public init(
        name: String? = nil,
        macAddress: String? = nil,
        model: DeviceModel? = nil,
        deviceID: String? = nil,
        remotePairingID: String? = nil,
        operatingSystem: OperatingSystem? = nil
    ) {
        self.name = name
        self.macAddress = macAddress
        self.model = model
        self.deviceID = deviceID
        self.remotePairingID = remotePairingID ?? UUID().uuidString
        self.operatingSystem = operatingSystem
    }
}

// MARK: - Protocol Settings

/// Container for all protocol-specific settings.
public struct ProtocolSettings: Codable, Sendable {
    public var airplay: AirPlaySettings
    public var companion: CompanionSettings
    public var dmap: DmapSettings
    public var mrp: MrpSettings
    public var raop: RaopSettings

    public init(
        airplay: AirPlaySettings = AirPlaySettings(),
        companion: CompanionSettings = CompanionSettings(),
        dmap: DmapSettings = DmapSettings(),
        mrp: MrpSettings = MrpSettings(),
        raop: RaopSettings = RaopSettings()
    ) {
        self.airplay = airplay
        self.companion = companion
        self.dmap = dmap
        self.mrp = mrp
        self.raop = raop
    }
}

// MARK: - ATV Settings

/// Top-level settings for a device, combining identification and protocol settings.
public struct ATVSettings: Codable, Sendable {
    public var info: InfoSettings
    public var protocols: ProtocolSettings

    public init(
        info: InfoSettings = InfoSettings(),
        protocols: ProtocolSettings = ProtocolSettings()
    ) {
        self.info = info
        self.protocols = protocols
    }

    /// Get credentials for a specific protocol.
    public func credentials(for protocol: ATVProtocol) -> String? {
        switch `protocol` {
        case .airPlay: return protocols.airplay.credentials
        case .companion: return protocols.companion.credentials
        case .dmap: return protocols.dmap.credentials
        case .mrp: return protocols.mrp.credentials
        case .raop: return protocols.raop.credentials
        }
    }

    /// Set credentials for a specific protocol.
    public mutating func setCredentials(_ credentials: String?, for protocol: ATVProtocol) {
        switch `protocol` {
        case .airPlay: protocols.airplay.credentials = credentials
        case .companion: protocols.companion.credentials = credentials
        case .dmap: protocols.dmap.credentials = credentials
        case .mrp: protocols.mrp.credentials = credentials
        case .raop: protocols.raop.credentials = credentials
        }
    }
}
