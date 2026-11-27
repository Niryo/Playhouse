import Foundation

/// A side page of the standalone chat that runs alongside it, as its bridge and the GUI list it.
package struct ParallelChatBubbleRecord: Codable, Equatable, Identifiable {
    package let id: UUID
    package let chatID: UUID
    package let prompt: String
    package let createdAt: Date
    /// The chat's turn the bubble's page returns after: its placeholder. Nil when the chat was empty.
    package let anchorTurnID: String?
    /// Whether the bubble's turn is still running, so it cannot be closed yet.
    package let isRunning: Bool

    package init(id: UUID, chatID: UUID, prompt: String, createdAt: Date, anchorTurnID: String?, isRunning: Bool) {
        self.id = id
        self.chatID = chatID
        self.prompt = prompt
        self.createdAt = createdAt
        self.anchorTurnID = anchorTurnID
        self.isRunning = isRunning
    }
}

/// Where a closed bubble's page went in the chat.
package struct ParallelChatBubbleCloseResult: Codable, Equatable {
    package let pageIDs: [String]
    /// The chat's turn the page now follows; nil when it opens the chat.
    package let afterTurnID: String?

    package init(pageIDs: [String], afterTurnID: String?) {
        self.pageIDs = pageIDs
        self.afterTurnID = afterTurnID
    }
}

extension BoardTaskManager {
    /// A new bubble for the standalone chat, placed after the chat's latest turn and asking
    /// the chat's own provider and model.
    package func createParallelChatBubble(chatID: UUID, prompt: String) async throws -> StandaloneChat {
        guard let chat = try standaloneChatModel(chatID), chat.isStandaloneChat, chat.parallelOfChatID == nil else {
            throw BridgeCommandError(code: "not_found", message: "Standalone chat not found.")
        }
        let bubble = StandaloneChat(provider: chat.conversationProvider)
        bubble.title = String(prompt.prefix(80))
        bubble.parallelOfChatID = chat.id
        bubble.parallelPrompt = prompt
        bubble.parallelAnchorTurnID = try conversationTranscriptStore().outline(chat.id).turns.last?.id
        bubble.conversationEffortRawValue = chat.conversationEffortRawValue
        bubble.conversationModelIDsData = chat.conversationModelIDsData
        modelContext.insert(bubble)
        try await saveTaskContext(taskID: bubble.id)
        PlayhouseDiagnostics.record("chat.bubble.created", fields: [
            "chatID": chat.id.uuidString, "bubbleID": bubble.id.uuidString,
            "anchorTurnID": bubble.parallelAnchorTurnID ?? "",
        ])
        return bubble
    }

    package func parallelChatBubbles(of chatID: UUID) throws -> [StandaloneChat] {
        try modelContext.fetch(ModelFetch<StandaloneChat>(
            .equals("parallelOfChatID", chatID),
            sortBy: [("createdAt", true)]
        ))
    }

    package func parallelChatBubbleRecord(_ bubble: StandaloneChat) -> ParallelChatBubbleRecord {
        ParallelChatBubbleRecord(
            id: bubble.id, chatID: bubble.parallelOfChatID ?? bubble.id, prompt: bubble.parallelPrompt ?? bubble.title,
            createdAt: bubble.createdAt, anchorTurnID: bubble.parallelAnchorTurnID,
            isRunning: (try? hasConversationTurnReservation(bubble.id)) ?? true
        )
    }
}

extension ConversationManager {
    /// Sends `text` on a new page of its own that runs alongside the standalone chat, the way a
    /// New page send would, in a bubble the chat takes back when it is closed.
    package func sendInParallel(
        text: String,
        imageDataURLs: [String] = [],
        onBubbleCreated: (ParallelChatBubbleRecord) -> Void = { _ in },
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws -> ConversationHistory {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !imageDataURLs.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "A parallel page needs a message.")
        }
        let chat = try await tasks.getOrCreateStandaloneChat(provider: settingsManager.defaultConversationProvider)
        let bubble = try await tasks.createParallelChatBubble(chatID: chat.id, prompt: prompt)
        onBubbleCreated(tasks.parallelChatBubbleRecord(bubble))
        Self.bumpVisibleRevision(chat.id)
        return try await send(
            taskID: bubble.id, text: text, imageDataURLs: imageDataURLs,
            startsNewChatPage: true, onUpdate: onUpdate, onUserInput: onUserInput
        )
    }

    /// Closes a bubble whose turn has finished, inserting its page into the standalone chat at
    /// its placeholder, never at or after the chat's current page, without splitting a page.
    @discardableResult
    package func closeParallelChatBubble(id: UUID) async throws -> ParallelChatBubbleCloseResult {
        guard let bubble = try tasks.standaloneChatModel(id), let chatID = bubble.parallelOfChatID else {
            throw BridgeCommandError(code: "not_found", message: "Parallel page not found.")
        }
        let result = try await tasks.withConversationTurnReservationIfFree(id) { () async throws -> ParallelChatBubbleCloseResult in
            await resolvePendingStandalonePageFallback(taskID: id)
            let bubbleChatManager = try tasks.standaloneChatManager(for: id)
            if try bubbleChatManager.hasPendingFallback() || savedUserInputRequest(taskID: id) != nil
                || !tasks.queuedConversationMessages(taskID: id).isEmpty {
                throw BridgeCommandError(code: "invalid_transition", message: "This parallel page is still waiting on its turn, so it can't close yet.")
            }
            // One close at a time places its page among the chat's turns. The chat's own turn may
            // still run: the moved page goes in closed and before any turn not yet filed, so it
            // never becomes the chat's current page or takes that turn.
            return try await tasks.withTaskOperationLock(chatID) {
                try await mergeParallelChatBubble(bubble, into: chatID, bubbleChatManager: bubbleChatManager)
            }
        }
        guard let result else {
            throw BridgeCommandError(code: "invalid_transition", message: "This parallel page is still answering, so it can't close yet.")
        }
        return result
    }

    private func mergeParallelChatBubble(
        _ bubble: StandaloneChat,
        into chatID: UUID,
        bubbleChatManager: StandaloneChatManager
    ) async throws -> ParallelChatBubbleCloseResult {
        let chatManager = try tasks.standaloneChatManager(for: chatID)
        let turnIDs = try transcripts.outline(chatID).turns.map(\.id)
        let assignments = try chatManager.pageAssignmentsByTurnID()
        let activePage = try chatManager.activePage()
        let insertion = Self.parallelChatBubbleInsertion(
            turnIDs: turnIDs, anchorTurnID: bubble.parallelAnchorTurnID,
            pageIDByTurnID: assignments.mapValues(\.id), activePageID: activePage?.id
        )
        let afterTurnID = insertion > 0 ? turnIDs[insertion - 1] : nil
        // Dated between the pages around it, so the page labels list it where the transcript shows
        // it; a page with a neighbour on one side only is a second apart from it, which the
        // store's millisecond times keep apart from any later page placed between the two.
        let pages = try bubbleChatManager.listPages(limit: 10_000).sorted { $0.createdAt < $1.createdAt }
        let before = afterTurnID.flatMap { assignments[$0]?.createdAt }
        let after = (insertion < turnIDs.count ? assignments[turnIDs[insertion]]?.createdAt : nil) ?? activePage?.createdAt
        var dates: [String: Date] = [:]
        for (index, page) in pages.enumerated() {
            let step = Double(index + 1) / Double(pages.count + 1)
            switch (before, after) {
            case let (before?, after?) where before < after:
                dates[page.id] = before.addingTimeInterval(after.timeIntervalSince(before) * step)
            case let (_, after?):
                dates[page.id] = after.addingTimeInterval(-Double(pages.count - index))
            case let (before?, nil):
                dates[page.id] = before.addingTimeInterval(Double(index + 1))
            case (nil, nil):
                dates[page.id] = page.createdAt
            }
        }
        // Each step can run again: an interrupted close is finished by closing the bubble again,
        // and until then the bubble takes no turn that could open a page this close already moved.
        if !bubble.parallelIsClosing {
            bubble.parallelIsClosing = true
            try await tasks.saveTaskContext(taskID: bubble.id)
        }
        try chatManager.adoptPages(fromChatID: bubbleChatManager.chatID, createdAt: dates)
        try transcripts.moveTurns(from: bubble.id, into: chatID, afterTurnID: afterTurnID)
        if let chat = try tasks.standaloneChatModel(chatID) {
            chat.totalInputTokens += bubble.totalInputTokens
            chat.totalOutputTokens += bubble.totalOutputTokens
            chat.totalCacheReadTokens += bubble.totalCacheReadTokens
            chat.totalCacheCreationTokens += bubble.totalCacheCreationTokens
        }
        let bubbleID = bubble.id
        tasks.modelContext.delete(bubble)
        try await tasks.saveTaskContext(taskID: chatID)
        PlayhouseDiagnostics.record("chat.bubble.closed", fields: [
            "chatID": chatID.uuidString, "bubbleID": bubbleID.uuidString,
            "afterTurnID": afterTurnID ?? "", "pageCount": String(pages.count),
        ])
        Self.bumpVisibleRevision(chatID)
        ConversationTurnEvents.publish(chatID, ConversationUpdate(type: "chat_page_updated"))
        return ParallelChatBubbleCloseResult(pageIDs: pages.map(\.id), afterTurnID: afterTurnID)
    }

    /// The index among the chat's turns a closing bubble's page goes before: right after its
    /// anchor turn, moved back to the start of the anchor's page when the chat went on with that
    /// page, and never past the start of the current page or of trailing turns not yet filed.
    package static func parallelChatBubbleInsertion(
        turnIDs: [String],
        anchorTurnID: String?,
        pageIDByTurnID: [String: String],
        activePageID: String?
    ) -> Int {
        let anchor = anchorTurnID.map { turnIDs.firstIndex(of: $0) ?? turnIDs.count - 1 } ?? -1
        var insertion = anchor + 1
        if anchor >= 0, insertion < turnIDs.count, let anchorPage = pageIDByTurnID[turnIDs[anchor]],
           pageIDByTurnID[turnIDs[insertion]] == anchorPage {
            insertion = anchor
            while insertion > 0, pageIDByTurnID[turnIDs[insertion - 1]] == anchorPage { insertion -= 1 }
        }
        var current = turnIDs.count
        while current > 0 {
            let page = pageIDByTurnID[turnIDs[current - 1]]
            guard page == nil || page == activePageID else { break }
            current -= 1
        }
        return max(0, min(insertion, current))
    }
}
