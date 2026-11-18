import SwiftUI

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
            .padding(CGFloat(common.padding ?? CardProps.defaultPadding))
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

/// A composite atom: the column Stack with a surface that `PanelProps.stack`
/// describes, drawn by the Stack's own view, padded by
/// `PanelProps.defaultPadding` unless its `padding` is set.
struct AtomPanel<Content: View>: View {
    var props = PanelProps()
    var common = AtomCommon()
    @ViewBuilder var content: () -> Content

    var body: some View {
        AtomStack(props: props.stack, common: padded, atom: .panel, content: content)
    }

    private var padded: AtomCommon {
        var copy = common
        copy.padding = copy.padding ?? PanelProps.defaultPadding
        return copy
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
/// `height` fixes it. Each new `scrollRequest` scrolls the Stack whose
/// `scrollID` is `scrollTo` to the top.
///
/// With `onEndReached`, a zero-height marker after the column reports where it
/// sits in the scroll view's own visible bounds, and the end is reported each
/// time that marker moves into view (or the content fits). It reads geometry
/// rather than the marker's appearance: a lazy stack inside a scroll view
/// nested in another one (a catalog page) never makes a scrolled-to marker
/// appear.
struct AtomScroll<Content: View>: View {
    var props = ScrollProps()
    var common = AtomCommon()
    var onEndReached: (() -> Void)?
    @ViewBuilder var content: () -> Content
    @State private var viewportHeight: CGFloat?
    /// Only whether the end is in view is state, so scrolling redraws nothing.
    @State private var endInView = false
    @State private var lastEndOffset = EndOffsetBox()
    @State private var space = UUID()

    var body: some View {
        ScrollViewReader { proxy in
            scrollView
                .onChange(of: props.scrollRequest) {
                    guard let target = props.scrollTo else { return }
                    // The request often lands with the content that grows to
                    // reach the target (a collapsed section expanding), so it
                    // scrolls on the next turn, once that content is laid out.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
        }
        .modifier(Applied(when: props.maxHeight != nil) { $0.frame(maxHeight: CGFloat(props.maxHeight ?? 0)) })
        .atomCommon(common, atom: .scroll)
    }

    private var scrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if props.lazy == true {
                        LazyVStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
                    } else {
                        VStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
                    }
                }
                if onEndReached != nil {
                    Color.clear
                        .frame(height: 0)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: AtomScrollEndOffsetKey.self, value: proxy.frame(in: .named(space)).minY)
                        })
                        .accessibilityHidden(true)
                }
            }
            .padding(CGFloat(props.inset ?? 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverRevealScrollers()
        }
        .coordinateSpace(name: space)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: AtomScrollViewportHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(AtomScrollEndOffsetKey.self) { offset in
            lastEndOffset.value = offset
            checkEnd()
        }
        .onPreferenceChange(AtomScrollViewportHeightKey.self) { height in
            viewportHeight = height
            checkEnd()
        }
        // An outer Scroll reads only its own marker and viewport.
        .transformPreference(AtomScrollEndOffsetKey.self) { $0 = nil }
        .transformPreference(AtomScrollViewportHeightKey.self) { $0 = nil }
        // A Scroll that goes away reports no pending end.
        .onDisappear { lastEndOffset.generation += 1 }
    }

    /// Reports the end once each time it comes into view. A lazy stack sizes
    /// itself over several layout passes as it builds rows, which can show the
    /// marker for a moment (the board's archive then asked for a second page),
    /// so the end counts as reached only while it is still in view 0.15 s later.
    private func checkEnd() {
        guard onEndReached != nil, let viewportHeight, let endOffset = lastEndOffset.value, viewportHeight > 0 else { return }
        let inView = endOffset <= viewportHeight
        guard inView != endInView else { return }
        endInView = inView
        let box = lastEndOffset
        box.generation += 1
        guard inView else { return }
        let generation = box.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard box.generation == generation else { return }
            onEndReached?()
        }
    }

    /// The marker's latest offset, and a count of the end's moves in and out
    /// of view that cancels a pending report, kept out of SwiftUI's state.
    final class EndOffsetBox {
        var value: CGFloat?
        var generation = 0
    }
}

private struct AtomScrollEndOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

private struct AtomScrollViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
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
