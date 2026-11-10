import Foundation

/// The atoms plugins compose UI from: exactly the pieces the native
/// composites (the task item, the Agents info section, the Token Stats
/// modal, the Skills page and the repository chips and picker) are built of. Each
/// atom's props are a plain Decodable struct, decoded from a create/update
/// op's payload here and built directly by native SwiftUI code, so both reach
/// the same view (see `AtomRegistry` in Plugins/Atoms).
enum AtomType: String, CaseIterable, Sendable {
    case stack = "Stack"
    case text = "Text"
    case icon = "Icon"
    case label = "Label"
    case button = "Button"
    case link = "Link"
    case spinner = "Spinner"
    case spacer = "Spacer"
    case pillPicker = "PillPicker"
    case card = "Card"
    case disclosure = "Disclosure"
    case panel = "Panel"
    case meter = "Meter"
    case scroll = "Scroll"
    case divider = "Divider"
    case choiceBar = "ChoiceBar"
    case toggle = "Toggle"
    case textField = "TextField"
    case segmented = "Segmented"
    case menu = "Menu"
    case pressArea = "PressArea"
    case overlay = "Overlay"
    case editor = "Editor"
    case popover = "Popover"
    case stepSlider = "StepSlider"

    /// The events each atom raises; a plugin's handler for any other name is never called.
    var events: Set<String> {
        switch self {
        case .button: ["onPress"]
        case .pillPicker: ["onChange"]
        case .card: ["onPress", "onMenu"]
        case .disclosure: ["onToggle"]
        case .choiceBar, .segmented: ["onChange"]
        case .textField: ["onChange", "onSubmit", "onArrow"]
        case .toggle: ["onToggle"]
        case .menu: ["onMenu"]
        case .pressArea: ["onPress", "onLongPress"]
        case .editor: ["onChange", "onSubmit", "onSteerSubmit", "onFocusChange"]
        case .popover: ["onDismiss"]
        case .stepSlider: ["onChange"]
        case .stack, .text, .icon, .label, .link, .spinner, .spacer, .panel, .meter, .scroll, .divider, .overlay: []
        }
    }

    /// Whether the atom shows atom children. A Text holds only raw strings.
    var takesAtomChildren: Bool {
        switch self {
        case .stack, .button, .link, .card, .disclosure, .panel, .scroll, .pressArea, .overlay, .popover: true
        case .text, .icon, .label, .spinner, .spacer, .pillPicker, .meter, .divider, .choiceBar, .toggle, .textField, .segmented, .menu, .editor, .stepSlider: false
        }
    }

    /// Whether the atom lays out a composite's structure, rather than being a
    /// leaf that a native view could hold on its own. A Button or Link takes
    /// children but is a leaf. The debug atom highlight colors the two apart.
    var isContainer: Bool {
        switch self {
        case .stack, .panel, .card, .scroll, .disclosure, .overlay, .popover: true
        case .text, .icon, .label, .button, .link, .spinner, .spacer, .pillPicker, .meter, .divider, .choiceBar,
             .toggle, .textField, .segmented, .menu, .pressArea, .editor, .stepSlider: false
        }
    }

    /// Checks that `parent` shows a `child` node of that type (`PluginNode.textType` for raw strings).
    static func validateChild(parent: String, child: String) throws {
        if parent == "#root" { return }
        let isText = child == "#text"
        guard let atom = AtomType(rawValue: parent),
              isText ? atom == .text : atom.takesAtomChildren else {
            throw PluginTreeError(message: isText
                ? "<\(parent)> can't hold a string; put it in a <Text>."
                : "<\(parent)> can't hold <\(child)>.")
        }
    }

    var propKeys: Set<String> {
        switch self {
        case .stack: Self.keys(StackProps.CodingKeys.self)
        case .text: Self.keys(TextProps.CodingKeys.self)
        case .icon: Self.keys(IconProps.CodingKeys.self)
        case .label: Self.keys(LabelProps.CodingKeys.self)
        case .button: Self.keys(ButtonProps.CodingKeys.self)
        case .link: Self.keys(LinkProps.CodingKeys.self)
        case .spinner: Self.keys(SpinnerProps.CodingKeys.self)
        case .spacer: Self.keys(SpacerProps.CodingKeys.self)
        case .pillPicker: Self.keys(PillPickerProps.CodingKeys.self)
        case .card: Self.keys(CardProps.CodingKeys.self)
        case .disclosure: Self.keys(DisclosureProps.CodingKeys.self)
        case .panel: Self.keys(PanelProps.CodingKeys.self)
        case .meter: Self.keys(MeterProps.CodingKeys.self)
        case .scroll: Self.keys(ScrollProps.CodingKeys.self)
        case .divider: []
        case .choiceBar: Self.keys(ChoiceBarProps.CodingKeys.self)
        case .toggle: Self.keys(ToggleProps.CodingKeys.self)
        case .textField: Self.keys(TextFieldProps.CodingKeys.self)
        case .segmented: Self.keys(SegmentedProps.CodingKeys.self)
        case .menu: Self.keys(MenuProps.CodingKeys.self)
        case .pressArea: Self.keys(PressAreaProps.CodingKeys.self)
        case .overlay: Self.keys(OverlayProps.CodingKeys.self)
        case .editor: Self.keys(EditorProps.CodingKeys.self)
        case .popover: Self.keys(PopoverProps.CodingKeys.self)
        case .stepSlider: Self.keys(StepSliderProps.CodingKeys.self)
        }
    }

    private static func keys<Key: CodingKey & CaseIterable>(_: Key.Type) -> Set<String> {
        Set(Key.allCases.map(\.stringValue))
    }

    /// Checks a create/update op: a known atom, only its own events, only its
    /// own and the common props, each of the right type.
    static func validate(type: String, props: [String: PluginValue], events: [String]) throws {
        guard let atom = AtomType(rawValue: type) else {
            throw PluginTreeError(message: "Unknown atom <\(type)>.")
        }
        if let unknown = events.sorted().first(where: { !atom.events.contains($0) }) {
            throw PluginTreeError(message: "<\(type)> has no event \"\(unknown)\".")
        }
        let allowed = atom.propKeys.union(AtomCommon.keys)
        if let unknown = props.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw PluginTreeError(message: "<\(type)> has no prop \"\(unknown)\".")
        }
        do {
            _ = try AtomCommon.decode(props)
            switch atom {
            case .stack: _ = try StackProps.decode(props)
            case .text: _ = try TextProps.decode(props)
            case .icon: _ = try IconProps.decode(props)
            case .label: _ = try LabelProps.decode(props)
            case .button: _ = try ButtonProps.decode(props)
            case .link: _ = try LinkProps.decode(props)
            case .spinner: _ = try SpinnerProps.decode(props)
            case .spacer: _ = try SpacerProps.decode(props)
            case .pillPicker: _ = try PillPickerProps.decode(props)
            case .card: _ = try CardProps.decode(props)
            case .disclosure: _ = try DisclosureProps.decode(props)
            case .panel: _ = try PanelProps.decode(props)
            case .meter: _ = try MeterProps.decode(props)
            case .scroll: _ = try ScrollProps.decode(props)
            case .divider: _ = try DividerProps.decode(props)
            case .choiceBar: _ = try ChoiceBarProps.decode(props)
            case .toggle: _ = try ToggleProps.decode(props)
            case .textField: _ = try TextFieldProps.decode(props)
            case .segmented: _ = try SegmentedProps.decode(props)
            case .menu: _ = try MenuProps.decode(props)
            case .pressArea: _ = try PressAreaProps.decode(props)
            case .overlay: _ = try OverlayProps.decode(props)
            case .editor: _ = try EditorProps.decode(props)
            case .popover: _ = try PopoverProps.decode(props)
            case .stepSlider: _ = try StepSliderProps.decode(props)
            }
        } catch let error as DecodingError {
            throw PluginTreeError(message: "<\(type)> has an invalid prop: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

protocol AtomPropsDecodable: Decodable {}

extension AtomPropsDecodable {
    /// Decodes the props directly from their values, with no JSON in between;
    /// it runs on every create/update and every render of the atom.
    static func decode(_ props: [String: PluginValue]) throws -> Self {
        try PluginValueDecoder.decode(Self.self, from: .object(props))
    }
}

/// Props every atom takes: accessibility, tooltip and frame.
struct AtomCommon: AtomPropsDecodable, Equatable {
    /// The accessibility identifier.
    var testID: String?
    /// The accessibility label, value and hint.
    var label: String?
    var value: String?
    var hint: String?
    /// The hover tooltip.
    var help: String?
    var width: Double?
    var height: Double?
    var minWidth: Double?
    var minHeight: Double?
    /// Stretch to the available width, content leading.
    var fillWidth: Bool?
    var padding: Double?
    /// Extra horizontal padding, inside `padding`.
    var paddingX: Double?
    /// Extra vertical padding, inside `padding`.
    var paddingY: Double?
    /// Dims the atom and everything in it (0...1).
    var opacity: Double?
    /// Let clicks through to whatever is behind (the card's open button).
    var passThrough: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case testID, label, value, hint, help, width, height, minWidth, minHeight, fillWidth, padding, paddingX, paddingY, opacity, passThrough
    }

    static let keys = Set(CodingKeys.allCases.map(\.stringValue))
}

/// A row or column. `axis` is "h" or "v" (default); `align` is leading,
/// center or trailing for a column and top, center, bottom or baseline (the
/// first line of text) for a row.
/// `group` makes it one accessibility container for its children; `combine`
/// makes it one accessibility element whose label joins theirs.
struct StackProps: AtomPropsDecodable, Equatable {
    var axis: String?
    var spacing: Double?
    var align: String?
    var group: Bool?
    var combine: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case axis, spacing, align, group, combine }
}

/// A string, from `text` or the atom's raw string children. Weights: regular,
/// medium, semibold, bold; designs: default, monospaced, rounded.
struct TextProps: AtomPropsDecodable, Equatable {
    var text: String?
    var size: Double?
    var weight: String?
    var design: String?
    var color: String?
    var lineLimit: Int?
    var tracking: Double?
    var lineSpacing: Double?
    /// Grow vertically to fit instead of truncating.
    var wrap: Bool?
    /// Animate digit changes.
    var numeric: Bool?
    /// Where a cut-off string shows "…": head, middle or tail (default).
    var truncation: String?
    /// Give every digit the same width, so changing numbers don't shift.
    var monospacedDigits: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case text, size, weight, design, color, lineLimit, tracking, lineSpacing, wrap, numeric, truncation, monospacedDigits
    }
}

/// An SF Symbol (`name`) or a template image from the app's assets (`asset`).
struct IconProps: AtomPropsDecodable, Equatable {
    var name: String?
    var asset: String?
    var size: Double?
    var weight: String?
    var color: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case name, asset, size, weight, color }
}

/// An SF Symbol beside a string.
struct LabelProps: AtomPropsDecodable, Equatable {
    var text: String
    var icon: String
    var size: Double?
    var weight: String?
    var color: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, icon, size, weight, color }
}

/// A button whose label is its children. `style` is plain (default),
/// borderless, bordered (a push button), prominent (the accent-filled
/// push button) or automatic (the platform's default for where it sits); `emphasis` is the padding of the hover capsule, if any, and
/// `overhang` lets that capsule spill past the button's layout size.
/// `controlSize` "small" makes it a small control (it inherits the size
/// otherwise); `shortcut` "default" makes Return press it and "cancel"
/// makes Escape press it, window-wide, so only a window's primary or
/// dismissing action should set one. `destructive` gives it the destructive
/// role (a push button draws its title red).
struct ButtonProps: AtomPropsDecodable, Equatable {
    var style: String?
    var emphasis: Double?
    var overhang: Bool?
    var disabled: Bool?
    var controlSize: String?
    var shortcut: String?
    var destructive: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case style, emphasis, overhang, disabled, controlSize, shortcut, destructive }
}

/// Opens `url` in the browser; its label is its children.
struct LinkProps: AtomPropsDecodable, Equatable {
    var url: String
    var emphasis: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case url, emphasis }
}

/// An indeterminate progress spinner; `size` is small (default), mini or
/// regular.
struct SpinnerProps: AtomPropsDecodable, Equatable {
    var size: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case size }
}

struct SpacerProps: AtomPropsDecodable, Equatable {
    var minLength: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case minLength }
}

/// A capsule showing the selected option that expands into all of them when
/// clicked. `onChange` receives the chosen option's value.
struct PillPickerProps: AtomPropsDecodable, Equatable {
    struct Option: Codable, Equatable {
        var value: String
        var label: String
        var help: String?
        var testID: String?
    }

    var options: [Option]
    var selected: String

    enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }
}

/// The task item's surface: a rounded, bordered card that is one big button
/// (`onPress`), with a right-click menu (`onMenu` receives the item's id) and
/// an optional usage meter along its leading edge (`meter`, 0...1).
struct CardProps: AtomPropsDecodable, Equatable {
    struct MenuItem: Codable, Equatable {
        var id: String
        var title: String
        var icon: String?
        var destructive: Bool?
        var testID: String?
    }

    var menu: [MenuItem]?
    var meter: Double?
    var meterLabel: String?
    var meterTestID: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case menu, meter, meterLabel, meterTestID }
}

/// A section whose title is a button that collapses and expands its
/// children (the Agents info section). It is controlled: `collapsed` is what
/// it shows, and a click calls `onToggle` (no value; the owner flips the
/// state it holds) inside an animation, so the owner's change animates. `toggleTestID` identifies the
/// title button; `common.testID` the whole section.
struct DisclosureProps: AtomPropsDecodable, Equatable {
    var title: String
    var collapsed: Bool
    /// Between the title and each child.
    var spacing: Double?
    var toggleTestID: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case title, collapsed, spacing, toggleTestID }
}

/// A rounded, filled background behind its children, which it lays out as a
/// leading column (an agent's block in Agents info). `fill` is a color name
/// (primary by default) drawn at `fillOpacity` (0.05 by default); `stroke`
/// is a color name for a border inside its edge, drawn at `strokeOpacity`
/// (1 by default), `strokeWidth` points wide (1 by default) and dashed by
/// `dash` (on, off lengths; solid by default). `capsule` rounds its ends fully
/// instead of using `cornerRadius` (a circle when it is square). `align` is
/// `leading` (the default: children at the leading edge, and a `minHeight` keeps
/// them at the top, as a board column does) or `center` (children centered both
/// ways, as an empty state's are, with `fillWidth` stretching it without moving
/// them). It is one accessibility container, or with `combine` one element whose
/// label joins its children's.
struct PanelProps: AtomPropsDecodable, Equatable {
    var spacing: Double?
    var fill: String?
    var fillOpacity: Double?
    var cornerRadius: Double?
    var capsule: Bool?
    var stroke: String?
    var strokeOpacity: Double?
    var strokeWidth: Double?
    var dash: [Double]?
    var align: String?
    var combine: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case spacing, fill, fillOpacity, cornerRadius, capsule, stroke, strokeOpacity, strokeWidth, dash, align, combine }
}

/// A horizontal usage bar: a capsule track filled to `fraction` (0...1) in
/// `color` (accent by default), `thickness` points tall (3 by default).
/// The track is primary at `trackOpacity` (0.12 by default), and the fill is
/// never shorter than `minFill` points (0 by default). Decorative unless it
/// has an accessibility `label`.
struct MeterProps: AtomPropsDecodable, Equatable {
    var fraction: Double
    var color: String?
    var thickness: Double?
    var trackOpacity: Double?
    var minFill: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case fraction, color, thickness, trackOpacity, minFill }
}

/// A vertical scroll view around a leading column of its children (the
/// Token Stats sections), stretched to the available width. `height` (a
/// common prop) fixes its height; `maxHeight` lets it shrink to its content.
/// `inset` pads the column inside the scroll view, and `lazy` builds only
/// the children in view (the Skills page's gallery).
struct ScrollProps: AtomPropsDecodable, Equatable {
    var spacing: Double?
    var maxHeight: Double?
    var inset: Double?
    var lazy: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case spacing, maxHeight, inset, lazy }
}

/// A thin separator line across the stack it sits in.
/// It has no props of its own.
struct DividerProps: AtomPropsDecodable, Equatable {}

/// A row of mutually exclusive choices (the Token Stats sections), each its
/// own button with its option's `testID`, the selected one highlighted and
/// marked selected. It is controlled: `onChange` receives the chosen value.
struct ChoiceBarProps: AtomPropsDecodable, Equatable {
    struct Option: Codable, Equatable {
        var value: String
        var label: String
        var testID: String?
    }

    var options: [Option]
    var selected: String

    enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }
}

/// A switch (a skill's on/off). It is controlled: `isOn` is what it shows,
/// and a click calls `onToggle` (no value; the owner flips the state it
/// holds). `size` is mini, small or regular (the default); it has no visible
/// label, so give it an accessibility `label`.
struct ToggleProps: AtomPropsDecodable, Equatable {
    var isOn: Bool
    var size: String?
    var disabled: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case isOn, size, disabled }
}

/// A one-line rounded text field (the Skills page's search, the repository
/// picker's search). It is controlled: `text` is what it shows, and every
/// edit calls `onChange` with the new text. `placeholder` shows while it is
/// empty, and `autoFocus` gives it the keyboard focus when it appears. With
/// a handler, Return calls `onSubmit` and the Up and Down arrows call
/// `onArrow` with "up" or "down" instead of moving the caret.
struct TextFieldProps: AtomPropsDecodable, Equatable {
    var text: String
    var placeholder: String?
    var autoFocus: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case text, placeholder, autoFocus }
}

/// A segmented control (the Skills page's Skills | Rules | MCP and source
/// pickers). It is controlled: `selected` is what it shows, and choosing a
/// segment calls `onChange` with its value. Without a `width` it is as wide
/// as its segments.
struct SegmentedProps: AtomPropsDecodable, Equatable {
    struct Option: Codable, Equatable {
        var value: String
        var label: String
    }

    var options: [Option]
    var selected: String
    var disabled: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case options, selected, disabled }
}

/// A borderless pull-down menu whose label is an SF Symbol (`icon`, at
/// `size` and `weight`, in `color`, secondary by default), framed by the
/// common `width` and `height`. `items` are its groups, each a list of
/// items, with a separator between groups; choosing one calls `onMenu` with
/// its id.
struct MenuProps: AtomPropsDecodable, Equatable {
    struct Item: Codable, Equatable {
        var id: String
        var title: String
        var destructive: Bool?
        var help: String?
        var testID: String?
        /// Marked with a checkmark: the current choice.
        var checked: Bool?
        /// An SF Symbol shown before the title.
        var icon: String?
    }

    var icon: String?
    var size: Double?
    var weight: String?
    var color: String?
    /// Text beside the symbol (or alone), `textSize` and `textWeight` styled.
    var text: String?
    var textSize: Double?
    var textWeight: String?
    /// A second symbol between the first and the text (the mode menu's goal).
    var badgeIcon: String?
    /// The pull-down's chevron; hidden by default.
    var indicator: Bool?
    var disabled: Bool?
    var items: [[Item]]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case icon, size, weight, color, text, textSize, textWeight, badgeIcon, indicator, disabled, items
    }
}

/// A leading column of its children that tells a click (`onPress`) from a
/// press and hold (`onLongPress`), the way a skill row opens or starts
/// selecting. It takes every click on its children, so it holds only what
/// the press is for (a row's text, not its controls); `pointer` shows the
/// pointing hand over it. It is one accessibility container.
struct PressAreaProps: AtomPropsDecodable, Equatable {
    var spacing: Double?
    var pointer: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case spacing, pointer }
}

/// Its first child laid out as usual, with the rest drawn over it at `align`
/// (center by default; top, bottom, leading, trailing, topLeading,
/// topTrailing, bottomLeading or bottomTrailing), moved by `offsetX` and
/// `offsetY` points without changing its size: a repository chip's remove
/// badge on its top trailing corner. It is one accessibility container.
struct OverlayProps: AtomPropsDecodable, Equatable {
    var align: String?
    var offsetX: Double?
    var offsetY: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case align, offsetX, offsetY }
}

/// A multiline message editor that grows with its text (the composer's).
/// It is controlled: `text` is what it shows, taken whenever the owner changes
/// it while the editor isn't being typed in, and each edit calls `onChange`.
/// `onSubmit` is Return, `onSteerSubmit` is Command-Return; `onFocusChange`
/// is raised with whether the editor now has the keyboard (a boolean). `focused` moves the keyboard in,
/// each new `focusRequest` does once with the caret at the end, and
/// `autofocus` takes it when the editor appears. `placeholder` shows while
/// `text` is empty, with `placeholderTestID`. `inputTestID` and `inputLabel`
/// name the text view itself to accessibility (the common `testID` names its
/// container). The common `hint` is the editor's accessibility help. A pasted image is native-only: a plugin never
/// sees it.
struct EditorProps: AtomPropsDecodable, Equatable {
    var text: String
    var placeholder: String?
    var placeholderTestID: String?
    var enabled: Bool?
    var autofocus: Bool?
    var focused: Bool?
    var focusRequest: Int?
    var inputTestID: String?
    var inputLabel: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case text, placeholder, placeholderTestID, enabled, autofocus, focused, focusRequest, inputTestID, inputLabel
    }
}

/// A popover anchored to its first child and showing the rest in a leading
/// column (a native owner gives any content). It is
/// controlled: it is open while `isPresented` is true, and a click outside or
/// Escape calls `onDismiss`, after which the owner sets `isPresented` false.
/// `arrowEdge` (`top` default, `bottom`, `leading`, `trailing`) is the
/// anchor's edge it points at; `width` fixes the popover's. The anchor and
/// the content keep their own accessibility, so a `testID` here only names
/// the popover to a plugin's events.
struct PopoverProps: AtomPropsDecodable, Equatable {
    var isPresented: Bool
    var arrowEdge: String?
    var width: Double?

    enum CodingKeys: String, CodingKey, CaseIterable { case isPresented, arrowEdge, width }
}

/// A discrete slider over `options`, as wide as its container. It is
/// controlled: `selected` is what it shows, and moving it (a click, a drag or
/// the arrow keys) calls `onChange` with the option's value. With a single
/// option it is inert. The common `label` and `testID` name it for accessibility.
struct StepSliderProps: AtomPropsDecodable, Equatable {
    struct Option: Codable, Equatable {
        var value: String
        var label: String
    }

    var options: [Option]
    var selected: String

    enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }
}
