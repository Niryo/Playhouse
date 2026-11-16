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
    /// The plugin `open` presented, whose entry shows as selected.
    var openPluginID: String?
    @Environment(PluginRegistry.self) private var registry
    @AppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) private var isAddModeOn = false

    var body: some View {
        let plugins = registry.plugins(for: placement)
        if !plugins.isEmpty || isAddModeOn {
            AtomStack(props: StackProps(axis: placement.isIconOnly ? "h" : "v", spacing: placement.isIconOnly ? 4 : 6), common: AtomCommon(fillWidth: placement.isIconOnly ? nil : true)) {
                ForEach(plugins) { plugin in
                    PluginEntryButton(plugin: plugin, placement: placement, props: props, actions: actions, open: open, isOpen: plugin.id == openPluginID)
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
    /// Its modal, sidebar or page is presented.
    let isOpen: Bool
    @State private var isPopoverPresented = false

    var body: some View {
        let isSelected = isPopoverPresented || isOpen
        AtomButton(
            common: AtomCommon(testID: "plugin-entry-\(plugin.id)", label: plugin.name, help: plugin.name, fillWidth: placement.isIconOnly ? nil : true),
            action: {
                if plugin.presentationKind == .popover { isPopoverPresented.toggle() } else { open(plugin) }
            }
        ) {
            if placement.isIconOnly {
                AtomIcon(props: IconProps(name: plugin.icon, size: 12, weight: "medium", color: isSelected ? "accent" : "secondary"), common: AtomCommon(width: 26, height: 24))
            } else {
                AtomStack(props: StackProps(align: "leading", fill: "accent", fillOpacity: isSelected ? 0.14 : 0, cornerRadius: 8), common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)) {
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
/// over the whole view. An installed plugin's header closes it; a built-in
/// plugin draws its own chrome and closes with `ui.close`.
struct PluginPresentationModifier: ViewModifier {
    @Binding var plugin: PluginRecord?
    let props: (PluginRecord) -> [String: PluginValue]
    let actions: PluginUIActions
    @Environment(PluginRegistry.self) private var registry

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
                ModalProps(isPresented: isPresenting(.modal), width: plugin.map { Double($0.surfaceSize.width) }, height: plugin.map { Double($0.surfaceSize.height) }, inset: 0),
                common: surfaceCommon,
                onDismiss: { plugin = nil }
            ) { surface }
            .atomSidePanel(
                SidePanelProps(isPresented: isPresenting(.sidebar), width: plugin.map { Double($0.surfaceSize.width) } ?? 360),
                common: surfaceCommon
            ) { surface }
            .atomPage(PageProps(isPresented: isPresenting(.page)), common: surfaceCommon) { surface }
            // An open plugin follows its reloaded record (so a saved
            // `state` reaches it); one disabled or deleted while open stops
            // running.
            .onChange(of: registry.plugins) { _, plugins in
                guard let open = plugin else { return }
                let current = plugins.first { $0.id == open.id && $0.isActive }
                if current != open { plugin = current }
            }
    }

    @ViewBuilder
    private var surface: some View {
        if let plugin {
            var surfaceActions = actions
            let _ = surfaceActions.close = { self.plugin = nil }
            PluginPropsScope {
                if plugin.builtIn {
                    BuiltInPluginView(plugin: plugin, props: props(plugin), actions: surfaceActions)
                } else {
                    PluginSurfaceView(plugin: plugin, props: props(plugin), actions: surfaceActions)
                }
            }
        }
    }
}

extension View {
    func pluginPresentation(_ plugin: Binding<PluginRecord?>, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions) -> some View {
        modifier(PluginPresentationModifier(plugin: plugin, props: props, actions: actions))
    }
}

/// One placement's inline plugins (`PluginPresentation.inline`), rendered in
/// place as sections of their sidebar: a built-in plugin's native view, or
/// an installed plugin's atoms without a header.
struct PluginInlineSlot: View {
    let placement: PluginPlacement
    let props: (PluginRecord) -> [String: PluginValue]
    var actions = PluginUIActions()
    /// Set where the slot's view is rebuilt as its context moves (a task
    /// card changing columns), so its installed plugins keep running.
    var keepAliveScope: String?
    @Environment(PluginRegistry.self) private var registry

    var body: some View {
        ForEach(registry.inlinePlugins(for: placement)) { plugin in
            PluginPropsScope {
                if plugin.builtIn {
                    BuiltInPluginView(plugin: plugin, props: props(plugin), actions: actions)
                } else {
                    PluginSurfaceView(plugin: plugin, props: props(plugin), actions: actions, keepAliveKey: keepAliveScope.map { "\(plugin.id):\($0)" })
                }
            }
        }
    }
}

/// Whether a section plugin has anything to show: a section whose plugin
/// renders nothing hides, header included, while it stays mounted to notice
/// when it has something again.
struct PluginSectionContentKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// The bottom of the board's sidebar (`PluginPlacement.mainSidebarBottom`):
/// each section plugin under a collapsible header drawn from the Disclosure
/// atom with the plugin's name, stacked top to bottom under the sidebar's
/// spacer, so expanding a section grows it upward and pushes the sections
/// above it up. In Add Plugin mode its "Add here" placeholder follows them.
struct PluginSectionSlot: View {
    let placement: PluginPlacement
    let props: (PluginRecord) -> [String: PluginValue]
    var actions = PluginUIActions()
    var add: (PluginPlacement) -> Void = { _ in }
    @Environment(PluginRegistry.self) private var registry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(registry.sectionPlugins(for: placement)) { plugin in
                PluginSection(plugin: plugin, props: props, actions: actions)
            }
            // Only the placeholder: no plugin here has an entry button.
            PluginSlot(placement: placement, props: props, actions: actions, add: add)
                .padding(.top, 12)
        }
    }
}

/// One section plugin: the host's header and the plugin's view. The view
/// stays mounted while the section is collapsed (with no height), so the
/// plugin keeps running and its state survives. Whether it is collapsed is
/// the plugin's state `collapsed`, saved with `plugin.state.set`.
private struct PluginSection: View {
    let plugin: PluginRecord
    let props: (PluginRecord) -> [String: PluginValue]
    let actions: PluginUIActions
    /// The toggle's value until the saved state catches up.
    @State private var pendingCollapsed: Bool?
    @State private var hasContent = false

    private var savedCollapsed: Bool { plugin.state["collapsed"] == .bool(true) }
    private var isCollapsed: Bool { pendingCollapsed ?? savedCollapsed }

    var body: some View {
        let collapsed = isCollapsed
        VStack(alignment: .leading, spacing: 0) {
            if hasContent {
                AtomDisclosure(
                    props: DisclosureProps(title: plugin.name, collapsed: collapsed, toggleTestID: "plugin-section-\(plugin.id)-toggle"),
                    onToggle: { toggle(to: !collapsed) }
                ) {}
            }
            PluginPropsScope {
                if plugin.builtIn {
                    BuiltInPluginView(plugin: plugin, props: props(plugin), actions: actions)
                } else {
                    PluginSurfaceView(plugin: plugin, props: props(plugin), actions: actions)
                }
            }
            .padding(.top, 6)
            .frame(height: collapsed || !hasContent ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(collapsed || !hasContent ? 0 : 1)
            .allowsHitTesting(!collapsed && hasContent)
            .accessibilityHidden(collapsed || !hasContent)
        }
        .padding(.top, hasContent ? 12 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-section-\(plugin.id)")
        // A section with nothing to show is not there at all.
        .accessibilityHidden(!hasContent)
        .onPreferenceChange(PluginSectionContentKey.self) { hasContent = $0 }
        .onChange(of: savedCollapsed) { pendingCollapsed = nil }
    }

    private func toggle(to collapsed: Bool) {
        pendingCollapsed = collapsed
        let host = PluginHost(plugin: plugin, actions: actions)
        Task { @MainActor in
            do {
                try await host.call("bridge", "plugin.state.set", ["pluginID": .string(plugin.id), "key": .string("collapsed"), "value": .bool(collapsed)])
            } catch {
                PlayhouseDiagnostics.record("plugin.section.toggle.failed", fields: ["pluginID": plugin.id, "error": error.localizedDescription])
                pendingCollapsed = nil
            }
        }
    }
}
