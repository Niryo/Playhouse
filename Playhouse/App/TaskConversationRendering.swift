import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

final class TextHeightMeasurer {
    private var heights: [CGFloat: CGFloat] = [:]
    /// The text last measured, as it was given.
    private(set) var text: NSAttributedString?

    /// Records the text the view now shows, which forgets every height measured for the previous text.
    func setText(_ text: NSAttributedString) {
        self.text = text.copy() as? NSAttributedString
        heights.removeAll()
    }

    func height(forWidth width: CGFloat, in view: NSTextView) -> CGFloat {
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

extension NSTextStorage {
    /// Changes the storage from showing `previous` to showing `text`, keeping the paragraphs both
    /// share at the start. A streaming reply grows at its end, and a layout manager re-lays out
    /// only from the first edited character, so each update costs the new text rather than the
    /// whole reply. The two are compared as given because the storage itself never equals what
    /// was set: it substitutes fonts, for emoji for example.
    func replaceChangedTail(with text: NSAttributedString, previous: NSAttributedString?) {
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

/// Inline `code` in conversation text: a tinted run on a rounded pill, as code editors show it.
enum InlineCodeStyle {
    /// Marks inline code runs; its value is the pill's fill color.
    static let attribute = NSAttributedString.Key("PlayhouseInlineCode")
    /// Room kept clear on each side of a run for its pill.
    static let horizontalPadding: CGFloat = 4

    static let textColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.79, blue: 0.56, alpha: 1)
            : NSColor(srgbRed: 0.66, green: 0.22, blue: 0.11, alpha: 1)
    }
    static let backgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.06)
    }

    /// Styles `range` of `text` as inline code. Kerning, not added characters, makes room for the
    /// pill, so comment offsets into the text are unchanged.
    static func apply(to text: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0 else { return }
        text.addAttributes([.foregroundColor: textColor, attribute: backgroundColor], range: range)
        text.addAttribute(.kern, value: horizontalPadding, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        if range.location > 0 {
            text.addAttribute(.kern, value: horizontalPadding, range: NSRange(location: range.location - 1, length: 1))
        }
    }
}

/// Draws each inline code run's pill behind its glyphs, one per line the run spans.
final class InlineCodeLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(InlineCodeStyle.attribute, in: characters) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
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

@Observable
final class ComposerDraftModel {
    var text = ""
    /// Bumped to put the keyboard back in the composer, such as after the Skills page closes.
    var focusRequest = 0
    /// The editor's selected range, in UTF-16 offsets, for the composer's plugins.
    var selection = NSRange(location: 0, length: 0)
    /// The composer text that needs no save: the draft last saved or restored, or the empty
    /// composer a send, steer, or queue left behind.
    @ObservationIgnored var settledText = ""
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
    /// The latest pending-comment save; the next one waits for it.
    @ObservationIgnored var annotationSaveTask: Task<Void, Never>?
}

/// Evaluates `content` in its own body, so Observation attributes the composer's draft reads to
/// this view rather than to the enclosing `TaskConversationView`.
struct ComposerDraftScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

/// The transcript's sizes for each block: larger than the app's body text, for reading replies.
extension MarkdownBlock {
    var font: NSFont {
        switch kind {
        case .heading(let level): NSFont.systemFont(ofSize: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold)
        case .listItem, .orderedListItem, .quote, .paragraph, .rule: NSFont.systemFont(ofSize: 16)
        case .codeBlock: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        case .table: NSFont.systemFont(ofSize: 14)
        }
    }
}

/// A reply's Markdown blocks as rendered: runs of prose share one text view, while each code
/// block and table keeps its own card.
enum AssistantMarkdownSegment: Identifiable {
    case prose([MarkdownBlock])
    case card(MarkdownBlock)

    var id: Int {
        switch self {
        case .prose(let blocks): blocks[0].id
        case .card(let block): block.id
        }
    }

    static func segments(of blocks: [MarkdownBlock]) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
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

/// Remembers a value derived from reply text for each slot, such as one reply's prose run. Every
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
struct AssistantProseLayout {
    private struct PlacedBlock {
        let block: MarkdownBlock
        /// The block's own text, after any list marker.
        let contentRange: NSRange
        /// The whole line, list marker included.
        let lineRange: NSRange
    }

    let text: NSAttributedString
    private let placed: [PlacedBlock]

    var id: Int { placed[0].block.id }

    var endsWithParagraph: Bool {
        if case .paragraph = placed[placed.count - 1].block.kind { return true }
        return false
    }

    /// The text's own size and color: the reply's bullets read as part of the text, like an
    /// editor's rendered Markdown, rather than as faint annotations beside it.
    static let markerFont = NSFont.systemFont(ofSize: 16)
    static let bulletFont = NSFont.systemFont(ofSize: 16, weight: .black)
    /// Indent shared by every item, so bullets and numbers line up down a list.
    private static let listIndent: CGFloat = 26
    /// A quote's indent; it reads as a quote by its dimmed color and indent alone.
    private static let quoteIndent: CGFloat = 16

    private static func isListItem(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .listItem, .orderedListItem: true
        case .heading, .quote, .paragraph, .codeBlock, .table, .rule: false
        }
    }

    private static let cache = ReplyRenderCache<AssistantProseLayout>(countLimit: 2000)

    /// The layout for these blocks, kept for `slot` until their text or comments change.
    static func cached(slot: String, blocks: [MarkdownBlock], responseAnnotations: [ResponseAnnotationReference]) -> AssistantProseLayout {
        var key = ""
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
        return cache.value(slot: slot, key: key) { AssistantProseLayout(blocks: blocks, responseAnnotations: responseAnnotations) }
    }

    init(blocks: [MarkdownBlock], responseAnnotations: [ResponseAnnotationReference]) {
        let text = NSMutableAttributedString()
        var placed: [PlacedBlock] = []
        for (index, block) in blocks.enumerated() {
            let lineStart = text.length
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            // A list's items sit close together; paragraphs and whole lists keep more room.
            let next = index + 1 < blocks.count ? blocks[index + 1].kind : nil
            switch block.kind {
            case .heading: style.paragraphSpacing = 8
            case .listItem, .orderedListItem:
                style.paragraphSpacing = next.map(Self.isListItem) == true ? 6 : 14
            case .quote, .paragraph, .codeBlock, .table, .rule:
                style.paragraphSpacing = next.map(Self.isListItem) == true ? 10 : 14
            }
            if case .quote = block.kind {
                style.firstLineHeadIndent = Self.quoteIndent
                style.headIndent = Self.quoteIndent
            }
            let marker: (text: String, font: NSFont)? = switch block.kind {
            case .listItem: ("•", Self.bulletFont)
            case .orderedListItem(let number): ("\(number).", Self.markerFont)
            case .heading, .quote, .paragraph, .codeBlock, .table, .rule: nil
            }
            if let marker {
                // Wrapped lines align under the text, past the widest marker ("10.", "100.").
                let markerWidth = ceil((marker.text as NSString).size(withAttributes: [.font: marker.font]).width)
                let indent = max(Self.listIndent, markerWidth + 10)
                style.firstLineHeadIndent = 6
                style.headIndent = indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                text.append(NSAttributedString(string: marker.text + "\t", attributes: [
                    .font: marker.font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                ]))
            }
            let content = NSMutableAttributedString(
                attributedString: MarkdownInlineText.nsAttributedString(block.text, baseFont: block.font)
            )
            // Replaced here rather than by the text view, so offsets count the visible labels.
            SelectableAnnotationText.replaceResponseAnnotationMarkers(in: content, references: responseAnnotations)
            let contentRange = NSRange(location: text.length, length: content.length)
            content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { font, range, _ in
                if font == nil { content.addAttribute(.font, value: block.font, range: range) }
            }
            content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
            if case .quote = block.kind {
                content.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: content.length)) { color, range, _ in
                    if color == nil { content.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range) }
                }
            }
            text.append(content)
            placed.append(PlacedBlock(
                block: block,
                contentRange: contentRange,
                lineRange: NSRange(location: lineStart, length: text.length - lineStart)
            ))
            if index < blocks.count - 1 {
                text.append(NSAttributedString(string: "\n", attributes: [.font: block.font, .paragraphStyle: style]))
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

    var accessibilityBlocks: [CommentTrackingTextView.AccessibilityBlock] {
        placed.map { placed in
            let content = (text.string as NSString).substring(with: placed.contentRange)
            let (identifier, label): (String, String) = switch placed.block.kind {
            case .heading: ("assistant-markdown-heading-\(placed.block.id)", content)
            case .listItem: ("assistant-markdown-list-item-\(placed.block.id)", content)
            case .orderedListItem(let number): ("assistant-markdown-ordered-list-item-\(placed.block.id)", "\(number). " + content)
            case .quote: ("assistant-markdown-quote-\(placed.block.id)", content)
            case .paragraph, .codeBlock, .table, .rule: ("assistant-markdown-paragraph-\(placed.block.id)", content)
            }
            return CommentTrackingTextView.AccessibilityBlock(identifier: identifier, label: label, range: placed.lineRange)
        }
    }
}

struct CodeBlockCardView: View {
    let blockID: Int
    let code: String
    let language: String?
    let font: NSFont
    /// Starts the card's accessibility identifiers (`<prefix>-…-<blockID>`); nil leaves them unset.
    /// A Markdown atom passes its own testID, so its cards never match the transcript's.
    var identifierPrefix: String? = "assistant-markdown"

    @State private var didCopy = false
    @State private var copyFeedbackToken = UUID()

    private var languageDisplayName: String {
        guard let language, !language.isEmpty else { return "Code" }
        return language.prefix(1).uppercased() + language.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                Text(languageDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .cardIdentifier(identifierPrefix.map { "\($0)-code-block-language-\(blockID)" })
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    let token = UUID()
                    copyFeedbackToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copyFeedbackToken == token { didCopy = false }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("Copy code")
                .accessibilityLabel("Copy code")
                .cardIdentifier(identifierPrefix.map { "\($0)-code-block-copy-\(blockID)" })
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.15)

            CodeBlockTextView(attributedText: CodeSyntaxHighlighter.highlight(code, language: language, font: font))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Keeps the language label and copy action identifiable inside the identified card.
        .accessibilityElement(children: .contain)
    }
}

/// Tracks the pointer over one reply, so hovering it redraws only that reply and not the transcript.
/// An AppKit tracking area, not `onHover`: pressing the Copy message button ended SwiftUI's hover,
/// which hid the button before the press could complete.
struct AssistantReplyHoverScope<Content: View>: View {
    @ViewBuilder let content: (_ isHovering: Bool) -> Content
    @State private var isHovering = false

    var body: some View {
        content(isHovering)
            .background {
                OverlayHoverTracker { hovering in
                    if isHovering != hovering { isHovering = hovering }
                }
                .accessibilityHidden(true)
            }
    }
}

/// Copies a whole reply as the Markdown the agent wrote, tables and code fences included, which a
/// text selection can't do because tables and code blocks are separate views from the prose.
/// It shows while the pointer is over the reply, and stays while it confirms the copy.
struct CopyMessageButton: View {
    let markdown: String
    let messageID: String
    let isRevealed: Bool

    @State private var didCopy = false
    @State private var copyFeedbackToken = UUID()

    var body: some View {
        let isShown = isRevealed || didCopy
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
            didCopy = true
            let token = UUID()
            copyFeedbackToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copyFeedbackToken == token { didCopy = false }
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .nativeHelp("Copy message")
        .accessibilityLabel("Copy message")
        .accessibilityValue(didCopy ? "Copied" : "")
        .accessibilityIdentifier("assistant-copy-message-\(messageID)")
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }
}

struct CodeBlockTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeCoordinator() -> TextHeightMeasurer {
        TextHeightMeasurer()
    }

    func makeNSView(context: Context) -> NSTextView {
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

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.textStorage?.string != attributedText.string else { return }
        // The measurer holds the text the view shows, until it takes the new one below.
        view.textStorage?.replaceChangedTail(with: attributedText, previous: context.coordinator.text)
        context.coordinator.setText(attributedText)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 500)
        let contentHeight = context.coordinator.height(forWidth: width, in: nsView)
        return CGSize(width: width, height: ceil(contentHeight) + 2)
    }
}

/// A deterministic "Recalling <page title>" line for a standalone chat page the agent loaded into
/// its context with `chat page read`. The title comes from the page archive, not the agent.
struct ChatPageRecallRow: View {
    let activityID: String
    let pageID: String

    @State private var title: String?

    var body: some View {
        let label = "Recalling \(title ?? "an earlier page")"
        AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(fillWidth: true, paddingY: 2)) {
            AtomIcon(props: IconProps(name: "clock.arrow.circlepath", size: 12, color: "secondary"))
            AtomText(props: TextProps(text: label, size: 14, color: "secondary", lineLimit: 1))
            AtomSpacer(props: SpacerProps(minLength: 0))
        }
        .accessibilitySummary(label, id: "conversation-chat-page-recall-\(activityID)")
        .task(id: pageID) {
            let directory = ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            title = (try? StandaloneChatManager(dataDirectory: directory).page(id: pageID))?.title
        }
    }
}

/// Keeps the transcript's settled rows, those before the newest turn, cheap at any history length.
/// Only the messages near the viewport render as real views; every other settled message is a blank
/// box exactly as tall as it measured when it was last shown, so the content keeps its size as rows
/// come and go and nothing above the reader moves. A message not yet measured renders for real
/// until it is. SwiftUI's lazy stack was tried first: it guesses the heights of rows it has not
/// realized, its corrections moved the content under the reader, and following the bottom while it
/// corrected never let layout settle.
/// that side chat, which it continues.

struct AnnotationSelection: Identifiable {
    let id = UUID()
    let messageID: String
    /// The text view showing the selection, which anchors its side chat bubble: the first block
    /// of an assistant prose run, or 0 for a user message.
    let anchorID: Int
    let blockID: Int
    let startOffset: Int
    let endBlockID: Int
    let endOffset: Int
    let text: String
    let bounds: CGRect
    /// Set when clicking commented or side-chatted text reopens its bubble: the comment
    /// and side chat it shows, which a new selection has neither of.
    var annotationID: UUID? = nil
    var sideChatID: String? = nil

    var isReopened: Bool { annotationID != nil || sideChatID != nil }

    var source: ConversationTextSource {
        ConversationTextSource(messageID: messageID, blockID: blockID, startOffset: startOffset, endBlockID: endBlockID, endOffset: endOffset)
    }
}
