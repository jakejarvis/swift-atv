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
    /// `ATVClient.connect` uses protocol credentials from `ATVSettings` first
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

    /// Pairing status after considering saved settings and service credentials.
    public func effectivePairingStatus(settings: ATVSettings = ATVSettings()) -> EffectivePairingStatus {
        switch pairingRequirement {
        case .disabled:
            return .disabled
        case .unsupported:
            return .unsupported
        case .notNeeded:
            return .notNeeded
        case .optional:
            return hasCredentials(settings: settings) ? .paired : .unpaired
        case .mandatory:
            return hasCredentials(settings: settings) ? .paired : .credentialsMissing
        }
    }

    private func hasCredentials(settings: ATVSettings) -> Bool {
        guard let credentials = settings.credentials(for: `protocol`) ?? credentials else {
            return false
        }
        return !credentials.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Effective pairing status for a discovered service.
public enum EffectivePairingStatus: Sendable, Hashable {
    case disabled
    case unsupported
    case notNeeded
    case unpaired
    case credentialsMissing
    case paired
}

/// Connectability status for a discovered service.
public enum ServiceConnectabilityStatus: Sendable, Hashable {
    case connectable
    case disabled
    case unsupported
    case missingCredentials
    case invalidCredentials
    case airPlayTunnelUnavailable
}

/// Local preflight result for a service before opening a network connection.
public struct ServiceConnectability: Sendable, Hashable {
    public let service: ServiceInfo
    public let status: ServiceConnectabilityStatus
    public let diagnostic: String?

    public init(
        service: ServiceInfo,
        status: ServiceConnectabilityStatus,
        diagnostic: String? = nil
    ) {
        self.service = service
        self.status = status
        self.diagnostic = diagnostic
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
            // Merge: newer Bonjour data wins when it is populated, but a
            // sparse duplicate must not erase identifiers, TXT metadata, or
            // pairing state learned from an earlier result.
            var merged = service
            let existing = services[index]
            if merged.identifier == nil {
                merged.identifier = existing.identifier
            }
            if merged.credentials == nil {
                merged.credentials = existing.credentials
            }
            if merged.password == nil {
                merged.password = existing.password
            }
            if merged.properties.isEmpty {
                merged.properties = existing.properties
            } else {
                merged.properties = existing.properties.merging(merged.properties) { _, new in new }
            }
            if merged.pairingRequirement == .unsupported, existing.pairingRequirement != .unsupported {
                merged.pairingRequirement = existing.pairingRequirement
            }
            services[index] = merged
        } else {
            services.append(service)
        }
    }

    /// The main identifier, preferring the explicit identifier, then MRP, then any service.
    ///
    /// Service TXT records are used as a fallback when a service was decoded
    /// from Bonjour metadata but does not store a preferred identifier.
    public var mainIdentifier: String? {
        if let identifier = nonEmptyIdentifier(identifier) { return identifier }
        if let mrpService = service(for: .mrp),
            let mrpId = preferredIdentifier(from: mrpService)
        {
            return mrpId
        }
        for service in services {
            if let identifier = preferredIdentifier(from: service) {
                return identifier
            }
        }
        return nil
    }

    /// All known identifiers for this device configuration.
    ///
    /// Includes the configuration identifier, service identifiers, and
    /// recognized Bonjour TXT identifiers from each service.
    public var allIdentifiers: Set<String> {
        var identifiers = Set<String>()
        if let identifier = nonEmptyIdentifier(identifier) {
            identifiers.insert(identifier)
        }
        for service in services {
            if let identifier = nonEmptyIdentifier(service.identifier) {
                identifiers.insert(identifier)
            }
            identifiers.formUnion(DiscoveryIdentifiers.all(from: service.properties))
        }
        return identifiers
    }

    /// Whether this configuration has any service or device identifier matching `identifier`.
    public func matchesIdentifier(_ identifier: String) -> Bool {
        allIdentifiers.contains(identifier)
    }

    /// Local service connectability policy after applying saved settings.
    public func connectability(settings: ATVSettings = ATVSettings()) -> [ServiceConnectability] {
        services.map { service in
            connectability(for: service, settings: settings)
        }
    }

    /// Protocols that can be attempted with the supplied settings.
    public func connectableProtocols(settings: ATVSettings = ATVSettings()) -> [ATVProtocol] {
        connectability(settings: settings).compactMap { item in
            item.status == .connectable ? item.service.protocol : nil
        }
    }

    /// Preferred service to pair, ordered by the supplied protocol preference.
    public func preferredPairingService(
        settings: ATVSettings = ATVSettings(),
        protocols: [ATVProtocol] = ConnectOptions.defaultProtocolOrder
    ) -> ServiceInfo? {
        let candidates = services.filter { service in
            service.enabled && protocols.contains(service.protocol)
        }
        for `protocol` in protocols {
            guard let service = candidates.first(where: { $0.protocol == `protocol` }) else {
                continue
            }
            switch service.effectivePairingStatus(settings: settings) {
            case .unpaired, .credentialsMissing:
                return service
            case .disabled, .unsupported, .notNeeded, .paired:
                continue
            }
        }
        return nil
    }

    public var description: String {
        let serviceList = services.map(\.description).joined(separator: ", ")
        return "\(name) (\(address)) [\(serviceList)]"
    }

    private func preferredIdentifier(from service: ServiceInfo) -> String? {
        if let identifier = nonEmptyIdentifier(service.identifier) {
            return identifier
        }
        return DiscoveryIdentifiers.preferred(from: service.properties)
    }

    private func nonEmptyIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func connectability(
        for service: ServiceInfo,
        settings: ATVSettings
    ) -> ServiceConnectability {
        guard service.enabled else {
            return ServiceConnectability(
                service: service,
                status: .disabled,
                diagnostic: "Service is disabled"
            )
        }

        switch service.protocol {
        case .companion:
            return credentialRequiredConnectability(
                service: service,
                settings: settings,
                missingDiagnostic: "Companion requires pairing credentials"
            )

        case .mrp:
            if service.pairingRequirement == .mandatory {
                return credentialRequiredConnectability(
                    service: service,
                    settings: settings,
                    missingDiagnostic: "MRP service requires pairing credentials"
                )
            }
            return optionalCredentialConnectability(service: service, settings: settings)

        case .airPlay:
            return airPlayConnectability(service: service, settings: settings)
        }
    }

    private func credentialRequiredConnectability(
        service: ServiceInfo,
        settings: ATVSettings,
        missingDiagnostic: String
    ) -> ServiceConnectability {
        guard let serialized = settings.credentials(for: service.protocol) ?? service.credentials,
            !serialized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ServiceConnectability(
                service: service,
                status: .missingCredentials,
                diagnostic: missingDiagnostic
            )
        }
        do {
            _ = try HAPCredentials.parse(serialized)
            return ServiceConnectability(service: service, status: .connectable)
        } catch {
            return ServiceConnectability(
                service: service,
                status: .invalidCredentials,
                diagnostic: String(describing: error)
            )
        }
    }

    private func optionalCredentialConnectability(
        service: ServiceInfo,
        settings: ATVSettings
    ) -> ServiceConnectability {
        guard let serialized = settings.credentials(for: service.protocol) ?? service.credentials,
            !serialized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ServiceConnectability(service: service, status: .connectable)
        }
        do {
            _ = try HAPCredentials.parse(serialized)
            return ServiceConnectability(service: service, status: .connectable)
        } catch {
            return ServiceConnectability(
                service: service,
                status: .invalidCredentials,
                diagnostic: String(describing: error)
            )
        }
    }

    private func airPlayConnectability(
        service: ServiceInfo,
        settings: ATVSettings
    ) -> ServiceConnectability {
        guard settings.protocols.airplay.mrpTunnelMode != .disable else {
            return ServiceConnectability(
                service: service,
                status: .airPlayTunnelUnavailable,
                diagnostic: "AirPlay MRP tunnel is disabled by settings"
            )
        }

        do {
            let candidates = try ATVClient.resolvedAirPlayTunnelCredentialCandidates(
                for: service,
                configuration: self,
                settings: settings
            )
            guard
                AirPlaySupport.supportsRemoteControlTunnel(
                    service: service,
                    credentials: candidates.first,
                    settings: settings
                )
            else {
                return ServiceConnectability(
                    service: service,
                    status: .airPlayTunnelUnavailable,
                    diagnostic: "AirPlay MRP tunnel is not supported by this service"
                )
            }
            return ServiceConnectability(service: service, status: .connectable)
        } catch let error {
            switch error {
            case .noCredentials:
                return ServiceConnectability(
                    service: service,
                    status: .missingCredentials,
                    diagnostic: error.errorDescription
                )
            case .invalidCredentials:
                return ServiceConnectability(
                    service: service,
                    status: .invalidCredentials,
                    diagnostic: error.errorDescription
                )
            default:
                return ServiceConnectability(
                    service: service,
                    status: .unsupported,
                    diagnostic: error.errorDescription
                )
            }
        }
    }
}
