import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll runway above the rendered window. It keeps an
                    // upward drag available even when the latest turn alone is
                    // shorter than the viewport, and it is replaced by the
                    // earlier messages as soon as they are revealed. It is as
                    // tall as those messages are estimated to be, so the
                    // scroller keeps about the same size as they appear.
                    let runwayHeight = olderConversationRunwayHeight(viewport: viewport.size)
                    if hasOlderConversationMessages {
                        Color.clear
                            .frame(height: runwayHeight)
                            .accessibilityHidden(true)
                        // Scroll position is only observable from macOS 15 on,
                        // so older systems keep an explicit control rather than
                        // an upward drag that cannot be detected.
                        if #unavailable(macOS 15) {
                            Button("Load earlier messages") {
                                revealOlderConversationMessages(using: scrollProxy)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .buttonHoverPointer()
                            .nativeHelp("Load 40 earlier messages.")
                            .accessibilityIdentifier("conversation-load-older-button")
                        }
                    }
                    // Tracks how far the top of the rendered window sits below
                    // the top of the viewport, which is how an upward scroll is
                    // detected.
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ConversationTopMarkerPositionKey.self,
                            value: geometry.frame(in: .named(Self.conversationScrollCoordinateSpace)).minY
                        )
                    }
                    .frame(height: 0)

                let leadingGoalEntries = goalAchievementTimelineEntries.filter { goalAchievementAnchorMessageID(for: $0) == nil }
                // Worked out once per pass rather than once per row: each walks the whole transcript, and
                // every row of it is rebuilt whenever the transcript's width changes, as while resizing the chat.
                let renderedMessages = renderedConversationMessages
                let rowContext = makeTranscriptRowContext(rendered: renderedMessages)
                // Everything before the newest turn is settled, so only its rows near the viewport
                // render (see `TranscriptVirtualizer`): scrolling, hit testing and layout cost what
                // is on screen rather than everything revealed so far. The newest turn, where answers
                // stream and rows grow, always renders in full in the layout below. When the newest
                // turn starts before the rendered window, as when one live turn outgrows a window
                // that was never pinned, every rendered row belongs to it and renders in full.
                let latestTurnStartIndex = rowContext.latestTurnStartID.flatMap { id in
                    renderedMessages.firstIndex { $0.id == id }
                } ?? 0
                let messageReferences = renderedMessages.indices.map { RenderedMessageReference(id: renderedMessages[$0].id, index: $0) }
                let leadingBoundaries = providerBoundaries.filter { $0.afterMessageID == nil }
                let hasSettledRows = !messages.isEmpty
                    && (latestTurnStartIndex > 0 || !leadingGoalEntries.isEmpty || !leadingBoundaries.isEmpty)
                let settledIDs = messageReferences[..<latestTurnStartIndex].map(\.id)
                let settledSignatures = settledRowSignatures(renderedMessages[..<latestTurnStartIndex], context: rowContext)
                let virtualizer = transcriptVirtualizer
                let _ = { virtualizer.order = settledIDs }()
                VStack(alignment: .leading, spacing: 16) {
                if hasSettledRows {
                    VStack(alignment: .leading, spacing: TranscriptVirtualizer.spacing) {
                        ForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                        ForEach(leadingBoundaries) { boundary in
                            providerBoundaryRow(boundary)
                        }
                        // Positions are summed from the top of the messages themselves, below the
                        // leading goal and boundary rows.
                        VStack(alignment: .leading, spacing: TranscriptVirtualizer.spacing) {
                            SettledTranscriptRows(
                                ids: settledIDs, signatures: settledSignatures, virtualizer: virtualizer,
                                pinnedIDs: Set([annotationSelection?.messageID, currentTextSelection?.messageID].compactMap { $0 })
                            ) { index in
                                // One message's rows measure as one box.
                                AnyView(VStack(alignment: .leading, spacing: TranscriptVirtualizer.spacing) {
                                    transcriptRows(for: renderedMessages[index], context: rowContext)
                                })
                            }
                        }
                        .reportGeometry({ $0.frame(in: .named(Self.transcriptContentCoordinateSpace)).minY }) { top in
                            virtualizer.sectionTop = top
                            virtualizer.invalidate()
                        }
                    }
                    .onDisappear { virtualizer.resetWidth() }
                    .reportGeometry({ $0.size.width }) { width in
                        // Rows far from the viewport keep scaled heights until they show again,
                        // so keep the reader on the message they were reading once a resize ends.
                        let anchor = virtualizer.width > 0 && !lastConversationScrollSample.isFollowingLatest ? virtualizer.topVisibleAnchor() : nil
                        guard virtualizer.updateWidth(width) else { return }
                        if virtualizer.resizeAnchor == nil { virtualizer.resizeAnchor = anchor }
                        virtualizer.resizeAnchorTask?.cancel()
                        virtualizer.resizeAnchorTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            guard !Task.isCancelled else { return }
                            defer { virtualizer.resizeAnchor = nil }
                            // A reveal restores its own anchor and a history load pins its turn,
                            // as `followConversationBottom` also defers to.
                            guard let anchor = virtualizer.resizeAnchor, !lastConversationScrollSample.isFollowingLatest,
                                  !isRevealingOlderConversationMessages, !isLatestConversationTurnPinPending,
                                  virtualizer.hasDrifted(from: anchor) else { return }
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { scrollProxy.scrollTo(anchor.id, anchor: .top) }
                        }
                    }
                }
                // The newest turn's own stack reserves the filler below it: from its question to
                // the end of the transcript it is at least a viewport tall, less the bottom padding
                // and end marker already below it, which lets a turn shorter than the viewport be
                // pinned to the top, and makes that pin exactly the bottom, which following starts
                // from. The runway above the window does the same for the other end. Sizing the
                // filler from measurements instead, which SwiftUI reports a pass later, left it
                // stale and opened blank overscroll below the transcript. A newer question moves
                // the previous turn's rows up into the settled rows, which rebuilds them once.
                ConversationTranscriptLayout(
                    spacing: 16,
                    minimumLatestTurnHeight: max(0, viewport.size.height - Self.conversationVerticalPadding - Self.conversationScrollEndHeight)
                ) {
                    if messages.isEmpty && activeGoal?.status != "complete" && !isLoadingHistory {
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
                            }
                            Spacer(minLength: 28)
                        }
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 38)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("empty-conversation")
                    } else if !messages.isEmpty {
                        ForEach(messageReferences[latestTurnStartIndex...]) { reference in
                            transcriptRows(for: renderedMessages[reference.index], context: rowContext)
                        }
                        ForEach(liveChatPageRecalls) { activity in
                            if let pageID = activity.recalledChatPageID {
                                ChatPageRecallRow(activityID: activity.id, pageID: pageID)
                            }
                        }
                        if shouldShowActivityDisclosure, activityDisclosureAnchorID == nil {
                            activityList
                        }
                    }

                    if messages.isEmpty && shouldShowActivityDisclosure {
                        activityList
                    }
                    if messages.isEmpty {
                        ForEach(providerBoundaries) { boundary in
                            providerBoundaryRow(boundary)
                        }
                    }
                    if messages.isEmpty {
                        ForEach(leadingGoalEntries) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                    }
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
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-latest-anchor")
                    // Spans the newest turn at its natural height, which only
                    // "does the newest turn fit the viewport?" is asked of.
                    Color.clear
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ConversationLatestTurnHeightKey.self,
                                    value: geometry.size.height
                                )
                            }
                        }
                        .accessibilityHidden(true)
                        .layoutValue(key: ConversationLatestTurnExtentKey.self, value: true)
                }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, Self.conversationVerticalPadding)
                // A window that holds older messages back needs the runway's
                // counterpart below even when no turn of its own is rendered.
                .frame(
                    minHeight: hasOlderConversationMessages
                        ? max(0, viewport.size.height - Self.conversationScrollEndHeight)
                        : nil,
                    alignment: .top
                )
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                // The very end of the scroll content, filler included, which is
                // where following new content keeps the viewport. Unlike
                // `scrollToLatest`, following can target it: a scroll that
                // lands short of the real end changes the scroll extent again,
                // and that change is followed once more.
                Color.clear
                    .frame(height: Self.conversationScrollEndHeight)
                    .id(Self.conversationScrollEndID)
                    .accessibilityHidden(true)
                }
                .hoverRevealScrollers()
                .background {
                    // The scroll observer reports this geometry from macOS 15
                    // on; before that the content's own frame in the scroll's
                    // space carries it.
                    if #unavailable(macOS 15) {
                        GeometryReader { geometry in
                            let frame = geometry.frame(in: .named(Self.conversationScrollCoordinateSpace)) // the scroll view's space
                            Color.clear.preference(
                                key: ConversationScrollGeometryKey.self,
                                value: ConversationScrollGeometry(
                                    offsetY: -frame.minY,
                                    contentHeight: frame.height,
                                    maxOffsetY: frame.height - viewport.size.height
                                )
                            )
                        }
                    }
                }
                .coordinateSpace(name: Self.transcriptContentCoordinateSpace)
            }
            .coordinateSpace(name: Self.conversationScrollCoordinateSpace)
            .accessibilityIdentifier("conversation-scroll-view")
            .accessibilityValue(hasLoadedConversation
                ? "Showing latest \(renderedConversationMessages.count) of \(conversationMessages.count + earlierStoredMessageCount) messages"
                : "Loading conversation history")
            .onPreferenceChange(ConversationTopMarkerPositionKey.self) { markerY in
                // Exactly one source drives the reveal: the scroll observer
                // where it exists, this marker where it does not.
                if #unavailable(macOS 15) {
                    handleConversationWindowTop(markerY, using: scrollProxy, allowsJump: true)
                }
            }
            .onPreferenceChange(ConversationScrollGeometryKey.self) { geometry in
                guard let geometry else { return }
                transcriptVirtualizer.updateViewport(offsetY: geometry.offsetY, height: viewport.size.height)
                let old = lastConversationScrollSample.geometry ?? geometry
                lastConversationScrollSample.geometry = geometry
                followConversationBottom(from: old, to: geometry, using: scrollProxy)
            }
            .modifier(ConversationScrollOffsetObserver { old, new in
                lastConversationScrollSample.viewportHeight = viewport.size.height
                transcriptVirtualizer.updateViewport(offsetY: new.offsetY, height: viewport.size.height)
                followConversationBottom(from: old, to: new, using: scrollProxy)
                guard lastConversationScrollSample.offsetY != new.offsetY else { return }
                lastConversationScrollSample.offsetY = new.offsetY
                handleConversationWindowTop(
                    conversationWindowTopY(offsetY: new.offsetY, viewportHeight: viewport.size.height),
                    using: scrollProxy,
                    allowsJump: true
                )
            })
            .onPreferenceChange(ConversationLatestTurnHeightKey.self) { height in
                // Only "shorter than the viewport?" is ever asked of this value,
                // and publishing each revision re-renders the whole transcript,
                // so cap it once the turn overflows.
                let clamped = min(height, viewport.size.height + 1)
                if clamped != latestTurnContentHeight { latestTurnContentHeight = clamped }
            }
            .onChange(of: isLoadingHistory) { _, isLoading in
                // Every completed history load reopens on the newest turn,
                // including reloads that leave the messages unchanged.
                guard !isLoading else { return }
                presentLatestConversationTurn(using: scrollProxy)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToLatestUserMessage(using: scrollProxy, viewportHeight: viewport.size.height)
            }
            // These compare the transcript only before it is first presented, the only time
            // their handlers act; a nil on either side is the comparison starting or stopping,
            // not a change of the transcript.
            .onChange(of: hasPresentedLatestConversation ? nil : messages.map(\.text)) { previous, current in
                if previous != nil, current != nil, !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: hasPresentedLatestConversation ? nil : activities) { previous, current in
                if previous != nil, current != nil, isResponding && !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: isResponding) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: activeGoal?.status) { _, status in
                if status == "complete" && !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: goalAchievementTimelineEntries.count) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: userInputRequest?.id) { _, requestID in
                // The question form sits below the latest message; bring it into view
                // whether it arrives with the history or later from the daemon.
                guard requestID != nil else { return }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.easeOut(duration: 0.2)) {
                        scrollProxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                    }
                    // The form's rows are placed from estimates until realized, so the first
                    // scroll can stop short of Submit; scroll again once they are.
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    for delay in Self.scrollSettleDelays {
                        try? await Task.sleep(nanoseconds: delay)
                        withTransaction(transaction) { scrollProxy.scrollTo("conversation-latest-anchor", anchor: .bottom) }
                    }
                }
            }
            }
        }
    }

    static let conversationScrollCoordinateSpace = "conversation-transcript-scroll"
    /// The scroll content's own space, in which positions stay put while the transcript scrolls.
    static let transcriptContentCoordinateSpace = "conversation-transcript-content"
    static let conversationScrollEndID = "conversation-scroll-end"
    static let conversationScrollEndHeight: CGFloat = 1
    static let conversationVerticalPadding: CGFloat = 24

    var emptyConversationRepositoryTitle: String {
        var repositoryNames = task.repositoryWorktrees.map {
            URL(fileURLWithPath: $0.repositoryPath).lastPathComponent
        }
        if repositoryNames.isEmpty {
            repositoryNames = task.workspaceRootPaths.compactMap { path in
                let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
                let gitMarker = repositoryURL.appendingPathComponent(".git")
                guard FileManager.default.fileExists(atPath: gitMarker.path) else { return nil }
                return repositoryURL.lastPathComponent
            }
        }
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

    var activityList: some View {
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
                    let activeIDsOutside = Set(activeSubagents.map(\.id) + [activeProcess?.id].compactMap { $0 })
                        .union(inlineToolCalls.ids)
                    ForEach(activities.filter {
                        !$0.isSubagent && !$0.isContextCompaction && !activeIDsOutside.contains($0.id)
                            && !(task.isStandaloneChat && $0.recalledChatPageID != nil)
                    }) { activity in
                        activityRow(activity)
                    }
                    let agentActivities = activities.filter(\.isSubagent)
                    let completedAgentActivities = agentActivities.filter { !$0.isActive }
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
                handles: mentionHandles, edit: mentionEdit, onKey: handleMentionKey,
                onEditingChange: { isComposerEditing = $0 }
            ))
                // A zero-height strip along the composer's top edge, so the menu grows upward over the
                // transcript rather than covering the text being typed.
                .overlay(alignment: .top) {
                    Color.clear.frame(height: 0).overlay(alignment: .bottomLeading) { mentionMenu }
                }
                .onChange(of: typedMention?.location) { _, location in
                    if location != dismissedMentionLocation { dismissedMentionLocation = nil }
                }
                .onChange(of: activeMention?.location) { _, location in
                    mentionSelection = 0
                    // Each new mention reads the catalog again, so it shows the latest recent mentions.
                    if location != nil { Task { await loadMentions() } }
                }
                .onChange(of: activeMention?.query) { _, _ in mentionSelection = 0 }
                .task(id: task.id) { await loadMentions() }
                .onChange(of: draft) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/plan" {
                        activatePlanMode()
                    } else if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/goal", provider.supportsGoals {
                        isEnteringGoal = true
                        draft = ""
                    }
                    scheduleDraftAutosave(newValue)
                }
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
