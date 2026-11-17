import SwiftUI

/// The standalone chat's pages as the labels beside its transcript show them. It reads only
/// the newest pages, and older ones as the reader scrolls the labels up to them.
@MainActor
@Observable
final class ChatPageAnchorsModel {
    /// Pages read at a time.
    static let pageBatchSize = 40

    /// Pages that hold messages, oldest first.
    private(set) var pages: [StandaloneChatPage] = []
    private(set) var hasOlderPages = false
    /// The page at the top of the transcript's viewport.
    private(set) var currentPageID: String?
    /// The page a jump is reading.
    var loadingPageID: String?
    @ObservationIgnored private var limit = ChatPageAnchorsModel.pageBatchSize

    nonisolated init() {}

    func reload(from chatManager: StandaloneChatManager) {
        // One page past the limit tells whether older ones remain.
        let newest = (try? chatManager.listPages(limit: limit + 1)) ?? []
        let loaded = Array(newest.prefix(limit).filter { $0.messageCount > 0 }.reversed())
        if hasOlderPages != (newest.count > limit) { hasOlderPages = newest.count > limit }
        if loaded != pages { pages = loaded }
    }

    func clear() {
        pages = []
        hasOlderPages = false
    }

    func loadOlder() {
        guard hasOlderPages, let chatManager = Self.chatManager() else { return }
        limit += Self.pageBatchSize
        reload(from: chatManager)
    }

    /// The page the transcript shows. A page older than the labels read so far is read with
    /// the pages down to it, so its label exists to be marked.
    func setCurrentPage(_ pageID: String) {
        guard currentPageID != pageID else { return }
        if !pages.contains(where: { $0.id == pageID }), hasOlderPages, let chatManager = Self.chatManager() {
            var attempts = 0
            while hasOlderPages, attempts < 25, !pages.contains(where: { $0.id == pageID }) {
                limit += Self.pageBatchSize
                reload(from: chatManager)
                attempts += 1
            }
        }
        currentPageID = pageID
    }

    static func chatManager() -> StandaloneChatManager? {
        try? StandaloneChatManager(dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"])
    }
}

/// How the standalone chat's transcript shares its width with the page labels.
enum ChatPageAnchorsLayout {
    /// Below this transcript width the labels would leave too little room for messages.
    static let minimumTranscriptWidth: CGFloat = 380
    static let leadingInset: CGFloat = 12
    /// Where the transcript's rows start without the labels.
    static let transcriptPadding: CGFloat = 28
    static let transcriptMaxWidth: CGFloat = 820
    static let bubbleMaxWidth: CGFloat = 620

    /// The width the labels take from the transcript's rows: the gap that agent replies used
    /// to leave on their right, and whatever a wide chat has beyond a full-width message.
    static func rowInset(transcriptWidth: CGFloat) -> CGFloat {
        let rowWidth = min(transcriptWidth, transcriptMaxWidth) - transcriptPadding * 2
        return min(168, max(101, rowWidth - bubbleMaxWidth))
    }

    /// Labels in view at a time; older ones are scrolled to.
    static let visibleLabelCount = 15
    static let labelHeight: CGFloat = 14
    static let labelSpacing: CGFloat = 12
    static let labelsVerticalPadding: CGFloat = 6
    /// The gap between the last label and the jump-to-bottom button below it, and between the
    /// pin button and the first label above it.
    static let jumpToBottomSpacing: CGFloat = 4
    /// Where the handle of the unpinned labels sits from the transcript column's edge.
    static let handleInset: CGFloat = 6
    /// How the labels slide out from their handle, pushing the messages right, and back in.
    static let slideAnimation = Animation.easeInOut(duration: 0.22)

    /// The height that shows `count` labels, at most `visibleLabelCount` of them.
    static func labelsHeight(count: Int) -> CGFloat {
        let rows = CGFloat(max(1, min(count, visibleLabelCount)))
        return rows * labelHeight + (rows - 1) * labelSpacing + labelsVerticalPadding * 2
    }

    /// Where the transcript's centered column starts.
    static func columnLeading(transcriptWidth: CGFloat) -> CGFloat {
        max(0, (transcriptWidth - transcriptMaxWidth) / 2)
    }
}

/// The standalone chat's page labels: a narrow column of page titles beside the transcript,
/// well apart from each other and a few at a time; scrolling it, with no scroll bar, reaches
/// older ones. Clicking one jumps to its page; the page the transcript shows is marked, and
/// the column scrolls to keep it in view. Below the labels, a button jumps straight to the
/// bottom of the chat; above them, a pin keeps them open instead of only while hovered.
struct ChatPageAnchorsView: View {
    let model: ChatPageAnchorsModel
    let width: CGFloat
    let isPinned: Bool
    let jump: (StandaloneChatPage) -> Void
    let jumpToBottom: () -> Void
    let togglePin: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatPageAnchorsLayout.labelSpacing) {
                    if model.hasOlderPages {
                        // Reaching the oldest label read so far reads the ones before it.
                        Color.clear
                            .frame(height: 1)
                            .id("older-\(model.pages.count)")
                            .onAppear { loadOlder(proxy) }
                    }
                    ForEach(model.pages, id: \.id) { page in
                        ChatPageAnchorLabel(
                            page: page,
                            isCurrent: page.id == model.currentPageID,
                            isLoading: page.id == model.loadingPageID,
                            action: { jump(page) }
                        )
                        .id(page.id)
                    }
                }
                .padding(.vertical, ChatPageAnchorsLayout.labelsVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `.hidden` still shows a bar when the system always shows scroll bars.
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .accessibilityLabel("Chat pages")
            .accessibilityValue("\(model.pages.count) pages\(model.hasOlderPages ? ", older pages above" : "")")
            .accessibilityIdentifier("chat-page-anchors")
            .onChange(of: model.currentPageID) { _, pageID in
                guard let pageID else { return }
                // Slow enough to read as the labels following the transcript.
                withAnimation(.easeInOut(duration: 0.7)) { proxy.scrollTo(pageID, anchor: .center) }
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: ChatPageAnchorsLayout.labelsHeight(count: model.pages.count))
        // Hangs below the labels, centered across them, so the labels themselves stay centered
        // on the transcript.
        .overlay(alignment: .bottom) {
            ChatJumpToBottomButton(action: jumpToBottom)
                .alignmentGuide(.bottom) { $0[.top] - ChatPageAnchorsLayout.jumpToBottomSpacing }
        }
        // Hangs above the labels as the arrow hangs below them.
        .overlay(alignment: .top) {
            ChatPageAnchorsPinButton(isPinned: isPinned, action: togglePin)
                .alignmentGuide(.top) { $0[.bottom] + ChatPageAnchorsLayout.jumpToBottomSpacing }
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        let firstID = model.pages.first?.id
        model.loadOlder()
        // The label the reader reached stays where it was while older ones lay out above it.
        guard let firstID, model.pages.first?.id != firstID else { return }
        DispatchQueue.main.async { proxy.scrollTo(firstID, anchor: .top) }
    }
}

private struct ChatPageAnchorLabel: View {
    let page: StandaloneChatPage
    let isCurrent: Bool
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(isCurrent ? Color.accentColor : Color.primary.opacity(isHovering ? 0.35 : 0.16))
                    .frame(width: 2, height: 12)
                Text(page.title)
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent || isHovering ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(isLoading ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: ChatPageAnchorsLayout.labelHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .onHover { isHovering = $0 }
        .nativeHelp(page.title)
        .accessibilityLabel(page.title)
        .accessibilityValue(isLoading ? "loading" : isCurrent ? "current" : "")
        .accessibilityIdentifier("chat-page-anchor-\(page.id)")
    }
}

/// Below the page labels, an arrow that jumps to the bottom of the chat at once, from an
/// earlier page or from anywhere the reader scrolled up to.
private struct ChatJumpToBottomButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(width: 24, height: ChatPageAnchorsLayout.labelHeight + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .onHover { isHovering = $0 }
        .nativeHelp("Jump to the bottom of the chat")
        .accessibilityLabel("Jump to bottom of chat")
        .accessibilityIdentifier("chat-page-anchors-jump-to-bottom")
    }
}

/// Above the page labels, a pin that keeps them open beside the transcript, or lets them fold
/// back into their handle when the pointer leaves.
private struct ChatPageAnchorsPinButton: View {
    let isPinned: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(45))
                .foregroundStyle(isPinned ? Color.accentColor : isHovering ? Color.primary : Color.secondary)
                .frame(width: 24, height: ChatPageAnchorsLayout.labelHeight + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .onHover { isHovering = $0 }
        .nativeHelp(isPinned ? "Show the chat's pages only while hovering their handle" : "Keep the chat's pages open")
        .accessibilityLabel(isPinned ? "Unpin chat pages" : "Pin chat pages open")
        .accessibilityValue(isPinned ? "pinned" : "unpinned")
        .accessibilityIdentifier("chat-page-anchors-pin")
    }
}

/// The thin handle at the transcript's leading edge, halfway down it, that slides the unpinned
/// page labels out while hovered.
struct ChatPageAnchorsHandle: View {
    @State private var isHovering = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(isHovering ? 0.32 : 0.16))
            .frame(width: 3, height: 44)
            // A wider, taller target than the line itself, so it is easy to find.
            .frame(width: 14, height: 88)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityElement()
            .accessibilityLabel("Show chat pages")
            .accessibilityHint("Hover to show the chat's pages")
            .accessibilityIdentifier("chat-page-anchors-handle")
    }
}
