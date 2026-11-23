import AppKit
import SwiftUI

/// The Markdown atom's sizes and spacing, all scaled from its body size: the transcript reads at
/// 16 points and the skill previews at 13, and both take every other measure from here.
/// A `>` quote's bar, drawn down the leading edge of its lines by `MarkdownLayoutManager`.
enum MarkdownQuoteStyle {
    /// Marks a quote's text; its value is the bar's color.
    static let attribute = NSAttributedString.Key("PlayhouseMarkdownQuote")
    static let barWidth: CGFloat = 3
    static let barColor = NSColor.secondaryLabelColor.withAlphaComponent(0.4)
}

struct MarkdownStyle: Hashable {
    let size: CGFloat

    var bodyFont: NSFont { .systemFont(ofSize: size) }
    /// Headings are semibold and scale from the body size: at the transcript's 16 points, 19, 17,
    /// then 15.
    func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: size + 3, weight: .semibold)
        case 2: .systemFont(ofSize: size + 1, weight: .semibold)
        default: .systemFont(ofSize: size - 1, weight: .semibold)
        }
    }
    /// Code blocks and tables sit a step below the prose; a monospaced face reads larger than it.
    var codeFont: NSFont { .monospacedSystemFont(ofSize: (size * 0.9).rounded(), weight: .regular) }
    var tableFont: NSFont { .systemFont(ofSize: (size * 0.9).rounded()) }
    /// The text's own size and color: bullets read as part of the text, like an editor's
    /// rendered Markdown, rather than as faint annotations beside it.
    var bulletFont: NSFont { .systemFont(ofSize: size, weight: .black) }

    var lineSpacing: CGFloat { (size / 4).rounded() }
    /// After a paragraph, a quote, a heading's section or a whole list.
    var paragraphSpacing: CGFloat { (size * 0.875).rounded() }
    /// A list's items sit close together.
    var listItemSpacing: CGFloat { (size * 0.375).rounded() }
    /// Before a list that follows prose.
    var beforeListSpacing: CGFloat { (size * 0.625).rounded() }
    var headingSpacing: CGFloat { (size / 2).rounded() }
    /// Indent shared by every list item, so bullets and numbers line up down a list.
    var listIndent: CGFloat { (size * 1.625).rounded() }
    /// Leaves room for the leading quote bar.
    var quoteIndent: CGFloat { size }
    /// Between a prose run and the cards around it.
    var blockSpacing: CGFloat { (size * 0.45).rounded() }
    /// Below a prose run that ends on a paragraph, which has no paragraph spacing of its own.
    var trailingParagraphPadding: CGFloat { (size * 0.3).rounded() }

    func font(for kind: MarkdownBlock.Kind) -> NSFont {
        switch kind {
        case .heading(let level): headingFont(level)
        case .listItem, .orderedListItem, .quote, .paragraph, .rule: bodyFont
        case .codeBlock: codeFont
        case .table: tableFont
        }
    }
}

/// Markdown blocks as rendered: runs of prose share one text view, so a selection runs across
/// headings, paragraphs, lists and quotes, while each code block, table and rule keeps its own card.
enum MarkdownSegment: Identifiable {
    case prose([MarkdownBlock])
    case card(MarkdownBlock)

    var id: Int {
        switch self {
        case .prose(let blocks): blocks[0].id
        case .card(let block): block.id
        }
    }

    static func segments(of blocks: [MarkdownBlock]) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var prose: [MarkdownBlock] = []
        for block in blocks {
            if block.kind.isCard {
                if !prose.isEmpty { segments.append(.prose(prose)) }
                prose.removeAll()
                segments.append(.card(block))
            } else {
                prose.append(block)
            }
        }
        if !prose.isEmpty { segments.append(.prose(prose)) }
        return segments
    }
}

/// Remembers a value derived from Markdown text for each slot, such as one reply's prose run. Every
/// message in the transcript re-renders when any of it changes, as on each update of a streaming
/// reply, and parsing and styling every earlier reply again each time kept the main thread busy.
/// A slot holds only its latest text, so a streaming reply replaces its own entry rather than
/// filling the cache with each partial version and pushing finished replies out.
final class ReplyRenderCache<Value> {
    private final class Entry {
        let key: String
        let value: Value
        init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private let cache = NSCache<NSString, Entry>()

    init(countLimit: Int) {
        cache.countLimit = countLimit
    }

    func value(slot: String, key: String, make: () -> Value) -> Value {
        if let entry = cache.object(forKey: slot as NSString), entry.key == key { return entry.value }
        let value = make()
        cache.setObject(Entry(key: key, value: value), forKey: slot as NSString)
        return value
    }
}

/// Consecutive prose blocks laid out as one attributed string. Comments keep block-relative
/// offsets, so they survive a change in how blocks are grouped; this maps between those and
/// positions in the combined text.
struct MarkdownProseLayout {
    private struct PlacedBlock {
        let block: MarkdownBlock
        /// The block's own text, after any list marker.
        let contentRange: NSRange
        /// The whole line, list marker included.
        let lineRange: NSRange
    }

    let text: NSAttributedString
    private let placed: [PlacedBlock]
    private let identifierPrefix: String?

    var id: Int { placed[0].block.id }

    var endsWithParagraph: Bool {
        if case .paragraph = placed[placed.count - 1].block.kind { return true }
        return false
    }

    private static func isListItem(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .listItem, .orderedListItem: true
        case .heading, .quote, .paragraph, .codeBlock, .table, .rule: false
        }
    }

    /// Hosted runs, one entry per slot, which a streaming reply replaces as it grows.
    private static let slotCache = ReplyRenderCache<MarkdownProseLayout>(countLimit: 2000)
    /// Unhosted runs, such as a skill preview's, by their whole input.
    private static let contentCache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 200
        return cache
    }()

    private final class Box {
        let layout: MarkdownProseLayout
        init(_ layout: MarkdownProseLayout) { self.layout = layout }
    }

    /// The layout for these blocks, kept until their text, style or comments change: for `slot`
    /// when one is given, otherwise by its whole input.
    static func cached(
        slot: String?, blocks: [MarkdownBlock], style: MarkdownStyle, textColor: NSColor,
        identifierPrefix: String?, responseAnnotations: [ResponseAnnotationReference]
    ) -> MarkdownProseLayout {
        var key = "\(style.size)\u{1}\(textColor.description)\u{1}\(identifierPrefix ?? "")\u{2}"
        for block in blocks {
            let kind = switch block.kind {
            case .heading(let level): "h\(level)"
            case .listItem: "li"
            case .orderedListItem(let number): "ol\(number)"
            case .quote: "q"
            case .paragraph: "p"
            case .codeBlock, .table, .rule: "card"
            }
            key += "\(block.id)\u{1}\(kind)\u{1}\(block.text)\u{2}"
        }
        for annotation in responseAnnotations {
            key += "\u{3}\(annotation.text)\u{1}\(annotation.comment)"
        }
        let make = {
            MarkdownProseLayout(blocks: blocks, style: style, textColor: textColor,
                                identifierPrefix: identifierPrefix, responseAnnotations: responseAnnotations)
        }
        if let slot { return slotCache.value(slot: slot, key: key, make: make) }
        if let cached = contentCache.object(forKey: key as NSString) { return cached.layout }
        let layout = make()
        contentCache.setObject(Box(layout), forKey: key as NSString)
        return layout
    }

    init(
        blocks: [MarkdownBlock], style: MarkdownStyle, textColor: NSColor = .labelColor,
        identifierPrefix: String? = nil, responseAnnotations: [ResponseAnnotationReference] = []
    ) {
        self.identifierPrefix = identifierPrefix
        let text = NSMutableAttributedString()
        var placed: [PlacedBlock] = []
        for (index, block) in blocks.enumerated() {
            let lineStart = text.length
            let font = style.font(for: block.kind)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            let next = index + 1 < blocks.count ? blocks[index + 1].kind : nil
            switch block.kind {
            case .heading: paragraph.paragraphSpacing = style.headingSpacing
            case .listItem, .orderedListItem:
                paragraph.paragraphSpacing = next.map(Self.isListItem) == true ? style.listItemSpacing : style.paragraphSpacing
            case .quote, .paragraph, .codeBlock, .table, .rule:
                paragraph.paragraphSpacing = next.map(Self.isListItem) == true ? style.beforeListSpacing : style.paragraphSpacing
            }
            if case .quote = block.kind {
                paragraph.firstLineHeadIndent = style.quoteIndent
                paragraph.headIndent = style.quoteIndent
            }
            let marker: (text: String, font: NSFont)? = switch block.kind {
            case .listItem: ("•", style.bulletFont)
            case .orderedListItem(let number): ("\(number).", style.bodyFont)
            case .heading, .quote, .paragraph, .codeBlock, .table, .rule: nil
            }
            if let marker {
                // Wrapped lines align under the text, past the widest marker ("10.", "100.").
                let markerWidth = ceil((marker.text as NSString).size(withAttributes: [.font: marker.font]).width)
                let indent = max(style.listIndent, markerWidth + 10)
                paragraph.firstLineHeadIndent = (style.size * 0.375).rounded()
                paragraph.headIndent = indent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                text.append(NSAttributedString(string: marker.text + "\t", attributes: [
                    .font: marker.font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraph,
                ]))
            }
            let content = NSMutableAttributedString(
                attributedString: MarkdownInlineText.nsAttributedString(block.text, baseFont: font)
            )
            // Replaced here rather than by the text view, so offsets count the visible labels.
            SelectableAnnotationText.replaceResponseAnnotationMarkers(in: content, references: responseAnnotations)
            let contentRange = NSRange(location: text.length, length: content.length)
            let whole = NSRange(location: 0, length: content.length)
            content.enumerateAttribute(.font, in: whole) { value, range, _ in
                if value == nil { content.addAttribute(.font, value: font, range: range) }
            }
            content.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            let isQuote = if case .quote = block.kind { true } else { false }
            if isQuote {
                content.addAttribute(MarkdownQuoteStyle.attribute, value: MarkdownQuoteStyle.barColor, range: whole)
            }
            let color = isQuote ? NSColor.secondaryLabelColor : textColor
            content.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
                if value == nil { content.addAttribute(.foregroundColor, value: color, range: range) }
            }
            text.append(content)
            placed.append(PlacedBlock(
                block: block,
                contentRange: contentRange,
                lineRange: NSRange(location: lineStart, length: text.length - lineStart)
            ))
            if index < blocks.count - 1 {
                text.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
            }
        }
        self.text = text
        self.placed = placed
    }

    /// The comment's range in `text`, or nil when it belongs to blocks outside this run.
    func range(of annotation: ConversationAnnotation) -> NSRange? {
        range(of: annotation.source)
    }

    func range(of source: ConversationTextSource) -> NSRange? {
        guard let start = placed.first(where: { $0.block.id == source.blockID })?.contentRange,
              let end = placed.first(where: { $0.block.id == source.endBlockID })?.contentRange,
              (0...start.length).contains(source.startOffset),
              (0...end.length).contains(source.endOffset) else { return nil }
        let location = start.location + source.startOffset
        let endLocation = end.location + source.endOffset
        guard endLocation > location else { return nil }
        return NSRange(location: location, length: endLocation - location)
    }

    /// A selection in `text` as block-relative positions, with list markers and line breaks at
    /// its ends left out; nil when it covers no block text.
    func blockPositions(of range: NSRange) -> (blockID: Int, startOffset: Int, endBlockID: Int, endOffset: Int)? {
        guard let start = placed.first(where: { NSMaxRange($0.contentRange) > range.location }),
              let end = placed.last(where: { $0.contentRange.location < NSMaxRange(range) }) else { return nil }
        let startLocation = max(range.location, start.contentRange.location)
        let endLocation = min(NSMaxRange(range), NSMaxRange(end.contentRange))
        guard endLocation > startLocation else { return nil }
        return (start.block.id, startLocation - start.contentRange.location,
                end.block.id, endLocation - end.contentRange.location)
    }

    /// Each block as its own accessibility element, identified `<prefix>-<kind>-<line>` when the
    /// atom has an identifier prefix.
    var accessibilityBlocks: [CommentTrackingTextView.AccessibilityBlock] {
        placed.map { placed in
            let content = (text.string as NSString).substring(with: placed.contentRange)
            let (kind, label): (String, String) = switch placed.block.kind {
            case .heading: ("heading", content)
            case .listItem: ("list-item", content)
            case .orderedListItem(let number): ("ordered-list-item", "\(number). " + content)
            case .quote: ("quote", content)
            case .paragraph, .codeBlock, .table, .rule: ("paragraph", content)
            }
            return CommentTrackingTextView.AccessibilityBlock(
                identifier: identifierPrefix.map { "\($0)-\(kind)-\(placed.block.id)" } ?? "",
                label: label, range: placed.lineRange
            )
        }
    }
}

/// What a native composite adds to a Markdown atom's prose, which plugins never set: the
/// transcript's comments, side chats and the selection that opens them. Each callback is given
/// the prose run it concerns, whose layout maps block-relative comment positions into its text.
struct MarkdownTextHost {
    /// Keys the parse and each prose run's layout, so re-rendering a message reuses them and a
    /// streaming reply replaces its own entries: the message ID.
    let slot: String
    /// Starts the accessibility identifiers of the prose and cards in place of the atom's testID.
    var identifierPrefix: String? = nil
    /// Opens every link as AppKit does; unset, only web and mail links open, as in plugin text.
    var opensAnyLink = false
    /// Reports each block as a group that only locates its part of the text, rather than as a
    /// static text read by its label: a reply's blocks are anchors for comments, and its text is
    /// read whole from the text view.
    var blocksAreGroups = false
    var responseAnnotations: [ResponseAnnotationReference] = []
    /// Commented ranges of a run's text, rendered orange.
    var highlightedRanges: (MarkdownProseLayout) -> [NSRange] = { _ in [] }
    /// Ranges of a run's text a side chat discusses, rendered purple.
    var chatRanges: (MarkdownProseLayout) -> [NSRange] = { _ in [] }
    var onHighlightClick: ((MarkdownProseLayout, NSRange, CGRect) -> Void)? = nil
    var onSelection: (MarkdownProseLayout, NSRange, String, CGRect) -> Void = { _, _, _, _ in }
    /// Drawn over a run's text, such as the actions for its selection.
    var overlay: (MarkdownProseLayout) -> AnyView = { _ in AnyView(EmptyView()) }
}

/// One prose run of a Markdown atom: its blocks in a single selectable text view.
struct MarkdownProseText: View {
    let layout: MarkdownProseLayout
    let style: MarkdownStyle
    let textColor: NSColor
    let selectable: Bool
    let identifierPrefix: String?
    /// The atom's whole Markdown, which copying a fully selected run of a hosted atom copies, as
    /// copying a whole reply's text always has; other atoms copy the text as shown.
    let markdown: String
    let host: MarkdownTextHost?

    var body: some View {
        let layout = layout
        SelectableAnnotationText(
            text: layout.text.string,
            highlightedRanges: host?.highlightedRanges(layout) ?? [],
            chatRanges: host?.chatRanges(layout) ?? [],
            onHighlightClick: host?.onHighlightClick.map { click in { range, bounds in click(layout, range, bounds) } },
            responseAnnotations: host?.responseAnnotations ?? [],
            responseCommentSourcePrefix: host.map { "\($0.slot):\(layout.id)" } ?? "",
            isAssistantText: true,
            textColor: textColor,
            onSelection: { range, text, bounds in host?.onSelection(layout, range, text, bounds) },
            formattedText: layout.text,
            font: style.bodyFont,
            wholeMessageText: host == nil ? nil : markdown,
            accessibilityBlocks: layout.accessibilityBlocks,
            allowsSelection: selectable,
            restrictsLinks: host?.opensAnyLink != true,
            blocksAreText: host?.blocksAreGroups != true,
            accessibilityIdentifier: identifierPrefix.map { "\($0)-prose-\(layout.id)" }
        )
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) { host?.overlay(layout) }
            .padding(.bottom, layout.endsWithParagraph ? style.trailingParagraphPadding : 0)
    }
}
