import Foundation

/// Generic message dispatch system for pub-sub communication between protocol layers.
///
/// Thread-safe actor that manages message subscriptions and dispatches messages
/// to registered handlers based on dispatch type.
public actor MessageDispatcher<DispatchType: Hashable & Sendable, MessageType: Sendable> {

    /// A registered message handler with optional filter.
    private struct Handler: Sendable where DispatchType: Sendable, MessageType: Sendable {
        let id: UUID
        let filter: (@Sendable (MessageType) -> Bool)?
        let callback: @Sendable (MessageType) async -> Void
    }

    private var handlers: [DispatchType: [Handler]] = [:]
    private var defaultHandlers: [Handler] = []

    public init() {}

    /// Register a handler for a specific dispatch type.
    /// - Parameters:
    ///   - type: The dispatch type to listen for.
    ///   - filter: Optional filter to apply before calling the handler.
    ///   - handler: Async callback invoked when a matching message is dispatched.
    /// - Returns: A registration ID that can be used to remove the handler.
    @discardableResult
    public func listen(
        to type: DispatchType,
        filter: (@Sendable (MessageType) -> Bool)? = nil,
        handler: @escaping @Sendable (MessageType) async -> Void
    ) -> UUID {
        let h = Handler(id: UUID(), filter: filter, callback: handler)
        handlers[type, default: []].append(h)
        return h.id
    }

    /// Register a default handler that receives all dispatched messages.
    @discardableResult
    public func listenAll(
        handler: @escaping @Sendable (MessageType) async -> Void
    ) -> UUID {
        let h = Handler(id: UUID(), filter: nil, callback: handler)
        defaultHandlers.append(h)
        return h.id
    }

    /// Remove a specific handler by its registration ID.
    public func removeHandler(_ id: UUID) {
        for key in handlers.keys {
            handlers[key]?.removeAll { $0.id == id }
        }
        defaultHandlers.removeAll { $0.id == id }
    }

    /// Remove all handlers for a specific dispatch type.
    public func removeHandlers(for type: DispatchType) {
        handlers[type] = nil
    }

    /// Remove all handlers.
    public func removeAllHandlers() {
        handlers.removeAll()
        defaultHandlers.removeAll()
    }

    /// Dispatch a message to all matching handlers.
    public func dispatch(_ type: DispatchType, message: MessageType) async {
        let typeHandlers = handlers[type] ?? []

        for handler in typeHandlers {
            if let filter = handler.filter, !filter(message) {
                continue
            }
            await handler.callback(message)
        }

        for handler in defaultHandlers {
            await handler.callback(message)
        }
    }

    /// Check if there are any handlers registered for a type.
    public func hasHandlers(for type: DispatchType) -> Bool {
        guard let h = handlers[type] else { return false }
        return !h.isEmpty
    }
}
