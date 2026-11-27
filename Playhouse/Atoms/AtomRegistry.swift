import Foundation
import PlayhouseCore
import PlayhouseUI

/// Every atom a plugin may create, registered by its props type. Each entry
/// builds the same view native code uses from the props the node stores,
/// decoded once from a plugin's op or typed by native Swift code, so both take
/// the one entry and rendering never decodes; children render through
/// `PluginChildren`, and events go to the tree's `AtomEventHandler`: a
/// plugin's runtime, or the handlers native code registers.
@MainActor
package enum AtomRegistry {
    package typealias Builder = (PluginNode, ResolvedAtomProps, any AtomEventHandler) throws -> PHAnyView

    package static let builders: [String: Builder] = {
        var builders: [String: Builder] = [:]
        func register<Props: AtomProps, Content: PHView>(_: Props.Type, _ build: @escaping (PluginNode, Props, AtomCommon, any AtomEventHandler) -> Content) {
            builders[Props.atomType.rawValue] = { node, resolved, events in
                guard let props = resolved.atom as? Props else {
                    throw PluginTreeError(message: "<\(node.type)> holds \(type(of: resolved.atom)), not \(Props.self).")
                }
                return PHAnyView(build(node, props, resolved.common, events))
            }
        }
        register(StackProps.self) { node, props, common, events in
            AtomStack(props: props, common: common, onHover: node.events.contains("onHover") ? { hovering in
                events.dispatch(nodeID: node.id, event: "onHover", value: .bool(hovering))
            } : nil) {
                PluginChildren(node: node, events: events)
            }
        }
        register(TextProps.self) { node, props, common, _ in
            AtomText(props: props, common: common, children: node.joinedText)
        }
        register(MarkdownProps.self) { node, props, common, _ in
            AtomMarkdown(props: props, common: common, children: node.joinedText)
        }
        register(IconProps.self) { node, props, common, _ in
            AtomIcon(props: props, common: common)
        }
        register(ImageProps.self) { node, props, common, _ in
            AtomImage(props: props, common: common)
        }
        register(LabelProps.self) { node, props, common, _ in
            AtomLabel(props: props, common: common)
        }
        register(ButtonProps.self) { node, props, common, events in
            AtomButton(props: props, common: common, action: {
                events.dispatch(nodeID: node.id, event: "onPress", value: nil)
            }) {
                PluginChildren(node: node, events: events)
            }
        }
        register(LinkProps.self) { node, props, common, events in
            AtomLink(props: props, common: common) {
                PluginChildren(node: node, events: events)
            }
        }
        register(SpinnerProps.self) { node, props, common, _ in
            AtomSpinner(props: props, common: common)
        }
        register(SpacerProps.self) { node, props, common, _ in
            AtomSpacer(props: props)
        }
        register(PillPickerProps.self) { node, props, common, events in
            AtomPillPicker(props: props, common: common) { value in
                events.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            }
        }
        register(CardProps.self) { node, props, common, events in
            AtomCard(props: props, common: common, onPress: {
                events.dispatch(nodeID: node.id, event: "onPress", value: nil)
            }, onMenu: { id in
                events.dispatch(nodeID: node.id, event: "onMenu", value: .string(id))
            }) {
                PluginChildren(node: node, events: events)
            }
        }
        register(DisclosureProps.self) { node, props, common, events in
            AtomDisclosure(props: props, common: common, onToggle: {
                events.dispatch(nodeID: node.id, event: "onToggle", value: nil)
            }) {
                PluginChildren(node: node, events: events)
            }
        }
        register(PanelProps.self) { node, props, common, events in
            AtomPanel(props: props, common: common) {
                PluginChildren(node: node, events: events)
            }
        }
        register(MeterProps.self) { node, props, common, _ in
            AtomMeter(props: props, common: common)
        }
        register(ScrollProps.self) { node, props, common, events in
            AtomScroll(props: props, common: common, onEndReached: node.events.contains("onEndReached") ? {
                events.dispatch(nodeID: node.id, event: "onEndReached", value: nil)
            } : nil) {
                PluginChildren(node: node, events: events)
            }
        }
        register(DividerProps.self) { node, props, common, _ in
            AtomDivider(common: common)
        }
        register(ChoiceBarProps.self) { node, props, common, events in
            AtomChoiceBar(props: props, common: common) { value in
                events.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            }
        }
        register(ToggleProps.self) { node, props, common, events in
            AtomToggle(props: props, common: common) {
                events.dispatch(nodeID: node.id, event: "onToggle", value: nil)
            }
        }
        register(TextFieldProps.self) { node, props, common, events in
            // Return and the arrows stay the field's own unless the plugin handles them.
            AtomTextField(props: props, common: common, onChange: { text in
                events.dispatch(nodeID: node.id, event: "onChange", value: .string(text))
            }, onSubmit: node.events.contains("onSubmit") ? {
                events.dispatch(nodeID: node.id, event: "onSubmit", value: nil)
            } : nil, onArrow: node.events.contains("onArrow") ? { direction in
                events.dispatch(nodeID: node.id, event: "onArrow", value: .string(direction))
            } : nil, onEscape: node.events.contains("onEscape") ? {
                events.dispatch(nodeID: node.id, event: "onEscape", value: nil)
            } : nil)
        }
        register(SegmentedProps.self) { node, props, common, events in
            AtomSegmented(props: props, common: common) { value in
                events.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            }
        }
        register(MenuProps.self) { node, props, common, events in
            AtomMenu(props: props, common: common) { id in
                events.dispatch(nodeID: node.id, event: "onMenu", value: .string(id))
            }
        }
        register(PressAreaProps.self) { node, props, common, events in
            AtomPressArea(props: props, common: common, onPress: {
                events.dispatch(nodeID: node.id, event: "onPress", value: nil)
            }, onLongPress: {
                events.dispatch(nodeID: node.id, event: "onLongPress", value: nil)
            }) {
                PluginChildren(node: node, events: events)
            }
        }
        register(EditorProps.self) { node, props, common, events in
            AtomEditor(props: props, common: common, onChange: { text in
                events.dispatch(nodeID: node.id, event: "onChange", value: .string(text))
            }, onSubmit: {
                events.dispatch(nodeID: node.id, event: "onSubmit", value: nil)
            }, onSteerSubmit: {
                events.dispatch(nodeID: node.id, event: "onSteerSubmit", value: nil)
            }, onFocusChange: { focused in
                events.dispatch(nodeID: node.id, event: "onFocusChange", value: .bool(focused))
            })
        }
        register(PopoverProps.self) { node, props, common, events in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AtomPopover(props: props, common: common, onDismiss: {
                events.dispatch(nodeID: node.id, event: "onDismiss", value: nil)
            }, anchor: {
                if let anchor = children.first { PluginNodeView(node: anchor, events: events) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: CGFloat(props.spacing ?? PopoverProps.defaultSpacing), events: events)
            })
        }
        register(ModalProps.self) { node, props, common, events in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AtomModal(props: props, common: common, onDismiss: {
                events.dispatch(nodeID: node.id, event: "onDismiss", value: nil)
            }, base: {
                if let base = children.first { PluginNodeView(node: base, events: events) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: CGFloat(props.spacing ?? ModalProps.defaultSpacing), events: events)
            })
        }
        register(PageProps.self) { node, props, common, events in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AtomPage(props: props, common: common, base: {
                if let base = children.first { PluginNodeView(node: base, events: events) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: 0, events: events)
            })
        }
        register(SidePanelProps.self) { node, props, common, events in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AtomSidePanel(props: props, common: common, base: {
                if let base = children.first { PluginNodeView(node: base, events: events) }
            }, content: {
                PresentedChildren(children: Array(children.dropFirst()), spacing: 0, events: events)
            })
        }
        register(StepSliderProps.self) { node, props, common, events in
            AtomStepSlider(props: props, common: common) { value in
                events.dispatch(nodeID: node.id, event: "onChange", value: .string(value))
            }
        }
        register(OverlayProps.self) { node, props, common, events in
            let children = node.children.filter { $0.type != PluginNode.textType }
            return AtomOverlay(props: props, common: common) {
                if let base = children.first { PluginNodeView(node: base, events: events) }
            } overlay: {
                PHForEach(children.dropFirst()) { child in
                    PluginNodeView(node: child, events: events)
                }
            }
        }
        register(ResizeHandleProps.self) { node, props, common, events in
            AtomResizeHandle(props: props, common: common, onDrag: { translation in
                events.dispatch(nodeID: node.id, event: "onDrag", value: .number(translation))
            }, onDragEnd: {
                events.dispatch(nodeID: node.id, event: "onDragEnd", value: nil)
            })
        }
        register(DatePickerProps.self) { node, props, common, events in
            AtomDatePicker(props: props, common: common) { value in
                events.dispatch(nodeID: node.id, event: "onChange", value: .number(value))
            }
        }
        assert(Set(builders.keys) == Set(AtomType.allCases.map(\.rawValue)), "Every atom needs exactly one registry entry.")
        return builders
    }()

    package static func view(for node: PluginNode, events: any AtomEventHandler) -> PHAnyView {
        do {
            guard let builder = builders[node.type] else {
                throw PluginTreeError(message: "Unknown atom <\(node.type)>.")
            }
            return try builder(node, try node.resolved.get(), events)
        } catch {
            return PHAnyView(PHText(error.localizedDescription)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .accessibilityIdentifier("plugin-node-error"))
        }
    }
}

/// One node of a plugin's tree. Its body reads only this node's props, so an
/// op that changes another node never re-evaluates it.
package struct PluginNodeView: PHView {
    package let node: PluginNode
    package let events: any AtomEventHandler

    package var body: some PHView {
        #if PLAYHOUSE_ATOM_BENCHMARK
        AtomCounters.bodies += 1
        #endif
        return AtomRegistry.view(for: node, events: events)
    }

    package init(node: PluginNode, events: any AtomEventHandler) {
        self.node = node
        self.events = events
    }
}

/// A node's atom children, in order. Raw text nodes are part of their Text atom.
package struct PluginChildren: PHView {
    package let node: PluginNode
    package let events: any AtomEventHandler

    package var body: some PHView {
        PHForEach(node.children.filter { $0.type != PluginNode.textType }) { child in
            PluginNodeView(node: child, events: events)
        }
    }

    package init(node: PluginNode, events: any AtomEventHandler) {
        self.node = node
        self.events = events
    }
}

/// What a Popover, Modal, Page or SidePanel presents: every child after the
/// first, in a leading column.
package struct PresentedChildren: PHView {
    package let children: [PluginNode]
    package let spacing: CGFloat
    package let events: any AtomEventHandler

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: spacing) {
            PHForEach(children) { child in
                PluginNodeView(node: child, events: events)
            }
        }
    }

    package init(children: [PluginNode], spacing: CGFloat, events: any AtomEventHandler) {
        self.children = children
        self.spacing = spacing
        self.events = events
    }
}
