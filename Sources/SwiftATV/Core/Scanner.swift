#if canImport(Network)
    import Foundation
    import Network

    /// Bonjour service types used to discover Apple TV devices.
    public enum BonjourServiceType: String, CaseIterable, Sendable {
        case mrp = "_mediaremotetv._tcp"
        case companion = "_companion-link._tcp"
        case airPlay = "_airplay._tcp"
        case raop = "_raop._tcp"
        case dmap = "_touch-able._tcp"
        case deviceInfo = "_device-info._tcp"
        case sleepProxy = "_sleep-proxy._udp"

        /// The ATV protocol this service type maps to, if any.
        public var atvProtocol: ATVProtocol? {
            switch self {
            case .mrp: return .mrp
            case .companion: return .companion
            case .airPlay: return .airPlay
            case .raop: return .raop
            case .dmap: return .dmap
            case .deviceInfo, .sleepProxy: return nil
            }
        }

        /// Default port for this service type.
        public var defaultPort: Int? {
            switch self {
            case .mrp: return ServiceInfo.defaultMRPPort
            case .companion: return ServiceInfo.defaultCompanionPort
            case .airPlay: return ServiceInfo.defaultAirPlayPort
            case .raop: return ServiceInfo.defaultRAOPPort
            case .dmap: return ServiceInfo.defaultDMAPPort
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

    /// Scans the local network for Apple TV devices using Bonjour/mDNS.
    public actor ATVScanner {

        /// Service types to scan for protocol discovery.
        private static let protocolServiceTypes: [BonjourServiceType] = [
            .mrp, .companion, .airPlay, .raop, .dmap,
        ]

        /// Scan the local network for Apple TV devices.
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
        ) async throws(ATVError) -> [AppleTVConfiguration] {
            _ = try timeoutNanoseconds(from: timeout, parameterName: "timeout")

            // Determine which service types to scan based on protocol filter
            let serviceTypes: [BonjourServiceType]
            if let protocols {
                serviceTypes = Self.protocolServiceTypes.filter { svc in
                    guard let proto = svc.atvProtocol else { return false }
                    return protocols.contains(proto)
                }
            } else {
                serviceTypes = Self.protocolServiceTypes
            }

            // Also always scan for device info
            let allTypes = serviceTypes + [.deviceInfo]

            // Browse for each service type concurrently
            let services: [DiscoveredService]
            do {
                services = try await withThrowingTaskGroup(
                    of: [DiscoveredService].self
                ) { group in
                    for serviceType in allTypes {
                        group.addTask {
                            try await Self.browse(serviceType: serviceType, timeout: timeout)
                        }
                    }

                    var allServices: [DiscoveredService] = []
                    for try await result in group {
                        allServices.append(contentsOf: result)
                    }
                    return allServices
                }
            } catch let err as ATVError {
                throw err
            } catch {
                throw ATVError.wrap(error)
            }

            var results = Self.configurations(from: services)

            // Filter by identifiers if specified
            if let identifiers {
                results = results.filter { config in
                    !config.allIdentifiers.isDisjoint(with: identifiers)
                }
            }

            return results
        }

        internal static func configurations(from services: [DiscoveredService]) -> [AppleTVConfiguration] {
            var configs: [AppleTVConfiguration] = []

            for service in services {
                merge(service, into: &configs)
            }

            return configs
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

            case .airPlay, .raop:
                let passwordRequired = property(properties, keys: ["pw"])?.lowercased() == "true"
                return passwordRequired ? .mandatory : .notNeeded

            case .dmap:
                return .unsupported
            }
        }

        private static func merge(
            _ service: DiscoveredService,
            into configs: inout [AppleTVConfiguration]
        ) {
            let identifiers = serviceIdentifiers(from: service.txtRecord)
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
                        name: service.name,
                        identifier: identifiers.sorted().first
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
            if target.deviceInfo.model == .unknown, source.deviceInfo.model != .unknown {
                target.deviceInfo = source.deviceInfo
            }
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
                config.identifier = identifiers.sorted().first
            }

            if service.serviceType == .deviceInfo {
                config.deviceInfo = DeviceInfo.fromProperties(service.txtRecord)
                return
            }

            guard let proto = service.serviceType.atvProtocol else { return }

            let serviceInfo = ServiceInfo(
                protocol: proto,
                port: service.port,
                identifier: preferredIdentifier(from: service.txtRecord),
                properties: service.txtRecord,
                pairingRequirement: Self.pairingRequirement(from: service.txtRecord, for: proto)
            )

            config.addService(serviceInfo)

            if config.deviceInfo.model == .unknown {
                let info = DeviceInfo.fromProperties(service.txtRecord)
                if info.model != .unknown {
                    config.deviceInfo = info
                }
            }
        }

        private static func serviceIdentifiers(from properties: [String: String]) -> Set<String> {
            Set(
                ["UniqueIdentifier", "deviceid", "DACP-ID", "hg", "gid"].compactMap { key in
                    property(properties, keys: [key])
                }.filter { !$0.isEmpty }
            )
        }

        private static func preferredIdentifier(from properties: [String: String]) -> String? {
            for key in ["UniqueIdentifier", "deviceid", "DACP-ID", "hg", "gid"] {
                if let value = property(properties, keys: [key]), !value.isEmpty {
                    return value
                }
            }
            return nil
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

        /// Mutable state shared across @Sendable NWBrowser callbacks.
        private final class BrowseState: @unchecked Sendable {
            let lock = NSLock()
            var discovered: [DiscoveredService] = []
            var hasResumed = false
            var browser: NWBrowser?
            var resolvers: [ObjectIdentifier: NWConnection] = [:]

            func setBrowser(_ browser: NWBrowser) {
                lock.withLock {
                    self.browser = browser
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

            func append(_ service: DiscoveredService?) {
                lock.withLock {
                    guard let service, !hasResumed else { return }
                    discovered.append(service)
                }
            }

            func safeResume(_ continuation: CheckedContinuation<[DiscoveredService], Error>) {
                let snapshot = lock.withLock {
                    guard !hasResumed else {
                        return nil as (NWBrowser?, [NWConnection], [DiscoveredService])?
                    }
                    hasResumed = true
                    let snapshot = (browser, Array(resolvers.values), discovered)
                    browser = nil
                    resolvers.removeAll()
                    return snapshot
                }

                guard let (browser, resolvers, discovered) = snapshot else {
                    return
                }

                browser?.cancel()
                for resolver in resolvers {
                    resolver.cancel()
                }
                continuation.resume(returning: discovered)
            }
        }

        /// Browse for a specific Bonjour service type and resolve endpoints.
        private static func browse(
            serviceType: BonjourServiceType,
            timeout: TimeInterval
        ) async throws -> [DiscoveredService] {
            let timeoutNs = try timeoutNanoseconds(from: timeout, parameterName: "timeout")

            return try await withCheckedThrowingContinuation { continuation in
                let state = BrowseState()

                let params = NWParameters()
                params.includePeerToPeer = true

                let browser = NWBrowser(
                    for: .bonjour(type: serviceType.rawValue, domain: "local."),
                    using: params
                )
                state.setBrowser(browser)

                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    state.safeResume(continuation)
                }

                browser.stateUpdateHandler = { browserState in
                    if case .failed = browserState {
                        timeoutTask.cancel()
                        state.safeResume(continuation)
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
        }

        /// Resolve a Bonjour browser result to get host, port, and TXT record.
        private static func resolveEndpoint(
            _ result: NWBrowser.Result,
            serviceType: BonjourServiceType,
            browseState: BrowseState,
            completion: @escaping @Sendable (DiscoveredService?) -> Void
        ) {
            let endpoint = result.endpoint
            let name: String
            if case .service(let n, _, _, _) = endpoint {
                name = n
            } else {
                name = "Unknown"
            }

            // Extract TXT record from metadata
            let txtRecord: [String: String] = {
                var record: [String: String] = [:]
                if case .bonjour(let txt) = result.metadata {
                    for key in txt.dictionary.keys {
                        if let value = txt.dictionary[key] {
                            record[key] = value
                        }
                    }
                }
                return record
            }()

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
                        connection.cancel()
                        completion(nil)
                    }

                case .failed, .cancelled:
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
    }
#endif
