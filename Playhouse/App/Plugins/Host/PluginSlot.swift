import SwiftUI

/// One plugin placement, composed only of atoms: the entry buttons of the
/// plugins installed there and, in Add Plugin mode, the highlighted "Add here"
/// placeholder. A popover plugin opens anchored to its button; the others ask
/// the owner (`open`) to present them.
struct PluginSlot: View {
    let placement: PluginPlacement
    /// The context the placement hands a plugin.
    let props: (PluginRecord) -> [String: PluginValue]
    var actions = PluginUIActions()
    /// Presents a modal, sidebar or page plugin.
    var open: (PluginRecord) -> Void = { _ in }
    /// The "Add here" placeholder was pressed.
    var add: (PluginPlacement) -> Void = { _ in }
    @Environment(PluginRegistry.self) private var registry
    @AppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) private var isAddModeOn = false

    var body: some View {
        let plugins = registry.plugins(for: placement)
        if !plugins.isEmpty || isAddModeOn {
            AtomStack(props: StackProps(axis: placement.isIconOnly ? "h" : "v", spacing: placement.isIconOnly ? 4 : 6), common: AtomCommon(fillWidth: placement.isIconOnly ? nil : true)) {
                ForEach(plugins) { plugin in
                    PluginEntryButton(plugin: plugin, placement: placement, props: props, actions: actions, open: open)
                }
                if isAddModeOn {
                    placeholder
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        let common = AtomCommon(testID: "plugin-add-here-\(placement.rawValue)", label: "Add here", help: "Add a plugin to the \(placement.title)", fillWidth: placement.isIconOnly ? nil : true)
        AtomButton(common: common, action: { add(placement) }) {
            if placement.isIconOnly {
                AtomStack(props: StackProps(fill: "accent", fillOpacity: 0.14, cornerRadius: 5, stroke: "accent", dash: [3, 2]), common: AtomCommon(width: 26, height: 24)) {
                    AtomIcon(props: IconProps(name: "plus.square.dashed", size: 12, weight: "semibold", color: "accent"))
                }
            } else {
                AtomStack(props: StackProps(align: "leading", fill: "accent", fillOpacity: 0.12, cornerRadius: 8, stroke: "accent", dash: [4, 3]), common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)) {
                    AtomLabel(props: LabelProps(text: "Add here", icon: "plus.square.dashed", size: 12, weight: "semibold", color: "accent"))
                }
            }
        }
    }
}

/// An installed plugin's button at its placement.
private struct PluginEntryButton: View {
    let plugin: PluginRecord
    let placement: PluginPlacement
    let props: (PluginRecord) -> [String: PluginValue]
    let actions: PluginUIActions
    let open: (PluginRecord) -> Void
    @State private var isPopoverPresented = false

    var body: some View {
        AtomButton(
            common: AtomCommon(testID: "plugin-entry-\(plugin.id)", label: plugin.name, help: plugin.name, fillWidth: placement.isIconOnly ? nil : true),
            action: {
                if plugin.presentationKind == .popover { isPopoverPresented.toggle() } else { open(plugin) }
            }
        ) {
            if placement.isIconOnly {
                AtomIcon(props: IconProps(name: plugin.icon, size: 12, weight: "medium", color: isPopoverPresented ? "accent" : "secondary"), common: AtomCommon(width: 26, height: 24))
            } else {
                AtomStack(props: StackProps(align: "leading", fill: "accent", fillOpacity: isPopoverPresented ? 0.14 : 0, cornerRadius: 8), common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)) {
                    AtomLabel(props: LabelProps(text: plugin.name, icon: plugin.icon, size: 12, weight: "medium"))
                }
            }
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: placement == .composerActions ? .top : .trailing) {
            PluginPropsScope {
                PluginSurfaceView(plugin: plugin, props: props(plugin), actions: popoverActions)
                    .frame(width: plugin.surfaceSize.width, height: plugin.surfaceSize.height)
            }
        }
    }

    private var popoverActions: PluginUIActions {
        var popoverActions = actions
        popoverActions.close = { isPopoverPresented = false }
        return popoverActions
    }
}

/// Evaluates `content` in its own body, so the context a plugin reads (such
/// as the composer's draft) re-renders only the plugin's surface.
struct PluginPropsScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// Add Plugin mode's bar across the top of the window, with its Close button.
struct PluginModeBanner: View {
    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 10, fill: "accent", fillOpacity: 0.16), common: AtomCommon(fillWidth: true, paddingX: 16, paddingY: 7)) {
            AtomIcon(props: IconProps(name: "puzzlepiece.extension", size: 12, weight: "semibold", color: "accent"))
            AtomText(
                props: TextProps(text: "Add Plugin mode: press an “Add here” spot to choose where your plugin’s button goes.", size: 12, weight: "medium"),
                common: AtomCommon(testID: "plugin-mode-banner-text")
            )
            AtomSpacer(props: SpacerProps(minLength: 0))
            AtomButton(
                props: ButtonProps(style: "bordered", controlSize: "small"),
                common: AtomCommon(testID: "plugin-mode-close", label: "Close Add Plugin mode", help: "Leave Add Plugin mode"),
                action: { PluginRegistry.setAddMode(false) }
            ) {
                AtomText(props: TextProps(text: "Close", size: 11, weight: "medium"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-mode-banner")
    }
}

/// A modal, sidebar or page plugin opened from a placement, composed from the
/// Modal, SidePanel and Page presentation atoms over the view that owns the
/// placement: a sheet, a panel sliding in from the trailing edge, or a page
/// over the whole view. The plugin's own header closes it.
struct PluginPresentationModifier: ViewModifier {
    @Binding var plugin: PluginRecord?
    let props: (PluginRecord) -> [String: PluginValue]
    let actions: PluginUIActions

    private func isPresenting(_ kind: PluginPresentation) -> Bool {
        plugin?.presentationKind == kind
    }

    /// The presented container takes the atom's identifier, so it carries the
    /// plugin surface's, as a popover's surface does.
    private var surfaceCommon: AtomCommon {
        AtomCommon(testID: plugin.map { "plugin-surface-\($0.id)" })
    }

    func body(content: Content) -> some View {
        content
            .atomModal(
                ModalProps(isPresented: isPresenting(.modal), width: plugin.map { Double($0.surfaceSize.width) }, height: plugin.map { Double($0.surfaceSize.height) }),
                common: surfaceCommon,
                onDismiss: { plugin = nil }
            ) { surface }
            .atomSidePanel(
                SidePanelProps(isPresented: isPresenting(.sidebar), width: plugin.map { Double($0.surfaceSize.width) } ?? 360),
                common: surfaceCommon
            ) { surface }
            .atomPage(PageProps(isPresented: isPresenting(.page)), common: surfaceCommon) { surface }
    }

    @ViewBuilder
    private var surface: some View {
        if let plugin {
            var surfaceActions = actions
            let _ = surfaceActions.close = { self.plugin = nil }
            PluginPropsScope {
                PluginSurfaceView(plugin: plugin, props: props(plugin), actions: surfaceActions)
            }
        }
    }
}

extension View {
    func pluginPresentation(_ plugin: Binding<PluginRecord?>, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions) -> some View {
        modifier(PluginPresentationModifier(plugin: plugin, props: props, actions: actions))
    }
}
