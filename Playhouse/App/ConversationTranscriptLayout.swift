import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

final class ConversationScrollSample {
    var offsetY: CGFloat?
    var viewportHeight: CGFloat = 0
    /// Whether new content scrolls the transcript along to its bottom.
    /// Reaching the bottom turns it on and scrolling up away from it turns it
    /// off. It is read only when content changes, so it lives here, where
    /// writing it on every scroll frame re-renders nothing.
    var isFollowingLatest = false
    /// The last geometry the macOS 14 preference reported, which is what its
    /// next report is compared against.
    var geometry: ConversationScrollGeometry?
    /// Height of the runway above the rendered window as last laid out, which
    /// is where the window top sits in the scroll content.
    var runwayHeight: CGFloat = 0
    /// What the runway's estimate was last made for, and that estimate.
    struct RunwayKey: Equatable {
        var firstLoadedID: String?
        var windowStartID: String?
        var hiddenLoadedCount: Int
        var storedCount: Int
    }
    var runwayKey: RunwayKey?
    var estimatedHiddenHeight: CGFloat = 0
    var rowHeights = ConversationRowHeightEstimates()
    /// Estimated height of one message still in the store, taken from the
    /// loaded messages above the rendered window.
    var storedMessageAverageHeight: CGFloat = ConversationRowHeightEstimates.typicalMessageHeight
    /// The text width the runway's estimates were last made at.
    var rowHeightWidth: CGFloat = ConversationRowHeightEstimates.textWidth(viewportWidth: 820)
}

/// Estimated heights of transcript messages that are not rendered, so the
/// runway above the rendered window can stand in for them at about their real
/// length. The scroller then reflects the whole transcript from the start, the
/// way list views size unrealized rows from estimates, instead of shrinking
/// each time a batch of older messages is revealed.
struct ConversationRowHeightEstimates {
    private struct Entry {
        var textLength: Int
        var width: CGFloat
        var height: CGFloat
    }

    private var entries: [String: Entry] = [:]

    /// Width available to message text, rounded so that resizing the window
    /// does not re-estimate every message on every pixel.
    static func textWidth(viewportWidth: CGFloat) -> CGFloat {
        let width = min(viewportWidth, 820) - 56
        return max(200, (width / 20).rounded(.down) * 20)
    }

    mutating func height(for message: ConversationMessage, width: CGFloat) -> CGFloat {
        let textLength = message.text.utf16.count
        if let entry = entries[message.id], entry.textLength == textLength, entry.width == width {
            return entry.height
        }
        let height = Self.estimatedHeight(text: message.text, isUser: message.role == .user, imageCount: message.imageDataURLs.count, width: width)
        entries[message.id] = Entry(textLength: textLength, width: width, height: height)
        return height
    }

    /// Wrapped lines at the transcript's body size, plus the row's own chrome
    /// and the spacing that follows it.
    static func estimatedHeight(text: String, isUser: Bool, imageCount: Int, width: CGFloat) -> CGFloat {
        // A user question sits in a bubble narrower than the column.
        let charactersPerLine = max(20, (isUser ? width * 0.75 : width) / 7.5)
        var lines: CGFloat = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (CGFloat(paragraph.utf16.count) / charactersPerLine).rounded(.up))
        }
        return lines * 21 + (isUser ? 36 : 12) + CGFloat(imageCount) * 180 + 16
    }

    /// A collapsed tool call row with its spacing.
    static let toolCallRowHeight: CGFloat = 46
    /// A stored message's height before any loaded one above the window can
    /// stand in for it.
    static let typicalMessageHeight: CGFloat = 80
}

/// The parts of the transcript's scroll geometry that following the bottom and
/// revealing older messages depend on.
struct ConversationScrollGeometry: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    /// The largest offset the content allows; the transcript is at its bottom
    /// when `offsetY` reaches it.
    var maxOffsetY: CGFloat
}

/// The scroll geometry measured from the content's own frame, for macOS 14,
/// where the scroll view does not report it.
struct ConversationScrollGeometryKey: PreferenceKey {
    static var defaultValue: ConversationScrollGeometry?

    static func reduce(value: inout ConversationScrollGeometry?, nextValue: () -> ConversationScrollGeometry?) {
        value = nextValue() ?? value
    }
}

/// Reports the transcript's scroll geometry where the platform supports it.
/// The preference-based markers stay as the fallback for macOS 14.
struct ConversationScrollOffsetObserver: ViewModifier {
    let onGeometryChange: (_ old: ConversationScrollGeometry, _ new: ConversationScrollGeometry) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: ConversationScrollGeometry.self) { geometry in
                ConversationScrollGeometry(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    maxOffsetY: geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
                )
            } action: { old, new in
                onGeometryChange(old, new)
            }
        } else {
            content
        }
    }
}

struct ConversationTopMarkerPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ConversationLatestTurnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// Only the newest turn reports a height; every other view contributes the
    /// default, which must not replace the measurement.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Marks the row whose top starts the newest turn.
struct ConversationLatestTurnStartKey: LayoutValueKey {
    static let defaultValue = false
}

/// Marks the view the layout stretches over the newest turn instead of stacking.
struct ConversationLatestTurnExtentKey: LayoutValueKey {
    static let defaultValue = false
}

/// A leading-aligned vertical stack that keeps at least
/// `minimumLatestTurnHeight` from the top of the newest turn's first row to its
/// end, adding the difference as blank space below the last row. The extent
/// view is not stacked: it is laid over the newest turn at its natural height.
/// Streamed text a conversation window has received but not yet applied.
/// A reference, so the scheduled apply and the stream share one buffer without
/// every buffered delta invalidating the view.
@MainActor
final class PendingStreamedTextDeltas {
    var messageID: String?
    var taskID: UUID?
    var text = ""
    var isApplyScheduled = false
}

struct ConversationTranscriptLayout: Layout {
    var spacing: CGFloat
    var minimumLatestTurnHeight: CGFloat

    private struct Measurement {
        var sizes: [CGSize]
        var tops: [CGFloat]
        var contentHeight: CGFloat
        var latestTurnTop: CGFloat?
    }

    // Measured on every call rather than cached: a row that grows on its own,
    // like an AppKit text view, would otherwise leave a stale filler behind.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measurement = measure(width: proposal.width, subviews: subviews)
        // As wide as its widest row, as a leading-aligned VStack is.
        let width = measurement.sizes.map(\.width).max() ?? 0
        let latestTurnHeight = measurement.latestTurnTop.map { measurement.contentHeight - $0 } ?? 0
        let filler = measurement.latestTurnTop == nil ? 0 : max(0, minimumLatestTurnHeight - latestTurnHeight)
        return CGSize(width: width, height: measurement.contentHeight + filler)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measurement = measure(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            if subview[ConversationLatestTurnExtentKey.self] {
                let top = measurement.latestTurnTop ?? measurement.contentHeight
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY + top),
                    proposal: ProposedViewSize(width: bounds.width, height: measurement.contentHeight - top)
                )
            } else {
                subview.place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY + measurement.tops[index]),
                    proposal: ProposedViewSize(width: bounds.width, height: measurement.sizes[index].height)
                )
            }
        }
    }

    private func measure(width: CGFloat?, subviews: Subviews) -> Measurement {
        var sizes: [CGSize] = []
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        var hasStacked = false
        var latestTurnTop: CGFloat?
        for subview in subviews {
            guard !subview[ConversationLatestTurnExtentKey.self] else {
                sizes.append(.zero)
                tops.append(0)
                continue
            }
            if hasStacked { y += spacing }
            hasStacked = true
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if latestTurnTop == nil, subview[ConversationLatestTurnStartKey.self] { latestTurnTop = y }
            sizes.append(size)
            tops.append(y)
            y += size.height
        }
        return Measurement(sizes: sizes, tops: tops, contentHeight: y, latestTurnTop: latestTurnTop)
    }
}


struct SelectableAnnotationText: NSViewRepresentable {
    let text: String
    /// Commented ranges of `text`, rendered orange.
    let highlightedRanges: [NSRange]
    /// `@` mentions in `text`, rendered in the accent color.
    var mentionRanges: [NSRange] = []
    /// Ranges of `text` a side chat discusses, rendered purple unless a comment covers them too.
    var chatRanges: [NSRange] = []
    /// A click inside a commented or side-chatted range, selecting nothing, reports that range
    /// (a commented one first) and where it is in the text.
    var onHighlightClick: ((NSRange, CGRect) -> Void)? = nil
    var responseAnnotations: [ResponseAnnotationReference] = []
    var responseCommentSourcePrefix = ""
    var isAssistantText = false
    var textColor: NSColor = .labelColor
    let onSelection: (NSRange, String, CGRect) -> Void
    var formattedText: NSAttributedString? = nil
    var font = NSFont.systemFont(ofSize: 16)
    var wholeMessageText: String? = nil
    var accessibilityBlocks: [CommentTrackingTextView.AccessibilityBlock] = []

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            responseCommentSourcePrefix: responseCommentSourcePrefix
        )
    }

    func makeNSView(context: Context) -> NSTextView {
        // TextKit 2 lays out and draws only what it takes to be the visible part of a text view,
        // which it misjudges inside a SwiftUI scroll view, leaving a reply taller than the
        // viewport blank. Its layout manager is also needed for selection and hover hit-testing.
        let view = CommentTrackingTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(InlineCodeLayoutManager())
        view.isEditable = false
        view.isSelectable = true
        if isAssistantText {
            view.setAccessibilityRole(.staticText)
        }
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 5)
        view.textContainer?.lineFragmentPadding = 0
        // SwiftUI sizes the view through sizeThatFits; a self-resizing text view grows from its
        // bottom edge in the unflipped host and draws outside its frame until SwiftUI catches up.
        view.isVerticallyResizable = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        context.coordinator.anchorView = view
        view.hoverTrackingOwner = context.coordinator
        view.accessibilityBlocks = accessibilityBlocks
        view.onClickWithoutSelection = { [weak coordinator = context.coordinator, weak view] index in
            guard let coordinator, let view else { return }
            coordinator.highlightClicked(at: index, in: view)
        }
        updateHighlightClicks(context.coordinator)
        view.updateTrackingAreas()
        update(view, coordinator: context.coordinator)
        context.coordinator.renderedKey = renderKey
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        (view as? CommentTrackingTextView)?.wholeMessageText = wholeMessageText
        (view as? CommentTrackingTextView)?.accessibilityBlocks = accessibilityBlocks
        context.coordinator.onSelection = onSelection
        context.coordinator.responseCommentSourcePrefix = responseCommentSourcePrefix
        context.coordinator.anchorView = view
        updateHighlightClicks(context.coordinator)
        guard context.coordinator.renderedKey != renderKey else {
            return
        }
        update(view, coordinator: context.coordinator)
        context.coordinator.renderedKey = renderKey
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 500)
        // Laying the text out again is the costliest part of a transcript re-render, and its
        // result only changes with the width or with the text, which `update` replaces.
        let contentHeight = context.coordinator.measurer.height(forWidth: width, in: nsView)
        return CGSize(width: width, height: ceil(contentHeight) + 2 * nsView.textContainerInset.height + 2)
    }

    private var renderKey: String {
        responseCommentSourcePrefix + "|" + text + highlightedRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            + "|" + mentionRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            + "|" + chatRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            + responseAnnotations.map { "\($0.text):\($0.comment)" }.joined(separator: "|")
    }

    private func updateHighlightClicks(_ coordinator: Coordinator) {
        coordinator.onHighlightClick = onHighlightClick
        coordinator.highlightRanges = onHighlightClick == nil ? [] : highlightedRanges + chatRanges
    }

    private func update(_ view: NSTextView, coordinator: Coordinator) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let value: NSMutableAttributedString
        if let formattedText {
            value = NSMutableAttributedString(attributedString: formattedText)
            for (key, fallback) in [(NSAttributedString.Key.font, font as Any),
                                    (.foregroundColor, textColor as Any),
                                    (.paragraphStyle, style as Any)] {
                var missingRanges: [NSRange] = []
                value.enumerateAttribute(key, in: NSRange(location: 0, length: value.length)) { attribute, range, _ in
                    if attribute == nil { missingRanges.append(range) }
                }
                for range in missingRanges where range.length > 0 {
                    value.addAttribute(key, value: fallback, range: range)
                }
            }
        } else {
            value = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: style
            ])
        }
        for range in mentionRanges {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= value.length else { continue }
            value.addAttributes([.foregroundColor: NSColor.controlAccentColor, .playhouseMention: true], range: range)
        }
        // Purple first, so a range that is commented as well ends up orange.
        for (ranges, color) in [(chatRanges, NSColor.systemPurple), (highlightedRanges, NSColor.systemOrange)] {
            for range in ranges {
                guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= value.length else { continue }
                value.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
        Self.replaceResponseAnnotationMarkers(in: value, references: responseAnnotations)
        // Setting these restyles all of the text already shown, which would defeat replacing only
        // its changed tail; every run in `value` carries its own font and color anyway.
        if view.textStorage?.length == 0 {
            view.font = font
            view.textColor = textColor
        }
        view.backgroundColor = .clear
        // The measurer holds the text the view shows, until it takes the new one below.
        view.textStorage?.replaceChangedTail(with: value, previous: coordinator.measurer.text)
        coordinator.measurer.setText(value)
        // Read back from what is drawn, so the title names exactly the mentions shown in color.
        view.setAccessibilityTitle(view.textStorage?.drawnMentionsTitle)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.responseCommentContentDidChange()
    }

    private static let responseCommentTextKey = NSAttributedString.Key("PlayhouseResponseCommentText")
    private static let responseCommentBodyKey = NSAttributedString.Key("PlayhouseResponseCommentBody")

    static func replaceResponseAnnotationMarkers(in value: NSMutableAttributedString, references: [ResponseAnnotationReference]) {
        let pattern = #":(?:playhouse-annotation|codex-annotation)\{index=\"(\d+)\"\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let originalText = value.string as NSString
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: originalText.length)).reversed() {
            guard match.numberOfRanges > 1,
                  let index = Int(originalText.substring(with: match.range(at: 1))) else { continue }
            let label = match.range.location == 0 ? "\(index + 1)." : "Comment \(index + 1)"
            let isResolved = references.indices.contains(index)
            let replacement = NSMutableAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: isResolved ? NSColor.controlAccentColor
                    : (value.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor ?? .labelColor),
            ])
            if isResolved {
                let reference = references[index]
                replacement.addAttribute(.underlineStyle,
                                         value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                         range: NSRange(location: 0, length: replacement.length))
                replacement.addAttribute(responseCommentTextKey, value: reference.text, range: NSRange(location: 0, length: replacement.length))
                replacement.addAttribute(responseCommentBodyKey, value: reference.comment, range: NSRange(location: 0, length: replacement.length))
            }
            value.replaceCharacters(in: match.range, with: replacement)
        }
    }

    final class Coordinator: NSResponder, NSTextViewDelegate, NSPopoverDelegate {
        var onSelection: (NSRange, String, CGRect) -> Void
        var onHighlightClick: ((NSRange, CGRect) -> Void)?
        /// The commented ranges, then the side-chatted ones, in the order a click checks them.
        var highlightRanges: [NSRange] = []
        var responseCommentSourcePrefix: String
        weak var anchorView: NSTextView?
        var renderedKey = ""
        let measurer = TextHeightMeasurer()
        /// Room above a selection for the Side chat hint, centered 22pt above it and 30pt tall.
        private static let selectionHintClearance: CGFloat = 40
        private var responseCommentPopover: NSPopover?
        private var activeResponseCommentID: String?
        private var pendingResponseCommentSourceID: String?
        private var pendingResponseCommentWorkItem: DispatchWorkItem?

        init(
            onSelection: @escaping (NSRange, String, CGRect) -> Void,
            responseCommentSourcePrefix: String
        ) {
            self.onSelection = onSelection
            self.responseCommentSourcePrefix = responseCommentSourcePrefix
            super.init()
        }

        required init?(coder: NSCoder) {
            return nil
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            guard let anchorView else { return }
            updateResponseCommentHover(at: nil, in: anchorView)
        }

        private func updateHover(for event: NSEvent) {
            guard let anchorView else { return }
            updateResponseCommentHover(at: anchorView.convert(event.locationInWindow, from: nil), in: anchorView)
        }

        func updateResponseCommentHover(at point: CGPoint?, in view: NSTextView) {
            let hit = point.flatMap { responseComment(at: $0, in: view) }
            guard let hit else {
                cancelPendingResponseCommentHover()
                closeResponseCommentPopover()
                return
            }
            let sourceID = hit.sourceID
            if sourceID == pendingResponseCommentSourceID ||
                (sourceID == activeResponseCommentID && responseCommentPopover?.isShown == true) {
                return
            }
            cancelPendingResponseCommentHover()
            closeResponseCommentPopover()
            pendingResponseCommentSourceID = sourceID
            let workItem = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view,
                      self.pendingResponseCommentSourceID == sourceID,
                      let window = view.window else { return }
                self.pendingResponseCommentWorkItem = nil
                self.pendingResponseCommentSourceID = nil
                let currentPoint = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let currentHit = self.responseComment(at: currentPoint, in: view)
                guard let currentHit,
                      currentHit.sourceID == sourceID else { return }
                self.showResponseCommentPopover(
                    sourceID: sourceID,
                    selectedText: currentHit.selectedText,
                    comment: currentHit.comment,
                    bounds: currentHit.anchor,
                    anchorView: view
                )
            }
            pendingResponseCommentWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: workItem)
        }

        private func responseComment(at point: CGPoint, in view: NSTextView) -> (sourceID: String, selectedText: String, comment: String, anchor: CGRect)? {
            guard let storage = view.textStorage,
                  let layoutManager = view.layoutManager,
                  let textContainer = view.textContainer,
                  let window = view.window else { return nil }
            var hit: (sourceID: String, selectedText: String, comment: String, anchor: CGRect)?
            storage.enumerateAttribute(
                SelectableAnnotationText.responseCommentTextKey,
                in: NSRange(location: 0, length: storage.length)
            ) { selectedTextValue, range, stop in
                guard let selectedText = selectedTextValue as? String, range.length > 0,
                      let comment = storage.attribute(SelectableAnnotationText.responseCommentBodyKey,
                                                      at: range.location, effectiveRange: nil) as? String else { return }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var fragments: [CGRect] = []
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { rect, _ in
                    let origin = view.textContainerOrigin
                    fragments.append(CGRect(
                        x: origin.x + rect.minX,
                        y: view.isFlipped ? origin.y + rect.minY : view.bounds.height - origin.y - rect.maxY,
                        width: rect.width,
                        height: rect.height
                    ))
                }
                guard let firstFragment = fragments.first else { return }
                let firstScreenRect = view.firstRect(forCharacterRange: range, actualRange: nil)
                guard !firstScreenRect.isNull, !firstScreenRect.isEmpty else { return }
                let firstViewRect = view.convert(window.convertFromScreen(firstScreenRect), from: nil)
                let offset = CGPoint(x: firstViewRect.minX - firstFragment.minX,
                                     y: firstViewRect.minY - firstFragment.minY)
                for (index, fragment) in fragments.enumerated() {
                    let glyphBounds = index == 0 ? firstViewRect
                        : fragment.offsetBy(dx: offset.x, dy: offset.y)
                    let bounds = glyphBounds.insetBy(dx: -4, dy: -5)
                    guard bounds.contains(point) else { continue }
                    hit = (
                        sourceID: "\(self.responseCommentSourcePrefix):\(range.location)",
                        selectedText: selectedText,
                        comment: comment,
                        anchor: CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: 1)
                    )
                    stop.pointee = true
                    break
                }
            }
            return hit
        }


        private func showResponseCommentPopover(
            sourceID: String,
            selectedText: String,
            comment: String,
            bounds: CGRect,
            anchorView: NSView
        ) {
            guard activeResponseCommentID != sourceID || responseCommentPopover?.isShown != true else { return }
            closeResponseCommentPopover()
            activeResponseCommentID = sourceID

            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.delegate = self
            let hostingController = NSHostingController(rootView: ResponseCommentHoverCard(
                selectedText: selectedText,
                comment: comment
            ))
            hostingController.view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: 320, height: 120)
            responseCommentPopover = popover
            popover.show(relativeTo: bounds, of: anchorView, preferredEdge: .minY)
        }

        private func closeResponseCommentPopover() {
            responseCommentPopover?.close()
            responseCommentPopover = nil
            activeResponseCommentID = nil
        }

        private func cancelPendingResponseCommentHover() {
            pendingResponseCommentWorkItem?.cancel()
            pendingResponseCommentWorkItem = nil
            pendingResponseCommentSourceID = nil
        }

        func responseCommentContentDidChange() {
            cancelPendingResponseCommentHover()
            closeResponseCommentPopover()
        }

        func popoverDidClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover,
                  popover === responseCommentPopover else { return }
            responseCommentPopover = nil
            activeResponseCommentID = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (view.string as NSString).length else {
                onSelection(range, "", .zero)
                return
            }
            let text = (view.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            onSelection(range, text, bounds(of: range, in: view))
        }

        func highlightClicked(at index: Int, in view: NSTextView) {
            guard let onHighlightClick,
                  let range = highlightRanges.first(where: { NSLocationInRange(index, $0) }),
                  NSMaxRange(range) <= (view.string as NSString).length else { return }
            onHighlightClick(range, bounds(of: range, in: view))
        }

        /// Where `range` is in the view, as the Side chat hint and bubble anchor on it.
        private func bounds(of range: NSRange, in view: NSTextView) -> CGRect {
            let glyphs = view.layoutManager?.glyphRange(forCharacterRange: range, actualCharacterRange: nil) ?? NSRange(location: 0, length: 0)
            var bounds = view.layoutManager?.boundingRect(forGlyphRange: glyphs, in: view.textContainer!) ?? .zero
            bounds.origin.x += view.textContainerOrigin.x
            bounds.origin.y += view.textContainerOrigin.y
            // A selection that starts above the visible part of the transcript anchors its Side
            // chat hint, which sits above the selection, to the top of what is still visible.
            let visible = view.visibleRect
            if bounds.minY < visible.minY, bounds.maxY > visible.minY {
                let top = min(visible.minY + Self.selectionHintClearance, bounds.maxY)
                bounds.size.height = bounds.maxY - top
                bounds.origin.y = top
            }
            return bounds
        }
    }
}

/// The schedule chosen in the composer's hint, before Send saves it.
struct ComposerSchedule: Equatable {
    var kind: TaskScheduleKind = .once
    var fireAt: Date = ComposerSchedule.nextFullHour()
    var title = ""
    var preset: TaskRecurrence.Preset = .daily
    /// The hour and minute of a daily, weekday or weekly run.
    var time: Date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
    /// The minute past the hour of an hourly run.
    var minute = 0
    var weekday = 2

    init() {}

    init?(task: BoardTask) {
        guard let kind = task.scheduleKind else { return nil }
        self.kind = kind
        if kind == .once {
            fireAt = task.scheduledAt ?? Self.nextFullHour()
        } else if let recurrence = task.scheduleRecurrence {
            title = task.title
            preset = recurrence.preset
            time = Calendar.current.date(bySettingHour: recurrence.hour, minute: recurrence.minute, second: 0, of: .now) ?? .now
            minute = recurrence.minute
            weekday = recurrence.weekday ?? 2
        }
    }

    /// The next full hour at least five minutes away, so the default can't pass while the
    /// hint is still open.
    static func nextFullHour(after now: Date = .now) -> Date {
        Calendar.current.nextDate(after: now.addingTimeInterval(300), matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? now.addingTimeInterval(3600)
    }

    var recurrence: TaskRecurrence {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return TaskRecurrence(
            preset: preset,
            hour: parts.hour ?? 9,
            minute: preset == .hourly ? minute : (parts.minute ?? 0),
            weekday: preset == .weekly ? weekday : nil
        )
    }

    func validationMessage(now: Date = .now) -> String? {
        switch kind {
        case .once:
            return fireAt > now ? nil : "Choose a time in the future."
        case .recurring:
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Give the recurring task a title." : nil
        }
    }

    func summary(now: Date = .now) -> String {
        switch kind {
        case .once:
            return "Runs \(ScheduleFormatting.relativeTime(fireAt, now: now))"
        case .recurring:
            let next = recurrence.nextOccurrence(after: now)
            return "\(recurrence.summary()) · next \(ScheduleFormatting.relativeTime(next, now: now))"
        }
    }

    func request(prompt: String, imageDataURLs: [String], mode: ConversationMode, modelID: String?) -> TaskScheduleRequest {
        TaskScheduleRequest(
            kind: kind,
            fireAt: kind == .once ? fireAt : nil,
            recurrence: kind == .recurring ? recurrence : nil,
            title: kind == .recurring ? title : nil,
            prompt: prompt,
            imageDataURLs: imageDataURLs,
            mode: mode,
            modelID: modelID
        )
    }
}

