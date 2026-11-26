import Foundation
import Observation

/// One mutation the plugin's React host config sends; a commit is an array
/// of these, passed to Swift as a JavaScript value. See
/// Playhouse/App/Plugins/README.md.
enum PluginOp: Equatable {
    case create(id: Int, type: String, props: [String: PluginValue], events: [String])
    case createText(id: Int, text: String)
    case update(id: Int, props: [String: PluginValue], events: [String])
    case text(id: Int, text: String)
    case append(parent: Int, child: Int)
    case insert(parent: Int, child: Int, before: Int)
    case remove(parent: Int, child: Int)
    case clear

    /// Reads one op object (`{op: "append", parent: 3, child: 4}`).
    init(_ value: PluginValue) throws {
        guard let fields = value.object, let op = fields["op"]?.string else {
            throw PluginTreeError(message: "An op must be an object with an \"op\" name, not \(value.jsonText).")
        }
        func int(_ key: String) throws -> Int {
            guard let number = fields[key]?.int else { throw PluginTreeError(message: "The \(op) op needs an integer \"\(key)\".") }
            return number
        }
        func string(_ key: String) throws -> String {
            guard let text = fields[key]?.string else { throw PluginTreeError(message: "The \(op) op needs a string \"\(key)\".") }
            return text
        }
        func props() throws -> [String: PluginValue] {
            switch fields["props"] {
            case nil, .null?: return [:]
            case .object(let props)?: return props
            default: throw PluginTreeError(message: "The \(op) op's \"props\" must be an object.")
            }
        }
        func events() throws -> [String] {
            switch fields["events"] {
            case nil, .null?: return []
            case .array(let names)?:
                return try names.map { name in
                    guard let text = name.string else { throw PluginTreeError(message: "The \(op) op's \"events\" must be strings.") }
                    return text
                }
            default: throw PluginTreeError(message: "The \(op) op's \"events\" must be an array.")
            }
        }
        switch op {
        case "create": self = .create(id: try int("id"), type: try string("type"), props: try props(), events: try events())
        case "createText": self = .createText(id: try int("id"), text: try string("text"))
        case "update": self = .update(id: try int("id"), props: try props(), events: try events())
        case "text": self = .text(id: try int("id"), text: try string("text"))
        case "append": self = .append(parent: try int("parent"), child: try int("child"))
        case "insert": self = .insert(parent: try int("parent"), child: try int("child"), before: try int("before"))
        case "remove": self = .remove(parent: try int("parent"), child: try int("child"))
        case "clear": self = .clear
        default: throw PluginTreeError(message: "Unknown op \(op).")
        }
    }

    var name: String {
        switch self {
        case .create: "create"
        case .createText: "createText"
        case .update: "update"
        case .text: "text"
        case .append: "append"
        case .insert: "insert"
        case .remove: "remove"
        case .clear: "clear"
        }
    }

    /// The node the op creates or changes (for append/insert/remove, the child).
    var nodeID: Int? {
        switch self {
        case .create(let id, _, _, _), .createText(let id, _), .update(let id, _, _), .text(let id, _): id
        case .append(_, let child), .insert(_, let child, _), .remove(_, let child): child
        case .clear: nil
        }
    }
}

/// A node's props as they were given.
enum PluginNodeProps {
    /// A plugin's JSON props, decoded once when the op that sent them applies.
    case dynamic([String: PluginValue])
    /// Props native Swift code built, the atom's own and the common ones; never decoded.
    case typed(any AtomProps, AtomCommon)

    /// The props as plugin values: a plugin's as it sent them, typed ones
    /// encoded into the dictionary a plugin would send for them.
    var values: [String: PluginValue] {
        switch self {
        case .dynamic(let values):
            return values
        case .typed(let atom, let common):
            let (own, shared) = Self.encoded(atom, common)
            return own.merging(shared) { atom, _ in atom }
        }
    }

    /// The keys both the atom's own props and the common ones have (a Modal's
    /// `width`) that typed props set differently, one of them unset included. A
    /// plugin's one key fills both, so typed props must set them alike, or
    /// their `values` couldn't stand for them.
    static func conflictingKeys(_ atom: any AtomProps, _ common: AtomCommon) -> [String] {
        let (own, shared) = encoded(atom, common)
        return type(of: atom).atomType.propKeys.intersection(AtomCommon.keys).filter { own[$0] != shared[$0] }.sorted()
    }

    private static func encoded(_ atom: any AtomProps, _ common: AtomCommon) -> (own: [String: PluginValue], shared: [String: PluginValue]) {
        ((try? PluginValue(encoding: atom))?.object ?? [:], (try? PluginValue(encoding: common))?.object ?? [:])
    }
}

/// One element of the rendered tree: an atom, or a raw text node inside a Text
/// atom. Each node is observed on its own, so an op that changes one node
/// re-renders only the SwiftUI view showing that node (and what it contains).
///
/// Its props are decoded when they are set, never when it renders: `resolved`
/// holds the decoded structs (or why they don't decode), and is all a view reads.
@Observable
final class PluginNode: Identifiable {
    static let textType = "#text"
    /// A native tree's placeholder for content its host view supplies, named
    /// by `text` (`AtomNodeSpec.slot`); never created by a plugin's ops.
    static let slotType = "#slot"

    let id: Int
    let type: String
    /// The props as given: a plugin's dictionary, or native typed props.
    private(set) var props: PluginNodeProps
    /// The atom's own and common props, decoded once when `props` were set,
    /// or the error decoding them, which the node's view shows.
    private(set) var resolved: Result<ResolvedAtomProps, PluginTreeError>
    /// The event props the plugin set (`onPress`, …); their handlers stay in JavaScript.
    var events: Set<String>
    var text: String
    var children: [PluginNode] = []
    /// How many update/text ops (or, for typed props, `setProps` calls that
    /// changed them) changed this node after it was created.
    @ObservationIgnored private(set) var updateCount = 0

    /// A node from a plugin's op (or a raw text node, with `text`). `resolved`
    /// is the op's validated props; without it, `props` are decoded here.
    init(id: Int, type: String, props: [String: PluginValue] = [:], resolved: ResolvedAtomProps? = nil, events: Set<String> = [], text: String = "") {
        self.id = id
        self.type = type
        self.props = .dynamic(props)
        self.resolved = Self.resolve(type: type, props: props, resolved: resolved)
        self.events = events
        self.text = text
    }

    /// A node native Swift code builds with typed props: its atom is the props'
    /// own, and nothing is decoded.
    init<Props: AtomProps>(id: Int, props: Props, common: AtomCommon = AtomCommon(), events: Set<String> = []) {
        assert(PluginNodeProps.conflictingKeys(props, common).isEmpty, "<\(Props.atomType.rawValue)> sets \(PluginNodeProps.conflictingKeys(props, common)) differently in its props and common props.")
        self.id = id
        type = Props.atomType.rawValue
        self.props = .typed(props, common)
        resolved = .success(ResolvedAtomProps(atom: props, common: common))
        self.events = events
        text = ""
    }

    /// The common props, when they decoded.
    var common: AtomCommon? { try? resolved.get().common }

    /// A Text atom's string: its raw text children joined.
    var joinedText: String {
        children.filter { $0.type == Self.textType }.map(\.text).joined()
    }

    /// Replaces a typed node's props. Equal props change nothing, so the
    /// node's view isn't redrawn; returns whether they changed.
    @discardableResult
    func setProps<Props: AtomProps>(_ props: Props, common: AtomCommon = AtomCommon()) -> Bool {
        precondition(Props.atomType.rawValue == type, "<\(type)> can't take \(Props.self).")
        assert(PluginNodeProps.conflictingKeys(props, common).isEmpty, "<\(type)> sets \(PluginNodeProps.conflictingKeys(props, common)) differently in its props and common props.")
        if case .typed(let atom, let oldCommon) = self.props, atom.isEqual(to: props), oldCommon == common { return false }
        self.props = .typed(props, common)
        resolved = .success(ResolvedAtomProps(atom: props, common: common))
        updateCount += 1
        return true
    }

    /// Replaces a plugin node's props from an update op, decoding them once.
    fileprivate func setProps(_ values: [String: PluginValue], resolved: ResolvedAtomProps?) {
        if case .dynamic(let old) = props, old == values { return }
        props = .dynamic(values)
        self.resolved = Self.resolve(type: type, props: values, resolved: resolved)
    }

    private static func resolve(type: String, props: [String: PluginValue], resolved: ResolvedAtomProps?) -> Result<ResolvedAtomProps, PluginTreeError> {
        if let resolved { return .success(resolved) }
        if type == textType || type == slotType || type == "#root" { return .failure(PluginTreeError(message: "<\(type)> is not an atom.")) }
        do {
            return .success(try AtomType.decode(type: type, props: props))
        } catch let error as PluginTreeError {
            return .failure(error)
        } catch {
            return .failure(PluginTreeError(message: error.localizedDescription))
        }
    }

    fileprivate func noteUpdate() { updateCount += 1 }
}

/// What the last commit did, for the catalog's readout and the CLI.
struct PluginCommitSummary: Equatable {
    var number: Int
    var ops: [String]
    var touchedNodes: [Int]
}

struct PluginTreeError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// The node tree a plugin's ops build. The root container is node 0.
@Observable
final class PluginNodeTree {
    private(set) var root = PluginNode(id: 0, type: "#root")
    private(set) var lastCommit: PluginCommitSummary?
    @ObservationIgnored private var nodes: [Int: PluginNode] = [:]
    /// Checks an atom's type, props and events before a create or update is
    /// applied, returning the decoded props the node stores. Without it, a
    /// node decodes its props itself and keeps any error for its view.
    @ObservationIgnored var validate: ((String, [String: PluginValue], [String]) throws -> ResolvedAtomProps)?
    /// Checks that a parent type shows a child type before an append or insert.
    @ObservationIgnored var validateChild: (String, String) throws -> Void = { _, _ in }

    init() {
        nodes[0] = root
    }

    func node(_ id: Int) -> PluginNode? { nodes[id] }

    /// Reads a commit's op array and applies it. A malformed op is reported
    /// before any op of the commit applies.
    func apply(_ commit: PluginValue) throws {
        guard case .array(let items) = commit else { throw PluginTreeError(message: "A commit must be an array of ops.") }
        try apply(items.map(PluginOp.init))
    }

    /// Applies one commit. Ops are checked as they apply; an invalid op stops
    /// the commit at that op.
    func apply(_ ops: [PluginOp]) throws {
        var touched: [Int] = []
        for op in ops {
            try apply(op)
            if let id = op.nodeID, !touched.contains(id) { touched.append(id) }
        }
        lastCommit = PluginCommitSummary(number: (lastCommit?.number ?? 0) + 1, ops: ops.map(\.name), touchedNodes: touched)
    }

    private func apply(_ op: PluginOp) throws {
        switch op {
        case .create(let id, let type, let props, let events):
            guard nodes[id] == nil else { throw PluginTreeError(message: "Node \(id) already exists.") }
            let resolved = try validate?(type, props, events)
            nodes[id] = PluginNode(id: id, type: type, props: props, resolved: resolved, events: Set(events))
        case .createText(let id, let text):
            guard nodes[id] == nil else { throw PluginTreeError(message: "Node \(id) already exists.") }
            nodes[id] = PluginNode(id: id, type: PluginNode.textType, text: text)
        case .update(let id, let props, let events):
            let node = try existing(id)
            let resolved = try validate?(node.type, props, events)
            node.setProps(props, resolved: resolved)
            if node.events != Set(events) { node.events = Set(events) }
            node.noteUpdate()
        case .text(let id, let text):
            let node = try existing(id)
            node.text = text
            node.noteUpdate()
        case .append(let parentID, let childID):
            let parent = try existing(parentID), child = try existing(childID)
            try validateChild(parent.type, child.type)
            var children = parent.children
            children.removeAll { $0 === child }
            children.append(child)
            parent.children = children
        case .insert(let parentID, let childID, let beforeID):
            let parent = try existing(parentID), child = try existing(childID)
            try validateChild(parent.type, child.type)
            var children = parent.children
            children.removeAll { $0 === child }
            guard let index = children.firstIndex(where: { $0.id == beforeID }) else {
                throw PluginTreeError(message: "Node \(beforeID) is not a child of node \(parentID).")
            }
            children.insert(child, at: index)
            parent.children = children
        case .remove(let parentID, let childID):
            let parent = try existing(parentID), child = try existing(childID)
            parent.children.removeAll { $0 === child }
            forget(child)
        case .clear:
            root.children.forEach(forget)
            root.children = []
        }
    }

    private func existing(_ id: Int) throws -> PluginNode {
        guard let node = nodes[id] else { throw PluginTreeError(message: "Unknown node \(id).") }
        return node
    }

    private func forget(_ node: PluginNode) {
        nodes[node.id] = nil
        node.children.forEach(forget)
    }

    /// The tree as JSON-ready values: type, props, events, text and update counts.
    func snapshot(_ node: PluginNode? = nil) -> PluginValue {
        let node = node ?? root
        var object: [String: PluginValue] = ["id": .number(Double(node.id)), "type": .string(node.type), "updates": .number(Double(node.updateCount))]
        if node.type == PluginNode.textType {
            object["text"] = .string(node.text)
        } else {
            let props = node.props.values
            if !props.isEmpty { object["props"] = .object(props) }
            if !node.events.isEmpty { object["events"] = .array(node.events.sorted().map(PluginValue.string)) }
            if !node.children.isEmpty { object["children"] = .array(node.children.map { snapshot($0) }) }
        }
        return .object(object)
    }
}
