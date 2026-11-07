import Darwin
import Foundation

extension ConversationProvider {
    /// The model Playhouse requests when the user hasn't picked one.
    var defaultModelID: String {
        switch self {
        case .codex: CodexAppServerClient.modelID
        case .claude: ClaudeCodeClient.preferredDefaultModelID
        }
    }

    /// A fast model for one-shot helper turns such as title generation.
    var titleModelID: String {
        switch self {
        case .codex: CodexAppServerClient.modelID
        case .claude: ClaudeCodeClient.titleModelID
        }
    }

    var defaultModelName: String {
        switch self {
        case .codex: "GPT-6 Luna"
        case .claude: "Default"
        }
    }

    /// The short name shown above assistant messages, derived from the model
    /// that produced the message.
    func assistantLabel(modelName: String?) -> String {
        switch self {
        case .codex:
            guard let modelName else { return "Codex" }
            let shortName = modelName.split(separator: " ").last.map(String.init) ?? modelName
            return "Codex · \(shortName)"
        case .claude:
            return modelName.map { "Claude · \($0)" } ?? "Claude"
        }
    }

    /// Goals are a Codex app-server feature with no Claude Code equivalent.
    var supportsGoals: Bool { self == .codex }

    static func parse(_ value: String) throws -> ConversationProvider {
        guard let provider = ConversationProvider(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Unknown conversation provider '\(value)'. Valid providers: \(allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return provider
    }
}

enum ConversationRole: String, Codable, Equatable {
    case user
    case assistant
}

/// Stand-ins the daemon puts in history for prompts Playhouse sends on its own (a recovery
/// turn applying a saved answer, an outcome reminder). They are not something the user
/// said, so the transcript must not treat them as the start of a conversation turn.
enum PrivatePromptPlaceholder {
    static let recoveryAnswer = "[Private answer sent after restart]"
    static let outcomeReminder = "[Playhouse private outcome reminder hidden]"

    static func matches(_ text: String) -> Bool {
        text == recoveryAnswer || text.contains(outcomeReminder)
    }
}

/// Prompts Playhouse sends to the agent on its own (status nudges, pull request fixes). The
/// conversation shows them, but as automatic messages rather than something the user wrote.
enum PlayhouseSentMessage {
    static let pullRequestAutopilotMarker = "Playhouse autopilot:"
    static let pullRequestConflicts = "The PR has conflicts. Fix them, commit, and push."
    static let pullRequestConflictsRetry = "The PR still has conflicts or your latest commit has not reached GitHub. Resolve the remaining conflicts, commit, and push. Verify the PR's merge status before finishing."

    static func matches(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return PrivateOutcomeNudgeMarker.matches(trimmed)
            || trimmed.hasPrefix(pullRequestAutopilotMarker)
            || trimmed == pullRequestConflicts
            || trimmed == pullRequestConflictsRetry
    }

    /// The text shown in the automatic message: a nudge's marker line only identifies it.
    static func displayText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PrivateOutcomeNudgeMarker.matches(trimmed) else { return trimmed }
        return trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ConversationMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: ConversationRole
    var createdAt: Date?
    var text: String
    var imageDataURLs: [String]
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

    private enum CodingKeys: String, CodingKey { case id, role, createdAt, text, imageDataURLs, phase, turnID, timelineOrder, asyncQuestions, provider, modelID }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(ConversationRole.self, forKey: .role)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        imageDataURLs = try container.decodeIfPresent([String].self, forKey: .imageDataURLs) ?? []
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
    /// Stored rather than computed so the CLI payload carries it too.
    let totalTokens: Int
    /// Uncached input + cache writes + output. Includes subagents when call
    /// usage with the cache split exists; otherwise the turn-level buckets.
    let tokensExcludingCacheReads: Int

    var turnCount: Int { turns.count }

    init(taskID: UUID, usage: ConversationTokenUsage, turns: [Turn], tools: [Tool], callUsage: CallUsage) {
        self.taskID = taskID
        self.usage = usage
        self.turns = turns
        self.tools = tools
        self.callUsage = callUsage
        totalTokens = usage.totalTokens
        tokensExcludingCacheReads = callUsage.totalTokensExcludingCacheReads ?? usage.totalTokens - usage.cacheReadTokens
    }
}

/// The operations Playhouse's shared conversation orchestration needs from a
/// provider runtime. Codex and Claude Code each implement it over their own
/// native protocol; history composition and persistence stay in the manager.
@MainActor
/// The callbacks a provider reports one turn through, as `sendMessage` takes them. A turn
/// this daemon reattached after a restart reports through the same set.
struct ConversationTurnCallbacks {
    let onDelta: (String) -> Void
    let onFinalMessage: (String) -> Void
    let onActivity: (ConversationActivity) -> Void
    let onDiff: (ConversationTurnDiff) -> Void
    let onHistory: (ConversationHistory) -> Void
    let onActionRequest: () -> Void
    let onUserInput: (ConversationUserInputRequest) async -> Void
    let onSteerMessage: (String, [String]) -> Void
    let onProgressMessage: (ConversationMessage) -> Void
    let onTurnStarted: (String) -> Void
    let onTokenUsage: (ConversationTurnUsageReport) -> Void
}

/// What a daemon found when it went back to a turn that was running when its predecessor died.
enum ConversationReattachResult: Equatable {
    /// The provider has no running turn for the conversation.
    case notRunning
    /// The turn ended, now or while no daemon was connected; its result is in history.
    case finished
    /// The agent that ran the turn is gone without finishing it.
    case agentGone
}

protocol ConversationProviderClient: AnyObject {
    var provider: ConversationProvider { get }
    var wasLastTurnInterrupted: Bool { get }
    var isPreparingForApplicationTermination: Bool { get }
    var lastTurnActivityDurations: [String: Int] { get }

    /// The most recent turn result for one conversation. Providers that can run
    /// conversations in parallel must answer per thread, not for the client.
    func wasLastTurnInterrupted(threadID: String) -> Bool
    func lastTurnActivityDurations(threadID: String) -> [String: Int]

    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String]
    /// Diagnostics for one conversation's turn. A runtime that can run several
    /// turns at once must not report another conversation's process or turn.
    func diagnosticFields(forThread threadID: String, _ additionalFields: [String: String]) -> [String: String]
    func startThread(workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?) async throws -> String
    func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption]
    func validateEffort(_ effort: ConversationEffort, modelID: String, workspace: ConversationWorkspaceContext) async throws
    func sendMessage(
        _ text: String,
        imageDataURLs: [String],
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        sessionRecoveryContext: String?,
        developerInstructions: String?,
        onDelta: @escaping (String) -> Void,
        onFinalMessage: @escaping (String) -> Void,
        onActivity: @escaping (ConversationActivity) -> Void,
        onDiff: @escaping (ConversationTurnDiff) -> Void,
        onHistory: @escaping (ConversationHistory) -> Void,
        onActionRequest: @escaping () -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void,
        onSteerMessage: @escaping (String, [String]) -> Void,
        onProgressMessage: @escaping (ConversationMessage) -> Void,
        onTurnStarted: @escaping (String) -> Void,
        onTokenUsage: @escaping (ConversationTurnUsageReport) -> Void,
        sensitiveUserInputAnswerValues: [String],
        hideSensitiveRecoveryPrompt: Bool
    ) async throws
    /// Follows a turn of `threadID` that kept running while the daemon restarted, reporting
    /// through `callbacks` until it ends. `onAttached` runs once the turn is registered as this
    /// daemon's own (or was found settled), before the wait.
    func followReattachedTurn(
        threadID: String,
        workspace: ConversationWorkspaceContext,
        callbacks: ConversationTurnCallbacks,
        onAttached: @escaping () -> Void
    ) async throws -> ConversationReattachResult
    func interruptActiveTurn(threadID: String) async throws -> Bool
    func steerActiveTurn(threadID: String, text: String, imageDataURLs: [String]) async throws -> Bool
    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool
    func rejectUserInput(requestID: String, threadID: String, message: String)
    func isTurnActive(threadID: String) -> Bool
    func isTurnActiveInProcess(threadID: String) -> Bool
    func canInterruptActiveTurn(threadID: String) -> Bool
    func activeTurnOwnerProcessID(threadID: String) -> Int32?
    func markTurnStarting(threadID: String)
    func clearTurnStarting(threadID: String)
    func beginConversationOperation()
    func finishConversationOperation()
    func prepareForApplicationTermination() async
    func shutdown()
    /// A separate client for one-shot helper turns such as title generation.
    func makeAuxiliaryClient() -> ConversationProviderClient
    /// Whether an error means this provider can't run here at all (not
    /// installed, can't start, or not signed in), rather than a failed turn.
    func isProviderUnavailable(_ error: Error) -> Bool
}

extension ConversationProviderClient {
    func validateEffort(_ effort: ConversationEffort, modelID: String, workspace: ConversationWorkspaceContext) async throws {}

    func diagnosticFields() -> [String: String] { diagnosticFields([:]) }

    /// A runtime that runs one turn at a time already describes that turn.
    func diagnosticFields(forThread threadID: String, _ additionalFields: [String: String]) -> [String: String] {
        diagnosticFields(additionalFields)
    }

    /// A runtime that runs one turn at a time has only one last turn to report.
    func wasLastTurnInterrupted(threadID: String) -> Bool { wasLastTurnInterrupted }

    func lastTurnActivityDurations(threadID: String) -> [String: Int] { lastTurnActivityDurations }

    func sendMessage(
        _ text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort = .medium,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        sessionRecoveryContext: String? = nil,
        developerInstructions: String? = nil,
        onFinalMessage: @escaping (String) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws {
        try await sendMessage(
            text, imageDataURLs: imageDataURLs, mode: mode, modelID: modelID, effort: effort, threadID: threadID,
            workspace: workspace, sessionRecoveryContext: sessionRecoveryContext, developerInstructions: developerInstructions,
            onDelta: { _ in }, onFinalMessage: onFinalMessage, onActivity: { _ in }, onDiff: { _ in },
            onHistory: { _ in }, onActionRequest: {}, onUserInput: onUserInput,
            onSteerMessage: { _, _ in }, onProgressMessage: { _ in }, onTurnStarted: { _ in },
            onTokenUsage: { _ in },
            sensitiveUserInputAnswerValues: [], hideSensitiveRecoveryPrompt: false
        )
    }
}

/// What a window needs to know about the turns the bridge daemon is running,
/// so it can show progress, questions, and goal changes without owning any
/// provider process itself.
/// Delivers a provider child process's output and exit to a main-actor
/// consumer in arrival order without parking a dispatch thread per chunk.
///
/// The previous design ran one dispatch block per read that blocked on a
/// semaphore until the main actor had consumed the chunk. A handler that never
/// returned then held that worker thread forever, and once enough had piled up
/// no provider's output was read at all; at EOF the readability source also
/// kept enqueueing blocks, which is how the daemon grew to tens of gigabytes.
/// Here the producers only append under a lock and a single main-actor drain
/// consumes sequentially, so a slow handler delays its own client only.
final class ProviderOutputPump: @unchecked Sendable {
    enum Item {
        case output(Data)
        case exit(Process)
        /// A provider this daemon didn't spawn as a `Process` stopped: an agent that outlives
        /// its daemon exited (with its wait status when it was this daemon's child), or the
        /// connection to a shared server closed.
        case ended(Int32?)
    }

    private let label: String
    private let consume: @MainActor (Item) async -> Void
    private let lock = NSLock()
    private var items: [Item] = []
    private var isDraining = false

    init(label: String, consume: @escaping @MainActor (Item) async -> Void) {
        self.label = label
        self.consume = consume
    }

    /// Serializes the producers' reads with their pushes, so output a
    /// readability callback is reading cannot land after the exit the
    /// termination handler pushes.
    func push(_ item: Item) {
        lock.lock()
        items.append(item)
        let startDrain = !isDraining
        if startDrain { isDraining = true }
        lock.unlock()
        guard startDrain else { return }
        Task { @MainActor in await self.drain() }
    }

    /// Runs `read` and pushes its result atomically with respect to other pushes.
    func pushReading(_ read: () -> Item?) {
        lock.lock()
        let item = read()
        if let item { items.append(item) }
        let startDrain = item != nil && !isDraining
        if startDrain { isDraining = true }
        lock.unlock()
        guard startDrain else { return }
        Task { @MainActor in await self.drain() }
    }

    /// Removes the next queued item, or clears `isDraining` when the queue is empty.
    /// Kept synchronous because `NSLock` cannot be used from async contexts.
    private func popNextOrFinishDraining() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard !items.isEmpty else {
            isDraining = false
            return nil
        }
        return items.removeFirst()
    }

    @MainActor
    private func drain() async {
        while let next = popNextOrFinishDraining() {
            // Reports a handler that has not returned after ten seconds while it
            // is still stuck, since one that never returns would otherwise leave
            // no trace of what it was handling.
            let head: String
            switch next {
            case .output(let data): head = String(decoding: data.prefix(200), as: UTF8.self)
            case .exit(let process): head = "exit status \(process.terminationStatus)"
            case .ended(let status): head = "ended \(status.map(String.init) ?? "")"
            }
            let label = label
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                PlayhouseDiagnostics.record("provider.output.handling_stalled", fields: ["provider": label, "head": head])
            }
            await consume(next)
            watchdog.cancel()
        }
    }

    /// Every byte a closed pipe still holds, without blocking.
    nonisolated static func readAvailableBytes(from descriptor: Int32) -> Data {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, 0) > 0, pollDescriptor.revents & Int16(POLLIN) != 0 else { break }
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            collected.append(buffer, count: count)
        }
        return collected
    }
}

struct ConversationRuntimeSnapshot: Codable, Equatable {
    struct Goal: Codable, Equatable {
        var stateThreadID: String?
        var stateRevision = 0
        var turnRevision = 0
        var turnCompletedRevision = 0
        var turnCompletedTurnID: String?
        var turnStartedThreadID: String?
        var observedThreadIDs: [String] = []
    }

    /// Sorted, so equal snapshots compare equal.
    var activeThreadIDs: [String] = []
    /// The active conversations whose turn can be paused right now.
    var interruptibleThreadIDs: [String] = []
    /// Conversations whose most recent turn was paused rather than finished.
    var interruptedThreadIDs: [String] = []
    var pendingUserInput: [String: ConversationUserInputRequest] = [:]
    /// See `ConversationManager.visibleRevisions`, keyed by task ID.
    var conversationRevisions: [String: Int] = [:]
    var goal = Goal()

    func isTurnActive(threadID: String) -> Bool { activeThreadIDs.contains(threadID) }
    func canInterruptActiveTurn(threadID: String) -> Bool { interruptibleThreadIDs.contains(threadID) }
    func wasLastTurnInterrupted(threadID: String) -> Bool { interruptedThreadIDs.contains(threadID) }

    /// The part of the snapshot about one task: its conversation revision and the turn state of
    /// its threads. Two slices differ whenever something that task's conversation reads from the
    /// snapshot changed. The goal state is kept whole, as the conversation always read it: only a
    /// window's own Goal turns change it, so it costs no re-render while other tasks work.
    func slice(taskID: String, threadIDs: Set<String>) -> ConversationRuntimeSnapshot {
        var slice = ConversationRuntimeSnapshot()
        slice.activeThreadIDs = activeThreadIDs.filter(threadIDs.contains)
        slice.interruptibleThreadIDs = interruptibleThreadIDs.filter(threadIDs.contains)
        slice.interruptedThreadIDs = interruptedThreadIDs.filter(threadIDs.contains)
        slice.pendingUserInput = pendingUserInput.filter { threadIDs.contains($0.key) }
        slice.conversationRevisions = conversationRevisions.filter { $0.key == taskID }
        slice.goal = goal
        return slice
    }

    /// `dataDirectory` limits the snapshot to the clients serving that data
    /// directory. Debug/test requests carry one so that two isolated stores
    /// in the same daemon never see each other's turns; production requests
    /// carry none and see every client.
    @MainActor
    static func current(dataDirectory: String? = nil) -> ConversationRuntimeSnapshot {
        let scope = dataDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var snapshot = ConversationRuntimeSnapshot()
        var active = Set<String>()
        var interruptible = Set<String>()
        var interrupted = Set<String>()
        for client in CodexAppServerClient.allSharedClients where scope == nil || client.runtimeScope == scope {
            active.formUnion(client.activeThreadIDsSnapshot)
            interruptible.formUnion(client.activeThreadIDsSnapshot.filter { client.canInterruptActiveTurn(threadID: $0) })
            interrupted.formUnion(client.interruptedThreadIDsSnapshot)
            snapshot.pendingUserInput.merge(client.pendingUserInputsSnapshot) { current, _ in current }
            guard client.goalRuntimeEnabled else { continue }
            snapshot.goal.stateThreadID = client.goalStateThreadID
            snapshot.goal.stateRevision = client.goalStateRevision
            snapshot.goal.turnRevision = client.goalTurnRevision
            snapshot.goal.turnCompletedRevision = client.goalTurnCompletedRevision
            snapshot.goal.turnCompletedTurnID = client.goalTurnCompletedTurnID
            snapshot.goal.turnStartedThreadID = client.goalTurnStartedThreadID
            snapshot.goal.observedThreadIDs = client.observedGoalThreadIDs
        }
        for client in ClaudeCodeClient.allSharedPrimaryClients where scope == nil || client.runtimeScope == scope {
            active.formUnion(client.activeThreadIDsSnapshot)
            interruptible.formUnion(client.activeThreadIDsSnapshot.filter { client.canInterruptActiveTurn(threadID: $0) })
            interrupted.formUnion(client.interruptedThreadIDsSnapshot)
            snapshot.pendingUserInput.merge(client.pendingUserInputsSnapshot) { current, _ in current }
        }
        snapshot.conversationRevisions = Dictionary(uniqueKeysWithValues: ConversationManager.visibleRevisions.map { ($0.key.uuidString, $0.value) })
        snapshot.activeThreadIDs = active.sorted()
        snapshot.interruptibleThreadIDs = interruptible.sorted()
        snapshot.interruptedThreadIDs = interrupted.sorted()
        return snapshot
    }

    /// Emits the snapshot now and again whenever it changes, until the
    /// consumer stops iterating. Provider state is in this process's memory, so
    /// sampling it is cheap and needs no cross-process signalling.
    @MainActor
    static func changes(dataDirectory: String? = nil) -> AsyncStream<ConversationRuntimeSnapshot> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                var last: ConversationRuntimeSnapshot?
                while !Task.isCancelled {
                    let snapshot = current(dataDirectory: dataDirectory)
                    if snapshot != last {
                        last = snapshot
                        continuation.yield(snapshot)
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Live CPU usage of each turn-active task, keyed by thread/session ID. A
/// Claude task owns its own Claude Code process, so its value is that
/// process tree's load. Codex multiplexes every task's turns inside one
/// shared `app-server` process, so a Codex task's value is the share of that
/// app-server's tree attributed to it by working directory (see
/// `CodexProcessAttribution`).
struct TaskCPUUsageSnapshot: Codable, Equatable {
    var percentByThreadID: [String: Double] = [:]

    /// See `ConversationRuntimeSnapshot.current(dataDirectory:)` for why
    /// `dataDirectory` scopes the snapshot to one isolated client set.
    @MainActor
    static func current(dataDirectory: String? = nil) async -> TaskCPUUsageSnapshot {
        let scope = dataDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var pidsByThreadID: [String: pid_t] = [:]
        for client in ClaudeCodeClient.allSharedPrimaryClients where scope == nil || client.runtimeScope == scope {
            pidsByThreadID.merge(client.activeProcessIdentifiersByThreadID) { current, _ in current }
        }
        var snapshot = TaskCPUUsageSnapshot()
        for (threadID, pid) in pidsByThreadID {
            if let percent = await TaskCPUUsageSampler.shared.sample(threadID: threadID, rootPID: pid) {
                snapshot.percentByThreadID[threadID] = percent
            }
        }
        for client in CodexAppServerClient.allSharedClients where scope == nil || client.runtimeScope == scope {
            guard let pid = client.appServerProcessIdentifier else { continue }
            let percents = await TaskCPUUsageSampler.shared.sampleCodexAppServer(
                rootPID: pid, rootsByThreadID: client.activeThreadWorkspaceRootsByThreadID
            )
            snapshot.percentByThreadID.merge(percents) { current, _ in current }
        }
        return snapshot
    }

    /// Emits a CPU snapshot every few seconds, yielding only on change.
    /// Sampled far less often than `ConversationRuntimeSnapshot` (pure
    /// in-memory bookkeeping, cheap at 100ms) because walking process trees
    /// via libproc for every active task is materially more expensive and
    /// must not become a meaningful CPU cost on its own.
    @MainActor
    static func changes(dataDirectory: String? = nil) -> AsyncStream<TaskCPUUsageSnapshot> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                var last: TaskCPUUsageSnapshot?
                while !Task.isCancelled {
                    let snapshot = await current(dataDirectory: dataDirectory)
                    if snapshot != last {
                        last = snapshot
                        continuation.yield(snapshot)
                    }
                    try? await Task.sleep(for: .seconds(sampleIntervalSeconds))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let sampleIntervalSeconds: Double = 4
}

/// One client per provider, shared by a window or a single bridge request.
@MainActor
struct ConversationClients {
    let codex: CodexAppServerClient
    let claude: ClaudeCodeClient
    /// The shared skill gallery, which a turn's launch bridges to its provider.
    var skills: SkillCatalogManager? = nil

    func client(for provider: ConversationProvider) -> ConversationProviderClient {
        switch provider {
        case .codex: codex
        case .claude: claude
        }
    }

    var all: [ConversationProviderClient] { [codex, claude] }

    /// Separate clients for one-shot helper turns: the task's provider first,
    /// then the other provider for when the preferred one is unavailable.
    func helperClients(preferring provider: ConversationProvider) -> [ConversationProviderClient] {
        let preferred = client(for: provider)
        return [preferred.makeAuxiliaryClient()] + all.filter { $0.provider != provider }.map { $0.makeAuxiliaryClient() }
    }
}

private struct ConversationSteerMailboxRequest: Codable {
    let id: String
    let threadID: String
    let expectedTurnID: String
    let text: String
    var imageDataURLs: [String]? = []
    /// "interrupt" asks the owner to stop its turn; absent means steer.
    var kind: String? = nil
}

private struct ConversationSteerMailboxActiveTurn: Codable {
    let threadID: String
    let turnID: String
    let processID: Int32
}

private struct ConversationSteerMailboxResponse: Codable {
    let accepted: Bool
    let error: String?
}

struct ConversationSteerMailboxError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// File-based handoff that lets another Playhouse process (usually the CLI)
/// steer a turn owned by the app. The turn owner publishes its active turn
/// and services requests; any provider can use it because thread and session
/// IDs are globally unique.
@MainActor
enum ConversationSteerMailbox {
    private static var directory: URL?

    static func configure(directory: URL) {
        self.directory = directory
    }

    static func requestSteer(threadID: String, text: String, imageDataURLs: [String]) async throws -> Bool {
        try await request(threadID: threadID, text: text, imageDataURLs: imageDataURLs, kind: nil)
    }

    /// Asks the process that owns the thread's active turn to stop it.
    static func requestInterrupt(threadID: String) async throws -> Bool {
        try await request(threadID: threadID, text: "", imageDataURLs: [], kind: "interrupt")
    }

    private static func request(threadID: String, text: String, imageDataURLs: [String], kind: String?) async throws -> Bool {
        guard let directory else { return false }
        let activeURL = activeTurnURL(threadID: threadID, directory: directory)
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return false }
        let activeTurn = try JSONDecoder().decode(ConversationSteerMailboxActiveTurn.self, from: Data(contentsOf: activeURL))
        guard activeTurn.threadID == threadID else { return false }
        guard Darwin.kill(activeTurn.processID, 0) == 0 || errno == EPERM else {
            try? FileManager.default.removeItem(at: activeURL)
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = Darwin.chmod(directory.path, mode_t(0o700))
        let requestID = UUID().uuidString
        let requestURL = directory.appendingPathComponent("\(requestID).request.json")
        let responseURL = directory.appendingPathComponent("\(requestID).response.json")
        let request = ConversationSteerMailboxRequest(id: requestID, threadID: threadID, expectedTurnID: activeTurn.turnID, text: text, imageDataURLs: imageDataURLs, kind: kind)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        _ = Darwin.chmod(requestURL.path, mode_t(0o600))
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                let response = try JSONDecoder().decode(ConversationSteerMailboxResponse.self, from: Data(contentsOf: responseURL))
                if let error = response.error {
                    throw ConversationSteerMailboxError(message: error)
                }
                return response.accepted
            }
            if !FileManager.default.fileExists(atPath: activeURL.path) { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Answers pending requests for the owner's active turn. `steer` and
    /// `interrupt` return whether the runtime accepted the request; a thrown
    /// error is reported back.
    static func service(
        threadID: String,
        turnID: String,
        steer: (String, [String]) async throws -> Bool,
        interrupt: () async throws -> Bool
    ) async {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for requestURL in files where requestURL.lastPathComponent.hasSuffix(".request.json") {
            guard let request = try? JSONDecoder().decode(ConversationSteerMailboxRequest.self, from: Data(contentsOf: requestURL)),
                  request.threadID == threadID else { continue }
            let claimedURL = directory.appendingPathComponent("\(request.id).claimed.json")
            do { try FileManager.default.moveItem(at: requestURL, to: claimedURL) }
            catch { continue }
            let responseURL = directory.appendingPathComponent("\(request.id).response.json")
            let response: ConversationSteerMailboxResponse
            if request.expectedTurnID != turnID {
                response = ConversationSteerMailboxResponse(accepted: false, error: nil)
            } else {
                do {
                    let accepted = request.kind == "interrupt"
                        ? try await interrupt()
                        : try await steer(request.text, request.imageDataURLs ?? [])
                    response = ConversationSteerMailboxResponse(accepted: accepted, error: nil)
                } catch {
                    response = ConversationSteerMailboxResponse(accepted: false, error: error.localizedDescription)
                }
            }
            if let data = try? JSONEncoder().encode(response) {
                try? data.write(to: responseURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: claimedURL)
        }
    }

    static func publishActiveTurn(threadID: String, turnID: String) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = Darwin.chmod(directory.path, mode_t(0o700))
            let data = try JSONEncoder().encode(ConversationSteerMailboxActiveTurn(
                threadID: threadID,
                turnID: turnID,
                processID: Int32(ProcessInfo.processInfo.processIdentifier)
            ))
            let url = activeTurnURL(threadID: threadID, directory: directory)
            try data.write(to: url, options: .atomic)
            _ = Darwin.chmod(url.path, mode_t(0o600))
        } catch {
            PlayhouseDiagnostics.record("conversation.steer_mailbox.publish_failed", fields: ["threadID": threadID])
        }
    }

    static func clearActiveTurn(threadID: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: activeTurnURL(threadID: threadID, directory: directory))
    }

    /// The live process that published an active turn for this thread, if any.
    static func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        activeTurn(threadID: threadID)?.processID
    }

    static func activeTurnID(threadID: String) -> String? {
        activeTurn(threadID: threadID)?.turnID
    }

    private static func activeTurn(threadID: String) -> ConversationSteerMailboxActiveTurn? {
        guard let directory else { return nil }
        let activeURL = activeTurnURL(threadID: threadID, directory: directory)
        guard let active = try? JSONDecoder().decode(ConversationSteerMailboxActiveTurn.self, from: Data(contentsOf: activeURL)),
              active.threadID == threadID else { return nil }
        guard Darwin.kill(active.processID, 0) == 0 || errno == EPERM else {
            try? FileManager.default.removeItem(at: activeURL)
            return nil
        }
        return active
    }

    private static func activeTurnURL(threadID: String, directory: URL) -> URL {
        let key = threadID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("active-\(key).json")
    }
}

/// Shared child-process environment for provider CLIs.
@MainActor
enum ConversationProcessEnvironment {
    /// Lets a provider's child process run `playhouse` back into this app's service.
    /// The child inherits the launching process's environment (the GUI app or the
    /// bridge daemon), not the CLI caller's, so the service name and store directory
    /// must be passed on explicitly. The app identity is the same in both processes.
    ///
    /// `dataDirectoryOverride` must be the specific client instance's own resolved
    /// data directory (its construction-time `sharedClient`/`sharedPrimaryClient`
    /// cache-key input), not read from an ambient global: the bridge daemon is one
    /// long-lived process that can serve several isolated test data directories
    /// (debug/test builds only — production always has exactly one), and a shared
    /// mutable "current data directory" would let one request's child process pick
    /// up whichever directory a concurrently-running, unrelated request happened to
    /// set most recently.
    static func forwardPlayhouseBridgeEnvironment(_ environment: inout [String: String], dataDirectoryOverride: String? = nil) {
        if environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] == nil {
            environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = BridgeContract.serviceName(
                forApplication: PlayhouseAppIdentity.applicationIdentifier
            )
        }
        if let dataDirectoryOverride {
            environment["PLAYHOUSE_DATA_DIRECTORY"] = dataDirectoryOverride
        } else if environment["PLAYHOUSE_DATA_DIRECTORY"] == nil {
            environment["PLAYHOUSE_DATA_DIRECTORY"] = PlayhouseDiagnostics.storeURL.deletingLastPathComponent().path
        }
    }
}

/// A provider executable override is honored only inside a directory that a
/// Playhouse test fixture owns, so the environment can't redirect real turns.
enum ConversationProviderFixture {
    /// How to start an executable. A test's owned fixture script written by the
    /// sandboxed UI test runner is quarantined, and macOS refuses to exec a
    /// quarantined script directly, so such a script runs through its
    /// interpreter instead; its `argv[0]` stays the script path.
    static func launchCommand(executable: String, arguments: [String]) -> (executable: String, arguments: [String]) {
        guard getxattr(executable, "com.apple.quarantine", nil, 0, 0, 0) >= 0,
              let handle = FileHandle(forReadingAtPath: executable),
              let head = try? handle.read(upToCount: 256),
              let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              line.hasPrefix("#!") else { return (executable, arguments) }
        let shebang = line.dropFirst(2).split(separator: " ").map(String.init)
        guard let interpreter = shebang.first else { return (executable, arguments) }
        return (interpreter, Array(shebang.dropFirst()) + [executable] + arguments)
    }

    /// The override value that means this CLI is not installed: no fixture, and
    /// no fallback to the machine's own CLI. The test harness passes it for every
    /// provider a case does not install a fixture for, so no default test reaches
    /// a real CLI that happens to be on the machine.
    static let notInstalledOverride = "none"

    static func ownedExecutable(_ path: String?, providerMarker: (name: String, value: String)) -> String? {
        if path == notInstalledOverride { return notInstalledOverride }
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let markers = [providerMarker, (".playhouse-bridge-fixture", "Playhouse bridge tests own this deterministic fixture (v1).\n")]
        for (name, value) in markers {
            if (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) == value { return path }
        }
        return nil
    }
}

/// A model occasionally writes its final `playhouse-cli task outcome` command as
/// answer text instead of running it. A trailing echo of that command is removed
/// from the visible answer and still counts as the turn's reported outcome.
enum LeakedTurnOutcome {
    private static let pattern: NSRegularExpression = {
        let executable = NSRegularExpression.escapedPattern(for: TaskProgressReportInstructions.executableName)
        let subcommand = TaskProgressReportInstructions.outcomeSubcommand
            .split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        return try! NSRegularExpression(pattern:
            #"[\p{So}\x{FE0F}\s`]*\n[\p{So}\x{FE0F}\s`$>]*(?:'[^'\n]*|[^\s'`]*)"# + executable + #"'?\s+"# + subcommand
            + #"\s+([0-9A-Fa-f-]{36})\s+("#
            + TurnOutcome.allCases.map { NSRegularExpression.escapedPattern(for: $0.rawValue) }.joined(separator: "|")
            + #")[\s`.]*\z"#)
    }()

    static func split(_ text: String) -> (text: String, taskID: UUID?, outcome: String?) {
        // The leading newline lets an answer that is only the echoed command match too.
        let candidate = "\n" + text
        guard let match = pattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              let echo = Range(match.range, in: candidate),
              let id = Range(match.range(at: 1), in: candidate),
              let outcome = Range(match.range(at: 2), in: candidate) else {
            return (text, nil, nil)
        }
        let visible = candidate[..<echo.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (visible, UUID(uuidString: String(candidate[id])), String(candidate[outcome]))
    }

    static func visibleText(_ text: String) -> String { split(text).text }
}
