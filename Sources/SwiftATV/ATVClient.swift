import Foundation

/// Default timeout for protocol request/response exchanges during setup.
public let defaultProtocolRequestTimeout: TimeInterval = 5.0

/// Connection setup strategy.
public enum ConnectStrategy: Sendable, Hashable {
    /// Return after the first usable protocol connects.
    case firstUsable
    /// Attempt every allowed protocol and return when at least one connects.
    case allAllowed
}

/// Options controlling protocol selection during connection.
public struct ConnectOptions: Sendable, Hashable {
    public static let defaultProtocolOrder: [ATVProtocol] = [.mrp, .airPlay, .companion]

    /// Protocols to attempt, in preference order.
    public var protocols: [ATVProtocol]
    /// Whether to return after one connection or attach every usable protocol.
    public var strategy: ConnectStrategy
    /// Timeout used by AirPlay HTTP/RTSP setup requests.
    public var requestTimeout: TimeInterval

    public init(
        protocols: [ATVProtocol] = ConnectOptions.defaultProtocolOrder,
        strategy: ConnectStrategy = .firstUsable,
        requestTimeout: TimeInterval = defaultProtocolRequestTimeout
    ) {
        self.protocols = protocols
        self.strategy = strategy
        self.requestTimeout = requestTimeout
    }
}

/// One protocol setup attempt made during connection.
public struct ConnectAttempt: Sendable {
    public let `protocol`: ATVProtocol
    public let port: Int
    public let error: ATVError?

    public init(protocol: ATVProtocol, port: Int, error: ATVError? = nil) {
        self.protocol = `protocol`
        self.port = port
        self.error = error
    }

    public var succeeded: Bool { error == nil }
}

/// Optional setup diagnostic associated with a connected protocol.
public struct ProtocolSetupDiagnostic: Sendable, Hashable {
    public let `protocol`: ATVProtocol
    public let capability: Capability
    public let info: CapabilityInfo

    public init(protocol: ATVProtocol, capability: Capability, info: CapabilityInfo) {
        self.protocol = `protocol`
        self.capability = capability
        self.info = info
    }
}

/// Result metadata returned by ``ATVClient/connect(_:options:settings:)``.
public struct ConnectResult: Sendable {
    public let device: any AppleTVDevice
    public let primaryProtocol: ATVProtocol
    public let activeProtocols: [ATVProtocol]
    public let attempts: [ConnectAttempt]
    public let setupDiagnostics: [ProtocolSetupDiagnostic]

    public init(
        device: any AppleTVDevice,
        primaryProtocol: ATVProtocol,
        activeProtocols: [ATVProtocol],
        attempts: [ConnectAttempt],
        setupDiagnostics: [ProtocolSetupDiagnostic] = []
    ) {
        self.device = device
        self.primaryProtocol = primaryProtocol
        self.activeProtocols = activeProtocols
        self.attempts = attempts
        self.setupDiagnostics = setupDiagnostics
    }
}

/// High-level client entry points for discovering, pairing, and connecting to Apple TV devices.
///
/// Port of the Python pyatv library to idiomatic Swift.
/// Supports device discovery, pairing, and remote control via
/// MRP, AirPlay, and Companion protocols.
public enum ATVClient {

    /// Library version.
    public static let version = "0.3.0"

    fileprivate static let connectProtocolPriority = ConnectOptions.defaultProtocolOrder

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
        /// on the local network. Sleep-proxy discovery is included even when a
        /// protocol filter is supplied so sleeping devices can be marked.
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
        /// configurations. Sleep-proxy discovery is included even when a
        /// protocol filter is supplied so sleeping devices can be marked.
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

    /// Connect to an Apple TV device and return protocol setup metadata.
    ///
    /// Services are attempted in ``ConnectOptions/protocols`` order. With
    /// ``ConnectStrategy/firstUsable`` the method returns after the first
    /// successful protocol. With ``ConnectStrategy/allAllowed`` it continues
    /// attaching lower-priority protocols and returns if at least one protocol
    /// connects. When only Companion is discovered but reusable HAP credentials
    /// exist, the AirPlay MRP tunnel may be attempted on the default AirPlay
    /// port. If all attempts fail, the thrown `.connectionFailed` contains
    /// the failed protocols and their underlying errors. A strict
    /// single-protocol request throws that protocol's underlying setup error
    /// directly.
    ///
    /// - Parameters:
    ///   - config: Device configuration obtained from scanning or manually created.
    ///   - options: Protocol order, setup strategy, and request timeout.
    ///   - settings: Optional settings containing saved protocol credentials.
    /// - Returns: Connected device plus protocol setup metadata.
    public static func connect(
        _ config: AppleTVConfiguration,
        options: ConnectOptions = ConnectOptions(),
        settings: ATVSettings? = nil
    ) async throws(ATVError) -> ConnectResult {
        let deviceSettings = settings ?? ATVSettings()
        _ = try timeoutNanoseconds(from: options.requestTimeout, parameterName: "options.requestTimeout")
        let requestedProtocols = deduplicated(options.protocols)
        guard !requestedProtocols.isEmpty else {
            throw ATVError.invalidConfig("options.protocols must contain at least one protocol")
        }

        let availableServices = enabledServicesForConnect(
            from: config,
            requestedProtocols: requestedProtocols,
            settings: deviceSettings
        )

        guard !availableServices.isEmpty else {
            throw ATVError.noService("No enabled services in configuration")
        }

        let selectedServices = requestedProtocols.flatMap { requestedProtocol in
            availableServices.filter { service in service.protocol == requestedProtocol }
        }

        guard !selectedServices.isEmpty else {
            let requested = requestedProtocols.map(\.description).joined(separator: ", ")
            throw ATVError.noService("No enabled requested services in configuration: \(requested)")
        }

        try validateClientIdentity(settings: deviceSettings, for: config)

        let prioritizedServices = selectedServices.prioritizedForConnect(order: requestedProtocols)
        let facade = FacadeAppleTV(
            configuration: config,
            settings: deviceSettings
        )

        var failedAttempts: [ConnectionAttemptError] = []
        var attempts: [ConnectAttempt] = []
        var connectedAnyProtocol = false

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
                        credentialCandidates: airPlayCredentialCandidates,
                        requestTimeout: options.requestTimeout
                    )
                } else {
                    try await setupProtocol(
                        facade,
                        service: service,
                        credentials: credentials,
                        requestTimeout: options.requestTimeout
                    )
                }
                attempts.append(ConnectAttempt(protocol: service.protocol, port: service.port))
                connectedAnyProtocol = true
                if options.strategy == .firstUsable {
                    return try connectResult(facade: facade, attempts: attempts)
                }
            } catch let error as ATVError {
                failedAttempts.append(
                    ConnectionAttemptError(protocol: service.protocol, port: service.port, error: error)
                )
                attempts.append(ConnectAttempt(protocol: service.protocol, port: service.port, error: error))
            } catch {
                let wrapped = ATVError.wrap(error)
                failedAttempts.append(
                    ConnectionAttemptError(protocol: service.protocol, port: service.port, error: wrapped)
                )
                attempts.append(ConnectAttempt(protocol: service.protocol, port: service.port, error: wrapped))
            }
        }

        if connectedAnyProtocol {
            return try connectResult(facade: facade, attempts: attempts)
        }

        await facade.close()
        if requestedProtocols.count == 1, failedAttempts.count == 1 {
            throw failedAttempts[0].error
        }
        throw ATVError.connectionFailed(message: "No usable protocol connected", attempts: failedAttempts)
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
        credentials: HAPCredentials?,
        requestTimeout: TimeInterval
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
        try await facade.setupProtocol(
            service,
            credentials: credentials,
            requestTimeout: requestTimeout
        )
    }

    private static func setupAirPlayProtocol(
        _ facade: FacadeAppleTV,
        service: ServiceInfo,
        credentialCandidates: [HAPCredentials],
        requestTimeout: TimeInterval
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
        try await facade.setupAirPlayMRPTunnel(
            service,
            credentialCandidates: credentialCandidates,
            requestTimeout: requestTimeout
        )
    }

    private static func connectResult(
        facade: FacadeAppleTV,
        attempts: [ConnectAttempt]
    ) throws(ATVError) -> ConnectResult {
        guard let primaryProtocol = facade.connectedPrimaryProtocol else {
            throw ATVError.connectionFailed(message: "Protocol setup completed without active protocols")
        }
        return ConnectResult(
            device: facade,
            primaryProtocol: primaryProtocol,
            activeProtocols: facade.connectedActiveProtocols,
            attempts: attempts,
            setupDiagnostics: facade.protocolSetupDiagnostics
        )
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

    internal static func enabledServicesForConnect(
        from configuration: AppleTVConfiguration,
        requestedProtocols: [ATVProtocol],
        settings: ATVSettings
    ) -> [ServiceInfo] {
        var services = configuration.services.filter(\.enabled)
        if let derivedAirPlay = companionDerivedAirPlayServiceIfAvailable(
            from: configuration,
            requestedProtocols: requestedProtocols,
            settings: settings
        ) {
            services.append(derivedAirPlay)
        }
        return services
    }

    internal static func companionDerivedAirPlayServiceIfAvailable(
        from configuration: AppleTVConfiguration,
        requestedProtocols: [ATVProtocol],
        settings: ATVSettings
    ) -> ServiceInfo? {
        let enabledServices = configuration.services.filter(\.enabled)
        guard
            requestedProtocols.contains(.airPlay),
            settings.protocols.airplay.mrpTunnelMode != .disable,
            !configuration.services.contains(where: { $0.protocol == .airPlay }),
            let companion = enabledServices.first(where: { $0.protocol == .companion }),
            hasAirPlayTunnelCredentialCandidate(settings: settings, companionService: companion)
        else {
            return nil
        }

        let derivedAirPlay = companionDerivedAirPlayService(
            from: companion,
            configuration: configuration
        )
        guard
            settings.protocols.airplay.mrpTunnelMode == .force
                || AirPlaySupport.isAppleTVService(derivedAirPlay)
        else {
            return nil
        }

        return derivedAirPlay
    }

    private static func companionDerivedAirPlayService(
        from companion: ServiceInfo,
        configuration: AppleTVConfiguration
    ) -> ServiceInfo {
        var properties = companion.properties
        properties[AirPlaySupport.companionDerivedServiceProperty] = "true"

        if AirPlaySupport.property(properties, keys: ["model", "am", "rpMd"]) == nil,
            let model = configuration.deviceInfo.modelString
        {
            properties["model"] = model
        }
        if AirPlaySupport.property(properties, keys: ["osvers", "rpVr"]) == nil,
            let version = configuration.deviceInfo.version
        {
            properties["osvers"] = version
        }

        return ServiceInfo(
            protocol: .airPlay,
            port: ServiceInfo.defaultAirPlayPort,
            identifier: companion.identifier ?? configuration.mainIdentifier,
            credentials: companion.credentials,
            enabled: true,
            properties: properties,
            pairingRequirement: .notNeeded
        )
    }

    private static func hasAirPlayTunnelCredentialCandidate(
        settings: ATVSettings,
        companionService: ServiceInfo
    ) -> Bool {
        [
            settings.protocols.airplay.credentials,
            settings.protocols.companion.credentials,
            companionService.credentials,
        ].contains { candidate in
            guard let candidate else { return false }
            return !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
            ("clientIdentity.rapportIdentifier", identity.rapportIdentifier),
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

    private static func deduplicated(_ protocols: [ATVProtocol]) -> [ATVProtocol] {
        var seen = Set<ATVProtocol>()
        var result: [ATVProtocol] = []
        for `protocol` in protocols where seen.insert(`protocol`).inserted {
            result.append(`protocol`)
        }
        return result
    }
}

extension ATVProtocol {
    fileprivate var connectPriority: Int {
        ATVClient.connectProtocolPriority.firstIndex(of: self) ?? Int.max
    }
}

extension Array where Element == ServiceInfo {
    fileprivate func prioritizedForConnect(order: [ATVProtocol]) -> [ServiceInfo] {
        enumerated()
            .sorted { lhs, rhs in
                let lhsPriority =
                    order.firstIndex(of: lhs.element.protocol)
                    ?? lhs.element.protocol.connectPriority
                let rhsPriority =
                    order.firstIndex(of: rhs.element.protocol)
                    ?? rhs.element.protocol.connectPriority
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
