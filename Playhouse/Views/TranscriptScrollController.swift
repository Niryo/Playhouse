import Foundation
import PlayhouseCore
import PlayhouseAtoms
import PlayhouseUI

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
/// It works on the platform scroll view behind the `PHScrollView` (a `PHScrollSurface`), whose
/// changes arrive while the layout pass is still running, and reads row positions from `TranscriptGeometry`,
/// which the transcript's layout wrote earlier in that same pass, so nothing waits for a later
/// pass to correct an earlier one.
@MainActor
package final class TranscriptScrollController {
    package enum Pin {
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

    private typealias Metrics = PHScrollSurface.Metrics

    package let geometry = TranscriptGeometry()
    package let virtualizer: TranscriptVirtualizer
    /// Distance from the top of the scroll content to the top of the transcript layout.
    package var layoutTop: CGFloat = 0
    /// Space kept above the newest question when it is pinned to the top of the viewport.
    package var latestTurnMargin: CGFloat = 0
    /// What the conversation does in response to the transcript. The scroll view's installer
    /// supplies them, and they are not kept here: they capture the conversation view's state,
    /// which holds this controller.
    package struct Handlers {
        /// The reader scrolled up to within a viewport of the oldest rendered message.
        package var onApproachTop: () -> Void
        /// The transcript started or stopped following its bottom.
        package var onFollowingChange: (Bool) -> Void
        /// The reader scrolled down to within a viewport of the newest rendered message while
        /// the rendered window ends before the transcript does.
        package var onApproachBottom: () -> Void = {}
        /// Another message's row reached the top of the viewport.
        package var onTopRowChange: (String) -> Void = { _ in }

        package init(onApproachTop: @escaping () -> Void, onFollowingChange: @escaping (Bool) -> Void, onApproachBottom: @escaping () -> Void = {}, onTopRowChange: @escaping (String) -> Void = { _ in }) {
            self.onApproachTop = onApproachTop
            self.onFollowingChange = onFollowingChange
            self.onApproachBottom = onApproachBottom
            self.onTopRowChange = onTopRowChange
        }
    }
    /// Whether the rendered rows run to the end of the transcript. A window that ends earlier
    /// has more to reveal below it, so its bottom is not one to follow.
    package var rendersTranscriptEnd = true
    /// The handlers of the conversation view now shown, held by its installer, not here.
    fileprivate weak var handlerBox: HandlerBox?

    /// How close to the bottom, in points, still counts as at the bottom.
    package static let followThreshold: CGFloat = 16
    package static let pinAnimationDuration: TimeInterval = 0.2

    private var surface: PHScrollSurface?
    private var intent = Intent.reading(nil)
    private var last: Metrics?
    private var isApplying = false
    /// Older messages were revealed and have not laid out yet.
    private var isRevealPending = false
    /// Newer messages were revealed below a window that ends early and have not laid out yet.
    private var isNewerRevealPending = false
    /// The window opened on its newest messages and should fill the viewport once they lay out.
    private var isFillPending = false
    private var topRowID: String?
    private var animationStart: (time: TimeInterval, offsetY: CGFloat)?

    package init() {
        virtualizer = TranscriptVirtualizer(geometry: geometry)
    }

    @MainActor deinit {
        surface?.invalidate()
    }

    package var isFollowing: Bool {
        if case .following = intent { return true }
        return false
    }

    private var isReadingOrFollowing: Bool {
        switch intent {
        case .following, .reading: true
        case .latestTurn, .row: false
        }
    }

    // MARK: Intents

    /// Sets where the transcript should be and keeps it there until the reader scrolls.
    package func pin(_ pin: Pin, animated: Bool = false) {
        switch pin {
        case .bottom: setIntent(.following)
        case .latestTurn: setIntent(.latestTurn)
        case .row(let id): setIntent(.row(id))
        }
        if animated, surface != nil {
            startAnimation()
        } else {
            stopAnimation()
            applyIntent()
        }
    }

    /// A turn started on its own. A reader whose pinned question is also the end of the
    /// transcript is at the bottom, and follows the answer from there.
    package func followIfAtBottom() {
        guard case .latestTurn = intent, let metrics = metrics(), isAtBottom(metrics) else { return }
        setIntent(.following)
    }

    /// Older messages were just revealed above the reader. Until they lay out, scrolling asks
    /// for no further batch, so a burst of scroll events reveals one batch rather than several
    /// at once. Should the reader still be near the top once they have, as after a batch shorter
    /// than the viewport, `onApproachTop` runs again.
    package func didRevealOlderRows() {
        isRevealPending = true
    }

    /// The rendered window opened on only the newest few messages. Once they lay out, older
    /// messages are revealed, a batch per layout, for as long as the viewport still reaches
    /// within a viewport of the oldest rendered one, so the reader opens on a full screen
    /// without the rows far above it rendering.
    ///
    /// Unlike a reveal it holds no further batch back: the window may not change at all, as on a
    /// reload of the same messages, and then no layout would come to clear it. It is checked
    /// once the call has returned as well, for the same reason.
    package func fillViewportWithOlderRows() {
        isFillPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, isFillPending, isReadingOrFollowing, let metrics = metrics(), isNearTop(metrics) else { return }
            isFillPending = false
            approachTop()
        }
    }

    /// Newer messages were just revealed below a window that ends before the transcript does.
    /// Like `didRevealOlderRows`: one batch per layout, and `onApproachBottom` runs again
    /// should the reader still be near the bottom once they have laid out.
    package func didRevealNewerRows() {
        isNewerRevealPending = true
    }

    private func setIntent(_ newIntent: Intent) {
        let wasFollowing = isFollowing
        intent = newIntent
        if wasFollowing != isFollowing { handlerBox?.handlers?.onFollowingChange(isFollowing) }
    }

    // MARK: Scroll view

    package func attach(to handle: PHScrollViewHandle) {
        guard let surface = handle.surface(reusing: surface), surface !== self.surface else { return }
        detach()
        self.surface = surface
        surface.onBoundsChange = { [weak self] in self?.clipBoundsDidChange() }
        surface.onLayoutChange = { [weak self] in self?.layoutDidChange() }
        surface.onScrollWheel = { [weak self] deltaY in self?.scrollWheelDidMove(deltaY: deltaY) }
        last = nil
        applyIntent()
    }

    package func detach() {
        stopAnimation()
        surface?.invalidate()
        surface = nil
        last = nil
        isRevealPending = false
        isNewerRevealPending = false
        isFillPending = false
    }

    private func metrics() -> Metrics? {
        surface?.metrics
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
        guard let surface else { return }
        isApplying = true
        surface.setOffsetY(min(max(offsetY, metrics.minOffsetY), metrics.maxOffsetY))
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

    private func scrollWheelDidMove(deltaY: CGFloat) {
        guard let metrics = metrics() else { return }
        if deltaY > 0 {
            if metrics.offsetY <= metrics.minOffsetY + 0.5 { approachTop() }
        } else if metrics.offsetY >= metrics.maxOffsetY - 0.5 {
            // Likewise a window at its bottom cannot scroll further down.
            approachBottom()
        }
    }

    private func approachTop() {
        guard !isRevealPending else { return }
        handlerBox?.handlers?.onApproachTop()
    }

    private func approachBottom() {
        guard !rendersTranscriptEnd, !isNewerRevealPending else { return }
        handlerBox?.handlers?.onApproachBottom()
    }

    private func layoutDidChange() {
        guard !isApplying else { return }
        let didReveal = isRevealPending || isFillPending
        isRevealPending = false
        isFillPending = false
        let didRevealNewer = isNewerRevealPending
        isNewerRevealPending = false
        // A running animation moves toward the intent's position as it now is.
        guard surface?.isRunningFrameUpdates != true else {
            last = metrics()
            return
        }
        applyIntent()
        // A transcript following its end keeps filling too, as one opened on its newest
        // messages does until they reach above the viewport.
        if didReveal, isReadingOrFollowing, let last, isNearTop(last) {
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
            self.handlerBox?.handlers?.onTopRowChange(id)
        }
    }

    // MARK: Animation

    private func startAnimation() {
        guard let surface, let metrics = metrics() else { return }
        animationStart = (PHScrollSurface.now, metrics.offsetY)
        guard !surface.isRunningFrameUpdates else { return }
        surface.startFrameUpdates { [weak self] in self?.animationDidTick() }
    }

    private func stopAnimation() {
        surface?.stopFrameUpdates()
        animationStart = nil
    }

    /// Eases toward the intent's position as it is on each frame, so content that arrives while
    /// the animation runs moves its destination rather than leaving it short.
    private func animationDidTick() {
        guard let start = animationStart, let metrics = metrics(), let target = intendedOffsetY(in: metrics) else {
            stopAnimation()
            applyIntent()
            return
        }
        let progress = min(1, (PHScrollSurface.now - start.time) / Self.pinAnimationDuration)
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

extension PHView {
    /// Hands the scroll view enclosing this view to `controller`, along with where the transcript
    /// layout sits in the scroll content and the conversation's handlers. Apply it to the
    /// `PHScrollView`'s content: only a view inside the scroll view can find it.
    package func transcriptScroll(
        _ controller: TranscriptScrollController,
        layoutTop: CGFloat,
        latestTurnMargin: CGFloat,
        rendersTranscriptEnd: Bool = true,
        handlers: TranscriptScrollController.Handlers
    ) -> some PHView {
        let box = TranscriptScrollController.HandlerBox(handlers: handlers)
        return phScrollSurface(
            owner: box,
            update: {
                controller.handlerBox = box
                controller.layoutTop = layoutTop
                controller.latestTurnMargin = latestTurnMargin
                controller.rendersTranscriptEnd = rendersTranscriptEnd
            },
            attach: { controller.attach(to: $0) },
            detach: { controller.detach() }
        )
    }
}

extension TranscriptScrollController {
    /// Holds the handlers for as long as the installer that shows them, which the controller
    /// reads weakly: they capture the conversation view's state, which holds the controller.
    package final class HandlerBox {
        package var handlers: Handlers?
        package init(handlers: Handlers) { self.handlers = handlers }
    }
}

private extension PHScrollSurface.Metrics {
    var minOffsetY: CGFloat { -topInset }
    var maxOffsetY: CGFloat { max(minOffsetY, documentHeight + bottomInset - viewportSize.height) }
    /// Where in the scroll content the visible part of the viewport starts.
    var visibleTop: CGFloat { offsetY + topInset }
    var visibleHeight: CGFloat { viewportSize.height - topInset - bottomInset }

    func hasSameLayout(as other: Self) -> Bool {
        documentHeight == other.documentHeight && viewportSize == other.viewportSize
            && topInset == other.topInset && bottomInset == other.bottomInset
    }
}
