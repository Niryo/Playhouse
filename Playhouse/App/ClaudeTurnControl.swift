import Foundation
import AppKit
import SwiftData
import Darwin

extension ClaudeSessionRunner {
    func runTurn(
        text: String,
        imageDataURLs: [String],
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort,
        workspace: ConversationWorkspaceContext,
        isNewSession: Bool,
        sessionRecoveryContext: String?,
        developerInstructions: String?,
        sensitiveUserInputAnswerValues: [String],
        hideSensitiveRecoveryPrompt: Bool
    ) async throws {
        activeMode = mode
        activeReadOnly = workspace.isReadOnly
        wakeGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS", default: ClaudeSessionRunner.parentWakeGracePeriod
        )
        wokenSilenceGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS", default: ClaudeSessionRunner.wokenTurnSilenceGracePeriod
        )
        var providerPrompt = text
        var initialize: [String: Any]
        do {
            initialize = try await launch(
                resume: !isNewSession, mode: mode, modelID: modelID, effort: effort,
                workspace: workspace, developerInstructions: developerInstructions
            )
        } catch ClientError.sessionNotFound {
            // A new session ID may have been persisted before its first turn
            // reached Claude Code. A missing resumed session needs the visible
            // Playhouse transcript so Claude does not silently lose its context.
            if !isNewSession {
                providerPrompt = ConversationHandoff.prompt(
                    ConversationHandoff.stripContext(from: text),
                    context: sessionRecoveryContext
                )
            }
            stopProcess()
            initialize = try await launch(
                resume: false, mode: mode, modelID: modelID, effort: effort,
                workspace: workspace, developerInstructions: developerInstructions
            )
        }
        // Claude Code has the session now. A turn that fails after this point
        // still leaves the transcript behind, so the next turn resumes it.
        sessionExists = true
        try ClaudeCodeClient.verifyVersion(initialize["claude_code_version"] as? String)

        let turnID = UUID().uuidString.lowercased()
        let userMessageID = UUID().uuidString.lowercased()
        activeTurnID = turnID
        turnCompletion = TurnCompletion()
        parentWakeBackstopGeneration += 1
        pendingCommandUUIDs = [userMessageID]
        // Active before the write, which suspends: Claude Code can answer before it returns,
        // and the runner must not look idle meanwhile.
        isTurnActive = true
        do {
            try await writeUserMessage(text: providerPrompt, imageDataURLs: imageDataURLs, uuid: userMessageID, priority: nil)
        } catch {
            isTurnActive = false
            throw error
        }
        owner?.runnerStateChanged(self)
        ClaudeCodeClient.markProcessActive(sessionID: sessionID)
        ConversationSteerMailbox.publishActiveTurn(threadID: sessionID, turnID: turnID)
        turnStartedHandler?(turnID)
        turnStartedHandler = nil
        PlayhouseDiagnostics.record("claude.turn.started", fields: diagnosticFields([
            "threadID": sessionID,
            "turnID": turnID,
            "mode": mode.rawValue,
            "workspaceRootCount": String(workspace.roots.count)
        ]))

        let mailboxTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.activeTurnID == turnID {
                await ConversationSteerMailbox.service(threadID: self.sessionID, turnID: turnID) { text, images in
                    let accepted = try await self.sendSteerInput(text: text, imageDataURLs: images)
                    if accepted { self.steerMessageHandler?(text, images) }
                    return accepted
                } interrupt: {
                    try await self.interrupt()
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        defer { mailboxTask.cancel() }
        do {
            try await waitForTurnCompletion()
            PlayhouseDiagnostics.record("claude.turn.ended", fields: diagnosticFields([
                "threadID": sessionID, "turnID": turnID, "turnStatus": "completed"
            ]))
        } catch {
            var fields = hideSensitiveRecoveryPrompt
                ? ["error": "Private conversation recovery turn failed."]
                : PlayhouseDiagnostics.errorFields(error, redacting: sensitiveUserInputAnswerValues)
            fields["threadID"] = sessionID
            fields["turnID"] = turnID
            fields["turnStatus"] = wasInterrupted ? "interrupted" : "failed"
            fields.merge(diagnosticFields([:])) { _, new in new }
            PlayhouseDiagnostics.record("claude.turn.ended", fields: fields)
            throw error
        }
    }

    func finishTurnCleanup() {
        ClaudeCodeClient.clearProcessActive(sessionID: sessionID)
        ConversationSteerMailbox.clearActiveTurn(threadID: sessionID)
        activeTurnID = nil
        activeMode = .code
        activeReadOnly = false
        isTurnActive = false
        pendingQuestion = nil
        pendingUserInputRequest = nil
        deltaHandler = nil
        finalMessageHandler = nil
        recordedFinalHandler = nil
        progressMessageHandler = nil
        steerMessageHandler = nil
        activityHandler = nil
        userInputHandler = nil
        stopProcess()
    }

    func interrupt() async throws -> Bool {
        guard activeTurnID != nil, isAgentRunning else { return false }
        wasInterrupted = true
        do {
            _ = try await controlRequest(["subtype": "interrupt"])
            return true
        } catch {
            wasInterrupted = false
            throw error
        }
    }

    /// Delivers input into the running turn with `priority: "next"`, which Claude
    /// Code injects at its next tool boundary without cancelling in-flight work.
    /// A turn Claude Code answered but that this runner still holds open — for
    /// an outstanding background task, an undelivered notification, or a parent
    /// wake — is as steerable as one still streaming: Playhouse keeps showing it
    /// as the active turn, so its input must still reach the running process.
    func sendSteerInput(text: String, imageDataURLs: [String]) async throws -> Bool {
        guard isTurnActive, activeTurnID != nil, isAgentRunning,
              !isTurnSettled || !turnCompletion.resultReceived || !pendingCommandUUIDs.isEmpty else {
            // A refusal is invisible to the user — the follow-up just stays
            // queued — so record why the runtime turned it down.
            PlayhouseDiagnostics.record("claude.turn.steer_rejected", fields: diagnosticFields([
                "isTurnSettled": String(isTurnSettled),
                "resultReceived": String(turnCompletion.resultReceived),
                "pendingCommandCount": String(pendingCommandUUIDs.count),
                "processRunning": String(isAgentRunning),
                "outstandingBackgroundTaskCount": String(outstandingBackgroundTaskIDs.count),
                "pendingBackgroundNotificationCount": String(pendingBackgroundTaskNotificationIDs.count),
                "awaitingParentWake": String(turnCompletion.awaitingParentWake),
                "resultCount": String(turnCompletion.resultCount),
                "wokenTurnCount": String(turnCompletion.wokenTurnCount)
            ]))
            return false
        }
        // What Claude wrote before this input is recorded above it, before its reply can start.
        // A daemon that replays this run does not see the write, but Claude's reply re-records
        // that answer under the same ID.
        recordHeldAnswer()
        let uuid = UUID().uuidString.lowercased()
        pendingCommandUUIDs.insert(uuid)
        do {
            try await writeUserMessage(text: text, imageDataURLs: imageDataURLs, uuid: uuid, priority: "next")
        } catch {
            pendingCommandUUIDs.remove(uuid)
            throw error
        }
        // The answer to this input, not the result that preceded it, ends the turn.
        if turnCompletion.resultError == nil { turnCompletion.resultReceived = false }
        PlayhouseDiagnostics.record("claude.turn.steered", fields: diagnosticFields(["imageCount": String(imageDataURLs.count)]))
        return true
    }

    func answerUserInput(requestID: String, answers: [String: [String]]) -> Bool {
        guard let pending = pendingQuestion, pending.controlRequestID == requestID else { return false }
        let questionsByID = Dictionary(uniqueKeysWithValues: pending.questions.map { ($0.id, $0) })
        let valid = Set(answers.keys) == Set(questionsByID.keys) && answers.allSatisfy { id, values in
            guard !values.isEmpty, let question = questionsByID[id] else { return false }
            return values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && (question.allowsOther || values.allSatisfy { value in question.options.contains { $0.label == value } })
        }
        guard valid else {
            PlayhouseDiagnostics.record("claude.user_input.answer.failed", fields: [
                "requestID": requestID, "threadID": sessionID, "reason": "invalid_answer_shape"
            ])
            return false
        }
        var updatedInput = pending.input
        var answerMap: [String: String] = [:]
        for question in pending.questions {
            answerMap[question.question] = (answers[question.id] ?? []).joined(separator: ", ")
        }
        updatedInput["answers"] = answerMap
        do {
            try sendControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": updatedInput])
        } catch {
            actionRequestHandler?()
            return false
        }
        agentRun?.commitAnswer(requestID)
        clearPendingQuestion()
        PlayhouseDiagnostics.record("claude.user_input.answer.succeeded", fields: [
            "requestID": requestID, "threadID": sessionID, "questionCount": String(answers.count)
        ])
        return true
    }

    func rejectUserInput(requestID: String, message: String) {
        guard let pending = pendingQuestion, pending.controlRequestID == requestID else { return }
        clearPendingQuestion()
        try? sendControlResponse(requestID: requestID, response: ["behavior": "deny", "message": message, "interrupt": true])
        agentRun?.commitAnswer(requestID)
        finishTurn(.failure(ClientError.turnFailed(message)))
    }

    func shutdown() {
        stopProcess()
    }
}
