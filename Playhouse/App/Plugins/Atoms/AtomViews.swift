import SwiftUI

// The atoms' SwiftUI views. Plugins reach them through `AtomRegistry`, and
// native composites (the task item, the Agents info section, the Token
// Stats modal, the Skills page) build them directly with the same props
// structs, so both share one implementation.

/// Colors a prop may name: primary, secondary, tertiary, accent, text (the
/// conversation text color), panel and window (the workspace's panel and
/// window backgrounds), red, green, orange, blue, purple, or #RRGGBB.
enum AtomColor {
    static func style(_ name: String?) -> AnyShapeStyle? {
        guard let name else { return nil }
        switch name {
        case "primary": return AnyShapeStyle(.primary)
        case "secondary": return AnyShapeStyle(.secondary)
        case "tertiary": return AnyShapeStyle(.tertiary)
        case "accent": return AnyShapeStyle(Color.accentColor)
        case "text": return AnyShapeStyle(WorkspaceTheme.conversationText)
        case "panel": return AnyShapeStyle(WorkspaceTheme.panelBackground)
        case "window": return AnyShapeStyle(WorkspaceTheme.windowBackground)
        case "red": return AnyShapeStyle(Color.red)
        case "green": return AnyShapeStyle(Color.green)
        case "orange": return AnyShapeStyle(Color.orange)
        case "blue": return AnyShapeStyle(Color.blue)
        // GitHub's merged purple.
        case "purple": return AnyShapeStyle(Color(red: 0.64, green: 0.44, blue: 0.97))
        default:
            guard name.hasPrefix("#"), name.count == 7, let value = UInt32(name.dropFirst(), radix: 16) else { return nil }
            return AnyShapeStyle(Color(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            ))
        }
    }

    /// `color` as the #RRGGBB a prop carries.
    static func hex(_ color: Color) -> String {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let channel = { (value: CGFloat) in Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(resolved.redComponent), channel(resolved.greenComponent), channel(resolved.blueComponent))
    }
}

enum AtomFont {
    static func font(size: Double?, weight: String?, design: String? = nil, monospacedDigits: Bool = false) -> Font? {
        guard size != nil || weight != nil || design != nil || monospacedDigits else { return nil }
        let font = Font.system(size: size ?? NSFont.systemFontSize, weight: self.weight(weight), design: self.design(design))
        return monospacedDigits ? font.monospacedDigit() : font
    }

    private static func design(_ name: String?) -> Font.Design {
        switch name {
        case "monospaced": .monospaced
        case "rounded": .rounded
        default: .default
        }
    }

    private static func weight(_ name: String?) -> Font.Weight {
        switch name {
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: .regular
        }
    }
}

private struct AtomCommonModifier: ViewModifier {
    let common: AtomCommon
    /// The atom's type, for the debug highlight.
    let atom: AtomType
    /// Makes the atom one accessibility container for its children.
    var group = false
    /// Makes the atom one accessibility element whose label joins its children's.
    var combine = false

    /// False when the atom already applied its frame (a Button, inside its label).
    var frame = true

    func body(content: Content) -> some View {
        content
            .modifier(Applied(when: frame) { $0.atomFrame(common) })
            .modifier(OptionalHelp(text: common.help))
            .allowsHitTesting(common.passThrough != true)
            .modifier(AtomAccessibility(common: common, group: group, combine: combine))
            .atomHighlight(atom)
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.nativeHelp(text) } else { content }
    }
}

/// Only the accessibility fields a plugin set: an empty label or identifier
/// would replace a Text's own label or erase its children's identifiers.
private struct AtomAccessibility: ViewModifier {
    let common: AtomCommon
    let group: Bool
    let combine: Bool

    func body(content: Content) -> some View {
        content
            .modifier(Applied(when: group && !combine) { $0.accessibilityElement(children: .contain) })
            .modifier(Applied(when: combine) { $0.accessibilityElement(children: .combine) })
            .modifier(Applied(when: common.label != nil) { $0.accessibilityLabel(common.label ?? "") })
            .modifier(Applied(when: common.value != nil) { $0.accessibilityValue(common.value ?? "") })
            .modifier(Applied(when: common.hint != nil) { $0.accessibilityHint(common.hint ?? "") })
            .modifier(Applied(when: common.testID != nil) { $0.accessibilityIdentifier(common.testID ?? "") })
    }
}

private struct Applied<Modified: View>: ViewModifier {
    let when: Bool
    let transform: (AnyView) -> Modified

    init(when: Bool, _ transform: @escaping (AnyView) -> Modified) {
        self.when = when
        self.transform = transform
    }

    func body(content: Content) -> some View {
        if when { transform(AnyView(content)) } else { content }
    }
}

extension View {
    func atomCommon(_ common: AtomCommon, atom: AtomType, group: Bool = false, combine: Bool = false, frame: Bool = true) -> some View {
        modifier(AtomCommonModifier(common: common, atom: atom, group: group, combine: combine, frame: frame))
    }

    /// The common size, fill and padding props, each applied only when set.
    /// A flexible frame isn't a no-op even with every bound nil: it places a
    /// row at exactly the width the row fitted, and a row placed that way gives
    /// a nested stack one spacing too little, so its text wraps or truncates
    /// (the task item's time showed "…"). Min sizes go through `AtomMinSize`.
    func atomFrame(_ common: AtomCommon) -> some View {
        self
            .modifier(Applied(when: common.paddingX != nil) { $0.padding(.horizontal, CGFloat(common.paddingX ?? 0)) })
            .modifier(Applied(when: common.width != nil || common.height != nil) {
                $0.frame(width: common.width.map { CGFloat($0) }, height: common.height.map { CGFloat($0) })
            })
            .modifier(Applied(when: common.minWidth != nil || common.minHeight != nil) { content in
                AtomMinSize(minWidth: common.minWidth.map { CGFloat($0) }, minHeight: common.minHeight.map { CGFloat($0) }) { content }
            })
            .modifier(Applied(when: common.fillWidth == true) { $0.frame(maxWidth: .infinity, alignment: .leading) })
            .modifier(Applied(when: common.padding != nil) { $0.padding(CGFloat(common.padding ?? 0)) })
    }

    @ViewBuilder
    func atomForeground(_ color: String?) -> some View {
        if let style = AtomColor.style(color) { foregroundStyle(style) } else { self }
    }

    @ViewBuilder
    func atomFont(_ font: Font?) -> some View {
        if let font { self.font(font) } else { self }
    }

    @ViewBuilder
    func atomEmphasis(_ padding: Double?) -> some View {
        if let padding { actionButtonHoverEmphasis(padding: CGFloat(padding)) } else { self }
    }
}

/// `frame(minWidth:minHeight:)` that places its content with the proposal it
/// was given rather than the size it fitted (see `atomFrame`), centered.
private struct AtomMinSize: Layout {
    let minWidth: CGFloat?
    let minHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(clamped(proposal)) ?? .zero
        return CGSize(width: max(size.width, minWidth ?? 0), height: max(size.height, minHeight ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: clamped(proposal))
    }

    /// Like a frame's: never less than the minimum.
    private func clamped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(
            width: proposal.width.map { max($0, minWidth ?? 0) },
            height: proposal.height.map { max($0, minHeight ?? 0) }
        )
    }
}

struct AtomStack<Content: View>: View {
    var props = StackProps()
    var common = AtomCommon()
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if props.axis == "h" {
                HStack(alignment: verticalAlignment, spacing: props.spacing.map { CGFloat($0) }, content: content)
            } else {
                VStack(alignment: horizontalAlignment, spacing: props.spacing.map { CGFloat($0) }, content: content)
            }
        }
        .atomCommon(common, atom: .stack, group: props.group == true, combine: props.combine == true)
    }

    private var verticalAlignment: VerticalAlignment {
        switch props.align {
        case "top": .top
        case "bottom": .bottom
        case "baseline": .firstTextBaseline
        default: .center
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch props.align {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

struct AtomText: View {
    var props = TextProps()
    var common = AtomCommon()
    /// The raw string children, when `props.text` is unset.
    var children = ""

    var body: some View {
        let string = props.text ?? children
        Text(verbatim: string)
            .lineSpacing(CGFloat(props.lineSpacing ?? 0))
            .atomFont(AtomFont.font(size: props.size, weight: props.weight, design: props.design, monospacedDigits: props.monospacedDigits == true))
            .tracking(CGFloat(props.tracking ?? 0))
            .atomForeground(props.color)
            .lineLimit(props.lineLimit)
            .truncationMode(truncationMode)
            .contentTransition(props.numeric == true ? .numericText() : .identity)
            .animation(props.numeric == true ? .default : nil, value: string)
            .fixedSize(horizontal: false, vertical: props.wrap == true)
            .atomCommon(common, atom: .text)
    }

    private var truncationMode: Text.TruncationMode {
        switch props.truncation {
        case "head": .head
        case "middle": .middle
        default: .tail
        }
    }
}

struct AtomIcon: View {
    var props = IconProps()
    var common = AtomCommon()

    var body: some View {
        Group {
            if let asset = props.asset {
                Image(asset)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: props.name ?? "questionmark")
                    .atomFont(AtomFont.font(size: props.size, weight: props.weight))
            }
        }
        .atomForeground(props.color)
        .atomCommon(common, atom: .icon)
    }
}

struct AtomLabel: View {
    var props: LabelProps
    var common = AtomCommon()

    var body: some View {
        Label(props.text, systemImage: props.icon)
            .atomFont(AtomFont.font(size: props.size, weight: props.weight))
            .atomForeground(props.color)
            .atomCommon(common, atom: .label)
    }
}

struct AtomButton<Content: View>: View {
    var props = ButtonProps()
    var common = AtomCommon()
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        styled
            .modifier(Applied(when: props.controlSize == "small") { $0.controlSize(.small) })
            .modifier(Applied(when: props.shortcut == "default") { $0.keyboardShortcut(.defaultAction) })
            .modifier(Applied(when: props.shortcut == "cancel") { $0.keyboardShortcut(.cancelAction) })
            .padding(.horizontal, overhangs ? -CGFloat((props.emphasis ?? 0) + (common.paddingX ?? 0)) : 0)
            .padding(.vertical, overhangs ? -CGFloat(props.emphasis ?? 0) : 0)
            .disabled(props.disabled == true)
            .atomCommon(common, atom: .button, frame: false)
    }

    private var isFixedSize: Bool { common.width != nil || common.height != nil }
    /// A fixed-size capsule already spills past its slot.
    private var overhangs: Bool { props.overhang == true && !isFixedSize }

    /// The frame sizes the content: framed outside a 10 pt capsule, a 30 pt
    /// button left its "PR" 10 pt and truncated it to "…". A fixed size is the
    /// button's slot, the click target, and the capsule spills past it;
    /// otherwise the whole padded capsule is the click target.
    private var label: some View {
        var outer = common
        outer.paddingX = nil
        return content()
            .padding(.horizontal, CGFloat(common.paddingX ?? 0))
            .atomFrame(outer)
            .atomEmphasis(props.emphasis)
            .padding(isFixedSize ? -CGFloat(props.emphasis ?? 0) : 0)
            .contentShape(Rectangle())
    }

    private var role: ButtonRole? { props.destructive == true ? .destructive : nil }

    @ViewBuilder
    private var styled: some View {
        switch props.style {
        case "borderless":
            Button(role: role, action: action) { label }
                .buttonStyle(.borderless)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "bordered":
            Button(role: role, action: action) { label }
                .buttonStyle(.bordered)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "prominent":
            Button(role: role, action: action) { label }
                .buttonStyle(.borderedProminent)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        default:
            Button(role: role, action: action) { label }
                .buttonStyle(.plain)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        }
    }
}

struct AtomLink<Content: View>: View {
    var props: LinkProps
    var common = AtomCommon()
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let url = URL(string: props.url) {
            Link(destination: url, label: content)
                .buttonStyle(.borderless)
                .atomEmphasis(props.emphasis)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
                .atomCommon(common, atom: .link)
                .contentShape(Rectangle())
        } else {
            content().atomCommon(common, atom: .link)
        }
    }
}

struct AtomSpinner: View {
    var props = SpinnerProps()
    var common = AtomCommon()

    var body: some View {
        ProgressView()
            .controlSize(props.size == "mini" ? .mini : props.size == "regular" ? .regular : .small)
            .atomCommon(common, atom: .spinner)
    }
}

struct AtomSpacer: View {
    var props = SpacerProps()

    var body: some View {
        Spacer(minLength: props.minLength.map { CGFloat($0) })
            .atomHighlight(.spacer)
    }
}

/// Collapsed it shows the selected option and a chevron; clicked, it slides
/// open into every option. A choice shows at once and reverts after five
/// seconds unless `selected` catches up (a rejected choice must not stick).
/// `common.help` is the collapsed tooltip; "{help}" in it becomes the shown
/// option's help.
struct AtomPillPicker: View {
    var props: PillPickerProps
    var common = AtomCommon()
    let onChange: (String) -> Void
    @State private var isExpanded = false
    @State private var chosen: String?
    @Namespace private var selection

    private var shown: String { chosen ?? props.selected }
    private var shownOption: PillPickerProps.Option? { props.options.first { $0.value == shown } }

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                ForEach(Array(props.options.enumerated()), id: \.element.value) { index, option in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 1, height: 9)
                            .opacity(option.value == shown || props.options[index - 1].value == shown ? 0 : 1)
                    }
                    optionButton(option)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isExpanded = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(shownOption?.label ?? shown)
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection))
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp((common.help ?? "{help}").replacingOccurrences(of: "{help}", with: shownOption?.help ?? ""))
                .accessibilityLabel(common.label ?? shownOption?.label ?? shown)
                .accessibilityValue(shown)
                .accessibilityIdentifier(common.testID ?? "")
            }
        }
        .padding(.horizontal, 1)
        .background(Capsule().fill(Color.primary.opacity(0.07)).frame(height: 19))
        .clipShape(Capsule().inset(by: -6))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .onChange(of: props.selected) { _, stored in
            if stored == chosen { chosen = nil }
        }
        .task(id: chosen) {
            guard chosen != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            chosen = nil
        }
        .atomHighlight(.pillPicker)
    }

    private func optionButton(_ option: PillPickerProps.Option) -> some View {
        let isSelected = option.value == shown
        return Button {
            if !isSelected {
                chosen = option.value
                onChange(option.value)
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { isExpanded = false }
        } label: {
            Text(option.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background {
                    if isSelected {
                        Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection)
                    }
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .nativeHelp(option.help ?? option.label)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(option.testID ?? "")
    }
}

/// The task item's surface. Its content sits in front of one big button that
/// owns the card chrome, so a click anywhere the content lets through (atoms
/// with `passThrough`) presses the card. `common.testID`, `label` and `hint`
/// describe that button; the card itself is an accessibility container.
struct AtomCard<Content: View>: View {
    var props = CardProps()
    var common = AtomCommon()
    let onPress: () -> Void
    let onMenu: (String) -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(CGFloat(common.padding ?? 0))
            .frame(maxWidth: common.fillWidth == true ? .infinity : nil, alignment: .leading)
            .background {
                Button(action: { DispatchQueue.main.async(execute: onPress) }) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(WorkspaceTheme.windowBackground)
                        .shadow(color: .black.opacity(0.035), radius: 5, x: 0, y: 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .buttonHoverPointer()
                .buttonStyle(.plain) // no-tooltip: clicking a card obviously opens it; VoiceOver gets the hint.
                .accessibilityLabel(common.label ?? "")
                .accessibilityHint(common.hint ?? "")
                .accessibilityIdentifier(common.testID ?? "")
            }
            .overlay(alignment: .leading) {
                if let fraction = props.meter {
                    GeometryReader { proxy in
                        // The gradient is drawn at the track's full height so a
                        // y-position always maps to the same color, then masked
                        // down to the filled part.
                        CPUUsageHeatmap.gradient
                            .opacity(0.15)
                        CPUUsageHeatmap.gradient
                            .mask(alignment: .bottom) {
                                Rectangle().frame(height: proxy.size.height * min(1, max(0, fraction)))
                            }
                    }
                    .frame(width: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.vertical, 1)
                    .animation(.easeInOut(duration: 1.2), value: fraction)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(props.meterTestID ?? "")
                    .accessibilityLabel(props.meterLabel ?? "")
                }
            }
            .accessibilityElement(children: .contain)
            .contextMenu {
                ForEach(props.menu ?? [], id: \.id) { item in
                    Button(item.title, systemImage: item.icon ?? "circle", role: item.destructive == true ? .destructive : nil) {
                        onMenu(item.id)
                    }
                    .buttonHoverPointer()
                    .help(item.title.replacingOccurrences(of: "…", with: ""))
                    .accessibilityIdentifier(item.testID ?? "")
                }
            }
            .atomHighlight(.card)
    }
}

/// A section whose title collapses and expands its children. The title is a
/// button with a chevron; a click calls `onToggle` inside an animation, so
/// whatever owns `collapsed` flips it and the children animate in and out.
/// The section is one accessibility container.
struct AtomDisclosure<Content: View>: View {
    var props: DisclosureProps
    var common = AtomCommon()
    let onToggle: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(props.spacing ?? 6)) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { onToggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: props.collapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .accessibilityHidden(true)
                    Text(verbatim: props.title)
                        .font(.system(size: 10, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .nativeHelp(props.collapsed ? "Expand \(props.title)" : "Collapse \(props.title)")
            .accessibilityLabel(props.title)
            .accessibilityValue(props.collapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)
            .modifier(Applied(when: props.toggleTestID != nil) { $0.accessibilityIdentifier(props.toggleTestID ?? "") })
            if !props.collapsed {
                // A Group hands the transition to each child.
                Group(content: content)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .atomCommon(common, atom: .disclosure, group: true)
    }
}

/// A rounded, filled background behind a leading column of its children.
/// The frame and padding props size the panel, so the fill covers them. Its
/// minimum size is a plain frame around the column rather than `atomFrame`'s,
/// so the children stay at the top (or the center, with `align: "center"`).
struct AtomPanel<Content: View>: View {
    var props = PanelProps()
    var common = AtomCommon()
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(props.cornerRadius ?? 8), style: .continuous)
        let centered = props.align == "center"
        var framed = common
        framed.minWidth = nil
        framed.minHeight = nil
        if centered { framed.fillWidth = nil }
        return VStack(alignment: centered ? .center : .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
            .atomFrame(framed)
            .modifier(Applied(when: centered && common.fillWidth == true) { $0.frame(maxWidth: .infinity) })
            .modifier(Applied(when: common.minWidth != nil || common.minHeight != nil) {
                $0.frame(minWidth: common.minWidth.map { CGFloat($0) }, minHeight: common.minHeight.map { CGFloat($0) }, alignment: centered ? .center : .topLeading)
            })
            .background((AtomColor.style(props.fill) ?? AnyShapeStyle(.primary)).opacity(props.fillOpacity ?? 0.05), in: shape)
            .overlay {
                if let stroke = AtomColor.style(props.stroke) {
                    shape.strokeBorder(
                        stroke.opacity(props.strokeOpacity ?? 1),
                        style: StrokeStyle(lineWidth: CGFloat(props.strokeWidth ?? 1), dash: (props.dash ?? []).map { CGFloat($0) })
                    )
                }
            }
            .atomCommon(common, atom: .panel, group: props.combine != true, combine: props.combine == true, frame: false)
    }
}

/// A capsule usage bar filled to `fraction`. Drawn rather than a ProgressView:
/// an AppKit progress indicator per bar makes every accessibility query of
/// the window slow.
struct AtomMeter: View {
    var props: MeterProps
    var common = AtomCommon()

    var body: some View {
        let fraction = min(1, max(0, props.fraction))
        Capsule()
            .fill(Color.primary.opacity(props.trackOpacity ?? 0.12))
            .frame(height: CGFloat(props.thickness ?? 3))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(AtomColor.style(props.color) ?? AnyShapeStyle(Color.accentColor))
                        .frame(width: min(proxy.size.width, max(CGFloat(props.minFill ?? 0), proxy.size.width * fraction)))
                }
            }
            .accessibilityHidden(common.label == nil)
            .atomCommon(common, atom: .meter)
    }
}

/// A vertical scroll view around a leading column that fills its width.
/// `maxHeight` caps it while letting it shrink to its content; the common
/// `height` fixes it.
struct AtomScroll<Content: View>: View {
    var props = ScrollProps()
    var common = AtomCommon()
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            Group {
                if props.lazy == true {
                    LazyVStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
                } else {
                    VStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
                }
            }
            .padding(CGFloat(props.inset ?? 0))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(Applied(when: props.maxHeight != nil) { $0.frame(maxHeight: CGFloat(props.maxHeight ?? 0)) })
        .atomCommon(common, atom: .scroll)
    }
}

struct AtomDivider: View {
    var common = AtomCommon()

    var body: some View {
        Divider()
            .atomCommon(common, atom: .divider)
    }
}

/// A row of mutually exclusive choices, each its own button so it can be
/// found by its option's `testID`. The selected one is highlighted and
/// carries the selected trait; choosing another calls `onChange` with its
/// value, and the owner moves `selected`.
struct AtomChoiceBar: View {
    var props: ChoiceBarProps
    var common = AtomCommon()
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(props.options, id: \.value) { option in
                let isSelected = option.value == props.selected
                Button {
                    if !isSelected { onChange(option.value) }
                } label: {
                    Text(verbatim: option.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp(option.label)
                .modifier(Applied(when: option.testID != nil) { $0.accessibilityIdentifier(option.testID ?? "") })
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .atomCommon(common, atom: .choiceBar, group: true)
    }
}

/// A switch with no visible label. A click asks the owner to flip `isOn`
/// (`onToggle`); it shows whatever `isOn` it is given.
struct AtomToggle: View {
    var props: ToggleProps
    var common = AtomCommon()
    let onToggle: () -> Void

    var body: some View {
        Toggle(common.label ?? "", isOn: Binding(get: { props.isOn }, set: { if $0 != props.isOn { onToggle() } }))
            .toggleStyle(.switch)
            .controlSize(controlSize)
            .labelsHidden()
            .disabled(props.disabled == true)
            .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
            .atomCommon(common, atom: .toggle)
    }

    private var controlSize: ControlSize {
        switch props.size {
        case "mini": .mini
        case "small": .small
        default: .regular
        }
    }
}

/// A rounded one-line text field. It edits its own copy of `text` so typing
/// never waits on the owner, reports each edit through `onChange`, and takes
/// the owner's `text` whenever that changes.
struct AtomTextField: View {
    var props: TextFieldProps
    var common = AtomCommon()
    let onChange: (String) -> Void
    @State private var text: String

    init(props: TextFieldProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void) {
        self.props = props
        self.common = common
        self.onChange = onChange
        _text = State(initialValue: props.text)
    }

    var body: some View {
        TextField(props.placeholder ?? "", text: Binding(get: { text }, set: { text = $0; onChange($0) }))
            .textFieldStyle(.roundedBorder)
            .onChange(of: props.text) { _, owned in
                if owned != text { text = owned }
            }
            .atomCommon(common, atom: .textField)
    }
}

/// A segmented control showing `selected`; choosing a segment calls
/// `onChange` with its value. Without a `width` it fits its segments.
struct AtomSegmented: View {
    var props: SegmentedProps
    var common = AtomCommon()
    let onChange: (String) -> Void

    var body: some View {
        Picker(common.label ?? "", selection: Binding(get: { props.selected }, set: { if $0 != props.selected { onChange($0) } })) {
            ForEach(props.options, id: \.value) { option in
                Text(verbatim: option.label).tag(option.value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .modifier(Applied(when: common.width == nil) { $0.fixedSize() })
        .disabled(props.disabled == true)
        .atomCommon(common, atom: .segmented)
    }
}

/// A borderless pull-down menu labelled by an SF Symbol. The common width and
/// height frame the symbol, so they are the click target; a separator sits
/// between the item groups.
struct AtomMenu: View {
    var props: MenuProps
    var common = AtomCommon()
    let onMenu: (String) -> Void

    var body: some View {
        var label = common
        label.testID = nil
        label.label = nil
        label.help = nil
        let groups = props.items.filter { !$0.isEmpty }
        return Menu {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(group, id: \.id) { item in
                    Button(item.title, role: item.destructive == true ? .destructive : nil) { onMenu(item.id) }
                        .buttonHoverPointer()
                        .help(item.help ?? item.title)
                        .modifier(Applied(when: item.testID != nil) { $0.accessibilityIdentifier(item.testID ?? "") })
                }
            }
        } label: {
            Image(systemName: props.icon)
                .atomFont(AtomFont.font(size: props.size, weight: props.weight))
                .foregroundStyle(AtomColor.style(props.color) ?? AnyShapeStyle(.secondary))
                .atomFrame(label)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        .atomCommon(common, atom: .menu, frame: false)
    }
}

/// A leading column whose clicks and presses AppKit tells apart: a click
/// calls `onPress` and a press and hold calls `onLongPress`. It covers its
/// children, so it holds only the part of a row the press is for. It is one
/// accessibility container, so its identifier never replaces theirs.
struct AtomPressArea<Content: View>: View {
    var props = PressAreaProps()
    var common = AtomCommon()
    let onPress: () -> Void
    let onLongPress: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
            .overlay {
                PressAreaView(showsPointingHand: props.pointer == true, onClick: onPress, onLongPress: onLongPress)
            }
            .atomCommon(common, atom: .pressArea, group: true)
    }
}

/// AppKit's own mouse tracking tells a click from a press and hold: SwiftUI's
/// long-press gesture raced against a tap could stay tracking after a click
/// opened the editor, and the window then ignored every click until it was
/// minimized.
struct PressAreaView: NSViewRepresentable {
    let showsPointingHand: Bool
    let onClick: () -> Void
    let onLongPress: () -> Void

    func makeNSView(context: Context) -> PressView { PressView() }

    func updateNSView(_ view: PressView, context: Context) {
        view.onClick = onClick
        view.onLongPress = onLongPress
        if view.showsPointingHand != showsPointingHand {
            view.showsPointingHand = showsPointingHand
            view.window?.invalidateCursorRects(for: view)
        }
    }

    final class PressView: NSView {
        static let holdDuration: TimeInterval = 0.45
        var onClick: () -> Void = {}
        var onLongPress: () -> Void = {}
        var showsPointingHand = false

        override func isAccessibilityElement() -> Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if showsPointingHand { addCursorRect(bounds, cursor: .pointingHand) }
        }

        /// Tracks the press to its mouse-up here, so no gesture state outlives it.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let deadline = Date(timeIntervalSinceNow: Self.holdDuration)
            var held = false
            while true {
                let next = window.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: held ? .distantFuture : deadline,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else {
                    held = true
                    onLongPress()
                    continue
                }
                guard next.type == .leftMouseUp else { continue }
                if !held, bounds.contains(convert(next.locationInWindow, from: nil)) { onClick() }
                return
            }
        }
    }
}
