import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func history(
        taskID: UUID,
        onActionRequest: @escaping () -> Void = {},
        sensitiveUserInputAnswerValues: [String] = [],
        restoringEarlierChatPages: Bool = false,
        messageLimit: Int? = nil,
        beforeMessageID: String? = nil,
        includesImageData: Bool = false
    ) async throws -> ConversationHistory {
        if let messageLimit, messageLimit < 1 {
            throw BridgeCommandError(code: "invalid_argument", message: "The history limit must be a positive number of messages.")
        }
        var source = "composed"
        var history: ConversationHistory
        if let messageLimit, sensitiveUserInputAnswerValues.isEmpty,
           let page = try storedTranscriptPage(taskID: taskID, messageLimit: messageLimit, beforeMessageID: beforeMessageID) {
            history = page
            source = "stored-page"
        } else {
            history = try await composedHistory(
                taskID: taskID,
                onActionRequest: onActionRequest,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                restoringEarlierChatPages: restoringEarlierChatPages
            )
            if messageLimit != nil || beforeMessageID != nil {
                let end = try Self.pageEnd(of: history.messages, before: beforeMessageID)
                let start = messageLimit.map { max(0, end - $0) } ?? 0
                history.earlierMessageCount = start
                history.messages = Array(history.messages[start..<end])
                history.timelineActivities = ConversationActivity.visibleTimelineActivities(
                    history.timelineActivities, visibleMessageIDs: Set(history.messages.map(\.id)), excludedTurnIDs: []
                )
            }
        }
        var hydratedImageMessages = 0
        if includesImageData {
            // Composition reads transcript messages without their image data;
            // fill it in for the messages actually returned.
            let images = try transcripts.imageDataURLs(taskID, messageIDs: Set(history.messages.compactMap {
                $0.imageDataURLs.isEmpty ? $0.id : nil
            }))
            if !images.isEmpty {
                history.messages = history.messages.map { message in
                    guard message.imageDataURLs.isEmpty, let byTurn = images[message.id],
                          let stored = message.turnID.flatMap({ byTurn[$0] }) ?? (byTurn.count == 1 ? byTurn.values.first : nil)
                    else { return message }
                    hydratedImageMessages += 1
                    var message = message
                    message.imageDataURLs = stored
                    return message
                }
            }
        }
        PlayhouseDiagnostics.record("conversation.history.read", fields: [
            "taskID": taskID.uuidString,
            "source": source,
            "messageLimit": messageLimit.map(String.init) ?? "none",
            "beforeMessageProvided": String(beforeMessageID != nil),
            "returnedMessageCount": String(history.messages.count),
            "earlierMessageCount": history.earlierMessageCount.map(String.init) ?? "none",
            "hydratedImageMessageCount": String(hydratedImageMessages),
        ])
        return history
    }

    static func pageEnd(of messages: [ConversationMessage], before messageID: String?) throws -> Int {
        guard let messageID else { return messages.count }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw BridgeCommandError(code: "not_found", message: "That message is not in this conversation's history.")
        }
        return index
    }

    /// A page read straight from stored rows, loading only the turns it covers.
    /// It applies only where composing the whole transcript would order these
    /// messages by stored position alone: a Claude-only task with no Codex
    /// thread, no pending private-answer redaction, and no positioned elements. Otherwise
    /// returns nil and the caller composes the whole history and slices it.
    func storedTranscriptPage(taskID: UUID, messageLimit: Int, beforeMessageID: String?) throws -> ConversationHistory? {
        let task = try tasks.conversationSubject(taskID)
        guard !task.isStandaloneChat, task.codexThreadID == nil else { return nil }
        let store = try transcripts
        let state = try store.readState(taskID)
        // Private Claude turns (`sensitiveTurnIDs`) only filter compaction rows in
        // composition, and a page here has none, so they don't block this read.
        guard !state.segments.isEmpty, state.segments.allSatisfy({ $0.provider == .claude }),
              state.pendingSensitiveUserInputRedaction != true,
              (state.sensitiveCodexTurnIDs ?? []).isEmpty else { return nil }
        let outline = try store.outline(taskID)
        guard !outline.hasPositionedElements else { return nil }
        // Composition orders by segment before position, so stored order holds
        // only while every turn's segment is known and never moves backward.
        var segmentIndex = -1
        for turn in outline.turns {
            guard let index = state.segmentIndex(of: turn.segmentID), index >= segmentIndex else { return nil }
            segmentIndex = index
        }
        let visibleTurns = outline.turns.filter { !$0.userTexts.contains(where: Self.isPrivateOutcomeReminderPrompt) }
        let messageIDs = visibleTurns.flatMap(\.messageIDs)
        let end: Int
        if let beforeMessageID {
            guard let index = messageIDs.firstIndex(of: beforeMessageID) else {
                throw BridgeCommandError(code: "not_found", message: "That message is not in this conversation's history.")
            }
            end = index
        } else {
            end = messageIDs.count
        }
        let start = max(0, end - messageLimit)
        // The turns overlapping [start, end), plus the latest visible turn, whose
        // activities the conversation shows wherever the page falls.
        var covered: [String] = []
        var offset = 0
        var firstCoveredOffset = 0
        for turn in visibleTurns {
            let range = offset..<(offset + turn.messageIDs.count)
            if range.overlaps(start..<end) {
                if covered.isEmpty { firstCoveredOffset = offset }
                covered.append(turn.id)
            }
            offset = range.upperBound
        }
        // The latest turn is the latest one the user started; status nudges after it only add their work.
        let latestIndex = visibleTurns.lastIndex { !$0.userTexts.contains(where: PrivateOutcomeNudgeMarker.matches) } ?? (visibleTurns.endIndex - 1)
        let activityTurns = latestIndex >= 0 ? Array(visibleTurns[latestIndex...]) : []
        var selection = ConversationTranscriptStore.TurnSelection(turnIDs: Set(covered))
        selection.turnIDs.formUnion(activityTurns.map(\.id))
        var partial = try store.read(taskID, turns: selection, includeImages: false)
        let latestTurn = partial.turns.last { $0.id == activityTurns.first?.id }
        let nudgeWork = partial.turns.filter { turn in activityTurns.dropFirst().contains { $0.id == turn.id } }
            .flatMap { $0.activities.filter { $0.isSubagent || $0.isTimelineToolCall } }
        partial.turns = partial.turns.filter { covered.contains($0.id) }
        let composed = Self.compose(transcript: partial, codex: nil)
        let modelIDs = state.segments.reduce(into: [String: String]()) { result, segment in
            result.merge(segment.codexTurnModelIDs) { existing, _ in existing }
        }
        let pageStart = start - firstCoveredOffset
        // Composition numbers the covered turns from zero; every visible message
        // before them precedes them in the whole conversation's timeline.
        let pageMessages = composed.messages.dropFirst(pageStart).prefix(end - start).map { message -> ConversationMessage in
            var message = message
            message.timelineOrder = message.timelineOrder.map { $0 + firstCoveredOffset }
            if message.provider == nil, message.turnID != nil { message.provider = .codex }
            if message.modelID == nil, let turnID = message.turnID { message.modelID = modelIDs[turnID] }
            return message
        }
        let earlierTurnIDs = visibleTurns.prefix(max(latestIndex, 0)).map(\.id)
        let pageMessageIDs = Set(pageMessages.map(\.id))
        return ConversationHistory(
            messages: Array(pageMessages),
            activities: try store.subagentActivities(taskID, turnIDs: earlierTurnIDs) + (latestTurn?.activities ?? []) + nudgeWork,
            timelineActivities: ConversationActivity.visibleTimelineActivities(
                composed.timelineActivities, visibleMessageIDs: pageMessageIDs, excludedTurnIDs: []
            ),
            diff: nil,
            answeredAsyncQuestionIDs: try tasks.answeredAsyncQuestionIDs(taskID: taskID),
            pendingUserInputRequest: visiblePendingUserInputRequest(taskID: taskID, transcript: state),
            providerBoundaries: [],
            earlierMessageCount: start
        )
    }

    func composedHistory(
        taskID: UUID,
        onActionRequest: @escaping () -> Void,
        sensitiveUserInputAnswerValues: [String],
        restoringEarlierChatPages: Bool
    ) async throws -> ConversationHistory {
        let task = try tasks.conversationSubject(taskID)
        let transcript = try transcripts.read(taskID, turns: .all, includeImages: false)
        let answered = try tasks.answeredAsyncQuestionIDs(taskID: taskID)
        // Tasks that never left Codex keep reading their native Codex thread.
        let hasSensitiveRecoveryState = transcript.pendingUserInputRequest != nil
            || transcript.pendingSensitiveUserInputRedaction == true
            || !(transcript.sensitiveTurnIDs ?? []).isEmpty
            || !(transcript.sensitiveCodexTurnIDs ?? []).isEmpty
        guard !transcript.isEmpty || hasSensitiveRecoveryState else {
            let codex = try await codexHistory(
                task: task,
                onActionRequest: onActionRequest,
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues
            )
                ?? ConversationHistory(messages: [], activities: [], diff: nil)
            return ConversationHistory(
                messages: Self.redactingSensitiveMessages(
                    Self.codexMessagesForDisplay(codex.messages, transcript: transcript),
                    turnIDs: [],
                    redactAllMessages: transcript.pendingSensitiveUserInputRedaction == true
                ),
                activities: transcript.pendingSensitiveUserInputRedaction == true
                    ? []
                    : codex.activities.filter { $0.turnID.map(Self.sensitiveCodexTurnIDs(transcript).contains) != true },
                timelineActivities: transcript.pendingSensitiveUserInputRedaction == true
                    ? []
                    : ConversationActivity.visibleTimelineActivities(
                        codex.timelineActivities,
                        visibleMessageIDs: Set(Self.codexMessagesForDisplay(codex.messages, transcript: transcript).map(\.id)),
                        excludedTurnIDs: Self.sensitiveCodexTurnIDs(transcript).union(codex.messages.filter {
                            $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text)
                        }.compactMap(\.turnID))
                    ),
                diff: Self.shouldHideCodexDiff(transcript, codex: codex) ? nil : codex.diff,
                answeredAsyncQuestionIDs: answered,
                pendingUserInputRequest: visiblePendingUserInputRequest(taskID: taskID, transcript: transcript)
            )
        }
        // Codex can't list a thread before its first turn, so a mixed transcript
        // reads Codex only once a Codex segment owns turns or has recovery state.
        let usesCodex = task.codexThreadID != nil && (
            transcript.segments.contains { $0.provider == .codex && !$0.codexTurnIDs.isEmpty }
                || transcript.pendingSensitiveUserInputRedaction == true
                || transcript.pendingUserInputRequest != nil
                || !(transcript.sensitiveTurnIDs ?? []).isEmpty
                || !(transcript.sensitiveCodexTurnIDs ?? []).isEmpty
        )
        let codex = usesCodex ? try await codexHistory(
            task: task,
            onActionRequest: onActionRequest,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues
        ) : nil
        let composed = Self.compose(transcript: transcript, codex: codex)
        let visibleMessages = Self.redactingSensitiveMessages(
            composed.messages,
            turnIDs: [],
            redactAllMessages: transcript.pendingSensitiveUserInputRedaction == true
        )
        let modelIDs = transcript.segments.reduce(into: [String: String]()) { result, segment in
            result.merge(segment.codexTurnModelIDs) { existing, _ in existing }
        }
        let messages = visibleMessages.map { message -> ConversationMessage in
            var message = message
            if message.provider == nil, message.turnID != nil { message.provider = .codex }
            if message.modelID == nil, let turnID = message.turnID { message.modelID = modelIDs[turnID] }
            return message
        }
        return ConversationHistory(
            messages: task.isStandaloneChat && restoringEarlierChatPages
                ? standaloneChatMessagesRestoringEarlierPages(taskID: taskID, messages)
                : messages,
            activities: transcript.pendingSensitiveUserInputRedaction == true ? [] : composed.activities,
            timelineActivities: composed.timelineActivities,
            diff: transcript.pendingSensitiveUserInputRedaction == true ? nil : composed.diff,
            answeredAsyncQuestionIDs: answered,
            pendingUserInputRequest: visiblePendingUserInputRequest(taskID: taskID, transcript: transcript),
            providerBoundaries: composed.providerBoundaries
        )
    }

    /// Each page runs in its own provider session, so a provider that answers history from its
    /// native thread (Codex) only knows the current page. The local page archive restores the
    /// earlier pages ahead of them, keeping the whole chat visible while context stays per page.
    func standaloneChatMessagesRestoringEarlierPages(
        taskID: UUID,
        _ messages: [ConversationMessage]
    ) -> [ConversationMessage] {
        guard let chatManager = try? tasks.standaloneChatManager(),
              let pages = try? chatManager.listPages(limit: 500), !pages.isEmpty else { return messages }
        let knownTurnIDs = Set(messages.compactMap(\.turnID))
        var restored: [ConversationMessage] = []
        for page in pages.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let archived = try? chatManager.messages(pageID: page.id) else { continue }
            for message in archived where !knownTurnIDs.contains(message.turnID) {
                restored.append(ConversationMessage(
                    id: message.id,
                    role: ConversationRole(rawValue: message.role) ?? .user,
                    text: message.text,
                    turnID: message.turnID,
                    provider: ConversationProvider(rawValue: page.provider),
                    createdAt: message.createdAt
                ))
            }
        }
        return restored.isEmpty ? messages : restored + messages
    }
    func codexHistory(
        task: any ConversationSubject,
        onActionRequest: @escaping () -> Void,
        sensitiveUserInputAnswerValues: [String] = []
    ) async throws -> ConversationHistory? {
        guard let threadID = task.codexThreadID else { return nil }
        let taskID = task.id
        // A window and the CLI share one client and app-server; only a window's read follows the
        // thread's Goal turns and takes the action handler (see `loadThread`).
        let codex = clients.codex
        let recoveryTranscript = try? transcripts.readState(taskID)
        let hasSensitiveRecoveryState = recoveryTranscript?.pendingUserInputRequest != nil
            || recoveryTranscript?.pendingSensitiveUserInputRedaction == true
            || !(recoveryTranscript?.sensitiveTurnIDs ?? []).isEmpty
            || !(recoveryTranscript?.sensitiveCodexTurnIDs ?? []).isEmpty
        // Reading history can load the thread, which a later send then reuses,
        // so it carries the same skill bridge a send would.
        let workspace = try launchWorkspace(for: task, roots: Self.historyRoots(task).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        let settings = settingsManager
        let repositoryRoot = settings.defaultParentFolderURL
        PlayhouseDiagnostics.record("conversation.history.started", fields: codex.diagnosticFields([
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "taskStatus": task.status.rawValue
        ]))
        do {
            let history = try await codex.loadThread(
                id: threadID,
                workspace: workspace,
                modelID: try? modelID(taskID: taskID),
                developerInstructions: TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: repositoryRoot?.path,
                    isStandaloneChat: task.isStandaloneChat,
                    isPluginEditor: task.authoringPluginID != nil,
                    isArchived: task.status == .done,
                    pluginPlacement: task.authoringPluginPlacement,
                    pluginID: task.authoringPluginID,
                    pluginsDirectory: clients.skills?.pluginsDirectory
                ),
                sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
                sensitiveConversation: hasSensitiveRecoveryState,
                observeGoalTurns: clients.observesGoalTurns,
                onActionRequest: onActionRequest
            )
            let savedDurations = tasks.conversationActivityDurations(taskID: taskID)
            let activities = history.activities.map { activity -> ConversationActivity in
                var activity = activity
                if activity.durationMs == nil { activity.durationMs = savedDurations[activity.id] }
                return activity
            }
            PlayhouseDiagnostics.record("conversation.history.succeeded", fields: codex.diagnosticFields([
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "messageCount": String(history.messages.count),
                "activityCount": String(history.activities.count)
            ]))
            return ConversationHistory(
                messages: history.messages, activities: activities,
                timelineActivities: history.timelineActivities, diff: history.diff
            )
        } catch {
            var fields: [String: String]
            if hasSensitiveRecoveryState && sensitiveUserInputAnswerValues.isEmpty {
                // After a restart the answer is deliberately not persisted, so
                // provider supplied error text cannot be safely scrubbed.
                fields = ["errorDescription": "History for a private recovery conversation could not be loaded."]
            } else {
                fields = PlayhouseDiagnostics.errorFields(
                    error,
                    redacting: [task.title, task.savedPrompt ?? "", task.pendingSubmittedPrompt ?? ""] + sensitiveUserInputAnswerValues
                )
            }
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["taskStatus"] = task.status.rawValue
            fields.merge(codex.diagnosticFields()) { _, new in new }
            PlayhouseDiagnostics.record("conversation.history.failed", fields: fields)
            if hasSensitiveRecoveryState {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "History for a private recovery conversation could not be loaded."
                )
            }
            throw error
        }
    }

    /// Orders every visible element by provider segment, then by its position
    /// within that provider's own timeline, and inserts a divider wherever the
    /// provider changes.
    static func compose(transcript: ConversationTranscript, codex: ConversationHistory?) -> ConversationHistory {
        enum Element {
            case message(ConversationMessage)
            case compaction(ConversationActivity)
        }
        var elements: [(segment: Int, order: Int, tieBreak: Int, element: Element)] = []
        let segments = transcript.segments
        let lastCodexSegment = segments.lastIndex { $0.provider == .codex } ?? -1
        var codexSegmentByTurn: [String: Int] = [:]
        for (index, segment) in segments.enumerated() where segment.provider == .codex {
            for turnID in segment.codexTurnIDs where codexSegmentByTurn[turnID] == nil {
                codexSegmentByTurn[turnID] = index
            }
        }
        func codexSegment(_ turnID: String?) -> Int {
            turnID.flatMap { codexSegmentByTurn[$0] } ?? lastCodexSegment
        }
        var codexTurnSegment: Int?
        let sensitiveTurnIDs = Self.sensitiveCodexTurnIDs(transcript)
        let safeCodexMessages = Self.codexMessagesForDisplay(codex?.messages ?? [], transcript: transcript)
        func transcriptOrder(for message: ConversationMessage, fallback: Int) -> (order: Int, tieBreak: Int) {
            guard message.provider == .codex, message.phase == "agent_image" else {
                return (message.timelineOrder ?? fallback, 0)
            }
            if let order = message.timelineOrder { return (order, 0) }
            let relevantMessages = message.turnID.map { turnID in
                safeCodexMessages.filter { $0.turnID == turnID }
            } ?? safeCodexMessages
            guard let lastTurnOrder = relevantMessages.compactMap(\.timelineOrder).max() else {
                return (fallback, 0)
            }
            // Keep the image just after the final native item of its turn and
            // ahead of the next turn's first item, even when their orders touch.
            return (lastTurnOrder, fallback + 1)
        }
        for (offset, message) in safeCodexMessages.enumerated() {
            let segment = message.turnID.map(codexSegment) ?? codexTurnSegment ?? lastCodexSegment
            codexTurnSegment = segment
            var attributed = message
            attributed.provider = attributed.provider ?? .codex
            if attributed.modelID == nil, let turnID = attributed.turnID {
                attributed.modelID = segments.compactMap { $0.codexTurnModelIDs[turnID] }.first
            }
            elements.append((segment, message.timelineOrder ?? offset, 0, .message(attributed)))
        }
        let privateReminderTurnIDs = Set(codex?.messages.filter {
            $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text)
        }.compactMap(\.turnID) ?? [])
        let privateTranscriptReminderTurnIDs = Set(transcript.turns.compactMap { turn in
            turn.messages.contains { $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text) } ? turn.id : nil
        })
        let allSensitiveTurnIDs = Set(transcript.sensitiveTurnIDs ?? [])
        let playhouseCodexCompactionIDs = Set((transcript.contextCompactions ?? []).compactMap {
            $0.provider == ConversationProvider.codex.rawValue ? $0.providerActivityID : nil
        })
        let codexActivities = transcript.pendingSensitiveUserInputRedaction == true
            ? []
            : (codex?.activities ?? []).filter {
                !playhouseCodexCompactionIDs.contains($0.id)
                    && $0.turnID.map { sensitiveTurnIDs.contains($0) || privateReminderTurnIDs.contains($0) } != true
            }
        for activity in codexActivities where activity.isContextCompaction {
            let order = activity.timelineOrder ?? Int.max
            let precedingTurn = codex?.messages.last { ($0.timelineOrder ?? 0) < order }?.turnID
            elements.append((codexSegment(activity.turnID ?? precedingTurn), order, 0, .compaction(activity)))
        }
        var localOrder = 0
        for turn in transcript.turns {
            if privateTranscriptReminderTurnIDs.contains(turn.id) { continue }
            let segment = transcript.segmentIndex(of: turn.segmentID) ?? segments.count
            for message in turn.messages {
                let position = transcriptOrder(for: message, fallback: localOrder)
                elements.append((segment, position.order, position.tieBreak, .message(message)))
                localOrder += 1
            }
            for activity in turn.activities where activity.turnID.map(allSensitiveTurnIDs.contains) != true {
                if activity.isContextCompaction {
                    elements.append((segment, activity.timelineOrder ?? localOrder, 0, .compaction(activity)))
                }
                localOrder += 1
            }
        }
        elements.sort { ($0.segment, $0.order, $0.tieBreak) < ($1.segment, $1.order, $1.tieBreak) }

        var messages: [ConversationMessage] = []
        var compactions: [ConversationActivity] = []
        var lastMessageBeforeSegment: [Int: String] = [:]
        var lastMessageID: String?
        var nextSegment = 0
        for (order, item) in elements.enumerated() {
            while nextSegment <= item.segment, nextSegment < segments.count {
                lastMessageBeforeSegment[nextSegment] = lastMessageID
                nextSegment += 1
            }
            switch item.element {
            case .message(var message):
                message.timelineOrder = order
                messages.append(message)
                lastMessageID = message.id
            case .compaction(var activity):
                activity.timelineOrder = order
                compactions.append(activity)
            }
        }
        while nextSegment < segments.count {
            lastMessageBeforeSegment[nextSegment] = lastMessageID
            nextSegment += 1
        }
        var boundaries: [ConversationProviderBoundary] = []
        for index in segments.indices.dropFirst() where segments[index].provider != segments[index - 1].provider {
            boundaries.append(ConversationProviderBoundary(
                id: "provider-boundary-\(segments[index].id)",
                provider: segments[index].provider,
                afterMessageID: lastMessageBeforeSegment[index] ?? nil
            ))
        }

        // Activity details follow the latest turn, as each provider reports them.
        let activities: [ConversationActivity]
        let diff: ConversationTurnDiff?
        if segments.last?.provider == .claude {
            let visibleTurns = transcript.turns.filter { !privateTranscriptReminderTurnIDs.contains($0.id) }
            // The latest turn is the latest one the user started. Status nudges Playhouse sent
            // after it are shown as messages, but only the work they did joins its activities.
            let latestTurnIndex = visibleTurns.lastIndex { turn in
                !turn.messages.contains { $0.role == .user && PrivateOutcomeNudgeMarker.matches($0.text) }
            } ?? visibleTurns.endIndex - 1
            let latestTurn = latestTurnIndex >= 0 ? visibleTurns[latestTurnIndex] : nil
            let nudgeWork = visibleTurns.suffix(from: min(latestTurnIndex + 1, visibleTurns.endIndex))
                .flatMap { $0.activities.filter { $0.isSubagent || $0.isTimelineToolCall } }
            let subagents = visibleTurns.enumerated().filter { $0.offset < latestTurnIndex }.flatMap { $0.element.activities.filter(\.isSubagent) }
            activities = subagents + (latestTurn?.activities ?? []) + nudgeWork + compactions
            diff = nil
        } else {
            activities = codexActivities.filter { !$0.isContextCompaction } + compactions
            diff = Self.shouldHideCodexDiff(transcript, codex: codex) ? nil : codex?.diff
        }
        // Every turn's tool calls, each placed after the message it followed.
        var timelineActivities: [ConversationActivity] = []
        if transcript.pendingSensitiveUserInputRedaction != true {
            let visibleTurns = transcript.turns.filter { !privateTranscriptReminderTurnIDs.contains($0.id) }
            timelineActivities = ConversationActivity.visibleTimelineActivities(
                (codex?.timelineActivities ?? []).filter { !playhouseCodexCompactionIDs.contains($0.id) }
                    + visibleTurns.flatMap(\.activities),
                visibleMessageIDs: Set(messages.map(\.id)),
                excludedTurnIDs: sensitiveTurnIDs.union(privateReminderTurnIDs).union(allSensitiveTurnIDs)
                    .union(privateTranscriptReminderTurnIDs)
            )
        }
        var history = ConversationHistory(
            messages: messages,
            activities: activities,
            diff: diff,
            pendingUserInputRequest: transcript.pendingUserInputRequest,
            providerBoundaries: boundaries
        )
        history.timelineActivities = timelineActivities
        return history
    }

    /// Reads a subagent's work without resuming or changing its turn.
    func subagentHistory(taskID: UUID, activity: ConversationActivity) async throws -> ConversationHistory {
        let task = try tasks.conversationSubject(taskID)
        guard let childID = activity.childThreadID else {
            throw BridgeCommandError(code: "invalid_argument", message: "That activity is not a subagent.")
        }
        let isClaudeSubagent = try transcripts.read(taskID, turns: .all, includeImages: false).turns.contains { turn in
            turn.activities.contains { $0.childThreadID == childID }
        }
        guard isClaudeSubagent else {
            let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
            return try await clients.codex.inspectThreadReadOnly(id: childID, workspace: workspace)
        }
        // Claude Code reports a subagent's prompt summary and final report to its
        // parent; Playhouse shows those rather than its private sidechain.
        let report = ConversationMessage(id: "\(childID)-report", role: .assistant, text: activity.detail, phase: "final_answer", provider: .claude)
        return ConversationHistory(messages: [report], activities: [], diff: nil)
    }

    func searchArchive(query: String, codexHomePath: String? = nil) async throws -> [BoardTaskRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Archive search query can't be blank.")
        }
        let completed = try tasks.list(status: .done)
        let titleMatches = completed.filter { $0.title.localizedCaseInsensitiveContains(normalizedQuery) }
        let titleIDs = Set(titleMatches.map(\.id))
        let root: URL
        if let codexHomePath, !codexHomePath.isEmpty {
            root = URL(fileURLWithPath: codexHomePath, isDirectory: true)
        } else if let environmentRoot = PlayhouseProcessEnvironment.current["CODEX_HOME"], !environmentRoot.isEmpty {
            root = URL(fileURLWithPath: environmentRoot, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        let roots = [root.appendingPathComponent("sessions", isDirectory: true), root.appendingPathComponent("archived_sessions", isDirectory: true)]
        let taskByThread = Dictionary(completed.compactMap { task -> (String, UUID)? in
            guard !titleIDs.contains(task.id), let threadID = task.codexThreadID else { return nil }
            return (threadID, task.id)
        }, uniquingKeysWith: { first, _ in first })
        let scanTask = Task.detached(priority: .userInitiated) {
            try Self.searchSessionFiles(query: normalizedQuery, taskByThread: taskByThread, roots: roots)
        }
        var conversationIDs = try await withTaskCancellationHandler {
            try await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        // Claude turns live in Playhouse's transcript store rather than a provider session file.
        let store = try transcripts
        let needle = normalizedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        for task in completed where !titleIDs.contains(task.id) && !conversationIDs.contains(task.id) {
            try Task.checkCancellation()
            let matches = try store.read(task.id, turns: .all, includeImages: false).turns.contains { turn in
                turn.messages.contains { $0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }
            }
            if matches { conversationIDs.insert(task.id) }
        }
        let byID = Dictionary(uniqueKeysWithValues: completed.map { ($0.id, $0) })
        let titles = titleMatches.sorted { $0.createdAt > $1.createdAt }
        let conversations = conversationIDs.compactMap { byID[$0] }.sorted { $0.createdAt > $1.createdAt }
        return titles + conversations
    }

    nonisolated static func searchSessionFiles(query: String, taskByThread: [String: UUID], roots: [URL]) throws -> Set<UUID> {
        var filesByThread: [String: [URL]] = [:]
        for sessionsRoot in roots {
            guard let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                try Task.checkCancellation()
                let basename = fileURL.deletingPathExtension().lastPathComponent
                guard let threadID = taskByThread.keys.first(where: { basename.hasSuffix("-\($0)") }) else { continue }
                filesByThread[threadID, default: []].append(fileURL)
            }
        }
        var conversationIDs = Set<UUID>()
        for (threadID, taskID) in taskByThread {
            for fileURL in filesByThread[threadID] ?? [] {
                try Task.checkCancellation()
                if try sessionFile(fileURL, contains: query) {
                    conversationIDs.insert(taskID)
                    break
                }
            }
        }
        return conversationIDs
    }

    nonisolated static func sessionFile(_ url: URL, contains query: String) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var pending = Data()
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let line = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
                if Self.messageText(in: line).contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }) { return true }
            }
        }
        if !pending.isEmpty, Self.messageText(in: pending).contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }) { return true }
        return false
    }

    nonisolated static func messageText(in line: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return [] }
        if type == "response_item", let itemType = payload["type"] as? String, itemType == "message",
           let role = payload["role"] as? String, role == "user" || role == "assistant",
           let content = payload["content"] as? [[String: Any]] {
            let searchableTextTypes: Set<String> = ["text", "input_text", "output_text"]
            return content.compactMap {
                guard let contentType = $0["type"] as? String, searchableTextTypes.contains(contentType) else { return nil }
                return $0["text"] as? String
            }
        }
        if type == "event_msg", let eventType = payload["type"] as? String,
           eventType == "UserMessage" || eventType == "AgentMessage",
           let message = payload["message"] as? String { return [message] }
        return []
    }
}
