import Foundation

/// The kinds of value a component prop accepts. Any prop may instead hold a
/// `{{binding}}` string, which is checked after resolution, not here.
enum PluginPropKind: Equatable {
    case string
    case number
    case bool
    case color
    case options([String])
    /// Any JSON value (for example the `items` of a list).
    case any

    var label: String {
        switch self {
        case .string: "string"
        case .number: "number"
        case .bool: "bool"
        case .color: "color"
        case .options(let values): values.joined(separator: " | ")
        case .any: "any"
        }
    }
}

struct PluginPropSpec: Equatable {
    var name: String
    var kind: PluginPropKind
    var required = false
    var defaultValue: BridgeValue? = nil
    var doc: String
}

struct PluginEventSpec: Equatable {
    var name: String
    var doc: String
}

struct PluginComponentSpec: Equatable {
    var type: String
    var section: String
    var summary: String
    var props: [PluginPropSpec]
    var events: [PluginEventSpec] = []
    var acceptsChildren = false
    /// Modal-like: present only while its `open` prop is true.
    var presentation = false
    /// Resolved by the core into its children (`if`, `list`); there is no renderer for it.
    var structural = false
    var wave: Int

    /// An interactive showcase is required for components with their own events and for presentation components.
    var needsInteractiveShowcase: Bool { !events.isEmpty || presentation }
}

struct PluginCatalogSection: Equatable {
    var id: String
    var title: String
    var summary: String
}

/// The single source of truth for which components exist and what they accept.
/// Adding a component: add its spec here, add its renderer under
/// Plugins/Renderer/Components and register it in `PluginComponentRegistry`,
/// then add it to a showcase under Playhouse/Resources/Showcase/<section>/
/// (see docs/plugins/adding-a-component.md).
enum PluginComponentCatalog {
    static let sections: [PluginCatalogSection] = [
        .init(id: "foundations", title: "Foundations", summary: "Common props, semantic colors, spacing and the type scale shared by every component."),
        .init(id: "layout", title: "Layout", summary: "Stacks and containers that arrange other components."),
        .init(id: "separators", title: "Separators", summary: "Lines and fixed gaps between content."),
        .init(id: "typography", title: "Typography", summary: "Text, headings and inline text styles."),
        .init(id: "media", title: "Media and icons", summary: "SF Symbols, images and avatars."),
        .init(id: "buttons", title: "Buttons", summary: "Controls that run an action when clicked."),
        .init(id: "text-input", title: "Text input", summary: "Fields that edit text and numbers."),
        .init(id: "selection", title: "Selection", summary: "Toggles, checkboxes, pickers and segmented controls."),
        .init(id: "pickers", title: "Pickers", summary: "Color, date, time, file and folder pickers."),
        .init(id: "progress-status", title: "Progress and status", summary: "Progress bars, spinners, badges and status indicators."),
        .init(id: "feedback", title: "Feedback", summary: "Banners, callouts, empty states and toasts."),
        .init(id: "overlays", title: "Overlays and dialogs", summary: "Modals, sheets, dialogs, popovers, tooltips and menus."),
        .init(id: "navigation", title: "Navigation", summary: "Tabs, accordions, breadcrumbs and pagination."),
        .init(id: "forms", title: "Forms", summary: "Fields with labels, help and validation messages."),
        .init(id: "data", title: "Data display", summary: "Cards, tags, stats, tables, trees and timelines."),
        .init(id: "charts", title: "Charts", summary: "Bar, line, area, pie and other charts."),
        .init(id: "structural", title: "Structural", summary: "Conditionals and repetition, resolved before rendering."),
        .init(id: "terminal", title: "Terminal", summary: "Interactive terminals and command output."),
        .init(id: "agent", title: "Agent", summary: "Agent conversations and prompt input."),
        .init(id: "playhouse", title: "Playhouse", summary: "Tasks, repositories and pull requests."),
        .init(id: "behaviors", title: "Behaviors", summary: "Keyboard shortcuts, drag and drop and hover areas."),
    ]

    static let semanticColors = ["accent", "primary", "secondary", "muted", "success", "warning", "danger", "info", "clear"]

    /// Props every component accepts. Events here are available on any component.
    static let commonProps: [PluginPropSpec] = [
        .init(name: "width", kind: .number, doc: "Fixed width in points."),
        .init(name: "height", kind: .number, doc: "Fixed height in points."),
        .init(name: "minWidth", kind: .number, doc: "Minimum width in points."),
        .init(name: "maxWidth", kind: .number, doc: "Maximum width in points."),
        .init(name: "minHeight", kind: .number, doc: "Minimum height in points."),
        .init(name: "maxHeight", kind: .number, doc: "Maximum height in points."),
        .init(name: "grow", kind: .bool, doc: "Fill the available width."),
        .init(name: "align", kind: .options(["leading", "center", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"]), doc: "Alignment inside the component's frame."),
        .init(name: "padding", kind: .number, doc: "Padding on every side, in points."),
        .init(name: "background", kind: .color, doc: "Background color."),
        .init(name: "foreground", kind: .color, doc: "Text and symbol color."),
        .init(name: "border", kind: .color, doc: "One-point border color."),
        .init(name: "radius", kind: .number, doc: "Corner radius of the background and border."),
        .init(name: "opacity", kind: .number, doc: "Opacity from 0 to 1."),
        .init(name: "shadow", kind: .bool, doc: "A soft drop shadow."),
        .init(name: "hidden", kind: .bool, doc: "Leave the component out entirely."),
        .init(name: "disabled", kind: .bool, doc: "Disable interaction."),
        .init(name: "tooltip", kind: .string, doc: "Hover help text."),
    ]

    static let commonEvents: [PluginEventSpec] = [
        .init(name: "onTap", doc: "Runs an action when the component is clicked."),
        .init(name: "onAppear", doc: "Runs an action when the component first appears."),
    ]

    static let components: [PluginComponentSpec] = [
        // Layout
        .init(type: "vstack", section: "layout", summary: "Arranges children vertically.", props: [
            .init(name: "spacing", kind: .number, defaultValue: .integer(8), doc: "Space between children."),
            .init(name: "alignment", kind: .options(["leading", "center", "trailing"]), defaultValue: .string("leading"), doc: "Horizontal alignment of children."),
        ], acceptsChildren: true, wave: 1),
        .init(type: "hstack", section: "layout", summary: "Arranges children horizontally.", props: [
            .init(name: "spacing", kind: .number, defaultValue: .integer(8), doc: "Space between children."),
            .init(name: "alignment", kind: .options(["top", "center", "bottom", "firstTextBaseline"]), defaultValue: .string("center"), doc: "Vertical alignment of children."),
        ], acceptsChildren: true, wave: 1),
        .init(type: "zstack", section: "layout", summary: "Layers children on top of each other.", props: [
            .init(name: "alignment", kind: .options(["center", "leading", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"]), defaultValue: .string("center"), doc: "Alignment of the layers."),
        ], acceptsChildren: true, wave: 1),
        .init(type: "spacer", section: "layout", summary: "Flexible space that pushes siblings apart.", props: [
            .init(name: "minLength", kind: .number, doc: "Smallest length the spacer can shrink to."),
        ], wave: 1),
        // Separators
        .init(type: "divider", section: "separators", summary: "A thin separator line.", props: [
            .init(name: "axis", kind: .options(["auto", "horizontal", "vertical"]), defaultValue: .string("auto"), doc: "Line direction; auto follows the parent stack."),
        ], wave: 1),
        // Typography
        .init(type: "text", section: "typography", summary: "A run of text.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The text to show."),
            .init(name: "style", kind: .options(["body", "callout", "caption", "footnote", "subheadline", "headline", "title", "largeTitle"]), defaultValue: .string("body"), doc: "Text style from the type scale."),
            .init(name: "weight", kind: .options(["regular", "medium", "semibold", "bold"]), doc: "Font weight."),
            .init(name: "color", kind: .color, doc: "Text color."),
            .init(name: "monospaced", kind: .bool, defaultValue: .boolean(false), doc: "Use a monospaced font."),
            .init(name: "lineLimit", kind: .number, doc: "Maximum number of lines."),
        ], wave: 1),
        .init(type: "heading", section: "typography", summary: "A section heading.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The heading text."),
            .init(name: "level", kind: .options(["1", "2", "3", "4"]), defaultValue: .string("2"), doc: "Heading level; 1 is the largest."),
        ], wave: 1),
        // Media
        .init(type: "icon", section: "media", summary: "An SF Symbol.", props: [
            .init(name: "name", kind: .string, required: true, doc: "SF Symbol name, for example \"star.fill\"."),
            .init(name: "size", kind: .number, defaultValue: .integer(16), doc: "Point size."),
            .init(name: "color", kind: .color, doc: "Symbol color."),
        ], wave: 1),
        // Buttons
        .init(type: "button", section: "buttons", summary: "A push button that runs an action.", props: [
            .init(name: "title", kind: .string, required: true, doc: "The button label."),
            .init(name: "icon", kind: .string, doc: "Optional SF Symbol shown before the title."),
            .init(name: "style", kind: .options(["bordered", "prominent", "borderless", "plain"]), defaultValue: .string("bordered"), doc: "Visual style."),
            .init(name: "destructive", kind: .bool, defaultValue: .boolean(false), doc: "Mark the button as destructive."),
        ], events: [.init(name: "onTap", doc: "Runs when the button is clicked.")], wave: 1),
        // Text input
        .init(type: "textfield", section: "text-input", summary: "A single-line text field.", props: [
            .init(name: "value", kind: .string, doc: "The text, usually bound to state."),
            .init(name: "placeholder", kind: .string, doc: "Hint shown while the field is empty."),
        ], events: [.init(name: "onChange", doc: "Runs on every edit with { value } merged into the payload.")], wave: 1),
        // Progress and status
        .init(type: "progress-bar", section: "progress-status", summary: "A linear progress bar; indeterminate without a value.", props: [
            .init(name: "value", kind: .number, doc: "Current progress; leave unset for an indeterminate bar."),
            .init(name: "total", kind: .number, defaultValue: .integer(100), doc: "The value that means complete."),
            .init(name: "label", kind: .string, doc: "Text shown above the bar."),
            .init(name: "showValue", kind: .bool, defaultValue: .boolean(false), doc: "Show the percentage."),
        ], wave: 1),
        .init(type: "spinner", section: "progress-status", summary: "An indeterminate activity spinner.", props: [
            .init(name: "size", kind: .options(["small", "regular", "large"]), defaultValue: .string("regular"), doc: "Spinner size."),
            .init(name: "label", kind: .string, doc: "Text shown beside the spinner."),
        ], wave: 1),
        // Structural
        .init(type: "if", section: "structural", summary: "Shows its children only while cond is truthy.", props: [
            .init(name: "cond", kind: .any, required: true, doc: "Usually a binding such as \"{{loading}}\" or \"{{!items.length}}\"."),
        ], acceptsChildren: true, structural: true, wave: 1),
        .init(type: "list", section: "structural", summary: "Repeats its children once per item.", props: [
            .init(name: "items", kind: .any, required: true, doc: "An array, usually a binding such as \"{{tasks}}\"."),
            .init(name: "as", kind: .string, defaultValue: .string("item"), doc: "The name each item is bound to; \"index\" holds its position."),
            .init(name: "key", kind: .string, defaultValue: .string("id"), doc: "The item field that identifies a row across updates."),
        ], acceptsChildren: true, structural: true, wave: 1),
    ]

    private static let specsByType = Dictionary(uniqueKeysWithValues: components.map { ($0.type, $0) })

    static func spec(_ type: String) -> PluginComponentSpec? { specsByType[type] }

    static func section(_ id: String) -> PluginCatalogSection? { sections.first { $0.id == id } }

    /// Every prop name a component accepts, including common props and events.
    static func acceptedPropNames(_ spec: PluginComponentSpec) -> Set<String> {
        Set(spec.props.map(\.name) + commonProps.map(\.name) + spec.events.map(\.name) + commonEvents.map(\.name))
    }

    static func isEventName(_ name: String, for spec: PluginComponentSpec) -> Bool {
        spec.events.contains { $0.name == name } || commonEvents.contains { $0.name == name }
    }

    /// The catalog as JSON, for `plugin components` and the docs.
    static func catalogValue(type: String? = nil) -> BridgeValue {
        func prop(_ spec: PluginPropSpec) -> BridgeValue {
            .object([
                "name": .string(spec.name),
                "kind": .string(spec.kind.label),
                "required": .boolean(spec.required),
                "default": spec.defaultValue ?? .null,
                "doc": .string(spec.doc),
            ])
        }
        func event(_ spec: PluginEventSpec) -> BridgeValue { .object(["name": .string(spec.name), "doc": .string(spec.doc)]) }
        let selected = components.filter { type == nil || $0.type == type }
        return .object([
            "sections": .array(sections.map { section in
                .object(["id": .string(section.id), "title": .string(section.title), "summary": .string(section.summary)])
            }),
            "components": .array(selected.map { spec in
                .object([
                    "type": .string(spec.type),
                    "section": .string(spec.section),
                    "summary": .string(spec.summary),
                    "props": .array(spec.props.map(prop)),
                    "events": .array(spec.events.map(event)),
                    "acceptsChildren": .boolean(spec.acceptsChildren),
                    "presentation": .boolean(spec.presentation),
                    "structural": .boolean(spec.structural),
                    "wave": .integer(spec.wave),
                ])
            }),
            "commonProps": .array(commonProps.map(prop)),
            "commonEvents": .array(commonEvents.map(event)),
            "semanticColors": .array(semanticColors.map(BridgeValue.string)),
        ])
    }

    static func isValidColor(_ text: String) -> Bool {
        if semanticColors.contains(text) { return true }
        guard text.hasPrefix("#") else { return false }
        let hex = text.dropFirst()
        return (hex.count == 6 || hex.count == 8) && hex.allSatisfy(\.isHexDigit)
    }
}
