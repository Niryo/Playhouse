import SwiftUI

/// Every atom a plugin may create, registered by name. Each entry decodes the
/// node's props from its op payload and builds the same view native code
/// uses; children render through `PluginChildren`, events go back to the
/// plugin's handlers through its runtime.
@MainActor
enum AtomRegistry {
    typealias Builder = (PluginNode, PluginRuntime) throws -> AnyView

    static let builders: [String: Builder] = {
        var builders: [String: Builder] = [:]
        func register(_ type: AtomType, _ builder: @escaping Builder) {
            builders[type.rawValue] = builder
        }
        register(.stack) { node, runtime in
            AnyView(AtomStack(props: try .decode(node.props), common: try .decode(node.props)) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.text) { node, _ in
            AnyView(AtomText(props: try .decode(node.props), common: try .decode(node.props), children: node.joinedText))
        }
        register(.icon) { node, _ in
            AnyView(AtomIcon(props: try .decode(node.props), common: try .decode(node.props)))
        }
        register(.label) { node, _ in
            AnyView(AtomLabel(props: try .decode(node.props), common: try .decode(node.props)))
        }
        register(.button) { node, runtime in
            AnyView(AtomButton(props: try .decode(node.props), common: try .decode(node.props), action: {
                runtime.dispatch(nodeID: node.id, event: "onPress")
            }) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.link) { node, runtime in
            AnyView(AtomLink(props: try .decode(node.props), common: try .decode(node.props)) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.spinner) { node, _ in
            AnyView(AtomSpinner(props: try .decode(node.props), common: try .decode(node.props)))
        }
        register(.spacer) { node, _ in
            AnyView(AtomSpacer(props: try .decode(node.props)))
        }
        register(.pillPicker) { node, runtime in
            AnyView(AtomPillPicker(props: try .decode(node.props), common: try .decode(node.props)) { value in
                runtime.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            })
        }
        register(.card) { node, runtime in
            AnyView(AtomCard(props: try .decode(node.props), common: try .decode(node.props), onPress: {
                runtime.dispatch(nodeID: node.id, event: "onPress")
            }, onMenu: { id in
                runtime.dispatch(nodeID: node.id, event: "onMenu", value: .string(id))
            }) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.disclosure) { node, runtime in
            AnyView(AtomDisclosure(props: try .decode(node.props), common: try .decode(node.props), onToggle: {
                runtime.dispatch(nodeID: node.id, event: "onToggle")
            }) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.panel) { node, runtime in
            AnyView(AtomPanel(props: try .decode(node.props), common: try .decode(node.props)) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.meter) { node, _ in
            AnyView(AtomMeter(props: try .decode(node.props), common: try .decode(node.props)))
        }
        assert(Set(builders.keys) == Set(AtomType.allCases.map(\.rawValue)), "Every atom needs exactly one registry entry.")
        return builders
    }()

    static func view(for node: PluginNode, runtime: PluginRuntime) -> AnyView {
        do {
            guard let builder = builders[node.type] else {
                throw PluginTreeError(message: "Unknown atom <\(node.type)>.")
            }
            return try builder(node, runtime)
        } catch {
            return AnyView(Text(error.localizedDescription)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .accessibilityIdentifier("plugin-node-error"))
        }
    }
}

/// One node of a plugin's tree. Its body reads only this node's props, so an
/// op that changes another node never re-evaluates it.
struct PluginNodeView: View {
    let node: PluginNode
    let runtime: PluginRuntime

    var body: some View {
        AtomRegistry.view(for: node, runtime: runtime)
    }
}

/// A node's atom children, in order. Raw text nodes are part of their Text atom.
struct PluginChildren: View {
    let node: PluginNode
    let runtime: PluginRuntime

    var body: some View {
        ForEach(node.children.filter { $0.type != PluginNode.textType }) { child in
            PluginNodeView(node: child, runtime: runtime)
        }
    }
}
