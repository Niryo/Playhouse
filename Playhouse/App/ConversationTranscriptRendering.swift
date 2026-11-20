import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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
    /// Starts the card's accessibility identifiers (`<prefix>-…-<blockID>`); nil leaves them unset.
    /// A Markdown atom passes its own testID, so its cards never match the transcript's.
    var identifierPrefix: String? = "assistant-markdown"

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
        let formatted = MarkdownInlineText.nsAttributedString(cell, baseFont: font)
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
                        .cardIdentifier(identifierPrefix.map { "\($0)-table-\(blockID)-header-\(column)" })
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
                            .cardIdentifier(identifierPrefix.map { "\($0)-table-\(blockID)-cell-\(rowIndex)-\(column)" })
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
        .cardIdentifier(identifierPrefix.map { "\($0)-table-\(blockID)" })
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
