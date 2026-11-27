import Foundation

extension BoardTaskManager {
    package func recordTokenUsage(
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
    package func recordLiveCall(taskID: UUID, provider: ConversationProvider, sourceID: String, call: ConversationLiveCall) async throws {
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
    package func refreshClaudeCallUsage(taskID: UUID, sessionID: String, configDirectory: String) async throws {
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

    package func tokenUsageSummary(_ id: UUID) throws -> TaskTokenUsageSummary {
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

    /// The turn's own row of a conversation's token accounting: its usage and tools, the
    /// compactions and resume cache misses inside it, and the model calls its requests made.
    package func tokenUsageSummary(_ id: UUID, turnID: String, homes: ProviderSessionHomes) async throws -> TaskTokenUsageSummary {
        let scope = try tokenMapScope(id, turnID: turnID)
        let transcript = (try? conversationTranscriptStore().readState(id)) ?? ConversationTranscript()
        let rows = (transcript.tokenUsage ?? []).filter { $0.id == turnID }
        let agents = await Task.detached(priority: .userInitiated) {
            ProviderTokenMap.load(sessions: scope.sessions, homes: homes, window: scope.window)
        }.value
        let usage = rows.reduce(ConversationTokenUsage()) { $0 + $1.usage }
        let tools = Set(rows.flatMap(\.toolLabels)).sorted()
        return TaskTokenUsageSummary(
            taskID: id,
            usage: usage,
            turns: rows.map {
                TaskTokenUsageSummary.Turn(id: $0.id, provider: $0.provider, recordedAt: $0.recordedAt, usage: $0.usage, tools: $0.toolLabels)
            },
            tools: tools.map { TaskTokenUsageSummary.Tool(id: $0, turnCount: 1, totalTokens: usage.totalTokens) },
            callUsage: TaskTokenUsageSummary.CallUsage(snapshots: ProviderTokenMap.callUsageSnapshots(agents)),
            contextCompactions: (transcript.contextCompactions ?? []).filter { scope.window?.contains($0.recordedAt) == true },
            promptCacheMisses: (transcript.promptCacheMisses ?? []).filter { $0.turnID == turnID }
        )
    }

    /// The provider sessions whose files hold what this task's requests were
    /// sent, the current provider's first so it is the default agent.
    package func tokenMapSessions(_ id: UUID) throws -> [ProviderSessionReference] {
        let subject = try requireSubject(id)
        let providers = [subject.conversationProvider] + ConversationProvider.allCases.filter { $0 != subject.conversationProvider }
        return providers.compactMap { provider in
            subject.conversationID(for: provider).map { sessionReference(subject, provider: provider, sessionID: $0) }
        }
    }

    private func sessionReference(_ subject: any ConversationSubject, provider: ConversationProvider, sessionID: String) -> ProviderSessionReference {
        let subagents = subject.callUsageSnapshots["\(provider.rawValue):\(sessionID)"]?.subagents.keys.sorted() ?? []
        // OpenCode's turns write its sessions' messages beside the store.
        let storeDirectory = modelContext.storeURL.deletingLastPathComponent()
        return ProviderSessionReference(
            provider: provider, sessionID: sessionID, subagentThreadIDs: provider == .codex ? subagents : [],
            requestLogDirectory: provider == .opencode ? OpenCodeRequestLog.directory(storeDirectory: storeDirectory) : nil
        )
    }

    /// What a token map reads: the whole conversation (no `turnID`), or one turn. A turn reads
    /// only the session it ran in, which for a standalone chat is its page's own session rather
    /// than whichever page the chat is on now, and only the requests sent between its first
    /// message and the next turn's.
    package func tokenMapScope(_ id: UUID, turnID: String?) throws -> TokenMapScope {
        guard let turnID else { return TokenMapScope(sessions: try tokenMapSessions(id), window: nil) }
        let subject = try requireSubject(id)
        let store = try conversationTranscriptStore()
        let order = try store.outline(id).turns
        guard let position = order.firstIndex(where: { $0.id == turnID }) else {
            throw BridgeCommandError(code: "not_found", message: "That turn is not in this conversation.")
        }
        let next = order.indices.contains(position + 1) ? order[position + 1].id : nil
        let transcript = try store.read(id, turns: .init(turnIDs: Set([turnID] + (next.map { [$0] } ?? []))), includeImages: false)
        func startedAt(_ id: String?) -> Date? {
            transcript.turns.first { $0.id == id }?.messages.compactMap(\.createdAt).min()
        }
        // A turn's scope always narrows: without its start time no request can be placed in it.
        guard let start = startedAt(turnID) else {
            throw BridgeCommandError(code: "not_found", message: "That turn has no recorded start time, so its requests can't be told apart.")
        }
        let turn = transcript.turns.first { $0.id == turnID }
        let row = transcript.tokenUsage?.first { $0.id == turnID }
        let provider = row?.provider
            ?? transcript.segments.first { $0.id == turn?.segmentID }?.provider
            ?? subject.conversationProvider
        // A later turn with no start time of its own ends this one when its usage was recorded.
        let end = next.map { startedAt($0) ?? row?.recordedAt ?? start }
        // A chat turn filed on a page reads that page's session, or none when the page's session is
        // another provider's; only a turn not yet filed reads the chat's own session, narrowed by the window.
        let sessionID: String?
        if subject.isStandaloneChat, let page = try standaloneChatManager(for: id).pageAssignmentsByTurnID()[turnID] {
            sessionID = page.conversationID(forProvider: provider.rawValue)
        } else {
            sessionID = subject.conversationID(for: provider)
        }
        return TokenMapScope(
            sessions: sessionID.map { [sessionReference(subject, provider: provider, sessionID: $0)] } ?? [],
            window: ProviderRequestWindow(start: start, end: end)
        )
    }

    /// What filled this task's context, ranked by the tokens each item, tool
    /// and MCP server added, read from the providers' own session files.
    package func tokenWasteReport(_ id: UUID, turnID: String? = nil, homes: ProviderSessionHomes) async throws -> TaskTokenWasteReport {
        let scope = try tokenMapScope(id, turnID: turnID)
        return await Task.detached(priority: .userInitiated) {
            ProviderTokenMap.wasteReport(taskID: id, agents: ProviderTokenMap.load(sessions: scope.sessions, homes: homes, window: scope.window))
        }.value
    }

    /// One page of an agent's context: the final transcript, everything ever
    /// sent, or one request's items in the order it sent them (`request` is
    /// from 1; `nil` is the request the final transcript was read from).
    package func rawInputPage(
        _ id: UUID, turnID: String? = nil, homes: ProviderSessionHomes, agent: String?, scope: TaskRawInputScope, order: TaskRawInputOrder,
        query: String, offset: Int, limit: Int, focus: Int?, request: Int? = nil
    ) async throws -> TaskRawInputPage {
        let map = try tokenMapScope(id, turnID: turnID)
        return try await Task.detached(priority: .userInitiated) {
            try ProviderTokenMap.page(
                taskID: id, agents: ProviderTokenMap.load(sessions: map.sessions, homes: homes, window: map.window), agent: agent,
                scope: scope, order: order, query: query, offset: offset, limit: limit, focus: focus, request: request
            )
        }.value
    }

    /// One whole request of an agent, as readable text or as its request body JSON.
    package func rawInputExport(
        _ id: UUID, turnID: String? = nil, homes: ProviderSessionHomes, agent: String?, request: Int?, format: TaskRawInputExportFormat
    ) async throws -> TaskRawInputExport {
        let scope = try tokenMapScope(id, turnID: turnID)
        return try await Task.detached(priority: .userInitiated) {
            try ProviderTokenMap.export(
                taskID: id, agents: ProviderTokenMap.load(sessions: scope.sessions, homes: homes, window: scope.window), agent: agent,
                request: request, format: format
            )
        }.value
    }

    /// One chunk of an item's full text, exactly as the model received it.
    package func rawInputText(
        _ id: UUID, turnID: String? = nil, homes: ProviderSessionHomes, agent: String?, item: Int, offset: Int, length: Int
    ) async throws -> TaskRawInputText {
        let scope = try tokenMapScope(id, turnID: turnID)
        return try await Task.detached(priority: .userInitiated) {
            try ProviderTokenMap.text(
                taskID: id, agents: ProviderTokenMap.load(sessions: scope.sessions, homes: homes, window: scope.window), agent: agent,
                item: item, offset: offset, length: length
            )
        }.value
    }

    /// `reason` explains a `nil` percent: `"not_running"` for an idle or
    /// not-yet-sampled task of either provider. A turn-active Codex task
    /// reports its working-directory share of the shared app-server's tree
    /// (see `TaskCPUUsageSnapshot`), `0` when none of it is attributable.
    package struct TaskCPUUsageResult: Codable {
        package var cpuPercent: Double?
        package var reason: String?

        // Synthesized Encodable would use encodeIfPresent for the optional
        // properties and omit `cpuPercent`/`reason` entirely when nil, but the
        // CLI/UI contract reads an explicit `null` to distinguish "idle" from
        // a missing field, so both keys are always written.
        package enum CodingKeys: String, CodingKey {
            case cpuPercent
            case reason
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cpuPercent, forKey: .cpuPercent)
            try container.encode(reason, forKey: .reason)
        }

        package init(cpuPercent: Double? = nil, reason: String? = nil) {
            self.cpuPercent = cpuPercent
            self.reason = reason
        }
    }
}
