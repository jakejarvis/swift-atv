import Foundation

/// Priority-based method routing across protocol implementations.
///
/// The relayer maintains a priority-ordered list of protocol implementations.
/// When a method is called, it delegates to the highest-priority protocol
/// that has registered an implementation.
///
/// Thread safety: Mutable registrations are protected by `NSLock`.
public final class Relayer<Interface>: @unchecked Sendable {

    /// Default protocol priority order (highest first).
    public static var defaultPriorities: [ATVProtocol] {
        [.mrp, .airPlay, .companion]
    }

    private struct Registration {
        let `protocol`: ATVProtocol
        let implementation: Interface
    }

    private let lock = NSLock()
    private var registrations: [Registration] = []
    private let priorities: [ATVProtocol]
    private var takeoverProtocol: ATVProtocol?

    /// Initialize with custom priorities.
    public init(priorities: [ATVProtocol] = Relayer.defaultPriorities) {
        self.priorities = priorities
    }

    /// Register a protocol implementation.
    public func register(_ implementation: Interface, for protocol: ATVProtocol) {
        lock.lock()
        defer { lock.unlock() }
        registrations.removeAll { $0.protocol == `protocol` }
        registrations.append(Registration(protocol: `protocol`, implementation: implementation))
    }

    /// Get the highest-priority registered implementation.
    /// If a takeover protocol is active, that implementation is returned instead.
    public var main: Interface? {
        lock.lock()
        defer { lock.unlock() }

        if let takeover = takeoverProtocol {
            return registrations.first { $0.protocol == takeover }?.implementation
        }

        for priority in priorities {
            if let reg = registrations.first(where: { $0.protocol == priority }) {
                return reg.implementation
            }
        }
        return nil
    }

    /// Get the implementation for a specific protocol.
    public func get(for protocol: ATVProtocol) -> Interface? {
        lock.lock()
        defer { lock.unlock() }
        return registrations.first { $0.protocol == `protocol` }?.implementation
    }

    /// Get all registered implementations in priority order.
    public var all: [Interface] {
        lock.lock()
        defer { lock.unlock() }
        var result: [Interface] = []
        for priority in priorities {
            if let reg = registrations.first(where: { $0.protocol == priority }) {
                result.append(reg.implementation)
            }
        }
        return result
    }

    /// Temporarily override priority to use a specific protocol.
    /// Returns a closure that releases the takeover when called.
    public func takeover(_ protocol: ATVProtocol) -> @Sendable () -> Void {
        lock.lock()
        takeoverProtocol = `protocol`
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.takeoverProtocol = nil
            self?.lock.unlock()
        }
    }

    /// Whether any implementations are registered.
    public var hasImplementations: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !registrations.isEmpty
    }

    /// Registered protocols in priority order.
    public var registeredProtocols: [ATVProtocol] {
        lock.lock()
        defer { lock.unlock() }
        return priorities.filter { p in registrations.contains { $0.protocol == p } }
    }
}
