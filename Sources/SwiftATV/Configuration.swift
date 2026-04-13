import Foundation

/// Information about a specific protocol service on a device.
public struct ServiceInfo: Codable, Sendable, Hashable, CustomStringConvertible {
    /// Protocol this service represents.
    public var `protocol`: ATVProtocol
    /// Port number the service is running on.
    public var port: Int
    /// Unique identifier for this service.
    public var identifier: String?
    /// Credentials for this service (e.g. from pairing).
    ///
    /// `SwiftATV.connect` uses protocol credentials from `ATVSettings` first
    /// and falls back to this value when settings do not contain credentials
    /// for the same protocol.
    public var credentials: String?
    /// Password for this service.
    public var password: String?
    /// Whether the service is enabled.
    public var enabled: Bool
    /// Properties from mDNS TXT record.
    public var properties: [String: String]
    /// Pairing requirement for this service.
    public var pairingRequirement: PairingRequirement

    public init(
        protocol: ATVProtocol,
        port: Int,
        identifier: String? = nil,
        credentials: String? = nil,
        password: String? = nil,
        enabled: Bool = true,
        properties: [String: String] = [:],
        pairingRequirement: PairingRequirement = .unsupported
    ) {
        self.protocol = `protocol`
        self.port = port
        self.identifier = identifier
        self.credentials = credentials
        self.password = password
        self.enabled = enabled
        self.properties = properties
        self.pairingRequirement = pairingRequirement
    }

    public var description: String {
        "\(`protocol`):\(port)"
    }
}

// MARK: - Default Ports

extension ServiceInfo {
    /// Default port for MRP protocol.
    public static let defaultMRPPort = 49152
    /// Default port for Companion protocol.
    public static let defaultCompanionPort = 49153
    /// Default port for AirPlay protocol.
    public static let defaultAirPlayPort = 7000
    /// Default port for RAOP protocol.
    public static let defaultRAOPPort = 7000
    /// Default port for DMAP protocol.
    public static let defaultDMAPPort = 3689
}

// MARK: - Apple TV Configuration

/// Full configuration for a discovered Apple TV device.
public struct AppleTVConfiguration: Codable, Sendable, Hashable, CustomStringConvertible {
    /// IP address of the device.
    public var address: String
    /// Name of the device (e.g. "Living Room").
    public var name: String
    /// Whether the device is in deep sleep.
    public var deepSleep: Bool
    /// Protocol services available on this device.
    public var services: [ServiceInfo]
    /// Information about the device hardware/software.
    public var deviceInfo: DeviceInfo
    /// Unique identifier for this device.
    public var identifier: String?

    public init(
        address: String,
        name: String,
        deepSleep: Bool = false,
        services: [ServiceInfo] = [],
        deviceInfo: DeviceInfo = DeviceInfo(),
        identifier: String? = nil
    ) {
        self.address = address
        self.name = name
        self.deepSleep = deepSleep
        self.services = services
        self.deviceInfo = deviceInfo
        self.identifier = identifier
    }

    /// Get the service for a specific protocol.
    public func service(for protocol: ATVProtocol) -> ServiceInfo? {
        services.first { $0.protocol == `protocol` }
    }

    /// Add or merge a service for this device.
    public mutating func addService(_ service: ServiceInfo) {
        if let index = services.firstIndex(where: { $0.protocol == service.protocol }) {
            // Merge: keep existing credentials if new service doesn't have them
            var merged = service
            if merged.credentials == nil {
                merged.credentials = services[index].credentials
            }
            if merged.password == nil {
                merged.password = services[index].password
            }
            services[index] = merged
        } else {
            services.append(service)
        }
    }

    /// The main identifier, preferring the explicit identifier, then MRP, then any service.
    public var mainIdentifier: String? {
        if let identifier { return identifier }
        if let mrpId = service(for: .mrp)?.identifier { return mrpId }
        return services.first?.identifier
    }

    /// All known identifiers for this device configuration.
    public var allIdentifiers: Set<String> {
        var identifiers = Set<String>()
        if let identifier, !identifier.isEmpty {
            identifiers.insert(identifier)
        }
        for service in services {
            if let identifier = service.identifier, !identifier.isEmpty {
                identifiers.insert(identifier)
            }
        }
        return identifiers
    }

    /// Whether this configuration has any service or device identifier matching `identifier`.
    public func matchesIdentifier(_ identifier: String) -> Bool {
        allIdentifiers.contains(identifier)
    }

    public var description: String {
        let serviceList = services.map(\.description).joined(separator: ", ")
        return "\(name) (\(address)) [\(serviceList)]"
    }
}
