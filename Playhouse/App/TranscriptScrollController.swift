import AppKit
import SwiftUI

/// Owns the conversation transcript's scroll position.
///
/// SwiftUI lays the transcript out and draws it; this controller alone decides where the
/// viewport is. It holds one intent at a time and applies it again, in the same pass, whenever
/// the transcript's layout changes:
///
/// - `following`: the viewport stays at the bottom, so a streaming answer scrolls along.
/// - `latestTurn`: the newest question stays at the top of the viewport.
/// - `reading`: the row the reader is on stays where it is on screen, whatever changes above
///   it (older messages revealed, rows far away measured again) or below it (new content).
///
/// - `row`: a named row stays at the top of the viewport, as after a jump to a chat page.
///
/// Only the reader moves between them by scrolling: reaching the bottom starts following and
/// leaving it starts reading. `pin` sets an intent on the reader's behalf, as opening a
/// conversation or sending a message does.
///
/// It works on the `NSScrollView` behind the SwiftUI `ScrollView`, whose notifications arrive
/// while the layout pass is still running, and reads row positions from `TranscriptGeometry`,
/// which the transcript's layout wrote earlier in that same pass, so nothing waits for a later
/// pass to correct an earlier one.
@MainActor
final class TranscriptScrollController: NSObject {
    enum Pin {
        /// The newest question at the top of the viewport.
        case latestTurn
        /// The end of the transcript, following what arrives.
        case bottom
        /// The row of this message at the top of the viewport, once it has laid out.
        case row(String)
    }

    private struct Anchor {
        var id: String
        /// How far the viewport's top is below the row's top.
        var depth: CGFloat
        var rowHeight: CGFloat
        var width: CGFloat
    }

    private enum Intent {
        case following
        case latestTurn
        case row(String)
        case reading(Anchor?)
    }

    private struct Metrics: Equatable {
        var offsetY: CGFloat
        var documentHeight: CGFloat
        var viewportSize: CGSize
        /// The parts of the viewport that bars cover, such as a window's title bar.
        var topInset: CGFloat
        var bottomInset: CGFloat

        var minOffsetY: CGFloat { -topInset }
        var maxOffsetY: CGFloat { max(minOffsetY, documentHeight + bottomInset - viewportSize.height) }
        /// Where in the scroll content the visible part of the viewport starts.
        var visibleTop: CGFloat { offsetY + topInset }
        var visibleHeight: CGFloat { viewportSize.height - topInset - bottomInset }

        func hasSameLayout(as other: Metrics) -> Bool {
            documentHeight == other.documentHeight && viewportSize == other.viewportSize
                && topInset == other.topInset && bottomInset == other.bottomInset
        }
    }

    let geometry = TranscriptGeometry()
    let virtualizer: TranscriptVirtualizer
    /// Distance from the top of the scroll content to the top of the transcript layout.
    var layoutTop: CGFloat = 0
    /// Space kept above the newest question when it is pinned to the top of the viewport.
    var latestTurnMargin: CGFloat = 0
    /// What the conversation does in response to the transcript. The scroll view's installer
    /// supplies them, and they are not kept here: they capture the conversation view's state,
    /// which holds this controller.
    struct Handlers {
        /// The reader scrolled up to within a viewport of the oldest rendered message.
        var onApproachTop: () -> Void
        /// The transcript started or stopped following its bottom.
        var onFollowingChange: (Bool) -> Void
        /// The reader scrolled down to within a viewport of the newest rendered message while
        /// the rendered window ends before the transcript does.
        var onApproachBottom: () -> Void = {}
        /// Another message's row reached the top of the viewport.
        var onTopRowChange: (String) -> Void = { _ in }
    }
    /// Whether the rendered rows run to the end of the transcript. A window that ends earlier
    /// has more to reveal below it, so its bottom is not one to follow.
    var rendersTranscriptEnd = true
    fileprivate weak var installer: TranscriptScrollInstaller.InstallerView?

    /// How close to the bottom, in points, still counts as at the bottom.
    static let followThreshold: CGFloat = 16
    static let pinAnimationDuration: CFTimeInterval = 0.2

    private weak var scrollView: NSScrollView?
    private var intent = Intent.reading(nil)
    private var last: Metrics?
    private var isApplying = false
    /// Older messages were revealed and have not laid out yet.
    private var isRevealPending = false
    /// Newer messages were revealed below a window that ends early and have not laid out yet.
    private var isNewerRevealPending = false
    private var topRowID: String?
    private var notificationTokens: [NSObjectProtocol] = []
    private var scrollWheelMonitor: Any?
    private var displayLink: CADisplayLink?
    private var animationStart: (time: CFTimeInterval, offsetY: CGFloat)?

    override init() {
        virtualizer = TranscriptVirtualizer(geometry: geometry)
        super.init()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        if let scrollWheelMonitor { NSEvent.removeMonitor(scrollWheelMonitor) }
    }

    var isFollowing: Bool {
        if case .following = intent { return true }
        return false
    }

    // MARK: Intents

    /// Sets where the transcript should be and keeps it there until the reader scrolls.
    func pin(_ pin: Pin, animated: Bool = false) {
        switch pin {
        case .bottom: setIntent(.following)
        case .latestTurn: setIntent(.latestTurn)
        case .row(let id): setIntent(.row(id))
        }
        if animated, scrollView != nil {
            startAnimation()
        } else {
            stopAnimation()
            applyIntent()
        }
    }

    /// A turn started on its own. A reader whose pinned question is also the end of the
    /// transcript is at the bottom, and follows the answer from there.
    func followIfAtBottom() {
        guard case .latestTurn = intent, let metrics = metrics(), isAtBottom(metrics) else { return }
        setIntent(.following)
    }

    /// Older messages were just revealed above the reader. Until they lay out, scrolling asks
    /// for no further batch, so a burst of scroll events reveals one batch rather than several
    /// at once. Should the reader still be near the top once they have, as after a batch shorter
    /// than the viewport, `onApproachTop` runs again.
    func didRevealOlderRows() {
        isRevealPending = true
    }

    /// Newer messages were just revealed below a window that ends before the transcript does.
    /// Like `didRevealOlderRows`: one batch per layout, and `onApproachBottom` runs again
    /// should the reader still be near the bottom once they have laid out.
    func didRevealNewerRows() {
        isNewerRevealPending = true
    }

    private func setIntent(_ newIntent: Intent) {
        let wasFollowing = isFollowing
        intent = newIntent
        if wasFollowing != isFollowing { installer?.handlers?.onFollowingChange(isFollowing) }
    }

    // MARK: Scroll view

    func attach(to scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        guard let documentView = scrollView.documentView, documentView.isFlipped else { return }
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
                MainActor.assumeIsolated { self?.clipBoundsDidChange() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: clipView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutDidChange() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: documentView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutDidChange() }
            },
        ]
        // A transcript already at its top cannot scroll further, so an upward scroll there
        // changes nothing the notifications above would report.
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.scrollWheelDidMove(event) }
            return event
        }
        last = nil
        applyIntent()
    }

    func detach() {
        stopAnimation()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens = []
        if let scrollWheelMonitor { NSEvent.removeMonitor(scrollWheelMonitor) }
        scrollWheelMonitor = nil
        scrollView = nil
        last = nil
        isRevealPending = false
        isNewerRevealPending = false
    }

    private func metrics() -> Metrics? {
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

    private func isAtBottom(_ metrics: Metrics) -> Bool {
        metrics.maxOffsetY - metrics.offsetY <= Self.followThreshold
    }

    private func isNearTop(_ metrics: Metrics) -> Bool {
        metrics.offsetY - metrics.minOffsetY <= metrics.visibleHeight
    }

    private func isNearBottom(_ metrics: Metrics) -> Bool {
        metrics.maxOffsetY - metrics.offsetY <= metrics.visibleHeight
    }

    private func setOffsetY(_ offsetY: CGFloat, in metrics: Metrics) {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        let scale = scrollView.window?.backingScaleFactor ?? 2
        let target = (min(max(offsetY, metrics.minOffsetY), metrics.maxOffsetY) * scale).rounded() / scale
        guard abs(clipView.bounds.minY - target) > 0.01 else { return }
        isApplying = true
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clipView)
        isApplying = false
    }

    // MARK: Changes

    private func clipBoundsDidChange() {
        guard !isApplying, let metrics = metrics() else { return }
        // AppKit moves the viewport itself when the content, the viewport or its insets change,
        // as when the content shrinks under it; that is a layout change, not the reader scrolling.
        guard let last, metrics.hasSameLayout(as: last) else {
            layoutDidChange()
            return
        }
        guard metrics.offsetY != last.offsetY else { return }
        stopAnimation()
        setIntent(rendersTranscriptEnd && isAtBottom(metrics) ? .following : .reading(anchor(at: metrics)))
        self.last = metrics
        reportViewport(metrics)
        // Older messages are revealed before the reader reaches the top of the rendered ones,
        // so scrolling up never stops at an edge that then moves.
        if metrics.offsetY < last.offsetY, isNearTop(metrics) { approachTop() }
        if metrics.offsetY > last.offsetY, isNearBottom(metrics) { approachBottom() }
    }

    private func scrollWheelDidMove(_ event: NSEvent) {
        guard event.scrollingDeltaY != 0, let scrollView, event.window === scrollView.window,
              scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil)),
              let metrics = metrics() else { return }
        if event.scrollingDeltaY > 0 {
            if metrics.offsetY <= metrics.minOffsetY + 0.5 { approachTop() }
        } else if metrics.offsetY >= metrics.maxOffsetY - 0.5 {
            // Likewise a window at its bottom cannot scroll further down.
            approachBottom()
        }
    }

    private func approachTop() {
        guard !isRevealPending else { return }
        installer?.handlers?.onApproachTop()
    }

    private func approachBottom() {
        guard !rendersTranscriptEnd, !isNewerRevealPending else { return }
        installer?.handlers?.onApproachBottom()
    }

    private func layoutDidChange() {
        guard !isApplying else { return }
        let didReveal = isRevealPending
        isRevealPending = false
        let didRevealNewer = isNewerRevealPending
        isNewerRevealPending = false
        // A running animation moves toward the intent's position as it now is.
        guard displayLink == nil else {
            last = metrics()
            return
        }
        applyIntent()
        if didReveal, case .reading = intent, let last, isNearTop(last) {
            // Revealing changes state, which a layout pass must not.
            DispatchQueue.main.async { [weak self] in self?.approachTop() }
        }
        if didRevealNewer, !isFollowing, let last, isNearBottom(last) {
            DispatchQueue.main.async { [weak self] in self?.approachBottom() }
        }
    }

    /// Moves the viewport to where the intent says it belongs in the transcript as now laid out.
    private func applyIntent() {
        guard let metrics = metrics() else { return }
        if let offsetY = intendedOffsetY(in: metrics) { setOffsetY(offsetY, in: metrics) }
        guard let settled = self.metrics() else { return }
        last = settled
        reportViewport(settled)
    }

    private func intendedOffsetY(in metrics: Metrics) -> CGFloat? {
        switch intent {
        case .following:
            return metrics.maxOffsetY
        case .latestTurn:
            // Without the newest question among the rendered rows there is nothing to pin.
            return geometry.latestTurnTop.map { layoutTop + $0 - latestTurnMargin - metrics.topInset }
        case .row(let id):
            // The row lays out a pass after it is asked for; the intent waits for it.
            return geometry.row(id).map { layoutTop + $0.top - latestTurnMargin - metrics.topInset }
        case .reading(let anchor):
            guard var anchor, let row = geometry.row(anchor.id) else {
                // The row the reader was on is gone, as after a reload; stay put.
                intent = .reading(self.anchor(at: metrics))
                return nil
            }
            // A row that reflows to a new width keeps the reader at the same share of it; one
            // that grows at its end, as a streaming answer does, keeps them at the same depth.
            if abs(anchor.width - geometry.width) > 0.5, anchor.rowHeight > 0, (0..<anchor.rowHeight).contains(anchor.depth) {
                anchor.depth = (anchor.depth / anchor.rowHeight * row.height).rounded()
            }
            anchor.rowHeight = row.height
            anchor.width = geometry.width
            intent = .reading(anchor)
            return layoutTop + row.top + anchor.depth - metrics.topInset
        }
    }

    /// The row at the top of the viewport and how far into it the viewport's top is.
    private func anchor(at metrics: Metrics) -> Anchor? {
        let y = metrics.visibleTop - layoutTop
        guard let row = geometry.row(atOrAbove: y) else { return nil }
        return Anchor(id: row.id, depth: y - row.top, rowHeight: row.height, width: geometry.width)
    }

    private func reportViewport(_ metrics: Metrics) {
        let offsetY = metrics.visibleTop - layoutTop
        virtualizer.updateViewport(offsetY: offsetY, height: metrics.visibleHeight)
        // A row still counts as the top one while the margin kept above a pinned row shows.
        guard let id = geometry.row(atOrAbove: offsetY + latestTurnMargin + 1)?.id, id != topRowID else { return }
        topRowID = id
        // Reported after the pass: this runs inside layout, which must not change state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.topRowID == id else { return }
            self.installer?.handlers?.onTopRowChange(id)
        }
    }

    // MARK: Animation

    private func startAnimation() {
        guard let scrollView, let metrics = metrics() else { return }
        animationStart = (CACurrentMediaTime(), metrics.offsetY)
        guard displayLink == nil else { return }
        let link = scrollView.displayLink(target: self, selector: #selector(animationDidTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animationStart = nil
    }

    /// Eases toward the intent's position as it is on each frame, so content that arrives while
    /// the animation runs moves its destination rather than leaving it short.
    @objc private func animationDidTick(_ link: CADisplayLink) {
        guard let start = animationStart, let metrics = metrics(), let target = intendedOffsetY(in: metrics) else {
            stopAnimation()
            applyIntent()
            return
        }
        let progress = min(1, (CACurrentMediaTime() - start.time) / Self.pinAnimationDuration)
        guard progress < 1 else {
            stopAnimation()
            applyIntent()
            return
        }
        let eased = 1 - pow(1 - progress, 3)
        let clamped = min(max(target, metrics.minOffsetY), metrics.maxOffsetY)
        setOffsetY(start.offsetY + (clamped - start.offsetY) * eased, in: metrics)
        if let settled = self.metrics() {
            last = settled
            reportViewport(settled)
        }
    }
}

extension View {
    /// Hands the scroll view enclosing this view to `controller`, along with where the transcript
    /// layout sits in the scroll content and the conversation's handlers. Apply it to the
    /// `ScrollView`'s content: only a view inside the scroll view can find it.
    func transcriptScroll(
        _ controller: TranscriptScrollController,
        layoutTop: CGFloat,
        latestTurnMargin: CGFloat,
        rendersTranscriptEnd: Bool = true,
        handlers: TranscriptScrollController.Handlers
    ) -> some View {
        background(TranscriptScrollInstaller(
            controller: controller, layoutTop: layoutTop, latestTurnMargin: latestTurnMargin,
            rendersTranscriptEnd: rendersTranscriptEnd, handlers: handlers
        ))
    }
}

private struct TranscriptScrollInstaller: NSViewRepresentable {
    let controller: TranscriptScrollController
    let layoutTop: CGFloat
    let latestTurnMargin: CGFloat
    let rendersTranscriptEnd: Bool
    let handlers: TranscriptScrollController.Handlers

    func makeNSView(context: Context) -> InstallerView {
        let view = InstallerView()
        connect(view)
        return view
    }

    // Runs on every pass of the conversation, so the handlers read the view as it now is.
    func updateNSView(_ view: InstallerView, context: Context) {
        if view.controller !== controller { view.controller?.detach() }
        connect(view)
        // Attaching again is a no-op once attached, and picks the scroll view up on a later
        // pass if it was not there on the first.
        view.attach()
    }

    private func connect(_ view: InstallerView) {
        view.controller = controller
        view.handlers = handlers
        controller.installer = view
        controller.layoutTop = layoutTop
        controller.latestTurnMargin = latestTurnMargin
        controller.rendersTranscriptEnd = rendersTranscriptEnd
    }

    final class InstallerView: NSView {
        weak var controller: TranscriptScrollController?
        var handlers: TranscriptScrollController.Handlers?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                controller?.detach()
            } else {
                attach()
            }
        }

        func attach() {
            guard window != nil, let scrollView = enclosingScrollView else { return }
            controller?.attach(to: scrollView)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}
