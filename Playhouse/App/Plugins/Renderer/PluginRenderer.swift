import AppKit
import SwiftUI

/// Draws one component type from a resolved node. A component never sees
/// bindings, JavaScript or the daemon: the core has already resolved its props,
/// and `ctx` turns user input back into taps and edits on its node.
protocol PluginComponent {
    static var type: String { get }
    /// True for controls that handle their own clicks and help text (buttons, fields),
    /// so the common `onTap` and `tooltip` props aren't applied on top of them.
    static var handlesOwnInput: Bool { get }
    @MainActor static func render(_ ctx: PluginRenderContext) -> AnyView
}

extension PluginComponent {
    static var handlesOwnInput: Bool { false }
}

/// Every renderer, by component type. Adding a component: write its spec in
/// `PluginComponentCatalog`, add a file under Renderer/Components, and list it here.
enum PluginComponentRegistry {
    static let components: [PluginComponent.Type] = [
        VStackComponent.self,
        HStackComponent.self,
        ZStackComponent.self,
        ScrollComponent.self,
        SpacerComponent.self,
        DividerComponent.self,
        TextComponent.self,
        HeadingComponent.self,
        IconComponent.self,
        ButtonComponent.self,
        TextFieldComponent.self,
        ProgressBarComponent.self,
        SpinnerComponent.self,
        LabelComponent.self,
        CodeComponent.self,
        KbdComponent.self,
        LinkComponent.self,
        ImageComponent.self,
        AvatarComponent.self,
        IconButtonComponent.self,
        CopyButtonComponent.self,
        SecureFieldComponent.self,
        TextEditorComponent.self,
        SearchFieldComponent.self,
        ToggleComponent.self,
        SegmentedComponent.self,
        PickerComponent.self,
        SliderComponent.self,
        DatePickerComponent.self,
        BadgeComponent.self,
        ChipComponent.self,
        CardComponent.self,
        StatusDotComponent.self,
        EmptyStateComponent.self,
        HintComponent.self,
        MenuComponent.self,
        MenuItemComponent.self,
        ContextMenuComponent.self,
        PopoverComponent.self,
        SheetComponent.self,
        AlertComponent.self,
        ConfirmDialogComponent.self,
    ]

    private static let byType: [String: PluginComponent.Type] = Dictionary(
        components.map { ($0.type, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func component(for type: String) -> PluginComponent.Type? { byType[type] }
}

struct PluginNodeActions {
    var tap: (Int) -> Void
    var input: (Int, String) -> Void
    /// Runs any event of a node with an optional value (`onChange` of a toggle, `onDismiss` of a sheet).
    var fire: (Int, String, BridgeValue?) -> Void = { _, _, _ in }
    /// The plugin's folder, for `src` props.
    var directory: URL?

    static let inert = PluginNodeActions(tap: { _ in }, input: { _, _ in })
}

/// What a component's renderer gets: its resolved node, typed prop readers,
/// its children, and the actions that report input back to the core.
struct PluginRenderContext {
    let node: PluginResolvedNode
    let actions: PluginNodeActions
    let showNodeIDs: Bool

    func string(_ name: String) -> String? {
        guard let value = node.props[name], !value.isNull else { return nil }
        return value.string ?? value.interpolatedText
    }

    func number(_ name: String) -> Double? {
        guard let value = node.props[name] else { return nil }
        return value.number ?? value.string.flatMap(Double.init)
    }

    func cgFloat(_ name: String) -> CGFloat? { number(name).map { CGFloat($0) } }

    func bool(_ name: String) -> Bool { node.props[name]?.isTruthy ?? false }

    func color(_ name: String) -> Color? { string(name).flatMap(PluginColor.color) }

    var horizontalAlignment: HorizontalAlignment {
        switch string("alignment") {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }

    var verticalAlignment: VerticalAlignment {
        switch string("alignment") {
        case "top": .top
        case "bottom": .bottom
        case "firstTextBaseline": .firstTextBaseline
        default: .center
        }
    }

    func alignment(_ name: String) -> Alignment? {
        switch string(name) {
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        case "top": .top
        case "bottom": .bottom
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: nil
        }
    }

    var children: PluginChildrenView { PluginChildrenView(nodes: node.children, actions: actions, showNodeIDs: showNodeIDs) }

    /// A subset of the children, for components that treat some of them specially (a menu's entries, a popover's anchor).
    func view(of nodes: [PluginResolvedNode]) -> PluginChildrenView { PluginChildrenView(nodes: nodes, actions: actions, showNodeIDs: showNodeIDs) }

    var hasTap: Bool { node.events["onTap"] != nil }

    func tap() { actions.tap(node.id) }

    func input(_ text: String) { actions.input(node.id, text) }

    func fire(_ event: String, value: BridgeValue? = nil) { actions.fire(node.id, event, value) }

    func has(_ event: String) -> Bool { node.events[event] != nil }

    /// A file prop resolved inside the plugin's folder.
    func fileURL(_ name: String) -> URL? {
        guard let path = string(name), let directory = actions.directory else { return nil }
        return PluginFiles.resolve(path, in: directory)
    }

    /// The `options` of a picker or segmented control as (value, title, icon).
    var options: [(value: String, title: String, icon: String?)] {
        (node.props["options"]?.array ?? []).compactMap { option in
            if let text = option.string { return (text, text, nil) }
            guard let object = option.object, let value = object["value"]?.string ?? object["value"]?.number.map({ BridgeValue.decimal($0).interpolatedText }) else { return nil }
            return (value, object["title"]?.string ?? value, object["icon"]?.string)
        }
    }

    /// The children that aren't menu entries, for a context menu's content.
    var contentChildren: [PluginResolvedNode] { node.children.filter { !Self.menuEntryTypes.contains($0.type) } }
    var menuChildren: [PluginResolvedNode] { node.children.filter { Self.menuEntryTypes.contains($0.type) } }
    private static let menuEntryTypes = Set(PluginComponentCatalog.spec("menu")?.childTypes ?? [])
}

struct PluginChildrenView: View {
    let nodes: [PluginResolvedNode]
    let actions: PluginNodeActions
    let showNodeIDs: Bool

    var body: some View {
        ForEach(nodes, id: \.id) { node in
            PluginNodeView(node: node, actions: actions, showNodeIDs: showNodeIDs)
        }
    }
}

/// One element: its component plus the props every component shares.
struct PluginNodeView: View {
    let node: PluginResolvedNode
    let actions: PluginNodeActions
    var showNodeIDs = false

    var body: some View {
        let ctx = PluginRenderContext(node: node, actions: actions, showNodeIDs: showNodeIDs)
        if let component = PluginComponentRegistry.component(for: node.type), node.error == nil {
            decorated(component.render(ctx), ctx: ctx)
        } else if PluginComponentRegistry.component(for: node.type) == nil {
            PluginPlaceholder(
                symbol: "questionmark.square.dashed",
                message: node.error ?? "Unknown component \"\(node.type)\".",
                identifier: "plugin-unknown-component"
            )
        } else {
            PluginPlaceholder(symbol: "exclamationmark.triangle", message: node.error ?? "", identifier: "plugin-error")
        }
    }

    @ViewBuilder
    private func decorated(_ content: AnyView, ctx: PluginRenderContext) -> some View {
        let radius = ctx.cgFloat("radius") ?? 0
        let isContainer = PluginComponentCatalog.spec(node.type)?.acceptsChildren == true
        let handlesOwnInput = PluginComponentRegistry.component(for: node.type)?.handlesOwnInput == true
        let tooltip = handlesOwnInput ? nil : ctx.string("tooltip")
        content
            .padding(ctx.cgFloat("padding") ?? 0)
            .frame(width: ctx.cgFloat("width"), height: ctx.cgFloat("height"))
            .frame(
                minWidth: ctx.cgFloat("minWidth"),
                maxWidth: ctx.bool("grow") ? .infinity : ctx.cgFloat("maxWidth"),
                minHeight: ctx.cgFloat("minHeight"),
                maxHeight: ctx.cgFloat("maxHeight"),
                alignment: ctx.alignment("align") ?? (ctx.bool("grow") ? .leading : .center)
            )
            .background(ctx.color("background").map { RoundedRectangle(cornerRadius: radius).fill($0) })
            .overlay(ctx.color("border").map { RoundedRectangle(cornerRadius: radius).strokeBorder($0, lineWidth: 1) })
            .pluginForeground(ctx.color("foreground"))
            .opacity(ctx.number("opacity") ?? 1)
            .shadow(color: ctx.bool("shadow") ? .black.opacity(0.25) : .clear, radius: ctx.bool("shadow") ? 4 : 0, y: ctx.bool("shadow") ? 2 : 0)
            .disabled(ctx.bool("disabled"))
            .pluginTooltip(tooltip)
            .pluginTapTarget(ctx.hasTap && !handlesOwnInput ? { ctx.tap() } : nil)
            .pluginCursor(ctx.string("cursor"))
            .pluginContainer(isContainer)
            .accessibilityIdentifier("plugin-node-\(node.id)")
            .overlay(alignment: .topLeading) {
                if showNodeIDs {
                    let number = "\(node.id)"
                    Text(number)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                        .offset(x: -4, y: -4)
                        .accessibilityLabel(number)
                        .accessibilityIdentifier("plugin-node-badge-\(node.id)")
                }
            }
    }
}

private extension View {
    @ViewBuilder
    func pluginForeground(_ color: Color?) -> some View {
        if let color { foregroundStyle(color) } else { self }
    }

    @ViewBuilder
    func pluginTooltip(_ text: String?) -> some View {
        if let text { nativeHelp(text) } else { self }
    }

    @ViewBuilder
    func pluginTapTarget(_ action: (() -> Void)?) -> some View {
        if let action {
            contentShape(Rectangle())
                .onTapGesture(perform: action)
                .hoverCursor(.pointingHand)
                .accessibilityAddTraits(.isButton)
        } else {
            self
        }
    }

    @ViewBuilder
    func pluginCursor(_ name: String?) -> some View {
        if name == "pointer" { hoverCursor(.pointingHand) } else { self }
    }

    @ViewBuilder
    func pluginContainer(_ isContainer: Bool) -> some View {
        if isContainer { accessibilityElement(children: .contain) } else { self }
    }
}

struct PluginPlaceholder: View {
    let symbol: String
    let message: String
    let identifier: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [4])))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
    }
}

enum PluginColor {
    static func color(_ text: String) -> Color? {
        switch text {
        case "accent": return WorkspaceTheme.accent
        case "primary": return .primary
        case "secondary": return .secondary
        case "muted": return Color.gray.opacity(0.35)
        case "success": return .green
        case "warning": return .orange
        case "danger": return .red
        case "info": return .blue
        case "purple": return .purple
        case "window": return WorkspaceTheme.windowBackground
        case "panel": return WorkspaceTheme.panelBackground
        case "input": return WorkspaceTheme.inputBackground
        case "clear": return .clear
        default: break
        }
        guard text.hasPrefix("#"), let raw = UInt64(text.dropFirst(), radix: 16) else { return nil }
        let hex = text.dropFirst()
        let hasAlpha = hex.count == 8
        guard hex.count == 6 || hasAlpha else { return nil }
        let value = hasAlpha ? raw : (raw << 8) | 0xFF
        return Color(
            .sRGB,
            red: Double((value >> 24) & 0xFF) / 255,
            green: Double((value >> 16) & 0xFF) / 255,
            blue: Double((value >> 8) & 0xFF) / 255,
            opacity: Double(value & 0xFF) / 255
        )
    }
}
