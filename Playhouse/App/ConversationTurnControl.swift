import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    // MARK: - Turn control

    func interrupt(taskID: UUID) async throws -> Bool {
        PlayhouseDiagnostics.record("conversation.interrupt.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.conversationSubject(taskID)
        guard let threadID = task.activeConversationID else {
            PlayhouseDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_thread"
            ])
            return false
        }
        let providerClient = client(for: task)
        guard providerClient.isTurnActive(threadID: threadID)
                || providerClient.activeTurnOwnerProcessID(threadID: threadID) != nil else {
            PlayhouseDiagnostics.record("conversation.interrupt.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "no_active_turn"
            ])
            return false
        }
        // A user-requested stop is a resumable pause. Persist that intent before
        // asking the provider so the task leaves In Progress as soon as Stop is
        // clicked, even when the provider is still thinking or the interrupt
        // acknowledgment takes time.
        let pauseRevision = try await tasks.transitionLifecycleStatus(
            taskID,
            from: .inProgress,
            to: .waitingResponse
        )
        let interrupted: Bool
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
        if !interrupted, let pauseRevision {
            _ = try await tasks.restoreLifecycleStatus(taskID, to: .inProgress, ifRevision: pauseRevision)
        }
        PlayhouseDiagnostics.record("conversation.interrupt.finished", fields: [
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "provider": task.conversationProvider.rawValue,
            "interrupted": String(interrupted)
        ])
        return interrupted
    }

    func steer(taskID: UUID, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        let task = try tasks.conversationSubject(taskID)
        guard let threadID = task.activeConversationID else { return false }
        let steeredText = await expandMentions(normalizedText, for: task)
        // The running turn records and streams the steered input itself.
        return try await client(for: task).steerActiveTurn(threadID: threadID, text: steeredText, imageDataURLs: imageDataURLs)
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
        activeSendTaskIDs.insert(taskID)
        defer { activeSendTaskIDs.remove(taskID) }
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
            if retainQueuedMessagesOnFailure, let threadID = try? tasks.conversationSubject(taskID).activeConversationID {
                try? tasks.retainQueuedMessagesForUserAction(taskID: taskID, threadID: threadID)
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
