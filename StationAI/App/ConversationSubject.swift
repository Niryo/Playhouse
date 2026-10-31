import Foundation
import SwiftData

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
