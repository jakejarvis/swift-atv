#if canImport(Network)
    import Darwin
    import Foundation
    import Network

    /// Bonjour service types used to discover Apple TV devices.
    public enum BonjourServiceType: String, CaseIterable, Sendable {
        case mrp = "_mediaremotetv._tcp"
        case companion = "_companion-link._tcp"
        case airPlay = "_airplay._tcp"
        case deviceInfo = "_device-info._tcp"
        case sleepProxy = "_sleep-proxy._udp"

        /// The ATV protocol this service type maps to, if any.
        public var atvProtocol: ATVProtocol? {
            switch self {
            case .mrp: return .mrp
            case .companion: return .companion
            case .airPlay: return .airPlay
            case .deviceInfo, .sleepProxy: return nil
            }
        }

        /// Default port for this service type.
        public var defaultPort: Int? {
            switch self {
            case .mrp: return ServiceInfo.defaultMRPPort
            case .companion: return ServiceInfo.defaultCompanionPort
            case .airPlay: return ServiceInfo.defaultAirPlayPort
            case .deviceInfo, .sleepProxy: return nil
            }
        }
    }

    /// Discovered service result from a Bonjour browser.
    internal struct DiscoveredService: Sendable {
        let serviceType: BonjourServiceType
        let name: String
        let host: String
        let port: Int
        let txtRecord: [String: String]
    }

    /// Diagnostic category for Bonjour scan issues.
    public enum ATVScanDiagnosticKind: Sendable, Hashable {
        /// A browser moved into a waiting state and may recover.
        case browserWaiting
        /// A browser failed for a Bonjour service type.
        case browserFailed
        /// A discovered endpoint could not be resolved.
        case resolverFailed
        /// A service resolved successfully but did not include a TXT record.
        case emptyTXTRecord
        /// A sleep-proxy service resolved without a usable device identifier.
        case missingIdentifier
    }

    /// Non-fatal diagnostic emitted while scanning for Bonjour services.
    public struct ATVScanDiagnostic: Sendable, Hashable, CustomStringConvertible {
        /// Bonjour service type that produced the diagnostic.
        public let serviceType: BonjourServiceType
        /// Kind of scan issue observed.
        public let kind: ATVScanDiagnosticKind
        /// Human-readable diagnostic details.
        public let message: String

        public init(
            serviceType: BonjourServiceType,
            kind: ATVScanDiagnosticKind,
            message: String
        ) {
            self.serviceType = serviceType
            self.kind = kind
            self.message = message
        }

        public var description: String {
            "\(serviceType.rawValue): \(kind) - \(message)"
        }
    }

    /// Result from a diagnostic Bonjour scan.
    public struct ATVScanResult: Sendable, Hashable {
        /// Discovered device configurations.
        public let devices: [AppleTVConfiguration]
        /// Non-fatal scan diagnostics, if any.
        public let diagnostics: [ATVScanDiagnostic]

        public init(
            devices: [AppleTVConfiguration],
            diagnostics: [ATVScanDiagnostic] = []
        ) {
            self.devices = devices
            self.diagnostics = diagnostics
        }
    }

    /// Scans the local network for Apple TV devices using Bonjour/mDNS.
    public actor ATVScanner {

        /// Service types to scan for protocol discovery.
        private static let protocolServiceTypes: [BonjourServiceType] = [
            .mrp, .companion, .airPlay,
        ]

        /// Scan the local network for Apple TV devices.
        ///
        /// Device-info and sleep-proxy services are scanned alongside the
        /// requested protocol services.
        /// - Parameters:
        ///   - timeout: How long to scan in seconds. Default is 5.
        ///   - identifiers: Optional set of device identifiers to filter by.
        ///   - protocols: Optional set of protocols to filter by.
        /// - Returns: Array of discovered device configurations.
        public static func scan(
            timeout: TimeInterval = 5.0,
            identifiers: Set<String>? = nil,
            protocols: Set<ATVProtocol>? = nil
        ) async throws(ATVError) -> [AppleTVConfiguration] {
            try await scanWithDiagnostics(
                timeout: timeout,
                identifiers: identifiers,
                protocols: protocols
            ).devices
        }

        /// Scan the local network for Apple TV devices and return non-fatal diagnostics.
        ///
        /// Device-info and sleep-proxy services are scanned alongside the
        /// requested protocol services.
        /// - Parameters:
        ///   - timeout: How long to scan in seconds. Default is 5.
        ///   - identifiers: Optional set of device identifiers to filter by.
        ///   - protocols: Optional set of protocols to filter by.
        /// - Returns: Discovered device configurations plus browse diagnostics.
        public static func scanWithDiagnostics(
            timeout: TimeInterval = 5.0,
            identifiers: Set<String>? = nil,
            protocols: Set<ATVProtocol>? = nil
        ) async throws(ATVError) -> ATVScanResult {
            let scanner = ATVScanner()
            return try await scanner.performScan(
                timeout: timeout,
                identifiers: identifiers,
                protocols: protocols
            )
        }

        private init() {}

        private func performScan(
            timeout: TimeInterval,
            identifiers: Set<String>?,
            protocols: Set<ATVProtocol>?
        ) async throws(ATVError) -> ATVScanResult {
            _ = try timeoutNanoseconds(from: timeout, parameterName: "timeout")

            let allTypes = Self.serviceTypes(for: protocols)

            // Browse for each service type concurrently
            let browseOutput: BrowseOutput
            do {
                browseOutput = try await withThrowingTaskGroup(
                    of: BrowseOutput.self
                ) { group in
                    for serviceType in allTypes {
                        group.addTask {
                            try await Self.browse(serviceType: serviceType, timeout: timeout)
                        }
                    }

                    var allServices: [DiscoveredService] = []
                    var allDiagnostics: [ATVScanDiagnostic] = []
                    for try await result in group {
                        allServices.append(contentsOf: result.services)
                        allDiagnostics.append(contentsOf: result.diagnostics)
                    }
                    return BrowseOutput(services: allServices, diagnostics: allDiagnostics)
                }
            } catch let err as ATVError {
                throw err
            } catch {
                throw ATVError.wrap(error)
            }

            return Self.scanResult(
                from: browseOutput.services,
                diagnostics: browseOutput.diagnostics,
                identifiers: identifiers
            )
        }

        internal static func serviceTypes(for protocols: Set<ATVProtocol>?) -> [BonjourServiceType] {
            let serviceTypes: [BonjourServiceType]
            if let protocols {
                serviceTypes = Self.protocolServiceTypes.filter { svc in
                    guard let proto = svc.atvProtocol else { return false }
                    return protocols.contains(proto)
                }
            } else {
                serviceTypes = Self.protocolServiceTypes
            }

            return serviceTypes + [.deviceInfo, .sleepProxy]
        }

        internal static func configurations(from services: [DiscoveredService]) -> [AppleTVConfiguration] {
            var configs: [AppleTVConfiguration] = []

            for service in services {
                merge(service, into: &configs)
            }

            return configs
        }

        internal static func scanResult(
            from services: [DiscoveredService],
            diagnostics: [ATVScanDiagnostic],
            identifiers: Set<String>? = nil
        ) -> ATVScanResult {
            var diagnostics = diagnostics
            for service in services
            where service.serviceType == .sleepProxy && serviceIdentifiers(from: service).isEmpty {
                diagnostics.append(
                    ATVScanDiagnostic(
                        serviceType: .sleepProxy,
                        kind: .missingIdentifier,
                        message: "Resolved sleep proxy \(service.name) without a usable identifier"
                    )
                )
            }
            var results = Self.configurations(from: services)

            if let identifiers {
                results = results.filter { config in
                    !config.allIdentifiers.isDisjoint(with: identifiers)
                }
            }

            return ATVScanResult(devices: results, diagnostics: diagnostics)
        }

        internal static func pairingRequirement(
            from properties: [String: String],
            for `protocol`: ATVProtocol
        ) -> PairingRequirement {
            switch `protocol` {
            case .companion:
                guard let flags = intProperty(properties, keys: ["rpfl", "rpFl"]) else {
                    return .unsupported
                }
                if flags & 0x04 != 0 {
                    return .disabled
                }
                if flags & 0x4000 != 0 {
                    return .mandatory
                }
                return .unsupported

            case .mrp:
                let allowPairing = property(properties, keys: ["allowpairing", "AllowPairing"])
                return allowPairing?.lowercased() == "yes" ? .optional : .disabled

            case .airPlay:
                return AirPlaySupport.pairingRequirement(from: properties)
            }
        }

        private static func merge(
            _ service: DiscoveredService,
            into configs: inout [AppleTVConfiguration]
        ) {
            let identifiers = serviceIdentifiers(from: service)
            let preferredIdentifier = preferredIdentifier(from: service)
            let matchingIndices = configs.indices.filter { index in
                let config = configs[index]
                let hasSharedIdentifier =
                    !identifiers.isEmpty && !config.allIdentifiers.isDisjoint(with: identifiers)
                return hasSharedIdentifier || config.address == service.host
            }

            let targetIndex: Int
            if let first = matchingIndices.first {
                targetIndex = first
                if matchingIndices.count > 1 {
                    for duplicateIndex in matchingIndices.dropFirst().reversed() {
                        let duplicate = configs.remove(at: duplicateIndex)
                        merge(duplicate, into: &configs[targetIndex])
                    }
                }
            } else {
                configs.append(
                    AppleTVConfiguration(
                        address: service.host,
                        name: displayName(from: service),
                        identifier: preferredIdentifier
                    )
                )
                targetIndex = configs.index(before: configs.endIndex)
            }

            apply(service, to: &configs[targetIndex], identifiers: identifiers)
        }

        private static func merge(
            _ source: AppleTVConfiguration,
            into target: inout AppleTVConfiguration
        ) {
            if target.identifier == nil {
                target.identifier = source.identifier
            }
            target.deepSleep = target.deepSleep || source.deepSleep
            mergeDeviceInfo(source.deviceInfo, into: &target.deviceInfo)
            for service in source.services {
                target.addService(service)
            }
        }

        private static func apply(
            _ service: DiscoveredService,
            to config: inout AppleTVConfiguration,
            identifiers: Set<String>
        ) {
            if config.identifier == nil {
                config.identifier = preferredIdentifier(from: service)
            }

            if service.serviceType == .deviceInfo {
                mergeDeviceInfo(DeviceInfo.fromProperties(service.txtRecord), into: &config.deviceInfo)
                return
            }

            if service.serviceType == .sleepProxy {
                config.deepSleep = true
                return
            }

            guard let proto = service.serviceType.atvProtocol else { return }

            let serviceInfo = ServiceInfo(
                protocol: proto,
                port: service.port,
                identifier: preferredIdentifier(from: service),
                properties: service.txtRecord,
                pairingRequirement: Self.pairingRequirement(from: service.txtRecord, for: proto)
            )

            config.addService(serviceInfo)

            mergeDeviceInfo(DeviceInfo.fromProperties(service.txtRecord), into: &config.deviceInfo)
        }

        private static func mergeDeviceInfo(_ source: DeviceInfo, into target: inout DeviceInfo) {
            if source.operatingSystem != .unknown {
                target.operatingSystem = source.operatingSystem
            }
            if let version = source.version {
                target.version = version
            }
            if let buildNumber = source.buildNumber {
                target.buildNumber = buildNumber
            }
            if source.model != .unknown {
                target.model = source.model
            }
            if let modelString = source.modelString {
                target.modelString = modelString
            }
            if let macAddress = source.macAddress {
                target.macAddress = macAddress
            }
        }

        private static func serviceIdentifiers(from service: DiscoveredService) -> Set<String> {
            var identifiers = DiscoveryIdentifiers.all(from: service.txtRecord)
            if service.serviceType == .sleepProxy, let identifier = sleepProxyIdentifier(from: service.name) {
                identifiers.insert(identifier)
            }
            return identifiers
        }

        private static func preferredIdentifier(from service: DiscoveredService) -> String? {
            DiscoveryIdentifiers.preferred(from: service.txtRecord)
                ?? (service.serviceType == .sleepProxy ? sleepProxyIdentifier(from: service.name) : nil)
        }

        private static func displayName(from service: DiscoveredService) -> String {
            guard service.serviceType == .sleepProxy else {
                return service.name
            }
            let parts = service.name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                return service.name
            }
            return String(parts[1])
        }

        private static func sleepProxyIdentifier(from name: String) -> String? {
            let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let raw = parts.first else {
                return nil
            }
            let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return identifier.isEmpty ? nil : identifier
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

        private static func intProperty(_ properties: [String: String], keys: [String]) -> Int? {
            guard let rawValue = property(properties, keys: keys) else {
                return nil
            }
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("0x") {
                return Int(trimmed.dropFirst(2), radix: 16)
            }
            return Int(trimmed) ?? Int(trimmed, radix: 16)
        }

        private struct BrowseOutput: Sendable {
            var services: [DiscoveredService]
            var diagnostics: [ATVScanDiagnostic]
        }

        internal struct BonjourServiceEndpoint: Sendable {
            let name: String
            let type: String
            let domain: String
        }

        internal struct ResolvedBonjourService: Sendable {
            let host: String
            let port: Int
            let txtRecord: [String: String]
        }

        internal struct BonjourResolutionOutput: Sendable {
            let service: DiscoveredService?
            let diagnostics: [ATVScanDiagnostic]
        }

        internal protocol BonjourServiceResolving: AnyObject, Sendable {
            func resolve(
                completion: @escaping @Sendable (Result<ResolvedBonjourService, Error>) -> Void
            )
            func cancel()
        }

        /// Mutable state shared across @Sendable NWBrowser callbacks.
        private final class BrowseState: @unchecked Sendable {
            private typealias Snapshot = (
                browser: NWBrowser?,
                resolvers: [NWConnection],
                serviceResolvers: [any BonjourServiceResolving],
                continuation: CheckedContinuation<BrowseOutput, Error>,
                timeoutTask: Task<Void, Never>?
            )

            let lock = NSLock()
            var discovered: [DiscoveredService] = []
            var diagnostics: [ATVScanDiagnostic] = []
            var hasResumed = false
            var browser: NWBrowser?
            var resolvers: [ObjectIdentifier: NWConnection] = [:]
            var serviceResolvers: [ObjectIdentifier: any BonjourServiceResolving] = [:]
            var continuation: CheckedContinuation<BrowseOutput, Error>?
            var timeoutTask: Task<Void, Never>?

            func setContinuation(_ continuation: CheckedContinuation<BrowseOutput, Error>) {
                lock.withLock {
                    self.continuation = continuation
                }
            }

            func setBrowser(_ browser: NWBrowser) {
                lock.withLock {
                    self.browser = browser
                }
            }

            func setTimeoutTask(_ task: Task<Void, Never>) {
                lock.withLock {
                    if hasResumed {
                        task.cancel()
                    } else {
                        timeoutTask = task
                    }
                }
            }

            func addResolver(_ connection: NWConnection) {
                lock.withLock {
                    resolvers[ObjectIdentifier(connection)] = connection
                }
            }

            func removeResolver(_ connection: NWConnection) {
                _ = lock.withLock {
                    resolvers.removeValue(forKey: ObjectIdentifier(connection))
                }
            }

            func addResolver(_ resolver: any BonjourServiceResolving) {
                lock.withLock {
                    serviceResolvers[ObjectIdentifier(resolver)] = resolver
                }
            }

            func removeResolver(_ resolver: any BonjourServiceResolving) {
                _ = lock.withLock {
                    serviceResolvers.removeValue(forKey: ObjectIdentifier(resolver))
                }
            }

            func appendDiagnostic(_ diagnostic: ATVScanDiagnostic) {
                lock.withLock {
                    guard !hasResumed else { return }
                    diagnostics.append(diagnostic)
                }
            }

            func appendDiagnostic(
                serviceType: BonjourServiceType,
                kind: ATVScanDiagnosticKind,
                message: String
            ) {
                lock.withLock {
                    guard !hasResumed else { return }
                    diagnostics.append(
                        ATVScanDiagnostic(
                            serviceType: serviceType,
                            kind: kind,
                            message: message
                        )
                    )
                }
            }

            func append(_ service: DiscoveredService?) {
                lock.withLock {
                    guard let service, !hasResumed else { return }
                    discovered.append(service)
                }
            }

            func safeResume() {
                let output = lock.withLock {
                    BrowseOutput(services: discovered, diagnostics: diagnostics)
                }
                safeFinish(.success(output))
            }

            func safeFail(_ error: ATVError) {
                safeFinish(.failure(error))
            }

            private func safeFinish(_ result: Result<BrowseOutput, Error>) {
                let snapshot = lock.withLock {
                    guard !hasResumed, let continuation else {
                        return nil as Snapshot?
                    }
                    hasResumed = true
                    let snapshot: Snapshot = (
                        browser,
                        Array(resolvers.values),
                        Array(serviceResolvers.values),
                        continuation,
                        timeoutTask
                    )
                    browser = nil
                    resolvers.removeAll()
                    serviceResolvers.removeAll()
                    self.continuation = nil
                    timeoutTask = nil
                    return snapshot
                }

                guard let snapshot else {
                    return
                }

                snapshot.browser?.cancel()
                for resolver in snapshot.resolvers {
                    resolver.cancel()
                }
                for resolver in snapshot.serviceResolvers {
                    resolver.cancel()
                }
                snapshot.timeoutTask?.cancel()
                switch result {
                case .success(let output):
                    snapshot.continuation.resume(returning: output)
                case .failure(let error):
                    snapshot.continuation.resume(throwing: error)
                }
            }
        }

        /// Browse for a specific Bonjour service type and resolve endpoints.
        private static func browse(
            serviceType: BonjourServiceType,
            timeout: TimeInterval
        ) async throws -> BrowseOutput {
            let timeoutNs = try timeoutNanoseconds(from: timeout, parameterName: "timeout")
            let state = BrowseState()
            let cancellationContext = TimeoutContext(
                operation: "scan",
                requestID: serviceType.rawValue,
                duration: timeout
            )

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(
                            throwing: ATVError.operationCancelled(cancellationContext)
                        )
                        return
                    }
                    state.setContinuation(continuation)
                    if Task.isCancelled {
                        state.safeFail(ATVError.operationCancelled(cancellationContext))
                        return
                    }

                    let params = NWParameters()
                    params.includePeerToPeer = true

                    let browser = NWBrowser(
                        for: .bonjour(type: serviceType.rawValue, domain: "local."),
                        using: params
                    )
                    state.setBrowser(browser)

                    let timeoutTask = Task {
                        try? await Task.sleep(nanoseconds: timeoutNs)
                        state.safeResume()
                    }
                    state.setTimeoutTask(timeoutTask)

                    browser.stateUpdateHandler = { browserState in
                        switch browserState {
                        case .waiting(let error):
                            state.appendDiagnostic(
                                serviceType: serviceType,
                                kind: .browserWaiting,
                                message: String(describing: error)
                            )

                        case .failed(let error):
                            state.appendDiagnostic(
                                serviceType: serviceType,
                                kind: .browserFailed,
                                message: String(describing: error)
                            )
                            state.safeResume()

                        default:
                            break
                        }
                    }

                    browser.browseResultsChangedHandler = { results, _ in
                        state.lock.lock()
                        guard !state.hasResumed else {
                            state.lock.unlock()
                            return
                        }
                        let newResults = Array(results)
                        state.lock.unlock()

                        for result in newResults {
                            Self.resolveEndpoint(result, serviceType: serviceType, browseState: state) { service in
                                state.append(service)
                            }
                        }
                    }

                    browser.start(queue: .global())
                }
            } onCancel: {
                state.safeFail(ATVError.operationCancelled(cancellationContext))
            }
        }

        /// Resolve a Bonjour browser result to get host, port, and TXT record.
        private static func resolveEndpoint(
            _ result: NWBrowser.Result,
            serviceType: BonjourServiceType,
            browseState: BrowseState,
            completion: @escaping @Sendable (DiscoveredService?) -> Void
        ) {
            let endpoint = result.endpoint

            let metadataTXTRecord = txtRecord(from: result.metadata)
            if case .service(let name, let type, let domain, _) = endpoint {
                let serviceEndpoint = BonjourServiceEndpoint(
                    name: name,
                    type: type,
                    domain: domain
                )
                let resolver = NetServiceBonjourResolver(endpoint: serviceEndpoint, timeout: 3)
                browseState.addResolver(resolver)

                resolveBonjourEndpoint(
                    serviceEndpoint,
                    serviceType: serviceType,
                    metadataTXTRecord: metadataTXTRecord,
                    resolver: resolver
                ) { output in
                    browseState.removeResolver(resolver)
                    for diagnostic in output.diagnostics {
                        browseState.appendDiagnostic(diagnostic)
                    }
                    completion(output.service)
                }
                return
            }

            resolveNetworkEndpoint(
                endpoint,
                name: "Unknown",
                serviceType: serviceType,
                txtRecord: metadataTXTRecord,
                browseState: browseState,
                completion: completion
            )
        }

        internal static func resolveBonjourEndpoint(
            _ endpoint: BonjourServiceEndpoint,
            serviceType: BonjourServiceType,
            metadataTXTRecord: [String: String],
            resolver: any BonjourServiceResolving,
            completion: @escaping @Sendable (BonjourResolutionOutput) -> Void
        ) {
            resolver.resolve { result in
                switch result {
                case .success(let resolved):
                    var txtRecord = resolved.txtRecord
                    for (key, value) in metadataTXTRecord where txtRecord[key] == nil {
                        txtRecord[key] = value
                    }

                    let service = DiscoveredService(
                        serviceType: serviceType,
                        name: endpoint.name,
                        host: resolved.host,
                        port: resolved.port,
                        txtRecord: txtRecord
                    )
                    var diagnostics: [ATVScanDiagnostic] = []
                    if txtRecord.isEmpty {
                        diagnostics.append(
                            ATVScanDiagnostic(
                                serviceType: serviceType,
                                kind: .emptyTXTRecord,
                                message:
                                    "Resolved \(endpoint.name) \(endpoint.type) \(endpoint.domain) with empty TXT record"
                            )
                        )
                    }
                    completion(BonjourResolutionOutput(service: service, diagnostics: diagnostics))

                case .failure(let error):
                    completion(
                        BonjourResolutionOutput(
                            service: nil,
                            diagnostics: [
                                ATVScanDiagnostic(
                                    serviceType: serviceType,
                                    kind: .resolverFailed,
                                    message:
                                        "Failed to resolve \(endpoint.name) \(endpoint.type) \(endpoint.domain): \(error)"
                                )
                            ]
                        )
                    )
                }
            }
        }

        private static func resolveNetworkEndpoint(
            _ endpoint: NWEndpoint,
            name: String,
            serviceType: BonjourServiceType,
            txtRecord: [String: String],
            browseState: BrowseState,
            completion: @escaping @Sendable (DiscoveredService?) -> Void
        ) {
            // Create a connection to resolve the address
            let params = NWParameters.tcp
            let connection = NWConnection(to: endpoint, using: params)
            browseState.addResolver(connection)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    browseState.removeResolver(connection)
                    if let path = connection.currentPath,
                        let remoteEndpoint = path.remoteEndpoint,
                        case .hostPort(let host, let port) = remoteEndpoint
                    {
                        let hostStr: String
                        switch host {
                        case .ipv4(let addr):
                            hostStr = "\(addr)"
                        case .ipv6(let addr):
                            hostStr = "\(addr)"
                        case .name(let h, _):
                            hostStr = h
                        @unknown default:
                            hostStr = "\(host)"
                        }

                        let service = DiscoveredService(
                            serviceType: serviceType,
                            name: name,
                            host: hostStr,
                            port: Int(port.rawValue),
                            txtRecord: txtRecord
                        )
                        connection.cancel()
                        completion(service)
                    } else {
                        browseState.appendDiagnostic(
                            serviceType: serviceType,
                            kind: .resolverFailed,
                            message: "Resolved \(endpoint) without a host and port"
                        )
                        connection.cancel()
                        completion(nil)
                    }

                case .failed(let error):
                    browseState.appendDiagnostic(
                        serviceType: serviceType,
                        kind: .resolverFailed,
                        message: "Failed to resolve \(endpoint): \(error)"
                    )
                    browseState.removeResolver(connection)
                    completion(nil)

                case .cancelled:
                    browseState.removeResolver(connection)
                    completion(nil)

                default:
                    break
                }
            }

            connection.start(queue: .global())

            // Timeout for resolution
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                browseState.removeResolver(connection)
                connection.cancel()
            }
        }

        private static func txtRecord(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
            var record: [String: String] = [:]
            if case .bonjour(let txt) = metadata {
                for key in txt.dictionary.keys {
                    if let value = txt.dictionary[key] {
                        record[key] = value
                    }
                }
            }
            return record
        }

        private final class NetServiceBonjourResolver: NSObject, BonjourServiceResolving,
            @unchecked Sendable, NetServiceDelegate
        {
            private let endpoint: BonjourServiceEndpoint
            private let timeout: TimeInterval
            private let lock = NSLock()
            private var service: NetService?
            private var completion: (@Sendable (Result<ResolvedBonjourService, Error>) -> Void)?
            private var didFinish = false

            init(endpoint: BonjourServiceEndpoint, timeout: TimeInterval) {
                self.endpoint = endpoint
                self.timeout = timeout
            }

            func resolve(
                completion: @escaping @Sendable (Result<ResolvedBonjourService, Error>) -> Void
            ) {
                lock.withLock {
                    self.completion = completion
                }

                DispatchQueue.main.async {
                    let service = NetService(
                        domain: Self.normalizedDomain(self.endpoint.domain),
                        type: Self.normalizedType(self.endpoint.type),
                        name: self.endpoint.name
                    )
                    service.delegate = self
                    service.schedule(in: .main, forMode: .default)
                    self.lock.withLock {
                        guard !self.didFinish else { return }
                        self.service = service
                    }
                    service.resolve(withTimeout: self.timeout)
                }
            }

            func cancel() {
                let service = lock.withLock {
                    didFinish = true
                    completion = nil
                    let service = self.service
                    self.service = nil
                    return service
                }

                DispatchQueue.main.async {
                    service?.stop()
                    service?.remove(from: .main, forMode: .default)
                    service?.delegate = nil
                }
            }

            func netServiceDidResolveAddress(_ sender: NetService) {
                let host = Self.host(from: sender.addresses) ?? sender.hostName ?? endpoint.name
                let resolved = ResolvedBonjourService(
                    host: Self.trimTrailingDot(host),
                    port: sender.port,
                    txtRecord: Self.txtRecord(from: sender)
                )
                finish(.success(resolved), service: sender)
            }

            func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
                finish(
                    .failure(NetServiceResolutionError(errorDict: errorDict)),
                    service: sender
                )
            }

            private func finish(
                _ result: Result<ResolvedBonjourService, Error>,
                service: NetService
            ) {
                let completion = lock.withLock {
                    guard !didFinish else {
                        return nil as (@Sendable (Result<ResolvedBonjourService, Error>) -> Void)?
                    }
                    didFinish = true
                    let completion = self.completion
                    self.completion = nil
                    self.service = nil
                    return completion
                }

                service.stop()
                service.remove(from: .main, forMode: .default)
                service.delegate = nil
                completion?(result)
            }

            private static func normalizedDomain(_ domain: String) -> String {
                domain.hasSuffix(".") ? domain : "\(domain)."
            }

            private static func normalizedType(_ type: String) -> String {
                type.hasSuffix(".") ? type : "\(type)."
            }

            private static func txtRecord(from service: NetService) -> [String: String] {
                guard let data = service.txtRecordData() else {
                    return [:]
                }

                var record: [String: String] = [:]
                for (key, value) in NetService.dictionary(fromTXTRecord: data) {
                    record[key] = String(data: value, encoding: .utf8) ?? ""
                }
                return record
            }

            private static func host(from addresses: [Data]?) -> String? {
                guard let addresses else { return nil }
                for address in addresses {
                    if let host = host(from: address) {
                        return host
                    }
                }
                return nil
            }

            private static func host(from address: Data) -> String? {
                address.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        return nil
                    }
                    let sockaddrPointer = baseAddress.assumingMemoryBound(to: sockaddr.self)
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        sockaddrPointer,
                        socklen_t(address.count),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    guard result == 0 else {
                        return nil
                    }
                    let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    return String(decoding: bytes, as: UTF8.self)
                }
            }

            private static func trimTrailingDot(_ host: String) -> String {
                host.hasSuffix(".") ? String(host.dropLast()) : host
            }
        }

        private struct NetServiceResolutionError: Error, CustomStringConvertible {
            let errorDict: [String: NSNumber]

            var description: String {
                errorDict.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            }
        }
    }
#endif
