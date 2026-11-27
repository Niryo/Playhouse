import Foundation
import PlayhouseCore
import PlayhouseUI
/// Its base laid out as usual, with `overlay` drawn over it at `align` and
/// moved by the offsets, so the overlay never changes the base's size. It is
/// one accessibility container, so its identifier never replaces theirs.
package struct AtomOverlay<Base: PHView, Over: PHView>: PHView {
    package var props = OverlayProps()
    package var common = AtomCommon()
    @PHViewBuilder package var base: () -> Base
    @PHViewBuilder package var overlay: () -> Over
    @PHState private var isHovering = false

    package var body: some PHView {
        layered
            .background {
                if props.revealOnHover == true {
                    PHHoverTracker { isHovering = $0 }.accessibilityHidden(true)
                }
            }
            .atomCommon(common, atom: .overlay, group: props.group != false)
    }

    @PHViewBuilder
    private var layered: some PHView {
        if props.behind == true {
            base().background(alignment: alignment) { layer }
        } else {
            base().overlay(alignment: alignment) { layer }
        }
    }

    @PHViewBuilder
    private var layer: some PHView {
        if isHovering || props.revealOnHover != true {
            overlay().offset(x: CGFloat(props.offsetX ?? 0), y: CGFloat(props.offsetY ?? 0))
        }
    }

    private var alignment: PHAlignment {
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

    package init(props: OverlayProps = OverlayProps(), common: AtomCommon = AtomCommon(), @PHViewBuilder base: @escaping () -> Base, @PHViewBuilder overlay: @escaping () -> Over) {
        self.props = props
        self.common = common
        self.base = base
        self.overlay = overlay
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
/// closing it (an `@Environment(\.dismiss)`), calls `onDismiss`; a modal that
/// isn't `dismissible` ignores Escape and has no close button. Native owners give any SwiftUI
/// content; a plugin's is every child after the first.
package struct AtomModal<Base: PHView, Content: PHView>: PHView {
    package var props: ModalProps
    package var common = AtomCommon()
    package let onDismiss: () -> Void
    @PHViewBuilder package var base: () -> Base
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        base()
            .sheet(isPresented: PHBinding(get: { props.isPresented }, set: { if !$0 && props.isPresented { onDismiss() } })) {
                PHVStack(alignment: .leading, spacing: CGFloat(props.spacing ?? ModalProps.defaultSpacing)) {
                    if let title = props.title {
                        AtomModalHeader(
                            title: title, subtitle: props.subtitle, icon: props.icon,
                            idPrefix: common.testID ?? "modal", onClose: isDismissible ? onDismiss : nil
                        )
                    }
                    content()
                }
                .interactiveDismissDisabled(!isDismissible)
                .padding(CGFloat(props.inset ?? ModalProps.defaultInset))
                .modifier(Applied(when: props.width != nil || props.height != nil) {
                    $0.frame(width: props.width.map { CGFloat($0) }, height: props.height.map { CGFloat($0) }, alignment: .topLeading)
                })
                .modifier(AtomAccessibility(common: common.presentationAccessibility, group: true, combine: false))
            }
            .atomCommon(common.presentationLayout(owningHeight: true), atom: .modal)
    }

    private var isDismissible: Bool { props.dismissible != false }

    package init(props: ModalProps, common: AtomCommon = AtomCommon(), onDismiss: @escaping () -> Void, @PHViewBuilder base: @escaping () -> Base, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.onDismiss = onDismiss
        self.base = base
        self.content = content
    }
}

/// The app's standard modal header, composed of atoms: an optional accent
/// symbol, the title (19-point semibold rounded, as the Token Stats and
/// Rename Task sheets' are) over an optional secondary subtitle, and a close
/// button at the trailing edge when there is an `onClose`. A Modal with a `title` and an installed
/// plugin's surface both start with it. The title is `<idPrefix>-title` and
/// the close button `<idPrefix>-close`.
package struct AtomModalHeader: PHView {
    package let title: String
    package var subtitle: String?
    package var icon: String?
    package var titleSize: Double = 19
    package let idPrefix: String
    package let onClose: (() -> Void)?

    package var body: some PHView {
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
            if let onClose {
                AtomButton(props: ButtonProps(emphasis: 5), common: AtomCommon(testID: "\(idPrefix)-close", label: "Close \(title)", help: "Close"), action: onClose) {
                    AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 11, weight: "semibold", color: "secondary"), common: AtomCommon(width: 20, height: titleSize + 5))
                }
            }
        }
    }

    package init(title: String, subtitle: String? = nil, icon: String? = nil, titleSize: Double = 19, idPrefix: String, onClose: (() -> Void)?) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.titleSize = titleSize
        self.idPrefix = idPrefix
        self.onClose = onClose
    }
}

/// A page that slides in from the trailing edge over all of `base`, on the
/// window background, while `props.isPresented` (a main sidebar page plugin
/// over the board). `base` sizes the atom; the owner closes the page.
package struct AtomPage<Base: PHView, Content: PHView>: PHView {
    package var props: PageProps
    package var common = AtomCommon()
    @PHViewBuilder package var base: () -> Base
    @PHViewBuilder package var content: () -> Content

    package var body: some PHView {
        base()
            .background(PHAccessibilityHitTestAnchor())
            .overlay {
                PHZStack {
                    if props.isPresented {
                        content()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(WorkspaceTheme.windowBackground)
                            .phShadow(color: .black.opacity(0.25), radius: 16, x: -4)
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

    package init(props: PageProps, common: AtomCommon = AtomCommon(), @PHViewBuilder base: @escaping () -> Base, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.base = base
        self.content = content
    }
}

/// A full-height panel that slides in over the `edge` of `base` (trailing
/// by default), `width` wide (340 by default), on the window background with
/// a hairline along its inner edge and a shadow, while `props.isPresented`
/// (the Done archive over the board). `base` sizes the atom; the owner
/// closes the panel.
package struct AtomSidePanel<Base: PHView, Content: PHView>: PHView {
    package var props: SidePanelProps
    package var common = AtomCommon()
    @PHViewBuilder package var base: () -> Base
    @PHViewBuilder package var content: () -> Content

    private var leading: Bool { props.edge == "leading" }

    package var body: some PHView {
        base()
            .background(PHAccessibilityHitTestAnchor())
            .overlay {
                // A full-size stack aligned to the edge, holding the panel while it shows.
                PHZStack(alignment: leading ? .leading : .trailing) {
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

    private var panel: some PHView {
        content()
            .frame(width: CGFloat(props.width ?? 340))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(WorkspaceTheme.windowBackground)
            .background(PHAccessibilityHitTestAnchor())
            .overlay(alignment: leading ? .trailing : .leading) {
                PHRectangle().fill(PHColor.primary.opacity(0.10)).frame(width: 1)
            }
            .phShadow(color: .black.opacity(0.16), radius: 18, x: leading ? 6 : -6, y: 0)
            .modifier(AtomAccessibility(common: common.presentationAccessibility, group: true, combine: false))
    }

    package init(props: SidePanelProps, common: AtomCommon = AtomCommon(), @PHViewBuilder base: @escaping () -> Base, @PHViewBuilder content: @escaping () -> Content) {
        self.props = props
        self.common = common
        self.base = base
        self.content = content
    }
}
extension PHView {
    /// This view as an `AtomModal`'s base: native owners present a modal from what they already show.
    package func atomModal(_ props: ModalProps, common: AtomCommon = AtomCommon(), onDismiss: @escaping () -> Void, @PHViewBuilder content: @escaping () -> some PHView) -> some PHView {
        AtomModal(props: props, common: common, onDismiss: onDismiss, base: { self }, content: content)
    }

    /// This view as an `AtomPage`'s base.
    package func atomPage(_ props: PageProps, common: AtomCommon = AtomCommon(), @PHViewBuilder content: @escaping () -> some PHView) -> some PHView {
        AtomPage(props: props, common: common, base: { self }, content: content)
    }

    /// This view as an `AtomSidePanel`'s base.
    package func atomSidePanel(_ props: SidePanelProps, common: AtomCommon = AtomCommon(), @PHViewBuilder content: @escaping () -> some PHView) -> some PHView {
        AtomSidePanel(props: props, common: common, base: { self }, content: content)
    }
}
