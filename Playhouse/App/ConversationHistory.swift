import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    /// Reads a conversation from Playhouse's own transcript store. Every turn,
    /// whichever provider ran it, is recorded there as it streams, so history
    /// never asks a provider runtime for its thread.
    func history(
        taskID: UUID,
        onActionRequest: @escaping () -> Void = {},
        messageLimit: Int? = nil,
        beforeMessageID: String? = nil,
        afterMessageID: String? = nil,
        chatPageID: String? = nil,
        includesImageData: Bool = false
    ) async throws -> ConversationHistory {
        if let messageLimit, messageLimit < 1 {
            throw BridgeCommandError(code: "invalid_argument", message: "The history limit must be a positive number of messages.")
        }
        // A forward window starts at a chat page or right after a message and runs toward the newest.
        let readsForward = afterMessageID != nil || chatPageID != nil
        if readsForward, beforeMessageID != nil || (afterMessageID != nil && chatPageID != nil) {
            throw BridgeCommandError(code: "invalid_argument", message: "Read history before a message, after a message, or from a chat page; choose one.")
        }
        attachCodexThread(taskID: taskID, onActionRequest: onActionRequest)
        var source = "composed"
        var history: ConversationHistory
        if readsForward {
            history = try composedHistory(taskID: taskID)
            let start = try forwardWindowStart(taskID: taskID, in: history.messages, after: afterMessageID, chatPageID: chatPageID)
            let end = messageLimit.map { min(history.messages.count, start + $0) } ?? history.messages.count
            history.earlierMessageCount = start
            history.laterMessageCount = history.messages.count - end
            history.messages = Array(history.messages[start..<end])
            history.timelineActivities = ConversationActivity.visibleTimelineActivities(
                history.timelineActivities, visibleMessageIDs: Set(history.messages.map(\.id)), excludedTurnIDs: []
            )
            source = "composed-forward"
        } else if let messageLimit,
           let page = try storedTranscriptPage(taskID: taskID, messageLimit: messageLimit, beforeMessageID: beforeMessageID) {
            history = page
            source = "stored-page"
        } else {
            history = try composedHistory(taskID: taskID)
            if messageLimit != nil || beforeMessageID != nil {
                let end = try Self.pageEnd(of: history.messages, before: beforeMessageID)
                let start = messageLimit.map { max(0, end - $0) } ?? 0
                history.earlierMessageCount = start
                history.laterMessageCount = history.messages.count - end
                history.messages = Array(history.messages[start..<end])
                history.timelineActivities = ConversationActivity.visibleTimelineActivities(
                    history.timelineActivities, visibleMessageIDs: Set(history.messages.map(\.id)), excludedTurnIDs: []
                )
            }
        }
        var hydratedImageMessages = 0
        var deferredImageMessages = 0
        if includesImageData {
            // A reader that defers images opens on the newest turn the user started, so only
            // that turn's images travel with the page. Earlier messages are only marked:
            // their images can be tens of megabytes that the reader may never show.
            // An earlier page holds no part of that turn, so all of its images wait.
            let inlineStart = !defersHistoryImages ? 0
                : beforeMessageID != nil || readsForward ? history.messages.count
                : ConversationMessage.latestTurnStartIndex(in: history.messages) ?? 0
            let store = try transcripts
            let deferredTurns = try store.turnsWithImages(taskID, messageIDs: Set(history.messages[..<inlineStart].compactMap {
                $0.imageDataURLs.isEmpty ? $0.id : nil
            }))
            // Composition reads transcript messages without their image data;
            // fill it in for the messages actually returned.
            let images = try store.imageDataURLs(taskID, messageIDs: Set(history.messages[inlineStart...].compactMap {
                $0.imageDataURLs.isEmpty ? $0.id : nil
            }))
            history.messages = history.messages.enumerated().map { index, message in
                var message = message
                if index < inlineStart {
                    let stored = deferredTurns[message.id].map { turns in
                        message.turnID.map(turns.contains) == true || turns.count == 1
                    } == true
                    guard stored || !message.imageDataURLs.isEmpty else { return message }
                    deferredImageMessages += 1
                    message.imageDataURLs = []
                    message.imagesDeferred = true
                    return message
                }
                guard message.imageDataURLs.isEmpty, let byTurn = images[message.id],
                      let stored = message.turnID.flatMap({ byTurn[$0] }) ?? (byTurn.count == 1 ? byTurn.values.first : nil)
                else { return message }
                hydratedImageMessages += 1
                message.imageDataURLs = stored
                return message
            }
        }
        PlayhouseDiagnostics.record("conversation.history.read", fields: [
            "taskID": taskID.uuidString,
            "source": source,
            "messageLimit": messageLimit.map(String.init) ?? "none",
            "beforeMessageProvided": String(beforeMessageID != nil),
            "afterMessageProvided": String(afterMessageID != nil),
            "chatPageProvided": String(chatPageID != nil),
            "returnedMessageCount": String(history.messages.count),
            "earlierMessageCount": history.earlierMessageCount.map(String.init) ?? "none",
            "hydratedImageMessageCount": String(hydratedImageMessages),
            "deferredImageMessageCount": String(deferredImageMessages),
        ])
        return history
    }

    /// The images of the given messages, for a reader whose history read left
    /// them out (`imagesDeferred`). Messages without images are not returned.
    func messageImages(taskID: UUID, messageIDs: [String]) async throws -> [ConversationMessageImages] {
        _ = try tasks.conversationSubject(taskID)
        let wanted = Set(messageIDs)
        guard !wanted.isEmpty, !wanted.contains("") else {
            throw BridgeCommandError(code: "invalid_argument", message: "Name at least one message to read images for.")
        }
        let found = try transcripts.imageDataURLs(taskID, messageIDs: wanted).flatMap { id, byTurn in
            byTurn.map { ConversationMessageImages(id: id, turnID: $0.key, imageDataURLs: $0.value) }
        }
        PlayhouseDiagnostics.record("conversation.images.read", fields: [
            "taskID": taskID.uuidString,
            "requestedMessageCount": String(wanted.count),
            "returnedMessageCount": String(found.count),
        ])
        return found.sorted { ($0.id, $0.turnID ?? "") < ($1.id, $1.turnID ?? "") }
    }

    static func pageEnd(of messages: [ConversationMessage], before messageID: String?) throws -> Int {
        guard let messageID else { return messages.count }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            throw BridgeCommandError(code: "not_found", message: "That message is not in this conversation's history.")
        }
        return index
    }

    /// Where a forward window starts: right after `messageID`, or at the first message of the
    /// standalone chat page `chatPageID`.
    func forwardWindowStart(
        taskID: UUID, in messages: [ConversationMessage], after messageID: String?, chatPageID: String?
    ) throws -> Int {
        if let messageID {
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                throw BridgeCommandError(code: "not_found", message: "That message is not in this conversation's history.")
            }
            return index + 1
        }
        guard try tasks.conversationSubject(taskID).isStandaloneChat else {
            throw BridgeCommandError(code: "invalid_argument", message: "Only the standalone chat has pages to read history from.")
        }
        let pageByTurnID = try tasks.standaloneChatManager().pageAssignmentsByTurnID()
        guard let index = messages.firstIndex(where: { $0.turnID.flatMap { pageByTurnID[$0]?.id } == chatPageID }) else {
            throw BridgeCommandError(code: "not_found", message: "That chat page has no messages in this conversation's history.")
        }
        return index
    }

    /// A page read straight from stored rows, loading only the turns it covers.
    /// It applies wherever composing the whole transcript would order these
    /// messages by stored position alone: no positioned elements and turns whose
    /// segments never move backward. Otherwise returns nil and the caller
    /// composes the whole history and slices it.
    func storedTranscriptPage(taskID: UUID, messageLimit: Int, beforeMessageID: String?) throws -> ConversationHistory? {
        let store = try transcripts
        let state = try store.readState(taskID)
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
        let composed = Self.compose(transcript: partial)
        let pageStart = start - firstCoveredOffset
        // Composition numbers the covered turns from zero; every visible message
        // before them precedes them in the whole conversation's timeline.
        let pageMessages = composed.messages.dropFirst(pageStart).prefix(end - start).map { message -> ConversationMessage in
            var message = message
            message.timelineOrder = message.timelineOrder.map { $0 + firstCoveredOffset }
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
            diff: state.latestDiff,
            answeredAsyncQuestionIDs: try tasks.answeredAsyncQuestionIDs(taskID: taskID),
            pendingUserInputRequest: visiblePendingUserInputRequest(taskID: taskID, transcript: state),
            providerBoundaries: Self.providerBoundaries(segments: state.segments, turns: visibleTurns),
            earlierMessageCount: start,
            laterMessageCount: messageIDs.count - end
        )
    }

    func composedHistory(taskID: UUID) throws -> ConversationHistory {
        let transcript = try transcripts.read(taskID, turns: .all, includeImages: false)
        var history = Self.compose(transcript: transcript)
        history.answeredAsyncQuestionIDs = try tasks.answeredAsyncQuestionIDs(taskID: taskID)
        history.pendingUserInputRequest = visiblePendingUserInputRequest(taskID: taskID, transcript: transcript)
        return history
    }

    /// History no longer reads a Codex thread, but a window's read still
    /// attaches to it in the background: that follows the thread's Goal turns,
    /// which Codex starts on its own, and routes its approval requests here.
    func attachCodexThread(taskID: UUID, onActionRequest: @escaping () -> Void) {
        guard clients.observesGoalTurns, let task = try? tasks.conversationSubject(taskID),
              let threadID = task.codexThreadID, task.conversationProvider == .codex else { return }
        let codex = clients.codex
        recordCodexContextlessTurns(taskID: taskID, threadID: threadID)
        guard codex.goalObservationThreadID != threadID || codex.actionRequestHandler == nil else { return }
        guard let workspace = try? launchWorkspace(for: task, roots: Self.historyRoots(task).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }) else { return }
        let modelID = try? modelID(taskID: taskID)
        let developerInstructions = TaskThreadDeveloperInstructions.make(
            taskID: taskID,
            repositories: task.repositoryWorktrees,
            contextFolders: task.contextFolderPaths,
            repositoryRootPath: settingsManager.defaultParentFolderURL?.path,
            isStandaloneChat: task.isStandaloneChat,
            isPluginEditor: task.authoringPluginID != nil,
            isArchived: task.status == .done,
            pluginPlacement: task.authoringPluginPlacement,
            pluginID: task.authoringPluginID,
            pluginName: (task as? StandaloneChat)?.pluginAuthoringName,
            pluginPresentation: (task as? StandaloneChat)?.pluginAuthoringPresentation,
            pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory
        )
        Task { @MainActor in
            do {
                try await codex.attachThread(
                    id: threadID, workspace: workspace, modelID: modelID,
                    developerInstructions: developerInstructions, onActionRequest: onActionRequest
                )
            } catch {
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["taskID"] = taskID.uuidString
                fields["threadID"] = threadID
                PlayhouseDiagnostics.record("conversation.codex_attach.failed", fields: fields)
            }
        }
    }

    /// Records a turn Codex ran on its own, such as a Goal's work turn, into its own local
    /// turn when it ends, from the items it streamed; no Playhouse send's callbacks saw them.
    func recordCodexGoalTurn(taskID: UUID, threadID: String, turnID: String, entries: [[String: Any]]) async {
        do {
            let task = try tasks.conversationSubject(taskID)
            // `.turn` also loads the latest turn, so the check names this turn.
            guard task.codexThreadID == threadID,
                  try !transcripts.read(taskID, turns: .turn(turnID), includeImages: false).turns.contains(where: { $0.id == turnID }) else {
                PlayhouseDiagnostics.record("conversation.codex_goal_turn.skipped", fields: [
                    "taskID": taskID.uuidString, "threadID": threadID, "turnID": turnID,
                    "reason": task.codexThreadID == threadID ? "already_recorded" : "thread_changed",
                ])
                return
            }
            let messages = entries.compactMap(CodexAppServerClient.chatMessage(from:))
            let activities = entries.compactMap { entry -> ConversationActivity? in
                guard let item = entry["item"] as? [String: Any] else { return nil }
                return ConversationActivity.from(item: item, lifecycle: "completed", turnID: turnID)
            }
            guard !messages.isEmpty else {
                PlayhouseDiagnostics.record("conversation.codex_goal_turn.skipped", fields: [
                    "taskID": taskID.uuidString, "threadID": threadID, "turnID": turnID, "reason": "no_messages",
                ])
                return
            }
            // The task's model belongs to its current provider; one that left Codex keeps the
            // model Codex last ran with.
            let currentModelID = try? modelID(taskID: taskID)
            let modelID = task.conversationProvider == .codex
                ? currentModelID ?? nil
                : latestTranscriptModelID(taskID: taskID, provider: .codex)
            try transcripts.mutate(taskID, turns: .turn(turnID)) { transcript in
                guard !transcript.turns.contains(where: { $0.id == turnID }) else { return }
                // Codex ran this turn, whichever provider the task uses now: it joins the
                // current Codex segment, or opens one that needs no handoff.
                if transcript.segments.last?.provider != .codex {
                    transcript.segments.append(.init(id: UUID().uuidString, provider: .codex, startedAt: .now, handoffDelivered: true))
                }
                guard let segmentID = transcript.segments.last?.id else { return }
                transcript.turns.append(.init(
                    id: turnID, segmentID: segmentID,
                    messages: messages.map { message in
                        var message = message
                        message.provider = .codex
                        message.modelID = message.modelID ?? modelID
                        message.timelineOrder = nil
                        message.createdAt = message.createdAt ?? .now
                        return message
                    },
                    activities: activities.filter { !$0.isContextCompaction }
                ))
                if let index = transcript.segments.firstIndex(where: { $0.id == segmentID }) {
                    if !transcript.segments[index].codexTurnIDs.contains(turnID) {
                        transcript.segments[index].codexTurnIDs.append(turnID)
                    }
                    if let modelID { transcript.segments[index].codexTurnModelIDs[turnID] = modelID }
                }
            }
            Self.bumpVisibleRevision(taskID)
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            PlayhouseDiagnostics.record("conversation.codex_goal_turn.record_failed", fields: fields)
        }
    }

    /// Has the Codex client record the turns it runs on its own in this task's thread.
    /// The recorder holds this manager strongly: the bridge builds a manager per request, so a
    /// weak one would be gone before the turn ends. Each install replaces the thread's last one.
    func recordCodexContextlessTurns(taskID: UUID, threadID: String) {
        clients.codex.contextlessTurnRecorders[threadID] = { [self] turnID, entries in
            nonisolated(unsafe) let entries = entries
            Task { @MainActor in await self.recordCodexGoalTurn(taskID: taskID, threadID: threadID, turnID: turnID, entries: entries) }
        }
    }

    /// The index of the turn message a compaction row follows: the message it was recorded after,
    /// or, for a row recorded without one, the last message written before its compaction finished.
    /// Nil when neither is known, so the row stays after the turn's messages.
    static func compactionAnchor(_ activity: ConversationActivity, in messages: [ConversationMessage], recordedAt: Date?) -> Int? {
        if let afterMessageID = activity.afterMessageID,
           let index = messages.firstIndex(where: { $0.id == afterMessageID }) {
            return index
        }
        guard let recordedAt else { return nil }
        return messages.lastIndex { $0.createdAt.map { $0 <= recordedAt } == true }
    }

    /// The dividers `compose` draws, from turn outlines alone: one wherever the provider
    /// changes, after the last message of the turns before that segment.
    static func providerBoundaries(
        segments: [ConversationTranscript.Segment], turns: [ConversationTranscriptStore.Outline.Turn]
    ) -> [ConversationProviderBoundary] {
        var lastMessageBefore: [String: String] = [:]
        var lastMessageID: String?
        var turnIndex = 0
        for segment in segments {
            lastMessageBefore[segment.id] = lastMessageID
            while turnIndex < turns.count, turns[turnIndex].segmentID == segment.id {
                lastMessageID = turns[turnIndex].messageIDs.last ?? lastMessageID
                turnIndex += 1
            }
        }
        return segments.indices.dropFirst().filter { segments[$0].provider != segments[$0 - 1].provider }.map { index in
            ConversationProviderBoundary(
                id: "provider-boundary-\(segments[index].id)",
                provider: segments[index].provider,
                afterMessageID: lastMessageBefore[segments[index].id]
            )
        }
    }

    /// Orders every visible element by provider segment, then by its position
    /// within that segment's turns, and inserts a divider wherever the
    /// provider changes.
    static func compose(transcript: ConversationTranscript) -> ConversationHistory {
        enum Element {
            case message(ConversationMessage)
            case compaction(ConversationActivity)
        }
        var elements: [(segment: Int, order: Int, tieBreak: Int, element: Element)] = []
        let segments = transcript.segments
        let privateTranscriptReminderTurnIDs = Set(transcript.turns.compactMap { turn in
            turn.messages.contains { $0.role == .user && Self.isPrivateOutcomeReminderPrompt($0.text) } ? turn.id : nil
        })
        let compactionRecordedAt = Dictionary(
            (transcript.contextCompactions ?? []).map { ($0.id, $0.recordedAt) }, uniquingKeysWith: { first, _ in first }
        )
        var localOrder = 0
        for turn in transcript.turns {
            if privateTranscriptReminderTurnIDs.contains(turn.id) { continue }
            let segment = transcript.segmentIndex(of: turn.segmentID) ?? segments.count
            var messagePositions: [(order: Int, tieBreak: Int)] = []
            for message in turn.messages {
                let position = (message.timelineOrder ?? localOrder, 0)
                elements.append((segment, position.0, position.1, .message(message)))
                messagePositions.append(position)
                localOrder += 1
            }
            var compactionsAfterMessage: [Int: Int] = [:]
            for activity in turn.activities {
                if activity.isContextCompaction {
                    if activity.timelineOrder == nil,
                       let anchor = Self.compactionAnchor(activity, in: turn.messages, recordedAt: compactionRecordedAt[activity.id]) {
                        // A long turn can compact several times; each row stays between the messages
                        // it came between instead of every row stacking after the turn's last message.
                        let count = compactionsAfterMessage[anchor, default: 0] + 1
                        compactionsAfterMessage[anchor] = count
                        let position = messagePositions[anchor]
                        elements.append((segment, position.order, position.tieBreak + count, .compaction(activity)))
                    } else {
                        elements.append((segment, activity.timelineOrder ?? localOrder, 0, .compaction(activity)))
                    }
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

        // Activity details follow the latest turn the user started. Status nudges Playhouse
        // sent after it are shown as messages, but only the work they did joins its activities.
        let visibleTurns = transcript.turns.filter { !privateTranscriptReminderTurnIDs.contains($0.id) }
        let latestTurnIndex = visibleTurns.lastIndex { turn in
            !turn.messages.contains { $0.role == .user && PrivateOutcomeNudgeMarker.matches($0.text) }
        } ?? visibleTurns.endIndex - 1
        let latestTurn = latestTurnIndex >= 0 ? visibleTurns[latestTurnIndex] : nil
        let nudgeWork = visibleTurns.suffix(from: min(latestTurnIndex + 1, visibleTurns.endIndex))
            .flatMap { $0.activities.filter { $0.isSubagent || $0.isTimelineToolCall } }
        let subagents = visibleTurns.enumerated().filter { $0.offset < latestTurnIndex }.flatMap { $0.element.activities.filter(\.isSubagent) }
        // Compactions come from `compactions`, placed among the messages; the latest
        // turn's own copies would draw each one a second time.
        let activities = subagents + (latestTurn?.activities ?? []).filter { !$0.isContextCompaction }
            + nudgeWork + compactions
        // Every turn's tool calls, each placed after the message it followed.
        let timelineActivities = ConversationActivity.visibleTimelineActivities(
            visibleTurns.flatMap(\.activities),
            visibleMessageIDs: Set(messages.map(\.id)),
            excludedTurnIDs: privateTranscriptReminderTurnIDs
        )
        var history = ConversationHistory(
            messages: messages,
            activities: activities,
            diff: transcript.latestDiff,
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
        // Both providers' subagents are stored; the turn's segment tells which ran it.
        let transcript = try transcripts.read(taskID, turns: .all, includeImages: false)
        let claudeSegmentIDs = Set(transcript.segments.filter { $0.provider == .claude }.map(\.id))
        let isClaudeSubagent = transcript.turns.contains { turn in
            claudeSegmentIDs.contains(turn.segmentID) && turn.activities.contains { $0.childThreadID == childID }
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

    func searchArchive(query: String) async throws -> [BoardTaskRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Archive search query can't be blank.")
        }
        let completed = try tasks.list(status: .done)
        let titleMatches = completed.filter { $0.title.localizedCaseInsensitiveContains(normalizedQuery) }
        let titleIDs = Set(titleMatches.map(\.id))
        // Every provider's turns live in Playhouse's transcript store.
        let store = try transcripts
        let needle = normalizedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var conversationIDs = Set<UUID>()
        for task in completed where !titleIDs.contains(task.id) {
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
}
