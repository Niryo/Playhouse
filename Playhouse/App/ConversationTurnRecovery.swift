import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func resumeReattachedRuns(storeDirectory: String?) async {
        guard let storeDirectory else { return }
        if let scan = Self.reattachScans[storeDirectory] {
            await scan.value
            return
        }
        let scan = Task { @MainActor in await self.reattachCutOffTurns(storeDirectory: URL(fileURLWithPath: storeDirectory, isDirectory: true)) }
        Self.reattachScans[storeDirectory] = scan
        await scan.value
    }

    func reattachCutOffTurns(storeDirectory: URL) async {
        let codexRuns = CodexSharedServer.runsDirectory(dataDirectory: storeDirectory)
        await Self.stopUntrackedAgents(storeDirectory: storeDirectory)
        // A dead server leaves only its files.
        var liveServers: [(server: CodexSharedServer, manifest: CodexServerManifest)] = []
        for entry in CodexSharedServer.manifests(in: codexRuns, serviceName: AgentRunService.name) {
            if entry.manifest.process?.isAlive == true {
                liveServers.append(entry)
            } else if entry.manifest.state != "spawning" || Date().timeIntervalSince(entry.manifest.createdAt) > 30 {
                entry.server.removeFiles(socketPath: entry.manifest.socketPath)
            }
        }
        var followed = Set<UUID>()
        for taskID in tasks.tasksWithCutOffTurns() {
            guard let task = try? tasks.conversationSubject(taskID) else {
                tasks.clearConversationTurnOutcome(taskID)
                continue
            }
            var attached = false
            if task.conversationProvider == .codex, let threadID = task.codexThreadID,
               let live = liveServers.first(where: { $0.manifest.threads[threadID] != nil }),
               let client = CodexAppServerClient.sharedClient(for: live.server, runDirectory: storeDirectory) {
                attached = await reattachTurn(taskID: taskID, client: client, threadID: threadID)
            } else if task.conversationProvider == .claude, let sessionID = task.claudeSessionID {
                attached = await reattachTurn(taskID: taskID, client: clients.claude, threadID: sessionID)
            }
            if attached { followed.insert(taskID) } else { await settleTurnLostInRestart(taskID: taskID) }
        }
        await recoverUnfiledStandaloneChatTurnsAtStartup(skipping: followed)
        for live in liveServers {
            await CodexAppServerClient.sharedClient(for: live.server, runDirectory: storeDirectory)?.adoptSharedServer()
        }
        // A run whose task has no cut-off turn left is one whose turn already settled.
        let claudeRuns = ClaudeRunFiles.runsDirectory(dataDirectory: storeDirectory)
        for run in ClaudeRunFiles.runs(in: claudeRuns) where !ClaudeCodeClient.hasActiveRunner(sessionID: run.manifest.sessionID) {
            await ClaudeAgentRun.attach(directory: run.directory)?.terminateAndRemove()
        }
    }

    /// Stops agent processes of this data folder that no run or server manifest accounts for:
    /// a daemon killed between starting an agent and recording it would leave it running unseen.
    static func stopUntrackedAgents(storeDirectory: URL) async {
        let codexRuns = CodexSharedServer.runsDirectory(dataDirectory: storeDirectory)
        let claudeRuns = ClaudeRunFiles.runsDirectory(dataDirectory: storeDirectory)
        var known = Set<AgentProcessIdentity>()
        // A spawn still being recorded has no identity yet; what writes into its files is its own.
        var spawning: [String] = []
        // Every service's manifests count: a process another service recorded is not untracked.
        for entry in CodexSharedServer.manifests(in: codexRuns, serviceName: nil) {
            if let process = entry.manifest.process { known.insert(process) }
            if entry.manifest.process == nil, Date().timeIntervalSince(entry.manifest.createdAt) < 30 {
                spawning.append(entry.server.logURL.resolvingSymlinksInPath().path)
            }
        }
        for run in ClaudeRunFiles.runs(in: claudeRuns, serviceName: nil) {
            if let process = run.manifest.process { known.insert(process) }
            if run.manifest.process == nil, Date().timeIntervalSince(run.manifest.createdAt) < 30 {
                spawning.append(run.directory.resolvingSymlinksInPath().path + "/")
            }
        }
        let found = await Task.detached {
            AgentProcessSweep.processes(withStandardStreamsUnder: [codexRuns.path, claudeRuns.path])
        }.value.filter { process in
            !spawning.contains { process.path == $0 || process.path.hasPrefix($0) }
        }
        // A helper a recorded agent started shares its log and is that agent's to stop.
        var trackedPIDs = Set(known.map(\.pid))
        var untracked = found.filter { !known.contains($0.identity) }
        var grew = true
        while grew {
            grew = false
            for process in untracked where trackedPIDs.contains(process.parentPID) {
                trackedPIDs.insert(process.identity.pid)
                grew = true
            }
            untracked.removeAll { trackedPIDs.contains($0.identity.pid) }
        }
        for process in untracked {
            PlayhouseDiagnostics.record("agent.untracked.stopped", fields: [
                "processID": String(process.identity.pid),
                "path": process.path,
            ])
            await AgentRunHost.terminate(process.identity)
        }
    }

    /// A cut-off turn whose agent didn't survive: it waits for the user, with its conversation
    /// kept, rather than staying In Progress with nothing behind it.
    func settleTurnLostInRestart(taskID: UUID) async {
        defer { tasks.clearConversationTurnOutcome(taskID) }
        guard let task = try? tasks.conversationSubject(taskID), task.status == .inProgress else { return }
        if let pending = try? transcripts.readState(taskID).pendingUserInputRequest, pending.threadID == task.activeConversationID {
            // A saved question stays answerable, as when the task is reconciled on open.
            return
        }
        _ = try? await tasks.setLifecycleStatus(taskID, to: .waitingResponse, message: Self.interruptedByRestartMessage)
        try? await tasks.clearPendingSubmittedPrompt(taskID)
        PlayhouseDiagnostics.record("conversation.turn.lost_in_restart", fields: ["taskID": taskID.uuidString])
        Self.bumpVisibleRevision(taskID)
    }

    /// Follows one cut-off turn in the background, holding its turn reservation as a send would,
    /// and returns once the turn is this daemon's own (true) or turned out to have no agent (false).
    func reattachTurn(taskID: UUID, client: ConversationProviderClient, threadID: String) async -> Bool {
        guard let task = try? tasks.conversationSubject(taskID),
              let workspace = try? launchWorkspace(for: task, roots: task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }) else {
            return false
        }
        let provider = task.conversationProvider
        let attached = AsyncFlag()
        BridgeBackgroundWork.start {
            let onUpdate: (ConversationUpdate) -> Void = { update in
                if Self.historyVisibleUpdateTypes.contains(update.type) { Self.bumpVisibleRevision(taskID) }
                ConversationTurnEvents.publish(taskID, update)
            }
            var followed = false
            do {
                try await self.tasks.withConversationTurnReservation(taskID) {
                    ConversationTurnEvents.begin(taskID)
                    defer { ConversationTurnEvents.end(taskID) }
                    defer { Self.bumpVisibleRevision(taskID) }
                    followed = try await self.followReattachedTurn(
                        taskID: taskID, provider: provider, client: client, threadID: threadID,
                        workspace: workspace, attached: attached, onUpdate: onUpdate
                    )
                }
            } catch {
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["taskID"] = taskID.uuidString
                PlayhouseDiagnostics.record("conversation.turn.reattach_failed", fields: fields)
            }
            attached.set(false)
            if followed, !Self.dispatchingQueuedTaskIDs.contains(taskID) {
                await self.dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: nil, onUpdate: onUpdate, onUserInput: { _ in })
            }
        }
        return await attached.value
    }

    /// Runs inside the task's turn reservation. Returns whether a turn was followed to its end.
    func followReattachedTurn(
        taskID: UUID,
        provider: ConversationProvider,
        client: ConversationProviderClient,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        attached: AsyncFlag,
        onUpdate: @escaping (ConversationUpdate) -> Void
    ) async throws -> Bool {
        try tasks.activateConversationTurnOutcome(taskID)
        defer { tasks.clearConversationTurnOutcome(taskID) }
        let transcript = try transcripts.readState(taskID)
        let segment = transcript.segments.last.map { (segmentID: $0.id, handoff: String?.none) }
        // Claude records its turn locally; the reattached run carries on in the turn it started,
        // the transcript's newest, since a task runs one turn at a time.
        let claudeTurn = provider == .claude ? try transcripts.read(taskID, turns: .all, includeImages: false).turns.last : nil
        let claudeTurnID = claudeTurn?.id
        let recording = TurnRecording()
        // Final answers are numbered within their turn; carry on after the ones already recorded.
        recording.finalMessageCount = claudeTurn.map { turn in
            turn.messages.filter { $0.id.hasPrefix("\(turn.id)-final-") }.count
        } ?? 0
        let modelID = (try? modelID(taskID: taskID)) ?? nil
        let callbacks = turnCallbacks(
            taskID: taskID, provider: provider, client: client, threadID: threadID,
            modelID: modelID ?? provider.defaultModelID,
            segment: segment, claudeTurnID: claudeTurnID,
            hideSensitiveRecoveryPrompt: false, sensitiveUserInputAnswerValues: [],
            isPlayhouseNudge: transcript.activeTurnIsPlayhouseNudge == true, userInputAnswers: [:], recording: recording,
            onUpdate: onUpdate, onUserInput: { _ in }
        )
        let result: ConversationReattachResult
        var phase = "\(provider.rawValue)-reattached-turn"
        do {
            result = try await client.followReattachedTurn(
                threadID: threadID, workspace: workspace, callbacks: callbacks,
                onAttached: { attached.set(true) }
            )
        } catch {
            attached.set(true)
            for (activityID, durationMs) in client.lastTurnActivityDurations(threadID: threadID) {
                try? await tasks.recordConversationActivityDuration(taskID: taskID, activityID: activityID, durationMs: durationMs)
            }
            let pendingQuestion = try? transcripts.readState(taskID).pendingUserInputRequest
            let status: TaskStatus
            let message: String?
            if client.wasLastTurnInterrupted(threadID: threadID) {
                (status, message) = (.waitingResponse, nil)
            } else if let pendingQuestion {
                (status, message) = pendingQuestion.isBlocking
                    ? (.waitingResponse, "Waiting for your saved question to be answered.")
                    : (.inProgress, "A saved question is available for your response.")
            } else {
                (status, message) = (.waitingResponse, Self.interruptedByRestartMessage)
            }
            _ = try? await tasks.setLifecycleStatus(taskID, to: status, message: message)
            try? await tasks.clearPendingSubmittedPrompt(taskID)
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            fields["phase"] = phase
            PlayhouseDiagnostics.record("conversation.reattached_turn.failed", fields: fields)
            // A chat turn whose agent died with no daemon following it is filed with what it
            // wrote, on the page its close-turn named, so its page doesn't start empty.
            // Its question is filed even with no answer saved: its in-flight record says it ran.
            await recoverUnfiledStandaloneChatTurns(taskID: taskID, reason: "reattach-lost")
            onUpdate(ConversationUpdate(type: "completed", history: try? await history(taskID: taskID, includesImageData: true)))
            return false
        }
        switch result {
        case .agentGone, .notRunning:
            return false
        case .finished:
            break
        }
        PlayhouseDiagnostics.record("conversation.reattached_turn.finished", fields: [
            "taskID": taskID.uuidString,
            "provider": provider.rawValue,
        ])
        lastReportedTurnOutcomeByTaskID.removeValue(forKey: taskID)
        try await settleFinishedTurn(
            taskID: taskID, client: client, threadID: threadID, recording: recording,
            deferMissingOutcomeStatus: true, phase: &phase
        )
        // A chat gets no nudge here: the daemon that sent the turn is gone, and with it the
        // signal count it took at the start, so a reattached chat turn leaves a missed page
        // decision to the background classifier, which the filing below schedules.
        let subject = try? tasks.conversationSubject(taskID)
        let chat = subject.flatMap { $0.isStandaloneChat ? $0 : nil }
        if subject?.authoringPluginID != nil {
            if (try? transcripts.readState(taskID).pendingUserInputRequest) == nil {
                _ = try await tasks.setLifecycleStatus(taskID, to: .waitingResponse)
            }
        } else if chat == nil {
            try await driveUnsettledTurns(
                taskID: taskID, isStandaloneChat: false, mode: .code, modelID: nil,
                client: client, onUpdate: onUpdate, onUserInput: { _ in }
            )
        }
        lastReportedTurnOutcomeByTaskID.removeValue(forKey: taskID)
        try? await tasks.clearPendingSubmittedPrompt(taskID)
        let finalHistory = try await history(taskID: taskID, includesImageData: true)
        // The followed turn may be the chat's close-turn nudge, which is never filed: the turn
        // it belongs to is the newest one the user sent.
        if let chat, let turnID = finalHistory.messages.last(where: {
            $0.role == .user && !PrivateOutcomeNudgeMarker.matches($0.text) && !ProviderAutomaticNotice.matches($0.text)
        })?.turnID {
            fileReattachedStandaloneChatTurn(chat: chat, history: finalHistory, turnID: turnID, onUpdate: onUpdate)
        }
        onUpdate(ConversationUpdate(type: "completed", history: standaloneChatDisplayHistory(taskID: taskID, finalHistory)))
        return true
    }

    /// A turn that ends unsettled is driven forward privately: `in-progress` asks for a
    /// continuation, and a turn that reported nothing is nudged to say where it stands. Shared by
    /// a sent turn and a turn this daemon reattached after a restart.
    func driveUnsettledTurns(
        taskID: UUID,
        isStandaloneChat: Bool,
        mode: ConversationMode,
        modelID: String?,
        client operationClient: ConversationProviderClient,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void
    ) async throws {
        // A turn that ends unsettled is driven forward privately rather
        // than dropped on the board: `in-progress` asks for a
        // continuation outright, and a turn that reported nothing is
        // nudged to say where it stands.
        var continuations = 0
        var stoppedForUser = false
        var continuationFailed = false
        // A standalone chat settles a turn with its close-turn page signal. It gets one
        // visible reminder to send that signal; a chat has nothing to continue, and a page
        // decision still missing after the reminder falls to the background classifier.
        let maxAttempts = isStandaloneChat ? 1 : TurnOutcome.maxContinuations
        while continuations < maxAttempts {
            // A question the model raised settles the turn on the
            // user; nudging past it would talk over them.
            guard (try? self.transcripts.readState(taskID).pendingUserInputRequest) == nil else { break }
            // The user taking over ends Playhouse's private driving.
            // A continuation tells the model to resume working, so
            // without this it could undo a Stop or run ahead of a
            // queued follow-up up to the continuation limit.
            if self.userTookOverConversation(taskID: taskID, client: operationClient) {
                stoppedForUser = true
                break
            }
            let reported = self.lastReportedTurnOutcomeByTaskID[taskID].flatMap(TurnOutcome.init(rawValue:))
            guard reported == nil || (reported == .inProgress && !isStandaloneChat) else { break }
            continuations += 1
            let prompt = isStandaloneChat
                ? Self.chatPageCloseTurnNudgePrompt(chatID: taskID)
                : reported == .inProgress
                    ? Self.outcomeContinuationPrompt(attempt: continuations)
                    : Self.outcomeNudgePrompt(attempt: continuations)
            do {
                _ = try await self.sendReserved(
                    taskID: taskID,
                    text: prompt,
                    imageDataURLs: [],
                    mode: mode,
                    requestedModelID: modelID,
                    userInputAnswers: [:],
                    sensitiveUserInputAnswerValues: [],
                    hideSensitiveRecoveryPrompt: false,
                    isPlayhouseNudge: true,
                    deferMissingOutcomeStatus: true,
                    statusBeforeSubmission: nil,
                    // An internal reminder quotes no chat page of its own.
                    contextPageIDs: [],
                    onTurnStarting: nil,
                    onUpdate: onUpdate,
                    onUserInput: onUserInput
                )
            } catch {
                // A Stop lands as a thrown turn, so the throw alone
                // can't tell a user takeover from a provider failure.
                // Only the latter is Playhouse's to report.
                if self.userTookOverConversation(taskID: taskID, client: operationClient) {
                    stoppedForUser = true
                } else {
                    continuationFailed = true
                }
                break
            }
        }
        let settled = self.lastReportedTurnOutcomeByTaskID[taskID].flatMap(TurnOutcome.init(rawValue:))
        let waitingOnUser = (try? self.transcripts.readState(taskID).pendingUserInputRequest) != nil
        if !isStandaloneChat, !stoppedForUser, !waitingOnUser, settled == nil || settled == .inProgress {
            // The work is unsettled and the user was never asked
            // anything, so Waiting Response would misreport this.
            // Blocked says Playhouse stopped driving, and the reason
            // says why.
            let reason: String
            if continuationFailed {
                reason = "Playhouse couldn't run the private turn that would continue this work. Send a message to pick the work up again."
            } else if settled == .inProgress {
                reason = "Still working after \(TurnOutcome.maxContinuations) continuation turns. Send a message to pick the work up again."
            } else {
                reason = "The turn ended without reporting an outcome, and \(TurnOutcome.maxContinuations) status nudges went unanswered. Send a message to pick the work up again."
            }
            _ = try await self.tasks.setLifecycleStatus(taskID, to: .blocked, message: reason)
        }
    }

    /// Whether the user has taken this conversation back from Playhouse's /// continuation loop, either by stopping the turn or by queueing a follow-up.
    /// Only messages still waiting to be sent count: a `needsAction` row the user
    /// has to retry themselves must not suppress the loop forever.
    func userTookOverConversation(taskID: UUID, client: ConversationProviderClient) -> Bool {
        if let threadID = try? tasks.taskModel(taskID).activeConversationID,
           client.wasLastTurnInterrupted(threadID: threadID) {
            return true
        }
        return ((try? tasks.queuedConversationMessages(taskID: taskID)) ?? []).contains { $0.state == .queued }
    }

    /// The page this turn belongs to, creating the first one when the chat is brand new so the
    /// opening turn already runs inside its own page session.
    func standaloneChatActivePage(taskID: UUID) -> StandaloneChatPage? {
        guard let task = try? tasks.conversationSubject(taskID),
              let chatManager = try? tasks.standaloneChatManager() else { return nil }
        if let existing = (try? chatManager.activePage()) ?? nil { return existing }
        return try? chatManager.createPage(
            title: "New conversation",
            provider: task.conversationProvider.rawValue,
            closingCurrentActivePage: false
        )
    }

    /// Renders the given pages' archived turns as one handoff block. This is what keeps a page
    /// standalone: a page session only ever receives its own page (plus any page an annotation
    /// explicitly points at), never the whole chat.
    func standaloneChatPageContext(taskID: UUID, pageIDs: [String]) -> String? {
        guard !pageIDs.isEmpty, let chatManager = try? tasks.standaloneChatManager() else { return nil }
        var messages: [ConversationMessage] = []
        for pageID in pageIDs {
            guard let page = try? chatManager.page(id: pageID),
                  let archived = try? chatManager.messages(pageID: pageID), !archived.isEmpty else { continue }
            messages.append(ConversationMessage(
                id: "chat-page-\(page.id)", role: .user,
                text: "[Page: \(page.title)]", turnID: "chat-page-\(page.id)"
            ))
            messages += archived.map { message in
                ConversationMessage(
                    id: message.id,
                    role: ConversationRole(rawValue: message.role) ?? .user,
                    text: message.text,
                    turnID: message.turnID,
                    provider: ConversationProvider(rawValue: page.provider)
                )
            }
        }
        guard !messages.isEmpty else { return nil }
        let provider = (try? tasks.conversationSubject(taskID))?.conversationProvider ?? .claude
        return ConversationHandoff.context(
            for: provider, messages: messages, preamble: ConversationHandoff.chatPagePreamble
        )
    }

    /// Files a finished chat turn and settles its page decision. Both GUI and CLI sends pass
    /// through here, and so does a turn this daemon took over after a restart. `page` is where
    /// the turn's close-turn put it (nil: the active page); `missedSignal` says no close-turn
    /// ran, so the background classifier decides the page.
    func recordStandaloneChatTurn(
        task: any ConversationSubject,
        chatManager: StandaloneChatManager,
        history: ConversationHistory,
        latestTurnID: String,
        page targetPage: StandaloneChatPage? = nil,
        missedSignal: Bool,
        onUpdate: @escaping (ConversationUpdate) -> Void
    ) {
        // Persist messages and schedule classification before releasing the turn reservation,
        // so a following send can wait for the page decision without overtaking it.
        let page: StandaloneChatPage? = targetPage ?? {
            if let existing = try? chatManager.activePage() { return existing }
            return try? chatManager.createPage(
                title: "New conversation",
                provider: task.conversationProvider.rawValue,
                closingCurrentActivePage: false
            )
        }()
        if let page {
            // Only the turn's own conversation is filed: a provider's automatic notice stays in
            // the transcript but never in a page or the context a page replays.
            let turnMessages = Self.withoutNudgeTurns(history.messages).filter { $0.turnID == latestTurnID }
            // Nothing to file leaves no page decision to make, and a pending one with no
            // question could never resolve.
            guard !turnMessages.isEmpty else { return }
            do {
                // A turn already filed (by startup recovery, say) keeps its page decision.
                guard try chatManager.fileTurn(
                    pageID: page.id, turnID: latestTurnID, messages: Self.standaloneChatTurnMessages(turnMessages)
                ) else { return }
            } catch {
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["taskID"] = task.id.uuidString
                fields["turnID"] = latestTurnID
                PlayhouseDiagnostics.record("chat.page.turn_file_failed", fields: fields)
            }
        }
        guard missedSignal else {
            try? chatManager.setLastTurnMissedSignal(false)
            return
        }
        guard let page else {
            try? chatManager.setLastTurnMissedSignal(true)
            return
        }
        do {
            try chatManager.markPendingFallback(pageID: page.id, turnID: latestTurnID)
        } catch {
            PlayhouseDiagnostics.record("chat.page.fallback.pending_persist_failed", fields: [
                "taskID": task.id.uuidString,
                "turnID": latestTurnID,
                "errorType": String(describing: type(of: error))
            ])
            try? chatManager.setLastTurnMissedSignal(true)
            onUpdate(ConversationUpdate(type: "chat_page_updated"))
            return
        }

        // Make the pending classification visible immediately. The resolver emits the
        // matching update after it has persisted its page/title result.
        onUpdate(ConversationUpdate(type: "chat_page_updated"))
        let currentQuestion = Self.withoutNudgeTurns(history.messages)
            .last(where: { $0.role == .user && $0.turnID == latestTurnID })?.text
        let workspace = try? ConversationWorkspaceContext(roots: [])
        guard let currentQuestion, let workspace else {
            PlayhouseDiagnostics.record("chat.page.fallback.not_scheduled", fields: [
                "hasPage": "true",
                "hasQuestion": String(currentQuestion != nil),
                "hasWorkspace": String(workspace != nil),
                "messageCount": String(history.messages.filter { $0.turnID == latestTurnID }.count)
            ])
            return
        }
        let priorMessages = (try? chatManager.messages(pageID: page.id).filter { $0.turnID != latestTurnID }) ?? []
        let classifierClients = clients.helperClients(preferring: task.conversationProvider)
        let fallbackID = UUID()
        let fallbackTask = Task { @MainActor [self] in
            PlayhouseDiagnostics.record("chat.page.fallback.started", fields: [
                "taskID": task.id.uuidString,
                "turnID": latestTurnID,
                "provider": task.conversationProvider.rawValue
            ])
            await resolveMissedStandalonePageSignal(
                chatManager: chatManager,
                page: page,
                turnID: latestTurnID,
                currentQuestion: currentQuestion,
                priorMessages: priorMessages,
                provider: task.conversationProvider,
                clients: classifierClients,
                workspace: workspace,
                onUpdate: onUpdate
            )
        }
        Self.standalonePageFallbackTasks[task.id] = (fallbackID, fallbackTask)
        PlayhouseDiagnostics.record("chat.page.fallback.scheduled", fields: [
            "taskID": task.id.uuidString,
            "provider": task.conversationProvider.rawValue,
            "clientCount": String(classifierClients.count),
            "turnID": latestTurnID
        ])
    }

    /// What a page keeps of a turn's messages.
    static func standaloneChatTurnMessages(_ messages: [ConversationMessage]) -> [StandaloneChatTurnMessage] {
        messages.map { StandaloneChatTurnMessage(role: $0.role.rawValue, text: $0.text, createdAt: $0.createdAt) }
    }

    /// Files a chat turn this daemon followed to its end after a restart. The daemon that sent
    /// it died before it could, and took the signal count it captured at the start with it, so
    /// the page comes from the close-turn signals kept since the turn began (its in-flight
    /// record, else its first message's time): the last one names the page, and none means a
    /// missed signal, which schedules the background classifier just as a sent turn does.
    func fileReattachedStandaloneChatTurn(
        chat: any ConversationSubject,
        history: ConversationHistory,
        turnID: String,
        onUpdate: @escaping (ConversationUpdate) -> Void
    ) {
        guard let chatManager = try? tasks.standaloneChatManager() else { return }
        let startedAt = ((try? chatManager.inflightTurnStartedAt()) ?? nil)
            ?? history.messages.filter { $0.turnID == turnID }.compactMap(\.createdAt).min()
        let signal = startedAt.flatMap { (try? chatManager.turnSignals(from: $0))?.last }
        let page = signal.flatMap { try? chatManager.page(id: $0.pageID) }
        recordStandaloneChatTurn(
            task: chat,
            chatManager: chatManager,
            history: history,
            latestTurnID: turnID,
            page: page,
            missedSignal: signal == nil,
            onUpdate: onUpdate
        )
        try? chatManager.endTurn()
        let filedPage = (try? chatManager.pageAssignmentsByTurnID())?[turnID]
        PlayhouseDiagnostics.record("chat.page.reattached_turn.filed", fields: [
            "taskID": chat.id.uuidString,
            "turnID": turnID,
            "pageID": filedPage?.id ?? "",
            "signal": signal == nil ? "missed" : "close-turn",
        ])
        onUpdate(ConversationUpdate(type: "chat_page_updated"))
    }

    /// A finished chat turn that no page holds.
    struct UnfiledStandaloneChatTurn {
        let turnID: String
        /// The turn's messages as a page keeps them: nudges and automatic notices left out.
        let messages: [ConversationMessage]
        let startedAt: Date?
        /// When the user's next turn started; nil for the newest turn.
        let nextTurnStartedAt: Date?
        let laterTurnIDs: Set<String>
        let precedingFiledTurnID: String?
    }

    /// The answered turns of a chat transcript that no page holds. Turns from before the chat
    /// filed anything are left alone: a chat that predates pages never filed them, so only a turn
    /// after a filed one was lost. A turn with no answer was a failed send, which no page ever
    /// held. `inFlightSince` is the chat's in-flight record: the newest turn then really ran (its
    /// daemon died before filing it), so it is kept even when it is the chat's first turn or its
    /// agent died before Playhouse saved an answer, and that record is its start time, which a
    /// provider's messages may not carry (Codex). A nudge turn is never a turn of its own: its
    /// time belongs to the turn it reminded, whose close-turn it may have run.
    static func unfiledStandaloneChatTurns(
        _ messages: [ConversationMessage],
        filedTurnIDs: Set<String>,
        inFlightSince: Date? = nil
    ) -> [UnfiledStandaloneChatTurn] {
        var order: [String] = []
        var raw: [String: [ConversationMessage]] = [:]
        for message in messages {
            guard let turnID = message.turnID else { continue }
            if raw[turnID] == nil { order.append(turnID) }
            raw[turnID, default: []].append(message)
        }
        var kept: [String: [ConversationMessage]] = [:]
        for message in withoutNudgeTurns(messages) {
            guard let turnID = message.turnID else { continue }
            kept[turnID, default: []].append(message)
        }
        let userTurns = order.filter { turnID in
            !(raw[turnID] ?? []).contains { $0.role == .user && PrivateOutcomeNudgeMarker.matches($0.text) }
        }
        let inFlightTurnID = inFlightSince == nil ? nil : userTurns.last
        func startedAt(_ turnID: String) -> Date? {
            turnID == inFlightTurnID ? inFlightSince : raw[turnID]?.compactMap(\.createdAt).min()
        }
        guard let start = userTurns.firstIndex(where: filedTurnIDs.contains)
            ?? (inFlightTurnID == nil ? nil : userTurns.count - 1) else { return [] }
        var precedingFiled: String?
        var result: [UnfiledStandaloneChatTurn] = []
        for index in userTurns.indices where index >= start {
            let turnID = userTurns[index]
            if filedTurnIDs.contains(turnID) {
                precedingFiled = turnID
                continue
            }
            let turnMessages = kept[turnID] ?? []
            guard turnID == inFlightTurnID || turnMessages.contains(where: { $0.role == .assistant }),
                  !turnMessages.isEmpty else { continue }
            let next = userTurns.indices.contains(index + 1) ? userTurns[index + 1] : nil
            result.append(UnfiledStandaloneChatTurn(
                turnID: turnID,
                messages: turnMessages,
                startedAt: startedAt(turnID),
                nextTurnStartedAt: next.flatMap(startedAt),
                laterTurnIDs: Set(userTurns[(index + 1)...]),
                precedingFiledTurnID: precedingFiled
            ))
        }
        return result
    }

    /// The chat's turns with their messages. Playhouse keeps Claude turns itself, so they read
    /// without any provider; Codex keeps its turns in its own thread, read only on request.
    func standaloneChatTranscriptMessages(taskID: UUID, readingProviderThread: Bool) async -> [ConversationMessage] {
        if readingProviderThread, (try? tasks.conversationSubject(taskID))?.conversationProvider == .codex {
            return (try? await history(taskID: taskID).messages) ?? []
        }
        let turns = (try? transcripts.read(taskID, turns: .all, includeImages: false).turns) ?? []
        return turns.flatMap { turn in
            turn.messages.map { message in
                var message = message
                message.turnID = turn.id
                return message
            }
        }
    }

    /// The page an unfiled turn belongs on: the page its last close-turn named; for a turn from
    /// before signals were kept, the page its `--continues false` opened while it ran; otherwise
    /// the page of the turn before it, and failing that the active page.
    func standaloneChatRecoveryPage(
        chatManager: StandaloneChatManager,
        turn: UnfiledStandaloneChatTurn,
        assignments: [String: StandaloneChatPage]
    ) -> (page: StandaloneChatPage, source: String)? {
        if let start = turn.startedAt {
            if let signal = (try? chatManager.turnSignals(from: start, to: turn.nextTurnStartedAt))?.last,
               let page = try? chatManager.page(id: signal.pageID) {
                return (page, "close-turn")
            }
            let lastMessageAt = turn.messages.compactMap(\.createdAt).max() ?? start
            let end = min(turn.nextTurnStartedAt ?? .distantFuture, lastMessageAt.addingTimeInterval(120))
            if let page = (try? chatManager.pagesCreated(from: start, to: end))?.last {
                return (page, "page-opened-in-turn")
            }
        }
        if let preceding = turn.precedingFiledTurnID, let page = assignments[preceding] {
            return (page, "preceding-turn-page")
        }
        if let page = (try? chatManager.activePage()) ?? nil { return (page, "active-page") }
        return nil
    }

    /// Files the chat turns no daemon lived to file: a turn in flight when its daemon died, whose
    /// agent then finished or died with no daemon following it. Run while holding the chat's turn
    /// reservation, so no turn is in flight. Filing is idempotent, so a later run files nothing.
    /// The chat's in-flight record is cleared once its turn is on a page.
    @discardableResult
    func recoverUnfiledStandaloneChatTurns(
        taskID: UUID,
        reason: String,
        readingProviderThread: Bool = true
    ) async -> Int {
        guard (try? tasks.conversationSubject(taskID))?.isStandaloneChat == true,
              let chatManager = try? tasks.standaloneChatManager(),
              let filed = try? chatManager.filedTurnIDs() else { return 0 }
        let messages = await standaloneChatTranscriptMessages(taskID: taskID, readingProviderThread: readingProviderThread)
        let inFlightSince = (try? chatManager.inflightTurnStartedAt()) ?? nil
        defer {
            // The record names the newest turn; once that turn is filed it has done its job.
            if inFlightSince != nil, let newest = messages.last(where: { $0.role == .user && !PrivateOutcomeNudgeMarker.matches($0.text) })?.turnID,
               (try? chatManager.filedTurnIDs())?.contains(newest) == true {
                try? chatManager.endTurn()
            }
        }
        let unfiled = Self.unfiledStandaloneChatTurns(messages, filedTurnIDs: filed, inFlightSince: inFlightSince)
        guard !unfiled.isEmpty else { return 0 }
        let assignments = (try? chatManager.pageAssignmentsByTurnID()) ?? [:]
        var recovered = 0
        for turn in unfiled {
            guard let target = standaloneChatRecoveryPage(chatManager: chatManager, turn: turn, assignments: assignments) else { continue }
            do {
                guard try chatManager.fileTurn(
                    pageID: target.page.id,
                    turnID: turn.turnID,
                    messages: Self.standaloneChatTurnMessages(turn.messages),
                    laterTurnIDs: turn.laterTurnIDs
                ) else { continue }
                recovered += 1
                PlayhouseDiagnostics.record("chat.page.turn_recovered", fields: [
                    "taskID": taskID.uuidString,
                    "turnID": turn.turnID,
                    "pageID": target.page.id,
                    "source": target.source,
                    "reason": reason,
                    "messageCount": String(turn.messages.count),
                ])
            } catch {
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["taskID"] = taskID.uuidString
                fields["turnID"] = turn.turnID
                fields["reason"] = reason
                PlayhouseDiagnostics.record("chat.page.turn_recovery_failed", fields: fields)
            }
        }
        if recovered > 0 { Self.bumpVisibleRevision(taskID) }
        return recovered
    }

    /// Recovers each chat's unfiled turns when a daemon starts, before it answers any request.
    /// A chat whose cut-off turn this daemon is following is skipped (that turn files itself when
    /// it ends), as is one whose turn another process holds. Only Playhouse's own transcript is
    /// read here, so a start never waits on a provider.
    func recoverUnfiledStandaloneChatTurnsAtStartup(skipping followed: Set<UUID>) async {
        for chatID in tasks.standaloneChatIDs() where !followed.contains(chatID) {
            // Every request waits for this scan, so a chat whose turn is running (a window's own
            // send, say) is left to that send's own recovery rather than waited for.
            _ = try? await tasks.withConversationTurnReservationIfFree(chatID) {
                await self.recoverUnfiledStandaloneChatTurns(taskID: chatID, reason: "startup", readingProviderThread: false)
            }
        }
    }

    func resolvePendingStandalonePageFallback(
        taskID: UUID,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async {
        if let pending = Self.standalonePageFallbackTasks[taskID] {
            await pending.task.value
            if Self.standalonePageFallbackTasks[taskID]?.id == pending.id {
                Self.standalonePageFallbackTasks.removeValue(forKey: taskID)
            }
            return
        }
        guard let task = try? tasks.conversationSubject(taskID), task.isStandaloneChat,
              let chatManager = try? tasks.standaloneChatManager(),
              let missedSignal = try? chatManager.lastTurnMissedSignal() else { return }
        let pending: StandaloneChatPendingFallback? = (try? chatManager.pendingFallback()) ?? nil
        guard missedSignal || pending != nil else { return }
        let page: StandaloneChatPage?
        if let pending {
            page = try? chatManager.page(id: pending.pageID)
        } else {
            page = (try? chatManager.activePage()) ?? nil
        }
        guard let page,
              let messages = try? chatManager.messages(pageID: page.id),
              let latestTurnID = pending?.turnID ?? messages.last?.turnID,
              let currentQuestion = messages.last(where: { $0.role == ConversationRole.user.rawValue && $0.turnID == latestTurnID })?.text,
              let workspace = try? ConversationWorkspaceContext(roots: []) else { return }
        if pending == nil {
            do {
                guard try chatManager.recoverPendingFallbackIfActive(pageID: page.id, turnID: latestTurnID) else { return }
            } catch {
                PlayhouseDiagnostics.record("chat.page.fallback.pending_recovery_failed", fields: [
                    "taskID": taskID.uuidString,
                    "turnID": latestTurnID,
                    "errorType": String(describing: type(of: error))
                ])
                return
            }
        }
        let priorMessages = messages.filter { $0.turnID != latestTurnID }
        await resolveMissedStandalonePageSignal(
            chatManager: chatManager,
            page: page,
            turnID: latestTurnID,
            currentQuestion: currentQuestion,
            priorMessages: priorMessages,
            provider: task.conversationProvider,
            clients: clients.helperClients(preferring: task.conversationProvider),
            workspace: workspace,
            onUpdate: onUpdate
        )
    }

    func resolveMissedStandalonePageSignal(
        chatManager: StandaloneChatManager,
        page: StandaloneChatPage,
        turnID: String,
        currentQuestion: String,
        priorMessages: [StandaloneChatMessage],
        provider: ConversationProvider,
        clients classifierClients: [ConversationProviderClient],
        workspace: ConversationWorkspaceContext,
        onUpdate: @escaping (ConversationUpdate) -> Void
    ) async {
        let classifier = StandaloneChatPageFallbackClassifier(clients: classifierClients)
        guard let result = await classifier.classify(
            currentQuestion: currentQuestion,
            precedingMessages: priorMessages,
            workspace: workspace
        ) else { return }

        do {
            let title = result.decision.title?
                .split(whereSeparator: \.isWhitespace)
                .prefix(8)
                .joined(separator: " ")
            let applied = try chatManager.applyFallbackClassification(
                pageID: page.id,
                turnID: turnID,
                continues: result.decision.continues,
                title: title.flatMap { $0.isEmpty ? nil : $0 },
                provider: provider.rawValue,
                hasPriorUserMessage: priorMessages.contains(where: { $0.role == ConversationRole.user.rawValue })
            )
            guard applied else {
                PlayhouseDiagnostics.record("chat.page.fallback.stale", fields: ["reason": "pending_turn_or_active_page_changed"])
                return
            }
            PlayhouseDiagnostics.record("chat.page.fallback.applied", fields: [
                "provider": result.provider.rawValue,
                "continues": String(result.decision.continues),
                "pageID": page.id
            ])
            onUpdate(ConversationUpdate(type: "chat_page_updated"))
        } catch {
            PlayhouseDiagnostics.record("chat.page.fallback.apply_failed", fields: [
                "provider": result.provider.rawValue,
                "phase": "persist-decision"
            ])
        }
    }

    func dispatchQueuedMessages(
        taskID: UUID,
        mode: ConversationMode,
        modelID: String?,
        onlyMessageID: UUID? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void
    ) async {
        let threadID: String
        do {
            guard let value = try tasks.conversationSubject(taskID).activeConversationID else { return }
            threadID = value
        } catch { return }
        guard Self.dispatchingQueuedTaskIDs.insert(taskID).inserted else {
            Self.pendingQueuedTaskDispatchIDs.insert(taskID)
            return
        }
        var dispatchEncounteredFailure = false
        defer { Self.dispatchingQueuedTaskIDs.remove(taskID) }
        var messageIDFilter = onlyMessageID
        while true {
            while true {
                let item: QueuedConversationMessage?
                do { item = try tasks.claimNextQueuedMessage(taskID: taskID, threadID: threadID, messageID: messageIDFilter) }
                catch { break }
                guard let item else { break }
                // Windows hide a follow-up while it is claimed, so announce the claim
                // and, however delivery ends, its removal or return as needs-action.
                Self.bumpVisibleRevision(taskID)
                defer { Self.bumpVisibleRevision(taskID) }
                do {
                    _ = try await send(
                        taskID: taskID,
                        text: item.text,
                        imageDataURLs: item.imageDataURLs ?? [],
                        mode: mode,
                        modelID: modelID,
                        retainQueuedMessagesOnFailure: false,
                        onUpdate: onUpdate,
                        onUserInput: onUserInput
                    )
                    if let itemID = item.asyncQuestionItemID {
                        try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: itemID)
                    }
                    try tasks.finishQueuedMessage(item, succeeded: true)
                    onUpdate(ConversationUpdate(type: "queue_changed"))
                } catch {
                    dispatchEncounteredFailure = true
                    try? tasks.finishQueuedMessage(item, succeeded: false)
                    onUpdate(ConversationUpdate(type: "queue_changed"))
                    onUpdate(ConversationUpdate(type: "action_notice", message: "A queued follow-up needs your review before it can be retried."))
                    break
                }
            }
            guard !dispatchEncounteredFailure else { break }
            let hadPendingDispatch = Self.pendingQueuedTaskDispatchIDs.remove(taskID) != nil
            let hasQueuedFollowUp = messageIDFilter != nil &&
                ((try? tasks.queuedConversationMessages(taskID: taskID).contains { $0.state == .queued }) == true)
            guard hadPendingDispatch || hasQueuedFollowUp else { break }
            messageIDFilter = nil
        }
    }
}
