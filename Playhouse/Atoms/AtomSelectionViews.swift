import Foundation
import PlayhouseCore
import PlayhouseUI

package struct AtomPillPicker: PHView {
    package var props: PillPickerProps
    package var common = AtomCommon()
    package let onChange: (String) -> Void
    @PHState private var isExpanded = false
    @PHState private var chosen: String?
    @PHNamespace private var selection

    private var shown: String { chosen ?? props.selected }
    private var shownOption: PillPickerProps.Option? { props.options.first { $0.value == shown } }

    package var body: some PHView {
        PHHStack(spacing: 0) {
            if isExpanded {
                PHForEach(Array(props.options.enumerated()), id: \.element.value) { index, option in
                    if index > 0 {
                        PHRectangle()
                            .fill(PHColor.primary.opacity(0.18))
                            .frame(width: 1, height: 9)
                            .opacity(option.value == shown || props.options[index - 1].value == shown ? 0 : 1)
                    }
                    optionButton(option)
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                }
            } else {
                PHButton {
                    phWithAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isExpanded = true }
                } label: {
                    PHHStack(spacing: 3) {
                        PHText(shownOption?.label ?? shown)
                            .font(.system(size: 9, weight: .semibold))
                        PHImage(icon: .chevronRight)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(PHCapsule().fill(PHColor.primary.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection))
                    .frame(minHeight: 30)
                    .contentShape(PHRectangle())
                }
                .buttonStyle(.plain)
                .plainButtonHoverPointer()
                .nativeHelp((common.help ?? "{help}").replacingOccurrences(of: "{help}", with: shownOption?.help ?? ""))
                .accessibilityLabel(common.label ?? shownOption?.label ?? shown)
                .accessibilityValue(shown)
                .accessibilityIdentifier(common.testID ?? "")
            }
        }
        .padding(.horizontal, 1)
        .background(PHCapsule().fill(PHColor.primary.opacity(0.07)).frame(height: 19))
        .clipShape(PHCapsule().inset(by: -6))
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

    private func optionButton(_ option: PillPickerProps.Option) -> some PHView {
        let isSelected = option.value == shown
        return PHButton {
            if !isSelected {
                chosen = option.value
                onChange(option.value)
            }
            phWithAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { isExpanded = false }
        } label: {
            PHText(option.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? PHColor.primary : PHColor.secondary)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background {
                    if isSelected {
                        PHCapsule().fill(PHColor.primary.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection)
                    }
                }
                .frame(minHeight: 30)
                .contentShape(PHRectangle())
        }
        .buttonStyle(.plain)
        .plainButtonHoverPointer()
        .nativeHelp(option.help ?? option.label)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(option.testID ?? "")
    }

    package init(props: PillPickerProps, common: AtomCommon = AtomCommon(), onChange: @escaping (String) -> Void) {
        self.props = props
        self.common = common
        self.onChange = onChange
    }
}

/// The task item's surface. Its content sits in front of one big button that
/// owns the card chrome, so a click anywhere the content lets through (atoms
/// with `passThrough`) presses the card. `common.testID`, `label` and `hint`
/// describe that button; the card itself is an accessibility container.
package struct AtomCard<Content: PHView>: PHView {
    package var props = CardProps()
    package var common = AtomCommon()
    package let onPress: () -> Void
    package let onMenu: (String) -> Void
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        content()
            .padding(CGFloat(common.padding ?? CardProps.defaultPadding))
            .frame(maxWidth: common.fillWidth == true ? .infinity : nil, alignment: .leading)
            .background {
                PHButton(action: { DispatchQueue.main.async(execute: onPress) }) {
                    PHRoundedRectangle.phContinuous(cornerRadius: 12)
                        .fill(WorkspaceTheme.windowBackground)
                        .phShadow(color: .black.opacity(0.035), radius: 5, x: 0, y: 2)
                        .overlay {
                            PHRoundedRectangle.phContinuous(cornerRadius: 12)
                                .strokeBorder(PHColor.primary.opacity(0.07), lineWidth: 1)
                        }
                        .contentShape(PHRoundedRectangle.phContinuous(cornerRadius: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .plainButtonHoverPointer()
                .buttonStyle(.plain) // no-tooltip: clicking a card obviously opens it; VoiceOver gets the hint.
                .accessibilityLabel(common.label ?? "")
                .accessibilityHint(common.hint ?? "")
                .accessibilityIdentifier(common.testID ?? "")
            }
            .overlay(alignment: .leading) {
                if let fraction = props.meter {
                    PHGeometryReader { proxy in
                        // The gradient is drawn at the track's full height so a
                        // y-position always maps to the same color, then masked
                        // down to the filled part.
                        CPUUsageHeatmap.gradient
                            .opacity(0.15)
                        CPUUsageHeatmap.gradient
                            .phMask(alignment: .bottom) {
                                PHRectangle().frame(height: proxy.size.height * min(1, max(0, fraction)))
                            }
                    }
                    .frame(width: 4)
                    .clipShape(PHRoundedRectangle.phContinuous(cornerRadius: 12))
                    .padding(.vertical, 1)
                    .animation(.easeInOut(duration: 1.2), value: fraction)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier(props.meterTestID ?? "")
                    .accessibilityLabel(props.meterLabel ?? "")
                }
            }
            .accessibilityElement(children: .contain)
            .phContextMenu {
                PHForEach(props.menu ?? [], id: \.id) { item in
                    PHButton(item.title, icon: item.icon.map(PHIcon.init(named:)) ?? .circle, role: item.destructive == true ? .destructive : nil) {
                        onMenu(item.id)
                    }
                    .help(item.title.replacingOccurrences(of: "…", with: ""))
                    .accessibilityIdentifier(item.testID ?? "")
                }
            }
            .atomHighlight(.card)
    }

    package init(props: CardProps = CardProps(), common: AtomCommon = AtomCommon(), onPress: @escaping () -> Void, onMenu: @escaping (String) -> Void, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.onPress = onPress
        self.onMenu = onMenu
        self.content = content
    }
}

/// A section whose title collapses and expands its children. The title is a
/// button with a chevron; a click calls `onToggle` inside an animation, so
/// whatever owns `collapsed` flips it and the children animate in and out.
/// The section is one accessibility container.
package struct AtomDisclosure<Content: PHView>: PHView {
    package var props: DisclosureProps
    package var common = AtomCommon()
    package let onToggle: () -> Void
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: CGFloat(props.spacing ?? 6)) {
            PHButton {
                phWithAnimation(.easeInOut(duration: 0.22)) { onToggle() }
            } label: {
                PHHStack(spacing: 4) {
                    PHImage(icon: props.collapsed ? .chevronUp : .chevronDown)
                        .font(.system(size: 8, weight: .bold))
                        .accessibilityHidden(true)
                    PHText(verbatim: props.title)
                        .font(.system(size: 10, weight: .semibold))
                    PHSpacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(PHRectangle())
            }
            .buttonStyle(.plain)
            .plainButtonHoverPointer()
            .nativeHelp(props.collapsed ? "Expand \(props.title)" : "Collapse \(props.title)")
            .accessibilityLabel(props.title)
            .accessibilityValue(props.collapsed ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)
            .modifier(Applied(when: props.toggleTestID != nil) { $0.accessibilityIdentifier(props.toggleTestID ?? "") })
            if !props.collapsed {
                // A Group hands the transition to each child.
                PHGroup(content: content)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .atomCommon(common, atom: .disclosure, group: true)
    }

    package init(props: DisclosureProps, common: AtomCommon = AtomCommon(), onToggle: @escaping () -> Void, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.onToggle = onToggle
        self.content = content
    }
}

/// A composite atom: the column Stack with a surface that `PanelProps.stack`
/// describes, drawn by the Stack's own view, padded by
/// `PanelProps.defaultPadding` unless its `padding` is set.
package struct AtomPanel<Content: PHView>: PHView {
    package var props = PanelProps()
    package var common = AtomCommon()
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        AtomStack(props: props.stack, common: padded, atom: .panel, content: content)
    }

    private var padded: AtomCommon {
        var copy = common
        copy.padding = copy.padding ?? PanelProps.defaultPadding
        return copy
    }

    package init(props: PanelProps = PanelProps(), common: AtomCommon = AtomCommon(), @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.content = content
    }
}

/// A capsule usage bar filled to `fraction`. Drawn rather than a ProgressView:
/// an AppKit progress indicator per bar makes every accessibility query of
/// the window slow.
package struct AtomMeter: PHView {
    package var props: MeterProps
    package var common = AtomCommon()

    package var body: some PHView {
        let fraction = min(1, max(0, props.fraction))
        PHCapsule()
            .fill(PHColor.primary.opacity(props.trackOpacity ?? 0.12))
            .frame(height: CGFloat(props.thickness ?? 3))
            .overlay(alignment: .leading) {
                PHGeometryReader { proxy in
                    PHCapsule()
                        .fill(AtomColor.style(props.color) ?? PHAnyShapeStyle(PHColor.accentColor))
                        .frame(width: min(proxy.size.width, max(CGFloat(props.minFill ?? 0), proxy.size.width * fraction)))
                }
            }
            .accessibilityHidden(common.label == nil)
            .atomCommon(common, atom: .meter)
    }

    package init(props: MeterProps, common: AtomCommon = AtomCommon()) {
        self.props = props
        self.common = common
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
package struct AtomScroll<Content: PHView>: PHView {
    package var props = ScrollProps()
    package var common = AtomCommon()
    package var onEndReached: (() -> Void)?
    @PHViewBuilder package var content: () -> Content
    @PHState private var viewportHeight: CGFloat?
    /// Only whether the end is in view is state, so scrolling redraws nothing.
    @PHState private var endInView = false
    @PHState private var lastEndOffset = EndOffsetBox()
    @PHState private var space = UUID()

    package var body: some PHView {
        surface
            .modifier(Applied(when: props.maxHeight != nil) { $0.frame(maxHeight: CGFloat(props.maxHeight ?? 0)) })
            .atomCommon(common, atom: .scroll)
    }

    @PHViewBuilder
    private var surface: some PHView {
        if props.axis == "horizontal" {
            PHScrollView(.horizontal, content: content)
        } else if props.axis == "both" {
            PHScrollView([.horizontal, .vertical], content: content)
        } else if props.directContent == true {
            PHScrollView(content: content)
        } else {
            managedScroll
        }
    }

    private var managedScroll: some PHView {
        PHScrollViewReader { proxy in
            scrollView
                .onChange(of: props.scrollRequest) {
                    guard let target = props.scrollTo else { return }
                    // The request often lands with the content that grows to
                    // reach the target (a collapsed section expanding), so it
                    // scrolls on the next turn, once that content is laid out.
                    DispatchQueue.main.async {
                        phWithAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
        }
    }

    private var scrollView: some PHView {
        PHScrollView {
            PHVStack(alignment: .leading, spacing: 0) {
                PHGroup {
                    if props.lazy == true {
                        PHLazyVStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
                    } else {
                        PHVStack(alignment: .leading, spacing: props.spacing.map { CGFloat($0) }, content: content)
                    }
                }
                if onEndReached != nil {
                    PHColor.clear
                        .frame(height: 0)
                        .background(PHGeometryReader { proxy in
                            PHColor.clear.preference(key: AtomScrollEndOffsetKey.self, value: proxy.frame(in: .named(space)).minY)
                        })
                        .accessibilityHidden(true)
                }
            }
            .padding(CGFloat(props.inset ?? 0))
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverRevealScrollers()
        }
        .coordinateSpace(name: space)
        .background(PHGeometryReader { proxy in
            PHColor.clear.preference(key: AtomScrollViewportHeightKey.self, value: proxy.size.height)
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
    package final class EndOffsetBox {
        package var value: CGFloat?
        package var generation = 0
    }

    package init(props: ScrollProps = ScrollProps(), common: AtomCommon = AtomCommon(), onEndReached: (() -> Void)? = nil, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.onEndReached = onEndReached
        self.content = content
    }
}

private struct AtomScrollEndOffsetKey: PHPreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

private struct AtomScrollViewportHeightKey: PHPreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

package struct AtomDivider: PHView {
    package var common = AtomCommon()

    package var body: some PHView {
        PHDivider()
            .atomCommon(common, atom: .divider)
    }

    package init(common: AtomCommon = AtomCommon()) {
        self.common = common
    }
}

/// A row of mutually exclusive choices, each its own button so it can be
/// found by its option's `testID`. The selected one is highlighted and
/// carries the selected trait; choosing another calls `onChange` with its
