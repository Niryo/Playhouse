import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Answers `sizeThatFits` for `CodeBlockTextView` and `SelectableAnnotationText`. One layout pass
/// proposes several widths, so heights are kept per width until the text changes. The height is
/// measured with the text view's own layout manager: a separate copy of the text laid out the
/// whole reply a second time at every new width, as on each frame of a chat resize, before the
/// view laid out its own copy again to draw it. Measured this way, the view's frame then takes
/// the width its text was just laid out for, and drawing reuses that layout.
private final class TextHeightMeasurer {
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

private extension NSTextStorage {
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
private enum InlineCodeStyle {
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
private final class InlineCodeLayoutManager: NSLayoutManager {
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
private final class ComposerDraftModel {
    var text = ""
    /// Bumped to put the keyboard back in the composer, such as after the Skills page closes.
    var focusRequest = 0
    /// The composer text that needs no save: the draft last saved or restored, or the empty
    /// composer a send, steer, or queue left behind.
    @ObservationIgnored var settledText = ""
    @ObservationIgnored var autosaveTask: Task<Void, Never>?
}

/// Evaluates `content` in its own body, so Observation attributes the composer's draft reads to
/// this view rather than to the enclosing `TaskConversationView`.
private struct ComposerDraftScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { content() }
}

private enum MarkdownTableColumnAlignment {
    case leading, center, trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct AssistantMarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case listItem
        case orderedListItem(number: Int)
        case codeBlock(language: String?)
        case table(headers: [String], alignments: [MarkdownTableColumnAlignment], rows: [[String]])
        case paragraph
    }

    let id: Int
    let kind: Kind
    let text: String

    var font: NSFont {
        switch kind {
        case .heading(let level): NSFont.systemFont(ofSize: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold)
        case .listItem, .orderedListItem, .paragraph: NSFont.systemFont(ofSize: 16)
        case .codeBlock: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        case .table: NSFont.systemFont(ofSize: 14)
        }
    }
}

/// A reply's Markdown blocks as rendered: runs of prose share one text view, while each code
/// block and table keeps its own card.
private enum AssistantMarkdownSegment: Identifiable {
    case prose([AssistantMarkdownBlock])
    case card(AssistantMarkdownBlock)

    var id: Int {
        switch self {
        case .prose(let blocks): blocks[0].id
        case .card(let block): block.id
        }
    }

    static func segments(of blocks: [AssistantMarkdownBlock]) -> [AssistantMarkdownSegment] {
        var segments: [AssistantMarkdownSegment] = []
        var prose: [AssistantMarkdownBlock] = []
        for block in blocks {
            switch block.kind {
            case .codeBlock, .table:
                if !prose.isEmpty { segments.append(.prose(prose)) }
                prose.removeAll()
                segments.append(.card(block))
            case .heading, .listItem, .orderedListItem, .paragraph:
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
private final class ReplyRenderCache<Value> {
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
private struct AssistantProseLayout {
    private struct PlacedBlock {
        let block: AssistantMarkdownBlock
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

    private static func isListItem(_ kind: AssistantMarkdownBlock.Kind) -> Bool {
        switch kind {
        case .listItem, .orderedListItem: true
        case .heading, .paragraph, .codeBlock, .table: false
        }
    }

    private static let cache = ReplyRenderCache<AssistantProseLayout>(countLimit: 2000)

    /// The layout for these blocks, kept for `slot` until their text or comments change.
    static func cached(slot: String, blocks: [AssistantMarkdownBlock], responseAnnotations: [ResponseAnnotationReference]) -> AssistantProseLayout {
        var key = ""
        for block in blocks {
            let kind = switch block.kind {
            case .heading(let level): "h\(level)"
            case .listItem: "li"
            case .orderedListItem(let number): "ol\(number)"
            case .paragraph: "p"
            case .codeBlock, .table: "card"
            }
            key += "\(block.id)\u{1}\(kind)\u{1}\(block.text)\u{2}"
        }
        for annotation in responseAnnotations {
            key += "\u{3}\(annotation.text)\u{1}\(annotation.comment)"
        }
        return cache.value(slot: slot, key: key) { AssistantProseLayout(blocks: blocks, responseAnnotations: responseAnnotations) }
    }

    init(blocks: [AssistantMarkdownBlock], responseAnnotations: [ResponseAnnotationReference]) {
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
            case .paragraph, .codeBlock, .table:
                style.paragraphSpacing = next.map(Self.isListItem) == true ? 10 : 14
            }
            let marker: (text: String, font: NSFont)? = switch block.kind {
            case .listItem: ("•", Self.bulletFont)
            case .orderedListItem(let number): ("\(number).", Self.markerFont)
            case .heading, .paragraph, .codeBlock, .table: nil
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
                attributedString: TaskConversationView.markdownNSAttributedString(block.text, baseFont: block.font)
            )
            // Replaced here rather than by the text view, so offsets count the visible labels.
            SelectableAnnotationText.replaceResponseAnnotationMarkers(in: content, references: responseAnnotations)
            let contentRange = NSRange(location: text.length, length: content.length)
            content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { font, range, _ in
                if font == nil { content.addAttribute(.font, value: block.font, range: range) }
            }
            content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
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
        guard let start = placed.first(where: { $0.block.id == annotation.blockID })?.contentRange,
              let end = placed.first(where: { $0.block.id == annotation.endBlockID })?.contentRange,
              (0...start.length).contains(annotation.startOffset),
              (0...end.length).contains(annotation.endOffset) else { return nil }
        let location = start.location + annotation.startOffset
        let endLocation = end.location + annotation.endOffset
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
            case .paragraph, .codeBlock, .table: ("assistant-markdown-paragraph-\(placed.block.id)", content)
            }
            return CommentTrackingTextView.AccessibilityBlock(identifier: identifier, label: label, range: placed.lineRange)
        }
    }
}

private struct CodeBlockCardView: View {
    let blockID: Int
    let code: String
    let language: String?
    let font: NSFont

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
                    .accessibilityIdentifier("assistant-markdown-code-block-language-\(blockID)")
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
                .accessibilityIdentifier("assistant-markdown-code-block-copy-\(blockID)")
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

private struct CodeBlockTextView: NSViewRepresentable {
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
private struct ChatPageRecallRow: View {
    let activityID: String
    let pageID: String

    @State private var title: String?

    var body: some View {
        let label = "Recalling \(title ?? "an earlier page")"
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("conversation-chat-page-recall-\(activityID)")
        .task(id: pageID) {
            let directory = ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            title = (try? StandaloneChatManager(dataDirectory: directory).page(id: pageID))?.title
        }
    }
}

/// One tool call in the conversation timeline: the tool's name and what the call was for, then
/// what it was given (IN) and what it returned (OUT), clipped to a few lines until expanded.
private struct ToolCallTimelineRow: View {
    let activity: ConversationActivity

    @State private var isExpanded = false

    private static let collapsedLineLimit = 3

    private var name: String {
        if activity.toolKind == "mcp" { return activity.title }
        return activity.tool ?? activity.title
    }

    private var summary: String? {
        if let summary = activity.summary, !summary.isEmpty { return summary }
        guard activity.input == nil else { return nil }
        return activity.detail.split(separator: "\n").first.map(String.init)
    }

    private var output: String? {
        guard let output = activity.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else { return nil }
        return output
    }

    private var statusColor: Color {
        switch activity.status.lowercased() {
        case "completed": .green
        case "failed": .red
        case "interrupted", "stopped": .orange
        default: .accentColor
        }
    }

    /// Whether either block holds more than its collapsed lines show.
    private var canExpand: Bool {
        [activity.input, output].compactMap { $0 }.contains { text in
            text.count > 240 || text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLineLimit
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WorkspaceTheme.conversationText)
                        .accessibilityIdentifier("conversation-tool-call-name-\(activity.id)")
                    if let summary {
                        Text(summary)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("conversation-tool-call-summary-\(activity.id)")
                    }
                    Spacer(minLength: 0)
                    if canExpand {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .buttonHoverPointer()
                        .nativeHelp(isExpanded ? "Show less" : "Show full input and output")
                        .accessibilityLabel(isExpanded ? "Show less" : "Show full input and output")
                        .accessibilityIdentifier("conversation-tool-call-toggle-\(activity.id)")
                    }
                }
                if activity.input != nil || output != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        if let input = activity.input {
                            ioRow(label: "IN", text: input, identifier: "conversation-tool-call-input-\(activity.id)")
                        }
                        if activity.input != nil, output != nil {
                            Divider().opacity(0.35)
                        }
                        if let output {
                            ioRow(label: "OUT", text: output, identifier: "conversation-tool-call-output-\(activity.id)")
                        }
                    }
                    .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) \(activity.statusLabel)")
        .accessibilityIdentifier("conversation-tool-call-\(activity.id)")
    }

    private func ioRow(label: String, text: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(WorkspaceTheme.conversationText)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(label) \(text)")
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Renders a parsed Markdown pipe table as a bordered grid instead of its raw `|`/`---` source,
/// following `CodeBlockCardView`'s card styling so tables visually match other assistant blocks.
private struct TableBlockView: View {
    let blockID: Int
    let headers: [String]
    let alignments: [MarkdownTableColumnAlignment]
    let rows: [[String]]
    let font: NSFont

    private func alignment(forColumn column: Int) -> MarkdownTableColumnAlignment {
        column < alignments.count ? alignments[column] : .leading
    }

    /// Maps a column's text alignment to the matching frame alignment, so the cell's text and its
    /// containing frame agree on where content sits (`.leading`/`.trailing` text alignment alone
    /// has no effect inside a frame that doesn't also pin content to that same edge).
    private func frameAlignment(forColumn column: Int) -> Alignment {
        switch alignment(forColumn: column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// The weight is applied here rather than by the caller because `cellText` already sets a
    /// `.font`, and the innermost `.font` modifier is the one SwiftUI honors — a `.semibold` font
    /// applied by the caller outside this view would be silently discarded.
    private func cellText(_ cell: String, weight: Font.Weight = .regular) -> some View {
        let formatted = TaskConversationView.markdownNSAttributedString(cell, baseFont: font)
        return Text((try? AttributedString(formatted, including: \.appKit)) ?? AttributedString(cell))
            .font(.system(size: font.pointSize, weight: weight))
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { column, header in
                    cellText(header, weight: .semibold)
                        .multilineTextAlignment(alignment(forColumn: column).textAlignment)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(forColumn: column))
                        .padding(8)
                        .accessibilityIdentifier("assistant-markdown-table-\(blockID)-header-\(column)")
                }
            }
            .background(WorkspaceTheme.inputBackground)

            Divider().opacity(0.3)

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        cellText(cell)
                            .multilineTextAlignment(alignment(forColumn: column).textAlignment)
                            .frame(maxWidth: .infinity, alignment: frameAlignment(forColumn: column))
                            .padding(8)
                            .accessibilityIdentifier("assistant-markdown-table-\(blockID)-cell-\(rowIndex)-\(column)")
                    }
                }
                if rowIndex < rows.count - 1 {
                    Divider().opacity(0.12)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant-markdown-table-\(blockID)")
    }
}

private struct ConversationAnnotation: Identifiable, Codable {
    let id: UUID
    let messageID: String
    /// The comment starts `startOffset` into this block's text and ends `endOffset` into
    /// `endBlockID`'s, so a comment on prose blocks rendered together can span several of them.
    let blockID: Int
    let startOffset: Int
    let endBlockID: Int
    let endOffset: Int
    let text: String
    let comment: String
    var pending = true
}

private struct ResponseAnnotationReference {
    let text: String
    let comment: String
}

private struct ResponseCommentHoverCard: View {
    let selectedText: String
    let comment: String
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Highlighted text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(selectedText)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("response-comment-highlighted-text")
                    .accessibilityLabel(selectedText)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Comment")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(comment)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("response-comment-content")
                    .accessibilityLabel(comment)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.easeIn(duration: 0.12)) {
                isVisible = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("response-comment-hover-card")
        .accessibilityLabel("Highlighted text: \(selectedText). Comment: \(comment)")
    }
}

/// A text view whose height `TextHeightMeasurer` measures with its own layout manager. Measuring
/// sets the text container to each width SwiftUI asks about, and a width answered from the
/// measurer's cache leaves the container where the last uncached question put it, so the
/// container is matched to the view's own width again before the text is drawn.
private class MeasuredTextView: NSTextView {
    override func viewWillDraw() {
        if let textContainer {
            let width = bounds.width - 2 * textContainerInset.width
            if textContainer.size.width != width {
                textContainer.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            }
        }
        super.viewWillDraw()
    }
}

private final class CommentTrackingTextView: MeasuredTextView {
    var hoverTrackingOwner: AnyObject?
    /// The whole message this block belongs to; copying a fully selected block copies it all.
    var wholeMessageText: String?
    /// The prose blocks laid out in this view, exposed as their own accessibility elements so
    /// each heading, paragraph, and list item stays identifiable though they share one view.
    var accessibilityBlocks: [AccessibilityBlock] = [] {
        didSet { if accessibilityBlocks != oldValue { blockElements = nil } }
    }
    /// Accessibility clients hold on to children between queries, so the elements live as long
    /// as the blocks they describe.
    private var blockElements: [BlockAccessibilityElement]?
    private var hoverTrackingArea: NSTrackingArea?

    struct AccessibilityBlock: Equatable {
        let identifier: String
        let label: String
        let range: NSRange
    }

    private final class BlockAccessibilityElement: NSAccessibilityElement {
        weak var textView: NSTextView?
        let range: NSRange

        init(block: AccessibilityBlock, textView: NSTextView) {
            self.textView = textView
            range = block.range
            super.init()
            setAccessibilityRole(.group)
            setAccessibilityLabel(block.label)
            setAccessibilityIdentifier(block.identifier)
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

    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        guard !accessibilityBlocks.isEmpty else { return children }
        let elements = blockElements ?? accessibilityBlocks.map { BlockAccessibilityElement(block: $0, textView: self) }
        blockElements = elements
        return children + elements
    }

    override func copy(_ sender: Any?) {
        guard let wholeMessageText, selectedRange() == NSRange(location: 0, length: string.utf16.count) else {
            super.copy(sender)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(wholeMessageText, forType: .string)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
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

private struct AnnotationSelection: Identifiable {
    let id = UUID()
    let messageID: String
    /// The text view showing the selection, which places its Add comment hint: the first block
    /// of an assistant prose run, or 0 for a user message.
    let anchorID: Int
    let blockID: Int
    let startOffset: Int
    let endBlockID: Int
    let endOffset: Int
    let text: String
    let bounds: CGRect
}

struct TaskConversationView: View {
    private struct PendingImage: Identifiable {
        let id = UUID()
        let dataURL: String
        let image: NSImage
    }
    private struct RepositoryBadgeEditID: Identifiable, Equatable {
        let path: String
        var id: String { path }
    }

    /// An outlined pencil with a wide body, drawn on a 24-point grid. The SF Symbol pencil
    /// stays a thin stick at small sizes, which does not read as an edit button.
    private struct EditPencilShape: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
            }
            var path = Path()
            path.move(to: point(4, 16.5))
            path.addLine(to: point(15.5, 5))
            path.addLine(to: point(19, 8.5))
            path.addLine(to: point(7.5, 20))
            path.addLine(to: point(3.5, 20.5))
            path.closeSubpath()
            path.move(to: point(13, 7.5))
            path.addLine(to: point(16.5, 11))
            return path
        }
    }

    private struct ChangeRepositoryGroup: Identifiable {
        let repository: String
        let entries: [WorkspaceChangeEntry]
        var id: String { repository }
    }

    private struct GoalAchievementTimelineEntry: Codable, Identifiable, Equatable {
        let id: String
        let summary: String
        let afterMessageID: String

        static let beforeFirstMessageID = "__before_first_message__"
    }

    @Environment(\.modelContext) private var modelContext
    /// Read without observing; `runtimeSlice` re-renders this view for its own task's changes.
    @Environment(\.conversationRuntimeModel) private var runtimeModel
    @StateObject private var runtimeSlice = ConversationRuntimeSliceObserver()
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""

    let task: any ConversationSubject
    var isNewTask = false
    var isReadOnly = false
    var conflictResolutionRequested = false
    var onConflictResolutionChecked: (Bool) -> Void = { _ in }
    /// The prompt a task opened from the Skills page's Fix with Agent sends on arrival.
    var skillFixPrompt: String? = nil
    /// Shows another task's conversation, sending it the prompt once it opens.
    var onOpenTask: (UUID, String) -> Void = { _, _ in }
    let onBack: () -> Void

    /// The draft lives in an observable model, so a keystroke re-renders only views that read it
    /// (the composer inside `ComposerDraftScope`), not the whole transcript. Read `draft` (or
    /// `isSendDisabled`) during body evaluation only inside that scope; handlers may read it freely.
    @State private var composerDraft = ComposerDraftModel()
    private var draft: String {
        get { composerDraft.text }
        nonmutating set { composerDraft.text = newValue }
    }
    /// Steers this window has shown but the turn's stream hasn't echoed yet, and
    /// the reverse. The turn streams every steer, including this window's own,
    /// but a reopened window no longer reads that stream, so it shows its own.
    @State private var unechoedLocalSteers: [String] = []
    @State private var unconfirmedStreamedSteers: [String] = []
    /// This window's own sends whose turn stream it is reading right now.
    @State private var followedTurnStreams = 0
    /// A history reload for another caller's turn is running, and whether a
    /// newer revision arrived since it started.
    @State private var isFollowingHistory = false
    @State private var followedHistoryIsStale = false
    @State private var composerHeight: CGFloat = 28
    private var draftAutosaveTask: Task<Void, Never>? {
        get { composerDraft.autosaveTask }
        nonmutating set { composerDraft.autosaveTask = newValue }
    }
    private var isDraftUnsaved: Bool { draft != composerDraft.settledText }
    @State private var pendingImages: [PendingImage] = []
    /// The task's skill gallery covers the conversation, which keeps its draft underneath.
    @State private var isShowingSkills = false
    @State private var selectedChatImage: NSImage?
    @State private var isGeneratingTitle = false
    @State private var chatPagesByTurnID: [String: StandaloneChatPage] = [:]
    @State private var conversationMode: ConversationMode = .code
    @State private var isEnteringGoal = false
    @State private var activeGoal: CodexThreadGoal?
    @State private var goalAchievementTimelineEntries: [GoalAchievementTimelineEntry] = []
    @State private var currentGoalGenerationID: String?
    @State private var currentGoalObjective: String?
    @State private var currentGoalTimeBaselineSeconds: Double?
    @State private var isGoalExpanded = false
    @State private var goalStatusUpdatedAt = Date.now
    @State private var modelOptions: [ConversationModelOption] = []
    @State private var selectedModelID = ""
    @State private var selectedEffort: ConversationEffort = .medium
    @State private var pickerModelID = ""
    @State private var pickerEffort: ConversationEffort = .medium
    @State private var isModelPickerPresented = false
    @State private var providerBoundaries: [ConversationProviderBoundary] = []
    @State private var isSwitchingProvider = false
    @State private var providerNotice: String?
    @State private var messages: [ConversationMessage] = []
    // Oldest message currently rendered in the transcript. The transcript keeps a
    // window that starts here and runs to the newest message; opening a
    // conversation starts the window at the latest user turn.
    @State private var oldestRenderedMessageID: String?
    @State private var isRevealingOlderConversationMessages = false
    /// The latest scroll sample. It changes every scroll frame, so it lives in a
    /// reference outside SwiftUI state, where writing it re-renders nothing.
    @State private var lastConversationScrollSample = ConversationScrollSample()
    /// Messages older than `messages` that the daemon still holds. History is
    /// read a page at a time, and the next page loads once the reader scrolls
    /// past the oldest message already here.
    @State private var earlierStoredMessageCount = 0
    /// Set once the transcript has settled at or above the top of its rendered
    /// window, which is what makes the next upward scroll reveal older
    /// messages. Position has to be observed, never assumed, or a layout pass
    /// taken before the newest turn is pinned reveals a batch on open.
    @State private var isOlderConversationRevealArmed = false
    /// True from the start of a history load until the newest turn has been
    /// pinned, so load-time scroll requests cannot follow the bottom past it.
    @State private var isLatestConversationTurnPinPending = true
    @State private var hasPresentedLatestConversation = false
    /// Natural height of the newest turn, before the minimum height that keeps
    /// it pinnable to the top of the viewport. It only decides whether a
    /// presentation pins the turn or scrolls to its end; layout never reads it.
    @State private var latestTurnContentHeight: CGFloat = 0
    @State private var lastScrolledUserMessageID: String?
    @State private var annotations: [ConversationAnnotation] = []
    @State private var annotationSelection: AnnotationSelection?
    @State private var currentTextSelection: AnnotationSelection?
    @State private var annotationComment = ""
    @State private var activities: [ConversationActivity] = []
    /// Tool calls from every loaded turn, each shown in the timeline after the
    /// message it followed.
    @State private var timelineActivities: [ConversationActivity] = []
    /// A live turn shows its work: the disclosure opens as the turn starts and
    /// folds back into Worked for once the turn settles. A collapse the reader
    /// performs mid-turn stays collapsed until the next turn starts.
    @State private var isActivityExpanded = false
    @State private var responseStartedAt: Date?
    @State private var completedResponseDuration: Int?
    @State private var collapsedProgressTurnIDs = Set<String>()
    @State private var selectedSubagent: ConversationActivity?
    @State private var subagentHistory: ConversationHistory?
    @State private var isLoadingSubagent = false
    @State private var subagentError: String?
    @State private var changeInventory = WorkspaceChangeInventory(unviewed: [], viewed: [], mergingRepositories: [])
    @State private var isViewedSectionExpanded = false
    @AppStorage(WorkspaceSettings.taskSidebarCollapsedKey, store: WorkspaceSettings.preferencesStore) private var isTaskSidebarCollapsed = false
    @AppStorage(WorkspaceSettings.workspaceChangesSectionCollapsedKey, store: WorkspaceSettings.preferencesStore) private var isChangesSectionCollapsed = false
    /// The loading placeholder is for the first read only; later watcher refreshes keep the
    /// current list (or empty state) on screen instead of flashing the spinner.
    @State private var hasLoadedChanges = false
    @State private var isLoadingChanges = false
    @State private var changesNeedRefresh = false
    @State private var changeWatcher: WorkspaceChangeWatcher?
    @State private var isTerminalPresented = false
    @AppStorage(TerminalPanelLayout.widthKey, store: WorkspaceSettings.preferencesStore)
    private var terminalPanelWidth = Double(TerminalPanelLayout.defaultWidth)
    @State private var terminalResizeStartWidth: CGFloat?
    @StateObject private var terminalSession = TaskTerminalSession()
    @State private var changesError: String?
    @State private var selectedChange: WorkspaceChangeEntry?
    @State private var selectedDiff: WorkspaceFileDiff?
    @State private var isDiffPresented = false
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var isMonacoReady = false
    @State private var monacoPresentation: MonacoDiffPresentation?
    @State private var monacoError: String?
    @State private var diffChangeCount: Int?
    @State private var isLoadingHistory = false
    @State private var isApplyingSavedRepositories = false
    @State private var isResponding = false
    @State private var isPreparingSubmittedMessage = false
    @State private var conflictResolutionAttempt = 0
    @State private var hasPausedResponse = false
    @State private var isPausingResponse = false
    @State private var queuedMessages: [QueuedConversationMessage] = []
    /// A `.dispatching` follow-up is claimed for delivery: either reserved for a
    /// steer, or sent as its own turn and kept in the store until that whole turn
    /// ends. Only the others are still waiting for the user.
    private var waitingFollowUps: [QueuedConversationMessage] { queuedMessages.filter { $0.state != .dispatching } }
    @State private var isSubmittingLiveMessage = false
    @State private var userInputRequest: ConversationUserInputRequest?
    // The live snapshot can still carry a request this window just answered.
    @State private var answeredUserInputRequestIDs: Set<String> = []
    // Safe replies this window streamed for secret recovery turns, which history hides.
    @State private var streamedRecoveryReplies: [String: String] = [:]
    @State private var userInputAnswers: [String: [String]] = [:]
    @State private var userInputOther: [String: String] = [:]
    @State private var userInputOtherSelected: Set<String> = []
    @State private var asyncQuestionAnswers: [String: String] = [:]
    @State private var answeredAsyncQuestionIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var actionNotice: String?
    @State private var isShowingWorkspaceEditor = false
    @State private var isShowingRepositoryPicker = false
    @State private var isChoosingRepositoryParent = false
    @State private var repositorySearch = ""
    @State private var repositorySuggestionIndex = 0
    @State private var lastSelectedRepositoryPaths: [String] = []
    @State private var didOverrideRepositoryDefault = false
    @State private var suggestedRepositories: [URL] = []
    @State private var expandedRepositoryPath: String?
    @State private var repositoryBeingEdited: RepositoryWorktreeRecord?
    @State private var editedBranch = ""
    @State private var editedBranchFrom = ""
    @State private var editedMergeTarget = ""
    @State private var editingRepositoryField: String?
    @State private var recentRepositoryPaths: [String] = []
    @FocusState private var focusedRepositoryField: String?
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isRepositorySearchFocused: Bool

    private var isSendDisabled: Bool {
        !isRepositoryRootConfigured || isApplyingSavedRepositories || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty && !annotations.contains(where: \.pending) && !isEnteringGoal) || isDisplayingActiveResponse || isLoadingHistory || userInputRequest != nil
    }

    private var isRepositoryRootConfigured: Bool {
        // Standalone chat has no repository/worktree of its own, so it must never require the
        // app's global repository-root setting to be configured before sending.
        task.isStandaloneChat || WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) != nil
    }

    private var conversationRuntime: ConversationRuntimeModel {
        guard let runtimeModel else { preconditionFailure("The conversation runtime model is not in the environment.") }
        return runtimeModel
    }

    private var canPauseResponse: Bool {
        guard let threadID = task.activeConversationID else { return false }
        return conversationRuntime.canInterruptActiveTurn(threadID: threadID)
    }

    private var provider: ConversationProvider { task.conversationProvider }

    /// Observed so the view refreshes when this task's turn starts or ends.
    /// Claude runs conversations in parallel, so a client-wide flag would miss
    /// this task's edge while another conversation keeps running.
    private var providerTurnIsActive: Bool {
        guard let threadID = task.activeConversationID else { return false }
        return conversationRuntime.isTurnActive(threadID: threadID)
    }

    /// Claude can hold a pending question in several conversations at once, so
    /// this task reads the question from its own session rather than from the
    /// client-wide value.
    private var providerPendingUserInputRequest: ConversationUserInputRequest? {
        conversationRuntime.pendingUserInputRequest(forThread: task.activeConversationID ?? "")
    }

    /// The plan exists only once a first message was sent and the agent is not
    /// waiting on the user's answer to its questions.
    private var canShowStartImplementing: Bool {
        conversationMode == .plan && !isResponding && !isReadOnly
            && messages.contains(where: { $0.role == .user })
            && userInputRequest == nil && providerPendingUserInputRequest == nil
    }

    /// Why a task's plan can't be handed off to an implementation turn yet; transient loading
    /// states also disable the button but need no explanation. A chat never has a workspace
    /// root or a repository picker, so it keeps its disabled button without this reason.
    private var startImplementingUnavailableReason: String? {
        guard !task.isStandaloneChat else { return nil }
        return PlanImplementationHandoff.unavailableReason(workspaceRootPaths: task.workspaceRootPaths)
    }

    private var isConversationTurnActive: Bool {
        conversationRuntime.isTurnActive(threadID: task.activeConversationID ?? "")
    }

    /// Provider switches wait for active turns and queued follow-ups to settle.
    private var canSwitchProvider: Bool {
        !isReadOnly && !isResponding && !isLoadingHistory && !isPreparingSubmittedMessage && !isSwitchingProvider
            && userInputRequest == nil && queuedMessages.isEmpty && task.status != .done
    }

    private var approvalNotice: String {
        "\(provider.displayName) requested an approval. Playhouse denied it because approval prompts are disabled."
    }

    private var diffHighlightStatus: String {
        guard let diffChangeCount else { return "Calculating changes…" }
        guard diffChangeCount > 0 else { return "No text changes" }
        return "\(diffChangeCount) change\(diffChangeCount == 1 ? "" : "s") highlighted"
    }

    /// Describes the editor the diff is actually rendered in: Monaco is loaded once per
    /// session, so a later diff reports the same editor it reused.
    private var monacoStartupDescription: String {
        guard isMonacoReady, let monacoPresentation else { return "Starting editor" }
        let reuse = monacoPresentation.reusedWarmEditor ? "reused" : "loaded"
        return "Editor \(monacoPresentation.editorTag) \(reuse), showing \(monacoPresentation.path)"
    }

    private var latestConversationTurnID: String? {
        if let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            return messages.dropFirst(latestUserIndex + 1).first(where: {
                $0.role == .assistant && $0.turnID != nil
            })?.turnID ?? messages[latestUserIndex].turnID
        }
        return messages.last(where: { $0.turnID != nil })?.turnID
    }

    private var progressMessageIDs: Set<String> {
        guard let latestConversationTurnID,
              collapsedProgressTurnIDs.contains(latestConversationTurnID) else { return [] }
        return Set(messages.lazy.filter {
            $0.role == .assistant && $0.phase == "commentary" && $0.turnID == latestConversationTurnID
        }.map(\.id))
    }

    private var progressMessages: [ConversationMessage] {
        // Computed once: reading the property inside the filter rebuilt the set for every message.
        let ids = progressMessageIDs
        guard !ids.isEmpty else { return [] }
        return messages.filter { ids.contains($0.id) }
    }

    private var conversationMessages: [ConversationMessage] {
        let completedProgressIDs = progressMessageIDs
        // Read on every layout pass and every scroll sample, so the common case
        // of nothing collapsed must not copy the transcript.
        guard !completedProgressIDs.isEmpty else { return messages }
        return messages.filter { !completedProgressIDs.contains($0.id) }
    }

    private static let olderConversationMessageBatchSize = 40
    /// Messages read per history request: the newest page on open, then one
    /// more page each time the rendered window reaches the oldest loaded one.
    static let historyPageSize = 80
    /// How far the transcript must be dragged past the oldest rendered message
    /// before the next older batch is revealed.
    private static let olderConversationRevealThreshold: CGFloat = 24
    /// Corrective scroll passes after the first one, in nanoseconds. A
    /// `LazyVStack` row that was not realized when the scroll began is placed
    /// from an estimate, so the position has to be reapplied once it exists.
    private static let scrollSettleDelays: [UInt64] = [50_000_000]
    /// How close to the bottom, in points, still counts as at the bottom, so
    /// new content keeps being followed.
    private static let conversationBottomFollowThreshold: CGFloat = 16
    /// Above this many changed files the sidebar shows a notice instead of the list, which would stall layout.
    private static let maxRenderedChangeCount = 1000

    /// First message of the newest user turn. Opening a conversation renders
    /// this message and everything after it, so the latest question sits at the
    /// top of the viewport with its answer below.
    private var latestConversationTurnStartID: String? {
        let allMessages = conversationMessages
        // Prompts Playhouse sends on its own are not a turn the user started: anchoring the
        // window there would hide the conversation the recovery is continuing.
        // When redaction has replaced every user message, the placeholders are all there is to anchor on.
        return allMessages.last(where: { $0.role == .user && !PrivatePromptPlaceholder.matches($0.text) })?.id
            ?? allMessages.last(where: { $0.role == .user })?.id
            ?? allMessages.last?.id
    }

    /// The window runs from `oldestRenderedMessageID` to the newest message.
    /// A conversation that was empty when it loaded establishes no window of
    /// its own, so it keeps the newest batch rendered as messages arrive.
    private var renderedConversationMessages: [ConversationMessage] {
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return Array(allMessages.suffix(Self.olderConversationMessageBatchSize))
        }
        return Array(allMessages[startIndex...])
    }

    private var hasOlderConversationMessages: Bool {
        // Answered from indices rather than by building the rendered window:
        // every scroll sample asks this question.
        if earlierStoredMessageCount > 0 { return true }
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return allMessages.count > Self.olderConversationMessageBatchSize
        }
        return startIndex > allMessages.startIndex
    }

    /// Reveals the next older batch, keeping the message that was at the top of
    /// the viewport in place so the transcript does not jump under the pointer.
    private func revealOlderConversationMessages(using proxy: ScrollViewProxy) {
        guard hasOlderConversationMessages, !isRevealingOlderConversationMessages else { return }
        let allMessages = conversationMessages
        guard let currentTopID = renderedConversationMessages.first?.id,
              let currentStartIndex = allMessages.firstIndex(where: { $0.id == currentTopID }) else { return }
        // The loaded messages cannot fill another batch above the window, so
        // read the next older page from the daemon first.
        if currentStartIndex < Self.olderConversationMessageBatchSize, earlierStoredMessageCount > 0 {
            isRevealingOlderConversationMessages = true
            isOlderConversationRevealArmed = false
            Task { @MainActor in
                let loaded = await loadEarlierConversationMessages()
                isRevealingOlderConversationMessages = false
                if loaded { revealOlderConversationMessages(using: proxy) }
            }
            return
        }
        let newStartIndex = max(0, currentStartIndex - Self.olderConversationMessageBatchSize)
        guard newStartIndex < currentStartIndex else { return }
        isRevealingOlderConversationMessages = true
        isOlderConversationRevealArmed = false
        oldestRenderedMessageID = allMessages[newStartIndex].id
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let restoreAnchor = { proxy.scrollTo(currentTopID, anchor: .top) }
            withTransaction(transaction, restoreAnchor)
            // The batch that was just inserted above the anchor is positioned
            // from estimates until its rows are realized, so the anchor has to
            // be restored again once they are.
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(transaction, restoreAnchor)
            }
            isRevealingOlderConversationMessages = false
        }
    }

    /// Reads the page of history just before the oldest loaded message and
    /// prepends it. Returns whether any earlier messages were added.
    private func loadEarlierConversationMessages() async -> Bool {
        guard let oldestLoadedID = messages.first?.id else { return false }
        do {
            let page = try await conversationManager.history(
                taskID: task.id,
                messageLimit: Self.historyPageSize,
                beforeMessageID: oldestLoadedID
            )
            // Another reload may have replaced the transcript while this read ran.
            guard messages.first?.id == oldestLoadedID else { return false }
            let loadedIDs = Set(messages.map(\.id))
            let earlier = page.messages.filter { !loadedIDs.contains($0.id) }
            messages = earlier + messages
            earlierStoredMessageCount = page.earlierMessageCount ?? 0
            mergeTimelineActivities(page.timelineActivities)
            collapsedProgressTurnIDs.formUnion(earlier.lazy
                .filter { $0.role == .assistant && $0.phase == "final_answer" }
                .compactMap(\.turnID))
            restoreAnnotations(from: messages, keepingPending: true)
            return !earlier.isEmpty
        } catch {
            // The anchor message can be gone after a provider switch rewrote
            // history; reload the newest page rather than leave paging stuck.
            if (error as? BridgeCommandError)?.code == "not_found" {
                earlierStoredMessageCount = 0
                Task { await loadConversation() }
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    /// Applies a history read to the transcript. A page keeps the earlier
    /// messages this window already loaded above it; a complete history is
    /// trimmed back to the messages already loaded, so a reload never pulls
    /// the whole conversation into memory.
    private func applyHistoryMessages(_ history: ConversationHistory, _ incoming: [ConversationMessage]? = nil) {
        defer { mergeTimelineActivities(history.timelineActivities) }
        let incoming = incoming ?? history.messages
        if let earlierCount = history.earlierMessageCount {
            if let first = incoming.first, let overlap = messages.firstIndex(where: { $0.id == first.id }) {
                messages = Array(messages[..<overlap]) + incoming
                earlierStoredMessageCount = max(0, earlierCount - overlap)
            } else {
                messages = incoming
                earlierStoredMessageCount = earlierCount
            }
            return
        }
        if earlierStoredMessageCount > 0 || messages.count >= Self.historyPageSize,
           let oldestLoadedID = messages.first?.id,
           let start = incoming.firstIndex(where: { $0.id == oldestLoadedID }) {
            messages = Array(incoming[start...])
            earlierStoredMessageCount = start
        } else {
            messages = incoming
            earlierStoredMessageCount = 0
        }
    }

    /// Adds a history read's placed tool calls, replacing earlier copies of the
    /// same calls, and drops calls whose message is no longer loaded.
    private func mergeTimelineActivities(_ incoming: [ConversationActivity]) {
        let incomingIDs = Set(incoming.map(\.id))
        let loadedMessageIDs = Set(messages.map(\.id))
        timelineActivities = (timelineActivities.filter { !incomingIDs.contains($0.id) } + incoming).filter {
            $0.afterMessageID.map(loadedMessageIDs.contains) == true
        }
    }

    /// The runway occupies everything above the rendered window, so the distance
    /// from the viewport top to the window top is what is left of it.
    private func conversationWindowTopY(offsetY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        hasOlderConversationMessages ? viewportHeight - offsetY : -offsetY
    }

    /// Handles a new position for the top of the rendered window, measured from
    /// the top of the viewport. Dragging it below the threshold means the user
    /// scrolled past the oldest rendered message, which reveals the next batch.
    private func handleConversationWindowTop(_ windowTopY: CGFloat, using proxy: ScrollViewProxy) {
        // This runs for every scroll sample, and publishing state re-renders the
        // whole transcript, so the armed flag is only ever written when it
        // actually changes.
        guard hasOlderConversationMessages, !isRevealingOlderConversationMessages else {
            if isOlderConversationRevealArmed { isOlderConversationRevealArmed = false }
            return
        }
        let isWithinWindowTop = windowTopY <= Self.olderConversationRevealThreshold
        guard isOlderConversationRevealArmed else {
            // Arm only once the window top has settled at or above the top of
            // the viewport. Position has to be observed, never assumed, or the
            // layout pass taken before the newest turn is pinned reveals a
            // batch on open.
            if isWithinWindowTop { isOlderConversationRevealArmed = true }
            return
        }
        guard !isWithinWindowTop else { return }
        revealOlderConversationMessages(using: proxy)
    }

    /// Keeps the newest content in view while the reader stays at the bottom.
    /// Reaching the bottom starts following; scrolling up away from it stops,
    /// so content arriving below never pulls a reader back down.
    private func followConversationBottom(
        from old: ConversationScrollGeometry,
        to new: ConversationScrollGeometry,
        using proxy: ScrollViewProxy
    ) {
        let sample = lastConversationScrollSample
        if new.maxOffsetY - new.offsetY <= Self.conversationBottomFollowThreshold {
            sample.isFollowingLatest = true
            return
        }
        // Content arriving below leaves the offset where it was, and a shrinking
        // transcript clamps it onto the bottom, so only the reader moves it up.
        if new.offsetY < old.offsetY - 0.5 {
            sample.isFollowingLatest = false
            return
        }
        // A history load pins its own turn, and a reveal restores its anchor;
        // following the bottom then would scroll away from either.
        guard sample.isFollowingLatest, new.maxOffsetY != old.maxOffsetY,
              !isLatestConversationTurnPinPending, !isRevealingOlderConversationMessages else { return }
        Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(Self.conversationScrollEndID, anchor: .bottom) }
        }
    }

    /// Collapses the transcript to the newest user turn and pins that question
    /// to the top of the viewport.
    private func presentLatestConversationTurn(using proxy: ScrollViewProxy) {
        guard let turnStartID = latestConversationTurnStartID else {
            // Nothing to pin: an empty conversation renders everything it
            // receives while it stays open.
            isLatestConversationTurnPinPending = false
            return
        }
        oldestRenderedMessageID = turnStartID
        isOlderConversationRevealArmed = false
        // This pin already puts the newest question at the top, so record it as
        // the one in view; otherwise the next message count change scrolls to it
        // a second time as though it had just been sent.
        lastScrolledUserMessageID = conversationMessages.last(where: { $0.role == .user })?.id
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let pin = {
                // A pending question form renders below the newest turn and
                // must be fully reachable, Submit included; pinning the turn's
                // question to the top can leave the form behind the composer.
                if let request = userInputRequest, request.threadID == task.activeConversationID {
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                } else {
                    proxy.scrollTo(turnStartID, anchor: .top)
                }
            }
            withTransaction(transaction, pin)
            // The rows below the pin are realized by that first scroll; pinning
            // again lands on their real positions instead of estimates.
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(transaction, pin)
            }
            hasPresentedLatestConversation = true
            isLatestConversationTurnPinPending = false
            // A pin that lands where the transcript already was reports no new
            // scroll sample, which would leave the reveal disarmed for good;
            // judge it from where the viewport now is.
            if let offsetY = lastConversationScrollSample.offsetY {
                handleConversationWindowTop(
                    conversationWindowTopY(offsetY: offsetY, viewportHeight: lastConversationScrollSample.viewportHeight),
                    using: proxy
                )
            }
        }
    }

    /// Timeline anchors resolve against the whole transcript, while the
    /// transcript renders a window that starts at the newest turn. Clamp an
    /// anchor that falls above the window to its first rendered message so the
    /// row still appears instead of disappearing with the messages it follows.
    ///
    /// Provider boundaries and goal achievements are state transitions that
    /// stay meaningful wherever they are shown, so they are clamped. Context
    /// compaction rows are not: they are positional markers whose meaning comes
    /// from the two messages they sit between, and they reappear with those
    /// messages as older batches are revealed.
    private func renderedAnchorMessageID(for anchorID: String?) -> String? {
        guard let anchorID else { return nil }
        let rendered = renderedConversationMessages
        if rendered.contains(where: { $0.id == anchorID }) { return anchorID }
        return rendered.first?.id ?? anchorID
    }

    private func goalAchievementAnchorMessageID(for entry: GoalAchievementTimelineEntry) -> String? {
        if entry.afterMessageID == GoalAchievementTimelineEntry.beforeFirstMessageID { return nil }
        if conversationMessages.contains(where: { $0.id == entry.afterMessageID }) {
            return entry.afterMessageID
        }
        return conversationMessages.last?.id
    }

    private var activityDisclosureAnchorID: String? {
        if let latestUserIndex = conversationMessages.lastIndex(where: { $0.role == .user }) {
            return conversationMessages.dropFirst(latestUserIndex + 1).first(where: { $0.role == .assistant })?.id
        }
        return conversationMessages.first(where: { $0.role == .assistant })?.id
    }

    private var shouldShowActivityDisclosure: Bool {
        !activities.isEmpty || !progressMessageIDs.isEmpty || isResponding || completedResponseDuration != nil || hasCompletedAssistantResponse
    }

    private var hasCompletedAssistantResponse: Bool {
        guard let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return messages.contains { $0.role == .assistant && $0.phase == "final_answer" }
        }
        let messagesAfterLatestUser = messages.dropFirst(latestUserIndex + 1)
        if messagesAfterLatestUser.contains(where: {
            $0.role == .assistant && $0.phase == "final_answer"
        }) {
            return true
        }
        guard !providerTurnIsActive else { return false }
        return messagesAfterLatestUser.contains {
            $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isDisplayingActiveResponse: Bool {
        isResponding && !hasCompletedAssistantResponse
    }

    private var responseStartedAtDefaultsKey: String {
        TaskPreferenceKeys.responseStartedAt(taskID: task.id)
    }

    private var completedResponseDurationDefaultsKey: String {
        TaskPreferenceKeys.completedResponseDuration(taskID: task.id)
    }

    private var goalAchievementTimelineDefaultsKey: String {
        TaskPreferenceKeys.goalAchievementTimeline(taskID: task.id)
    }

    private var goalGenerationDefaultsKey: String {
        CodexGoalGenerationStore.generationIDKey(taskID: task.id)
    }

    private var goalGenerationObjectiveDefaultsKey: String {
        CodexGoalGenerationStore.objectiveKey(taskID: task.id)
    }

    private var goalGenerationTimeBaselineDefaultsKey: String {
        CodexGoalGenerationStore.timeBaselineKey(taskID: task.id)
    }

    var body: some View {
        Group {
            if task.isStandaloneChat {
                // The standalone chat sidebar reuses only the conversation transcript/composer,
                // not the repo-specific "Changes" sidebar a real task's worktree needs.
                conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    taskSidebar

                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)

                    conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The terminal floats over the conversation's right edge rather than taking
                // its width, so opening it never reflows the transcript or the composer.
                .overlay(alignment: .trailing) {
                    if isTerminalPresented {
                        GeometryReader { geometry in
                            let available = conversationWidth(in: geometry.size.width)
                            let width = TerminalPanelLayout.clampedWidth(CGFloat(terminalPanelWidth), available: available)
                            HStack(spacing: 0) {
                                terminalResizeHandle(width: width, available: available)
                                TaskTerminalPanel(
                                    session: terminalSession,
                                    onRestart: { terminalSession.restart(workspaceManager: workspaceManager) },
                                    onClose: { setTerminalPresented(false) }
                                )
                            }
                            .frame(width: width)
                            .shadow(color: .black.opacity(0.22), radius: 12, x: -4, y: 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                .clipped()
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .onChange(of: task.id, initial: true) {
            runtimeSlice.observe(conversationRuntime, taskID: task.id.uuidString) { [task] in
                Set([task.codexThreadID, task.claudeSessionID].compactMap { $0 })
            }
        }
        .onAppear {
            if !isReadOnly,
               let savedMode = WorkspaceSettings.preferencesStore.string(forKey: conversationModeDefaultsKey),
               let mode = ConversationMode(rawValue: savedMode) {
                conversationMode = mode
            }
            guard isNewTask else { return }
            isShowingRepositoryPicker = false
            lastSelectedRepositoryPaths = WorkspaceSettingsManager().lastSelectedRepositories
            isComposerFocused = true
            loadSuggestedRepositories()
            let savedRepositories = validLastSelectedRepositoryURLs
            if !savedRepositories.isEmpty {
                selectRepositories(savedRepositories, reopenPickerOnError: false, isApplyingDefault: true)
            }
        }
        .sheet(isPresented: $isShowingWorkspaceEditor) {
            WorkspaceRootsEditor(
                parentFolderURL: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath),
                initialRoots: workspaceRootURLs,
                repositoryWorktrees: task.repositoryWorktrees,
                onSave: updateWorkspaceRoots
            )
        }
        .sheet(isPresented: Binding(
            get: { selectedChatImage != nil },
            set: { if !$0 { selectedChatImage = nil } }
        )) {
            if let selectedChatImage {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Close") { self.selectedChatImage = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("close-chat-image-viewer")
                        .buttonHoverPointer()
                        .nativeHelp("Close the full-size image")
                    Image(nsImage: selectedChatImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Full-size attached image")
                        .accessibilityIdentifier("chat-image-full-size")
                }
                .padding(16)
                // Stay within the window's own 980x640 content minimum so the sheet
                // can never outgrow its host window and push Close out of reach.
                .frame(minWidth: 900, minHeight: 600)
            }
        }
        .overlay { skillsPage }
        .task {
            // Synchronous, so the picker shows the cached model name on the
            // first frame instead of "Default" while the conversation and a
            // fresh model list are still round-tripping through the bridge.
            if !isReadOnly { primeModelOptionsFromCache() }
            if !isReadOnly { refreshQueuedMessages() }
            if !isReadOnly {
                _ = try? await conversationManager.reconcileLifecycleStatusOnOpen(taskID: task.id)
            }
            if !isReadOnly, let request = providerPendingUserInputRequest, request.threadID == task.activeConversationID {
                userInputRequest = request
            }
            await loadConversation()
            if !isReadOnly {
                refreshQueuedMessages()
                await loadModels()
            }
            if task.isStandaloneChat { refreshChatPageStatus() }
            if isNewTask {
                await Task.yield()
                isComposerFocused = true
            }
            if conflictResolutionRequested && !isReadOnly && !isResponding {
                conflictResolutionAttempt = 1
                sendMessage(overrideText: "The PR has conflicts. Fix them, commit, and push.")
            } else if let skillFixPrompt, !isReadOnly, !isResponding, messages.isEmpty, task.pendingSubmittedPrompt == nil {
                // Sent as the composer's own draft, so the composer clears as for any send.
                draft = skillFixPrompt
                sendMessage()
            }
        }
        .onChange(of: providerPendingUserInputRequest) { previous, request in
            // Once the snapshot drops it, a later question may reuse an answered request's ID.
            if request == nil { answeredUserInputRequestIDs.removeAll() }
            // A live question can end without an answer here (a rejected private
            // question, or another window's answer); keep it only if it was saved.
            if request == nil, let previous, userInputRequest?.id == previous.id {
                Task { @MainActor in
                    guard let history = try? await conversationManager.history(taskID: task.id, messageLimit: 1),
                          userInputRequest?.id == previous.id else { return }
                    let saved = history.pendingUserInputRequest
                    userInputRequest = saved?.threadID == task.activeConversationID ? saved : nil
                }
            }
            guard let request, request.threadID == task.activeConversationID, request != userInputRequest,
                  !answeredUserInputRequestIDs.contains(request.id) else { return }
            showUserInputRequest(request)
        }
        .onChange(of: messages) { _, _ in
            // History reloads bring back the hidden text for replies this window streamed.
            if !streamedRecoveryReplies.isEmpty { showStreamedRecoveryReplies() }
        }
        .onChange(of: providerTurnIsActive) { _, isTurnActive in
            if !isTurnActive, task.isStandaloneChat { refreshChatPageStatus() }
            if !isTurnActive, !isReadOnly {
                refreshQueuedMessages()
            }
            let submittedTurnIsPending = task.pendingSubmittedPrompt != nil
                && (task.status == .inProgress || task.status == .waitingResponse)
            guard let taskThreadID = task.activeConversationID else {
                isResponding = submittedTurnIsPending
                return
            }
            let completedTurnIsVisible = hasCompletedAssistantResponse && !isTurnActive
            isResponding = completedTurnIsVisible
                ? false
                : submittedTurnIsPending || (isTurnActive && conversationRuntime.isTurnActive(threadID: taskThreadID))
            // A turn stopped while this window followed it (not sent from it) can still be continued.
            if !isTurnActive, !isResponding, conversationRuntime.wasLastTurnInterrupted(threadID: taskThreadID) {
                hasPausedResponse = true
            }
        }
        .onChange(of: task.pendingSubmittedPrompt == nil) { _, cleared in
            // The daemon clears the submitted prompt after the turn ends, which can be after
            // this window saw it end. A turn parked on a question is not over, even while the
            // runtime snapshot lags, so leave the answer flow to settle it.
            if cleared, isResponding, !providerTurnIsActive,
               userInputRequest == nil, providerPendingUserInputRequest == nil,
               !conversationRuntime.isTurnActive(threadID: task.activeConversationID ?? "") {
                isResponding = false
            }
        }
        .onChange(of: conversationRuntime.wasLastTurnInterrupted(threadID: task.activeConversationID ?? "")) { _, interrupted in
            // The daemon can report the stop after this window loaded the settled turn.
            if interrupted, !isResponding, !providerTurnIsActive { hasPausedResponse = true }
        }
        .onChange(of: conversationRuntime.snapshot.conversationRevisions[task.id.uuidString]) { _, _ in
            // Another caller's turn (a queued follow-up, a CLI send or steer, or
            // a turn this window started before it was reopened) reaches this
            // window only through history.
            guard !isReadOnly else { return }
            refreshQueuedMessages()
            // A page decision can land after the turn ended; only a revision announces it.
            // Mid-turn revisions are progress, and turn end refreshes pages anyway, so the
            // store is only reread while no turn runs.
            if task.isStandaloneChat, !providerTurnIsActive { refreshChatPageStatus() }
            // History lags what this window's own stream has already shown.
            guard followedTurnStreams == 0 else { return }
            followHistory()
        }
        .onChange(of: conversationRuntime.snapshot.goal.stateRevision) { _, _ in
            guard conversationRuntime.snapshot.goal.stateThreadID == task.codexThreadID else { return }
            Task { @MainActor in
                activeGoal = try? await conversationManager.goal(taskID: task.id)
                if let activeGoal { reconcileGoalGeneration(with: activeGoal) }
                goalStatusUpdatedAt = .now
            }
        }
        .onChange(of: conversationRuntime.snapshot.goal.turnRevision) { _, _ in
            guard let threadID = task.codexThreadID, conversationRuntime.isObservingGoal(threadID: threadID) else { return }
            Task { @MainActor in await refreshGoalConversation() }
        }
        .onChange(of: conversationRuntime.snapshot.goal.turnCompletedRevision) { _, _ in
            guard let threadID = task.codexThreadID, conversationRuntime.isObservingGoal(threadID: threadID) else { return }
            let completedTurnID = conversationRuntime.snapshot.goal.turnCompletedTurnID
            Task { @MainActor in
                activeGoal = try? await conversationManager.goal(taskID: task.id)
                goalStatusUpdatedAt = .now
                await refreshGoalConversation()
                guard let activeGoal, activeGoal.status == "complete" else { return }
                reconcileGoalGeneration(with: activeGoal)
                guard let generationID = currentGoalGenerationID,
                      !goalAchievementTimelineEntries.contains(where: { $0.id == generationID }) else { return }
                let completionMessage = completedTurnID.flatMap { turnID in
                    conversationMessages.last(where: { $0.turnID == turnID })
                } ?? conversationMessages.last
                let anchorID = completionMessage?.id ?? GoalAchievementTimelineEntry.beforeFirstMessageID
                goalAchievementTimelineEntries.append(GoalAchievementTimelineEntry(
                    id: generationID,
                    summary: goalAchievementSummary(activeGoal),
                    afterMessageID: anchorID
                ))
                persistGoalAchievementTimeline()
            }
        }
        .task(id: task.workspaceRootPaths) {
            let watchPaths = await WorkspaceChangeWatcher.watchPaths(workspaceRoots: task.workspaceRootPaths)
            guard !Task.isCancelled else { return }
            changeWatcher?.stop()
            changeWatcher = WorkspaceChangeWatcher(paths: watchPaths) {
                Task { await refreshWorkspaceChanges() }
            }
            changeWatcher?.start()
            await refreshWorkspaceChanges()
        }
        .onDisappear {
            changeWatcher?.stop()
            changeWatcher = nil
            terminalSession.terminate()
            // Switching tasks replaces this view without going back first.
            if !isReadOnly, isDraftUnsaved { persistDraft(reportingErrors: false) }
        }
    }

    private func setTerminalPresented(_ presented: Bool) {
        if presented { terminalSession.startIfNeeded(taskID: task.id, workspaceManager: workspaceManager) }
        withAnimation(.easeOut(duration: 0.22)) { isTerminalPresented = presented }
    }

    /// The panel's left border; dragging it left widens the terminal and right narrows it.
    private func terminalResizeHandle(width: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 17)
                    .contentShape(Rectangle())
                    .hoverCursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if terminalResizeStartWidth == nil {
                                    // Held for the whole drag, so the pointer can leave the thin border.
                                    NSCursor.resizeLeftRight.push()
                                }
                                let start = terminalResizeStartWidth ?? width
                                terminalResizeStartWidth = start
                                terminalPanelWidth = Double(TerminalPanelLayout.clampedWidth(
                                    start - value.translation.width, available: available
                                ))
                            }
                            .onEnded { _ in
                                if terminalResizeStartWidth != nil { NSCursor.pop() }
                                terminalResizeStartWidth = nil
                            }
                    )
                    .onDisappear {
                        // A panel closed mid-drag may never end the gesture.
                        if terminalResizeStartWidth != nil {
                            NSCursor.pop()
                            terminalResizeStartWidth = nil
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Resize terminal")
                    .accessibilityValue("\(Int(width.rounded())) points")
                    .accessibilityIdentifier("terminal-resize-handle")
            }
    }

    private static let expandedSidebarWidth: CGFloat = 232
    private static let collapsedSidebarWidth: CGFloat = 38

    /// The width the terminal panel can float over: the conversation, beside the sidebar and its divider.
    private func conversationWidth(in containerWidth: CGFloat) -> CGFloat {
        containerWidth - (isTaskSidebarCollapsed ? Self.collapsedSidebarWidth : Self.expandedSidebarWidth) - 1
    }

    /// Why this task can't open a terminal yet, shared with the CLI's `task terminal`.
    private var terminalUnavailableReason: String? {
        TaskTerminalLaunch.unavailableReason(for: task.repositoryWorktrees)
    }

    /// Quick actions for the task, right-aligned along the bottom of the sidebar.
    private var sidebarCommandRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Button {
                setTerminalPresented(!isTerminalPresented)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .foregroundStyle(terminalUnavailableReason != nil && !isTerminalPresented
                        ? Color.secondary.opacity(0.35)
                        : (isTerminalPresented ? WorkspaceTheme.accent : Color.secondary))
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isTerminalPresented ? WorkspaceTheme.accent.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .disabled(terminalUnavailableReason != nil && !isTerminalPresented)
            .nativeHelp(terminalUnavailableReason ?? (isTerminalPresented ? "Hide the terminal" : "Open a terminal in this task's worktree"))
            .accessibilityLabel(isTerminalPresented ? "Hide terminal" : "Open terminal")
            .accessibilityValue(isTerminalPresented ? "Shown" : "Hidden")
            .accessibilityIdentifier("toggle-terminal-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-command-row")
    }

    @ViewBuilder
    private var taskSidebar: some View {
        if isTaskSidebarCollapsed {
            collapsedTaskSidebar
        } else {
            expandedTaskSidebar
        }
    }

    private func setTaskSidebarCollapsed(_ collapsed: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isTaskSidebarCollapsed = collapsed
        }
    }

    private func toggleChangesSection() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isChangesSectionCollapsed.toggle()
        }
    }

    /// A narrow rail that keeps the pending count visible while the sidebar is hidden.
    private var collapsedTaskSidebar: some View {
        VStack(spacing: 8) {
            Button {
                setTaskSidebarCollapsed(false)
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Show sidebar")
            .accessibilityLabel("Show sidebar")
            .accessibilityIdentifier("show-task-sidebar-button")

            if !changeInventory.unviewed.isEmpty {
                Text("\(changeInventory.unviewed.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Changes to review: \(changeInventory.unviewed.count)")
                    .accessibilityIdentifier("collapsed-task-sidebar-count")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(width: Self.collapsedSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar-collapsed")
    }

    private var expandedTaskSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    setTaskSidebarCollapsed(true)
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 24)
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .nativeHelp("Hide sidebar")
                .accessibilityLabel("Hide sidebar")
                .accessibilityIdentifier("hide-task-sidebar-button")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            changesSectionHeader

            if isChangesSectionCollapsed {
                Spacer(minLength: 0)
            } else {
                changesSectionContent
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            sidebarCommandRow
        }
        .frame(width: Self.expandedSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar")
    }

    /// The Changes section's header; collapsing hides its lists so later sidebar sections
    /// can share the column, and the pending count stays visible while it's collapsed.
    private var changesSectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                toggleChangesSection()
            } label: {
                Image(systemName: isChangesSectionCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 24)
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp(isChangesSectionCollapsed ? "Expand changes" : "Collapse changes")
            .accessibilityLabel(isChangesSectionCollapsed ? "Expand changes" : "Collapse changes")
            .accessibilityValue(isChangesSectionCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("toggle-workspace-changes-section-button")
            Text("Changes")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("workspace-changes-title")
                .onTapGesture { toggleChangesSection() }
            if isChangesSectionCollapsed && !changeInventory.unviewed.isEmpty {
                Text("\(changeInventory.unviewed.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Changes to review: \(changeInventory.unviewed.count)")
                    .accessibilityIdentifier("collapsed-workspace-changes-section-count")
            }
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture { toggleChangesSection() }
            Button {
                Task { await refreshWorkspaceChanges() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Refresh workspace changes")
            .accessibilityLabel("Refresh workspace changes")
            .accessibilityIdentifier("refresh-workspace-changes-button")
            .disabled(!hasLoadedChanges)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-changes-section-header")
    }

    @ViewBuilder
    private var changesSectionContent: some View {
        if let changesError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't read Git changes", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                Text(changesError)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task { await refreshWorkspaceChanges() }
                }
                .buttonHoverPointer()
                .nativeHelp("Retry")
                .font(.system(size: 11, weight: .medium))
                .accessibilityIdentifier("retry-workspace-changes-button")
            }
            .padding(12)
            .accessibilityIdentifier("workspace-changes-error")
        } else if !hasLoadedChanges {
            ProgressView("Checking folders…")
                .controlSize(.small)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace-changes-loading")
        } else if changeInventory.isEmpty && !changeInventory.mergingRepositories.isEmpty {
            mergeInProgressNotice
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if changeInventory.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text("No changes")
                    .font(.system(size: 12, weight: .medium))
                Text("Changes in Git repositories under this task's folders will appear here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("workspace-changes-empty")
        } else if changeInventory.count > Self.maxRenderedChangeCount {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text("Too many changes to list")
                    .font(.system(size: 12, weight: .medium))
                Text(tooManyChangesMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // An explicit label: a combined element of these texts reads back with an empty label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Too many changes to list. \(tooManyChangesMessage)")
            .accessibilityIdentifier("workspace-changes-too-many")
        } else {
            ScrollView {
                // Lazy so off-screen rows stay out of the view tree; every row carries AppKit tooltip views.
                LazyVStack(alignment: .leading, spacing: 15) {
                    if !changeInventory.mergingRepositories.isEmpty {
                        mergeInProgressNotice
                            .padding(.horizontal, 14)
                    }
                    changeSection(title: "Viewed", entries: changeInventory.viewed)
                    changeSection(title: "Changes", entries: changeInventory.unviewed)
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("workspace-changes-list")
        }
    }

    /// A Viewed row always shows the reviewed work from the branch base; only a change made
    /// after that review is measured from the saved snapshot.
    private func diffBaselineLabel(_ entry: WorkspaceChangeEntry) -> String {
        entry.group == .unviewed && entry.hasViewedSnapshot ? "Since last viewed" : "Since branch base"
    }

    private var mergeInProgressMessage: String {
        "Changes in \(changeInventory.mergingRepositories.map(repositoryLabel).joined(separator: ", ")) are hidden until the merge is committed or aborted."
    }

    private var tooManyChangesMessage: String {
        "\(changeInventory.count) changed files is more than the \(Self.maxRenderedChangeCount) this list shows. Check for files that should be ignored, such as build output."
    }

    /// Shown in place of a repository's files while it has a merge open, since the merge stages
    /// everything the merged branch brought in.
    private var mergeInProgressNotice: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("Merge in progress")
                .font(.system(size: 12, weight: .medium))
            Text(mergeInProgressMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        // An explicit label: a combined element of these texts reads back with an empty label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Merge in progress. \(mergeInProgressMessage)")
        .accessibilityIdentifier("workspace-changes-merge-in-progress")
    }

    private func changeSection(title: String, entries: [WorkspaceChangeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: title == "Viewed" ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(title == "Viewed" ? .green : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier(title == "Viewed" ? "viewed-changes-title" : "unviewed-changes-title")
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if title == "Viewed" {
                    Image(systemName: isViewedSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if !entries.isEmpty {
                    Button {
                        Task { await markAllViewed() }
                    } label: {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 18)
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .nativeHelp("Mark all as viewed")
                    .accessibilityLabel("Mark all as viewed")
                    .accessibilityIdentifier("mark-all-viewed-button")
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                if title == "Viewed" { isViewedSectionExpanded.toggle() }
            }
            // Without a container, the section identifier replaces the title's own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(title == "Viewed" ? "viewed-changes-section" : "unviewed-changes-section")

            if title == "Viewed" && !isViewedSectionExpanded {
                EmptyView()
            } else if entries.isEmpty {
                Text("No files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 31)
                    .padding(.vertical, 3)
            } else {
                let groups = repositoryGroups(entries)
                ForEach(groups, id: \.repository) { repositoryGroup in
                    if Set(changeInventory.unviewed.map(\.repository) + changeInventory.viewed.map(\.repository)).count > 1 {
                        Text(repositoryLabel(repositoryGroup.repository))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 17)
                            .padding(.top, 4)
                            .accessibilityIdentifier("workspace-repository-\(repositoryGroup.repository.hashValue)")
                    }
                    ForEach(repositoryGroup.entries) { entry in
                        HStack(spacing: 2) {
                            Button {
                                openDiff(entry)
                            } label: {
                                HStack(spacing: 7) {
                                Image(systemName: changeSymbol(for: entry.status))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(changeColor(for: entry.status))
                                    .frame(width: 12)
                                Text(entry.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(entry.isUncommitted ? Color.green : Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(statusBadge(for: entry))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(changeColor(for: entry.status))
                            }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(selectedChange?.id == entry.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .nativeHelp("View \(entry.group.displayName) diff for \(entry.path)")
                            .accessibilityLabel("\(entry.path), \(entry.status), \(entry.group.displayName)")
                            // The button is one accessibility element, so the name's color is reported here.
                            .accessibilityValue(entry.isUncommitted ? "Uncommitted, green" : "Committed, primary")
                            .accessibilityIdentifier("workspace-change-\(entry.group.rawValue)-\(entry.path)")
                            if entry.group == .unviewed {
                                Button {
                                    Task { await markViewed(entry) }
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 22)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Mark as viewed")
                                .accessibilityLabel("Mark \(entry.path) as viewed")
                                .accessibilityIdentifier("mark-viewed-\(entry.path)")
                            } else {
                                Button {
                                    Task { await markUnviewed(entry) }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 22)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Mark as unviewed")
                                .accessibilityLabel("Mark \(entry.path) as unviewed")
                                .accessibilityIdentifier("mark-unviewed-\(entry.path)")
                            }
                        }
                        .padding(.horizontal, 7)
                    }
                }
            }
        }
    }

    private func repositoryGroups(_ entries: [WorkspaceChangeEntry]) -> [ChangeRepositoryGroup] {
        Dictionary(grouping: entries, by: \.repository)
            .keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { repository in
                ChangeRepositoryGroup(repository: repository, entries: entries.filter { $0.repository == repository })
            }
    }

    private func repositoryLabel(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(2).joined(separator: "/")
    }

    private func statusBadge(for entry: WorkspaceChangeEntry) -> String {
        if entry.statusCode == "??" { return "U" }
        if entry.statusCode.contains("R") { return "R" }
        if entry.statusCode.contains("A") { return "A" }
        if entry.statusCode.contains("D") { return "D" }
        if entry.status == "conflict" { return "!" }
        return "M"
    }

    private func changeSymbol(for status: String) -> String {
        switch status {
        case "added", "untracked": "plus.square.fill"
        case "deleted": "minus.square.fill"
        case "renamed", "copied": "arrow.turn.up.right"
        case "conflict": "exclamationmark.triangle.fill"
        default: "doc.text"
        }
    }

    private func changeColor(for status: String) -> Color {
        switch status {
        case "added", "untracked": .green
        case "deleted", "conflict": .red
        case "renamed", "copied": .orange
        default: .secondary
        }
    }

    private var conversationPanel: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                conversationHeader

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                safetyNotice

                // An agent's conversation covers this one; laying out the hidden
                // transcript underneath it would only cost time.
                if selectedSubagent == nil {
                    conversation
                } else {
                    Spacer(minLength: 0)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                if isReadOnly {
                    Label("Archived conversation · read only", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("archived-conversation-read-only")
                } else {
                    ComposerDraftScope { composer }
                }
            }
            .accessibilityHidden(selectedSubagent != nil)
            // The final answer folds this turn's activity, agents included, into
            // Worked for, even while an agent's conversation covers the transcript.
            .onChange(of: hasCompletedAssistantResponse) { _, hasCompletedResponse in
                if hasCompletedResponse {
                    isActivityExpanded = false
                }
            }
            // A turn in flight shows its progress instead of burying it behind
            // "Working for". Settling folds the section away again whether the
            // turn answered, was stopped, or was interrupted, so the result
            // reads cleanly. A collapse the reader performs mid-turn stays
            // collapsed, because this fires on the active/settled transition
            // rather than on each message or activity update.
            //
            // `initial` is for a task opened while its turn already runs; the
            // first evaluation still reads the default `isResponding`, so the
            // expansion actually lands when `loadHistory` raises it.
            //
            // One provider difference rides on `hasCompletedAssistantResponse`
            // rather than on this rule: Claude persists `final_answer` on its
            // answer, while a Codex `agentMessage` read back from history does
            // not, so between a Codex final answer and its turn completion a
            // task reopened from persisted history keeps the section open where
            // Claude's would have folded. The window's own stream marks the
            // phase for both, so this only shows on a reload inside that window.
            .onChange(of: isDisplayingActiveResponse, initial: true) { _, isActive in
                isActivityExpanded = isActive
            }

            if isDiffPresented {
                fileDiffOverlay
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }

            if let selectedSubagent {
                subagentConversation(selectedSubagent)
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.24), value: isDiffPresented)
        .onExitCommand {
            if isDiffPresented { closeDiff() }
        }
    }

    private var fileDiffOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button(action: closeDiff) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .nativeHelp("Close diff")
                .accessibilityLabel("Close diff")
                .accessibilityIdentifier("close-workspace-diff-button")

                if let selectedChange {
                    Image(systemName: changeSymbol(for: selectedChange.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(changeColor(for: selectedChange.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedChange.path)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("workspace-diff-title")
                        Text("\(repositoryLabel(selectedChange.repository)) · \(diffBaselineLabel(selectedChange))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("workspace-diff-source")
                    }
                } else {
                    Text("File diff")
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer(minLength: 0)
                if selectedDiff?.isText == true {
                    Text(isMonacoReady ? "Side-by-side" : "Starting editor")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace-diff-editor-status")
                        .accessibilityValue(monacoStartupDescription)
                    if isMonacoReady {
                        Text(diffHighlightStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(diffChangeCount.map { $0 > 0 ? Color.green : Color.secondary } ?? Color.secondary)
                            .accessibilityIdentifier("workspace-diff-highlight-status")
                    }
                }
                Text("READ ONLY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceTheme.windowBackground)

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)

            Group {
                if isLoadingDiff {
                    ProgressView("Loading file diff…")
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace-diff-loading")
                } else if let diffError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(diffError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .accessibilityIdentifier("workspace-diff-error")
                } else if let selectedDiff, selectedDiff.isText {
                    if let monacoError {
                        VStack(spacing: 9) {
                            Text(monacoError)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Reload editor") {
                                isMonacoReady = false
                                diffChangeCount = nil
                                self.monacoError = nil
                                // Clearing the diff first takes the shared editor out of the
                                // view tree; resetting alone can't replace a hosted NSView.
                                self.selectedDiff = nil
                                MonacoDiffWebViewHost.shared.reset()
                                if let selectedChange { openDiff(selectedChange) }
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Reload editor")
                            .font(.system(size: 11, weight: .medium))
                        }
                        .padding(24)
                    } else {
                        ZStack {
                            MonacoDiffEditor(
                                diff: selectedDiff,
                                theme: colorScheme == .dark ? "vs-dark" : "vs",
                                isReady: $isMonacoReady,
                                loadError: $monacoError,
                                diffChangeCount: $diffChangeCount,
                                presentation: $monacoPresentation
                            )
                            .accessibilityIdentifier("workspace-diff-editor")

                            if !isMonacoReady {
                                ProgressView("Starting Monaco…")
                                    .controlSize(.small)
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("workspace-diff-editor-loading")
                            }
                        }
                    }
                } else if let selectedDiff {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(selectedDiff.message ?? "This file can't be shown as a text diff.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("workspace-diff-unsupported")
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceTheme.inputBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-diff-overlay")
        .background(EscapeKeyMonitor(onEscape: closeDiff).frame(width: 0, height: 0))
    }

    private func openDiff(_ entry: WorkspaceChangeEntry) {
        selectedChange = entry
        selectedDiff = nil
        isLoadingDiff = true
        diffError = nil
        monacoError = nil
        isMonacoReady = false
        monacoPresentation = nil
        diffChangeCount = nil
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = true
        }

        Task {
            do {
                let diff = try await workspaceManager.diff(
                    for: task.id,
                    repository: entry.repository,
                    path: entry.path,
                    group: entry.group.rawValue
                )
                guard selectedChange?.id == entry.id else { return }
                selectedDiff = diff
            } catch {
                guard selectedChange?.id == entry.id else { return }
                diffError = error.localizedDescription
            }
            if selectedChange?.id == entry.id { isLoadingDiff = false }
        }
    }

    private func closeDiff() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = false
        }
    }

    private func markViewed(_ entry: WorkspaceChangeEntry) async {
        do {
            try await workspaceManager.markViewed(for: task.id, repository: entry.repository, path: entry.path)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    private func markUnviewed(_ entry: WorkspaceChangeEntry) async {
        do {
            try await workspaceManager.markUnviewed(for: task.id, repository: entry.repository, path: entry.path)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    private func markAllViewed() async {
        do {
            _ = try await workspaceManager.markAllViewed(for: task.id)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    private func refreshWorkspaceChanges() async {
        guard !isLoadingChanges else {
            changesNeedRefresh = true
            return
        }
        isLoadingChanges = true
        defer {
            isLoadingChanges = false
            hasLoadedChanges = true
        }

        repeat {
            changesNeedRefresh = false
            do {
                let inventory = try await workspaceManager.changes(for: task.id)
                changeInventory = inventory
                changesError = nil
                if let selectedChange {
                    if let current = (inventory.unviewed + inventory.viewed).first(where: { $0.id == selectedChange.id }) {
                        self.selectedChange = current
                        if isDiffPresented {
                            do {
                                let diff = try await workspaceManager.diff(
                                    for: task.id,
                                    repository: current.repository,
                                    path: current.path,
                                    group: current.group.rawValue
                                )
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = diff
                                    diffError = nil
                                }
                            } catch {
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = nil
                                    diffError = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        self.selectedChange = nil
                        selectedDiff = nil
                        diffError = "This file no longer has a Git change."
                    }
                }
            } catch {
                changesError = error.localizedDescription
            }
        } while changesNeedRefresh
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            Button(action: saveAndBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Back to Kanban")
            .accessibilityLabel("Back to Kanban board")
            .accessibilityIdentifier("back-to-board-button")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isGeneratingTitle || task.title == "Generating title…" {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityIdentifier("task-title-generating-loader")
                            Text("Generating title…")
                        }
                        .accessibilityIdentifier("task-title-generating")
                    } else {
                        Text(task.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .accessibilityIdentifier("task-view-title")
                    }

                    Spacer(minLength: 8)

                    if !task.isStandaloneChat {
                        repositoryBadges
                    }
                }

                if !task.isStandaloneChat {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(task.status.accent)
                            .frame(width: 6, height: 6)
                        Text(task.status.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(task.status == .blocked ? Color.red : Color.secondary)
                            .lineLimit(3)
                            .accessibilityIdentifier("task-status-message")
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceTheme.windowBackground.opacity(0.96))
    }

    private var repositoryBadges: some View {
        let suggestedRepositoryPaths = suggestedRepositories.map(\.path)
        let attachedRepositoryPaths = task.repositoryWorktrees.map(\.repositoryPath)
        return HStack(spacing: 10) {
            ForEach(task.repositoryWorktrees, id: \.repositoryPath) { repository in
                repositoryChip(repository)
            }
            Button {
                if isShowingRepositoryPicker { isShowingRepositoryPicker = false } else { showRepositoryPicker() }
            } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28).background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain).nativeHelp("Add a repository").accessibilityLabel("Add repository")
            .accessibilityIdentifier("add-conversation-repository-button")
            // The popover content only refreshes with this view, so key it to the suggestions it lists.
            .popover(isPresented: $isShowingRepositoryPicker, arrowEdge: .bottom) { repositoryPicker.id(suggestedRepositoryPaths + recentRepositoryPaths) }
            .disabled(isReadOnly)
        }
        .onAppear { loadRecentRepositories() }
        .onChange(of: attachedRepositoryPaths) { _, _ in loadRecentRepositories() }
    }

    private func showRepositoryPicker() {
        isShowingRepositoryPicker = true
        loadRecentRepositories()
        if suggestedRepositories.isEmpty { loadSuggestedRepositories() }
    }

    private func repositoryChip(_ repository: RepositoryWorktreeRecord) -> some View {
        let name = URL(fileURLWithPath: repository.repositoryPath).lastPathComponent
        return Button {
            repositoryBeingEdited = repository
            resetRepositoryEdits(to: repository)
            editingRepositoryField = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkspaceTheme.accent)
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 11).padding(.trailing, 14).padding(.vertical, 7)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
        }
        .buttonHoverPointer()
        .nativeHelp("Edit repository settings for \(name)")
        .buttonStyle(.plain)
        .disabled(isReadOnly)
        .popover(item: Binding(
            get: { repositoryBeingEdited?.repositoryPath == repository.repositoryPath ? RepositoryBadgeEditID(path: repository.repositoryPath) : nil },
            set: { if $0 == nil { repositoryBeingEdited = nil } }
        )) { _ in
            repositorySettingsPopover(repository, name: name)
        }
        .accessibilityIdentifier("conversation-repository-badge-\(name)")
        .overlay(alignment: .topTrailing) {
            if !isReadOnly {
                Button { removeConversationRepository(repository) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(WorkspaceTheme.panelBackground, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .nativeHelp("Remove \(name) from this task")
                .accessibilityLabel("Remove \(name)")
                .accessibilityIdentifier("remove-conversation-repository-\(name)")
                .offset(x: 6, y: -6)
            }
        }
    }

    private func repositorySettingsPopover(_ repository: RepositoryWorktreeRecord, name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name).font(.system(size: 15, weight: .semibold))
                .allowsHitTesting(false)
                .accessibilityIdentifier("conversation-repository-settings-title")
            VStack(alignment: .leading, spacing: 8) {
                repositoryDetailRow("Branch name", value: $editedBranch, field: "branch", placeholder: "auto", identifier: "conversation-repository-branch", repository: repository)
                repositoryDetailRow("Branch from", value: $editedBranchFrom, field: "from", placeholder: "default", identifier: "conversation-repository-branch-from", repository: repository)
                repositoryDetailRow("Merge to", value: $editedMergeTarget, field: "to", placeholder: "default", identifier: "conversation-repository-merge-target", repository: repository)
            }
            if !repository.isPending {
                Text("Settings are locked after the task starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("conversation-repository-settings-locked")
            }
        }
        .font(.system(size: 13))
        .padding(18)
        .frame(width: 360, alignment: .leading)
        // A click anywhere outside the field being edited dismisses the edit unsaved.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { cancelRepositoryFieldEdit(repository) }
        )
    }

    private var repositoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parentFolderURL = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) {
                HStack(spacing: 5) {
                    Text("Suggestions from \(parentFolderURL.path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .nativeHelp(parentFolderURL.path)
                    Spacer(minLength: 0)
                    Button("Change…") { chooseRepositoryParentFolder() }
                        .buttonHoverPointer()
                        .nativeHelp("Choose a different repository suggestion folder")
                        .disabled(isChoosingRepositoryParent)
                        .accessibilityIdentifier("choose-repository-suggestion-parent-button")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                Text("Choose a parent folder to find Git repositories.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Choose suggestion folder…") { chooseRepositoryParentFolder() }
                    .buttonHoverPointer()
                    .nativeHelp("Choose a folder to find repository suggestions")
                    .disabled(isChoosingRepositoryParent)
                    .accessibilityIdentifier("choose-repository-suggestion-parent-button")
            }
            TextField(repositorySearchPlaceholder, text: $repositorySearch)
                .textFieldStyle(.roundedBorder)
                .focused($isRepositorySearchFocused)
                .onChange(of: repositorySearch) { _, value in
                    repositorySuggestionIndex = 0
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        didOverrideRepositoryDefault = true
                    }
                }
                .onKeyPress { press in
                    let available = pickerRepositories
                    switch press.key {
                    case .downArrow:
                        guard !available.isEmpty else { return .ignored }
                        didOverrideRepositoryDefault = true
                        repositorySuggestionIndex = min(repositorySuggestionIndex + 1, available.count - 1)
                        return .handled
                    case .upArrow:
                        guard !available.isEmpty else { return .ignored }
                        didOverrideRepositoryDefault = true
                        repositorySuggestionIndex = max(repositorySuggestionIndex - 1, 0)
                        return .handled
                    case .return:
                        if isUsingSavedRepositoryDefault {
                            let savedRepositories = validLastSelectedRepositoryURLs
                            guard !savedRepositories.isEmpty else { return .handled }
                            selectRepositories(savedRepositories)
                        } else if available.indices.contains(repositorySuggestionIndex) {
                            selectRepositorySuggestion(available[repositorySuggestionIndex])
                        } else {
                            return .ignored
                        }
                        return .handled
                    default:
                        return .ignored
                    }
                }
                .accessibilityIdentifier("conversation-repository-search")
            let available = pickerRepositories
            let isListingRecent = isShowingRecentRepositories
            if isListingRecent {
                Text("Recent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("conversation-repository-recent-header")
            }
            if !isListingRecent, WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) == nil {
                EmptyView()
            } else if available.isEmpty {
                Text("No matching repositories.").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(available.enumerated()), id: \.element.path) { index, repository in
                            Button {
                                selectRepositorySuggestion(repository)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.lastPathComponent).font(.system(size: 11, weight: .medium))
                                    Text(repository.path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Select repository")
                            .buttonStyle(.plain)
                            .background(index == repositorySuggestionIndex ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityIdentifier("conversation-repository-\(isListingRecent ? "recent" : "suggestion")-\(repository.lastPathComponent)")
                        }
                    }
                }.frame(width: 280, height: min(CGFloat(available.count * 42), 180))
            }
        }
        .padding(12)
        .frame(width: 304)
        .defaultFocus($isRepositorySearchFocused, isNewTask)
    }

    private var repositorySearchPlaceholder: String {
        guard isNewTask, !lastSelectedRepositoryPaths.isEmpty else { return "Search repositories…" }
        let names = lastSelectedRepositoryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "\(names.joined(separator: ", ")) ↵"
    }

    private var isUsingSavedRepositoryDefault: Bool {
        isNewTask && task.repositoryWorktrees.isEmpty &&
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !didOverrideRepositoryDefault && !lastSelectedRepositoryPaths.isEmpty
    }

    private var validLastSelectedRepositoryURLs: [URL] {
        lastSelectedRepositoryPaths.compactMap { path in
            let repository = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let gitMarker = repository.appendingPathComponent(".git")
            return FileManager.default.fileExists(atPath: gitMarker.path) ? repository : nil
        }
    }

    /// Before anything is typed the picker offers recently used repositories, newest first;
    /// typing switches to searching every repository under the suggestion folder.
    private var isShowingRecentRepositories: Bool {
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recentRepositoryPaths.isEmpty
    }

    private var pickerRepositories: [URL] {
        isShowingRecentRepositories
            ? recentRepositoryPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            : availableRepositorySuggestions
    }

    private var availableRepositorySuggestions: [URL] {
        suggestedRepositories.filter { candidate in
            !task.repositoryWorktrees.contains(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == candidate.standardizedFileURL.path }) &&
            (repositorySearch.isEmpty || candidate.lastPathComponent.localizedCaseInsensitiveContains(repositorySearch) || candidate.path.localizedCaseInsensitiveContains(repositorySearch))
        }
    }

    private func selectRepositorySuggestion(_ repository: URL) {
        didOverrideRepositoryDefault = true
        selectRepositories([repository])
    }

    private func selectRepositories(
        _ repositories: [URL],
        reopenPickerOnError: Bool = true,
        isApplyingDefault: Bool = false
    ) {
        isShowingRepositoryPicker = false
        repositorySearch = ""
        if isApplyingDefault { isApplyingSavedRepositories = true }
        Task { @MainActor in
            defer {
                if isApplyingDefault { isApplyingSavedRepositories = false }
            }
            do {
                var selectedPaths = task.repositoryWorktrees.map { $0.repositoryPath }
                var repositoriesToAdd: [String] = []
                let manager = BoardTaskManager(modelContext: modelContext)
                for repository in repositories {
                    let path = repository.standardizedFileURL.path
                    guard !selectedPaths.contains(path) else { continue }
                    selectedPaths.append(path)
                    repositoriesToAdd.append(path)
                }
                if !repositoriesToAdd.isEmpty {
                    _ = try await manager.addRepositories(task.id, repositoryPaths: repositoriesToAdd)
                }
                let availablePaths = selectedPaths.filter { path in
                    FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
                }
                try WorkspaceSettingsManager().setLastSelectedRepositories(availablePaths)
                loadRecentRepositories()
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't add repository: \(error.localizedDescription)"
                isShowingRepositoryPicker = reopenPickerOnError
            }
        }
    }

    private func loadRecentRepositories() {
        guard !task.isStandaloneChat else { return }
        recentRepositoryPaths = (try? WorkspaceManager(
            taskManager: BoardTaskManager(modelContext: modelContext)
        ).recentRepositorySuggestions(for: task.id)) ?? []
    }

    private func loadSuggestedRepositories() {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) else { return }
        Task {
            suggestedRepositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parent.path).map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }) ?? []
        }
    }

    private func chooseRepositoryParentFolder(showRepositoryPickerWhenFinished: Bool = true) {
        guard !isChoosingRepositoryParent else { return }
        isShowingRepositoryPicker = false
        let panel = NSOpenPanel()
        panel.title = "Choose repository root folder"
        panel.message = "Playhouse will search below this folder for repositories. A root folder is required before sending conversations."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        isChoosingRepositoryParent = true
        panel.begin { response in
            DispatchQueue.main.async {
                isChoosingRepositoryParent = false
                guard response == .OK, let selected = panel.url else {
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                    return
                }
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                    loadSuggestedRepositories()
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                } catch {
                    errorMessage = "Couldn't set the repository suggestion folder: \(error.localizedDescription)"
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                }
            }
        }
    }

    private var safetyNotice: some View {
        let additionalFolders = workspaceRootURLs.filter { url in
            !task.repositoryWorktrees.contains {
                URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == url.path
            }
        }
        return Group {
            if !additionalFolders.isEmpty {
                let folderLabels = additionalFolders.map(\.lastPathComponent)
                let folderSummary = "Working in: " + folderLabels.joined(separator: " · ")
                let fullFolderSummary = "Working in: " + additionalFolders.map(\.path).joined(separator: " · ")
                Text(folderSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fullFolderSummary)
                    .accessibilityIdentifier("working-folders-summary")
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }
        }
    }

    /// What every row of one transcript pass shares, worked out once for the pass.
    private struct TranscriptRowContext {
        let inlineTools: [String: [ConversationActivity]]
        /// The message the activity disclosure sits above, or nil when it is not shown above one.
        let activityDisclosureAnchorID: String?
        let latestTurnStartID: String?
        let conversationMessages: [ConversationMessage]
    }

    /// One message of the rendered window with the rows anchored to it: its
    /// page separator and activity disclosure above, and the boundaries, goal
    /// achievements, tool calls, and compactions that follow it.
    @ViewBuilder
    private func transcriptRows(for message: ConversationMessage, context: TranscriptRowContext) -> some View {
        if let page = standaloneChatPageSeparator(before: message) {
            standaloneChatPageSeparator(page)
                .id("chat-page-separator-\(page.id)-\(message.id)")
        }
        if message.id == context.activityDisclosureAnchorID {
            activityList
        }
        transcriptEntry(message)
            .id(message.id)
            // The question itself starts the newest turn, below any page
            // separator, so a pin lands on the bubble.
            .layoutValue(key: ConversationLatestTurnStartKey.self, value: message.id == context.latestTurnStartID)
        ForEach(providerBoundaries.filter {
            renderedAnchorMessageID(for: boundaryAnchorID(for: $0)) == message.id
        }) { boundary in
            providerBoundaryRow(boundary)
        }
        ForEach(goalAchievementTimelineEntries.filter {
            renderedAnchorMessageID(for: goalAchievementAnchorMessageID(for: $0)) == message.id
        }) { entry in
            goalAchievementTimelineRow(entry)
                .id(entry.id)
        }
        ForEach(context.inlineTools[message.id] ?? []) { activity in
            if let pageID = activity.recalledChatPageID {
                ChatPageRecallRow(activityID: activity.id, pageID: pageID)
            } else {
                ToolCallTimelineRow(activity: activity)
            }
        }
        let nextOrder = context.conversationMessages.first(where: {
            guard let current = message.timelineOrder, let candidate = $0.timelineOrder else { return false }
            return candidate > current
        })?.timelineOrder
        ForEach(activities.filter {
            guard $0.isContextCompaction, let eventOrder = $0.timelineOrder,
                  let messageOrder = message.timelineOrder, eventOrder > messageOrder else { return false }
            return nextOrder.map { eventOrder < $0 } ?? true
        }) { activity in
            contextCompactionTimelineRow(activity)
        }
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll runway above the rendered window. It keeps an
                    // upward drag available even when the latest turn alone is
                    // shorter than the viewport, and it is replaced by the
                    // earlier messages as soon as they are revealed.
                    if hasOlderConversationMessages {
                        Color.clear
                            .frame(height: viewport.size.height)
                            .accessibilityHidden(true)
                        // Scroll position is only observable from macOS 15 on,
                        // so older systems keep an explicit control rather than
                        // an upward drag that cannot be detected.
                        if #unavailable(macOS 15) {
                            Button("Load earlier messages") {
                                revealOlderConversationMessages(using: scrollProxy)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .buttonHoverPointer()
                            .nativeHelp("Load 40 earlier messages.")
                            .accessibilityIdentifier("conversation-load-older-button")
                        }
                    }
                    // Tracks how far the top of the rendered window sits below
                    // the top of the viewport, which is how an upward scroll is
                    // detected.
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ConversationTopMarkerPositionKey.self,
                            value: geometry.frame(in: .named(Self.conversationScrollCoordinateSpace)).minY
                        )
                    }
                    .frame(height: 0)

                // One stack for the whole rendered window, so rows keep their
                // identity, and with it their state, as a newer question moves
                // the start of the newest turn past them. The layout reserves
                // the filler below the newest turn itself: from its question to
                // the end of the transcript it is at least a viewport tall, less
                // the bottom padding and end marker already below it, which lets
                // a turn shorter than the viewport be pinned to the top, and
                // makes that pin exactly the bottom, which following starts
                // from. The runway above the window does the same for the other
                // end. Sizing the filler from measurements instead, which
                // SwiftUI reports a pass later, left it stale and opened blank
                // overscroll below the transcript.
                let leadingGoalEntries = goalAchievementTimelineEntries.filter { goalAchievementAnchorMessageID(for: $0) == nil }
                // Worked out once per pass rather than once per row: each walks the whole transcript, and
                // every row of it is rebuilt whenever the transcript's width changes, as while resizing the chat.
                let rowContext = TranscriptRowContext(
                    inlineTools: inlineToolCalls.byMessageID,
                    activityDisclosureAnchorID: shouldShowActivityDisclosure ? activityDisclosureAnchorID : nil,
                    latestTurnStartID: latestConversationTurnStartID,
                    conversationMessages: conversationMessages
                )
                ConversationTranscriptLayout(
                    spacing: 16,
                    minimumLatestTurnHeight: max(0, viewport.size.height - Self.conversationVerticalPadding - Self.conversationScrollEndHeight)
                ) {
                    if messages.isEmpty && activeGoal?.status != "complete" && !isLoadingHistory {
                        VStack(spacing: 0) {
                            if task.isStandaloneChat {
                                // A chat has no repository to name, so the placeholder keeps only
                                // its prompt. The leading spacer balances the trailing one that
                                // the title would otherwise have pushed against.
                                Spacer(minLength: 0)
                            } else {
                                Text(emptyConversationRepositoryTitle)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(emptyConversationRepositoryTitleColor)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .accessibilityLabel(emptyConversationRepositoryTitle)
                                    .accessibilityIdentifier("empty-conversation-repository-title")
                                Spacer(minLength: 58)
                            }
                            VStack(spacing: 14) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 29, weight: .regular))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                    .accessibilityLabel("Conversation")
                                Text("Send a message to \(provider.assistantLabel(modelName: promptModelName)).")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Send a message to \(provider.assistantLabel(modelName: promptModelName)).")
                                    .accessibilityIdentifier("model-prompt")
                            }
                            Spacer(minLength: 28)
                        }
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 38)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("empty-conversation")
                    } else if !messages.isEmpty {
                        // A plain stack: a LazyVStack of these AppKit-backed rows could keep
                        // re-estimating its rows after a send and never finish layout. At most
                        // a recent window of messages renders, and older batches load on demand.
                        ForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                        ForEach(providerBoundaries.filter { $0.afterMessageID == nil }) { boundary in
                            providerBoundaryRow(boundary)
                        }
                        ForEach(renderedConversationMessages) { message in
                            transcriptRows(for: message, context: rowContext)
                        }
                        ForEach(liveChatPageRecalls) { activity in
                            if let pageID = activity.recalledChatPageID {
                                ChatPageRecallRow(activityID: activity.id, pageID: pageID)
                            }
                        }
                        if shouldShowActivityDisclosure, activityDisclosureAnchorID == nil {
                            activityList
                        }
                    }

                    if messages.isEmpty && shouldShowActivityDisclosure {
                        activityList
                    }
                    if messages.isEmpty {
                        ForEach(providerBoundaries) { boundary in
                            providerBoundaryRow(boundary)
                        }
                    }
                    if messages.isEmpty {
                        ForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                    }
                    if let request = userInputRequest, request.threadID == task.activeConversationID {
                        userInputForm(request)
                            .frame(maxWidth: 620, alignment: .leading)
                            .accessibilityIdentifier("conversation-user-input-request")
                    }

                    if let activeProcess {
                        activityRow(activeProcess, compact: true)
                    }
                    ForEach(activeSubagents) { activity in
                        subagentTimelineRow(activity)
                    }
                    ForEach(activities.filter { $0.isContextCompaction && $0.timelineOrder == nil }) { activity in
                        contextCompactionTimelineRow(activity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-latest-anchor")
                    // Spans the newest turn at its natural height, which only
                    // "does the newest turn fit the viewport?" is asked of.
                    Color.clear
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationLatestTurnHeightKey.self,
                                    value: geometry.size.height
                                )
                            }
                        }
                        .accessibilityHidden(true)
                        .layoutValue(key: ConversationLatestTurnExtentKey.self, value: true)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, Self.conversationVerticalPadding)
                // A window that holds older messages back needs the runway's
                // counterpart below even when no turn of its own is rendered.
                .frame(
                    minHeight: hasOlderConversationMessages
                        ? max(0, viewport.size.height - Self.conversationScrollEndHeight)
                        : nil,
                    alignment: .top
                )
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                // The very end of the scroll content, filler included, which is
                // where following new content keeps the viewport. Unlike
                // `scrollToLatest`, following can target it: a scroll that
                // lands short of the real end changes the scroll extent again,
                // and that change is followed once more.
                Color.clear
                    .frame(height: Self.conversationScrollEndHeight)
                    .id(Self.conversationScrollEndID)
                    .accessibilityHidden(true)
                }
                .background {
                    // The scroll observer reports this geometry from macOS 15
                    // on; before that the content's own frame in the scroll's
                    // space carries it.
                    if #unavailable(macOS 15) {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(Self.conversationScrollCoordinateSpace))
                            Color.clear.preference(
                                key: ConversationScrollGeometryKey.self,
                                value: ConversationScrollGeometry(
                                    offsetY: -frame.minY,
                                    contentHeight: frame.height,
                                    maxOffsetY: frame.height - viewport.size.height
                                )
                            )
                        }
                    }
                }
            }
            .coordinateSpace(name: Self.conversationScrollCoordinateSpace)
            .scrollIndicators(.visible)
            .accessibilityIdentifier("conversation-scroll-view")
            .accessibilityValue("Showing latest \(renderedConversationMessages.count) of \(conversationMessages.count + earlierStoredMessageCount) messages")
            .onPreferenceChange(ConversationTopMarkerPositionKey.self) { markerY in
                // Exactly one source drives the reveal: the scroll observer
                // where it exists, this marker where it does not.
                if #unavailable(macOS 15) {
                    handleConversationWindowTop(markerY, using: scrollProxy)
                }
            }
            .onPreferenceChange(ConversationScrollGeometryKey.self) { geometry in
                guard let geometry else { return }
                let old = lastConversationScrollSample.geometry ?? geometry
                lastConversationScrollSample.geometry = geometry
                followConversationBottom(from: old, to: geometry, using: scrollProxy)
            }
            .modifier(ConversationScrollOffsetObserver { old, new in
                lastConversationScrollSample.viewportHeight = viewport.size.height
                followConversationBottom(from: old, to: new, using: scrollProxy)
                guard lastConversationScrollSample.offsetY != new.offsetY else { return }
                lastConversationScrollSample.offsetY = new.offsetY
                handleConversationWindowTop(
                    conversationWindowTopY(offsetY: new.offsetY, viewportHeight: viewport.size.height),
                    using: scrollProxy
                )
            })
            .onPreferenceChange(ConversationLatestTurnHeightKey.self) { height in
                // Only "shorter than the viewport?" is ever asked of this value,
                // and publishing each revision re-renders the whole transcript,
                // so cap it once the turn overflows.
                let clamped = min(height, viewport.size.height + 1)
                if clamped != latestTurnContentHeight { latestTurnContentHeight = clamped }
            }
            .onChange(of: isLoadingHistory) { _, isLoading in
                // Every completed history load reopens on the newest turn,
                // including reloads that leave the messages unchanged.
                guard !isLoading else { return }
                presentLatestConversationTurn(using: scrollProxy)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToLatestUserMessage(using: scrollProxy, viewportHeight: viewport.size.height)
            }
            .onChange(of: messages.map(\.text)) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: activities) { _, _ in
                if isResponding && !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: isResponding) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: activeGoal?.status) { _, status in
                if status == "complete" && !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: goalAchievementTimelineEntries.count) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: userInputRequest?.id) { _, requestID in
                // The question form sits below the latest message; bring it into view
                // whether it arrives with the history or later from the daemon.
                guard requestID != nil else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                    }
                    // The form's rows are placed from estimates until realized, so the first
                    // scroll can stop short of Submit; scroll again once they are.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    for delay in Self.scrollSettleDelays {
                        try? await Task.sleep(nanoseconds: delay)
                        withTransaction(transaction) { scrollProxy.scrollTo("conversation-latest-anchor", anchor: .bottom) }
                    }
                }
            }
            }
        }
    }

    private static let conversationScrollCoordinateSpace = "conversation-transcript-scroll"
    private static let conversationScrollEndID = "conversation-scroll-end"
    private static let conversationScrollEndHeight: CGFloat = 1
    private static let conversationVerticalPadding: CGFloat = 24

    private var emptyConversationRepositoryTitle: String {
        var repositoryNames = task.repositoryWorktrees.map {
            URL(fileURLWithPath: $0.repositoryPath).lastPathComponent
        }
        if repositoryNames.isEmpty {
            repositoryNames = task.workspaceRootPaths.compactMap { path in
                let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
                let gitMarker = repositoryURL.appendingPathComponent(".git")
                guard FileManager.default.fileExists(atPath: gitMarker.path) else { return nil }
                return repositoryURL.lastPathComponent
            }
        }
        return repositoryNames.isEmpty ? "No repository selected" : repositoryNames.joined(separator: " · ")
    }

    private var emptyConversationRepositoryTitleColor: Color {
        colorScheme == .dark
            ? .orange
            : Color(red: 0.18, green: 0.31, blue: 0.68)
    }

    private var activeSubagents: [ConversationActivity] {
        activities.filter { $0.isSubagent && $0.isActive }
    }

    /// Earlier turns' tool calls, keyed by the message each followed. The latest turn shows its
    /// calls in Working for instead, and folds them into Worked for once it finishes.
    private var inlineToolCalls: (byMessageID: [String: [ConversationActivity]], ids: Set<String>) {
        guard !timelineActivities.isEmpty else { return ([:], []) }
        var turnByMessageID: [String: String] = [:]
        for message in messages { if let turnID = message.turnID { turnByMessageID[message.id] = turnID } }
        let latestTurnID = latestConversationTurnID
        var byMessageID: [String: [ConversationActivity]] = [:]
        var ids = Set<String>()
        for activity in timelineActivities where activity.isTimelineToolCall {
            guard let anchor = activity.afterMessageID, let turnID = turnByMessageID[anchor],
                  turnID != latestTurnID, ids.insert(activity.id).inserted else { continue }
            byMessageID[anchor, default: []].append(activity)
        }
        return (byMessageID, ids)
    }

    /// The standalone chat's page recalls in the latest turn. They render as their own lines the
    /// moment the call is seen instead of waiting inside the collapsed work disclosure.
    private var liveChatPageRecalls: [ConversationActivity] {
        guard task.isStandaloneChat else { return [] }
        let inlineIDs = inlineToolCalls.ids
        return activities.filter { $0.recalledChatPageID != nil && !inlineIDs.contains($0.id) }
    }

    /// Keep the latest live non-agent operation in the conversation timeline.
    /// Earlier live operations remain available in the expanded activity list.
    private var activeProcess: ConversationActivity? {
        activities
            .filter { !$0.isSubagent && !$0.isContextCompaction && $0.isActive && $0.recalledChatPageID == nil }
            .enumerated()
            .max { left, right in
                let leftOrder = left.element.timelineOrder ?? left.offset
                let rightOrder = right.element.timelineOrder ?? right.offset
                return leftOrder < rightOrder
            }?
            .element
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isActivityExpanded.toggle()
                }
            } label: {
                activityDisclosureButtonLabel
            }
            .buttonHoverPointer()
            .nativeHelp("Show or hide Codex activity details")
            .buttonStyle(.plain)
            .accessibilityValue(isActivityExpanded ? "Expanded, down chevron" : "Collapsed, right chevron")
            .accessibilityHint("Shows Codex progress messages and completed activity details.")
            .accessibilityIdentifier("codex-activity-disclosure")


            Divider()
                .opacity(0.32)
                .accessibilityElement()
                .accessibilityLabel("Separator between work duration and response")

            if isActivityExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if !progressMessages.isEmpty {
                        Text("Progress")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(progressMessages) { message in
                            assistantMarkdownContent(Self.displayableAssistantText(message.text))
                                .font(.system(size: 12))
                                .foregroundStyle(WorkspaceTheme.conversationText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("codex-progress-message-\(message.id)")
                        }
                    }
                    let activeIDsOutside = Set(activeSubagents.map(\.id) + [activeProcess?.id].compactMap { $0 })
                        .union(inlineToolCalls.ids)
                    ForEach(activities.filter {
                        !$0.isSubagent && !$0.isContextCompaction && !activeIDsOutside.contains($0.id)
                            && !(task.isStandaloneChat && $0.recalledChatPageID != nil)
                    }) { activity in
                        activityRow(activity)
                    }
                    let agentActivities = activities.filter(\.isSubagent)
                    let completedAgentActivities = agentActivities.filter { !$0.isActive }
                    if !completedAgentActivities.isEmpty {
                        Text("Agents used")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(completedAgentActivities) { activity in
                            subagentTimelineRow(activity)
                        }
                    }
                }
                .padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("codex-activity-details")
            }
        }
    }

    private func goalAchievementTimelineRow(_ entry: GoalAchievementTimelineEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            Text(entry.summary)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("goal-achieved-banner")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal-achievement-timeline-row")
    }

    /// A message as the transcript shows it. A background agent's report is the agent's work, not
    /// the parent's reply, so it gets the agent's row, which opens the report, instead of a bubble.
    @ViewBuilder
    private func transcriptEntry(_ message: ConversationMessage) -> some View {
        let reportPrefix = ConversationTranscriptStore.backgroundAgentReportMessagePrefix
        if message.role == .assistant, message.phase == "subagent_report", message.id.hasPrefix(reportPrefix) {
            let agentID = String(message.id.dropFirst(reportPrefix.count))
            subagentTimelineRow(
                agentReportActivity(agentID: agentID, report: message.text),
                identifier: "agent-report-row-\(agentID)"
            )
        } else {
            messageBubble(message)
        }
    }

    /// The agent a report belongs to, carrying the report the agent window shows. A report whose
    /// activity isn't loaded still opens, under a generic name.
    private func agentReportActivity(agentID: String, report: String) -> ConversationActivity {
        var activity = activities.first { $0.childThreadID == agentID || $0.id == agentID }
            ?? ConversationActivity(id: agentID, title: "Background agent", detail: report, status: "completed", childThreadID: agentID)
        activity.detail = report
        return activity
    }

    private func subagentTimelineRow(_ activity: ConversationActivity, identifier: String? = nil) -> some View {
        // The icon sits beside the button, not in its label, because a macOS
        // button folds its label into one accessible element and the icon must
        // stay a distinct image.
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Color.clear.frame(width: 20, height: 5).accessibilityHidden(true)
                Image("SubagentIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { openSubagent(activity) }
                    .accessibilityLabel("\(activity.title) agent icon")
            }
            Button {
                openSubagent(activity)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(activity.title) \(activity.timelineStatus)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let metadata = [activity.agentPath, activity.model, activity.reasoningEffort]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                    if let duration = activity.durationLabel() {
                        Text(duration)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
            .buttonHoverPointer()
            .nativeHelp("Open the read-only conversation for this agent")
            .buttonStyle(.plain)
            // Beside the button, like the icon, so it stays its own element.
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 30)
                .contentShape(Rectangle())
                .onTapGesture { openSubagent(activity) }
                .accessibilityLabel("Open \(activity.title)")
                .accessibilityIdentifier("subagent-row-chevron")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.title) \(activity.timelineStatus)")
        .accessibilityValue([activity.detail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier(identifier ?? "codex-subagent-row-\(activity.childThreadID ?? activity.id)")
    }

    @ViewBuilder
    private func activityRow(_ activity: ConversationActivity, compact: Bool = false) -> some View {
        let displayDetail = [activity.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if compact {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                if !displayDetail.isEmpty {
                    Text(displayDetail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                        .accessibilityLabel(displayDetail)
                } else {
                    Spacer(minLength: 0)
                }
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if activity.isActive, activity.startedAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let duration = activity.durationLabel(at: timeline.date) ?? ""
                        Text(duration)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityValue(duration)
                            .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
            .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityIdentifier("codex-activity-row-\(activity.id)")
        } else {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !displayDetail.isEmpty {
                Text(displayDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                    .accessibilityLabel(displayDetail)
            }
            if activity.isActive, activity.startedAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let duration = activity.durationLabel(at: timeline.date) ?? ""
                    Text(duration)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityValue(duration)
                        .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
                }
            } else if let duration = activity.durationLabel() {
                Text(duration)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityValue(duration)
                    .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
            } else {
                Text("Duration unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityValue("Duration unavailable")
                    .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
        .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier(activity.isSubagent ? "codex-subagent-row-\(activity.childThreadID ?? activity.id)" : "codex-activity-row-\(activity.id)")
        }
    }

    private func contextCompactionTimelineRow(_ activity: ConversationActivity) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.status == "inProgress" ? "Compacting context…" : "Context compacted")
                    .font(.system(size: 12, weight: .medium))
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .accessibilityIdentifier("context-compaction-summary-\(activity.id)")
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context compaction, \(activity.statusLabel)")
        .accessibilityValue(activity.statusLabel)
        .accessibilityIdentifier("context-compaction-row-\(activity.id)")
    }

    /// A boundary after a message that later folded into the activity list
    /// anchors to the nearest visible message instead.
    private func boundaryAnchorID(for boundary: ConversationProviderBoundary) -> String? {
        guard let afterMessageID = boundary.afterMessageID else { return nil }
        if conversationMessages.contains(where: { $0.id == afterMessageID }) { return afterMessageID }
        guard let index = messages.firstIndex(where: { $0.id == afterMessageID }) else { return conversationMessages.last?.id }
        let visible = Set(conversationMessages.map(\.id))
        return messages[...index].last(where: { visible.contains($0.id) })?.id
    }

    private func providerBoundaryRow(_ boundary: ConversationProviderBoundary) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            Text("Conversation switched to \(boundary.provider.displayName)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Conversation switched to \(boundary.provider.displayName)")
                .accessibilityIdentifier("provider-boundary-\(boundary.provider.rawValue)")
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .id(boundary.id)
    }

    private func openSubagent(_ activity: ConversationActivity) {
        selectedSubagent = activity
        subagentHistory = nil
        subagentError = nil
        isLoadingSubagent = true
        guard activity.childThreadID != nil else { return }
        Task { @MainActor in
            do {
                subagentHistory = try await conversationManager.subagentHistory(taskID: task.id, activity: activity)
            } catch {
                subagentError = "Couldn't load this agent conversation: \(error.localizedDescription)"
            }
            isLoadingSubagent = false
        }
    }

    private func subagentConversation(_ activity: ConversationActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    selectedSubagent = nil
                    subagentHistory = nil
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
                .buttonHoverPointer()
                .nativeHelp("Return to the parent conversation")
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagent-back-button")
                Text(activity.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Read only").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if isLoadingSubagent {
                ProgressView("Loading agent conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let subagentError {
                Text(subagentError).foregroundStyle(.secondary).padding(24)
            } else if let subagentHistory {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(subagentHistory.messages) { message in messageBubble(message) }
                        if subagentHistory.messages.isEmpty {
                            Text("No conversation content is available yet.").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("subagent-conversation-scroll-view")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-conversation-panel")
    }

    @ViewBuilder
    private var activityDisclosureButtonLabel: some View {
        if isDisplayingActiveResponse, let responseStartedAt {
            TimelineView(.periodic(from: responseStartedAt, by: 1)) { timeline in
                activityDisclosureContents(
                    workingFor: Self.durationLabel(Self.elapsedSeconds(since: responseStartedAt, now: timeline.date))
                )
            }
        } else {
            activityDisclosureContents(
                workedFor: completedResponseDuration.map(Self.durationLabel) ?? (hasCompletedAssistantResponse ? "" : nil)
            )
        }
    }

    private func activityDisclosureContents(workingFor: String? = nil, workedFor: String? = nil) -> some View {
        return HStack(spacing: 7) {
            if let workingFor {
                Text("Working for \(workingFor)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("codex-working-duration")
            } else if let workedFor {
                Text(workedFor.isEmpty ? "Worked for" : "Worked for \(workedFor)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-worked-duration")
            } else {
                Text("Codex activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: isActivityExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityIdentifier("codex-activity-chevron")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // After the frame, so the whole row the button spans takes the click.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func messageBubble(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .assistant {
                if message.asyncQuestions == nil &&
                    Self.displayableAssistantText(message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResponding {
                    EmptyView()
                } else if message.asyncQuestions != nil {
                    asyncQuestionBubble(message)
                } else {
                    assistantBubble(message)
                }
                Spacer(minLength: 70)
            } else {
                Spacer(minLength: 70)
                userBubble(message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func asyncQuestionKey(messageID: String, index: Int) -> String {
        "\(messageID):\(index)"
    }

    private func asyncQuestionWasAnswered(_ message: ConversationMessage) -> Bool {
        answeredAsyncQuestionIDs.contains(message.id)
            || queuedMessages.contains { $0.asyncQuestionItemID == message.id }
    }

    private func asyncQuestionBubble(_ message: ConversationMessage) -> some View {
        let questions = message.asyncQuestions ?? []
        let answered = asyncQuestionWasAnswered(message)
        return VStack(alignment: .leading, spacing: 12) {
            Text(assistantLabel(for: message))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                let answerKey = asyncQuestionKey(messageID: message.id, index: index)
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let options = question.options, !options.isEmpty {
                        if !answered && !isReadOnly {
                            ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                                Button {
                                    asyncQuestionAnswers[answerKey] = option
                                } label: {
                                    Label(option, systemImage: asyncQuestionAnswers[answerKey] == option ? "largecircle.fill.circle" : "circle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Choose this answer for \(question.title)")
                                .accessibilityIdentifier("async-question-option-\(message.id)-\(index)-\(optionIndex)")
                            }
                            TextField("Other answer", text: Binding(
                                get: {
                                    let answer = asyncQuestionAnswers[answerKey] ?? ""
                                    return options.contains(answer) ? "" : answer
                                },
                                set: { asyncQuestionAnswers[answerKey] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("async-question-other-\(message.id)-\(index)")
                        } else {
                            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                Text(option).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    } else if !answered && !isReadOnly {
                        TextField("Your answer", text: Binding(
                                get: { asyncQuestionAnswers[answerKey] ?? "" },
                                set: { asyncQuestionAnswers[answerKey] = $0 }
                            ))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("async-question-answer-\(message.id)-\(index)")
                    }
                }
            }
            if answered {
                Text(answeredAsyncQuestionIDs.contains(message.id) ? "Answered" : "Pending")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !isReadOnly {
                Button("Send answers") { submitAsyncQuestions(message) }
                    .buttonStyle(.borderedProminent)
                    .buttonHoverPointer()
                    .nativeHelp("Send your answers to \(provider.displayName)")
                    .disabled(isSubmittingLiveMessage || isLoadingHistory || questions.enumerated().contains { index, _ in
                        let key = asyncQuestionKey(messageID: message.id, index: index)
                        return (asyncQuestionAnswers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                    .accessibilityIdentifier("submit-async-questions-\(message.id)")
            }
        }
        .padding(15)
        .frame(maxWidth: 620, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("async-question-\(message.id)")
    }

    private func submitAsyncQuestions(_ message: ConversationMessage) {
        guard let questions = message.asyncQuestions, !questions.isEmpty else { return }
        let answers = questions.indices.map { asyncQuestionAnswers[asyncQuestionKey(messageID: message.id, index: $0)] ?? "" }
        let priorAssistantMessages = Dictionary(
            uniqueKeysWithValues: messages
                .filter { $0.role == .assistant }
                .map { ($0.id, $0.text) }
        )
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let result = try await conversationManager.answerAsyncQuestion(taskID: task.id, question: message, answers: answers)
                if !result.queued { answeredAsyncQuestionIDs.insert(message.id) }
                if let history = result.history {
                    applyHistoryMessages(history)
                    activities = history.activities
                    answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                } else if result.queued {
                    refreshQueuedMessages()
                } else {
                    var settledHistory: ConversationHistory?
                    for _ in 0..<50 {
                        if let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize),
                           history.messages.contains(where: { candidate in
                               candidate.role == .assistant &&
                               candidate.asyncQuestions == nil &&
                               !candidate.text.isEmpty &&
                               priorAssistantMessages[candidate.id] != candidate.text
                           }) {
                            settledHistory = history
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if let settledHistory {
                        applyHistoryMessages(settledHistory)
                        activities = settledHistory.activities
                        answeredAsyncQuestionIDs = Set(settledHistory.answeredAsyncQuestionIDs)
                    } else {
                        messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: result.text))
                    }
                }
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func assistantBubble(_ message: ConversationMessage) -> some View {
        let displayText = Self.displayableAssistantText(message.text)
        let accessibilityText = displayText.count <= 1_000 && !displayText.isEmpty
            ? displayText
            : "Response from \((message.provider ?? provider).displayName)"
        let responseAnnotations = responseAnnotationReferences(for: message)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("message-time-\(message.id)")
                }
                Text(assistantLabel(for: message))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant-provider-\(message.id)")
            }

            ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                if let image = Self.image(fromDataURL: dataURL) {
                    Button { selectedChatImage = image } label: {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open attached image")
                    .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                    .buttonHoverPointer()
                    .nativeHelp("Open image at full size")
                }
            }
            if !displayText.isEmpty {
                assistantMarkdownContent(displayText, messageID: message.id, responseAnnotations: responseAnnotations)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(WorkspaceTheme.conversationText)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityIdentifier("assistant-message-\(message.id)")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func userBubble(_ message: ConversationMessage) -> some View {
        let accessibleText = Self.displayableUserText(message.text)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                    if let image = Self.image(fromDataURL: dataURL) {
                        Button { selectedChatImage = image } label: {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open attached image")
                        .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                        .buttonHoverPointer()
                        .nativeHelp("Open image at full size")
                    }
                }
                let visibleText = Self.displayableUserText(message.text)
                if !visibleText.isEmpty {
                    SelectableAnnotationText(
                        text: visibleText,
                        highlightedRanges: annotations.filter { $0.messageID == message.id && $0.blockID == 0 }.map {
                            NSRange(location: $0.startOffset, length: $0.endOffset - $0.startOffset)
                        },
                        textColor: .labelColor,
                        onSelection: { range, selectedText, bounds in
                            currentTextSelection = selectedText.isEmpty ? nil : AnnotationSelection(
                                messageID: message.id, anchorID: 0, blockID: 0, startOffset: range.location,
                                endBlockID: 0, endOffset: NSMaxRange(range), text: selectedText, bounds: bounds
                            )
                        }
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        // Anchored on the text like assistant blocks; as a ZStack sibling of the
                        // bubble the hint's popover ignored clicks on its controls.
                        .overlay(alignment: .topLeading) {
                            selectionHint(messageID: message.id, anchorID: 0)
                                .offset(y: -16)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        // The border is part of the background so the selection hint above stays clickable.
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(WorkspaceTheme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                                )
                        }
                }
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("message-time-\(message.id)")
                }
            }
            .frame(maxWidth: 620, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibleText.isEmpty ? "Attached image" : accessibleText)
            .accessibilityIdentifier("user-message-\(message.id)")
        }
    }

    private static func markdownAttributedText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }

    /// Every transcript body re-evaluation re-renders each assistant block, so parsed Markdown is
    /// memoized by its exact inputs instead of being re-parsed for an unchanged block.
    /// Bounded because a streaming block adds a key for every partial text it passes through.
    private static let markdownPlainTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    private static let markdownNSAttributedStringCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 500
        return cache
    }()

    private static func markdownPlainText(_ markdown: String) -> String {
        if let cached = markdownPlainTextCache.object(forKey: markdown as NSString) {
            return cached as String
        }
        let text = String(Self.markdownAttributedText(markdown).characters)
        markdownPlainTextCache.setObject(text as NSString, forKey: markdown as NSString)
        return text
    }

    /// Bridges Markdown-parsed text to `NSAttributedString`, resizing inline code/bold/italic
    /// runs to `baseFont`'s point size (preserving their monospace/bold/italic traits) instead of
    /// the parser's own default-size font, so inline formatting matches the surrounding body text.
    fileprivate static func markdownNSAttributedString(_ markdown: String, baseFont: NSFont) -> NSAttributedString {
        let cacheKey = "\(baseFont.fontName)|\(baseFont.pointSize)|\(markdown)" as NSString
        if let cached = markdownNSAttributedStringCache.object(forKey: cacheKey) {
            return cached
        }
        let attributed = Self.markdownAttributedText(markdown)
        // Fonts are applied on the NSAttributedString because NSFont is not Sendable,
        // which AttributedString's AppKit font attribute requires.
        let result = NSMutableAttributedString(attributed)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let font: NSFont
            if intent.contains(.code) {
                // Slightly smaller than the prose, which a monospaced face reads larger than.
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                InlineCodeStyle.apply(to: result, range: NSRange(run.range, in: attributed))
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                guard !traits.isEmpty else { continue }
                font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
            }
            result.addAttribute(.font, value: font, range: NSRange(run.range, in: attributed))
        }
        markdownNSAttributedStringCache.setObject(result, forKey: cacheKey)
        return result
    }

    private static func displayableAssistantText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayableUserText(_ text: String) -> String {
        let commentEnvelopeStart = text.range(of: "<playhouse-comment-context>")
            ?? text.range(of: "<playhouse-annotation-context>")
        let commentEnvelopeEnd = commentEnvelopeStart.flatMap { envelope in
            text.range(of: "</playhouse-comment-context>", range: envelope.upperBound..<text.endIndex)
                ?? text.range(of: "</playhouse-annotation-context>", range: envelope.upperBound..<text.endIndex)
        }
        if let envelope = commentEnvelopeStart, commentEnvelopeEnd != nil,
           Self.containsSerializedAnnotations(text) {
            return String(text[..<envelope.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let legacyHeader = "# Response annotations:\nThe following JSON contains comments on selected conversation text, in array order."
        if let header = text.range(of: legacyHeader), Self.containsSerializedAnnotations(text) {
            return String(text[..<header.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let commentHeader = "# Response comments:\nThe following JSON contains comments on selected conversation text, in array order."
        if let header = text.range(of: commentHeader), Self.containsSerializedAnnotations(text) {
            return String(text[..<header.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func containsSerializedAnnotations(_ text: String) -> Bool {
        let start = text.range(of: "<response-comments>") ?? text.range(of: "<response-annotations>")
        guard let start,
              let end = text.range(of: "</response-comments>", range: start.upperBound..<text.endIndex)
                ?? text.range(of: "</response-annotations>", range: start.upperBound..<text.endIndex),
              let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !items.isEmpty else { return false }
        return items.allSatisfy { item in
            guard item["text"] is String, (item["comment"] is String || item["annotation"] is String),
                  let source = item["source"] as? [String: Any] else { return false }
            return source["messageId"] is String && source["blockID"] is Int
                && source["startOffset"] is Int && source["endOffset"] is Int
        }
    }

    private func selectionHint(messageID: String, anchorID: Int) -> some View {
        Group {
            if let selection = currentTextSelection,
               selection.messageID == messageID, selection.anchorID == anchorID {
                GeometryReader { geometry in
                    Button {
                        annotationSelection = selection
                        annotationComment = ""
                    } label: {
                        Text("Add comment")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .nativeHelp("Add comment to selected text")
                    .accessibilityIdentifier("add-comment-to-selection-button")
                    .frame(width: 112, height: 30)
                    // Attached to the hint itself: after `.position`, the view fills the whole
                    // text block, and the popover opened at the block's top edge, away from the hint.
                    .popover(isPresented: Binding(
                        get: { annotationSelection?.id == selection.id },
                        set: { isPresented in
                            if !isPresented, annotationSelection?.id == selection.id {
                                annotationSelection = nil
                                annotationComment = ""
                            }
                        }
                    ), arrowEdge: .top) {
                        HStack(spacing: 10) {
                            TextField("Add an optional comment…", text: $annotationComment)
                                .textFieldStyle(.plain)
                                .onSubmit { addAnnotation(selection) }
                                .accessibilityIdentifier("comment-input-field")
                            Button { addAnnotation(selection) } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.black)
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.78), in: Circle())
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .nativeHelp("Add comment")
                            .accessibilityLabel("Add comment")
                            .accessibilityIdentifier("add-comment-button")
                        }
                        .padding(.leading, 15)
                        .padding(.trailing, 7)
                        .padding(.vertical, 7)
                        .frame(width: 355)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        // The outline is drawn over the field and the arrow. Hit-testable, it took
                        // every click on the arrow, which never ran its action; only the text
                        // field, an AppKit view, still received clicks.
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
                        .padding(5)
                    }
                    .position(
                        x: min(max(selection.bounds.midX, 56), max(56, geometry.size.width - 56)),
                        y: selection.bounds.minY - 22
                    )
                    .zIndex(20)
                }
            }
        }
    }

    private func assistantMarkdownContent(
        _ markdown: String,
        messageID: String? = nil,
        responseAnnotations: [ResponseAnnotationReference] = []
    ) -> some View {
        // Progress text without a message ID is short-lived, so only replies are kept.
        let blocks = messageID.map { messageID in
            Self.markdownBlocksCache.value(slot: messageID, key: markdown) { Self.markdownBlocks(markdown) }
        } ?? Self.markdownBlocks(markdown)
        return VStack(alignment: .leading, spacing: 7) {
            if let messageID {
                ForEach(AssistantMarkdownSegment.segments(of: blocks)) { segment in
                    switch segment {
                    case .prose(let prose):
                        assistantProseText(prose, messageID: messageID, responseAnnotations: responseAnnotations, wholeMessageText: markdown)
                    case .card(let block):
                        markdownCard(block)
                    }
                }
            } else {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading(let level):
                        markdownBlockText(block)
                            .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                            .accessibilityIdentifier("assistant-markdown-heading-\(block.id)")
                    case .listItem:
                        // The marker is rendered through SelectableAnnotationText/NSTextView, so
                        // its baseline is AppKit's, as in a transcript reply's prose text.
                        HStack(alignment: .top, spacing: 7) {
                            markerText("•")
                            markdownBlockText(block)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Self.markdownPlainText(block.text))
                        .accessibilityIdentifier("assistant-markdown-list-item-\(block.id)")
                    case .orderedListItem(let number):
                        HStack(alignment: .top, spacing: 7) {
                            markerText("\(number).")
                            markdownBlockText(block)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(number). " + Self.markdownPlainText(block.text))
                        .accessibilityIdentifier("assistant-markdown-ordered-list-item-\(block.id)")
                    case .codeBlock, .table:
                        markdownCard(block)
                    case .paragraph:
                        markdownBlockText(block)
                            .accessibilityIdentifier("assistant-markdown-paragraph-\(block.id)")
                            .padding(.bottom, 5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownCard(_ block: AssistantMarkdownBlock) -> some View {
        switch block.kind {
        case .codeBlock(let language):
            CodeBlockCardView(blockID: block.id, code: block.text, language: language, font: block.font)
                .accessibilityIdentifier("assistant-markdown-code-block-\(block.id)")
        case .table(let headers, let alignments, let rows):
            TableBlockView(blockID: block.id, headers: headers, alignments: alignments, rows: rows, font: block.font)
        case .heading, .listItem, .orderedListItem, .paragraph:
            EmptyView()
        }
    }

    /// One reply's consecutive prose blocks in a single text view, so a selection, and the
    /// comment made on it, can run across headings, paragraphs, and list items.
    private func assistantProseText(
        _ blocks: [AssistantMarkdownBlock],
        messageID: String,
        responseAnnotations: [ResponseAnnotationReference],
        wholeMessageText: String
    ) -> some View {
        let layout = AssistantProseLayout.cached(slot: "\(messageID):\(blocks[0].id)", blocks: blocks, responseAnnotations: responseAnnotations)
        return SelectableAnnotationText(
            text: layout.text.string,
            highlightedRanges: annotations.filter { $0.messageID == messageID }.compactMap(layout.range(of:)),
            responseAnnotations: responseAnnotations,
            responseCommentSourcePrefix: "\(messageID):\(layout.id)",
            isAssistantText: true,
            onSelection: { range, text, bounds in
                guard !text.isEmpty, let positions = layout.blockPositions(of: range) else {
                    currentTextSelection = nil
                    return
                }
                currentTextSelection = AnnotationSelection(
                    messageID: messageID, anchorID: layout.id,
                    blockID: positions.blockID, startOffset: positions.startOffset,
                    endBlockID: positions.endBlockID, endOffset: positions.endOffset,
                    text: text, bounds: bounds
                )
            },
            formattedText: layout.text,
            wholeMessageText: wholeMessageText,
            accessibilityBlocks: layout.accessibilityBlocks
        )
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) { selectionHint(messageID: messageID, anchorID: layout.id) }
            .accessibilityIdentifier("assistant-markdown-prose-\(layout.id)")
            .padding(.bottom, layout.endsWithParagraph ? 5 : 0)
    }

    private func markdownBlockText(_ block: AssistantMarkdownBlock) -> some View {
        let formatted = NSMutableAttributedString(attributedString: Self.markdownNSAttributedString(block.text, baseFont: block.font))
        // SwiftUI text has no pill drawing of its own; the inline code tint is drawn as a plain background.
        formatted.enumerateAttribute(InlineCodeStyle.attribute, in: NSRange(location: 0, length: formatted.length)) { value, range, _ in
            if let color = value as? NSColor { formatted.addAttribute(.backgroundColor, value: color, range: range) }
        }
        return Text((try? AttributedString(formatted, including: \.appKit)) ?? Self.markdownAttributedText(block.text))
    }

    /// Renders a list marker ("•" or "1.") through the same `SelectableAnnotationText`/NSTextView
    /// plumbing as list-item content, so the marker shares identical font metrics and
    /// `textContainerInset` with its sibling content view — guaranteeing `.top`-aligned HStack
    /// rows line up exactly, rather than approximating the gap between two different text-layout
    /// engines (SwiftUI `Text` vs. AppKit `NSTextView`) with a guessed padding constant.
    private func markerText(_ marker: String) -> some View {
        let markerFont = marker == "•" ? AssistantProseLayout.bulletFont : AssistantProseLayout.markerFont
        // Measure the marker itself instead of a fixed column width, so two-digit (or longer)
        // ordered-list numbers ("10.", "100.") get enough width and never wrap/clip.
        let markerWidth = NSAttributedString(string: marker, attributes: [.font: markerFont]).size().width
        return SelectableAnnotationText(
            text: marker,
            highlightedRanges: [],
            onSelection: { _, _, _ in },
            formattedText: NSAttributedString(string: marker, attributes: [
                .font: markerFont,
                .foregroundColor: NSColor.labelColor,
            ]),
            font: markerFont
        )
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: ceil(markerWidth) + 4, alignment: .leading)
    }

    private func addAnnotation(_ selection: AnnotationSelection) {
        guard annotationSelection?.id == selection.id else { return }
        annotations.append(ConversationAnnotation(
            id: UUID(), messageID: selection.messageID, blockID: selection.blockID,
            startOffset: selection.startOffset, endBlockID: selection.endBlockID, endOffset: selection.endOffset,
            text: selection.text, comment: annotationComment.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        annotationSelection = nil
        currentTextSelection = nil
        annotationComment = ""
    }

    private func responseAnnotationReferences(for message: ConversationMessage) -> [ResponseAnnotationReference] {
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }),
              let userMessage = messages[..<messageIndex].last(where: { $0.role == .user }),
              let start = userMessage.text.range(of: "<response-comments>")
                ?? userMessage.text.range(of: "<response-annotations>"),
              let end = userMessage.text.range(of: "</response-comments>", range: start.upperBound..<userMessage.text.endIndex)
                ?? userMessage.text.range(of: "</response-annotations>", range: start.upperBound..<userMessage.text.endIndex),
              let data = String(userMessage.text[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let text = item["text"] as? String,
                  let comment = item["comment"] as? String ?? item["annotation"] as? String else { return nil }
            return ResponseAnnotationReference(text: text, comment: comment)
        }
    }

    /// Splits a Markdown table row on `|`, dropping an optional leading/trailing pipe the way
    /// GFM tables are usually written (`| a | b |` as well as the bare `a | b`).
    private static func markdownTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Returns the per-column alignment if `line` is a valid GFM table separator row (each cell is
    /// dashes with optional leading/trailing colon, e.g. `---`, `:---`, `:---:`, `---:`), or `nil`
    /// if it isn't a separator row at all.
    private static func markdownTableSeparatorAlignments(_ line: String) -> [MarkdownTableColumnAlignment]? {
        let cells = markdownTableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableColumnAlignment] = []
        for cell in cells {
            var body = cell
            let leadingColon = body.hasPrefix(":")
            if leadingColon { body.removeFirst() }
            let trailingColon = body.hasSuffix(":")
            if trailingColon { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func orderedListPrefix(_ line: Substring) -> (number: Int, rest: Substring)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return (number, afterDigits.dropFirst(2))
    }

    private static let markdownBlocksCache = ReplyRenderCache<[AssistantMarkdownBlock]>(countLimit: 2000)

    private static func markdownBlocks(_ markdown: String) -> [AssistantMarkdownBlock] {
        var blocks: [AssistantMarkdownBlock] = []
        var paragraphLines: [String] = []
        var paragraphStart: Int?
        // Only treat digit-dot-space prefixes as an ordered list when they form a sequence that
        // starts at 1 and increments by one; otherwise a sentence like "3. 5 billion parameters…"
        // would be mis-parsed as a list item.
        var lastOrderedNumber: Int?

        func flushParagraph() {
            guard let start = paragraphStart, !paragraphLines.isEmpty else { return }
            blocks.append(AssistantMarkdownBlock(
                id: start,
                kind: .paragraph,
                text: paragraphLines.joined(separator: " ")
            ))
            paragraphLines.removeAll()
            paragraphStart = nil
        }

        let rawLines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < rawLines.count {
            let rawLine = rawLines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                // A blank line alone does not end an ordered list: Markdown allows a "loose"
                // list with blank lines between items, so `lastOrderedNumber` carries across
                // this gap and only resets once a non-list block actually interrupts it.
                flushParagraph()
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                lastOrderedNumber = nil
                let fenceStart = index
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                // Only a line consisting solely of backticks closes the fence, matching
                // CommonMark; a mere `hasPrefix("```")` would also match content lines inside the
                // code block itself (e.g. a code sample that demonstrates Markdown fences).
                while index < rawLines.count {
                    let candidate = rawLines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= 3, candidate.allSatisfy({ $0 == "`" }) { break }
                    codeLines.append(rawLines[index])
                    index += 1
                }
                if index < rawLines.count { index += 1 } // consume closing fence
                blocks.append(AssistantMarkdownBlock(
                    id: fenceStart,
                    kind: .codeBlock(language: language.isEmpty ? nil : language),
                    text: codeLines.joined(separator: "\n")
                ))
                continue
            }
            if line.contains("|"), index + 1 < rawLines.count,
               let alignments = Self.markdownTableSeparatorAlignments(rawLines[index + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = Self.markdownTableCells(line)
                // A separator row with a different cell count than the header isn't a valid GFM
                // table (e.g. a stray "---" thematic break after a line that merely contains "|");
                // fall through to the normal paragraph/heading/list handling below instead.
                if headers.count == alignments.count {
                    flushParagraph()
                    lastOrderedNumber = nil
                    let tableStart = index
                    index += 2 // consume the header row and the separator row
                    var rows: [[String]] = []
                    while index < rawLines.count {
                        let rowLine = rawLines[index].trimmingCharacters(in: .whitespaces)
                        guard !rowLine.isEmpty, rowLine.contains("|") else { break }
                        // GFM pads short rows and drops extra cells, so every row renders with the
                        // header's column count; without this a ragged row would shift the Grid's
                        // remaining columns out of alignment with their headers.
                        var cells = Self.markdownTableCells(rowLine)
                        if cells.count > headers.count { cells.removeSubrange(headers.count...) }
                        cells.append(contentsOf: Array(repeating: "", count: max(0, headers.count - cells.count)))
                        rows.append(cells)
                        index += 1
                    }
                    blocks.append(AssistantMarkdownBlock(
                        id: tableStart,
                        kind: .table(headers: headers, alignments: alignments, rows: rows),
                        text: ""
                    ))
                    continue
                }
            }
            if line.range(of: #":(?:playhouse-annotation|codex-annotation)\{index=\"\d+\"\}"#, options: .regularExpression) != nil {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(id: index, kind: .paragraph, text: line))
                index += 1
                continue
            }
            let headingPrefix = line.prefix(while: { $0 == "#" })
            if !headingPrefix.isEmpty, headingPrefix.count <= 6,
               line.dropFirst(headingPrefix.count).first == " " {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(
                    id: index,
                    kind: .heading(headingPrefix.count),
                    text: String(line.dropFirst(headingPrefix.count + 1))
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(id: index, kind: .listItem, text: String(line.dropFirst(2))))
            } else if let ordered = orderedListPrefix(line[...]),
                      // As in CommonMark, only a list starting at 1 may interrupt a paragraph,
                      // so a wrapped line that happens to begin "3. " stays part of its paragraph.
                      paragraphLines.isEmpty || ordered.number == 1,
                      ordered.number == (lastOrderedNumber.map { $0 + 1 } ?? 1) {
                flushParagraph()
                lastOrderedNumber = ordered.number
                blocks.append(AssistantMarkdownBlock(id: index, kind: .orderedListItem(number: ordered.number), text: String(ordered.rest)))
            } else {
                lastOrderedNumber = nil
                paragraphStart = paragraphStart ?? index
                paragraphLines.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Button { selectedChatImage = attachment.image } label: {
                                    Image(nsImage: attachment.image).resizable().scaledToFill()
                                        .frame(width: 64, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open attached image")
                                .accessibilityIdentifier("pending-chat-image-\(attachment.id)")
                                .buttonHoverPointer()
                                .nativeHelp("Open image at full size")

                                Button {
                                    pendingImages.removeAll { $0.id == attachment.id }
                                    persistDraft()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonHoverPointer()
                                .nativeHelp("Remove image")
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove image")
                            }
                        }
                    }
                }.accessibilityIdentifier("pending-chat-images")
            }
            if let actionNotice {
                Label(actionNotice, systemImage: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("codex-action-notice")
            }
            if let providerNotice {
                Label(providerNotice, systemImage: "arrow.triangle.swap")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider-capabilities-notice")
            }

            if !isRepositoryRootConfigured {
                HStack(spacing: 8) {
                    Label("Set the repository root folder before sending.", systemImage: "folder.badge.questionmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("repository-root-required-notice")
                    Spacer(minLength: 0)
                    Button("Set root folder…") {
                        chooseRepositoryParentFolder(showRepositoryPickerWhenFinished: false)
                    }
                    .buttonHoverPointer()
                    .buttonStyle(.bordered)
                    .nativeHelp("Choose the folder that contains your repositories.")
                    .accessibilityIdentifier("set-conversation-repository-root-button")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("codex-chat-error")
            }

            if !waitingFollowUps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(waitingFollowUps) { queued in
                        HStack(spacing: 12) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(queued.text)
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("queued-message-text-\(queued.id.uuidString)")
                            if let imageCount = queued.imageDataURLs?.count, imageCount > 0 {
                                Label("\(imageCount)", systemImage: "photo")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .nativeHelp(imageCount == 1 ? "1 attached image" : "\(imageCount) attached images")
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(imageCount == 1 ? "1 attached image" : "\(imageCount) attached images")
                                    .accessibilityIdentifier("queued-message-images-\(queued.id.uuidString)")
                            }
                            if queued.state == .needsAction {
                                Text("Needs action")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Follow-up needs your action")
                                    .accessibilityIdentifier("queued-message-needs-action-\(queued.id.uuidString)")
                                Button { retryQueuedMessage(queued) } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .buttonHoverPointer()
                                .nativeHelp("Retry this follow-up")
                                .accessibilityLabel("Retry follow-up")
                                .accessibilityIdentifier("retry-queued-message-\(queued.id.uuidString)")
                            } else {
                                Button("Steer") { steerQueuedMessage(queued) }
                                    .disabled(isSubmittingLiveMessage)
                                    .buttonHoverPointer()
                                    .nativeHelp("Send this follow-up to the active turn now")
                                    .accessibilityIdentifier("steer-queued-message-\(queued.id.uuidString)")
                            }
                            Button { removeQueuedMessage(queued) } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Remove this follow-up")
                            .accessibilityLabel("Remove follow-up")
                            .accessibilityIdentifier("remove-queued-message-\(queued.id.uuidString)")
                            Menu {
                                Button("Copy text") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(queued.text, forType: .string)
                                }
                                .buttonHoverPointer()
                                .help("Copy this follow-up")
                                Button("Remove follow-up", role: .destructive) { removeQueuedMessage(queued) }
                                    .buttonHoverPointer()
                                    .help("Remove this follow-up")
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .nativeHelp("More follow-up actions")
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("More follow-up actions")
                            .accessibilityIdentifier("queued-message-more-\(queued.id.uuidString)")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("queued-message-\(queued.id.uuidString)")
                    }
                }
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("queued-follow-ups")
            }

            VStack(alignment: .leading, spacing: 10) {
                let pendingCommentCount = annotations.filter(\.pending).count
                if pendingCommentCount > 0 {
                    Label("\(pendingCommentCount) comment\(pendingCommentCount == 1 ? "" : "s")", systemImage: "text.bubble")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .accessibilityIdentifier("pending-comment-count")
                }

                if let activeGoal, activeGoal.status != "complete", !isReadOnly, provider.supportsGoals {
                    HStack(spacing: 10) {
                        Image(systemName: "scope").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                        Text("\(activeGoal.status == "paused" ? "Paused goal" : "Pursuing goal") \(activeGoal.objective)")
                            .lineLimit(1).truncationMode(.tail).font(.system(size: 15))
                            .accessibilityIdentifier("active-goal-title")
                        Spacer(minLength: 4)
                        if let seconds = activeGoal.timeUsedSeconds {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Self.goalDuration(goalElapsedTime(for: activeGoal, reportedSeconds: seconds)
                                    + (activeGoal.status == "active" ? context.date.timeIntervalSince(goalStatusUpdatedAt) : 0)))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("goal-elapsed-time")
                            }
                        }
                        Button(role: .destructive) { Task { await mutateGoal("clear") } } label: { Image(systemName: "trash") }
                            .buttonHoverPointer().buttonStyle(.plain).nativeHelp("Clear goal")
                            .accessibilityLabel("Clear goal").accessibilityIdentifier("goal-clear-button")
                        Button { Task { await mutateGoal(activeGoal.status == "paused" ? "resume" : "pause") } } label: {
                            Image(systemName: activeGoal.status == "paused" ? "play.fill" : "pause")
                        }
                            .buttonHoverPointer().buttonStyle(.plain).nativeHelp(activeGoal.status == "paused" ? "Resume goal" : "Pause goal")
                            .accessibilityLabel(activeGoal.status == "paused" ? "Resume goal" : "Pause goal")
                            .accessibilityIdentifier("goal-pause-resume-button")
                        Button { isGoalExpanded.toggle() } label: { Image(systemName: isGoalExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .buttonHoverPointer().buttonStyle(.plain).nativeHelp(isGoalExpanded ? "Collapse goal" : "Expand goal")
                            .accessibilityLabel(isGoalExpanded ? "Collapse goal" : "Expand goal")
                            .accessibilityValue(isGoalExpanded ? "Expanded" : "Collapsed")
                            .accessibilityIdentifier("goal-expand-button")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false) }
                    .accessibilityElement(children: .contain)
                    .accessibilityValue(conversationRuntime.snapshot.goal.turnStartedThreadID == task.codexThreadID ? "Work started" : (conversationRuntime.isTurnActive(threadID: task.codexThreadID ?? "") ? "Working" : "Waiting"))
                    .accessibilityIdentifier("active-goal-progress-row")
                    if isGoalExpanded {
                        Text(activeGoal.objective).font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                            .accessibilityIdentifier("active-goal-details")
                    }
                }
                NativeChatEditor(
                    text: $composerDraft.text,
                    height: $composerHeight,
                    isFocused: Binding(get: { isComposerFocused }, set: { isComposerFocused = $0 }),
                    focusRequest: composerDraft.focusRequest,
                    isEnabled: !isReadOnly,
                    autofocusOnAppear: isNewTask,
                    accessibilityHelp: isReadOnly
                        ? "Archived conversation, read-only."
                         : (isResponding ? "Press Return to queue this follow-up. Press Command-Return to steer the active turn, or use a queued row's Steer action."
                            : (isLoadingHistory ? "Composer unavailable while conversation history loads." : "")),
                    onSubmit: {
                        if isResponding {
                            queueDraftForAfterTurn()
                        } else {
                            sendMessage()
                        }
                    },
                    onSteerSubmit: {
                        if isResponding, isConversationTurnActive {
                            steerCurrentTurn()
                        }
                    },
                    onPasteImage: { image in
                        do { try addImageData(image) }
                        catch { errorMessage = error.localizedDescription }
                    }
                )
                    .frame(height: composerHeight)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(isEnteringGoal ? "Set a goal to keep pursuing" : (isResponding || activeGoal != nil ? "Ask for follow-up changes" : "Message…"))
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("composer-placeholder")
                        }
                    }
                    .onChange(of: draft) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/plan" {
                            activatePlanMode()
                        } else if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/goal", provider.supportsGoals {
                            isEnteringGoal = true
                            draft = ""
                        }
                        scheduleDraftAutosave(newValue)
                    }
                    .disabled(isReadOnly || isPreparingSubmittedMessage)
                    .accessibilityIdentifier("message-composer-scroll-view")

                HStack(spacing: 12) {
                    Button { isShowingSkills = true } label: { Image(systemName: "sparkles") }
                    .buttonHoverPointer()
                    .nativeHelp("Skills")
                        .buttonStyle(.plain).accessibilityLabel("Skills")
                        .accessibilityIdentifier("open-skills-button")
                    Menu {
                        if provider.supportsGoals {
                            Button {
                                isEnteringGoal = true
                                draft = ""
                            } label: {
                                Label("Goal", systemImage: "scope")
                            }
                            .buttonHoverPointer()
                            .help("Set a goal to keep pursuing")
                            .accessibilityIdentifier("conversation-mode-goal")
                        }
                        ForEach(ConversationMode.allCases, id: \.self) { mode in
                            Button {
                                isEnteringGoal = false
                                setConversationMode(mode)
                            } label: {
                                if conversationMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                            .buttonHoverPointer()
                            .help("Switch to \(mode.title) mode")
                            .accessibilityIdentifier("conversation-mode-\(mode.rawValue)")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            if isEnteringGoal {
                                Image(systemName: "scope")
                                Text("Goal")
                                    .font(.system(size: 11, weight: .semibold))
                            } else if conversationMode == .plan {
                                Text("Plan")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(isEnteringGoal || conversationMode == .plan ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 30, minHeight: 31)
                        .contentShape(Rectangle())
                    }
                    .buttonHoverPointer()
                    .menuStyle(.borderlessButton)
                    .nativeHelp("Change conversation mode or add context")
                    .accessibilityLabel(isEnteringGoal ? "Goal" : "Conversation mode: \(conversationMode.title)")
                    .accessibilityIdentifier("conversation-mode-menu")

                    if canShowStartImplementing {
                        Button(action: startImplementingPlan) {
                            Text("Start Implementing")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .frame(height: 31)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain)
                        .disabled(workspaceRootURLs.isEmpty || isLoadingHistory || isPreparingSubmittedMessage)
                        .nativeHelp(startImplementingUnavailableReason ?? "Switch to Code mode and start implementing this plan")
                        .accessibilityValue(startImplementingUnavailableReason ?? (workspaceRootURLs.isEmpty ? "Unavailable" : "Available"))
                        .accessibilityHint("Switches to Code mode and starts implementing this plan")
                        .accessibilityIdentifier("start-implementing-button")

                        // The reason is shown, not only hovered, and opens the header's repository picker.
                        if let reason = startImplementingUnavailableReason {
                            Button(action: showRepositoryPicker) {
                                Label("No repository", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(emptyConversationRepositoryTitleColor)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .disabled(isReadOnly)
                            .nativeHelp(reason)
                            .accessibilityLabel("No repository")
                            .accessibilityValue(reason)
                            .accessibilityHint("Opens the repository picker")
                            .accessibilityIdentifier("start-implementing-unavailable-reason")
                        }
                    }

                    Spacer(minLength: 0)

                    providerMenu

                    Button {
                        if isModelPickerPresented {
                            commitModelPickerSelection()
                            isModelPickerPresented = false
                        } else {
                            pickerModelID = selectedModelID
                            pickerEffort = selectedEffort
                            isModelPickerPresented = true
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(selectedModelName)
                            Text(selectedEffort.title).foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .nativeHelp("Choose a model and reasoning effort")
                    .accessibilityLabel("Model: \(selectedModelName), effort: \(selectedEffort.title)")
                    .accessibilityValue(selectedModelName)
                    .accessibilityIdentifier("model-picker-menu")
                    .popover(isPresented: Binding(
                        get: { isModelPickerPresented },
                        set: { isPresented in
                            if !isPresented && isModelPickerPresented {
                                commitModelPickerSelection()
                            }
                            isModelPickerPresented = isPresented
                        }
                    ), arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(modelOptions) { model in
                                Button {
                                    selectPickerModel(model)
                                } label: {
                                    HStack {
                                        Text(model.name)
                                        Spacer()
                                        if pickerModelID == model.id || (pickerModelID.isEmpty && model.isDefault) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Select \(model.name)")
                                .accessibilityIdentifier("model-option-\(model.id)")
                            }
                            Divider().padding(.vertical, 8)
                            Text(pickerEffort.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityIdentifier("selected-model-effort")
                            if pickerEffortChoices.count > 1 {
                                // The native slider knob is translucent on macOS 26, so it is drawn by
                                // EffortStepSlider; an undrawn native slider laid over it takes the
                                // pointer and keyboard, and a SwiftUI Slider represents it to accessibility.
                                EffortStepSlider(selection: $pickerEffort, choices: pickerEffortChoices)
                                    .overlay {
                                        EffortAccessibilitySlider(selection: $pickerEffort, choices: pickerEffortChoices)
                                    }
                                    .accessibilityRepresentation {
                                        Slider(value: Binding(
                                            get: { Double(pickerEffortChoices.firstIndex(of: pickerEffort) ?? 0) },
                                            set: { pickerEffort = pickerEffortChoices[min(max(Int($0.rounded()), 0), pickerEffortChoices.count - 1)] }
                                        ), in: 0...Double(pickerEffortChoices.count - 1), step: 1)
                                        .accessibilityLabel("Model effort")
                                        .accessibilityValue(pickerEffort.title)
                                        .accessibilityIdentifier("model-effort-slider")
                                    }
                            } else {
                                EffortStepSlider(selection: $pickerEffort, choices: pickerEffortChoices)
                                    .accessibilityRepresentation {
                                        Text(pickerEffort.title)
                                            .accessibilityElement()
                                            .accessibilityLabel("Model effort")
                                            .accessibilityValue(pickerEffort.title)
                                            .accessibilityIdentifier("model-effort-slider")
                                    }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .frame(width: 320)
                    }

                    // A turn still finishing after its final answer can still be stopped; one
                    // that is only waiting on a question keeps the composer's send control.
                    if isDisplayingActiveResponse
                        || (isResponding && providerTurnIsActive && userInputRequest == nil && providerPendingUserInputRequest == nil) {
                        Button(action: pauseResponse) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.primary.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonHoverPointer()
                        .nativeHelp("Pause \(provider.displayName) response")
                        .buttonStyle(.plain)
                        .disabled(isPausingResponse || !canPauseResponse)
                        .accessibilityLabel("Stop response")
                        .accessibilityIdentifier("pause-response-button")
                    } else if hasPausedResponse {
                        Button(action: continueResponse) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonHoverPointer()
                        .nativeHelp("Continue \(provider.displayName) response")
                        .buttonStyle(.plain)
                        .accessibilityLabel("Continue response")
                        .accessibilityIdentifier("continue-response-button")
                    } else {
                        Button { sendMessage() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.accentColor, in: Circle())
                        }
                        .buttonHoverPointer()
                        .nativeHelp("Send message")
                        .buttonStyle(.plain)
                        .disabled(isSendDisabled)
                        .opacity(isSendDisabled ? 0.45 : 1)
                        .accessibilityLabel("Send message")
                        .accessibilityIdentifier("send-message-button")
                    }
                }
            }
            .padding(13)
            .background(WorkspaceTheme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }

    private func userInputForm(_ request: ConversationUserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A few questions")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("ai-question-form-title")
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 7) {
                    Text(question.question).font(.system(size: 12, weight: .medium))
                    if question.options.isEmpty {
                        Group {
                            if question.isSecret {
                                SecureField("Answer", text: Binding(
                                    get: { userInputAnswers[question.id]?.first ?? "" },
                                    set: { userInputAnswers[question.id] = [$0] }
                                ))
                            } else {
                                TextField("Your answer", text: Binding(
                                    get: { userInputAnswers[question.id]?.first ?? "" },
                                    set: { userInputAnswers[question.id] = [$0] }
                                ))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ai-question-answer-\(question.id)")
                    } else {
                        ForEach(question.options) { option in
                            let isSelected = (userInputAnswers[question.id] ?? []).first == option.label
                            Button {
                                userInputAnswers[question.id] = [option.label]
                                userInputOtherSelected.remove(question.id)
                            } label: {
                                Label(option.label, systemImage: isSelected ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Select answer: \(option.label)")
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ai-question-option-\(question.id)-\(option.label)")
                            .accessibilityValue(isSelected ? "selected" : "not selected")
                        }
                        if question.allowsOther {
                            Button {
                                userInputAnswers[question.id] = []
                                userInputOtherSelected.insert(question.id)
                            } label: {
                                Label("Other", systemImage: userInputOtherSelected.contains(question.id) ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Select a free-text answer")
                            .buttonStyle(.plain)
                            .accessibilityValue(userInputOtherSelected.contains(question.id) ? "selected" : "not selected")
                            TextField("Other answer", text: Binding(
                                get: { userInputOther[question.id] ?? "" },
                                set: {
                                    userInputOther[question.id] = $0
                                    userInputAnswers[question.id] = []
                                    userInputOtherSelected.insert(question.id)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            Button("Submit answers") {
                Task { @MainActor in await submitUserInput(request) }
            }
            .buttonHoverPointer()
            .nativeHelp("Submit answers")
                .buttonStyle(.borderedProminent)
                .disabled(request.questions.contains { question in
                    let selections = userInputAnswers[question.id] ?? []
                    return selections.isEmpty && (!userInputOtherSelected.contains(question.id) || (userInputOther[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
                .accessibilityIdentifier("submit-ai-answers-button")
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func submitUserInput(_ request: ConversationUserInputRequest) async {
        var answers: [String: [String]] = [:]
        for question in request.questions {
            var values = userInputAnswers[question.id] ?? []
            if userInputOtherSelected.contains(question.id), let other = userInputOther[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                values = [other]
            }
            answers[question.id] = values
        }
        isResponding = true
        errorMessage = nil
        // After a restart the answer runs as a whole recovery turn before this
        // call returns, so hide the answered card meanwhile. Marking it answered
        // now keeps a history refresh during the call from bringing it back.
        userInputRequest = nil
        answeredUserInputRequestIDs.insert(request.id)
        // A recovery turn streams its redacted reply before history hides it.
        var streamedRecoveryFinals: [String] = []
        do {
            let accepted = try await conversationManager.answerUserInput(
                taskID: task.id,
                request: request,
                answers: answers,
                modelID: selectedModelID.isEmpty ? nil : selectedModelID,
                onUpdate: { update in
                    if update.type == "assistant_final", let text = update.text, !text.isEmpty {
                        streamedRecoveryFinals.append(text)
                    }
                    guard update.type == "user_input", let nextRequest = update.userInputRequest else { return }
                    showUserInputRequest(nextRequest)
                }
            )
            guard accepted else {
                answeredUserInputRequestIDs.remove(request.id)
                isResponding = false
                if userInputRequest == nil { userInputRequest = request }
                errorMessage = "\(provider.displayName) couldn't accept those answers. Please check the responses and try again."
                return
            }
            answeredUserInputRequestIDs.insert(request.id)
            userInputRequest = nil
            userInputAnswers = [:]
            userInputOther = [:]
            userInputOtherSelected = []
            await loadConversation()
            // This window keeps showing the safe reply it streamed; a reload shows it hidden.
            if let finalText = streamedRecoveryFinals.last,
               let index = messages.lastIndex(where: { $0.role == .assistant }),
               messages[index].text == Self.hiddenRecoveryReplyText {
                streamedRecoveryReplies[messages[index].id] = finalText
                showStreamedRecoveryReplies()
            }
        } catch {
            // A failed answer keeps its saved question for retry; a new question the
            // turn raised meanwhile is already showing.
            answeredUserInputRequestIDs.remove(request.id)
            if userInputRequest == nil,
               let saved = try? await conversationManager.history(taskID: task.id).pendingUserInputRequest,
               saved.threadID == task.activeConversationID {
                userInputRequest = saved
            }
            isResponding = conversationRuntime.isTurnActive(threadID: request.threadID)
            errorMessage = error.localizedDescription
        }
    }

    private func loadConversation() async {
        isLoadingHistory = true
        hasPresentedLatestConversation = false
        isLatestConversationTurnPinPending = true
        isOlderConversationRevealArmed = false
        // Following resumes once the pinned turn is observed at the bottom.
        lastConversationScrollSample.isFollowingLatest = false
        oldestRenderedMessageID = nil
        errorMessage = nil
        let draftAtLoadStart = draft
        defer { isLoadingHistory = false }

        do {
            // Standalone chat rotates one session per page, so the transcript asks for the
            // earlier pages to be restored from the local archive alongside the live session.
            // Only the newest page is read; older pages load as the reader scrolls up.
            let history = try await conversationManager.history(
                taskID: task.id,
                messageLimit: Self.historyPageSize,
                onActionRequest: { actionNotice = approvalNotice }
            )
            messages = history.messages
            earlierStoredMessageCount = history.earlierMessageCount ?? 0
            // Resolve the window as soon as the messages land. The assignment
            // at the end of the load repeats it once progress collapsing has
            // settled which rows the transcript renders.
            oldestRenderedMessageID = latestConversationTurnStartID
            let savedUserInputRequest = history.pendingUserInputRequest?.threadID == task.activeConversationID
                ? history.pendingUserInputRequest
                : nil
            let currentProviderRequest = providerPendingUserInputRequest
            let liveUserInputRequest = currentProviderRequest?.threadID == task.activeConversationID
                && !answeredUserInputRequestIDs.contains(currentProviderRequest?.id ?? "")
                ? currentProviderRequest
                : nil
            // A history read can finish after the provider has raised a question
            // but before that request has been persisted. Keep the live request
            // visible instead of letting that older snapshot clear it.
            userInputRequest = savedUserInputRequest ?? liveUserInputRequest
            restoreAnnotations(from: history.messages)
            answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
            activities = history.activities
            timelineActivities = []
            mergeTimelineActivities(history.timelineActivities)
            providerBoundaries = history.providerBoundaries
            activeGoal = try? await conversationManager.goal(taskID: task.id)
            let defaults = WorkspaceSettings.preferencesStore
            if let data = defaults.data(forKey: goalAchievementTimelineDefaultsKey),
               let entries = try? JSONDecoder().decode([GoalAchievementTimelineEntry].self, from: data) {
                goalAchievementTimelineEntries = entries
            }
            currentGoalGenerationID = defaults.string(forKey: goalGenerationDefaultsKey)
            currentGoalObjective = defaults.string(forKey: goalGenerationObjectiveDefaultsKey)
            currentGoalTimeBaselineSeconds = defaults.object(forKey: goalGenerationTimeBaselineDefaultsKey) as? Double
            if let activeGoal {
                reconcileGoalGeneration(with: activeGoal)
                if activeGoal.status == "complete",
                   let generationID = currentGoalGenerationID,
                   !goalAchievementTimelineEntries.contains(where: { $0.id == generationID }) {
                    let anchorID = fallbackGoalCompletionAnchorID(in: history.messages, objective: activeGoal.objective)
                    goalAchievementTimelineEntries.append(GoalAchievementTimelineEntry(
                        id: generationID,
                        summary: goalAchievementSummary(activeGoal),
                        afterMessageID: anchorID
                    ))
                    persistGoalAchievementTimeline()
                }
            }
            goalStatusUpdatedAt = .now
            // Stores from before drafts were marked can hold an already sent prompt
            // as the saved prompt; that one does not belong back in the composer.
            let queuedTexts = Set(((try? conversationManager.queuedMessages(taskID: task.id)) ?? []).map(\.text))
            let promptWasSent = task.savedPrompt.map { prompt in
                history.messages.contains { $0.role == .user && $0.text == prompt }
                    || queuedTexts.contains(prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? false
            let hasPendingSubmittedPrompt = task.pendingSubmittedPrompt != nil
            if hasPendingSubmittedPrompt,
               !promptWasSent,
               let submittedPrompt = task.pendingSubmittedPrompt,
               !submittedPrompt.isEmpty {
                messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: submittedPrompt))
            }
            // A marked draft is unsent by definition: steering, queueing, and sending clear it.
            let savedDraft = task.hasUnsentDraft || !(promptWasSent || hasPendingSubmittedPrompt)
                ? task.savedPrompt ?? ""
                : ""
            let restoresDraftImages = task.hasUnsentDraft || !(promptWasSent || hasPendingSubmittedPrompt)
            // Unsent composer text is never replaced by a saved draft, which can only be older.
            // A composer the user just cleared is unsaved, and stays cleared.
            if draft == draftAtLoadStart, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isDraftUnsaved {
                composerDraft.settledText = savedDraft
                draft = savedDraft
            } else if isDraftUnsaved {
                // Autosave skips a reload, so save text that was still waiting for it.
                persistDraft()
            }
            if restoresDraftImages && pendingImages.isEmpty {
                pendingImages = task.draftImageDataURLs.compactMap { dataURL in
                    guard let comma = dataURL.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                          let image = NSImage(data: data) else { return nil }
                    return PendingImage(dataURL: dataURL, image: image)
                }
            }
            isResponding = hasPendingSubmittedPrompt
                && (task.status == .inProgress || task.status == .waitingResponse)
            if let threadID = task.activeConversationID {
                isResponding = isResponding || conversationRuntime.isTurnActive(threadID: threadID)
                // A turn paused while this view was closed can still be continued.
                if !isResponding, task.status == .waitingResponse, conversationRuntime.wasLastTurnInterrupted(threadID: threadID) {
                    hasPausedResponse = true
                }
            }
            if isResponding {
                responseStartedAt = defaults.object(forKey: responseStartedAtDefaultsKey) as? Date ?? Date()
                defaults.set(responseStartedAt, forKey: responseStartedAtDefaultsKey)
                completedResponseDuration = nil
            } else if let duration = defaults.object(forKey: completedResponseDurationDefaultsKey) as? Int {
                completedResponseDuration = duration
                responseStartedAt = nil
            } else if history.messages.contains(where: { $0.role == .assistant && $0.phase == "final_answer" }),
                      let startedAt = defaults.object(forKey: responseStartedAtDefaultsKey) as? Date {
                let duration = Self.elapsedSeconds(since: startedAt, now: Date())
                completedResponseDuration = duration
                defaults.set(duration, forKey: completedResponseDurationDefaultsKey)
                defaults.removeObject(forKey: responseStartedAtDefaultsKey)
                responseStartedAt = nil
            } else {
                responseStartedAt = nil
                defaults.removeObject(forKey: responseStartedAtDefaultsKey)
            }
            let activeTurnID = history.messages.last(where: { $0.turnID != nil })?.turnID
            collapsedProgressTurnIDs = Set(history.messages.lazy
                .filter {
                    $0.role == .assistant
                        && $0.phase == "final_answer"
                        && (!isResponding || $0.turnID != activeTurnID)
                }
                .compactMap(\.turnID))
            // Open on the newest turn. Progress-message collapsing above changes
            // which rows the transcript renders, so resolve the window start here.
            oldestRenderedMessageID = latestConversationTurnStartID
        } catch {
            errorMessage = error.localizedDescription
            // History failed, but an unanswered question stays answerable.
            let saved = try? conversationManager.savedUserInputRequest(taskID: task.id)
            if userInputRequest == nil, let request = saved ?? providerPendingUserInputRequest,
               request.threadID == task.activeConversationID, !answeredUserInputRequestIDs.contains(request.id) {
                showUserInputRequest(request)
            }
        }
    }

    private func restoreAnnotations(from messages: [ConversationMessage], keepingPending: Bool = false) {
        var restored: [ConversationAnnotation] = keepingPending ? annotations.filter(\.pending) : []
        for message in messages where message.role == .user {
            guard let start = message.text.range(of: "<response-comments>")
                    ?? message.text.range(of: "<response-annotations>"),
                  let end = message.text.range(of: "</response-comments>", range: start.upperBound..<message.text.endIndex)
                    ?? message.text.range(of: "</response-annotations>", range: start.upperBound..<message.text.endIndex),
                  let data = String(message.text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for item in items {
                guard let selectedText = item["text"] as? String,
                      let comment = item["comment"] as? String ?? item["annotation"] as? String,
                      let source = item["source"] as? [String: Any],
                      let sourceID = source["messageId"] as? String,
                      let blockID = source["blockID"] as? Int,
                      let startOffset = source["startOffset"] as? Int,
                      let endOffset = source["endOffset"] as? Int else { continue }
                restored.append(ConversationAnnotation(
                    id: UUID(), messageID: sourceID, blockID: blockID,
                    startOffset: startOffset, endBlockID: source["endBlockID"] as? Int ?? blockID, endOffset: endOffset,
                    text: selectedText, comment: comment, pending: false
                ))
            }
        }
        annotations = restored
    }

    /// Shows the cached provider model list and remembered selection without a
    /// bridge round trip, so the picker never has to fall back to the literal
    /// "Default" placeholder just because the live fetch hasn't returned yet.
    private func primeModelOptionsFromCache() {
        selectedModelID = (try? conversationManager.modelID(taskID: task.id)) ?? ""
        selectedEffort = (try? conversationManager.effort(taskID: task.id)) ?? .medium
        if let cachedModels = try? conversationManager.cachedModels(taskID: task.id), !cachedModels.isEmpty {
            modelOptions = cachedModels.newestVersionPerFamily()
        }
    }

    private func loadModels() async {
        primeModelOptionsFromCache()
        do {
            modelOptions = try await conversationManager.models(taskID: task.id)
            if !currentEffortChoices.contains(selectedEffort) {
                selectedEffort = currentEffortChoices.contains(.medium) ? .medium : currentEffortChoices[0]
                // Persist the clamp so the CLI and sends read the same effort the composer shows.
                _ = try? await conversationManager.setEffort(taskID: task.id, effort: selectedEffort)
            }
        } catch {
            // Keep the last known model available when an offline or unauthenticated app-server cannot list models.
        }
    }

    /// The prompt names only models the provider lists; Claude's "Default" is a
    /// placeholder, not a model, and an unlisted ID isn't a name.
    private var promptModelName: String? {
        if !selectedModelID.isEmpty, !modelOptions.contains(where: { $0.id == selectedModelID }) { return nil }
        let name = selectedModelName
        return provider == .claude && name == provider.defaultModelName ? nil : name
    }

    private var selectedModelName: String {
        guard !selectedModelID.isEmpty else {
            return modelOptions.first(where: \.isDefault)?.name ?? provider.defaultModelName
        }
        return modelName(for: selectedModelID)
    }

    /// The label shown above an assistant message is based on the model ID
    /// recorded for that turn, so later picker changes do not relabel history.
    private func assistantLabel(for message: ConversationMessage) -> String {
        let messageProvider = message.provider ?? provider
        let modelID = message.modelID
        let cachedModels = messageProvider == provider
            ? modelOptions
            : ((try? conversationManager.cachedModels(taskID: task.id, provider: messageProvider)) ?? [])
        let modelName = modelID.flatMap { id in cachedModels.first(where: { $0.id == id })?.name }
        return messageProvider.assistantLabel(modelName: modelName)
    }

    private var pickerEffortChoices: [ConversationEffort] {
        effortChoices(for: pickerModelID)
    }

    private var currentEffortChoices: [ConversationEffort] {
        effortChoices(for: selectedModelID)
    }

    private func effortChoices(for modelID: String) -> [ConversationEffort] {
        let model = modelID.isEmpty
            ? modelOptions.first(where: \.isDefault)
            : modelOptions.first(where: { $0.id == modelID })
        guard let supported = model?.supportedEfforts,
              !supported.isEmpty else { return ConversationEffort.allCases }
        return ConversationEffort.allCases.filter(supported.contains)
    }

    private func modelName(for modelID: String) -> String {
        modelOptions.first(where: { $0.id == modelID })?.name ?? modelID
    }

    private func selectPickerModel(_ model: ConversationModelOption) {
        pickerModelID = model.id
        guard !pickerEffortChoices.contains(pickerEffort) else { return }
        pickerEffort = pickerEffortChoices.contains(.medium) ? .medium : pickerEffortChoices[0]
    }

    private func commitModelPickerSelection() {
        let effortChanged = selectedEffort != pickerEffort
        selectedModelID = pickerModelID
        selectedEffort = pickerEffort
        Task { try? conversationManager.setModelID(taskID: task.id, modelID: pickerModelID) }
        guard effortChanged else { return }
        Task { try? await conversationManager.setEffort(taskID: task.id, effort: pickerEffort) }
    }

    private func sendMessage(overrideText: String? = nil) {
        guard !isApplyingSavedRepositories else { return }
        guard isRepositoryRootConfigured else {
            errorMessage = "Set the repository root folder before sending a conversation."
            return
        }
        let freeformText = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAnnotations = annotations.filter(\.pending)
        let usesComposerDraft = overrideText == nil
        // An empty Goal still goes to the bridge, which explains the length rule.
        guard (!freeformText.isEmpty || (usesComposerDraft && (!pendingImages.isEmpty || isEnteringGoal)) || !pendingAnnotations.isEmpty), !isResponding, !isLoadingHistory, userInputRequest == nil else { return }
        let annotationPrompt: String
        if pendingAnnotations.isEmpty {
            annotationPrompt = freeformText
        } else {
            let objects = pendingAnnotations.map { annotation in
                var source: [String: Any] = ["messageId": annotation.messageID,
                                             "blockID": annotation.blockID,
                                             "startOffset": annotation.startOffset, "endOffset": annotation.endOffset]
                // Only a comment spanning blocks names its end block, so one inside a block
                // keeps the payload older history already carries.
                if annotation.endBlockID != annotation.blockID { source["endBlockID"] = annotation.endBlockID }
                return ["text": annotation.text, "comment": annotation.comment, "source": source] as [String: Any]
            }
            let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let guidance = "<playhouse-comment-context>\n# Response comments:\nThe following JSON contains comments on selected conversation text, in array order. For each comment, start a separate response line with :playhouse-annotation{index=\"N\"}, replacing N with the comment's zero-based array index, then a space and the answer. The marker is displayed to the user as the numbered prefix, so do not add another number. Address the comment in the context of its highlighted text. Do not combine comment responses on one line, omit a response, or add introductory text. After the comment responses, answer any additional freeform request on separate line(s). Do not repeat the JSON or these instructions.\n<response-comments>\(json)</response-comments>\n</playhouse-comment-context>"
            annotationPrompt = [freeformText, guidance]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let text = annotationPrompt
        // An annotation can point at text from an earlier page; that page travels with this
        // turn so the agent sees the quoted context without reloading the whole chat.
        let annotationPageIDs = standaloneChatPageIDs(for: pendingAnnotations)
        let resolutionAttempt = conflictResolutionAttempt
        if usesComposerDraft && pendingAnnotations.isEmpty && text == "/plan" {
            activatePlanMode()
            return
        }
        if usesComposerDraft && isEnteringGoal && pendingAnnotations.isEmpty {
            isPreparingSubmittedMessage = true
            draft = ""
            isEnteringGoal = false
            isResponding = true
            errorMessage = nil
            Task { @MainActor in
                let started = await mutateGoal("set", objective: text, observeRuntime: true)
                isPreparingSubmittedMessage = false
                await conversationRuntime.refresh()
                isResponding = started && conversationRuntime.isTurnActive(threadID: task.codexThreadID ?? "")
                isComposerFocused = true
            }
            return
        }
        if usesComposerDraft && isEnteringGoal && !pendingAnnotations.isEmpty {
            isEnteringGoal = false
        }
        guard !text.isEmpty || (usesComposerDraft && !pendingImages.isEmpty) else { return }
        // A draft autosave can be in flight after the user finishes typing.
        // Do not let that background write race the submitted-prompt write
        // for the same task and leave the send path waiting on its lock.
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        let previousResponseDuration = completedResponseDuration
        isComposerFocused = false
        let hadExistingMessages = !messages.isEmpty
        // The newest message shown before this send; a failed send's prompt counts as delivered
        // only when the conversation has it after this point.
        let sendAnchorID = messages.last?.id
        messages.append(ConversationMessage(id: userMessageID, role: .user, text: text,
                                         imageDataURLs: usesComposerDraft ? pendingImages.map(\.dataURL) : []))
        if !hadExistingMessages {
            messages.append(ConversationMessage(id: assistantMessageID, role: .assistant, text: ""))
        }
        isResponding = true
        let startedAt = Date()
        responseStartedAt = startedAt
        completedResponseDuration = nil
        WorkspaceSettings.preferencesStore.set(startedAt, forKey: responseStartedAtDefaultsKey)
        WorkspaceSettings.preferencesStore.removeObject(forKey: completedResponseDurationDefaultsKey)
        if usesComposerDraft {
            composerDraft.settledText = ""
            draft = ""
        }
        let imageDataURLs = usesComposerDraft ? pendingImages.map(\.dataURL) : []
        if usesComposerDraft { pendingImages = [] }
        // Question IDs can repeat across turns.
        answeredUserInputRequestIDs.removeAll()
        hasPausedResponse = false
        isPausingResponse = false
        errorMessage = nil
        actionNotice = nil
        activities = []
        isPreparingSubmittedMessage = true
        let statusBeforeSubmission = task.status

        Task { @MainActor in
            let saved = await saveDraftAndGenerateTitle(
                status: .inProgress,
                prompt: text,
                generateTitle: false,
                reserveTitleForSend: true,
                sendsComposerDraft: usesComposerDraft
            )
            isPreparingSubmittedMessage = false
            guard saved else {
                if resolutionAttempt > 0 {
                    conflictResolutionAttempt = 0
                    onConflictResolutionChecked(false)
                }
                messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                if usesComposerDraft {
                    draft = freeformText
                    pendingImages = imageDataURLs.compactMap { dataURL in
                        guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                        return PendingImage(dataURL: dataURL, image: image)
                    }
                    persistDraft()
                }
                isResponding = false
                responseStartedAt = nil
                WorkspaceSettings.preferencesStore.removeObject(forKey: responseStartedAtDefaultsKey)
                completedResponseDuration = previousResponseDuration
                if let previousResponseDuration {
                    WorkspaceSettings.preferencesStore.set(previousResponseDuration, forKey: completedResponseDurationDefaultsKey)
                } else {
                    WorkspaceSettings.preferencesStore.removeObject(forKey: completedResponseDurationDefaultsKey)
                }
                return
            }
            followedTurnStreams += 1
            defer { followedTurnStreams -= 1 }
            do {
                _ = try await conversationManager.setEffort(taskID: task.id, effort: selectedEffort)
                _ = try await conversationManager.send(taskID: task.id, text: text, imageDataURLs: imageDataURLs, mode: conversationMode, modelID: selectedModelID.isEmpty ? nil : selectedModelID, statusBeforeSubmission: statusBeforeSubmission, contextPageIDs: annotationPageIDs, onTurnStarting: {
                    isResponding = true
                }, onUpdate: { update in
                    switch update.type {
                    case "text_delta":
                        guard let delta = update.text else { return }
                        let messageIndex: Int
                        if let existingIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messageIndex = existingIndex
                        } else {
                            messages.append(ConversationMessage(id: assistantMessageID, role: .assistant, text: ""))
                            messageIndex = messages.index(before: messages.endIndex)
                        }
                        messages[messageIndex].text += delta
                    case "assistant_final":
                        guard let text = update.text else { return }
                        if let messageIndex = messages.lastIndex(where: { $0.role == .assistant }),
                           messages[messageIndex].asyncQuestions == nil {
                            messages[messageIndex].text = text
                            messages[messageIndex].phase = "final_answer"
                        } else {
                            messages.append(ConversationMessage(
                                id: UUID().uuidString,
                                role: .assistant,
                                text: text,
                                phase: "final_answer"
                            ))
                        }
                    case "assistant_progress":
                        guard let itemID = update.itemID, let text = update.text else { return }
                        if let index = messages.firstIndex(where: { $0.id == itemID }) {
                            messages[index].text = text
                            messages[index].phase = update.phase
                            messages[index].asyncQuestions = update.asyncQuestions
                        } else if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messages.insert(ConversationMessage(
                                id: itemID,
                                role: .assistant,
                                text: text,
                                phase: update.phase,
                                asyncQuestions: update.asyncQuestions
                            ), at: placeholderIndex)
                        } else {
                            messages.append(ConversationMessage(
                                id: itemID,
                                role: .assistant,
                                text: text,
                                phase: update.phase,
                                asyncQuestions: update.asyncQuestions
                            ))
                        }
                        if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messages[placeholderIndex].text = ""
                        }
                    case "activity":
                        guard let activity = update.activity else { return }
                        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                            activities[index] = activity
                        } else {
                            activities.append(activity)
                        }
                    case "chat_page_updated":
                        refreshChatPageStatus()
                    case "diff":
                        break
                    case "history", "completed":
                        guard let history = update.history else { return }
                        var mergedMessages = history.messages
                        if update.type == "completed" {
                            for liveMessage in messages where !liveMessage.text.isEmpty {
                                if let persistedIndex = mergedMessages.firstIndex(where: { $0.id == liveMessage.id }) {
                                    if mergedMessages[persistedIndex].text.isEmpty {
                                        mergedMessages[persistedIndex] = liveMessage
                                    }
                                    continue
                                }
                                let alreadyPersisted = mergedMessages.contains {
                                    $0.role == liveMessage.role && $0.text == liveMessage.text
                                }
                                if !alreadyPersisted {
                                    mergedMessages.append(liveMessage)
                                }
                            }
                        }
                        applyHistoryMessages(history, mergedMessages)
                        answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                        activities = history.activities
                        if update.type == "completed" {
                            let sentIDs = Set(pendingAnnotations.map(\.id))
                            for index in annotations.indices where sentIDs.contains(annotations[index].id) {
                                annotations[index].pending = false
                            }
                            if let responseStartedAt {
                                let duration = Self.elapsedSeconds(since: responseStartedAt, now: Date())
                                completedResponseDuration = duration
                                WorkspaceSettings.preferencesStore.set(duration, forKey: completedResponseDurationDefaultsKey)
                                WorkspaceSettings.preferencesStore.removeObject(forKey: responseStartedAtDefaultsKey)
                            }
                            let finalAnswer = history.messages.last { (message: ConversationMessage) -> Bool in
                                message.role == .assistant && message.phase == "final_answer"
                            }
                            let completedTurnID: String? = finalAnswer?.turnID ?? history.messages.last?.turnID
                            if let completedTurnID {
                                collapsedProgressTurnIDs.insert(completedTurnID)
                            }
                            Task { await refreshWorkspaceChanges() }
                        }
                    case "queue_changed":
                        refreshQueuedMessages()
                    case "steered_message":
                        let steered = update.message ?? ""
                        if let index = unechoedLocalSteers.firstIndex(of: steered) {
                            unechoedLocalSteers.remove(at: index)
                        } else {
                            unconfirmedStreamedSteers.append(steered)
                            messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: steered, imageDataURLs: update.imageDataURLs ?? []))
                        }
                        if let message = update.message, draft == message { draft = "" }
                    case "action_notice":
                        actionNotice = update.message
                    default:
                        break
                    }
                }, onUserInput: { request in
                    showUserInputRequest(request)
                })
                if messages.first(where: { $0.id == assistantMessageID })?.text.isEmpty == true {
                    messages.removeAll { $0.id == assistantMessageID }
                }
                isComposerFocused = true
                if resolutionAttempt > 0 {
                    do {
                        switch try await BoardTaskManager(modelContext: modelContext).verifyPullRequestResolution(task.id) {
                        case .resolved:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(true)
                        case .stillConflicted where resolutionAttempt == 1:
                            conflictResolutionAttempt = 2
                            isResponding = false
                            sendMessage(overrideText: "The PR still has conflicts or your latest commit has not reached GitHub. Resolve the remaining conflicts, commit, and push. Verify the PR's merge status before finishing.")
                            return
                        case .stillConflicted:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(false)
                            errorMessage = "The PR still has conflicts after two turns. Review the PR and try again."
                        case .inconclusive:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(false)
                            errorMessage = "GitHub hasn't confirmed that the PR is conflict-free at the pushed head. Try again after its merge check finishes."
                        }
                    } catch {
                        conflictResolutionAttempt = 0
                        onConflictResolutionChecked(false)
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                if resolutionAttempt > 0 {
                    conflictResolutionAttempt = 0
                    onConflictResolutionChecked(false)
                }
                responseStartedAt = nil
                WorkspaceSettings.preferencesStore.removeObject(forKey: responseStartedAtDefaultsKey)
                if conversationRuntime.wasLastTurnInterrupted(threadID: task.activeConversationID ?? "") {
                    hasPausedResponse = true
                } else if let deliveredHistory = await historyIfSendReachedConversation(text, after: sendAnchorID) {
                    // The send failed after its prompt was saved to the conversation (for example,
                    // Codex exited after the turn started). Returning it to the composer would save
                    // it as an unsent draft and prefix it to the next message.
                    applyHistoryMessages(deliveredHistory)
                    errorMessage = error.localizedDescription
                } else {
                    messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                    if usesComposerDraft {
                        draft = freeformText
                        pendingImages = imageDataURLs.compactMap { dataURL in
                            guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                            return PendingImage(dataURL: dataURL, image: image)
                        }
                        persistDraft()
                    }
                    errorMessage = error.localizedDescription
                }
                isComposerFocused = true
            }

            isResponding = false
        }
    }

    /// The conversation's history when a send that reported failure still added its prompt after
    /// `anchorID`, the newest message shown before the send; nil when it didn't. When the anchor
    /// isn't in the fetched page the answer is nil, so the prompt returns to the composer rather
    /// than risk dropping text that never reached the conversation.
    private func historyIfSendReachedConversation(_ text: String, after anchorID: String?) async -> ConversationHistory? {
        guard let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize) else { return nil }
        let later: ArraySlice<ConversationMessage>
        if let anchorID {
            guard let anchorIndex = history.messages.firstIndex(where: { $0.id == anchorID }) else { return nil }
            later = history.messages[history.messages.index(after: anchorIndex)...]
        } else {
            later = history.messages[...]
        }
        let sent = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return later.contains { $0.role == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == sent } ? history : nil
    }

    private func mutateGoal(_ action: String, objective: String? = nil, observeRuntime: Bool = false) async -> Bool {
        do {
            activeGoal = try await conversationManager.goal(taskID: task.id, objective: objective, action: action, observeRuntime: observeRuntime)
            if action == "set", let activeGoal { reconcileGoalGeneration(with: activeGoal) }
            goalStatusUpdatedAt = .now
            if action == "clear" { isGoalExpanded = false }
            return true
        } catch {
            errorMessage = error.localizedDescription
            if action == "set" {
                draft = objective ?? ""
                isEnteringGoal = true
                activeGoal = try? await conversationManager.goal(taskID: task.id)
            }
            return false
        }
    }

    private func reconcileGoalGeneration(with goal: CodexThreadGoal) {
        let defaults = WorkspaceSettings.preferencesStore
        let savedID = defaults.string(forKey: goalGenerationDefaultsKey) ?? currentGoalGenerationID
        let savedObjective = defaults.string(forKey: goalGenerationObjectiveDefaultsKey) ?? currentGoalObjective
        let savedTimeBaseline = defaults.object(forKey: goalGenerationTimeBaselineDefaultsKey) as? Double
            ?? currentGoalTimeBaselineSeconds
        let priorGenerationCompleted = savedID.map { id in
            goalAchievementTimelineEntries.contains { $0.id == id }
        } ?? false
        if savedID == nil || savedObjective != goal.objective || (goal.status == "active" && priorGenerationCompleted) {
            let generationID = UUID().uuidString
            let hasPreviousGoalGeneration = savedID != nil || !goalAchievementTimelineEntries.isEmpty
            let timeBaseline = hasPreviousGoalGeneration ? Double(goal.timeUsedSeconds ?? 0) : 0
            currentGoalGenerationID = generationID
            currentGoalObjective = goal.objective
            currentGoalTimeBaselineSeconds = timeBaseline
            defaults.set(generationID, forKey: goalGenerationDefaultsKey)
            defaults.set(goal.objective, forKey: goalGenerationObjectiveDefaultsKey)
            defaults.set(timeBaseline, forKey: goalGenerationTimeBaselineDefaultsKey)
        } else {
            currentGoalGenerationID = savedID
            currentGoalObjective = goal.objective
            let timeBaseline = savedTimeBaseline ?? 0
            currentGoalTimeBaselineSeconds = timeBaseline
            defaults.set(timeBaseline, forKey: goalGenerationTimeBaselineDefaultsKey)
        }
    }

    private func goalElapsedTime(for goal: CodexThreadGoal, reportedSeconds: Double? = nil) -> Double {
        let seconds = reportedSeconds ?? Double(goal.timeUsedSeconds ?? 0)
        return max(0, seconds - (currentGoalTimeBaselineSeconds ?? 0))
    }

    private func persistGoalAchievementTimeline() {
        guard let data = try? JSONEncoder().encode(goalAchievementTimelineEntries) else { return }
        WorkspaceSettings.preferencesStore.set(data, forKey: goalAchievementTimelineDefaultsKey)
    }

    private func fallbackGoalCompletionAnchorID(in historyMessages: [ConversationMessage], objective: String) -> String {
        if let goalMessage = historyMessages.last(where: { $0.role == .user && $0.text == objective }),
           let turnID = goalMessage.turnID,
           let finalMessage = historyMessages.last(where: { $0.turnID == turnID }) {
            return finalMessage.id
        }
        return historyMessages.last?.id ?? GoalAchievementTimelineEntry.beforeFirstMessageID
    }

    private func refreshGoalConversation(keepingShownTurn: Bool = false) async {
        do {
            let history = try await conversationManager.history(
                taskID: task.id,
                messageLimit: max(Self.historyPageSize, messages.count),
                onActionRequest: { actionNotice = approvalNotice }
            )
            // This is how a window learns that a recovery it did not send has died:
            // history hides the saved question only while that recovery runs.
            if userInputRequest == nil, let saved = history.pendingUserInputRequest,
               saved.threadID == task.activeConversationID,
               !answeredUserInputRequestIDs.contains(saved.id) {
                userInputRequest = saved
            }
            // A provider may not list a running turn's items yet, so mid-turn history can
            // hold less than this window already shows; applying it would blank the turn.
            let historyCount = history.messages.count + (history.earlierMessageCount ?? 0)
            if keepingShownTurn, historyCount < messages.count + earlierStoredMessageCount { return }
            applyHistoryMessages(history)
            activities = history.activities
            providerBoundaries = history.providerBoundaries
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reloads history for a turn this window isn't streaming. A running turn
    /// can bump the revision many times a second, so reloads run one at a
    /// time and at most once a second, and the newest revision always loads.
    private func followHistory() {
        followedHistoryIsStale = true
        guard !isFollowingHistory else { return }
        isFollowingHistory = true
        Task { @MainActor in
            while followedHistoryIsStale, followedTurnStreams == 0 {
                followedHistoryIsStale = false
                await refreshGoalConversation(keepingShownTurn: providerTurnIsActive)
                try? await Task.sleep(for: .seconds(1))
            }
            isFollowingHistory = false
        }
    }

    private static func goalDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func goalAchievementSummary(_ goal: CodexThreadGoal) -> String {
        guard goal.timeUsedSeconds != nil else { return "Goal achieved" }
        return "Goal achieved in \(Self.goalDuration(goalElapsedTime(for: goal)))"
    }

    private static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    private static func elapsedSeconds(since start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start).rounded(.down)))
    }

    private func refreshQueuedMessages() {
        queuedMessages = (try? conversationManager.queuedMessages(taskID: task.id)) ?? []
        answeredAsyncQuestionIDs = Set((try? conversationManager.answeredAsyncQuestionIDs(taskID: task.id)) ?? [])
    }

    private func refreshChatPageStatus() {
        guard let chatManager = try? StandaloneChatManager(dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]) else {
            chatPagesByTurnID = [:]
            return
        }
        chatPagesByTurnID = (try? chatManager.pageAssignmentsByTurnID()) ?? [:]
    }

    private func standaloneChatPageSeparator(before message: ConversationMessage) -> StandaloneChatPage? {
        guard task.isStandaloneChat,
              let turnID = message.turnID,
              let page = chatPagesByTurnID[turnID],
              let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        let previousTurnID = messages[..<messageIndex].last(where: { $0.turnID != nil })?.turnID
        guard previousTurnID.flatMap({ chatPagesByTurnID[$0]?.id }) != page.id else { return nil }
        return page
    }

    /// Pages that the pending annotations quote from, excluding the page this turn already runs
    /// in. Only standalone chat has pages, so task conversations always send an empty list.
    private func standaloneChatPageIDs(for pendingAnnotations: [ConversationAnnotation]) -> [String] {
        guard task.isStandaloneChat, !pendingAnnotations.isEmpty else { return [] }
        let activePageID = messages.last(where: { $0.turnID != nil })?.turnID.flatMap { chatPagesByTurnID[$0]?.id }
        var pageIDs: [String] = []
        for annotation in pendingAnnotations {
            guard let turnID = messages.first(where: { $0.id == annotation.messageID })?.turnID,
                  let pageID = chatPagesByTurnID[turnID]?.id,
                  pageID != activePageID, !pageIDs.contains(pageID) else { continue }
            pageIDs.append(pageID)
        }
        return pageIDs
    }

    private func standaloneChatPageSeparator(_ page: StandaloneChatPage) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.primary.opacity(0.13)).frame(height: 1)
            Text(page.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("chat-page-separator")
            Rectangle().fill(Color.primary.opacity(0.13)).frame(height: 1)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private func queueDraftForAfterTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDataURLs = pendingImages.map(\.dataURL)
        guard !text.isEmpty || !imageDataURLs.isEmpty else { return }
        do {
            _ = try conversationManager.queueMessage(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
            clearHandedOffDraft()
            refreshQueuedMessages()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeQueuedMessage(_ message: QueuedConversationMessage) {
        do {
            try conversationManager.removeQueuedMessage(taskID: task.id, messageID: message.id)
            refreshQueuedMessages()
        } catch { errorMessage = error.localizedDescription }
    }

    private func steerQueuedMessage(_ message: QueuedConversationMessage) {
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let outcome = try await conversationManager.steerQueuedMessage(taskID: task.id, messageID: message.id)
                refreshQueuedMessages()
                guard outcome.accepted else {
                    if let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize) {
                        applyHistoryMessages(history)
                        activities = history.activities
                        answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                    }
                    errorMessage = nil
                    return
                }
                showLocalSteer(outcome.message, imageDataURLs: outcome.imageDataURLs)
                refreshQueuedMessages()
                errorMessage = nil
            } catch {
                refreshQueuedMessages()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func steerCurrentTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDataURLs = pendingImages.map(\.dataURL)
        guard !text.isEmpty || !imageDataURLs.isEmpty else { return }
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let accepted = try await conversationManager.steer(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
                guard accepted else {
                    _ = try await conversationManager.queueMissedSteer(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
                    clearHandedOffDraft()
                    refreshQueuedMessages()
                    if let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize) {
                        applyHistoryMessages(history)
                        activities = history.activities
                    }
                    errorMessage = nil
                    return
                }
                showLocalSteer(text, imageDataURLs: imageDataURLs)
                clearHandedOffDraft()
                errorMessage = nil
            } catch {
                refreshQueuedMessages()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retryQueuedMessage(_ message: QueuedConversationMessage) {
        Task { @MainActor in
            do {
                let retried = try await conversationManager.retryQueuedMessage(taskID: task.id, messageID: message.id, onUserInput: { request in
                    showUserInputRequest(request)
                })
                guard retried else {
                    throw BridgeCommandError(code: "operation_failed", message: "The queued follow-up still needs your attention.")
                }
                let history = try await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize)
                applyHistoryMessages(history)
                activities = history.activities
                answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                refreshQueuedMessages()
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func addImageData(_ data: Data) throws {
        let wasOversizedInput = data.count > 10_000_000
        let bitmap = wasOversizedInput
            ? Self.thumbnailBitmap(from: data)
            : NSBitmapImageRep(data: data)
        guard let bitmap else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        try addImage(bitmap, preferJPEG: wasOversizedInput)
    }

    private static func thumbnailBitmap(from data: Data) -> NSBitmapImageRep? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                ] as CFDictionary
              ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    private func addImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) throws {
        guard pendingImages.count < 8 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        guard let encoded = Self.encodedImage(bitmap, preferJPEG: preferJPEG), encoded.data.count <= 10_000_000 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        let previewData = preferJPEG
            ? bitmap.representation(using: .png, properties: [:])
            : encoded.data
        guard let previewData, let previewImage = NSImage(data: previewData) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        pendingImages.append(PendingImage(dataURL: "data:\(encoded.mimeType);base64,\(encoded.data.base64EncodedString())", image: previewImage))
        persistDraft()
    }

    /// Text and images handed to the active turn or the queue leave the saved draft
    /// at once, so reopening the task doesn't restore them to the composer.
    private func clearHandedOffDraft() {
        composerDraft.settledText = ""
        draft = ""
        pendingImages.removeAll()
        persistDraft()
    }

    /// Saves the composer's text and images together as the task's draft, during a turn
    /// as well as between turns. Values are captured now, so a save still completes after
    /// the view goes away.
    private func persistDraft(reportingErrors: Bool = true) {
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        let text = draft
        let images = pendingImages.map(\.dataURL)
        let taskID = task.id
        let taskManager = BoardTaskManager(modelContext: modelContext)
        composerDraft.settledText = text
        Task { @MainActor in
            do {
                _ = try await taskManager.saveDraft(taskID, prompt: text, imageDataURLs: images)
            } catch {
                if reportingErrors { errorMessage = error.localizedDescription }
            }
        }
    }

    private static func encodedImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) -> (data: Data, mimeType: String)? {
        if preferJPEG,
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
           jpeg.count <= 10_000_000 {
            return (jpeg, "image/jpeg")
        }
        if !preferJPEG,
           let png = bitmap.representation(using: .png, properties: [:]), png.count <= 10_000_000 {
            return (png, "image/png")
        }

        let maximumDimension = 1600
        let scale = min(1, Double(maximumDimension) / Double(max(bitmap.pixelsWide, bitmap.pixelsHigh)))
        var width = max(1, Int((Double(bitmap.pixelsWide) * scale).rounded()))
        var height = max(1, Int((Double(bitmap.pixelsHigh) * scale).rounded()))
        while width > 0 && height > 0 {
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            guard let context = NSGraphicsContext(bitmapImageRep: resized) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            bitmap.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
                if let jpeg = resized.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= 10_000_000 {
                    return (jpeg, "image/jpeg")
                }
            }
            guard width > 1, height > 1 else { return nil }
            width = max(1, Int(Double(width) * 0.85))
            height = max(1, Int(Double(height) * 0.85))
        }
        return nil
    }

    private static func image(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    private func saveAndBack() {
        draftAutosaveTask?.cancel()
        if userInputRequest != nil {
            userInputRequest = nil
            Task { @MainActor in
                await Task.yield()
                onBack()
            }
            return
        }
        if isReadOnly { onBack(); return }
        if isResponding {
            // The turn keeps running, and so does the draft typed beside it.
            if isDraftUnsaved { persistDraft() }
            onBack()
            return
        }
        let hasStartedRepository = task.repositoryWorktrees.contains { !$0.isPending }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Folder-only context is not work in progress: an otherwise empty new task is discarded.
        if isNewTask, !hasStartedRepository,
           pendingImages.isEmpty, messages.isEmpty, activities.isEmpty,
           !hasDraft, !isLoadingHistory {
            Task { @MainActor in
                do {
                    try await BoardTaskManager(modelContext: modelContext).delete(task.id)
                    onBack()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        if isDraftUnsaved, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let images = pendingImages.map(\.dataURL)
            Task { @MainActor in
                do {
                    _ = try await BoardTaskManager(modelContext: modelContext).saveDraft(task.id, prompt: "", imageDataURLs: images)
                    composerDraft.settledText = draft
                    await saveDraftAndGenerateTitle(status: nil, then: onBack)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        Task { @MainActor in _ = await saveDraftAndGenerateTitle(status: nil, then: onBack) }
    }

    private static let hiddenRecoveryReplyText = "[Response to private answer hidden]"

    private func showStreamedRecoveryReplies() {
        for index in messages.indices where messages[index].text == Self.hiddenRecoveryReplyText {
            if let text = streamedRecoveryReplies[messages[index].id] { messages[index].text = text }
        }
    }

    /// Shows a question; the same question can arrive again, so keep its answers.
    private func showUserInputRequest(_ request: ConversationUserInputRequest) {
        let isNewQuestion = request.id != userInputRequest?.id
        userInputRequest = request
        guard isNewQuestion else { return }
        userInputAnswers = [:]
        userInputOther = [:]
        userInputOtherSelected = []
    }

    private func showLocalSteer(_ text: String, imageDataURLs: [String] = []) {
        if let index = unconfirmedStreamedSteers.firstIndex(of: text) {
            unconfirmedStreamedSteers.remove(at: index)
            return
        }
        unechoedLocalSteers.append(text)
        messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: text, imageDataURLs: imageDataURLs))
    }

    /// Autosaves typed text while the agent responds as well as between turns. Composer
    /// changes that need no save (a restored draft, or the empty composer a send leaves)
    /// match the settled text and are skipped.
    private func scheduleDraftAutosave(_ value: String) {
        draftAutosaveTask?.cancel()
        guard !isReadOnly, !isLoadingHistory, value != composerDraft.settledText else { return }
        draftAutosaveTask = Task { @MainActor in
            // Let AppKit finish a burst of synthesized keystrokes before the
            // main-actor SwiftData write starts. This keeps long XCTest
            // `typeText` operations responsive while retaining prompt
            // autosave once typing settles.
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, !isLoadingHistory, draft == value else { return }
            persistDraft()
        }
    }

    @discardableResult
    private func saveDraftAndGenerateTitle(
        status: TaskStatus?,
        prompt submittedPrompt: String? = nil,
        generateTitle: Bool = true,
        reserveTitleForSend: Bool = false,
        sendsComposerDraft: Bool = false,
        then completion: (() -> Void)? = nil
    ) async -> Bool {
        let prompt = (submittedPrompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            // An image-only send has no prompt to submit, but its draft is no longer unsent. Its
            // images leave the draft once the turn starts.
            if sendsComposerDraft {
                do {
                    _ = try await BoardTaskManager(modelContext: modelContext).savePrompt(task.id, prompt: "")
                } catch {
                    errorMessage = error.localizedDescription
                    return false
                }
            }
            if task.title == "Generating title…", task.pendingSubmittedPrompt == nil {
                _ = try? await BoardTaskManager(modelContext: modelContext).renameIfTitleMatches(
                    task.id,
                    expectedTitle: "Generating title…",
                    title: "Untitled task"
                )
            }
            completion?()
            return true
        }
        let taskManager = BoardTaskManager(modelContext: modelContext)
        var shouldGenerateTitle = false
        do {
            // Without a status change this saves the composer's draft, text and images together.
            let savedTask = status == nil && !reserveTitleForSend
                ? try await taskManager.saveDraft(task.id, prompt: prompt, imageDataURLs: pendingImages.map(\.dataURL))
                : try await taskManager.savePrompt(
                    task.id,
                    prompt: prompt,
                    status: status,
                    submitted: reserveTitleForSend,
                    replacingDraft: sendsComposerDraft
                )
            if status == nil && !reserveTitleForSend { composerDraft.settledText = draft }
            if generateTitle, ["Generating title…", "Untitled task"].contains(savedTask.title) {
                shouldGenerateTitle = try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: savedTask.title,
                    title: "Generating title…"
                ) != nil
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        completion?()
        guard shouldGenerateTitle else { return true }
        isGeneratingTitle = true
        Task { @MainActor in
            let generated = await generateTaskTitle(from: prompt)
            let title = generated?.title
            let titleSource = generated?.provider.rawValue ?? "prompt-fallback"
            let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
            let taskManager = BoardTaskManager(modelContext: modelContext)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            do {
                guard try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: "Generating title…",
                    title: resolvedTitle
                ) != nil else {
                    let currentTitle = (try? taskManager.taskModel(task.id).title) ?? ""
                    PlayhouseDiagnostics.record("task.title_apply.skipped", fields: [
                        "taskID": task.id.uuidString,
                        "reason": "title_changed",
                        "currentTitleState": PlayhouseTaskTitleDiagnostics.state(of: currentTitle),
                        "titleSource": titleSource
                    ])
                    isGeneratingTitle = false
                    return
                }
                PlayhouseDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": task.id.uuidString,
                    "titleSource": titleSource,
                    "fallbackWordCount": title == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
                ])
            } catch {
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["taskID"] = task.id.uuidString
                fields["titleSource"] = titleSource
                PlayhouseDiagnostics.record("task.title_apply.failed", fields: fields)
            }
            isGeneratingTitle = false
        }
        return true
    }

    private func generateTaskTitle(from prompt: String) async -> (title: String, provider: ConversationProvider)? {
        await conversationManager.generateTitle(taskID: task.id, prompt: prompt)
    }

    private var providerMenu: some View {
        Menu {
            ForEach(ConversationProvider.allCases) { option in
                Button {
                    switchProvider(to: option)
                } label: {
                    if option == provider {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
                .buttonHoverPointer()
                .help("Run this task's next turns with \(option.displayName)")
                .accessibilityIdentifier("conversation-provider-\(option.rawValue)")
            }
        } label: {
            Text(provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonHoverPointer()
        .disabled(!canSwitchProvider)
        .nativeHelp(providerMenuHelp)
        .accessibilityLabel("Provider: \(provider.displayName)")
        .accessibilityValue(provider.rawValue)
        .accessibilityIdentifier("conversation-provider-menu")
    }

    private var providerMenuHelp: String {
        canSwitchProvider
            ? "Choose which assistant runs this task"
            : "Wait for the current turn, questions, and queued follow-ups to finish before switching"
    }

    private func switchProvider(to newProvider: ConversationProvider) {
        guard newProvider != provider, canSwitchProvider else { return }
        isSwitchingProvider = true
        Task { @MainActor in
            defer { isSwitchingProvider = false }
            do {
                _ = try await conversationManager.setProvider(taskID: task.id, provider: newProvider)
                isEnteringGoal = false
                errorMessage = nil
                providerNotice = nil
                modelOptions = []
                await loadConversation()
                await loadModels()
                await loadProviderNotice()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Puts `/skill-name` at the start of the draft and returns to the
    /// conversation. Claude Code runs it as a slash command; Codex receives the
    /// skill itself alongside the message.
    private func useSkill(_ skill: SkillRecord) {
        let token = "/" + skill.name
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.hasPrefix(token + " "), rest != token {
            draft = rest.isEmpty ? token + " " : token + " " + rest
        }
        isShowingSkills = false
        composerDraft.focusRequest += 1
    }

    /// The skill gallery as a full page that slides in from the trailing side
    /// over the task, and back out when it closes.
    private var skillsPage: some View {
        ZStack {
            if isShowingSkills {
                SkillsPageView(
                    task: task, manager: conversationManager, onUse: useSkill,
                    onFixTask: { taskID, prompt in
                        isShowingSkills = false
                        onOpenTask(taskID, prompt)
                    }
                ) {
                    isShowingSkills = false
                    composerDraft.focusRequest += 1
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.25), radius: 16, x: -4)
                .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(isShowingSkills)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: isShowingSkills)
    }

    /// Summarizes how the selected provider's native configuration differs, so a
    /// switch doesn't silently change which skills or MCP servers are available.
    private func loadProviderNotice() async {
        guard let capabilities = try? await conversationManager.providerCapabilities(taskID: task.id),
              let current = capabilities.first(where: { $0.provider == provider }) else { return }
        if let error = current.error, !current.isAvailable {
            providerNotice = error
            return
        }
        var parts: [String] = []
        switch provider {
        case .claude:
            parts.append("Claude uses its own settings: \(current.skills.count) skills and commands, \(current.mcpServers.count) MCP servers.")
        case .codex:
            parts.append("Codex runs without MCP servers, apps, or hooks.")
        }
        parts.append(provider.supportsGoals ? "Goals are available." : "Goals are available only with Codex.")
        parts.append("Earlier turns are shared as text context on the next message.")
        providerNotice = parts.joined(separator: " ")
    }

    private func pauseResponse() {
        guard isResponding, !isPausingResponse else { return }
        isPausingResponse = true
        Task { @MainActor in
            do {
                let interrupted = try await conversationManager.interrupt(taskID: task.id)
                guard interrupted else {
                    isPausingResponse = false
                    return
                }
            } catch {
                isPausingResponse = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func continueResponse() {
        guard hasPausedResponse else { return }
        sendMessage(overrideText: "Continue with the same request from where you left off.")
    }

    private func activatePlanMode() {
        isEnteringGoal = false
        setConversationMode(.plan)
        draft = ""
    }

    private var conversationModeDefaultsKey: String {
        TaskPreferenceKeys.conversationMode(taskID: task.id)
    }

    private func setConversationMode(_ mode: ConversationMode) {
        conversationMode = mode
        WorkspaceSettings.preferencesStore.set(mode.rawValue, forKey: conversationModeDefaultsKey)
    }

    private func startImplementingPlan() {
        isEnteringGoal = false
        setConversationMode(.code)
        sendMessage(overrideText: "Start implementing the plan.")
    }

    private var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Provider-owning operations run in the bridge daemon, not in this window.
    private var conversationManager: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    private var workspaceManager: WorkspaceManager {
        WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
    }

    private func updateWorkspaceRoots(_ roots: [URL]) {
        Task { @MainActor in
            do {
                _ = try await WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
                    .setRoots(roots.map { $0.standardizedFileURL.path }, for: task.id)
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't save working folders: \(error.localizedDescription)"
            }
        }
    }

    private func saveConversationRepository(_ original: RepositoryWorktreeRecord, field: String) {
        let branch = editedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchFrom = editedBranchFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeTarget = editedMergeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branchFrom.isEmpty else {
            errorMessage = "Branch and merge-from values can't be empty."
            return
        }
        Task { @MainActor in
            do {
                let saved = try await BoardTaskManager(modelContext: modelContext).updateRepository(
                    task.id,
                    repositoryPath: original.repositoryPath,
                    branch: branch,
                    branchFrom: branchFrom,
                    mergeTarget: mergeTarget.isEmpty ? nil : mergeTarget
                )
                // The popover stays open on the saved value so another field can be edited next.
                if editingRepositoryField == field {
                    editingRepositoryField = nil
                    // Show what was saved, which can differ from what was typed: a branch-from
                    // found only on the remote is saved as its remote-tracking branch.
                    if let record = saved.repositoryWorktrees.first(where: { $0.repositoryPath == original.repositoryPath }) {
                        editedBranch = record.branch
                        editedBranchFrom = record.branchFrom
                        editedMergeTarget = record.mergeTarget ?? ""
                    }
                }
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't save repository settings: \(error.localizedDescription)"
            }
        }
    }

    /// The stored settings for a repository, read fresh so an edit starts from what is saved.
    private func currentRepositoryRecord(_ repository: RepositoryWorktreeRecord) -> RepositoryWorktreeRecord {
        task.repositoryWorktrees.first { $0.repositoryPath == repository.repositoryPath } ?? repository
    }

    private func resetRepositoryEdits(to repository: RepositoryWorktreeRecord) {
        let current = currentRepositoryRecord(repository)
        editedBranch = current.branch
        editedBranchFrom = current.branchFrom
        editedMergeTarget = current.mergeTarget ?? ""
    }

    private func beginRepositoryFieldEdit(_ field: String, repository: RepositoryWorktreeRecord) {
        // Only one field is edited at a time; switching fields drops the unsaved one.
        resetRepositoryEdits(to: repository)
        editingRepositoryField = field
        DispatchQueue.main.async { focusedRepositoryField = field }
    }

    private func cancelRepositoryFieldEdit(_ repository: RepositoryWorktreeRecord) {
        guard editingRepositoryField != nil else { return }
        resetRepositoryEdits(to: repository)
        editingRepositoryField = nil
        focusedRepositoryField = nil
    }

    @ViewBuilder
    private func repositoryDetailRow(
        _ title: String,
        value: Binding<String>,
        field: String,
        placeholder: String,
        identifier: String,
        repository: RepositoryWorktreeRecord
    ) -> some View {
        let editable = repository.isPending
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                .allowsHitTesting(false)
            if editable, editingRepositoryField == field {
                TextField(placeholder, text: value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focusedRepositoryField, equals: field)
                    .onSubmit { saveConversationRepository(repository, field: field) }
                    .onKeyPress(.escape) {
                        cancelRepositoryFieldEdit(repository)
                        return .handled
                    }
                    .accessibilityIdentifier(identifier)
                    .padding(.leading, 9).padding(.trailing, 34).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                    .overlay(alignment: .trailing) {
                        Button { saveConversationRepository(repository, field: field) } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain)
                        .nativeHelp("Save \(title)")
                        .accessibilityLabel("Save \(title)")
                        .accessibilityIdentifier("\(identifier)-save")
                        .padding(.trailing, 5)
                    }
            } else {
                let displayValue = value.wrappedValue.isEmpty ? placeholder : value.wrappedValue
                HStack(spacing: 3) {
                    Text(displayValue)
                        .fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                        .allowsHitTesting(false)
                        .accessibilityLabel(displayValue)
                        .accessibilityIdentifier("\(identifier)-value")
                    if editable {
                        Button {
                            beginRepositoryFieldEdit(field, repository: repository)
                        } label: {
                            EditPencilShape()
                                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 14)
                                .frame(width: 22, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain).nativeHelp("Edit \(title)").accessibilityLabel("Edit \(title)")
                        .accessibilityIdentifier("\(identifier)-edit")
                    }
                }
                .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 34)
    }

    private func removeConversationRepository(_ repository: RepositoryWorktreeRecord) {
        Task { @MainActor in
            do {
                _ = try await WorkspaceManager(
                    taskManager: BoardTaskManager(modelContext: modelContext)
                ).removeRepository(repository.repositoryPath, from: task.id)
                if repositoryBeingEdited?.repositoryPath == repository.repositoryPath { repositoryBeingEdited = nil }
                errorMessage = nil
                loadRecentRepositories()
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't remove repository: \(error.localizedDescription)"
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard !messages.isEmpty || !activities.isEmpty || activeGoal?.status == "complete" else { return }
        // A load in progress owns the scroll position: following the bottom now
        // would scroll past the question the transcript is about to pin.
        if isLatestConversationTurnPinPending {
            presentLatestConversationTurn(using: proxy)
            return
        }
        // While the newest turn still fits the viewport, keep its question
        // pinned to the top instead of following the bottom into the filler
        // that makes that pin reachable.
        if let turnStartID = latestConversationTurnStartID,
           oldestRenderedMessageID == turnStartID,
           latestTurnContentHeight > 0,
           latestTurnContentHeight + 2 * Self.conversationVerticalPadding <= viewportHeight {
            presentLatestConversationTurn(using: proxy)
            return
        }
        // Scroll to the real latest row. A synthetic target after LazyVStack can
        // be positioned using its estimated content height before the lazy rows
        // have settled, leaving the viewport in the blank space below the chat.
        let latestMessageID = renderedConversationMessages.last?.id
        // Defer until the state-driven content update has had a layout pass.
        let shouldAnimate = hasPresentedLatestConversation
        Task { @MainActor in
            await Task.yield()
            // Record the question this presentation lands on, so a newly sent
            // one is told apart from the one already in view.
            lastScrolledUserMessageID = renderedConversationMessages.last(where: { $0.role == .user })?.id
            let scroll = {
                // A pending question renders below the latest message.
                if let latestMessageID, userInputRequest == nil {
                    proxy.scrollTo(latestMessageID, anchor: .bottom)
                } else {
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                }
            }
            if shouldAnimate {
                withAnimation(.easeOut(duration: 0.2), scroll)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, scroll)
            }
            // A LazyVStack places rows it has not realized yet from estimated
            // heights, so the first scroll can stop short of the real last row.
            // Scrolling again after it has been realized lands on it.
            var settleTransaction = Transaction()
            settleTransaction.disablesAnimations = true
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(settleTransaction, scroll)
            }
            hasPresentedLatestConversation = true
        }
    }

    /// After the conversation is already settled, a newly sent question should land at the
    /// top of the viewport while its answer streams in below. The filler makes that pin the
    /// bottom of the transcript, so once the answer outgrows the viewport, following the
    /// bottom carries the reader along with it unless they have scrolled up.
    private func scrollToLatestUserMessage(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard hasPresentedLatestConversation else {
            scrollToLatest(using: proxy, viewportHeight: viewportHeight)
            return
        }
        guard let latestUserMessage = renderedConversationMessages.last(where: { $0.role == .user }),
              latestUserMessage.id != lastScrolledUserMessageID else { return }
        lastScrolledUserMessageID = latestUserMessage.id
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                // A question form that arrived with this turn renders below it and must stay
                // reachable, Submit included, so it wins over pinning the question to the top.
                if let request = userInputRequest, request.threadID == task.activeConversationID {
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                } else {
                    proxy.scrollTo(latestUserMessage.id, anchor: .top)
                }
            }
        }
    }
}

private final class ConversationScrollSample {
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
}

/// The parts of the transcript's scroll geometry that following the bottom and
/// revealing older messages depend on.
private struct ConversationScrollGeometry: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    /// The largest offset the content allows; the transcript is at its bottom
    /// when `offsetY` reaches it.
    var maxOffsetY: CGFloat
}

/// The scroll geometry measured from the content's own frame, for macOS 14,
/// where the scroll view does not report it.
private struct ConversationScrollGeometryKey: PreferenceKey {
    static var defaultValue: ConversationScrollGeometry?

    static func reduce(value: inout ConversationScrollGeometry?, nextValue: () -> ConversationScrollGeometry?) {
        value = nextValue() ?? value
    }
}

/// Reports the transcript's scroll geometry where the platform supports it.
/// The preference-based markers stay as the fallback for macOS 14.
private struct ConversationScrollOffsetObserver: ViewModifier {
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

private struct ConversationTopMarkerPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationLatestTurnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// Only the newest turn reports a height; every other view contributes the
    /// default, which must not replace the measurement.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Marks the row whose top starts the newest turn.
private struct ConversationLatestTurnStartKey: LayoutValueKey {
    static let defaultValue = false
}

/// Marks the view the layout stretches over the newest turn instead of stacking.
private struct ConversationLatestTurnExtentKey: LayoutValueKey {
    static let defaultValue = false
}

/// A leading-aligned vertical stack that keeps at least
/// `minimumLatestTurnHeight` from the top of the newest turn's first row to its
/// end, adding the difference as blank space below the last row. The extent
/// view is not stacked: it is laid over the newest turn at its natural height.
private struct ConversationTranscriptLayout: Layout {
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


// The native text view owns wrapping and document sizing. SwiftUI only receives
// a bounded viewport height; it never asks a multiline TextField for its ideal size.
private struct NativeChatEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    /// Each new value moves the keyboard into the editor once, with the caret at the end.
    let focusRequest: Int
    let isEnabled: Bool
    let autofocusOnAppear: Bool
    let accessibilityHelp: String
    let onSubmit: () -> Void
    let onSteerSubmit: () -> Void
    let onPasteImage: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatEditorScrollView {
        let scroll = ChatEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = ChatEditorTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        editor.isRichText = false
        // Prompts carry code and commands; send exactly the quotes and dashes the user typed.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .textColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 28)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityIdentifier("message-composer")
        editor.setAccessibilityLabel("Message")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.onHeightChange = { [weak coordinator = context.coordinator] height in
            // AppKit layout must finish before updating SwiftUI state.
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll, scroll.viewportHeight == height else { return }
                if coordinator?.parent.height != height { coordinator?.parent.height = height }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: ChatEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatEditorTextView else { return }
        editor.onSubmit = onSubmit
        editor.onSteerSubmit = onSteerSubmit
        editor.onPasteImage = onPasteImage
        editor.isEditable = isEnabled
        editor.isSelectable = isEnabled
        editor.setAccessibilityHelp(accessibilityHelp)
        scroll.shouldFocusEditor = isFocused && isEnabled
        scroll.shouldAutofocusEditor = autofocusOnAppear && isEnabled
        let editorOwnsEditing = isFocused && editor.window?.firstResponder === editor
        if editor.string != text, !editorOwnsEditing {
            editor.string = text
            editor.undoManager?.removeAllActions()
            scroll.requestTextLayout()
        }
        if isFocused, isEnabled, editor.window?.firstResponder !== editor {
            if let window = editor.window {
                window.makeFirstResponder(editor)
            } else {
                DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                    guard let editor,
                          let coordinator,
                          coordinator.parent.isFocused,
                          coordinator.parent.isEnabled else { return }
                    editor.window?.makeFirstResponder(editor)
                }
            }
        }
        scroll.focusEditorIfNeeded()
        if focusRequest != context.coordinator.handledFocusRequest, isEnabled {
            context.coordinator.handledFocusRequest = focusRequest
            // After this update, so a view that covered the editor has gone.
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.window?.makeFirstResponder(editor) == true else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeChatEditor
        var handledFocusRequest: Int
        init(_ parent: NativeChatEditor) {
            self.parent = parent
            handledFocusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ChatEditorTextView else { return }
            parent.text = editor.string
            (editor.enclosingScrollView as? ChatEditorScrollView)?.requestTextLayout()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    }
}

private final class ChatEditorScrollView: NSScrollView {
    var onHeightChange: ((CGFloat) -> Void)?
    var shouldFocusEditor = false
    var shouldAutofocusEditor = false
    private var didAutofocusEditor = false
    private(set) var viewportHeight: CGFloat = 28
    private var previousWidth: CGFloat = 0
    private var textLayoutNeeded = true
    private var layoutRequestGeneration = 0

    func requestTextLayout() {
        textLayoutNeeded = true
        layoutRequestGeneration += 1
        let generation = layoutRequestGeneration
        // Let NSTextView finish its edit/layout pass, then update the viewport
        // before another typing burst can reach the next wrapped line.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutRequestGeneration == generation else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.focusEditorIfNeeded()
        }
    }

    func focusEditorIfNeeded() {
        guard let window,
              let editor = documentView as? NSTextView,
              shouldFocusEditor || (shouldAutofocusEditor && !didAutofocusEditor) else { return }
        if window.makeFirstResponder(editor), shouldAutofocusEditor {
            didAutofocusEditor = true
        }
    }

    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 0, textLayoutNeeded || width != previousWidth else { return }
        textLayoutNeeded = false
        previousWidth = width
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        let font = editor.font ?? NSFont.systemFont(ofSize: 14)
        let inset = editor.textContainerInset
        let laidOutTextHeight: CGFloat
        if let layoutManager = editor.layoutManager, let textContainer = editor.textContainer {
            // Measure with the same TextKit container that wraps the live editor.
            // A separate boundingRect calculation ignores line-fragment padding,
            // so it can report one fewer line exactly as text crosses a wrap.
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            laidOutTextHeight = max(usedRect.maxY, layoutManager.extraLineFragmentRect.maxY)
        } else {
            laidOutTextHeight = 0
        }
        let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.2
        let contentHeight = ceil(max(lineHeight, laidOutTextHeight) + inset.height * 2)
        let documentHeight = max(28, contentHeight)
        editor.setFrameSize(NSSize(width: width, height: documentHeight))
        documentHeightDidChange(documentHeight)
    }

    func documentHeightDidChange(_ documentHeight: CGFloat) {
        let editor = documentView as? NSTextView
        let font = editor?.font ?? NSFont.systemFont(ofSize: 14)
        let lineHeight = editor?.layoutManager?.defaultLineHeight(for: font) ?? 17
        let verticalInset = editor?.textContainerInset.height ?? 4
        let maximumHeight = ceil(lineHeight * 12 + verticalInset * 2)
        let newHeight = min(maximumHeight, max(28, ceil(documentHeight)))
        if viewportHeight != newHeight {
            viewportHeight = newHeight
            onHeightChange?(newHeight)
        }
    }
}

private final class ChatEditorTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onSteerSubmit: (() -> Void)?
    var onPasteImage: ((Data) -> Void)?

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(), isEditable {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if event.modifierFlags.contains(.command) {
                onSteerSubmit?()
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        // Prefer the original image bytes. AppKit's NSImage object reader can
        // reject large clipboard representations before the composer gets a
        // chance to resize them for the 10 MB payload limit.
        if let data = pasteboard.data(forType: .png)
                    ?? pasteboard.data(forType: .tiff) {
            onPasteImage?(data)
        } else if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            if let data = image.tiffRepresentation {
                onPasteImage?(data)
            } else {
                super.paste(sender)
            }
        } else {
            super.paste(sender)
        }
    }
}

private struct SelectableAnnotationText: NSViewRepresentable {
    let text: String
    /// Commented ranges of `text`, rendered orange.
    let highlightedRanges: [NSRange]
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
            + responseAnnotations.map { "\($0.text):\($0.comment)" }.joined(separator: "|")
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
        for range in highlightedRanges {
            guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= value.length else { continue }
            value.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
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
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.responseCommentContentDidChange()
    }

    private static let responseCommentTextKey = NSAttributedString.Key("PlayhouseResponseCommentText")
    private static let responseCommentBodyKey = NSAttributedString.Key("PlayhouseResponseCommentBody")

    fileprivate static func replaceResponseAnnotationMarkers(in value: NSMutableAttributedString, references: [ResponseAnnotationReference]) {
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
        var responseCommentSourcePrefix: String
        weak var anchorView: NSTextView?
        var renderedKey = ""
        let measurer = TextHeightMeasurer()
        /// Room above a selection for the Add comment hint, centered 22pt above it and 30pt tall.
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
            let glyphs = view.layoutManager?.glyphRange(forCharacterRange: range, actualCharacterRange: nil) ?? NSRange(location: 0, length: 0)
            var bounds = view.layoutManager?.boundingRect(forGlyphRange: glyphs, in: view.textContainer!) ?? .zero
            bounds.origin.x += view.textContainerOrigin.x
            bounds.origin.y += view.textContainerOrigin.y
            // A selection that starts above the visible part of the transcript anchors its Add
            // comment hint, which sits above the selection, to the top of what is still visible.
            let visible = view.visibleRect
            if bounds.minY < visible.minY, bounds.maxY > visible.minY {
                let top = min(visible.minY + Self.selectionHintClearance, bounds.maxY)
                bounds.size.height = bounds.maxY - top
                bounds.origin.y = top
            }
            onSelection(range, text, bounds)
        }
    }
}

/// A discrete effort slider whose knob is an opaque white disc, so it stays solid over any track or popover background.
/// An undrawn native slider over the drawn effort track, so pointer clicks,
/// drags, and arrow keys behave exactly as a macOS slider's do.
private struct EffortAccessibilitySlider: NSViewRepresentable {
    @Binding var selection: ConversationEffort
    let choices: [ConversationEffort]

    final class InputSlider: NSSlider {
        // EffortStepSlider draws the control; this one only takes input.
        override func draw(_ dirtyRect: NSRect) {}
        // Clicking the effort track lets the arrow keys step it, as with the
        // visible slider, regardless of the Full Keyboard Access setting.
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }
    }

    final class Coordinator: NSObject {
        var parent: EffortAccessibilitySlider
        init(_ parent: EffortAccessibilitySlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) {
            let index = min(max(Int(sender.doubleValue.rounded()), 0), parent.choices.count - 1)
            parent.selection = parent.choices[index]
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> InputSlider {
        let slider = InputSlider(value: 0, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.allowsTickMarkValuesOnly = true
        slider.focusRingType = .none
        // The SwiftUI representation around it is what accessibility reads.
        slider.setAccessibilityElement(false)
        return slider
    }

    func updateNSView(_ slider: InputSlider, context: Context) {
        context.coordinator.parent = self
        slider.maxValue = Double(choices.count - 1)
        slider.numberOfTickMarks = choices.count
        slider.doubleValue = Double(choices.firstIndex(of: selection) ?? 0)
    }
}

private struct EffortStepSlider: View {
    @Binding var selection: ConversationEffort
    let choices: [ConversationEffort]

    private let knobDiameter: CGFloat = 20
    private let trackHeight: CGFloat = 6

    private var selectedIndex: Int { choices.firstIndex(of: selection) ?? 0 }
    private var stepCount: Int { max(choices.count - 1, 1) }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knobDiameter, 1)
            let knobX = travel * CGFloat(selectedIndex) / CGFloat(stepCount)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: knobX + knobDiameter / 2, height: trackHeight)
                ForEach(choices.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .offset(x: travel * CGFloat(index) / CGFloat(stepCount) + knobDiameter / 2 - 2)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: knobDiameter, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !choices.isEmpty else { return }
                let fraction = (value.location.x - knobDiameter / 2) / travel
                let index = min(Int((min(max(fraction, 0), 1) * CGFloat(stepCount)).rounded()), choices.count - 1)
                selection = choices[index]
            })
        }
        .frame(height: knobDiameter)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = choices[min(max(selectedIndex + delta, 0), choices.count - 1)]
        return .handled
    }
}
