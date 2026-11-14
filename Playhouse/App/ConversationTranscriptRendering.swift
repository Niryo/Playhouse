import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class TranscriptVirtualizer {
    private struct Measurement {
        var height: CGFloat
        var width: CGFloat
        /// What the rows showed when measured. A message whose rows change while it is a box,
        /// such as by tool calls, a comment or a reload arriving, renders and measures again.
        var signature: Int
    }

    /// Measured settled messages that render as real views. Only the settled rows read it, so
    /// changing it re-renders them alone.
    private(set) var realizedIDs: Set<String> = []
    /// Bumped when a resize rescales the boxes, so they redraw at their new heights at once.
    private(set) var boxRevision = 0
    @ObservationIgnored private var measurements: [String: Measurement] = [:]
    /// The settled messages in transcript order, as last rendered.
    @ObservationIgnored var order: [String] = []
    /// Top of the settled rows in the scroll content.
    @ObservationIgnored var sectionTop: CGFloat = 0
    @ObservationIgnored private(set) var width: CGFloat = 0
    @ObservationIgnored private var offsetY: CGFloat?
    @ObservationIgnored private var viewportHeight: CGFloat = 0
    /// The content span the realized rows were chosen for.
    @ObservationIgnored private var realizedSpan: ClosedRange<CGFloat>?
    @ObservationIgnored private var isRecomputeScheduled = false
    /// The settled message the reader was on when a resize began, and how far into it the
    /// viewport's top was, restored once the resize ends.
    @ObservationIgnored var resizeAnchor: (id: String, depth: CGFloat)?
    @ObservationIgnored var resizeAnchorTask: Task<Void, Never>?
    static let spacing: CGFloat = 16

    /// Whether a settled message renders as a real view, given the `realized` set the caller read
    /// in its body. The caller reads `realizedIDs` up front so it depends on it even while no row
    /// has been measured yet; otherwise the rows would never turn into boxes once measured.
    func isRealized(_ id: String, signature: Int, in realized: Set<String>) -> Bool {
        guard let measurement = measurements[id], measurement.signature == signature else { return true }
        return realized.contains(id)
    }

    /// The box a settled message takes while it is not rendered: the height it measured, scaled
    /// for a width change, since text grows taller roughly as its width shrinks.
    func boxHeight(_ id: String) -> CGFloat {
        guard let measurement = measurements[id] else { return 0 }
        guard width > 0, measurement.width > 0, abs(measurement.width - width) > 0.5 else { return measurement.height }
        return (measurement.height * measurement.width / width).rounded()
    }

    func record(_ id: String, height: CGFloat, signature: Int) {
        let previous = measurements[id]
        if let previous, abs(previous.height - height) < 0.5, abs(previous.width - width) < 0.5, previous.signature == signature { return }
        measurements[id] = Measurement(height: height, width: width, signature: signature)
        // A row measured for the first time, or again after its content changed, may lie outside
        // the viewport's surroundings.
        if previous == nil || previous?.signature != signature { scheduleRecompute() }
    }

    /// Notes a width change and reports whether it is one, as opposed to the first width seen.
    func updateWidth(_ newWidth: CGFloat) -> Bool {
        let isResize = width > 0 && abs(width - newWidth) > 0.5
        width = newWidth
        if isResize {
            invalidate()
            DispatchQueue.main.async { [weak self] in self?.boxRevision += 1 }
        }
        return isResize
    }

    /// The settled rows left the transcript, as on a reload to the newest turn; the width they
    /// report when they return is not a resize.
    func resetWidth() {
        width = 0
    }

    func updateViewport(offsetY: CGFloat, height: CGFloat) {
        self.offsetY = offsetY
        viewportHeight = height
        guard height > 0 else { return }
        // Rows are chosen for a span well beyond the viewport, and chosen again only once the
        // viewport nears that span's edge, so scrolling re-renders the rows now and then rather
        // than on every frame.
        let needed = (offsetY - height * 0.5)...(offsetY + height * 1.5)
        if let span = realizedSpan, span.lowerBound <= needed.lowerBound, span.upperBound >= needed.upperBound { return }
        scheduleRecompute()
    }

    func invalidate() {
        realizedSpan = nil
        scheduleRecompute()
    }

    /// The settled message at the top of the viewport and how far into it the viewport's top is,
    /// if the viewport's top is in the settled rows.
    func topVisibleAnchor() -> (id: String, depth: CGFloat)? {
        guard let offsetY else { return nil }
        var y = sectionTop
        for id in order {
            let height = boxHeight(id)
            if y + height > offsetY { return y <= offsetY + viewportHeight ? (id, offsetY - y) : nil }
            y += height + Self.spacing
        }
        return nil
    }

    /// Whether the viewport's top has drifted off `anchor` since it was taken, by more than a
    /// rounding of row heights. A width change that leaves the reader where they were, such as
    /// the scroller appearing, then needs no correction: scrolling would move the transcript
    /// under a reader who is following its bottom.
    func hasDrifted(from anchor: (id: String, depth: CGFloat)) -> Bool {
        guard let offsetY else { return false }
        var y = sectionTop
        for id in order {
            if id == anchor.id { return abs((offsetY - y) - anchor.depth) > 40 }
            y += boxHeight(id) + Self.spacing
        }
        return false
    }

    private func scheduleRecompute() {
        guard !isRecomputeScheduled else { return }
        isRecomputeScheduled = true
        // Measurements and scroll samples arrive during layout, which must not change state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isRecomputeScheduled = false
            recompute()
        }
    }

    private func recompute() {
        guard let offsetY, viewportHeight > 0 else { return }
        let span = (offsetY - viewportHeight * 1.5)...(offsetY + viewportHeight * 2.5)
        var y = sectionTop
        var realized = Set<String>()
        for id in order where measurements[id] != nil {
            let height = boxHeight(id)
            if y + height >= span.lowerBound, y <= span.upperBound { realized.insert(id) }
            y += height + Self.spacing
        }
        realizedSpan = span
        if realized != realizedIDs { realizedIDs = realized }
    }
}

/// Reports a value read from a view's geometry when the view first lays out and whenever it
/// changes. Measurements must include the first layout: a row that never changes height after
/// appearing would otherwise never be measured, and an unmeasured row always renders in full.
struct GeometryValueReporter<Value: Equatable>: ViewModifier {
    let value: (GeometryProxy) -> Value
    let action: (Value) -> Void

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let current = value(proxy)
                Color.clear
                    .onAppear { action(current) }
                    .onChange(of: current) { _, newValue in action(newValue) }
            }
        }
    }
}

extension View {
    func reportGeometry<Value: Equatable>(_ value: @escaping (GeometryProxy) -> Value, action: @escaping (Value) -> Void) -> some View {
        modifier(GeometryValueReporter(value: value, action: action))
    }
}

/// The settled messages, each either rendered or a box of its measured height. A box keeps the
/// message's ID, so scrolling to it still works.
struct SettledTranscriptRows: View {
    let ids: [String]
    /// Per message, a summary of what its rows show (see `TranscriptVirtualizer`).
    let signatures: [Int]
    let virtualizer: TranscriptVirtualizer
    /// Messages that render however far they are from the viewport: one holding the reader's
    /// text selection or an open side chat bubble, which is anchored inside the message's text
    /// and would close, losing its chat, if the message became a box.
    let pinnedIDs: Set<String>
    let row: (Int) -> AnyView

    var body: some View {
        let _ = virtualizer.boxRevision
        let realized = virtualizer.realizedIDs
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
            let signature = signatures[index]
            if pinnedIDs.contains(id) || virtualizer.isRealized(id, signature: signature, in: realized) {
                row(index)
                    .reportGeometry({ $0.size.height }) { height in
                        virtualizer.record(id, height: height, signature: signature)
                    }
            } else {
                Color.clear
                    .frame(height: virtualizer.boxHeight(id))
                    .id(id)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Which tool calls the reader expanded. It lives with the conversation rather than in each row:
/// a settled row that scrolls far away becomes a box and is rebuilt when it returns, and a newer
/// question moves rows out of the newest turn, and an expanded call should stay expanded through either.
@Observable
final class ToolCallExpansionState {
    var expandedIDs: Set<String> = []
}

/// One tool call in the conversation timeline: the tool's name and what the call was for, then
/// what it was given (IN) and what it returned (OUT), clipped to a few lines until expanded.
struct ToolCallTimelineRow: View {
    let activity: ConversationActivity
    let expansion: ToolCallExpansionState

    private var isExpanded: Bool {
        get { expansion.expandedIDs.contains(activity.id) }
        nonmutating set {
            if newValue { expansion.expandedIDs.insert(activity.id) } else { expansion.expandedIDs.remove(activity.id) }
        }
    }

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
struct TableBlockView: View {
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
    /// The vertical `fixedSize` lets a cell take the full height of its wrapped text; without it
    /// the `Grid` row settles on a shorter height and long cells are cut off with an ellipsis.
    private func cellText(_ cell: String, weight: Font.Weight = .regular) -> some View {
        let formatted = TaskConversationView.markdownNSAttributedString(cell, baseFont: font)
        return Text((try? AttributedString(formatted, including: \.appKit)) ?? AttributedString(cell))
            .font(.system(size: font.pointSize, weight: weight))
            .fixedSize(horizontal: false, vertical: true)
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

struct ResponseAnnotationReference {
    let text: String
    let comment: String
}

struct ResponseCommentHoverCard: View {
    let selectedText: String
    let comment: String
    @State private var isVisible = false

    /// Composed only of plugin atoms (Plugins/Atoms); it fades in.
    var body: some View {
        AtomPanel(
            props: PanelProps(spacing: 8, fill: "window", fillOpacity: 1, cornerRadius: 12),
            common: AtomCommon(
                testID: "response-comment-hover-card", label: "Highlighted text: \(selectedText). Comment: \(comment)",
                width: 320, padding: 0, paddingX: 12, paddingY: 12
            )
        ) {
            entry("Highlighted text", selectedText, testID: "response-comment-highlighted-text")
            entry("Comment", comment, testID: "response-comment-content")
        }
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.easeIn(duration: 0.12)) {
                isVisible = true
            }
        }
    }

    private func entry(_ caption: String, _ text: String, testID: String) -> some View {
        AtomStack(props: StackProps(spacing: 3, align: "leading")) {
            AtomText(props: TextProps(text: caption, size: 10, weight: "semibold", color: "secondary"))
            AtomText(props: TextProps(text: text, size: 12, lineLimit: 3), common: AtomCommon(testID: testID, label: text))
        }
    }
}

/// A text view whose height `TextHeightMeasurer` measures with its own layout manager. Measuring
/// sets the text container to each width SwiftUI asks about, and a width answered from the
/// measurer's cache leaves the container where the last uncached question put it, so the
/// container is matched to the view's own width again before the text is drawn.
class MeasuredTextView: NSTextView {
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

/// The bubble that opens on selected conversation text: a small side chat about the
/// selection, forked read-only from the task's conversation, whose Add comment button
/// turns what is typed into a comment on the selection instead of sending it. Clicking
/// commented or side-chatted text opens it again with that comment, which it edits, and
