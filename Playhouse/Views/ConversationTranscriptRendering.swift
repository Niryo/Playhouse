import Foundation
import Observation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// Which tool calls the reader expanded. It lives with the conversation rather than in each row:
/// a settled row that scrolls far away becomes a box and is rebuilt when it returns, and a newer
/// question moves rows out of the newest turn, and an expanded call should stay expanded through either.
@Observable
package final class ToolCallExpansionState {
    package var expandedIDs: Set<String> = []
}

/// One tool call in the conversation timeline: the tool's name and what the call was for, then
/// what it was given (IN) and what it returned (OUT), clipped to a few lines until expanded.
/// A shell call collapses further, to one line with the start of its command, and shows what it
/// was for and its IN and OUT blocks only once expanded.
package struct ToolCallTimelineRow: PHView {
    package let activity: ConversationActivity
    package let expansion: ToolCallExpansionState

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

    private var statusColor: PHColor {
        switch activity.status.lowercased() {
        case "completed": .green
        case "failed": .red
        case "interrupted", "stopped": .orange
        default: .accentColor
        }
    }

    /// Both providers name their shell tool `Bash`, so Claude and Codex commands collapse alike.
    private var isShellCommand: Bool {
        activity.toolKind != "mcp" && activity.tool == "Bash" && (activity.input != nil || output != nil)
    }

    /// The collapsed shell row's preview: the command's first non-empty line, ending in an
    /// ellipsis when more lines follow. A first line too long for the row is cut by truncation.
    private var commandPreview: String? {
        let lines = (activity.input ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }
        return lines.count > 1 ? "\(first) …" : first
    }

    private var showsDetails: Bool { !isShellCommand || isExpanded }

    /// Whether either block holds more than its collapsed lines show.
    private var canExpand: Bool {
        if isShellCommand { return true }
        return [activity.input, output].compactMap { $0 }.contains { text in
            text.count > 240 || text.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLineLimit
        }
    }

    package var body: some PHView {
        PHHStack(alignment: .top, spacing: 10) {
            PHCircle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .accessibilityHidden(true)
            PHVStack(alignment: .leading, spacing: 8) {
                PHHStack(alignment: .firstTextBaseline, spacing: 8) {
                    PHText(name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(WorkspaceTheme.conversationText)
                        .accessibilityIdentifier("conversation-tool-call-name-\(activity.id)")
                    if !showsDetails, let commandPreview {
                        PHText(commandPreview)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .accessibilityLabel(commandPreview)
                            .accessibilityIdentifier("conversation-tool-call-command-\(activity.id)")
                    } else if let summary {
                        PHText(summary)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("conversation-tool-call-summary-\(activity.id)")
                    }
                    PHSpacer(minLength: 0)
                    if canExpand {
                        PHButton {
                            phWithAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
                        } label: {
                            PHImage(icon: isExpanded ? .chevronUp : .chevronDown)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(PHRectangle())
                        }
                        .buttonStyle(.plain)
                        .plainButtonHoverPointer()
                        .nativeHelp(isExpanded ? "Show less" : "Show full input and output")
                        .accessibilityLabel(isExpanded ? "Show less" : "Show full input and output")
                        .accessibilityIdentifier("conversation-tool-call-toggle-\(activity.id)")
                    }
                }
                if showsDetails, activity.input != nil || output != nil {
                    PHVStack(alignment: .leading, spacing: 0) {
                        if let input = activity.input {
                            ioRow(label: "IN", text: input, identifier: "conversation-tool-call-input-\(activity.id)")
                        }
                        if activity.input != nil, output != nil {
                            PHDivider().opacity(0.35)
                        }
                        if let output {
                            ioRow(label: "OUT", text: output, identifier: "conversation-tool-call-output-\(activity.id)")
                        }
                    }
                    .background(WorkspaceTheme.inputBackground, in: PHRoundedRectangle.phContinuous(cornerRadius: 8))
                    .overlay(PHRoundedRectangle.phContinuous(cornerRadius: 8).strokeBorder(PHColor.primary.opacity(0.08)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) \(activity.statusLabel)")
        .accessibilityIdentifier("conversation-tool-call-\(activity.id)")
    }

    private func ioRow(label: String, text: String, identifier: String) -> some PHView {
        PHHStack(alignment: .firstTextBaseline, spacing: 12) {
            PHText(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
                .accessibilityHidden(true)
            PHText(text)
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

    package init(activity: ConversationActivity, expansion: ToolCallExpansionState) {
        self.activity = activity
        self.expansion = expansion
    }
}
package struct ResponseCommentHoverCard: PHView {
    package let selectedText: String
    package let comment: String
    @PHState private var isVisible = false

    /// Composed only of plugin atoms (Plugins/Atoms); it fades in.
    package var body: some PHView {
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
            phWithAnimation(.easeIn(duration: 0.12)) {
                isVisible = true
            }
        }
    }

    private func entry(_ caption: String, _ text: String, testID: String) -> some PHView {
        AtomStack(props: StackProps(spacing: 3, align: "leading")) {
            AtomText(props: TextProps(text: caption, size: 10, weight: "semibold", color: "secondary"))
            AtomText(props: TextProps(text: text, size: 12, lineLimit: 3), common: AtomCommon(testID: testID, label: text))
        }
    }

    package init(selectedText: String, comment: String) {
        self.selectedText = selectedText
        self.comment = comment
    }
}
/// The bubble that opens on selected conversation text: a small side chat about the
/// selection, forked read-only from the task's conversation, whose Add comment button
/// turns what is typed into a comment on the selection instead of sending it. Clicking
/// commented or side-chatted text opens it again with that comment, which it edits, and
