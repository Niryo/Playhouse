import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    func revealOlderConversationMessages(using proxy: ScrollViewProxy, covering distance: CGFloat? = nil) {
        guard hasOlderConversationMessages, !isRevealingOlderConversationMessages else { return }
        let allMessages = conversationMessages
        guard let currentTopID = renderedConversationMessages.first?.id,
              let currentStartIndex = allMessages.firstIndex(where: { $0.id == currentTopID }) else { return }
        let batchSize = Self.olderConversationMessageBatchSize
        var newStartIndex = max(0, currentStartIndex - batchSize)
        var needsEarlierPage = currentStartIndex < batchSize
        if let distance {
            let heights = estimatedConversationRowHeights(of: 0..<currentStartIndex, in: allMessages)
            var covered = heights[newStartIndex...].reduce(0, +)
            while covered < distance, newStartIndex > 0 {
                let next = max(0, newStartIndex - batchSize)
                covered += heights[next..<newStartIndex].reduce(0, +)
                newStartIndex = next
            }
            needsEarlierPage = needsEarlierPage || covered < distance
        }
        // The loaded messages cannot fill what is to be revealed above the
        // window, so read the next older page from the daemon first.
        if needsEarlierPage, earlierStoredMessageCount > 0 {
            isRevealingOlderConversationMessages = true
            isOlderConversationRevealArmed = false
            Task { @MainActor in
                let loaded = await loadEarlierConversationMessages()
                isRevealingOlderConversationMessages = false
                if loaded { revealOlderConversationMessages(using: proxy, covering: distance) }
            }
            return
        }
        guard newStartIndex < currentStartIndex else { return }
        isRevealingOlderConversationMessages = true
        isOlderConversationRevealArmed = false
        oldestRenderedMessageID = allMessages[newStartIndex].id
        if distance != nil {
            Task { @MainActor in
                // The revealed rows take the runway's place at the reader's
                // offset; once laid out, judge again in case the estimate fell
                // short of the viewport.
                await Task.yield()
                for delay in Self.scrollSettleDelays {
                    try? await Task.sleep(nanoseconds: delay)
                }
                isRevealingOlderConversationMessages = false
                if let offsetY = lastConversationScrollSample.offsetY {
                    handleConversationWindowTop(
                        conversationWindowTopY(offsetY: offsetY, viewportHeight: lastConversationScrollSample.viewportHeight),
                        using: proxy,
                        allowsJump: true
                    )
                }
            }
            return
        }
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let restoreAnchor = { proxy.scrollTo(currentTopID, anchor: .top) }
            withTransaction(transaction, restoreAnchor)
            // The batch that was just inserted above the anchor is positioned
            // from estimates until its rows are realized, so the anchor has to
            // be restored again once they are.
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(transaction, restoreAnchor)
            }
            isRevealingOlderConversationMessages = false
        }
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
    func applyHistoryMessages(_ history: ConversationHistory, _ incoming: [ConversationMessage]? = nil) {
        // Buffered text arrived before this history, so it applies first, as it would have unbuffered.
        flushStreamedTextDeltas()
        defer { mergeTimelineActivities(history.timelineActivities) }
        let incoming = incoming ?? history.messages
        if let earlierCount = history.earlierMessageCount {
            if let first = incoming.first, let overlap = messages.firstIndex(where: { $0.id == first.id }) {
                messages = Array(messages[..<overlap]) + incoming
                earlierStoredMessageCount = max(0, earlierCount - overlap)
            } else {
                messages = incoming
                earlierStoredMessageCount = earlierCount
            }
            return
        }
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

    /// The runway occupies everything above the rendered window, so the distance
    /// from the viewport top to the window top is what is left of it.
    func conversationWindowTopY(offsetY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard hasOlderConversationMessages else { return -offsetY }
        let runwayHeight = lastConversationScrollSample.runwayHeight
        return (runwayHeight > 0 ? runwayHeight : viewportHeight) - offsetY
    }

    /// The runway's height: the estimated length of every message above the
    /// rendered window, the loaded ones and those still in the store, and at
    /// least a viewport so an upward drag is always available. Recorded on the
    /// scroll sample, where scroll handling reads where the window top is.
    func olderConversationRunwayHeight(viewport: CGSize) -> CGFloat {
        let sample = lastConversationScrollSample
        sample.viewportHeight = viewport.height
        guard hasOlderConversationMessages else {
            sample.runwayHeight = 0
            return 0
        }
        let allMessages = conversationMessages
        let startIndex = oldestRenderedMessageID.flatMap { id in allMessages.firstIndex { $0.id == id } }
            ?? max(0, allMessages.count - Self.olderConversationMessageBatchSize)
        // The runway sits above everything the reader can see, so a change in
        // its height moves the content under them. It is estimated again only
        // when the window or the history above it changes, which a reveal or a
        // reload owns the position for, never as the transcript reflows to a
        // new width or the window's own rows, a streaming answer among them,
        // grow.
        let key = ConversationScrollSample.RunwayKey(
            firstLoadedID: allMessages.first?.id,
            windowStartID: startIndex < allMessages.count ? allMessages[startIndex].id : nil,
            hiddenLoadedCount: startIndex,
            storedCount: earlierStoredMessageCount
        )
        if key == sample.runwayKey, sample.estimatedHiddenHeight > 0 {
            let height = max(viewport.height, sample.estimatedHiddenHeight)
            sample.runwayHeight = height
            return height
        }
        sample.runwayKey = key
        sample.rowHeightWidth = ConversationRowHeightEstimates.textWidth(viewportWidth: viewport.width)
        var hiddenHeight = estimatedConversationRowHeights(of: 0..<startIndex, in: allMessages).reduce(0, +)
        // Messages still in the store are assumed to be like the hidden loaded
        // ones. With none hidden, the last such average stands in.
        if startIndex > 0 {
            sample.storedMessageAverageHeight = hiddenHeight / CGFloat(startIndex)
        }
        hiddenHeight += sample.storedMessageAverageHeight * CGFloat(earlierStoredMessageCount)
        sample.estimatedHiddenHeight = hiddenHeight.rounded()
        let height = max(viewport.height, sample.estimatedHiddenHeight)
        sample.runwayHeight = height
        return height
    }

    /// Estimated height of each loaded message in `range` with the tool calls
    /// placed after it, at the width the runway was last laid out at.
    func estimatedConversationRowHeights(of range: Range<Int>, in allMessages: [ConversationMessage]) -> [CGFloat] {
        let sample = lastConversationScrollSample
        var toolCallCounts: [String: Int] = [:]
        for activity in timelineActivities {
            if let anchor = activity.afterMessageID { toolCallCounts[anchor, default: 0] += 1 }
        }
        return range.map { index in
            let message = allMessages[index]
            return sample.rowHeights.height(for: message, width: sample.rowHeightWidth)
                + CGFloat(toolCallCounts[message.id] ?? 0) * ConversationRowHeightEstimates.toolCallRowHeight
        }
    }

    /// Handles a new position for the top of the rendered window, measured from
    /// the top of the viewport. Dragging it below the threshold means the user
    /// scrolled past the oldest rendered message, which reveals the next batch.
    /// When `allowsJump` is set, a position deep in the runway, as dragging the
    /// scroller there leaves, reveals as many batches as the estimate says
    /// reach the viewport. The macOS 14 marker reports layout changes as well
    /// as scrolls, which is safe because the runway above the window only
    /// changes height when a reveal or a reload, both guarded here, changes it.
    func handleConversationWindowTop(_ windowTopY: CGFloat, using proxy: ScrollViewProxy, allowsJump: Bool = false) {
        // This runs for every scroll sample, and publishing state re-renders the
        // whole transcript, so the armed flag is only ever written when it
        // actually changes.
        guard hasOlderConversationMessages, !isRevealingOlderConversationMessages else {
            if isOlderConversationRevealArmed { isOlderConversationRevealArmed = false }
            return
        }
        // Opening pins the newest turn from an offset of zero, which is the top
        // of the runway; only a settled transcript can be jumped through.
        let viewportHeight = lastConversationScrollSample.viewportHeight
        if allowsJump, hasPresentedLatestConversation, !isLatestConversationTurnPinPending,
           viewportHeight > 0, windowTopY > viewportHeight {
            revealOlderConversationMessages(using: proxy, covering: windowTopY + viewportHeight)
            return
        }
        let isWithinWindowTop = windowTopY <= Self.olderConversationRevealThreshold
        guard isOlderConversationRevealArmed else {
            // Arm only once the window top has settled at or above the top of
            // the viewport. Position has to be observed, never assumed, or the
            // layout pass taken before the newest turn is pinned reveals a
            // batch on open.
            if isWithinWindowTop { isOlderConversationRevealArmed = true }
            return
        }
        guard !isWithinWindowTop else { return }
        revealOlderConversationMessages(using: proxy)
    }

    /// Keeps the newest content in view while the reader stays at the bottom.
    /// Reaching the bottom starts following; scrolling up away from it stops,
    /// so content arriving below never pulls a reader back down.
    func followConversationBottom(
        from old: ConversationScrollGeometry,
        to new: ConversationScrollGeometry,
        using proxy: ScrollViewProxy
    ) {
        let sample = lastConversationScrollSample
        if new.maxOffsetY - new.offsetY <= Self.conversationBottomFollowThreshold {
            sample.isFollowingLatest = true
            return
        }
        // Content arriving below leaves the offset where it was, and a shrinking
        // transcript clamps it onto the bottom, so only the reader moves it up.
        if new.offsetY < old.offsetY - 0.5 {
            sample.isFollowingLatest = false
            return
        }
        // A history load pins its own turn, and a reveal restores its anchor;
        // following the bottom then would scroll away from either.
        guard sample.isFollowingLatest, new.maxOffsetY != old.maxOffsetY,
              !isLatestConversationTurnPinPending, !isRevealingOlderConversationMessages else { return }
        Task { @MainActor in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(Self.conversationScrollEndID, anchor: .bottom) }
        }
    }

    /// Collapses the transcript to the newest user turn and pins that question
    /// to the top of the viewport.
    func presentLatestConversationTurn(using proxy: ScrollViewProxy) {
        guard let turnStartID = latestConversationTurnStartID else {
            // Nothing to pin: an empty conversation renders everything it
            // receives while it stays open.
            isLatestConversationTurnPinPending = false
            return
        }
        oldestRenderedMessageID = turnStartID
        isOlderConversationRevealArmed = false
        // This pin already puts the newest question at the top, so record it as
        // the one in view; otherwise the next message count change scrolls to it
        // a second time as though it had just been sent.
        lastScrolledUserMessageID = conversationMessages.last(where: { $0.role == .user && !$0.isPlayhouseSent })?.id
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let pin = {
                // A pending question form renders below the newest turn and
                // must be fully reachable, Submit included; pinning the turn's
                // question to the top can leave the form behind the composer.
                if let request = userInputRequest, request.threadID == task.activeConversationID {
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                } else {
                    proxy.scrollTo(turnStartID, anchor: .top)
                }
            }
            withTransaction(transaction, pin)
            // The rows below the pin are realized by that first scroll; pinning
            // again lands on their real positions instead of estimates.
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(transaction, pin)
            }
            hasPresentedLatestConversation = true
            isLatestConversationTurnPinPending = false
            // A pin that lands where the transcript already was reports no new
            // scroll sample, which would leave the reveal disarmed for good;
            // judge it from where the viewport now is.
            if let offsetY = lastConversationScrollSample.offsetY {
                handleConversationWindowTop(
                    conversationWindowTopY(offsetY: offsetY, viewportHeight: lastConversationScrollSample.viewportHeight),
                    using: proxy
                )
            }
        }
    }

    /// Timeline anchors resolve against the whole transcript, while the
    /// transcript renders a window that starts at the newest turn. Clamp an
    /// anchor that falls above the window to its first rendered message so the
    /// row still appears instead of disappearing with the messages it follows.
    ///
    /// Provider boundaries and goal achievements are state transitions that
    /// stay meaningful wherever they are shown, so they are clamped. Context
    /// compaction rows are not: they are positional markers whose meaning comes
    /// from the two messages they sit between, and they reappear with those
    /// messages as older batches are revealed.
    static func renderedAnchorMessageID(for anchorID: String?, renderedIDs: Set<String>, firstRenderedID: String?) -> String? {
        guard let anchorID else { return nil }
        if renderedIDs.contains(anchorID) { return anchorID }
        return firstRenderedID ?? anchorID
    }

    func goalAchievementAnchorMessageID(for entry: GoalAchievementTimelineEntry) -> String? {
        if entry.afterMessageID == GoalAchievementTimelineEntry.beforeFirstMessageID { return nil }
        if conversationMessages.contains(where: { $0.id == entry.afterMessageID }) {
            return entry.afterMessageID
        }
        return conversationMessages.last?.id
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
    }

    /// A rendered message's identity and its position in this pass's window. The
    /// transcript's `ForEach` iterates these rather than the messages themselves:
    /// SwiftUI compares a `ForEach`'s data on every update, and comparing every
    /// message's full contents on every streamed delta was a large share of the
    /// time spent streaming into a long conversation.
    struct RenderedMessageReference: Identifiable, Equatable {
        let id: String
        let index: Int
    }

    func makeTranscriptRowContext(rendered: [ConversationMessage]) -> TranscriptRowContext {
        let allMessages = conversationMessages
        let renderedIDs = Set(rendered.map(\.id))
        func renderedAnchor(_ anchorID: String?) -> String? {
            Self.renderedAnchorMessageID(for: anchorID, renderedIDs: renderedIDs, firstRenderedID: rendered.first?.id)
        }
        var boundaries: [String: [ConversationProviderBoundary]] = [:]
        for boundary in providerBoundaries {
            if let anchor = renderedAnchor(boundaryAnchorID(for: boundary)) { boundaries[anchor, default: []].append(boundary) }
        }
        var goalEntries: [String: [GoalAchievementTimelineEntry]] = [:]
        for entry in goalAchievementTimelineEntries {
            if let anchor = renderedAnchor(goalAchievementAnchorMessageID(for: entry)) { goalEntries[anchor, default: []].append(entry) }
        }
        return TranscriptRowContext(
            inlineTools: inlineToolCalls.byMessageID,
            activityDisclosureAnchorID: shouldShowActivityDisclosure ? activityDisclosureAnchorID : nil,
            latestTurnStartID: latestConversationTurnStartID,
            conversationMessages: allMessages,
            boundariesByAnchorID: boundaries,
            goalEntriesByAnchorID: goalEntries,
            orderedContextCompactions: activities.filter { $0.isContextCompaction && $0.timelineOrder != nil }
        )
    }

    /// For each settled message, a summary of everything its rows render from besides its ID, so a
    /// box whose message changed is measured again rather than kept at a stale height.
    func settledRowSignatures(_ settled: ArraySlice<ConversationMessage>, context: TranscriptRowContext) -> [Int] {
        guard !settled.isEmpty else { return [] }
        let annotationCounts = Dictionary(grouping: annotations, by: \.messageID).mapValues(\.count)
        let compactionCount = context.orderedContextCompactions.count
        return settled.map { message in
            var hasher = Hasher()
            hasher.combine(message.text.utf16.count)
            hasher.combine(message.imageDataURLs.count)
            hasher.combine(message.asyncQuestions != nil)
            hasher.combine(context.inlineTools[message.id]?.count ?? 0)
            hasher.combine(context.boundariesByAnchorID[message.id]?.count ?? 0)
            hasher.combine(context.goalEntriesByAnchorID[message.id]?.count ?? 0)
            hasher.combine(annotationCounts[message.id] ?? 0)
            hasher.combine(message.id == context.activityDisclosureAnchorID)
            hasher.combine(isResponding && message.role == .assistant && message.text.isEmpty)
            hasher.combine(compactionCount)
            return hasher.finalize()
        }
    }

    /// One message of the rendered window with the rows anchored to it: its
    /// page separator and activity disclosure above, and the boundaries, goal
    /// achievements, tool calls, and compactions that follow it.
    @ViewBuilder
    func transcriptRows(for message: ConversationMessage, context: TranscriptRowContext) -> some View {
        if let page = standaloneChatPageSeparator(before: message) {
            standaloneChatPageSeparator(page)
                .id("chat-page-separator-\(page.id)-\(message.id)")
        }
        if message.id == context.activityDisclosureAnchorID {
            activityList
        }
        transcriptEntry(message)
            .id(message.id)
            // The question itself starts the newest turn, below any page
            // separator, so a pin lands on the bubble.
            .layoutValue(key: ConversationLatestTurnStartKey.self, value: message.id == context.latestTurnStartID)
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
            .buttonHoverPointer()
            .nativeHelp("Open the read-only conversation for this agent")
            .buttonStyle(.plain)
            // Beside the button, like the icon, so it stays its own element.
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 30)
                .contentShape(Rectangle())
                .onTapGesture { openSubagent(activity) }
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
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
        .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier(activity.isSubagent ? "codex-subagent-row-\(activity.childThreadID ?? activity.id)" : "codex-activity-row-\(activity.id)")
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

    /// A boundary after a message that later folded into the activity list
    /// anchors to the nearest visible message instead.
    func boundaryAnchorID(for boundary: ConversationProviderBoundary) -> String? {
        guard let afterMessageID = boundary.afterMessageID else { return nil }
        if conversationMessages.contains(where: { $0.id == afterMessageID }) { return afterMessageID }
        guard let index = messages.firstIndex(where: { $0.id == afterMessageID }) else { return conversationMessages.last?.id }
        let visible = Set(conversationMessages.map(\.id))
        return messages[...index].last(where: { visible.contains($0.id) })?.id
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
        guard activity.childThreadID != nil else { return }
        Task { @MainActor in
            do {
                subagentHistory = try await conversationManager.subagentHistory(taskID: task.id, activity: activity)
            } catch {
                subagentError = "Couldn't load this agent conversation: \(error.localizedDescription)"
            }
            isLoadingSubagent = false
        }
    }

    func subagentConversation(_ activity: ConversationActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    selectedSubagent = nil
                    subagentHistory = nil
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
                .buttonHoverPointer()
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
                        ForEach(subagentHistory.messages) { message in messageBubble(message) }
                        if subagentHistory.messages.isEmpty {
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
