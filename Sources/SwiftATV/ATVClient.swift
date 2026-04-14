import Foundation

/// High-level client entry points for discovering, pairing, and connecting to Apple TV devices.
///
/// Port of the Python pyatv library to idiomatic Swift.
/// Supports device discovery, pairing, and remote control via
/// MRP, AirPlay, and Companion protocols.
public enum ATVClient {

    /// Library version.
    public static let version = "0.2.2"

    fileprivate static let connectProtocolPriority: [ATVProtocol] = [
        .mrp, .airPlay, .companion,
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
        /// let devices = try await ATVClient.scan()
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

        /// Scan the local network for Apple TV devices and return non-fatal diagnostics.
        ///
        /// This method preserves discovered devices even when one Bonjour
        /// browser or resolver reports a recoverable failure. Use
        /// ``scan(timeout:identifiers:protocols:)`` when you only need device
        /// configurations.
        ///
        /// - Parameters:
        ///   - timeout: Maximum time to scan in seconds. Default is 5.
        ///   - identifiers: Optional set of device identifiers to filter by.
        ///   - protocols: Optional set of protocols to scan for.
        /// - Returns: Discovered device configurations plus scan diagnostics.
        public static func scanWithDiagnostics(
            timeout: TimeInterval = 5.0,
            identifiers: Set<String>? = nil,
            protocols: Set<ATVProtocol>? = nil
        ) async throws(ATVError) -> ATVScanResult {
            try await ATVScanner.scanWithDiagnostics(
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
    /// in deterministic order: direct MRP, then AirPlay-tunneled MRP when
    /// direct MRP is unavailable or fails, then Companion. The method returns
    /// as soon as the first usable protocol connects. If all automatic
    /// attempts fail, the thrown `.connectionFailed` contains the attempted
    /// protocols and their underlying errors. If `settings` does not contain
    /// credentials for a protocol, `ServiceInfo.credentials` is used as a
    /// fallback. The AirPlay tunnel tries AirPlay credentials first and
    /// Companion credentials second. Companion requires credentials.
    ///
    /// - Parameters:
    ///   - config: Device configuration obtained from scanning or manually created.
    ///   - protocol: Optional protocol to use. If nil, the best available is chosen.
    ///   - settings: Optional settings containing saved protocol credentials.
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

        try validateClientIdentity(settings: deviceSettings, for: config)

        let prioritizedServices = selectedServices.prioritizedForConnect()
        let facade = FacadeAppleTV(
            configuration: config,
            settings: deviceSettings
        )

        var attempts: [ConnectionAttemptError] = []
        let requestedSpecificProtocol = `protocol` != nil

        for service in prioritizedServices {
            do {
                let credentials: HAPCredentials?
                var airPlayCredentialCandidates: [HAPCredentials]?
                if service.protocol == .airPlay {
                    let candidates = try resolvedAirPlayTunnelCredentialCandidates(
                        for: service,
                        configuration: config,
                        settings: deviceSettings
                    )
                    let isSupported = AirPlaySupport.supportsRemoteControlTunnel(
                        service: service,
                        credentials: candidates.first,
                        settings: deviceSettings
                    )
                    guard isSupported else {
                        throw ATVError.notSupported("AirPlay MRP tunnel is not supported by this service")
                    }
                    credentials = candidates.first
                    airPlayCredentialCandidates = candidates
                } else {
                    credentials = try resolvedCredentials(for: service, settings: deviceSettings)
                    if service.protocol == .companion, credentials == nil {
                        throw ATVError.noCredentials("Companion requires pairing credentials")
                    }
                    if service.pairingRequirement == .mandatory, credentials == nil {
                        throw ATVError.noCredentials(
                            "\(service.protocol) service requires pairing credentials"
                        )
                    }
                }
                if let airPlayCredentialCandidates {
                    try await setupAirPlayProtocol(
                        facade,
                        service: service,
                        credentialCandidates: airPlayCredentialCandidates
                    )
                } else {
                    try await setupProtocol(facade, service: service, credentials: credentials)
                }
                return facade
            } catch let error as ATVError {
                if requestedSpecificProtocol {
                    await facade.close()
                    throw error
                }
                attempts.append(ConnectionAttemptError(protocol: service.protocol, port: service.port, error: error))
            } catch {
                let wrapped = ATVError.wrap(error)
                if requestedSpecificProtocol {
                    await facade.close()
                    throw wrapped
                }
                attempts.append(ConnectionAttemptError(protocol: service.protocol, port: service.port, error: wrapped))
            }
        }

        await facade.close()
        throw ATVError.connectionFailed(message: "No usable protocol connected", attempts: attempts)
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
        try await pair(config, protocol: `protocol`, settings: nil)
    }

    /// Pair with an Apple TV device using explicit settings.
    ///
    /// This overload is useful for protocol-specific pairing options, such as
    /// forcing AirPlay 2 pairing for manually constructed configurations, and
    /// for setting the local client identity shown in Apple TV pairing records.
    ///
    /// - Parameters:
    ///   - config: Device configuration.
    ///   - protocol: Protocol to pair with.
    ///   - settings: Optional settings used for protocol-specific pairing options.
    /// - Returns: A pairing handler to complete the pairing process.
    public static func pair(
        _ config: AppleTVConfiguration,
        protocol: ATVProtocol,
        settings: ATVSettings? = nil
    ) async throws(ATVError) -> any PairingHandler {
        let deviceSettings = settings ?? ATVSettings()
        guard let service = config.service(for: `protocol`) else {
            throw ATVError.noService("No \(`protocol`) service found")
        }
        guard service.enabled else {
            throw ATVError.noService("No enabled \(`protocol`) service found")
        }
        try validatePairingService(service)
        try validateClientIdentity(settings: deviceSettings, for: config)

        switch `protocol` {
        case .companion:
            return try await CompanionPairingHandler.create(
                config: config,
                service: service,
                settings: deviceSettings
            )
        case .mrp:
            return try await MRPPairingHandler.create(
                config: config,
                service: service,
                settings: deviceSettings
            )
        case .airPlay:
            return try await AirPlayPairingHandler.create(
                config: config,
                service: service,
                settings: deviceSettings
            )
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

    private static func setupAirPlayProtocol(
        _ facade: FacadeAppleTV,
        service: ServiceInfo,
        credentialCandidates: [HAPCredentials]
    ) async throws(ATVError) {
        if let override = protocolSetupOverrideStore.get() {
            do {
                try await override(facade, service, credentialCandidates.first)
            } catch let error as ATVError {
                throw error
            } catch {
                throw ATVError.wrap(error)
            }
            return
        }
        try await facade.setupAirPlayMRPTunnel(service, credentialCandidates: credentialCandidates)
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

    internal static func resolvedAirPlayTunnelCredentialCandidates(
        for service: ServiceInfo,
        configuration: AppleTVConfiguration,
        settings: ATVSettings
    ) throws(ATVError) -> [HAPCredentials] {
        var serializedValues: [String] = []
        func append(_ value: String?) {
            guard let value, !serializedValues.contains(value) else { return }
            serializedValues.append(value)
        }

        append(settings.protocols.airplay.credentials)
        append(service.credentials)
        append(settings.protocols.companion.credentials)
        append(configuration.service(for: .companion)?.credentials)

        var candidates: [HAPCredentials] = []
        var firstParseError: ATVError?
        for serialized in serializedValues {
            guard !serialized.isEmpty else {
                firstParseError = firstParseError ?? .invalidCredentials("Empty AirPlay tunnel credentials")
                continue
            }
            do {
                candidates.append(try HAPCredentials.parse(serialized))
            } catch let err as ATVError {
                firstParseError = firstParseError ?? err
            } catch {
                firstParseError = firstParseError ?? ATVError.wrap(error)
            }
        }

        if !candidates.isEmpty {
            return candidates
        }
        if let firstParseError {
            throw firstParseError
        }
        throw ATVError.noCredentials("AirPlay MRP tunnel requires AirPlay or Companion HAP credentials")
    }

    internal static func validateClientIdentity(
        settings: ATVSettings,
        for configuration: AppleTVConfiguration
    ) throws(ATVError) {
        var targetIdentifiers = configuration.allIdentifiers
        if let macAddress = configuration.deviceInfo.macAddress {
            targetIdentifiers.insert(macAddress)
        }
        guard !targetIdentifiers.isEmpty else { return }

        let identity = settings.clientIdentity
        let clientValues: [(field: String, value: String)] = [
            ("clientIdentity.deviceID", identity.deviceID),
            ("clientIdentity.macAddress", identity.macAddress),
            ("clientIdentity.pairingIdentifier", identity.pairingIdentifier),
        ]

        for clientValue in clientValues {
            for targetIdentifier in targetIdentifiers
            where identifiersCollide(clientValue.value, targetIdentifier) {
                throw ATVError.settingsError(
                    "\(clientValue.field) must identify the local controller, but matches target device identifier \(targetIdentifier)"
                )
            }
        }
    }

    internal static func validatePairingService(_ service: ServiceInfo) throws(ATVError) {
        switch service.pairingRequirement {
        case .mandatory, .optional:
            return
        case .notNeeded where service.protocol == .airPlay:
            return
        case .disabled:
            throw ATVError.pairingFailed("Pairing is disabled for \(service.protocol)")
        case .unsupported:
            throw ATVError.notSupported("Pairing is not supported for \(service.protocol)")
        case .notNeeded:
            throw ATVError.notSupported("Pairing is not needed for \(service.protocol)")
        }
    }

    private static func identifiersCollide(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if let lhsMac = normalizedMAC(lhs), let rhsMac = normalizedMAC(rhs) {
            return lhsMac == rhsMac
        }
        return false
    }

    private static func normalizedMAC(_ value: String) -> String? {
        var hex = ""
        for scalar in value.unicodeScalars {
            if CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar) {
                hex.unicodeScalars.append(UnicodeScalar(scalar.value)!)
            } else if scalar == ":" || scalar == "-" {
                continue
            } else {
                return nil
            }
        }
        return hex.count == 12 ? hex.lowercased() : nil
    }
}

extension ATVProtocol {
    fileprivate var connectPriority: Int {
        ATVClient.connectProtocolPriority.firstIndex(of: self) ?? Int.max
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
