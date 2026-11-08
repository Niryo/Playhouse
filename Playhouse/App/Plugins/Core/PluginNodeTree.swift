import Foundation
import Observation

/// One mutation the plugin's React host config sends; a commit is a JSON array
/// of these. See Playhouse/App/Plugins/README.md.
enum PluginOp: Decodable, Equatable {
    case create(id: Int, type: String, props: [String: PluginValue], events: [String])
    case createText(id: Int, text: String)
    case update(id: Int, props: [String: PluginValue], events: [String])
    case text(id: Int, text: String)
    case append(parent: Int, child: Int)
    case insert(parent: Int, child: Int, before: Int)
    case remove(parent: Int, child: Int)
    case clear

    private enum CodingKeys: String, CodingKey { case op, id, type, props, events, text, parent, child, before }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        func int(_ key: CodingKeys) throws -> Int { try container.decode(Int.self, forKey: key) }
        switch op {
        case "create":
            self = .create(
                id: try int(.id),
                type: try container.decode(String.self, forKey: .type),
                props: try container.decodeIfPresent([String: PluginValue].self, forKey: .props) ?? [:],
                events: try container.decodeIfPresent([String].self, forKey: .events) ?? []
            )
        case "createText": self = .createText(id: try int(.id), text: try container.decode(String.self, forKey: .text))
        case "update":
            self = .update(
                id: try int(.id),
                props: try container.decodeIfPresent([String: PluginValue].self, forKey: .props) ?? [:],
                events: try container.decodeIfPresent([String].self, forKey: .events) ?? []
            )
        case "text": self = .text(id: try int(.id), text: try container.decode(String.self, forKey: .text))
        case "append": self = .append(parent: try int(.parent), child: try int(.child))
        case "insert": self = .insert(parent: try int(.parent), child: try int(.child), before: try int(.before))
        case "remove": self = .remove(parent: try int(.parent), child: try int(.child))
        case "clear": self = .clear
        default:
            throw DecodingError.dataCorruptedError(forKey: .op, in: container, debugDescription: "Unknown op \(op)")
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

/// One element of the rendered tree: an atom, or a raw text node inside a Text
/// atom. Each node is observed on its own, so an op that changes one node
/// re-renders only the SwiftUI view showing that node (and what it contains).
@Observable
final class PluginNode: Identifiable {
    static let textType = "#text"

    let id: Int
    let type: String
    var props: [String: PluginValue]
    /// The event props the plugin set (`onPress`, …); their handlers stay in JavaScript.
    var events: Set<String>
    var text: String
    var children: [PluginNode] = []
    /// How many update/text ops changed this node after it was created.
    @ObservationIgnored private(set) var updateCount = 0

    init(id: Int, type: String, props: [String: PluginValue] = [:], events: Set<String> = [], text: String = "") {
        self.id = id
        self.type = type
        self.props = props
        self.events = events
        self.text = text
    }

    /// A Text atom's string: its raw text children joined.
    var joinedText: String {
        children.filter { $0.type == Self.textType }.map(\.text).joined()
    }

    fileprivate func noteUpdate() { updateCount += 1 }
}

/// What the last commit did, for the catalog's readout and the CLI.
struct PluginCommitSummary: Equatable {
    var number: Int
    var ops: [String]
    var touchedNodes: [Int]
}

struct PluginTreeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The node tree a plugin's ops build. The root container is node 0.
@Observable
final class PluginNodeTree {
    private(set) var root = PluginNode(id: 0, type: "#root")
    private(set) var lastCommit: PluginCommitSummary?
    @ObservationIgnored private var nodes: [Int: PluginNode] = [:]
    /// Checks an atom's type, props and events before a create or update is applied.
    @ObservationIgnored var validate: (String, [String: PluginValue], [String]) throws -> Void = { _, _, _ in }
    /// Checks that a parent type shows a child type before an append or insert.
    @ObservationIgnored var validateChild: (String, String) throws -> Void = { _, _ in }

    init() {
        nodes[0] = root
    }

    func node(_ id: Int) -> PluginNode? { nodes[id] }

    func apply(json: String) throws {
        let ops = try JSONDecoder().decode([PluginOp].self, from: Data(json.utf8))
        try apply(ops)
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
            try validate(type, props, events)
            nodes[id] = PluginNode(id: id, type: type, props: props, events: Set(events))
        case .createText(let id, let text):
            guard nodes[id] == nil else { throw PluginTreeError(message: "Node \(id) already exists.") }
            nodes[id] = PluginNode(id: id, type: PluginNode.textType, text: text)
        case .update(let id, let props, let events):
            let node = try existing(id)
            try validate(node.type, props, events)
            if node.props != props { node.props = props }
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
            if !node.props.isEmpty { object["props"] = .object(node.props) }
            if !node.events.isEmpty { object["events"] = .array(node.events.sorted().map(PluginValue.string)) }
            if !node.children.isEmpty { object["children"] = .array(node.children.map { snapshot($0) }) }
        }
        return .object(object)
    }
}
