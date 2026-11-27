import Foundation

extension ClaudeSessionRunner {
    package func reportLiveCall(_ body: [String: Any], agentID: String?) {
        guard let id = body["id"] as? String, let payload = body["usage"] as? [String: Any] else { return }
        let usage = ConversationTokenUsage(providerPayload: payload)
        let sent = usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens
        guard sent + usage.outputTokens > 0 else { return }
        let previous = liveCallUsage[id]
        guard previous?.sent != sent || previous?.output != usage.outputTokens else { return }
        liveCallUsage[id] = (sent, usage.outputTokens, usage)
        tokenUsageHandler?(ConversationTurnUsageReport(
            turnID: nil, usage: ConversationTokenUsage(), toolLabels: [],
            liveCall: ConversationLiveCall(
                agentID: agentID,
                calls: previous == nil ? 1 : 0,
                sentTokens: sent - (previous?.sent ?? 0),
                outputTokens: usage.outputTokens - (previous?.output ?? 0),
                uncachedInputTokens: usage.inputTokens - (previous?.usage.inputTokens ?? 0),
                cacheReadTokens: usage.cacheReadTokens - (previous?.usage.cacheReadTokens ?? 0),
                cacheWriteTokens: usage.cacheCreationTokens - (previous?.usage.cacheCreationTokens ?? 0),
                contextTokens: sent
            )
        ))
    }

    package func handleAssistant(_ message: [String: Any]) {
        guard let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        let parentToolID = message["parent_tool_use_id"] as? String
        reportLiveCall(body, agentID: parentToolID)
        let messageID = body["id"] as? String ?? UUID().uuidString
        if parentToolID == nil { noteParentResponseStarted() }
        for (index, block) in content.enumerated() {
            switch block["type"] as? String {
            case "text":
                guard parentToolID == nil, !planWasPresented,
                      let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let pending = pendingAssistantText, pendingTextSpansOutcomeReport {
                    // Claude often answers, reports the outcome, then adds a closing
                    // line; the answer must not be demoted to commentary.
                    pendingAssistantText = (pending.id, pending.text + "\n\n" + text, false)
                    pendingTextSpansOutcomeReport = false
                    continue
                }
                closePendingAssistantText()
                pendingAssistantText = ("\(messageID)-\(index)", text, false)
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                if let parentToolID {
                    noteSubagentProgress(parentToolID: parentToolID, toolName: name)
                    continue
                }
                if name == "AskUserQuestion" || (name == "ExitPlanMode" && activeMode == .plan) { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                // Playhouse's own progress, outcome, and chat page reports are
                // bookkeeping, not work, so they don't turn the answer written
                // before them into commentary.
                let report = ClaudeCodeClient.reportCommand(name: name, input: input)
                if let pending = pendingAssistantText, let report {
                    // An answer a result or a steer already closed is not extended by later text.
                    if report == .outcome, !pending.recorded { pendingTextSpansOutcomeReport = true }
                } else {
                    closePendingAssistantText()
                }
                activityStartedAtUptime[toolID] = DispatchTime.now().uptimeNanoseconds
                if ["Task", "Agent", "Bash"].contains(name), input["run_in_background"] as? Bool == true {
                    backgroundedToolUseIDs.insert(toolID)
                }
                let activity = ClaudeCodeClient.activity(toolID: toolID, name: name, input: input, status: "inProgress", turnID: activeTurnID)
                toolActivities[toolID] = activity
                activityHandler?(activity)
            default:
                continue
            }
        }
    }

    package func noteSubagentProgress(parentToolID: String, toolName: String) {
        guard var activity = toolActivities[parentToolID], activity.isSubagent else { return }
        activity.detail = [activity.agentPath, "Using \(toolName)"].compactMap { $0 }.joined(separator: "\n")
        toolActivities[parentToolID] = activity
        activityHandler?(activity)
    }

    /// Claude Code adds a user message of its own inside a turn, for example when the turn ended
    /// on a tool call with no visible text after it. It is not the user's, so it is recorded as an
    /// automatic notice. The answer written before it is closed as its own final message, so
    /// whatever Claude writes in response is a separate message rather than appended to it.
    package func handleSyntheticUserMessage(_ message: [String: Any]) -> Bool {
        guard message["isSynthetic"] as? Bool == true,
              message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil,
              let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return false }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let pending = pendingAssistantText {
            pendingAssistantText = nil
            pendingTextSpansOutcomeReport = false
            emitFinal(pending)
        }
        // The event's own ID keeps a replayed run from recording the notice twice.
        let id = "claude-notice-\((message["uuid"] as? String) ?? UUID().uuidString.lowercased())"
        progressMessageHandler?(ConversationMessage(
            id: id, role: .user, text: ProviderAutomaticNotice.claudeCode(text), turnID: activeTurnID, provider: .claude
        ))
        return true
    }

    package func handleToolResults(_ message: [String: Any]) {
        guard message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil,
              let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String, var activity = toolActivities[toolID] else { continue }
            let output = ClaudeCodeClient.resultText(block["content"])
            // A backgrounded Agent/Task call's tool_result only confirms the launch,
            // not completion; its real outcome arrives later as a system task event.
            // The launch confirmation is still what the call returned.
            if backgroundedToolUseIDs.contains(toolID) {
                if activity.isTimelineToolCall, activity.input != nil, !output.isEmpty {
                    activity.output = String(output.suffix(2_000))
                    toolActivities[toolID] = activity
                    activityHandler?(activity)
                }
                continue
            }
            let isError = block["is_error"] as? Bool ?? false
            var detail = activity.detail
            if !output.isEmpty, activity.toolKind != "mcp" {
                detail = [detail, String(output.suffix(2_000))].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            let duration = activityStartedAtUptime.removeValue(forKey: toolID).map {
                max(1, Int((DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000))
            }
            activity = ConversationActivity(
                id: activity.id, title: activity.title, detail: detail, status: isError ? "failed" : "completed",
                childThreadID: activity.childThreadID, agentPath: activity.agentPath, model: activity.model,
                toolKind: activity.toolKind, server: activity.server, tool: activity.tool,
                durationMs: duration, turnID: activity.turnID,
                summary: activity.summary, input: activity.input,
                // Only a call with an IN block shows what it returned; a file read's
                // contents, say, would just repeat the file.
                output: activity.isTimelineToolCall && activity.input != nil && !output.isEmpty
                    ? String(output.suffix(2_000)) : activity.output
            )
            if let duration { activityDurations[activity.id] = duration }
            toolActivities[toolID] = activity
            activityHandler?(activity)
        }
    }

    /// Background Agent/Task progress arrives as `system` events (enabled by
    /// `--forward-subagent-text`), not as a `tool_result` on the launching turn,
    /// since the agent can keep running after that turn's own answer is given.
    package func handleSystem(_ message: [String: Any]) {
        guard let subtype = message["subtype"] as? String else { return }
        switch subtype {
        case "init":
            // Claude Code starts a provider turn of its own to deliver a finished
            // background task; that turn's result also belongs to this one. The
            // wake itself stays pending until that turn's parent request starts,
            // which is what clears it below: `init` alone means Claude Code has
            // not delivered the notification yet, and a turn that counted the
            // woken result here while clearing the wake could look settled with
            // nothing running — stranding the turn open (no backstop is armed
            // once the wake is clear) and making the runtime refuse steered
            // input for a turn Playhouse still shows as active.
            if turnCompletion.awaitingParentWake, !turnCompletion.countedWakeInit {
                turnCompletion.countedWakeInit = true
                turnCompletion.wokenTurnCount += 1
                scheduleParentWakeBackstopIfNeeded()
            }
        case "status":
            // Claude Code compacts before the call that would cross its
            // auto-compact window, and for `/compact`; either way it reports
            // the start here and the result as a boundary.
            if message["status"] as? String == "compacting" {
                // Claude Code can report one compaction's start more than once; it stays one row.
                let rowID = pendingCompactionActivityID
                    ?? "claude-compaction-\((message["uuid"] as? String) ?? UUID().uuidString.lowercased())"
                pendingCompactionActivityID = rowID
                activityHandler?(compactionActivity(id: rowID, status: "inProgress", details: nil))
            } else if let result = message["compact_result"] as? String, result != "success",
                      let pending = pendingCompactionActivityID {
                pendingCompactionActivityID = nil
                activityHandler?(compactionActivity(id: pending, status: "failed", details: nil))
            }
        case "compact_boundary":
            let metadata = message["compact_metadata"] as? [String: Any] ?? [:]
            let rowID = pendingCompactionActivityID
                ?? "claude-compaction-\((message["uuid"] as? String) ?? UUID().uuidString.lowercased())"
            pendingCompactionActivityID = nil
            let details = ContextCompactionDetails(
                trigger: .reported(metadata["trigger"] as? String, requested: compactionTrigger),
                preTokens: (metadata["pre_tokens"] as? NSNumber)?.intValue,
                postTokens: (metadata["post_tokens"] as? NSNumber)?.intValue
            )
            activityHandler?(compactionActivity(id: rowID, status: "completed", details: details))
        case "background_tasks_changed":
            let tasks = message["tasks"] as? [[String: Any]] ?? []
            outstandingBackgroundTaskIDs = Set(tasks.compactMap { $0["task_id"] as? String })
            completeTurnIfSettled()
        case "task_started":
            guard let taskID = message["task_id"] as? String,
                  let toolUseID = message["tool_use_id"] as? String else { return }
            let taskType = message["task_type"] as? String
            guard message["owned_by_subagent"] as? Bool != true,
                  taskType == "local_agent" || taskType == "local_bash" else {
                nestedBackgroundTaskIDs.insert(taskID)
                return
            }
            if taskType == "local_bash" { backgroundShellTaskIDs.insert(taskID) }
            pendingBackgroundTaskNotificationIDs.insert(taskID)
            backgroundTaskToolUseIDs[taskID] = toolUseID
            guard var activity = toolActivities[toolUseID] else { return }
            activity.backgroundTaskID = taskID
            toolActivities[toolUseID] = activity
            activityHandler?(activity)
        case "task_progress":
            guard let taskID = message["task_id"] as? String, !nestedBackgroundTaskIDs.contains(taskID),
                  let toolUseID = (message["tool_use_id"] as? String) ?? backgroundTaskToolUseIDs[taskID],
                  var activity = toolActivities[toolUseID] else { return }
            let lastTool = message["last_tool_name"] as? String
            activity.detail = [activity.agentPath, lastTool.map { "Using \($0)" }].compactMap { $0 }.joined(separator: "\n")
            activity.backgroundTaskID = taskID
            toolActivities[toolUseID] = activity
            activityHandler?(activity)
        case "task_updated", "task_notification":
            guard let taskID = message["task_id"] as? String else { return }
            let isTaskNotification = subtype == "task_notification"
            if isTaskNotification {
                outstandingBackgroundTaskIDs.remove(taskID)
                pendingBackgroundTaskNotificationIDs.remove(taskID)
            }
            guard !nestedBackgroundTaskIDs.contains(taskID) else { return }
            // Claude Code delivers every top-level notification to the parent.
            if isTaskNotification { setAwaitingParentWake(true) }
            let isShell = backgroundShellTaskIDs.contains(taskID)
            let patch = message["patch"] as? [String: Any]
            guard let rawStatus = (message["status"] as? String) ?? (patch?["status"] as? String) else {
                completeTurnIfSettled()
                return
            }
            let status = Self.resolvedBackgroundTaskStatus(rawStatus)
            let summary = message["summary"] as? String
            // A task_updated event can report a terminal status before Claude
            // sends the task_notification containing the actual agent result.
            // Keep the activity and parent turn open until that result arrives.
            if !isTaskNotification, status != "inProgress" {
                pendingBackgroundTaskNotificationIDs.insert(taskID)
                completeTurnIfSettled()
                return
            }
            if let toolUseID = (message["tool_use_id"] as? String) ?? backgroundTaskToolUseIDs[taskID],
               let existing = toolActivities[toolUseID] {
                let duration = activityStartedAtUptime.removeValue(forKey: toolUseID).map {
                    max(1, Int((DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000))
                }
                let activity = ConversationActivity(
                    id: existing.id, title: existing.title, detail: summary ?? existing.detail, status: status,
                    childThreadID: existing.childThreadID, agentPath: existing.agentPath, model: existing.model,
                    toolKind: existing.toolKind, server: existing.server, tool: existing.tool,
                    durationMs: duration ?? existing.durationMs, turnID: existing.turnID, backgroundTaskID: taskID,
                    backgroundTaskSummary: isShell ? nil : summary ?? existing.backgroundTaskSummary
                ).preservingTimelineFields(of: existing)
                if let duration { activityDurations[activity.id] = duration }
                toolActivities[toolUseID] = activity
                activityHandler?(activity)
            } else {
                // No in-memory record: a prior process started this agent and this
                // runner never saw its task_started. Surface a synthetic update keyed
                // only by backgroundTaskID so the owner can resolve it against the
                // persisted activity from whichever earlier turn launched it.
                activityHandler?(ConversationActivity(
                    id: taskID, title: "Background agent", detail: summary ?? "", status: status,
                    backgroundTaskID: taskID, backgroundTaskSummary: summary
                ))
            }
            completeTurnIfSettled()
        default:
            break
        }
    }

    /// The timeline row of one compaction. Claude Code names Playhouse's own
    /// `/compact` a manual one, so the trigger Playhouse asked for labels it.
    package func compactionActivity(id: String, status: String, details: ContextCompactionDetails?) -> ConversationActivity {
        let trigger = details?.trigger ?? compactionTrigger
        let automatic = trigger?.isAutomatic ?? false
        let detail: String
        switch status {
        case "inProgress": detail = automatic ? "Automatic · \(trigger?.label ?? "")" : ""
        case "failed": detail = "Claude Code couldn't compact the context."
        default: detail = details?.summary ?? ""
        }
        return ConversationActivity(
            id: id, title: status == "failed"
                ? (automatic ? "Automatic context compaction failed" : "Context compaction failed")
                : (automatic ? "Context compacted automatically" : "Context compacted"), detail: detail,
            status: status, isContextCompaction: true, turnID: activeTurnID, compaction: details
        )
    }

    package static func resolvedBackgroundTaskStatus(_ status: String) -> String {
        switch status {
        case "completed": "completed"
        case "stopped": "stopped"
        default: "failed"
        }
    }

    package func handleResult(_ message: [String: Any]) {
        let subtype = message["subtype"] as? String ?? ""
        let isError = message["is_error"] as? Bool ?? (subtype != "success")
        reportTokenUsage(message)
        if isError {
            let text = (message["result"] as? String) ?? (message["errors"] as? [String])?.joined(separator: " ") ?? ""
            if text.contains("No conversation found with session ID") { sessionWasMissing = true }
            let error: Error
            if wasInterrupted {
                error = ClientError.turnFailed("The Claude turn was interrupted.")
            } else {
                error = ClaudeCodeClient.classifyFailure(ClientError.turnFailed(text.isEmpty ? "Claude couldn't complete this turn (\(subtype))." : text), text: text)
            }
            turnCompletion.resultReceived = true
            turnCompletion.resultError = error
            // An interrupt or failure ends the logical turn even if steered input is queued.
            pendingCommandUUIDs.removeAll()
        } else {
            turnCompletion.resultReceived = true
        }
        turnCompletion.resultCount += 1
        if !isError, !isTurnSettled { recordHeldAnswer() }
        completeTurnIfSettled()
    }

    /// A result ends Claude Code's provider turn, so the text before it is that turn's whole
    /// answer. When background work or steered input keeps the Playhouse turn open, the answer
    /// is recorded now rather than when the turn settles, which can be long after, or never if
    /// the turn fails; a steered message's answer would otherwise appear only in Claude Code's
    /// own transcript. A steer closes what was written before it the same way, so that answer is
    /// recorded above the steer rather than after Claude's reply to it. The answer stays held,
    /// so if nothing follows it still becomes the final answer.
    package func recordHeldAnswer() {
        guard let pending = pendingAssistantText, !pending.recorded else { return }
        emitProgress(id: pending.id, text: pending.text)
        pendingAssistantText = (pending.id, pending.text, true)
        // Text after it starts a new answer.
        pendingTextSpansOutcomeReport = false
    }

    /// Delivers the held answer as the final answer. One already recorded as progress carries
    /// its ID, so a turn recorder settles it where it stands, once; a caller that only takes
    /// final answers, such as a side chat, still receives it.
    package func emitFinal(_ pending: (id: String, text: String, recorded: Bool)) {
        if pending.recorded, let recordedFinalHandler {
            recordedFinalHandler(pending.text, pending.id)
        } else {
            finalMessageHandler?(pending.text)
        }
    }

    /// Closes the held answer as commentary: the turn went on to other work after it.
    package func closePendingAssistantText() {
        if let pending = pendingAssistantText, !pending.recorded { emitProgress(id: pending.id, text: pending.text) }
        pendingAssistantText = nil
        pendingTextSpansOutcomeReport = false
    }

    /// Claude Code reports a turn's token cost on its `result` message. A logical
    /// Playhouse turn can take several results (each background-task wake owes
    /// its own), so every result's usage is reported and the recorder sums them.
    package func reportTokenUsage(_ message: [String: Any]) {
        guard let payload = message["usage"] as? [String: Any] else { return }
        let usage = ConversationTokenUsage(providerPayload: payload)
        guard !usage.isEmpty else {
            // A non-empty payload that parses to all zeros means Claude Code
            // changed its usage field names; silently dropping it would make a
            // real regression invisible.
            PlayhouseDiagnostics.record("claude.turn.usage_unparsed", fields: diagnosticFields([
                "payloadKeys": payload.keys.sorted().joined(separator: ","),
            ]))
            return
        }
        let labels = toolActivities.values
            .filter { $0.turnID == activeTurnID }
            .map(\.tokenUsageLabel)
        tokenUsageHandler?(ConversationTurnUsageReport(
            turnID: activeTurnID,
            usage: usage,
            toolLabels: Array(Set(labels)).sorted()
        ))
    }

    /// Every change to the expected wake invalidates a pending backstop, so a
    /// timer started for one notification can't clear a later one.
    package func setAwaitingParentWake(_ awaiting: Bool) {
        turnCompletion.awaitingParentWake = awaiting
        turnCompletion.countedWakeInit = false
        parentWakeBackstopGeneration += 1
    }

    /// When only an undelivered background notification holds a finished turn
    /// open, settle after a grace period: Claude Code normally starts the woken
    /// turn within milliseconds, and a notification it consumed without a new
    /// request must not hold the task In Progress indefinitely. A woken turn
    /// Claude Code announced with `system init` and then never spoke in is
    /// covered too, on its own longer grace, so a turn whose expected woken
    /// result never arrives still settles rather than staying active forever.
    /// Ending the provider turn here claims nothing about the work: the task
    /// then settles on the outcome the agent reported, and a turn that ended
    /// without one gets the owner's single recovery prompt, not Review.
    package func scheduleParentWakeBackstopIfNeeded() {
        guard turnCompletion.awaitingParentWake, turnCompletion.resultError == nil,
              turnCompletion.resultReceived, !isHeldByBackgroundTasks else { return }
        parentWakeBackstopGeneration += 1
        let generation = parentWakeBackstopGeneration
        // A wake whose woken turn already announced itself gets the long grace:
        // that turn exists, so silence may only mean it is slow to speak.
        let announced = turnCompletion.countedWakeInit
        let grace = announced ? wokenSilenceGrace : wakeGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.parentWakeBackstopGeneration == generation,
                  self.turnCompletion.awaitingParentWake else { return }
            PlayhouseDiagnostics.record("claude.turn.parent_wake_timeout", fields: self.diagnosticFields([
                "wokenTurnAnnounced": String(announced)
            ]))
            // The woken turn this wake was counted for never produced a result
            // of its own, so the turn stops owing one. Without this the counted
            // wake outlives the notification it belonged to and the turn can
            // never satisfy `resultCount > wokenTurnCount` again.
            if self.turnCompletion.countedWakeInit { self.turnCompletion.wokenTurnCount -= 1 }
            self.setAwaitingParentWake(false)
            self.completeTurnIfSettled()
        }
    }

    /// Claude Code wakes the parent for a background agent's notification after
    /// its earlier result, so any new parent response means that result no
    /// longer ends the turn; only the parent's next result does.
    package func noteParentResponseStarted() {
        guard turnCompletion.resultReceived, turnCompletion.resultError == nil else { return }
        turnCompletion.resultReceived = false
        // A stopping outcome reported before that result described the work as it stood then.
        // The parent is working again, so it must report where this newer work ends.
        owner?.stoppingOutcomeProbes[sessionID]?.withdraw()
    }

    package func completeTurnIfSettled() {
        guard isTurnSettled else {
            scheduleParentWakeBackstopIfNeeded()
            return
        }
        if let error = turnCompletion.resultError {
            finishTurn(.failure(error))
            return
        }
        if let pending = pendingAssistantText {
            pendingAssistantText = nil
            emitFinal(pending)
        }
        // A completed turn has no running tools left to observe.
        for (id, var activity) in toolActivities where activity.isActive {
            activity = ConversationActivity(
                id: activity.id, title: activity.title, detail: activity.detail, status: "completed",
                childThreadID: activity.childThreadID, agentPath: activity.agentPath, model: activity.model,
                toolKind: activity.toolKind, server: activity.server, tool: activity.tool, turnID: activity.turnID
            ).preservingTimelineFields(of: activity)
            toolActivities[id] = activity
            activityHandler?(activity)
        }
        finishTurn(.success(()))
    }

    package func emitProgress(id: String, text: String) {
        progressMessageHandler?(ConversationMessage(
            id: id, role: .assistant, text: text, phase: "commentary", turnID: activeTurnID, provider: .claude
        ))
    }
}
