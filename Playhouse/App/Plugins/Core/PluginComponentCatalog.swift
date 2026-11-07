import Foundation

/// The kinds of value a component prop accepts. Any prop may instead hold a
/// `{{binding}}` string, which is checked after resolution, not here.
enum PluginPropKind: Equatable {
    case string
    case number
    case bool
    case color
    /// A file path inside the plugin folder.
    case file
    case options([String])
    /// Any JSON value (for example the `items` of a list).
    case any

    var label: String {
        switch self {
        case .string: "string"
        case .number: "number"
        case .bool: "bool"
        case .color: "color"
        case .file: "file"
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
    /// The kind of `value` the event carries (`onChange` of a toggle is a bool); nil for events without one.
    var valueKind: PluginPropKind? = nil
    /// The array prop holding the values this event may carry (`options` of a picker); a value outside it is refused.
    var valueFrom: String? = nil
}

struct PluginComponentSpec: Equatable {
    var type: String
    var section: String
    var summary: String
    var props: [PluginPropSpec]
    var events: [PluginEventSpec] = []
    var acceptsChildren = false
    /// Modal-like: present only while its `open` prop is true. While closed its events are refused
    /// and only its first `anchorChildren` children are in the tree.
    var presentation = false
    var anchorChildren = 0
    /// When set, the only component types allowed as children (`if` and `list` are looked through).
    var childTypes: [String]? = nil
    /// When set, the component must sit directly inside one of these types.
    var parentTypes: [String]? = nil
    var minChildren = 0
    /// At least one of these props must be set (an icon needs a name or a src).
    var needsOneOf: [String] = []
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

    static let textStyles = ["body", "callout", "caption", "footnote", "subheadline", "headline", "title", "largeTitle"]

    static let semanticColors = ["accent", "primary", "secondary", "muted", "success", "warning", "danger", "info", "purple", "window", "panel", "input", "clear"]

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
        .init(name: "cursor", kind: .options(["pointer", "default"]), doc: "Mouse cursor while hovering; clickable components use the pointer already."),
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
            .init(name: "label", kind: .string, doc: "Text centered on a horizontal line."),
        ], wave: 1),
        // Typography
        .init(type: "text", section: "typography", summary: "A run of text.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The text to show."),
            .init(name: "style", kind: .options(["body", "callout", "caption", "footnote", "subheadline", "headline", "title", "largeTitle"]), defaultValue: .string("body"), doc: "Text style from the type scale."),
            .init(name: "weight", kind: .options(["regular", "medium", "semibold", "bold"]), doc: "Font weight."),
            .init(name: "color", kind: .color, doc: "Text color."),
            .init(name: "monospaced", kind: .bool, defaultValue: .boolean(false), doc: "Use a monospaced font."),
            .init(name: "lineLimit", kind: .number, doc: "Maximum number of lines."),
            .init(name: "selectable", kind: .bool, defaultValue: .boolean(false), doc: "Let the user select and copy the text."),
            .init(name: "markdown", kind: .bool, defaultValue: .boolean(false), doc: "Render inline markdown (bold, italic, code, links)."),
        ], wave: 1),
        .init(type: "heading", section: "typography", summary: "A section heading.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The heading text."),
            .init(name: "level", kind: .options(["1", "2", "3", "4"]), defaultValue: .string("2"), doc: "Heading level; 1 is the largest."),
        ], wave: 1),
        // Media
        .init(type: "icon", section: "media", summary: "An SF Symbol.", props: [
            .init(name: "name", kind: .string, doc: "SF Symbol name, for example \"star.fill\". Give this or src."),
            .init(name: "src", kind: .file, doc: "An image file in the plugin folder (png, jpg, pdf, svg), drawn as a template icon tinted with color."),
            .init(name: "size", kind: .number, defaultValue: .integer(16), doc: "Point size."),
            .init(name: "color", kind: .color, doc: "Symbol color."),
            .init(name: "weight", kind: .options(["regular", "medium", "semibold", "bold"]), doc: "Symbol weight."),
            .init(name: "rendering", kind: .options(["monochrome", "hierarchical", "multicolor"]), defaultValue: .string("monochrome"), doc: "How a symbol's layers are colored."),
        ], needsOneOf: ["name", "src"], wave: 1),
        // Buttons
        .init(type: "button", section: "buttons", summary: "A push button that runs an action.", props: [
            .init(name: "title", kind: .string, required: true, doc: "The button label."),
            .init(name: "icon", kind: .string, doc: "Optional SF Symbol shown before the title."),
            .init(name: "style", kind: .options(["bordered", "prominent", "borderless", "plain", "link"]), defaultValue: .string("bordered"), doc: "Visual style."),
            .init(name: "size", kind: .options(["mini", "small", "regular", "large"]), defaultValue: .string("regular"), doc: "Control size."),
            .init(name: "shortcut", kind: .string, doc: "Keyboard shortcut while the window is key, for example \"cmd+s\" or \"return\"."),
            .init(name: "destructive", kind: .bool, defaultValue: .boolean(false), doc: "Mark the button as destructive."),
        ], events: [.init(name: "onTap", doc: "Runs when the button is clicked.")], wave: 1),
        // Text input
        .init(type: "textfield", section: "text-input", summary: "A single-line text field.", props: [
            .init(name: "value", kind: .string, doc: "The text, usually bound to state."),
            .init(name: "placeholder", kind: .string, doc: "Hint shown while the field is empty."),
            .init(name: "style", kind: .options(["rounded", "plain"]), defaultValue: .string("rounded"), doc: "Field chrome; plain has no border."),
        ], events: [
            .init(name: "onChange", doc: "Runs on every edit with { value } merged into the payload.", valueKind: .string),
            .init(name: "onSubmit", doc: "Runs when the user presses Return."),
        ], wave: 1),
        // Progress and status
        .init(type: "progress-bar", section: "progress-status", summary: "A linear progress bar; indeterminate without a value.", props: [
            .init(name: "value", kind: .number, doc: "Current progress; leave unset for an indeterminate bar."),
            .init(name: "total", kind: .number, defaultValue: .integer(100), doc: "The value that means complete."),
            .init(name: "label", kind: .string, doc: "Text shown above the bar."),
            .init(name: "showValue", kind: .bool, defaultValue: .boolean(false), doc: "Show the percentage."),
            .init(name: "color", kind: .color, doc: "Fill color; defaults to the accent."),
            .init(name: "thickness", kind: .number, doc: "Bar thickness in points; set it for a slim capsule bar instead of the system one."),
            .init(name: "axis", kind: .options(["horizontal", "vertical"]), defaultValue: .string("horizontal"), doc: "A vertical bar fills from the bottom."),
        ], wave: 1),
        .init(type: "spinner", section: "progress-status", summary: "An indeterminate activity spinner.", props: [
            .init(name: "size", kind: .options(["mini", "small", "regular", "large"]), defaultValue: .string("regular"), doc: "Spinner size."),
            .init(name: "label", kind: .string, doc: "Text shown beside the spinner."),
        ], wave: 1),
        // Wave 2: the app's atomic building blocks
        .init(type: "label", section: "typography", summary: "Text with an SF Symbol beside it.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The text to show."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown before the text."),
            .init(name: "style", kind: .options(textStyles), defaultValue: .string("body"), doc: "Text style from the type scale."),
            .init(name: "color", kind: .color, doc: "Text and symbol color."),
            .init(name: "iconOnly", kind: .bool, defaultValue: .boolean(false), doc: "Show only the symbol; the text stays as its accessibility label."),
        ], wave: 2),
        .init(type: "code", section: "typography", summary: "An inline monospaced span on a subtle background.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The code to show."),
            .init(name: "color", kind: .color, doc: "Text color."),
        ], wave: 2),
        .init(type: "kbd", section: "typography", summary: "A keyboard shortcut hint drawn as key caps.", props: [
            .init(name: "keys", kind: .string, required: true, doc: "The shortcut, for example \"cmd+shift+k\" or \"⌘⇧K\"; each key gets its own cap."),
        ], wave: 2),
        .init(type: "link", section: "typography", summary: "Text that opens a web address.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The link text."),
            .init(name: "url", kind: .string, required: true, doc: "An http, https or mailto address."),
        ], events: [.init(name: "onTap", doc: "Runs when the link is clicked, before it opens.")], wave: 2),
        .init(type: "image", section: "media", summary: "A picture from the plugin folder.", props: [
            .init(name: "src", kind: .file, required: true, doc: "Image file in the plugin folder (png, jpg, gif, pdf, svg)."),
            .init(name: "fit", kind: .options(["fit", "fill"]), defaultValue: .string("fit"), doc: "Scale inside the frame, or fill and crop it."),
            .init(name: "alt", kind: .string, doc: "Accessibility description."),
            .init(name: "cornerRadius", kind: .number, defaultValue: .integer(0), doc: "Clip the image to rounded corners."),
        ], wave: 2),
        .init(type: "avatar", section: "media", summary: "A circle with initials or a picture.", props: [
            .init(name: "text", kind: .string, doc: "Name or initials; up to two letters are shown."),
            .init(name: "src", kind: .file, doc: "Image file in the plugin folder, used instead of initials."),
            .init(name: "size", kind: .number, defaultValue: .integer(28), doc: "Diameter in points."),
            .init(name: "color", kind: .color, defaultValue: .string("accent"), doc: "Circle color behind initials."),
        ], wave: 2),
        .init(type: "icon-button", section: "buttons", summary: "A compact symbol-only button with a hover highlight.", props: [
            .init(name: "icon", kind: .string, required: true, doc: "SF Symbol name."),
            .init(name: "title", kind: .string, doc: "Accessibility label and tooltip."),
            .init(name: "size", kind: .options(["mini", "small", "regular"]), defaultValue: .string("small"), doc: "Symbol size."),
            .init(name: "emphasis", kind: .bool, defaultValue: .boolean(true), doc: "Highlight with an accent capsule on hover."),
            .init(name: "color", kind: .color, doc: "Symbol color."),
            .init(name: "destructive", kind: .bool, defaultValue: .boolean(false), doc: "Mark the action as destructive."),
        ], events: [.init(name: "onTap", doc: "Runs when the button is clicked.")], wave: 2),
        .init(type: "copy-button", section: "buttons", summary: "Copies text to the clipboard and shows a checkmark.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The text placed on the clipboard."),
            .init(name: "title", kind: .string, doc: "Label beside the icon; leave unset for an icon-only button."),
            .init(name: "icon", kind: .string, defaultValue: .string("doc.on.doc"), doc: "SF Symbol shown before it is clicked."),
        ], events: [.init(name: "onCopy", doc: "Runs after the text is copied.")], wave: 2),
        .init(type: "secure-field", section: "text-input", summary: "A single-line field that hides what is typed.", props: [
            .init(name: "value", kind: .string, doc: "The text, usually bound to state."),
            .init(name: "placeholder", kind: .string, doc: "Hint shown while the field is empty."),
        ], events: [.init(name: "onChange", doc: "Runs on every edit with { value } merged into the payload.", valueKind: .string)], wave: 2),
        .init(type: "text-editor", section: "text-input", summary: "A multi-line text editor.", props: [
            .init(name: "value", kind: .string, doc: "The text, usually bound to state."),
            .init(name: "placeholder", kind: .string, doc: "Hint shown while the editor is empty."),
            .init(name: "minLines", kind: .number, defaultValue: .integer(3), doc: "Height in lines of text."),
            .init(name: "monospaced", kind: .bool, defaultValue: .boolean(false), doc: "Use a monospaced font."),
        ], events: [.init(name: "onChange", doc: "Runs on every edit with { value } merged into the payload.", valueKind: .string)], wave: 2),
        .init(type: "search-field", section: "text-input", summary: "A search box with a magnifier and a clear button.", props: [
            .init(name: "value", kind: .string, doc: "The query, usually bound to state."),
            .init(name: "placeholder", kind: .string, defaultValue: .string("Search"), doc: "Hint shown while the field is empty."),
        ], events: [
            .init(name: "onChange", doc: "Runs on every edit with { value } merged into the payload.", valueKind: .string),
            .init(name: "onSubmit", doc: "Runs when the user presses Return."),
        ], wave: 2),
        .init(type: "toggle", section: "selection", summary: "An on/off switch or checkbox.", props: [
            .init(name: "label", kind: .string, doc: "Text beside the control."),
            .init(name: "value", kind: .bool, defaultValue: .boolean(false), doc: "Whether it is on, usually bound to state."),
            .init(name: "style", kind: .options(["switch", "checkbox"]), defaultValue: .string("switch"), doc: "Control style."),
        ], events: [.init(name: "onChange", doc: "Runs when toggled with { value: true | false } merged into the payload.", valueKind: .bool)], wave: 2),
        .init(type: "segmented", section: "selection", summary: "A segmented control that picks one of a few options.", props: [
            .init(name: "options", kind: .any, required: true, doc: "An array of { value, title, icon? }, or of plain strings."),
            .init(name: "value", kind: .string, doc: "The selected option's value, usually bound to state."),
        ], events: [.init(name: "onChange", doc: "Runs when the selection changes with { value } merged into the payload.", valueKind: .string, valueFrom: "options")], wave: 2),
        .init(type: "picker", section: "selection", summary: "A pop-up menu that picks one option.", props: [
            .init(name: "options", kind: .any, required: true, doc: "An array of { value, title }, or of plain strings."),
            .init(name: "value", kind: .string, doc: "The selected option's value, usually bound to state."),
            .init(name: "label", kind: .string, doc: "Text beside the control."),
        ], events: [.init(name: "onChange", doc: "Runs when the selection changes with { value } merged into the payload.", valueKind: .string, valueFrom: "options")], wave: 2),
        .init(type: "slider", section: "selection", summary: "A slider for a number, optionally in steps with tick marks.", props: [
            .init(name: "value", kind: .number, defaultValue: .integer(0), doc: "The current number, usually bound to state."),
            .init(name: "min", kind: .number, defaultValue: .integer(0), doc: "Lowest value."),
            .init(name: "max", kind: .number, defaultValue: .integer(100), doc: "Highest value."),
            .init(name: "step", kind: .number, doc: "Step size; leave unset for a continuous slider."),
            .init(name: "ticks", kind: .bool, defaultValue: .boolean(false), doc: "Draw a tick at each step."),
            .init(name: "label", kind: .string, doc: "Text beside the slider."),
        ], events: [.init(name: "onChange", doc: "Runs while dragging with { value } merged into the payload.", valueKind: .number)], wave: 2),
        .init(type: "date-picker", section: "pickers", summary: "A date and/or time picker.", props: [
            .init(name: "value", kind: .string, doc: "An ISO 8601 date-time such as \"2026-11-07T09:30:00Z\", usually bound to state."),
            .init(name: "mode", kind: .options(["date", "time", "datetime"]), defaultValue: .string("date"), doc: "Which parts the user edits."),
            .init(name: "label", kind: .string, doc: "Text beside the picker."),
        ], events: [.init(name: "onChange", doc: "Runs on every edit with { value } as an ISO 8601 string merged into the payload.", valueKind: .string)], wave: 2),
        .init(type: "badge", section: "data", summary: "A small label for a status or count.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The label."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown before the text."),
            .init(name: "color", kind: .color, defaultValue: .string("accent"), doc: "Tint."),
            .init(name: "style", kind: .options(["tinted", "solid", "outline"]), defaultValue: .string("tinted"), doc: "Tinted fill, solid fill or outline."),
            .init(name: "size", kind: .options(["small", "regular"]), defaultValue: .string("regular"), doc: "Badge size."),
            .init(name: "monospaced", kind: .bool, defaultValue: .boolean(false), doc: "Use a monospaced font, for counts and numbers."),
        ], wave: 2),
        .init(type: "chip", section: "data", summary: "A rounded tag that can be clicked, selected or removed.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The label."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown before the text."),
            .init(name: "color", kind: .color, defaultValue: .string("secondary"), doc: "Border and text tint."),
            .init(name: "selected", kind: .bool, defaultValue: .boolean(false), doc: "Fill with the tint."),
            .init(name: "removable", kind: .bool, defaultValue: .boolean(false), doc: "Show a remove button."),
        ], events: [
            .init(name: "onTap", doc: "Runs when the chip is clicked."),
            .init(name: "onRemove", doc: "Runs when the remove button is clicked."),
        ], wave: 2),
        .init(type: "card", section: "data", summary: "A rounded surface that groups content.", props: [
            .init(name: "style", kind: .options(["panel", "material", "dashed", "plain"]), defaultValue: .string("panel"), doc: "Surface style."),
            .init(name: "inset", kind: .number, defaultValue: .integer(12), doc: "Space between the edge and the content."),
            .init(name: "cornerRadius", kind: .number, defaultValue: .integer(10), doc: "Corner radius."),
            .init(name: "spacing", kind: .number, defaultValue: .integer(8), doc: "Space between children."),
        ], acceptsChildren: true, wave: 2),
        .init(type: "status-dot", section: "progress-status", summary: "A small colored dot for a state.", props: [
            .init(name: "color", kind: .color, defaultValue: .string("accent"), doc: "Dot color."),
            .init(name: "size", kind: .number, defaultValue: .integer(8), doc: "Diameter in points."),
        ], wave: 2),
        .init(type: "empty-state", section: "feedback", summary: "A message for a list or area with nothing in it.", props: [
            .init(name: "title", kind: .string, required: true, doc: "What is missing."),
            .init(name: "message", kind: .string, doc: "A hint about what to do."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown above the title."),
            .init(name: "style", kind: .options(["plain", "dashed"]), defaultValue: .string("plain"), doc: "Plain text or a dashed card."),
        ], wave: 2),
        .init(type: "hint", section: "feedback", summary: "A short note, as a caption or a floating capsule.", props: [
            .init(name: "text", kind: .string, required: true, doc: "The note."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown before the text."),
            .init(name: "style", kind: .options(["caption", "capsule"]), defaultValue: .string("caption"), doc: "A small secondary caption or a floating material capsule."),
            .init(name: "tone", kind: .color, defaultValue: .string("secondary"), doc: "Text and symbol color."),
        ], wave: 2),
        .init(type: "scroll", section: "layout", summary: "Scrolls its children when they outgrow the frame.", props: [
            .init(name: "axis", kind: .options(["vertical", "horizontal"]), defaultValue: .string("vertical"), doc: "Scroll direction."),
            .init(name: "spacing", kind: .number, defaultValue: .integer(8), doc: "Space between children."),
        ], acceptsChildren: true, wave: 2),
        .init(type: "menu", section: "overlays", summary: "A button that opens a menu of items.", props: [
            .init(name: "title", kind: .string, doc: "Button label."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown before the title, or alone."),
            .init(name: "indicator", kind: .bool, defaultValue: .boolean(true), doc: "Show the pull-down arrow."),
        ], acceptsChildren: true, childTypes: ["menu-item", "divider"], minChildren: 1, wave: 2),
        .init(type: "menu-item", section: "overlays", summary: "One entry of a menu or context menu.", props: [
            .init(name: "title", kind: .string, required: true, doc: "The entry text."),
            .init(name: "icon", kind: .string, doc: "SF Symbol shown before the title."),
            .init(name: "checked", kind: .bool, defaultValue: .boolean(false), doc: "Mark the entry with a checkmark."),
            .init(name: "destructive", kind: .bool, defaultValue: .boolean(false), doc: "Mark the entry as destructive."),
        ], events: [.init(name: "onTap", doc: "Runs when the entry is chosen.")], parentTypes: ["menu", "context-menu"], wave: 2),
        .init(type: "context-menu", section: "overlays", summary: "Adds a right-click menu to its content.", props: [], acceptsChildren: true, minChildren: 2, wave: 2),
        .init(type: "popover", section: "overlays", summary: "Floating content anchored to its first child.", props: [
            .init(name: "open", kind: .bool, required: true, doc: "Whether the popover is showing, usually bound to state."),
            .init(name: "edge", kind: .options(["bottom", "top", "leading", "trailing"]), defaultValue: .string("bottom"), doc: "Which side of the anchor it opens on."),
        ], events: [.init(name: "onDismiss", doc: "Runs when the user clicks away; set open to false in the action.")], acceptsChildren: true, presentation: true, anchorChildren: 1, minChildren: 2, wave: 2),
        .init(type: "sheet", section: "overlays", summary: "A panel that slides over the window until dismissed.", props: [
            .init(name: "open", kind: .bool, required: true, doc: "Whether the sheet is showing, usually bound to state."),
            .init(name: "contentWidth", kind: .number, defaultValue: .integer(360), doc: "Sheet width in points."),
        ], events: [.init(name: "onDismiss", doc: "Runs when the user presses Escape; set open to false in the action.")], acceptsChildren: true, presentation: true, minChildren: 1, wave: 2),
        .init(type: "alert", section: "overlays", summary: "A dialog with a message and one button.", props: [
            .init(name: "open", kind: .bool, required: true, doc: "Whether the alert is showing, usually bound to state."),
            .init(name: "title", kind: .string, required: true, doc: "Alert title."),
            .init(name: "message", kind: .string, doc: "Explanatory text."),
            .init(name: "buttonTitle", kind: .string, defaultValue: .string("OK"), doc: "The button's label."),
        ], events: [.init(name: "onDismiss", doc: "Runs when the button is clicked; set open to false in the action.")], presentation: true, wave: 2),
        .init(type: "confirm-dialog", section: "overlays", summary: "A dialog that asks to confirm or cancel an action.", props: [
            .init(name: "open", kind: .bool, required: true, doc: "Whether the dialog is showing, usually bound to state."),
            .init(name: "title", kind: .string, required: true, doc: "Question shown to the user."),
            .init(name: "message", kind: .string, doc: "Explanatory text."),
            .init(name: "confirmTitle", kind: .string, defaultValue: .string("Confirm"), doc: "The confirming button's label."),
            .init(name: "cancelTitle", kind: .string, defaultValue: .string("Cancel"), doc: "The cancel button's label."),
            .init(name: "destructive", kind: .bool, defaultValue: .boolean(false), doc: "Mark the confirming button as destructive."),
        ], events: [
            .init(name: "onConfirm", doc: "Runs when the user confirms; set open to false in the action."),
            .init(name: "onCancel", doc: "Runs when the user cancels or dismisses; set open to false in the action."),
        ], presentation: true, wave: 2),
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

    static func event(_ name: String, for spec: PluginComponentSpec) -> PluginEventSpec? {
        spec.events.first { $0.name == name } ?? commonEvents.first { $0.name == name }
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
        func event(_ spec: PluginEventSpec) -> BridgeValue {
            .object([
                "name": .string(spec.name),
                "doc": .string(spec.doc),
                "valueKind": spec.valueKind.map { .string($0.label) } ?? .null,
                "valueFrom": spec.valueFrom.map(BridgeValue.string) ?? .null,
            ])
        }
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
                    "anchorChildren": .integer(spec.anchorChildren),
                    "childTypes": spec.childTypes.map { .array($0.map(BridgeValue.string)) } ?? .null,
                    "parentTypes": spec.parentTypes.map { .array($0.map(BridgeValue.string)) } ?? .null,
                    "minChildren": .integer(spec.minChildren),
                    "needsOneOf": .array(spec.needsOneOf.map(BridgeValue.string)),
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
