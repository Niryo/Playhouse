import SwiftUI

/// The standalone chat's pages as the labels beside its transcript show them. It reads only
/// the newest pages, and older ones as the reader scrolls the labels up to them.
@MainActor
@Observable
final class ChatPageAnchorsModel {
    /// Pages read at a time: as many as the column shows, so opening it reads only those.
    static let pageBatchSize = ChatPageAnchorsLayout.visibleLabelCount

    /// Pages that hold messages, oldest first.
    private(set) var pages: [StandaloneChatPage] = []
    private(set) var hasOlderPages = false
    /// The page at the top of the transcript's viewport.
    private(set) var currentPageID: String?
    /// The page a jump is reading.
    var loadingPageID: String?
    /// The text typed in the search above the labels.
    private(set) var searchText = ""
    /// While searching, the pages anywhere in the chat whose titles hold the search text,
    /// oldest first, in place of the newest pages.
    private(set) var searchResults: [StandaloneChatPage]?
    @ObservationIgnored private var limit = ChatPageAnchorsModel.pageBatchSize
    @ObservationIgnored private var searchLimit = ChatPageAnchorsModel.pageBatchSize
    /// Whether matching pages remain beyond the ones the search read.
    private(set) var hasMoreSearchResults = false
    /// The chat store, opened once: scrolling the labels and typing in their search read it
    /// again and again, and opening it runs its schema migration.
    @ObservationIgnored private var openedChatManager: StandaloneChatManager?

    nonisolated init() {}

    /// The labels the column shows: the search's matches, or the newest pages.
    var shownPages: [StandaloneChatPage] { searchResults ?? pages }
    var hasOlderShownPages: Bool { searchResults == nil ? hasOlderPages : hasMoreSearchResults }

    func reload(from chatManager: StandaloneChatManager) {
        openedChatManager = chatManager
        // One page past the limit tells whether older ones remain.
        let newest = (try? chatManager.listPages(limit: limit + 1)) ?? []
        let loaded = Array(newest.prefix(limit).filter { $0.messageCount > 0 }.reversed())
        if hasOlderPages != (newest.count > limit) { hasOlderPages = newest.count > limit }
        if loaded != pages { pages = loaded }
        reloadSearch(from: chatManager)
    }

    func clear() {
        pages = []
        hasOlderPages = false
        if searchResults != nil { searchResults = [] }
        hasMoreSearchResults = false
    }

    func loadOlder() {
        guard let chatManager = chatManager() else { return }
        if searchResults != nil {
            guard hasMoreSearchResults else { return }
            searchLimit += Self.pageBatchSize
            reloadSearch(from: chatManager)
            return
        }
        guard hasOlderPages else { return }
        limit += Self.pageBatchSize
        reload(from: chatManager)
    }

    /// Shows only the pages whose titles hold `text`; empty text shows the newest pages again.
    func search(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        searchLimit = Self.pageBatchSize
        if let chatManager = chatManager() {
            reloadSearch(from: chatManager)
        }
    }

    private func reloadSearch(from chatManager: StandaloneChatManager) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if searchResults != nil { searchResults = nil }
            if hasMoreSearchResults { hasMoreSearchResults = false }
            return
        }
        let matches = (try? chatManager.listPages(limit: searchLimit + 1, titleContaining: query)) ?? []
        let loaded = Array(matches.prefix(searchLimit).filter { $0.messageCount > 0 }.reversed())
        if hasMoreSearchResults != (matches.count > searchLimit) { hasMoreSearchResults = matches.count > searchLimit }
        if loaded != searchResults { searchResults = loaded }
    }

    /// The page the transcript shows. A page older than the labels read so far is read with
    /// the pages down to it, so its label exists to be marked.
    func setCurrentPage(_ pageID: String) {
        guard currentPageID != pageID else { return }
        if !pages.contains(where: { $0.id == pageID }), hasOlderPages, let chatManager = chatManager() {
            while hasOlderPages, !pages.contains(where: { $0.id == pageID }) {
                limit += Self.pageBatchSize
                reload(from: chatManager)
            }
        }
        currentPageID = pageID
    }

    /// The chat store the labels read, opened on first use.
    func chatManager() -> StandaloneChatManager? {
        if let openedChatManager { return openedChatManager }
        openedChatManager = try? StandaloneChatManager(dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"])
        return openedChatManager
    }
}

/// How the standalone chat's transcript makes room for the page labels: the open labels widen
/// the chat sidebar by `pushWidth`, pushing the board aside, and the transcript's rows move right
/// by as much, keeping their width so their text does not reflow.
enum ChatPageAnchorsLayout {
    /// Below this transcript width the chat offers no labels.
    static let minimumTranscriptWidth: CGFloat = 380
    /// Where the transcript's rows start without the labels.
    static let transcriptPadding: CGFloat = 28
    static let transcriptMaxWidth: CGFloat = 820

    /// Labels in view at a time; older ones are read as they are scrolled to.
    static let visibleLabelCount = 10
    static let labelHeight: CGFloat = 14
    static let labelSpacing: CGFloat = 20
    static let labelsVerticalPadding: CGFloat = 6
    /// The gap between the last label and the jump-to-bottom button below it.
    static let jumpToBottomSpacing: CGFloat = 4
    /// The search above the labels, and its gap from the first label.
    static let searchHeight: CGFloat = 18
    static let searchSpacing: CGFloat = 4
    /// Where the labels' line sits from the transcript column's edge. The handle's target spans
    /// this inset too, so with the chat at the window's edge, a pointer pushed against that edge,
    /// where the window's own resize edge is, still reaches the handle.
    static let handleInset: CGFloat = 2
    /// The handle's target, which the open labels start just beyond.
    static let handleWidth: CGFloat = 12
    /// How far right of the handle the open labels start.
    static let labelsHandleGap: CGFloat = 2
    /// Where the open labels start from the transcript column's edge: just right of the handle.
    static let labelsLeading = handleInset + handleWidth + labelsHandleGap

    /// The labels' width.
    static let labelsWidth: CGFloat = 112
    /// How far the open labels push the rows right, and widen the chat sidebar: the labels'
    /// room, ending a little before the rows start.
    static let pushWidth = labelsLeading + labelsWidth + 12 - transcriptPadding
    /// How the labels slide out from their handle, pushing the messages right, and back in.
    static let slideAnimation = Animation.easeInOut(duration: 0.22)

    /// The height that shows `count` labels, at most `visibleLabelCount` of them.
    static func labelsHeight(count: Int) -> CGFloat {
        let rows = CGFloat(max(1, min(count, visibleLabelCount)))
        return rows * labelHeight + (rows - 1) * labelSpacing + labelsVerticalPadding * 2
    }

    /// Where the transcript's centered column starts, while the labels push it by `push`.
    static func columnLeading(transcriptWidth: CGFloat, push: CGFloat) -> CGFloat {
        max(0, (transcriptWidth - transcriptMaxWidth - push) / 2)
    }
}

/// How far the chat's open page labels ask the chat sidebar to widen, so the board makes room
/// for them instead of the transcript's rows narrowing.
struct ChatPageAnchorsPushKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatPageAnchorsPushEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The width the chat sidebar grows by for the page labels, set in the same update that
    /// widens the sidebar. It holds the slide's end value from that update on, while the
    /// sidebar's width animates, so views read it through an `Animatable` modifier
    /// (`ChatPageAnchorsPushedRows`, `ChatPageAnchorsColumnInset`) that follows the sidebar
    /// frame by frame.
    var chatPageAnchorsPush: CGFloat {
        get { self[ChatPageAnchorsPushEnvironmentKey.self] }
        set { self[ChatPageAnchorsPushEnvironmentKey.self] = newValue }
    }
}

/// Moves the transcript's rows right by the open labels' push, keeping their width. The push
/// animates here, frame by frame with the chat sidebar widening by as much. Read straight from
/// the environment it would reach its end at once while the sidebar is still growing, so for
/// the slide's length the rows would narrow (or, folding, widen), reflow their text and move
/// the reader's place in the transcript, then move it back.
struct ChatPageAnchorsPushedRows: ViewModifier, Animatable {
    var push: CGFloat

    var animatableData: CGFloat {
        get { push }
        set { push = newValue }
    }

    func body(content: Content) -> some View {
        content
            .padding(.leading, push)
            .padding(.horizontal, ChatPageAnchorsLayout.transcriptPadding)
            .frame(maxWidth: ChatPageAnchorsLayout.transcriptMaxWidth + push)
    }
}

/// Places the labels' handle at the transcript's centered column, which the push moves. Like
/// `ChatPageAnchorsPushedRows`, the push animates here, so while the transcript widens the
/// handle stays at the rows' edge instead of jumping by half the push and drifting back.
struct ChatPageAnchorsColumnInset: ViewModifier, Animatable {
    var push: CGFloat
    let transcriptWidth: CGFloat

    var animatableData: CGFloat {
        get { push }
        set { push = newValue }
    }

    func body(content: Content) -> some View {
        // The handle's own target spans `handleInset`, reaching the column's edge.
        content.padding(.leading, ChatPageAnchorsLayout.columnLeading(transcriptWidth: transcriptWidth, push: push))
    }
}

/// Where the marker above the oldest label read so far ends, in the labels' scroll view.
private struct ChatPageAnchorsOlderEdgeKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

/// The standalone chat's page labels: a narrow column of page titles beside the transcript,
/// well apart from each other and a few at a time; scrolling it, with no scroll bar, reaches
/// older ones. Clicking one jumps to its page; the page the transcript shows is marked, and
/// the column scrolls to keep it in view. Above the labels, a small search narrows them to the
/// pages whose titles hold its text; below them, a button jumps straight to the bottom of the chat.
struct ChatPageAnchorsView: View {
    let model: ChatPageAnchorsModel
    let width: CGFloat
    let jump: (StandaloneChatPage) -> Void
    let jumpToBottom: () -> Void
    /// Whether the search above the labels has the keyboard, which keeps unlocked labels out.
    var searchFocusChanged: (Bool) -> Void = { _ in }
    @State private var olderEdge = OlderEdge()
    private static let scrollSpace = "chat-page-anchors-scroll"

    /// Whether the marker above the oldest label read is in view, and a count of its moves in
    /// and out of view that cancels a pending read, kept out of SwiftUI's state.
    final class OlderEdge {
        var isInView = false
        var generation = 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatPageAnchorsLayout.labelSpacing) {
                    if model.hasOlderShownPages {
                        // Scrolling up to the oldest label read so far reads the ones before it.
                        Color.clear
                            .frame(height: 1)
                            .id("older-\(model.shownPages.count)")
                            .background(GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ChatPageAnchorsOlderEdgeKey.self,
                                    value: geometry.frame(in: .named(Self.scrollSpace)).maxY
                                )
                            })
                    }
                    ForEach(model.shownPages, id: \.id) { page in
                        ChatPageAnchorLabel(
                            page: page,
                            isCurrent: page.id == model.currentPageID,
                            isLoading: page.id == model.loadingPageID,
                            action: { jump(page) }
                        )
                        .id(page.id)
                    }
                    if model.shownPages.isEmpty {
                        Text("No matching pages")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(height: ChatPageAnchorsLayout.labelHeight)
                            .accessibilityIdentifier("chat-page-anchors-no-matches")
                    }
                }
                .padding(.vertical, ChatPageAnchorsLayout.labelsVerticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `.hidden` still shows a bar when the system always shows scroll bars.
            .scrollIndicators(.never)
            .coordinateSpace(name: Self.scrollSpace)
            // The marker's place, not its appearing: the stack builds rows just outside the
            // column, so the marker can appear while the reader is still at the newest labels.
            .onPreferenceChange(ChatPageAnchorsOlderEdgeKey.self) { edge in
                olderEdgeMoved(inView: (edge ?? 0) > 0, proxy)
            }
            .defaultScrollAnchor(.bottom)
            .accessibilityLabel("Chat pages")
            .accessibilityValue("\(model.shownPages.count) pages\(model.hasOlderShownPages ? ", older pages above" : "")")
            .accessibilityIdentifier("chat-page-anchors")
            .onChange(of: model.currentPageID) { _, pageID in
                guard let pageID else { return }
                // Slow enough to read as the labels following the transcript.
                withAnimation(.easeInOut(duration: 0.7)) { proxy.scrollTo(pageID, anchor: .center) }
            }
            .onChange(of: model.searchResults?.last?.id) { _, newestMatchID in
                // A new search starts at its newest match, like the labels start at the newest page.
                guard let newestMatchID else { return }
                proxy.scrollTo(newestMatchID, anchor: .bottom)
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: ChatPageAnchorsLayout.labelsHeight(count: model.shownPages.count))
        // The search and the arrow hang above and below the labels, so the labels themselves
        // stay centered on the transcript.
        .overlay(alignment: .top) {
            ChatPageAnchorsSearchField(model: model, focusChanged: searchFocusChanged)
                .alignmentGuide(.top) { $0[.bottom] + ChatPageAnchorsLayout.searchSpacing }
        }
        .overlay(alignment: .bottom) {
            ChatJumpToBottomButton(action: jumpToBottom)
                .alignmentGuide(.bottom) { $0[.top] - ChatPageAnchorsLayout.jumpToBottomSpacing }
        }
    }

    /// Reads older labels once each time the marker comes into view. A lazy stack sizes itself
    /// over several layout passes, which can show the marker for a moment, as can the labels
    /// read laying out before the column scrolls back to the one the reader reached; so the
    /// marker counts as reached only while it is still in view 0.15 s later.
    private func olderEdgeMoved(inView: Bool, _ proxy: ScrollViewProxy) {
        let edge = olderEdge
        guard inView != edge.isInView else { return }
        edge.isInView = inView
        edge.generation += 1
        guard inView else { return }
        let generation = edge.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard edge.generation == generation else { return }
            loadOlder(proxy)
        }
    }

    private func loadOlder(_ proxy: ScrollViewProxy) {
        let firstID = model.shownPages.first?.id
        model.loadOlder()
        // The label the reader reached stays where it was while older ones lay out above it.
        guard let firstID, model.shownPages.first?.id != firstID else { return }
        DispatchQueue.main.async { proxy.scrollTo(firstID, anchor: .top) }
    }
}

/// Above the page labels, a small field that narrows them to the pages whose titles hold its
/// text, read from the whole chat. Escape, or its clear button, shows every page again.
private struct ChatPageAnchorsSearchField: View {
    let model: ChatPageAnchorsModel
    let focusChanged: (Bool) -> Void
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search pages", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isFocused)
                .onExitCommand { clear() }
                .accessibilityLabel("Search chat pages")
                .accessibilityIdentifier("chat-page-anchors-search")
            if !text.isEmpty {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("Clear the search")
                .accessibilityLabel("Clear chat page search")
                .accessibilityIdentifier("chat-page-anchors-search-clear")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: ChatPageAnchorsLayout.searchHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(isFocused ? 0.09 : 0.05)))
        .onAppear { text = model.searchText }
        .onChange(of: text) { _, edited in model.search(edited) }
        .onChange(of: isFocused) { _, focused in focusChanged(focused) }
        .onDisappear { if isFocused { focusChanged(false) } }
    }

    private func clear() {
        text = ""
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

/// The parts of the page labels column whose hover, or the search's focus, keeps the unlocked
/// labels slid out.
enum ChatPageAnchorsHoverPart: Hashable {
    case handle
    case labels
    /// The search above the labels has the keyboard.
    case search
}

/// The handle at the transcript's leading edge, halfway down it. Folded, it is a faint thin line
/// that slides the labels out while hovered; beside the open labels it thickens under a small
/// open lock, and clicking it locks them open, which closes the lock, or unlocks them again.
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
                .frame(width: isOpen || isLocked ? 5 : 3, height: 64)
                // A wider, taller target than the line itself, so it is easy to find, reaching
                // left to the transcript column's edge, which is the window's edge when the chat
                // is against it.
                .frame(width: ChatPageAnchorsLayout.handleWidth, height: 108)
                .padding(.leading, ChatPageAnchorsLayout.handleInset)
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
        // Above the line, inside the handle's target, so hovering or clicking it is the handle's.
        // Laid over the button after its accessibility modifiers, so it is its own element.
        .overlay(alignment: .topTrailing) {
            if isOpen || isLocked {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isLocked || isHovering ? Color.primary : Color.secondary)
                    .frame(width: ChatPageAnchorsLayout.handleWidth, height: 14)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityLabel(isLocked ? "Chat pages locked" : "Chat pages unlocked")
                    .accessibilityValue(isLocked ? "locked" : "unlocked")
                    .accessibilityIdentifier("chat-page-anchors-lock")
            }
        }
    }

    private var fill: Color {
        // The lock above it shows whether the labels are locked; the line looks the same either way.
        if isOpen || isLocked { return Color.primary.opacity(isHovering ? 0.5 : 0.34) }
        return Color.primary.opacity(isHovering ? 0.32 : 0.16)
    }
}
