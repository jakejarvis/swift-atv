import Foundation

/// SwiftATV - Swift library for controlling Apple TV devices.
///
/// Port of the Python pyatv library to idiomatic Swift.
/// Supports device discovery, pairing, and remote control via
/// MRP, DMAP, AirPlay, Companion, and RAOP protocols.
public enum SwiftATV {

    /// Library version.
    public static let version = "0.1.0"

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

        // Determine which protocols to connect
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

        // Create the facade that unifies protocol implementations
        let facade = FacadeAppleTV(
            configuration: config,
            settings: deviceSettings
        )

        var setupCount = 0
        for service in selectedServices {
            switch service.protocol {
            case .companion, .mrp:
                try await facade.setupProtocol(service)
                setupCount += 1
            case .dmap, .airPlay, .raop:
                if `protocol` != nil {
                    throw ATVError.notSupported("Connection not yet implemented for \(service.protocol)")
                }
                continue
            }
        }

        guard setupCount > 0 else {
            throw ATVError.noService("No supported enabled services in configuration")
        }

        return facade
    }

    /// Pair with an Apple TV device.
    ///
    /// Initiates the pairing process for a specific protocol.
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
}
