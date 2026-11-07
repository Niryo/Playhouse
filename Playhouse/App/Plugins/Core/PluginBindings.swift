import Foundation

/// An event prop after resolution: the action to run and its resolved payload.
struct PluginEventBinding: Codable, Equatable {
    var action: String
    var payload: BridgeValue
}

/// One element of the tree the renderer draws and the dev runner prints. Structural
/// nodes (`if`, `list`) never appear: they are replaced by the children they produce.
struct PluginResolvedNode: Codable, Equatable {
    var id: Int
    var type: String
    var props: [String: BridgeValue]
    var events: [String: PluginEventBinding]
    var children: [PluginResolvedNode]
    /// Set when this element couldn't be resolved or isn't a known component.
    var error: String?

    var allNodes: [PluginResolvedNode] { [self] + children.flatMap(\.allNodes) }
}

/// Gives each element a number keyed by its structural path, so an element keeps
/// its number across re-renders and reloads while new elements get new numbers.
/// Numbers are never reused within a session.
final class PluginNodeIDAllocator {
    private let lock = NSLock()
    private var numbers: [String: Int] = [:]
    private var next = 1

    func id(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let existing = numbers[path] { return existing }
        let number = next
        next += 1
        numbers[path] = number
        return number
    }
}

/// Binding expressions: `{{path}}`, `{{!path}}` and `{{!!path}}`, where a path is
/// dot-separated names or indexes (`items.0.title`), plus `.length` on arrays and
/// strings. Anything more is computed in JS and stored in state.
enum PluginBindings {
    struct Scope {
        var state: BridgeValue
        var locals: [String: BridgeValue] = [:]
    }

    /// The `{{…}}` expressions in a string, or an error message for malformed ones.
    static func expressions(in text: String) -> Result<[String], PluginLoadError> {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                return .failure(PluginLoadError("Unclosed binding in \"\(text)\"."))
            }
            let expression = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let problem = problem(in: expression) {
                return .failure(PluginLoadError("Invalid binding {{\(expression)}}: \(problem)"))
            }
            found.append(expression)
            rest = rest[close.upperBound...]
        }
        return .success(found)
    }

    static func problem(in expression: String) -> String? {
        let path = expression.drop { $0 == "!" }
        guard !path.isEmpty else { return "it is empty." }
        for segment in path.split(separator: ".", omittingEmptySubsequences: false) {
            guard !segment.isEmpty else { return "it has an empty path segment." }
            guard segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) else {
                return "only names, indexes and \"!\" are allowed; compute anything else in logic.js."
            }
        }
        return nil
    }

    /// Resolves one prop or payload value. A string that is exactly one binding
    /// takes the bound value itself; bindings inside a longer string interpolate as text.
    static func resolve(_ value: BridgeValue, in scope: Scope) -> BridgeValue {
        switch value {
        case .string(let text):
            guard text.contains("{{") else { return value }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"),
               case .success(let expressions) = expressions(in: trimmed), expressions.count == 1,
               trimmed.dropFirst(2).dropLast(2).range(of: "{{") == nil {
                return evaluate(expressions[0], in: scope)
            }
            var output = ""
            var rest = Substring(text)
            while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
                output += rest[..<open.lowerBound]
                let expression = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                output += evaluate(expression, in: scope).interpolatedText
                rest = rest[close.upperBound...]
            }
            return .string(output + rest)
        case .array(let values):
            return .array(values.map { resolve($0, in: scope) })
        case .object(let object):
            return .object(object.mapValues { resolve($0, in: scope) })
        default:
            return value
        }
    }

    static func evaluate(_ expression: String, in scope: Scope) -> BridgeValue {
        let negations = expression.prefix { $0 == "!" }.count
        let path = expression.dropFirst(negations).split(separator: ".").map(String.init)
        guard let first = path.first else { return .null }
        var current: BridgeValue = scope.locals[first] ?? lookup(first, in: scope.state)
        for segment in path.dropFirst() {
            current = lookup(segment, in: current)
        }
        guard negations > 0 else { return current }
        let truthy = current.isTruthy
        return .boolean(negations % 2 == 1 ? !truthy : truthy)
    }

    private static func lookup(_ segment: String, in value: BridgeValue) -> BridgeValue {
        switch value {
        case .object(let object):
            return object[segment] ?? .null
        case .array(let values):
            if segment == "length" { return .integer(values.count) }
            guard let index = Int(segment), values.indices.contains(index) else { return .null }
            return values[index]
        case .string(let text):
            return segment == "length" ? .integer(text.count) : .null
        default:
            return .null
        }
    }
}

/// Turns a view tree plus state into the resolved tree.
struct PluginTreeResolver {
    let allocator: PluginNodeIDAllocator

    func resolve(_ root: PluginViewNode, viewID: String, state: BridgeValue) -> PluginResolvedNode {
        let scope = PluginBindings.Scope(state: state)
        let nodes = resolve(root, path: "\(viewID)", scope: scope)
        if nodes.count == 1 { return nodes[0] }
        // A structural root produced zero or several elements; wrap them in a stack.
        return PluginResolvedNode(id: allocator.id(for: "\(viewID)#root"), type: "vstack", props: [:], events: [:], children: nodes, error: nil)
    }

    private func resolve(_ node: PluginViewNode, path: String, scope: PluginBindings.Scope) -> [PluginResolvedNode] {
        switch node.type {
        case "if":
            let condition = PluginBindings.resolve(node.props["cond"] ?? .null, in: scope)
            guard condition.isTruthy else { return [] }
            return children(of: node, path: path, scope: scope)
        case "list":
            let items = PluginBindings.resolve(node.props["items"] ?? .null, in: scope).array ?? []
            let alias = node.props["as"]?.string ?? "item"
            let keyField = node.props["key"]?.string ?? "id"
            var seenKeys: Set<String> = []
            return items.enumerated().flatMap { index, item -> [PluginResolvedNode] in
                var key = item.object?[keyField].map(\.interpolatedText).flatMap { $0.isEmpty ? nil : $0 } ?? "#\(index)"
                if !seenKeys.insert(key).inserted { key += "#\(index)" }
                var itemScope = scope
                itemScope.locals[alias] = item
                itemScope.locals["index"] = .integer(index)
                return children(of: node, path: "\(path)[\(key)]", scope: itemScope)
            }
        default:
            break
        }

        let id = allocator.id(for: path)
        if let hidden = node.props["hidden"], PluginBindings.resolve(hidden, in: scope).isTruthy { return [] }
        guard let spec = PluginComponentCatalog.spec(node.type) else {
            return [PluginResolvedNode(id: id, type: node.type, props: [:], events: [:], children: [], error: "Unknown component \"\(node.type)\".")]
        }
        var props: [String: BridgeValue] = [:]
        var events: [String: PluginEventBinding] = [:]
        for (name, raw) in node.props where name != "hidden" {
            if PluginComponentCatalog.isEventName(name, for: spec) {
                guard let object = raw.object, let action = object["action"]?.string else { continue }
                events[name] = PluginEventBinding(action: action, payload: PluginBindings.resolve(object["payload"] ?? .null, in: scope))
            } else {
                props[name] = PluginBindings.resolve(raw, in: scope)
            }
        }
        for prop in spec.props where props[prop.name] == nil {
            if let defaultValue = prop.defaultValue { props[prop.name] = defaultValue }
        }
        let missing = spec.props.filter { $0.required && (props[$0.name]?.isNull ?? true) }.map(\.name)
        var resolvedChildren = children(of: node, path: path, scope: scope)
        // A closed popover keeps its anchor; a closed sheet keeps nothing, so its content can't be reached.
        if spec.presentation, props["open"]?.isTruthy != true { resolvedChildren = Array(resolvedChildren.prefix(spec.anchorChildren)) }
        return [PluginResolvedNode(
            id: id,
            type: node.type,
            props: props,
            events: events,
            children: resolvedChildren,
            error: missing.isEmpty ? nil : "Missing required prop \(missing.joined(separator: ", "))."
        )]
    }

    private func children(of node: PluginViewNode, path: String, scope: PluginBindings.Scope) -> [PluginResolvedNode] {
        node.children.enumerated().flatMap { index, child in resolve(child, path: "\(path)/\(index)", scope: scope) }
    }
}
