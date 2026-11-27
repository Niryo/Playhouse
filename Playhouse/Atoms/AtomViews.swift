import Foundation
import PlayhouseCore
import PlayhouseUI

// The atoms' SwiftUI views. Plugins reach them through `AtomRegistry`, and
// native composites (the task item, the Agents info section, the Token
// Stats modal, the Skills page, the repository chips and picker) build them directly with the same props
// structs, so both share one implementation.

/// Colors a prop may name: primary, secondary, tertiary, accent, text (the
/// conversation text color), panel and window (the workspace's panel and
/// window backgrounds), white, red, green, orange, blue, purple, or #RRGGBB.
package enum AtomColor {
    package static func style(_ name: String?) -> PHAnyShapeStyle? {
        switch name {
        case "primary": return PHAnyShapeStyle(.primary)
        case "secondary": return PHAnyShapeStyle(.secondary)
        case "tertiary": return PHAnyShapeStyle(.tertiary)
        default: return color(name).map { PHAnyShapeStyle($0) }
        }
    }

    /// A color name as AppKit text draws it, for atoms that render through an AppKit text view;
    /// the hierarchical styles map to the matching label colors.
    package static func nsColor(_ name: String?) -> PHPlatformColor? {
        switch name {
        case "primary": return .labelColor
        case "secondary": return .secondaryLabelColor
        case "tertiary": return .tertiaryLabelColor
        default: return color(name).map { PHPlatformColor($0) }
        }
    }

    /// Every named color but the hierarchical styles.
    private static func color(_ name: String?) -> PHColor? {
        guard let name else { return nil }
        switch name {
        case "accent": return PHColor.accentColor
        case "text": return WorkspaceTheme.conversationText
        case "panel": return WorkspaceTheme.panelBackground
        case "window": return WorkspaceTheme.windowBackground
        case "white": return PHColor.white
        case "red": return PHColor.red
        case "green": return PHColor.green
        case "orange": return PHColor.orange
        case "blue": return PHColor.blue
        // GitHub's merged purple.
        case "purple": return PHColor(red: 0.64, green: 0.44, blue: 0.97)
        default:
            guard name.hasPrefix("#"), name.count == 7, let value = UInt32(name.dropFirst(), radix: 16) else { return nil }
            return PHColor(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
    }

    /// `color` as the #RRGGBB a prop carries.
    package static func hex(_ color: PHColor) -> String {
        let resolved = PHPlatformColor(color).usingColorSpace(.sRGB) ?? .gray
        let channel = { (value: CGFloat) in Int((min(1, max(0, value)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(resolved.redComponent), channel(resolved.greenComponent), channel(resolved.blueComponent))
    }
}

package enum AtomFont {
    package static func font(size: Double?, weight: String?, design: String? = nil, monospacedDigits: Bool = false) -> PHFont? {
        guard size != nil || weight != nil || design != nil || monospacedDigits else { return nil }
        let font = PHFont.system(size: size ?? PHPlatformFont.systemFontSize, weight: self.weight(weight), design: self.design(design))
        return monospacedDigits ? font.monospacedDigit() : font
    }

    private static func design(_ name: String?) -> PHFont.Design {
        switch name {
        case "monospaced": .monospaced
        case "rounded": .rounded
        default: .default
        }
    }

    private static func weight(_ name: String?) -> PHFont.Weight {
        switch name {
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        default: .regular
        }
    }
}

package struct AtomCommonModifier: PHViewModifier {
    package let common: AtomCommon
    /// The atom's type, for the debug highlight.
    package let atom: AtomType
    /// Makes the atom one accessibility container for its children.
    package var group = false
    /// Makes the atom one accessibility element whose label joins its children's.
    package var combine = false
    /// Makes the atom one accessibility element that reads only as its label.
    package var summary = false

    /// False when the atom already applied its frame (a Button, inside its label).
    package var frame = true

    package func body(content: Content) -> some PHView {
        content
            .modifier(Applied(when: frame) { $0.atomFrame(common) })
            .modifier(OptionalHelp(text: common.help))
            .allowsHitTesting(common.passThrough != true)
            .modifier(AtomAccessibility(common: common, group: group, combine: combine, summary: summary))
            .atomHighlight(atom)
    }

    package init(common: AtomCommon, atom: AtomType, group: Bool = false, combine: Bool = false, summary: Bool = false, frame: Bool = true) {
        self.common = common
        self.atom = atom
        self.group = group
        self.combine = combine
        self.summary = summary
        self.frame = frame
    }
}

package struct OptionalHelp: PHViewModifier {
    package let text: String?

    package func body(content: Content) -> some PHView {
        if let text { content.nativeHelp(text) } else { content }
    }

    package init(text: String?) {
        self.text = text
    }
}

/// Only the accessibility fields a plugin set: an empty label or identifier
/// would replace a Text's own label or erase its children's identifiers.
package struct AtomAccessibility: PHViewModifier {
    package let common: AtomCommon
    package let group: Bool
    package let combine: Bool
    package var summary = false

    package func body(content: Content) -> some PHView {
        content
            .modifier(Applied(when: group && !combine && !summary) { $0.accessibilityElement(children: .contain) })
            .modifier(Applied(when: combine && !summary) { $0.accessibilityElement(children: .combine) })
            .modifier(Applied(when: summary) { $0.accessibilityElement(children: .ignore) })
            .modifier(Applied(when: common.label != nil) { $0.accessibilityLabel(common.label ?? "") })
            .modifier(Applied(when: common.value != nil) { $0.accessibilityValue(common.value ?? "") })
            .modifier(Applied(when: common.hint != nil) { $0.accessibilityHint(common.hint ?? "") })
            .modifier(Applied(when: common.testID != nil) { $0.accessibilityIdentifier(common.testID ?? "") })
    }

    package init(common: AtomCommon, group: Bool, combine: Bool, summary: Bool = false) {
        self.common = common
        self.group = group
        self.combine = combine
        self.summary = summary
    }
}

package struct Applied<Modified: PHView>: PHViewModifier {
    package let when: Bool
    package let transform: (PHAnyView) -> Modified

    package init(when: Bool, _ transform: @escaping (PHAnyView) -> Modified) {
        self.when = when
        self.transform = transform
    }

    package func body(content: Content) -> some PHView {
        if when { transform(PHAnyView(content)) } else { content }
    }
}

extension PHView {
    package func atomCommon(_ common: AtomCommon, atom: AtomType, group: Bool = false, combine: Bool = false, summary: Bool = false, frame: Bool = true) -> some PHView {
        modifier(AtomCommonModifier(common: common, atom: atom, group: group, combine: combine, summary: summary, frame: frame))
    }

    /// The common size, fill and padding props, each applied only when set.
    /// A flexible frame isn't a no-op even with every bound nil: it places a
    /// row at exactly the width the row fitted, and a row placed that way gives
    /// a nested stack one spacing too little, so its text wraps or truncates
    /// (the task item's time showed "…"). Min sizes go through `AtomMinSize`.
    package func atomFrame(_ common: AtomCommon) -> some PHView {
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
            .modifier(Applied(when: common.fixedSize == true) { $0.fixedSize() })
    }

    @PHViewBuilder
    package func atomForeground(_ color: String?) -> some PHView {
        if let style = AtomColor.style(color) { foregroundStyle(style) } else { self }
    }

    @PHViewBuilder
    package func atomFont(_ font: PHFont?) -> some PHView {
        if let font { self.font(font) } else { self }
    }

    @PHViewBuilder
    package func atomEmphasis(_ padding: Double?) -> some PHView {
        if let padding { actionButtonHoverEmphasis(padding: CGFloat(padding)) } else { self }
    }
}

/// `frame(minWidth:minHeight:)` that places its content with the proposal it
/// was given rather than the size it fitted (see `atomFrame`), centered.
package struct AtomMinSize: PHLayout {
    package let minWidth: CGFloat?
    package let minHeight: CGFloat?

    package func sizeThatFits(proposal: PHProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(clamped(proposal)) ?? .zero
        return CGSize(width: max(size.width, minWidth ?? 0), height: max(size.height, minHeight ?? 0))
    }

    package func placeSubviews(in bounds: CGRect, proposal: PHProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: clamped(proposal))
    }

    /// Like a frame's: never less than the minimum.
    private func clamped(_ proposal: PHProposedViewSize) -> PHProposedViewSize {
        PHProposedViewSize(
            width: proposal.width.map { max($0, minWidth ?? 0) },
            height: proposal.height.map { max($0, minHeight ?? 0) }
        )
    }

    package init(minWidth: CGFloat?, minHeight: CGFloat?) {
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}

/// A row or column, which draws a surface behind its children when it has a
/// fill, border or shape prop. The frame and padding props then size the
/// surface, so it covers them, and its minimum size is a plain frame around
/// the stack rather than `atomFrame`'s, so the children stay at the start of
/// its axis and at `align` across it, or centered both ways when `align` is
/// center or unset (the default).
