import Foundation

/// The atoms plugins compose UI from: exactly the pieces the native
/// composites (the task item, the Agents info section, the Token Stats
/// modal, the Skills page and the repository chips and picker) are built of. Each
/// atom's props are a plain Codable struct (`AtomProps`), decoded once from a
/// create/update op's payload here and stored on the node, or built directly by
/// native Swift code as typed props, so both reach the same view (see
/// `AtomRegistry` in Plugins/Atoms).
package enum AtomType: String, CaseIterable, Sendable {
    case stack = "Stack"
    case text = "Text"
    case markdown = "Markdown"
    case icon = "Icon"
    case image = "Image"
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
    case modal = "Modal"
    case page = "Page"
    case sidePanel = "SidePanel"
    case resizeHandle = "ResizeHandle"
    case datePicker = "DatePicker"

    /// The events each atom raises; a plugin's handler for any other name is never called.
    package var events: Set<String> {
        switch self {
        case .button: ["onPress"]
        case .stack: ["onHover"]
        case .pillPicker: ["onChange"]
        case .card: ["onPress", "onMenu"]
        case .disclosure: ["onToggle"]
        case .choiceBar, .segmented: ["onChange"]
        case .textField: ["onChange", "onSubmit", "onArrow", "onEscape"]
        case .toggle: ["onToggle"]
        case .menu: ["onMenu"]
        case .pressArea: ["onPress", "onLongPress"]
        case .editor: ["onChange", "onSubmit", "onSteerSubmit", "onFocusChange"]
        case .popover, .modal: ["onDismiss"]
        case .stepSlider: ["onChange"]
        case .scroll: ["onEndReached"]
        case .resizeHandle: ["onDrag", "onDragEnd"]
        case .datePicker: ["onChange"]
        case .text, .markdown, .icon, .image, .label, .link, .spinner, .spacer, .panel, .meter, .divider, .overlay, .page, .sidePanel: []
        }
    }

    /// Whether the atom shows atom children. A Text or Markdown holds only raw strings.
    package var takesAtomChildren: Bool {
        switch self {
        case .stack, .button, .link, .card, .disclosure, .panel, .scroll, .pressArea, .overlay, .popover, .modal, .page, .sidePanel: true
        case .text, .markdown, .icon, .image, .label, .spinner, .spacer, .pillPicker, .meter, .divider, .choiceBar, .toggle, .textField, .segmented, .menu, .editor, .stepSlider, .resizeHandle, .datePicker: false
        }
    }

    /// Whether the atom lays out a composite's structure, rather than being a
    /// leaf that a native view could hold on its own. A Button or Link takes
    /// children but is a leaf. The debug atom highlight colors the two apart.
    package var isContainer: Bool {
        switch self {
        case .stack, .panel, .card, .scroll, .disclosure, .overlay, .popover, .modal, .page, .sidePanel: true
        case .text, .markdown, .icon, .image, .label, .button, .link, .spinner, .spacer, .pillPicker, .meter, .divider, .choiceBar,
             .toggle, .textField, .segmented, .menu, .pressArea, .editor, .stepSlider, .resizeHandle, .datePicker: false
        }
    }

    /// Whether the atom shows its raw string children (`PluginNode.textType`) as its text.
    package var takesStrings: Bool { self == .text || self == .markdown }

    /// Checks that `parent` shows a `child` node of that type (`PluginNode.textType` for raw strings).
    package static func validateChild(parent: String, child: String) throws {
        if parent == "#root" { return }
        let isText = child == "#text"
        guard let atom = AtomType(rawValue: parent),
              isText ? atom.takesStrings : atom.takesAtomChildren else {
            throw PluginTreeError(message: isText
                ? "<\(parent)> can't hold a string; put it in a <Text> or <Markdown>."
                : "<\(parent)> can't hold <\(child)>.")
        }
    }

    package var propKeys: Set<String> {
        switch self {
        case .stack: Self.keys(StackProps.CodingKeys.self)
        case .text: Self.keys(TextProps.CodingKeys.self)
        case .markdown: Self.keys(MarkdownProps.CodingKeys.self)
        case .icon: Self.keys(IconProps.CodingKeys.self)
        case .image: Self.keys(ImageProps.CodingKeys.self)
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
        case .modal: Self.keys(ModalProps.CodingKeys.self)
        case .page: Self.keys(PageProps.CodingKeys.self)
        case .sidePanel: Self.keys(SidePanelProps.CodingKeys.self)
        case .resizeHandle: Self.keys(ResizeHandleProps.CodingKeys.self)
        case .datePicker: Self.keys(DatePickerProps.CodingKeys.self)
        }
    }

    private static func keys<Key: CodingKey & CaseIterable>(_: Key.Type) -> Set<String> {
        Set(Key.allCases.map(\.stringValue))
    }

    /// Checks a create/update op: a known atom, only its own events, only its
    /// own and the common props, each of the right type. Returns the decoded
    /// props, so the op's node stores them and the check is the only decode.
    package static func validate(type: String, props: [String: PluginValue], events: [String]) throws -> ResolvedAtomProps {
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
        let resolved = try decode(atom, props: props)
        switch resolved.atom {
        case let markdown as MarkdownProps: try markdown.validateFrontmatter()
        case let image as ImageProps: try image.validateURL()
        case let button as ButtonProps:
            if let shortcut = button.shortcut {
                guard let parsed = AtomShortcut(shortcut) else {
                    throw PluginTreeError(message: "<Button> has an invalid shortcut \"\(shortcut)\": use default, cancel, or cmd, ctrl or option with any other modifiers and a key, such as cmd+shift+n.")
                }
                if AppShortcut.reserved.contains(parsed) {
                    throw PluginTreeError(message: "<Button> can't take the shortcut \"\(shortcut)\" (\(parsed.display)): Playhouse uses it.")
                }
            }
        default: break
        }
        return resolved
    }

    /// Decodes a node's props, its atom's own and the common ones, with no
    /// other checks: what an op's node stores, so rendering never decodes.
    package static func decode(type: String, props: [String: PluginValue]) throws -> ResolvedAtomProps {
        guard let atom = AtomType(rawValue: type) else {
            throw PluginTreeError(message: "Unknown atom <\(type)>.")
        }
        return try decode(atom, props: props)
    }

    private static func decode(_ atom: AtomType, props: [String: PluginValue]) throws -> ResolvedAtomProps {
        func decode<Props: AtomProps>(_: Props.Type) throws -> any AtomProps { try Props.decode(props) }
        do {
            let common = try AtomCommon.decode(props)
            return ResolvedAtomProps(atom: try decode(atom.propsType), common: common)
        } catch let error as DecodingError {
            throw PluginTreeError(message: "<\(atom.rawValue)> has an invalid prop: \(Self.describe(error))")
        }
    }

    /// The struct holding the atom's own props.
    package var propsType: any AtomProps.Type {
        switch self {
        case .stack: StackProps.self
        case .text: TextProps.self
        case .markdown: MarkdownProps.self
        case .icon: IconProps.self
        case .image: ImageProps.self
        case .label: LabelProps.self
        case .button: ButtonProps.self
        case .link: LinkProps.self
        case .spinner: SpinnerProps.self
        case .spacer: SpacerProps.self
        case .pillPicker: PillPickerProps.self
        case .card: CardProps.self
        case .disclosure: DisclosureProps.self
        case .panel: PanelProps.self
        case .meter: MeterProps.self
        case .scroll: ScrollProps.self
        case .divider: DividerProps.self
        case .choiceBar: ChoiceBarProps.self
        case .toggle: ToggleProps.self
        case .textField: TextFieldProps.self
        case .segmented: SegmentedProps.self
        case .menu: MenuProps.self
        case .pressArea: PressAreaProps.self
        case .overlay: OverlayProps.self
        case .editor: EditorProps.self
        case .popover: PopoverProps.self
        case .stepSlider: StepSliderProps.self
        case .modal: ModalProps.self
        case .page: PageProps.self
        case .sidePanel: SidePanelProps.self
        case .resizeHandle: ResizeHandleProps.self
        case .datePicker: DatePickerProps.self
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

/// Props decoded from a plugin's `PluginValue`s: an atom's own (`AtomProps`)
/// and the common ones (`AtomCommon`). They hold only plain values (strings,
/// numbers, booleans and string names such as "accent"), never SwiftUI types,
/// and are Codable, so a tree can be serialized for a UI written in another
/// language.
package protocol AtomPropsCodable: Codable {}

extension AtomPropsCodable {
    /// Decodes the props directly from their values, with no JSON in between;
    /// it runs once per create/update op, never when the atom renders.
    package static func decode(_ props: [String: PluginValue]) throws -> Self {
        #if PLAYHOUSE_ATOM_BENCHMARK
        AtomCounters.decodes += 1
        #endif
        return try PluginValueDecoder.decode(Self.self, from: .object(props))
    }
}

/// One atom's own props. A plugin's arrive as a dictionary and are decoded
/// once per op; native Swift code builds them typed
/// (`PluginNode(id:props:common:)`) and they are never decoded.
package protocol AtomProps: AtomPropsCodable, Equatable {
    /// The atom these props are for.
    static var atomType: AtomType { get }
}

extension AtomProps {
    package func isEqual(to other: any AtomProps) -> Bool { (other as? Self) == self }
}

/// A node's props as its view reads them: the atom's own and the common ones.
package struct ResolvedAtomProps {
    package let atom: any AtomProps
    package let common: AtomCommon

    package init(atom: any AtomProps, common: AtomCommon) {
        self.atom = atom
        self.common = common
    }
}

#if PLAYHOUSE_ATOM_BENCHMARK
/// How often props were decoded and atom bodies evaluated, read by
/// `scripts/benchmark-atom-tree.sh`; compiled only into its builds.
package enum AtomCounters {
    package nonisolated(unsafe) static var decodes = 0
    package nonisolated(unsafe) static var bodies = 0
}
#endif

/// Props every atom takes: accessibility, tooltip and frame.
package struct AtomCommon: AtomPropsCodable, Equatable {
    /// The accessibility identifier.
    package var testID: String?
    /// The accessibility label, value and hint.
    package var label: String?
    package var value: String?
    package var hint: String?
    /// The hover tooltip.
    package var help: String?
    package var width: Double?
    package var height: Double?
    package var minWidth: Double?
    package var minHeight: Double?
    /// Stretch to the available width, content leading.
    package var fillWidth: Bool?
    /// Keep its natural size: a tight row neither wraps nor truncates it, and
    /// squeezes its other children instead (a badge beside a name).
    package var fixedSize: Bool?
    /// Preserves the full height of content while allowing it to wrap horizontally.
    package var scale: Double? = nil
    package var fixedHeight: Bool? = nil
    package var padding: Double?
    /// Extra horizontal padding, inside `padding`.
    package var paddingX: Double?
    /// Extra vertical padding, inside `padding`.
    package var paddingY: Double?
    /// Dims the atom and everything in it (0...1).
    package var opacity: Double?
    /// Let clicks through to whatever is behind (the card's open button).
    package var passThrough: Bool?
    /// Extra padding on one edge, inside `padding` and beside `paddingX` and `paddingY`.
    package var paddingTop: Double?
    package var paddingBottom: Double?
    package var paddingLeading: Double?
    package var paddingTrailing: Double?
    /// The widest and tallest it grows, in points: it takes the size it is
    /// offered up to these (`fillWidth` and `fillHeight` with no cap).
    package var maxWidth: Double?
    package var maxHeight: Double?
    /// Stretch to the available height.
    package var fillHeight: Bool?
    /// Where its content sits when its frame (`width`, `height`, `fillWidth`,
    /// `fillHeight`, `maxWidth`, `maxHeight`) is larger: center, leading,
    /// trailing, top, bottom, topLeading, topTrailing, bottomLeading or
    /// bottomTrailing. Unset, `fillWidth` and `fillHeight` keep it at the
    /// leading edge and top, and a fixed size centers it.
    package var frameAlign: String?
    /// Hidden from accessibility: a decorative atom (a status dot, a divider).
    package var decorative: Bool?
    /// Which of a row's children keeps its size when the row is tight: the
    /// highest first (0 default).
    package var layoutPriority: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable {
        case testID, label, value, hint, help, width, height, minWidth, minHeight, fillWidth, fixedSize, padding, paddingX, paddingY, opacity, passThrough
        case paddingTop, paddingBottom, paddingLeading, paddingTrailing, maxWidth, maxHeight, fillHeight, frameAlign, decorative, layoutPriority
    }

    package static let keys = Set(CodingKeys.allCases.map(\.stringValue))

    package init(testID: String? = nil, label: String? = nil, value: String? = nil, hint: String? = nil, help: String? = nil, width: Double? = nil, height: Double? = nil, minWidth: Double? = nil, minHeight: Double? = nil, maxWidth: Double? = nil, maxHeight: Double? = nil, fillWidth: Bool? = nil, fillHeight: Bool? = nil, frameAlign: String? = nil, fixedSize: Bool? = nil, layoutPriority: Double? = nil, padding: Double? = nil, paddingX: Double? = nil, paddingY: Double? = nil, paddingTop: Double? = nil, paddingBottom: Double? = nil, paddingLeading: Double? = nil, paddingTrailing: Double? = nil, opacity: Double? = nil, passThrough: Bool? = nil, decorative: Bool? = nil, fixedHeight: Bool? = nil, scale: Double? = nil) {
        self.scale = scale
        self.fixedHeight = fixedHeight
        self.testID = testID
        self.label = label
        self.value = value
        self.hint = hint
        self.help = help
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.fillWidth = fillWidth
        self.fixedSize = fixedSize
        self.padding = padding
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.opacity = opacity
        self.passThrough = passThrough
        self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom
        self.paddingLeading = paddingLeading
        self.paddingTrailing = paddingTrailing
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.fillHeight = fillHeight
        self.frameAlign = frameAlign
        self.decorative = decorative
        self.layoutPriority = layoutPriority
    }

    /// Whether it pads one edge more than the others.
    package var hasEdgePadding: Bool { paddingTop != nil || paddingBottom != nil || paddingLeading != nil || paddingTrailing != nil }
}

/// A row, column or layers. `axis` is "h", "v" (default) or "z" (children
/// drawn over each other, sized to the largest); `align` is leading, center
/// or trailing for a column, top, center, bottom or baseline (the first line
/// of text) for a row, and any `AtomAlignment` name (center default) for
/// layers. With a handler, `onHover(isHovering)` is raised as the pointer
/// enters and leaves it.
/// `scrollID` names it as a place a Scroll around it can scroll to (`scrollTo`).
/// `group` makes it one accessibility container for its children; `combine`
/// makes it one accessibility element whose label joins theirs; `summary`
/// makes it one element that reads only as its `label`, hiding its children
/// (on macOS a combined element of Texts can report them as a value that
/// hides an explicit label).
///
/// It draws nothing unless it has a surface prop. `fill` (a color name,
/// primary by default) at `fillOpacity` (1 by default) fills it when either is
/// set; a border inside its edge is drawn when any of `stroke` (a color name,
/// primary by default), `strokeOpacity` (1), `strokeWidth` (1) or `dash` (on,
/// off lengths; solid by default) is set. The shape is a rectangle rounded by
/// `cornerRadius` (0 by default), or with `capsule` fully rounded ends (a
/// circle when it is square). A Stack with a surface sizes the surface with
/// the frame and padding props, and lays its children out inside it: at the
/// start of its axis and at `align` across it (a `minHeight` column with
/// `align` leading keeps its children at the top leading corner), or, with
/// `align` center or unset (a Stack's default), centered both ways, also when
/// `fillWidth` stretches it. A fixed `width` or `height` centers them, as it
/// centers any atom's content. A color name it doesn't know draws primary.
/// `material` puts a translucent material behind the fill, `clip` clips the
/// children to the shape, and `shadow` casts a shadow; each is a surface prop.
package struct StackProps: AtomProps {
    package static let atomType = AtomType.stack

    package var axis: String?
    package var spacing: Double?
    package var align: String?
    package var group: Bool?
    package var combine: Bool?
    package var fill: String?
    package var fillOpacity: Double?
    package var cornerRadius: Double?
    package var capsule: Bool?
    package var stroke: String?
    package var strokeOpacity: Double?
    package var strokeWidth: Double?
    package var dash: [Double]?
    package var summary: Bool?
    package var scrollID: String?
    /// Includes empty space inside the surface in hit testing.
    package var hitSurface: Bool? = nil
    /// Inherited typography for children that do not set their own.
    package var textSize: Double? = nil
    package var textColor: String? = nil
    /// A platform form section heading, used with axis "section".
    package var sectionTitle: String? = nil
    /// Rounds just the top corners of the surface.
    package var topCorners: Bool? = nil
    package var lazy: Bool? = nil
    package var layout: String? = nil
    package var collapsed: Bool? = nil
    /// A translucent material behind its fill: regular, ultraThin or bar.
    package var material: String?
    /// Clips its children to its shape.
    package var clip: Bool?
    /// A black shadow behind it, blurred by `shadow` points, at
    /// `shadowOpacity` (0.33 default), moved by `shadowX` and `shadowY`.
    package var shadow: Double?
    package var shadowOpacity: Double?
    package var shadowX: Double?
    package var shadowY: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable {
        case axis, spacing, align, group, combine, summary, fill, fillOpacity, cornerRadius, capsule, stroke, strokeOpacity, strokeWidth, dash, scrollID
        case material, clip, shadow, shadowOpacity, shadowX, shadowY
    }

    /// Whether it fills its shape.
    package var hasFill: Bool { fill != nil || fillOpacity != nil }
    /// Whether it draws a border.
    package var hasStroke: Bool { stroke != nil || strokeOpacity != nil || strokeWidth != nil || dash != nil }
    /// Whether it draws a surface, and so lays its children out inside it.
    package var hasSurface: Bool { hasFill || hasStroke || cornerRadius != nil || capsule != nil || material != nil || clip != nil || shadow != nil }

    package init(axis: String? = nil, spacing: Double? = nil, align: String? = nil, group: Bool? = nil, combine: Bool? = nil, fill: String? = nil, fillOpacity: Double? = nil, cornerRadius: Double? = nil, capsule: Bool? = nil, stroke: String? = nil, strokeOpacity: Double? = nil, strokeWidth: Double? = nil, dash: [Double]? = nil, material: String? = nil, clip: Bool? = nil, shadow: Double? = nil, shadowOpacity: Double? = nil, shadowX: Double? = nil, shadowY: Double? = nil, summary: Bool? = nil, scrollID: String? = nil, hitSurface: Bool? = nil, textSize: Double? = nil, textColor: String? = nil, sectionTitle: String? = nil, topCorners: Bool? = nil, lazy: Bool? = nil, layout: String? = nil, collapsed: Bool? = nil) {
        self.layout = layout
        self.collapsed = collapsed
        self.lazy = lazy
        self.topCorners = topCorners
        self.sectionTitle = sectionTitle
        self.hitSurface = hitSurface
        self.textSize = textSize
        self.textColor = textColor
        self.material = material
        self.clip = clip
        self.shadow = shadow
        self.shadowOpacity = shadowOpacity
        self.shadowX = shadowX
        self.shadowY = shadowY
        self.axis = axis
        self.spacing = spacing
        self.align = align
        self.group = group
        self.combine = combine
        self.fill = fill
        self.fillOpacity = fillOpacity
        self.cornerRadius = cornerRadius
        self.capsule = capsule
        self.stroke = stroke
        self.strokeOpacity = strokeOpacity
        self.strokeWidth = strokeWidth
        self.dash = dash
        self.summary = summary
        self.scrollID = scrollID
    }
}

/// A string, from `text` or the atom's raw string children. Weights: regular,
/// medium, semibold, bold; designs: default, monospaced, rounded.
package struct TextProps: AtomProps {
    package static let atomType = AtomType.text

    package var text: String?
    package var size: Double?
    package var weight: String?
    package var design: String?
    package var color: String?
    package var lineLimit: Int?
    package var tracking: Double?
    package var lineSpacing: Double?
    /// Grow vertically to fit instead of truncating.
    package var wrap: Bool?
    /// Animate digit changes.
    package var numeric: Bool?
    /// Where a cut-off string shows "…": head, middle or tail (default).
    package var truncation: String?
    /// Give every digit the same width, so changing numbers don't shift.
    package var monospacedDigits: Bool?
    /// How wrapped lines line up: leading (default), center or trailing.
    package var align: String?
    /// Lets the reader select and copy the text.
    package var selectable: Bool?

    package var textStyle: String? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable {
        case text, size, weight, design, color, lineLimit, tracking, lineSpacing, wrap, numeric, truncation, monospacedDigits, align, selectable
    }

    package init(text: String? = nil, size: Double? = nil, weight: String? = nil, design: String? = nil, color: String? = nil, lineLimit: Int? = nil, tracking: Double? = nil, lineSpacing: Double? = nil, wrap: Bool? = nil, numeric: Bool? = nil, truncation: String? = nil, monospacedDigits: Bool? = nil, align: String? = nil, selectable: Bool? = nil, textStyle: String? = nil) {
        self.textStyle = textStyle
        self.selectable = selectable
        self.text = text
        self.size = size
        self.weight = weight
        self.design = design
        self.color = color
        self.lineLimit = lineLimit
        self.tracking = tracking
        self.lineSpacing = lineSpacing
        self.wrap = wrap
        self.numeric = numeric
        self.truncation = truncation
        self.monospacedDigits = monospacedDigits
        self.align = align
    }
}

/// Markdown, from `text` or the atom's raw string children, rendered as
/// formatted blocks: headings, bullet and numbered lists, quotes, fenced code
/// (in a card with a copy button), pipe tables, rules and paragraphs, with
/// bold, italic, inline code and links (opened in the default browser).
/// `size` is the body text's point size (13 by default); headings scale from
/// it. `color` colors the prose. `selectable` lets the reader select its text.
/// `frontmatter` decides what a leading `---` YAML block shows as: "table"
/// (a small table of its entries) or "hide"; unset, it is plain Markdown.
package struct MarkdownProps: AtomProps {
    package static let atomType = AtomType.markdown

    package var text: String?
    package var size: Double?
    package var color: String?
    package var selectable: Bool?
    package var frontmatter: String?

    package enum CodingKeys: String, CodingKey, CaseIterable { case text, size, color, selectable, frontmatter }

    package static let frontmatterModes = ["table", "hide"]

    /// Checks `frontmatter` names a mode, so a typo isn't silently shown as Markdown.
    @discardableResult
    package func validateFrontmatter() throws -> Self {
        if let frontmatter, !Self.frontmatterModes.contains(frontmatter) {
            throw PluginTreeError(message:
                "<Markdown> has an invalid prop: frontmatter: expected \"table\" or \"hide\", found \"\(frontmatter)\"")
        }
        return self
    }

    package init(text: String? = nil, size: Double? = nil, color: String? = nil, selectable: Bool? = nil, frontmatter: String? = nil) {
        self.text = text
        self.size = size
        self.color = color
        self.selectable = selectable
        self.frontmatter = frontmatter
    }
}

/// An SF Symbol (`name`) or a template image from the app's assets (`asset`);
/// `original` draws the asset in its own colors (the app logo) instead.
package struct IconProps: AtomProps {
    package static let atomType = AtomType.icon

    package var name: String?
    package var asset: String?
    package var size: Double?
    package var weight: String?
    package var color: String?
    package var original: Bool?

    package var textStyle: String? = nil
    /// Additional palette color for symbols with more than one layer.
    package var secondaryColor: String? = nil
    package var secondaryOpacity: Double? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case name, asset, size, weight, color, original }

    package init(name: String? = nil, asset: String? = nil, size: Double? = nil, weight: String? = nil, color: String? = nil, original: Bool? = nil, textStyle: String? = nil, secondaryColor: String? = nil, secondaryOpacity: Double? = nil) {
        self.secondaryColor = secondaryColor
        self.secondaryOpacity = secondaryOpacity
        self.textStyle = textStyle
        self.name = name
        self.asset = asset
        self.size = size
        self.weight = weight
        self.color = color
        self.original = original
    }
}

/// A picture loaded from `url`: `https`, `http` (which App Transport Security
/// lets reach only IP addresses and local hosts, as for `fetch`), a `file://`
/// path or a `data:image/…` URL. `size` makes it a square of that many points
/// (otherwise the common `width` and `height` frame it, or it takes the width
/// it is offered at the picture's aspect ratio). `contentMode` `fill` (the
/// default) covers the frame and crops, `fit` shows all of it. `cornerRadius`
/// rounds its corners and `circle` clips it to a circle (a profile picture).
/// While it loads, and when it fails, it shows `placeholder` (an SF Symbol) on
/// a faint fill, never an error. The window loads and caches it natively, so a
/// re-render or another copy of the same URL doesn't load it again. It is
/// decorative unless it has an accessibility `label`.
package struct ImageProps: AtomProps {
    package static let atomType = AtomType.image

    package var url: String
    package var size: Double?
    package var contentMode: String?
    package var cornerRadius: Double?
    package var circle: Bool?
    package var placeholder: String?

    package enum CodingKeys: String, CodingKey, CaseIterable { case url, size, contentMode, cornerRadius, circle, placeholder }

    /// The URL it loads, or nil when `url` isn't one it may load.
    package var source: URL? { try? validateURL() }

    /// Checks `url` the way `fetch` checks its URL, also allowing local files and image data.
    @discardableResult
    package func validateURL() throws -> URL {
        let invalid = PluginTreeError(message:
            "<Image> has an invalid prop: url: expected an absolute https, http, file or data:image URL, found \"\(url)\"")
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else { throw invalid }
        switch scheme {
        case "http", "https":
            guard let host = parsed.host, !host.isEmpty else { throw invalid }
        case "file":
            guard parsed.path.hasPrefix("/"), parsed.path.count > 1 else { throw invalid }
        case "data":
            guard url.dropFirst("data:".count).lowercased().hasPrefix("image/") else { throw invalid }
        default:
            throw invalid
        }
        return parsed
    }

    package init(url: String, size: Double? = nil, contentMode: String? = nil, cornerRadius: Double? = nil, circle: Bool? = nil, placeholder: String? = nil) {
        self.url = url
        self.size = size
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.circle = circle
        self.placeholder = placeholder
    }
}

/// An SF Symbol beside a string.
package struct LabelProps: AtomProps {
    package static let atomType = AtomType.label

    package var text: String
    package var icon: String
    package var size: Double?
    package var weight: String?
    package var color: String?
    package var lineLimit: Int? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case text, icon, size, weight, color }

    package init(text: String, icon: String, size: Double? = nil, weight: String? = nil, color: String? = nil, lineLimit: Int? = nil) {
        self.lineLimit = lineLimit
        self.text = text
        self.icon = icon
        self.size = size
        self.weight = weight
        self.color = color
    }
}

/// A button whose label is its children. `style` is plain (default),
/// borderless, bordered (a push button), prominent (the accent-filled
/// push button), link (accent text like a hyperlink) or automatic (the platform's default for where it sits); `emphasis` is the padding of the hover capsule, if any, and
/// `overhang` lets that capsule spill past the button's layout size.
/// `controlSize` "small" or "large" makes it a small or large control (it inherits the size
/// otherwise); `shortcut` "default" makes Return press it, "cancel" makes
/// Escape press it, and modifiers with a key ("cmd+shift+n", see
/// `AtomShortcut`) make those keys press it, window-wide, so only a window's
/// primary or dismissing action, or one it is worth a key, should set one (a
/// plugin can't take `AppShortcut.reserved`, the app's own keys); the
/// hover hint (`help`) then ends by naming the shortcut, as in "Save (⌘S)". `destructive` gives it the destructive
/// role (a push button draws its title red). `selected` marks it selected to
/// accessibility, the current choice of a row of buttons (a ChoiceBar's).
package struct ButtonProps: AtomProps {
    package static let atomType = AtomType.button

    package var style: String?
    package var emphasis: Double?
    package var overhang: Bool?
    package var disabled: Bool?
    package var controlSize: String?
    package var shortcut: String?
    package var destructive: Bool?
    package var selected: Bool?
    /// The native command title for a menu item.
    package var title: String? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case style, emphasis, overhang, disabled, controlSize, shortcut, destructive, selected }

    package init(style: String? = nil, emphasis: Double? = nil, overhang: Bool? = nil, disabled: Bool? = nil, controlSize: String? = nil, shortcut: String? = nil, destructive: Bool? = nil, selected: Bool? = nil, title: String? = nil) {
        self.title = title
        self.style = style
        self.emphasis = emphasis
        self.overhang = overhang
        self.disabled = disabled
        self.controlSize = controlSize
        self.shortcut = shortcut
        self.destructive = destructive
        self.selected = selected
    }
}

/// Opens `url` in the browser; its label is its children.
package struct LinkProps: AtomProps {
    package static let atomType = AtomType.link

    package var url: String
    package var emphasis: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable { case url, emphasis }

    package init(url: String, emphasis: Double? = nil) {
        self.url = url
        self.emphasis = emphasis
    }
}

/// An indeterminate progress spinner; `size` is small (default), mini or
/// regular.
package struct SpinnerProps: AtomProps {
    package static let atomType = AtomType.spinner

    package var size: String?

    package enum CodingKeys: String, CodingKey, CaseIterable { case size }

    package init(size: String? = nil) {
        self.size = size
    }
}

package struct SpacerProps: AtomProps {
    package static let atomType = AtomType.spacer

    package var minLength: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable { case minLength }

    package init(minLength: Double? = nil) {
        self.minLength = minLength
    }
}

/// A capsule showing the selected option that expands into all of them when
/// clicked. `onChange` receives the chosen option's value.
package struct PillPickerProps: AtomProps {
    package static let atomType = AtomType.pillPicker

    package struct Option: Codable, Equatable {
        package var value: String
        package var label: String
        package var help: String?
        package var testID: String?

        package init(value: String, label: String, help: String? = nil, testID: String? = nil) {
            self.value = value
            self.label = label
            self.help = help
            self.testID = testID
        }
    }

    package var options: [Option]
    package var selected: String

    package enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }

    package init(options: [Option], selected: String) {
        self.options = options
        self.selected = selected
    }
}

/// The task item's surface: a rounded, bordered card that is one big button
/// (`onPress`), with a right-click menu (`onMenu` receives the item's id) and
/// an optional usage meter along its leading edge (`meter`, 0...1).
package struct CardProps: AtomProps {
    package static let atomType = AtomType.card

    /// The common `padding` of a Card that sets none.
    package static let defaultPadding: Double = 14

    package struct MenuItem: Codable, Equatable {
        package var id: String
        package var title: String
        package var icon: String?
        package var destructive: Bool?
        package var testID: String?

        package init(id: String, title: String, icon: String? = nil, destructive: Bool? = nil, testID: String? = nil) {
            self.id = id
            self.title = title
            self.icon = icon
            self.destructive = destructive
            self.testID = testID
        }
    }

    package var menu: [MenuItem]?
    package var meter: Double?
    package var meterLabel: String?
    package var meterTestID: String?

    package enum CodingKeys: String, CodingKey, CaseIterable { case menu, meter, meterLabel, meterTestID }

    package init(menu: [MenuItem]? = nil, meter: Double? = nil, meterLabel: String? = nil, meterTestID: String? = nil) {
        self.menu = menu
        self.meter = meter
        self.meterLabel = meterLabel
        self.meterTestID = meterTestID
    }
}

/// A section whose title is a button that collapses and expands its
/// children (the Agents info section). It is controlled: `collapsed` is what
/// it shows, and a click calls `onToggle` (no value; the owner flips the
/// state it holds) inside an animation, so the owner's change animates. `toggleTestID` identifies the
/// title button; `common.testID` the whole section.
package struct DisclosureProps: AtomProps {
    package static let atomType = AtomType.disclosure

    package var title: String
    package var collapsed: Bool
    /// Between the title and each child.
    package var spacing: Double?
    package var toggleTestID: String?

    package enum CodingKeys: String, CodingKey, CaseIterable { case title, collapsed, spacing, toggleTestID }

    package init(title: String, collapsed: Bool, spacing: Double? = nil, toggleTestID: String? = nil) {
        self.title = title
        self.collapsed = collapsed
        self.spacing = spacing
        self.toggleTestID = toggleTestID
    }
}

/// A composite atom: shorthand for a column `Stack` with a surface and
/// `group` (an agent's block in Agents info), so everything it does a Stack
/// can do. It differs from a Stack only in its defaults: `fill` primary at
/// `fillOpacity` 0.05, `cornerRadius` 8, `align` `leading` (children at the
/// leading edge, and a `minHeight` keeps them at the top, as a board column
/// does) or `center` (centered both ways, as an empty state's are), and one
/// accessibility container (or with `combine` one element whose label joins
/// its children's). Its border is drawn only when it has a `stroke`, at
/// `strokeOpacity` (1), `strokeWidth` (1) and `dash` (solid). Unlike a Stack
/// it is padded by default: the common `padding` is `defaultPadding` unless
/// set (a native Panel sized by its own frame passes 0).
package struct PanelProps: AtomProps {
    package static let atomType = AtomType.panel

    /// The common `padding` of a Panel that sets none.
    package static let defaultPadding: Double = 12

    package var spacing: Double?
    package var fill: String?
    package var fillOpacity: Double?
    package var cornerRadius: Double?
    package var capsule: Bool?
    package var stroke: String?
    package var strokeOpacity: Double?
    package var strokeWidth: Double?
    package var dash: [Double]?
    package var align: String?
    package var combine: Bool?

    package enum CodingKeys: String, CodingKey, CaseIterable { case spacing, fill, fillOpacity, cornerRadius, capsule, stroke, strokeOpacity, strokeWidth, dash, align, combine }

    /// The Stack this Panel stands for.
    package var stack: StackProps {
        StackProps(
            axis: "v", spacing: spacing, align: align == "center" ? "center" : "leading", group: true, combine: combine,
            fill: fill ?? "primary", fillOpacity: fillOpacity ?? 0.05, cornerRadius: cornerRadius ?? 8, capsule: capsule,
            stroke: stroke,
            strokeOpacity: stroke == nil ? nil : strokeOpacity,
            strokeWidth: stroke == nil ? nil : strokeWidth,
            dash: stroke == nil ? nil : dash
        )
    }

    package init(spacing: Double? = nil, fill: String? = nil, fillOpacity: Double? = nil, cornerRadius: Double? = nil, capsule: Bool? = nil, stroke: String? = nil, strokeOpacity: Double? = nil, strokeWidth: Double? = nil, dash: [Double]? = nil, align: String? = nil, combine: Bool? = nil) {
        self.spacing = spacing
        self.fill = fill
        self.fillOpacity = fillOpacity
        self.cornerRadius = cornerRadius
        self.capsule = capsule
        self.stroke = stroke
        self.strokeOpacity = strokeOpacity
        self.strokeWidth = strokeWidth
        self.dash = dash
        self.align = align
        self.combine = combine
    }
}

/// A horizontal usage bar: a capsule track filled to `fraction` (0...1) in
/// `color` (accent by default), `thickness` points tall (3 by default).
/// The track is primary at `trackOpacity` (0.12 by default), and the fill is
/// never shorter than `minFill` points (0 by default). Decorative unless it
/// has an accessibility `label`.
package struct MeterProps: AtomProps {
    package static let atomType = AtomType.meter

    package var fraction: Double
    package var color: String?
    package var thickness: Double?
    package var trackOpacity: Double?
    package var minFill: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable { case fraction, color, thickness, trackOpacity, minFill }

    package init(fraction: Double, color: String? = nil, thickness: Double? = nil, trackOpacity: Double? = nil, minFill: Double? = nil) {
        self.fraction = fraction
        self.color = color
        self.thickness = thickness
        self.trackOpacity = trackOpacity
        self.minFill = minFill
    }
}

/// A vertical scroll view around a leading column of its children (the
/// Token Stats sections), stretched to the available width. `height` (a
/// common prop) fixes its height; `maxHeight` lets it shrink to its content.
/// `inset` pads the column inside the scroll view, and `lazy` builds only
/// the children in view (the Done archive's rows). It raises `onEndReached`
/// each time the end of its content comes into view (and once when the
/// content fits), so its owner can append the next page (the Done archive's
/// 40 at a time). Each new `scrollRequest` scrolls, animated, until the
/// descendant Stack whose `scrollID` is `scrollTo` sits at the top (the
/// Skills page's section anchors); a lazy column can reach only a Stack it
/// has built.
package struct ScrollProps: AtomProps {
    package static let atomType = AtomType.scroll

    package var spacing: Double?
    package var maxHeight: Double?
    package var inset: Double?
    package var lazy: Bool?
    package var scrollTo: String?
    package var scrollRequest: Int?

    /// A horizontal or two-axis scroll surface. The default is vertical.
    package var axis: String? = nil
    /// Lay out the supplied content directly, preserving a caller's custom layout.
    package var directContent: Bool? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case spacing, maxHeight, inset, lazy, scrollTo, scrollRequest }

    package init(spacing: Double? = nil, maxHeight: Double? = nil, inset: Double? = nil, lazy: Bool? = nil, scrollTo: String? = nil, scrollRequest: Int? = nil, axis: String? = nil, directContent: Bool? = nil) {
        self.axis = axis
        self.directContent = directContent
        self.spacing = spacing
        self.maxHeight = maxHeight
        self.inset = inset
        self.lazy = lazy
        self.scrollTo = scrollTo
        self.scrollRequest = scrollRequest
    }
}

/// A thin separator line across the stack it sits in.
/// It has no props of its own.
package struct DividerProps: AtomProps {
    package static let atomType = AtomType.divider
}

/// A row of mutually exclusive choices (the Token Stats sections), each its
/// own button with its option's `testID`, the selected one highlighted and
/// marked selected. It is controlled: `onChange` receives the chosen value.
package struct ChoiceBarProps: AtomProps {
    package static let atomType = AtomType.choiceBar

    package struct Option: Codable, Equatable {
        package var value: String
        package var label: String
        package var testID: String?

        package init(value: String, label: String, testID: String? = nil) {
            self.value = value
            self.label = label
            self.testID = testID
        }
    }

    package var options: [Option]
    package var selected: String

    package enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }

    package init(options: [Option], selected: String) {
        self.options = options
        self.selected = selected
    }
}

/// A switch (a skill's on/off). It is controlled: `isOn` is what it shows,
/// and a click calls `onToggle` (no value; the owner flips the state it
/// holds). `size` is mini, small or regular (the default); it has no visible
/// label, so give it an accessibility `label`.
package struct ToggleProps: AtomProps {
    package static let atomType = AtomType.toggle

    package var isOn: Bool
    package var size: String?
    package var disabled: Bool?

    package var showsLabel: Bool? = nil
    package var style: String? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case isOn, size, disabled }

    package init(isOn: Bool, size: String? = nil, disabled: Bool? = nil, showsLabel: Bool? = nil, style: String? = nil) {
        self.showsLabel = showsLabel
        self.style = style
        self.isOn = isOn
        self.size = size
        self.disabled = disabled
    }
}

/// A one-line rounded text field (the Skills page's search, the repository
/// picker's search). It is controlled: `text` is what it shows, and every
/// edit calls `onChange` with the new text. `placeholder` shows while it is
/// empty, and `autoFocus` gives it the keyboard focus when it appears. With
/// a handler, Return calls `onSubmit` and the Up and Down arrows call
/// `onArrow` with "up" or "down" instead of moving the caret. `style`
/// `plain` drops the rounded border, for a field inside a decorated `Stack`
/// (the Done archive's search); `rounded` is the default.
///
/// `secure` hides what is typed (a password); `multiline` lets it wrap and
/// grow down as the text does; `size` and `design` set its font; each new
/// `focusRequest` moves the keyboard into it once. With a handler, Escape
/// calls `onEscape`.
package struct TextFieldProps: AtomProps {
    package static let atomType = AtomType.textField

    package var text: String
    package var placeholder: String?
    package var autoFocus: Bool?
    package var style: String?
    package var secure: Bool?
    package var multiline: Bool?
    package var size: Double?
    package var design: String?
    package var focusRequest: Int?

    package var controlSize: String? = nil
    package var lineLimit: Int? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case text, placeholder, autoFocus, style, secure, multiline, size, design, focusRequest }

    package init(text: String, placeholder: String? = nil, autoFocus: Bool? = nil, style: String? = nil, secure: Bool? = nil, multiline: Bool? = nil, size: Double? = nil, design: String? = nil, focusRequest: Int? = nil, controlSize: String? = nil, lineLimit: Int? = nil) {
        self.controlSize = controlSize
        self.lineLimit = lineLimit
        self.text = text
        self.placeholder = placeholder
        self.autoFocus = autoFocus
        self.style = style
        self.secure = secure
        self.multiline = multiline
        self.size = size
        self.design = design
        self.focusRequest = focusRequest
    }
}

/// A segmented control (the Skills page's Skills | Rules | MCP and source
/// pickers). It is controlled: `selected` is what it shows, and choosing a
/// segment calls `onChange` with its value. Without a `width` it is as wide
/// as its segments. `style` shows the same choice as `segmented` (default),
/// `menu` (a pop-up button showing the selected option) or `radio` (a
/// column of radio buttons).
package struct SegmentedProps: AtomProps {
    package static let atomType = AtomType.segmented

    package struct Option: Codable, Equatable {
        package var value: String
        package var label: String

        package init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    package var options: [Option]
    package var selected: String
    package var disabled: Bool?
    package var style: String?

    package var showsLabel: Bool? = nil
    /// Native forms can let the picker stretch for the platform's label column.
    package var fitContent: Bool? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case options, selected, disabled, style }

    package init(options: [Option], selected: String, disabled: Bool? = nil, style: String? = nil, showsLabel: Bool? = nil, fitContent: Bool? = nil) {
        self.fitContent = fitContent
        self.showsLabel = showsLabel
        self.options = options
        self.selected = selected
        self.disabled = disabled
        self.style = style
    }
}

/// A borderless pull-down menu whose label is an SF Symbol (`icon`, at
/// `size` and `weight`, in `color`, secondary by default), framed by the
/// common `width` and `height`. `items` are its groups, each a list of
/// items, with a separator between groups; choosing one calls `onMenu` with
/// its id.
package struct MenuProps: AtomProps {
    package static let atomType = AtomType.menu

    package struct Item: Codable, Equatable {
        package var id: String
        package var title: String
        package var destructive: Bool?
        package var help: String?
        package var testID: String?
        /// Marked with a checkmark: the current choice.
        package var checked: Bool?
        /// An SF Symbol shown before the title.
        package var icon: String?
        /// Shown dimmed and can't be chosen.
        package var disabled: Bool?
        package var informational: Bool? = nil

        private enum CodingKeys: String, CodingKey {
            case id, title, destructive, help, testID, checked, icon, disabled
        }

        package init(id: String, title: String, destructive: Bool? = nil, help: String? = nil, testID: String? = nil, checked: Bool? = nil, icon: String? = nil, disabled: Bool? = nil, informational: Bool? = nil) {
            self.informational = informational
            self.id = id
            self.title = title
            self.destructive = destructive
            self.help = help
            self.testID = testID
            self.checked = checked
            self.icon = icon
            self.disabled = disabled
        }
    }

    package var icon: String?
    package var size: Double?
    package var weight: String?
    package var color: String?
    /// Text beside the symbol (or alone), `textSize` and `textWeight` styled.
    package var text: String?
    package var textSize: Double?
    package var textWeight: String?
    /// A second symbol between the first and the text (the mode menu's goal).
    package var badgeIcon: String?
    /// The pull-down's chevron; hidden by default.
    package var indicator: Bool?
    package var disabled: Bool?
    package var items: [[Item]]
    package var style: String? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable {
        case icon, size, weight, color, text, textSize, textWeight, badgeIcon, indicator, disabled, items
    }

    package init(icon: String? = nil, size: Double? = nil, weight: String? = nil, color: String? = nil, text: String? = nil, textSize: Double? = nil, textWeight: String? = nil, badgeIcon: String? = nil, indicator: Bool? = nil, disabled: Bool? = nil, items: [[Item]], style: String? = nil) {
        self.style = style
        self.icon = icon
        self.size = size
        self.weight = weight
        self.color = color
        self.text = text
        self.textSize = textSize
        self.textWeight = textWeight
        self.badgeIcon = badgeIcon
        self.indicator = indicator
        self.disabled = disabled
        self.items = items
    }
}

/// A leading column of its children that tells a click (`onPress`) from a
/// press and hold (`onLongPress`), the way a skill row opens or starts
/// selecting. It takes every click on its children, so it holds only what
/// the press is for (a row's text, not its controls); `pointer` shows the
/// pointing hand over it. It is one accessibility container.
package struct PressAreaProps: AtomProps {
    package static let atomType = AtomType.pressArea

    package var spacing: Double?
    package var pointer: Bool?

    package enum CodingKeys: String, CodingKey, CaseIterable { case spacing, pointer }

    package init(spacing: Double? = nil, pointer: Bool? = nil) {
        self.spacing = spacing
        self.pointer = pointer
    }
}

/// Its first child laid out as usual, with the rest drawn over it at `align`
/// (center by default; top, bottom, leading, trailing, topLeading,
/// topTrailing, bottomLeading or bottomTrailing), moved by `offsetX` and
/// `offsetY` points without changing its size: a repository chip's remove
/// badge on its top trailing corner. It is one accessibility container.
/// `revealOnHover` draws the overlay only while the pointer is over the
/// atom: a repository row's Replace and Add buttons.
package struct OverlayProps: AtomProps {
    package static let atomType = AtomType.overlay

    package var align: String?
    package var offsetX: Double?
    package var offsetY: Double?
    package var revealOnHover: Bool?

    package var behind: Bool? = nil
    package var group: Bool? = nil

    package enum CodingKeys: String, CodingKey, CaseIterable { case align, offsetX, offsetY, revealOnHover }

    package init(align: String? = nil, offsetX: Double? = nil, offsetY: Double? = nil, revealOnHover: Bool? = nil, behind: Bool? = nil, group: Bool? = nil) {
        self.behind = behind
        self.group = group
        self.align = align
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.revealOnHover = revealOnHover
    }
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
package struct EditorProps: AtomProps {
    package static let atomType = AtomType.editor

    package var text: String
    package var placeholder: String?
    package var placeholderTestID: String?
    package var enabled: Bool?
    package var autofocus: Bool?
    package var focused: Bool?
    package var focusRequest: Int?
    package var inputTestID: String?
    package var inputLabel: String?

    package enum CodingKeys: String, CodingKey, CaseIterable {
        case text, placeholder, placeholderTestID, enabled, autofocus, focused, focusRequest, inputTestID, inputLabel
    }

    package init(text: String, placeholder: String? = nil, placeholderTestID: String? = nil, enabled: Bool? = nil, autofocus: Bool? = nil, focused: Bool? = nil, focusRequest: Int? = nil, inputTestID: String? = nil, inputLabel: String? = nil) {
        self.text = text
        self.placeholder = placeholder
        self.placeholderTestID = placeholderTestID
        self.enabled = enabled
        self.autofocus = autofocus
        self.focused = focused
        self.focusRequest = focusRequest
        self.inputTestID = inputTestID
        self.inputLabel = inputLabel
    }
}

/// A popover anchored to its first child and showing the rest in a leading
/// column (a native owner gives any content). It is
/// controlled: it is open while `isPresented` is true, and a click outside or
/// Escape calls `onDismiss`, after which the owner sets `isPresented` false.
/// `arrowEdge` (`top` default, `bottom`, `leading`, `trailing`) is the
/// anchor's edge it points at; `width` fixes the popover's. The content is
/// padded by `inset` (`defaultInset` unless set) and a plugin's children are
/// `spacing` apart (`defaultSpacing` unless set), so content looks right with
/// no padding of its own; a native owner that pads its content passes 0. The
/// anchor and the content keep their own accessibility, so a `testID` here
/// only names the popover to a plugin's events.
///
/// With `hover` it is a hint instead: it also opens while the pointer rests
/// on the anchor for `delay` seconds (`defaultHoverDelay` unless set) and
/// closes when the pointer leaves it. A hint takes no keyboard focus and no
/// clicks away from the window, so it never raises `onDismiss` (the Skills
/// page's rows show their details this way).
package struct PopoverProps: AtomProps {
    package static let atomType = AtomType.popover

    package static let defaultInset: Double = 14
    package static let defaultSpacing: Double = 10
    package static let defaultHoverDelay: Double = 0.4

    package var isPresented: Bool
    package var arrowEdge: String?
    package var width: Double?
    package var inset: Double?
    package var spacing: Double?
    package var hover: Bool?
    package var delay: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable { case isPresented, arrowEdge, width, inset, spacing, hover, delay }

    package init(isPresented: Bool, arrowEdge: String? = nil, width: Double? = nil, inset: Double? = nil, spacing: Double? = nil, hover: Bool? = nil, delay: Double? = nil) {
        self.isPresented = isPresented
        self.arrowEdge = arrowEdge
        self.width = width
        self.inset = inset
        self.spacing = spacing
        self.hover = hover
        self.delay = delay
    }
}

/// A discrete slider over `options`, as wide as its container. It is
/// controlled: `selected` is what it shows, and moving it (a click, a drag or
/// the arrow keys) calls `onChange` with the option's value. With a single
/// option it is inert. The common `label` and `testID` name it for accessibility.
package struct StepSliderProps: AtomProps {
    package static let atomType = AtomType.stepSlider

    package struct Option: Codable, Equatable {
        package var value: String
        package var label: String

        package init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    package var options: [Option]
    package var selected: String

    package enum CodingKeys: String, CodingKey, CaseIterable { case options, selected }

    package init(options: [Option], selected: String) {
        self.options = options
        self.selected = selected
    }
}

/// A modal sheet over the window, presented from its first child, which stays
/// laid out as usual, and showing the rest in a leading column (the Token
/// Stats modal; a native owner gives any content). It is controlled: it is
/// open while `isPresented` is true, and Escape (or a native owner's content
/// dismissing itself) calls `onDismiss`, after which the owner sets
/// `isPresented` false. `width` and `height` fix the sheet's
/// size, its content at the top leading corner; without them it fits its
/// content. With a `title` the sheet starts with the app's standard modal
/// header: an optional `icon` (SF Symbol), the title, an optional `subtitle`
/// and a close button (`<testID>-close`, `modal-close` without one) that
/// calls `onDismiss`. The header and content are padded by `inset`
/// (`defaultInset` unless set, as the app's own sheets are) and `spacing`
/// apart, as are a plugin's children (`defaultSpacing` unless set); a native
/// owner whose content pads itself passes an `inset` of 0. With `dismissible`
/// false the user can't close it: the header has no close button and Escape
/// does nothing, so only the owner's own control (a required choice) closes
/// it. Its `testID` names the sheet's content column.
package struct ModalProps: AtomProps {
    package static let atomType = AtomType.modal

    package static let defaultInset: Double = 24
    package static let defaultSpacing: Double = 16

    package var isPresented: Bool
    package var width: Double?
    package var height: Double?
    package var title: String?
    package var subtitle: String?
    package var icon: String?
    package var inset: Double?
    package var spacing: Double?
    package var dismissible: Bool?

    package enum CodingKeys: String, CodingKey, CaseIterable { case isPresented, width, height, title, subtitle, icon, inset, spacing, dismissible }

    package init(isPresented: Bool, width: Double? = nil, height: Double? = nil, title: String? = nil, subtitle: String? = nil, icon: String? = nil, inset: Double? = nil, spacing: Double? = nil, dismissible: Bool? = nil) {
        self.isPresented = isPresented
        self.width = width
        self.height = height
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.inset = inset
        self.spacing = spacing
        self.dismissible = dismissible
    }
}

/// A page that slides in from the trailing edge over its first child and
/// covers all of it (a main sidebar page plugin over the board), showing the
/// rest in a leading column on the window background. The first child stays
/// laid out as usual and sizes the atom. It is controlled: the page shows
/// while `isPresented` is true, and the owner closes it with its own control
/// (the page's Back button). Its `testID` names the page.
package struct PageProps: AtomProps {
    package static let atomType = AtomType.page

    package var isPresented: Bool

    package enum CodingKeys: String, CodingKey, CaseIterable { case isPresented }

    package init(isPresented: Bool) {
        self.isPresented = isPresented
    }
}

/// A full-height panel that slides in over one edge of its first child (the
/// Done archive over the board), showing the rest in a column with no
/// spacing on the window background, a hairline along its inner edge and a
/// shadow over what it covers. `edge` is `trailing` (the default) or
/// `leading`; `width` is the panel's (340 by default). The first child stays
/// laid out as usual and sizes the atom. It is controlled: the panel shows
/// while `isPresented` is true, and the owner closes it with its own control
/// (the archive's close button). Its `testID` names the panel.
package struct SidePanelProps: AtomProps {
    package static let atomType = AtomType.sidePanel

    package var isPresented: Bool
    package var edge: String?
    package var width: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable { case isPresented, edge, width }

    package init(isPresented: Bool, edge: String? = nil, width: Double? = nil) {
        self.isPresented = isPresented
        self.edge = edge
        self.width = width
    }
}

/// An invisible strip to drag a border by (the terminal panel's and the chat
/// sidebar's edges). The pointer shows the resize cursor over it and keeps it
/// for the whole drag, so the pointer can leave the strip. `axis` "h" (the
/// default) drags left and right, "v" up and down. Its common `width` (or
/// `height` for "v") is the strip's grab area; draw the border itself with a
/// `Stack` beside or under it.
package struct ResizeHandleProps: AtomProps {
    package static let atomType = AtomType.resizeHandle

    package var axis: String?

    package enum CodingKeys: String, CodingKey, CaseIterable { case axis }

    package init(axis: String? = nil) {
        self.axis = axis
    }
}

/// A date or time field the reader edits with the keyboard or the arrows.
/// It is controlled: `date` (seconds since 1970) is what it shows, and each
/// edit calls `onChange` with the new date. `components` is `dateTime`
/// (default), `date` or `time`; `min` (seconds since 1970) is the earliest it
/// takes.
package struct DatePickerProps: AtomProps {
    package static let atomType = AtomType.datePicker

    package var date: Double
    package var components: String?
    package var min: Double?

    package enum CodingKeys: String, CodingKey, CaseIterable { case date, components, min }

    package init(date: Double, components: String? = nil, min: Double? = nil) {
        self.date = date
        self.components = components
        self.min = min
    }
}
