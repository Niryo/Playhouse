import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    var conversation: some View {
        GeometryReader { viewport in
            let scroll = transcriptScroll
            let showsPageAnchors = showsChatPageAnchors(transcriptWidth: viewport.size.width)
            let isBrowsingEarlier = isBrowsingEarlierMessages
            ScrollView {
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
                        ForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                        ForEach(providerBoundaries.filter { $0.afterMessageID == nil }) { boundary in
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
                                AnyView(transcriptLeadingRows(for: renderedMessages[index], context: rowContext))
                            },
                            row: { index in
                                // One message's rows measure as one box.
                                AnyView(VStack(alignment: .leading, spacing: Self.transcriptRowSpacing) {
                                    transcriptRows(for: renderedMessages[index], context: rowContext)
                                })
                            }
                        )
                        // What belongs to the newest turn waits below an earlier chat page
                        // the reader jumped to.
                        if !isBrowsingEarlier {
                            ForEach(liveChatPageRecalls) { activity in
                                if let pageID = activity.recalledChatPageID {
                                    ChatPageRecallRow(activityID: activity.id, pageID: pageID)
                                }
                            }
                            if shouldShowActivityDisclosure, activityDisclosureAnchorID == nil {
                                activityList
                            }
                        }
                    } else {
                        if activeGoal?.status != "complete" && !isLoadingHistory {
                            emptyConversationPlaceholder
                        }
                        if shouldShowActivityDisclosure {
                            activityList
                        }
                        ForEach(providerBoundaries) { boundary in
                            providerBoundaryRow(boundary)
                        }
                        ForEach(leadingGoalEntries) { entry in
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
                        ForEach(activeSubagents) { activity in
                            subagentTimelineRow(activity)
                        }
                        ForEach(activities.filter { $0.isContextCompaction && $0.timelineOrder == nil }) { activity in
                            contextCompactionTimelineRow(activity)
                        }
                    }
                }
                // The open page labels widen the chat sidebar and push the rows right by as much,
                // so the rows keep their width and their text stays as it was.
                .padding(.leading, chatPageAnchorsPush)
                .padding(.horizontal, ChatPageAnchorsLayout.transcriptPadding)
                .padding(.vertical, Self.conversationVerticalPadding)
                .frame(maxWidth: ChatPageAnchorsLayout.transcriptMaxWidth + chatPageAnchorsPush)
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
    var emptyConversationPlaceholder: some View {
        VStack(spacing: 0) {
            if task.isStandaloneChat || task.authoringPluginID != nil {
                // A chat has no repository to name, so the placeholder keeps only
                // its prompt. The leading spacer balances the trailing one that
                // the title would otherwise have pushed against.
                Spacer(minLength: 0)
            } else {
                Text(emptyConversationRepositoryTitle)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(emptyConversationRepositoryTitleColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .accessibilityLabel(emptyConversationRepositoryTitle)
                    .accessibilityIdentifier("empty-conversation-repository-title")
                Spacer(minLength: 58)
            }
            if showsEmptyConversationAddRepositoryPrompt {
                emptyConversationAddRepositoryPrompt
            } else {
                emptyConversationModelPrompt
            }
            Spacer(minLength: 28)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(.horizontal, 30)
        .padding(.vertical, 38)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-conversation")
    }

    /// A repository task with nothing selected teaches the picker: the empty state's + opens the
    /// same Add repository hint as the header's + button.
    var showsEmptyConversationAddRepositoryPrompt: Bool {
        !isReadOnly && !task.isStandaloneChat && task.authoringPluginID == nil
            && emptyConversationRepositoryNames.isEmpty
    }

    var emptyConversationAddRepositoryPrompt: some View {
        EmptyConversationAddRepositoryPrompt(action: showRepositoryPicker)
    }

    var emptyConversationModelPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 29, weight: .regular))
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .accessibilityLabel("Conversation")
            Text(task.authoringPluginID != nil ? "Describe your plugin in the prompt below." : "Send a message to \(provider.assistantLabel(modelName: promptModelName)).")
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
    var emptyConversationPluginDetailRows: [(id: String, label: String, value: String)] {
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

    var emptyConversationPluginDetails: some View {
        VStack(spacing: 12) {
            if !emptyConversationPluginDetailRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(emptyConversationPluginDetailRows, id: \.id) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            Text(row.value)
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
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Text("Want to change any of these, even the name? Just ask in your prompt.")
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
    static let transcriptRowSpacing: CGFloat = 16
    static let conversationVerticalPadding: CGFloat = 24
    /// Space kept above the newest question when it is pinned to the top of the viewport.
    static let latestTurnTopMargin: CGFloat = 12

    /// The selected repositories' names, or the Git roots' names for a task without worktrees.
    var emptyConversationRepositoryNames: [String] {
        let repositoryNames = task.repositoryWorktrees.map {
            URL(fileURLWithPath: $0.repositoryPath).lastPathComponent
        }
        guard repositoryNames.isEmpty else { return repositoryNames }
        return task.workspaceRootPaths.compactMap { path in
            let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
            let gitMarker = repositoryURL.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitMarker.path) else { return nil }
            return repositoryURL.lastPathComponent
        }
    }

    var emptyConversationRepositoryTitle: String {
        let repositoryNames = emptyConversationRepositoryNames
        return repositoryNames.isEmpty ? "No repository selected" : repositoryNames.joined(separator: " · ")
    }

    var emptyConversationRepositoryTitleColor: Color {
        colorScheme == .dark
            ? .orange
            : Color(red: 0.18, green: 0.31, blue: 0.68)
    }

    var activeSubagents: [ConversationActivity] {
        activities.filter { $0.isSubagent && $0.isActive }
    }

    /// Earlier turns' tool calls, keyed by the message each followed. The latest turn shows its
    /// calls in Working for instead, and folds them into Worked for once it finishes.
    var inlineToolCalls: (byMessageID: [String: [ConversationActivity]], ids: Set<String>) {
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
    var liveChatPageRecalls: [ConversationActivity] {
        guard task.isStandaloneChat else { return [] }
        let inlineIDs = inlineToolCalls.ids
        return activities.filter { $0.recalledChatPageID != nil && !inlineIDs.contains($0.id) }
    }

    /// Keep the latest live non-agent operation in the conversation timeline.
    /// Earlier live operations remain available in the expanded activity list.
    var activeProcess: ConversationActivity? {
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

    @ViewBuilder
    var activityList: some View {
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

    func activityDisclosure(expandedActivities: [ConversationActivity], completedAgentActivities: [ConversationActivity]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isActivityExpanded.toggle()
                }
            } label: {
                activityDisclosureButtonLabel
            }
            .buttonHoverPointer()
            .nativeHelp("Show or hide Codex activity details")
            .buttonStyle(.plain)
            .accessibilityValue(isActivityExpanded ? "Expanded, down chevron" : "Collapsed, right chevron")
            .accessibilityHint("Shows Codex progress messages and completed activity details.")
            .accessibilityIdentifier("codex-activity-disclosure")


            Divider()
                .opacity(0.32)
                .accessibilityElement()
                .accessibilityLabel("Separator between work duration and response")

            if isActivityExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if !progressMessages.isEmpty {
                        Text("Progress")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(progressMessages) { message in
                            assistantMarkdownContent(Self.displayableAssistantText(message.text))
                                .font(.system(size: 12))
                                .foregroundStyle(WorkspaceTheme.conversationText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("codex-progress-message-\(message.id)")
                        }
                    }
                    ForEach(expandedActivities) { activity in
                        activityRow(activity)
                    }
                    if !completedAgentActivities.isEmpty {
                        Text("Agents used")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(completedAgentActivities) { activity in
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
    var thinkingRow: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking…")
        .accessibilityIdentifier("codex-activity-thinking")
    }

    /// Composed only of plugin atoms (Plugins/Atoms).

    /// The notices above the composer, composed only of plugin atoms (Plugins/Atoms).
    @ViewBuilder
    var composerNotices: some View {
        if let actionNotice {
            AtomLabel(props: LabelProps(text: actionNotice, icon: "hand.raised.fill", size: 11, weight: "medium", color: "orange"), common: AtomCommon(testID: "codex-action-notice"))
        }
        if let providerNotice {
            AtomLabel(props: LabelProps(text: providerNotice, icon: "arrow.triangle.swap", size: 11, weight: "medium", color: "secondary"), common: AtomCommon(testID: "provider-capabilities-notice"))
                .fixedSize(horizontal: false, vertical: true)
        }
        if !isRepositoryRootConfigured {
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                AtomLabel(
                    props: LabelProps(text: "Set the repository root folder before sending.", icon: "folder.badge.questionmark", size: 11, weight: "medium", color: "orange"),
                    common: AtomCommon(testID: "repository-root-required-notice")
                )
                AtomSpacer(props: SpacerProps(minLength: 0))
                AtomButton(
                    props: ButtonProps(style: "bordered"),
                    common: AtomCommon(testID: "set-conversation-repository-root-button", help: "Choose the folder that contains your repositories."),
                    action: { chooseRepositoryParentFolder(showRepositoryPickerWhenFinished: false) }
                ) {
                    AtomText(props: TextProps(text: "Set root folder…"))
                }
            }
        }
        if let errorMessage {
            AtomLabel(props: LabelProps(text: errorMessage, icon: "exclamationmark.triangle.fill", size: 11, weight: "medium", color: "red"))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilitySummary(errorMessage, id: "codex-chat-error")
        }
    }

    /// Follow-ups waiting for the active turn, composed only of plugin atoms (Plugins/Atoms).
    var queuedFollowUpList: some View {
        AtomPanel(
            props: PanelProps(spacing: 0, fill: "primary", fillOpacity: 0.08, cornerRadius: 18, stroke: "primary", strokeOpacity: 0.08),
            common: AtomCommon(testID: "queued-follow-ups", padding: 0)
        ) {
            ForEach(waitingFollowUps) { queued in
                queuedFollowUpRow(queued)
            }
        }
    }

    func queuedFollowUpRow(_ queued: QueuedConversationMessage) -> some View {
        let id = queued.id.uuidString
        return AtomStack(props: StackProps(axis: "h", spacing: 12, group: true), common: AtomCommon(testID: "queued-message-\(id)", paddingX: 14, paddingY: 11)) {
            AtomIcon(props: IconProps(name: "text.line.first.and.arrowtriangle.forward", size: 14, weight: "medium", color: "secondary"))
            AtomText(props: TextProps(text: queued.text, size: 14, lineLimit: 1), common: AtomCommon(testID: "queued-message-text-\(id)", fillWidth: true))
            if let imageCount = queued.imageDataURLs?.count, imageCount > 0 {
                let description = imageCount == 1 ? "1 attached image" : "\(imageCount) attached images"
                AtomLabel(props: LabelProps(text: "\(imageCount)", icon: "photo", size: 12, color: "secondary"), common: AtomCommon(help: description))
                    .accessibilitySummary(description, id: "queued-message-images-\(id)")
            }
            if queued.state == .needsAction {
                AtomText(props: TextProps(text: "Needs action", size: 12, color: "secondary"), common: AtomCommon(testID: "queued-message-needs-action-\(id)", label: "Follow-up needs your action"))
                AtomButton(
                    props: ButtonProps(style: "automatic"),
                    common: AtomCommon(testID: "retry-queued-message-\(id)", label: "Retry follow-up", help: "Retry this follow-up"),
                    action: { retryQueuedMessage(queued) }
                ) {
                    AtomIcon(props: IconProps(name: "arrow.clockwise", size: 13, weight: "medium"))
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
                AtomIcon(props: IconProps(name: "trash", size: 13, weight: "medium"))
            }
            AtomMenu(
                props: MenuProps(icon: "ellipsis", size: 13, weight: "semibold", color: "primary", indicator: true, items: [[
                    MenuProps.Item(id: "copy", title: "Copy text", help: "Copy this follow-up"),
                    MenuProps.Item(id: "remove", title: "Remove follow-up", destructive: true, help: "Remove this follow-up"),
                ]]),
                common: AtomCommon(testID: "queued-message-more-\(id)", label: "More follow-up actions", help: "More follow-up actions", width: 24, height: 24),
                onMenu: { choice in
                    if choice == "copy" {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(queued.text, forType: .string)
                    } else {
                        removeQueuedMessage(queued)
                    }
                }
            )
        }
    }

    /// The active goal above the composer box, composed only of plugin atoms
    /// (Plugins/Atoms); a native timeline ticks its elapsed time.
    func activeGoalRow(_ activeGoal: CodexThreadGoal) -> some View {
        let isPaused = activeGoal.status == "paused"
        let progress = conversationRuntime.snapshot.goal.turnStartedThreadID == task.codexThreadID
            ? "Work started" : (conversationRuntime.isTurnActive(threadID: task.codexThreadID ?? "") ? "Working" : "Waiting")
        return AtomPanel(
            props: PanelProps(fill: "primary", fillOpacity: 0.10, cornerRadius: 18, stroke: "primary", strokeOpacity: 0.08),
            common: AtomCommon(testID: "active-goal-progress-row", value: progress, padding: 0, paddingX: 14, paddingY: 10)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 10)) {
                AtomIcon(props: IconProps(name: "scope", size: 17, weight: "medium", color: "secondary"))
                AtomText(props: TextProps(text: "\(isPaused ? "Paused goal" : "Pursuing goal") \(activeGoal.objective)", size: 15, lineLimit: 1), common: AtomCommon(testID: "active-goal-title"))
                AtomSpacer(props: SpacerProps(minLength: 4))
                if let seconds = activeGoal.timeUsedSeconds {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        AtomText(
                            props: TextProps(text: Self.goalDuration(goalElapsedTime(for: activeGoal, reportedSeconds: seconds)
                                + (activeGoal.status == "active" ? context.date.timeIntervalSince(goalStatusUpdatedAt) : 0)), color: "secondary"),
                            common: AtomCommon(testID: "goal-elapsed-time")
                        )
                    }
                }
                AtomButton(props: ButtonProps(destructive: true), common: AtomCommon(testID: "goal-clear-button", label: "Clear goal", help: "Clear goal"), action: { Task { await mutateGoal("clear") } }) {
                    AtomIcon(props: IconProps(name: "trash"))
                }
                AtomButton(
                    common: AtomCommon(testID: "goal-pause-resume-button", label: isPaused ? "Resume goal" : "Pause goal", help: isPaused ? "Resume goal" : "Pause goal"),
                    action: { Task { await mutateGoal(isPaused ? "resume" : "pause") } }
                ) {
                    AtomIcon(props: IconProps(name: isPaused ? "play.fill" : "pause"))
                }
                AtomButton(
                    common: AtomCommon(
                        testID: "goal-expand-button", label: isGoalExpanded ? "Collapse goal" : "Expand goal", value: isGoalExpanded ? "Expanded" : "Collapsed",
                        help: isGoalExpanded ? "Collapse goal" : "Expand goal", width: 30, height: 30
                    ),
                    action: { isGoalExpanded.toggle() }
                ) {
                    AtomIcon(props: IconProps(name: isGoalExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"))
                }
            }
        }
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Button { selectedChatImage = attachment.image } label: {
                                    Image(nsImage: attachment.image).resizable().scaledToFill()
                                        .frame(width: 64, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open attached image")
                                .accessibilityIdentifier("pending-chat-image-\(attachment.id)")
                                .buttonHoverPointer()
                                .nativeHelp("Open image at full size")

                                Button {
                                    pendingImages.removeAll { $0.id == attachment.id }
                                    persistDraft()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonHoverPointer()
                                .nativeHelp("Remove image")
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove image")
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

            ComposerView(model: composerModel, actions: composerActions, header: {
        recalledChatPageChips
        let pendingCommentCount = annotations.filter(\.pending).count
        if pendingCommentCount > 0 {
            AtomPanel(
                props: PanelProps(fill: "primary", fillOpacity: 0.1, cornerRadius: 13, stroke: "primary", strokeOpacity: 0.08),
                common: AtomCommon(padding: 0, paddingX: 12, paddingY: 8)
            ) {
                AtomLabel(
                    props: LabelProps(text: "\(pendingCommentCount) comment\(pendingCommentCount == 1 ? "" : "s")", icon: "text.bubble", size: 13, weight: "medium", color: "primary"),
                    common: AtomCommon(testID: "pending-comment-count", opacity: 0.82)
                )
            }
            // A badge on the chip's corner, like the one that removes an attached image.
            .overlay(alignment: .topTrailing) {
                Button(action: discardPendingAnnotations) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .black.opacity(0.7))
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
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
            }, scheduleContent: { scheduleHint }, pluginActions: isReadOnly ? nil : AnyView(
                PluginSlot(placement: .composerActions, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
            ), mentions: ChatEditorMentions(
                handles: mentionHandles, edit: mentionEdit, onKey: handleComposerKey,
                onEditingChange: { isComposerEditing = $0 }
            ))
                // A zero-height strip along the composer's top edge, so the menu grows upward over the
                // transcript rather than covering the text being typed.
                .overlay(alignment: .top) {
                    Color.clear.frame(height: 0).overlay(alignment: .bottomLeading) {
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
private struct EmptyConversationAddRepositoryPrompt: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor.opacity(isHovering ? 0.24 : 0.14)))
                    .overlay(Circle().strokeBorder(Color.accentColor.opacity(isHovering ? 0.4 : 0.22)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .nativeHelp("Add a repository")
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel("Add repository")
            .accessibilityIdentifier("empty-conversation-add-repository-button")
            Text("Add repositories to the task's context")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("empty-conversation-add-repository-caption")
        }
    }
}
