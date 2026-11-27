import Foundation
import PlayhouseCore
import PlayhouseUI

// The atoms' SwiftUI views. Plugins reach them through `AtomRegistry`, and
// native composites (the task item, the Agents info section, the Token
// Stats modal, the Skills page, the repository chips and picker) build them directly with the same props
// structs, so both share one implementation.

/// Colors a prop may name: primary, secondary, tertiary, accent, themeAccent
/// (the workspace's own blue), text (the conversation text color), panel,
/// window and input (the workspace's panel, window and text field
/// backgrounds), control (the system control background), clear, white,
/// black, gray, red, green, orange, yellow, blue, purple, or #RRGGBB.
package enum AtomColor {
    package static func style(_ name: String?, opacity: Double? = nil) -> PHAnyShapeStyle? {
        if let opacity, let value = color(name) { return PHAnyShapeStyle(value.opacity(opacity)) }
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
        case "input": return WorkspaceTheme.inputBackground
        case "control": return PHColor(platformColor: .controlBackgroundColor)
        case "themeAccent": return WorkspaceTheme.accent
        case "clear": return PHColor.clear
        case "black": return PHColor.black
        case "gray": return PHColor.gray
        case "yellow": return PHColor.yellow
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

/// An alignment a prop names: center, leading, trailing, top, bottom,
/// topLeading, topTrailing, bottomLeading or bottomTrailing.
package enum AtomAlignment {
    package static func alignment(_ name: String?) -> PHAlignment? {
        switch name {
        case "center": .center
        case "leading": .leading
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
}

package enum AtomFont {
    package static func font(size: Double?, weight: String?, design: String? = nil, monospacedDigits: Bool = false, textStyle: String? = nil) -> PHFont? {
        if let textStyle, let style = styles[textStyle] {
            let font = PHFont.system(style, design: self.design(design), weight: weight.map(self.weight))
            return monospacedDigits ? font.monospacedDigit() : font
        }
        guard size != nil || weight != nil || design != nil || monospacedDigits else { return nil }
        let font = PHFont.system(size: size ?? PHPlatformFont.systemFontSize, weight: self.weight(weight), design: self.design(design))
        return monospacedDigits ? font.monospacedDigit() : font
    }

    private static let styles: [String: PHFont.TextStyle] = [
        "largeTitle": .largeTitle, "title": .title, "title2": .title2, "title3": .title3,
        "headline": .headline, "subheadline": .subheadline, "body": .body, "callout": .callout,
        "footnote": .footnote, "caption": .caption, "caption2": .caption2,
    ]

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
            .modifier(Applied(when: common.layoutPriority != nil) { $0.layoutPriority(common.layoutPriority ?? 0) })
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
            .modifier(Applied(when: common.decorative == true) { $0.accessibilityHidden(true) })
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
    /// `stretchAlignment` places the content of a `fillWidth`, `fillHeight`,
    /// `maxWidth` or `maxHeight` frame when `frameAlign` is unset (a surfaced
    /// Stack passes where its children sit).
    package func atomFrame(_ common: AtomCommon, stretchAlignment: PHAlignment? = nil) -> some PHView {
        let named = AtomAlignment.alignment(common.frameAlign)
        let stretches = common.fillWidth == true || common.fillHeight == true || common.maxWidth != nil || common.maxHeight != nil
        let padded = self
            .modifier(Applied(when: common.paddingX != nil) { $0.padding(.horizontal, CGFloat(common.paddingX ?? 0)) })
            .modifier(Applied(when: common.paddingY != nil) { $0.padding(.vertical, CGFloat(common.paddingY ?? 0)) })
            .modifier(Applied(when: common.hasEdgePadding) {
                $0.padding(PHEdgeInsets(
                    top: CGFloat(common.paddingTop ?? 0), leading: CGFloat(common.paddingLeading ?? 0),
                    bottom: CGFloat(common.paddingBottom ?? 0), trailing: CGFloat(common.paddingTrailing ?? 0)
                ))
            })
        let framed = padded
            .modifier(Applied(when: common.width != nil || common.height != nil) {
                $0.frame(width: common.width.map { CGFloat($0) }, height: common.height.map { CGFloat($0) }, alignment: named ?? .center)
            })
            .modifier(Applied(when: common.minWidth != nil || common.minHeight != nil) { content in
                AtomMinSize(minWidth: common.minWidth.map { CGFloat($0) }, minHeight: common.minHeight.map { CGFloat($0) }) { content }
            })
            .modifier(Applied(when: stretches) {
                $0.frame(
                    maxWidth: common.maxWidth.map { CGFloat($0) } ?? (common.fillWidth == true ? .infinity : nil),
                    maxHeight: common.maxHeight.map { CGFloat($0) } ?? (common.fillHeight == true ? .infinity : nil),
                    alignment: named ?? stretchAlignment ?? PHAlignment(horizontal: common.fillWidth == true ? .leading : .center, vertical: .center)
                )
            })
        return framed
            .modifier(Applied(when: common.padding != nil) { $0.padding(CGFloat(common.padding ?? 0)) })
            .modifier(Applied(when: common.opacity != nil) { $0.opacity(common.opacity ?? 1) })
            .modifier(Applied(when: common.fixedHeight == true) { $0.fixedSize(horizontal: false, vertical: true) })
            .modifier(Applied(when: common.scale != nil) { $0.scaleEffect(CGFloat(common.scale ?? 1)) })
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
