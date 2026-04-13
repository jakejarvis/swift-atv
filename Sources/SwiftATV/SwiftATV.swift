import Foundation

/// SwiftATV - Swift library for controlling Apple TV devices.
///
/// Port of the Python pyatv library to idiomatic Swift.
/// Supports device discovery, pairing, and remote control via
/// MRP, DMAP, AirPlay, Companion, and RAOP protocols.
public enum SwiftATV {

    /// Library version.
    public static let version = "0.1.0"

    fileprivate static let connectProtocolPriority: [ATVProtocol] = [
        .mrp, .companion, .airPlay, .raop, .dmap,
    ]

    internal typealias ProtocolSetupOverride =
        @Sendable (
            FacadeAppleTV,
            ServiceInfo,
            HAPCredentials?
        ) async throws -> Void

    private final class ProtocolSetupOverrideStore: @unchecked Sendable {
        private let lock = NSLock()
        private var override: ProtocolSetupOverride?

        func get() -> ProtocolSetupOverride? {
            lock.withLock { override }
        }

        func set(_ override: ProtocolSetupOverride?) {
            lock.withLock {
                self.override = override
            }
        }
    }

    private static let protocolSetupOverrideStore = ProtocolSetupOverrideStore()

    internal static func withProtocolSetupOverride<T>(
        _ override: @escaping ProtocolSetupOverride,
        operation: () async throws -> T
    ) async rethrows -> T {
        protocolSetupOverrideStore.set(override)
        defer { protocolSetupOverrideStore.set(nil) }
        return try await operation()
    }

    #if canImport(Network)
        /// Scan the local network for Apple TV devices.
        ///
        /// Uses Bonjour/mDNS to discover Apple TV, HomePod, and AirPlay devices
        /// on the local network.
        ///
        /// - Parameters:
        ///   - timeout: Maximum time to scan in seconds. Default is 5.
        ///   - identifiers: Optional set of device identifiers to filter by.
        ///   - protocols: Optional set of protocols to scan for.
        /// - Returns: Array of discovered device configurations.
        ///
        /// ```swift
        /// let devices = try await SwiftATV.scan()
        /// for device in devices {
        ///     print("\(device.name) at \(device.address)")
        /// }
        /// ```
        public static func scan(
            timeout: TimeInterval = 5.0,
            identifiers: Set<String>? = nil,
            protocols: Set<ATVProtocol>? = nil
        ) async throws(ATVError) -> [AppleTVConfiguration] {
            try await ATVScanner.scan(
                timeout: timeout,
                identifiers: identifiers,
                protocols: protocols
            )
        }
    #endif

    /// Connect to an Apple TV device.
    ///
    /// Establishes a connection using the available protocol services
    /// in the configuration.
    ///
    /// Without an explicit protocol, implemented control protocols are tried
    /// in deterministic order (MRP, then Companion) and setup falls back past
    /// failed services until at least one protocol connects. If `settings`
    /// does not contain credentials for a protocol, `ServiceInfo.credentials`
    /// is used as a fallback.
    ///
    /// - Parameters:
    ///   - config: Device configuration obtained from scanning or manually created.
    ///   - protocol: Optional protocol to use. If nil, the best available is chosen.
    /// - Returns: A connected device instance.
    public static func connect(
        _ config: AppleTVConfiguration,
        protocol: ATVProtocol? = nil,
        settings: ATVSettings? = nil
    ) async throws(ATVError) -> any AppleTVDevice {
        let deviceSettings = settings ?? ATVSettings()

        let availableServices = config.services.filter(\.enabled)

        guard !availableServices.isEmpty else {
            throw ATVError.noService("No enabled services in configuration")
        }

        let selectedServices = availableServices.filter { service in
            guard let requestedProtocol = `protocol` else { return true }
            return service.protocol == requestedProtocol
        }

        guard !selectedServices.isEmpty else {
            if let requestedProtocol = `protocol` {
                throw ATVError.noService("No enabled \(requestedProtocol) service in configuration")
            }
            throw ATVError.noService("No enabled services in configuration")
        }

        let prioritizedServices = selectedServices.prioritizedForConnect()
        let facade = FacadeAppleTV(
            configuration: config,
            settings: deviceSettings
        )

        var setupCount = 0
        var bestError: ATVError?
        var sawUnsupportedService = false
        let requestedSpecificProtocol = `protocol` != nil

        for service in prioritizedServices {
            guard service.protocol.isConnectSupported else {
                let error = ATVError.notSupported("Connection not yet implemented for \(service.protocol)")
                if requestedSpecificProtocol {
                    await facade.close()
                    throw error
                }
                sawUnsupportedService = true
                continue
            }

            do {
                let credentials = try resolvedCredentials(for: service, settings: deviceSettings)
                if service.pairingRequirement == .mandatory, credentials == nil {
                    throw ATVError.noCredentials(
                        "\(service.protocol) service requires pairing credentials"
                    )
                }
                try await setupProtocol(facade, service: service, credentials: credentials)
                setupCount += 1
            } catch let error as ATVError {
                if requestedSpecificProtocol {
                    await facade.close()
                    throw error
                }
                if setupCount == 0, bestError == nil {
                    bestError = error
                }
            } catch {
                let wrapped = ATVError.wrap(error)
                if requestedSpecificProtocol {
                    await facade.close()
                    throw wrapped
                }
                if setupCount == 0, bestError == nil {
                    bestError = wrapped
                }
            }
        }

        guard setupCount > 0 else {
            await facade.close()
            if let bestError {
                throw bestError
            }
            if sawUnsupportedService {
                throw ATVError.noService("No supported enabled services in configuration")
            }
            throw ATVError.noService("No usable enabled services in configuration")
        }

        return facade
    }

    /// Pair with an Apple TV device.
    ///
    /// Initiates the pairing process for a specific protocol.
    ///
    /// Pairing is only opened for services whose pairing requirement is
    /// `.optional` or `.mandatory`; disabled, unsupported, and not-needed
    /// services fail before any network connection is opened.
    ///
    /// - Parameters:
    ///   - config: Device configuration.
    ///   - protocol: Protocol to pair with.
    /// - Returns: A pairing handler to complete the pairing process.
    public static func pair(
        _ config: AppleTVConfiguration,
        protocol: ATVProtocol
    ) async throws(ATVError) -> any PairingHandler {
        guard let service = config.service(for: `protocol`) else {
            throw ATVError.noService("No \(`protocol`) service found")
        }
        guard service.enabled else {
            throw ATVError.noService("No enabled \(`protocol`) service found")
        }
        try validatePairingService(service)

        switch `protocol` {
        case .companion:
            return try await CompanionPairingHandler.create(
                config: config,
                service: service
            )
        case .mrp:
            return try await MRPPairingHandler.create(
                config: config,
                service: service
            )
        default:
            throw ATVError.notSupported("Pairing not yet implemented for \(`protocol`)")
        }
    }

    private static func setupProtocol(
        _ facade: FacadeAppleTV,
        service: ServiceInfo,
        credentials: HAPCredentials?
    ) async throws(ATVError) {
        if let override = protocolSetupOverrideStore.get() {
            do {
                try await override(facade, service, credentials)
            } catch let error as ATVError {
                throw error
            } catch {
                throw ATVError.wrap(error)
            }
            return
        }
        try await facade.setupProtocol(service, credentials: credentials)
    }

    internal static func resolvedCredentials(
        for service: ServiceInfo,
        settings: ATVSettings
    ) throws(ATVError) -> HAPCredentials? {
        guard let serialized = settings.credentials(for: service.protocol) ?? service.credentials else {
            return nil
        }
        guard !serialized.isEmpty else {
            throw ATVError.invalidCredentials("Empty \(service.protocol) credentials")
        }
        do {
            return try HAPCredentials.parse(serialized)
        } catch {
            throw ATVError.invalidCredentials(
                "Invalid \(service.protocol) credentials: \(String(describing: error))"
            )
        }
    }

    internal static func validatePairingService(_ service: ServiceInfo) throws(ATVError) {
        switch service.pairingRequirement {
        case .mandatory, .optional:
            return
        case .disabled:
            throw ATVError.pairingFailed("Pairing is disabled for \(service.protocol)")
        case .unsupported:
            throw ATVError.notSupported("Pairing is not supported for \(service.protocol)")
        case .notNeeded:
            throw ATVError.notSupported("Pairing is not needed for \(service.protocol)")
        }
    }
}

extension ATVProtocol {
    fileprivate var connectPriority: Int {
        SwiftATV.connectProtocolPriority.firstIndex(of: self) ?? Int.max
    }

    fileprivate var isConnectSupported: Bool {
        switch self {
        case .mrp, .companion:
            return true
        case .airPlay, .raop, .dmap:
            return false
        }
    }
}

extension Array where Element == ServiceInfo {
    fileprivate func prioritizedForConnect() -> [ServiceInfo] {
        enumerated()
            .sorted { lhs, rhs in
                let lhsPriority = lhs.element.protocol.connectPriority
                let rhsPriority = rhs.element.protocol.connectPriority
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
