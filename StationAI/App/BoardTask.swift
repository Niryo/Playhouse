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

@Model
final class BoardTask {
    var id: UUID
    var title: String
    var statusRawValue: String
    var statusMessage: String?
    var createdAt: Date
    var codexThreadID: String?
    var savedPrompt: String?
    var workspaceRootPathsData: Data?
    var repositoryWorktreesData: Data?
    var contextFolderPathsData: Data?

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

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRawValue) ?? .backlog }
        set { statusRawValue = newValue.rawValue }
    }

    init(title: String, status: TaskStatus = .backlog, workspaceRootPaths: [String] = []) {
        id = UUID()
        self.title = title
        statusRawValue = status.rawValue
        statusMessage = nil
        createdAt = .now
        codexThreadID = nil
        savedPrompt = nil
        workspaceRootPathsData = try? JSONEncoder().encode(workspaceRootPaths)
        repositoryWorktreesData = nil
        contextFolderPathsData = nil
    }
}

struct RepositoryWorktreeSpec: Codable, Equatable {
    var repositoryPath: String
    var branch: String?
    var branchFrom: String?
    var mergeTarget: String? = nil
}

struct RepositoryWorktreeRecord: Codable, Equatable {
    var repositoryPath: String
    var branch: String
    var worktreePath: String
    var branchFrom: String
    var createdByStationAI: Bool
    var mergeTarget: String? = nil
    var mergeCompleted: Bool = false
    var mergeError: String? = nil
    var isPending: Bool = false

    private enum CodingKeys: String, CodingKey {
        case repositoryPath, branch, worktreePath, branchFrom, createdByStationAI
        case mergeTarget, mergeCompleted, mergeError, isPending
    }

    init(
        repositoryPath: String,
        branch: String,
        worktreePath: String,
        branchFrom: String,
        createdByStationAI: Bool,
        mergeTarget: String? = nil,
        mergeCompleted: Bool = false,
        mergeError: String? = nil,
        isPending: Bool = false
    ) {
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.worktreePath = worktreePath
        self.branchFrom = branchFrom
        self.createdByStationAI = createdByStationAI
        self.mergeTarget = mergeTarget
        self.mergeCompleted = mergeCompleted
        self.mergeError = mergeError
        self.isPending = isPending
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        repositoryPath = try values.decode(String.self, forKey: .repositoryPath)
        branch = try values.decode(String.self, forKey: .branch)
        worktreePath = try values.decode(String.self, forKey: .worktreePath)
        branchFrom = try values.decode(String.self, forKey: .branchFrom)
        createdByStationAI = try values.decode(Bool.self, forKey: .createdByStationAI)
        mergeTarget = try values.decodeIfPresent(String.self, forKey: .mergeTarget)
        mergeCompleted = try values.decodeIfPresent(Bool.self, forKey: .mergeCompleted) ?? false
        mergeError = try values.decodeIfPresent(String.self, forKey: .mergeError)
        isPending = try values.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
    }
}
