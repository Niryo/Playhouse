import Darwin
import Foundation

struct ConversationMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: ConversationRole
    var createdAt: Date?
    var text: String
    var imageDataURLs: [String]
    /// True when the message has images that this read left out. A history read
    /// that defers images sets it; `ConversationManager.messageImages` returns them.
    var imagesDeferred: Bool?
    var phase: String?
    var turnID: String?
    var timelineOrder: Int?
    var asyncQuestions: [ConversationAsyncQuestion]?
    /// The runtime that produced an assistant message, or received a user message.
    /// Nil for transcripts saved before Playhouse supported more than Codex.
    var provider: ConversationProvider?
    /// Model selected when this message's turn was dispatched, when known.
    var modelID: String?

    init(id: String, role: ConversationRole, text: String, imageDataURLs: [String] = [], phase: String? = nil, turnID: String? = nil, timelineOrder: Int? = nil, asyncQuestions: [ConversationAsyncQuestion]? = nil, provider: ConversationProvider? = nil, createdAt: Date? = .now, modelID: String? = nil) {
        self.id = id
        self.role = role
        self.createdAt = createdAt
        self.text = text
        self.imageDataURLs = imageDataURLs
        self.phase = phase
        self.turnID = turnID
        self.timelineOrder = timelineOrder
        self.asyncQuestions = asyncQuestions
        self.provider = provider
        self.modelID = modelID
    }

    /// A user-role message Playhouse sent on its own, shown apart from the user's own.
    var isPlayhouseSent: Bool { role == .user && PlayhouseSentMessage.matches(text) }

    /// Where the newest turn the user started begins: what a window opening the conversation shows first.
    /// `continuingIDs` names live messages that joined a running turn before history gave them its turn ID.
    static func latestTurnStartIndex(in messages: [ConversationMessage], continuingIDs: Set<String> = []) -> Int? {
        // Prompts Playhouse sends on its own are not a turn the user started: anchoring the
        // window there would hide the conversation the recovery is continuing.
        // When redaction has replaced every user message, the placeholders are all there is to anchor on.
        messages.indices.last(where: { index in
            !PrivatePromptPlaceholder.matches(messages[index].text)
                && startsUserTurn(at: index, in: messages, continuingIDs: continuingIDs)
        })
            ?? messages.lastIndex(where: { $0.role == .user })
            ?? messages.indices.last
    }

    /// Whether the message at `index` is one the user sent to start a turn: not a prompt
    /// Playhouse sent on its own, and not a message that joined a turn already under way.
    static func startsUserTurn(at index: Int, in messages: [ConversationMessage], continuingIDs: Set<String> = []) -> Bool {
        let message = messages[index]
        return message.role == .user && !message.isPlayhouseSent
            && !continuesTurn(at: index, in: messages, continuingIDs: continuingIDs)
    }

    /// Whether the user message at `index` joined a turn already under way, as a steer or a notice
    /// the provider's runtime adds does, rather than starting one. Such a message follows the work
    /// its turn did before it, so it never moves where that turn begins.
    static func continuesTurn(at index: Int, in messages: [ConversationMessage], continuingIDs: Set<String> = []) -> Bool {
        let message = messages[index]
        guard message.role == .user else { return false }
        if continuingIDs.contains(message.id) { return true }
        guard let turnID = message.turnID else { return false }
        // A turn's messages are contiguous, so the scan stops at the first message of another turn.
        for earlier in messages[..<index].reversed() {
            guard let earlierTurnID = earlier.turnID else { continue }
            if earlierTurnID != turnID { return false }
            if earlier.role == .user { return true }
        }
        return false
    }

    private enum CodingKeys: String, CodingKey { case id, role, createdAt, text, imageDataURLs, imagesDeferred, phase, turnID, timelineOrder, asyncQuestions, provider, modelID }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(ConversationRole.self, forKey: .role)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        imageDataURLs = try container.decodeIfPresent([String].self, forKey: .imageDataURLs) ?? []
        imagesDeferred = try container.decodeIfPresent(Bool.self, forKey: .imagesDeferred)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        timelineOrder = try container.decodeIfPresent(Int.self, forKey: .timelineOrder)
        asyncQuestions = try container.decodeIfPresent([ConversationAsyncQuestion].self, forKey: .asyncQuestions)
        provider = try container.decodeIfPresent(ConversationProvider.self, forKey: .provider)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    }
}

struct ConversationAsyncQuestion: Codable, Equatable {
    let title: String
    let options: [String]?
}

struct ConversationUserQuestion: Identifiable, Codable, Equatable {
    struct Option: Identifiable, Codable, Equatable {
        let label: String
        let description: String?
        var id: String { label }
    }
    let id: String
    let header: String
    let question: String
    let options: [Option]
    let allowsOther: Bool
    let isSecret: Bool
}

struct ConversationUserInputRequest: Identifiable, Codable, Equatable {
    let id: String
    let threadID: String
    let questions: [ConversationUserQuestion]
    let isBlocking: Bool
    let mode: ConversationMode
}

enum ConversationMode: String, CaseIterable, Hashable, Codable {
    case code = "default"
    case plan

    var title: String {
        switch self {
        case .code: "Code mode"
        case .plan: "Plan mode"
        }
    }
}

enum ConversationEffort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }
    var title: String { rawValue == "xhigh" ? "Extra High" : rawValue.capitalized }
    var sliderPosition: Double { Double(Self.allCases.firstIndex(of: self) ?? 1) }

    static func from(sliderPosition: Double) -> ConversationEffort {
        allCases[min(max(Int(sliderPosition.rounded()), 0), allCases.count - 1)]
    }
}

struct ConversationModelOption: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
    var supportedEfforts: [ConversationEffort]? = nil
}

extension Array where Element == ConversationModelOption {
    /// The efforts `modelID` supports, or every effort when it doesn't say; an empty ID is the
    /// default model.
    func effortChoices(for modelID: String) -> [ConversationEffort] {
        let model = modelID.isEmpty ? first(where: \.isDefault) : first(where: { $0.id == modelID })
        guard let supported = model?.supportedEfforts, !supported.isEmpty else { return ConversationEffort.allCases }
        return ConversationEffort.allCases.filter(supported.contains)
    }

    /// `effort`, or the effort a newly chosen model falls back to when it doesn't support it.
    func effort(_ effort: ConversationEffort, keptFor modelID: String) -> ConversationEffort {
        let choices = effortChoices(for: modelID)
        if choices.contains(effort) { return effort }
        return choices.contains(.medium) ? .medium : choices[0]
    }

    /// Keeps the newest concrete model in each family and drops aliases superseded by a versioned model.
    func newestVersionPerFamily() -> [ConversationModelOption] {
        let visibleModels = filter { $0.id.caseInsensitiveCompare("default") != .orderedSame }
        var newestVersions: [String: VersionedModel] = [:]
        for model in visibleModels {
            guard let version = ModelVersion(id: model.id) else { continue }
            guard let current = newestVersions[version.family] else {
                newestVersions[version.family] = VersionedModel(id: model.id, version: version)
                continue
            }
            if version.isPreferred(over: current.version, id: model.id, otherID: current.id) {
                newestVersions[version.family] = VersionedModel(id: model.id, version: version)
            }
        }
        var retainedFamilies = Set<String>()
        return visibleModels.filter { model in
            let family = ModelVersion.familyName(for: model.id)
            if let newest = newestVersions[family] {
                guard model.id == newest.id else { return false }
                return retainedFamilies.insert(family).inserted
            }
            guard !ModelVersion.isAlias(model.id) else { return false }
            return retainedFamilies.insert(family).inserted
        }
    }

    /// The entry that supersedes a remembered selection the filtered list no longer
    /// offers, so a saved choice such as `claude-opus-5` follows its family forward
    /// instead of silently continuing to run an older model than the picker shows.
    /// Returns nil when the selection is still offered or the family only moved backwards.
    ///
    /// Only a strictly higher version number moves a selection, not merely a preferred
    /// one. That protects a dated snapshot such as `claude-opus-5-5-20251001`, which only
    /// the CLI can select: its family's undated `claude-opus-5-5` carries the same numbers
    /// and so leaves the pin in place, while a genuinely newer `claude-opus-6` still wins.
    /// The mirror case holds a selection still: an undated ID whose family now offers only
    /// a same-numbered snapshot stays put, unofferable but never silently re-pointed.
    ///
    /// Callers pass a `newestVersionPerFamily()` result, which holds one entry per
    /// family; the newest-of-family pick below keeps the answer well defined on a raw
    /// provider list too.
    func supersedingModel(forSelectedID selectedID: String) -> ConversationModelOption? {
        guard !selectedID.isEmpty, !contains(where: { $0.id == selectedID }) else { return nil }
        let family = ModelVersion.familyName(for: selectedID)
        let candidates = compactMap { model -> (ConversationModelOption, ModelVersion)? in
            guard ModelVersion.familyName(for: model.id) == family,
                  let version = ModelVersion(id: model.id) else { return nil }
            return (model, version)
        }
        guard let (candidate, candidateVersion) = candidates.max(by: {
            $1.1.isPreferred(over: $0.1, id: $1.0.id, otherID: $0.0.id)
        }) else { return nil }
        // A selection with no parseable version is a bare alias left by an older
        // Playhouse release, such as `opus`. There is nothing to compare, and the
        // family's offered entry is exactly what that alias used to mean, so it
        // always migrates rather than lingering as an ID the picker cannot show.
        guard let selectedVersion = ModelVersion(id: selectedID) else { return candidate }
        return selectedVersion.numbers.lexicographicallyPrecedes(candidateVersion.numbers) ? candidate : nil
    }
}

private struct VersionedModel {
    let id: String
    let version: ModelVersion
}

/// A model ID split into its family name and numeric version, such as `gpt-sol` and `[6, 1]` for `gpt-6.1-sol`.
private struct ModelVersion {
    let family: String
    let numbers: [Int]
    let snapshotDate: Int?

    var isSnapshot: Bool { snapshotDate != nil }

    init?(id: String) {
        var familyTokens: [String] = []
        var numbers: [Int] = []
        var snapshotDate: Int?
        for token in id.lowercased().split(separator: "-") {
            // Eight-digit date stamps such as `20251001` identify a snapshot, not a version.
            if token.count == 8, token.allSatisfy({ $0.isASCII && $0.isNumber }) {
                snapshotDate = Int(token)
                continue
            }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            if !parts.isEmpty, parts.allSatisfy({ $0 != nil }) {
                numbers += parts.compactMap { $0 }
            } else {
                familyTokens.append(String(token))
            }
        }
        guard !numbers.isEmpty else { return nil }
        if familyTokens.first == "claude" { familyTokens.removeFirst() }
        self.family = familyTokens.joined(separator: "-")
        self.numbers = numbers
        self.snapshotDate = snapshotDate
    }

    static func familyName(for id: String) -> String {
        guard let version = ModelVersion(id: id) else {
            let tokens = id.lowercased().split(separator: "-").map(String.init)
            return tokens.first == "claude" ? tokens.dropFirst().joined(separator: "-") : tokens.joined(separator: "-")
        }
        return version.family
    }

    /// Only reachable for a provider release that reports a bare alias with no
    /// resolved model at all. An alias that names its resolved model arrives here
    /// already keyed on that concrete ID, so it is compared by version like any
    /// other entry rather than being dropped as unversioned.
    ///
    /// The list is deliberately narrow: an unlisted bare alias is retained rather
    /// than hidden. `scripts/test-live-integration.py` asserts against the same set.
    static func isAlias(_ id: String) -> Bool {
        let normalizedID = id.lowercased().hasPrefix("claude-") ? String(id.dropFirst("claude-".count)).lowercased() : id.lowercased()
        return ["opus", "sonnet", "haiku", "default"].contains(normalizedID)
    }

    func isPreferred(over other: ModelVersion, id: String, otherID: String) -> Bool {
        if numbers != other.numbers { return other.numbers.lexicographicallyPrecedes(numbers) }
        switch (snapshotDate, other.snapshotDate) {
        case (nil, .some): return true
        case (.some, nil): return false
        case let (.some(date), .some(otherDate)) where date != otherDate: return date > otherDate
        default: return id.localizedStandardCompare(otherID) == .orderedAscending
        }
    }
}

/// A divider shown where a task's conversation moved to another provider.
struct ConversationProviderBoundary: Codable, Equatable, Identifiable {
    let id: String
    let provider: ConversationProvider
    /// The message the divider follows; nil places it before the first message.
    let afterMessageID: String?
}

/// One turn's token cost together with the tools, skills, MCP servers and
/// subagents that ran in it.
///
/// Neither runtime attributes tokens to an individual tool call — usage is
/// reported once per turn — so the turn is the unit Playhouse records, and the
/// tool labels say what that turn's tokens were spent on.
struct ConversationTurnUsageReport: Sendable {
    let turnID: String?
    let usage: ConversationTokenUsage
    let toolLabels: [String]
    /// Set for a live per-model-call update, which carries no turn usage of its own.
    var liveCall: ConversationLiveCall?

    init(turnID: String?, usage: ConversationTokenUsage, toolLabels: [String], liveCall: ConversationLiveCall? = nil) {
        self.turnID = turnID
        self.usage = usage
        self.toolLabels = toolLabels
        self.liveCall = liveCall
    }
}

/// A change in one agent's call usage, reported as the provider streams it.
///
/// A delta rather than a running total so the recorder can add it to whatever a
/// resumed session already holds. `agentID` is nil for the main agent.
struct ConversationLiveCall: Sendable, Equatable {
    var agentID: String?
    var calls: Int
    var sentTokens: Int
    var outputTokens: Int
    var uncachedInputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    /// The context size of this call, for the main agent's final transcript size.
    var contextTokens: Int
}

/// A task's token accounting: the running totals, the per-turn detail behind
/// them, and what each tool took part in.
struct TaskTokenUsageSummary: Codable, Equatable {
    struct Turn: Codable, Equatable, Identifiable {
        let id: String
        let provider: ConversationProvider
        let recordedAt: Date
        let usage: ConversationTokenUsage
        let tools: [String]
        /// Stored rather than computed so the CLI payload carries it too.
        let totalTokens: Int

        init(id: String, provider: ConversationProvider, recordedAt: Date, usage: ConversationTokenUsage, tools: [String]) {
            self.id = id
            self.provider = provider
            self.recordedAt = recordedAt
            self.usage = usage
            self.tools = tools
            totalTokens = usage.totalTokens
        }
    }

    /// A tool, skill, MCP server or subagent, with the turns it ran in.
    ///
    /// `totalTokens` is what those turns cost in full, not what the tool alone
    /// cost: neither provider reports usage below turn granularity, so a turn
    /// that ran several tools counts toward each of them.
    struct Tool: Codable, Equatable, Identifiable {
        let id: String
        let turnCount: Int
        let totalTokens: Int
    }

    /// Model-call accounting across the main agent and every subagent. The
    /// CLI payload carries it as-is, so `available` tells a task with no
    /// recorded calls apart from one that really sent zero tokens.
    struct CallUsage: Codable, Equatable {
        struct Agent: Codable, Equatable {
            let calls: Int
            let sentTokens: Int
            let outputTokens: Int
            let finalTranscriptTokens: Int
            /// Uncached input + cache writes + output; nil when recorded before the cache split.
            let tokensExcludingCacheReads: Int?
        }
        struct Subagents: Codable, Equatable {
            let count: Int
            let calls: Int
            let sentTokens: Int
            let outputTokens: Int
            let tokensExcludingCacheReads: Int?
        }
        let available: Bool
        let finalTranscriptTokens: Int
        let totalSentTokens: Int
        let totalCalls: Int
        let totalOutputTokens: Int
        /// Uncached input + cache writes + output, subagents included; nil when
        /// any call was recorded before the cache split was stored.
        let totalTokensExcludingCacheReads: Int?
        let mainAgent: Agent
        let subagents: Subagents

        init(snapshots: [ConversationCallUsageSnapshot]) {
            let active = snapshots.filter { $0.totalCalls > 0 }
            let main = active.reduce(ConversationCallUsage()) { $0 + $1.main }
            let subs = active.flatMap { $0.subagents.values }
            available = !active.isEmpty
            finalTranscriptTokens = active.filter { !$0.main.isEmpty }.max { $0.updatedAt < $1.updatedAt }?.main.lastContextTokens ?? 0
            totalSentTokens = active.reduce(0) { $0 + $1.totalSentTokens }
            totalCalls = active.reduce(0) { $0 + $1.totalCalls }
            totalOutputTokens = active.reduce(0) { $0 + $1.totalOutputTokens }
            let hasSplit = !active.isEmpty && active.allSatisfy(\.hasCacheSplit)
            totalTokensExcludingCacheReads = hasSplit ? active.reduce(0) { $0 + $1.totalTokensExcludingCacheReads } : nil
            mainAgent = Agent(
                calls: main.calls, sentTokens: main.sentTokens, outputTokens: main.outputTokens, finalTranscriptTokens: finalTranscriptTokens,
                tokensExcludingCacheReads: hasSplit ? main.tokensExcludingCacheReads : nil
            )
            subagents = Subagents(
                count: subs.count,
                calls: subs.reduce(0) { $0 + $1.calls },
                sentTokens: subs.reduce(0) { $0 + $1.sentTokens },
                outputTokens: subs.reduce(0) { $0 + $1.outputTokens },
                tokensExcludingCacheReads: hasSplit ? subs.reduce(0) { $0 + $1.tokensExcludingCacheReads } : nil
            )
        }
    }

    let taskID: UUID
    let usage: ConversationTokenUsage
    let turns: [Turn]
    let tools: [Tool]
    let callUsage: CallUsage
    let contextCompactions: [ContextCompactionEvent]
    let promptCacheMisses: [PromptCacheMissEvent]
    /// Stored rather than computed so the CLI payload carries it too.
    let totalTokens: Int
    /// Uncached input + cache writes + output. Includes subagents when call
    /// usage with the cache split exists; otherwise the turn-level buckets.
    let tokensExcludingCacheReads: Int

    var turnCount: Int { turns.count }

    init(taskID: UUID, usage: ConversationTokenUsage, turns: [Turn], tools: [Tool], callUsage: CallUsage, contextCompactions: [ContextCompactionEvent] = [], promptCacheMisses: [PromptCacheMissEvent] = []) {
        self.taskID = taskID
        self.usage = usage
        self.turns = turns
        self.tools = tools
        self.callUsage = callUsage
        self.contextCompactions = contextCompactions
        self.promptCacheMisses = promptCacheMisses
        totalTokens = usage.totalTokens
        tokensExcludingCacheReads = callUsage.totalTokensExcludingCacheReads ?? usage.totalTokens - usage.cacheReadTokens
    }
}
