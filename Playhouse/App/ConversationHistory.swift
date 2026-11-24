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
        // The turn of the first message after a page, which runs on past it when the page's last message shares it.
        var turnIDAfterPage: String?
        if readsForward {
            history = try composedHistory(taskID: taskID)
            let start = try forwardWindowStart(taskID: taskID, in: history.messages, after: afterMessageID, chatPageID: chatPageID)
            let end = messageLimit.map { min(history.messages.count, start + $0) } ?? history.messages.count
            turnIDAfterPage = end < history.messages.count ? history.messages[end].turnID : nil
            history.earlierMessageCount = start
            history.laterMessageCount = history.messages.count - end
            history.messages = Array(history.messages[start..<end])
            history.timelineActivities = ConversationActivity.visibleTimelineActivities(
                history.timelineActivities, visibleMessageIDs: Set(history.messages.map(\.id)), excludedTurnIDs: []
            )
            source = "composed-forward"
        } else if let messageLimit,
           let page = try storedTranscriptPage(taskID: taskID, messageLimit: messageLimit, beforeMessageID: beforeMessageID) {
            (history, turnIDAfterPage) = page
            source = "stored-page"
        } else {
            history = try composedHistory(taskID: taskID)
            if messageLimit != nil || beforeMessageID != nil {
                let end = try Self.pageEnd(of: history.messages, before: beforeMessageID)
                let start = messageLimit.map { max(0, end - $0) } ?? 0
                turnIDAfterPage = end < history.messages.count ? history.messages[end].turnID : nil
                history.earlierMessageCount = start
                history.laterMessageCount = history.messages.count - end
                history.messages = Array(history.messages[start..<end])
                history.timelineActivities = ConversationActivity.visibleTimelineActivities(
                    history.timelineActivities, visibleMessageIDs: Set(history.messages.map(\.id)), excludedTurnIDs: []
                )
            }
        }
        history.messages = Self.attachingTurnTokenUsage(
            history.messages, rows: (try? transcripts.readState(taskID))?.tokenUsage ?? [], turnIDAfterPage: turnIDAfterPage
        )
        // Durations Playhouse measured are also saved with the task when the turn settles; they
        // fill in activities recorded before an update kept its duration (older transcripts).
        let savedDurations = tasks.conversationActivityDurations(taskID: taskID)
        if !savedDurations.isEmpty {
            history.activities = Self.fillingDurations(history.activities, from: savedDurations)
            history.timelineActivities = Self.fillingDurations(history.timelineActivities, from: savedDurations)
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
        let pageByTurnID = try tasks.standaloneChatManager(for: taskID).pageAssignmentsByTurnID()
        guard let index = messages.firstIndex(where: { $0.turnID.flatMap { pageByTurnID[$0]?.id } == chatPageID }) else {
            throw BridgeCommandError(code: "not_found", message: "That chat page has no messages in this conversation's history.")
        }
        return index
    }

    /// A page read straight from stored rows, loading only the turns it covers.
    /// It applies wherever composing the whole transcript would order these
    /// messages by stored position alone: no positioned elements and turns whose
    /// segments never move backward. Otherwise returns nil and the caller
    /// composes the whole history and slices it. Also returns the turn of the first
    /// message after the page, nil when the page runs to the newest message.
    func storedTranscriptPage(
        taskID: UUID, messageLimit: Int, beforeMessageID: String?
    ) throws -> (history: ConversationHistory, turnIDAfterPage: String?)? {
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
        var turnIDAfterPage: String?
        for turn in visibleTurns {
            let range = offset..<(offset + turn.messageIDs.count)
            if range.overlaps(start..<end) {
                if covered.isEmpty { firstCoveredOffset = offset }
                covered.append(turn.id)
            }
            if range.contains(end) { turnIDAfterPage = turn.id }
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
        return (ConversationHistory(
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
        ), turnIDAfterPage)
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
            pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory,
            isOptimizedContext: task.conversationContextMode == .optimized
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
        var segmentsWithMessages: Set<String> = []
        var lastMessageID: String?
        var turnIndex = 0
        for segment in segments {
            lastMessageBefore[segment.id] = lastMessageID
            while turnIndex < turns.count, turns[turnIndex].segmentID == segment.id {
                if let last = turns[turnIndex].messageIDs.last {
                    lastMessageID = last
                    segmentsWithMessages.insert(segment.id)
                }
                turnIndex += 1
            }
        }
        return Self.dividers(segments: segments, showsMessages: { segmentsWithMessages.contains(segments[$0].id) }) { index in
            lastMessageBefore[segments[index].id]
        }
    }

    /// A divider wherever the provider changes between the segments that showed messages. A
    /// segment that showed none, such as a switch undone before anything was sent, draws no
    /// divider of its own, so it leaves no pair of dividers with nothing between them. The
    /// latest segment always counts: a switch still waiting for its first message shows.
    static func dividers(
        segments: [ConversationTranscript.Segment], showsMessages: (Int) -> Bool, afterMessageID: (Int) -> String?
    ) -> [ConversationProviderBoundary] {
        let shown = segments.indices.filter { $0 == segments.count - 1 || showsMessages($0) }
        return zip(shown, shown.dropFirst()).filter { segments[$0.0].provider != segments[$0.1].provider }.map { _, index in
            ConversationProviderBoundary(
                id: "provider-boundary-\(segments[index].id)",
                provider: segments[index].provider,
                afterMessageID: afterMessageID(index)
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
        let segmentsWithMessages = Set(elements.compactMap { item -> Int? in
            if case .message = item.element { return item.segment }
            return nil
        })
        let boundaries = Self.dividers(segments: segments, showsMessages: segmentsWithMessages.contains) { index in
            lastMessageBeforeSegment[index] ?? nil
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

    /// Marks each turn's last reply with what the turn cost, so the reply can show its
    /// turn's tokens: providers report usage once per turn, never per message. A turn that
    /// runs past the end of the page (`turnIDAfterPage`, the turn of the first message after
    /// it) has its last reply on a later page, so none of its messages here is marked.
    /// Activities without a duration of their own take the one saved for them, if any.
    static func fillingDurations(_ activities: [ConversationActivity], from saved: [String: Int]) -> [ConversationActivity] {
        activities.map { activity in
            guard activity.durationMs == nil, let durationMs = saved[activity.id] else { return activity }
            var activity = activity
            activity.durationMs = durationMs
            return activity
        }
    }

    static func attachingTurnTokenUsage(
        _ messages: [ConversationMessage], rows: [ConversationTranscript.TurnTokenUsage], turnIDAfterPage: String?
    ) -> [ConversationMessage] {
        let usageByTurn = Dictionary(rows.map { ($0.id, $0.usage) }, uniquingKeysWith: +)
        var lastReplyByTurn: [String: String] = [:]
        // A background agent's report is drawn as the agent's row, not as a reply.
        for message in messages where message.role == .assistant && message.phase != "subagent_report" {
            if let turnID = message.turnID { lastReplyByTurn[turnID] = message.id }
        }
        let unfinishedTurnID = turnIDAfterPage.flatMap { $0 == messages.last?.turnID ? $0 : nil }
        return messages.map { message in
            var message = message
            message.turnTokenUsage = message.turnID.flatMap { turnID in
                guard turnID != unfinishedTurnID, lastReplyByTurn[turnID] == message.id,
                      let usage = usageByTurn[turnID], !usage.isEmpty else { return nil }
                return usage
            }
            return message
        }
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
        // Claude Code streams only a subagent's launch and report to its parent;
        // its own work is in its sidechain file, read again on every call so a
        // running agent shows its latest work.
        let sessionIDs = [task.conversationID(for: .claude)].compactMap { $0 }
        let configDirectory = clients.claude.configDirectory
        let parsed = await Task.detached(priority: .userInitiated) {
            ClaudeSubagentTranscriptReader.agentFile(toolUseID: childID, sessionIDs: sessionIDs, configDirectory: configDirectory)
                .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
                .map(ClaudeSubagentTranscriptReader.parse)
        }.value
        let sidechain = parsed.map(ClaudeSubagentTranscriptReader.history)
        let report = ConversationMessage(id: "\(childID)-report", role: .assistant, text: activity.detail, phase: "final_answer", provider: .claude)
        guard var history = sidechain, !history.messages.isEmpty || !history.timelineActivities.isEmpty else {
            return ConversationHistory(messages: [report], activities: [], diff: nil)
        }
        // A finished agent's report is its last text; add it when the file ends before it.
        if !activity.isActive, !activity.detail.isEmpty {
            let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let last = history.messages.indices.last, history.messages[last].role == .assistant,
               trimmed(history.messages[last].text) == trimmed(activity.detail) {
                history.messages[last].phase = "final_answer"
            } else {
                history.messages.append(report)
            }
        }
        return history
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

/// A board task's conversation numbered by position, the one numbering the optimized context
/// seed, `conversation outline` and `conversation read` share. Messages (the user's, steers,
/// the agent's commentary and final answers, subagent reports, prompts Playhouse sent) take
/// whole numbers from 1 in transcript order; the tool calls after message 12 are 12.1, 12.2
/// and so on, so a whole number is always a message and a decimal always a tool call. The
/// transcript only grows, so a position keeps naming the same entry.
struct ConversationTimeline {
    struct Position: Comparable, Hashable, CustomStringConvertible {
        let message: Int
        /// Zero for the message itself; the tool call's ordinal after it otherwise.
        let tool: Int

        init(message: Int, tool: Int = 0) {
            self.message = message
            self.tool = tool
        }

        /// `12` or `12.3`; nil for anything else.
        init?(_ text: String) {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let message = Int(parts[0]), message >= 1 else { return nil }
            let tool = parts.count == 2 ? Int(parts[1]) : 0
            guard let tool, tool >= 0, parts.count == 1 || tool >= 1 else { return nil }
            self.init(message: message, tool: tool)
        }

        var description: String { tool == 0 ? "\(message)" : "\(message).\(tool)" }
        var isToolCall: Bool { tool > 0 }

        static func < (lhs: Position, rhs: Position) -> Bool {
            (lhs.message, lhs.tool) < (rhs.message, rhs.tool)
        }
    }

    enum Kind: String, Codable, CaseIterable {
        /// A message the user wrote to start a turn.
        case user
        /// A message the user added to a running turn.
        case steer
        /// The agent's text before its answer.
        case agent
        case final
        /// The final answer of a turn sent in Plan mode.
        case plan
        case subagent
        /// A prompt Playhouse or the provider's runtime sent on its own.
        case playhouse
        case tool
    }

    struct Entry: Codable, Equatable {
        let position: String
        let kind: Kind
        let turn: Int
        let id: String
        let text: String
        var createdAt: Date?
        var title: String?
        var status: String?
        var input: String?
        var output: String?
    }

    struct Turn {
        let number: Int
        let startedByUser: Bool
        let isPlan: Bool
        let startedFreshSession: Bool
        var positions: [Position] = []
        var kinds: [Kind] = []
    }

    private(set) var entries: [(position: Position, entry: Entry)] = []
    private(set) var turns: [Turn] = []

    var messageCount: Int { entries.filter { !$0.position.isToolCall }.count }
    var toolCallCount: Int { entries.filter { $0.position.isToolCall }.count }

    init(transcript: ConversationTranscript) {
        let planTurnIDs = Set(transcript.planTurnIDs ?? [])
        let freshTurnIDs = Set(transcript.freshSessionTurnIDs ?? [])
        var number = 0
        for turn in transcript.turns {
            // Turns written before nudges were shown hold only a placeholder; history hides them
            // with the same check, so positions follow the visible conversation.
            if turn.messages.contains(where: { $0.role == .user && ConversationManager.isPrivateOutcomeReminderPrompt($0.text) }) { continue }
            guard !turn.messages.isEmpty else { continue }
            let firstUser = turn.messages.first { $0.role == .user }
            let startedByUser = firstUser.map { !Self.isPlayhouseSent($0) } ?? false
            let isPlan = planTurnIDs.contains(turn.id)
            let planAnswerID = isPlan ? turn.messages.last { $0.role == .assistant && $0.phase == "final_answer" }?.id : nil
            var summary = Turn(
                number: turns.count + 1, startedByUser: startedByUser,
                isPlan: isPlan, startedFreshSession: freshTurnIDs.contains(turn.id)
            )
            var messageNumbers: [String: Int] = [:]
            var dated: [(date: Date, number: Int)] = []
            var seenUser = false
            for message in turn.messages {
                number += 1
                messageNumbers[message.id] = number
                if let date = message.createdAt { dated.append((date, number)) }
                let kind: Kind
                switch message.role {
                case .user:
                    kind = Self.isPlayhouseSent(message) ? .playhouse : (seenUser ? .steer : .user)
                    seenUser = true
                case .assistant:
                    switch message.phase {
                    case "final_answer": kind = message.id == planAnswerID ? .plan : .final
                    case "subagent_report": kind = .subagent
                    default: kind = .agent
                    }
                }
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let position = Position(message: number)
                entries.append((position, Entry(
                    position: position.description, kind: kind, turn: summary.number, id: message.id,
                    text: text.isEmpty && !message.imageDataURLs.isEmpty ? "[image]" : text, createdAt: message.createdAt
                )))
                summary.positions.append(position)
                summary.kinds.append(kind)
            }
            let firstNumber = number - turn.messages.count + 1
            var toolCounts: [Int: Int] = [:]
            var toolEntries: [(position: Position, entry: Entry)] = []
            var previousParent: Int?
            for activity in turn.activities where !activity.isContextCompaction {
                // A call sits under the message it followed. A call recorded without that falls
                // back to the latest message written before it started, and a call with neither
                // follows the call before it, since a turn's calls are stored in order.
                let parent = activity.afterMessageID.flatMap { messageNumbers[$0] }
                    ?? activity.startedAt.flatMap { start in dated.last { $0.date <= start }?.number }
                    ?? previousParent
                    ?? firstNumber
                previousParent = parent
                let ordinal = toolCounts[parent, default: 0] + 1
                toolCounts[parent] = ordinal
                let position = Position(message: parent, tool: ordinal)
                toolEntries.append((position, Entry(
                    position: position.description, kind: .tool, turn: summary.number, id: activity.id,
                    text: activity.summary ?? activity.detail, createdAt: activity.startedAt,
                    title: activity.title, status: activity.status,
                    input: activity.input.map { Self.shortened($0, limit: 4_000) },
                    output: activity.output.map { Self.shortened($0, limit: 4_000) }
                )))
            }
            for item in toolEntries.sorted(by: { $0.position < $1.position }) {
                summary.positions.append(item.position)
                summary.kinds.append(.tool)
            }
            entries.append(contentsOf: toolEntries)
            turns.append(summary)
        }
        entries.sort { $0.position < $1.position }
    }

    private static func isPlayhouseSent(_ message: ConversationMessage) -> Bool {
        message.isPlayhouseSent || PrivateOutcomeNudgeMarker.matches(message.text)
            || PrivatePromptPlaceholder.matches(message.text) || ProviderAutomaticNotice.matches(message.text)
    }

    static func shortened(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + " […]" : text
    }

    func entry(at position: Position) -> Entry? {
        entries.first { $0.position == position }?.entry
    }

    var latestPlan: Entry? { entries.last { $0.entry.kind == .plan }?.entry }
    var latestFinalAnswer: Entry? { entries.last { $0.entry.kind == .final || $0.entry.kind == .plan }?.entry }

    var outline: ConversationOutline {
        ConversationOutline(
            totalMessages: messageCount,
            totalToolCalls: toolCallCount,
            totalTurns: turns.count,
            latestPlanPosition: latestPlan?.position,
            latestFinalAnswerPosition: latestFinalAnswer?.position,
            turns: turns.map { turn in
                let messages = zip(turn.positions, turn.kinds).filter { !$0.0.isToolCall }
                return ConversationOutline.Turn(
                    turn: turn.number,
                    startedBy: turn.startedByUser ? "user" : "playhouse",
                    firstPosition: messages.first?.0.description ?? "",
                    lastPosition: messages.last?.0.description ?? "",
                    userPositions: messages.filter { $0.1 == .user || $0.1 == .playhouse }.map(\.0.description),
                    steerPositions: messages.filter { $0.1 == .steer }.map(\.0.description),
                    agentMessages: messages.filter { [.agent, .subagent].contains($0.1) }.count,
                    toolCalls: turn.kinds.filter { $0 == .tool }.count,
                    finalAnswerPositions: messages.filter { $0.1 == .final || $0.1 == .plan }.map(\.0.description),
                    plan: turn.isPlan,
                    freshSession: turn.startedFreshSession
                )
            }
        )
    }
}

/// `conversation outline`: the positional map an optimized follow-up's seed also carries.
struct ConversationOutline: Codable, Equatable {
    struct Turn: Codable, Equatable {
        let turn: Int
        /// user, or playhouse for a turn Playhouse sent on its own (an outcome nudge).
        let startedBy: String
        let firstPosition: String
        let lastPosition: String
        let userPositions: [String]
        let steerPositions: [String]
        let agentMessages: Int
        let toolCalls: Int
        let finalAnswerPositions: [String]
        let plan: Bool
        let freshSession: Bool
    }

    let totalMessages: Int
    let totalToolCalls: Int
    let totalTurns: Int
    let latestPlanPosition: String?
    let latestFinalAnswerPosition: String?
    let turns: [Turn]
}

/// `conversation read`: the requested entries, with the totals that bound positions.
struct ConversationReadResult: Codable, Equatable {
    let totalMessages: Int
    let totalToolCalls: Int
    let entries: [ConversationTimeline.Entry]
}

extension ConversationManager {
    func timeline(taskID: UUID) throws -> ConversationTimeline {
        _ = try tasks.conversationSubject(taskID)
        return ConversationTimeline(transcript: try transcripts.read(taskID, turns: .all, includeImages: false))
    }

    func outline(taskID: UUID) throws -> ConversationOutline {
        try timeline(taskID: taskID).outline
    }

    /// Entries by position: the listed `positions`, or the range `from`...`to` (each end
    /// optional), narrowed to `kinds`. A range holds messages only unless `includesTools`
    /// or `kinds` asks for tool calls; listed positions are returned as named.
    func read(
        taskID: UUID,
        positions: [String],
        from: String?,
        to: String?,
        kinds: [String],
        includesTools: Bool
    ) throws -> ConversationReadResult {
        func parse(_ text: String) throws -> ConversationTimeline.Position {
            guard let position = ConversationTimeline.Position(text) else {
                throw BridgeCommandError(
                    code: "invalid_argument",
                    message: "\"\(text)\" is not a conversation position. Use a message number such as 12, or a tool call such as 12.3."
                )
            }
            return position
        }
        let kindFilter = try Set(kinds.map { name -> ConversationTimeline.Kind in
            guard let kind = ConversationTimeline.Kind(rawValue: name) else {
                throw BridgeCommandError(
                    code: "invalid_argument",
                    message: "Unknown entry kind \"\(name)\". Use: \(ConversationTimeline.Kind.allCases.map(\.rawValue).joined(separator: ", "))."
                )
            }
            return kind
        })
        guard positions.isEmpty || (from == nil && to == nil) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Read listed positions with --at, or a range with --from and --to; choose one.")
        }
        let timeline = try timeline(taskID: taskID)
        let bounds = "The conversation has \(timeline.messageCount) messages and \(timeline.toolCallCount) tool calls."
        var selected: [ConversationTimeline.Entry]
        if !positions.isEmpty {
            selected = try positions.map { text in
                let position = try parse(text)
                guard let entry = timeline.entry(at: position) else {
                    throw BridgeCommandError(code: "not_found", message: "Nothing is at position \(position). \(bounds)")
                }
                return entry
            }
        } else {
            let lower = try from.map(parse) ?? ConversationTimeline.Position(message: 1)
            let explicitUpper = try to.map(parse)
            if let explicitUpper, lower > explicitUpper {
                throw BridgeCommandError(code: "invalid_argument", message: "--from \(lower) comes after --to \(explicitUpper).")
            }
            guard timeline.messageCount == 0 || lower.message <= timeline.messageCount else {
                throw BridgeCommandError(code: "not_found", message: "Position \(lower) is past the end of the conversation. \(bounds)")
            }
            // Without --to, the range runs through the last message and the calls after it.
            let upper = explicitUpper ?? ConversationTimeline.Position(message: max(timeline.messageCount, 1), tool: Int.max)
            let tools = includesTools || kindFilter.contains(.tool)
            selected = timeline.entries
                .filter { $0.position >= lower && $0.position <= upper && (tools || !$0.position.isToolCall) }
                .map(\.entry)
        }
        if !kindFilter.isEmpty {
            selected = selected.filter { kindFilter.contains($0.kind) }
        }
        return ConversationReadResult(totalMessages: timeline.messageCount, totalToolCalls: timeline.toolCallCount, entries: selected)
    }
}

extension ConversationHandoff {
    /// The user's messages are cut to this many characters, newest kept whole first.
    static let optimizedUserMessagesCharacterLimit = 24_000
    static let optimizedFinalAnswerCharacterLimit = 2_400
    /// The outline lists at most this many of the newest turns, one line each.
    static let optimizedOutlineTurnLimit = 200

    /// The seed of an optimized follow-up's fresh session: the conversation's positional
    /// outline, every message the user wrote and the latest final answer (never a plan),
    /// with how to read the rest. Nil for a conversation with nothing in it yet.
    static func optimizedFollowUpContext(taskID: UUID, timeline: ConversationTimeline) -> String? {
        guard !timeline.turns.isEmpty else { return nil }
        let outline = timeline.outline
        var sections = ["""
        Playhouse optimized context, not part of the user's message. This follow-up runs in a fresh session: none of this conversation's earlier turns are loaded, only what is below. Positions number the whole conversation: a whole number is a message, and a decimal such as 12.3 is the third tool call after message 12, so the gap between two user messages shows how much the agent did in between. Read anything else of task \(taskID.uuidString) with conversation read, which reads entries by position or range, every turn's final answer without the work before it, or the tool calls too; run help conversation --for task for its options.
        """]

        func count(_ value: Int, _ noun: String) -> String { "\(value) \(noun)\(value == 1 ? "" : "s")" }
        var lines = ["Conversation outline: \(count(outline.totalMessages, "message")) and \(count(outline.totalToolCalls, "tool call")) in \(count(outline.totalTurns, "turn"))."]
        let shownTurns = outline.turns.suffix(optimizedOutlineTurnLimit)
        if shownTurns.count < outline.turns.count {
            lines.append("- Turns 1-\(outline.turns.count - shownTurns.count): run conversation outline for these.")
        }
        for turn in shownTurns {
            var parts: [String] = []
            let opener = turn.startedBy == "user" ? "user" : "Playhouse"
            parts.append("\(opener) @\(turn.userPositions.first ?? turn.firstPosition)")
            if !turn.steerPositions.isEmpty {
                parts.append("steers @" + turn.steerPositions.joined(separator: ", @"))
            }
            parts.append("\(turn.agentMessages) agent \(turn.agentMessages == 1 ? "message" : "messages"), \(turn.toolCalls) tool \(turn.toolCalls == 1 ? "call" : "calls")")
            if let answer = turn.finalAnswerPositions.last {
                parts.append("\(turn.plan ? "plan" : "final answer") @\(answer)")
            }
            parts.append("ends @\(turn.lastPosition)")
            lines.append("- Turn \(turn.turn)\(turn.plan ? " (Plan mode)" : ""): " + parts.joined(separator: "; "))
        }
        sections.append(lines.joined(separator: "\n"))

        // The newest messages stay whole; older ones shrink once the budget runs out.
        let userEntries = timeline.entries.map(\.entry).filter { $0.kind == .user || $0.kind == .steer }
        var budget = optimizedUserMessagesCharacterLimit
        var userLines: [String] = []
        for entry in userEntries.reversed() {
            let label = "@\(entry.position)\(entry.kind == .steer ? " (steer)" : "")"
            if entry.text.count <= budget {
                budget -= entry.text.count
                userLines.append("\(label): \(entry.text)")
            } else {
                let kept = max(budget, 200)
                budget = max(budget - kept, 0)
                userLines.append("\(label): \(String(entry.text.prefix(kept))) […] (read @\(entry.position) for the full text)")
            }
        }
        if !userLines.isEmpty {
            sections.append((["The user's messages, oldest first:"] + userLines.reversed()).joined(separator: "\n\n"))
        }
        // A plan is not seeded: an old plan read as current instructions confuses the fresh
        // session. The outline still gives its position for conversation read.
        if let answer = timeline.entries.last(where: { $0.entry.kind == .final })?.entry {
            sections.append("The latest final answer (@\(answer.position)), shortened when long:\n\n" + shortenedWithReadHint(answer, limit: optimizedFinalAnswerCharacterLimit))
        }
        return """
        \(openTag)
        \(sections.joined(separator: "\n\n"))
        \(closeTag)
        """
    }

    private static func shortenedWithReadHint(_ entry: ConversationTimeline.Entry, limit: Int) -> String {
        entry.text.count > limit
            ? String(entry.text.prefix(limit)) + " […] (read @\(entry.position) for the rest)"
            : entry.text
    }
}
