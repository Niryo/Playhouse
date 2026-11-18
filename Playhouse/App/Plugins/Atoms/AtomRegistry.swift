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
        register(.image) { node, _ in
            AnyView(AtomImage(props: try .decode(node.props), common: try .decode(node.props)))
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
        register(.scroll) { node, runtime in
            AnyView(AtomScroll(props: try .decode(node.props), common: try .decode(node.props), onEndReached: node.events.contains("onEndReached") ? {
                runtime.dispatch(nodeID: node.id, event: "onEndReached")
            } : nil) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.divider) { node, _ in
            AnyView(AtomDivider(common: try .decode(node.props)))
        }
        register(.choiceBar) { node, runtime in
            AnyView(AtomChoiceBar(props: try .decode(node.props), common: try .decode(node.props)) { value in
                runtime.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            })
        }
        register(.toggle) { node, runtime in
            AnyView(AtomToggle(props: try .decode(node.props), common: try .decode(node.props)) {
                runtime.dispatch(nodeID: node.id, event: "onToggle")
            })
        }
        register(.textField) { node, runtime in
            // Return and the arrows stay the field's own unless the plugin handles them.
            AnyView(AtomTextField(props: try .decode(node.props), common: try .decode(node.props), onChange: { text in
                runtime.dispatch(nodeID: node.id, event: "onChange", value: .string(text))
            }, onSubmit: node.events.contains("onSubmit") ? {
                runtime.dispatch(nodeID: node.id, event: "onSubmit")
            } : nil, onArrow: node.events.contains("onArrow") ? { direction in
                runtime.dispatch(nodeID: node.id, event: "onArrow", value: .string(direction))
            } : nil))
        }
        register(.segmented) { node, runtime in
            AnyView(AtomSegmented(props: try .decode(node.props), common: try .decode(node.props)) { value in
                runtime.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            })
        }
        register(.menu) { node, runtime in
            AnyView(AtomMenu(props: try .decode(node.props), common: try .decode(node.props)) { id in
                runtime.dispatch(nodeID: node.id, event: "onMenu", value: .string(id))
            })
        }
        register(.pressArea) { node, runtime in
            AnyView(AtomPressArea(props: try .decode(node.props), common: try .decode(node.props), onPress: {
                runtime.dispatch(nodeID: node.id, event: "onPress")
            }, onLongPress: {
                runtime.dispatch(nodeID: node.id, event: "onLongPress")
            }) {
                PluginChildren(node: node, runtime: runtime)
            })
        }
        register(.editor) { node, runtime in
            AnyView(AtomEditor(props: try .decode(node.props), common: try .decode(node.props), onChange: { text in
                runtime.dispatch(nodeID: node.id, event: "onChange", value: .string(text))
            }, onSubmit: {
                runtime.dispatch(nodeID: node.id, event: "onSubmit")
            }, onSteerSubmit: {
                runtime.dispatch(nodeID: node.id, event: "onSteerSubmit")
            }, onFocusChange: { focused in
                runtime.dispatch(nodeID: node.id, event: "onFocusChange", value: .bool(focused))
            }))
        }
        register(.popover) { node, runtime in
            let children = node.children.filter { $0.type != PluginNode.textType }
            let props: PopoverProps = try .decode(node.props)
            return AnyView(AtomPopover(props: props, common: try .decode(node.props), onDismiss: {
                runtime.dispatch(nodeID: node.id, event: "onDismiss")
            }, anchor: {
                if let anchor = children.first { PluginNodeView(node: anchor, runtime: runtime) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: CGFloat(props.spacing ?? PopoverProps.defaultSpacing), runtime: runtime)
            }))
        }
        register(.modal) { node, runtime in
            let children = node.children.filter { $0.type != PluginNode.textType }
            let props: ModalProps = try .decode(node.props)
            return AnyView(AtomModal(props: props, common: try .decode(node.props), onDismiss: {
                runtime.dispatch(nodeID: node.id, event: "onDismiss")
            }, base: {
                if let base = children.first { PluginNodeView(node: base, runtime: runtime) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: CGFloat(props.spacing ?? ModalProps.defaultSpacing), runtime: runtime)
            }))
        }
        register(.page) { node, runtime in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AnyView(AtomPage(props: try .decode(node.props), common: try .decode(node.props), base: {
                if let base = children.first { PluginNodeView(node: base, runtime: runtime) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: 0, runtime: runtime)
            }))
        }
        register(.sidePanel) { node, runtime in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AnyView(AtomSidePanel(props: try .decode(node.props), common: try .decode(node.props), base: {
                if let base = children.first { PluginNodeView(node: base, runtime: runtime) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: 0, runtime: runtime)
            }))
        }
        register(.stepSlider) { node, runtime in
            AnyView(AtomStepSlider(props: try .decode(node.props), common: try .decode(node.props)) { value in
                runtime.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            })
        }
        register(.overlay) { node, runtime in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AnyView(AtomOverlay(props: try .decode(node.props), common: try .decode(node.props)) {
                if let base = children.first { PluginNodeView(node: base, runtime: runtime) }
            } overlay: {
                ForEach(children.dropFirst()) { child in
                    PluginNodeView(node: child, runtime: runtime)
                }
            })
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

/// What a Popover, Modal, Page or SidePanel presents: every child after the
/// first, in a leading column.
struct PresentedChildren: View {
    let children: [PluginNode]
    let spacing: CGFloat
    let runtime: PluginRuntime

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(children) { child in
                PluginNodeView(node: child, runtime: runtime)
            }
        }
    }
}
