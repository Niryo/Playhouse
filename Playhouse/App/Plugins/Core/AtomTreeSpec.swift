import Foundation

/// An atom tree described as plain data, the way a native composite describes
/// itself when it renders through `AtomRegistry` instead of hand-written
/// SwiftUI (the atom-tree spike; see docs/atom-tree-performance.md). A
/// composite is a pure function from its model to a spec; a reconciler keeps
/// a live node tree in step with the latest spec, changing only the nodes
/// whose props or children differ, so only their views re-render.
///
/// Like the rest of the plugin core it is Foundation-only and holds only
/// plain values, so the same spec could drive atoms written for another platform.
struct AtomNodeSpec {
    enum Content {
        case atom(any AtomProps, AtomCommon)
        /// Native content the host view supplies by name (the task item's
        /// plugin row), which no atom can describe. Only native trees have
        /// slots; a plugin's ops can't create one.
        case slot(String)
    }

    let id: Int
    var content: Content
    var events: [String]
    var children: [AtomNodeSpec]

    init<Props: AtomProps>(_ id: Int, _ props: Props, _ common: AtomCommon = AtomCommon(), events: [String] = [], children: [AtomNodeSpec] = []) {
        self.id = id
        content = .atom(props, common)
        self.events = events
        self.children = children
    }

    static func slot(_ id: Int, _ name: String) -> AtomNodeSpec {
        AtomNodeSpec(id: id, content: .slot(name))
    }

    private init(id: Int, content: Content) {
        self.id = id
        self.content = content
        events = []
        children = []
    }

    var type: String {
        switch content {
        case .atom(let props, _): Swift.type(of: props).atomType.rawValue
        case .slot: PluginNode.slotType
        }
    }

    /// The node and all of its descendants.
    var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

/// Keeps a tree of typed `PluginNode`s in step with a spec: no dictionaries,
/// nothing decoded, and a node whose props are equal isn't touched. Events go
/// to `onEvent` with the node's id.
final class TypedAtomTree {
    private(set) var root: PluginNode?
    let handlers: AtomEventHandlers
    var onEvent: (Int, String, PluginValue?) -> Void = { _, _, _ in }
    private var nodes: [Int: PluginNode] = [:]
    private var registered: [Int: Set<String>] = [:]

    /// Trees whose roots one view shows together share `handlers`, with distinct node ids.
    init(handlers: AtomEventHandlers = AtomEventHandlers()) {
        self.handlers = handlers
    }

    /// Applies `spec`; returns the ids of the nodes it created or whose props changed.
    @discardableResult
    func apply(_ spec: AtomNodeSpec) -> [Int] {
        var changed: [Int] = []
        var seen = Set<Int>()
        let node = reconcile(spec, changed: &changed, seen: &seen)
        if root !== node { root = node }
        for (id, node) in nodes where !seen.contains(id) {
            handlers.remove(node)
            nodes[id] = nil
            registered[id] = nil
        }
        return changed
    }

    private func reconcile(_ spec: AtomNodeSpec, changed: inout [Int], seen: inout Set<Int>) -> PluginNode {
        seen.insert(spec.id)
        let node: PluginNode
        if let existing = nodes[spec.id], existing.type == spec.type {
            node = existing
            if case .atom(let props, let common) = spec.content, Self.set(props, common, on: node) { changed.append(spec.id) }
        } else {
            switch spec.content {
            case .atom(let props, let common): node = Self.make(spec.id, props, common)
            case .slot(let name): node = PluginNode(id: spec.id, type: PluginNode.slotType, text: name)
            }
            nodes[spec.id] = node
            registered[spec.id] = nil
            changed.append(spec.id)
        }
        for event in registered[spec.id, default: []].subtracting(spec.events) {
            handlers.remove(node, event)
            registered[spec.id]?.remove(event)
        }
        for event in spec.events where registered[spec.id]?.contains(event) != true {
            let id = spec.id
            handlers.on(node, event) { [weak self] value in self?.onEvent(id, event, value) }
            registered[spec.id, default: []].insert(event)
        }
        let children = spec.children.map { reconcile($0, changed: &changed, seen: &seen) }
        if node.children.map(\.id) != children.map(\.id) || zip(node.children, children).contains(where: { $0 !== $1 }) {
            node.children = children
        }
        return node
    }

    private static func make<Props: AtomProps>(_ id: Int, _ props: Props, _ common: AtomCommon) -> PluginNode {
        PluginNode(id: id, props: props, common: common)
    }

    private static func set<Props: AtomProps>(_ props: Props, _ common: AtomCommon, on node: PluginNode) -> Bool {
        node.setProps(props, common: common)
    }
}

/// Keeps a plugin-style node tree in step with a spec by sending it the ops
/// a plugin's commit would (dictionary props, validated and decoded once per
/// op), with no JavaScript: what a composite costs if it renders the way
/// plugins do. Slots have no op and are left out. A node id must keep its
/// atom type: a changed type would create a node whose id is still in use.
final class DynamicAtomTree {
    let tree = PluginNodeTree()
    let handlers: AtomEventHandlers
    var onEvent: (Int, String, PluginValue?) -> Void = { _, _, _ in }
    private struct Sent: Equatable {
        var type: String
        var values: [String: PluginValue]
        var events: [String]
        var children: [Int]
    }
    private var sent: [Int: Sent] = [:]

    init(handlers: AtomEventHandlers = AtomEventHandlers()) {
        self.handlers = handlers
        tree.validate = AtomType.validate
        tree.validateChild = AtomType.validateChild
    }

    /// The ops that bring the tree from the last spec to `spec`, the root
    /// spec's node a child of the tree's root.
    func ops(for spec: AtomNodeSpec) -> [PluginOp] {
        var ops: [PluginOp] = []
        var next: [Int: Sent] = [:]
        collect(spec, into: &next)
        // Removed subtrees first, from their old parents.
        for (id, old) in sent {
            for child in old.children where next[child] == nil && next[id] != nil {
                ops.append(.remove(parent: id, child: child))
            }
        }
        emit(spec, next: next, into: &ops)
        if sent[spec.id] == nil {
            if let oldRoot = tree.root.children.first, oldRoot.id != spec.id { ops.append(.remove(parent: 0, child: oldRoot.id)) }
            ops.append(.append(parent: 0, child: spec.id))
        }
        sent = next
        return ops
    }

    /// Applies `spec` as one commit; returns how many ops it took.
    @discardableResult
    func apply(_ spec: AtomNodeSpec) throws -> Int {
        let before = Set(sent.keys)
        let ops = ops(for: spec)
        guard !ops.isEmpty else { return 0 }
        try tree.apply(ops)
        for id in before.subtracting(sent.keys) { handlers.remove(nodeID: id) }
        for op in ops {
            guard case .create(let id, _, _, let events) = op, let node = tree.node(id) else { continue }
            for event in events {
                handlers.on(node, event) { [weak self] value in self?.onEvent(id, event, value) }
            }
        }
        return ops.count
    }

    var root: PluginNode? { tree.root.children.first }

    private func collect(_ spec: AtomNodeSpec, into next: inout [Int: Sent]) {
        guard case .atom(let props, let common) = spec.content else { return }
        let children = spec.children.filter { if case .slot = $0.content { false } else { true } }
        next[spec.id] = Sent(type: spec.type, values: PluginNodeProps.typed(props, common).values, events: spec.events.sorted(), children: children.map(\.id))
        children.forEach { collect($0, into: &next) }
    }

    private func emit(_ spec: AtomNodeSpec, next: [Int: Sent], into ops: inout [PluginOp]) {
        guard let now = next[spec.id] else { return }
        let old = sent[spec.id]
        if old == nil || old?.type != now.type {
            ops.append(.create(id: spec.id, type: now.type, props: now.values, events: now.events))
        } else if old?.values != now.values || old?.events != now.events {
            ops.append(.update(id: spec.id, props: now.values, events: now.events))
        }
        for child in spec.children { emit(child, next: next, into: &ops) }
        if old?.children != now.children {
            // Appending moves a child to the end, so appending them all in order sets the order.
            for child in now.children { ops.append(.append(parent: spec.id, child: child)) }
        }
    }
}
