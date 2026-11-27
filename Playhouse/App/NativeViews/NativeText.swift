import AppKit
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI
import PlayhouseViews
import SwiftUI

// The transcript's and the Markdown atom's native text views, behind `PHNativeSelectableText`
// and `PHNativeCodeBlockText`: AppKit lays out, draws and selects the text.

package struct SelectableAnnotationText: NSViewRepresentable {
    package let text: String
    /// Commented ranges of `text`, rendered orange.
    package let highlightedRanges: [NSRange]
    /// `@` mentions in `text`, rendered in the accent color.
    package var mentionRanges: [NSRange] = []
    /// Ranges of `text` a side chat discusses, rendered purple unless a comment covers them too.
    package var chatRanges: [NSRange] = []
    /// A click inside a commented or side-chatted range, selecting nothing, reports that range
    /// (a commented one first) and where it is in the text.
    package var onHighlightClick: ((NSRange, CGRect) -> Void)? = nil
    package var responseAnnotations: [ResponseAnnotationReference] = []
    package var responseCommentSourcePrefix = ""
    package var isAssistantText = false
    package var textColor: PHPlatformColor = .labelColor
    package let onSelection: (NSRange, String, CGRect) -> Void
    package var formattedText: NSAttributedString? = nil
    package var font = PHPlatformFont.systemFont(ofSize: 16)
    package var wholeMessageText: String? = nil
    package var accessibilityBlocks: [CommentTrackingTextView.AccessibilityBlock] = []
    /// False keeps the text from being selected; its links still open.
    package var allowsSelection = true
    /// Opens only web and mail links, as plugin text may; any other link does nothing.
    package var restrictsLinks = false
    /// Reports `accessibilityBlocks` as static texts, read by their labels, instead of groups
    /// that only locate their part of the text.
    package var blocksAreText = false
    /// Set on the text view itself, which a SwiftUI identifier around it may not reach.
    package var accessibilityIdentifier: String? = nil

    package func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            responseCommentSourcePrefix: responseCommentSourcePrefix
        )
    }

    package func makeNSView(context: Context) -> NSTextView {
        // TextKit 2 lays out and draws only what it takes to be the visible part of a text view,
        // which it misjudges inside a SwiftUI scroll view, leaving a reply taller than the
        // viewport blank. Its layout manager is also needed for selection and hover hit-testing.
        let view = CommentTrackingTextView(usingTextLayoutManager: false)
        view.textContainer?.replaceLayoutManager(MarkdownLayoutManager())
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
        view.blocksAreText = blocksAreText
        if let accessibilityIdentifier { view.setAccessibilityIdentifier(accessibilityIdentifier) }
        view.accessibilityBlocks = accessibilityBlocks
        view.onClickWithoutSelection = { [weak coordinator = context.coordinator, weak view] index in
            guard let coordinator, let view else { return }
            coordinator.highlightClicked(at: index, in: view)
        }
        updateHighlightClicks(context.coordinator)
        view.updateTrackingAreas()
        update(view, coordinator: context.coordinator)
        context.coordinator.renderedKey = renderKey
        context.coordinator.renderedText = formattedText
        return view
    }

    package func updateNSView(_ view: NSTextView, context: Context) {
        (view as? CommentTrackingTextView)?.wholeMessageText = wholeMessageText
        (view as? CommentTrackingTextView)?.accessibilityBlocks = accessibilityBlocks
        context.coordinator.onSelection = onSelection
        context.coordinator.responseCommentSourcePrefix = responseCommentSourcePrefix
        context.coordinator.anchorView = view
        updateHighlightClicks(context.coordinator)
        // The formatted text is cached per input, so another instance can restyle the same characters.
        guard context.coordinator.renderedKey != renderKey || context.coordinator.renderedText !== formattedText else {
            return
        }
        update(view, coordinator: context.coordinator)
        context.coordinator.renderedKey = renderKey
        context.coordinator.renderedText = formattedText
    }

    package func sizeThatFits(_ proposal: PHProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 500)
        // Laying the text out again is the costliest part of a transcript re-render, and its
        // result only changes with the width or with the text, which `update` replaces.
        let contentHeight = context.coordinator.measurer.height(forWidth: width, in: nsView)
        return CGSize(width: width, height: ceil(contentHeight) + 2 * nsView.textContainerInset.height + 2)
    }

    private var renderKey: String {
        "\(font.pointSize)|\(textColor.description)|" + responseCommentSourcePrefix + "|" + text + highlightedRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            + "|" + mentionRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            + "|" + chatRanges.map { "\($0.location):\($0.length)" }.joined(separator: ",")
            + responseAnnotations.map { "\($0.text):\($0.comment)" }.joined(separator: "|")
    }

    private func updateHighlightClicks(_ coordinator: Coordinator) {
        coordinator.allowsSelection = allowsSelection
        coordinator.restrictsLinks = restrictsLinks
        coordinator.onHighlightClick = onHighlightClick
        coordinator.highlightRanges = onHighlightClick == nil ? [] : highlightedRanges + chatRanges
    }

    private func update(_ view: NSTextView, coordinator: Coordinator) {
        let style = PHMutableParagraphStyle()
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
            value.addAttributes([.foregroundColor: PHPlatformColor.controlAccentColor, .playhouseMention: true], range: range)
        }
        // Purple first, so a range that is commented as well ends up orange.
        for (ranges, color) in [(chatRanges, PHPlatformColor.systemPurple), (highlightedRanges, PHPlatformColor.systemOrange)] {
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

    private static var responseCommentTextKey: NSAttributedString.Key { PHNativeSelectableText.responseCommentTextKey }
    private static var responseCommentBodyKey: NSAttributedString.Key { PHNativeSelectableText.responseCommentBodyKey }

    package static func replaceResponseAnnotationMarkers(in value: NSMutableAttributedString, references: [ResponseAnnotationReference]) {
        PHNativeSelectableText.replaceResponseAnnotationMarkers(in: value, references: references)
    }

    package final class Coordinator: NSResponder, NSTextViewDelegate, NSPopoverDelegate {
        package var onSelection: (NSRange, String, CGRect) -> Void
        package var onHighlightClick: ((NSRange, CGRect) -> Void)?
        /// The commented ranges, then the side-chatted ones, in the order a click checks them.
        package var highlightRanges: [NSRange] = []
        package var responseCommentSourcePrefix: String
        package var allowsSelection = true
        package var restrictsLinks = false
        package weak var anchorView: NSTextView?
        package var renderedKey = ""
        /// The formatted text last shown, held so a new instance is told apart from it.
        package var renderedText: NSAttributedString?
        package let measurer = TextHeightMeasurer()
        /// Room above a selection for the Side chat hint, centered 22pt above it and 30pt tall.
        private static let selectionHintClearance: CGFloat = 40
        private var responseCommentPopover: NSPopover?
        private var activeResponseCommentID: String?
        private var pendingResponseCommentSourceID: String?
        private var pendingResponseCommentWorkItem: DispatchWorkItem?

        package init(
            onSelection: @escaping (NSRange, String, CGRect) -> Void,
            responseCommentSourcePrefix: String
        ) {
            self.onSelection = onSelection
            self.responseCommentSourcePrefix = responseCommentSourcePrefix
            super.init()
        }

        package required init?(coder: NSCoder) {
            return nil
        }

        package override func mouseEntered(with event: NSEvent) {
            updateHover(for: event)
        }

        package override func mouseMoved(with event: NSEvent) {
            updateHover(for: event)
        }

        package override func mouseExited(with event: NSEvent) {
            guard let anchorView else { return }
            updateResponseCommentHover(at: nil, in: anchorView)
        }

        private func updateHover(for event: NSEvent) {
            guard let anchorView else { return }
            updateResponseCommentHover(at: anchorView.convert(event.locationInWindow, from: nil), in: anchorView)
        }

        package func updateResponseCommentHover(at point: CGPoint?, in view: NSTextView) {
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

        package func responseCommentContentDidChange() {
            cancelPendingResponseCommentHover()
            closeResponseCommentPopover()
        }

        package func popoverDidClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover,
                  popover === responseCommentPopover else { return }
            responseCommentPopover = nil
            activeResponseCommentID = nil
        }

        package func textView(
            _ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
            toCharacterRange newSelectedCharRange: NSRange
        ) -> NSRange {
            allowsSelection ? newSelectedCharRange : NSRange(location: newSelectedCharRange.location, length: 0)
        }

        package func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard restrictsLinks else { return false }
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            guard let url, MarkdownDocument.opensLink(url) else { return true }
            Platform.services.open(url)
            return true
        }

        package func textViewDidChangeSelection(_ notification: Notification) {
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

        package func highlightClicked(at index: Int, in view: NSTextView) {
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

package final class CommentTrackingTextView: MeasuredTextView {
    package var hoverTrackingOwner: AnyObject?
    /// A single click that leaves nothing selected, with the index of the character it hit.
    package var onClickWithoutSelection: ((Int) -> Void)?
    /// The whole message this block belongs to; copying a fully selected block copies it all.
    package var wholeMessageText: String?
    /// The prose blocks laid out in this view, exposed as their own accessibility elements so
    /// each heading, paragraph, and list item stays identifiable though they share one view.
    package var accessibilityBlocks: [AccessibilityBlock] = [] {
        didSet { if accessibilityBlocks != oldValue { blockElements = nil } }
    }
    /// Reports the blocks as static texts rather than groups; see `SelectableAnnotationText.blocksAreText`.
    package var blocksAreText = false
    /// Accessibility clients hold on to children between queries, so the elements live as long
    /// as the blocks they describe.
    private var blockElements: [BlockAccessibilityElement]?
    private var hoverTrackingArea: NSTrackingArea?

    package typealias AccessibilityBlock = SelectableTextAccessibilityBlock

    private final class BlockAccessibilityElement: NSAccessibilityElement {
        weak var textView: NSTextView?
        let range: NSRange

        init(block: AccessibilityBlock, textView: NSTextView, isText: Bool) {
            self.textView = textView
            range = block.range
            super.init()
            setAccessibilityRole(isText ? .staticText : .group)
            setAccessibilityLabel(block.label)
            if !block.identifier.isEmpty { setAccessibilityIdentifier(block.identifier) }
            setAccessibilityParent(textView)
        }

        /// Computed on each query, since the view moves as the transcript scrolls. Placed
        /// relative to the text view's own accessibility frame: converting through the window
        /// misses the transcript's scroll offset for a text view taller than the viewport.
        override func accessibilityFrame() -> NSRect {
            guard let textView,
                  let layoutManager = textView.layoutManager, let textContainer = textView.textContainer,
                  NSMaxRange(range) <= (textView.string as NSString).length else { return .zero }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textView.textContainerOrigin.x - textView.bounds.minX,
                          dy: textView.textContainerOrigin.y - textView.bounds.minY)
            // The text view is flipped, and screen coordinates grow upward from its bottom edge.
            let viewFrame = textView.accessibilityFrame()
            return NSRect(x: viewFrame.minX + bounds.minX, y: viewFrame.maxY - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }
    }

    package override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        guard !accessibilityBlocks.isEmpty else { return children }
        let elements = blockElements ?? accessibilityBlocks.map { BlockAccessibilityElement(block: $0, textView: self, isText: blocksAreText) }
        blockElements = elements
        return children + elements
    }

    package override func copy(_ sender: Any?) {
        guard let wholeMessageText, selectedRange() == NSRange(location: 0, length: string.utf16.count) else {
            super.copy(sender)
            return
        }
        Platform.services.copyToClipboard(wholeMessageText)
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    private var pendingClick: DispatchWorkItem?

    /// The text view tracks the drag that selects text until the mouse goes up, so the
    /// selection is settled by the time `super` returns. The click is reported once the
    /// double-click interval passes without another, so double-clicking still selects a word.
    package override func mouseDown(with event: NSEvent) {
        pendingClick?.cancel()
        pendingClick = nil
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0, onClickWithoutSelection != nil,
              let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        // A click on the character itself, not on the empty end of its line.
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .contains(containerPoint) else { return }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let click = DispatchWorkItem { [weak self] in
            guard let self, self.selectedRange().length == 0 else { return }
            self.pendingClick = nil
            self.onClickWithoutSelection?(index)
        }
        pendingClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil, let hoverTrackingOwner else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: hoverTrackingOwner,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }
}

/// A text view whose height `TextHeightMeasurer` measures with its own layout manager. Measuring
/// sets the text container to each width SwiftUI asks about, and a width answered from the
/// measurer's cache leaves the container where the last uncached question put it, so the
/// container is matched to the view's own width again before the text is drawn.
package class MeasuredTextView: NSTextView {
    package override func viewWillDraw() {
        if let textContainer {
            let width = bounds.width - 2 * textContainerInset.width
            if textContainer.size.width != width {
                textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            }
        }
        super.viewWillDraw()
    }
}

package final class TextHeightMeasurer {
    private var heights: [CGFloat: CGFloat] = [:]
    /// The text last measured, as it was given.
    package private(set) var text: NSAttributedString?

    /// Records the text the view now shows, which forgets every height measured for the previous text.
    package func setText(_ text: NSAttributedString) {
        self.text = text.copy() as? NSAttributedString
        heights.removeAll()
    }

    package func height(forWidth width: CGFloat, in view: NSTextView) -> CGFloat {
        if let height = heights[width] { return height }
        guard let layoutManager = view.layoutManager, let container = view.textContainer else { return 0 }
        // The container tracks the view's width, which SwiftUI sets to this proposal next, so the
        // layout made here is usually the one the view draws; `MeasuredTextView` puts the
        // container back to its own width before drawing when a later question moved it.
        if container.size.width != width {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        // A live window resize proposes a new width every frame; only the latest few recur.
        if heights.count >= 8 { heights.removeAll() }
        heights[width] = height
        return height
    }
}

/// Draws what Markdown text shows behind its glyphs: each inline code run's pill, one per line
/// the run spans, and each quote's bar down the leading edge of its lines.
package final class MarkdownLayoutManager: NSLayoutManager {
    package override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(MarkdownQuoteStyle.attribute, in: characters) { value, range, _ in
            guard let color = value as? PHPlatformColor else { return }
            var bar = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { lineRect, usedRect, _, _, _ in
                bar = bar.union(NSRect(x: lineRect.minX, y: usedRect.minY, width: MarkdownQuoteStyle.barWidth, height: usedRect.height))
            }
            guard !bar.isNull else { return }
            color.setFill()
            NSBezierPath(roundedRect: bar.offsetBy(dx: origin.x, dy: origin.y), xRadius: 1.5, yRadius: 1.5).fill()
        }
        storage.enumerateAttribute(InlineCodeStyle.attribute, in: characters) { value, range, _ in
            guard let color = value as? PHPlatformColor else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? PHPlatformFont
                ?? PHPlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            let codeGlyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            enumerateLineFragments(forGlyphRange: codeGlyphs) { lineRect, _, _, lineGlyphs, _ in
                let piece = NSIntersectionRange(lineGlyphs, codeGlyphs)
                guard piece.length > 0 else { return }
                var rect = self.boundingRect(forGlyphRange: piece, in: container)
                let baseline = lineRect.minY + self.location(forGlyphAt: piece.location).y
                rect.origin.y = baseline - font.ascender - 2
                rect.size.height = font.ascender - font.descender + 4
                rect.origin.x -= InlineCodeStyle.horizontalPadding - 1
                rect.size.width += InlineCodeStyle.horizontalPadding - 1
                color.setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

package struct CodeBlockTextView: NSViewRepresentable {
    package let attributedText: NSAttributedString

    package func makeCoordinator() -> TextHeightMeasurer {
        TextHeightMeasurer()
    }

    package func makeNSView(context: Context) -> NSTextView {
        // TextKit 1 lays out and draws all of the text; see SelectableAnnotationText.
        let view = MeasuredTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = false
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(attributedText)
        context.coordinator.setText(attributedText)
        return view
    }

    package func updateNSView(_ view: NSTextView, context: Context) {
        guard view.textStorage?.string != attributedText.string else { return }
        // The measurer holds the text the view shows, until it takes the new one below.
        view.textStorage?.replaceChangedTail(with: attributedText, previous: context.coordinator.text)
        context.coordinator.setText(attributedText)
    }

    package func sizeThatFits(_ proposal: PHProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 500)
        let contentHeight = context.coordinator.height(forWidth: width, in: nsView)
        return CGSize(width: width, height: ceil(contentHeight) + 2)
    }
}

extension NSTextStorage {
    /// Changes the storage from showing `previous` to showing `text`, keeping the paragraphs both
    /// share at the start. A streaming reply grows at its end, and a layout manager re-lays out
    /// only from the first edited character, so each update costs the new text rather than the
    /// whole reply. The two are compared as given because the storage itself never equals what
    /// was set: it substitutes fonts, for emoji for example.
    package func replaceChangedTail(with text: NSAttributedString, previous: NSAttributedString?) {
        guard let previous, previous.length == length else {
            setAttributedString(text)
            return
        }
        let oldText = previous.string as NSString
        let newText = text.string as NSString
        var common = 0
        for (old, new) in zip(previous.string.utf16, text.string.utf16) {
            guard old == new else { break }
            common += 1
        }
        if common == oldText.length, common == newText.length, previous.isEqual(to: text) { return }
        // A paragraph's style can depend on what follows it (list spacing, the line break that
        // joins it to a new block), so the paragraph before the change is replaced as well.
        var start = oldText.paragraphRange(for: NSRange(location: common, length: 0)).location
        if start > 0 {
            start = oldText.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        // A change of style further back, such as a highlighted comment, replaces everything.
        if start > 0, !previous.attributedSubstring(from: NSRange(location: 0, length: start))
            .isEqual(to: text.attributedSubstring(from: NSRange(location: 0, length: start))) {
            start = 0
        }
        beginEditing()
        replaceCharacters(
            in: NSRange(location: start, length: oldText.length - start),
            with: text.attributedSubstring(from: NSRange(location: start, length: newText.length - start))
        )
        endEditing()
    }
}
