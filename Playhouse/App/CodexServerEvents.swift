import Foundation
import AppKit
import SwiftData
import Darwin

extension CodexAppServerClient {
    func handleNotification(method: String, params: [String: Any]) {
        if let threadID = params["threadId"] as? String, let plain = plainTurns[threadID] {
            if plain.observe(method: method, params: params) {
                plainTurns[threadID] = nil
                releaseEphemeralThread(threadID)
            }
            return
        }
        // The warm thread of direct MCP calls runs no turns; its notifications are no conversation's.
        if let threadID = params["threadId"] as? String, threadID == mcpCallThread?.id { return }
        if let threadID = params["threadId"] as? String,
           let turnID = (params["turnId"] as? String) ?? (params["turn"] as? [String: Any])?["id"] as? String,
           rejectedTurnKeys.contains(Self.turnKey(threadID: threadID, turnID: turnID)) { return }
        let context = (params["threadId"] as? String).flatMap { turnContexts[$0] }
        if method == "turn/started" || method == "turn/completed", let threadID = params["threadId"] as? String,
           threadParents[threadID] == nil {
            if method == "turn/started" { runningTurnThreadIDs.insert(threadID) } else { runningTurnThreadIDs.remove(threadID) }
        }
        if ["item/started", "item/completed", "item/commandExecution/outputDelta"].contains(method) {
            noteCommandItem(method: method, params: params)
        }
        switch method {
        case "thread/status/changed":
            // Lifecycle authority stays with turn/started and turn/completed; the status is
            // kept to reconcile against, and to see a thread the app-server gave up on.
            guard let threadID = params["threadId"] as? String,
                  let status = (params["status"] as? [String: Any])?["type"] as? String else { return }
            if threadStatuses[threadID] != status {
                PlayhouseDiagnostics.record("codex.thread.status_changed", fields: diagnosticFields([
                    "threadID": threadID,
                    "status": status,
                ]))
            }
            threadStatuses[threadID] = status
        case "thread/goal/updated", "thread/goal/cleared":
            guard let threadID = params["threadId"] as? String else { return }
            goalStateThreadID = threadID
            goalStateRevision += 1
            noteGoalEvent()
        case "turn/started":
            // Server notifications use params {threadId, turn:{id,status,...}}.
            // A subagent's thread reports through its parent's turn instead.
            guard let threadID = params["threadId"] as? String,
                  context != nil || threadParents[threadID] == nil,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }
            if let pending = pendingCompactions[threadID], pending.turnID == nil {
                pending.turnID = turnID
            }
            context?.turnID = turnID
            if context == nil {
                contextlessTurnIDs[threadID] = turnID
                contextlessTurnEntries[threadID] = []
            } else if activeThreadID == threadID {
                activeTurnID = turnID
            }
            isTurnActive = true
            Self.processActiveThreadIDs.insert(threadID)
            if goalObservationThreadID == threadID {
                goalTurnStartRevision += 1
                goalTurnRevision += 1
                goalTurnStartedThreadID = threadID
                noteGoalEvent()
            }
        case "item/agentMessage/delta", "item/plan/delta":
            guard let context, let delta = params["delta"] as? String else { return }
            context.onDelta(delta)
        case "item/started", "item/completed":
            if goalObservationThreadID == (params["threadId"] as? String) {
                goalTurnRevision += 1
                noteGoalEvent()
            }
            // Buffered whether or not a recorder is registered yet, so one registered mid-turn
            // still records the whole turn when it ends.
            if context == nil, method == "item/completed",
               let threadID = params["threadId"] as? String, let turnID = params["turnId"] as? String,
               contextlessTurnIDs[threadID] == turnID,
               let item = params["item"] as? [String: Any] {
                contextlessTurnEntries[threadID, default: []].append(["turnId": turnID, "item": item])
            }
            guard let context, var item = params["item"] as? [String: Any] else { return }
            if let id = item["id"] as? String,
               let type = item["type"] as? String,
               ["userMessage", "agentMessage", "plan"].contains(type) {
                if context.messageTimestamps[id] == nil {
                    let observedAt = Date()
                    context.messageTimestamps[id] = observedAt
                    context.onMessageTimestamp(id, observedAt)
                }
            }
            if method == "item/completed",
               let itemType = item["type"] as? String,
               itemType == "agentMessage" || itemType == "plan" {
                let text = item["text"] as? String ?? ""
                let questions = itemType == "agentMessage" && item["delivery"] as? String == "async"
                    ? Self.asyncQuestions(from: item) : nil
                guard !text.isEmpty || questions != nil else { return }
                if itemType == "agentMessage", item["delivery"] as? String == "async",
                   let questions {
                    context.onProgress(ConversationMessage(
                        id: item["id"] as? String ?? UUID().uuidString,
                        role: .assistant,
                        text: text,
                        phase: item["phase"] as? String,
                        turnID: params["turnId"] as? String,
                        asyncQuestions: questions
                    ))
                } else if itemType == "agentMessage", item["phase"] as? String == "commentary" {
                    context.onProgress(ConversationMessage(
                        id: item["id"] as? String ?? UUID().uuidString,
                        role: .assistant,
                        text: text,
                        phase: "commentary",
                        turnID: params["turnId"] as? String
                    ))
                } else {
                    context.onFinal(text)
                }
            }
            let activityID = item["type"] as? String == "subAgentActivity"
                ? (item["agentThreadId"] as? String ?? item["id"] as? String)
                : item["id"] as? String
            guard let activityID else { return }
            if method == "item/started" {
                context.startedAtUptime[activityID] = context.startedAtUptime[activityID] ?? DispatchTime.now().uptimeNanoseconds
                context.startedAtDate[activityID] = context.startedAtDate[activityID] ?? .now
            }
            let measuredDuration: Int?
            if method == "item/completed", let started = context.startedAtUptime[activityID] {
                measuredDuration = max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
            } else {
                measuredDuration = nil
            }
            // A subagent's terminal event may omit the path and model its start reported.
            if item["type"] as? String == "subAgentActivity", let started = context.activities[activityID] {
                if item["agentPath"] == nil, let path = started.agentPath { item["agentPath"] = path }
                if item["model"] == nil, let model = started.model { item["model"] = model }
                if item["reasoningEffort"] == nil, let effort = started.reasoningEffort { item["reasoningEffort"] = effort }
            }
            guard let activity = ConversationActivity.from(
                item: item,
                lifecycle: method == "item/completed" ? "completed" : "inProgress",
                turnID: params["turnId"] as? String,
                startedAt: context.startedAtDate[activityID],
                measuredDurationMs: measuredDuration
            ) else { return }
            if method == "item/completed" {
                if let diff = ConversationTurnDiff.fromFileChangeItems([item]) { context.onDiff(diff) }
                if let durationMs = activity.durationMs { context.durations[activity.id] = durationMs }
                context.startedAtUptime.removeValue(forKey: activityID)
                context.startedAtDate.removeValue(forKey: activityID)
            }
            context.activities[activity.id] = activity
            context.onActivity(activity)
        case "item/commandExecution/outputDelta":
            guard let context, let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String,
                  var activity = context.activities[itemID] else { return }
            let output = String((activity.detail + delta).suffix(2_000))
            activity.detail = output
            context.activities[itemID] = activity
            context.onActivity(activity)
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let id = thread["id"] as? String,
               let parent = thread["parentThreadId"] as? String
                ?? (((thread["source"] as? [String: Any])?["subAgent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String {
                threadParents[id] = parent
            }
        case "thread/tokenUsage/updated":
            reportCallUsage(params)
        case "account/rateLimits/updated":
            if let snapshot = params["rateLimits"] as? [String: Any] {
                AgentUsageStore.shared(scope: runtimeScope).recordCodexUpdate(snapshot)
            }
        case "account/login/completed", "account/updated":
            Task { await refreshAgentUsage() }
        case "turn/diff/updated":
            guard let context, let diff = params["diff"] as? String, !diff.isEmpty else { return }
            context.onDiff(ConversationTurnDiff(unifiedDiff: diff))
        case "turn/completed":
            // A terminal notification has the same threadId/turn envelope; only a matching waiter completes.
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }

            flushDeltaLogSummaries(threadID: threadID, turnID: turnID, reason: "turn_completed")

            // The app-server reports a turn's cost on its terminal notification,
            // either beside the turn envelope or inside it.
            if let context,
               let payload = (params["usage"] as? [String: Any]) ?? (turn["usage"] as? [String: Any]) {
                let usage = ConversationTokenUsage(codexPayload: payload)
                if usage.isEmpty {
                    // A non-empty payload that parses to all zeros means the
                    // app-server changed its usage field names; silently
                    // dropping it would make a real regression invisible.
                    PlayhouseDiagnostics.record("codex.turn.usage_unparsed", fields: diagnosticFields([
                        "threadID": threadID,
                        "turnID": turnID,
                        "payloadKeys": payload.keys.sorted().joined(separator: ","),
                    ]))
                } else {
                    context.onTokenUsage(ConversationTurnUsageReport(
                        turnID: turnID,
                        usage: usage,
                        toolLabels: Array(Set(context.activities.values.map(\.tokenUsageLabel))).sorted()
                    ))
                }
            }

            // Real app-servers report cost per model call instead, so the turn's
            // row is the sum of the calls seen during it.
            if let context, params["usage"] == nil, turn["usage"] == nil, !context.callUsage.isEmpty {
                context.onTokenUsage(ConversationTurnUsageReport(
                    turnID: turnID,
                    usage: context.callUsage,
                    toolLabels: Array(Set(context.activities.values.map(\.tokenUsageLabel))).sorted()
                ))
                context.callUsage = ConversationTokenUsage()
            }

            PlayhouseDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))

            let isMatchingActiveTurn = activeThreadID == threadID && activeTurnID == turnID
            let isContextlessTurn = contextlessTurnIDs[threadID] == turnID
            if isMatchingActiveTurn {
                activeTurnID = nil
                isTurnActive = false
                Self.processActiveThreadIDs.remove(threadID)
                ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            }
            if isContextlessTurn {
                PlayhouseDiagnostics.record("codex.contextless_turn.ended", fields: diagnosticFields([
                    "threadID": threadID,
                    "turnID": turnID,
                    "hasRecorder": contextlessTurnRecorders[threadID] == nil ? "false" : "true",
                    "itemCount": String(contextlessTurnEntries[threadID]?.count ?? 0),
                ]))
                contextlessTurnRecorders[threadID]?(turnID, contextlessTurnEntries[threadID] ?? [])
                contextlessTurnEntries.removeValue(forKey: threadID)
                contextlessTurnIDs.removeValue(forKey: threadID)
                isTurnActive = turnContexts.values.contains { $0.turnID != nil } || !contextlessTurnIDs.isEmpty
                Self.processActiveThreadIDs.remove(threadID)
                ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            }

            let key = Self.turnKey(threadID: threadID, turnID: turnID)
            let result: Result<Void, Error>
            if turn["status"] as? String == "completed" {
                result = .success(())
            } else {
                result = .failure(ClientError.turnFailed(Self.turnFailureDescription(turn)))
            }

            if let pending = pendingCompactions[threadID], pending.turnID == turnID {
                pending.result = result
                return
            }

            if goalObservationThreadID == threadID, isContextlessTurn {
                goalTurnCompletedTurnID = turnID
                goalTurnRevision += 1
                goalTurnCompletedRevision += 1
                noteGoalEvent()
                return
            }

            if let waiter = turnWaiters.removeValue(forKey: key) {
                switch result {
                case .success:
                    waiter.resume()
                case .failure(let error):
                    waiter.resume(throwing: error)
                }
            } else {
                completedTurns[key] = result
            }
        default:
            break
        }
    }

    func handleServerRequest(method: String, params: [String: Any], requestID: Any, from source: AnyObject?) async {
        let normalizedMethod = method.lowercased()
        if normalizedMethod.contains("approval") || normalizedMethod.contains("item/tool/") ||
            normalizedMethod.contains("elicitation"),
           method != "item/tool/requestUserInput", method != "tool/requestUserInput" {
            if let threadID = params["threadId"] as? String, let context = turnContexts[threadID] {
                context.onAction()
            }
        }

        let result: [String: Any]
        switch method {
        case "item/tool/requestUserInput", "tool/requestUserInput":
            guard let questionsRaw = params["questions"] as? [[String: Any]],
                  let threadID = params["threadId"] as? String,
                  let requestIDString = requestID as? String ?? (requestID as? NSNumber)?.stringValue else {
                sendServerError(requestID: requestID, code: -32602, message: "Invalid user input request.")
                return
            }
            let questions = questionsRaw.compactMap { raw -> ConversationUserQuestion? in
                guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
                let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> ConversationUserQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return ConversationUserQuestion.Option(label: label, description: option["description"] as? String)
                }
                return ConversationUserQuestion(id: id, header: raw["header"] as? String ?? "Question", question: question,
                                         options: options, allowsOther: raw["isOther"] as? Bool ?? false,
                                         isSecret: raw["isSecret"] as? Bool ?? false)
            }
            guard !questions.isEmpty else {
                sendServerError(requestID: requestID, code: -32602, message: "The request did not contain any questions.")
                return
            }
            guard Set(questions.map(\.id)).count == questions.count else {
                sendServerError(requestID: requestID, code: -32602, message: "Question IDs must be unique.")
                return
            }
            guard let context = userInputContexts[threadID] else {
                // A shared app-server sends the request to every connected client; the client whose
                // turn raised it answers. Rejecting it here could win that race and fail the turn, and
                // when no client owns it yet the server keeps it for the client that resumes the thread.
                if socketConnection != nil {
                    PlayhouseDiagnostics.record("codex.user_input.unowned_ignored", fields: diagnosticFields(["threadID": threadID]))
                    return
                }
                sendServerError(requestID: requestID, code: -32000, message: "No conversation owns this question request.")
                return
            }
            let request = ConversationUserInputRequest(
                id: requestIDString,
                threadID: threadID,
                questions: questions,
                isBlocking: context.mode == .plan || (params["isBlocking"] as? Bool ?? true),
                mode: context.mode
            )
            pendingUserInputs[threadID] = PendingUserInput(nativeID: requestID, request: request, asker: source)
            pendingUserInputRequest = request
            await context.handler(request)
            return
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "item/permissions/requestApproval":
            result = ["permissions": [:], "scope": "turn"]
        case "applyPatchApproval", "execCommandApproval":
            result = [
                "decision": [
                    "denied": ["rejection": "Playhouse is configured without approval prompts; this action was not approved."]
                ]
            ]
        case "mcpServer/elicitation/request":
            result = ["action": "decline"]
        default:
            sendServerError(
                requestID: requestID,
                code: -32601,
                message: "Playhouse does not provide this optional integration."
            )
            return
        }

        do {
            try sendJSON(["jsonrpc": "2.0", "id": requestID, "result": result])
        } catch {
            actionRequestHandler?()
        }
    }

    func sendServerError(requestID: Any, code: Int, message: String) {
        try? sendJSON([
            "jsonrpc": "2.0",
            "id": requestID,
            "error": ["code": code, "message": message]
        ])
    }
}
