import Foundation
import PlayhouseCore
import PlayhouseAtoms
import PlayhouseUI

/// One plugin placement, composed only of atoms: the entry buttons of the
/// plugins installed there and, in Add Plugin mode, the highlighted "Add here"
/// placeholder. A popover plugin opens anchored to its button; the others ask
/// the owner (`open`) to present them.
package struct PluginSlot: PHView {
    package let placement: PluginPlacement
    /// The context the placement hands a plugin.
    package let props: (PluginRecord) -> [String: PluginValue]
    package var actions = PluginUIActions()
    /// Presents a modal, sidebar or page plugin.
    package var open: (PluginRecord) -> Void = { _ in }
    /// The "Add here" placeholder was pressed.
    package var add: (PluginPlacement) -> Void = { _ in }
    /// The plugin `open` presented, whose entry shows as selected.
    package var openPluginID: String?
    @PHEnvironment(PluginRegistry.self) private var registry
    @PHAppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) private var isAddModeOn = false

    package var body: some PHView {
        let plugins = registry.plugins(for: placement)
        if !plugins.isEmpty || isAddModeOn {
            AtomStack(props: StackProps(axis: placement.isIconOnly ? "h" : "v", spacing: placement.isIconOnly ? 4 : 6), common: AtomCommon(fillWidth: placement.isIconOnly ? nil : true)) {
                PHForEach(plugins) { plugin in
                    PluginEntryButton(plugin: plugin, placement: placement, props: props, actions: actions, open: open, isOpen: plugin.id == openPluginID)
                }
                if isAddModeOn {
                    placeholder
                }
            }
        }
    }

    @PHViewBuilder
    private var placeholder: some PHView {
        let common = AtomCommon(testID: "plugin-add-here-\(placement.rawValue)", label: "Add here", help: "Add a plugin to the \(placement.title)", fillWidth: placement.isIconOnly ? nil : true)
        AtomButton(common: common, action: { add(placement) }) {
            if placement.isIconOnly {
                AtomStack(props: StackProps(fill: "accent", fillOpacity: 0.14, cornerRadius: 5, stroke: "accent", dash: [3, 2]), common: AtomCommon(width: 26, height: 24)) {
                    AtomIcon(props: IconProps(name: PHIcon.plusSquareDashed.name, size: 12, weight: "semibold", color: "accent"))
                }
            } else {
                AtomStack(props: StackProps(align: "leading", fill: "accent", fillOpacity: 0.12, cornerRadius: 8, stroke: "accent", dash: [4, 3]), common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)) {
                    AtomLabel(props: LabelProps(text: "Add here", icon: PHIcon.plusSquareDashed.name, size: 12, weight: "semibold", color: "accent"))
                }
            }
        }
    }

    package init(placement: PluginPlacement, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions = PluginUIActions(), open: @escaping (PluginRecord) -> Void = { _ in }, add: @escaping (PluginPlacement) -> Void = { _ in }, openPluginID: String? = nil) {
        self.placement = placement
        self.props = props
        self.actions = actions
        self.openPluginID = openPluginID
        self.open = open
        self.add = add
    }
}

/// An installed plugin's button at its placement.
private struct PluginEntryButton: PHView {
    let plugin: PluginRecord
    let placement: PluginPlacement
    let props: (PluginRecord) -> [String: PluginValue]
    let actions: PluginUIActions
    let open: (PluginRecord) -> Void
    /// Its modal, sidebar or page is presented.
    let isOpen: Bool
    @PHState private var isPopoverPresented = false
    /// The popover's own `ui.confirm` dialog: one over the window would close it.
    @PHState private var confirmations = PluginConfirmations()

    var body: some PHView {
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
                AtomStack(common: AtomCommon(width: Double(plugin.surfaceSize.width), height: Double(plugin.surfaceSize.height))) {
                    if plugin.builtIn {
                        // A built-in draws its own chrome; the container carries the
                        // surface's identifier, as an installed plugin's surface does.
                        BuiltInPluginView(plugin: plugin, props: props(plugin), actions: popoverActions)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("plugin-surface-\(plugin.id)")
                    } else {
                        PluginSurfaceView(plugin: plugin, props: props(plugin), actions: popoverActions)
                    }
                }
                .modifier(PluginConfirmationModifier(confirmations: confirmations))
            }
        }
        // A question still pending when the popover closes is declined, so its plugin call returns.
        .onChange(of: isPopoverPresented) { _, shown in
            if !shown { confirmations.answer(false) }
        }
    }

    /// Opening a task or a new task leaves the button's view, so the popover closes first,
    /// and a confirmation is asked inside the popover, where the window can ask at all.
    private var popoverActions: PluginUIActions {
        var popoverActions = actions
        popoverActions.close = { isPopoverPresented = false }
        let confirmations = confirmations
        popoverActions.confirm = actions.confirm.map { _ in { await confirmations.ask($0) } }
        let openTask = actions.openTask
        popoverActions.openTask = { id in
            isPopoverPresented = false
            openTask(id)
        }
        popoverActions.newTask = actions.newTask.map { newTask in
            { schedule in
                isPopoverPresented = false
                newTask(schedule)
            }
        }
        return popoverActions
    }
}

/// Evaluates `content` in its own body, so the context a plugin reads (such
/// as the composer's draft) re-renders only the plugin's surface.
package struct PluginPropsScope<Content: PHView>: PHView {
    @PHViewBuilder package let content: () -> Content

    package var body: some PHView { content() }

    package init(@PHViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
}

/// Add Plugin mode's bar across the top of the window, with its Close button.
package struct PluginModeBanner: PHView {
    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 10, fill: "accent", fillOpacity: 0.16), common: AtomCommon(fillWidth: true, paddingX: 16, paddingY: 7)) {
            AtomIcon(props: IconProps(name: PHIcon.puzzlepieceExtension.name, size: 12, weight: "semibold", color: "accent"))
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

    package init() {}
}

/// A modal, sidebar or page plugin opened from a placement, composed from the
/// Modal, SidePanel and Page presentation atoms over the view that owns the
/// placement: a sheet, a panel sliding in from the trailing edge, or a page
/// over the whole view. An installed plugin's header closes it; a built-in
/// plugin draws its own chrome and closes with `ui.close`.
package struct PluginPresentationModifier: PHViewModifier {
    @PHBinding package var plugin: PluginRecord?
    package let props: (PluginRecord) -> [String: PluginValue]
    package let actions: PluginUIActions
    @PHEnvironment(PluginRegistry.self) private var registry

    private func isPresenting(_ kind: PluginPresentation) -> Bool {
        plugin?.presentationKind == kind
    }

    /// The presented container takes the atom's identifier, so it carries the
    /// plugin surface's, as a popover's surface does.
    private var surfaceCommon: AtomCommon {
        AtomCommon(testID: plugin.map { "plugin-surface-\($0.id)" })
    }

    package func body(content: Content) -> some PHView {
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

    @PHViewBuilder
    private var surface: some PHView {
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

    package init(plugin: PHBinding<PluginRecord?>, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions) {
        _plugin = plugin
        self.props = props
        self.actions = actions
    }
}

extension PHView {
    package func pluginPresentation(_ plugin: PHBinding<PluginRecord?>, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions) -> some PHView {
        modifier(PluginPresentationModifier(plugin: plugin, props: props, actions: actions))
    }
}

/// One placement's inline plugins (`PluginPresentation.inline`), rendered in
/// place as sections of their sidebar: a built-in plugin's native view, or
/// an installed plugin's atoms without a header.
package struct PluginInlineSlot: PHView {
    package let placement: PluginPlacement
    package let props: (PluginRecord) -> [String: PluginValue]
    package var actions = PluginUIActions()
    /// Set where the slot's view is rebuilt as its context moves (a task
    /// card changing columns), so its installed plugins keep running.
    package var keepAliveScope: String?
    @PHEnvironment(PluginRegistry.self) private var registry

    package var body: some PHView {
        PHForEach(registry.inlinePlugins(for: placement)) { plugin in
            PluginPropsScope {
                if plugin.builtIn {
                    BuiltInPluginView(plugin: plugin, props: props(plugin), actions: actions)
                } else {
                    PluginSurfaceView(plugin: plugin, props: props(plugin), actions: actions, keepAliveKey: keepAliveScope.map { "\(plugin.id):\($0)" })
                }
            }
        }
    }

    package init(placement: PluginPlacement, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions = PluginUIActions(), keepAliveScope: String? = nil) {
        self.placement = placement
        self.props = props
        self.actions = actions
        self.keepAliveScope = keepAliveScope
    }
}

/// Whether a section plugin has anything to show: a section whose plugin
/// renders nothing hides, header included, while it stays mounted to notice
/// when it has something again.
package struct PluginSectionContentKey: PHPreferenceKey {
    package static let defaultValue = true

    package static func reduce(value: inout Bool, nextValue: () -> Bool) {
        // Wrapping a plugin can contribute default values; only the plugin's
        // explicit report can hide its section.
        value = nextValue() && value
    }

    package init() {}
}

/// The bottom of the board's sidebar (`PluginPlacement.mainSidebarBottom`):
/// each section plugin under a collapsible header drawn from the Disclosure
/// atom with the plugin's name, stacked top to bottom under the sidebar's
/// spacer, so expanding a section grows it upward and pushes the sections
/// above it up. In Add Plugin mode its "Add here" placeholder follows them.
package struct PluginSectionSlot: PHView {
    package let placement: PluginPlacement
    package let props: (PluginRecord) -> [String: PluginValue]
    package var actions = PluginUIActions()
    package var add: (PluginPlacement) -> Void = { _ in }
    @PHEnvironment(PluginRegistry.self) private var registry

    package var body: some PHView {
        AtomStack(props: StackProps(spacing: 0, align: "leading")) {
            PHForEach(registry.sectionPlugins(for: placement)) { plugin in
                PluginSection(plugin: plugin, props: props, actions: actions)
            }
            // Only the placeholder: no plugin here has an entry button.
            AtomStack(common: AtomCommon(paddingTop: 12)) {
                PluginSlot(placement: placement, props: props, actions: actions, add: add)
            }
        }
    }

    package init(placement: PluginPlacement, props: @escaping (PluginRecord) -> [String: PluginValue], actions: PluginUIActions = PluginUIActions(), add: @escaping (PluginPlacement) -> Void = { _ in }) {
        self.placement = placement
        self.props = props
        self.actions = actions
        self.add = add
    }
}

/// One section plugin: the host's header and the plugin's view. The view
/// stays mounted while the section is collapsed (with no height), so the
/// plugin keeps running and its state survives. Whether it is collapsed is
/// the plugin's state `collapsed`, saved with `plugin.state.set`.
private struct PluginSection: PHView {
    let plugin: PluginRecord
    let props: (PluginRecord) -> [String: PluginValue]
    let actions: PluginUIActions
    /// The toggle's value until the saved state catches up.
    @PHState private var pendingCollapsed: Bool?
    @PHState private var hasContent = false

    private var savedCollapsed: Bool { plugin.state["collapsed"] == .bool(true) }
    private var isCollapsed: Bool { pendingCollapsed ?? savedCollapsed }

    var body: some PHView {
        let collapsed = isCollapsed
        let hidden = collapsed || !hasContent
        AtomStack(props: StackProps(spacing: 0, align: "leading", group: true), common: AtomCommon(testID: "plugin-section-\(plugin.id)", paddingTop: hasContent ? 12 : 0)) {
            if hasContent {
                AtomDisclosure(
                    props: DisclosureProps(title: plugin.name, collapsed: collapsed, toggleTestID: "plugin-section-\(plugin.id)-toggle"),
                    onToggle: { toggle(to: !collapsed) }
                ) {}
            }
            // Every prop here is set whether or not it is collapsed, so collapsing
            // never rebuilds the plugin's view.
            AtomStack(props: StackProps(clip: true), common: AtomCommon(opacity: hidden ? 0 : 1)) {
                AtomStack(props: StackProps(collapsed: hidden), common: AtomCommon(paddingTop: 6)) {
                    PluginPropsScope {
                        if plugin.builtIn {
                            BuiltInPluginView(plugin: plugin, props: props(plugin), actions: actions)
                        } else {
                            PluginSurfaceView(plugin: plugin, props: props(plugin), actions: actions)
                        }
                    }
                }
            }
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
        }
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
