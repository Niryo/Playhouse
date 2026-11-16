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
        return min(140, max(84, rowWidth - bubbleMaxWidth))
    }

    /// Where the transcript's centered column starts.
    static func columnLeading(transcriptWidth: CGFloat) -> CGFloat {
        max(0, (transcriptWidth - transcriptMaxWidth) / 2)
    }
}

/// The standalone chat's page labels: a narrow column of page titles beside the transcript,
/// well apart from each other. Clicking one jumps to its page; the page the transcript shows
/// is marked, and the column scrolls to keep it in view.
struct ChatPageAnchorsView: View {
    let model: ChatPageAnchorsModel
    let width: CGFloat
    let jump: (StandaloneChatPage) -> Void
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ChatPageAnchorsToggle(isHidden: false, action: hide)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
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
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverRevealScrollers()
                }
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
        }
        .frame(width: width, alignment: .leading)
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

/// Hides the page labels, or brings them back from the transcript's edge.
struct ChatPageAnchorsToggle: View {
    let isHidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .nativeHelp(isHidden ? "Show the chat's pages" : "Hide the chat's pages")
        .accessibilityLabel(isHidden ? "Show chat pages" : "Hide chat pages")
        .accessibilityValue(isHidden ? "hidden" : "shown")
        .accessibilityIdentifier("chat-page-anchors-toggle")
    }
}
