import Foundation

extension CodexAppServerClient {
    package func followReattachedTurn(
        threadID: String,
        workspace: ConversationWorkspaceContext,
        callbacks: ConversationTurnCallbacks,
        onAttached: @escaping () -> Void
    ) async throws -> ConversationReattachResult {
        guard let persistentServer, hasLiveSharedServer else { return .agentGone }
        guard turnContexts[threadID] == nil else { return .notRunning }
        let context = TurnContext(onDelta: callbacks.onDelta, onFinal: callbacks.onFinalMessage, onProgress: callbacks.onProgressMessage, onMessageTimestamp: callbacks.onMessageTimestamp,
                                  onSteer: callbacks.onSteerMessage, onActivity: callbacks.onActivity, onDiff: callbacks.onDiff,
                                  onAction: callbacks.onActionRequest, onTokenUsage: callbacks.onTokenUsage)
        turnContexts[threadID] = context
        userInputContexts[threadID] = UserInputContext(mode: .code, handler: callbacks.onUserInput)
        defer {
            completedActivityDurations[threadID] = context.durations
            turnContexts.removeValue(forKey: threadID)
            userInputContexts.removeValue(forKey: threadID)
            Self.processActiveThreadIDs.remove(threadID)
            ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            if Self.activeClientsByThreadID[threadID] === self {
                Self.activeClientsByThreadID.removeValue(forKey: threadID)
            }
            if activeThreadID == threadID {
                activeThreadID = turnContexts.first(where: { $0.value.turnID != nil })?.key
                activeTurnID = activeThreadID.flatMap { turnContexts[$0]?.turnID }
                activeConversationMode = .code
            }
            isTurnActive = turnContexts.values.contains { $0.turnID != nil }
        }
        try await ensureInitialized(workspace: workspace)
        let saved = serverManifest?.threads[threadID] ?? persistentServer.readManifest()?.threads[threadID]
        let parameters = ResumeParameters(
            modelID: saved?.modelID ?? Self.modelID,
            cwd: saved?.cwd ?? workspace.cwd.path,
            roots: saved?.roots ?? workspace.roots.map(\.path),
            developerInstructions: saved?.developerInstructions,
            mcpServers: saved?.mcpServers
        )
        var resumeParameters: [String: Any] = [
            "threadId": threadID,
            "excludeTurns": true,
            "model": parameters.modelID,
            "cwd": parameters.cwd,
            "sandbox": "danger-full-access",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "runtimeWorkspaceRoots": parameters.roots,
        ]
        if let developerInstructions = parameters.developerInstructions { resumeParameters["developerInstructions"] = developerInstructions }
        if let config = workspace.codexThreadConfig { resumeParameters["config"] = config }
        _ = try await request(method: "thread/resume", params: resumeParameters)
        resumedThreadParameters[threadID] = parameters
        let turns = try await request(method: "thread/turns/list", params: ["threadId": threadID, "limit": 1, "sortDirection": "desc"])
        guard let latest = (turns["data"] as? [[String: Any]])?.first, let turnID = latest["id"] as? String else {
            onAttached()
            return .notRunning
        }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        PlayhouseDiagnostics.record("codex.turn.reattached", fields: diagnosticFields([
            "threadID": threadID,
            "turnID": turnID,
            "turnStatus": latest["status"] as? String ?? "unknown",
        ]))
        if latest["status"] as? String == "inProgress", completedTurns[turnKey] == nil {
            context.turnID = turnID
            runningTurnThreadIDs.insert(threadID)
            activeThreadID = threadID
            activeTurnID = turnID
            activeConversationMode = .code
            Self.activeClientsByThreadID[threadID] = self
            Self.processActiveThreadIDs.insert(threadID)
            isTurnActive = true
            ConversationSteerMailbox.publishActiveTurn(threadID: threadID, turnID: turnID)
            onAttached()
            let mailboxTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.turnContexts[threadID]?.turnID == turnID {
                    await self.serviceSteerMailbox(threadID: threadID, turnID: turnID)
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            defer { mailboxTask.cancel() }
            try await waitForTurn(turnKey)
            // Items that finished while no daemon followed the turn were never streamed.
            await backfillFinishedTurn(threadID: threadID, turnID: turnID, callbacks: callbacks)
        } else {
            onAttached()
            completedTurns.removeValue(forKey: turnKey)
            if latest["status"] as? String != "completed" {
                if latest["status"] as? String == "interrupted" { interruptedThreadIDs.insert(threadID) }
                await backfillFinishedTurn(threadID: threadID, turnID: turnID, callbacks: callbacks)
                throw ClientError.turnFailed(Self.turnFailureDescription(latest))
            }
            await backfillFinishedTurn(threadID: threadID, turnID: turnID, callbacks: callbacks)
        }
        return .finished
    }

    /// A turn that ended while no daemon followed it streamed nothing to Playhouse, so its
    /// messages are read from the thread once and handed over for recording.
    package func backfillFinishedTurn(threadID: String, turnID: String, callbacks: ConversationTurnCallbacks) async {
        guard let history = try? await readMessages(threadID: threadID, joinsAgentMessages: false) else { return }
        callbacks.onHistory(ConversationHistory(
            messages: history.messages.filter { $0.turnID == turnID },
            activities: history.activities.filter { $0.turnID == turnID },
            diff: history.diff
        ))
    }

    package func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
        PlayhouseDiagnostics.record("codex.user_input.answer.started", fields: [
            "requestID": requestID,
            "threadID": threadID,
            "questionCount": String(answers.count),
            "answerCount": String(answers.values.reduce(0) { $0 + $1.count })
        ])
        if let owner = activeClient(forThread: threadID), owner !== self {
            return owner.answerUserInput(requestID: requestID, threadID: threadID, answers: answers)
        }
        guard let pending = pendingUserInputs[threadID], pending.request.id == requestID else { return false }
        // A question is only live while the app-server that asked it is still
        // the running one. Its exit can be handled before its last output is,
        // and a later call may already have launched a replacement, so check
        // the asker itself; otherwise the saved copy recovers it as a new turn.
        guard let asker = pending.asker, asker === transportToken, transportIsRunning else {
            clearPendingUserInput(threadID: threadID)
            return false
        }
        let requestIDValue = pending.nativeID
        let pendingUserInputQuestions = Dictionary(uniqueKeysWithValues: pending.request.questions.map { ($0.id, $0) })
        let answersAreValid = Set(answers.keys) == Set(pendingUserInputQuestions.keys) &&
            answers.allSatisfy { questionID, values in
                guard !values.isEmpty, let question = pendingUserInputQuestions[questionID] else { return false }
                guard !question.options.isEmpty else { return values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
                let allowedLabels = Set(question.options.map(\.label))
                return values.allSatisfy { allowedLabels.contains($0) || question.allowsOther }
            }
        guard answersAreValid else {
            PlayhouseDiagnostics.record("codex.user_input.answer.failed", fields: [
                "requestID": requestID,
                "threadID": threadID,
                "reason": "invalid_answer_shape",
                "questionCount": String(answers.count)
            ])
            clearPendingUserInput(threadID: threadID)
            sendServerError(requestID: requestIDValue, code: -32602, message: "Answers must include a non-empty response for every question.")
            return false
        }
        do {
            try sendJSON(["jsonrpc": "2.0", "id": requestIDValue,
                          "result": ["answers": answers.mapValues { ["answers": $0] }]])
            clearPendingUserInput(threadID: threadID)
            PlayhouseDiagnostics.record("codex.user_input.answer.succeeded", fields: [
                "requestID": requestID,
                "threadID": threadID,
                "questionCount": String(answers.count),
                "answerCount": String(answers.values.reduce(0) { $0 + $1.count })
            ])
            return true
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["requestID"] = requestID
            fields["threadID"] = threadID
            PlayhouseDiagnostics.record("codex.user_input.answer.failed", fields: fields)
            actionRequestHandler?()
            return false
        }
    }

    package func rejectUserInput(requestID: String, threadID: String, message: String) {
        if let owner = activeClient(forThread: threadID), owner !== self {
            owner.rejectUserInput(requestID: requestID, threadID: threadID, message: message)
            return
        }
        guard let pending = pendingUserInputs[threadID], pending.request.id == requestID else { return }
        let requestIDValue = pending.nativeID
        clearPendingUserInput(threadID: threadID)
        sendServerError(requestID: requestIDValue, code: -32000, message: message)

        guard let turnID = activeTurnID(for: threadID) else { return }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        rejectedTurnKeys.insert(turnKey)
        let error = ClientError.turnFailed(message)
        if let waiter = turnWaiters.removeValue(forKey: turnKey) {
            waiter.resume(throwing: error)
        } else {
            completedTurns[turnKey] = .failure(error)
        }
        Task { try? await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
    }

    package func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? {
        pendingUserInputs[threadID]?.request
    }

    package func clearPendingUserInput(threadID: String) {
        pendingUserInputs.removeValue(forKey: threadID)
        pendingUserInputRequest = pendingUserInputs.values.first?.request
    }

    package func isTurnActive(threadID: String) -> Bool {
        startingThreadIDs.contains(threadID)
            || turnContexts[threadID]?.turnID != nil
            || contextlessTurnIDs[threadID] != nil
            || (activeThreadID == threadID && activeTurnID != nil)
            || pendingUserInputs[threadID] != nil
            || backgroundWaitThreadIDs.contains(threadID)
    }

    package func activeTurnID(for threadID: String) -> String? {
        if let turnID = turnContexts[threadID]?.turnID { return turnID }
        if let turnID = contextlessTurnIDs[threadID] { return turnID }
        guard activeThreadID == threadID else { return nil }
        return activeTurnID
    }

    package func isObservingGoal(threadID: String) -> Bool {
        goalObservationThreadID == threadID
    }
}
