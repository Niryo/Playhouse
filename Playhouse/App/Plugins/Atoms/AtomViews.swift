import SwiftUI

// The atoms' SwiftUI views. Plugins reach them through `AtomRegistry`, and
// native composites (the task item, the Agents info section, the Token
// Stats modal, the Skills page, the repository chips and picker) build them directly with the same props
// structs, so both share one implementation.

/// Colors a prop may name: primary, secondary, tertiary, accent, text (the
/// conversation text color), panel and window (the workspace's panel and
/// window backgrounds), white, red, green, orange, blue, purple, or #RRGGBB.
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
        case "white": return AnyShapeStyle(Color.white)
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

struct AtomCommonModifier: ViewModifier {
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

struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text { content.nativeHelp(text) } else { content }
    }
}

/// Only the accessibility fields a plugin set: an empty label or identifier
/// would replace a Text's own label or erase its children's identifiers.
struct AtomAccessibility: ViewModifier {
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

struct Applied<Modified: View>: ViewModifier {
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
            .modifier(Applied(when: common.paddingY != nil) { $0.padding(.vertical, CGFloat(common.paddingY ?? 0)) })
            .modifier(Applied(when: common.width != nil || common.height != nil) {
                $0.frame(width: common.width.map { CGFloat($0) }, height: common.height.map { CGFloat($0) })
            })
            .modifier(Applied(when: common.minWidth != nil || common.minHeight != nil) { content in
                AtomMinSize(minWidth: common.minWidth.map { CGFloat($0) }, minHeight: common.minHeight.map { CGFloat($0) }) { content }
            })
            .modifier(Applied(when: common.fillWidth == true) { $0.frame(maxWidth: .infinity, alignment: .leading) })
            .modifier(Applied(when: common.padding != nil) { $0.padding(CGFloat(common.padding ?? 0)) })
            .modifier(Applied(when: common.opacity != nil) { $0.opacity(common.opacity ?? 1) })
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
struct AtomMinSize: Layout {
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

/// A row or column, which draws a surface behind its children when it has a
/// fill, border or shape prop. The frame and padding props then size the
/// surface, so it covers them, and its minimum size is a plain frame around
/// the stack rather than `atomFrame`'s, so the children stay at the start of
/// its axis and at `align` across it, or centered both ways when `align` is
/// center or unset (the default).
