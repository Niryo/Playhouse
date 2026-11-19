import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    /// Records a message of a local turn as its provider streamed it.
    func recordTurnMessage(
        taskID: UUID, turnID: String, provider: ConversationProvider = .claude,
        modelID: String? = nil, _ message: ConversationMessage
    ) {
        do {
            try transcripts.mutate(taskID, turns: .turn(turnID)) { transcript in
                // `.turn` also loads the latest turn; a message whose turn is gone is
                // dropped rather than attached to another turn.
                guard let index = transcript.turns.lastIndex(where: { $0.id == turnID }) else {
                    PlayhouseDiagnostics.record("conversation.turn_message.dropped", fields: [
                        "taskID": taskID.uuidString, "turnID": turnID,
                    ])
                    return
                }
                var message = message
                message.turnID = transcript.turns[index].id
                message.provider = provider
                message.modelID = message.modelID ?? modelID
                // Stored order is the timeline; a provider's own item order would only
                // mark the message as positioned.
                message.timelineOrder = nil
                if let existing = transcript.turns[index].messages.firstIndex(where: { $0.id == message.id }) {
                    message.createdAt = message.createdAt ?? transcript.turns[index].messages[existing].createdAt
                    transcript.turns[index].messages[existing] = message
                } else {
                    message.createdAt = message.createdAt ?? .now
                    transcript.turns[index].messages.append(message)
                }
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            PlayhouseDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    func recordPromptCacheMiss(taskID: UUID, _ event: PromptCacheMissEvent) {
        do {
            try transcripts.mutate(taskID, turns: .none) { transcript in
                transcript.promptCacheMisses = (transcript.promptCacheMisses ?? []) + [event]
            }
            PlayhouseDiagnostics.record("conversation.resume.cache_miss", fields: [
                "taskID": taskID.uuidString, "cacheReadTokens": String(event.cacheReadTokens),
                "cacheWriteTokens": String(event.cacheWriteTokens), "idleSeconds": String(event.idleSeconds ?? 0)
            ])
        } catch {
            PlayhouseDiagnostics.record("conversation.resume.cache_miss_record_failed", fields: ["taskID": taskID.uuidString])
        }
    }

    func recordContextCompaction(taskID: UUID, _ event: ContextCompactionEvent) {
        do {
            try transcripts.mutate(taskID, turns: .none) { transcript in
                if !(transcript.contextCompactions ?? []).contains(where: { $0.id == event.id }) {
                    transcript.contextCompactions = (transcript.contextCompactions ?? []) + [event]
                }
            }
            PlayhouseDiagnostics.record("conversation.compaction.recorded", fields: [
                "taskID": taskID.uuidString, "trigger": event.trigger.rawValue,
                "preTokens": String(event.preTokens ?? 0), "postTokens": String(event.postTokens ?? 0)
            ])
        } catch {
            PlayhouseDiagnostics.record("conversation.compaction.record_failed", fields: ["taskID": taskID.uuidString])
        }
    }

    func recordTurnActivity(taskID: UUID, turnID: String, provider: ConversationProvider = .claude, _ activity: ConversationActivity) {
        // Loads only the turns this update can touch: its own turn, wherever an
        // activity with the same background task lives, and wherever that
        // activity's background agent report already sits.
        var selection = ConversationTranscriptStore.TurnSelection(turnIDs: [turnID])
        selection.backgroundTaskID = activity.backgroundTaskID
        selection.messageIDs = [ConversationTranscriptStore.backgroundAgentReportMessagePrefix + activity.id]
        do {
            try transcripts.mutate(taskID, turns: selection) { transcript in
                // A background Agent/Task call can still be running (or get a terminal
                // notification) after the turn that launched it ends, and after a
                // restart its new turn has no in-memory record of the launch at all.
                // Resolve by the provider's durable backgroundTaskID first, wherever in
                // the transcript that activity actually lives, before falling back to
                // an id match scoped to this turn.
                if let backgroundTaskID = activity.backgroundTaskID {
                    for turnIndex in transcript.turns.indices {
                        guard let existingIndex = transcript.turns[turnIndex].activities.firstIndex(where: {
                            $0.backgroundTaskID == backgroundTaskID
                        }) else { continue }
                        let existing = transcript.turns[turnIndex].activities[existingIndex]
                        let updatedActivity = ConversationActivity(
                            id: existing.id, title: existing.title,
                            detail: activity.detail.isEmpty ? existing.detail : activity.detail,
                            status: activity.status,
                            childThreadID: existing.childThreadID, agentPath: existing.agentPath, model: existing.model,
                            reasoningEffort: existing.reasoningEffort, toolKind: existing.toolKind,
                            server: existing.server, tool: existing.tool,
                            durationMs: activity.durationMs ?? existing.durationMs, startedAt: existing.startedAt,
                            isContextCompaction: existing.isContextCompaction, turnID: existing.turnID,
                            timelineOrder: existing.timelineOrder, backgroundTaskID: existing.backgroundTaskID,
                            backgroundTaskSummary: activity.backgroundTaskSummary ?? existing.backgroundTaskSummary
                        ).preservingTimelineFields(of: existing).preservingTimelineFields(of: activity)
                        transcript.turns[turnIndex].activities[existingIndex] = updatedActivity
                        let reportTurnIndex = transcript.turns.lastIndex(where: { $0.id == turnID }) ?? turnIndex
                        let reportTurnID = transcript.turns[reportTurnIndex].id
                        Self.upsertBackgroundAgentReport(
                            activity: updatedActivity,
                            transcript: &transcript,
                            turnID: reportTurnID,
                            provider: provider
                        )
                        return
                    }
                }
                guard let index = transcript.turns.lastIndex(where: { $0.id == turnID }) else { return }
                var activity = activity
                activity.turnID = turnID
                if activity.isContextCompaction {
                    // A compaction starts after the text written before it, so a new row follows the
                    // turn's latest message; later updates to the row keep that place.
                    let continuesRow = transcript.turns[index].activities.contains {
                        $0.isContextCompaction && ($0.id == activity.id || $0.status == "inProgress")
                    }
                    if !continuesRow, activity.afterMessageID == nil {
                        activity.afterMessageID = transcript.turns[index].messages.last?.id
                    }
                    ConversationActivity.upsertCompaction(activity, into: &transcript.turns[index].activities)
                } else if let existing = transcript.turns[index].activities.firstIndex(where: { $0.id == activity.id }) {
                    activity = activity.preservingTimelineFields(of: transcript.turns[index].activities[existing])
                    transcript.turns[index].activities[existing] = activity
                } else {
                    // A provider reports a call after the text written before it, so the
                    // turn's latest message is the one this call follows.
                    if activity.isTimelineToolCall, activity.afterMessageID == nil {
                        activity.afterMessageID = transcript.turns[index].messages.last?.id
                    }
                    transcript.turns[index].activities.append(activity)
                }
                let targetTurnID = transcript.turns[index].id
                Self.upsertBackgroundAgentReport(activity: activity, transcript: &transcript, turnID: targetTurnID, provider: provider)
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            PlayhouseDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    func debugImportRecordClaudeMessage(taskID: UUID, turnID: String, modelID: String?, _ message: ConversationMessage) { recordTurnMessage(taskID: taskID, turnID: turnID, modelID: modelID, message) } // DEBUG-IMPORT:
    func debugImportRecordClaudeActivity(taskID: UUID, turnID: String, _ activity: ConversationActivity) { recordTurnActivity(taskID: taskID, turnID: turnID, activity) } // DEBUG-IMPORT:
    func debugImportPrepareSegmentID(taskID: UUID) async throws -> String? { try await prepareSegment(task: tasks.conversationSubject(taskID))?.segmentID } // DEBUG-IMPORT:

    /// Claude reports a background agent's result on its task notification,
    /// outside the parent assistant response. Persist that report as a normal
    /// assistant message so it is visible in the conversation and available to
    /// later turns, as a Codex subagent's report arrives as an agent message of its parent turn.
    static func upsertBackgroundAgentReport(
        activity: ConversationActivity,
        transcript: inout ConversationTranscript,
        turnID: String,
        provider: ConversationProvider = .claude
    ) {
        guard activity.backgroundTaskID != nil,
              activity.status == "completed",
              let summary = activity.backgroundTaskSummary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let messageID = ConversationTranscriptStore.backgroundAgentReportMessagePrefix + activity.id
        guard let targetTurnIndex = transcript.turns.firstIndex(where: { $0.id == turnID }) else { return }
        let report = ConversationMessage(
            id: messageID,
            role: .assistant,
            text: summary,
            phase: "subagent_report",
            turnID: turnID,
            provider: provider
        )
        for index in transcript.turns.indices {
            transcript.turns[index].messages.removeAll { $0.id == messageID }
        }
        transcript.turns[targetTurnIndex].messages.append(report)
    }

    /// Records the accepted turn before its first events can be queried by another XPC call.
    func recordCodexTurnStarted(taskID: UUID, segmentID: String, turnID: String, modelID: String) {
        do {
            try transcripts.mutate(taskID, turns: .none) { transcript in
                guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                if !transcript.segments[index].codexTurnIDs.contains(turnID) {
                    transcript.segments[index].codexTurnIDs.append(turnID)
                }
                transcript.segments[index].codexTurnModelIDs[turnID] = modelID
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            PlayhouseDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    /// Makes the task's provider the current segment and returns it with the
    /// handoff context its first prompt still needs, if any.
    func prepareSegment(task: any ConversationSubject) async throws -> (segmentID: String, handoff: String?)? {
        let provider = task.conversationProvider
        var transcript = try transcripts.readState(task.id)
        if transcript.segments.last?.provider != provider || transcript.segments.isEmpty {
            transcript = try transcripts.mutate(task.id, turns: .none) { transcript in
                if transcript.segments.last?.provider != provider || transcript.segments.isEmpty {
                    let isInitialExistingCodex = transcript.segments.isEmpty && provider == .codex && task.codexThreadID != nil
                    let isFirst = transcript.segments.isEmpty && task.codexThreadID == nil
                    transcript.segments.append(.init(id: UUID().uuidString, provider: provider, startedAt: .now, handoffDelivered: isFirst || isInitialExistingCodex))
                }
                return transcript
            }
        }
        guard let segment = transcript.segments.last else { return nil }
        guard !segment.handoffDelivered else { return (segment.id, nil) }
        // Only an undelivered handoff needs to know which turns each segment owns.
        transcript = try transcripts.read(task.id, turns: .all, includeImages: false)
        let history = try await history(taskID: task.id, includesImageData: false)
        let current = transcript.segments.count - 1
        let previousOwnSegment = transcript.segments[..<current].lastIndex { $0.provider == provider }
        let unseenStart = previousOwnSegment.map { index in
            // Everything after this provider's last message is new to it.
            let ownTurnIDs = Set(transcript.turns(in: transcript.segments[index]).map(\.id) + transcript.segments[index].codexTurnIDs)
            return (history.messages.lastIndex { $0.turnID.map(ownTurnIDs.contains) == true } ?? -1) + 1
        } ?? 0
        let unseen = Self.withoutNudgeTurns(Array(history.messages.dropFirst(unseenStart))).filter {
            $0.provider != provider && !Self.isPrivateOutcomeReminderPrompt($0.text)
        }
        return (segment.id, ConversationHandoff.context(for: provider, messages: Array(unseen)))
    }

    /// What one turn records while it runs. A reminder continuation and a reattached turn each
    /// get their own.
    final class TurnRecording {
        var finalMessageCount = 0
        var leakedOutcome: String?
        var pendingQuestionLifecycleRevision: Int?
        /// Set on a turn that resumes a Claude session with a warm-looking
        /// cache, so its first model call is checked for a cache miss.
        var checksResumeCacheMiss = false
        /// How long the session had gone without a model call before this turn.
        var resumeIdleSeconds: Double?
        /// When each activity was last written, with the status written then. Codex
        /// reports every chunk of a command's output as an update, so a running
        /// activity is rewritten at most once a second; its status changes always are.
        var activityWrites: [String: (status: String, at: Date)] = [:]
        /// The newest update of each activity that the throttle held back. It is written
        /// once its second has passed unless a newer write superseded it, so the store,
        /// the only record of the turn, never misses an activity's last state.
        var heldActivities: [String: ConversationActivity] = [:]
        /// The files this turn changed so far; each reported diff replaces its files' chunks.
        var turnDiff: ConversationTurnDiff?

        enum ActivityWrite { case now, holdUntil(Date), held }

        func activityWrite(_ activity: ConversationActivity, now: Date = .now) -> ActivityWrite {
            if let last = activityWrites[activity.id], last.status == activity.status,
               activity.durationMs == nil, now.timeIntervalSince(last.at) < 1 {
                let alreadyHeld = heldActivities[activity.id] != nil
                heldActivities[activity.id] = activity
                return alreadyHeld ? .held : .holdUntil(last.at.addingTimeInterval(1))
            }
            activityWrites[activity.id] = (activity.status, now)
            heldActivities[activity.id] = nil
            return .now
        }

        /// The held update of an activity, if a newer write hasn't superseded it.
        func releaseHeldActivity(_ id: String, now: Date = .now) -> ConversationActivity? {
            guard let activity = heldActivities.removeValue(forKey: id) else { return nil }
            activityWrites[id] = (activity.status, now)
            return activity
        }
    }

    /// The callbacks a provider reports one turn through: they record its transcript, usage and
    /// questions and stream its updates. A sent turn and a turn this daemon reattached after a
    /// restart use the same set, so both land the same way. `turnID` is the local turn every
    /// message, activity and usage row of this turn is recorded under, whichever provider runs it.
    func turnCallbacks(
        taskID: UUID,
        provider: ConversationProvider,
        client: ConversationProviderClient,
        threadID: String,
        modelID: String,
        segment: (segmentID: String, handoff: String?)?,
        turnID localTurnID: String,
        isPlayhouseNudge: Bool,
        userInputAnswers: [String: [String]],
        recording: TurnRecording,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void
    ) -> ConversationTurnCallbacks {
        let streamTurnUpdate = onUpdate
        let approvalNotice = "\(provider.displayName) requested an approval. Playhouse denied it because approval prompts are disabled."
        return ConversationTurnCallbacks(
            onDelta: { delta in
                onUpdate(ConversationUpdate(type: "text_delta", text: delta))
            },
            onFinalMessage: { answer in
                let split = LeakedTurnOutcome.split(answer)
                if split.taskID == taskID { recording.leakedOutcome = split.outcome }
                let message = split.text
                // An answer that was only the echo still replaces the streamed text.
                if !message.isEmpty {
                    recording.finalMessageCount += 1
                    self.recordTurnMessage(taskID: taskID, turnID: localTurnID, provider: provider, modelID: modelID, ConversationMessage(
                        id: "\(localTurnID)-final-\(recording.finalMessageCount)", role: .assistant, text: message, phase: "final_answer"
                    ))
                }
                streamTurnUpdate(ConversationUpdate(type: "assistant_final", text: message))
            },
            onActivity: { activity in
                switch recording.activityWrite(activity) {
                case .now:
                    self.recordTurnActivity(taskID: taskID, turnID: localTurnID, provider: provider, activity)
                case .holdUntil(let deadline):
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                        if let held = recording.releaseHeldActivity(activity.id) {
                            self.recordTurnActivity(taskID: taskID, turnID: localTurnID, provider: provider, held)
                        }
                    }
                case .held:
                    break
                }
                // Claude Code's own native auto-compaction, or a /compact the user or agent ran.
                if provider == .claude, activity.isContextCompaction, activity.status == "completed", let details = activity.compaction {
                    self.recordContextCompaction(taskID: taskID, ContextCompactionEvent(
                        id: activity.id, recordedAt: .now, trigger: details.trigger,
                        preTokens: details.preTokens, postTokens: details.postTokens
                    ))
                }
                if let durationMs = activity.durationMs {
                    Task { @MainActor in
                        try? await self.tasks.recordConversationActivityDuration(
                            taskID: taskID,
                            activityID: activity.id,
                            durationMs: durationMs
                        )
                    }
                }
                streamTurnUpdate(ConversationUpdate(type: "activity", activity: activity))
            },
            onDiff: { diff in
                // A Playhouse reminder continues the turn it nudges, so its changes add to
                // that turn's diff rather than replace it.
                let base = recording.turnDiff
                    ?? (isPlayhouseNudge ? (try? self.transcripts.readState(taskID))?.latestDiff : nil)
                let merged = base?.merging(diff) ?? diff
                recording.turnDiff = merged
                self.recordLatestDiff(taskID: taskID, merged)
                streamTurnUpdate(ConversationUpdate(type: "diff", diff: merged.unifiedDiff))
            },
            onHistory: { history in
                // A provider hands over history only for a turn that ran while no daemon
                // followed it; record whatever of it this turn did not stream.
                self.backfillTurn(taskID: taskID, turnID: localTurnID, provider: provider, modelID: modelID, history)
            },
            onActionRequest: {
                onUpdate(ConversationUpdate(type: "action_notice", message: approvalNotice))
            },
            onUserInput: { request async in
                if isPlayhouseNudge {
                    let isStandaloneChat = (try? self.tasks.conversationSubject(taskID))?.isStandaloneChat == true
                    client.rejectUserInput(
                        requestID: request.id,
                        threadID: request.threadID,
                        message: isStandaloneChat
                            ? "This is a Playhouse page reminder. Do not ask the user here; run the chat page close-turn command for your previous reply."
                            : "This is a private Playhouse status nudge. Do not ask the user here; report `waiting-response` if you need an answer, keep working in this turn if work remains, or report `completed` if the work is finished."
                    )
                    return
                }
                do {
                    try self.persistPendingUserInputRequest(request, taskID: taskID)
                } catch {
                    client.rejectUserInput(requestID: request.id, threadID: request.threadID, message: "Playhouse couldn't save this question for recovery. Please try again.")
                    onUpdate(ConversationUpdate(type: "action_notice", message: "Couldn't save the pending question. The provider turn was stopped so the question isn't lost."))
                    return
                }
                // A blocking provider question pauses the conversation until
                // the user answers. Reflect that pause on the board even
                // though the provider turn remains reserved in the background.
                let lifecycle = request.isBlocking
                    ? try? await self.tasks.transitionLifecycleStatus(taskID, from: .inProgress, to: .waitingResponse)
                    : nil
                if let revision = lifecycle ?? nil {
                    recording.pendingQuestionLifecycleRevision = revision
                }
                let status = try? await self.tasks.clearProgressReport(taskID)
                onUpdate(ConversationUpdate(
                    type: "user_input",
                    userInputRequest: request,
                    taskStatus: lifecycle != nil ? TaskStatus.waitingResponse.rawValue : status?.status
                ))
                if !userInputAnswers.isEmpty {
                    let answersAccepted = client.answerUserInput(requestID: request.id, threadID: request.threadID, answers: userInputAnswers)
                    if !answersAccepted {
                        onUpdate(ConversationUpdate(type: "action_notice", message: "The supplied answers didn't match \(provider.displayName)'s questions."))
                    } else {
                        try? self.clearPendingUserInputRequest(taskID: taskID, requestID: request.id)
                        if request.isBlocking,
                           let resumed = try? await self.tasks.resumeWaitingResponseAfterUserInput(taskID) {
                            onUpdate(ConversationUpdate(type: "task_status", taskStatus: resumed.status))
                        }
                    }
                }
                await onUserInput(request)
            },
            onSteerMessage: { message, images in
                self.recordTurnMessage(taskID: taskID, turnID: localTurnID, provider: provider, modelID: modelID, ConversationMessage(
                    id: UUID().uuidString.lowercased(), role: .user, text: message, imageDataURLs: images
                ))
                onUpdate(ConversationUpdate(type: "steered_message", message: message, imageDataURLs: images))
            },
            onProgressMessage: { message in
                var message = message
                // Progress is recorded without a leaked outcome block, as an answer is, whichever
                // of the live and backfill paths records it first.
                if message.role == .assistant {
                    let split = LeakedTurnOutcome.split(message.text)
                    if split.taskID == taskID { recording.leakedOutcome = split.outcome }
                    message.text = split.text
                    // Progress that was only the echo leaves nothing to show.
                    if message.text.isEmpty, message.asyncQuestions == nil { return }
                }
                self.recordTurnMessage(taskID: taskID, turnID: localTurnID, provider: provider, modelID: modelID, message)
                // A notice the provider's runtime added to the turn streams as the user-side
                // message it is recorded as, not as the assistant's progress.
                if message.role == .user {
                    streamTurnUpdate(ConversationUpdate(type: "steered_message", message: message.text))
                    return
                }
                streamTurnUpdate(ConversationUpdate(
                    type: "assistant_progress",
                    text: message.text,
                    itemID: message.id,
                    phase: message.phase,
                    asyncQuestions: message.asyncQuestions
                ))
            },
            onMessageTimestamp: { _, _ in },
            onTurnStarted: { providerTurnID in
                ConversationTurnLaunch.turnStarted(taskID)
                // Codex's own turn ID is kept as resume metadata beside the local turn.
                if provider == .codex, let segment {
                    self.recordCodexTurnStarted(taskID: taskID, segmentID: segment.segmentID, turnID: providerTurnID, modelID: modelID)
                }
            },
            onTokenUsage: { report in
                let attributed = ConversationTurnUsageReport(
                    turnID: localTurnID,
                    usage: report.usage,
                    toolLabels: report.toolLabels,
                    liveCall: report.liveCall
                )
                let claudeConfigDirectory = (client as? ClaudeCodeClient)?.configDirectory
                if recording.checksResumeCacheMiss, let call = report.liveCall, call.agentID == nil, call.calls > 0 {
                    // Only the resumed turn's first call tells whether the cache survived.
                    recording.checksResumeCacheMiss = false
                    if ContextCompactionPolicy.isCacheMiss(cacheReadTokens: call.cacheReadTokens, cacheWriteTokens: call.cacheWriteTokens) {
                        self.recordPromptCacheMiss(taskID: taskID, PromptCacheMissEvent(
                            id: UUID().uuidString.lowercased(), recordedAt: .now, turnID: localTurnID,
                            cacheReadTokens: call.cacheReadTokens, cacheWriteTokens: call.cacheWriteTokens,
                            idleSeconds: recording.resumeIdleSeconds
                        ))
                    }
                }
                Task { @MainActor in
                    do {
                        try await self.tasks.recordTokenUsage(taskID: taskID, provider: provider, sourceID: threadID, report: attributed)
                        // A Claude result closes a turn: settle the live counts against the session files.
                        if provider == .claude, attributed.liveCall == nil, let claudeConfigDirectory {
                            try await self.tasks.refreshClaudeCallUsage(taskID: taskID, sessionID: threadID, configDirectory: claudeConfigDirectory)
                        }
                    } catch {
                        var fields = PlayhouseDiagnostics.errorFields(error)
                        fields["taskID"] = taskID.uuidString
                        PlayhouseDiagnostics.record("task.token_usage.record_failed", fields: fields)
                    }
                }
            }
        )
    }

    /// Persists the working-tree diff its provider last reported for the latest turn.
    func recordLatestDiff(taskID: UUID, _ diff: ConversationTurnDiff?) {
        do {
            try transcripts.mutate(taskID, turns: .none) { transcript in
                transcript.latestDiff = diff
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            PlayhouseDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    /// Adds a provider's own record of a turn to the local turn: the messages the turn
    /// didn't stream (matched by role and text), its activities, and its diff.
    func backfillTurn(
        taskID: UUID, turnID: String, provider: ConversationProvider, modelID: String, _ history: ConversationHistory
    ) {
        do {
            try transcripts.mutate(taskID, turns: .turn(turnID)) { transcript in
                guard let index = transcript.turns.lastIndex(where: { $0.id == turnID }) else { return }
                var turn = transcript.turns[index]
                for var message in history.messages {
                    // An answer is recorded without a leaked outcome block, as the live path records it.
                    if message.role == .assistant { message.text = LeakedTurnOutcome.split(message.text).text }
                    let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !turn.messages.contains(where: {
                        $0.id == message.id || ($0.role == message.role && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text)
                    }) else { continue }
                    message.turnID = turnID
                    message.provider = provider
                    message.modelID = message.modelID ?? modelID
                    message.timelineOrder = nil
                    message.createdAt = message.createdAt ?? .now
                    turn.messages.append(message)
                }
                for activity in history.activities where !activity.isContextCompaction
                    && !turn.activities.contains(where: { $0.id == activity.id }) {
                    var activity = activity
                    activity.turnID = turnID
                    activity.timelineOrder = nil
                    turn.activities.append(activity)
                }
                transcript.turns[index] = turn
                if let diff = history.diff { transcript.latestDiff = diff }
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            PlayhouseDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    /// Settles a turn that ended: its activity durations, the outcome it reported and the
    /// status that outcome decides, and the auto-PR on Review. A sent turn and a turn this daemon
    /// reattached after a restart both finish here.
}
