import Foundation

package struct ConversationMessage: Codable, Identifiable, Equatable {
    package let id: String
    package let role: ConversationRole
    package var createdAt: Date?
    package var text: String
    package var imageDataURLs: [String]
    /// True when the message has images that this read left out. A history read
    /// that defers images sets it; `ConversationManager.messageImages` returns them.
    package var imagesDeferred: Bool?
    package var phase: String?
    package var turnID: String?
    package var timelineOrder: Int?
    package var asyncQuestions: [ConversationAsyncQuestion]?
    /// The runtime that produced an assistant message, or received a user message.
    /// Nil for transcripts saved before Playhouse supported more than Codex.
    package var provider: ConversationProvider?
    /// Model selected when this message's turn was dispatched, when known.
    package var modelID: String?
    /// What this message's turn cost, set by a history read on the turn's last reply only
    /// (see `ConversationManager.attachingTurnTokenUsage`); never stored in the transcript.
    package var turnTokenUsage: ConversationTokenUsage?

    package init(id: String, role: ConversationRole, text: String, imageDataURLs: [String] = [], phase: String? = nil, turnID: String? = nil, timelineOrder: Int? = nil, asyncQuestions: [ConversationAsyncQuestion]? = nil, provider: ConversationProvider? = nil, createdAt: Date? = .now, modelID: String? = nil) {
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
    package var isPlayhouseSent: Bool { role == .user && PlayhouseSentMessage.matches(text) }

    /// Where the newest turn the user started begins: what a window opening the conversation shows first.
    /// `continuingIDs` names live messages that joined a running turn before history gave them its turn ID.
    package static func latestTurnStartIndex(in messages: [ConversationMessage], continuingIDs: Set<String> = []) -> Int? {
        // Prompts Playhouse sends on its own are not a turn the user started: anchoring the
        // window there would hide the conversation the recovery is continuing.
        // When redaction has replaced every user message, the placeholders are all there is to anchor on.
        messages.indices.last(where: { index in
            !PrivatePromptPlaceholder.matches(messages[index].text)
                && !PrivatePromptPlaceholder.isRecoveryAnswer(messages[index].text)
                && startsUserTurn(at: index, in: messages, continuingIDs: continuingIDs)
        })
            ?? messages.lastIndex(where: { $0.role == .user })
            ?? messages.indices.last
    }

    /// Whether the message at `index` is one the user sent to start a turn: not a prompt
    /// Playhouse sent on its own, and not a message that joined a turn already under way.
    package static func startsUserTurn(at index: Int, in messages: [ConversationMessage], continuingIDs: Set<String> = []) -> Bool {
        let message = messages[index]
        return message.role == .user && !message.isPlayhouseSent
            && !continuesTurn(at: index, in: messages, continuingIDs: continuingIDs)
    }

    /// Whether the user message at `index` joined a turn already under way, as a steer or a notice
    /// the provider's runtime adds does, rather than starting one. Such a message follows the work
    /// its turn did before it, so it never moves where that turn begins.
    package static func continuesTurn(at index: Int, in messages: [ConversationMessage], continuingIDs: Set<String> = []) -> Bool {
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

    private enum CodingKeys: String, CodingKey { case id, role, createdAt, text, imageDataURLs, imagesDeferred, phase, turnID, timelineOrder, asyncQuestions, provider, modelID, turnTokenUsage }
    package init(from decoder: Decoder) throws {
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
        turnTokenUsage = try container.decodeIfPresent(ConversationTokenUsage.self, forKey: .turnTokenUsage)
    }
}

package struct ConversationAsyncQuestion: Codable, Equatable {
    package let title: String
    package let options: [String]?

    package init(title: String, options: [String]?) {
        self.title = title
        self.options = options
    }
}

package struct ConversationUserQuestion: Identifiable, Codable, Equatable {
    package struct Option: Identifiable, Codable, Equatable {
        package let label: String
        package let description: String?
        package var id: String { label }

        package init(label: String, description: String?) {
            self.label = label
            self.description = description
        }
    }
    package let id: String
    package let header: String
    package let question: String
    package let options: [Option]
    package let allowsOther: Bool
    package let isSecret: Bool

    package init(id: String, header: String, question: String, options: [Option], allowsOther: Bool, isSecret: Bool) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.allowsOther = allowsOther
        self.isSecret = isSecret
    }
}

package struct ConversationUserInputRequest: Identifiable, Codable, Equatable {
    package let id: String
    package let threadID: String
    package let questions: [ConversationUserQuestion]
    package let isBlocking: Bool
    package let mode: ConversationMode

    package init(id: String, threadID: String, questions: [ConversationUserQuestion], isBlocking: Bool, mode: ConversationMode) {
        self.id = id
        self.threadID = threadID
        self.questions = questions
        self.isBlocking = isBlocking
        self.mode = mode
    }
}

package enum ConversationMode: String, CaseIterable, Hashable, Codable {
    case code = "default"
    case plan

    package var title: String {
        switch self {
        case .code: "Code mode"
        case .plan: "Plan mode"
        }
    }
}

package enum ConversationEffort: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh

    package var id: String { rawValue }
    package var title: String { rawValue == "xhigh" ? "Extra High" : rawValue.capitalized }
    package var sliderPosition: Double { Double(Self.allCases.firstIndex(of: self) ?? 1) }

    package static func from(sliderPosition: Double) -> ConversationEffort {
        allCases[min(max(Int(sliderPosition.rounded()), 0), allCases.count - 1)]
    }
}

package struct ConversationModelOption: Codable, Identifiable, Hashable {
    package let id: String
    package let name: String
    package let isDefault: Bool
    package var supportedEfforts: [ConversationEffort]? = nil

    package init(id: String, name: String, isDefault: Bool, supportedEfforts: [ConversationEffort]? = nil) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.supportedEfforts = supportedEfforts
    }
}

extension Array where Element == ConversationModelOption {
    /// The efforts `modelID` supports, or every effort when it doesn't say; an empty ID is the
    /// default model.
    package func effortChoices(for modelID: String) -> [ConversationEffort] {
        let model = modelID.isEmpty ? first(where: \.isDefault) : first(where: { $0.id == modelID })
        guard let supported = model?.supportedEfforts, !supported.isEmpty else { return ConversationEffort.allCases }
        return ConversationEffort.allCases.filter(supported.contains)
    }

    /// `effort`, or the effort a newly chosen model falls back to when it doesn't support it.
    package func effort(_ effort: ConversationEffort, keptFor modelID: String) -> ConversationEffort {
        let choices = effortChoices(for: modelID)
        if choices.contains(effort) { return effort }
        return choices.contains(.medium) ? .medium : choices[0]
    }

    /// Keeps the newest concrete model in each family and drops aliases superseded by a versioned model.
    package func newestVersionPerFamily() -> [ConversationModelOption] {
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
    package func supersedingModel(forSelectedID selectedID: String) -> ConversationModelOption? {
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
package struct ConversationProviderBoundary: Codable, Equatable, Identifiable {
    package let id: String
    package let provider: ConversationProvider
    /// The message the divider follows; nil places it before the first message.
    package let afterMessageID: String?

    package init(id: String, provider: ConversationProvider, afterMessageID: String?) {
        self.id = id
        self.provider = provider
        self.afterMessageID = afterMessageID
    }
}

/// One turn's token cost together with the tools, skills, MCP servers and
/// subagents that ran in it.
///
/// Neither runtime attributes tokens to an individual tool call — usage is
/// reported once per turn — so the turn is the unit Playhouse records, and the
/// tool labels say what that turn's tokens were spent on.
package struct ConversationTurnUsageReport: Sendable {
    package let turnID: String?
    package let usage: ConversationTokenUsage
    package let toolLabels: [String]
    /// Set for a live per-model-call update, which carries no turn usage of its own.
    package var liveCall: ConversationLiveCall?

    package init(turnID: String?, usage: ConversationTokenUsage, toolLabels: [String], liveCall: ConversationLiveCall? = nil) {
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
package struct ConversationLiveCall: Sendable, Equatable {
    package var agentID: String?
    package var calls: Int
    package var sentTokens: Int
    package var outputTokens: Int
    package var uncachedInputTokens: Int
    package var cacheReadTokens: Int
    package var cacheWriteTokens: Int
    /// The context size of this call, for the main agent's final transcript size.
    package var contextTokens: Int

    package init(agentID: String? = nil, calls: Int, sentTokens: Int, outputTokens: Int, uncachedInputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, contextTokens: Int) {
        self.agentID = agentID
        self.calls = calls
        self.sentTokens = sentTokens
        self.outputTokens = outputTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.contextTokens = contextTokens
    }
}

/// A task's token accounting: the running totals, the per-turn detail behind
/// them, and what each tool took part in.
package struct TaskTokenUsageSummary: Codable, Equatable {
    package struct Turn: Codable, Equatable, Identifiable {
        package let id: String
        package let provider: ConversationProvider
        package let recordedAt: Date
        package let usage: ConversationTokenUsage
        package let tools: [String]
        /// Stored rather than computed so the CLI payload carries it too.
        package let totalTokens: Int

        package init(id: String, provider: ConversationProvider, recordedAt: Date, usage: ConversationTokenUsage, tools: [String]) {
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
    package struct Tool: Codable, Equatable, Identifiable {
        package let id: String
        package let turnCount: Int
        package let totalTokens: Int

        package init(id: String, turnCount: Int, totalTokens: Int) {
            self.id = id
            self.turnCount = turnCount
            self.totalTokens = totalTokens
        }
    }

    /// Model-call accounting across the main agent and every subagent. The
    /// CLI payload carries it as-is, so `available` tells a task with no
    /// recorded calls apart from one that really sent zero tokens.
    package struct CallUsage: Codable, Equatable {
        package struct Agent: Codable, Equatable {
            package let calls: Int
            package let sentTokens: Int
            package let outputTokens: Int
            package let finalTranscriptTokens: Int
            /// Uncached input + cache writes + output; nil when recorded before the cache split.
            package let tokensExcludingCacheReads: Int?

            package init(calls: Int, sentTokens: Int, outputTokens: Int, finalTranscriptTokens: Int, tokensExcludingCacheReads: Int?) {
                self.calls = calls
                self.sentTokens = sentTokens
                self.outputTokens = outputTokens
                self.finalTranscriptTokens = finalTranscriptTokens
                self.tokensExcludingCacheReads = tokensExcludingCacheReads
            }
        }
        package struct Subagents: Codable, Equatable {
            package let count: Int
            package let calls: Int
            package let sentTokens: Int
            package let outputTokens: Int
            package let tokensExcludingCacheReads: Int?

            package init(count: Int, calls: Int, sentTokens: Int, outputTokens: Int, tokensExcludingCacheReads: Int?) {
                self.count = count
                self.calls = calls
                self.sentTokens = sentTokens
                self.outputTokens = outputTokens
                self.tokensExcludingCacheReads = tokensExcludingCacheReads
            }
        }
        package let available: Bool
        package let finalTranscriptTokens: Int
        package let totalSentTokens: Int
        package let totalCalls: Int
        package let totalOutputTokens: Int
        /// Uncached input + cache writes + output, subagents included; nil when
        /// any call was recorded before the cache split was stored.
        package let totalTokensExcludingCacheReads: Int?
        package let mainAgent: Agent
        package let subagents: Subagents

        package init(snapshots: [ConversationCallUsageSnapshot]) {
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

    package let taskID: UUID
    package let usage: ConversationTokenUsage
    package let turns: [Turn]
    package let tools: [Tool]
    package let callUsage: CallUsage
    package let contextCompactions: [ContextCompactionEvent]
    package let promptCacheMisses: [PromptCacheMissEvent]
    /// Stored rather than computed so the CLI payload carries it too.
    package let totalTokens: Int
    /// Uncached input + cache writes + output. Includes subagents when call
    /// usage with the cache split exists; otherwise the turn-level buckets.
    package let tokensExcludingCacheReads: Int

    package var turnCount: Int { turns.count }

    package init(taskID: UUID, usage: ConversationTokenUsage, turns: [Turn], tools: [Tool], callUsage: CallUsage, contextCompactions: [ContextCompactionEvent] = [], promptCacheMisses: [PromptCacheMissEvent] = []) {
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
