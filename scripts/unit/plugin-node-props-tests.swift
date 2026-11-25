import Foundation
import Observation

// Checks of how plugin nodes hold their props, compiled with Playhouse/App/Plugins/Core (with
// PLAYHOUSE_ATOM_BENCHMARK, for the decode counter) and run by scripts/test-e2e.sh before the bridge suite: a plugin's dictionary props are decoded once per
// create or update op and never when the node is read; native typed props are never decoded;
// a decoding error is computed when the op applies; and the props structs round-trip through
// Codable; and a native tree's events reach its Swift handlers. scripts/benchmark-atom-tree.sh
// renders both kinds through AtomRegistry.

@main
struct PluginNodePropsTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected { failures.append("\(message): expected \(expected), got \(actual)") }
    }

    static func meter(_ node: PluginNode?) -> MeterProps? {
        guard case .success(let resolved)? = node?.resolved else { return nil }
        return resolved.atom as? MeterProps
    }

    static func error(_ node: PluginNode?) -> String? {
        guard case .failure(let error)? = node?.resolved else { return nil }
        return error.message
    }

    /// Whether reading `read` registers a dependency that `change` then fires.
    static func notifies(_ read: () -> Void, after change: () -> Void) -> Bool {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking(read) { flag.fired = true }
        change()
        return flag.fired
    }

    static func main() {
        // A plugin's ops, validated as the runtime validates them: one decode of the atom's
        // props and one of the common props per create or update, none per read.
        let tree = PluginNodeTree()
        tree.validate = AtomType.validate
        tree.validateChild = AtomType.validateChild
        var before = AtomCounters.decodes
        try! tree.apply([
            .create(id: 1, type: "Meter", props: ["fraction": .number(0.25), "testID": .string("m")], events: []),
            .append(parent: 0, child: 1),
        ])
        expect(AtomCounters.decodes - before, 2, "A create decodes the atom's props and the common props once")
        before = AtomCounters.decodes
        for _ in 0..<100 { _ = tree.node(1)?.resolved }
        expect(AtomCounters.decodes - before, 0, "Reading a node's props never decodes")
        expect(meter(tree.node(1))?.fraction, 0.25, "The decoded props are stored on the node")
        expect(tree.node(1)?.common?.testID, "m", "The decoded common props are stored on the node")
        expect(PluginRenderCommand.find(testID: "m", in: tree.root)?.id, 1, "plugin render finds a node by its decoded testID")

        before = AtomCounters.decodes
        try! tree.apply([.update(id: 1, props: ["fraction": .number(0.5), "testID": .string("m")], events: [])])
        expect(AtomCounters.decodes - before, 2, "An update decodes once")
        expect(meter(tree.node(1))?.fraction, 0.5, "An update replaces the decoded props")
        expect(tree.node(1)?.updateCount, 1, "An update is counted")

        // An update that changes nothing leaves the node's observers alone.
        expect(notifies({ _ = tree.node(1)?.resolved }, after: {
            try! tree.apply([.update(id: 1, props: ["fraction": .number(0.5), "testID": .string("m")], events: [])])
        }), false, "An unchanged update doesn't invalidate the node")
        expect(notifies({ _ = tree.node(1)?.resolved }, after: {
            try! tree.apply([.update(id: 1, props: ["fraction": .number(0.75)], events: [])])
        }), true, "A changed update invalidates the node")

        // Validation still rejects an invalid op before it changes the node.
        do {
            try tree.apply([.update(id: 1, props: ["fraction": .string("half")], events: [])])
            failures.append("An invalid prop must reject the op")
        } catch {
            expect(error.localizedDescription, "<Meter> has an invalid prop: fraction: expected a number, found a string", "The op's error names the prop")
        }
        expect(meter(tree.node(1))?.fraction, 0.75, "A rejected op leaves the node's props")
        do {
            try tree.apply([.update(id: 1, props: ["fraction": .number(1), "bogus": .bool(true)], events: [])])
            failures.append("An unknown prop must reject the op")
        } catch {
            expect(error.localizedDescription, "<Meter> has no prop \"bogus\".", "An unknown prop is rejected")
        }

        // Without validation the error is computed when the op applies, and kept for the view.
        let lenient = PluginNodeTree()
        before = AtomCounters.decodes
        try! lenient.apply([.create(id: 1, type: "Meter", props: ["fraction": .string("half")], events: [])])
        let decodedAtCreate = AtomCounters.decodes - before
        expect(decodedAtCreate > 0, true, "An unvalidated create decodes when it applies")
        before = AtomCounters.decodes
        expect(error(lenient.node(1)), "<Meter> has an invalid prop: fraction: expected a number, found a string", "The decoding error is stored on the node")
        expect(AtomCounters.decodes - before, 0, "Reading the error doesn't decode")
        try! lenient.apply([.create(id: 2, type: "Bogus", props: [:], events: [])])
        expect(error(lenient.node(2)), "Unknown atom <Bogus>.", "An unknown atom is an error on the node")

        // Native typed props: no dictionary and no decoding, for creating or updating.
        before = AtomCounters.decodes
        let typed = PluginNode(id: 7, props: MeterProps(fraction: 0.4, color: "green"), common: AtomCommon(testID: "typed-meter", width: 80))
        expect(typed.type, "Meter", "A typed node takes its atom from its props type")
        expect(meter(typed), MeterProps(fraction: 0.4, color: "green"), "A typed node holds its props as given")
        expect(typed.common?.width, 80, "A typed node holds its common props as given")
        expect(typed.setProps(MeterProps(fraction: 0.4, color: "green"), common: AtomCommon(testID: "typed-meter", width: 80)), false,
               "Setting equal typed props changes nothing")
        expect(notifies({ _ = typed.resolved }, after: {
            typed.setProps(MeterProps(fraction: 0.9, color: "green"), common: AtomCommon(testID: "typed-meter", width: 80))
        }), true, "Setting new typed props invalidates the node")
        expect(meter(typed)?.fraction, 0.9, "Setting typed props replaces them")
        let column = PluginNode(id: 8, props: StackProps(axis: "v", spacing: 4))
        column.children = [typed, PluginNode(id: 9, props: TextProps(text: "Tokens", size: 11))]
        expect(AtomCounters.decodes - before, 0, "Typed nodes never decode")

        // Typed props serialize to the dictionary a plugin would send, which decodes back to them.
        let values = typed.props.values
        expect(values, ["fraction": .number(0.9), "color": .string("green"), "testID": .string("typed-meter"), "width": .number(80)],
               "Typed props encode to plugin values")
        let snapshot = PluginNodeTree().snapshot(column)
        expect(snapshot.object?["children"]?.array?.first?.object?["props"], .object(values), "A snapshot shows a typed node's props")
        let card = CardProps(menu: [.init(id: "open", title: "Open", icon: "arrow.up.right", destructive: false)], meter: 0.3)
        let picker = PillPickerProps(options: [.init(value: "a", label: "A", help: "First")], selected: "a")
        let stack = StackProps(axis: "h", fill: "accent", dash: [2, 3], scrollID: "top")
        let modal = ModalProps(isPresented: true, width: 500, title: "Stats")
        let roundTrips: [(any AtomProps, AtomCommon)] = [
            (card, AtomCommon(label: "L", padding: 4)), (picker, AtomCommon(label: "L", padding: 4)), (stack, AtomCommon(label: "L", padding: 4)),
            (MeterProps(fraction: 1), AtomCommon(label: "L", padding: 4)), (DividerProps(), AtomCommon(label: "L", padding: 4)),
            (MenuProps(icon: "gear", items: [[.init(id: "x", title: "X", checked: true)]]), AtomCommon(label: "L", padding: 4)),
            // A Modal's width is also the common width, as one plugin key sets both.
            (modal, AtomCommon(label: "L", width: 500)),
            (SidePanelProps(isPresented: false, edge: "leading", width: 300), AtomCommon(label: "L", width: 300)),
        ]
        expect(PluginNodeProps.conflictingKeys(modal, AtomCommon(width: 300)), ["width"], "Typed props that disagree on a shared key are caught")
        expect(PluginNodeProps.conflictingKeys(modal, AtomCommon(width: 500, padding: 2)), [], "Typed props that agree on a shared key are fine")
        expect(PluginNodeProps.conflictingKeys(modal, AtomCommon()), ["width"], "A shared key set on one side only is caught")
        expect(PluginNodeProps.conflictingKeys(ModalProps(isPresented: false), AtomCommon(height: 200)), ["height"], "A shared key set only in the common props is caught")
        for (props, common) in roundTrips {
            let node = PluginNode(id: 20, props: props, common: common)
            let decoded = PluginNode(id: 21, type: node.type, props: node.props.values)
            guard case .success(let back) = decoded.resolved else {
                failures.append("<\(node.type)>'s encoded props don't decode: \(error(decoded) ?? "")")
                continue
            }
            expect(back.atom.isEqual(to: props), true, "<\(node.type)>'s props round-trip through Codable")
            expect(back.common, common, "<\(node.type)>'s common props round-trip")
        }
        for atom in AtomType.allCases {
            expect(atom.propsType.atomType, atom, "\(atom.rawValue)'s props type names it")
        }

        // A native tree's events reach the Swift handlers registered for each node and event,
        // through the same protocol a plugin's runtime implements, with no JavaScript, and
        // registering a handler is what lists the event on the node.
        let handlers = AtomEventHandlers()
        let cardNode = PluginNode(id: 3, props: CardProps())
        let field = PluginNode(id: 4, props: TextFieldProps(text: ""))
        var received: [String] = []
        handlers.on(cardNode, "onPress") { value in received.append("press:\(value == nil)") }
        handlers.on(cardNode, "onMenu") { value in received.append("menu:\(value?.string ?? "")") }
        handlers.on(field, "onSubmit") { _ in received.append("submit") }
        expect(cardNode.events, ["onPress", "onMenu"], "Registering handlers lists their events on the node")
        expect(field.events, ["onSubmit"], "A field with a Return handler lists onSubmit, so the atom takes Return")
        let events: any AtomEventHandler = handlers
        expect(events.dispatch(nodeID: 3, event: "onPress", value: nil), true, "A registered press is handled")
        expect(events.dispatch(nodeID: 3, event: "onMenu", value: .string("archive")), true, "A registered menu choice is handled")
        expect(events.dispatch(nodeID: 4, event: "onSubmit", value: nil), true, "A registered submit is handled")
        expect(events.dispatch(nodeID: 4, event: "onChange", value: .string("x")), false, "An event the node has no handler for is not handled")
        expect(events.dispatch(nodeID: 9, event: "onPress", value: nil), false, "An event for an unknown node is not handled")
        expect(received, ["press:true", "menu:archive", "submit"], "Each handler gets its own event and payload")
        handlers.on(cardNode, "onPress") { _ in received.append("press again") }
        handlers.dispatch(nodeID: 3, event: "onPress", value: nil)
        expect(received.last, "press again", "Registering a handler again replaces the earlier one")
        handlers.remove(cardNode, "onMenu")
        expect(handlers.dispatch(nodeID: 3, event: "onMenu", value: .string("x")), false, "A removed handler is not called")
        expect(cardNode.events, ["onPress"], "Removing a handler unlists its event")
        expect(handlers.dispatch(nodeID: 3, event: "onPress", value: nil), true, "Removing one event keeps the node's others")
        handlers.remove(field)
        expect(handlers.dispatch(nodeID: 4, event: "onSubmit", value: nil), false, "Removing a node drops all of its handlers")
        expect(field.events, [], "Removing a node's handlers unlists all of its events")

        if failures.isEmpty {
            print("Plugin node props tests: \(checks) checks passed")
        } else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }
}
