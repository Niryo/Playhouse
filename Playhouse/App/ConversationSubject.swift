import Foundation
import SwiftData

/// Token counts a provider reported for one completed turn.
///
/// Both runtimes bill the same four buckets, so the breakdown is stored in
/// Playhouse's own shape rather than either provider's wire spelling. Defined
/// here rather than beside its other conversation-model siblings because
/// `scripts/seed-task-pr-link.swift` compiles this file and `BoardTask.swift`
/// standalone and must not gain a dependency on the rest of the app module.
struct ConversationTokenUsage: Codable, Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0

    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    var isEmpty: Bool { totalTokens == 0 }

    static func + (lhs: Self, rhs: Self) -> Self {
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
    init(providerPayload: [String: Any]) {
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

    init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
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
protocol ConversationSubject: AnyObject, Observable {
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
    var conversationProviderRawValue: String? { get set }
    var conversationEffortRawValue: String? { get set }
    var conversationModelIDsData: Data? { get set }
    var savedPrompt: String? { get set }
    var pendingSubmittedPrompt: String? { get set }
    var draftImageDataURLsData: Data? { get set }
    var conversationActivityDurationsData: Data? { get set }
    var answeredAsyncQuestionIDsData: Data? { get set }

    /// Running token totals across every turn this conversation has run.
    var totalInputTokens: Int { get set }
    var totalOutputTokens: Int { get set }
    var totalCacheReadTokens: Int { get set }
    var totalCacheCreationTokens: Int { get set }

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
    var answeredAsyncQuestionIDs: [String] {
        get {
            guard let answeredAsyncQuestionIDsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: answeredAsyncQuestionIDsData)) ?? []
        }
        set { answeredAsyncQuestionIDsData = try? JSONEncoder().encode(newValue) }
    }

    var draftImageDataURLs: [String] {
        get {
            guard let draftImageDataURLsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: draftImageDataURLsData)) ?? []
        }
        set { draftImageDataURLsData = try? JSONEncoder().encode(newValue) }
    }

    var conversationProvider: ConversationProvider {
        get { conversationProviderRawValue.flatMap(ConversationProvider.init(rawValue:)) ?? .codex }
        set { conversationProviderRawValue = newValue.rawValue }
    }

    var conversationEffort: String {
        get { conversationEffortRawValue ?? "medium" }
        set { conversationEffortRawValue = newValue }
    }

    var conversationModelID: String? {
        get {
            guard let conversationModelIDsData,
                  let modelIDs = try? JSONDecoder().decode([String: String].self, from: conversationModelIDsData) else { return nil }
            return modelIDs[conversationProvider.rawValue]
        }
        set {
            var modelIDs = (try? conversationModelIDsData.map { try JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
            modelIDs[conversationProvider.rawValue] = newValue
            conversationModelIDsData = try? JSONEncoder().encode(modelIDs)
        }
    }

    /// The native thread or session ID a provider uses for this conversation.
    func conversationID(for provider: ConversationProvider) -> String? {
        switch provider {
        case .codex: codexThreadID
        case .claude: claudeSessionID
        }
    }

    /// The conversation the current provider continues.
    var activeConversationID: String? { conversationID(for: conversationProvider) }

    /// Whether any provider has started a conversation here.
    var hasConversation: Bool { codexThreadID != nil || claudeSessionID != nil }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRawValue) ?? .backlog }
        set {
            let previous = status
            guard previous != newValue else { return }
            if previous == .inProgress, let startedAt = inProgressStartedAt {
                totalInProgressSeconds += max(0, Date.now.timeIntervalSince(startedAt))
                inProgressStartedAt = nil
            }
            statusRawValue = newValue.rawValue
            lifecycleRevision += 1
            if newValue == .inProgress { inProgressStartedAt = .now }
        }
    }

    var tokenUsage: ConversationTokenUsage {
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

    var totalTokens: Int { tokenUsage.totalTokens }

    var currentInProgressSeconds: Double {
        totalInProgressSeconds + (status == .inProgress ? max(0, Date.now.timeIntervalSince(inProgressStartedAt ?? .now)) : 0)
    }
}

/// The continuous standalone chat: one conversation, split into searchable pages, with no
/// board column, repository, worktree or task lifecycle of its own.
///
/// Page content lives in `StandaloneChatStore`'s SQLite archive; this model holds only the
/// live conversation state the engine needs, and the per-page provider sessions are bound in
/// the archive rather than here.
@Model
final class StandaloneChat {
    var id: UUID
    var title: String
    var createdAt: Date
    var statusRawValue: String
    var lifecycleRevision: Int = 0
    var statusMessage: String?
    var progressTypeRawValue: String?
    var progressLabel: String?
    var progressDetail: String?
    var inProgressStartedAt: Date?
    var totalInProgressSeconds: Double = 0
    var codexThreadID: String?
    var claudeSessionID: String?
    var conversationProviderRawValue: String?
    var conversationEffortRawValue: String?
    var conversationModelIDsData: Data?
    var savedPrompt: String?
    var pendingSubmittedPrompt: String?
    var draftImageDataURLsData: Data?
    var conversationActivityDurationsData: Data?
    var answeredAsyncQuestionIDsData: Data?
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCacheReadTokens: Int = 0
    var totalCacheCreationTokens: Int = 0

    init(provider: ConversationProvider = .codex) {
        id = UUID()
        title = "Chat"
        createdAt = .now
        statusRawValue = TaskStatus.backlog.rawValue
        conversationProviderRawValue = provider.rawValue
        conversationEffortRawValue = "medium"
    }
}

extension StandaloneChat: ConversationSubject {
    /// A standalone chat never has a workspace; these stay empty by construction.
    var workspaceRootPaths: [String] { [] }
    var repositoryWorktrees: [RepositoryWorktreeRecord] { [] }
    var contextFolderPaths: [String] { [] }
    var isStandaloneChat: Bool { true }
}

extension BoardTask: ConversationSubject {
    var isStandaloneChat: Bool { false }
}
