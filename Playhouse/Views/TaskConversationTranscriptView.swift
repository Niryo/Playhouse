import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {
    package var conversation: some PHView {
        PHGeometryReader { viewport in
            let scroll = transcriptScroll
            let showsPageAnchors = showsChatPageAnchors(transcriptWidth: viewport.size.width)
            let isBrowsingEarlier = isBrowsingEarlierMessages
            PHScrollView {
                let leadingGoalEntries = goalAchievementTimelineEntries.filter {
                    $0.afterMessageID == GoalAchievementTimelineEntry.beforeFirstMessageID
                }
                // Worked out once per pass rather than once per row: each walks the whole transcript, and
                // every row of it is rebuilt whenever the transcript's width changes, as while resizing the chat.
                let renderedMessages = renderedConversationMessages
                let rowContext = makeTranscriptRowContext(rendered: renderedMessages)
                // One layout holds every row, so it knows where each message is the moment it lays
                // out, which is what `TranscriptScrollController` positions the viewport from. Only
                // the messages near the viewport render; the rest are boxes of their measured height.
                TranscriptLayout(
                    spacing: Self.transcriptRowSpacing,
                    minimumLatestTurnHeight: max(0, viewport.size.height - Self.conversationVerticalPadding - Self.latestTurnTopMargin),
                    geometry: scroll.geometry
                ) {
                    if !messages.isEmpty {
                        PHForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                        PHForEach(providerBoundaries.filter { $0.afterMessageID == nil }) { boundary in
                            providerBoundaryRow(boundary)
                        }
                        TranscriptMessageRows(
                            ids: renderedMessages.map(\.id),
                            signatures: transcriptRowSignatures(renderedMessages, context: rowContext),
                            latestTurnStartID: rowContext.latestTurnStartID,
                            virtualizer: scroll.virtualizer,
                            pinnedIDs: Set([
                                renderedMessages.last?.id, rowContext.activityDisclosureAnchorID,
                                annotationSelection?.messageID, currentTextSelection?.messageID,
                            ].compactMap { $0 }),
                            latestTurnLeadingRows: { index in
                                PHAnyView(transcriptLeadingRows(for: renderedMessages[index], context: rowContext))
                            },
                            row: { index in
                                // One message's rows measure as one box.
                                PHAnyView(PHVStack(alignment: .leading, spacing: Self.transcriptRowSpacing) {
                                    transcriptRows(for: renderedMessages[index], context: rowContext)
                                })
                            }
                        )
                        // What belongs to the newest turn waits below an earlier chat page
                        // the reader jumped to.
                        if !isBrowsingEarlier {
                            PHForEach(liveChatPageRecalls) { activity in
                                if let pageID = activity.recalledChatPageID {
                                    ChatPageRecallRow(activityID: activity.id, pageID: pageID)
                                }
                            }
                            if shouldShowActivityDisclosure, activityDisclosureAnchorID == nil {
                                activityList
                            }
                        }
                    } else {
                        // Until the first history read lands the conversation is not known to be
                        // empty, so it shows that it is loading rather than the empty prompt. A new
                        // task has nothing to read: it shows its empty state at once.
                        if !hasLoadedConversation && !isNewTask {
                            ConversationHistoryLoadingIndicator()
                        } else if activeGoal?.status != "complete" && (isNewTask || !isLoadingHistory) {
                            PHForEach(parallelChatPlaceholders.filter { $0.anchorTurnID == nil }) { placeholder in
                                ParallelChatPlaceholderRow(bubbleID: placeholder.id, prompt: placeholder.prompt)
                                    .id("parallel-chat-placeholder-\(placeholder.id.uuidString)")
                            }
                            emptyConversationPlaceholder
                        }
                        if shouldShowActivityDisclosure {
                            activityList
                        }
                        PHForEach(providerBoundaries) { boundary in
                            providerBoundaryRow(boundary)
                        }
                        PHForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                    }
                    if !isBrowsingEarlier {
                        if let request = userInputRequest, request.threadID == task.activeConversationID {
                            userInputForm(request)
                                .frame(maxWidth: 620, alignment: .leading)
                                .accessibilityIdentifier("conversation-user-input-request")
                        }

                        if let activeProcess {
                            activityRow(activeProcess, compact: true)
                        }
                        PHForEach(activeSubagents) { activity in
                            subagentTimelineRow(activity)
                        }
                        PHForEach(activities.filter { $0.isContextCompaction && $0.timelineOrder == nil }) { activity in
                            contextCompactionTimelineRow(activity)
                        }
                    }
                }
                .padding(.vertical, Self.conversationVerticalPadding)
                // The open page labels widen the chat sidebar and push the rows right by as much,
                // so the rows keep their width and their text stays as it was.
                .modifier(ChatPageAnchorsPushedRows(push: chatPageAnchorsPush))
                .frame(maxWidth: .infinity)
                .hoverRevealScrollers()
                .transcriptScroll(
                    scroll,
                    layoutTop: Self.conversationVerticalPadding,
                    latestTurnMargin: Self.latestTurnTopMargin,
                    rendersTranscriptEnd: !isBrowsingEarlier,
                    handlers: transcriptScrollHandlers
                )
            }
            .accessibilityIdentifier("conversation-scroll-view")
            .accessibilityValue(hasLoadedConversation
                ? "Showing \(isBrowsingEarlier ? "earlier" : "latest") \(renderedConversationMessages.count) of \(storedConversationMessageCount) messages"
                : "Loading conversation history")
            .overlay(alignment: .leading) {
                chatPageAnchorsOverlay(showsLabels: showsPageAnchors, transcriptWidth: viewport.size.width)
            }
            .overlay(alignment: .bottom) { jumpToLatestButton }
            .preference(key: ChatPageAnchorsPushKey.self, value: showsPageAnchors ? ChatPageAnchorsLayout.pushWidth : 0)
            .onChange(of: offersChatPageAnchors(transcriptWidth: viewport.size.width)) { _, offers in
                // Labels slid out before the chat grew too narrow for them stay folded when it widens,
                // and the parts that vanished under the pointer no longer count as hovered.
                if !offers {
                    revealsChatPageAnchors = false
                    hoveredChatPageAnchorsParts = []
                }
            }
            .onChange(of: isLoadingHistory) { _, isLoading in
                // Every completed history load reopens on the newest turn,
                // including reloads that leave the messages unchanged.
                guard !isLoading else { return }
                presentLatestConversationTurn()
            }
            .onChange(of: messages.count) { _, _ in
                presentNewlySentQuestion()
            }
            .onChange(of: isResponding) { _, isResponding in
                if isResponding { scroll.followIfAtBottom() }
            }
            .task(id: latestActiveProcess?.id) {
                // An operation earns its own row only once it has run for a moment.
                try? await Task.sleep(for: .seconds(Self.activeProcessSettleDelay))
                guard !Task.isCancelled else { return }
                settledActiveProcessID = latestActiveProcess?.id
            }
            .onChange(of: userInputRequest?.id) { _, requestID in
                // The question form sits below the latest message; bring it into view
                // whether it arrives with the history or later from the daemon.
                guard requestID != nil, !isLoadingHistory else { return }
                if isBrowsingEarlierMessages { returnToLatestMessages() }
                scroll.pin(.bottom, animated: true)
            }
        }
    }

    /// Shown in place of the transcript while the conversation has no messages.
    package var emptyConversationPlaceholder: some PHView {
        PHVStack(spacing: 0) {
            if task.isStandaloneChat || task.authoringPluginID != nil {
                // A chat has no repository to name, so the placeholder keeps only
                // its prompt. The leading spacer balances the trailing one that
                // the title would otherwise have pushed against.
                PHSpacer(minLength: 0)
            } else {
                PHText(emptyConversationRepositoryTitle)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(emptyConversationRepositoryTitleColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityLabel(emptyConversationRepositoryTitle)
                    .accessibilityIdentifier("empty-conversation-repository-title")
                PHSpacer(minLength: 58)
            }
            if showsEmptyConversationAddRepositoryPrompt {
                emptyConversationAddRepositoryPrompt
            } else {
                emptyConversationModelPrompt
            }
            PHSpacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.horizontal, 30)
        .padding(.vertical, 38)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-conversation")
    }

    /// A repository task with nothing selected teaches the picker: the empty state's + opens the
    /// same Add repository hint as the header's + button.
    package var showsEmptyConversationAddRepositoryPrompt: Bool {
        !isReadOnly && !task.isStandaloneChat && task.authoringPluginID == nil
            && emptyConversationRepositoryNames.isEmpty
    }

    package var emptyConversationAddRepositoryPrompt: some PHView {
        EmptyConversationAddRepositoryPrompt(action: showRepositoryPicker)
    }

    package var emptyConversationModelPrompt: some PHView {
        PHVStack(spacing: 14) {
            PHImage(icon: .bubbleLeftAndBubbleRight)
                .font(.system(size: 29, weight: .regular))
                .foregroundStyle(PHColor.accentColor.opacity(0.8))
                .accessibilityLabel("Conversation")
            PHText(task.authoringPluginID != nil ? "Describe your plugin in the prompt below." : "Send a message to \(provider.assistantLabel(modelName: promptModelName)).")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel(task.authoringPluginID != nil ? "Describe your plugin in the prompt below." : "Send a message to \(provider.assistantLabel(modelName: promptModelName)).")
                .accessibilityIdentifier("model-prompt")
            if task.authoringPluginID != nil {
                emptyConversationPluginDetails
            }
        }
    }

    /// The choices the plugin editor started from, which the user can change by asking the agent.
    package var emptyConversationPluginDetailRows: [(id: String, label: String, value: String)] {
        let chat = task as? StandaloneChat
        var rows: [(id: String, label: String, value: String)] = []
        if let name = chat?.pluginAuthoringName { rows.append(("name", "Name", name)) }
        if let rawPlacement = task.authoringPluginPlacement {
            rows.append(("placement", "Placement", PluginPlacement(rawValue: rawPlacement)?.title ?? rawPlacement))
        }
        if let rawPresentation = chat?.pluginAuthoringPresentation {
            rows.append(("presentation", "Opens as", PluginPresentation(rawValue: rawPresentation)?.title ?? rawPresentation))
        }
        return rows
    }

    package var emptyConversationPluginDetails: some PHView {
        PHVStack(spacing: 12) {
            if !emptyConversationPluginDetailRows.isEmpty {
                PHVStack(alignment: .leading, spacing: 6) {
                    PHForEach(emptyConversationPluginDetailRows, id: \.id) { row in
                        PHHStack(alignment: .firstTextBaseline, spacing: 14) {
                            PHText(row.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            PHText(row.value)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(row.label): \(row.value)")
                        .accessibilityIdentifier("plugin-detail-\(row.id)")
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(PHRoundedRectangle(cornerRadius: 8).fill(PHColor.primary.opacity(0.05)))
            }
            PHText("Want to change any of these, even the name? Just ask in your prompt.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("plugin-details-change-hint")
        }
        .frame(maxWidth: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugin-details")
    }

    /// Space between the transcript's rows, and between the rows of one message.
    package static let transcriptRowSpacing: CGFloat = 16
    package static let conversationVerticalPadding: CGFloat = 24
    /// Space kept above the newest question when it is pinned to the top of the viewport.
    package static let latestTurnTopMargin: CGFloat = 12

    /// The selected repositories' names, or the Git roots' names for a task without worktrees.
    package var emptyConversationRepositoryNames: [String] {
        let repositoryNames = task.repositoryWorktrees.map {
            URL(fileURLWithPath: $0.repositoryPath).lastPathComponent
        }
        guard repositoryNames.isEmpty else { return repositoryNames }
        // A new task opens before its saved repositories are attached; naming them meanwhile
        // keeps the empty state from flashing "No repository selected" first.
        if isApplyingSavedRepositories {
            let savedNames = validLastSelectedRepositoryURLs.map(\.lastPathComponent)
            if !savedNames.isEmpty { return savedNames }
        }
        return task.workspaceRootPaths.compactMap { path in
            let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
            let gitMarker = repositoryURL.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitMarker.path) else { return nil }
            return repositoryURL.lastPathComponent
        }
    }

    package var emptyConversationRepositoryTitle: String {
        let repositoryNames = emptyConversationRepositoryNames
        return repositoryNames.isEmpty ? "No repository selected" : repositoryNames.joined(separator: " · ")
    }

    package var emptyConversationRepositoryTitleColor: PHColor {
        colorScheme == .dark
            ? .orange
            : PHColor(red: 0.18, green: 0.31, blue: 0.68)
    }

    package var activeSubagents: [ConversationActivity] {
        activities.filter { $0.isSubagent && $0.isActive }
    }

    /// Earlier turns' tool calls, keyed by the message each followed. The latest turn shows its
    /// calls in Working for instead, and folds them into Worked for once it finishes.
    package var inlineToolCalls: (byMessageID: [String: [ConversationActivity]], ids: Set<String>) {
        guard !timelineActivities.isEmpty else { return ([:], []) }
        var turnByMessageID: [String: String] = [:]
        for message in messages { if let turnID = message.turnID { turnByMessageID[message.id] = turnID } }
        let latestTurnID = latestConversationTurnID
        var byMessageID: [String: [ConversationActivity]] = [:]
        var ids = Set<String>()
        for activity in timelineActivities where activity.isTimelineToolCall {
            guard let anchor = activity.afterMessageID, let turnID = turnByMessageID[anchor],
                  turnID != latestTurnID, ids.insert(activity.id).inserted else { continue }
            byMessageID[anchor, default: []].append(activity)
        }
        return (byMessageID, ids)
    }

    /// The standalone chat's page recalls in the latest turn. They render as their own lines the
    /// moment the call is seen instead of waiting inside the collapsed work disclosure.
    package var liveChatPageRecalls: [ConversationActivity] {
        guard task.isStandaloneChat else { return [] }
        let inlineIDs = inlineToolCalls.ids
        return activities.filter { $0.recalledChatPageID != nil && !inlineIDs.contains($0.id) }
    }

    /// How long a live operation runs, in seconds, before it leaves the activity list for its own row.
    /// The row counts elapsed time in whole seconds, so an operation shorter than one has nothing
    /// for it to show that the list doesn't.
    package static let activeProcessSettleDelay: TimeInterval = 1

    /// The latest live operation, once it has run for `activeProcessSettleDelay`: since its start
    /// when that is known, as for a reopened task's long command, else since this window saw it.
    /// A provider can report an operation's start and end together (Codex reports the commands
    /// of a code cell once they ran, and a backlog of events arrives at once), and a row for each
    /// would flash Running and vanish before it could be read. Until then it waits in the list.
    package var activeProcess: ConversationActivity? {
        guard let process = latestActiveProcess else { return nil }
        if process.id == settledActiveProcessID { return process }
        guard let startedAt = process.startedAt, Date().timeIntervalSince(startedAt) >= Self.activeProcessSettleDelay else { return nil }
        return process
    }

    /// Keep the latest live non-agent operation in the conversation timeline.
    /// Earlier live operations remain available in the expanded activity list.
    package var latestActiveProcess: ConversationActivity? {
        activities
            .filter { !$0.isSubagent && !$0.isContextCompaction && $0.isActive && $0.recalledChatPageID == nil }
            .enumerated()
            .max { left, right in
                let leftOrder = left.element.timelineOrder ?? left.offset
                let rightOrder = right.element.timelineOrder ?? right.offset
                return leftOrder < rightOrder
            }?
            .element
    }

    @PHViewBuilder
    package var activityList: some PHView {
        let activeIDsOutside = Set(activeSubagents.map(\.id) + [activeProcess?.id].compactMap { $0 })
            .union(inlineToolCalls.ids)
        let expandedActivities = activities.filter {
            !$0.isSubagent && !$0.isContextCompaction && !activeIDsOutside.contains($0.id)
                && !(task.isStandaloneChat && $0.recalledChatPageID != nil)
        }
        let completedAgentActivities = activities.filter { $0.isSubagent && !$0.isActive }
        if isDisplayingActiveResponse && progressMessages.isEmpty && expandedActivities.isEmpty
            && completedAgentActivities.isEmpty && activeProcess == nil && activeSubagents.isEmpty
            && liveChatPageRecalls.isEmpty {
            thinkingRow
        } else {
            activityDisclosure(expandedActivities: expandedActivities, completedAgentActivities: completedAgentActivities)
        }
    }

    package func activityDisclosure(expandedActivities: [ConversationActivity], completedAgentActivities: [ConversationActivity]) -> some PHView {
        PHVStack(alignment: .leading, spacing: 8) {
            PHButton {
                phWithAnimation(.easeInOut(duration: 0.16)) {
                    isActivityExpanded.toggle()
                }
            } label: {
                activityDisclosureButtonLabel
            }
            .plainButtonHoverPointer()
            .nativeHelp("Show or hide Codex activity details")
            .buttonStyle(.plain)
            .accessibilityValue(isActivityExpanded ? "Expanded, down chevron" : "Collapsed, right chevron")
            .accessibilityHint("Shows Codex progress messages and completed activity details.")
            .accessibilityIdentifier("codex-activity-disclosure")


            PHDivider()
                .opacity(0.32)
                .accessibilityElement()
                .accessibilityLabel("Separator between work duration and response")

            if isActivityExpanded {
                PHVStack(alignment: .leading, spacing: 7) {
                    if !progressMessages.isEmpty {
                        PHText("Progress")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        PHForEach(progressMessages) { message in
                            AtomMarkdown(
                                props: MarkdownProps(text: Self.displayableAssistantText(message.text), size: 12, color: "text", selectable: true),
                                common: AtomCommon(testID: "codex-progress-message-\(message.id)")
                            )
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkspaceTheme.panelBackground, in: PHRoundedRectangle(cornerRadius: 8))
                        }
                    }
                    PHForEach(expandedActivities) { activity in
                        activityRow(activity)
                    }
                    if !completedAgentActivities.isEmpty {
                        PHText("Agents used")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        PHForEach(completedAgentActivities) { activity in
                            subagentTimelineRow(activity)
                        }
                    }
                }
                .padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("codex-activity-details")
            }
        }
    }

    /// Stands in for Working for until the turn reports its first progress or activity.
    package var thinkingRow: some PHView {
        PHHStack(spacing: 7) {
            PHProgressView()
                .controlSize(.small)
            PHText("Thinking…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking…")
        .accessibilityIdentifier("codex-activity-thinking")
    }

    /// Composed only of plugin atoms (Plugins/Atoms).

    /// The notices above the composer, composed only of plugin atoms (Plugins/Atoms).
    @PHViewBuilder
    package var composerNotices: some PHView {
        if let actionNotice {
            AtomLabel(props: LabelProps(text: actionNotice, icon: PHIcon.handRaisedFill.name, size: 11, weight: "medium", color: "orange"), common: AtomCommon(testID: "codex-action-notice"))
        }
        if let providerNotice {
            AtomLabel(props: LabelProps(text: providerNotice, icon: PHIcon.arrowTriangleSwap.name, size: 11, weight: "medium", color: "secondary"), common: AtomCommon(testID: "provider-capabilities-notice"))
                .fixedSize(horizontal: false, vertical: true)
        }
        if let errorMessage {
            AtomLabel(props: LabelProps(text: errorMessage, icon: PHIcon.exclamationmarkTriangleFill.name, size: 11, weight: "medium", color: "red"))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilitySummary(errorMessage, id: "codex-chat-error")
        }
    }

    /// Follow-ups waiting for the active turn, composed only of plugin atoms (Plugins/Atoms).
    package var queuedFollowUpList: some PHView {
        AtomPanel(
            props: PanelProps(spacing: 0, fill: "primary", fillOpacity: 0.08, cornerRadius: 18, stroke: "primary", strokeOpacity: 0.08),
            common: AtomCommon(testID: "queued-follow-ups", padding: 0)
        ) {
            PHForEach(waitingFollowUps) { queued in
                queuedFollowUpRow(queued)
            }
        }
    }

    package func queuedFollowUpRow(_ queued: QueuedConversationMessage) -> some PHView {
        let id = queued.id.uuidString
        return AtomStack(props: StackProps(axis: "h", spacing: 12, group: true), common: AtomCommon(testID: "queued-message-\(id)", paddingX: 14, paddingY: 11)) {
            AtomIcon(props: IconProps(name: PHIcon.textLineFirstAndArrowtriangleForward.name, size: 14, weight: "medium", color: "secondary"))
            AtomText(props: TextProps(text: queued.text, size: 14, lineLimit: 1), common: AtomCommon(testID: "queued-message-text-\(id)", fillWidth: true))
            if let imageCount = queued.imageDataURLs?.count, imageCount > 0 {
                let description = imageCount == 1 ? "1 attached image" : "\(imageCount) attached images"
                AtomLabel(props: LabelProps(text: "\(imageCount)", icon: PHIcon.photo.name, size: 12, color: "secondary"), common: AtomCommon(help: description))
                    .accessibilitySummary(description, id: "queued-message-images-\(id)")
            }
            if queued.state == .needsAction {
                AtomText(props: TextProps(text: "Needs action", size: 12, color: "secondary"), common: AtomCommon(testID: "queued-message-needs-action-\(id)", label: "Follow-up needs your action"))
                AtomButton(
                    props: ButtonProps(style: "automatic"),
                    common: AtomCommon(testID: "retry-queued-message-\(id)", label: "Retry follow-up", help: "Retry this follow-up"),
                    action: { retryQueuedMessage(queued) }
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.arrowClockwise.name, size: 13, weight: "medium"))
                }
            } else {
                AtomButton(
                    props: ButtonProps(style: "automatic", disabled: isSubmittingLiveMessage),
                    common: AtomCommon(testID: "steer-queued-message-\(id)", help: "Send this follow-up to the active turn now"),
                    action: { steerQueuedMessage(queued) }
                ) {
                    AtomText(props: TextProps(text: "Steer"))
                }
            }
            AtomButton(
                props: ButtonProps(style: "automatic"),
                common: AtomCommon(testID: "remove-queued-message-\(id)", label: "Remove follow-up", help: "Remove this follow-up"),
                action: { removeQueuedMessage(queued) }
            ) {
                AtomIcon(props: IconProps(name: PHIcon.trash.name, size: 13, weight: "medium"))
            }
            AtomMenu(
                props: MenuProps(icon: PHIcon.ellipsis.name, size: 13, weight: "semibold", color: "primary", indicator: true, items: [[
                    MenuProps.Item(id: "copy", title: "Copy text", help: "Copy this follow-up"),
                    MenuProps.Item(id: "remove", title: "Remove follow-up", destructive: true, help: "Remove this follow-up"),
                ]]),
                common: AtomCommon(testID: "queued-message-more-\(id)", label: "More follow-up actions", help: "More follow-up actions", width: 24, height: 24),
                onMenu: { choice in
                    if choice == "copy" {
                        Platform.services.copyToClipboard(queued.text)
                    } else {
                        removeQueuedMessage(queued)
                    }
                }
            )
        }
    }

    /// The active goal above the composer box, composed only of plugin atoms
    /// (Plugins/Atoms); a native timeline ticks its elapsed time.
    package func activeGoalRow(_ activeGoal: CodexThreadGoal) -> some PHView {
        let isPaused = activeGoal.status == "paused"
        let progress = conversationRuntime.snapshot.goal.turnStartedThreadID == task.codexThreadID
            ? "Work started" : (conversationRuntime.isTurnActive(threadID: task.codexThreadID ?? "") ? "Working" : "Waiting")
        return AtomPanel(
            props: PanelProps(fill: "primary", fillOpacity: 0.10, cornerRadius: 18, stroke: "primary", strokeOpacity: 0.08),
            common: AtomCommon(testID: "active-goal-progress-row", value: progress, padding: 0, paddingX: 14, paddingY: 10)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 10)) {
                AtomIcon(props: IconProps(name: PHIcon.scope.name, size: 17, weight: "medium", color: "secondary"))
                AtomText(props: TextProps(text: "\(isPaused ? "Paused goal" : "Pursuing goal") \(activeGoal.objective)", size: 15, lineLimit: 1), common: AtomCommon(testID: "active-goal-title"))
                AtomSpacer(props: SpacerProps(minLength: 4))
                if let seconds = activeGoal.timeUsedSeconds {
                    PHTimelineView(.periodic(from: .now, by: 1)) { context in
                        AtomText(
                            props: TextProps(text: Self.goalDuration(goalElapsedTime(for: activeGoal, reportedSeconds: seconds)
                                + (activeGoal.status == "active" ? context.date.timeIntervalSince(goalStatusUpdatedAt) : 0)), color: "secondary"),
                            common: AtomCommon(testID: "goal-elapsed-time")
                        )
                    }
                }
                AtomButton(props: ButtonProps(destructive: true), common: AtomCommon(testID: "goal-clear-button", label: "Clear goal", help: "Clear goal"), action: { Task { await mutateGoal("clear") } }) {
                    AtomIcon(props: IconProps(name: PHIcon.trash.name))
                }
                AtomButton(
                    common: AtomCommon(testID: "goal-pause-resume-button", label: isPaused ? "Resume goal" : "Pause goal", help: isPaused ? "Resume goal" : "Pause goal"),
                    action: { Task { await mutateGoal(isPaused ? "resume" : "pause") } }
                ) {
                    AtomIcon(props: IconProps(name: isPaused ? PHIcon.playFill.name : "pause"))
                }
                AtomButton(
                    common: AtomCommon(
                        testID: "goal-expand-button", label: isGoalExpanded ? "Collapse goal" : "Expand goal", value: isGoalExpanded ? "Expanded" : "Collapsed",
                        help: isGoalExpanded ? "Collapse goal" : "Expand goal", width: 30, height: 30
                    ),
                    action: { isGoalExpanded.toggle() }
                ) {
                    AtomIcon(props: IconProps(name: isGoalExpanded ? PHIcon.arrowDownRightAndArrowUpLeft.name : PHIcon.arrowUpLeftAndArrowDownRight.name))
                }
            }
        }
    }

    package var composer: some PHView {
        PHVStack(alignment: .leading, spacing: 8) {
            if !pendingImages.isEmpty {
                PHScrollView(.horizontal) {
                    PHHStack(spacing: 8) {
                        PHForEach(pendingImages) { attachment in
                            PHZStack(alignment: .topTrailing) {
                                PHButton { selectedChatImage = attachment.image } label: {
                                    PHImage(platformImage: attachment.image).resizable().scaledToFill()
                                        .frame(width: 64, height: 52)
                                        .clipShape(PHRoundedRectangle(cornerRadius: 8))
                                        // Clipping only hides the filled image's overflow; without a shape the
                                        // overflow still takes clicks, covering the previous thumbnail's remove badge.
                                        .contentShape(PHRoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open attached image")
                                .accessibilityIdentifier("pending-chat-image-\(attachment.id)")
                                .plainButtonHoverPointer()
                                .nativeHelp("Open image at full size")

                                PHButton {
                                    pendingImages.removeAll { $0.id == attachment.id }
                                    persistDraft()
                                } label: {
                                    PHImage(icon: .xmarkCircleFill).foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .plainButtonHoverPointer()
                                .nativeHelp("Remove image")
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove image")
                                .accessibilityIdentifier("remove-pending-chat-image-\(attachment.id)")
                            }
                        }
                    }
                    .hoverRevealScrollers()
                }.accessibilityIdentifier("pending-chat-images")
            }
            composerNotices

            if !waitingFollowUps.isEmpty {
                queuedFollowUpList
            }
            newChatPageControl

            ComposerView(model: composerModel, actions: composerActions, header: {
        recalledChatPageChips
        let pendingCommentCount = annotations.filter(\.pending).count
        if pendingCommentCount > 0 {
            AtomPanel(
                props: PanelProps(fill: "primary", fillOpacity: 0.1, cornerRadius: 13, stroke: "primary", strokeOpacity: 0.08),
                common: AtomCommon(padding: 0, paddingX: 12, paddingY: 8)
            ) {
                AtomLabel(
                    props: LabelProps(text: "\(pendingCommentCount) comment\(pendingCommentCount == 1 ? "" : "s")", icon: PHIcon.textBubble.name, size: 13, weight: "medium", color: "primary"),
                    common: AtomCommon(testID: "pending-comment-count", opacity: 0.82)
                )
            }
            // A badge on the chip's corner, like the one that removes an attached image.
            .overlay(alignment: .topTrailing) {
                PHButton(action: discardPendingAnnotations) {
                    PHImage(icon: .xmarkCircleFill)
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .plainButtonHoverPointer()
                .nativeHelp("Discard comments")
                .accessibilityLabel("Discard comments")
                .accessibilityIdentifier("discard-pending-comments-button")
                .offset(x: 6, y: -6)
            }
        }

        if let activeGoal, activeGoal.status != "complete", !isReadOnly, provider.supportsGoals {
            activeGoalRow(activeGoal)
            if isGoalExpanded {
                AtomText(
                    props: TextProps(text: activeGoal.objective, size: 13, color: "secondary"),
                    common: AtomCommon(testID: "active-goal-details", fillWidth: true, paddingX: 14)
                )
            }
        }
            }, scheduleContent: { scheduleHint }, pluginActions: isReadOnly ? nil : PHAnyView(
                PluginSlot(placement: .composerActions, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
            ), mentions: ChatEditorMentions(
                handles: mentionHandles, edit: mentionEdit, onKey: handleComposerKey,
                onEditingChange: { isComposerEditing = $0 }
            ), keyboardShortcuts: true)
                // A zero-height strip along the composer's top edge, so the menu grows upward over the
                // transcript rather than covering the text being typed.
                .overlay(alignment: .top) {
                    PHColor.clear.frame(height: 0).overlay(alignment: .bottomLeading) {
                        mentionMenu
                        slashMenu
                    }
                }
                .onChange(of: typedMention?.location) { _, location in
                    if location != dismissedMentionLocation { dismissedMentionLocation = nil }
                }
                .onChange(of: activeMention?.location) { _, location in
                    mentionSelection = 0
                    refreshMentionSuggestions()
                    // Each new mention reads the catalog again, so it shows the latest recent mentions.
                    if location != nil { Task { await loadMentions() } }
                }
                .onChange(of: activeMention?.query) { _, _ in
                    mentionSelection = 0
                    refreshMentionSuggestions()
                }
                .onChange(of: typedSlash?.location) { _, location in
                    if location != dismissedSlashLocation { dismissedSlashLocation = nil }
                    // Each new `/` reads the commands again, so they follow the plugins and the task's agent.
                    if location != nil { Task { await loadSlashEntries() } }
                }
                .onChange(of: activeSlash?.query) { _, _ in slashSelection = 0 }
                .onChange(of: activeSlashCommand?.name) { _, name in
                    // Each opening reads the list again, so it shows the latest servers, skills and plugins.
                    if name != nil, let command = activeSlashCommand { Task { await loadSlashItems(command) } }
                }
                .onChange(of: pluginRegistry.plugins) { _, _ in
                    if slashEntries != nil { Task { await loadSlashEntries() } }
                }
                .task(id: task.id) {
                    await loadMentions()
                    await loadSlashEntries()
                }
                .onChange(of: draft) { _, newValue in scheduleDraftAutosave(newValue) }
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }
}

/// The empty conversation's add-repository prompt: a standalone + like the header's, larger,
/// that lights up on hover, with its explanation below it.
private struct EmptyConversationAddRepositoryPrompt: PHView {
    let action: () -> Void
    @PHState private var isHovering = false

    var body: some PHView {
        PHVStack(spacing: 12) {
            PHButton(action: action) {
                PHImage(icon: .plus)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PHColor.accentColor)
                    .frame(width: 44, height: 44)
                    .background(PHCircle().fill(PHColor.accentColor.opacity(isHovering ? 0.24 : 0.14)))
                    .overlay(PHCircle().strokeBorder(PHColor.accentColor.opacity(isHovering ? 0.4 : 0.22)))
                    .contentShape(PHCircle())
            }
            .buttonStyle(.plain)
            .plainButtonHoverPointer()
            .nativeHelp("Add a repository")
            .phOnHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel("Add repository")
            .accessibilityIdentifier("empty-conversation-add-repository-button")
            PHText("Add repositories to the task's context")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("empty-conversation-add-repository-caption")
        }
    }
}

/// Stands in for the transcript while a conversation's first history read is under way. It shows
/// only once the read has taken a moment, so a conversation that opens quickly doesn't flash it.
private struct ConversationHistoryLoadingIndicator: PHView {
    static let delay: Duration = .milliseconds(300)
    @PHState private var isShown = false

    var body: some PHView {
        PHZStack {
            if isShown {
                PHHStack(spacing: 8) {
                    PHProgressView()
                        .controlSize(.small)
                    PHText("Loading conversation…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading conversation…")
                .accessibilityIdentifier("conversation-history-loading")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .task {
            try? await Task.sleep(for: Self.delay)
            isShown = true
        }
    }
}
