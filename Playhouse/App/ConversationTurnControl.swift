import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    // MARK: - Turn control

    func interrupt(taskID: UUID) async throws -> Bool {
        PlayhouseDiagnostics.record("conversation.interrupt.started", fields: ["taskID": taskID.uuidString])
        // A send this daemon accepted that doesn't own the turn yet (it is on its way to the
        // turn reservation, or waiting behind the turn being stopped) is stopped with it: it
        // gives up at its first launch checkpoint instead of starting a turn after the stop.
        let stoppedWaitingSend = ConversationTurnLaunch.requestStopOfWaitingSends(taskID)
        // A turn that is still launching (preparing worktrees, starting its thread or its
        // provider process) has nothing to interrupt yet. The stop is recorded so the launch
        // gives up at its next checkpoint, or, once the provider turn exists, is interrupted
        // below. Either way the task leaves In Progress now.
        var launchPauseRevision: Int?
        if stoppedWaitingSend || (ConversationTurnLaunch.isLaunching(taskID) && !canInterruptProviderTurn(taskID)) {
            launchPauseRevision = try await tasks.transitionLifecycleStatus(
                taskID,
                from: .inProgress,
                to: .waitingResponse
            )
            if ConversationTurnLaunch.isLaunching(taskID), !canInterruptProviderTurn(taskID) {
                ConversationTurnLaunch.requestStop(taskID)
                guard await ConversationTurnLaunch.settled(taskID) == .turnStarted else {
                    PlayhouseDiagnostics.record("conversation.interrupt.finished", fields: [
                        "taskID": taskID.uuidString,
                        "interrupted": "true",
                        "stoppedBeforeTurnStarted": "true"
                    ])
                    return true
                }
            }
        }
        let task = try tasks.conversationSubject(taskID)
        guard let threadID = task.activeConversationID else {
            PlayhouseDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_thread"
            ])
            return stoppedWaitingSend
        }
        let providerClient = client(for: task)
        guard providerClient.isTurnActive(threadID: threadID)
                || providerClient.activeTurnOwnerProcessID(threadID: threadID) != nil else {
            PlayhouseDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_active_turn"
            ])
            return stoppedWaitingSend
        }
        // A user-requested stop is a resumable pause. Persist that intent before
        // asking the provider so the task leaves In Progress as soon as Stop is
        // clicked, even when the provider is still thinking or the interrupt
        // acknowledgment takes time.
        let pauseRevision = try await tasks.transitionLifecycleStatus(
            taskID,
            from: .inProgress,
            to: .waitingResponse
        ) ?? launchPauseRevision
        // A stop already on its way to the provider covers this turn; asking again would
        // only reach the provider after the turn is gone. This stop shares that one's outcome,
        // unless it already stopped a message of its own that was waiting.
        guard ConversationTurnLaunch.beginProviderStop(taskID) else {
            let joined = stoppedWaitingSend ? true : await ConversationTurnLaunch.providerStopOutcome(taskID)
            PlayhouseDiagnostics.record("conversation.interrupt.finished", fields: [
                "taskID": taskID.uuidString,
                "interrupted": String(joined),
                "joinedStopInFlight": "true"
            ])
            return joined
        }
        var interrupted = false
        defer { ConversationTurnLaunch.endProviderStop(taskID, interrupted: interrupted) }
        do {
            interrupted = try await providerClient.interruptActiveTurn(threadID: threadID)
        } catch {
            if let pauseRevision,
               (providerClient.isTurnActive(threadID: threadID)
                    || providerClient.activeTurnOwnerProcessID(threadID: threadID) != nil) {
                _ = try? await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: pauseRevision)
            }
            throw error
        }
        if !interrupted, !stoppedWaitingSend, let pauseRevision {
            _ = try await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: pauseRevision)
        }
        PlayhouseDiagnostics.record("conversation.interrupt.finished", fields: [
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "provider": task.conversationProvider.rawValue,
            "interrupted": String(interrupted)
        ])
        return interrupted || stoppedWaitingSend
    }

    // MARK: - Task deletion

    /// How long deleting a task gives its turn to stop after an interrupt, and then again after
    /// the provider is force-stopped, before the delete gives up with an error.
    static let deleteInterruptTimeout: Duration = .seconds(3)
    static let deleteForceStopTimeout: Duration = .seconds(5)

    /// Deletes a task at once, whatever its agent is doing: a running turn, one waiting on a
    /// question, a launch, or sends waiting for the turn are stopped first, by interrupt and
    /// then by force, and only then is the task deleted. Every wait is bounded, so a turn that
    /// can't be stopped fails the delete with an error instead of hanging it. A second delete
    /// of the same task while one runs shares that one's result.
    func deleteTask(_ taskID: UUID, diagnostics: [String: String] = [:]) async throws {
        if let running = TaskDeletion.running(taskID) {
            PlayhouseDiagnostics.record("task.delete.joined", fields: ["taskID": taskID.uuidString])
            return try await running.value
        }
        // An unknown task fails as before, before anything is stopped.
        _ = try tasks.taskModel(taskID)
        let deletion = Task { @MainActor in
            try await self.stopTurnForDeletion(taskID)
            try await self.tasks.delete(taskID, diagnostics: diagnostics)
            // A provider process left idle after the turn has nothing more to do for the task. The
            // delete is done, so its reply doesn't wait for this.
            if let threadID = TaskDeletion.threadID(taskID) {
                let client = self.clients.client(for: TaskDeletion.provider(taskID) ?? .claude)
                Task { @MainActor in _ = await client.forceStopActiveTurn(threadID: threadID) }
            }
        }
        TaskDeletion.begin(taskID, deletion)
        do {
            try await deletion.value
            TaskDeletion.finish(taskID, deleted: true)
        } catch {
            TaskDeletion.finish(taskID, deleted: false)
            throw error
        }
    }

    private func stopTurnForDeletion(_ taskID: UUID) async throws {
        let task = try tasks.conversationSubject(taskID)
        TaskDeletion.remember(taskID, threadID: task.activeConversationID, provider: task.conversationProvider)
        let reserved = try tasks.hasConversationTurnReservation(taskID)
        guard reserved || ConversationTurnLaunch.isLaunching(taskID) || ConversationTurnLaunch.hasWaitingSend(taskID) else { return }
        var fields = [
            "taskID": taskID.uuidString,
            "provider": task.conversationProvider.rawValue,
            "threadID": task.activeConversationID ?? "",
            "taskStatus": task.status.rawValue,
            "reservationHeld": String(reserved)
        ]
        PlayhouseDiagnostics.record("task.delete.stopping_turn", fields: fields)
        // A question the turn waits on is declined first: an interrupt alone leaves a turn that
        // waits on the user open.
        if let threadID = task.activeConversationID,
           let question = try? transcripts.readState(taskID).pendingUserInputRequest, question.threadID == threadID {
            client(for: task).rejectUserInput(requestID: question.id, threadID: threadID, message: "The task was deleted.")
            fields["declinedQuestion"] = "true"
        }
        let interruptDeadline = ContinuousClock.now + Self.deleteInterruptTimeout
        let interrupted = await BoundedWait.result(within: Self.deleteInterruptTimeout) {
            (try? await self.interrupt(taskID: taskID)) ?? false
        }
        fields["interrupted"] = interrupted.map(String.init) ?? "timed_out"
        if await waitForTurnToEnd(taskID, timeout: max(.zero, interruptDeadline - ContinuousClock.now)) {
            fields["method"] = "interrupt"
            PlayhouseDiagnostics.record("task.delete.turn_stopped", fields: fields)
            return
        }
        // The provider didn't end the turn, so it is ended without it.
        let forceDeadline = ContinuousClock.now + Self.deleteForceStopTimeout
        let threadID = (try? tasks.conversationSubject(taskID).activeConversationID) ?? task.activeConversationID
        if let threadID {
            TaskDeletion.remember(taskID, threadID: threadID, provider: task.conversationProvider)
            let providerClient = client(for: task)
            let forced = await BoundedWait.result(within: Self.deleteForceStopTimeout) {
                await providerClient.forceStopActiveTurn(threadID: threadID)
            }
            fields["forceStopped"] = forced.map(String.init) ?? "timed_out"
        }
        PlayhouseDiagnostics.record("task.delete.turn_force_killed", fields: fields)
        if await waitForTurnToEnd(taskID, timeout: max(.zero, forceDeadline - ContinuousClock.now)) {
            fields["method"] = "force"
            PlayhouseDiagnostics.record("task.delete.turn_stopped", fields: fields)
            return
        }
        PlayhouseDiagnostics.record("task.delete.stop_failed", fields: fields)
        let seconds = (Self.deleteInterruptTimeout + Self.deleteForceStopTimeout).components.seconds
        throw BridgeCommandError(
            code: "operation_failed",
            message: "Couldn't stop the agent working on this task within \(seconds) seconds, so the task wasn't deleted. Try deleting it again."
        )
    }

    /// Whether the task's turn, its launch and every send waiting for it ended within `timeout`.
    private func waitForTurnToEnd(_ taskID: UUID, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            let reserved = (try? tasks.hasConversationTurnReservation(taskID)) ?? true
            if !reserved, !ConversationTurnLaunch.isLaunching(taskID), !ConversationTurnLaunch.hasWaitingSend(taskID) { return true }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func steer(taskID: UUID, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        // A steer sent while the turn is still launching is delivered as soon as the provider
        // turn exists, instead of missing it and running as a turn of its own.
        await waitForAcceptedSendToLaunch(taskID)
        if ConversationTurnLaunch.isLaunching(taskID), !canInterruptProviderTurn(taskID) {
            switch await ConversationTurnLaunch.settled(taskID) {
            case .turnStarted: break
            // The user stopped the message this steer was meant for, so it must not go on
            // to run as a turn of its own.
            case .stopped: throw ConversationTurnLaunch.stoppedBeforeStart
            case .ended: return false
            }
        }
        let task = try tasks.conversationSubject(taskID)
        guard let threadID = task.activeConversationID else { return false }
        let steeredText = await expandMentions(normalizedText, for: task)
        // The running turn records and streams the steered input itself.
        return try await client(for: task).steerActiveTurn(threadID: threadID, text: steeredText, imageDataURLs: imageDataURLs)
    }

    /// Whether the task's provider already has a turn that takes an interrupt or a steer.
    private func canInterruptProviderTurn(_ taskID: UUID) -> Bool {
        guard let task = try? tasks.conversationSubject(taskID), let threadID = task.activeConversationID else { return false }
        return client(for: task).canInterruptActiveTurn(threadID: threadID)
    }

    /// A send this daemon accepted reaches its launch within moments; a stop or steer that
    /// arrives in between waits for it instead of finding no turn at all.
    private func waitForAcceptedSendToLaunch(_ taskID: UUID) async {
        var remainingChecks = 100
        while remainingChecks > 0, ConversationTurnLaunch.hasWaitingSend(taskID),
              !ConversationTurnLaunch.isLaunching(taskID), !ConversationTurnEvents.isActive(taskID) {
            try? await Task.sleep(for: .milliseconds(20))
            remainingChecks -= 1
        }
    }

    /// `text` with the context block that tells the provider what its `@` mentions refer to.
    func expandMentions(_ text: String, for task: any ConversationSubject) async -> String {
        guard let mentions = clients.mentions else { return text }
        return await mentions.expand(text, for: task, tasks: tasks, settings: settingsManager)
    }

    func answerUserInput(taskID: UUID, requestID: String, threadID: String, answers: [String: [String]]) throws -> Bool {
        client(for: try tasks.conversationSubject(taskID)).answerUserInput(requestID: requestID, threadID: threadID, answers: answers)
    }

    func answerAsyncQuestion(
        taskID: UUID,
        question: ConversationMessage,
        answers: [String],
        historyMessageLimit: Int? = nil
    ) async throws -> (text: String, queued: Bool, history: ConversationHistory?) {
        let providerName = try tasks.conversationSubject(taskID).conversationProvider.displayName
        guard let questions = question.asyncQuestions, !questions.isEmpty, questions.count == answers.count else {
            throw BridgeCommandError(code: "invalid_argument", message: "Supply one answer for every question in the \(providerName) item.")
        }
        guard !(try tasks.answeredAsyncQuestionIDs(taskID: taskID)).contains(question.id) else {
            throw BridgeCommandError(code: "invalid_transition", message: "This \(providerName) question has already been answered.")
        }
        guard try !queuedMessages(taskID: taskID).contains(where: { $0.asyncQuestionItemID == question.id }) else {
            throw BridgeCommandError(code: "invalid_transition", message: "An answer to this \(providerName) question is already pending.")
        }
        let normalized = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty }) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Question answers can't be blank.")
        }
        let reply = zip(questions, normalized).map { pair in "\(pair.0.title): \(pair.1)" }.joined(separator: "\n")
        let steered = try await steer(taskID: taskID, text: reply)
        if steered {
            try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: question.id)
            return (reply, false, nil)
        }
        let item = try await queueMissedSteer(taskID: taskID, text: reply, asyncQuestionItemID: question.id)
        let stillQueued = try queuedMessages(taskID: taskID).contains { $0.id == item.id }
        if !stillQueued { try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: question.id) }
        return (reply, stillQueued, stillQueued ? nil : try await history(taskID: taskID, messageLimit: historyMessageLimit, includesImageData: true))
    }

    /// The question persisted for this conversation, readable without its provider.
    func savedUserInputRequest(taskID: UUID) throws -> ConversationUserInputRequest? {
        visiblePendingUserInputRequest(taskID: taskID, transcript: try transcripts.readState(taskID))
    }

    func queuedMessages(taskID: UUID) throws -> [QueuedConversationMessage] {
        try tasks.queuedConversationMessages(taskID: taskID)
    }

    func answeredAsyncQuestionIDs(taskID: UUID) throws -> [String] {
        try tasks.answeredAsyncQuestionIDs(taskID: taskID)
    }

    func queueMessage(taskID: UUID, text: String, imageDataURLs: [String] = [], asyncQuestionItemID: String? = nil) throws -> QueuedConversationMessage {
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        defer { Self.bumpVisibleRevision(taskID) }
        return try tasks.enqueueConversationMessage(
            taskID: taskID,
            text: text, imageDataURLs: imageDataURLs, asyncQuestionItemID: asyncQuestionItemID
        )
    }

    func queueMissedSteer(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        asyncQuestionItemID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws -> QueuedConversationMessage {
        let item = try queueMessage(taskID: taskID, text: text, imageDataURLs: imageDataURLs, asyncQuestionItemID: asyncQuestionItemID)
        if shouldDrainMissedSteerImmediately(taskID: taskID) {
            Task { @MainActor in
                await dispatchQueuedMessages(
                    taskID: taskID,
                    mode: .code,
                    modelID: nil,
                    onlyMessageID: item.id,
                    onUpdate: onUpdate,
                    onUserInput: onUserInput
                )
            }
        } else if Self.dispatchingQueuedTaskIDs.contains(taskID) {
            Self.pendingQueuedTaskDispatchIDs.insert(taskID)
        }
        return item
    }

    func removeQueuedMessage(taskID: UUID, messageID: UUID) throws {
        defer { Self.bumpVisibleRevision(taskID) }
        try tasks.removeQueuedMessage(taskID: taskID, messageID: messageID)
    }

    func steerQueuedMessage(taskID: UUID, messageID: UUID) async throws -> (message: String, imageDataURLs: [String], accepted: Bool) {
        let item = try tasks.queuedConversationMessages(taskID: taskID).first { $0.id == messageID }
        guard let item, item.state == .queued else {
            throw BridgeCommandError(code: "invalid_transition", message: "That follow-up is no longer available to steer.")
        }
        try tasks.reserveQueuedMessageForSteering(taskID: taskID, messageID: messageID)
        // Windows hide a follow-up while it is reserved, so announce the reservation
        // and, on every exit, its removal or return to the queue.
        Self.bumpVisibleRevision(taskID)
        defer { Self.bumpVisibleRevision(taskID) }
        do {
            let accepted = try await steer(taskID: taskID, text: item.text, imageDataURLs: item.imageDataURLs ?? [])
            if accepted {
                if let itemID = item.asyncQuestionItemID {
                    try await tasks.recordAnsweredAsyncQuestion(taskID: taskID, itemID: itemID)
                }
                try tasks.finishQueuedMessageSteering(taskID: taskID, messageID: messageID, accepted: true)
            }
            else {
                try tasks.requeueMissedSteer(taskID: taskID, messageID: messageID)
                if shouldDrainMissedSteerImmediately(taskID: taskID) {
                    Task { @MainActor in
                        await dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: nil, onlyMessageID: messageID, onUpdate: { _ in }, onUserInput: { _ in })
                    }
                } else if Self.dispatchingQueuedTaskIDs.contains(taskID) {
                    Self.pendingQueuedTaskDispatchIDs.insert(taskID)
                }
            }
            return (item.text, item.imageDataURLs ?? [], accepted)
        } catch {
            try? tasks.finishQueuedMessageSteering(taskID: taskID, messageID: messageID, accepted: false)
            throw error
        }
    }

    func retryQueuedMessage(
        taskID: UUID,
        messageID: UUID,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws -> Bool {
        try tasks.retryQueuedMessage(taskID: taskID, messageID: messageID)
        await dispatchQueuedMessages(taskID: taskID, mode: .code, modelID: nil, onlyMessageID: messageID, onUpdate: onUpdate, onUserInput: onUserInput)
        return try !tasks.queuedConversationMessages(taskID: taskID).contains { $0.id == messageID }
    }

    /// Sends a turn with the task's current provider. A nil model uses that
    /// provider's default, so queued and resumed turns follow a provider switch.
    func send(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode = .code,
        modelID: String? = nil,
        userInputAnswers: [String: [String]] = [:],
        retainQueuedMessagesOnFailure: Bool = true,
        statusBeforeSubmission: TaskStatus? = nil,
        contextPageIDs: [String] = [],
        onTurnStarting: (() -> Void)? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in },
        sensitiveUserInputAnswerValues: [String] = [],
        requiresSensitiveAnswerRedaction: Bool = false,
        hideSensitiveRecoveryPrompt: Bool = false,
        isPlayhouseNudge: Bool = false,
        applyingUserInputRequestID: String? = nil,
        onUserInputApplied: (() throws -> Void)? = nil,
        historyMessageLimit: Int? = nil
    ) async throws -> ConversationHistory {
        let streamUpdate = onUpdate
        let onUpdate: (ConversationUpdate) -> Void = { update in
            if Self.historyVisibleUpdateTypes.contains(update.type) { Self.bumpVisibleRevision(taskID) }
            streamUpdate(update)
            ConversationTurnEvents.publish(taskID, update)
        }
        defer { Self.bumpVisibleRevision(taskID) }
        activeSendTaskIDs.insert(taskID)
        defer { activeSendTaskIDs.remove(taskID) }
        try TaskDeletion.checkNotDeleting(taskID)
        ConversationTurnLaunch.sendWaiting(taskID)
        PlayhouseDiagnostics.recordAndFlush("conversation.send.accepted", fields: ["taskID": taskID.uuidString])
        var ownsTurnReservation = false
        defer { if !ownsTurnReservation { ConversationTurnLaunch.sendStoppedWaiting(taskID, ownsTurn: false) } }
        let task = try tasks.conversationSubject(taskID)
        if !task.isStandaloneChat, !isPlayhouseNudge, !text.hasPrefix(Self.pullRequestAutopilotPromptMarker) {
            try await tasks.clearPullRequestAutopilotSignature(taskID)
        }
        guard contextPageIDs.isEmpty || task.isStandaloneChat else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Chat pages belong to the standalone chat, so a task conversation cannot take --context-page."
            )
        }
        // After validation, so a rejected send leaves the recent mentions as they were.
        let text = isPlayhouseNudge ? text : await expandMentions(text, for: task)
        let operationClient = client(for: task)
        operationClient.beginConversationOperation()
        defer { operationClient.finishConversationOperation() }
        let isStandaloneChat = task.isStandaloneChat
        let standaloneChatManager = isStandaloneChat ? try? tasks.standaloneChatManager() : nil
        // Capture the signal after this send owns the turn reservation. Capturing before
        // waiting could accidentally count a previous queued turn's page signal.
        var signalBefore: Int?
        let history: ConversationHistory
        do {
            history = try await tasks.withConversationTurnReservation(taskID) {
                ConversationTurnEvents.begin(taskID)
                defer { ConversationTurnEvents.end(taskID) }
                ConversationTurnLaunch.begin(taskID)
                defer { ConversationTurnLaunch.end(taskID) }
                ownsTurnReservation = true
                ConversationTurnLaunch.sendStoppedWaiting(taskID, ownsTurn: true)
                // A send that waited behind a turn its task's deletion stopped hands the
                // reservation straight to the delete.
                try TaskDeletion.checkNotDeleting(taskID)
                // Only the reservation holder owns the applying marker: take it for
                // a recovery, or drop one a crashed recovery left behind.
                try self.transcripts.mutate(taskID, turns: .none) { transcript in
                    transcript.applyingUserInputRequestID = applyingUserInputRequestID
                }
                defer {
                    if applyingUserInputRequestID != nil {
                        try? self.transcripts.mutate(taskID, turns: .none) { transcript in
                            transcript.applyingUserInputRequestID = nil
                        }
                    }
                }
                do {
                    self.lastReportedTurnOutcomeByTaskID.removeValue(forKey: taskID)
                    if let standaloneChatManager {
                        // A subsequent turn must not overtake a pending page decision.
                        // The fallback remains background work for the completed turn, but
                        // the next provider request waits until its page is resolved.
                        if let pending = Self.standalonePageFallbackTasks[taskID] {
                            await pending.task.value
                            if Self.standalonePageFallbackTasks[taskID]?.id == pending.id {
                                Self.standalonePageFallbackTasks.removeValue(forKey: taskID)
                            }
                        }
                        // XPC helpers can be short-lived: if their process ended before
                        // its unstructured fallback task ran, recover the persisted missed
                        // turn before allowing a later message to overtake it.
                        await self.resolvePendingStandalonePageFallback(taskID: taskID, onUpdate: onUpdate)
                        let unresolvedPageState: (missedSignal: Bool, hasPendingFallback: Bool)
                        do {
                            unresolvedPageState = (
                                try standaloneChatManager.lastTurnMissedSignal(),
                                try standaloneChatManager.hasPendingFallback()
                            )
                        } catch {
                            throw BridgeCommandError(
                                code: "operation_failed",
                                message: "Couldn't verify the previous chat page decision. Retry sending."
                            )
                        }
                        if unresolvedPageState.missedSignal || unresolvedPageState.hasPendingFallback {
                            throw BridgeCommandError(
                                code: "operation_failed",
                                message: "A previous chat page classification is still pending. Retry sending after it resolves."
                            )
                        }
                        // A turn no daemon lived to file (it was in flight when its daemon
                        // died) is filed before this turn seeds a page session from the archive.
                        await self.recoverUnfiledStandaloneChatTurns(taskID: taskID, reason: "send")
                        signalBefore = (try? standaloneChatManager.signalSequence()) ?? 0
                        // Durable, unlike `signalBefore`: a daemon that takes this turn over after
                        // a restart reads when it began from here.
                        try? standaloneChatManager.beginTurn()
                    }
                    let result = try await self.sendReserved(
                        taskID: taskID,
                        text: text,
                        imageDataURLs: imageDataURLs,
                        mode: mode,
                        requestedModelID: modelID,
                        userInputAnswers: userInputAnswers,
                        sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                        requiresSensitiveAnswerRedaction: requiresSensitiveAnswerRedaction,
                        hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt,
                        isPlayhouseNudge: isPlayhouseNudge,
                        deferMissingOutcomeStatus: true,
                        statusBeforeSubmission: statusBeforeSubmission,
                        contextPageIDs: contextPageIDs,
                        onTurnStarting: onTurnStarting,
                        onUpdate: onUpdate,
                        onUserInput: onUserInput,
                        // A chat archives its finished turn from this result, so it
                        // must hold the whole turn rather than the newest page.
                        historyMessageLimit: task.isStandaloneChat ? nil : historyMessageLimit
                    )
                    if task.authoringPluginID == nil {
                        try await self.driveUnsettledTurns(
                            taskID: taskID, isStandaloneChat: isStandaloneChat, mode: mode, modelID: modelID,
                            client: operationClient, onUpdate: onUpdate, onUserInput: onUserInput
                        )
                    } else if (try? self.transcripts.readState(taskID).pendingUserInputRequest) == nil {
                        _ = try await self.tasks.setLifecycleStatus(taskID, to: .waitingResponse)
                    }
                    try onUserInputApplied?()
                    self.lastReportedTurnOutcomeByTaskID.removeValue(forKey: taskID)
                    try? await self.tasks.clearPendingSubmittedPrompt(taskID)
                    if let standaloneChatManager, let signalBefore,
                       let latestTurnID = result.messages.last?.turnID {
                        let signalAfter = (try? standaloneChatManager.signalSequence()) ?? signalBefore
                        self.recordStandaloneChatTurn(
                            task: task,
                            chatManager: standaloneChatManager,
                            history: result,
                            latestTurnID: latestTurnID,
                            missedSignal: signalAfter == signalBefore,
                            onUpdate: onUpdate
                        )
                    }
                    try? standaloneChatManager?.endTurn()
                    return result
                } catch {
                    // This daemon saw the send fail, so nothing is left for a later one to file.
                    if signalBefore != nil { try? standaloneChatManager?.endTurn() }
                    try? await self.tasks.clearPendingSubmittedPrompt(taskID)
                    throw error
                }
            }
        } catch {
            // Follow-ups queued before the conversation was named have no conversation ID.
            if retainQueuedMessagesOnFailure, let subject = try? tasks.conversationSubject(taskID) {
                try? tasks.retainQueuedMessagesForUserAction(taskID: taskID, threadID: subject.activeConversationID ?? "")
                onUpdate(ConversationUpdate(type: "queue_changed"))
            }
            throw error
        }
        if !Self.dispatchingQueuedTaskIDs.contains(taskID) {
            await dispatchQueuedMessages(taskID: taskID, mode: mode, modelID: modelID, onUpdate: onUpdate, onUserInput: onUserInput)
        }
        return history
    }

    /// The message a turn gets when its agent didn't survive a daemon restart.
    static let interruptedByRestartMessage = "The agent stopped while Playhouse was restarting. Your conversation is saved; send a follow-up to continue."

    /// Each data folder is scanned once per daemon. Every request waits for that scan, so no
    /// request can settle a task as stopped while its turn is still being reattached.
    static var reattachScans: [String: Task<Void, Never>] = [:]

    /// Goes back to the turns that were running when this service's previous daemon exited:
    /// agents keep running across a daemon restart, so each such turn is followed again by this
    /// daemon, and a turn whose agent is gone is settled as interrupted.
}

/// Tasks this daemon is deleting or has deleted. A send for one of them gives up instead of
/// starting a turn, so a follow-up queued behind the stopped turn can't take the reservation
/// back from the delete, and nothing dispatches more work for a task that is gone.
@MainActor
enum TaskDeletion {
    private static var runningDeletions: [UUID: Task<Void, Error>] = [:]
    private static var deletedTaskIDs: Set<UUID> = []
    private static var threads: [UUID: (threadID: String, provider: ConversationProvider)] = [:]

    static func running(_ taskID: UUID) -> Task<Void, Error>? { runningDeletions[taskID] }

    static func begin(_ taskID: UUID, _ deletion: Task<Void, Error>) { runningDeletions[taskID] = deletion }

    /// A delete that failed leaves the task usable again.
    static func finish(_ taskID: UUID, deleted: Bool) {
        runningDeletions.removeValue(forKey: taskID)
        threads.removeValue(forKey: taskID)
        if deleted { deletedTaskIDs.insert(taskID) }
    }

    /// The conversation the deleted task's turn ran in, kept so its idle provider process is
    /// stopped once the task is gone.
    static func remember(_ taskID: UUID, threadID: String?, provider: ConversationProvider) {
        guard let threadID, !threadID.isEmpty else { return }
        threads[taskID] = (threadID, provider)
    }

    static func threadID(_ taskID: UUID) -> String? { threads[taskID]?.threadID }
    static func provider(_ taskID: UUID) -> ConversationProvider? { threads[taskID]?.provider }

    static func isDeleting(_ taskID: UUID) -> Bool {
        runningDeletions[taskID] != nil || deletedTaskIDs.contains(taskID)
    }

    static let deletingCode = "task_deleting"

    /// Thrown from a send for a task being deleted.
    static func checkNotDeleting(_ taskID: UUID) throws {
        guard isDeleting(taskID) else { return }
        throw BridgeCommandError(code: deletingCode, message: "This task is being deleted, so the message wasn't sent.")
    }
}

/// A task's turn from the moment its send owns the turn reservation until the provider has a
/// turn to control. A stop or steer requested in that window is held here, so it is never
/// dropped just because the provider turn doesn't exist yet.
@MainActor
enum ConversationTurnLaunch {
    private static var launching: Set<UUID> = []
    private static var stopRequests: Set<UUID> = []
    /// Sends accepted for a task that don't own its turn reservation yet, and how many of
    /// them a stop arrived for.
    private static var waitingSends: [UUID: Int] = [:]
    private static var stoppedWaitingSends: [UUID: Int] = [:]
    private static var waiters: [UUID: [CheckedContinuation<End, Never>]] = [:]
    /// Tasks whose running turn a stop is asking the provider to interrupt right now.
    private static var providerStops: Set<UUID> = []
    private static var providerStopWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]

    /// How a launch ended: with a provider turn, by the user's stop, or by the send ending
    /// for any other reason.
    enum End { case turnStarted, stopped, ended }

    static func isLaunching(_ taskID: UUID) -> Bool { launching.contains(taskID) }

    static func begin(_ taskID: UUID) { launching.insert(taskID) }

    /// The provider turn exists: held stops and steers go to it now.
    static func turnStarted(_ taskID: UUID) { settle(taskID, turnStarted: true) }

    /// Whether a send accepted for the task has yet to take its turn reservation. Shared by
    /// every bridge request, each of which runs on a manager of its own.
    static func hasWaitingSend(_ taskID: UUID) -> Bool { waitingSends[taskID, default: 0] > 0 }

    /// The send is over, with or without a provider turn.
    static func end(_ taskID: UUID) { settle(taskID, turnStarted: false) }

    static func sendWaiting(_ taskID: UUID) { waitingSends[taskID, default: 0] += 1 }

    /// A waiting send took the turn reservation (`ownsTurn`) or gave up. One a stop arrived
    /// for starts its launch already stopped.
    static func sendStoppedWaiting(_ taskID: UUID, ownsTurn: Bool) {
        let waiting = waitingSends[taskID, default: 0] - 1
        waitingSends[taskID] = waiting > 0 ? waiting : nil
        let stopped = stoppedWaitingSends[taskID, default: 0]
        guard stopped > 0 else { return }
        stoppedWaitingSends[taskID] = stopped > 1 ? stopped - 1 : nil
        if ownsTurn, launching.contains(taskID) { stopRequests.insert(taskID) }
    }

    /// Marks every send still waiting for the task's turn as stopped; false when none waits.
    static func requestStopOfWaitingSends(_ taskID: UUID) -> Bool {
        guard let waiting = waitingSends[taskID], waiting > 0 else { return false }
        stoppedWaitingSends[taskID] = waiting
        return true
    }

    /// Claims the provider interrupt for the task's running turn; false when another stop
    /// already holds it.
    static func beginProviderStop(_ taskID: UUID) -> Bool { providerStops.insert(taskID).inserted }

    /// The provider answered the stop, or refused it: stops that joined it get the same outcome.
    static func endProviderStop(_ taskID: UUID, interrupted: Bool) {
        providerStops.remove(taskID)
        for waiter in providerStopWaiters.removeValue(forKey: taskID) ?? [] { waiter.resume(returning: interrupted) }
    }

    /// Whether the stop already on its way to the provider interrupted the turn.
    static func providerStopOutcome(_ taskID: UUID) async -> Bool {
        guard providerStops.contains(taskID) else { return true }
        return await withCheckedContinuation { providerStopWaiters[taskID, default: []].append($0) }
    }

    static func requestStop(_ taskID: UUID) {
        if launching.contains(taskID) { stopRequests.insert(taskID) }
    }

    /// Thrown from a launch checkpoint once the user asked to stop the turn it is preparing.
    static func checkStop(_ taskID: UUID) throws {
        if stopRequests.contains(taskID) { throw stoppedBeforeStart }
    }

    static let stoppedBeforeStartCode = "turn_stopped"
    static var stoppedBeforeStart: BridgeCommandError {
        BridgeCommandError(code: stoppedBeforeStartCode, message: "The message was stopped before the agent started on it.")
    }

    static func isStoppedBeforeStart(_ error: Error) -> Bool {
        (error as? BridgeCommandError)?.code == stoppedBeforeStartCode
    }

    /// Waits for the launching turn to start or for its send to end without one. A task that
    /// isn't launching reports a started turn, so callers go on to ask the provider.
    static func settled(_ taskID: UUID) async -> End {
        guard launching.contains(taskID) else { return .turnStarted }
        return await withCheckedContinuation { waiters[taskID, default: []].append($0) }
    }

    private static func settle(_ taskID: UUID, turnStarted: Bool) {
        guard launching.remove(taskID) != nil else { return }
        let stopped = stopRequests.remove(taskID) != nil
        let end: End = turnStarted ? .turnStarted : stopped ? .stopped : .ended
        for waiter in waiters.removeValue(forKey: taskID) ?? [] { waiter.resume(returning: end) }
    }
}
