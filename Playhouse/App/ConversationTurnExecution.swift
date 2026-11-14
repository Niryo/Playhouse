import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func settleFinishedTurn(
        taskID: UUID,
        client: ConversationProviderClient,
        threadID persistedThreadID: String?,
        recording: TurnRecording,
        deferMissingOutcomeStatus: Bool,
        phase: inout String
    ) async throws {
        for (activityID, durationMs) in persistedThreadID.map({ client.lastTurnActivityDurations(threadID: $0) }) ?? [:] {
            try await tasks.recordConversationActivityDuration(
                taskID: taskID,
                activityID: activityID,
                durationMs: durationMs
            )
        }
        phase = "worktree-finalization"
        phase = "review-status-persistence"
        let reportedOutcome = try await tasks.finishConversationTurnOutcome(taskID) ?? recording.leakedOutcome
        lastReportedTurnOutcomeByTaskID[taskID] = reportedOutcome
        // A chat's settled turn (its close-turn) only stops the recovery loop: a chat has no
        // board status for an outcome to decide.
        let statusOutcome = (try? tasks.conversationSubject(taskID))?.isStandaloneChat == true ? nil : reportedOutcome
        if statusOutcome == nil, deferMissingOutcomeStatus, let revision = recording.pendingQuestionLifecycleRevision,
           let stillPending = try? transcripts.readState(taskID).pendingUserInputRequest {
            // The turn completed without reporting an outcome while a structured
            // question it raised is still unanswered. Undo the immediate
            // waiting-response flip so the outcome reminder loop — not a stray
            // unanswered question — decides this task's fate, and downgrade the
            // saved request so reopening the conversation doesn't re-force it.
            _ = try? await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: revision)
            if stillPending.isBlocking {
                try? transcripts.mutate(taskID, turns: .none) { transcript in
                    guard transcript.pendingUserInputRequest?.id == stillPending.id else { return }
                    transcript.pendingUserInputRequest = ConversationUserInputRequest(
                        id: stillPending.id,
                        threadID: stillPending.threadID,
                        questions: stillPending.questions,
                        isBlocking: false,
                        mode: stillPending.mode
                    )
                }
            }
        } else if (try? tasks.conversationSubject(taskID).status) == .done {
            // A follow-up reopens a Done task before its turn, so a task still Done here has
            // no worktree to sync or review, and every outcome leaves it Done.
        } else if let outcome = statusOutcome.flatMap(TurnOutcome.init(rawValue:)) {
            switch outcome {
            case .inProgress:
                // `in-progress` settles on no status: the task stays In
                // Progress while the caller drives the next continuation turn.
                break
            case .completed:
                // A reviewed task must hold no local-only pull request changes:
                // sync them first, and block instead of resting partially pushed.
                phase = "review-sync"
                var syncError: Error?
                do {
                    _ = try await tasks.syncPullRequestChanges(taskID, clients: clients)
                } catch {
                    syncError = error
                }
                if let syncError {
                    PlayhouseDiagnostics.record("task.review.sync.failed", fields: [
                        "taskID": taskID.uuidString,
                        "error": syncError.localizedDescription
                    ])
                    _ = try await tasks.setLifecycleStatus(
                        taskID,
                        to: .blocked,
                        message: BoardTaskManager.reviewSyncBlockedMessage(syncError)
                    )
                } else {
                    let reviewRecord = try await tasks.setLifecycleStatus(taskID, to: .review)
                    phase = "review-auto-pr"
                    await tasks.createPullRequestsOnReviewIfNeeded(reviewRecord, clients: clients, settingsManager: settingsManager)
                }
            case .waitingResponse:
                _ = try await tasks.setLifecycleStatus(taskID, to: .waitingResponse)
            }
        } else if !deferMissingOutcomeStatus {
            _ = try await tasks.setLifecycleStatus(taskID, to: .waitingResponse)
        }
    }

    func sendReserved(
        taskID: UUID,
        text: String,
        imageDataURLs: [String],
        mode: ConversationMode,
        requestedModelID: String?,
        userInputAnswers: [String: [String]],
        sensitiveUserInputAnswerValues: [String],
        requiresSensitiveAnswerRedaction: Bool = false,
        hideSensitiveRecoveryPrompt: Bool,
        isPlayhouseNudge: Bool,
        deferMissingOutcomeStatus: Bool,
        statusBeforeSubmission: TaskStatus?,
        contextPageIDs: [String],
        onTurnStarting: (() -> Void)?,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void,
        historyMessageLimit: Int? = nil
    ) async throws -> ConversationHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedText = hideSensitiveRecoveryPrompt
            ? Self.privatePromptPlaceholder(for: normalizedText)
            : Self.redactingSensitiveText(normalizedText, values: sensitiveUserInputAnswerValues)
        // The provider and the transcript get the mention block; the task's own prompt, title and
        // worktree names keep what was typed.
        let typedText = MentionText.displayText(persistedText)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        var task = try tasks.conversationSubject(taskID)
        let provider = task.conversationProvider
        let client = clients.client(for: provider)
        let modelID = try requestedModelID ?? self.modelID(taskID: taskID) ?? provider.defaultModelID
        guard Self.isValidModelID(modelID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, digits, dots, underscores, and hyphens.")
        }
        // A Done task keeps its conversation; a follow-up reopens it below, once validated.
        let availableRoots = Self.launchRoots(task).compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
        let validationWorkspace = try ConversationWorkspaceContext(roots: availableRoots)
        let effort = ConversationEffort(rawValue: task.conversationEffort) ?? .medium
        try await client.validateEffort(effort, modelID: modelID, workspace: validationWorkspace)
        if requestedModelID != nil {
            try await setModelID(taskID: taskID, modelID: modelID)
        }
        try tasks.prepareConversationTurnOutcome(taskID)
        defer { tasks.clearConversationTurnOutcome(taskID) }
        var persistedThreadID = task.activeConversationID
        PlayhouseDiagnostics.recordAndFlush("conversation.send.started", fields: client.diagnosticFields(forThread: persistedThreadID ?? "", [
            "taskID": taskID.uuidString,
            "threadID": task.activeConversationID ?? "new",
            "taskStatus": task.status.rawValue,
            "mode": mode.rawValue
        ]))
        defer {
            if let threadID = persistedThreadID {
                client.clearTurnStarting(threadID: threadID)
            }
        }
        // A follow-up on a Done task moves it back to In Progress in fresh worktrees, so the
        // board shows it while the agent works. A failed send then leaves it waiting for the
        // user rather than Done with worktrees that the archive does not account for.
        let reopensDoneTask = !isPlayhouseNudge && !task.isStandaloneChat && task.status == .done
        if reopensDoneTask {
            do {
                try await tasks.reopenDoneTask(taskID)
                task = try tasks.conversationSubject(taskID)
            } catch {
                // A reopen that failed after leaving Done waits for the user; either way the
                // follow-up returns to the composer as the unsent draft.
                if (try? tasks.conversationSubject(taskID).status) != .done {
                    _ = try? await tasks.setLifecycleStatus(taskID, to: .waitingResponse, message: error.localizedDescription)
                }
                try? await tasks.returnUnsentSubmittedPromptToDraft(taskID)
                throw error
            }
        }
        let shouldGenerateTitle = !isPlayhouseNudge
            && !normalizedText.isEmpty
            && ["Untitled task", "Generating title…"].contains(task.title)
        // A caller that already saved the submitted prompt (the composer does,
        // so it survives navigation) supplies the status it replaced.
        let priorStatus = reopensDoneTask ? .waitingResponse : statusBeforeSubmission ?? task.status
        let priorStatusMessage = task.statusMessage
        let resolveTitleBeforeWorktree: Bool
        let workspace: ConversationWorkspaceContext
        let titleGeneration: Task<Void, Never>?
        var repositoryRoot: URL? = nil
        var resolvedWorktreeTitle: String? = ["Untitled task", "Generating title…"].contains(task.title)
            ? nil
            : task.title
        do {
            if reopensDoneTask {
                _ = try await tasks.savePrompt(taskID, prompt: persistedText, status: .inProgress, submitted: true)
            }
            // A task with explicit workspace roots is self-contained and may be
            // sent through CLI/XPC before the UI has initialized the global
            // default-parent setting. Rootless tasks still require that setting,
            // except standalone chat, which has no repository at all and must stay
            // usable even when no default repository parent is configured.
            repositoryRoot = task.isStandaloneChat ? nil : try (Self.launchRoots(task)
                .compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
                .first ?? settingsManager.requireRepositoryRootFolder())
            if !isPlayhouseNudge && !reopensDoneTask {
                _ = try await tasks.savePrompt(taskID, prompt: persistedText, status: .inProgress, submitted: true)
            }
            // Resolve the first submitted prompt's title before preparing any
            // repositories. The app's model context can lag repository changes
            // made through the bridge, so using this snapshot to detect an auto
            // branch can otherwise allocate "untitled-task" before the generated
            // title arrives.
            let titleMustPrecedeAutoWorktree = task.repositoryWorktrees.contains {
                $0.isPending && $0.branch == "auto"
            }
            resolveTitleBeforeWorktree = shouldGenerateTitle && titleMustPrecedeAutoWorktree
            if resolveTitleBeforeWorktree {
                let reserved = try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: task.title,
                    title: "Generating title…"
                )
                if reserved != nil {
                    let titleRoots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    let titleWorkspace = try ConversationWorkspaceContext(roots: titleRoots)
                    resolvedWorktreeTitle = try await generateAndApplyTitle(
                        taskID: taskID,
                        prompt: typedText,
                        workspace: titleWorkspace,
                        clients: clients.helperClients(preferring: provider)
                    )
                }
                task = try tasks.conversationSubject(taskID)
                if ["Untitled task", "Generating title…"].contains(task.title) {
                    throw BridgeCommandError(
                        code: "invalid_transition",
                        message: "The task title changed while it was being prepared. Try sending again."
                    )
                }
                resolvedWorktreeTitle = task.title
            }
            // A standalone chat owns no repositories, so there is no worktree to prepare.
            if !task.isStandaloneChat && task.authoringPluginID == nil {
                task = try await tasks.prepareRepositoryWorktrees(
                    taskID,
                    fallbackPrompt: isPlayhouseNudge && !task.hasUnsentDraft ? (task.savedPrompt ?? typedText) : typedText,
                    resolvedTitle: resolvedWorktreeTitle ?? typedText
                )
            }
            if !isPlayhouseNudge, !normalizedText.isEmpty {
                _ = try await tasks.savePrompt(taskID, prompt: typedText, status: .inProgress, submitted: true)
            }
            let roots = Self.launchRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) }
            workspace = try launchWorkspace(for: task, roots: roots, message: normalizedText)
            _ = try await tasks.clearProgressReport(taskID)
            if shouldGenerateTitle && !resolveTitleBeforeWorktree {
                let latest = try tasks.conversationSubject(taskID)
                let titleReserved = ["Untitled task", "Generating title…"].contains(latest.title)
                    ? try await tasks.renameIfTitleMatches(
                        taskID,
                        expectedTitle: latest.title,
                        title: "Generating title…"
                    ) != nil
                    : false
                if titleReserved {
                    let titleClients = clients.helperClients(preferring: provider)
                    titleGeneration = Task { @MainActor in
                        do {
                            _ = try await self.generateAndApplyTitle(
                                taskID: taskID,
                                prompt: typedText,
                                workspace: workspace,
                                clients: titleClients
                            )
                        } catch {
                            // Background title generation has always been best-effort;
                            // the helper records persistence failures before returning.
                        }
                    }
                } else {
                    titleGeneration = nil
                }
            } else {
                titleGeneration = nil
            }
        } catch {
            // No turn started: a rejected branch claim, title race, or missing
            // root must not leave the task In Progress. The prompt returns to the
            // composer as the unsent draft.
            _ = try? await tasks.setLifecycleStatus(taskID, to: priorStatus, message: priorStatusMessage)
            if !isPlayhouseNudge { try? await tasks.returnUnsentSubmittedPromptToDraft(taskID) }
            throw error
        }
        let started = try await tasks.setLifecycleStatus(taskID, to: .inProgress)
        onUpdate(ConversationUpdate(type: "started", taskStatus: started.status))
        var phase = "thread-start"
        let approvalNotice = "\(provider.displayName) requested an approval. Playhouse denied it because approval prompts are disabled."
        do {
            // Read the visible history for the handoff before this provider gets a
            // new native thread: Codex can't list a thread that has no turns yet.
            phase = "transcript-segment"
            let segment = try await prepareSegment(task: try tasks.conversationSubject(taskID))
            // A standalone chat page is its own context, so its recovery transcript is that page
            // alone; task conversations still hand off their whole visible history.
            let standaloneChatPage = task.isStandaloneChat ? standaloneChatActivePage(taskID: taskID) : nil
            let sessionRecoveryContext: String?
            if let standaloneChatPage {
                sessionRecoveryContext = standaloneChatPageContext(taskID: taskID, pageIDs: [standaloneChatPage.id])
            } else if provider == .claude {
                sessionRecoveryContext = ConversationHandoff.context(for: .claude, messages: Self.withoutNudgeTurns(try await history(taskID: taskID).messages))
            } else {
                sessionRecoveryContext = nil
            }
            phase = "thread-start"
            func standaloneChatInstructions() -> String {
                TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: repositoryRoot?.path,
                    isStandaloneChat: task.isStandaloneChat,
                    isPluginEditor: task.authoringPluginID != nil,
                    isArchived: task.status == .done,
                    pluginPlacement: task.authoringPluginPlacement,
                    pluginID: task.authoringPluginID,
                    pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory
                )
            }
            let threadID: String
            var resumesExistingSession = false
            // Each page owns its provider session. A page without one starts a fresh session that
            // carries the system prompt plus only that page's turns, so context never accumulates
            // across pages; the task pointer follows the active page's session.
            let pageSessionID = standaloneChatPage?.conversationID(forProvider: provider.rawValue)
            // A fresh page session has none of the page's own turns yet (the turn that opened the
            // page ran in the previous page's session), so seed it with that page's transcript.
            var standaloneChatSeedPageIDs: [String] = []
            if let standaloneChatPage, pageSessionID == nil { standaloneChatSeedPageIDs.append(standaloneChatPage.id) }
            // Annotations can reference an earlier page; that page travels with this turn only.
            standaloneChatSeedPageIDs += contextPageIDs.filter { !standaloneChatSeedPageIDs.contains($0) && $0 != standaloneChatPage?.id }
            let standaloneChatSeedContext = standaloneChatPage == nil && contextPageIDs.isEmpty
                ? nil
                : standaloneChatPageContext(taskID: taskID, pageIDs: standaloneChatSeedPageIDs)
            if let standaloneChatPage, pageSessionID == nil {
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: standaloneChatInstructions()
                )
                phase = "thread-persistence"
                try? tasks.standaloneChatManager().setProviderSession(
                    pageID: standaloneChatPage.id, provider: provider.rawValue, sessionID: threadID
                )
                _ = try await tasks.persistConversationID(taskID, provider: provider, id: threadID)
                persistedThreadID = threadID
                PlayhouseDiagnostics.record("chat.page.session_started", fields: [
                    "taskID": taskID.uuidString,
                    "pageID": standaloneChatPage.id,
                    "provider": provider.rawValue
                ])
            } else if let pageSessionID {
                threadID = pageSessionID
                if task.activeConversationID != pageSessionID {
                    _ = try await tasks.persistConversationID(taskID, provider: provider, id: pageSessionID)
                    persistedThreadID = pageSessionID
                }
            } else if task.isStandaloneChat {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "Playhouse couldn't open this chat page's own conversation. Try again."
                )
            } else if let existing = task.activeConversationID {
                threadID = existing
                resumesExistingSession = true
            } else {
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: standaloneChatInstructions()
                )
                phase = "thread-persistence"
                _ = try await tasks.persistConversationID(taskID, provider: provider, id: threadID)
                persistedThreadID = threadID
            }
            // A resumed Claude session whose prompt cache has expired, or whose model
            // this turn changes, is compacted first, so the turn doesn't rewrite the
            // whole context into a cold cache. Status nudges and autopilot prompts
            // resume the same way.
            var resumeCacheState: ClaudeSessionCacheState?
            var compactedBeforeTurn = false
            if resumesExistingSession, !task.isStandaloneChat, let segment,
               !hideSensitiveRecoveryPrompt, userInputAnswers.isEmpty {
                let settings = settingsManager.contextCompaction
                let state = provider == .claude
                    ? claudeSessionCacheState(sessionID: threadID)
                    : codexCompactionState(taskID: taskID, threadID: threadID)
                resumeCacheState = provider == .claude ? state : nil
                if let state,
                   let trigger = ContextCompactionPolicy.beforeTurnTrigger(
                    state: state, requestedModel: modelID, provider: provider.rawValue, now: .now, settings: settings
                   ) {
                    phase = "context-compaction"
                    let compactionInstructions = TaskThreadDeveloperInstructions.make(
                        taskID: taskID,
                        repositories: task.repositoryWorktrees,
                        contextFolders: task.contextFolderPaths,
                        repositoryRootPath: repositoryRoot?.path,
                        isStandaloneChat: task.isStandaloneChat,
                        isArchived: task.status == .done,
                        pluginPlacement: (task as? BoardTask)?.pluginPlacement,
                        pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory
                    )
                    if provider == .claude {
                        compactedBeforeTurn = await runAutomaticCompaction(
                            taskID: taskID, threadID: threadID, trigger: trigger, state: state,
                            // A model switch compacts with the old model, whose cache holds the context.
                            modelID: trigger == .modelSwitch ? (state.model ?? modelID) : modelID,
                            effort: effort, segmentID: segment.segmentID, workspace: workspace,
                            developerInstructions: compactionInstructions,
                            now: .now, onUpdate: onUpdate
                        )
                    } else {
                        compactedBeforeTurn = await runCodexAutomaticCompaction(
                            taskID: taskID, threadID: threadID, trigger: trigger, state: state,
                            modelID: state.model ?? modelID, segmentID: segment.segmentID,
                            workspace: workspace, developerInstructions: compactionInstructions,
                            now: .now, onUpdate: onUpdate
                        )
                    }
                    try Task.checkCancellation()
                    if client.wasLastTurnInterrupted(threadID: threadID) {
                        throw CancellationError()
                    }
                    phase = "thread-start"
                }
            }
            let claudeTurnID = provider == .claude ? UUID().uuidString.lowercased() : nil
            // Only a private answer's recovery turn hides its output; a status nudge is shown.
            let hidesRecoveryOutput = hideSensitiveRecoveryPrompt
            if let claudeTurnID, let segment {
                try transcripts.mutate(taskID, turns: .none) { transcript in
                    if hideSensitiveRecoveryPrompt || !sensitiveUserInputAnswerValues.isEmpty {
                        if hidesRecoveryOutput || !sensitiveUserInputAnswerValues.isEmpty {
                            transcript.sensitiveTurnIDs = Array(Set(transcript.sensitiveTurnIDs ?? []).union([claudeTurnID])).sorted()
                        }
                        // Claude messages are persisted locally from sanitized
                        // callbacks, so the prompt is already safe to retain.
                        transcript.pendingSensitiveUserInputRedaction = false
                    }
                    transcript.turns.append(.init(id: claudeTurnID, segmentID: segment.segmentID, messages: [ConversationMessage(
                        id: "\(claudeTurnID)-user", role: .user, text: persistedText, imageDataURLs: imageDataURLs,
                        turnID: claudeTurnID, provider: .claude, modelID: modelID
                    )]))
                }
            }
            let recording = TurnRecording()
            if let state = resumeCacheState, !compactedBeforeTurn, !state.compactedSinceLastCall {
                recording.checksResumeCacheMiss = true
                recording.resumeIdleSeconds = state.lastCallAt.map { Date.now.timeIntervalSince($0) }
            }
            let callbacks = turnCallbacks(
                taskID: taskID, provider: provider, client: client, threadID: threadID, modelID: modelID,
                segment: segment, claudeTurnID: claudeTurnID,
                hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                isPlayhouseNudge: isPlayhouseNudge, userInputAnswers: userInputAnswers,
                recording: recording, onUpdate: onUpdate, onUserInput: onUserInput
            )
            if onTurnStarting != nil {
                client.markTurnStarting(threadID: threadID)
                onTurnStarting?()
            }
            if !isPlayhouseNudge, !imageDataURLs.isEmpty {
                // Leftover images stay safely in the draft, so a failed cleanup must not fail the turn.
                do {
                    try await tasks.clearSentDraftImages(taskID, sentImageDataURLs: imageDataURLs)
                } catch {
                    var fields = PlayhouseDiagnostics.errorFields(error)
                    fields["taskID"] = taskID.uuidString
                    PlayhouseDiagnostics.record("task.draft.sent_images_clear.failed", fields: fields)
                }
            }
            phase = "\(provider.rawValue)-turn"
            try tasks.activateConversationTurnOutcome(taskID)
            try await client.sendMessage(
                ConversationHandoff.prompt(
                    normalizedText,
                    context: [segment?.handoff, standaloneChatSeedContext]
                        .compactMap { $0 }.joined(separator: "\n\n").nilWhenBlank
                ),
                imageDataURLs: imageDataURLs,
                mode: mode,
                modelID: modelID,
                effort: effort,
                threadID: threadID,
                workspace: workspace,
                sessionRecoveryContext: sessionRecoveryContext,
                developerInstructions: TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: repositoryRoot?.path,
                    isStandaloneChat: task.isStandaloneChat,
                    isPluginEditor: task.authoringPluginID != nil,
                    isArchived: task.status == .done,
                    pluginPlacement: task.authoringPluginPlacement,
                    pluginID: task.authoringPluginID,
                    pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory
                ),
                onDelta: callbacks.onDelta,
                onFinalMessage: callbacks.onFinalMessage,
                onActivity: callbacks.onActivity,
                onDiff: callbacks.onDiff,
                onHistory: callbacks.onHistory,
                onActionRequest: callbacks.onActionRequest,
                onUserInput: callbacks.onUserInput,
                onSteerMessage: callbacks.onSteerMessage,
                onProgressMessage: callbacks.onProgressMessage,
                onMessageTimestamp: callbacks.onMessageTimestamp,
                onTurnStarted: callbacks.onTurnStarted,
                onTokenUsage: callbacks.onTokenUsage,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt
            )
            if hideSensitiveRecoveryPrompt,
               try transcripts.readState(taskID).pendingSensitiveUserInputRedaction == true {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "Playhouse couldn't safely record the private answer for conversation history. The question remains available to retry."
                )
            }
            if let segment, segment.handoff != nil || provider == .claude {
                try transcripts.mutate(taskID, turns: .none) { transcript in
                    guard let index = transcript.segments.firstIndex(where: { $0.id == segment.segmentID }) else { return }
                    transcript.segments[index].handoffDelivered = true
                }
            }
            try await settleFinishedTurn(
                taskID: taskID, client: client, threadID: persistedThreadID, recording: recording,
                deferMissingOutcomeStatus: deferMissingOutcomeStatus, phase: &phase
            )
        } catch {
            await titleGeneration?.value
            for (activityID, durationMs) in persistedThreadID.map({ client.lastTurnActivityDurations(threadID: $0) }) ?? [:] {
                try? await tasks.recordConversationActivityDuration(
                    taskID: taskID,
                    activityID: activityID,
                    durationMs: durationMs
                )
            }
            let hideInternalReminderDetails = hideSensitiveRecoveryPrompt || isPlayhouseNudge
            var fields = hideInternalReminderDetails
                ? ["error": "Private conversation recovery turn failed."]
                : PlayhouseDiagnostics.errorFields(
                    error,
                    redacting: [task.title, task.savedPrompt ?? "", task.pendingSubmittedPrompt ?? ""] + sensitiveUserInputAnswerValues
                )
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = persistedThreadID ?? ""
            fields["provider"] = provider.rawValue
            fields["phase"] = phase
            fields["storePath"] = PlayhouseDiagnostics.storeURL.path
            fields.merge(client.diagnosticFields(forThread: persistedThreadID ?? "", [:])) { _, new in new }
            let wasUserInterrupted = persistedThreadID.map { client.wasLastTurnInterrupted(threadID: $0) } ?? false
            let shouldKeepWaiting = wasUserInterrupted
            let safeFailureMessage = hideSensitiveRecoveryPrompt || isPlayhouseNudge
                ? (isPlayhouseNudge
                    ? "The private status nudge could not be completed."
                    : "The private answer could not be applied. Please answer the question again.")
                : Self.redactingSensitiveText(error.localizedDescription, values: sensitiveUserInputAnswerValues)
            let pendingQuestion = try? transcripts.readState(taskID).pendingUserInputRequest
            let hasPendingBlockingQuestion = pendingQuestion?.isBlocking == true
            // A saved non-blocking question stays answerable after the provider
            // exits, exactly as when the task is reconciled on open.
            let hasPendingNonBlockingQuestion = pendingQuestion != nil && !hasPendingBlockingQuestion
            let failureStatus: TaskStatus
            if hasPendingBlockingQuestion || shouldKeepWaiting {
                failureStatus = .waitingResponse
            } else if hasPendingNonBlockingQuestion || hideSensitiveRecoveryPrompt || isPlayhouseNudge {
                failureStatus = .inProgress
            } else {
                failureStatus = .blocked
            }
            _ = try? await tasks.setLifecycleStatus(
                taskID,
                to: failureStatus,
                message: wasUserInterrupted ? nil : (hasPendingBlockingQuestion ? "Waiting for your saved question to be answered." : (hasPendingNonBlockingQuestion ? "A saved question is available for your response." : safeFailureMessage))
            )
            PlayhouseDiagnostics.record("conversation.send.failed", fields: fields)
            if hideSensitiveRecoveryPrompt || isPlayhouseNudge || !sensitiveUserInputAnswerValues.isEmpty {
                throw BridgeCommandError(code: "operation_failed", message: safeFailureMessage)
            }
            throw error
        }
        await titleGeneration?.value
        let finalHistory = try await history(
            taskID: taskID,
            onActionRequest: {
            onUpdate(ConversationUpdate(type: "action_notice", message: approvalNotice))
            },
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            messageLimit: historyMessageLimit,
            includesImageData: true
        )
        onUpdate(ConversationUpdate(type: "completed", history: standaloneChatDisplayHistory(taskID: taskID, finalHistory)))
        return finalHistory
    }
}
