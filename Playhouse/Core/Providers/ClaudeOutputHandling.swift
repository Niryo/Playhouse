import Foundation

extension ClaudeSessionRunner {
    package func handle(_ message: [String: Any]) async {
        switch message["type"] as? String {
        case "control_response":
            guard let response = message["response"] as? [String: Any],
                  let requestID = response["request_id"] as? String,
                  let continuation = pendingControlRequests.removeValue(forKey: requestID) else { return }
            if response["subtype"] as? String == "error" {
                continuation.resume(throwing: ClientError.protocolFailure(response["error"] as? String ?? "Claude Code rejected a control request."))
            } else {
                continuation.resume(returning: response["response"] as? [String: Any] ?? [:])
            }
        case "control_request":
            guard let requestID = message["request_id"] as? String,
                  let request = message["request"] as? [String: Any] else { return }
            await handleControlRequest(requestID: requestID, request: request)
        case "command_lifecycle":
            sawCommandLifecycle = true
            guard let uuid = message["command_uuid"] as? String,
                  ["completed", "cancelled", "failed"].contains(message["state"] as? String ?? "") else { return }
            pendingCommandUUIDs.remove(uuid)
            completeTurnIfSettled()
        case "stream_event":
            guard message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil else { return }
            noteParentResponseStarted()
            // A new parent request carries any notification queued before it.
            if (message["event"] as? [String: Any])?["type"] as? String == "message_start" {
                setAwaitingParentWake(false)
            }
            guard let event = message["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            deltaHandler?(text)
        case "assistant":
            handleAssistant(message)
        case "user":
            if handleSyntheticUserMessage(message) { return }
            handleToolResults(message)
        case "system":
            handleSystem(message)
        case "result":
            handleResult(message)
        case "rate_limit_event":
            // Account-wide, so it feeds the shared store rather than this turn.
            guard !isReplaying else { return }
            AgentUsageStore.shared(scope: owner?.runtimeScope).recordClaudeEvent(message)
        default:
            break
        }
    }

    package func handleControlRequest(requestID: String, request: [String: Any]) async {
        // A previous daemon of this run already answered it.
        if let agentRun, agentRun.manifest.hasAnswered(requestID) { return }
        if isReplaying {
            // Only a question still waiting for the user carries over from handled lines.
            guard agentRun?.manifest.pendingRequestIDs.contains(requestID) == true,
                  request["tool_name"] as? String == "AskUserQuestion" else { return }
            presentQuestions(requestID: requestID, input: request["input"] as? [String: Any] ?? [:])
            return
        }
        guard request["subtype"] as? String == "can_use_tool" else {
            if request["subtype"] as? String == "elicitation" { actionRequestHandler?() }
            sendControlError(requestID: requestID, message: "Playhouse does not provide this optional integration.")
            return
        }
        let toolName = request["tool_name"] as? String ?? ""
        let input = request["input"] as? [String: Any] ?? [:]
        switch toolName {
        case "AskUserQuestion":
            presentQuestions(requestID: requestID, input: input)
        case "ExitPlanMode" where activeMode == .plan:
            // Playhouse keeps plan mode until the user starts implementation, so the
            // plan becomes this turn's answer and Claude stops without editing.
            closePendingAssistantText()
            let plan = (input["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !plan.isEmpty {
                planWasPresented = true
                finalMessageHandler?(plan)
            }
            try? sendControlResponse(requestID: requestID, response: [
                "behavior": "deny",
                "message": "Playhouse showed this plan to the user, who will reply in a later message. End your turn now without further output."
            ])
        case _ where activeReadOnly && !ClaudeSessionRunner.readOnlyAllows(toolName: toolName, input: input):
            try? sendControlResponse(requestID: requestID, response: [
                "behavior": "deny",
                "message": SideChatReadOnlyPolicy.denialMessage
            ])
        default:
            // Code mode runs without approval prompts. Claude Code has already
            // applied the user's native allow and deny rules before asking.
            try? sendControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": input])
        }
    }

    /// The tools a read-only turn never gets, removed from its launch as well as denied.
    package static let readOnlyDeniedTools = SideChatReadOnlyPolicy.deniedTools

    /// Whether a read-only turn may use a tool Claude Code asked about (see `SideChatReadOnlyPolicy`).
    package static func readOnlyAllows(toolName: String, input: [String: Any]) -> Bool {
        SideChatReadOnlyPolicy.allows(toolName: toolName, input: input, cliPaths: [TaskThreadDeveloperInstructions.cliExecutableURL().path])
    }

    /// The launch's `--settings` with the read-only `PreToolUse` hook added, so every tool call
    /// is checked before the user's own Claude Code allow rules can approve it.
    package static func readOnlySettings(_ settings: String?) -> String? {
        var object = settings.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
        let cli = TaskThreadDeveloperInstructions.cliExecutableURL().path
        let command = ([cli] + SideChatReadOnlyPolicy.hookSubcommand)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append(["matcher": "*", "hooks": [["type": "command", "command": command]]])
        hooks["PreToolUse"] = preToolUse
        object["hooks"] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return settings }
        return String(data: data, encoding: .utf8)
    }

    package func presentQuestions(requestID: String, input: [String: Any]) {
        let rawQuestions = input["questions"] as? [[String: Any]] ?? []
        let questions = rawQuestions.enumerated().compactMap { index, raw -> ConversationUserQuestion? in
            guard let question = raw["question"] as? String, !question.isEmpty else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> ConversationUserQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return .init(label: label, description: option["description"] as? String)
            }
            return ConversationUserQuestion(
                id: "question-\(index + 1)", header: raw["header"] as? String ?? "Question",
                question: question, options: options, allowsOther: true, isSecret: false
            )
        }
        guard !questions.isEmpty else {
            try? sendControlResponse(requestID: requestID, response: ["behavior": "deny", "message": "The question had no content."])
            return
        }
        closePendingAssistantText()
        pendingQuestion = PendingQuestion(controlRequestID: requestID, sessionID: sessionID, input: input, questions: questions)
        if !isReplaying { agentRun?.notePending(requestID) }
        let request = ConversationUserInputRequest(id: requestID, threadID: sessionID, questions: questions, isBlocking: true, mode: activeMode)
        pendingUserInputRequest = request
        owner?.runnerStateChanged(self)
        let handler = userInputHandler
        Task { @MainActor in await handler?(request) }
    }

    package func clearPendingQuestion() {
        pendingQuestion = nil
        pendingUserInputRequest = nil
        owner?.runnerStateChanged(self)
    }
}
