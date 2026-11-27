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

    /// The status dot's color name.
    private var statusColor: String {
        switch activity.status.lowercased() {
        case "completed": "green"
        case "failed": "red"
        case "interrupted", "stopped": "orange"
        default: "accent"
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
        AtomStack(
            props: StackProps(axis: "h", spacing: 10, align: "top", group: true),
            common: AtomCommon(
                testID: "conversation-tool-call-\(activity.id)", label: "\(name) \(activity.statusLabel)",
                fillWidth: true, paddingY: 2
            )
        ) {
            // The dot is framed before its top padding, so the padding sits in an outer stack.
            AtomStack(common: AtomCommon(paddingTop: 6, decorative: true)) {
                AtomStack(props: StackProps(fill: statusColor, capsule: true), common: AtomCommon(width: 7, height: 7)) {
                    PHEmptyView()
                }
            }
            AtomStack(props: StackProps(spacing: 8, align: "leading")) {
                AtomStack(props: StackProps(axis: "h", spacing: 8, align: "baseline")) {
                    AtomText(
                        props: TextProps(text: name, size: 14, weight: "semibold", color: "text"),
                        common: AtomCommon(testID: "conversation-tool-call-name-\(activity.id)")
                    )
                    if !showsDetails, let commandPreview {
                        AtomText(
                            props: TextProps(text: commandPreview, size: 12, design: "monospaced", color: "secondary", lineLimit: 1, truncation: "tail"),
                            common: AtomCommon(testID: "conversation-tool-call-command-\(activity.id)", label: commandPreview)
                        )
                    } else if let summary {
                        AtomText(
                            props: TextProps(text: summary, size: 14, color: "secondary", lineLimit: 1, truncation: "middle"),
                            common: AtomCommon(testID: "conversation-tool-call-summary-\(activity.id)")
                        )
                    }
                    AtomSpacer(props: SpacerProps(minLength: 0))
                    if canExpand {
                        let hint = isExpanded ? "Show less" : "Show full input and output"
                        AtomButton(
                            common: AtomCommon(testID: "conversation-tool-call-toggle-\(activity.id)", label: hint, help: hint, width: 20, height: 20),
                            action: { phWithAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() } }
                        ) {
                            AtomIcon(props: IconProps(name: (isExpanded ? PHIcon.chevronUp : PHIcon.chevronDown).name, size: 11, weight: "semibold", color: "secondary"))
                        }
                    }
                }
                if showsDetails, activity.input != nil || output != nil {
                    AtomStack(props: StackProps(spacing: 0, align: "leading", fill: "input", cornerRadius: 8, stroke: "primary", strokeOpacity: 0.08)) {
                        if let input = activity.input {
                            ioRow(label: "IN", text: input, identifier: "conversation-tool-call-input-\(activity.id)")
                        }
                        if activity.input != nil, output != nil {
                            AtomDivider(common: AtomCommon(opacity: 0.35))
                        }
                        if let output {
                            ioRow(label: "OUT", text: output, identifier: "conversation-tool-call-output-\(activity.id)")
                        }
                    }
                }
            }
        }
    }

    private func ioRow(label: String, text: String, identifier: String) -> some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 12, align: "baseline"), common: AtomCommon(paddingX: 12, paddingY: 8)) {
            AtomText(
                props: TextProps(text: label, size: 11, weight: "medium", design: "monospaced", color: "secondary"),
                common: AtomCommon(width: 30, frameAlign: "leading", decorative: true)
            )
            AtomText(
                props: TextProps(
                    text: text, size: 12, design: "monospaced", color: "text",
                    lineLimit: isExpanded ? nil : Self.collapsedLineLimit, truncation: "tail", selectable: true
                ),
                common: AtomCommon(testID: identifier, label: "\(label) \(text)", fillWidth: true)
            )
        }
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
        // The fade sits outside the panel: a surfaced stack's own opacity would leave its fill opaque.
        AtomStack(common: AtomCommon(opacity: isVisible ? 1 : 0)) {
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
        }
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
