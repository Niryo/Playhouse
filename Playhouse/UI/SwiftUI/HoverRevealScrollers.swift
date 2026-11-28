#if os(macOS)
import AppKit
import ObjectiveC
import SwiftUI
import PlayhouseCore

/// Every Playhouse scroller follows the overlay pattern editors such as Xcode and VS Code use:
/// a scroller stays hidden until the pointer is over the content it scrolls, shows at a
/// subdued opacity while it is, and reaches full opacity only while its knob is being dragged.
///
/// AppKit already draws overlay scrollers, fades them out when scrolling stops, and widens
/// them under the pointer, so this keeps those native scrollers rather than drawing its own.
/// It forces the overlay style even when the system would show legacy, always-visible
/// scrollers (for example with a mouse attached), keeps the scrollers shown while the
/// content is hovered, and sets each scroller view's own alpha, which AppKit's fade does
/// not touch, for the resting and dragging opacity.
///
/// `scripts/check-hover-scrollers.py` keeps every app scroll view opted in.
package enum HoverRevealScrollers {
    /// Opacity of a shown scroller that is not being dragged.
    package static let restingOpacity: CGFloat = 0.45
    /// Opacity of a scroller while its knob is held.
    package static let draggingOpacity: CGFloat = 1

    /// The thickness an overlay scroller covers along the scroll view's edge. It floats
    /// over the content instead of taking space from it.
    package static var scrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
    }

    private static var controllerKey: UInt8 = 0

    /// Idempotent: a scroll view gets one controller for its lifetime.
    package static func install(on scrollView: NSScrollView) {
        guard objc_getAssociatedObject(scrollView, &controllerKey) == nil else { return }
        let controller = HoverRevealScrollerController(scrollView: scrollView)
        objc_setAssociatedObject(scrollView, &controllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

extension View {
    /// Applies `HoverRevealScrollers` to the scroll view enclosing this view. Apply it to a
    /// `ScrollView`'s content, a `List` row, or a `Form`'s content, not to the container itself:
    /// only a view inside the scroll view can find it.
    package func hoverRevealScrollers() -> some View {
        background(HoverRevealScrollerInstaller())
    }
}

private struct HoverRevealScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> InstallerView { InstallerView() }
    func updateNSView(_ view: InstallerView, context: Context) {}

    final class InstallerView: NSView {
        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scrollView = enclosingScrollView else { return }
            HoverRevealScrollers.install(on: scrollView)
        }

        package override func hitTest(_ point: NSPoint) -> NSView? { nil }
        package override func isAccessibilityElement() -> Bool { false }
    }
}

private final class HoverRevealScrollerController: NSResponder {
    private weak var scrollView: NSScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var trackingArea: NSTrackingArea?
    /// Overlay scrollers fade out about a second after the last flash, so a hovered scroll
    /// view re-flashes them; flashing a shown scroller keeps it fully shown without a flicker.
    private var revealTimer: Timer?
    private var isDragging = false

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init()
        enforceOverlayStyle()
        applyOpacity(animated: false)
        // AppKit resets the style when the system preference or a scroller changes, and
        // SwiftUI can replace a scroller when it updates the scroll view.
        observations = [
            scrollView.observe(\.scrollerStyle) { [weak self] _, _ in
                // Keep the clip view from laying out with legacy scroller width between passes.
                MainActor.assumeIsolated { self?.enforceOverlayStyle() }
            },
            scrollView.observe(\.verticalScroller) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyOpacity(animated: false) }
            },
            scrollView.observe(\.horizontalScroller) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyOpacity(animated: false) }
            },
        ]
        let center = NotificationCenter.default
        // Live scrolls also cover trackpad and wheel gestures; only one that starts with a
        // mouse button held is a scroller drag.
        notificationTokens = [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
                self?.setDragging(true)
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                self?.setDragging(false)
            },
        ]
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        scrollView.addTrackingArea(area)
        trackingArea = area
        // A tracking area sends no entered event for a pointer already inside it.
        if let window = scrollView.window {
            let point = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if scrollView.bounds.contains(point) { setHovered(true) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        revealTimer?.invalidate()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        revealTimer?.invalidate()
        revealTimer = nil
        guard hovered, let scrollView else { return }
        scrollView.flashScrollers()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            // A scroll view can leave its window without an exit event.
            guard let scrollView = self?.scrollView, scrollView.window != nil else {
                timer.invalidate()
                return
            }
            scrollView.flashScrollers()
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func setDragging(_ dragging: Bool) {
        guard isDragging != dragging else { return }
        isDragging = dragging
        applyOpacity(animated: true)
    }

    private func enforceOverlayStyle() {
        guard let scrollView, scrollView.scrollerStyle != .overlay else { return }
        scrollView.scrollerStyle = .overlay
    }

    private func applyOpacity(animated: Bool) {
        guard let scrollView else { return }
        let opacity = isDragging ? HoverRevealScrollers.draggingOpacity : HoverRevealScrollers.restingOpacity
        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller].compactMap({ $0 }) {
            guard scroller.alphaValue != opacity else { continue }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    scroller.animator().alphaValue = opacity
                }
            } else {
                scroller.alphaValue = opacity
            }
        }
    }
}
#endif
