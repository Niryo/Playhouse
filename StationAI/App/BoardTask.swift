import Foundation
import SwiftData
import SwiftUI

enum TaskStatus: String, CaseIterable, Identifiable {
    case backlog = "Backlog"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case waitingResponse = "Waiting Response"
    case review = "Review"
    case done = "Done"

    var id: String {
        rawValue
    }

    var accessibilityKey: String {
        rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    var accent: Color {
        switch self {
        case .backlog: Color(red: 0.52, green: 0.57, blue: 0.66)
        case .inProgress: Color(red: 0.75, green: 0.48, blue: 0.20)
        case .blocked: Color(red: 0.82, green: 0.30, blue: 0.30)
        case .waitingResponse: Color(red: 0.64, green: 0.44, blue: 0.80)
        case .review: Color(red: 0.28, green: 0.51, blue: 0.82)
        case .done: Color(red: 0.20, green: 0.62, blue: 0.45)
        }
    }
}

/// The agent runtime that executes a task's conversation turns.
enum ConversationProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

enum TaskProgressType: String, CaseIterable, Identifiable {
    case planning
    case searching
    case building
    case running
    case testing
    case reviewing
    case writing
    case committing

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .planning: "map"
        case .searching: "magnifyingglass"
        case .building: "hammer"
        case .running: "play.fill"
        case .testing: "checkmark.seal"
        case .reviewing: "eye"
        case .writing: "pencil.line"
        case .committing: "arrow.triangle.branch"
        }
    }
}

@Model
final class BoardTask {
    var id: UUID
    var title: String
    var statusRawValue: String
    var lifecycleRevision: Int = 0
    var statusMessage: String?
    var progressTypeRawValue: String?
    var progressLabel: String?
    var progressDetail: String?
    var createdAt: Date
    var inProgressStartedAt: Date?
    var totalInProgressSeconds: Double = 0
    var codexThreadID: String?
    var claudeSessionID: String?
    /// Nil for tasks created before provider selection; those use Codex.
    var conversationProviderRawValue: String?
    var conversationEffortRawValue: String?
    // Retained for one-time migration to the global provider model preference.
    var conversationModelIDsData: Data?
    var savedPrompt: String?
    var pendingSubmittedPrompt: String?
    var workspaceRootPathsData: Data?
    var repositoryWorktreesData: Data?
    var contextFolderPathsData: Data?
    var draftImageDataURLsData: Data?
    var conversationActivityDurationsData: Data?
    var answeredAsyncQuestionIDsData: Data?

    var answeredAsyncQuestionIDs: [String] {
        get {
            guard let answeredAsyncQuestionIDsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: answeredAsyncQuestionIDsData)) ?? []
        }
        set { answeredAsyncQuestionIDsData = try? JSONEncoder().encode(newValue) }
    }

    var workspaceRootPaths: [String] {
        get {
            guard let workspaceRootPathsData else { return [] }
            return (try? JSONDecoder().decode([String].self, from: workspaceRootPathsData)) ?? []
        }
        set {
            workspaceRootPathsData = try? JSONEncoder().encode(newValue)
        }
    }

    var repositoryWorktrees: [RepositoryWorktreeRecord] {
        get { guard let repositoryWorktreesData else { return [] }; return (try? JSONDecoder().decode([RepositoryWorktreeRecord].self, from: repositoryWorktreesData)) ?? [] }
        set { repositoryWorktreesData = try? JSONEncoder().encode(newValue) }
    }

    var contextFolderPaths: [String] {
        get { guard let contextFolderPathsData else { return workspaceRootPaths }; return (try? JSONDecoder().decode([String].self, from: contextFolderPathsData)) ?? [] }
        set { contextFolderPathsData = try? JSONEncoder().encode(newValue) }
    }

    var draftImageDataURLs: [String] {
        get { guard let draftImageDataURLsData else { return [] }; return (try? JSONDecoder().decode([String].self, from: draftImageDataURLsData)) ?? [] }
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

    /// The native thread or session ID a provider uses for this task.
    func conversationID(for provider: ConversationProvider) -> String? {
        switch provider {
        case .codex: codexThreadID
        case .claude: claudeSessionID
        }
    }

    /// The conversation the task's current provider continues.
    var activeConversationID: String? { conversationID(for: conversationProvider) }

    /// Whether any provider has started a conversation for this task.
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

    init(title: String, status: TaskStatus = .backlog, workspaceRootPaths: [String] = [], conversationProvider: ConversationProvider = .codex) {
        id = UUID()
        self.title = title
        statusRawValue = status.rawValue
        statusMessage = nil
        progressTypeRawValue = nil
        progressLabel = nil
        progressDetail = nil
        createdAt = .now
        inProgressStartedAt = status == .inProgress ? .now : nil
        totalInProgressSeconds = 0
        codexThreadID = nil
        claudeSessionID = nil
        conversationProviderRawValue = conversationProvider.rawValue
        conversationEffortRawValue = "medium"
        conversationModelIDsData = nil
        savedPrompt = nil
        pendingSubmittedPrompt = nil
        workspaceRootPathsData = try? JSONEncoder().encode(workspaceRootPaths)
        repositoryWorktreesData = nil
        contextFolderPathsData = nil
        draftImageDataURLsData = nil
        conversationActivityDurationsData = nil
        answeredAsyncQuestionIDsData = nil
    }
}

struct RepositoryWorktreeSpec: Codable, Equatable, Sendable {
    var repositoryPath: String
    var branch: String?
    var branchFrom: String?
    var mergeTarget: String? = nil
}

struct RepositoryWorktreeRecord: Codable, Equatable, Sendable {
    var repositoryPath: String
    var branch: String
    var worktreePath: String
    var branchFrom: String
    var createdByStationAI: Bool
    var mergeTarget: String? = nil
    var isPending: Bool = false
    var pullRequestNumber: Int? = nil
    var pullRequestURL: String? = nil

    private enum CodingKeys: String, CodingKey {
        case repositoryPath, branch, worktreePath, branchFrom, createdByStationAI
        case mergeTarget, isPending, pullRequestNumber, pullRequestURL
    }

    init(
        repositoryPath: String,
        branch: String,
        worktreePath: String,
        branchFrom: String,
        createdByStationAI: Bool,
        mergeTarget: String? = nil,
        isPending: Bool = false,
        pullRequestNumber: Int? = nil,
        pullRequestURL: String? = nil
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.worktreePath = worktreePath
        self.branchFrom = branchFrom
        self.createdByStationAI = createdByStationAI
        self.mergeTarget = mergeTarget
        self.isPending = isPending
        self.pullRequestNumber = pullRequestNumber
        self.pullRequestURL = pullRequestURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositoryPath = try values.decode(String.self, forKey: .repositoryPath)
        branch = try values.decode(String.self, forKey: .branch)
        worktreePath = try values.decode(String.self, forKey: .worktreePath)
        branchFrom = try values.decode(String.self, forKey: .branchFrom)
        createdByStationAI = try values.decode(Bool.self, forKey: .createdByStationAI)
        mergeTarget = try values.decodeIfPresent(String.self, forKey: .mergeTarget)
        isPending = try values.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        pullRequestNumber = try values.decodeIfPresent(Int.self, forKey: .pullRequestNumber)
        pullRequestURL = try values.decodeIfPresent(String.self, forKey: .pullRequestURL)
    }
}
