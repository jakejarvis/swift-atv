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
private struct DiscoveredService: Sendable {
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
    ) async throws -> [AppleTVConfiguration] {
        let scanner = ATVScanner()
        return try await scanner.performScan(
            timeout: timeout,
            identifiers: identifiers,
            protocols: protocols
        )
    }

    private var devices: [String: AppleTVConfiguration] = [:]

    private init() {}

    private func performScan(
        timeout: TimeInterval,
        identifiers: Set<String>?,
        protocols: Set<ATVProtocol>?
    ) async throws -> [AppleTVConfiguration] {
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
        let services = try await withThrowingTaskGroup(
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

        // Aggregate services by host address
        for service in services {
            processDiscoveredService(service)
        }

        var results = Array(devices.values)

        // Filter by identifiers if specified
        if let identifiers {
            results = results.filter { config in
                guard let id = config.mainIdentifier else { return false }
                return identifiers.contains(id)
            }
        }

        return results
    }

    private func processDiscoveredService(_ service: DiscoveredService) {
        let address = service.host

        if devices[address] == nil {
            devices[address] = AppleTVConfiguration(
                address: address,
                name: service.name
            )
        }

        // Update device info from properties
        if service.serviceType == .deviceInfo {
            devices[address]?.deviceInfo = DeviceInfo.fromProperties(service.txtRecord)
            return
        }

        // Add protocol service
        guard let proto = service.serviceType.atvProtocol else { return }

        // Extract identifier from TXT record
        let identifier = service.txtRecord["UniqueIdentifier"]
            ?? service.txtRecord["deviceid"]
            ?? service.txtRecord["DACP-ID"]

        let serviceInfo = ServiceInfo(
            protocol: proto,
            port: service.port,
            identifier: identifier,
            properties: service.txtRecord,
            pairingRequirement: parsePairingRequirement(service.txtRecord)
        )

        devices[address]?.addService(serviceInfo)

        // Update device info from service properties if not already set
        if devices[address]?.deviceInfo.model == .unknown {
            let info = DeviceInfo.fromProperties(service.txtRecord)
            if info.model != .unknown {
                devices[address]?.deviceInfo = info
            }
        }
    }

    private func parsePairingRequirement(_ properties: [String: String]) -> PairingRequirement {
        if let flags = properties["flags"], let val = Int(flags) {
            // Companion link typically requires pairing
            if val & 0x200 != 0 {
                return .mandatory
            }
        }
        return .unsupported
    }

    /// Mutable state shared across @Sendable NWBrowser callbacks.
    private final class BrowseState: @unchecked Sendable {
        let lock = NSLock()
        var discovered: [DiscoveredService] = []
        var hasResumed = false

        func safeResume(_ continuation: CheckedContinuation<[DiscoveredService], Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(returning: discovered)
        }
    }

    /// Browse for a specific Bonjour service type and resolve endpoints.
    private static func browse(
        serviceType: BonjourServiceType,
        timeout: TimeInterval
    ) async throws -> [DiscoveredService] {
        try await withCheckedThrowingContinuation { continuation in
            let state = BrowseState()

            let params = NWParameters()
            params.includePeerToPeer = true

            let browser = NWBrowser(
                for: .bonjour(type: serviceType.rawValue, domain: "local."),
                using: params
            )

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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
                    Self.resolveEndpoint(result, serviceType: serviceType) { service in
                        state.lock.lock()
                        if let service, !state.hasResumed {
                            state.discovered.append(service)
                        }
                        state.lock.unlock()
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

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
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
                completion(nil)

            default:
                break
            }
        }

        connection.start(queue: .global())

        // Timeout for resolution
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            connection.cancel()
        }
    }
}
#endif
