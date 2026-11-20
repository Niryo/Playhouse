import SwiftUI

struct AtomStack<Content: View>: View {
    var props = StackProps()
    var common = AtomCommon()
    /// The atom it is, for the debug highlight: a composite built on it (a Panel) passes its own.
    var atom: AtomType = .stack
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if !props.hasSurface {
                stack
                    .atomCommon(common, atom: atom, group: props.group == true, combine: props.combine == true, summary: props.summary == true)
            } else if props.capsule == true {
                surfaced(Capsule())
            } else {
                surfaced(RoundedRectangle(cornerRadius: CGFloat(props.cornerRadius ?? 0), style: .continuous))
            }
        }
        // A place an enclosing Scroll's `scrollTo` reaches.
        .modifier(Applied(when: props.scrollID != nil) { $0.id(props.scrollID ?? "") })
    }

    private var stack: some View {
        Group {
            if props.axis == "h" {
                HStack(alignment: verticalAlignment, spacing: props.spacing.map { CGFloat($0) }, content: content)
            } else {
                VStack(alignment: horizontalAlignment, spacing: props.spacing.map { CGFloat($0) }, content: content)
            }
        }
    }

    private func surfaced(_ shape: some InsettableShape) -> some View {
        let placement = surfacePlacement
        let stretchesLeading = placement.horizontal == .leading
        var framed = common
        framed.minWidth = nil
        framed.minHeight = nil
        if !stretchesLeading { framed.fillWidth = nil }
        let fill = props.hasFill
            ? AnyShapeStyle((AtomColor.style(props.fill) ?? AnyShapeStyle(.primary)).opacity(props.fillOpacity ?? 1))
            : AnyShapeStyle(Color.clear)
        return stack
            .atomFrame(framed)
            .modifier(Applied(when: !stretchesLeading && common.fillWidth == true) {
                $0.frame(maxWidth: .infinity, alignment: Alignment(horizontal: placement.horizontal, vertical: .center))
            })
            .modifier(Applied(when: common.minWidth != nil || common.minHeight != nil) {
                $0.frame(minWidth: common.minWidth.map { CGFloat($0) }, minHeight: common.minHeight.map { CGFloat($0) }, alignment: placement)
            })
            .background(fill, in: shape)
            .overlay {
                if props.hasStroke {
                    shape.strokeBorder(
                        (AtomColor.style(props.stroke) ?? AnyShapeStyle(.primary)).opacity(props.strokeOpacity ?? 1),
                        style: StrokeStyle(lineWidth: CGFloat(props.strokeWidth ?? 1), dash: (props.dash ?? []).map { CGFloat($0) })
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
    private var surfacePlacement: Alignment {
        if props.axis == "h" {
            let vertical = verticalAlignment
            if vertical == .center { return .center }
            return Alignment(horizontal: .leading, vertical: vertical == .bottom ? .bottom : .top)
        }
        let horizontal = horizontalAlignment
        return horizontal == .center ? .center : Alignment(horizontal: horizontal, vertical: .top)
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

    private var truncationMode: Text.TruncationMode {
        switch props.truncation {
        case "head": .head
        case "middle": .middle
        default: .tail
        }
    }

    private var alignment: TextAlignment {
        switch props.align {
        case "center": .center
        case "trailing": .trailing
        default: .leading
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
                    .renderingMode(props.original == true ? .original : .template)
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

/// A picture from a URL, loaded and cached by `AtomImageLoader`, showing its
/// placeholder while it loads and when it fails.
struct AtomImage: View {
    var props: ImageProps
    var common = AtomCommon()

    /// The last load this view finished, for the URL it was made for.
    @State private var loaded: (url: URL, image: NSImage?)?

    var body: some View {
        let source = props.source
        let image = source.flatMap { source in
            loaded?.url == source ? loaded?.image : AtomImageLoader.shared.cached(source)
        }
        let width = (props.size ?? common.width).map { CGFloat($0) }
        let height = (props.size ?? common.height).map { CGFloat($0) }
        Color.clear
            // Without both sides set, the picture's own aspect ratio sizes it.
            .modifier(Applied(when: width == nil || height == nil) {
                $0.aspectRatio(image.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 1 } ?? 1, contentMode: .fit)
            })
            .frame(width: width, height: height)
            .overlay {
                if let image {
                    Image(nsImage: image)
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

    private var shape: AnyShape {
        if props.circle == true { return AnyShape(Circle()) }
        if let radius = props.cornerRadius { return AnyShape(RoundedRectangle(cornerRadius: CGFloat(radius), style: .continuous)) }
        return AnyShape(Rectangle())
    }

    private var placeholder: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle().fill(.primary.opacity(0.06))
                if let name = props.placeholder {
                    Image(systemName: name)
                        .font(.system(size: max(1, min(proxy.size.width, proxy.size.height) * 0.5)))
                        .foregroundStyle(.secondary)
                }
            }
        }
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
            .modifier(Applied(when: props.controlSize == "large") { $0.controlSize(.large) })
            .keyboardShortcut(shortcut?.keyboardShortcut)
            .padding(.horizontal, overhangs ? -CGFloat((props.emphasis ?? 0) + (common.paddingX ?? 0)) : 0)
            .padding(.vertical, overhangs ? -CGFloat(props.emphasis ?? 0) : 0)
            .disabled(props.disabled == true)
            .modifier(Applied(when: props.selected == true) { $0.accessibilityAddTraits(.isSelected) })
            .atomCommon(helpNamingShortcut, atom: .button, frame: false)
            // Outside the button's accessibility element, so the swelling ring
            // never changes the frame the button reports.
            .modifier(Applied(when: props.pulse == true && props.disabled != true) { $0.modifier(AtomPulse()) })
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
        case "link":
            Button(role: role, action: action) { label }
                .buttonStyle(.link)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        case "automatic":
            Button(role: role, action: action) { label }
                .buttonStyle(.automatic)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        default:
            Button(role: role, action: action) { label }
                .buttonStyle(.plain)
                .buttonHoverPointer() // no-tooltip: the atom's help prop sets it, through atomCommon.
        }
    }
}

/// A Button's `pulse`: an accent ring that swells out from the button's edge
/// and fades, over and over, without changing its layout or click target.
private struct AtomPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(reduceMotion ? -3 : expanded ? -9 : -1)
                .opacity(reduceMotion ? 0.55 : expanded ? 0 : 0.8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { expanded = true }
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
