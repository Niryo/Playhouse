import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func recordClaudeMessage(taskID: UUID, turnID: String? = nil, modelID: String? = nil, _ message: ConversationMessage) {
        do {
            try transcripts.mutate(taskID, turns: .turn(turnID)) { transcript in
                guard let index = turnID.flatMap({ id in transcript.turns.lastIndex { $0.id == id } }) ?? transcript.turns.indices.last else { return }
                var message = message
                message.turnID = transcript.turns[index].id
                message.provider = .claude
                message.modelID = message.modelID ?? modelID
                if let existing = transcript.turns[index].messages.firstIndex(where: { $0.id == message.id }) {
                    transcript.turns[index].messages[existing] = message
                } else {
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

    func recordClaudeActivity(taskID: UUID, turnID: String, _ activity: ConversationActivity) {
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
                        Self.upsertClaudeBackgroundAgentReport(
                            activity: updatedActivity,
                            transcript: &transcript,
                            turnID: reportTurnID
                        )
                        return
                    }
                }
                guard let index = transcript.turns.lastIndex(where: { $0.id == turnID }) else { return }
                var activity = activity
                activity.turnID = turnID
                if let existing = transcript.turns[index].activities.firstIndex(where: { $0.id == activity.id }) {
                    activity = activity.preservingTimelineFields(of: transcript.turns[index].activities[existing])
                    transcript.turns[index].activities[existing] = activity
                } else {
                    // Claude reports a call after the text written before it, so the
                    // turn's latest message is the one this call follows.
                    if activity.isTimelineToolCall, activity.afterMessageID == nil {
                        activity.afterMessageID = transcript.turns[index].messages.last?.id
                    }
                    transcript.turns[index].activities.append(activity)
                }
                let targetTurnID = transcript.turns[index].id
                Self.upsertClaudeBackgroundAgentReport(activity: activity, transcript: &transcript, turnID: targetTurnID)
            }
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            PlayhouseDiagnostics.record("conversation.transcript.write_failed", fields: fields)
        }
    }

    func debugImportRecordClaudeMessage(taskID: UUID, turnID: String, modelID: String?, _ message: ConversationMessage) { recordClaudeMessage(taskID: taskID, turnID: turnID, modelID: modelID, message) } // DEBUG-IMPORT:
    func debugImportRecordClaudeActivity(taskID: UUID, turnID: String, _ activity: ConversationActivity) { recordClaudeActivity(taskID: taskID, turnID: turnID, activity) } // DEBUG-IMPORT:
    func debugImportPrepareSegmentID(taskID: UUID) async throws -> String? { try await prepareSegment(task: tasks.conversationSubject(taskID))?.segmentID } // DEBUG-IMPORT:

    /// Claude reports a background agent's result on its task notification,
    /// outside the parent assistant response. Persist that report as a normal
    /// assistant message so it is visible in the conversation and available to
    /// later turns, matching Codex's parent-thread agent message behavior.
    static func upsertClaudeBackgroundAgentReport(
        activity: ConversationActivity,
        transcript: inout ConversationTranscript,
        turnID: String
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
            provider: .claude
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

    /// Assigns Codex turns that ran during a segment to it, so a mixed transcript
    /// keeps them in order after later switches.
    func claimCodexTurns(taskID: UUID, segmentID: String, _ messages: [ConversationMessage]) {
        let turnIDs = Self.orderedTurnIDs(messages)
        do {
            try transcripts.mutate(taskID, turns: .none) { transcript in
                guard let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) else { return }
                let claimed = Set(transcript.segments.flatMap(\.codexTurnIDs))
                let newTurnIDs = turnIDs.filter { !claimed.contains($0) }
                transcript.segments[index].codexTurnIDs += newTurnIDs
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
                && $0.text != Self.privateOutcomeReminderResponsePlaceholder
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
    }

    /// The callbacks a provider reports one turn through: they record its transcript, usage and
    /// questions and stream its updates. A sent turn and a turn this daemon reattached after a
    /// restart use the same set, so both land the same way.
    func turnCallbacks(
        taskID: UUID,
        provider: ConversationProvider,
        client: ConversationProviderClient,
        threadID: String,
        modelID: String,
        segment: (segmentID: String, handoff: String?)?,
        claudeTurnID: String?,
        hideSensitiveRecoveryPrompt: Bool,
        sensitiveUserInputAnswerValues: [String],
        isPlayhouseNudge: Bool,
        userInputAnswers: [String: [String]],
        recording: TurnRecording,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void
    ) -> ConversationTurnCallbacks {
        // Only a private answer's recovery turn hides its output; a status nudge is shown.
        let hidesRecoveryOutput = hideSensitiveRecoveryPrompt
        let streamTurnUpdate = onUpdate
        let approvalNotice = "\(provider.displayName) requested an approval. Playhouse denied it because approval prompts are disabled."
        return ConversationTurnCallbacks(
            onDelta: { delta in
                // Deltas are many and superseded by the recorded message, so a
                // turn not shown yet drops them instead of withholding them.
                guard !hidesRecoveryOutput else { return }
                onUpdate(ConversationUpdate(type: "text_delta", text: delta))
            },
            onFinalMessage: { answer in
                let split = LeakedTurnOutcome.split(answer)
                if split.taskID == taskID { recording.leakedOutcome = split.outcome }
                let message = Self.redactingSensitiveText(split.text, values: sensitiveUserInputAnswerValues)
                // An answer that was only the echo still replaces the streamed text.
                if let claudeTurnID, !message.isEmpty {
                    recording.finalMessageCount += 1
                    self.recordClaudeMessage(taskID: taskID, turnID: claudeTurnID, modelID: modelID, ConversationMessage(
                        id: "\(claudeTurnID)-final-\(recording.finalMessageCount)", role: .assistant, text: message, phase: "final_answer"
                    ))
                }
                streamTurnUpdate(ConversationUpdate(type: "assistant_final", text: message))
            },
            onActivity: { activity in
                guard !hidesRecoveryOutput else { return }
                if let claudeTurnID { self.recordClaudeActivity(taskID: taskID, turnID: claudeTurnID, activity) }
                // Claude Code's own threshold compaction, or a /compact the user or agent ran.
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
                guard !hidesRecoveryOutput else { return }
                streamTurnUpdate(ConversationUpdate(type: "diff", diff: diff.unifiedDiff))
            },
            onHistory: { history in
                if provider == .codex, let segment { self.claimCodexTurns(taskID: taskID, segmentID: segment.segmentID, history.messages) }
                var history = history
                let matchedPrivateRecoveryTurnIDs = Set(history.messages.filter { message in
                    guard message.role == .user else { return false }
                    let containsPrivatePrompt = hideSensitiveRecoveryPrompt
                        && Self.isPrivateTaskPrompt(message.text)
                        && !Self.isPrivateOutcomeReminderPrompt(message.text)
                    let containsSecretAnswer = sensitiveUserInputAnswerValues.contains {
                        !$0.isEmpty && message.text.contains($0)
                    }
                    return containsPrivatePrompt || containsSecretAnswer
                }.compactMap(\.turnID))
                let privateOutcomeReminderTurnIDs = Set(history.messages.filter {
                    $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text)
                }.compactMap(\.turnID))
                let previousTranscript = try? self.transcripts.readState(taskID)
                let previouslyPrivateTurnIDs = Set(previousTranscript?.sensitiveCodexTurnIDs ?? [])
                let previouslySecretRecoveryTurnIDs = Set(previousTranscript?.sensitiveCodexSecretTurnIDs ?? [])
                let currentSecretRecoveryTurnIDs = Set(history.messages.filter { message in
                    guard message.role == .user else { return false }
                    return sensitiveUserInputAnswerValues.contains { !$0.isEmpty && message.text.contains($0) }
                }.compactMap(\.turnID))
                let privateSecretRecoveryTurnIDs = previouslySecretRecoveryTurnIDs.union(currentSecretRecoveryTurnIDs)
                let previouslyPrivateReminderTurnIDs = Set((previousTranscript?.sensitiveCodexTurnMessages ?? [:]).compactMap { turnID, messages in
                    messages.contains { $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text) } ? turnID : nil
                })
                let allPrivateTurnIDs = matchedPrivateRecoveryTurnIDs
                    .union(previouslyPrivateTurnIDs)
                    .union(privateOutcomeReminderTurnIDs)
                let allPrivateReminderTurnIDs = privateOutcomeReminderTurnIDs.union(previouslyPrivateReminderTurnIDs)
                if !matchedPrivateRecoveryTurnIDs.isEmpty, previousTranscript != nil {
                    do {
                        var safeCodexMessages: [String: [ConversationMessage]] = [:]
                        if provider == .codex {
                            for turnID in matchedPrivateRecoveryTurnIDs {
                                safeCodexMessages[turnID] = history.messages
                                    .filter { $0.turnID == turnID }
                                    .map { message -> ConversationMessage in
                                        var safe = Self.redactingSensitiveMessages(
                                            [message], turnIDs: matchedPrivateRecoveryTurnIDs, values: sensitiveUserInputAnswerValues
                                        )[0]
                                        if message.role == .user {
                                            safe.text = Self.privatePromptPlaceholder(for: message.text)
                                            safe.asyncQuestions = nil
                                        } else {
                                            let redactedText = Self.redactingSensitiveText(message.text, values: sensitiveUserInputAnswerValues)
                                            let stillContainsSecret = sensitiveUserInputAnswerValues.contains {
                                                !$0.isEmpty && redactedText.contains($0)
                                            }
                                            safe.text = privateSecretRecoveryTurnIDs.contains(turnID) || stillContainsSecret
                                                ? "[Response to private answer hidden]"
                                                : redactedText
                                            safe.asyncQuestions = nil
                                        }
                                        return safe
                                    }
                            }
                        }
                        try self.transcripts.mutate(taskID, turns: .none) { transcript in
                            transcript.sensitiveTurnIDs = Array(Set(transcript.sensitiveTurnIDs ?? []).union(matchedPrivateRecoveryTurnIDs)).sorted()
                            if provider == .codex {
                                transcript.sensitiveCodexTurnIDs = Array(Set(transcript.sensitiveCodexTurnIDs ?? []).union(matchedPrivateRecoveryTurnIDs)).sorted()
                                transcript.sensitiveCodexSecretTurnIDs = Array(Set(transcript.sensitiveCodexSecretTurnIDs ?? []).union(currentSecretRecoveryTurnIDs)).sorted()
                                var storedMessages = transcript.sensitiveCodexTurnMessages ?? [:]
                                storedMessages.merge(safeCodexMessages) { _, new in new }
                                transcript.sensitiveCodexTurnMessages = storedMessages
                            }
                            transcript.pendingSensitiveUserInputRedaction = false
                        }
                    } catch {
                        // Keep the pending marker so later reads redact conservatively.
                    }
                }
                let currentTranscript = try? self.transcripts.readState(taskID)
                let safeMessages = history.messages.filter { message in
                    guard let turnID = message.turnID else { return true }
                    return !privateOutcomeReminderTurnIDs.contains(turnID)
                }.map { message -> ConversationMessage in
                    if let turnID = message.turnID, allPrivateTurnIDs.contains(turnID) {
                        var privateMessage = message
                        privateMessage.text = message.role == .user
                            ? Self.privatePromptPlaceholder(for: message.text)
                            : (allPrivateReminderTurnIDs.contains(turnID)
                                ? Self.privateOutcomeReminderResponsePlaceholder
                                : "[Response to private answer hidden]")
                        privateMessage.asyncQuestions = nil
                        return privateMessage
                    }
                    if hideSensitiveRecoveryPrompt,
                       message.role == .user,
                       Self.isPrivateTaskPrompt(message.text) {
                        var privatePrompt = message
                        privatePrompt.text = Self.privatePromptPlaceholder(for: message.text)
                        privatePrompt.asyncQuestions = nil
                        return privatePrompt
                    }
                    return Self.redactingSensitiveMessages(
                        [message], turnIDs: [], values: sensitiveUserInputAnswerValues,
                        redactAllMessages: currentTranscript?.pendingSensitiveUserInputRedaction == true
                    )[0]
                }
                let hideProviderDetails = hidesRecoveryOutput
                    || currentTranscript?.pendingSensitiveUserInputRedaction == true
                let modelIDs = currentTranscript?.segments.reduce(into: [String: String]()) { result, segment in
                    result.merge(segment.codexTurnModelIDs) { existing, _ in existing }
                } ?? [:]
                let attributedMessages = safeMessages.map { message -> ConversationMessage in
                    var message = message
                    if provider == .codex {
                        message.createdAt = message.createdAt ?? currentTranscript?.messageTimestamps?[message.id]
                        message.provider = message.provider ?? .codex
                        if message.modelID == nil, let turnID = message.turnID { message.modelID = modelIDs[turnID] }
                    }
                    return message
                }
                history = ConversationHistory(
                    messages: attributedMessages,
                    activities: hideProviderDetails
                        ? []
                        : history.activities.filter { activity in
                            activity.turnID.map { !allPrivateTurnIDs.contains($0) } ?? true
                        },
                    timelineActivities: hideProviderDetails
                        ? []
                        : ConversationActivity.visibleTimelineActivities(
                            history.timelineActivities,
                            visibleMessageIDs: Set(attributedMessages.map(\.id)),
                            excludedTurnIDs: allPrivateTurnIDs
                        ),
                    diff: hideProviderDetails ? nil : history.diff,
                    answeredAsyncQuestionIDs: (try? self.tasks.answeredAsyncQuestionIDs(taskID: taskID)) ?? [],
                    pendingUserInputRequest: history.pendingUserInputRequest,
                    providerBoundaries: history.providerBoundaries
                )
                onUpdate(ConversationUpdate(type: "history", history: self.standaloneChatDisplayHistory(taskID: taskID, history)))
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
                if claudeTurnID != nil {
                    self.recordClaudeMessage(taskID: taskID, turnID: claudeTurnID, modelID: modelID, ConversationMessage(
                        id: UUID().uuidString.lowercased(), role: .user, text: message, imageDataURLs: images
                    ))
                }
                onUpdate(ConversationUpdate(type: "steered_message", message: message, imageDataURLs: images))
            },
            onProgressMessage: { message in
                var safeMessage = message
                safeMessage.text = Self.redactingSensitiveText(message.text, values: sensitiveUserInputAnswerValues)
                safeMessage.asyncQuestions = message.asyncQuestions?.map { question in
                    ConversationAsyncQuestion(
                        title: Self.redactingSensitiveText(question.title, values: sensitiveUserInputAnswerValues),
                        options: question.options?.map { Self.redactingSensitiveText($0, values: sensitiveUserInputAnswerValues) }
                    )
                }
                if let claudeTurnID {
                    self.recordClaudeMessage(taskID: taskID, turnID: claudeTurnID, modelID: modelID, safeMessage)
                }
                // A notice the provider's runtime added to the turn streams as the user-side
                // message it is recorded as, not as the assistant's progress.
                if safeMessage.role == .user {
                    streamTurnUpdate(ConversationUpdate(type: "steered_message", message: safeMessage.text))
                    return
                }
                streamTurnUpdate(ConversationUpdate(
                    type: "assistant_progress",
                    text: safeMessage.text,
                    itemID: safeMessage.id,
                    phase: safeMessage.phase,
                    asyncQuestions: safeMessage.asyncQuestions
                ))
            },
            onMessageTimestamp: { id, date in
                do {
                    try self.transcripts.mutate(taskID, turns: .none) { transcript in
                        var timestamps = transcript.messageTimestamps ?? [:]
                        if timestamps[id] == nil { timestamps[id] = date }
                        transcript.messageTimestamps = timestamps
                    }
                } catch {
                    PlayhouseDiagnostics.record("conversation.timestamp.write_failed", fields: PlayhouseDiagnostics.errorFields(error))
                }
            },
            onTurnStarted: { turnID in
                if provider == .codex, let segment {
                    self.recordCodexTurnStarted(taskID: taskID, segmentID: segment.segmentID, turnID: turnID, modelID: modelID)
                }
            },
            onTokenUsage: { report in
                // A private recovery turn still costs tokens, so the task's
                // totals include it, but its per-turn row is withheld for the
                // same reason its activity and messages are.
                let isHidden = hidesRecoveryOutput
                let attributed = ConversationTurnUsageReport(
                    turnID: isHidden ? nil : (provider == .claude ? claudeTurnID : report.turnID),
                    usage: report.usage,
                    toolLabels: isHidden ? [] : report.toolLabels,
                    liveCall: report.liveCall
                )
                let claudeConfigDirectory = (client as? ClaudeCodeClient)?.configDirectory
                if recording.checksResumeCacheMiss, let call = report.liveCall, call.agentID == nil, call.calls > 0 {
                    // Only the resumed turn's first call tells whether the cache survived.
                    recording.checksResumeCacheMiss = false
                    if ContextCompactionPolicy.isCacheMiss(cacheReadTokens: call.cacheReadTokens, cacheWriteTokens: call.cacheWriteTokens) {
                        self.recordPromptCacheMiss(taskID: taskID, PromptCacheMissEvent(
                            id: UUID().uuidString.lowercased(), recordedAt: .now, turnID: claudeTurnID,
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

    /// Settles a turn that ended: its activity durations, the outcome it reported and the
    /// status that outcome decides, and the auto-PR on Review. A sent turn and a turn this daemon
    /// reattached after a restart both finish here.
}
