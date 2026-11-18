import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func claudeSessionCacheState(sessionID: String) -> ClaudeSessionCacheState? {
        guard let file = ClaudeSessionUsageReader.sessionFile(sessionID: sessionID, configDirectory: clients.claude.configDirectory) else { return nil }
        return ClaudeSessionCacheState.read(file: file)
    }

    func codexCompactionState(taskID: UUID, threadID: String) -> ContextCompactionSessionState? {
        guard let task = try? tasks.conversationSubject(taskID),
              let snapshot = task.callUsageSnapshots["codex:\(threadID)"],
              snapshot.main.calls > 0 else { return nil }
        let transcript = (try? transcripts.readState(taskID)) ?? ConversationTranscript()
        let latestCodexSegment = transcript.segments.last(where: { $0.provider == .codex })
        let model = latestCodexSegment?.codexTurnIDs.last.flatMap { latestCodexSegment?.codexTurnModelIDs[$0] }
        let lastCompaction = transcript.contextCompactions?.last(where: { $0.provider == ConversationProvider.codex.rawValue })
        return ContextCompactionSessionState(
            lastCallAt: snapshot.updatedAt,
            contextTokens: snapshot.main.lastContextTokens,
            model: model,
            lastCompaction: nil,
            compactedSinceLastCall: lastCompaction?.lastCallAt == snapshot.updatedAt
        )
    }

    /// Run Playhouse's `/compact` as its own transcript turn. It deliberately
    /// doesn't activate or settle task outcome state: compaction is maintenance,
    /// not a user-visible task turn.
    func runAutomaticCompaction(
        taskID: UUID, threadID: String, trigger: ContextCompactionTrigger,
        state: ClaudeSessionCacheState, modelID: String, effort: ConversationEffort,
        segmentID: String, workspace: ConversationWorkspaceContext,
        developerInstructions: String?, now: Date, onUpdate: @escaping (ConversationUpdate) -> Void
    ) async -> Bool {
        let turnID = UUID().uuidString.lowercased()
        var usageReports: [ConversationTurnUsageReport] = []
        func persistUsage() async {
            for report in usageReports {
                let attributed = ConversationTurnUsageReport(
                    turnID: turnID, usage: report.usage,
                    toolLabels: report.toolLabels, liveCall: report.liveCall
                )
                do {
                    try await tasks.recordTokenUsage(taskID: taskID, provider: .claude, sourceID: threadID, report: attributed)
                } catch {
                    PlayhouseDiagnostics.record("task.token_usage.record_failed", fields: ["taskID": taskID.uuidString])
                }
            }
            usageReports.removeAll()
        }
        do {
            try transcripts.mutate(taskID, turns: .none) { transcript in
                transcript.turns.append(.init(id: turnID, segmentID: segmentID))
            }
            let callbacks = ConversationTurnCallbacks(
                onDelta: { _ in }, onFinalMessage: { _ in },
                onActivity: { activity in self.recordTurnActivity(taskID: taskID, turnID: turnID, activity) },
                onDiff: { _ in }, onHistory: { _ in }, onActionRequest: {},
                onUserInput: { _ in }, onSteerMessage: { _, _ in }, onProgressMessage: { _ in }, onMessageTimestamp: { _, _ in },
                onTurnStarted: { _ in }, onTokenUsage: { usageReports.append($0) }
            )
            try await clients.claude.compactSession(
                trigger: trigger, threadID: threadID, modelID: modelID, effort: effort,
                workspace: workspace, developerInstructions: developerInstructions, callbacks: callbacks
            )
            await persistUsage()
            let after = claudeSessionCacheState(sessionID: threadID)
            let event = ContextCompactionEvent(
                id: UUID().uuidString.lowercased(), recordedAt: now, trigger: trigger,
                preTokens: state.contextTokens, postTokens: after?.contextTokens,
                idleSeconds: state.lastCallAt.map { now.timeIntervalSince($0) }, model: modelID,
                lastCallAt: state.lastCallAt, succeeded: after?.compactedSinceLastCall == true
            )
            try transcripts.mutate(taskID, turns: .none) { $0.contextCompactions = ($0.contextCompactions ?? []) + [event] }
            PlayhouseDiagnostics.record("conversation.compaction.completed", fields: [
                "taskID": taskID.uuidString, "threadID": threadID, "trigger": trigger.rawValue,
                "preTokens": String(event.preTokens ?? 0), "postTokens": String(event.postTokens ?? 0),
                "succeeded": String(event.succeeded)
            ])
            onUpdate(ConversationUpdate(type: "activity"))
            return event.succeeded
        } catch {
            await persistUsage()
            let failedEvent = ContextCompactionEvent(
                id: turnID, recordedAt: now, trigger: trigger,
                preTokens: state.contextTokens, postTokens: nil,
                idleSeconds: state.lastCallAt.map { now.timeIntervalSince($0) }, model: modelID,
                lastCallAt: state.lastCallAt, succeeded: false
            )
            try? transcripts.mutate(taskID, turns: .none) { transcript in
                if !(transcript.contextCompactions ?? []).contains(where: { $0.id == failedEvent.id }) {
                    transcript.contextCompactions = (transcript.contextCompactions ?? []) + [failedEvent]
                }
            }
            PlayhouseDiagnostics.record("conversation.compaction.failed", fields: [
                "taskID": taskID.uuidString, "threadID": threadID, "trigger": trigger.rawValue,
                "preTokens": String(state.contextTokens), "error": error.localizedDescription
            ])
            return false
        }
    }

    /// Codex exposes a manual app-server compaction request but no prompt-cache
    /// expiry or post-compaction usage metadata. Its threshold/model-switch
    /// compaction therefore records the known pre-size and provider activity.
    func runCodexAutomaticCompaction(
        taskID: UUID, threadID: String, trigger: ContextCompactionTrigger,
        state: ContextCompactionSessionState, modelID: String, segmentID: String,
        workspace: ConversationWorkspaceContext, developerInstructions: String?, now: Date,
        onUpdate: @escaping (ConversationUpdate) -> Void
    ) async -> Bool {
        let turnID = UUID().uuidString.lowercased()
        do {
            try await clients.codex.compactThread(
                id: threadID, workspace: workspace, modelID: modelID,
                developerInstructions: developerInstructions
            )
            let event = ContextCompactionEvent(
                id: UUID().uuidString.lowercased(), recordedAt: now, trigger: trigger,
                preTokens: state.contextTokens, postTokens: nil,
                idleSeconds: state.lastCallAt.map { now.timeIntervalSince($0) }, model: modelID,
                lastCallAt: state.lastCallAt, succeeded: true, provider: ConversationProvider.codex.rawValue
            )
            // The row is its own turn, so it lands after every turn recorded before it.
            let activity = ConversationActivity(
                id: "playhouse-codex-compaction-\(event.id)",
                title: "Context compacted automatically",
                detail: ContextCompactionDetails(trigger: trigger, preTokens: state.contextTokens, postTokens: nil).summary,
                status: "completed", isContextCompaction: true,
                timelineOrder: nil,
                compaction: ContextCompactionDetails(trigger: trigger, preTokens: state.contextTokens, postTokens: nil)
            )
            try transcripts.mutate(taskID, turns: .none) { transcript in
                transcript.turns.append(.init(id: turnID, segmentID: segmentID, activities: [activity]))
                transcript.contextCompactions = (transcript.contextCompactions ?? []) + [event]
            }
            PlayhouseDiagnostics.record("conversation.compaction.completed", fields: [
                "taskID": taskID.uuidString, "threadID": threadID, "provider": ConversationProvider.codex.rawValue,
                "trigger": trigger.rawValue, "preTokens": String(event.preTokens ?? 0),
                "postTokens": "unknown", "succeeded": "true"
            ])
            onUpdate(ConversationUpdate(type: "activity"))
            return true
        } catch {
            let event = ContextCompactionEvent(
                id: UUID().uuidString.lowercased(), recordedAt: now, trigger: trigger,
                preTokens: state.contextTokens, postTokens: nil,
                idleSeconds: state.lastCallAt.map { now.timeIntervalSince($0) }, model: modelID,
                lastCallAt: state.lastCallAt, succeeded: false, provider: ConversationProvider.codex.rawValue
            )
            let activity = ConversationActivity(
                id: "playhouse-codex-compaction-\(event.id)", title: "Automatic context compaction failed",
                detail: ContextCompactionDetails(trigger: trigger, preTokens: state.contextTokens, postTokens: nil).summary,
                status: "failed", isContextCompaction: true,
                timelineOrder: nil,
                compaction: ContextCompactionDetails(trigger: trigger, preTokens: state.contextTokens, postTokens: nil)
            )
            try? transcripts.mutate(taskID, turns: .none) { transcript in
                transcript.turns.append(.init(id: turnID, segmentID: segmentID, activities: [activity]))
                transcript.contextCompactions = (transcript.contextCompactions ?? []) + [event]
            }
            PlayhouseDiagnostics.record("conversation.compaction.failed", fields: [
                "taskID": taskID.uuidString, "threadID": threadID, "provider": ConversationProvider.codex.rawValue,
                "trigger": trigger.rawValue, "preTokens": String(state.contextTokens),
                "error": error.localizedDescription
            ])
            onUpdate(ConversationUpdate(type: "activity"))
            return false
        }
    }

    /// Called by the existing scheduler tick in both the daemon and LaunchAgent.
    /// Each candidate must still be idle when it acquires the normal turn lock.
    func idleCompactionTick(now testTime: Date? = nil) async -> [String] {
        guard settingsManager.contextCompaction.enabled else { return [] }
        var compacted: [String] = []
        for record in (try? tasks.list()) ?? [] {
            let now = testTime ?? .now
            guard record.conversationProvider == ConversationProvider.claude.rawValue,
                  let sessionID = record.claudeSessionID else { continue }
            let transcript: ConversationTranscript
            do { transcript = try transcripts.readState(record.id) } catch { continue }
            let state = claudeSessionCacheState(sessionID: sessionID)
            let pendingInput = transcript.pendingUserInputRequest != nil
            let queued = (try? tasks.queuedConversationMessages(taskID: record.id).contains { $0.state == .queued }) ?? false
            let reserved = (try? tasks.hasConversationTurnReservation(record.id)) ?? true
            let active = ClaudeCodeClient.hasActiveRunner(sessionID: sessionID)
            let decision = ContextCompactionPolicy.idleDecision(
                status: record.status, isBusy: pendingInput || queued || reserved || active,
                state: state,
                lastAttemptedCallAt: transcript.contextCompactions?.last?.lastCallAt,
                now: now, settings: settingsManager.contextCompaction
            )
            guard decision == .compact, let segment = transcript.segments.last(where: { $0.provider == .claude }) else { continue }
            do {
                let acquired = try await tasks.withConversationTurnReservationIfFree(record.id) {
                    let now = testTime ?? .now
                    guard let state = self.claudeSessionCacheState(sessionID: sessionID),
                          let current = try? self.transcripts.readState(record.id),
                          let subject = try? self.tasks.conversationSubject(record.id),
                          ContextCompactionPolicy.idleDecision(
                            status: subject.status.rawValue, isBusy: false, state: state,
                            lastAttemptedCallAt: current.contextCompactions?.last?.lastCallAt,
                            now: now, settings: self.settingsManager.contextCompaction
                          ) == .compact else { return false }
                    guard !ClaudeCodeClient.hasActiveRunner(sessionID: sessionID),
                          (try? self.tasks.queuedConversationMessages(taskID: record.id).contains { $0.state == .queued }) != true,
                          (try? self.transcripts.readState(record.id).pendingUserInputRequest) == nil else { return false }
                    ConversationTurnEvents.begin(record.id)
                    defer {
                        ConversationTurnEvents.end(record.id)
                        Self.bumpVisibleRevision(record.id)
                    }
                    let publishUpdate: (ConversationUpdate) -> Void = { update in
                        if Self.historyVisibleUpdateTypes.contains(update.type) { Self.bumpVisibleRevision(record.id) }
                        ConversationTurnEvents.publish(record.id, update)
                    }
                    let roots = Self.launchRoots(subject).compactMap(WorkspaceSettings.validDirectoryURL(for:))
                    let workspace = try self.launchWorkspace(for: subject, roots: roots)
                    let instructions = TaskThreadDeveloperInstructions.make(
                        taskID: record.id, repositories: subject.repositoryWorktrees,
                        contextFolders: subject.contextFolderPaths, repositoryRootPath: roots.first?.path,
                        isStandaloneChat: false, isArchived: subject.status == .done,
                        pluginPlacement: (subject as? BoardTask)?.pluginPlacement,
                        pluginsDirectory: self.clients.skills?.pluginsDirectory
                    )
                    return await self.runAutomaticCompaction(
                        taskID: record.id, threadID: sessionID, trigger: .warmIdle, state: state,
                        modelID: state.model ?? "default", effort: ConversationEffort(rawValue: subject.conversationEffort) ?? .medium,
                        segmentID: segment.id, workspace: workspace, developerInstructions: instructions,
                        now: now, onUpdate: publishUpdate
                    )
                }
                if acquired == true { compacted.append(record.id.uuidString) }
            } catch {
                PlayhouseDiagnostics.record("conversation.compaction.idle_failed", fields: ["taskID": record.id.uuidString])
            }
        }
        return compacted
    }
}
