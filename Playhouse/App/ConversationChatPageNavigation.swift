import SwiftUI

/// Messages left unloaded between a chat page the reader jumped to and the newest messages.
/// `messages` then holds the page's messages, this gap, and the newest messages after it.
struct ConversationHistoryGap: Equatable {
    /// The last loaded message before the gap.
    var afterMessageID: String
    var storedMessageCount: Int
}

/// Jumping to a standalone chat page reads that page's messages alone and renders a window
/// that starts there and ends before the newest message. The window grows as the reader
/// scrolls: older messages above it as in any conversation, newer ones below it here.
extension TaskConversationView {
    /// Messages read for the page a jump lands on.
    static let chatPageWindowSize = 40
    /// Messages rendered right after a jump; more are revealed until they fill the viewport.
    static let chatPageInitialMessageCount = 6
    /// Newer messages revealed at a time as the reader nears the newest rendered one.
    static let newerConversationMessageBatchSize = 4
    /// Loaded messages left below the rendered window when the next newer page is read.
    static let newerConversationMessagePrefetchCount = 20

    /// Where the gap sits in `allMessages`: the index of the last message before it.
    func historyGapIndex(in allMessages: [ConversationMessage]) -> Int? {
        guard let historyGap,
              let index = allMessages.firstIndex(where: { $0.id == historyGap.afterMessageID }),
              index < allMessages.count - 1 else { return nil }
        return index
    }

    /// The last rendered index of a window that ends before the newest message, or nil when
    /// the window runs to the end of the transcript.
    func renderedWindowEndIndex(in allMessages: [ConversationMessage], from startIndex: Int) -> Int? {
        guard renderedWindowEndID != nil || historyGap != nil else { return nil }
        // A window never renders across messages that are not loaded.
        let gapIndex = historyGapIndex(in: allMessages).flatMap { $0 >= startIndex ? $0 : nil }
        if let renderedWindowEndID,
           let endIndex = allMessages.firstIndex(where: { $0.id == renderedWindowEndID }),
           endIndex >= startIndex, endIndex < allMessages.count - 1 {
            return min(endIndex, gapIndex ?? endIndex)
        }
        return gapIndex
    }

    /// Whether the rendered window ends before the newest message, as after a jump to an
    /// earlier chat page. What belongs to the running turn is hidden until the reader returns.
    var isBrowsingEarlierMessages: Bool {
        guard renderedWindowEndID != nil || historyGap != nil else { return false }
        let allMessages = conversationMessages
        guard let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else { return false }
        return renderedWindowEndIndex(in: allMessages, from: startIndex) != nil
    }

    /// Messages the conversation holds in all: loaded, before the loaded ones, and in the gap.
    var storedConversationMessageCount: Int {
        conversationMessages.count + earlierStoredMessageCount + (historyGap?.storedMessageCount ?? 0)
    }

    /// The page the newest turn belongs to, which the next message continues or closes.
    var activeChatPageID: String? {
        messages.last(where: { $0.turnID != nil })?.turnID.flatMap { chatPagesByTurnID[$0]?.id }
    }

    func chatPageID(of message: ConversationMessage) -> String? {
        message.turnID.flatMap { chatPagesByTurnID[$0]?.id }
    }

    /// The first message of a page, when the loaded messages are known to hold it: the message
    /// before it is loaded too, or it opens the conversation.
    func loadedChatPageStartID(_ pageID: String) -> String? {
        guard let index = messages.firstIndex(where: { chatPageID(of: $0) == pageID }) else { return nil }
        if index == 0 { return earlierStoredMessageCount == 0 ? messages[index].id : nil }
        // The message before it is not the one before it in the conversation across the gap.
        if let historyGap, messages[index - 1].id == historyGap.afterMessageID { return nil }
        return messages[index].id
    }

    /// Shows a page from its first message. A page whose start is not loaded is read on its
    /// own, without the messages between it and the newest ones.
    func jumpToChatPage(_ page: StandaloneChatPage) {
        guard task.isStandaloneChat, hasLoadedConversation, !isLoadingHistory else { return }
        chatPageJumpCount += 1
        let jump = chatPageJumpCount
        chatPageAnchors.setCurrentPage(page.id)
        if let startID = loadedChatPageStartID(page.id) {
            chatPageAnchors.loadingPageID = nil
            presentChatPage(startingAt: startID)
            return
        }
        chatPageAnchors.loadingPageID = page.id
        Task { @MainActor in
            defer {
                if chatPageAnchors.loadingPageID == page.id { chatPageAnchors.loadingPageID = nil }
            }
            do {
                let window = try await conversationManager.history(
                    taskID: task.id, messageLimit: Self.chatPageWindowSize, chatPageID: page.id
                )
                // A later jump, or a return to the newest messages, overtook this read.
                guard jump == chatPageJumpCount, let startID = window.messages.first?.id else { return }
                mergeChatPageWindow(window)
                presentChatPage(startingAt: startID)
            } catch {
                guard jump == chatPageJumpCount else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Puts a page's messages above the newest ones, with a gap for what lies between them.
    /// A page read earlier is dropped first, so jumping around never accumulates pages.
    func mergeChatPageWindow(_ window: ConversationHistory) {
        dropHistoryHead()
        var incoming = window.messages
        let tailStart = earlierStoredMessageCount
        let windowStart = window.earlierMessageCount ?? 0
        let loadedIDs = Set(messages.map(\.id))
        if let overlap = incoming.firstIndex(where: { loadedIDs.contains($0.id) }) {
            // The page runs into the loaded messages, so nothing is left unloaded between them.
            guard messages.first?.id == incoming[overlap].id else { return }
            incoming = Array(incoming[..<overlap])
        } else {
            let between = tailStart - windowStart - incoming.count
            if between > 0, let last = incoming.last {
                historyGap = ConversationHistoryGap(afterMessageID: last.id, storedMessageCount: between)
            } else if between < 0 {
                incoming = Array(incoming.prefix(max(0, incoming.count + between)))
            }
        }
        guard !incoming.isEmpty else { return }
        messages = incoming + messages
        earlierStoredMessageCount = windowStart
        mergeTimelineActivities(window.timelineActivities)
        collapsedProgressTurnIDs.formUnion(incoming.lazy
            .filter { $0.role == .assistant && $0.phase == "final_answer" }
            .compactMap(\.turnID))
        restoreAnnotations(from: messages, keepingPending: true)
    }

    /// Forgets the page read by a jump and the gap after it, leaving the newest messages.
    func dropHistoryHead() {
        guard let gap = historyGap else { return }
        historyGap = nil
        guard let index = messages.firstIndex(where: { $0.id == gap.afterMessageID }), index < messages.count - 1 else { return }
        earlierStoredMessageCount += index + 1 + gap.storedMessageCount
        messages.removeFirst(index + 1)
        mergeTimelineActivities([])
    }

    /// Renders a window that starts at a page's first message and puts it at the top of the
    /// viewport. Only a few messages render at once; the rest follow as the reader scrolls.
    func presentChatPage(startingAt startID: String) {
        if let gapIndex = historyGapIndex(in: messages),
           let index = messages.firstIndex(where: { $0.id == startID }), index > gapIndex {
            // The page is among the newest messages, so the one read earlier is not needed.
            dropHistoryHead()
        }
        let allMessages = conversationMessages
        guard let startIndex = allMessages.firstIndex(where: { $0.id == startID }) else { return }
        if startID == latestConversationTurnStartID {
            renderedWindowEndID = nil
            oldestRenderedMessageID = startID
            transcriptScroll.pin(.latestTurn)
            return
        }
        let lastIndex = historyGapIndex(in: allMessages) ?? allMessages.count - 1
        let endIndex = min(startIndex + Self.chatPageInitialMessageCount - 1, lastIndex)
        renderedWindowEndID = endIndex < allMessages.count - 1 ? allMessages[endIndex].id : nil
        oldestRenderedMessageID = startID
        transcriptScroll.pin(.row(startID))
        // The first messages can be shorter than the viewport.
        transcriptScroll.didRevealNewerRows()
    }

    /// Reveals the next few newer messages below a window that ends before the newest message,
    /// reading the ones in the gap before the reader reaches it. A window that reaches the
    /// newest message is an ordinary one again.
    func revealNewerConversationMessages() {
        guard hasLoadedConversation, !isLoadingHistory else { return }
        let allMessages = conversationMessages
        guard let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }),
              let endIndex = renderedWindowEndIndex(in: allMessages, from: startIndex) else { return }
        let gapIndex = historyGapIndex(in: allMessages)
        if let gapIndex, gapIndex - endIndex < Self.newerConversationMessagePrefetchCount,
           !isLoadingNewerConversationMessages {
            isLoadingNewerConversationMessages = true
            let gapEdgeID = allMessages[gapIndex].id
            Task { @MainActor in
                let loaded = await loadNewerConversationMessages()
                isLoadingNewerConversationMessages = false
                // A reader who reached the gap meanwhile is waiting there.
                if loaded, renderedWindowEndID == gapEdgeID { revealNewerConversationMessages() }
            }
        }
        let lastIndex = gapIndex ?? allMessages.count - 1
        guard endIndex < lastIndex else { return }
        let newEndIndex = min(endIndex + Self.newerConversationMessageBatchSize, lastIndex)
        renderedWindowEndID = newEndIndex < allMessages.count - 1 ? allMessages[newEndIndex].id : nil
        transcriptScroll.didRevealNewerRows()
    }

    /// Reads the page of history just after the gap's start and places it there. Returns
    /// whether the gap changed.
    func loadNewerConversationMessages() async -> Bool {
        guard let gap = historyGap else { return false }
        do {
            let page = try await conversationManager.history(
                taskID: task.id, messageLimit: Self.historyPageSize, afterMessageID: gap.afterMessageID
            )
            // A jump or a reload may have replaced the gap while this read ran.
            guard historyGap == gap, let gapIndex = historyGapIndex(in: messages) else { return false }
            // The window ends at the gap until the reader scrolls into what filled it.
            if renderedWindowEndID == nil { renderedWindowEndID = gap.afterMessageID }
            let tail = Array(messages[(gapIndex + 1)...])
            let tailIDs = Set(tail.map(\.id))
            var filling = page.messages
            var remaining = gap.storedMessageCount - filling.count
            if let overlap = filling.firstIndex(where: { tailIDs.contains($0.id) }) {
                filling = Array(filling[..<overlap])
                remaining = 0
            } else if remaining < 0 {
                filling = Array(filling.prefix(gap.storedMessageCount))
            }
            messages = Array(messages[...gapIndex]) + filling + tail
            if remaining > 0, let last = filling.last {
                historyGap = ConversationHistoryGap(afterMessageID: last.id, storedMessageCount: remaining)
            } else {
                historyGap = nil
            }
            mergeTimelineActivities(page.timelineActivities)
            collapsedProgressTurnIDs.formUnion(filling.lazy
                .filter { $0.role == .assistant && $0.phase == "final_answer" }
                .compactMap(\.turnID))
            restoreAnnotations(from: messages, keepingPending: true)
            return true
        } catch {
            // The message before the gap can be gone after history was rewritten.
            if (error as? BridgeCommandError)?.code == "not_found" {
                returnToLatestMessages()
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    /// Leaves an earlier chat page for the end of the transcript, at once.
    func returnToLatestMessages() {
        let wasBrowsing = isBrowsingEarlierMessages
        chatPageJumpCount += 1
        chatPageAnchors.loadingPageID = nil
        renderedWindowEndID = nil
        dropHistoryHead()
        if wasBrowsing, let turnStartID = latestConversationTurnStartID {
            oldestRenderedMessageID = turnStartID
        }
        transcriptScroll.pin(.bottom)
    }

    /// Marks the page the reader scrolled to as the current one among the page labels.
    func noteTopTranscriptRow(_ messageID: String) {
        topTranscriptRowID = messageID
        markCurrentChatPage()
    }

    /// Also run when the pages are read, which can follow the transcript's first layout.
    func markCurrentChatPage() {
        guard task.isStandaloneChat, let messageID = topTranscriptRowID,
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        // A message outside any page sits in the page of the messages before it.
        guard let pageID = messages[...index].reversed().lazy.compactMap({ chatPageID(of: $0) }).first else { return }
        chatPageAnchors.setCurrentPage(pageID)
    }

    /// Adds an earlier page to what the next message recalls and returns to the composer.
    func recallChatPage(_ page: StandaloneChatPage) {
        if !recalledChatPages.contains(where: { $0.id == page.id }) {
            recalledChatPages.append(page)
        }
        returnToLatestMessages()
        isComposerFocused = true
    }

    /// The composer's note of each page the next message recalls, with a way to drop it.
    @ViewBuilder
    var recalledChatPageChips: some View {
        ForEach(recalledChatPages, id: \.id) { page in
            AtomPanel(
                props: PanelProps(fill: "primary", fillOpacity: 0.1, cornerRadius: 13, stroke: "primary", strokeOpacity: 0.08),
                common: AtomCommon(padding: 0, paddingX: 12, paddingY: 8)
            ) {
                AtomStack(props: StackProps(axis: "h", spacing: 8, group: true), common: AtomCommon(testID: "composer-recalled-page-\(page.id)", label: "Recalling \(page.title)")) {
                    AtomIcon(props: IconProps(name: "arrow.uturn.backward.circle", size: 13, weight: "medium", color: "primary"), common: AtomCommon(opacity: 0.82))
                    AtomText(
                        props: TextProps(text: "Recalling \(page.title)", size: 13, weight: "medium", color: "primary", lineLimit: 1),
                        common: AtomCommon(testID: "composer-recalled-page-title", opacity: 0.82)
                    )
                    Button {
                        recalledChatPages.removeAll { $0.id == page.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .nativeHelp("Send the next message without recalling this conversation")
                    .accessibilityLabel("Stop recalling \(page.title)")
                    .accessibilityIdentifier("composer-recalled-page-remove-\(page.id)")
                }
            }
        }
    }

    /// Whether the chat has page labels to offer: only the standalone chat has pages, and a
    /// narrow chat keeps its width for messages.
    func offersChatPageAnchors(transcriptWidth: CGFloat) -> Bool {
        task.isStandaloneChat && !chatPageAnchors.pages.isEmpty
            && transcriptWidth >= ChatPageAnchorsLayout.minimumTranscriptWidth
    }

    /// Whether the page labels show beside the transcript: locked open from their handle, or
    /// slid out from it while hovered.
    func showsChatPageAnchors(transcriptWidth: CGFloat) -> Bool {
        offersChatPageAnchors(transcriptWidth: transcriptWidth) && (pinsChatPageAnchors || revealsChatPageAnchors)
    }

    /// The handle at the transcript's leading edge, halfway down it, and the page labels it
    /// slides out beside it while hovered or locked. Each part tracks its own hover, because a
    /// hover handler on a container around the handle gives the handle's accessibility element
    /// the container's whole frame.
    @ViewBuilder
    func chatPageAnchorsOverlay(showsLabels: Bool, transcriptWidth: CGFloat) -> some View {
        if offersChatPageAnchors(transcriptWidth: transcriptWidth) {
            let leading = ChatPageAnchorsLayout.columnLeading(transcriptWidth: transcriptWidth)
            HStack(spacing: ChatPageAnchorsLayout.labelsHandleGap) {
                ChatPageAnchorsHandle(
                    isOpen: showsLabels,
                    isLocked: pinsChatPageAnchors,
                    toggleLock: { pinsChatPageAnchors.toggle() },
                    hover: { hoverChatPageAnchors(.handle, $0) }
                )
                if showsLabels {
                    ChatPageAnchorsView(
                        model: chatPageAnchors,
                        width: ChatPageAnchorsLayout.labelsWidth(transcriptWidth: transcriptWidth),
                        jump: { jumpToChatPage($0) },
                        jumpToBottom: { returnToLatestMessages() }
                    )
                    // Room for the arrow below the labels, inside the hovered area.
                    .padding(.vertical, 26)
                    .contentShape(Rectangle())
                    .onHover { hoverChatPageAnchors(.labels, $0) }
                    // Labels that fold away under the pointer get no hover exit.
                    .onDisappear { hoveredChatPageAnchorsParts.remove(.labels) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .padding(.leading, leading + ChatPageAnchorsLayout.handleInset)
        }
    }

    /// Slides the unlocked labels out while the pointer is over their handle or them, and back
    /// in a moment after it leaves both; the delay also carries the pointer across the gap
    /// between them.
    func hoverChatPageAnchors(_ part: ChatPageAnchorsHoverPart, _ isHovering: Bool) {
        if isHovering {
            hoveredChatPageAnchorsParts.insert(part)
        } else {
            hoveredChatPageAnchorsParts.remove(part)
        }
        chatPageAnchorsCollapse?.cancel()
        chatPageAnchorsCollapse = nil
        if !hoveredChatPageAnchorsParts.isEmpty {
            guard !revealsChatPageAnchors else { return }
            withAnimation(ChatPageAnchorsLayout.slideAnimation) { revealsChatPageAnchors = true }
        } else if revealsChatPageAnchors {
            chatPageAnchorsCollapse = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(ChatPageAnchorsLayout.slideAnimation) { revealsChatPageAnchors = false }
            }
        }
    }

    /// Floats over an earlier chat page the reader jumped to, and takes them back to the end.
    @ViewBuilder
    var jumpToLatestButton: some View {
        if isBrowsingEarlierMessages {
            Button {
                returnToLatestMessages()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                    Text("Latest").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(WorkspaceTheme.panelBackground, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .nativeHelp("Return to the newest messages")
            .accessibilityLabel("Jump to latest messages")
            .accessibilityIdentifier("chat-jump-to-latest")
            .padding(.bottom, 10)
        }
    }
}

/// The small button on an earlier page's title that recalls the page into the next message.
struct ChatPageRecallButton: View {
    let pageID: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 8, weight: .bold))
                Text("Recall").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isHovering ? Color.primary : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(isHovering ? 0.12 : 0.06), in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .onHover { isHovering = $0 }
        .nativeHelp("Reference this conversation: your next message will recall it for the agent")
        .accessibilityLabel("Recall this conversation")
        .accessibilityIdentifier("chat-page-recall-\(pageID)")
    }
}
