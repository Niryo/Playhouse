import Foundation

extension CodexAppServerClient {
    package func activeTurnIdentity(threadID: String) -> String? {
        (activeClient(forThread: threadID) ?? self).activeTurnID(for: threadID)
            ?? ConversationSteerMailbox.activeTurnID(threadID: threadID)
    }

    package func interruptActiveTurn(threadID expectedThreadID: String) async throws -> Bool {
        if let owner = activeClient(forThread: expectedThreadID), owner !== self {
            return try await owner.interruptActiveTurn(threadID: expectedThreadID)
        }
        guard let turnID = activeTurnID(for: expectedThreadID) else {
            if try await stopBackgroundWait(threadID: expectedThreadID) { return true }
            guard activeClient(forThread: expectedThreadID) == nil else { return false }
            return try await ConversationSteerMailbox.requestInterrupt(threadID: expectedThreadID)
        }
        let threadID = expectedThreadID
        wasLastTurnInterrupted = true
        interruptedThreadIDs.insert(threadID)
        do {
            _ = try await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID], timeout: .seconds(10))
            return true
        } catch {
            if activeTurnID(for: threadID) == turnID,
               !rejectedTurnKeys.contains(Self.turnKey(threadID: threadID, turnID: turnID)) {
                wasLastTurnInterrupted = false
                interruptedThreadIDs.remove(threadID)
            }
            throw error
        }
    }

    /// Fails the thread's turn and any question it is waiting on right away and asks the
    /// app-server to interrupt it without waiting for the answer. The app-server itself keeps
    /// running: it is shared by every Codex conversation in this data folder.
    package func forceStopActiveTurn(threadID: String, interruptProvider: Bool) async -> Bool {
        if let owner = activeClient(forThread: threadID), owner !== self {
            return await owner.forceStopActiveTurn(threadID: threadID, interruptProvider: interruptProvider)
        }
        var stopped = false
        if let pending = pendingUserInputs[threadID] {
            clearPendingUserInput(threadID: threadID)
            sendServerError(requestID: pending.nativeID, code: -32000, message: "Playhouse stopped this turn.")
            stopped = true
        }
        if (try? await stopBackgroundWait(threadID: threadID)) == true { stopped = true }
        guard let turnID = activeTurnID(for: threadID) else { return stopped }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        rejectedTurnKeys.insert(turnKey)
        runningTurnThreadIDs.remove(threadID)
        wasLastTurnInterrupted = true
        interruptedThreadIDs.insert(threadID)
        if contextlessTurnIDs.removeValue(forKey: threadID) != nil {
            contextlessTurnEntries.removeValue(forKey: threadID)
            Self.processActiveThreadIDs.remove(threadID)
            ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            isTurnActive = !contextlessTurnIDs.isEmpty || turnContexts.values.contains { $0.turnID != nil }
        }
        let error = ClientError.turnFailed("Playhouse stopped this turn.")
        if let waiter = turnWaiters.removeValue(forKey: turnKey) {
            waiter.resume(throwing: error)
        } else {
            completedTurns[turnKey] = .failure(error)
        }
        if interruptProvider {
            Task { try? await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
        }
        return true
    }

    package func getGoal(threadID: String, workspace: ConversationWorkspaceContext) async throws -> CodexThreadGoal? {
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, reusingLoadedThread: true)
        let response = try await request(method: "thread/goal/get", params: ["threadId": threadID])
        guard let value = response["goal"] as? [String: Any] else { return nil }
        return Self.decodeGoal(value)
    }

    package func setGoal(threadID: String, objective: String? = nil, status: String? = nil, workspace: ConversationWorkspaceContext, observeRuntime: Bool = false) async throws -> CodexThreadGoal? {
        let startRevision = goalTurnStartRevision
        // Only a window's own Goal set follows the turns Codex starts for it; a CLI set on the
        // same app-server just sets the Goal.
        if observeRuntime {
            followGoalTurns(threadID: threadID)
            goalTurnStartedThreadID = nil
        }
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, reusingLoadedThread: true)
        var params: [String: Any] = ["threadId": threadID]
        if let objective { params["objective"] = objective }
        if let status { params["status"] = status }
        let response = try await request(method: "thread/goal/set", params: params)
        guard let value = response["goal"] as? [String: Any] else { return nil }
        if observeRuntime {
            try await waitForGoalTurnStart(threadID: threadID, after: startRevision)
            goalTurnRevision += 1
            noteGoalEvent()
        }
        return Self.decodeGoal(value)
    }

    package func clearGoal(threadID: String, workspace: ConversationWorkspaceContext) async throws {
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, reusingLoadedThread: true)
        _ = try await request(method: "thread/goal/clear", params: ["threadId": threadID])
    }

    package func shutdown() {
        if persistentServer != nil, serverManifest != nil {
            Task { await stopSharedServer(reason: "shutdown") }
            return
        }
        guard let process else {
            PlayhouseDiagnostics.record("codex.app_server.shutdown.skipped", fields: ["reason": "no_process"])
            return
        }
        guard process.isRunning else {
            PlayhouseDiagnostics.record("codex.app_server.shutdown.skipped", fields: [
                "reason": "already_stopped",
                "processID": String(process.processIdentifier),
                "terminationStatus": String(process.terminationStatus)
            ])
            return
        }
        let processID = process.processIdentifier
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            _ = kill(processID, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        PlayhouseDiagnostics.record("codex.app_server.shutdown.finished", fields: [
            "processID": String(processID),
            "terminationStatus": process.isRunning ? "still_running" : String(process.terminationStatus)
        ])
    }

    package func prepareForApplicationTermination() async {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = ContinuousClock.now + .seconds(4)
        isPreparingForApplicationTermination = true
        applicationShutdownInterruptResult = nil
        let threadID = activeThreadID
        var interruptAttempted = false
        var interruptResult = "not_attempted"
        PlayhouseDiagnostics.record("application.shutdown.started", fields: [
            "hasActiveTurn": String(isTurnActive),
            "conversationOperationsInFlight": String(conversationOperationsInFlight),
            "hasActiveThread": String(threadID != nil)
        ])
        if let threadID, isTurnActive {
            interruptAttempted = true
            interruptResult = "pending"
            Task { [weak self] in
                guard let self else { return }
                do {
                    let accepted = try await self.interruptActiveTurn(threadID: threadID)
                    self.applicationShutdownInterruptResult = accepted ? "accepted" : "not_accepted"
                } catch {
                    let failure = error as NSError
                    self.applicationShutdownInterruptResult = "failed"
                    PlayhouseDiagnostics.record("application.shutdown.interrupt_failed", fields: [
                        "errorDomain": failure.domain,
                        "errorCode": String(failure.code)
                    ])
                }
            }
        }
        while conversationOperationsInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let result = applicationShutdownInterruptResult { interruptResult = result }
        PlayhouseDiagnostics.record("application.shutdown.turn_drained", fields: [
            "turnStillActive": String(isTurnActive),
            "conversationOperationsInFlight": String(conversationOperationsInFlight),
            "interruptAttempted": String(interruptAttempted),
            "interruptAccepted": interruptResult,
            "drainTimedOut": String(conversationOperationsInFlight > 0),
            "elapsedMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        ])
        shutdown()
        PlayhouseDiagnostics.record("application.shutdown.finished", fields: [
            "elapsedMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        ])
    }

    package func beginConversationOperation() {
        conversationOperationsInFlight += 1
    }

    package func finishConversationOperation() {
        conversationOperationsInFlight = max(0, conversationOperationsInFlight - 1)
    }

    package static func decodeGoal(_ value: [String: Any]) -> CodexThreadGoal? {
        guard let threadID = value["threadId"] as? String,
              let objective = value["objective"] as? String,
              let status = value["status"] as? String else { return nil }
        return CodexThreadGoal(threadID: threadID, objective: objective, status: status,
            tokenBudget: value["tokenBudget"] as? Int, tokensUsed: value["tokensUsed"] as? Int,
            timeUsedSeconds: value["timeUsedSeconds"] as? Double)
    }

    package func steerActiveTurn(threadID expectedThreadID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard let target = activeClient(forThread: expectedThreadID) else {
            return try await ConversationSteerMailbox.requestSteer(threadID: expectedThreadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        guard let turnID = target.activeTurnID(for: expectedThreadID) else { return false }
        let accepted = try await target.sendSteerRequest(threadID: expectedThreadID, turnID: turnID, text: normalized, imageDataURLs: imageDataURLs)
        // The turn's own stream shows the steer, whoever sent it.
        if accepted { target.turnContexts[expectedThreadID]?.onSteer(normalized, imageDataURLs) }
        return accepted
    }

    package func sendSteerRequest(threadID: String, turnID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        // Verified against `codex-cli 0.162.1` app-server schemas: params require
        // threadId/input/expectedTurnId and the response requires turnId.
        let response: [String: Any]
        do {
            response = try await request(method: "turn/steer", params: [
                "threadId": threadID,
                "input": (text.isEmpty ? [] : [["type": "text", "text": text]]) + imageDataURLs.map { ["type": "image", "url": $0] },
                "expectedTurnId": turnID
            ])
        } catch {
            if case ClientError.staleTurn = error {
                return false
            }
            throw error
        }
        guard response["turnId"] as? String == turnID else {
            return false
        }
        return true
    }

    package func serviceSteerMailbox(threadID: String, turnID: String) async {
        await ConversationSteerMailbox.service(threadID: threadID, turnID: turnID) { text, images in
            let accepted: Bool
            do {
                accepted = try await sendSteerRequest(threadID: threadID, turnID: turnID, text: text, imageDataURLs: images)
            } catch {
                if case ClientError.staleTurn = error { return false }
                throw error
            }
            if accepted { turnContexts[threadID]?.onSteer(text, images) }
            return accepted
        } interrupt: {
            try await interruptActiveTurn(threadID: threadID)
        }
    }

    package func loadThreadForSend(
        threadID: String, workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?,
        sensitiveUserInputAnswerValues: [String], hideSensitiveRecoveryPrompt: Bool
    ) async throws -> Bool {
        // The same resume `sendMessage` makes, so the send finds the thread already loaded.
        do {
            try await resumeThreadIfNeeded(
                id: threadID,
                workspace: workspace,
                modelID: modelID,
                developerInstructions: developerInstructions,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                sensitiveConversation: hideSensitiveRecoveryPrompt || !sensitiveUserInputAnswerValues.isEmpty,
                confirmingModel: false
            )
            return true
        } catch ClientError.threadNotFound {
            return false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Any other failure is the send's to report, once the turn's message is recorded:
            // its own resume tries again (a transient failure may pass the second time) and
            // fails the turn as it did before this check.
            return true
        }
    }

    package func sendMessage(
        _ text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        sessionRecoveryContext: String? = nil,
        developerInstructions: String? = nil,
        onDelta: @escaping (String) -> Void,
        onFinalMessage: @escaping (String) -> Void,
        onActivity: @escaping (ConversationActivity) -> Void,
        onDiff: @escaping (ConversationTurnDiff) -> Void,
        onHistory: @escaping (ConversationHistory) -> Void,
        onActionRequest: @escaping () -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void,
        onSteerMessage: @escaping (String, [String]) -> Void = { _, _ in },
        onProgressMessage: @escaping (ConversationMessage) -> Void = { _ in },
        onMessageTimestamp: @escaping (String, Date) -> Void = { _, _ in },
        onTurnStarted: @escaping (String) -> Void,
        onTokenUsage: @escaping (ConversationTurnUsageReport) -> Void = { _ in },
        // Codex records each answer when its item completes, never early, so it has none.
        onRecordedFinalMessage: ((String, String) -> Void)? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        hideSensitiveRecoveryPrompt: Bool = false
    ) async throws {
        guard turnContexts[threadID] == nil else {
            throw BridgeCommandError(code: "invalid_transition", message: "This conversation already has an active send.")
        }
        let context = TurnContext(onDelta: onDelta, onFinal: onFinalMessage, onProgress: onProgressMessage, onMessageTimestamp: onMessageTimestamp,
                                  onSteer: onSteerMessage, onActivity: onActivity, onDiff: onDiff, onAction: onActionRequest,
                                  onTokenUsage: onTokenUsage)
        turnContexts[threadID] = context
        // A new turn supersedes a stop another client recorded for this thread.
        for client in Self.allSharedClients { client.interruptedThreadIDs.remove(threadID) }
        interruptedThreadIDs.remove(threadID)
        userInputContexts[threadID] = UserInputContext(mode: mode, handler: onUserInput)
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
        try await resumeThreadIfNeeded(
            id: threadID,
            workspace: workspace,
            modelID: modelID,
            developerInstructions: developerInstructions,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            sensitiveConversation: hideSensitiveRecoveryPrompt || !sensitiveUserInputAnswerValues.isEmpty,
            // The resumed thread may have used another model previously. This turn
            // supplies its selected model explicitly in `turn/start` below.
            confirmingModel: false
        )
        // This send's own stream follows the thread now. A Goal a window follows on another
        // thread keeps being followed: the CLI sends through the same client.
        if goalObservationThreadID == threadID { goalObservationThreadID = nil }
        contextlessTurnIDs.removeValue(forKey: threadID)
        contextlessTurnEntries.removeValue(forKey: threadID)
        activeThreadID = threadID
        Self.activeClientsByThreadID[threadID] = self
        activeTurnID = nil
        activeConversationMode = mode
        isTurnActive = turnContexts.values.contains { $0.turnID != nil }
        wasLastTurnInterrupted = false
        var input: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        input += imageDataURLs.map { ["type": "image", "url": $0] }
        // Codex has no slash commands, so a `/skill` the message names travels as a skill input.
        input += (workspace.skillBridge?.invocations ?? []).map { ["type": "skill", "name": $0.name, "path": $0.path] }
        var turnParams: [String: Any] = [
            "threadId": threadID,
            "input": input,
            "model": modelID,
            "cwd": workspace.cwd.path,
            "runtimeWorkspaceRoots": workspace.roots.map(\.path),
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "collaborationMode": [
                "mode": mode.rawValue,
                "settings": [
                    "model": modelID,
                    "reasoningEffort": effort.rawValue
                ]
            ]
        ]
        // Every turn of a read-only thread names its sandbox, so a resume can't widen it.
        if workspace.isReadOnly { turnParams["sandboxPolicy"] = ["type": "readOnly", "networkAccess": true] }
        // Before the request: the turn's first events can arrive ahead of its response, and a
        // command they end is this turn's to read, not background work.
        runningTurnThreadIDs.insert(threadID)
        let response: [String: Any]
        do {
            response = try await request(method: "turn/start", params: turnParams)
        } catch {
            runningTurnThreadIDs.remove(threadID)
            throw error
        }

        guard let turn = response["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            runningTurnThreadIDs.remove(threadID)
            throw ClientError.protocolFailure("Codex did not return a turn ID.")
        }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        let returnedStatus = turn["status"] as? String
        let turnAlreadyTerminal = completedTurns[turnKey] != nil
            || returnedStatus.map { ["completed", "failed", "interrupted"].contains($0) } == true
        context.turnID = turnAlreadyTerminal ? nil : turnID
        // Another request (a window following a Goal, or a send on another thread) may have
        // moved the single active slot while this turn started; this turn's context has it.
        if activeThreadID == threadID { activeTurnID = turnAlreadyTerminal ? nil : turnID }
        onTurnStarted(turnID)
        isTurnActive = !turnAlreadyTerminal
        if !turnAlreadyTerminal {
            ConversationSteerMailbox.publishActiveTurn(threadID: threadID, turnID: turnID)
            Self.processActiveThreadIDs.insert(threadID)
        }
        PlayhouseDiagnostics.record("codex.turn.started", fields: diagnosticFields([
            "threadID": threadID,
            "turnID": turnID,
            "turnStatus": returnedStatus ?? "unknown",
            "workspaceRootCount": String(workspace.roots.count),
        ]))

        switch turn["status"] as? String {
        case "completed":
            break
        case "failed", "interrupted":
            PlayhouseDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))
            throw ClientError.turnFailed(Self.turnFailureDescription(turn))
        default:
            let mailboxTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.turnContexts[threadID]?.turnID == turnID {
                    await self.serviceSteerMailbox(threadID: threadID, turnID: turnID)
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            defer { mailboxTask.cancel() }
            do {
                try await waitForTurn(turnKey)
            } catch {
                var fields = hideSensitiveRecoveryPrompt
                    ? ["errorDescription": "Private conversation recovery turn failed."]
                    : PlayhouseDiagnostics.errorFields(error)
                fields["threadID"] = threadID
                fields["turnID"] = turnID
                fields.merge(diagnosticFields()) { _, new in new }
                PlayhouseDiagnostics.record("codex.turn.wait_failed", fields: fields)
                throw error
            }
        }

    }
}
