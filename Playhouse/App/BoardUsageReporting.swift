import Foundation
import SwiftData

extension BoardTaskManager {
    func recordTokenUsage(
        taskID: UUID, provider: ConversationProvider, sourceID: String, report: ConversationTurnUsageReport
    ) async throws {
        if let call = report.liveCall {
            try await recordLiveCall(taskID: taskID, provider: provider, sourceID: sourceID, call: call)
            return
        }
        guard !report.usage.isEmpty else { return }
        if let turnID = report.turnID {
            try conversationTranscriptStore().mutate(taskID, turns: .none) { transcript in
                var rows = transcript.tokenUsage ?? []
                if let index = rows.firstIndex(where: { $0.id == turnID }) {
                    rows[index].usage = rows[index].usage + report.usage
                    rows[index].toolLabels = Array(Set(rows[index].toolLabels).union(report.toolLabels)).sorted()
                } else {
                    rows.append(ConversationTranscript.TurnTokenUsage(
                        id: turnID,
                        provider: provider,
                        recordedAt: .now,
                        usage: report.usage,
                        toolLabels: report.toolLabels.sorted()
                    ))
                }
                transcript.tokenUsage = rows
            }
        }
        try await withTaskOperationLock(taskID) {
            let task = try self.requireSubject(taskID)
            task.tokenUsage = task.tokenUsage + report.usage
            try await self.saveTaskContext(taskID: taskID)
        }
        PlayhouseDiagnostics.record("task.token_usage.recorded", fields: [
            "taskID": taskID.uuidString,
            "provider": provider.rawValue,
            "turnID": report.turnID ?? "",
            "totalTokens": String(report.usage.totalTokens),
        ])
    }

    /// Adds one streamed model call to the session's snapshot, so the card's
    /// counter climbs while the turn runs rather than jumping at its end.
    func recordLiveCall(taskID: UUID, provider: ConversationProvider, sourceID: String, call: ConversationLiveCall) async throws {
        try await withTaskOperationLock(taskID) {
            let task = try self.requireSubject(taskID)
            var snapshots = task.callUsageSnapshots
            let key = "\(provider.rawValue):\(sourceID)"
            var snapshot = snapshots[key] ?? ConversationCallUsageSnapshot(provider: provider.rawValue, updatedAt: .now)
            var agent = call.agentID.map { snapshot.subagents[$0] ?? ConversationCallUsage() } ?? snapshot.main
            agent.calls += call.calls
            agent.sentTokens += call.sentTokens
            agent.outputTokens += call.outputTokens
            agent.uncachedInputTokens += call.uncachedInputTokens
            agent.cacheReadTokens += call.cacheReadTokens
            agent.cacheWriteTokens += call.cacheWriteTokens
            if call.calls > 0 { agent.lastContextTokens = call.contextTokens }
            if let agentID = call.agentID { snapshot.subagents[agentID] = agent } else { snapshot.main = agent }
            snapshot.updatedAt = .now
            snapshots[key] = snapshot
            task.callUsageSnapshots = snapshots
            try await self.saveTaskContext(taskID: taskID)
        }
    }

    /// Replaces a Claude session's live-accumulated snapshot with what its
    /// session files hold, which also covers every subagent's final calls and
    /// the output counts that were still growing while streaming.
    func refreshClaudeCallUsage(taskID: UUID, sessionID: String, configDirectory: String) async throws {
        let snapshot = await Task.detached(priority: .utility) {
            ClaudeSessionUsageReader.read(sessionID: sessionID, configDirectory: configDirectory)
        }.value
        guard var snapshot else { return }
        try await withTaskOperationLock(taskID) {
            let task = try self.requireSubject(taskID)
            var snapshots = task.callUsageSnapshots
            snapshot.updatedAt = .now
            snapshots["\(ConversationProvider.claude.rawValue):\(sessionID)"] = snapshot
            task.callUsageSnapshots = snapshots
            try await self.saveTaskContext(taskID: taskID)
        }
        PlayhouseDiagnostics.record("task.call_usage.refreshed", fields: [
            "taskID": taskID.uuidString,
            "calls": String(snapshot.totalCalls),
            "sentTokens": String(snapshot.totalSentTokens),
        ])
    }

    func tokenUsageSummary(_ id: UUID) throws -> TaskTokenUsageSummary {
        let task = try requireSubject(id)
        let transcript = (try? conversationTranscriptStore().readState(id)) ?? ConversationTranscript()
        let rows = transcript.tokenUsage ?? []
        var turnsByTool: [String: (turnCount: Int, totalTokens: Int)] = [:]
        for row in rows {
            for label in Set(row.toolLabels) {
                let running = turnsByTool[label] ?? (0, 0)
                turnsByTool[label] = (running.turnCount + 1, running.totalTokens + row.usage.totalTokens)
            }
        }
        return TaskTokenUsageSummary(
            taskID: id,
            usage: task.tokenUsage,
            turns: rows.map {
                TaskTokenUsageSummary.Turn(
                    id: $0.id, provider: $0.provider, recordedAt: $0.recordedAt,
                    usage: $0.usage, tools: $0.toolLabels
                )
            },
            tools: turnsByTool
                .map { TaskTokenUsageSummary.Tool(id: $0.key, turnCount: $0.value.turnCount, totalTokens: $0.value.totalTokens) }
                .sorted { lhs, rhs in
                    lhs.totalTokens != rhs.totalTokens ? lhs.totalTokens > rhs.totalTokens : lhs.id < rhs.id
                },
            callUsage: TaskTokenUsageSummary.CallUsage(snapshots: Array(task.callUsageSnapshots.values)),
            contextCompactions: transcript.contextCompactions ?? [], promptCacheMisses: transcript.promptCacheMisses ?? []
        )
    }

    /// The provider sessions whose files hold what this task's requests were
    /// sent, the current provider's first so it is the default agent.
    func tokenMapSessions(_ id: UUID) throws -> [ProviderSessionReference] {
        let subject = try requireSubject(id)
        let snapshots = subject.callUsageSnapshots
        let providers = [subject.conversationProvider] + ConversationProvider.allCases.filter { $0 != subject.conversationProvider }
        return providers.compactMap { provider in
            guard let sessionID = subject.conversationID(for: provider) else { return nil }
            let subagents = snapshots["\(provider.rawValue):\(sessionID)"]?.subagents.keys.sorted() ?? []
            return ProviderSessionReference(
                provider: provider, sessionID: sessionID, subagentThreadIDs: provider == .codex ? subagents : []
            )
        }
    }

    /// What filled this task's context, ranked by the tokens each item, tool
    /// and MCP server added, read from the providers' own session files.
    func tokenWasteReport(_ id: UUID, homes: ProviderSessionHomes) async throws -> TaskTokenWasteReport {
        let sessions = try tokenMapSessions(id)
        return await Task.detached(priority: .userInitiated) {
            ProviderTokenMap.wasteReport(taskID: id, agents: ProviderTokenMap.load(sessions: sessions, homes: homes))
        }.value
    }

    /// One page of an agent's context: the final transcript, everything ever
    /// sent, or one request's items in the order it sent them (`request` is
    /// from 1; `nil` is the request the final transcript was read from).
    func rawInputPage(
        _ id: UUID, homes: ProviderSessionHomes, agent: String?, scope: TaskRawInputScope, order: TaskRawInputOrder,
        query: String, offset: Int, limit: Int, focus: Int?, request: Int? = nil
    ) async throws -> TaskRawInputPage {
        let sessions = try tokenMapSessions(id)
        return try await Task.detached(priority: .userInitiated) {
            try ProviderTokenMap.page(
                taskID: id, agents: ProviderTokenMap.load(sessions: sessions, homes: homes), agent: agent,
                scope: scope, order: order, query: query, offset: offset, limit: limit, focus: focus, request: request
            )
        }.value
    }

    /// One whole request of an agent, as readable text or as its request body JSON.
    func rawInputExport(
        _ id: UUID, homes: ProviderSessionHomes, agent: String?, request: Int?, format: TaskRawInputExportFormat
    ) async throws -> TaskRawInputExport {
        let sessions = try tokenMapSessions(id)
        return try await Task.detached(priority: .userInitiated) {
            try ProviderTokenMap.export(
                taskID: id, agents: ProviderTokenMap.load(sessions: sessions, homes: homes), agent: agent,
                request: request, format: format
            )
        }.value
    }

    /// One chunk of an item's full text, exactly as the model received it.
    func rawInputText(
        _ id: UUID, homes: ProviderSessionHomes, agent: String?, item: Int, offset: Int, length: Int
    ) async throws -> TaskRawInputText {
        let sessions = try tokenMapSessions(id)
        return try await Task.detached(priority: .userInitiated) {
            try ProviderTokenMap.text(
                taskID: id, agents: ProviderTokenMap.load(sessions: sessions, homes: homes), agent: agent,
                item: item, offset: offset, length: length
            )
        }.value
    }

    /// `reason` explains a `nil` percent: `"not_running"` for an idle or
    /// not-yet-sampled task of either provider. A turn-active Codex task
    /// reports its working-directory share of the shared app-server's tree
    /// (see `TaskCPUUsageSnapshot`), `0` when none of it is attributable.
    struct TaskCPUUsageResult: Codable {
        var cpuPercent: Double?
        var reason: String?

        // Synthesized Encodable would use encodeIfPresent for the optional
        // properties and omit `cpuPercent`/`reason` entirely when nil, but the
        // CLI/UI contract reads an explicit `null` to distinguish "idle" from
        // a missing field, so both keys are always written.
        enum CodingKeys: String, CodingKey {
            case cpuPercent
            case reason
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cpuPercent, forKey: .cpuPercent)
            try container.encode(reason, forKey: .reason)
        }
    }
}
