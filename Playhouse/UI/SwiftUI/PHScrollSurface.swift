#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// The platform scroll view behind a `PHScrollView`, for a controller that positions it itself
/// (the conversation transcript's). On macOS it is the `NSScrollView` SwiftUI creates; its
/// notifications arrive while SwiftUI's layout pass is still running, so the controller reacts
/// within the same pass. A Linux build wraps the GtkScrolledWindow here.
@MainActor
public final class PHScrollSurface {
    public struct Metrics: Equatable {
        public var offsetY: CGFloat
        public var documentHeight: CGFloat
        public var viewportSize: CGSize
        /// The parts of the viewport that bars cover, such as a window's title bar.
        public var topInset: CGFloat
        public var bottomInset: CGFloat
    }

    /// The scroll view's bounds moved: the reader scrolled, or the content or viewport changed.
    public var onBoundsChange: (() -> Void)?
    /// The viewport or the content changed size.
    public var onLayoutChange: (() -> Void)?
    /// A scroll wheel moved over the scroll view, by this many points (positive is up).
    public var onScrollWheel: ((CGFloat) -> Void)?

    private weak var scrollView: NSScrollView?
    private var notificationTokens: [NSObjectProtocol] = []
    private var scrollWheelMonitor: Any?
    private var displayLink: CADisplayLink?
    private var frameTick: (() -> Void)?

    /// Follows `scrollView`, whose document view must be flipped (as SwiftUI's is). Nil when it isn't.
    package init?(scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView, documentView.isFlipped else { return nil }
        self.scrollView = scrollView
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        documentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        // Delivered synchronously, on the thread that changed the view: inside SwiftUI's layout
        // pass for a layout change, and inside event handling for a scroll.
        notificationTokens = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBoundsChange?() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: clipView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLayoutChange?() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: documentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.onLayoutChange?() }
            },
        ]
        // A scroll view already at an edge cannot scroll further, so a wheel there changes
        // nothing the notifications above would report.
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event.scrollingDeltaY != 0, let scrollView = self.scrollView, event.window === scrollView.window,
                      scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)) else { return }
                self.onScrollWheel?(event.scrollingDeltaY)
            }
            return event
        }
    }

    /// Stops following the scroll view.
    public func invalidate() {
        stopFrameUpdates()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        if let scrollWheelMonitor { NSEvent.removeMonitor(scrollWheelMonitor) }
        scrollWheelMonitor = nil
        scrollView = nil
    }

    package func isSurface(of scrollView: NSScrollView) -> Bool { self.scrollView === scrollView }

    public var metrics: Metrics? {
        guard let scrollView, let documentView = scrollView.documentView else { return nil }
        let clipView = scrollView.contentView
        let insets = clipView.contentInsets
        return Metrics(
            offsetY: clipView.bounds.minY,
            documentHeight: documentView.frame.height,
            viewportSize: clipView.bounds.size,
            topInset: insets.top,
            bottomInset: insets.bottom
        )
    }

    /// Scrolls to `offsetY`, rounded to the screen's pixels. Nothing happens for a change under
    /// a hundredth of a point.
    public func setOffsetY(_ offsetY: CGFloat) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let scale = scrollView.window?.backingScaleFactor ?? 2
        let target = (offsetY * scale).rounded() / scale
        guard abs(clipView.bounds.minY - target) > 0.01 else { return }
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Calls `tick` on every display frame until `stopFrameUpdates()`.
    public func startFrameUpdates(_ tick: @escaping () -> Void) {
        frameTick = tick
        guard displayLink == nil, let scrollView else { return }
        let link = scrollView.displayLink(target: FrameTarget(surface: self), selector: #selector(FrameTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func stopFrameUpdates() {
        displayLink?.invalidate()
        displayLink = nil
        frameTick = nil
    }

    public var isRunningFrameUpdates: Bool { displayLink != nil }

    /// The clock frame updates run on, in seconds.
    public static var now: TimeInterval { CACurrentMediaTime() }

    private final class FrameTarget: NSObject {
        weak var surface: PHScrollSurface?
        init(surface: PHScrollSurface) { self.surface = surface }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { surface?.frameTick?() }
        }
    }
}

extension PHView {
    /// Finds the scroll view enclosing this view. `update` runs on every pass of the view; the
    /// scroll view is handed to `attach` once it is found (again after it moves to another
    /// window) and `detach` runs when it goes. `owner` is kept alive while the view is shown.
    /// Apply it to the `PHScrollView`'s content: only a view inside the scroll view can find it.
    public func phScrollSurface(
        owner: AnyObject?,
        update: @escaping () -> Void,
        attach: @escaping (PHScrollViewHandle) -> Void,
        detach: @escaping () -> Void
    ) -> some PHView {
        background(ScrollSurfaceInstaller(owner: owner, update: update, attach: attach, detach: detach))
    }
}

/// A found scroll view, which a controller turns into its `PHScrollSurface` once.
@MainActor
public struct PHScrollViewHandle {
    fileprivate let scrollView: NSScrollView

    /// The surface for this scroll view: `current` when it already follows it, else a new one.
    public func surface(reusing current: PHScrollSurface?) -> PHScrollSurface? {
        if let current, current.isSurface(of: scrollView) { return current }
        return PHScrollSurface(scrollView: scrollView)
    }
}

private struct ScrollSurfaceInstaller: NSViewRepresentable {
    let owner: AnyObject?
    let update: () -> Void
    let attach: (PHScrollViewHandle) -> Void
    let detach: () -> Void

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        connect(view)
        update()
        return view
    }

    // Runs on every pass, so the handlers read the view as it now is.
    func updateNSView(_ view: InstallerView, context: Context) {
        connect(view)
        update()
        // Attaching again is a no-op once attached, and picks the scroll view up on a later
        // pass if it was not there on the first.
        view.attachIfPossible()
    }

    private func connect(_ view: InstallerView) {
        view.owner = owner
        view.attach = attach
        view.detach = detach
    }

    final class InstallerView: NSView {
        package var owner: AnyObject?
        package var attach: ((PHScrollViewHandle) -> Void)?
        package var detach: (() -> Void)?

        package override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach?()
            } else {
                attachIfPossible()
            }
        }

        package func attachIfPossible() {
            guard window != nil, let scrollView = enclosingScrollView else { return }
            attach?(PHScrollViewHandle(scrollView: scrollView))
        }

        package override func hitTest(_ point: NSPoint) -> NSView? { nil }
        package override func isAccessibilityElement() -> Bool { false }
    }
}
#endif
