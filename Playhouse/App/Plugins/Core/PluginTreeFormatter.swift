import Foundation

/// Text and JSON forms of a resolved tree, for `playhouse-plugin-dev view`.
enum PluginTreeFormatter {
    /// One line per element, indented by depth:
    /// `[4] button title="Start" onTap→start`.
    static func text(_ node: PluginResolvedNode, depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth) + "[\(node.id)] \(node.type)"
        let defaults = PluginComponentCatalog.spec(node.type)?.props.reduce(into: [String: BridgeValue]()) { $0[$1.name] = $1.defaultValue } ?? [:]
        let props = node.props.keys.sorted().compactMap { name -> String? in
            // Props still at their catalog default are left out to keep the tree readable.
            guard let value = node.props[name], value != defaults[name] else { return nil }
            switch value {
            case .string(let text): return "\(name)=\"\(text.replacingOccurrences(of: "\n", with: "\\n"))\""
            case .array(let values): return "\(name)=[\(values.count) items]"
            case .object: return "\(name)={…}"
            default: return "\(name)=\(value.interpolatedText)"
            }
        }
        if !props.isEmpty { line += " " + props.joined(separator: " ") }
        let events = node.events.keys.sorted().map { "\($0)→\(node.events[$0]!.action)" }
        if !events.isEmpty { line += " " + events.joined(separator: " ") }
        if let error = node.error { line += " !error \(error)" }
        return ([line] + node.children.map { text($0, depth: depth + 1) }).joined(separator: "\n")
    }

    static func value(_ node: PluginResolvedNode) -> BridgeValue {
        (try? BridgeValue.encoding(node)) ?? .null
    }
}
