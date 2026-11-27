import Foundation
import Observation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI
@Observable
package final class ComposerDraftModel {
    package var text = ""
    /// Bumped to put the keyboard back in the composer, such as after the Skills page closes.
    package var focusRequest = 0
    /// The editor's selected range, in UTF-16 offsets, for the composer's plugins.
    package var selection = NSRange(location: 0, length: 0)
    /// The composer text that needs no save: the draft last saved or restored, or the empty
    /// composer a send, steer, or queue left behind.
    @ObservationIgnored package var settledText = ""
    @ObservationIgnored package var autosaveTask: Task<Void, Never>?
    /// The latest pending-comment save; the next one waits for it.
    @ObservationIgnored package var annotationSaveTask: Task<Void, Never>?
}

/// Evaluates `content` in its own body, so Observation attributes the composer's draft reads to
/// this view rather than to the enclosing `TaskConversationView`.
package struct ComposerDraftScope<Content: PHView>: PHView {
    @PHViewBuilder package let content: () -> Content

    package var body: some PHView { content() }

    package init(@PHViewBuilder content: @escaping () -> Content) {
        self.content = content
    }
}
/// Tracks the pointer over one reply, so hovering it redraws only that reply and not the transcript.
/// An AppKit tracking area, not `onHover`: pressing the Copy message button ended SwiftUI's hover,
/// which hid the button before the press could complete.
package struct AssistantReplyHoverScope<Content: PHView>: PHView {
    @PHViewBuilder package let content: (_ isHovering: Bool) -> Content
    @PHState private var isHovering = false

    package var body: some PHView {
        content(isHovering)
            .background { // ATOM-GAP: no atom hands its content an AppKit-tracked hover state (AtomStack's onHover is SwiftUI hover, which ends when a press begins)
                PHHoverTracker { hovering in
                    if isHovering != hovering { isHovering = hovering }
                }
                .accessibilityHidden(true)
            }
    }

    package init(@PHViewBuilder content: @escaping (_ isHovering: Bool) -> Content) {
        self.content = content
    }
}

/// Copies a whole reply as the Markdown the agent wrote, tables and code fences included, which a
/// text selection can't do because tables and code blocks are separate views from the prose.
/// It shows while the pointer is over the reply, and stays while it confirms the copy.
package struct CopyMessageButton: PHView {
    package let markdown: String
    package let messageID: String
    package let isRevealed: Bool

    @PHState private var didCopy = false
    @PHState private var copyFeedbackToken = UUID()

    package var body: some PHView {
        let isShown = isRevealed || didCopy
        AtomButton(
            common: AtomCommon(
                testID: "assistant-copy-message-\(messageID)", label: "Copy message", value: didCopy ? "Copied" : "", help: "Copy message",
                width: 18, height: 16, opacity: isShown ? 1 : 0, passThrough: !isShown, decorative: !isShown
            ),
            action: {
                Platform.services.copyToClipboard(markdown)
                didCopy = true
                let token = UUID()
                copyFeedbackToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copyFeedbackToken == token { didCopy = false }
                }
            }
        ) {
            AtomIcon(props: IconProps(name: (didCopy ? PHIcon.checkmark : PHIcon.docOnDoc).name, size: 11, weight: "medium", color: "secondary"))
        }
    }

    package init(markdown: String, messageID: String, isRevealed: Bool) {
        self.markdown = markdown
        self.messageID = messageID
        self.isRevealed = isRevealed
    }
}
/// A deterministic "Recalling <page title>" line for a standalone chat page the agent loaded into
/// its context with `chat page read`. The title comes from the page archive, not the agent.
package struct ChatPageRecallRow: PHView {
    package let activityID: String
    package let pageID: String

    @PHState private var title: String?

    package var body: some PHView {
        let label = "Recalling \(title ?? "an earlier page")"
        AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(fillWidth: true, paddingY: 2)) {
            AtomIcon(props: IconProps(name: PHIcon.clockArrowCirclepath.name, size: 12, color: "secondary"))
            AtomText(props: TextProps(text: label, size: 14, color: "secondary", lineLimit: 1))
            AtomSpacer(props: SpacerProps(minLength: 0))
        }
        .accessibilitySummary(label, id: "conversation-chat-page-recall-\(activityID)")
        .task(id: pageID) {
            let directory = ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            title = (try? StandaloneChatManager(dataDirectory: directory).page(id: pageID))?.title
        }
    }

    package init(activityID: String, pageID: String) {
        self.activityID = activityID
        self.pageID = pageID
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

package struct AnnotationSelection: Identifiable {
    package let id = UUID()
    package let messageID: String
    /// The text view showing the selection, which anchors its side chat bubble: the first block
    /// of an assistant prose run, or 0 for a user message.
    package let anchorID: Int
    package let blockID: Int
    package let startOffset: Int
    package let endBlockID: Int
    package let endOffset: Int
    package let text: String
    package let bounds: CGRect
    /// Set when clicking commented or side-chatted text reopens its bubble: the comment
    /// and side chat it shows, which a new selection has neither of.
    package var annotationID: UUID? = nil
    package var sideChatID: String? = nil

    package var isReopened: Bool { annotationID != nil || sideChatID != nil }

    package var source: ConversationTextSource {
        ConversationTextSource(messageID: messageID, blockID: blockID, startOffset: startOffset, endBlockID: endBlockID, endOffset: endOffset)
    }

    package init(messageID: String, anchorID: Int, blockID: Int, startOffset: Int, endBlockID: Int, endOffset: Int, text: String, bounds: CGRect, annotationID: UUID? = nil, sideChatID: String? = nil) {
        self.messageID = messageID
        self.anchorID = anchorID
        self.blockID = blockID
        self.startOffset = startOffset
        self.endBlockID = endBlockID
        self.endOffset = endOffset
        self.text = text
        self.bounds = bounds
        self.annotationID = annotationID
        self.sideChatID = sideChatID
    }
}
