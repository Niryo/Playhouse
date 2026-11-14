import SwiftUI

struct OverlayHoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            self.area = area
            // A newly installed area does not send an enter for a stationary pointer.
            // Defer the state update until SwiftUI has finished laying out the view.
            DispatchQueue.main.async { [weak self] in self?.syncHover() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.syncHover() }
        }

        private func syncHover() {
            guard let window, window.isKeyWindow else { onChange(false); return }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            onChange(visibleRect.contains(point))
        }

        override func mouseEntered(with event: NSEvent) { onChange(true) }
        override func mouseExited(with event: NSEvent) { onChange(false) }
    }
}

/// Its base laid out as usual, with `overlay` drawn over it at `align` and
/// moved by the offsets, so the overlay never changes the base's size. It is
/// one accessibility container, so its identifier never replaces theirs.
struct AtomOverlay<Base: View, Over: View>: View {
    var props = OverlayProps()
    var common = AtomCommon()
    @ViewBuilder var base: () -> Base
    @ViewBuilder var overlay: () -> Over
    @State private var isHovering = false

    var body: some View {
        base()
            .overlay(alignment: alignment) {
                if isHovering || props.revealOnHover != true {
                    overlay()
                        .offset(x: CGFloat(props.offsetX ?? 0), y: CGFloat(props.offsetY ?? 0))
                }
            }
            .background {
                if props.revealOnHover == true {
                    OverlayHoverTracker { isHovering = $0 }.accessibilityHidden(true)
                }
            }
            .atomCommon(common, atom: .overlay, group: true)
    }

    private var alignment: Alignment {
        switch props.align {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: .center
        }
    }
}

/// The layout props of a presentation atom (a Modal, Page or SidePanel),
/// applied around what it is presented over; its accessibility props name
/// what it presents instead.
private extension AtomCommon {
    var presentationLayout: AtomCommon {
        var copy = self
        copy.testID = nil
        copy.label = nil
        copy.value = nil
        copy.hint = nil
        return copy
    }

    /// The layout props of a Modal or SidePanel without the ones it owns: its
    /// own `width` (and the Modal's `height`) size what it presents, and,
    /// applied around the presenter too, they framed it to the panel's width,
    /// so the covered view spilled out of the atom and the panel sat in the
    /// middle of it.
    func presentationLayout(owningHeight: Bool) -> AtomCommon {
        var copy = presentationLayout
        copy.width = nil
        if owningHeight { copy.height = nil }
        return copy
    }

    var presentationAccessibility: AtomCommon {
        AtomCommon(testID: testID, label: label, value: value, hint: hint)
    }
}

/// A modal sheet presented from `base`, open while `props.isPresented`.
/// Escape, which the sheet handles itself, or a native owner's content
/// closing it (an `@Environment(\.dismiss)`), calls `onDismiss`. Native owners give any SwiftUI
/// content; a plugin's is every child after the first.
struct AtomModal<Base: View, Content: View>: View {
    var props: ModalProps
    var common = AtomCommon()
    let onDismiss: () -> Void
    @ViewBuilder var base: () -> Base
    @ViewBuilder var content: () -> Content

    var body: some View {
        base()
            .sheet(isPresented: Binding(get: { props.isPresented }, set: { if !$0 && props.isPresented { onDismiss() } })) {
                VStack(alignment: .leading, spacing: CGFloat(props.spacing ?? ModalProps.defaultSpacing)) {
                    if let title = props.title {
                        AtomModalHeader(
                            title: title, subtitle: props.subtitle, icon: props.icon,
                            idPrefix: common.testID ?? "modal", onClose: onDismiss
                        )
                    }
                    content()
                }
                .padding(CGFloat(props.inset ?? ModalProps.defaultInset))
                .modifier(Applied(when: props.width != nil || props.height != nil) {
                    $0.frame(width: props.width.map { CGFloat($0) }, height: props.height.map { CGFloat($0) }, alignment: .topLeading)
                })
                .modifier(AtomAccessibility(common: common.presentationAccessibility, group: true, combine: false))
            }
            .atomCommon(common.presentationLayout(owningHeight: true), atom: .modal)
    }
}

/// The app's standard modal header, composed of atoms: an optional accent
/// symbol, the title (19-point semibold rounded, as the Token Stats and
/// Rename Task sheets' are) over an optional secondary subtitle, and a close
/// button at the trailing edge. A Modal with a `title` and an installed
/// plugin's surface both start with it. The title is `<idPrefix>-title` and
/// the close button `<idPrefix>-close`.
struct AtomModalHeader: View {
    let title: String
    var subtitle: String?
    var icon: String?
    var titleSize: Double = 19
    let idPrefix: String
    let onClose: () -> Void

    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 10, align: "top"), common: AtomCommon(fillWidth: true)) {
            if let icon {
                AtomIcon(props: IconProps(name: icon, size: titleSize - 1, weight: "semibold", color: "accent"), common: AtomCommon(minWidth: titleSize + 5, minHeight: titleSize + 5))
            }
            AtomStack(props: StackProps(spacing: 3, align: "leading")) {
                AtomText(props: TextProps(text: title, size: titleSize, weight: "semibold", design: "rounded", lineLimit: 2), common: AtomCommon(testID: "\(idPrefix)-title"))
                if let subtitle {
                    AtomText(props: TextProps(text: subtitle, size: 12, color: "secondary", lineLimit: 2))
                }
            }
            AtomSpacer(props: SpacerProps(minLength: 8))
            AtomButton(props: ButtonProps(emphasis: 5), common: AtomCommon(testID: "\(idPrefix)-close", label: "Close \(title)", help: "Close"), action: onClose) {
                AtomIcon(props: IconProps(name: "xmark", size: 11, weight: "semibold", color: "secondary"), common: AtomCommon(width: 20, height: titleSize + 5))
            }
        }
    }
}

/// A page that slides in from the trailing edge over all of `base`, on the
/// window background, while `props.isPresented` (the Scheduled Tasks page
/// over the board). `base` sizes the atom; the owner closes the page.
struct AtomPage<Base: View, Content: View>: View {
    var props: PageProps
    var common = AtomCommon()
    @ViewBuilder var base: () -> Base
    @ViewBuilder var content: () -> Content

    var body: some View {
        base()
            .background(AccessibilityHitTestAnchor())
            .overlay {
                ZStack {
                    if props.isPresented {
                        content()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(WorkspaceTheme.windowBackground)
                            .shadow(color: .black.opacity(0.25), radius: 16, x: -4)
                            .modifier(AtomAccessibility(common: common.presentationAccessibility, group: true, combine: false))
                            // Ahead of the covered view, as a SidePanel's panel is.
                            .accessibilitySortPriority(1)
                            .transition(.move(edge: .trailing))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(props.isPresented)
                .animation(.spring(response: 0.34, dampingFraction: 0.92), value: props.isPresented)
            }
            // No accessibility container around base and page, as with a SidePanel.
            .atomCommon(common.presentationLayout, atom: .page)
    }
}

/// A full-height panel that slides in over the `edge` of `base` (trailing
/// by default), `width` wide (340 by default), on the window background with
/// a hairline along its inner edge and a shadow, while `props.isPresented`
/// (the Done archive over the board). `base` sizes the atom; the owner
/// closes the panel.
struct AtomSidePanel<Base: View, Content: View>: View {
    var props: SidePanelProps
    var common = AtomCommon()
    @ViewBuilder var base: () -> Base
    @ViewBuilder var content: () -> Content

    private var leading: Bool { props.edge == "leading" }

    var body: some View {
        base()
            .background(AccessibilityHitTestAnchor())
            .overlay {
                // A full-size stack aligned to the edge, holding the panel while it shows.
                ZStack(alignment: leading ? .leading : .trailing) {
                    if props.isPresented {
                        panel
                            // Ahead of the covered view, so an accessibility hit test over the
                            // panel finds its controls even when the covered view is one
                            // accessibility group (a plugin's base Stack with `group`).
                            .accessibilitySortPriority(1)
                            .transition(.move(edge: leading ? .leading : .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: leading ? .leading : .trailing)
                .allowsHitTesting(props.isPresented)
                .animation(.easeInOut(duration: 0.24), value: props.isPresented)
            }
            // No accessibility container around base and panel: the conversation view is a
            // base, and one around it split its labels' icons into separate elements and kept
            // native tooltips from showing even while nothing was presented.
            .atomCommon(common.presentationLayout(owningHeight: false), atom: .sidePanel)
    }

    private var panel: some View {
        content()
            .frame(width: CGFloat(props.width ?? 340))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(WorkspaceTheme.windowBackground)
            .background(AccessibilityHitTestAnchor())
            .overlay(alignment: leading ? .trailing : .leading) {
                Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 18, x: leading ? 6 : -6, y: 0)
            .modifier(AtomAccessibility(common: common.presentationAccessibility, group: true, combine: false))
    }
}

/// An empty, zero-size AppKit view kept behind what a Page or SidePanel covers.
/// Without a platform view there, accessibility hit tests over the presented
/// content resolve to the covered view underneath: its controls still take
/// clicks, but XCUITest (and so assistive clients) don't find them. Found by
/// bisecting the board's Done archive (#156); the AppKit mechanism is not
/// confirmed. test_task_done_removes_worktree_and_preserves_branch guards it on
/// the board; test_plugin_presentation_atoms_open_modal_page_and_side_panel and
/// test_plugin_done_archive_renders_from_atoms_like_native guard a plugin's
/// SidePanel over a grouped base.
struct AccessibilityHitTestAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// This view as an `AtomModal`'s base: native owners present a modal from what they already show.
    func atomModal(_ props: ModalProps, common: AtomCommon = AtomCommon(), onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping () -> some View) -> some View {
        AtomModal(props: props, common: common, onDismiss: onDismiss, base: { self }, content: content)
    }

    /// This view as an `AtomPage`'s base.
    func atomPage(_ props: PageProps, common: AtomCommon = AtomCommon(), @ViewBuilder content: @escaping () -> some View) -> some View {
        AtomPage(props: props, common: common, base: { self }, content: content)
    }

    /// This view as an `AtomSidePanel`'s base.
    func atomSidePanel(_ props: SidePanelProps, common: AtomCommon = AtomCommon(), @ViewBuilder content: @escaping () -> some View) -> some View {
        AtomSidePanel(props: props, common: common, base: { self }, content: content)
    }
}
