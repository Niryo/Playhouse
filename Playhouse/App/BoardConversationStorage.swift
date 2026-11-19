import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension BoardTaskManager {
    /// Links the task to a provider conversation. `replacing` names a conversation the
    /// provider no longer has, which a board task may swap for a new one; any other
    /// existing link is kept.
    func persistConversationID(
        _ id: UUID,
        provider: ConversationProvider,
        id conversationID: String,
        replacing missingConversationID: String? = nil
    ) async throws -> BoardTaskRecord {
        guard !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "\(provider.displayName) returned an empty conversation ID.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            let existing = task.conversationID(for: provider)
            // A standalone chat deliberately rotates sessions: each page owns one, and the task
            // pointer follows the active page. Board tasks keep exactly one conversation.
            guard existing == nil || existing == conversationID || task.isStandaloneChat
                || (missingConversationID != nil && existing == missingConversationID) else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task is already linked to a different \(provider.displayName) conversation.")
            }
            guard existing != conversationID else { return BoardTaskRecord(task: task) }
            switch provider {
            case .codex: task.codexThreadID = conversationID
            case .claude: task.claudeSessionID = conversationID
            }
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                switch provider {
                case .codex: task.codexThreadID = existing
                case .claude: task.claudeSessionID = existing
                }
                throw error
            }
            // Follow-ups queued on the replaced conversation belong to its successor.
            if let existing, !task.isStandaloneChat {
                try? mutateQueuedMessages(taskID: id) { items in
                    for index in items.indices where items[index].threadID == existing {
                        items[index].threadID = conversationID
                    }
                }
            }
            return BoardTaskRecord(task: task)
        }
    }

    /// Whether the task's follow-ups resume the whole conversation or start fresh,
    /// seeded sessions. Only a board task chooses: the standalone chat pages itself.
    func setConversationContextMode(_ id: UUID, mode: ConversationContextMode) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard let boardTask = task as? BoardTask else {
                throw BridgeCommandError(
                    code: "invalid_argument",
                    message: "The standalone chat already splits its context into pages, so it has no context mode."
                )
            }
            let previous = boardTask.conversationContextModeRawValue
            boardTask.conversationContextModeRawValue = mode.rawValue
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                boardTask.conversationContextModeRawValue = previous
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    /// Persists which provider runs the task's next turn. Callers that already
    /// have a conversation go through `ConversationManager.setProvider`, which
    /// checks that the conversation is settled and records the boundary.
    func setConversationProvider(_ id: UUID, provider: ConversationProvider) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.conversationProvider != provider || task.conversationProviderRawValue == nil else { return BoardTaskRecord(task: task) }
            let previous = task.conversationProviderRawValue
            task.conversationProvider = provider
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.conversationProviderRawValue = previous
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    func setConversationEffort(_ id: UUID, effort: ConversationEffort) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            let previous = task.conversationEffortRawValue
            task.conversationEffort = effort.rawValue
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.conversationEffortRawValue = previous
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    func setConversationModelID(_ id: UUID, modelID: String) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            let previous = task.conversationModelIDsData
            task.conversationModelID = modelID
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.conversationModelIDsData = previous
                throw error
            }
        }
    }

    func replaceConversationModelID(
        _ id: UUID,
        expectedProvider: ConversationProvider,
        expectedModelID: String,
        replacementModelID: String
    ) async throws -> Bool {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.conversationProvider == expectedProvider,
                  task.conversationModelID == expectedModelID else { return false }
            let previous = task.conversationModelIDsData
            task.conversationModelID = replacementModelID
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.conversationModelIDsData = previous
                throw error
            }
            return true
        }
    }

    func setWorkspaceRoots(_ id: UUID, roots: [String]) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        let initialRepositories = initialTask.repositoryWorktrees
        let initialWorkspaceRoots = initialTask.workspaceRootPaths
        let initialContextFolders = initialTask.contextFolderPaths
        if initialRepositories.isEmpty {
            let normalizedRoots = try Self.normalizeRoots(roots)
            return try await withConversationTurnReservation(id) {
                try await withTaskOperationLock(id) {
                    let task = try requireTask(id)
                    guard task.repositoryWorktrees == initialRepositories,
                          task.workspaceRootPaths == initialWorkspaceRoots,
                          task.contextFolderPaths == initialContextFolders else {
                        throw BridgeCommandError(code: "invalid_transition", message: "The task workspaces changed while folders were being validated. Try again.")
                    }
                    task.workspaceRootPaths = normalizedRoots
                    task.contextFolderPaths = normalizedRoots
                    try await saveTaskContext(taskID: id)
                    return BoardTaskRecord(task: task)
                }
            }
        } else {
            let paths = try Self.normalizeOptionalRoots(roots)
            let existingPaths = Set(initialRepositories.map { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path })
            let retained = initialRepositories.filter { existingPaths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) && paths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) }
            var worktrees = retained
            var folders: [String] = []
            for path in paths where !existingPaths.contains(path) {
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path) {
                    let record = try await worktreeService.pendingRecord(
                        spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
                    )
                    worktrees.append(record)
                } else {
                    folders.append(path)
                }
            }
            return try await withConversationTurnReservation(id) {
                try await withTaskOperationLock(id) {
                    try await withRepositoryAllocationLocks(worktrees.map(\.repositoryPath)) {
                        let task = try requireTask(id)
                        guard task.repositoryWorktrees == initialRepositories,
                              task.workspaceRootPaths == initialWorkspaceRoots,
                              task.contextFolderPaths == initialContextFolders else {
                            throw BridgeCommandError(code: "invalid_transition", message: "The task workspaces changed while folders were being validated. Try again.")
                        }
                        try validateRepositoryAssignments(worktrees, excludingTaskID: id)
                        task.repositoryWorktrees = worktrees
                        task.contextFolderPaths = folders
                        let resolvedRoots = try Self.normalizeOptionalRoots(worktrees.map(\.worktreePath) + folders)
                        guard !resolvedRoots.isEmpty else { throw PlayhouseManagerError.noWorkspaceRoots }
                        task.workspaceRootPaths = resolvedRoots
                        try await saveTaskContext(taskID: id)
                        return BoardTaskRecord(task: task)
                    }
                }
            }
        }
    }
}
