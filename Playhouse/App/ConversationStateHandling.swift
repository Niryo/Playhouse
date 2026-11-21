import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    /// The newest page of history, as `loadConversation` reads it.
    func readLatestHistoryPage() async throws -> ConversationHistory {
        try await conversationManager.history(
            taskID: task.id,
            messageLimit: Self.historyPageSize,
            onActionRequest: { actionNotice = approvalNotice }
        )
    }

    /// Opening a task: the newest page of history and the task as the daemon reconciled
    /// its status for the read, in one request.
    func readHistoryOnOpen() async throws -> (history: ConversationHistory, reconciled: BoardTaskRecord?) {
        try await conversationManager.historyOnOpen(
            taskID: task.id,
            messageLimit: Self.historyPageSize,
            onActionRequest: { actionNotice = approvalNotice }
        )
    }

    /// Applies the newest page of history, read here or by a `pendingRead` already in flight.
    /// The record a `pendingRead` returns, just reconciled by the daemon, decides the draft
    /// and pending prompt in place of the task model, which picks up that write asynchronously.
    func loadConversation(
        pendingRead: Task<(history: ConversationHistory, reconciled: BoardTaskRecord?), Error>? = nil
    ) async {
        isLoadingHistory = true
        oldestRenderedMessageID = nil
        renderedWindowEndID = nil
        chatPageJumpCount += 1
        errorMessage = nil
        let draftAtLoadStart = draft
        // A turn this window didn't send streams once the loaded history is in place.
        defer { watchRunningTurnIfNeeded() }
        defer {
            isLoadingHistory = false
            hasLoadedConversation = true
        }

        // Read alongside the history rather than after it: awaiting it once the messages are
        // in place let a frame render them before the finished turn's progress collapsed,
        // which drew every progress message of a long turn on the first open.
        let goalRead = Task { @MainActor in try? await conversationManager.goal(taskID: task.id) }
        defer { goalRead.cancel() }

        do {
            // Standalone chat rotates one session per page, so the transcript asks for the
            // earlier pages to be restored from the local archive alongside the live session.
            // Only the newest page is read; older pages load as the reader scrolls up.
            let (history, reconciled) = if let pendingRead {
                try await pendingRead.value
            } else {
                (try await readLatestHistoryPage(), BoardTaskRecord?.none)
            }
            // From here until the window is resolved nothing awaits, so no frame renders the
            // messages before the rows the transcript shows of them are settled.
            // Buffered text arrived before this history, so it applies first, as it would have unbuffered.
            flushStreamedTextDeltas()
            messages = history.messages
            earlierStoredMessageCount = history.earlierMessageCount ?? 0
            historyGap = nil
            let savedUserInputRequest = history.pendingUserInputRequest?.threadID == task.activeConversationID
                ? history.pendingUserInputRequest
                : nil
            let currentProviderRequest = providerPendingUserInputRequest
            let liveUserInputRequest = currentProviderRequest?.threadID == task.activeConversationID
                && !answeredUserInputRequestIDs.contains(currentProviderRequest?.id ?? "")
                ? currentProviderRequest
                : nil
            // A history read can finish after the provider has raised a question
            // but before that request has been persisted. Keep the live request
            // visible instead of letting that older snapshot clear it.
            userInputRequest = savedUserInputRequest ?? liveUserInputRequest
            restoreAnnotations(from: history.messages)
            loadSideChats()
            answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
            activities = history.activities
            timelineActivities = []
            mergeTimelineActivities(history.timelineActivities)
            providerBoundaries = history.providerBoundaries
            let defaults = WorkspaceSettings.preferencesStore
            if let data = defaults.data(forKey: goalAchievementTimelineDefaultsKey),
               let entries = try? JSONDecoder().decode([GoalAchievementTimelineEntry].self, from: data) {
                goalAchievementTimelineEntries = entries
            }
            currentGoalGenerationID = defaults.string(forKey: goalGenerationDefaultsKey)
            currentGoalObjective = defaults.string(forKey: goalGenerationObjectiveDefaultsKey)
            currentGoalTimeBaselineSeconds = defaults.object(forKey: goalGenerationTimeBaselineDefaultsKey) as? Double
            // A pending submitted prompt is shown as a bubble unless its text is already in the
            // loaded transcript. Only the flag decides draft restoration: `savedPrompt` otherwise
            // holds the last sent prompt, which can sit beyond the loaded page.
            let pendingSubmittedPrompt = reconciled.map(\.pendingSubmittedPrompt) ?? task.pendingSubmittedPrompt
            let hasUnsentDraft = reconciled?.hasUnsentDraft ?? task.hasUnsentDraft
            let status = reconciled.flatMap { TaskStatus(rawValue: $0.status) } ?? task.status
            let hasPendingSubmittedPrompt = pendingSubmittedPrompt != nil
            if let submittedPrompt = pendingSubmittedPrompt,
               !submittedPrompt.isEmpty,
               !history.messages.contains(where: { $0.role == .user && MentionText.sameUserText($0.text, submittedPrompt) }),
               // The saved prompt stands in for a recovery prompt the transcript keeps as sent.
               !(submittedPrompt == PrivatePromptPlaceholder.recoveryAnswer
                   && history.messages.contains(where: { $0.role == .user && PrivatePromptPlaceholder.isRecoveryAnswer($0.text) })) {
                messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: submittedPrompt))
            }
            // A marked draft is unsent by definition: steering, queueing, and sending clear it.
            let savedDraft = hasUnsentDraft ? (reconciled.map(\.savedPrompt) ?? task.savedPrompt) ?? "" : ""
            let restoresDraftImages = hasUnsentDraft
            // Unsent composer text is never replaced by a saved draft, which can only be older.
            // A composer the user just cleared is unsaved, and stays cleared.
            if draft == draftAtLoadStart, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isDraftUnsaved {
                composerDraft.settledText = savedDraft
                draft = savedDraft
            } else if isDraftUnsaved {
                // Autosave skips a reload, so save text that was still waiting for it.
                persistDraft()
            }
            if restoresDraftImages && pendingImages.isEmpty {
                pendingImages = (reconciled?.draftImageDataURLs ?? task.draftImageDataURLs).compactMap { dataURL in
                    guard let comma = dataURL.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                          let image = NSImage(data: data) else { return nil }
                    return PendingImage(dataURL: dataURL, image: image)
                }
            }
            isResponding = (hasPendingSubmittedPrompt
                && (status == .inProgress || status == .waitingResponse)) || providerTurnIsActive
            if let threadID = task.activeConversationID {
                isResponding = isResponding || conversationRuntime.isTurnActive(threadID: threadID)
                // A turn paused while this view was closed can still be continued.
                if !isResponding, status == .waitingResponse, conversationRuntime.wasLastTurnInterrupted(threadID: threadID) {
                    hasPausedResponse = true
                }
            }
            if isResponding {
                responseStartedAt = defaults.object(forKey: responseStartedAtDefaultsKey) as? Date ?? Date()
                defaults.set(responseStartedAt, forKey: responseStartedAtDefaultsKey)
                completedResponseDuration = nil
            } else if let duration = defaults.object(forKey: completedResponseDurationDefaultsKey) as? Int {
                completedResponseDuration = duration
                responseStartedAt = nil
            } else if history.messages.contains(where: { $0.role == .assistant && $0.phase == "final_answer" }),
                      let startedAt = defaults.object(forKey: responseStartedAtDefaultsKey) as? Date {
                let duration = Self.elapsedSeconds(since: startedAt, now: Date())
                completedResponseDuration = duration
                defaults.set(duration, forKey: completedResponseDurationDefaultsKey)
                defaults.removeObject(forKey: responseStartedAtDefaultsKey)
                responseStartedAt = nil
            } else {
                responseStartedAt = nil
                defaults.removeObject(forKey: responseStartedAtDefaultsKey)
            }
            let activeTurnID = history.messages.last(where: { $0.turnID != nil })?.turnID
            collapsedProgressTurnIDs = Set(history.messages.lazy
                .filter {
                    $0.role == .assistant
                        && $0.phase == "final_answer"
                        && (!isResponding || $0.turnID != activeTurnID)
                }
                .compactMap(\.turnID))
            // Open on the newest turn. Progress-message collapsing above changes
            // which rows the transcript renders, so resolve the window start here.
            oldestRenderedMessageID = openingWindowStartID
            activeGoal = await goalRead.value
            if let activeGoal {
                reconcileGoalGeneration(with: activeGoal)
                if activeGoal.status == "complete",
                   let generationID = currentGoalGenerationID,
                   !goalAchievementTimelineEntries.contains(where: { $0.id == generationID }) {
                    let anchorID = fallbackGoalCompletionAnchorID(in: history.messages, objective: activeGoal.objective)
                    goalAchievementTimelineEntries.append(GoalAchievementTimelineEntry(
                        id: generationID,
                        summary: goalAchievementSummary(activeGoal),
                        afterMessageID: anchorID
                    ))
                    persistGoalAchievementTimeline()
                }
            }
            goalStatusUpdatedAt = .now
        } catch {
            errorMessage = error.localizedDescription
            // History failed, but an unanswered question stays answerable.
            let saved = try? conversationManager.savedUserInputRequest(taskID: task.id)
            if userInputRequest == nil, let request = saved ?? providerPendingUserInputRequest,
               request.threadID == task.activeConversationID, !answeredUserInputRequestIDs.contains(request.id) {
                showUserInputRequest(request)
            }
        }
    }

    func loadSideChats() {
        SideChatStore.shared.load(taskID: task.id, using: conversationManager)
    }

    func restoreAnnotations(from messages: [ConversationMessage], keepingPending: Bool = false) {
        var restored: [ConversationAnnotation] = []
        for message in messages where message.role == .user {
            guard let start = message.text.range(of: "<response-comments>")
                    ?? message.text.range(of: "<response-annotations>"),
                  let end = message.text.range(of: "</response-comments>", range: start.upperBound..<message.text.endIndex)
                    ?? message.text.range(of: "</response-annotations>", range: start.upperBound..<message.text.endIndex),
                  let data = String(message.text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for item in items {
                guard let selectedText = item["text"] as? String,
                      let comment = item["comment"] as? String ?? item["annotation"] as? String,
                      let source = item["source"] as? [String: Any],
                      let sourceID = source["messageId"] as? String,
                      let blockID = source["blockID"] as? Int,
                      let startOffset = source["startOffset"] as? Int,
                      let endOffset = source["endOffset"] as? Int else { continue }
                restored.append(ConversationAnnotation(
                    id: UUID(), messageID: sourceID, blockID: blockID,
                    startOffset: startOffset, endBlockID: source["endBlockID"] as? Int ?? blockID, endOffset: endOffset,
                    text: selectedText, comment: comment, pending: false
                ))
            }
        }
        // Sent comments are never in the saved list, but one whose clear was interrupted could be.
        let persisted = inFlightAnnotationIDs.isEmpty ? PersistedAnnotations.decode(task.pendingAnnotationsData) : []
        annotations = PersistedAnnotations.restored(
            sent: restored,
            livePending: keepingPending ? annotations.filter(\.pending) : [],
            persisted: persisted
        )
        // Dropping such a comment, or keeping live ones, changes what is pending; save that once.
        if !isReadOnly, inFlightAnnotationIDs.isEmpty,
           Set(annotations.filter(\.pending).map(\.id)) != Set(persisted.map(\.id)) {
            persistPendingAnnotations()
        }
    }

    /// Shows the cached provider model list and remembered selection without a
    /// bridge round trip, so the picker never has to fall back to the literal
    /// "Default" placeholder just because the live fetch hasn't returned yet.
    /// Reads for the provider the window shows, which a switch changes before it is saved.
    func primeModelOptionsFromCache() {
        selectedModelID = (try? conversationManager.modelID(taskID: task.id, provider: provider)) ?? ""
        selectedEffort = (try? conversationManager.effort(taskID: task.id)) ?? .medium
        if let cachedModels = try? conversationManager.cachedModels(taskID: task.id, provider: provider), !cachedModels.isEmpty {
            modelOptions = cachedModels.newestVersionPerFamily()
        }
    }

    func loadModels() async {
        primeModelOptionsFromCache()
        // The daemon lists the saved provider's models; a switch still saving loads them once saved.
        guard !isSwitchingProvider else { return }
        let refreshedProvider = provider
        let selectionAtRefreshStart = selectedModelID
        do {
            let models = try await conversationManager.models(taskID: task.id)
            // A switch while the list loaded shows the other provider's models instead.
            guard provider == refreshedProvider else { return }
            modelOptions = models
            if selectedModelID == selectionAtRefreshStart {
                selectedModelID = (try? conversationManager.modelID(taskID: task.id, provider: provider)) ?? selectedModelID
            }
            if !currentEffortChoices.contains(selectedEffort) {
                selectedEffort = currentEffortChoices.contains(.medium) ? .medium : currentEffortChoices[0]
                // Persist the clamp so the CLI and sends read the same effort the composer shows.
                _ = try? await conversationManager.setEffort(taskID: task.id, effort: selectedEffort)
            }
        } catch {
            // Keep the last known model available when an offline or unauthenticated app-server cannot list models.
        }
    }

    /// The prompt names only models the provider lists; Claude's "Default" is a
    /// placeholder, not a model, and an unlisted ID isn't a name.
    var promptModelName: String? {
        if !selectedModelID.isEmpty, !modelOptions.contains(where: { $0.id == selectedModelID }) { return nil }
        let name = selectedModelName
        return provider == .claude && name == provider.defaultModelName ? nil : name
    }

    var selectedModelName: String {
        guard !selectedModelID.isEmpty else {
            return modelOptions.first(where: \.isDefault)?.name ?? provider.defaultModelName
        }
        return modelName(for: selectedModelID)
    }

    /// The label shown above an assistant message is based on the model ID
    /// recorded for that turn, so later picker changes do not relabel history.
    func assistantLabel(for message: ConversationMessage) -> String {
        let messageProvider = message.provider ?? provider
        let modelID = message.modelID
        let cachedModels = messageProvider == provider
            ? modelOptions
            : ((try? conversationManager.cachedModels(taskID: task.id, provider: messageProvider)) ?? [])
        let modelName = modelID.flatMap { id in cachedModels.first(where: { $0.id == id })?.name }
        return messageProvider.assistantLabel(modelName: modelName)
    }

    var pickerEffortChoices: [ConversationEffort] {
        effortChoices(for: pickerModelID)
    }

    var currentEffortChoices: [ConversationEffort] {
        effortChoices(for: selectedModelID)
    }

    func effortChoices(for modelID: String) -> [ConversationEffort] {
        modelOptions.effortChoices(for: modelID)
    }

    func modelName(for modelID: String) -> String {
        modelOptions.first(where: { $0.id == modelID })?.name ?? modelID
    }

    func selectPickerModel(_ model: ConversationModelOption) {
        pickerModelID = model.id
        pickerEffort = modelOptions.effort(pickerEffort, keptFor: model.id)
    }

    func commitModelPickerSelection() {
        let effortChanged = selectedEffort != pickerEffort
        selectedModelID = pickerModelID
        selectedEffort = pickerEffort
        // The choice is the shown provider's, even while a switch to it is being saved.
        let modelProvider = provider
        Task { @MainActor in
            do {
                try await conversationManager.setModelID(taskID: task.id, modelID: pickerModelID, provider: modelProvider)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        guard effortChanged else { return }
        Task { try? await conversationManager.setEffort(taskID: task.id, effort: pickerEffort) }
    }
    func mutateGoal(_ action: String, objective: String? = nil, observeRuntime: Bool = false) async -> Bool {
        do {
            activeGoal = try await conversationManager.goal(taskID: task.id, objective: objective, action: action, observeRuntime: observeRuntime)
            if action == "set", let activeGoal { reconcileGoalGeneration(with: activeGoal) }
            goalStatusUpdatedAt = .now
            if action == "clear" { isGoalExpanded = false }
            return true
        } catch {
            errorMessage = error.localizedDescription
            if action == "set" {
                draft = objective ?? ""
                enterGoal()
                activeGoal = try? await conversationManager.goal(taskID: task.id)
            }
            return false
        }
    }

    func reconcileGoalGeneration(with goal: CodexThreadGoal) {
        let defaults = WorkspaceSettings.preferencesStore
        let savedID = defaults.string(forKey: goalGenerationDefaultsKey) ?? currentGoalGenerationID
        let savedObjective = defaults.string(forKey: goalGenerationObjectiveDefaultsKey) ?? currentGoalObjective
        let savedTimeBaseline = defaults.object(forKey: goalGenerationTimeBaselineDefaultsKey) as? Double
            ?? currentGoalTimeBaselineSeconds
        let priorGenerationCompleted = savedID.map { id in
            goalAchievementTimelineEntries.contains { $0.id == id }
        } ?? false
        if savedID == nil || savedObjective != goal.objective || (goal.status == "active" && priorGenerationCompleted) {
            let generationID = UUID().uuidString
            let hasPreviousGoalGeneration = savedID != nil || !goalAchievementTimelineEntries.isEmpty
            let timeBaseline = hasPreviousGoalGeneration ? Double(goal.timeUsedSeconds ?? 0) : 0
            currentGoalGenerationID = generationID
            currentGoalObjective = goal.objective
            currentGoalTimeBaselineSeconds = timeBaseline
            defaults.set(generationID, forKey: goalGenerationDefaultsKey)
            defaults.set(goal.objective, forKey: goalGenerationObjectiveDefaultsKey)
            defaults.set(timeBaseline, forKey: goalGenerationTimeBaselineDefaultsKey)
        } else {
            currentGoalGenerationID = savedID
            currentGoalObjective = goal.objective
            let timeBaseline = savedTimeBaseline ?? 0
            currentGoalTimeBaselineSeconds = timeBaseline
            defaults.set(timeBaseline, forKey: goalGenerationTimeBaselineDefaultsKey)
        }
    }

    func goalElapsedTime(for goal: CodexThreadGoal, reportedSeconds: Double? = nil) -> Double {
        let seconds = reportedSeconds ?? Double(goal.timeUsedSeconds ?? 0)
        return max(0, seconds - (currentGoalTimeBaselineSeconds ?? 0))
    }

    func persistGoalAchievementTimeline() {
        guard let data = try? JSONEncoder().encode(goalAchievementTimelineEntries) else { return }
        WorkspaceSettings.preferencesStore.set(data, forKey: goalAchievementTimelineDefaultsKey)
    }

    func fallbackGoalCompletionAnchorID(in historyMessages: [ConversationMessage], objective: String) -> String {
        if let goalMessage = historyMessages.last(where: { $0.role == .user && $0.text == objective }),
           let turnID = goalMessage.turnID,
           let finalMessage = historyMessages.last(where: { $0.turnID == turnID }) {
            return finalMessage.id
        }
        return historyMessages.last?.id ?? GoalAchievementTimelineEntry.beforeFirstMessageID
    }

    func refreshGoalConversation(keepingShownTurn: Bool = false) async {
        do {
            let history = try await conversationManager.history(
                taskID: task.id,
                messageLimit: max(Self.historyPageSize, messages.count),
                onActionRequest: { actionNotice = approvalNotice }
            )
            // This is how a window learns that a recovery it did not send has died:
            // history hides the saved question only while that recovery runs.
            if userInputRequest == nil, let saved = history.pendingUserInputRequest,
               saved.threadID == task.activeConversationID,
               !answeredUserInputRequestIDs.contains(saved.id) {
                userInputRequest = saved
            }
            // A provider may not list a running turn's items yet, so mid-turn history can
            // hold less than this window already shows; applying it would blank the turn.
            let historyCount = history.messages.count + (history.earlierMessageCount ?? 0)
            if keepingShownTurn, historyCount < messages.count + earlierStoredMessageCount + (historyGap?.storedMessageCount ?? 0) { return }
            applyHistoryMessages(history)
            activities = history.activities
            providerBoundaries = history.providerBoundaries
            if let recoveryError = pluginBridgeRecoveryError {
                if errorMessage == recoveryError { errorMessage = nil }
                pluginBridgeRecoveryError = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Streams a running turn this window didn't send: a CLI send, a schedule, or a turn the
    /// daemon reattached after a restart. History reloads alone would show its progress but
    /// not its text as it is written.
    func watchRunningTurnIfNeeded() {
        guard !isReadOnly, !isLoadingHistory, !isWatchingRunningTurn, followedTurnStreams == 0, providerTurnIsActive else { return }
        isWatchingRunningTurn = true
        let assistantMessageID = UUID().uuidString
        followedTurnStreams += 1
        streamedReplyTargets[assistantMessageID] = assistantMessageID
        Task { @MainActor in
            defer {
                followedTurnStreams -= 1
                isWatchingRunningTurn = false
                streamedReplyTargets[assistantMessageID] = nil
                streamedRepliesAboveSteers[assistantMessageID] = nil
            }
            // The turn's prompt is already saved; show it while the rest streams in.
            await refreshGoalConversation(keepingShownTurn: true)
            _ = try? await conversationManager.watch(taskID: task.id, onUpdate: { update in
                applyStreamedUpdate(update, assistantMessageID: assistantMessageID)
            }, onUserInput: { request in
                showUserInputRequest(request)
            })
            flushStreamedTextDeltas()
            messages.removeAll { $0.id == assistantMessageID && $0.text.isEmpty }
            // The watched turn's final history arrived as its `completed` update; anything
            // after it (a queued follow-up starting) reaches this window the usual way.
            followHistory()
        }
    }

    /// Reloads history for a turn this window isn't streaming. A running turn
    /// can bump the revision many times a second, so reloads run one at a
    /// time and at most once a second, and the newest revision always loads.
    func followHistory() {
        followedHistoryIsStale = true
        guard !isFollowingHistory else { return }
        isFollowingHistory = true
        Task { @MainActor in
            while followedHistoryIsStale, followedTurnStreams == 0 {
                followedHistoryIsStale = false
                await refreshGoalConversation(keepingShownTurn: providerTurnIsActive)
                try? await Task.sleep(for: .seconds(1))
            }
            isFollowingHistory = false
        }
    }

    static func goalDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    func goalAchievementSummary(_ goal: CodexThreadGoal) -> String {
        guard goal.timeUsedSeconds != nil else { return "Goal achieved" }
        return "Goal achieved in \(Self.goalDuration(goalElapsedTime(for: goal)))"
    }

    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    static func elapsedSeconds(since start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start).rounded(.down)))
    }

    func refreshQueuedMessages() {
        queuedMessages = (try? conversationManager.queuedMessages(taskID: task.id)) ?? []
        answeredAsyncQuestionIDs = Set((try? conversationManager.answeredAsyncQuestionIDs(taskID: task.id)) ?? [])
    }

    func refreshChatPageStatus() {
        refreshParallelChatPlaceholders()
        // A parallel bubble is a single page of its own: it has no labels or separators to show.
        guard !task.isParallelChatBubble else { return }
        // The labels' own store, which stays open: this runs at every turn's end.
        guard let chatManager = chatPageAnchors.chatManager() else {
            chatPagesByTurnID = [:]
            chatPageAnchors.clear()
            return
        }
        chatPagesByTurnID = (try? chatManager.pageAssignmentsByTurnID()) ?? [:]
        chatPageAnchors.reload(from: chatManager)
        markCurrentChatPage()
    }
    func refreshParallelChatPlaceholders() {
        guard task.isStandaloneChat, !task.isParallelChatBubble,
              let bubbles = try? BoardTaskManager(modelContext: modelContext).parallelChatBubbles(of: task.id) else {
            if !parallelChatPlaceholders.isEmpty { parallelChatPlaceholders = [] }
            return
        }
        let placeholders = bubbles.map {
            ParallelChatPlaceholder(id: $0.id, prompt: $0.parallelPrompt ?? $0.title, anchorTurnID: $0.parallelAnchorTurnID)
        }
        if placeholders != parallelChatPlaceholders { parallelChatPlaceholders = placeholders }
    }

    func persistPendingAnnotations() {
        let data = PersistedAnnotations.encode(annotations.filter { !inFlightAnnotationIDs.contains($0.id) })
        let taskID = task.id
        let taskManager = BoardTaskManager(modelContext: modelContext)
        let previousSave = composerDraft.annotationSaveTask
        composerDraft.annotationSaveTask = Task { @MainActor in
            await previousSave?.value
            do {
                try await taskManager.savePendingAnnotations(taskID, data: data)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Ends a send's hold on its comments. Ones it did not deliver are still pending and go back
    /// to the saved draft by appending, never by overwriting: this view may be gone, and a newer
    /// view of the task may have saved other comments since.
    func releaseInFlightAnnotations(_ sent: [ConversationAnnotation]) {
        guard !sent.isEmpty else { return }
        let sentIDs = Set(sent.map(\.id))
        inFlightAnnotationIDs.subtract(sentIDs)
        let undelivered = annotations.filter { $0.pending && sentIDs.contains($0.id) }
        guard let data = PersistedAnnotations.encode(undelivered) else { return }
        let taskID = task.id
        let taskManager = BoardTaskManager(modelContext: modelContext)
        let previousSave = composerDraft.annotationSaveTask
        composerDraft.annotationSaveTask = Task { @MainActor in
            await previousSave?.value
            do {
                try await taskManager.savePendingAnnotations(taskID, data: data, appending: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Saves the composer's text and images together as the task's draft, during a turn
    /// as well as between turns. Values are captured now, so a save still completes after
    /// the view goes away.
    func persistDraft(reportingErrors: Bool = true) {
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        let text = draft
        let images = pendingImages.map(\.dataURL)
        let taskID = task.id
        let taskManager = BoardTaskManager(modelContext: modelContext)
        composerDraft.settledText = text
        Task { @MainActor in
            do {
                _ = try await taskManager.saveDraft(taskID, prompt: text, imageDataURLs: images)
            } catch {
                if reportingErrors { errorMessage = error.localizedDescription }
            }
        }
    }

    static func encodedImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) -> (data: Data, mimeType: String)? {
        if preferJPEG,
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
           jpeg.count <= 10_000_000 {
            return (jpeg, "image/jpeg")
        }
        if !preferJPEG,
           let png = bitmap.representation(using: .png, properties: [:]), png.count <= 10_000_000 {
            return (png, "image/png")
        }

        let maximumDimension = 1600
        let scale = min(1, Double(maximumDimension) / Double(max(bitmap.pixelsWide, bitmap.pixelsHigh)))
        var width = max(1, Int((Double(bitmap.pixelsWide) * scale).rounded()))
        var height = max(1, Int((Double(bitmap.pixelsHigh) * scale).rounded()))
        while width > 0 && height > 0 {
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            guard let context = NSGraphicsContext(bitmapImageRep: resized) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            bitmap.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
                if let jpeg = resized.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= 10_000_000 {
                    return (jpeg, "image/jpeg")
                }
            }
            guard width > 1, height > 1 else { return nil }
            width = max(1, Int(Double(width) * 0.85))
            height = max(1, Int(Double(height) * 0.85))
        }
        return nil
    }

    static func image(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    /// Decoded transcript images. The bubbles render inside `body`, which reruns on every keystroke in
    /// the composer; a new `NSImage` each time made Core Animation decode the whole PNG again on every
    /// frame. Reusing one image per attachment lets it keep the bitmap it already decoded.
    static let chatImageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// The image attached to a transcript message. The key names the attachment instead of hashing its
    /// data URL, which can run to megabytes; its length and tail tell apart images that share a slot.
    static func chatImage(fromDataURL value: String, messageID: String, index: Int) -> NSImage? {
        let key = "\(messageID)#\(index)#\(value.utf8.count)#\(value.suffix(48))" as NSString
        if let cached = chatImageCache.object(forKey: key) { return cached }
        guard let image = image(fromDataURL: value) else { return nil }
        chatImageCache.setObject(image, forKey: key)
        return image
    }

    func saveAndBack() {
        draftAutosaveTask?.cancel()
        if userInputRequest != nil {
            userInputRequest = nil
            Task { @MainActor in
                await Task.yield()
                onBack()
            }
            return
        }
        if isReadOnly { onBack(); return }
        if isResponding {
            // The turn keeps running, and so does the draft typed beside it.
            if isDraftUnsaved { persistDraft() }
            onBack()
            return
        }
        let hasStartedRepository = task.repositoryWorktrees.contains { !$0.isPending }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Folder-only context is not work in progress: an otherwise empty new task is discarded.
        if isNewTask, !hasStartedRepository,
           pendingImages.isEmpty, messages.isEmpty, activities.isEmpty,
           !hasDraft, !isLoadingHistory {
            Task { @MainActor in
                do {
                    try await BoardTaskManager(modelContext: modelContext).delete(task.id)
                    onBack()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        if isDraftUnsaved, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let images = pendingImages.map(\.dataURL)
            Task { @MainActor in
                do {
                    _ = try await BoardTaskManager(modelContext: modelContext).saveDraft(task.id, prompt: "", imageDataURLs: images)
                    composerDraft.settledText = draft
                    await saveDraftAndGenerateTitle(status: nil, then: onBack)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        Task { @MainActor in _ = await saveDraftAndGenerateTitle(status: nil, then: onBack) }
    }

    static var hiddenRecoveryReplyText: String { "[Response to private answer hidden]" }

    func showStreamedRecoveryReplies() {
        for index in messages.indices where messages[index].text == Self.hiddenRecoveryReplyText {
            if let text = streamedRecoveryReplies[messages[index].id] { messages[index].text = text }
        }
    }

    /// Holds a streamed delta until the next apply. The first delta of a batch
    /// schedules it; any other update, and the end of the stream, applies it sooner.
    func bufferStreamedTextDelta(_ delta: String, messageID: String) {
        let pending = pendingTextDeltas
        if pending.messageID != messageID || pending.taskID != task.id { flushStreamedTextDeltas() }
        pending.messageID = messageID
        pending.taskID = task.id
        pending.text += delta
        guard !pending.isApplyScheduled else { return }
        pending.isApplyScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.streamedTextApplyInterval)
            pending.isApplyScheduled = false
            flushStreamedTextDeltas()
        }
    }

    /// Appends the buffered text to its message, creating the message on the first text.
    func flushStreamedTextDeltas() {
        let pending = pendingTextDeltas
        guard let messageID = pending.messageID, let taskID = pending.taskID else { return }
        let text = pending.text
        pending.messageID = nil
        pending.taskID = nil
        pending.text = ""
        // Text streamed for another task's conversation is never shown in this one.
        guard taskID == task.id, !text.isEmpty else { return }
        let messageIndex: Int
        if let existingIndex = messages.firstIndex(where: { $0.id == messageID }) {
            messageIndex = existingIndex
        } else {
            messages.append(ConversationMessage(id: messageID, role: .assistant, text: ""))
            messageIndex = messages.index(before: messages.endIndex)
        }
        messages[messageIndex].text += text
    }

    /// Shows a question; the same question can arrive again, so keep its answers.
    func showUserInputRequest(_ request: ConversationUserInputRequest) {
        let isNewQuestion = request.id != userInputRequest?.id
        userInputRequest = request
        guard isNewQuestion else { return }
        userInputAnswers = [:]
        userInputOther = [:]
        userInputOtherSelected = []
    }

    /// Shows a steer in the transcript right away, before the provider has it.
    func showLocalSteer(_ steer: PendingLocalSteer) {
        // The steer follows the text that streamed before it.
        flushStreamedTextDeltas()
        if let index = unconfirmedStreamedSteers.firstIndex(where: { MentionText.sameUserText($0, steer.text) }) {
            unconfirmedStreamedSteers.remove(at: index)
            return
        }
        pendingLocalSteers.append(steer)
        unechoedLocalSteers.append(steer.text)
        liveSteerMessageIDs.insert(steer.id)
        moveStreamedRepliesBelowSteer()
        messages.append(ConversationMessage(id: steer.id, role: .user, text: steer.text, imageDataURLs: steer.imageDataURLs))
    }

    /// A steer closes what the turn has written so far: what streams after it starts a new
    /// message below the steer instead of growing the one above it.
    func moveStreamedRepliesBelowSteer() {
        for (stream, target) in streamedReplyTargets {
            messages.removeAll { $0.id == target && $0.role == .assistant && $0.text.isEmpty }
            // Only text the provider has not settled as an item or a final answer yet.
            if messages.contains(where: { $0.id == target && $0.phase == nil }) {
                streamedRepliesAboveSteers[stream, default: []].append(target)
            }
            streamedReplyTargets[stream] = UUID().uuidString
        }
    }

    /// The message above a steer that `text`, now settled by the provider, streamed into, if any.
    /// It is matched by content: a later item is new work and belongs below the steer.
    func takeStreamedReplyAboveSteer(stream: String, settling text: String) -> Int? {
        let settled = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for id in streamedRepliesAboveSteers[stream] ?? [] {
            guard let index = messages.firstIndex(where: { $0.id == id }) else { continue }
            let streamed = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !streamed.isEmpty, settled.hasPrefix(streamed) else { continue }
            streamedRepliesAboveSteers[stream]?.removeAll { $0 == id }
            return index
        }
        return nil
    }

    /// The provider has the steer, or it was withdrawn: history owns it from here.
    func settleLocalSteer(_ steer: PendingLocalSteer, delivered: Bool) {
        pendingLocalSteers.removeAll { $0.id == steer.id }
        guard !delivered else { return }
        messages.removeAll { $0.id == steer.id }
        if let index = unechoedLocalSteers.firstIndex(of: steer.text) { unechoedLocalSteers.remove(at: index) }
    }

    /// Delivers steers to the daemon after the ones before them, so they reach the agent in
    /// the order the user sent them while the composer stays free.
    func deliverSteerInOrder(_ delivery: @escaping @MainActor () async -> Void) {
        let previous = steerDeliveryTail
        steerDeliveryTail = Task { @MainActor in
            await previous?.value
            await delivery()
        }
    }

    /// Autosaves typed text while the agent responds as well as between turns. Composer
    /// changes that need no save (a restored draft, or the empty composer a send leaves)
    /// match the settled text and are skipped.
    func scheduleDraftAutosave(_ value: String) {
        draftAutosaveTask?.cancel()
        guard !isReadOnly, !isLoadingHistory, value != composerDraft.settledText else { return }
        draftAutosaveTask = Task { @MainActor in
            // Let AppKit finish a burst of synthesized keystrokes before the
            // main-actor SwiftData write starts. This keeps long XCTest
            // `typeText` operations responsive while retaining prompt
            // autosave once typing settles.
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, !isLoadingHistory, draft == value else { return }
            persistDraft()
        }
    }

    @discardableResult
    func saveDraftAndGenerateTitle(
        status: TaskStatus?,
        prompt submittedPrompt: String? = nil,
        generateTitle: Bool = true,
        reserveTitleForSend: Bool = false,
        sendsComposerDraft: Bool = false,
        then completion: (() -> Void)? = nil
    ) async -> Bool {
        let prompt = (submittedPrompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            // An image-only send has no prompt to submit, but its draft is no longer unsent. Its
            // images leave the draft once the turn starts.
            if sendsComposerDraft {
                do {
                    _ = try await BoardTaskManager(modelContext: modelContext).savePrompt(task.id, prompt: "", replacingDraft: true)
                } catch {
                    errorMessage = error.localizedDescription
                    return false
                }
            }
            if task.title == "Generating title…", task.pendingSubmittedPrompt == nil {
                _ = try? await BoardTaskManager(modelContext: modelContext).renameIfTitleMatches(
                    task.id,
                    expectedTitle: "Generating title…",
                    title: "Untitled task"
                )
            }
            completion?()
            return true
        }
        let taskManager = BoardTaskManager(modelContext: modelContext)
        var shouldGenerateTitle = false
        do {
            // Without a status change this saves the composer's draft, text and images together.
            let savedTask = status == nil && !reserveTitleForSend
                ? try await taskManager.saveDraft(task.id, prompt: prompt, imageDataURLs: pendingImages.map(\.dataURL))
                : try await taskManager.savePrompt(
                    task.id,
                    prompt: prompt,
                    status: status,
                    submitted: reserveTitleForSend,
                    replacingDraft: sendsComposerDraft
                )
            if status == nil && !reserveTitleForSend { composerDraft.settledText = draft }
            if generateTitle, ["Generating title…", "Untitled task"].contains(savedTask.title) {
                shouldGenerateTitle = try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: savedTask.title,
                    title: "Generating title…"
                ) != nil
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        completion?()
        guard shouldGenerateTitle else { return true }
        isGeneratingTitle = true
        Task { @MainActor in
            let generated = await generateTaskTitle(from: prompt)
            let title = generated?.title
            let titleSource = generated?.provider.rawValue ?? "prompt-fallback"
            let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
            let taskManager = BoardTaskManager(modelContext: modelContext)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            do {
                guard try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: "Generating title…",
                    title: resolvedTitle
                ) != nil else {
                    let currentTitle = (try? taskManager.taskModel(task.id).title) ?? ""
                    PlayhouseDiagnostics.record("task.title_apply.skipped", fields: [
                        "taskID": task.id.uuidString,
                        "reason": "title_changed",
                        "currentTitleState": PlayhouseTaskTitleDiagnostics.state(of: currentTitle),
                        "titleSource": titleSource
                    ])
                    isGeneratingTitle = false
                    return
                }
                PlayhouseDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": task.id.uuidString,
                    "titleSource": titleSource,
                    "fallbackWordCount": title == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
                ])
            } catch {
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["taskID"] = task.id.uuidString
                fields["titleSource"] = titleSource
                PlayhouseDiagnostics.record("task.title_apply.failed", fields: fields)
            }
            isGeneratingTitle = false
        }
        return true
    }

    func generateTaskTitle(from prompt: String) async -> (title: String, provider: ConversationProvider)? {
        await conversationManager.generateTitle(taskID: task.id, prompt: prompt)
    }

    var installedProviders: [ConversationProvider] {
        providerInstallStatuses.filter(\.isInstalled).map(\.provider)
    }

    /// The providers the menu offers to install. None until the daemon reports what's installed.
    var missingProviders: [ConversationProvider] {
        providerInstallStatuses.filter { !$0.isInstalled }.map(\.provider)
    }

    /// Reads which providers are installed. A conversation that hasn't started, whose provider
    /// isn't installed, switches to one that is, so the composer shows a provider that can run.
    func loadProviderInstallStatuses(adoptInstalledProvider: Bool = false) async {
        guard let statuses = try? await conversationManager.providerInstallStatuses() else { return }
        providerInstallStatuses = statuses
        guard adoptInstalledProvider, !installedProviders.contains(provider),
              let installed = installedProviders.first,
              messages.isEmpty, task.pendingSubmittedPrompt == nil, canSwitchProvider else { return }
        switchProvider(to: installed, remembersDefault: false)
    }

    /// Runs the provider's official installer through the daemon, then switches to it.
    func installProvider(_ newProvider: ConversationProvider) {
        guard installingProvider == nil else { return }
        installingProvider = newProvider
        errorMessage = nil
        Task { @MainActor in
            defer { installingProvider = nil }
            do {
                _ = try await conversationManager.installProvider(newProvider)
                await loadProviderInstallStatuses()
                if newProvider != provider, canSwitchProvider { switchProvider(to: newProvider) }
            } catch {
                await loadProviderInstallStatuses()
                errorMessage = "Couldn't install \(ConversationProviderInstaller.productName(newProvider)): \(error.localizedDescription)"
            }
        }
    }

    var providerMenuHelp: String {
        canSwitchProvider
            ? "Choose which assistant runs this task"
            : "Wait for the current turn, questions, and queued follow-ups to finish before switching"
    }

    /// The transcript is Playhouse's own and stays as it is: a switch only decides who
    /// runs the next turn. So the window shows the switch at once, from what it already
    /// holds (the cached models, the remembered model and the divider), while the daemon
    /// saves it. The provider's live model list and its notice follow in the background.
    func switchProvider(to newProvider: ConversationProvider, remembersDefault: Bool = true) {
        guard newProvider != provider, canSwitchProvider else { return }
        let shownBoundaries = providerBoundaries
        let shownModels = modelOptions
        let shownModelID = selectedModelID
        let shownNotice = providerNotice
        providerBoundaries = providerBoundaries(afterSwitchingTo: newProvider)
        isSwitchingProvider = true
        switchedProvider = newProvider
        isEnteringGoal = false
        errorMessage = nil
        providerNotice = nil
        modelOptions = []
        primeModelOptionsFromCache()
        providerSwitch = Task { @MainActor in
            defer {
                isSwitchingProvider = false
                providerSwitch = nil
            }
            do {
                providerBoundaries = try await conversationManager.setProvider(taskID: task.id, provider: newProvider, remembersDefault: remembersDefault).providerBoundaries
            } catch {
                // The switch didn't happen, so the window shows what it showed before.
                switchedProvider = nil
                providerBoundaries = shownBoundaries
                modelOptions = shownModels
                selectedModelID = shownModelID
                providerNotice = shownNotice
                errorMessage = error.localizedDescription
                return
            }
            if task.conversationProvider == newProvider {
                switchedProvider = nil
            } else {
                // The task model reports the saved switch, or another client's switch since, on
                // its next change. Should those two writes merge into no change at all, the
                // window stops showing its own switch here rather than go on showing it.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    if !isSwitchingProvider, switchedProvider == newProvider { switchedProvider = nil }
                }
            }
            Task { await loadModels() }
            Task { await loadProviderNotice() }
            // Goals are Codex's, so the goal follows the provider too.
            Task { @MainActor in
                let goal = try? await conversationManager.goal(taskID: task.id)
                guard provider == newProvider else { return }
                activeGoal = goal
                goalStatusUpdatedAt = .now
            }
        }
    }

    /// The dividers once the conversation switches to `newProvider`, as the daemon records
    /// the switch: a switch still waiting for its first message is replaced instead of
    /// leaving an empty divider, and returning to the latest message's provider leaves none.
    /// They show only until the switch is saved, which returns the recorded dividers.
    func providerBoundaries(afterSwitchingTo newProvider: ConversationProvider) -> [ConversationProviderBoundary] {
        guard let lastMessage = messages.last else { return providerBoundaries }
        var boundaries = providerBoundaries
        var latestProvider = provider
        if boundaries.last?.afterMessageID == lastMessage.id {
            boundaries.removeLast()
            latestProvider = boundaries.last?.provider ?? lastMessage.provider ?? newProvider
        }
        if latestProvider != newProvider {
            boundaries.append(ConversationProviderBoundary(
                id: "provider-boundary-switch-\(UUID().uuidString)", provider: newProvider, afterMessageID: lastMessage.id
            ))
        }
        return boundaries
    }

    func loadProviderNotice() async {
        let noticeProvider = provider
        guard let capabilities = try? await conversationManager.providerCapabilities(taskID: task.id),
              provider == noticeProvider,
              let current = capabilities.first(where: { $0.provider == provider }) else { return }
        // A provider that isn't installed is offered for install in the provider menu instead.
        guard current.isAvailable else {
            providerNotice = nil
            return
        }
        var parts: [String] = []
        switch provider {
        case .claude:
            parts.append("Claude uses its own settings: \(current.skills.count) skills and commands, \(current.mcpServers.count) MCP servers.")
        case .codex:
            parts.append("Codex runs without apps or hooks, with the MCP servers turned on in Skills, Rules & MCP.")
        }
        parts.append(provider.supportsGoals ? "Goals are available." : "Goals are available only with Codex.")
        parts.append("Earlier turns are shared as text context on the next message.")
        providerNotice = parts.joined(separator: " ")
    }

    /// Stops the response. The window shows the stop immediately; the daemon and the provider
    /// catch up in the background, however long the turn takes to wind down.
    func pauseResponse(confirmationID: String? = nil) {
        guard !isPausingResponse else { return }
        // Text that streamed before the click is part of what was stopped.
        flushStreamedTextDeltas()
        isPausingResponse = true
        isResponding = false
        hasPausedResponse = true
        interruptsInFlight += 1
        let generation = sendGeneration
        Task { @MainActor in
            do {
                var interrupted = try await conversationManager.interrupt(
                    taskID: task.id, confirmationID: confirmationID
                )
                // This window's send may not have reached the daemon when the stop did.
                var remainingAttempts = 50
                while !interrupted, remainingAttempts > 0, isPausingResponse,
                      sendGeneration == generation, sendsInFlight > 0 {
                    try? await Task.sleep(for: .milliseconds(100))
                    remainingAttempts -= 1
                    interrupted = try await conversationManager.interrupt(
                        taskID: task.id, confirmationID: confirmationID
                    )
                }
                interruptsInFlight -= 1
                guard sendGeneration == generation, isPausingResponse else { return }
                if !interrupted {
                    // Nothing was left to stop: the turn ended on its own first.
                    await conversationRuntime.refresh()
                    guard sendGeneration == generation, isPausingResponse else { return }
                    if !conversationRuntime.wasLastTurnInterrupted(threadID: task.activeConversationID ?? "") {
                        hasPausedResponse = false
                    }
                    // A turn that is still running, or a send of this window's that the stop
                    // never caught up with, goes back to showing Stop.
                    if providerTurnIsActive || sendsInFlight > 0 {
                        isPausingResponse = false
                        isResponding = true
                        hasPausedResponse = false
                        return
                    }
                }
                settleLocalStopIfDone()
            } catch {
                interruptsInFlight -= 1
                guard sendGeneration == generation, isPausingResponse else { return }
                // The turn is still running, so the window goes back to showing it.
                isPausingResponse = false
                hasPausedResponse = false
                isResponding = sendsInFlight > 0 || providerTurnIsActive
                if let confirmation = error as? ConversationStopConfirmation {
                    backgroundStopConfirmationID = confirmation.id
                    confirmsStoppingBackgroundWork = true
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Ends the local stop once the daemon answered it and the stopped turn is over, so a
    /// later turn shows its Stop button again.
    func settleLocalStopIfDone() {
        guard isPausingResponse, interruptsInFlight == 0, sendsInFlight == 0, !providerTurnIsActive else { return }
        isPausingResponse = false
    }

    /// The user stopped a message this window has not handed to the daemon yet. A new message
    /// waits until it is handed over, so it can neither overtake the stop nor be stopped by it.
    var isStopLandingOnOwnSend: Bool {
        isPausingResponse && sendsAwaitingDispatch > 0
    }

    func continueResponse() {
        guard hasPausedResponse, !isStopLandingOnOwnSend else { return }
        sendMessage(overrideText: "Continue with the same request from where you left off.")
    }

    var conversationModeDefaultsKey: String {
        TaskPreferenceKeys.conversationMode(taskID: task.id)
    }

    func setConversationMode(_ mode: ConversationMode) {
        conversationMode = mode
        WorkspaceSettings.preferencesStore.set(mode.rawValue, forKey: conversationModeDefaultsKey)
    }

    /// Plan mode and goal entry are never on together: turning one on turns the other off.
    func enterPlanMode() {
        isEnteringGoal = false
        setConversationMode(.plan)
    }

    func enterGoal() {
        isEnteringGoal = true
        if conversationMode == .plan { setConversationMode(.code) }
    }

    /// Optimized context is independent of Plan and Goal: it changes what a follow-up's
    /// session holds, not how the agent works. The task saves it, so it stays on until
    /// turned off; a failed save puts the toggle back.
    func toggleOptimizedContext() {
        let previous = conversationContextMode
        let next: ConversationContextMode = previous == .optimized ? .full : .optimized
        conversationContextMode = next
        Task {
            do {
                _ = try await conversationManager.setContextMode(taskID: task.id, mode: next)
            } catch {
                conversationContextMode = previous
                errorMessage = error.localizedDescription
            }
        }
    }

    func startImplementingPlan() {
        isEnteringGoal = false
        setConversationMode(.code)
        sendMessage(overrideText: "Start implementing the plan.")
    }
}
