import Foundation

/// The Plugin Catalog's Task Item demo as a native atom tree (the atom-tree
/// spike): the catalog's sample card from `TaskItemTree`, with the demo's
/// Block toggle and its readouts, all one typed tree native Swift keeps in
/// step (no JavaScript). The catalog's page draws it beside the JavaScript and
/// native SwiftUI items, and `plugin render --page TaskItem --renderer
/// native-tree` runs it headlessly, reporting which nodes each step changed.
/// Its identifiers carry a "tree-" prefix, so they never clash with the other two.
final class TaskItemTreeDemo {
    struct Sample: Decodable {
        var task: TaskItemModel
        var blockedStatusMessage: String
    }

    enum ID {
        static let root = 300, controls = 301, toggle = 302, toggleLabel = 303, opened = 304, lastAction = 305
    }

    let sample: Sample
    let tree = TypedAtomTree()
    private(set) var blocked = false
    private(set) var opened = 0
    private(set) var lastAction = "none"
    /// The nodes the last render created or changed.
    private(set) var changed: [Int] = []
    /// Called after an event re-rendered the tree.
    var onChange: () -> Void = {}

    /// The catalog's sample props (`catalog/sample-task.json`).
    init(props: [String: PluginValue]) throws {
        sample = try PluginValueDecoder.decode(Sample.self, from: .object(props))
        tree.onEvent = { [weak self] id, event, value in self?.handle(id, event, value) }
        render()
    }

    var model: TaskItemModel {
        var task = sample.task
        task.id = "tree-\(task.id)"
        if blocked {
            task.statusMessage = sample.blockedStatusMessage
            task.statusIsBlocked = true
        }
        return task
    }

    var root: PluginNode? { tree.root }

    func spec(now: Date = Date()) -> AtomNodeSpec {
        AtomNodeSpec(TaskItemTreeDemo.ID.root, StackProps(axis: "v", spacing: 12, align: "leading"), children: [
            TaskItemTree.spec(model: model, now: now),
            AtomNodeSpec(ID.controls, StackProps(axis: "h", spacing: 8), children: [
                AtomNodeSpec(ID.toggle, ButtonProps(style: "borderless"), AtomCommon(testID: "tree-toggle-blocked"), events: ["onPress"], children: [
                    AtomNodeSpec(ID.toggleLabel, TextProps(text: blocked ? "Unblock" : "Block", size: 11, weight: "medium", color: "accent")),
                ]),
                AtomNodeSpec(ID.opened, TextProps(text: "Opened \(opened) times", size: 11, color: "secondary"), AtomCommon(testID: "tree-opened-count")),
                AtomNodeSpec(ID.lastAction, TextProps(text: "Last: \(lastAction)", size: 11, color: "secondary"), AtomCommon(testID: "tree-last-action")),
            ]),
        ])
    }

    @discardableResult
    func render() -> [Int] {
        changed = tree.apply(spec())
        return changed
    }

    private func handle(_ id: Int, _ event: String, _ value: PluginValue?) {
        switch (id, event) {
        case (TaskItemTree.ID.card, "onPress"): opened += 1
        case (TaskItemTree.ID.card, "onMenu"): lastAction = "menu \(value?.string ?? "")"
        case (TaskItemTree.ID.tokenButton, "onPress"): lastAction = "token stats"
        case (ID.toggle, "onPress"): blocked.toggle()
        default: return
        }
        render()
        onChange()
    }

    /// Runs the demo headlessly for `plugin render --page TaskItem --renderer
    /// native-tree`: each event is `<testID>:<event>[:<value>]`, sent to the atom
    /// with that testID. Reports the final tree and, per step, the nodes it changed.
    static func run(props: [String: PluginValue], events: [PluginRenderCommand.Event]) throws -> PluginValue {
        let demo = try TaskItemTreeDemo(props: props)
        func number(_ ids: [Int]) -> PluginValue { .array(ids.map { .number(Double($0)) }) }
        var commits: [PluginValue] = [.object(["step": .string("render"), "changedNodes": number(demo.changed)])]
        for event in events {
            guard case .atom(let testID, let name, let value) = event else {
                throw PluginTreeError(message: "The native tree takes only atom events (<testID>:<event>[:<value>]).")
            }
            guard let root = demo.root, let node = PluginRenderCommand.find(testID: testID, in: root) else {
                throw PluginTreeError(message: "No atom has testID \"\(testID)\".")
            }
            guard node.events.contains(name) else {
                throw PluginTreeError(message: "<\(node.type)> \(testID) has no \(name) handler.")
            }
            demo.tree.handlers.dispatch(nodeID: node.id, event: name, value: value.map(PluginValue.string))
            commits.append(.object(["step": .string("\(testID):\(name)"), "changedNodes": number(demo.changed)]))
        }
        return .object([
            "renderer": .string("native-tree"),
            "commits": .array(commits),
            "tree": demo.root.map { PluginNodeTree().snapshot($0) } ?? .null,
            "errors": .array([]),
        ])
    }
}
