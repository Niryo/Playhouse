import CryptoKit
import Foundation

enum ProviderTokenCalibration {
    /// Walks the requests in order. A request's context minus the items already
    /// measured is what its new items cost, shared by weight. Items no request
    /// could measure fall back to the measured tokens-per-weight ratio.
    static func apply(
        items: inout [ProviderContextItem], requests: [(items: [Int], context: Int?)], preassigned: [Int: Int] = [:]
    ) {
        var assigned = [Bool](repeating: false, count: items.count)
        for (id, tokens) in preassigned {
            items[id].tokens = tokens
            assigned[id] = true
        }
        var measuredTokens = 0
        var measuredWeight = 0
        for request in requests {
            guard let context = request.context, context > 0 else { continue }
            var seen = Set<Int>()
            var known = 0
            var fresh: [Int] = []
            for id in request.items where seen.insert(id).inserted {
                if assigned[id] { known += items[id].tokens } else { fresh.append(id) }
            }
            let remaining = context - known
            guard !fresh.isEmpty, remaining > 0 else { continue }
            distribute(remaining, over: fresh, items: &items)
            for id in fresh { assigned[id] = true }
            measuredTokens += remaining
            measuredWeight += fresh.reduce(0) { $0 + items[$1].weight }
        }
        let ratio = measuredWeight > 0 ? Double(measuredTokens) / Double(measuredWeight) : 0.25
        for id in items.indices where !assigned[id] {
            items[id].tokens = Int((Double(items[id].weight) * ratio).rounded())
        }
    }

    /// Shares `tokens` by weight; the rounding remainder goes to the heaviest item.
    static func distribute(_ tokens: Int, over ids: [Int], items: inout [ProviderContextItem]) {
        let total = ids.reduce(0) { $0 + items[$1].weight }
        guard total > 0, let heaviest = ids.max(by: { items[$0].weight < items[$1].weight }) else { return }
        var given = 0
        for id in ids {
            let share = Int(Int64(tokens) * Int64(items[id].weight) / Int64(total))
            items[id].tokens = share
            given += share
        }
        items[heaviest].tokens += tokens - given
    }

    /// Ratio measured only from requests that append to the one before them.
    static func appendRatio(items: [ProviderContextItem], deltas: [(items: [Int], tokens: Int)]) -> Double? {
        var tokens = 0
        var weight = 0
        for delta in deltas where delta.tokens > 0 {
            let added = delta.items.reduce(0) { $0 + items[$1].weight }
            guard added > 0 else { continue }
            tokens += delta.tokens
            weight += added
        }
        return weight > 0 ? Double(tokens) / Double(weight) : nil
    }
}
// MARK: - Task token map

/// A provider session whose files a task's token map reads.
struct ProviderSessionReference: Sendable {
    let provider: ConversationProvider
    let sessionID: String
    /// Codex subagents run on their own threads, each with its own rollout file.
    let subagentThreadIDs: [String]
}

/// What a token map reads: the provider sessions, and for one turn the span its requests were sent in.
struct TokenMapScope: Sendable {
    let sessions: [ProviderSessionReference]
    let window: ProviderRequestWindow?
}

/// What wasted a task's tokens: the largest items, tools and MCP servers by
/// the tokens they added, what every request carries, repeats and cache misses.
struct TaskTokenWasteReport: Codable, Equatable, Sendable {
    struct Agent: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let provider: String
        let label: String
        let isMain: Bool
        let requests: Int
        let sentTokens: Int
        let finalTranscriptTokens: Int
        let items: Int
        let compactions: Int
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let item: Int
        let kind: String
        let label: String
        let server: String?
        let tokens: Int
        let requests: Int
        let rentTokens: Int
        let inFinalTranscript: Bool
        let preview: String
    }

    struct Tool: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let server: String?
        let calls: Int
        let totalTokens: Int
        let resultTokens: Int
        let largestResultTokens: Int
        let averageResultTokens: Int
        let rentTokens: Int
    }

    struct Server: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let tools: Int
        let calls: Int
        let totalTokens: Int
        let definitionTokens: Int
    }

    struct Overhead: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let label: String
        let kind: String
        let tokens: Int
        let requests: Int
        let everyRequest: Bool
        let item: Int?
    }

    struct Duplicate: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let item: Int
        let label: String
        let copies: Int
        let tokensPerCopy: Int
        let wastedTokens: Int
    }

    struct CacheMiss: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let agent: String
        let request: Int
        let timestamp: String?
        let contextTokens: Int
        /// Tokens the previous request already sent that this one did not read from cache.
        let rewrittenTokens: Int
    }

    let taskID: UUID
    let available: Bool
    let agents: [Agent]
    let wasters: [Item]
    let tools: [Tool]
    let servers: [Server]
    let overhead: [Overhead]
    let duplicates: [Duplicate]
    let cacheMisses: [CacheMiss]
}

/// One page of an agent's context, without the items' full text.
struct TaskRawInputPage: Codable, Equatable, Sendable {
    /// An item whose identical text one request sends more than once.
    struct Repeat: Codable, Equatable, Sendable {
        /// Position of the group's first copy in the request.
        let first: Int
        /// Which copy this is, from 1, and how many the request holds.
        let copy: Int
        let copies: Int
    }

    struct Row: Codable, Equatable, Sendable, Identifiable {
        let id: Int
        /// Where the item sits in a single request, from 0; absent in the other scopes.
        let position: Int?
        let kind: String
        let role: String
        let label: String
        let server: String?
        let tokens: Int
        let requests: Int
        let rentTokens: Int
        let inFinalTranscript: Bool
        let textLength: Int
        let preview: String
        let repeated: Repeat?
    }

    /// The single request a `request`-scope page lists.
    struct Request: Codable, Equatable, Sendable {
        /// From 1, in the order the agent made its requests.
        let number: Int
        let count: Int
        /// The request whose context is the final transcript, which a page shows when none is named.
        let latest: Int
        let timestamp: String?
        let querySource: String?
        let items: Int
        /// What the items' estimated sizes add up to.
        let itemTokens: Int
        /// The provider's own figures; absent when it reported no usage for this request.
        let contextTokens: Int?
        let inputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let outputTokens: Int?
        let repeatedItems: Int
        /// Whether the provider's log records exactly what the request sent.
        let exact: Bool
        let note: String
        let tokenNote: String
    }

    let taskID: UUID
    let agent: String?
    let agents: [TaskTokenWasteReport.Agent]
    let scope: String
    let order: String
    let query: String
    let total: Int
    let totalTokens: Int
    let maxTokens: Int
    let offset: Int
    let rows: [Row]
    /// Where the requested focus item sits in this ordering, so a caller can load up to it.
    let focusPosition: Int?
    let request: Request?
}

/// One whole request, exported as readable text or as the request body JSON.
struct TaskRawInputExport: Codable, Equatable, Sendable {
    let taskID: UUID
    let agent: String
    let request: Int
    let format: String
    let exact: Bool
    let items: Int
    let text: String
}

/// One chunk of an item's full text, as the model received it.
struct TaskRawInputText: Codable, Equatable, Sendable {
    let taskID: UUID
    let agent: String
    let item: Int
    let kind: String
    let label: String
    let tokens: Int
    let requests: Int
    /// For a tool result, the call that produced it.
    let call: String?
    let totalLength: Int
    let offset: Int
    let nextOffset: Int?
    let text: String
}

enum TaskRawInputScope: String, CaseIterable, Sendable {
    case finalTranscript = "final"
    case everything = "all"
    /// One request's items in the order it sent them, repeats included.
    case request
}

enum TaskRawInputExportFormat: String, CaseIterable, Sendable {
    case text
    case json
}

enum TaskRawInputOrder: String, CaseIterable, Sendable {
    case transcript
    case size
    case rent
}

enum ProviderTokenMap {
    struct LoadedAgent: Sendable {
        let id: String
        let label: String
        let isMain: Bool
        let log: ProviderAgentLog
    }

    static let defaultTextChunk = 32_768
    private static let listLimit = 20

    /// Reads every agent of the given sessions; agents whose files hold no request log are left out.
    /// A `window` keeps only the requests one turn made, and leaves out agents that made none in it.
    static func load(
        sessions: [ProviderSessionReference], homes: ProviderSessionHomes, window: ProviderRequestWindow? = nil,
        store: ProviderRequestLogStore = .shared
    ) -> [LoadedAgent] {
        var agents: [LoadedAgent] = []
        for session in sessions {
            let provider = session.provider.rawValue
            var files: [(id: String, label: String, isMain: Bool, file: URL)] = []
            switch session.provider {
            case .claude:
                guard let main = ClaudeSessionUsageReader.sessionFile(sessionID: session.sessionID, configDirectory: homes.claudeConfigDirectory) else { continue }
                files.append((provider, "Claude main agent", true, main))
                for subagent in ClaudeSessionUsageReader.subagentFiles(mainFile: main) {
                    files.append(("\(provider)/\(subagent.agentID)", "Claude subagent \(subagent.agentID)", false, subagent.file))
                }
            case .codex:
                if let main = store.codexRolloutFile(threadID: session.sessionID, codexHome: homes.codexHome) {
                    files.append((provider, "Codex main agent", true, main))
                }
                for thread in session.subagentThreadIDs.sorted() {
                    if let file = store.codexRolloutFile(threadID: thread, codexHome: homes.codexHome) {
                        files.append(("\(provider)/\(thread)", "Codex subagent \(thread)", false, file))
                    }
                }
            }
            for file in files {
                guard let whole = store.log(provider: session.provider, file: file.file) else { continue }
                let log = window.map { whole.within($0) } ?? whole
                guard log.isAvailable else { continue }
                agents.append(LoadedAgent(id: file.id, label: file.label, isMain: file.isMain, log: log))
            }
        }
        return agents
    }

    /// The model calls the loaded agents' logs record, one snapshot per provider, in the shape
    /// the task's own live-recorded call usage takes.
    static func callUsageSnapshots(_ agents: [LoadedAgent]) -> [ConversationCallUsageSnapshot] {
        var snapshots: [ConversationProvider: ConversationCallUsageSnapshot] = [:]
        for agent in agents {
            let provider = agent.log.provider
            var snapshot = snapshots[provider] ?? ConversationCallUsageSnapshot(provider: provider.rawValue, updatedAt: .now)
            var usage = ConversationCallUsage()
            for request in agent.log.requests {
                let cacheWrite = request.cacheWriteTokens ?? 0
                usage.calls += 1
                usage.sentTokens += request.contextTokens
                usage.outputTokens += request.outputTokens
                usage.cacheReadTokens += request.cacheReadTokens
                usage.cacheWriteTokens += cacheWrite
                usage.uncachedInputTokens += request.contextTokens - request.cacheReadTokens - cacheWrite
                usage.lastContextTokens = request.contextTokens
            }
            if agent.isMain { snapshot.main = usage } else { snapshot.subagents[agent.id] = usage }
            snapshots[provider] = snapshot
        }
        return ConversationProvider.allCases.compactMap { snapshots[$0] }
    }

    static func agentSummaries(_ agents: [LoadedAgent]) -> [TaskTokenWasteReport.Agent] {
        agents.map {
            TaskTokenWasteReport.Agent(
                id: $0.id, provider: $0.log.provider.rawValue, label: $0.label, isMain: $0.isMain,
                requests: $0.log.sentRequests, sentTokens: $0.log.sentTokens,
                finalTranscriptTokens: $0.log.finalTranscriptTokens,
                items: $0.log.items.filter { $0.requests > 0 }.count, compactions: $0.log.compactions
            )
        }
    }

    static func wasteReport(taskID: UUID, agents: [LoadedAgent]) -> TaskTokenWasteReport {
        var sent: [(agent: LoadedAgent, item: ProviderContextItem)] = []
        for agent in agents {
            for item in agent.log.items where item.requests > 0 { sent.append((agent, item)) }
        }
        func reportItem(_ agent: LoadedAgent, _ item: ProviderContextItem) -> TaskTokenWasteReport.Item {
            TaskTokenWasteReport.Item(
                id: "\(agent.id)#\(item.id)", agent: agent.id, item: item.id, kind: item.kind.rawValue,
                label: item.label, server: item.server, tokens: item.tokens, requests: item.requests,
                rentTokens: item.tokens * item.requests, inFinalTranscript: item.inFinalTranscript, preview: item.preview
            )
        }

        // Ranked by size: when an item arrived is chance, how much it added is the tool's doing.
        let wasters = sent
            .filter { !$0.item.kind.isFixedOverhead }
            .sorted { (lhs: (agent: LoadedAgent, item: ProviderContextItem), rhs: (agent: LoadedAgent, item: ProviderContextItem)) -> Bool in
                if lhs.item.tokens != rhs.item.tokens { return lhs.item.tokens > rhs.item.tokens }
                if lhs.agent.id != rhs.agent.id { return lhs.agent.id < rhs.agent.id }
                return lhs.item.id < rhs.item.id
            }
            .prefix(listLimit)
            .map { reportItem($0.agent, $0.item) }

        let toolItems = sent.filter { $0.item.kind == .toolCall || $0.item.kind == .toolResult }
        var tools: [TaskTokenWasteReport.Tool] = []
        for (label, entries) in Dictionary(grouping: toolItems, by: { $0.item.label }) {
            let results = entries.map(\.item).filter { $0.kind == .toolResult }
            let resultTokens = results.reduce(0) { $0 + $1.tokens }
            tools.append(TaskTokenWasteReport.Tool(
                id: label, server: entries.first?.item.server,
                calls: entries.filter { $0.item.kind == .toolCall }.count,
                totalTokens: entries.reduce(0) { $0 + $1.item.tokens },
                resultTokens: resultTokens,
                largestResultTokens: results.map(\.tokens).max() ?? 0,
                averageResultTokens: results.isEmpty ? 0 : resultTokens / results.count,
                rentTokens: entries.reduce(0) { $0 + $1.item.tokens * $1.item.requests }
            ))
        }
        tools.sort { $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.id < $1.id }

        let mains = agents.filter(\.isMain)
        var definitions: [ProviderContextItem] = []
        for agent in mains {
            definitions += agent.log.finalTranscript.map { agent.log.items[$0] }.filter { $0.kind == .toolDefinition }
        }
        let serverNames = Set(toolItems.compactMap(\.item.server) + definitions.compactMap(\.server))
        var servers: [TaskTokenWasteReport.Server] = []
        for server in serverNames {
            let used = toolItems.map(\.item).filter { $0.server == server }
            let defined = definitions.filter { $0.server == server }
            let labels = Set(used.map(\.label) + defined.map(\.label))
            servers.append(TaskTokenWasteReport.Server(
                id: server,
                tools: labels.count,
                calls: used.filter { $0.kind == .toolCall }.count,
                totalTokens: used.reduce(0) { $0 + $1.tokens },
                definitionTokens: defined.reduce(0) { $0 + $1.tokens }
            ))
        }
        servers.sort { lhs, rhs in
            let left = lhs.totalTokens + lhs.definitionTokens
            let right = rhs.totalTokens + rhs.definitionTokens
            return left != right ? left > right : lhs.id < rhs.id
        }

        var overhead: [TaskTokenWasteReport.Overhead] = []
        for agent in mains {
            let fixed = agent.log.finalTranscript.map { agent.log.items[$0] }.filter(\.kind.isFixedOverhead)
            for item in fixed where item.server == nil {
                overhead.append(.init(
                    id: "\(agent.id)#\(item.id)", agent: agent.id,
                    label: item.kind == .toolDefinition ? "Tool definition: \(item.label)" : item.label,
                    kind: item.kind.rawValue, tokens: item.tokens, requests: item.requests,
                    everyRequest: item.requests == agent.log.sentRequests, item: item.id
                ))
            }
            for (server, group) in Dictionary(grouping: fixed.filter { $0.server != nil }, by: { $0.server ?? "" }) {
                let requests = group.map(\.requests).max() ?? 0
                overhead.append(.init(
                    id: "\(agent.id)#mcp:\(server)", agent: agent.id,
                    label: "MCP server \(server) · \(group.count) tool definition\(group.count == 1 ? "" : "s")",
                    kind: ProviderContextKind.toolDefinition.rawValue, tokens: group.reduce(0) { $0 + $1.tokens },
                    requests: requests, everyRequest: requests == agent.log.sentRequests, item: nil
                ))
            }
        }
        overhead.sort { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }

        var duplicates: [TaskTokenWasteReport.Duplicate] = []
        for agent in agents {
            let results = agent.log.items.filter { $0.kind == .toolResult && $0.requests > 0 && $0.textLength > 0 }
            for copies in Dictionary(grouping: results, by: { "\($0.contentKey):\($0.textLength)" }).values where copies.count > 1 {
                let ordered = copies.sorted { $0.id < $1.id }
                duplicates.append(.init(
                    id: "\(agent.id)#\(ordered[0].id)", agent: agent.id, item: ordered[0].id, label: ordered[0].label,
                    copies: ordered.count, tokensPerCopy: ordered[0].tokens,
                    wastedTokens: ordered.dropFirst().reduce(0) { $0 + $1.tokens }
                ))
            }
        }
        duplicates.sort { $0.wastedTokens != $1.wastedTokens ? $0.wastedTokens > $1.wastedTokens : $0.id < $1.id }

        // New content is always sent uncached. A miss is a request that sent
        // more than half of what the previous one already sent without reading
        // it from cache, so it paid for that prefix again.
        var cacheMisses: [TaskTokenWasteReport.CacheMiss] = []
        for agent in agents {
            for (index, (previous, request)) in zip(agent.log.requests, agent.log.requests.dropFirst()).enumerated() {
                let added = max(0, request.contextTokens - previous.contextTokens)
                let rewritten = request.contextTokens - request.cacheReadTokens - added
                guard rewritten >= 1_000, rewritten * 2 >= previous.contextTokens else { continue }
                cacheMisses.append(.init(
                    id: "\(agent.id)#request:\(index + 2)", agent: agent.id, request: index + 2, timestamp: request.timestamp,
                    contextTokens: request.contextTokens, rewrittenTokens: rewritten
                ))
            }
        }
        cacheMisses.sort { $0.rewrittenTokens != $1.rewrittenTokens ? $0.rewrittenTokens > $1.rewrittenTokens : $0.id < $1.id }

        return TaskTokenWasteReport(
            taskID: taskID, available: !agents.isEmpty, agents: agentSummaries(agents),
            wasters: Array(wasters), tools: tools, servers: servers, overhead: overhead,
            duplicates: Array(duplicates.prefix(listLimit)), cacheMisses: Array(cacheMisses.prefix(listLimit))
        )
    }

    static func page(
        taskID: UUID, agents: [LoadedAgent], agent: String?, scope: TaskRawInputScope, order: TaskRawInputOrder,
        query: String, offset: Int, limit: Int, focus: Int?, request number: Int? = nil,
        store: ProviderRequestLogStore = .shared
    ) throws -> TaskRawInputPage {
        let summaries = agentSummaries(agents)
        guard let loaded = try resolve(agent, in: agents) else {
            return TaskRawInputPage(
                taskID: taskID, agent: nil, agents: summaries, scope: scope.rawValue, order: order.rawValue, query: query,
                total: 0, totalTokens: 0, maxTokens: 0, offset: offset, rows: [], focusPosition: nil, request: nil
            )
        }
        let items = loaded.log.items
        // A single request can send one item twice, so its rows are told apart by position.
        var entries: [(position: Int?, id: Int)]
        var repeats: [Int: TaskRawInputPage.Repeat] = [:]
        var request: TaskRawInputPage.Request?
        switch scope {
        case .finalTranscript:
            entries = loaded.log.finalTranscript.map { (nil, $0) }
        case .everything:
            // Everything ever sent, in the order it was first logged; Codex's hidden overhead leads.
            entries = items.filter { $0.requests > 0 }
                .sorted { ($0.kind == .hiddenOverhead ? -1 : $0.id) < ($1.kind == .hiddenOverhead ? -1 : $1.id) }
                .map { (nil, $0.id) }
        case .request:
            let index = try requestIndex(number, in: loaded.log)
            let sent = loaded.log.sent[index]
            entries = sent.items.enumerated().map { ($0.offset, $0.element) }
            repeats = repeatedItems(sent.items, items: items)
            request = requestSummary(index, of: loaded.log, repeats: repeats.count)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            var seen = Set<Int>()
            let unmatched = entries.map { items[$0.id] }.filter {
                seen.insert($0.id).inserted
                    && !$0.label.localizedCaseInsensitiveContains(needle) && !$0.preview.localizedCaseInsensitiveContains(needle)
            }
            let texts = store.texts(of: unmatched, in: loaded.log)
            let misses = Set(unmatched.map(\.id).filter { !(texts[$0]?.localizedCaseInsensitiveContains(needle) ?? false) })
            entries = entries.filter { !misses.contains($0.id) }
        }
        switch order {
        case .transcript: break
        case .size:
            entries = entries.enumerated().sorted { lhs, rhs in
                items[lhs.element.id].tokens != items[rhs.element.id].tokens
                    ? items[lhs.element.id].tokens > items[rhs.element.id].tokens : lhs.offset < rhs.offset
            }.map(\.element)
        case .rent:
            entries = entries.enumerated().sorted { lhs, rhs in
                let left = items[lhs.element.id].tokens * items[lhs.element.id].requests
                let right = items[rhs.element.id].tokens * items[rhs.element.id].requests
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        let window = entries.dropFirst(offset).prefix(limit)
        return TaskRawInputPage(
            taskID: taskID, agent: loaded.id, agents: summaries, scope: scope.rawValue, order: order.rawValue, query: needle,
            total: entries.count, totalTokens: entries.reduce(0) { $0 + items[$1.id].tokens },
            maxTokens: entries.map { items[$0.id].tokens }.max() ?? 0, offset: offset,
            rows: window.map { entry in
                let item = items[entry.id]
                return TaskRawInputPage.Row(
                    id: entry.id, position: entry.position, kind: item.kind.rawValue, role: item.role, label: item.label,
                    server: item.server, tokens: item.tokens, requests: item.requests, rentTokens: item.tokens * item.requests,
                    inFinalTranscript: item.inFinalTranscript, textLength: item.textLength, preview: item.preview,
                    repeated: entry.position.flatMap { repeats[$0] }
                )
            },
            focusPosition: focus.flatMap { id in entries.firstIndex { $0.id == id } },
            request: request
        )
    }

    /// Index in `sent` of request `number` (from 1); `nil` is the request the final transcript was read from.
    private static func requestIndex(_ number: Int?, in log: ProviderAgentLog) throws -> Int {
        guard let number else {
            guard let latest = log.finalRequest ?? log.sent.indices.last else {
                throw BridgeCommandError(code: "not_found", message: "This agent's log records no request.")
            }
            return latest
        }
        guard log.sent.indices.contains(number - 1) else {
            throw BridgeCommandError(
                code: "not_found",
                message: "This agent made \(log.sent.count) \(log.sent.count == 1 ? "request" : "requests"); there is no request \(number)."
            )
        }
        return number - 1
    }

    /// Items a request sends more than once with identical text, keyed by
    /// their positions in the request.
    static func repeatedItems(_ ids: [Int], items: [ProviderContextItem]) -> [Int: TaskRawInputPage.Repeat] {
        var copies: [String: [Int]] = [:]
        for (position, id) in ids.enumerated() {
            let item = items[id]
            guard item.kind != .hiddenOverhead, item.textLength > 0 else { continue }
            copies["\(item.contentKey):\(item.textLength)", default: []].append(position)
        }
        var result: [Int: TaskRawInputPage.Repeat] = [:]
        for positions in copies.values where positions.count > 1 {
            for (copy, position) in positions.enumerated() {
                result[position] = .init(first: positions[0], copy: copy + 1, copies: positions.count)
            }
        }
        return result
    }

    private static func requestSummary(_ index: Int, of log: ProviderAgentLog, repeats: Int) -> TaskRawInputPage.Request {
        let sent = log.sent[index]
        let itemTokens = sent.items.reduce(0) { $0 + log.items[$1].tokens }
        let usage = sent.usage
        let note: String
        let complete = sent.missingMessages == 0 && !sent.missingShape
        switch log.provider {
        case .claude where complete:
            note = "Exact: rebuilt from Claude Code's request log, with the system prompt, tool definitions and every message this request sent, in order."
        case .claude:
            var gaps: [String] = []
            if sent.missingShape { gaps.append("its system prompt and tool definitions") }
            if sent.missingMessages > 0 { gaps.append("\(sent.missingMessages) \(sent.missingMessages == 1 ? "message" : "messages")") }
            note = "Rebuilt from Claude Code's request log, which does not hold everything this request named; missing here: \(gaps.joined(separator: " and "))."
        case .codex:
            note = "Reconstructed: Codex resends the whole history, so this is its base instructions plus every item its rollout file saved before this request's output. Codex does not save its tool definitions or request framing; they are one estimated hidden-overhead item and are left out of the JSON export."
        }
        let tokenNote: String
        if let context = usage?.contextTokens {
            let difference = itemTokens - context
            tokenNote = difference == 0
                ? "The items' sizes add up to the input the provider reported for this request."
                : "The items' sizes add up to \(abs(difference)) \(difference > 0 ? "more" : "fewer") tokens than the provider reported: each item's size is measured once, from the first request that sent it, and an item sent twice counts twice."
        } else {
            tokenNote = "The provider reported no usage for this request; the items' sizes are estimates."
        }
        return TaskRawInputPage.Request(
            number: index + 1, count: log.sent.count, latest: (log.finalRequest ?? log.sent.count - 1) + 1,
            timestamp: sent.timestamp, querySource: sent.querySource, items: sent.items.count, itemTokens: itemTokens,
            contextTokens: usage?.contextTokens,
            inputTokens: usage.map { $0.contextTokens - $0.cacheReadTokens - ($0.cacheWriteTokens ?? 0) },
            cacheReadTokens: usage?.cacheReadTokens, cacheWriteTokens: usage?.cacheWriteTokens,
            outputTokens: usage?.outputTokens, repeatedItems: repeats,
            exact: log.provider == .claude && complete, note: note, tokenNote: tokenNote
        )
    }

    /// One whole request: as text, each item's full text under a header naming
    /// it, or as JSON, the request body as the provider's log holds it.
    static func export(
        taskID: UUID, agents: [LoadedAgent], agent: String?, request number: Int?, format: TaskRawInputExportFormat,
        store: ProviderRequestLogStore = .shared
    ) throws -> TaskRawInputExport {
        guard let loaded = try resolve(agent, in: agents) else {
            throw BridgeCommandError(code: "not_found", message: "This task has no request log yet.")
        }
        let log = loaded.log
        let index = try requestIndex(number, in: log)
        let sent = log.sent[index]
        let repeats = repeatedItems(sent.items, items: log.items)
        let summary = requestSummary(index, of: log, repeats: repeats.count)
        let text: String
        switch format {
        case .text:
            let texts = store.texts(of: Set(sent.items).map { log.items[$0] }, in: log)
            var lines = [
                "Request \(summary.number) of \(summary.count) · \(loaded.label)\(sent.timestamp.map { " · \($0)" } ?? "")",
                summary.contextTokens.map { context in
                    "Reported input: \(context) tokens (uncached \(summary.inputTokens ?? 0) · cache read \(summary.cacheReadTokens ?? 0)"
                        + (summary.cacheWriteTokens.map { " · cache write \($0)" } ?? "") + ")"
                } ?? "No usage reported.",
                "\(sent.items.count) items · \(summary.itemTokens) tokens by item · \(repeats.count) repeated",
                summary.note,
                summary.tokenNote,
            ]
            for (position, id) in sent.items.enumerated() {
                let item = log.items[id]
                var header = "===== #\(position + 1) · \(item.kind.rawValue) · \(item.label) · \(item.tokens) tokens"
                if let repeated = repeats[position] {
                    header += " · duplicate \(repeated.copy) of \(repeated.copies)"
                }
                lines += ["", header + " =====", texts[id] ?? item.preview]
            }
            text = lines.joined(separator: "\n") + "\n"
        case .json:
            text = ProviderContextText.prettyJSON(try requestBody(sent, of: log, store: store))
        }
        return TaskRawInputExport(
            taskID: taskID, agent: loaded.id, request: index + 1, format: format.rawValue,
            exact: summary.exact, items: sent.items.count, text: text
        )
    }

    /// Claude: the request's parameters, system prompt, tools and messages,
    /// with its cache markers put back. Codex: its instructions and input items.
    private static func requestBody(_ sent: ProviderSentRequest, of log: ProviderAgentLog, store: ProviderRequestLogStore) throws -> [String: Any] {
        var locations: [(key: Int, location: ProviderContextLocation)] = sent.items.enumerated().compactMap { position, id in
            log.items[id].location.map { (position, $0) }
        }
        if let line = sent.line { locations.append((-1, line)) }
        let values = store.values(at: locations, in: log)
        func value(_ position: Int) -> Any { values[position] ?? NSNull() }
        switch log.provider {
        case .codex:
            let kinds = sent.items.map { log.items[$0].kind }
            return [
                "instructions": kinds.indices.filter { kinds[$0] == .systemPrompt }.map(value).first ?? NSNull(),
                "input": kinds.indices.filter { kinds[$0] != .systemPrompt && kinds[$0] != .hiddenOverhead }.map(value),
            ]
        case .claude:
            let line = values[-1] as? [String: Any] ?? [:]
            var body = line["params"] as? [String: Any] ?? [:]
            let leading = sent.items.count - sent.messageLengths.reduce(0, +)
            body["system"] = (0..<leading).filter { log.items[sent.items[$0]].kind == .systemPrompt }.map(value)
            body["tools"] = (0..<leading).filter { log.items[sent.items[$0]].kind == .toolDefinition }.map(value)
            var messages: [Any] = []
            var start = leading
            for length in sent.messageLengths {
                let positions = Array(start..<(start + length))
                start += length
                guard let first = positions.first else { continue }
                let item = log.items[sent.items[first]]
                let content: Any
                if positions.count == 1, case .key = item.location?.path.last {
                    content = value(first)
                } else {
                    // Lines sent as one message turn a plain string into a text block.
                    content = positions.map { position -> Any in
                        (value(position) as? String).map { ["type": "text", "text": $0] as [String: Any] } ?? value(position)
                    }
                }
                messages.append(["role": item.role, "content": content])
            }
            body["messages"] = messages
            var marked: Any = body
            for marker in line["cacheControl"] as? [[String: Any]] ?? [] {
                guard let path = marker["path"] as? [Any], let cacheControl = marker["value"] else { continue }
                marked = settingCacheControl(cacheControl, at: path[...], in: marked)
            }
            return marked as? [String: Any] ?? body
        }
    }

    private static func settingCacheControl(_ value: Any, at path: ArraySlice<Any>, in container: Any) -> Any {
        guard let head = path.first else {
            guard var block = container as? [String: Any] else { return container }
            block["cache_control"] = value
            return block
        }
        if let key = head as? String, var object = container as? [String: Any], let child = object[key] {
            object[key] = settingCacheControl(value, at: path.dropFirst(), in: child)
            return object
        }
        if let index = (head as? NSNumber)?.intValue, var array = container as? [Any], array.indices.contains(index) {
            array[index] = settingCacheControl(value, at: path.dropFirst(), in: array[index])
            return array
        }
        return container
    }

    static func text(
        taskID: UUID, agents: [LoadedAgent], agent: String?, item id: Int, offset: Int, length: Int,
        store: ProviderRequestLogStore = .shared
    ) throws -> TaskRawInputText {
        guard let loaded = try resolve(agent, in: agents),
              loaded.log.items.indices.contains(id), loaded.log.items[id].requests > 0 else {
            throw BridgeCommandError(code: "not_found", message: "No item \(id) was sent in this task's context.")
        }
        let item = loaded.log.items[id]
        let scalars = Array(store.text(of: item, in: loaded.log).unicodeScalars)
        let start = min(offset, scalars.count)
        let window = min(length, scalars.count - start)
        var end = start + window
        // A chunk that is not the last ends on a line break, so lines are never split between chunks.
        if end < scalars.count, let newline = scalars[(start + window / 2)..<end].lastIndex(of: "\n") {
            end = newline + 1
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars[start..<end])
        let call = item.callItemID.map { callID -> String in
            let callItem = loaded.log.items[callID]
            let arguments = store.text(of: callItem, in: loaded.log)
            return "\(callItem.label) \(arguments.count > 2_000 ? String(arguments.prefix(1_999)) + "…" : arguments)"
        }
        return TaskRawInputText(
            taskID: taskID, agent: loaded.id, item: id, kind: item.kind.rawValue, label: item.label,
            tokens: item.tokens, requests: item.requests, call: call, totalLength: scalars.count,
            offset: start, nextOffset: end < scalars.count ? end : nil, text: String(text)
        )
    }

    /// `nil` picks the first agent; an unknown agent is an error rather than an empty answer.
    private static func resolve(_ agent: String?, in agents: [LoadedAgent]) throws -> LoadedAgent? {
        guard let agent, !agent.isEmpty else { return agents.first }
        guard let loaded = agents.first(where: { $0.id == agent }) else {
            throw BridgeCommandError(code: "not_found", message: "This task has no agent named \(agent).")
        }
        return loaded
    }
}
