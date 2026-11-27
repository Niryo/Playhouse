import Foundation
import PlayhouseCore
import PlayhouseUI

package struct AtomStack<Content: PHView>: PHView {
    package var props = StackProps()
    package var common = AtomCommon()
    /// The atom it is, for the debug highlight: a composite built on it (a Panel) passes its own.
    package var atom: AtomType = .stack
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        PHGroup {
            if !props.hasSurface {
                stack
                    .atomCommon(common, atom: atom, group: props.group == true, combine: props.combine == true, summary: props.summary == true)
            } else if props.capsule == true {
                surfaced(PHCapsule())
            } else {
                surfaced(PHRoundedRectangle.phContinuous(cornerRadius: CGFloat(props.cornerRadius ?? 0)))
            }
        }
        // A place an enclosing Scroll's `scrollTo` reaches.
        .modifier(Applied(when: props.scrollID != nil) { $0.id(props.scrollID ?? "") })
    }

    private var stack: some PHView {
        PHGroup {
            if props.axis == "h" {
                PHHStack(alignment: verticalAlignment, spacing: props.spacing.map { CGFloat($0) }, content: content)
            } else {
                PHVStack(alignment: horizontalAlignment, spacing: props.spacing.map { CGFloat($0) }, content: content)
            }
        }
    }

    private func surfaced(_ shape: some PHInsettableShape) -> some PHView {
        let placement = surfacePlacement
        let stretchesLeading = placement.horizontal == .leading
        var framed = common
        framed.minWidth = nil
        framed.minHeight = nil
        if !stretchesLeading { framed.fillWidth = nil }
        let fill = props.hasFill
            ? PHAnyShapeStyle((AtomColor.style(props.fill) ?? PHAnyShapeStyle(.primary)).opacity(props.fillOpacity ?? 1))
            : PHAnyShapeStyle(PHColor.clear)
        return stack
            .atomFrame(framed)
            .modifier(Applied(when: !stretchesLeading && common.fillWidth == true) {
                $0.frame(maxWidth: .infinity, alignment: PHAlignment(horizontal: placement.horizontal, vertical: .center))
            })
            .modifier(Applied(when: common.minWidth != nil || common.minHeight != nil) {
                $0.frame(minWidth: common.minWidth.map { CGFloat($0) }, minHeight: common.minHeight.map { CGFloat($0) }, alignment: placement)
            })
            .background(fill, in: shape)
            .overlay {
                if props.hasStroke {
                    shape.strokeBorder(
                        (AtomColor.style(props.stroke) ?? PHAnyShapeStyle(.primary)).opacity(props.strokeOpacity ?? 1),
                        style: PHStrokeStyle(lineWidth: CGFloat(props.strokeWidth ?? 1), dash: (props.dash ?? []).map { CGFloat($0) })
                    )
                    // A border never takes the clicks meant for the controls it frames.
                    .allowsHitTesting(false)
                }
            }
            .atomCommon(common, atom: atom, group: props.group == true, combine: props.combine == true, summary: props.summary == true, frame: false)
    }

    /// Where the children sit inside the surface: at the start of the axis and
    /// at `align` across it, or centered both ways when `align` is center or
    /// unset (the default).
    private var surfacePlacement: PHAlignment {
        if props.axis == "h" {
            let vertical = verticalAlignment
            if vertical == .center { return .center }
            return PHAlignment(horizontal: .leading, vertical: vertical == .bottom ? .bottom : .top)
        }
        let horizontal = horizontalAlignment
        return horizontal == .center ? .center : PHAlignment(horizontal: horizontal, vertical: .top)
    }

    private var verticalAlignment: PHVerticalAlignment {
        switch props.align {
        case "top": .top
        case "bottom": .bottom
        case "baseline": .firstTextBaseline
        default: .center
        }
    }

    private var horizontalAlignment: PHHorizontalAlignment {
        switch props.align {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }

    package init(props: StackProps = StackProps(), common: AtomCommon = AtomCommon(), atom: AtomType = .stack, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.atom = atom
        self.content = content
    }
}

package struct AtomText: PHView {
    package var props = TextProps()
    package var common = AtomCommon()
    /// The raw string children, when `props.text` is unset.
    package var children = ""

    package var body: some PHView {
        let string = props.text ?? children
        PHText(verbatim: string)
            .lineSpacing(CGFloat(props.lineSpacing ?? 0))
            .multilineTextAlignment(alignment)
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

    private var truncationMode: PHText.TruncationMode {
        switch props.truncation {
        case "head": .head
        case "middle": .middle
        default: .tail
        }
    }

    private var alignment: PHTextAlignment {
        switch props.align {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }

    package init(props: TextProps = TextProps(), common: AtomCommon = AtomCommon(), children: String = "") {
        self.props = props
        self.common = common
        self.children = children
    }
}

package struct AtomIcon: PHView {
    package var props = IconProps()
    package var common = AtomCommon()

    package var body: some PHView {
        PHGroup {
            if let asset = props.asset {
                PHImage(asset)
                    .resizable()
                    .renderingMode(props.original == true ? .original : .template)
                    .scaledToFit()
            } else {
                PHImage(icon: props.name.map(PHIcon.init(named:)) ?? .questionmark)
                    .atomFont(AtomFont.font(size: props.size, weight: props.weight))
            }
        }
        .atomForeground(props.color)
        .atomCommon(common, atom: .icon)
    }

    package init(props: IconProps = IconProps(), common: AtomCommon = AtomCommon()) {
        self.props = props
        self.common = common
    }
}

/// A picture from a URL, loaded and cached by `AtomImageLoader`, showing its
/// placeholder while it loads and when it fails.
package struct AtomImage: PHView {
    package var props: ImageProps
    package var common = AtomCommon()

    /// The last load this view finished, for the URL it was made for.
    @PHState private var loaded: (url: URL, image: PHPlatformImage?)?

    package var body: some PHView {
        let source = props.source
        let image = source.flatMap { source in
            loaded?.url == source ? loaded?.image : AtomImageLoader.shared.cached(source)
        }
        let width = (props.size ?? common.width).map { CGFloat($0) }
        let height = (props.size ?? common.height).map { CGFloat($0) }
        PHColor.clear
            // Without both sides set, the picture's own aspect ratio sizes it.
            .modifier(Applied(when: width == nil || height == nil) {
                $0.aspectRatio(image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? 1, contentMode: .fit)
            })
            .frame(width: width, height: height)
            .overlay {
                if let image {
                    PHImage(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: props.contentMode == "fit" ? .fit : .fill)
                } else {
                    placeholder
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .modifier(Applied(when: common.label == nil) { $0.accessibilityHidden(true) })
            .modifier(Applied(when: common.label != nil) {
                $0.accessibilityElement(children: .ignore).accessibilityAddTraits(.isImage)
            })
            .atomCommon(common, atom: .image)
            .task(id: source) {
                guard let source, AtomImageLoader.shared.cached(source) == nil else { return }
                let image = await AtomImageLoader.shared.load(source)
                if !Task.isCancelled { loaded = (source, image) }
            }
    }

    private var shape: PHAnyShape {
        if props.circle == true { return PHAnyShape(PHCircle()) }
        if let radius = props.cornerRadius { return PHAnyShape(PHRoundedRectangle.phContinuous(cornerRadius: CGFloat(radius))) }
        return PHAnyShape(PHRectangle())
    }

    private var placeholder: some PHView {
        PHGeometryReader { proxy in
            PHZStack {
                PHRectangle().fill(.primary.opacity(0.06))
                if let name = props.placeholder {
                    PHImage(icon: PHIcon(named: name))
                        .font(.system(size: max(1, min(proxy.size.width, proxy.size.height) * 0.5)))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    package init(props: ImageProps, common: AtomCommon = AtomCommon()) {
        self.props = props
        self.common = common
    }
}

package struct AtomLabel: PHView {
    package var props: LabelProps
    package var common = AtomCommon()

    package var body: some PHView {
        PHLabel(props.text, icon: PHIcon(named: props.icon))
            .atomFont(AtomFont.font(size: props.size, weight: props.weight))
            .atomForeground(props.color)
            .atomCommon(common, atom: .label)
    }

    package init(props: LabelProps, common: AtomCommon = AtomCommon()) {
        self.props = props
        self.common = common
    }
}

package struct AtomButton<Content: PHView>: PHView {
    package var props = ButtonProps()
    package var common = AtomCommon()
    package let action: () -> Void
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        styled
            .modifier(Applied(when: props.controlSize == "small") { $0.controlSize(.small) })
            .modifier(Applied(when: props.controlSize == "large") { $0.controlSize(.large) })
            .keyboardShortcut(shortcut?.keyboardShortcut)
            .padding(.horizontal, overhangs ? -CGFloat((props.emphasis ?? 0) + (common.paddingX ?? 0)) : 0)
            .padding(.vertical, overhangs ? -CGFloat(props.emphasis ?? 0) : 0)
            .disabled(props.disabled == true)
            .modifier(Applied(when: props.selected == true) { $0.accessibilityAddTraits(.isSelected) })
            .atomCommon(helpNamingShortcut, atom: .button, frame: false)
    }

    private var shortcut: AtomShortcut? { props.shortcut.flatMap(AtomShortcut.init) }

    /// The hover hint ends by naming the shortcut.
    private var helpNamingShortcut: AtomCommon {
        var common = common
        common.help = AtomShortcut.help(common.help, shortcut: props.shortcut)
        return common
    }

    private var isFixedSize: Bool { common.width != nil || common.height != nil }
    /// A fixed-size capsule already spills past its slot.
    private var overhangs: Bool { props.overhang == true && !isFixedSize }

    /// The frame sizes the content: framed outside a 10 pt capsule, a 30 pt
    /// button left its "PR" 10 pt and truncated it to "…". A fixed size is the
    /// button's slot, the click target, and the capsule spills past it;
    /// otherwise the whole padded capsule is the click target.
    private var label: some PHView {
        var outer = common
        outer.paddingX = nil
        return content()
            .padding(.horizontal, CGFloat(common.paddingX ?? 0))
            .atomFrame(outer)
            .atomEmphasis(props.emphasis)
            .padding(isFixedSize ? -CGFloat(props.emphasis ?? 0) : 0)
            .contentShape(PHRectangle())
    }

    private var role: PHButtonRole? { props.destructive == true ? .destructive : nil }

    @PHViewBuilder
    private var styled: some PHView {
        switch props.style {
        case "borderless":
            PHButton(role: role, action: action) { label }
                .buttonStyle(.borderless)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "bordered":
            PHButton(role: role, action: action) { label }
                .buttonStyle(.bordered)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "prominent":
            PHButton(role: role, action: action) { label }
                .buttonStyle(.borderedProminent)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "link":
            PHButton(role: role, action: action) { label }
                .buttonStyle(.link)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "automatic":
            PHButton(role: role, action: action) { label }
                .buttonStyle(.automatic)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        default:
            PHButton(role: role, action: action) { label }
                .buttonStyle(.plain)
                .plainButtonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        }
    }

    package init(props: ButtonProps = ButtonProps(), common: AtomCommon = AtomCommon(), action: @escaping () -> Void, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.action = action
        self.content = content
    }
}

package struct AtomLink<Content: PHView>: PHView {
    package var props: LinkProps
    package var common = AtomCommon()
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        if let url = URL(string: props.url) {
            PHLink(destination: url, label: content)
                .buttonStyle(.borderless)
                .atomEmphasis(props.emphasis)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
                .atomCommon(common, atom: .link)
                .contentShape(PHRectangle())
        } else {
            content().atomCommon(common, atom: .link)
        }
    }

    package init(props: LinkProps, common: AtomCommon = AtomCommon(), @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.content = content
    }
}

package struct AtomSpinner: PHView {
    package var props = SpinnerProps()
    package var common = AtomCommon()

    package var body: some PHView {
        PHProgressView()
            .controlSize(props.size == "mini" ? .mini : props.size == "regular" ? .regular : .small)
            .atomCommon(common, atom: .spinner)
    }

    package init(props: SpinnerProps = SpinnerProps(), common: AtomCommon = AtomCommon()) {
        self.props = props
        self.common = common
    }
}

package struct AtomSpacer: PHView {
    package var props = SpacerProps()

    package var body: some PHView {
        PHSpacer(minLength: props.minLength.map { CGFloat($0) })
            .atomHighlight(.spacer)
    }

    package init(props: SpacerProps = SpacerProps()) {
        self.props = props
    }
}

/// Collapsed it shows the selected option and a chevron; clicked, it slides
/// open into every option. A choice shows at once and reverts after five
/// seconds unless `selected` catches up (a rejected choice must not stick).
/// `common.help` is the collapsed tooltip; "{help}" in it becomes the shown
/// option's help.
