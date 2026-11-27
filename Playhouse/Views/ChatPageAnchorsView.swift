import Foundation
import Observation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// The standalone chat's pages as the labels beside its transcript show them. It reads only
/// the newest pages, and older ones as the reader scrolls the labels up to them.
@MainActor
@Observable
package final class ChatPageAnchorsModel {
    /// Pages read at a time: as many as the column shows, so opening it reads only those.
    package static let pageBatchSize = ChatPageAnchorsLayout.visibleLabelCount

    /// Pages that hold messages, oldest first.
    package private(set) var pages: [StandaloneChatPage] = []
    package private(set) var hasOlderPages = false
    /// The page at the top of the transcript's viewport.
    package private(set) var currentPageID: String?
    /// The page a jump is reading.
    package var loadingPageID: String?
    /// The text typed in the search above the labels.
    package private(set) var searchText = ""
    /// While searching, the pages anywhere in the chat whose titles hold the search text,
    /// oldest first, in place of the newest pages.
    package private(set) var searchResults: [StandaloneChatPage]?
    @ObservationIgnored private var limit = ChatPageAnchorsModel.pageBatchSize
    @ObservationIgnored private var searchLimit = ChatPageAnchorsModel.pageBatchSize
    /// Whether matching pages remain beyond the ones the search read.
    package private(set) var hasMoreSearchResults = false
    /// The chat store, opened once: scrolling the labels and typing in their search read it
    /// again and again, and opening it runs its schema migration.
    @ObservationIgnored private var openedChatManager: StandaloneChatManager?

    package nonisolated init() {}

    /// The labels the column shows: the search's matches, or the newest pages.
    package var shownPages: [StandaloneChatPage] { searchResults ?? pages }
    package var hasOlderShownPages: Bool { searchResults == nil ? hasOlderPages : hasMoreSearchResults }

    package func reload(from chatManager: StandaloneChatManager) {
        openedChatManager = chatManager
        // One page past the limit tells whether older ones remain.
        let newest = (try? chatManager.listPages(limit: limit + 1)) ?? []
        let loaded = Array(newest.prefix(limit).filter { $0.messageCount > 0 }.reversed())
        if hasOlderPages != (newest.count > limit) { hasOlderPages = newest.count > limit }
        if loaded != pages { pages = loaded }
        reloadSearch(from: chatManager)
    }

    package func clear() {
        pages = []
        hasOlderPages = false
        if searchResults != nil { searchResults = [] }
        hasMoreSearchResults = false
    }

    package func loadOlder() {
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
    package func search(_ text: String) {
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
    package func setCurrentPage(_ pageID: String) {
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
    package func chatManager() -> StandaloneChatManager? {
        if let openedChatManager { return openedChatManager }
        openedChatManager = try? StandaloneChatManager(dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"])
        return openedChatManager
    }
}

/// How the standalone chat's transcript makes room for the page labels: the open labels widen
/// the chat sidebar by `pushWidth`, pushing the board aside, and the transcript's rows move right
/// by as much, keeping their width so their text does not reflow.
package enum ChatPageAnchorsLayout {
    /// Below this transcript width the chat offers no labels.
    package static let minimumTranscriptWidth: CGFloat = 380
    /// Where the transcript's rows start without the labels.
    package static let transcriptPadding: CGFloat = 28
    package static let transcriptMaxWidth: CGFloat = 820

    /// Labels in view at a time; older ones are read as they are scrolled to.
    package static let visibleLabelCount = 10
    package static let labelHeight: CGFloat = 14
    package static let labelSpacing: CGFloat = 20
    package static let labelsVerticalPadding: CGFloat = 6
    /// The gap between the last label and the jump-to-bottom button below it.
    package static let jumpToBottomSpacing: CGFloat = 4
    /// The search above the labels, and its gap from the first label.
    package static let searchHeight: CGFloat = 18
    package static let searchSpacing: CGFloat = 4
    /// Where the labels' line sits from the transcript column's edge. The handle's target spans
    /// this inset too, so with the chat at the window's edge, a pointer pushed against that edge,
    /// where the window's own resize edge is, still reaches the handle.
    package static let handleInset: CGFloat = 2
    /// The handle's target, which the open labels start just beyond.
    package static let handleWidth: CGFloat = 12
    /// How far right of the handle the open labels start.
    package static let labelsHandleGap: CGFloat = 2
    /// Where the open labels start from the transcript column's edge: just right of the handle.
    package static let labelsLeading = handleInset + handleWidth + labelsHandleGap

    /// The labels' width.
    package static let labelsWidth: CGFloat = 112
    /// How far the open labels push the rows right, and widen the chat sidebar: the labels'
    /// room, ending a little before the rows start.
    package static let pushWidth = labelsLeading + labelsWidth + 12 - transcriptPadding
    /// How the labels slide out from their handle, pushing the messages right, and back in.
    package static let slideAnimation = PHAnimation.easeInOut(duration: 0.22)

    /// The height that shows `count` labels, at most `visibleLabelCount` of them.
    package static func labelsHeight(count: Int) -> CGFloat {
        let rows = CGFloat(max(1, min(count, visibleLabelCount)))
        return rows * labelHeight + (rows - 1) * labelSpacing + labelsVerticalPadding * 2
    }

    /// Where the transcript's centered column starts, while the labels push it by `push`.
    package static func columnLeading(transcriptWidth: CGFloat, push: CGFloat) -> CGFloat {
        max(0, (transcriptWidth - transcriptMaxWidth - push) / 2)
    }
}

/// How far the chat's open page labels ask the chat sidebar to widen, so the board makes room
/// for them instead of the transcript's rows narrowing.
package struct ChatPageAnchorsPushKey: PHPreferenceKey {
    package static let defaultValue: CGFloat = 0
    package static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }

    package init() {}
}

private struct ChatPageAnchorsPushEnvironmentKey: PHEnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension PHEnvironmentValues {
    /// The width the chat sidebar grows by for the page labels, set in the same update that
    /// widens the sidebar. It holds the slide's end value from that update on, while the
    /// sidebar's width animates, so views read it through an `Animatable` modifier
    /// (`ChatPageAnchorsPushedRows`, `ChatPageAnchorsColumnInset`) that follows the sidebar
    /// frame by frame.
    package var chatPageAnchorsPush: CGFloat {
        get { self[ChatPageAnchorsPushEnvironmentKey.self] }
        set { self[ChatPageAnchorsPushEnvironmentKey.self] = newValue }
    }
}

/// Moves the transcript's rows right by the open labels' push, keeping their width. The push
/// animates here, frame by frame with the chat sidebar widening by as much. Read straight from
/// the environment it would reach its end at once while the sidebar is still growing, so for
/// the slide's length the rows would narrow (or, folding, widen), reflow their text and move
/// the reader's place in the transcript, then move it back.
package struct ChatPageAnchorsPushedRows: PHViewModifier, PHAnimatable {
    package var push: CGFloat

    package var animatableData: CGFloat {
        get { push }
        set { push = newValue }
    }

    package func body(content: Content) -> some PHView {
        AtomStack(common: AtomCommon(
            maxWidth: ChatPageAnchorsLayout.transcriptMaxWidth + push, frameAlign: "center",
            paddingX: ChatPageAnchorsLayout.transcriptPadding, paddingLeading: push
        )) {
            content
        }
    }

    package init(push: CGFloat) {
        self.push = push
    }
}

/// Places the labels' handle at the transcript's centered column, which the push moves. Like
/// `ChatPageAnchorsPushedRows`, the push animates here, so while the transcript widens the
/// handle stays at the rows' edge instead of jumping by half the push and drifting back.
package struct ChatPageAnchorsColumnInset: PHViewModifier, PHAnimatable {
    package var push: CGFloat
    package let transcriptWidth: CGFloat

    package var animatableData: CGFloat {
        get { push }
        set { push = newValue }
    }

    package func body(content: Content) -> some PHView {
        // The handle's own target spans `handleInset`, reaching the column's edge.
        AtomStack(common: AtomCommon(paddingLeading: ChatPageAnchorsLayout.columnLeading(transcriptWidth: transcriptWidth, push: push))) {
            content
        }
    }

    package init(push: CGFloat, transcriptWidth: CGFloat) {
        self.push = push
        self.transcriptWidth = transcriptWidth
    }
}

/// The standalone chat's page labels: a narrow column of page titles beside the transcript,
/// well apart from each other and a few at a time; scrolling it, with no scroll bar, reaches
/// older ones. Clicking one jumps to its page; the page the transcript shows is marked, and
/// the column scrolls to keep it in view. Above the labels, a small search narrows them to the
/// pages whose titles hold its text; below them, a button jumps straight to the bottom of the chat.
package struct ChatPageAnchorsView: PHView {
    package let model: ChatPageAnchorsModel
    package let width: CGFloat
    package let jump: (StandaloneChatPage) -> Void
    package let jumpToBottom: () -> Void
    /// Whether the search above the labels has the keyboard, which keeps unlocked labels out.
    package var searchFocusChanged: (Bool) -> Void = { _ in }
    @PHState private var olderEdge = OlderEdge()
    private static let scrollSpace = "chat-page-anchors-scroll"

    /// Which marker above the oldest label read is in view, by the labels read when it was
    /// placed, and a count of the changes to it that cancels a pending read, kept out of
    /// SwiftUI's state.
    package final class OlderEdge {
        package var labelCountInView: Int?
        package var generation = 0
    }

    package var body: some PHView {
        // The search and the arrow hang above and below the labels, so the labels themselves
        // stay centered on the transcript: each sits its own height and its gap past their edge.
        AtomOverlay(props: OverlayProps(align: "bottom", offsetY: ChatPageAnchorsLayout.labelHeight + 4 + ChatPageAnchorsLayout.jumpToBottomSpacing)) {
            AtomOverlay(props: OverlayProps(align: "top", offsetY: -(ChatPageAnchorsLayout.searchHeight + ChatPageAnchorsLayout.searchSpacing))) {
                AtomStack(common: AtomCommon(
                    width: width, maxHeight: ChatPageAnchorsLayout.labelsHeight(count: model.shownPages.count), frameAlign: "leading"
                )) {
                    labels
                }
            } overlay: {
                ChatPageAnchorsSearchField(model: model, focusChanged: searchFocusChanged)
            }
        } overlay: {
            ChatJumpToBottomButton(action: jumpToBottom)
        }
    }

    private var labels: some PHView {
        PHScrollViewReader { proxy in
            AtomScroll(props: ScrollProps(directContent: true)) {
                AtomStack(common: AtomCommon(fillWidth: true, paddingY: ChatPageAnchorsLayout.labelsVerticalPadding)) {
                    AtomStack(props: StackProps(spacing: Double(ChatPageAnchorsLayout.labelSpacing), align: "leading", lazy: true)) {
                        if model.hasOlderShownPages {
                            // Scrolling up to the oldest label read so far reads the ones before it.
                            // The marker's place, not its appearing: the stack builds rows just outside the
                            // column, so the marker can appear while the reader is still at the newest labels.
                            let labelCount = model.shownPages.count
                            AtomStack(common: AtomCommon(height: 1, fillWidth: true)) { PHEmptyView() }
                                .id("older-\(labelCount)")
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.scrollSpace)).maxY } action: { maxY in
                                    olderEdgeMoved(labelCountInView: maxY > 0 ? labelCount : nil, proxy)
                                }
                                // A marker leaving the stack no longer counts as in view, unless the
                                // marker that replaced it already took its place.
                                .onDisappear {
                                    if olderEdge.labelCountInView == labelCount { olderEdgeMoved(labelCountInView: nil, proxy) }
                                }
                        }
                        PHForEach(model.shownPages, id: \.id) { page in
                            ChatPageAnchorLabel(
                                page: page,
                                isCurrent: page.id == model.currentPageID,
                                isLoading: page.id == model.loadingPageID,
                                action: { jump(page) }
                            )
                            .id(page.id)
                        }
                        if model.shownPages.isEmpty {
                            AtomText(
                                props: TextProps(text: "No matching pages", size: 11, color: "tertiary", lineLimit: 1),
                                common: AtomCommon(testID: "chat-page-anchors-no-matches", height: ChatPageAnchorsLayout.labelHeight)
                            )
                        }
                    }
                }
            }
            // `.hidden` still shows a bar when the system always shows scroll bars.
            .scrollIndicators(.never)
            .coordinateSpace(name: Self.scrollSpace)
            .defaultScrollAnchor(.bottom)
            .accessibilityLabel("Chat pages")
            .accessibilityValue("\(model.shownPages.count) pages\(model.hasOlderShownPages ? ", older pages above" : "")")
            .accessibilityIdentifier("chat-page-anchors")
            .onChange(of: model.currentPageID) { _, pageID in
                guard let pageID else { return }
                // Slow enough to read as the labels following the transcript.
                phWithAnimation(.easeInOut(duration: 0.7)) { proxy.scrollTo(pageID, anchor: .center) }
            }
            .onChange(of: model.searchResults?.last?.id) { _, newestMatchID in
                // A new search starts at its newest match, like the labels start at the newest page.
                guard let newestMatchID else { return }
                proxy.scrollTo(newestMatchID, anchor: .bottom)
            }
        }
    }

    /// Reads older labels once each time a marker comes into view. A lazy stack sizes itself
    /// over several layout passes, which can show the marker for a moment, as can the labels
    /// read laying out before the column scrolls back to the one the reader reached; so the
    /// marker counts as reached only while it is still in view 0.15 s later. The marker placed
    /// above newly read labels is a new arrival even when the one before it was still in view:
    /// a wheel scroll still under way can keep the column at its top, so the new marker never
    /// leaves view, and without that it would never read on.
    private func olderEdgeMoved(labelCountInView: Int?, _ proxy: PHScrollViewProxy) {
        let edge = olderEdge
        guard labelCountInView != edge.labelCountInView else { return }
        edge.labelCountInView = labelCountInView
        edge.generation += 1
        guard labelCountInView != nil else { return }
        let generation = edge.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard edge.generation == generation else { return }
            loadOlder(proxy)
        }
    }

    private func loadOlder(_ proxy: PHScrollViewProxy) {
        let firstID = model.shownPages.first?.id
        model.loadOlder()
        // The label the reader reached stays where it was while older ones lay out above it.
        guard let firstID, model.shownPages.first?.id != firstID else { return }
        DispatchQueue.main.async { proxy.scrollTo(firstID, anchor: .top) }
    }

    package init(model: ChatPageAnchorsModel, width: CGFloat, jump: @escaping (StandaloneChatPage) -> Void, jumpToBottom: @escaping () -> Void, searchFocusChanged: @escaping (Bool) -> Void = { _ in }) {
        self.model = model
        self.width = width
        self.jump = jump
        self.jumpToBottom = jumpToBottom
        self.searchFocusChanged = searchFocusChanged
    }
}

/// Above the page labels, a small field that narrows them to the pages whose titles hold its
/// text, read from the whole chat. Escape, or its clear button, shows every page again.
private struct ChatPageAnchorsSearchField: PHView {
    let model: ChatPageAnchorsModel
    let focusChanged: (Bool) -> Void
    @PHState private var text = ""
    @PHFocusState private var isFocused: Bool

    var body: some PHView {
        AtomStack(
            props: StackProps(axis: "h", spacing: 4, fill: "primary", fillOpacity: isFocused ? 0.09 : 0.05, cornerRadius: 5),
            common: AtomCommon(height: ChatPageAnchorsLayout.searchHeight, paddingX: 6)
        ) {
            AtomIcon(props: IconProps(name: PHIcon.magnifyingglass.name, size: 9, weight: "semibold", color: "secondary"))
            AtomTextField(
                props: TextFieldProps(text: text, placeholder: "Search pages", style: "plain", size: 11),
                common: AtomCommon(testID: "chat-page-anchors-search", label: "Search chat pages"),
                onChange: { text = $0 }, onEscape: clear, focus: $isFocused
            )
            if !text.isEmpty {
                AtomButton(
                    common: AtomCommon(testID: "chat-page-anchors-search-clear", label: "Clear chat page search", help: "Clear the search"),
                    action: clear
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.xmarkCircleFill.name, size: 10, color: "secondary"))
                }
            }
        }
        .onAppear { text = model.searchText }
        .onChange(of: text) { _, edited in model.search(edited) }
        .onChange(of: isFocused) { _, focused in focusChanged(focused) }
        .onDisappear { if isFocused { focusChanged(false) } }
    }

    private func clear() {
        text = ""
    }
}

private struct ChatPageAnchorLabel: PHView {
    let page: StandaloneChatPage
    let isCurrent: Bool
    let isLoading: Bool
    let action: () -> Void
    @PHState private var isHovering = false

    var body: some PHView {
        AtomButton(
            common: AtomCommon(
                testID: "chat-page-anchor-\(page.id)", label: page.title,
                value: isLoading ? "loading" : isCurrent ? "current" : "", help: page.title
            ),
            action: action
        ) {
            AtomStack(
                props: StackProps(axis: "h", spacing: 6),
                common: AtomCommon(height: ChatPageAnchorsLayout.labelHeight, fillWidth: true),
                onHover: { isHovering = $0 }
            ) {
                AtomStack(
                    props: StackProps(fill: isCurrent ? "accent" : "primary", fillOpacity: isCurrent ? 1 : (isHovering ? 0.35 : 0.16), capsule: true),
                    common: AtomCommon(width: 2, height: 12)
                ) { PHEmptyView() }
                AtomText(
                    props: TextProps(
                        text: page.title, size: 11, weight: isCurrent ? "semibold" : "regular",
                        color: isCurrent || isHovering ? "primary" : "secondary", lineLimit: 1
                    ),
                    common: AtomCommon(opacity: isLoading ? 0.5 : 1)
                )
            }
        }
    }
}

/// Below the page labels, an arrow that jumps to the bottom of the chat at once, from an
/// earlier page or from anywhere the reader scrolled up to.
private struct ChatJumpToBottomButton: PHView {
    let action: () -> Void
    @PHState private var isHovering = false

    var body: some PHView {
        AtomButton(
            common: AtomCommon(testID: "chat-page-anchors-jump-to-bottom", label: "Jump to bottom of chat", help: "Jump to the bottom of the chat"),
            action: action
        ) {
            AtomStack(common: AtomCommon(width: 24, height: ChatPageAnchorsLayout.labelHeight + 4), onHover: { isHovering = $0 }) {
                AtomIcon(props: IconProps(name: PHIcon.arrowDownToLine.name, size: 11, weight: "semibold", color: isHovering ? "primary" : "secondary"))
            }
        }
    }
}

/// The parts of the page labels column whose hover, or the search's focus, keeps the unlocked
/// labels slid out.
package enum ChatPageAnchorsHoverPart: Hashable {
    case handle
    case labels
    /// The search above the labels has the keyboard.
    case search
}

/// The handle at the transcript's leading edge, halfway down it. Folded, it is a faint thin line
/// that slides the labels out while hovered; beside the open labels it thickens under a small
/// open lock, and clicking it locks them open, which closes the lock, or unlocks them again.
package struct ChatPageAnchorsHandle: PHView {
    package let isOpen: Bool
    package let isLocked: Bool
    package let toggleLock: () -> Void
    package let hover: (Bool) -> Void
    @PHState private var isHovering = false

    package var body: some PHView {
        // Above the line, inside the handle's target, so hovering or clicking it is the handle's.
        // Laid over the button, so it is its own element.
        AtomOverlay(props: OverlayProps(align: "topTrailing")) {
            AtomButton(
                common: AtomCommon(
                    testID: "chat-page-anchors-handle", label: isLocked ? "Unlock chat pages" : "Lock chat pages open",
                    value: isLocked ? "locked" : isOpen ? "open" : "folded",
                    help: isLocked ? "Unlock the chat's pages, so they fold away when the pointer leaves" : "Lock the chat's pages open"
                ),
                action: toggleLock
            ) {
                // A wider, taller target than the line itself, so it is easy to find, reaching
                // left to the transcript column's edge, which is the window's edge when the chat
                // is against it.
                AtomStack(common: AtomCommon(paddingLeading: ChatPageAnchorsLayout.handleInset), onHover: {
                    isHovering = $0
                    hover($0)
                }) {
                    AtomStack(common: AtomCommon(width: ChatPageAnchorsLayout.handleWidth, height: 108)) {
                        AtomStack(
                            props: StackProps(fill: "primary", fillOpacity: fillOpacity, capsule: true),
                            common: AtomCommon(width: isOpen || isLocked ? 5 : 3, height: 64)
                        ) { PHEmptyView() }
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
        } overlay: {
            if isOpen || isLocked {
                AtomStack(common: AtomCommon(paddingTop: 5, passThrough: true)) {
                    AtomIcon(
                        props: IconProps(
                            name: isLocked ? PHIcon.lockFill.name : PHIcon.lockOpen.name, size: 9, weight: "semibold",
                            color: isLocked || isHovering ? "primary" : "secondary"
                        ),
                        common: AtomCommon(
                            testID: "chat-page-anchors-lock", label: isLocked ? "Chat pages locked" : "Chat pages unlocked",
                            value: isLocked ? "locked" : "unlocked", width: ChatPageAnchorsLayout.handleWidth, height: 14
                        )
                    )
                }
                .transition(.opacity)
            }
        }
    }

    private var fillOpacity: Double {
        // The lock above it shows whether the labels are locked; the line looks the same either way.
        if isOpen || isLocked { return isHovering ? 0.5 : 0.34 }
        return isHovering ? 0.32 : 0.16
    }

    package init(isOpen: Bool, isLocked: Bool, toggleLock: @escaping () -> Void, hover: @escaping (Bool) -> Void) {
        self.isOpen = isOpen
        self.isLocked = isLocked
        self.toggleLock = toggleLock
        self.hover = hover
    }
}
