import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    /// What this conversation does when the transcript's scroll controller reports the reader
    /// nearing the top or the transcript starting or stopping following.
    var transcriptScrollHandlers: TranscriptScrollController.Handlers {
        TranscriptScrollController.Handlers(
            onApproachTop: { revealOlderConversationMessages() },
            onFollowingChange: { isFollowing in
                // While the transcript follows its end, a conversation that established no window
                // keeps only the newest batch rendered. A reader who stops to read keeps the rows
                // they have, so none is taken from under them.
                guard !isFollowing, let firstRenderedID = renderedConversationMessages.first?.id,
                      oldestRenderedMessageID != firstRenderedID else { return }
                oldestRenderedMessageID = firstRenderedID
            },
            onApproachBottom: { revealNewerConversationMessages() },
            onTopRowChange: { noteTopTranscriptRow($0) }
        )
    }

    /// Reveals the next few older messages above the rendered window. The scroll controller
    /// keeps the row the reader is on where it is while they lay out above it, so this only
    /// decides which messages render. It runs as the reader nears the oldest rendered message,
    /// so they keep scrolling into messages that are already there.
    func revealOlderConversationMessages() {
        guard hasLoadedConversation, !isLoadingHistory, hasOlderConversationMessages else { return }
        let allMessages = conversationMessages
        guard let currentTopID = renderedConversationMessages.first?.id,
              let currentStartIndex = allMessages.firstIndex(where: { $0.id == currentTopID }) else { return }
        // The next older page is read from the daemon while loaded messages remain above the
        // reader, so they do not reach the oldest one and wait for it.
        if currentStartIndex < Self.olderConversationMessagePrefetchCount, earlierStoredMessageCount > 0,
           !isLoadingEarlierConversationMessages {
            isLoadingEarlierConversationMessages = true
            let oldestLoadedID = allMessages.first?.id
            Task { @MainActor in
                let loaded = await loadEarlierConversationMessages()
                isLoadingEarlierConversationMessages = false
                // A reader who reached the oldest loaded message meanwhile is waiting there.
                if loaded, renderedConversationMessages.first?.id == oldestLoadedID {
                    revealOlderConversationMessages()
                }
            }
        }
        guard currentStartIndex > 0 else { return }
        oldestRenderedMessageID = allMessages[max(0, currentStartIndex - Self.olderConversationMessageBatchSize)].id
        // Messages shorter than the viewport leave the reader still near the top.
        transcriptScroll.didRevealOlderRows()
    }

    /// Reads the page of history just before the oldest loaded message and
    /// prepends it. Returns whether any earlier messages were added.
    func loadEarlierConversationMessages() async -> Bool {
        guard let oldestLoadedID = messages.first?.id else { return false }
        do {
            let page = try await conversationManager.history(
                taskID: task.id,
                messageLimit: Self.historyPageSize,
                beforeMessageID: oldestLoadedID
            )
            // Another reload may have replaced the transcript while this read ran.
            guard messages.first?.id == oldestLoadedID else { return false }
            let loadedIDs = Set(messages.map(\.id))
            let earlier = page.messages.filter { !loadedIDs.contains($0.id) }
            messages = earlier + messages
            earlierStoredMessageCount = page.earlierMessageCount ?? 0
            mergeTimelineActivities(page.timelineActivities)
            collapsedProgressTurnIDs.formUnion(earlier.lazy
                .filter { $0.role == .assistant && $0.phase == "final_answer" }
                .compactMap(\.turnID))
            restoreAnnotations(from: messages, keepingPending: true)
            return !earlier.isEmpty
        } catch {
            // The anchor message can be gone after a provider switch rewrote
            // history; reload the newest page rather than leave paging stuck.
            if (error as? BridgeCommandError)?.code == "not_found" {
                earlierStoredMessageCount = 0
                Task { await loadConversation() }
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    /// Applies a history read to the transcript. A page keeps the earlier
    /// messages this window already loaded above it; a complete history is
    /// trimmed back to the messages already loaded, so a reload never pulls
    /// the whole conversation into memory.
    /// A steer shown before the provider has it isn't in history yet, so a history read that
    /// lands meanwhile keeps its bubble. One the latest turn already holds is left to history.
    func keepPendingLocalSteers() {
        guard !pendingLocalSteers.isEmpty else { return }
        let latestTurnID = messages.last?.turnID
        var persisted = messages.filter { $0.role == .user && (latestTurnID == nil || $0.turnID == latestTurnID) }
        for steer in pendingLocalSteers where !messages.contains(where: { $0.id == steer.id }) {
            if let index = persisted.firstIndex(where: { MentionText.sameUserText($0.text, steer.text) }) {
                persisted.remove(at: index)
                continue
            }
            messages.append(ConversationMessage(id: steer.id, role: .user, text: steer.text, imageDataURLs: steer.imageDataURLs))
        }
    }

    func applyHistoryMessages(_ history: ConversationHistory, _ incoming: [ConversationMessage]? = nil) {
        // Buffered text arrived before this history, so it applies first, as it would have unbuffered.
        flushStreamedTextDeltas()
        let renderedCount = establishedRenderedMessageCount
        let presentedQuestion = latestSentQuestion
        let windowStart = conversationMessages.first { $0.id == oldestRenderedMessageID }
        defer {
            keepPendingLocalSteers()
            mergeTimelineActivities(history.timelineActivities)
            keepTranscriptPosition(renderedCount: renderedCount, windowStart: windowStart, presentedQuestion: presentedQuestion)
        }
        let incoming = incoming ?? history.messages
        // Images this window already shows stay with it when the new read defers them.
        for message in messages where !message.imageDataURLs.isEmpty {
            deferredMessageImages[Self.deferredImageKey(message)] = message.imageDataURLs
        }
        // A chat page read by a jump stays above the gap; the read replaces what follows it.
        let gapIndex = historyGapIndex(in: messages)
        if let earlierCount = history.earlierMessageCount {
            if let first = incoming.first, let overlap = messages.firstIndex(where: { $0.id == first.id }) {
                messages = Array(messages[..<overlap]) + incoming
                if let gapIndex, overlap > gapIndex {
                    // The page and the gap are as they were: the read starts after them.
                } else {
                    historyGap = nil
                    earlierStoredMessageCount = max(0, earlierCount - overlap)
                }
            } else if let gapIndex, let gap = historyGap,
                      earlierCount - earlierStoredMessageCount - (gapIndex + 1) > 0 {
                messages = Array(messages[...gapIndex]) + incoming
                historyGap = ConversationHistoryGap(
                    afterMessageID: gap.afterMessageID,
                    storedMessageCount: earlierCount - earlierStoredMessageCount - (gapIndex + 1)
                )
            } else {
                messages = incoming
                earlierStoredMessageCount = earlierCount
                historyGap = nil
                renderedWindowEndID = nil
            }
            return
        }
        if let gapIndex, let gap = historyGap,
           let headStart = incoming.firstIndex(where: { $0.id == messages[0].id }),
           let gapStart = incoming.firstIndex(where: { $0.id == gap.afterMessageID }),
           let tailStart = incoming.firstIndex(where: { $0.id == messages[gapIndex + 1].id }),
           headStart <= gapStart, gapStart < tailStart {
            // A complete history is trimmed to the page and to the newest messages alike.
            messages = Array(incoming[headStart...gapStart]) + Array(incoming[tailStart...])
            earlierStoredMessageCount = headStart
            let between = tailStart - gapStart - 1
            historyGap = between > 0 ? ConversationHistoryGap(afterMessageID: gap.afterMessageID, storedMessageCount: between) : nil
            return
        }
        historyGap = nil
        if earlierStoredMessageCount > 0 || messages.count >= Self.historyPageSize,
           let oldestLoadedID = messages.first?.id,
           let start = incoming.firstIndex(where: { $0.id == oldestLoadedID }) {
            messages = Array(incoming[start...])
            earlierStoredMessageCount = start
        } else {
            messages = incoming
            earlierStoredMessageCount = 0
        }
    }

    /// Adds a history read's placed tool calls, replacing earlier copies of the
    /// same calls, and drops calls whose message is no longer loaded.
    func mergeTimelineActivities(_ incoming: [ConversationActivity]) {
        let incomingIDs = Set(incoming.map(\.id))
        let loadedMessageIDs = Set(messages.map(\.id))
        timelineActivities = (timelineActivities.filter { !incomingIDs.contains($0.id) } + incoming).filter {
            $0.afterMessageID.map(loadedMessageIDs.contains) == true
        }
    }

    /// The newest question the user sent themselves.
    var latestSentQuestion: ConversationMessage? {
        conversationMessages.last(where: { $0.role == .user && !$0.isPlayhouseSent })
    }

    /// Opens the transcript on the newest turn: the window starts at its question, which sits at
    /// the top of the viewport. A turn that is running, or a question form waiting below it,
    /// opens at the end of the transcript instead and follows what arrives. A turn too long to
    /// render at once opens at its end on its newest messages, and the messages above them
    /// render until they fill the viewport (see `openingWindowStartID`).
    func presentLatestConversationTurn() {
        // A reload leaves any earlier chat page the reader had jumped to.
        renderedWindowEndID = nil
        dropHistoryHead()
        guard let turnStartID = latestConversationTurnStartID, let windowStartID = openingWindowStartID else {
            // An empty conversation renders everything it receives while it stays open.
            transcriptScroll.pin(.bottom)
            return
        }
        oldestRenderedMessageID = windowStartID
        // The newest question is already in view, so it is not one that was just sent.
        lastScrolledUserMessageID = latestSentQuestion?.id
        // A pending question form renders below the newest turn and must be fully reachable,
        // Submit included. A conversation with no thread yet, as right after a provider switch,
        // has no form: no request is not a request for no thread.
        let hasQuestionForm = userInputRequest.map { $0.threadID == task.activeConversationID } ?? false
        let opensOnQuestion = windowStartID == turnStartID
        transcriptScroll.pin(isResponding || hasQuestionForm || !opensOnQuestion ? .bottom : .latestTurn)
        if !opensOnQuestion { transcriptScroll.fillViewportWithOlderRows() }
    }

    /// A question that was just sent lands at the top of the viewport while its answer streams in
    /// below. The transcript's layout makes that position the bottom of the transcript, so once
    /// the answer outgrows the viewport, following the bottom carries the reader along with it
    /// unless they scroll up.
    func presentNewlySentQuestion() {
        guard hasLoadedConversation, !isLoadingHistory,
              let question = latestSentQuestion, question.id != lastScrolledUserMessageID else { return }
        lastScrolledUserMessageID = question.id
        // A question sent while reading an earlier chat page is shown where it lands.
        if isBrowsingEarlierMessages { returnToLatestMessages() }
        transcriptScroll.pin(.bottom, animated: true)
    }

    /// History names messages by its own IDs, which replace the ones a live turn gave them.
    /// Keeps the rendered window and the question already presented pointing at the same
    /// messages, so a turn that ends never moves a reader or counts as a new question.
    func keepTranscriptPosition(renderedCount: Int?, windowStart: ConversationMessage?, presentedQuestion: ConversationMessage?) {
        let allMessages = conversationMessages
        if let renderedCount, let windowStartID = oldestRenderedMessageID, !allMessages.isEmpty,
           !allMessages.contains(where: { $0.id == windowStartID }) {
            // A window that starts at the user's message keeps starting there, however many
            // messages followed it before this history arrived; the count only stands in
            // when that message can't be found.
            let renamedStart = windowStart.flatMap { start in
                start.role == .user ? allMessages.last { $0.role == .user && MentionText.sameUserText($0.text, start.text) } : nil
            }
            oldestRenderedMessageID = renamedStart?.id ?? allMessages[max(0, allMessages.count - renderedCount)].id
        }
        if let presentedQuestion, presentedQuestion.id == lastScrolledUserMessageID,
           let question = latestSentQuestion, question.id != presentedQuestion.id,
           MentionText.sameUserText(question.text, presentedQuestion.text) {
            lastScrolledUserMessageID = question.id
        }
    }

    /// How many messages the rendered window holds, when it starts at a message it names.
    var establishedRenderedMessageCount: Int? {
        guard let oldestRenderedMessageID else { return nil }
        let allMessages = conversationMessages
        return allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }).map { allMessages.count - $0 }
    }

    struct TranscriptRowContext {
        let inlineTools: [String: [ConversationActivity]]
        /// The message the activity disclosure sits above, or nil when it is not shown above one.
        let activityDisclosureAnchorID: String?
        let latestTurnStartID: String?
        let conversationMessages: [ConversationMessage]
        /// Provider boundaries and goal achievements keyed by the rendered message they follow.
        let boundariesByAnchorID: [String: [ConversationProviderBoundary]]
        let goalEntriesByAnchorID: [String: [GoalAchievementTimelineEntry]]
        /// Context compactions with a timeline position, in activity order.
        let orderedContextCompactions: [ConversationActivity]
        /// Parallel bubbles' placeholders keyed by the message each sits above, where its page will
        /// return, or under the last message when it returns after everything loaded.
        var parallelPlaceholdersByMessageID: [String: [ParallelChatPlaceholder]] = [:]
        var parallelPlaceholdersAfterMessageID: [String: [ParallelChatPlaceholder]] = [:]
    }

    func makeTranscriptRowContext(rendered: [ConversationMessage]) -> TranscriptRowContext {
        let allMessages = conversationMessages
        let renderedIDs = Set(rendered.map(\.id))
        // Loaded and visible messages are listed once for every row rather than once per row.
        let loadedIDs = messages.map(\.id)
        let visibleIDs = Set(allMessages.map(\.id))
        let placeholders = parallelPlaceholderRows(in: allMessages)
        func anchor(_ messageID: String?) -> String? {
            messageID.flatMap { TranscriptRowAnchors.visibleAnchor(after: $0, loadedIDs: loadedIDs, visibleIDs: visibleIDs) }
        }
        let boundaries = TranscriptRowAnchors.rowsByRenderedAnchor(providerBoundaries, renderedIDs: renderedIDs) {
            anchor($0.afterMessageID)
        }
        let goalEntries = TranscriptRowAnchors.rowsByRenderedAnchor(goalAchievementTimelineEntries, renderedIDs: renderedIDs) {
            $0.afterMessageID == GoalAchievementTimelineEntry.beforeFirstMessageID ? nil : anchor($0.afterMessageID)
        }
        return TranscriptRowContext(
            inlineTools: inlineToolCalls.byMessageID,
            activityDisclosureAnchorID: shouldShowActivityDisclosure ? activityDisclosureAnchorID : nil,
            latestTurnStartID: latestConversationTurnStartID,
            conversationMessages: allMessages,
            boundariesByAnchorID: boundaries,
            goalEntriesByAnchorID: goalEntries,
            orderedContextCompactions: activities.filter { $0.isContextCompaction && $0.timelineOrder != nil },
            parallelPlaceholdersByMessageID: placeholders.before,
            parallelPlaceholdersAfterMessageID: placeholders.after
        )
    }

    /// Where each open bubble's page will return among the loaded turns, by the same rule its
    /// close applies, so the placeholder shows the very spot. A placeholder whose anchor turn
    /// isn't loaded waits until it is.
    func parallelPlaceholderRows(in allMessages: [ConversationMessage]) -> (before: [String: [ParallelChatPlaceholder]], after: [String: [ParallelChatPlaceholder]]) {
        guard !parallelChatPlaceholders.isEmpty else { return ([:], [:]) }
        var turnIDs: [String] = []
        var firstMessageIDByTurnID: [String: String] = [:]
        for message in allMessages {
            guard let turnID = message.turnID, firstMessageIDByTurnID[turnID] == nil else { continue }
            firstMessageIDByTurnID[turnID] = message.id
            turnIDs.append(turnID)
        }
        let pageIDByTurnID = chatPagesByTurnID.mapValues(\.id)
        let activePageID = chatPagesByTurnID.values.first { $0.closedAt == nil }?.id
        var before: [String: [ParallelChatPlaceholder]] = [:]
        var after: [String: [ParallelChatPlaceholder]] = [:]
        for placeholder in parallelChatPlaceholders {
            if let anchor = placeholder.anchorTurnID, !turnIDs.contains(anchor) { continue }
            let insertion = ConversationManager.parallelChatBubbleInsertion(
                turnIDs: turnIDs, anchorTurnID: placeholder.anchorTurnID,
                pageIDByTurnID: pageIDByTurnID, activePageID: activePageID
            )
            if insertion < turnIDs.count, let messageID = firstMessageIDByTurnID[turnIDs[insertion]] {
                before[messageID, default: []].append(placeholder)
            } else if let last = allMessages.last {
                after[last.id, default: []].append(placeholder)
            }
        }
        return (before, after)
    }

    /// For each rendered message, a summary of everything its rows render from besides its ID, so
    /// a box whose message changed is measured again rather than kept at a stale height.
    func transcriptRowSignatures(_ rendered: [ConversationMessage], context: TranscriptRowContext) -> [Int] {
        guard !rendered.isEmpty else { return [] }
        let annotationCounts = Dictionary(grouping: annotations, by: \.messageID).mapValues(\.count)
        let compactionCount = context.orderedContextCompactions.count
        return rendered.map { message in
            var hasher = Hasher()
            hasher.combine(message.text.utf16.count)
            hasher.combine(transcriptImageDataURLs(for: message).count)
            hasher.combine(message.imagesDeferred == true && deferredMessageImages[Self.deferredImageKey(message)] == nil)
            hasher.combine(message.asyncQuestions != nil)
            hasher.combine(context.inlineTools[message.id]?.count ?? 0)
            hasher.combine(context.boundariesByAnchorID[message.id]?.count ?? 0)
            hasher.combine(context.goalEntriesByAnchorID[message.id]?.count ?? 0)
            hasher.combine(context.parallelPlaceholdersByMessageID[message.id]?.count ?? 0)
            hasher.combine(context.parallelPlaceholdersAfterMessageID[message.id]?.count ?? 0)
            hasher.combine(annotationCounts[message.id] ?? 0)
            hasher.combine(message.id == context.activityDisclosureAnchorID)
            hasher.combine(isResponding && message.role == .assistant && message.text.isEmpty)
            hasher.combine(compactionCount)
            hasher.combine(turnTokenUsageShown(for: message)?.totalTokens)
            return hasher.finalize()
        }
    }

    /// The rows above a message: its page separator and the activity disclosure.
    @ViewBuilder
    func transcriptLeadingRows(for message: ConversationMessage, context: TranscriptRowContext) -> some View {
        ForEach(context.parallelPlaceholdersByMessageID[message.id] ?? []) { placeholder in
            ParallelChatPlaceholderRow(bubbleID: placeholder.id, prompt: placeholder.prompt)
                .id("parallel-chat-placeholder-\(placeholder.id.uuidString)")
        }
        if sendsNewChatPage, task.isStandaloneChat, message.id == context.latestTurnStartID {
            // The turn's page is filed when the turn ends; until then its separator is the new page's.
            newChatPageSeparator(removable: false)
                .id("new-chat-page-separator-\(message.id)")
        } else if let page = standaloneChatPageSeparator(before: message) {
            // A message written during a turn is queued or steers it, and neither carries a page.
            standaloneChatPageSeparator(page, canRecall: page.id != activeChatPageID && !isReadOnly && !isResponding)
                .id("chat-page-separator-\(page.id)-\(message.id)")
        }
        if message.id == context.activityDisclosureAnchorID {
            activityList
        }
    }

    /// One message of the rendered window with the rows anchored to it: its
    /// page separator and activity disclosure above, and the boundaries, goal
    /// achievements, tool calls, and compactions that follow it.
    @ViewBuilder
    func transcriptRows(for message: ConversationMessage, context: TranscriptRowContext) -> some View {
        // The question itself starts the newest turn, below any page separator, so the rows
        // above it are laid out as rows of their own and a pin lands on the bubble.
        if message.id != context.latestTurnStartID {
            transcriptLeadingRows(for: message, context: context)
        }
        transcriptEntry(message)
            .id(message.id)
        if let usage = turnTokenUsageShown(for: message) {
            turnTokenUsageRow(message, usage: usage)
        }
        ForEach(context.boundariesByAnchorID[message.id] ?? []) { boundary in
            providerBoundaryRow(boundary)
        }
        ForEach(context.goalEntriesByAnchorID[message.id] ?? []) { entry in
            goalAchievementTimelineRow(entry)
                .id(entry.id)
        }
        ForEach(context.inlineTools[message.id] ?? []) { activity in
            if let pageID = activity.recalledChatPageID {
                ChatPageRecallRow(activityID: activity.id, pageID: pageID)
            } else {
                ToolCallTimelineRow(activity: activity, expansion: toolCallExpansion)
            }
        }
        // Most transcripts have no compaction, so the scan for the next ordered message runs only when one exists.
        let compactions = message.timelineOrder == nil ? [] : context.orderedContextCompactions
        let nextOrder = compactions.isEmpty ? nil : context.conversationMessages.first(where: {
            guard let current = message.timelineOrder, let candidate = $0.timelineOrder else { return false }
            return candidate > current
        })?.timelineOrder
        ForEach(compactions.filter {
            guard let eventOrder = $0.timelineOrder,
                  let messageOrder = message.timelineOrder, eventOrder > messageOrder else { return false }
            return nextOrder.map { eventOrder < $0 } ?? true
        }) { activity in
            contextCompactionTimelineRow(activity)
        }
        ForEach(context.parallelPlaceholdersAfterMessageID[message.id] ?? []) { placeholder in
            ParallelChatPlaceholderRow(bubbleID: placeholder.id, prompt: placeholder.prompt)
                .id("parallel-chat-placeholder-\(placeholder.id.uuidString)")
        }
    }
    /// The standalone chat shows each turn's tokens under the turn's last reply, where the
    /// window can open Token Stats from it.
    func turnTokenUsageShown(for message: ConversationMessage) -> ConversationTokenUsage? {
        guard task.isStandaloneChat, showTokenStats != nil else { return nil }
        return message.turnTokenUsage
    }

    /// A reply's small token counter, the task item's counter button, opening Token Stats for that turn alone.
    func turnTokenUsageRow(_ message: ConversationMessage, usage: ConversationTokenUsage) -> some View {
        let number = IntegerFormatStyle<Int>().grouping(.automatic)
        let description = "This turn used \(usage.totalTokens.formatted(number)) tokens: "
            + "\(usage.inputTokens.formatted(number)) input, \(usage.outputTokens.formatted(number)) output, "
            + "\(usage.cacheReadTokens.formatted(number)) cache read, \(usage.cacheCreationTokens.formatted(number)) cache write"
        return AtomStack(props: StackProps(axis: "h"), common: AtomCommon(fillWidth: true)) {
            TokenCounterButton(
                tokens: TaskItemModel.Tokens(
                    compact: "\(TokenUsageHeatmap.compact(usage.totalTokens)) tokens", color: "secondary", description: description
                ),
                testID: "message-token-usage-\(message.id)",
                action: { showTokenStats?(TokenStatsTarget(id: task.id, title: task.title, turnID: message.turnID)) }
            )
            AtomSpacer(props: SpacerProps(minLength: 0))
        }
    }

    func goalAchievementTimelineRow(_ entry: GoalAchievementTimelineEntry) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 12, group: true), common: AtomCommon(testID: "goal-achievement-timeline-row", fillWidth: true, paddingY: 4)) {
            AtomIcon(props: IconProps(name: "checkmark.circle", size: 18, weight: "regular", color: "secondary"))
            AtomText(props: TextProps(text: entry.summary, size: 15, color: "secondary"), common: AtomCommon(testID: "goal-achieved-banner"))
            AtomSpacer(props: SpacerProps(minLength: 0))
        }
    }

    /// A message as the transcript shows it. A background agent's report is the agent's work, not
    /// the parent's reply, so it gets the agent's row, which opens the report, instead of a bubble.
    @ViewBuilder
    func transcriptEntry(_ message: ConversationMessage) -> some View {
        let reportPrefix = ConversationTranscriptStore.backgroundAgentReportMessagePrefix
        if message.role == .assistant, message.phase == "subagent_report", message.id.hasPrefix(reportPrefix) {
            let agentID = String(message.id.dropFirst(reportPrefix.count))
            subagentTimelineRow(
                agentReportActivity(agentID: agentID, report: message.text),
                identifier: "agent-report-row-\(agentID)"
            )
        } else {
            messageBubble(message)
        }
    }

    /// The agent a report belongs to, carrying the report the agent window shows. A report whose
    /// activity isn't loaded still opens, under a generic name.
    func agentReportActivity(agentID: String, report: String) -> ConversationActivity {
        var activity = activities.first { $0.childThreadID == agentID || $0.id == agentID }
            ?? ConversationActivity(id: agentID, title: "Background agent", detail: report, status: "completed", childThreadID: agentID)
        activity.detail = report
        return activity
    }

    func subagentTimelineRow(_ activity: ConversationActivity, identifier: String? = nil) -> some View {
        // The icon sits beside the button, not in its label, because a macOS
        // button folds its label into one accessible element and the icon must
        // stay a distinct image.
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Color.clear.frame(width: 20, height: 5).accessibilityHidden(true)
                Image("SubagentIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { openSubagent(activity) }
                    .plainButtonHoverPointer()
                    .accessibilityLabel("\(activity.title) agent icon")
            }
            Button {
                openSubagent(activity)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(activity.title) \(activity.timelineStatus)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let metadata = [activity.agentPath, activity.model, activity.reasoningEffort]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                    if let duration = activity.durationLabel() {
                        Text(duration)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
            .plainButtonHoverPointer()
            .nativeHelp("Open the read-only conversation for this agent")
            .buttonStyle(.plain)
            // Beside the button, like the icon, so it stays its own element.
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 30)
                .contentShape(Rectangle())
                .onTapGesture { openSubagent(activity) }
                .plainButtonHoverPointer()
                .accessibilityLabel("Open \(activity.title)")
                .accessibilityIdentifier("subagent-row-chevron")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.title) \(activity.timelineStatus)")
        .accessibilityValue([activity.detail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier(identifier ?? "codex-subagent-row-\(activity.childThreadID ?? activity.id)")
    }

    @ViewBuilder
    func activityRow(_ activity: ConversationActivity, compact: Bool = false) -> some View {
        let displayDetail = [activity.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if compact {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                Text(activity.titlePreview ?? activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("codex-activity-title-\(activity.id)")
                if !displayDetail.isEmpty {
                    Text(displayDetail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                        .accessibilityLabel(displayDetail)
                } else {
                    Spacer(minLength: 0)
                }
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if activity.isActive, activity.startedAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let duration = activity.durationLabel(at: timeline.date) ?? ""
                        Text(duration)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityValue(duration)
                            .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
            .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityIdentifier("codex-activity-row-\(activity.id)")
        } else {
        // A row is one line until the reader expands it: the title's first line, its status and,
        // while it runs, its elapsed time. Expanding shows the whole title, the detail and the
        // duration. The row's accessibility value carries the detail and duration either way.
        let isExpanded = expandedActivityIDs.contains(activity.id)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                // A long title shows its preview until the reader expands it; see `titlePreview`.
                let titlePreview = activity.titlePreview
                if !isExpanded || titlePreview == nil {
                    Text(titlePreview ?? activity.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("codex-activity-title-\(activity.id)")
                }
                Spacer(minLength: 4)
                if !isExpanded, activity.isActive, activity.startedAt != nil {
                    activityDurationText(activity)
                }
                Button {
                    if isExpanded { expandedActivityIDs.remove(activity.id) } else { expandedActivityIDs.insert(activity.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .plainButtonHoverPointer()
                .nativeHelp(isExpanded ? "Show only the first line of this activity" : "Show this activity's whole title and details")
                .accessibilityLabel(isExpanded ? "Collapse activity" : "Expand activity to show all text")
                .accessibilityValue(isExpanded ? "expanded" : "collapsed")
                .accessibilityIdentifier("codex-activity-toggle-\(activity.id)")
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if isExpanded {
                if activity.titlePreview != nil {
                    // On its own line rather than in the header's stack, which would measure it
                    // as one line of the whole title on every pass.
                    Text(activity.title)
                        .font(.system(size: 11, weight: .medium))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("codex-activity-title-\(activity.id)")
                }
                if !displayDetail.isEmpty {
                    Text(displayDetail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                        .accessibilityLabel(displayDetail)
                }
                activityDurationText(activity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
        .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier(activity.isSubagent ? "codex-subagent-row-\(activity.childThreadID ?? activity.id)" : "codex-activity-row-\(activity.id)")
        }
    }

    /// An activity's duration: ticking while it runs, its measured time once it ends.
    @ViewBuilder
    func activityDurationText(_ activity: ConversationActivity) -> some View {
        if activity.isActive, activity.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let duration = activity.durationLabel(at: timeline.date) ?? ""
                Text(duration)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityValue(duration)
                    .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
            }
        } else if let duration = activity.durationLabel() {
            Text(duration)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityValue(duration)
                .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
        } else {
            Text("Duration unavailable")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .accessibilityValue("Duration unavailable")
                .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
        }
    }

    /// Composed only of plugin atoms (Plugins/Atoms).
    func contextCompactionTimelineRow(_ activity: ConversationActivity) -> some View {
        AtomStack(
            props: StackProps(axis: "h", spacing: 9, align: "top", group: true),
            common: AtomCommon(
                testID: "context-compaction-row-\(activity.id)", label: "\(activity.title), \(activity.statusLabel), \(activity.detail)",
                value: activity.statusLabel, paddingY: 5
            )
        ) {
            AtomIcon(props: IconProps(name: "arrow.triangle.2.circlepath", color: "secondary"))
            AtomStack(props: StackProps(spacing: 3, align: "leading")) {
                AtomText(props: TextProps(text: activity.status == "inProgress" ? "Compacting context…" : activity.title, size: 12, weight: "medium"))
                if !activity.detail.isEmpty {
                    AtomText(
                        props: TextProps(text: activity.detail, size: 11, color: "secondary", lineLimit: 4),
                        common: AtomCommon(testID: "context-compaction-summary-\(activity.id)")
                    )
                }
            }
        }
    }

    /// Composed only of plugin atoms (Plugins/Atoms).
    func providerBoundaryRow(_ boundary: ConversationProviderBoundary) -> some View {
        let title = "Conversation switched to \(boundary.provider.displayName)"
        return AtomStack(props: StackProps(axis: "h", spacing: 10), common: AtomCommon(paddingY: 4)) {
            transcriptRule(opacity: 0.12)
            AtomText(props: TextProps(text: title, size: 11, weight: "semibold", color: "secondary", lineLimit: 1))
                .fixedSize()
                .accessibilitySummary(title, id: "provider-boundary-\(boundary.provider.rawValue)")
            transcriptRule(opacity: 0.12)
        }
        .id(boundary.id)
    }

    /// A hairline that takes the row's remaining width, beside a separator's title.
    func transcriptRule(opacity: Double) -> some View {
        AtomPanel(props: PanelProps(fill: "primary", fillOpacity: opacity, cornerRadius: 0), common: AtomCommon(height: 1, fillWidth: true, padding: 0)) {}
    }

    func openSubagent(_ activity: ConversationActivity) {
        selectedSubagent = activity
        subagentHistory = nil
        subagentError = nil
        isLoadingSubagent = true
        subagentRefresh?.cancel()
        guard activity.childThreadID != nil else { return }
        subagentRefresh = Task { @MainActor in
            // A running agent keeps working; read it again until it finishes,
            // then once more so its final work and report are shown.
            var isRunning = true
            while isRunning, !Task.isCancelled, selectedSubagent?.id == activity.id {
                let current = activities.first { $0.id == activity.id } ?? activity
                isRunning = current.isActive
                do {
                    subagentHistory = try await conversationManager.subagentHistory(taskID: task.id, activity: current)
                    subagentError = nil
                } catch {
                    // A failed refresh keeps the work already shown.
                    if subagentHistory == nil {
                        subagentError = "Couldn't load this agent conversation: \(error.localizedDescription)"
                    }
                }
                isLoadingSubagent = false
                if isRunning { try? await Task.sleep(for: Self.subagentRefreshInterval) }
            }
        }
    }

    static let subagentRefreshInterval: Duration = .seconds(2)

    /// The agent's tool calls that follow the given message, or precede every message when nil.
    func subagentToolCalls(after messageID: String?, in history: ConversationHistory) -> [ConversationActivity] {
        history.timelineActivities.filter { $0.afterMessageID == messageID }
    }

    func subagentConversation(_ activity: ConversationActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    subagentRefresh?.cancel()
                    selectedSubagent = nil
                    subagentHistory = nil
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
                .plainButtonHoverPointer()
                .nativeHelp("Return to the parent conversation")
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagent-back-button")
                Text(activity.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Read only").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if isLoadingSubagent {
                ProgressView("Loading agent conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let subagentError {
                Text(subagentError).foregroundStyle(.secondary).padding(24)
            } else if let subagentHistory {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(subagentToolCalls(after: nil, in: subagentHistory)) { activity in
                            ToolCallTimelineRow(activity: activity, expansion: toolCallExpansion)
                        }
                        ForEach(subagentHistory.messages) { message in
                            messageBubble(message)
                            ForEach(subagentToolCalls(after: message.id, in: subagentHistory)) { activity in
                                ToolCallTimelineRow(activity: activity, expansion: toolCallExpansion)
                            }
                        }
                        if subagentHistory.messages.isEmpty && subagentHistory.timelineActivities.isEmpty {
                            Text("No conversation content is available yet.").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .hoverRevealScrollers()
                }
                .accessibilityIdentifier("subagent-conversation-scroll-view")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-conversation-panel")
    }
}
