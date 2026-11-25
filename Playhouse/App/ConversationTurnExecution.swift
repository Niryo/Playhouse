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
        // Only a stopping outcome counts; the legacy `in-progress` parses to none.
        let report = TurnOutcome.parseStoredReport(try await tasks.finishConversationTurnOutcome(taskID) ?? recording.leakedOutcome)
        let reportedOutcome = report?.outcome.rawValue
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
                    _ = try await tasks.setLifecycleStatus(taskID, to: .review)
                    // The pull request mode plugin opens the PRs the move asks for.
                    phase = "review-auto-pr"
                    await PluginServiceHost.settle(taskID: taskID)
                }
            case .waitingResponse:
                _ = try await tasks.setLifecycleStatus(taskID, to: .waitingResponse)
            case .blocked:
                _ = try await tasks.setLifecycleStatus(
                    taskID, to: .blocked, message: report?.reason ?? "The agent reported the work as blocked without giving a reason."
                )
            }
        } else if !deferMissingOutcomeStatus {
            _ = try await tasks.setLifecycleStatus(taskID, to: .waitingResponse)
        }
    }

    /// Removes the latest turn when it got no further than its user message, with this text (as
    /// sent, mentions expanded) and exactly these images: a send that failed before its provider produced anything. Writes load
    /// messages without their images, so the turn is first read with them.
    func discardUnansweredTurn(taskID: UUID, text: String, imageDataURLs: [String]) {
        guard let latest = (try? transcripts.read(taskID, turns: .latest, includeImages: true))?.turns.last,
              latest.activities.isEmpty, latest.messages.count == 1, let only = latest.messages.first,
              only.role == .user, only.imageDataURLs == imageDataURLs,
              MentionText.sameUserText(only.text, text) else { return }
        try? transcripts.mutate(taskID, turns: .latest) { transcript in
            transcript.turns.removeAll { $0.id == latest.id && $0.activities.isEmpty && $0.messages.count == 1 }
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
        startsNewChatPage: Bool = false,
        onTurnStarting: (() -> Void)?,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void,
        historyMessageLimit: Int? = nil
    ) async throws -> ConversationHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The transcript keeps a recovery prompt as sent; the task's saved prompt, which is
        // task state rather than conversation, holds a stand-in for the answers it carries.
        let savedPromptText = hideSensitiveRecoveryPrompt ? PrivatePromptPlaceholder.recoveryAnswer : normalizedText
        // The provider and the transcript get the mention block; the task's own prompt, title and
        // worktree names keep what was typed.
        let typedText = MentionText.displayText(savedPromptText)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        var task = try tasks.conversationSubject(taskID)
        let provider = task.conversationProvider
        let client = clients.client(for: provider)
        let modelID = try requestedModelID ?? self.modelID(taskID: taskID) ?? provider.defaultModelID
        guard Self.isValidModelID(modelID) else {
            throw BridgeCommandError(code: "invalid_argument", message: ConversationManager.invalidModelIDMessage)
        }
        // A Done task keeps its conversation; a follow-up reopens it below, once validated.
        let availableRoots = Self.launchRoots(task).compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
        let validationWorkspace = try ConversationWorkspaceContext(roots: availableRoots, rootlessDirectory: settingsManager.defaultParentFolderURL)
        let effort = ConversationEffort(rawValue: task.conversationEffort) ?? .medium
        try await client.validateEffort(effort, modelID: modelID, workspace: validationWorkspace)
        if requestedModelID != nil {
            try await setModelID(taskID: taskID, modelID: modelID)
        }
        try tasks.prepareConversationTurnOutcome(taskID)
        defer { tasks.clearConversationTurnOutcome(taskID) }
        // Stop and steer requests wait on this launch until the provider turn exists.
        ConversationTurnLaunch.begin(taskID)
        defer { ConversationTurnLaunch.end(taskID) }
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
                _ = try await tasks.savePrompt(taskID, prompt: savedPromptText, status: .inProgress, submitted: true)
            }
            // A task with explicit workspace roots is self-contained and may be
            // sent through CLI/XPC before the UI has initialized the global
            // default-parent setting. Rootless tasks still require that setting,
            // except standalone chat, which has no repository at all and must stay
            // usable even when no default repository parent is configured.
            repositoryRoot = task.isStandaloneChat ? nil : try (Self.launchRoots(task)
                .compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
                .first ?? settingsManager.requireRepositoryRootFolder())
            try ConversationTurnLaunch.checkStop(taskID)
            if !isPlayhouseNudge && !reopensDoneTask {
                _ = try await tasks.savePrompt(taskID, prompt: savedPromptText, status: .inProgress, submitted: true)
            }
            // Resolve the first submitted prompt's title before preparing any
            // repositories. The app's model context can lag repository changes
            // made through the bridge, so using this snapshot to detect an auto
            // branch can otherwise allocate "untitled-task" before the generated
            // title arrives.
            let titleMustPrecedeAutoWorktree = task.repositoryWorktrees.contains {
                $0.isPending && RepositoryWorktreeRecord.isAutomaticBranch($0.branch)
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
                    let titleWorkspace = try ConversationWorkspaceContext(roots: titleRoots, rootlessDirectory: settingsManager.defaultParentFolderURL)
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
                try ConversationTurnLaunch.checkStop(taskID)
            }
            // A standalone chat owns no repositories, so there is no worktree to prepare.
            if !task.isStandaloneChat && task.authoringPluginID == nil {
                task = try await tasks.prepareRepositoryWorktrees(
                    taskID,
                    fallbackPrompt: isPlayhouseNudge && !task.hasUnsentDraft ? (task.savedPrompt ?? typedText) : typedText,
                    resolvedTitle: resolvedWorktreeTitle ?? typedText
                )
            }
            try ConversationTurnLaunch.checkStop(taskID)
            if !isPlayhouseNudge, !normalizedText.isEmpty {
                _ = try await tasks.savePrompt(taskID, prompt: typedText, status: .inProgress, submitted: true)
            }
            let roots = Self.launchRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) }
            workspace = try launchWorkspace(for: task, roots: roots, message: normalizedText)
            _ = try await tasks.clearProgressReport(taskID)
            try ConversationTurnLaunch.checkStop(taskID)
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
            // composer as the unsent draft. A stop the user asked for while the turn
            // was still being prepared ends the same way, and never In Progress.
            let restoredStatus = ConversationTurnLaunch.isStoppedBeforeStart(error) && priorStatus == .inProgress
                ? .waitingResponse
                : priorStatus
            _ = try? await tasks.setLifecycleStatus(taskID, to: restoredStatus, message: priorStatusMessage)
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
            try ConversationTurnLaunch.checkStop(taskID)
            // A standalone chat page is its own context, so its recovery transcript is that page
            // alone, rebuilding the session that already held it; task conversations still hand
            // off their whole visible history.
            if task.isStandaloneChat, startsNewChatPage {
                // The user's New page: this turn runs on a page of its own, in a fresh session
                // that never receives the last page's turns.
                let page = try tasks.standaloneChatManager(for: taskID).startUserNewPage(provider: provider.rawValue)
                PlayhouseDiagnostics.record("chat.page.user_new_page", fields: [
                    "taskID": taskID.uuidString, "pageID": page.id, "provider": provider.rawValue
                ])
                onUpdate(ConversationUpdate(type: "chat_page_updated"))
            } else if task.isStandaloneChat, !isPlayhouseNudge, userInputAnswers.isEmpty, !hideSensitiveRecoveryPrompt,
                      try tasks.standaloneChatManager(for: taskID).discardUnstartedUserNewPage() {
                // A message the user sent without New page continues the page before an empty New
                // page an earlier failed send left; Playhouse's own nudges and answers to the agent's
                // questions belong to the turn they follow and leave it alone.
                PlayhouseDiagnostics.record("chat.page.user_new_page_discarded", fields: [
                    "taskID": taskID.uuidString, "provider": provider.rawValue
                ])
                onUpdate(ConversationUpdate(type: "chat_page_updated"))
            }
            let standaloneChatPage = task.isStandaloneChat ? standaloneChatActivePage(taskID: taskID) : nil
            let sessionRecoveryContext: String?
            if let standaloneChatPage {
                sessionRecoveryContext = standaloneChatPageContext(taskID: taskID, headerPageID: nil, fullPageIDs: [standaloneChatPage.id])
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
                    pluginName: (task as? StandaloneChat)?.pluginAuthoringName,
                    pluginPresentation: (task as? StandaloneChat)?.pluginAuthoringPresentation,
                    pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory,
                    isOptimizedContext: task.conversationContextMode == .optimized
                )
            }
            var threadID: String
            var resumesExistingSession = false
            // Only a follow-up the user sent rotates the session: Playhouse's own nudges and
            // autopilot prompts, and answers to the agent's questions, continue the session
            // that asked for them.
            let startsOptimizedSession = task.conversationContextMode == .optimized
                && !task.isStandaloneChat && task.authoringPluginID == nil
                && !isPlayhouseNudge && !hideSensitiveRecoveryPrompt && userInputAnswers.isEmpty
                && !normalizedText.hasPrefix(Self.pullRequestAutopilotPromptMarker)
                && !PlayhouseSentMessage.matches(normalizedText)
            var optimizedSeedContext: String?
            // Each page owns its provider session. A page without one starts a fresh session that
            // carries the system prompt plus only that page's turns, so context never accumulates
            // across pages; the task pointer follows the active page's session.
            let pageSessionID = standaloneChatPage?.conversationID(forProvider: provider.rawValue)
            // A fresh page session has none of the page's own turns yet (the turn that opened the
            // page ran in the previous page's session, or another provider ran it). The user's
            // message may well start yet another topic, so it gets only the page metadata header
            // and loads the page itself when the message continues it.
            let standaloneChatHeaderPageID = pageSessionID == nil ? standaloneChatPage?.id : nil
            // Annotations can reference an earlier page; that page travels whole with this turn only.
            let standaloneChatFullPageIDs = contextPageIDs.filter { $0 != standaloneChatPage?.id }
            let standaloneChatSeedContext = standaloneChatPage == nil && contextPageIDs.isEmpty
                ? nil
                : standaloneChatPageContext(taskID: taskID, headerPageID: standaloneChatHeaderPageID, fullPageIDs: standaloneChatFullPageIDs)
            if let standaloneChatPage, pageSessionID == nil {
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: standaloneChatInstructions()
                )
                phase = "thread-persistence"
                try? tasks.standaloneChatManager(for: taskID).setProviderSession(
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
            } else if let existing = task.activeConversationID, startsOptimizedSession,
                      // A Codex goal belongs to its thread; rotating would strand it, so a task
                      // pursuing one keeps its thread until the goal is cleared.
                      await !Self.threadHasGoal(existing, provider: provider, clients: clients, workspace: workspace) {
                // Optimized context: a follow-up starts like a first message, in a fresh session
                // seeded with the conversation's outline and the user's own messages, and the
                // agent reads anything else it needs by position.
                optimizedSeedContext = ConversationHandoff.optimizedFollowUpContext(
                    taskID: taskID,
                    timeline: ConversationTimeline(transcript: try transcripts.read(taskID, turns: .all, includeImages: false))
                )
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: standaloneChatInstructions()
                )
                phase = "thread-persistence"
                _ = try await tasks.persistConversationID(taskID, provider: provider, id: threadID, replacing: existing)
                persistedThreadID = threadID
                PlayhouseDiagnostics.record("conversation.optimized_session_started", fields: [
                    "taskID": taskID.uuidString,
                    "provider": provider.rawValue,
                    "replacedThreadID": existing,
                    "threadID": threadID,
                    "seeded": optimizedSeedContext == nil ? "false" : "true"
                ])
                phase = "thread-start"
            } else if let existing = task.activeConversationID {
                threadID = existing
                resumesExistingSession = true
            } else {
                // A provider's first session in an optimized task that already has turns (after a
                // provider switch) gets the optimized seed rather than the whole visible history.
                if startsOptimizedSession {
                    optimizedSeedContext = ConversationHandoff.optimizedFollowUpContext(
                        taskID: taskID,
                        timeline: ConversationTimeline(transcript: try transcripts.read(taskID, turns: .all, includeImages: false))
                    )
                }
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: standaloneChatInstructions()
                )
                phase = "thread-persistence"
                _ = try await tasks.persistConversationID(taskID, provider: provider, id: threadID)
                persistedThreadID = threadID
            }
            // A thread the provider no longer has is replaced by a new one that receives the
            // conversation from Playhouse's own transcript with this turn's prompt.
            var missingThreadRecoveryContext: String?
            if resumesExistingSession || pageSessionID != nil,
               try await !client.loadThreadForSend(
                threadID: threadID, workspace: workspace, modelID: modelID,
                developerInstructions: standaloneChatInstructions(),
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt
               ) {
                let missingThreadID = threadID
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: standaloneChatInstructions()
                )
                phase = "thread-persistence"
                if let standaloneChatPage {
                    try? tasks.standaloneChatManager(for: taskID).setProviderSession(
                        pageID: standaloneChatPage.id, provider: provider.rawValue, sessionID: threadID
                    )
                }
                _ = try await tasks.persistConversationID(
                    taskID, provider: provider, id: threadID, replacing: missingThreadID
                )
                persistedThreadID = threadID
                resumesExistingSession = false
                missingThreadRecoveryContext = standaloneChatPage == nil
                    ? ConversationHandoff.context(for: provider, messages: Self.withoutNudgeTurns(try await history(taskID: taskID).messages))
                    : sessionRecoveryContext
                PlayhouseDiagnostics.record("conversation.thread.replaced_missing", fields: [
                    "taskID": taskID.uuidString,
                    "provider": provider.rawValue,
                    "missingThreadID": missingThreadID,
                    "threadID": threadID
                ])
                phase = "thread-start"
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
                let state: ClaudeSessionCacheState? = switch provider {
                case .claude: claudeSessionCacheState(sessionID: threadID)
                case .codex: codexCompactionState(taskID: taskID, threadID: threadID)
                case .opencode: await clients.opencode.compactionState(sessionID: threadID, workspace: workspace)
                }
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
                        isPluginEditor: task.authoringPluginID != nil,
                        isArchived: task.status == .done,
                        pluginPlacement: task.authoringPluginPlacement,
                        pluginID: task.authoringPluginID,
                        pluginName: (task as? StandaloneChat)?.pluginAuthoringName,
                        pluginPresentation: (task as? StandaloneChat)?.pluginAuthoringPresentation,
                        pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory,
                        isOptimizedContext: task.conversationContextMode == .optimized
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
                        compactedBeforeTurn = await runProviderAutomaticCompaction(
                            provider: provider, taskID: taskID, threadID: threadID, trigger: trigger, state: state,
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
            // The last point where nothing of this turn exists yet: past it the message is
            // recorded and sent, and a stop interrupts the provider turn instead.
            try ConversationTurnLaunch.checkStop(taskID)
            // Every turn is recorded locally, whichever provider runs it: the transcript is
            // Playhouse's own and never read back from a provider.
            let localTurnID = UUID().uuidString.lowercased()
            if let segment {
                try transcripts.mutate(taskID, turns: .none) { transcript in
                    if !isPlayhouseNudge { transcript.latestDiff = nil }
                    if mode == .plan { transcript.planTurnIDs = (transcript.planTurnIDs ?? []) + [localTurnID] }
                    if optimizedSeedContext != nil {
                        transcript.freshSessionTurnIDs = (transcript.freshSessionTurnIDs ?? []) + [localTurnID]
                    }
                    transcript.turns.append(.init(id: localTurnID, segmentID: segment.segmentID, messages: [ConversationMessage(
                        id: "\(localTurnID)-user", role: .user, text: normalizedText, imageDataURLs: imageDataURLs,
                        turnID: localTurnID, provider: provider, createdAt: .now, modelID: modelID
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
                segment: segment, turnID: localTurnID,
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
            installStoppingOutcomeProbe(taskID: taskID, client: client, threadID: threadID)
            try await client.sendMessage(
                ConversationHandoff.prompt(
                    normalizedText,
                    // The recovered transcript already holds what a provider-switch handoff carries.
                    // An optimized seed already holds every visible turn a provider switch would hand off.
                    context: [missingThreadRecoveryContext ?? optimizedSeedContext ?? segment?.handoff, standaloneChatSeedContext]
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
                    pluginName: (task as? StandaloneChat)?.pluginAuthoringName,
                    pluginPresentation: (task as? StandaloneChat)?.pluginAuthoringPresentation,
                    pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory,
                    isOptimizedContext: task.conversationContextMode == .optimized
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
                onRecordedFinalMessage: callbacks.onRecordedFinalMessage,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt
            )
            if let segment {
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
            if ConversationTurnLaunch.isStoppedBeforeStart(error) {
                // Stopped before anything reached the provider: the message returns to the
                // composer as the unsent draft and the task waits for the user.
                _ = try? await tasks.setLifecycleStatus(
                    taskID,
                    to: priorStatus == .inProgress ? .waitingResponse : priorStatus,
                    message: priorStatusMessage
                )
                if !isPlayhouseNudge { try? await tasks.returnUnsentSubmittedPromptToDraft(taskID) }
                PlayhouseDiagnostics.record("conversation.send.stopped_before_start", fields: [
                    "taskID": taskID.uuidString,
                    "provider": provider.rawValue,
                    "phase": phase
                ])
                throw error
            }
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
            // A turn its task's deletion stopped fails on purpose.
            if TaskDeletion.isDeleting(taskID) { fields["stoppedForTaskDeletion"] = "true" }
            fields.merge(client.diagnosticFields(forThread: persistedThreadID ?? "", [:])) { _, new in new }
            let wasUserInterrupted = persistedThreadID.map { client.wasLastTurnInterrupted(threadID: $0) } ?? false
            let shouldKeepWaiting = wasUserInterrupted
            let safeFailureMessage = hideSensitiveRecoveryPrompt || isPlayhouseNudge
                ? (isPlayhouseNudge
                    ? "The private status nudge could not be completed."
                    : "The private answer could not be applied. Please answer the question again.")
                : error.localizedDescription
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
            messageLimit: historyMessageLimit,
            includesImageData: true
        )
        onUpdate(ConversationUpdate(type: "completed", history: finalHistory))
        return finalHistory
    }

    /// Whether the provider's thread is pursuing a goal (active or paused). Only Codex has goals.
    static func threadHasGoal(
        _ threadID: String, provider: ConversationProvider, clients: ConversationClients, workspace: ConversationWorkspaceContext
    ) async -> Bool {
        guard provider.supportsGoals else { return false }
        return ((try? await clients.codex.getGoal(threadID: threadID, workspace: workspace)) ?? nil) != nil
    }
}
