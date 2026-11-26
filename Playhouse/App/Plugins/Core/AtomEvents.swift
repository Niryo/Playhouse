import Foundation

/// Where an atom sends its events, such as a Button's "onPress" or a TextField's
/// "onChange" with the new text. A plugin's `PluginRuntime` forwards them to the
/// handlers in its JavaScript; native Swift trees use `AtomEventHandlers`.
protocol AtomEventHandler: AnyObject {
    /// Sends `event` to node `nodeID`'s handler. Returns false when the node has no such handler.
    @discardableResult
    func dispatch(nodeID: Int, event: String, value: PluginValue?) -> Bool
}

extension PluginRuntime: AtomEventHandler {}

/// Event handlers for a tree native Swift code builds, by node and event name.
/// The value is the event's payload: the text of an "onChange", a menu item's
/// id, or nil for a press. Registering a handler also adds the event to the
/// node's `events`, which some atoms read to decide whether to take a key or a
/// scroll at all (a TextField's Return, a Scroll's end), so the two never
/// disagree. A handler that captures its owner should capture it weakly when
/// the owner also holds these handlers. Like `PluginRuntime`, use it on the main thread.
final class AtomEventHandlers: AtomEventHandler {
    private var handlers: [Int: [String: (PluginValue?) -> Void]] = [:]

    init() {}

    /// Calls `handler` whenever `node` sends `event`, replacing any earlier one.
    /// The event must be one the node's atom raises.
    func on(_ node: PluginNode, _ event: String, _ handler: @escaping (PluginValue?) -> Void) {
        assert(AtomType(rawValue: node.type)?.events.contains(event) == true, "<\(node.type)> raises no \(event).")
        handlers[node.id, default: [:]][event] = handler
        node.events.insert(event)
    }

    /// Removes `node`'s handler for `event`, or all of its handlers when `event` is nil.
    func remove(_ node: PluginNode, _ event: String? = nil) {
        if let event {
            handlers[node.id]?[event] = nil
            node.events.remove(event)
        } else {
            handlers[node.id] = nil
            node.events.removeAll()
        }
    }

    /// Removes the handlers of a node that is no longer in its tree.
    func remove(nodeID: Int) {
        handlers[nodeID] = nil
    }

    @discardableResult
    func dispatch(nodeID: Int, event: String, value: PluginValue?) -> Bool {
        guard let handler = handlers[nodeID]?[event] else { return false }
        handler(value)
        return true
    }
}
