import Foundation
import Observation

/// Token counts a provider reported for one completed turn.
///
/// Both runtimes bill the same four buckets, so the breakdown is stored in
/// Playhouse's own shape rather than either provider's wire spelling. Defined
/// here rather than beside its other conversation-model siblings because
/// `scripts/seed-task-pr-link.swift` compiles this file and `BoardTask.swift`
/// standalone and must not gain a dependency on the rest of the app module.
package struct ConversationTokenUsage: Codable, Equatable, Sendable {
    package var inputTokens = 0
    package var outputTokens = 0
    package var cacheReadTokens = 0
    package var cacheCreationTokens = 0

    package var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    package var isEmpty: Bool { totalTokens == 0 }

    package static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens
        )
    }

    /// Reads a provider's `usage` object. Claude Code reports
    /// `input_tokens`/`cache_read_input_tokens`; the Codex app-server reports
    /// the same counts as `cached_input_tokens` and in camelCase, so both
    /// spellings are accepted for each bucket.
    package init(providerPayload: [String: Any]) {
        func count(_ names: [String]) -> Int {
            for name in names {
                if let value = providerPayload[name] as? Int { return max(0, value) }
                if let value = providerPayload[name] as? Double { return max(0, Int(value)) }
            }
            return 0
        }
        inputTokens = count(["input_tokens", "inputTokens"])
        outputTokens = count(["output_tokens", "outputTokens"])
        cacheReadTokens = count(["cache_read_input_tokens", "cacheReadInputTokens", "cached_input_tokens", "cachedInputTokens"])
        cacheCreationTokens = count(["cache_creation_input_tokens", "cacheCreationInputTokens"])
    }

    /// Reads a Codex usage object. Codex's input count already includes its
    /// cached and cache-written tokens, so those are moved out of `inputTokens`
    /// into their own buckets rather than being counted twice.
    package init(codexPayload: [String: Any]) {
        self.init(providerPayload: codexPayload)
        if let cacheWrite = codexPayload["cache_write_input_tokens"] as? Int ?? codexPayload["cacheWriteInputTokens"] as? Int {
            cacheCreationTokens = max(0, cacheWrite)
        }
        inputTokens = max(0, inputTokens - cacheReadTokens - cacheCreationTokens)
    }

    package init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }
}

/// Model-call counts for one agent (the main agent or one subagent).
///
/// `sentTokens` is everything a call re-sends (input + cache read + cache
/// write), summed over calls; `lastContextTokens` is that same figure for the
/// most recent call, i.e. how large the transcript had grown by then.
package struct ConversationCallUsage: Codable, Equatable, Sendable {
    package var calls = 0
    package var sentTokens = 0
    package var outputTokens = 0
    package var lastContextTokens = 0
    /// What `sentTokens` is made of. Cache reads bill at a fraction of normal
    /// input, so the split is what lets a total leave them out. Snapshots
    /// recorded before the split existed decode these as zero.
    package var uncachedInputTokens = 0
    package var cacheReadTokens = 0
    package var cacheWriteTokens = 0

    package init(
        calls: Int = 0, sentTokens: Int = 0, outputTokens: Int = 0, lastContextTokens: Int = 0,
        uncachedInputTokens: Int = 0, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0
    ) {
        self.calls = calls
        self.sentTokens = sentTokens
        self.outputTokens = outputTokens
        self.lastContextTokens = lastContextTokens
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calls = try container.decodeIfPresent(Int.self, forKey: .calls) ?? 0
        sentTokens = try container.decodeIfPresent(Int.self, forKey: .sentTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        lastContextTokens = try container.decodeIfPresent(Int.self, forKey: .lastContextTokens) ?? 0
        uncachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .uncachedInputTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
    }

    package var isEmpty: Bool { calls == 0 }
    /// Whether the cache split accounts for everything sent; false for calls
    /// recorded before the split was stored.
    package var hasCacheSplit: Bool { uncachedInputTokens + cacheReadTokens + cacheWriteTokens == sentTokens }
    /// Everything but the cache reads: uncached input, cache writes and output.
    package var tokensExcludingCacheReads: Int { uncachedInputTokens + cacheWriteTokens + outputTokens }

    package static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            calls: lhs.calls + rhs.calls,
            sentTokens: lhs.sentTokens + rhs.sentTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            lastContextTokens: rhs.isEmpty ? lhs.lastContextTokens : rhs.lastContextTokens,
            uncachedInputTokens: lhs.uncachedInputTokens + rhs.uncachedInputTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens
        )
    }

    /// Adds one model call.
    package mutating func addCall(usage: ConversationTokenUsage) {
        let sent = usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens
        calls += 1
        sentTokens += sent
        outputTokens += usage.outputTokens
        uncachedInputTokens += usage.inputTokens
        cacheReadTokens += usage.cacheReadTokens
        cacheWriteTokens += usage.cacheCreationTokens
        lastContextTokens = sent
    }
}

/// One provider session's (Claude) or root thread's (Codex) call usage: the
/// main agent plus every subagent, keyed by agent ID.
package struct ConversationCallUsageSnapshot: Codable, Equatable, Sendable {
    package var provider: String
    package var updatedAt: Date
    package var main = ConversationCallUsage()
    package var subagents: [String: ConversationCallUsage] = [:]

    package var totalCalls: Int { main.calls + subagents.values.reduce(0) { $0 + $1.calls } }
    package var totalSentTokens: Int { main.sentTokens + subagents.values.reduce(0) { $0 + $1.sentTokens } }
    package var totalOutputTokens: Int { main.outputTokens + subagents.values.reduce(0) { $0 + $1.outputTokens } }
    package var hasCacheSplit: Bool { main.hasCacheSplit && subagents.values.allSatisfy(\.hasCacheSplit) }
    /// Uncached input + cache writes + output over the main agent and every subagent.
    package var totalTokensExcludingCacheReads: Int {
        main.tokensExcludingCacheReads + subagents.values.reduce(0) { $0 + $1.tokensExcludingCacheReads }
    }

    package init(provider: String, updatedAt: Date, main: ConversationCallUsage = ConversationCallUsage(), subagents: [String: ConversationCallUsage] = [:]) {
        self.provider = provider
        self.updatedAt = updatedAt
        self.main = main
        self.subagents = subagents
    }
}

/// The state a conversation turn needs, independent of what owns the conversation.
///
/// `BoardTask` and `StandaloneChat` are different creatures: a task is a board card with
/// repositories, worktrees and a lifecycle column; a standalone chat is a continuous,
/// page-indexed conversation with no workspace at all. What they genuinely share is the
/// conversation itself — provider sessions, the queued-message mailbox, draft prompts,
/// turn bookkeeping — so the conversation engine operates on this protocol and neither
/// model has to pretend to be the other.
///
/// Repository state is deliberately read-only here and empty for a standalone chat, so the
/// engine's cwd/changed-file paths stay shared while only `BoardTask` can ever gain a
/// repository. That is a compile-time boundary rather than a runtime `isStandaloneChat` guard.
package protocol ConversationSubject: AnyObject, Observable {
    var id: UUID { get }
    var title: String { get set }
    var createdAt: Date { get }

    /// Turn lifecycle state. A task renders this as its board column; a standalone chat uses
    /// only the in-progress/waiting-response/backlog subset to track whether a turn is running.
    var statusRawValue: String { get set }
    var lifecycleRevision: Int { get set }
    var statusMessage: String? { get set }
    var progressTypeRawValue: String? { get set }
    var progressLabel: String? { get set }
    var progressDetail: String? { get set }
    var inProgressStartedAt: Date? { get set }
    var totalInProgressSeconds: Double { get set }

    var codexThreadID: String? { get set }
    var claudeSessionID: String? { get set }
    var openCodeSessionID: String? { get set }
    var conversationProviderRawValue: String? { get set }
    var conversationEffortRawValue: String? { get set }
    var conversationModelIDsData: Data? { get set }
    var savedPrompt: String? { get set }
    var pendingSubmittedPrompt: String? { get set }
    /// True while `savedPrompt` and the draft images are the user's unsent composer draft,
    /// rather than the last prompt that was sent.
    var hasUnsentDraft: Bool { get set }
    /// When the composer last saved the unsent draft.
    var draftEditedAt: Date? { get set }
    var draftImageDataURLsData: Data? { get set }
    /// JSON-encoded review comments written but not yet sent; part of the unsent draft.
    var pendingAnnotationsData: Data? { get set }
    /// JSON-encoded side chats held on the selected text they discuss (`SavedSideChats`).
    var sideChatsData: Data? { get set }
    var conversationActivityDurationsData: Data? { get set }
    var answeredAsyncQuestionIDsData: Data? { get set }

    /// Running token totals across every turn this conversation has run.
    var totalInputTokens: Int { get set }
    var totalOutputTokens: Int { get set }
    var totalCacheReadTokens: Int { get set }
    var totalCacheCreationTokens: Int { get set }
    /// Per-call usage snapshots keyed `"<provider>:<session or thread id>"`.
    var callUsageSnapshotsData: Data? { get set }

    /// Workspace roots the turn may read. Empty for a standalone chat, which runs with no
    /// repository or worktree context.
    var workspaceRootPaths: [String] { get }
    var repositoryWorktrees: [RepositoryWorktreeRecord] { get }
    var contextFolderPaths: [String] { get }

    /// Which creature this is, derived from the model's type rather than stored on a row.
    ///
    /// The two differ in kind, not degree: a chat has no workspace to resolve, and it gets
    /// page-classification developer instructions instead of the repo-management and
    /// task-outcome ones. Nothing filters on this to hide a chat from the board — a chat is
    /// not a `BoardTask`, so it cannot appear there in the first place.
    var isStandaloneChat: Bool { get }
}

extension ConversationSubject {
    package var authoringPluginPlacement: String? {
        (self as? StandaloneChat)?.pluginPlacement
    }
    package var authoringPluginID: String? {
        (self as? StandaloneChat)?.authoredPluginID
    }
    /// A side page of the standalone chat that runs alongside it until it is closed.
    package var isParallelChatBubble: Bool {
        (self as? StandaloneChat)?.parallelOfChatID != nil
    }

    package var answeredAsyncQuestionIDs: [String] {
        get {
            guard let answeredAsyncQuestionIDsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: answeredAsyncQuestionIDsData)) ?? []
        }
        set { answeredAsyncQuestionIDsData = try? JSONEncoder().encode(newValue) }
    }

    package var draftImageDataURLs: [String] {
        get {
            guard let draftImageDataURLsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: draftImageDataURLsData)) ?? []
        }
        set { draftImageDataURLsData = try? JSONEncoder().encode(newValue) }
    }

    package var conversationProvider: ConversationProvider {
        get { conversationProviderRawValue.flatMap(ConversationProvider.init(rawValue:)) ?? .codex }
        set { conversationProviderRawValue = newValue.rawValue }
    }

    package var conversationEffort: String {
        get { conversationEffortRawValue ?? "medium" }
        set { conversationEffortRawValue = newValue }
    }

    /// Only a board task chooses; the standalone chat already pages its own context.
    package var conversationContextMode: ConversationContextMode {
        (self as? BoardTask)?.conversationContextModeRawValue.flatMap(ConversationContextMode.init(rawValue:)) ?? .full
    }

    package var conversationModelID: String? {
        get { conversationModelID(for: conversationProvider) }
        set { setConversationModelID(newValue, for: conversationProvider) }
    }

    /// The model this conversation chose for one provider, whichever provider runs it now.
    package func conversationModelID(for provider: ConversationProvider) -> String? {
        guard let conversationModelIDsData,
              let modelIDs = try? JSONDecoder().decode([String: String].self, from: conversationModelIDsData) else { return nil }
        return modelIDs[provider.rawValue]
    }

    package func setConversationModelID(_ modelID: String?, for provider: ConversationProvider) {
        var modelIDs = (try? conversationModelIDsData.map { try JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        modelIDs[provider.rawValue] = modelID
        conversationModelIDsData = try? JSONEncoder().encode(modelIDs)
    }

    /// The native thread or session ID a provider uses for this conversation.
    package func conversationID(for provider: ConversationProvider) -> String? {
        switch provider {
        case .codex: codexThreadID
        case .claude: claudeSessionID
        case .opencode: openCodeSessionID
        }
    }

    package func setConversationID(_ conversationID: String?, for provider: ConversationProvider) {
        switch provider {
        case .codex: codexThreadID = conversationID
        case .claude: claudeSessionID = conversationID
        case .opencode: openCodeSessionID = conversationID
        }
    }

    /// The conversation the current provider continues.
    package var activeConversationID: String? { conversationID(for: conversationProvider) }

    /// Whether any provider has started a conversation here.
    package var hasConversation: Bool { ConversationProvider.allCases.contains { conversationID(for: $0) != nil } }

    /// Every provider conversation started here.
    package var allConversationIDs: Set<String> { Set(ConversationProvider.allCases.compactMap { conversationID(for: $0) }) }

    package var status: TaskStatus {
        get { TaskStatus(rawValue: statusRawValue) ?? .backlog }
        set {
            let previous = status
            guard previous != newValue else { return }
            if previous == .inProgress, let startedAt = inProgressStartedAt {
                totalInProgressSeconds += max(0, Date.now.timeIntervalSince(startedAt))
                inProgressStartedAt = nil
            }
            // The column a board task leaves, until the move is saved and published.
            if let task = self as? BoardTask, task.statusBeforeSave == nil {
                task.statusBeforeSave = previous.rawValue
            }
            statusRawValue = newValue.rawValue
            lifecycleRevision += 1
            if newValue == .inProgress { inProgressStartedAt = .now }
        }
    }

    package var tokenUsage: ConversationTokenUsage {
        get {
            ConversationTokenUsage(
                inputTokens: totalInputTokens,
                outputTokens: totalOutputTokens,
                cacheReadTokens: totalCacheReadTokens,
                cacheCreationTokens: totalCacheCreationTokens
            )
        }
        set {
            totalInputTokens = newValue.inputTokens
            totalOutputTokens = newValue.outputTokens
            totalCacheReadTokens = newValue.cacheReadTokens
            totalCacheCreationTokens = newValue.cacheCreationTokens
        }
    }

    package var totalTokens: Int { tokenUsage.totalTokens }

    package var callUsageSnapshots: [String: ConversationCallUsageSnapshot] {
        get {
            guard let callUsageSnapshotsData else { return [:] }
            return (try? JSONDecoder().decode([String: ConversationCallUsageSnapshot].self, from: callUsageSnapshotsData)) ?? [:]
        }
        set { callUsageSnapshotsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    package var hasCallUsage: Bool { callUsageSnapshots.values.contains { $0.totalCalls > 0 } }
    package var totalCalls: Int { callUsageSnapshots.values.reduce(0) { $0 + $1.totalCalls } }
    /// Everything re-sent across the task, subagents included; falls back to the
    /// turn totals for tasks recorded before call-level usage existed.
    package var totalSentTokens: Int {
        hasCallUsage ? callUsageSnapshots.values.reduce(0) { $0 + $1.totalSentTokens } : tokenUsage.totalTokens - totalOutputTokens
    }
    /// Everything but cache reads (uncached input + cache writes + output),
    /// subagents included. Tasks recorded before the cache split was stored
    /// fall back to the turn-level buckets, which cover the main agent only.
    package var tokensExcludingCacheReads: Int {
        let snapshots = callUsageSnapshots.values.filter { $0.totalCalls > 0 }
        guard !snapshots.isEmpty, snapshots.allSatisfy(\.hasCacheSplit) else {
            return tokenUsage.totalTokens - tokenUsage.cacheReadTokens
        }
        return snapshots.reduce(0) { $0 + $1.totalTokensExcludingCacheReads }
    }
    /// The size of the transcript at the most recent main-agent call.
    package var finalTranscriptTokens: Int {
        callUsageSnapshots.values.filter { !$0.main.isEmpty }.max { $0.updatedAt < $1.updatedAt }?.main.lastContextTokens ?? 0
    }
    /// What the card's counter shows: total sent, or the legacy total.
    package var counterTokens: Int { hasCallUsage ? totalSentTokens : totalTokens }

    package var currentInProgressSeconds: Double {
        totalInProgressSeconds + (status == .inProgress ? max(0, Date.now.timeIntervalSince(inProgressStartedAt ?? .now)) : 0)
    }
}

/// The continuous standalone chat: one conversation, split into searchable pages, with no
/// board column, repository, worktree or task lifecycle of its own.
///
/// Page content lives in `StandaloneChatStore`'s SQLite archive; this model holds only the
/// live conversation state the engine needs, and the per-page provider sessions are bound in
/// the archive rather than here.
@Observable
package final class StandaloneChat: PersistentModel {
    @ObservationIgnored package let persistenceState = ModelPersistenceState()
    package var id: UUID
    package var title: String
    package var createdAt: Date
    // Plugin editors have their own persisted conversation, independent of the board
    // and of the general-purpose standalone chat.
    package var authoredPluginID: String?
    package var pluginPlacement: String?
    package var pluginAuthoringName: String?
    package var pluginAuthoringPresentation: String?
    package var pluginContextFolder: String?
    // A parallel bubble is a side page of the standalone chat with its own conversation, so it
    // runs alongside the chat. Closing it inserts its page into the chat after the anchor turn,
    // the chat's last turn when the bubble was sent (nil when the chat was empty).
    package var parallelOfChatID: UUID?
    package var parallelAnchorTurnID: String?
    package var parallelPrompt: String?
    /// Set once a close starts moving the bubble into the chat, so no later turn can open a page
    /// the close has already moved; closing it again finishes the move.
    package var parallelIsClosing: Bool = false
    package var statusRawValue: String
    package var lifecycleRevision: Int = 0
    package var statusMessage: String?
    package var progressTypeRawValue: String?
    package var progressLabel: String?
    package var progressDetail: String?
    package var inProgressStartedAt: Date?
    package var totalInProgressSeconds: Double = 0
    package var codexThreadID: String?
    package var claudeSessionID: String?
    package var openCodeSessionID: String?
    package var conversationProviderRawValue: String?
    package var conversationEffortRawValue: String?
    package var conversationModelIDsData: Data?
    package var savedPrompt: String?
    package var pendingSubmittedPrompt: String?
    package var hasUnsentDraft: Bool = false
    package var draftEditedAt: Date?
    package var draftImageDataURLsData: Data?
    package var pendingAnnotationsData: Data?
    package var sideChatsData: Data?
    package var conversationActivityDurationsData: Data?
    package var answeredAsyncQuestionIDsData: Data?
    package var totalInputTokens: Int = 0
    package var totalOutputTokens: Int = 0
    package var totalCacheReadTokens: Int = 0
    package var totalCacheCreationTokens: Int = 0
    package var callUsageSnapshotsData: Data?

    package init(provider: ConversationProvider = .codex) {
        id = UUID()
        title = "Chat"
        createdAt = .now
        statusRawValue = TaskStatus.backlog.rawValue
        conversationProviderRawValue = provider.rawValue
        conversationEffortRawValue = "medium"
    }

    package static let tableName = "standalone_chats"
    package static let persistedProperties: [PersistedProperty<StandaloneChat>] = [
        PersistedProperty("id", \.id),
        PersistedProperty("title", \.title),
        PersistedProperty("createdAt", \.createdAt),
        PersistedProperty("authoredPluginID", \.authoredPluginID),
        PersistedProperty("pluginPlacement", \.pluginPlacement),
        PersistedProperty("pluginAuthoringName", \.pluginAuthoringName),
        PersistedProperty("pluginAuthoringPresentation", \.pluginAuthoringPresentation),
        PersistedProperty("pluginContextFolder", \.pluginContextFolder),
        PersistedProperty("parallelOfChatID", \.parallelOfChatID),
        PersistedProperty("parallelAnchorTurnID", \.parallelAnchorTurnID),
        PersistedProperty("parallelPrompt", \.parallelPrompt),
        PersistedProperty("parallelIsClosing", \.parallelIsClosing),
        PersistedProperty("statusRawValue", \.statusRawValue),
        PersistedProperty("lifecycleRevision", \.lifecycleRevision),
        PersistedProperty("statusMessage", \.statusMessage),
        PersistedProperty("progressTypeRawValue", \.progressTypeRawValue),
        PersistedProperty("progressLabel", \.progressLabel),
        PersistedProperty("progressDetail", \.progressDetail),
        PersistedProperty("inProgressStartedAt", \.inProgressStartedAt),
        PersistedProperty("totalInProgressSeconds", \.totalInProgressSeconds),
        PersistedProperty("codexThreadID", \.codexThreadID),
        PersistedProperty("claudeSessionID", \.claudeSessionID),
        PersistedProperty("openCodeSessionID", \.openCodeSessionID),
        PersistedProperty("conversationProviderRawValue", \.conversationProviderRawValue),
        PersistedProperty("conversationEffortRawValue", \.conversationEffortRawValue),
        PersistedProperty("conversationModelIDsData", \.conversationModelIDsData),
        PersistedProperty("savedPrompt", \.savedPrompt),
        PersistedProperty("pendingSubmittedPrompt", \.pendingSubmittedPrompt),
        PersistedProperty("hasUnsentDraft", \.hasUnsentDraft),
        PersistedProperty("draftEditedAt", \.draftEditedAt),
        PersistedProperty("draftImageDataURLsData", \.draftImageDataURLsData),
        PersistedProperty("pendingAnnotationsData", \.pendingAnnotationsData),
        PersistedProperty("sideChatsData", \.sideChatsData),
        PersistedProperty("conversationActivityDurationsData", \.conversationActivityDurationsData),
        PersistedProperty("answeredAsyncQuestionIDsData", \.answeredAsyncQuestionIDsData),
        PersistedProperty("totalInputTokens", \.totalInputTokens),
        PersistedProperty("totalOutputTokens", \.totalOutputTokens),
        PersistedProperty("totalCacheReadTokens", \.totalCacheReadTokens),
        PersistedProperty("totalCacheCreationTokens", \.totalCacheCreationTokens),
        PersistedProperty("callUsageSnapshotsData", \.callUsageSnapshotsData),
    ]

    package required init(storedID: UUID) {
        id = storedID
        title = "Chat"
        createdAt = Date(timeIntervalSinceReferenceDate: 0)
        statusRawValue = TaskStatus.backlog.rawValue
    }
}

extension StandaloneChat: ConversationSubject {
    /// Plugin authoring has a context folder but never has a repository or worktree.
    package var workspaceRootPaths: [String] { contextFolderPaths }
    package var repositoryWorktrees: [RepositoryWorktreeRecord] { [] }
    package var contextFolderPaths: [String] { pluginContextFolder.map { [$0] } ?? [] }
    package var isStandaloneChat: Bool { authoredPluginID == nil }
}

extension BoardTask: ConversationSubject {
    package var isStandaloneChat: Bool { false }
}

/// A comment on selected conversation text. It stays pending until a turn sends it.
package struct ConversationAnnotation: Identifiable, Codable, Equatable {
    package let id: UUID
    package let messageID: String
    /// The comment starts `startOffset` into this block's text and ends `endOffset` into
    /// `endBlockID`'s, so a comment on prose blocks rendered together can span several of them.
    package let blockID: Int
    package let startOffset: Int
    package let endBlockID: Int
    package let endOffset: Int
    package let text: String
    package var comment: String
    package var pending = true

    /// Where in the transcript the comment's selection is.
    package var source: ConversationTextSource {
        ConversationTextSource(messageID: messageID, blockID: blockID, startOffset: startOffset, endBlockID: endBlockID, endOffset: endOffset)
    }

    /// True when both comments quote the same selection with the same comment, whatever their ids.
    package func sameComment(as other: ConversationAnnotation) -> Bool {
        messageID == other.messageID && blockID == other.blockID && startOffset == other.startOffset
            && endBlockID == other.endBlockID && endOffset == other.endOffset
            && text == other.text && comment == other.comment
    }

    package init(id: UUID, messageID: String, blockID: Int, startOffset: Int, endBlockID: Int, endOffset: Int, text: String, comment: String, pending: Bool = true) {
        self.id = id
        self.messageID = messageID
        self.blockID = blockID
        self.startOffset = startOffset
        self.endBlockID = endBlockID
        self.endOffset = endOffset
        self.text = text
        self.comment = comment
        self.pending = pending
    }
}

/// A selection of transcript text: it starts `startOffset` into `blockID`'s text and ends
/// `endOffset` into `endBlockID`'s, in the message `messageID`.
package struct ConversationTextSource: Codable, Equatable {
    package let messageID: String
    package let blockID: Int
    package let startOffset: Int
    package let endBlockID: Int
    package let endOffset: Int

    package init(messageID: String, blockID: Int, startOffset: Int, endBlockID: Int, endOffset: Int) {
        self.messageID = messageID
        self.blockID = blockID
        self.startOffset = startOffset
        self.endBlockID = endBlockID
        self.endOffset = endOffset
    }
}

/// Encoding and restore rules for the unsent comments saved with a task's draft.
package enum PersistedAnnotations {
    package static func encode(_ annotations: [ConversationAnnotation]) -> Data? {
        let pending = annotations.filter(\.pending)
        return pending.isEmpty ? nil : try? JSONEncoder().encode(pending)
    }

    /// Missing or unreadable data is an empty list, so tasks stored before the field existed load.
    package static func decode(_ data: Data?) -> [ConversationAnnotation] {
        guard let data, let decoded = try? JSONDecoder().decode([ConversationAnnotation].self, from: data) else { return [] }
        return decoded.map { annotation in
            var pending = annotation
            pending.pending = true
            return pending
        }
    }

    /// The comments to show after a load: the transcript's sent comments, then the pending ones
    /// kept in memory and saved with the task. A pending comment already sent (same id, or the
    /// same quote and text as a sent one) is dropped, so a send interrupted before the save was
    /// cleared never shows twice.
    package static func restored(sent: [ConversationAnnotation], livePending: [ConversationAnnotation],
                         persisted: [ConversationAnnotation]) -> [ConversationAnnotation] {
        var result = sent
        var pending: [ConversationAnnotation] = []
        for candidate in livePending + persisted {
            guard !pending.contains(where: { $0.id == candidate.id }),
                  !sent.contains(where: { $0.sameComment(as: candidate) }) else { continue }
            pending.append(candidate)
        }
        result.append(contentsOf: pending)
        return result
    }
}

/// How much of a board task's conversation a follow-up carries. Kept with the
/// models, which some tools compile on their own. `full` resumes the
/// provider session, as always. `optimized` starts every follow-up (not a steer) in a
/// fresh provider session seeded only with the user's messages, the last final answer
/// (never a plan) and a positional outline, and lets the agent read the rest on demand.
package enum ConversationContextMode: String, CaseIterable, Hashable, Codable {
    case full
    case optimized
}
