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
    /// The gap between the last label and the jump-to-bottom button below it.
    static let jumpToBottomSpacing: CGFloat = 4
    /// Where the labels' handle sits from the transcript column's edge.
    static let handleInset: CGFloat = 2
    /// The handle's target, which the open labels start just beyond.
    static let handleWidth: CGFloat = 12
    /// How far right of the handle the open labels start.
    static let labelsHandleGap: CGFloat = 2
    /// Where the open labels start from the transcript column's edge: just right of the handle.
    static let labelsLeading = handleInset + handleWidth + labelsHandleGap

    /// The labels' width: up to a little before the rows start.
    static func labelsWidth(transcriptWidth: CGFloat) -> CGFloat {
        rowInset(transcriptWidth: transcriptWidth) + transcriptPadding - labelsLeading - 12
    }
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
/// bottom of the chat.
struct ChatPageAnchorsView: View {
    let model: ChatPageAnchorsModel
    let width: CGFloat
    let jump: (StandaloneChatPage) -> Void
    let jumpToBottom: () -> Void

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

/// The parts of the page labels column whose hover keeps the unlocked labels slid out.
enum ChatPageAnchorsHoverPart: Hashable {
    case handle
    case labels
}

/// The handle at the transcript's leading edge, halfway down it. Folded, it is a faint thin line
/// that slides the labels out while hovered; beside the open labels it thickens, and clicking it
/// locks them open, which turns it the accent color, or unlocks them again.
struct ChatPageAnchorsHandle: View {
    let isOpen: Bool
    let isLocked: Bool
    let toggleLock: () -> Void
    let hover: (Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggleLock) {
            Capsule()
                .fill(fill)
                .frame(width: isOpen || isLocked ? 5 : 3, height: 44)
                // A wider, taller target than the line itself, so it is easy to find.
                .frame(width: ChatPageAnchorsLayout.handleWidth, height: 88)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .nativeHelp(isLocked ? "Unlock the chat's pages, so they fold away when the pointer leaves" : "Lock the chat's pages open")
        .onHover {
            isHovering = $0
            hover($0)
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(isLocked ? "Unlock chat pages" : "Lock chat pages open")
        .accessibilityValue(isLocked ? "locked" : isOpen ? "open" : "folded")
        .accessibilityIdentifier("chat-page-anchors-handle")
    }

    private var fill: Color {
        if isLocked { return Color.accentColor.opacity(isHovering ? 1 : 0.85) }
        if isOpen { return Color.primary.opacity(isHovering ? 0.5 : 0.34) }
        return Color.primary.opacity(isHovering ? 0.32 : 0.16)
    }
}
