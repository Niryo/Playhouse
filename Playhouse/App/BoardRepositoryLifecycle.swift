import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension BoardTaskManager {
    @discardableResult
    func addRepository(
        _ id: UUID,
        repositoryPath: String,
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        return try await addRepositories(
            id,
            repositoryPaths: [repositoryPath],
            duringActiveConversation: duringActiveConversation
        )
    }

    @discardableResult
    func addRepositories(
        _ id: UUID,
        repositoryPaths: [String],
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        guard !repositoryPaths.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Add at least one repository.")
        }

        PlayhouseDiagnostics.record("workspace.repository.add.started", fields: [
            "taskID": id.uuidString,
            "repositoryCount": String(repositoryPaths.count),
            "repositoryPaths": repositoryPaths.joined(separator: "\n")
        ])

        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }

        var records: [RepositoryWorktreeRecord] = []
        records.reserveCapacity(repositoryPaths.count)
        for path in repositoryPaths {
            records.append(try await worktreeService.pendingRecord(
                spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
            ))
        }

        // A repository the task already has, or one listed twice, gets another worktree
        // of its own (see `addWorktree`); the rest are added as pending records.
        let attachedRepositories = Set(initialTask.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
        var seenRepositories = Set<String>()
        var additionalWorktrees: [RepositoryWorktreeRecord] = []
        let newRecords = records.filter { record in
            let repository = Self.canonicalPath(record.repositoryPath)
            guard !attachedRepositories.contains(repository), seenRepositories.insert(repository).inserted else {
                additionalWorktrees.append(record)
                return false
            }
            return true
        }
        let addedRepositories = seenRepositories

        let mutation = {
            try await self.withTaskOperationLock(id) {
                return try await self.withRepositoryAllocationLocks(newRecords.map(\.repositoryPath)) {
                    let task = try self.requireTask(id)
                    guard task.status != .done else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
                    }

                    let currentRepositories = Set(task.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
                    if let duplicate = newRecords.first(where: { currentRepositories.contains(Self.canonicalPath($0.repositoryPath)) }) {
                        throw BridgeCommandError(
                            code: "invalid_transition",
                            message: "This repository was attached to the task while it was being added. Try again: \(duplicate.repositoryPath)"
                        )
                    }
                    try self.validateRepositoryAssignments(newRecords, excludingTaskID: id)

                    let repositories = task.repositoryWorktrees + newRecords
                    let contextFolders = try Self.normalizeOptionalRoots(
                        task.contextFolderPaths.filter {
                            !addedRepositories.contains(Self.canonicalPath($0))
                        }
                    )
                    let roots = try Self.normalizeOptionalRoots(repositories.map { $0.isPending ? $0.repositoryPath : $0.worktreePath } + contextFolders)
                    task.repositoryWorktrees = repositories
                    task.contextFolderPaths = contextFolders
                    task.workspaceRootPaths = roots
                    try await self.saveTaskContext(taskID: id)
                    PlayhouseDiagnostics.record("workspace.repository.add.succeeded", fields: [
                        "taskID": id.uuidString,
                        "repositoryCount": String(newRecords.count),
                        "repositoryPaths": newRecords.map(\.repositoryPath).joined(separator: "\n")
                    ])
                    return BoardTaskRecord(task: task)
                }
            }
        }
        var result: BoardTaskRecord
        if newRecords.isEmpty {
            result = BoardTaskRecord(task: initialTask)
        } else if duringActiveConversation {
            result = try await mutation()
        } else {
            result = try await withConversationTurnReservation(id) {
                try await mutation()
            }
        }
        for record in additionalWorktrees {
            result = try await addWorktree(
                id,
                repositoryPath: record.repositoryPath,
                duringActiveConversation: duringActiveConversation
            )
        }
        return result
    }

    /// Adds another worktree of a repository to the task, on its own branch, so one task
    /// can carry several pull requests to the same repository. The worktree is created
    /// right away on `branch` (or an auto-named branch from the task title) from
    /// `branchFrom`; it merges into the merge target the task already uses for this
    /// repository, or the repository's default.
    @discardableResult
    func addWorktree(
        _ id: UUID,
        repositoryPath: String,
        branch: String? = nil,
        branchFrom: String? = nil,
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }
        let repository = try await worktreeService.pendingRecord(
            spec: RepositoryWorktreeSpec(repositoryPath: repositoryPath, branch: nil, branchFrom: nil)
        ).repositoryPath
        let sibling = initialTask.repositoryWorktrees.first {
            Self.canonicalPath($0.repositoryPath) == Self.canonicalPath(repository)
        }
        let spec = RepositoryWorktreeSpec(
            repositoryPath: repository,
            branch: branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? branch : nil,
            branchFrom: branchFrom?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? branchFrom : nil,
            mergeTarget: sibling?.mergeTarget
        )
        // Validates the branch names before any lock is taken.
        let validated = try await worktreeService.pendingRecord(spec: spec)
        PlayhouseDiagnostics.record("workspace.repository.add_worktree.started", fields: [
            "taskID": id.uuidString, "repositoryPath": repository, "branch": validated.branch
        ])
        let mutation = {
            try await self.withTaskOperationLock(id) {
                try await self.withRepositoryAllocationLocks([repository]) {
                    let task = try self.requireTask(id)
                    guard task.status != .done else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
                    }
                    if let taken = task.repositoryWorktrees.first(where: {
                        Self.canonicalPath($0.repositoryPath) == Self.canonicalPath(repository) && $0.branch == validated.branch && !RepositoryWorktreeRecord.isAutomaticBranch(validated.branch)
                    }) {
                        throw BridgeCommandError(
                            code: "invalid_argument",
                            message: "This task already has a worktree on branch '\(validated.branch)': \(taken.isPending ? taken.repositoryPath : taken.worktreePath)"
                        )
                    }
                    try self.validateRepositoryAssignments([validated], excludingTaskID: id)
                    let record = try await self.worktreeService.resolve(
                        spec: spec,
                        title: task.title,
                        root: self.worktreeRoot,
                        reservedBranches: self.reservedBranches(repositoryPath: repository, excludingTaskID: id)
                            .union(self.ownBranches(of: repository, in: task.repositoryWorktrees))
                    )
                    do {
                        if let existing = task.repositoryWorktrees.first(where: {
                            !$0.isPending && Self.canonicalPath($0.worktreePath) == Self.canonicalPath(record.worktreePath)
                        }) {
                            throw BridgeCommandError(
                                code: "invalid_argument",
                                message: "This task already uses the worktree on branch '\(existing.branch)': \(existing.worktreePath)"
                            )
                        }
                        try self.validateRepositoryAssignments([record], excludingTaskID: id)
                        let repositories = task.repositoryWorktrees + [record]
                        task.repositoryWorktrees = repositories
                        task.workspaceRootPaths = try Self.normalizeOptionalRoots(
                            repositories.map { $0.isPending ? $0.repositoryPath : $0.worktreePath } + task.contextFolderPaths
                        )
                        try await self.saveTaskContext(taskID: id)
                    } catch {
                        if record.createdByPlayhouse { try? await self.worktreeService.remove(record) }
                        throw error
                    }
                    PlayhouseDiagnostics.record("workspace.repository.add_worktree.succeeded", fields: [
                        "taskID": id.uuidString, "repositoryPath": repository,
                        "branch": record.branch, "worktreePath": record.worktreePath
                    ])
                    return BoardTaskRecord(task: task)
                }
            }
        }
        if duringActiveConversation {
            return try await mutation()
        }
        return try await withConversationTurnReservation(id) {
            try await mutation()
        }
    }

    @discardableResult
    func replaceRepositories(
        _ id: UUID,
        repositoryPaths: [String],
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        guard !repositoryPaths.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Replace with at least one repository.")
        }
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }

        var seen = Set<String>()
        var normalizedPaths: [String] = []
        for path in repositoryPaths {
            let record = try await worktreeService.pendingRecord(
                spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
            )
            // Replacing keeps a repository's worktrees; listing it twice adds nothing more.
            if seen.insert(Self.canonicalPath(record.repositoryPath)).inserted {
                normalizedPaths.append(record.repositoryPath)
            }
        }

        let desired = Set(normalizedPaths.map(Self.canonicalPath))
        let existing = Set(initialTask.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
        let additions = normalizedPaths.filter { !existing.contains(Self.canonicalPath($0)) }
        if !additions.isEmpty {
            _ = try await addRepositories(
                id,
                repositoryPaths: additions,
                duringActiveConversation: duringActiveConversation
            )
        }

        let latestTask = try requireTask(id)
        let removals = latestTask.repositoryWorktrees
            .filter { !desired.contains(Self.canonicalPath($0.repositoryPath)) }
        for record in removals {
            do {
                _ = try await removeRepository(
                    id,
                    worktree: .record(record),
                    duringActiveConversation: duringActiveConversation
                )
            } catch {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "The replacement repositories were added, but the old repository \(record.repositoryPath) couldn't be removed. The task keeps both contexts. \(error.localizedDescription)"
                )
            }
        }
        return try get(id)
    }

    /// Works out a pending worktree's undecided branch-from and merge target (see
    /// `RepositoryWorktreeRecord.hasUndecidedDefaults`) and saves them, so its settings
    /// show what the task will start from. A record that changed meanwhile is left to the newer change.
    @discardableResult
    func resolveRepositoryDefaults(_ id: UUID, worktree selector: RepositoryWorktreeSelector) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        let initialRecord = try repositoryRecord(selector, in: initialTask)
        guard initialRecord.hasUndecidedDefaults else { return BoardTaskRecord(task: initialTask) }
        let resolved = try await worktreeService.resolvingDefaults(of: initialRecord)
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            if let index = task.repositoryWorktrees.firstIndex(where: { $0 == initialRecord }) {
                var repositories = task.repositoryWorktrees
                repositories[index] = resolved
                task.repositoryWorktrees = repositories
                try await saveTaskContext(taskID: id)
            }
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func updateRepository(
        _ id: UUID,
        worktree selector: RepositoryWorktreeSelector,
        branch: String,
        branchFrom: String,
        mergeTarget: String?
    ) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }
        guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branchFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Branch and merge-from values can't be empty.")
        }
        let initialRecord = try repositoryRecord(selector, in: initialTask)
        guard initialRecord.isPending else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repository settings are locked after the task starts.")
        }
        let validated = try await worktreeService.pendingRecord(
            spec: RepositoryWorktreeSpec(
                repositoryPath: initialRecord.repositoryPath,
                branch: branch,
                branchFrom: branchFrom,
                mergeTarget: mergeTarget
            )
        )

        return try await withConversationTurnReservation(id) {
            try await withTaskOperationLock(id) {
                try await withRepositoryAllocationLocks([validated.repositoryPath]) {
                    let task = try requireTask(id)
                    guard task.status != .done,
                          let index = task.repositoryWorktrees.firstIndex(where: { $0 == initialRecord || initialRecord.isUndecidedForm(of: $0) }) else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repository settings changed while they were being validated. Try again.")
                    }
                    var validated = validated
                    if RepositoryWorktreeRecord.isAutomaticBranch(validated.branch) {
                        var siblings = task.repositoryWorktrees
                        siblings.remove(at: index)
                        validated.branch = RepositoryWorktreeRecord.automaticBranch(for: validated.repositoryPath, among: siblings)
                    }
                    if !RepositoryWorktreeRecord.isAutomaticBranch(validated.branch), let sibling = task.repositoryWorktrees.enumerated().first(where: {
                        $0.offset != index && Self.canonicalPath($0.element.repositoryPath) == Self.canonicalPath(validated.repositoryPath) && $0.element.branch == validated.branch
                    }) {
                        throw BridgeCommandError(
                            code: "invalid_argument",
                            message: "Another worktree of this task already uses branch '\(validated.branch)': \(sibling.element.worktreePath)"
                        )
                    }
                    try validateRepositoryAssignments([validated], excludingTaskID: id)
                    var repositories = task.repositoryWorktrees
                    repositories[index] = validated
                    task.repositoryWorktrees = repositories
                    try await saveTaskContext(taskID: id)
                    return BoardTaskRecord(task: task)
                }
            }
        }
    }

    @discardableResult
    func removeRepository(
        _ id: UUID,
        worktree selector: RepositoryWorktreeSelector,
        duringActiveConversation: Bool = false
    ) async throws -> BoardTaskRecord {
        if duringActiveConversation {
            return try await removeRepositoryWhileTurnReserved(
                id,
                worktree: selector,
                deferWorktreeRemovalUntilTurnEnds: true
            )
        }
        return try await withConversationTurnReservation(id) {
            try await self.removeRepositoryWhileTurnReserved(id, worktree: selector)
        }
    }

    /// Starts follow-up Git work in a repository whose pull request merged: the merged
    /// record is retired to `pastRepositoryWorktrees` (keeping its PR link on the card) and a
    /// fresh worktree on a new branch is created from the merge target as the remote has it
    /// now. A Done task (whose worktrees are already gone) may always renew: it moves back to
    /// In Progress with a fresh worktree for every repository whose worktree was removed. The
    /// old worktree, when still present, is removed once the current turn ends.
    @discardableResult
    func renewRepository(_ id: UUID, worktree selector: RepositoryWorktreeSelector) async throws -> BoardTask {
        PlayhouseDiagnostics.record("workspace.repository.renew.started", fields: [
            "taskID": id.uuidString,
            "repositoryPath": selector.repositoryPath ?? "",
            "worktreePath": selector.worktreePath ?? ""
        ])
        let initialTask = try requireTask(id)
        let initialRecord = try repositoryRecord(selector, in: initialTask)
        let wasDone = initialTask.status == .done
        if !wasDone {
            guard let number = initialRecord.pullRequestNumber else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "This repository has no merged pull request, so keep working in its worktree: \(initialRecord.worktreePath)"
                )
            }
            var merged = initialRecord.isPullRequestMerged
            if !merged {
                let executable = try pullRequestService.resolveExecutable()
                merged = try await pullRequestService.isMerged(initialRecord, executable: executable)
            }
            guard merged else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "Pull request #\(number) isn't merged yet, so keep working in its worktree: \(initialRecord.worktreePath)"
                )
            }
        }
        let oldWorktreeExists = initialRecord.createdByPlayhouse && !initialRecord.isPending
            && FileManager.default.fileExists(atPath: initialRecord.worktreePath)
        if oldWorktreeExists, try await worktreeService.hasChanges(initialRecord) {
            throw BridgeCommandError(
                code: "operation_failed",
                message: "The merged worktree has uncommitted changes: \(initialRecord.worktreePath). Carry them over or discard them, then renew again."
            )
        }
        // Moving to Done removed every managed worktree, so reopening a Done task renews
        // each repository whose worktree is gone, not only the one asked for.
        let renewed = wasDone
            ? initialTask.repositoryWorktrees.filter {
                $0 == initialRecord || (!$0.isPending && !FileManager.default.fileExists(atPath: $0.worktreePath))
            }
            : [initialRecord]
        var replacements: [(old: RepositoryWorktreeRecord, fresh: RepositoryWorktreeRecord)] = []
        for record in renewed {
            let base = try await worktreeService.freshMergeTargetBase(
                repositoryPath: record.repositoryPath,
                mergeTarget: record.mergeTarget
            )
            replacements.append((record, try await worktreeService.pendingRecord(spec: RepositoryWorktreeSpec(
                repositoryPath: record.repositoryPath,
                branch: nil,
                branchFrom: base,
                mergeTarget: record.mergeTarget
            ))))
        }
        try await withTaskOperationLock(id) {
            try await withRepositoryAllocationLocks(renewed.map(\.repositoryPath)) {
                let task = try requireTask(id)
                guard task.repositoryWorktrees == initialTask.repositoryWorktrees, task.status == initialTask.status else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its repository was being renewed. Try again.")
                }
                let repositories = task.repositoryWorktrees.map { record in
                    replacements.first { $0.old == record }?.fresh ?? record
                }
                task.repositoryWorktrees = repositories
                retirePullRequests(replacements.map(\.old).map { record in
                    var retired = record
                    // Outside Done, renewing first confirmed the pull request merged.
                    if !wasDone { retired.isPullRequestMerged = true }
                    return retired
                }, on: task)
                task.workspaceRootPaths = try Self.normalizeOptionalRoots(
                    repositories.map { $0.isPending ? $0.repositoryPath : $0.worktreePath } + task.contextFolderPaths
                )
                if wasDone {
                    task.status = .inProgress
                    task.lifecycleRevision += 1
                    task.statusMessage = nil
                }
                try await saveTaskContext(taskID: id)
            }
        }
        let prepared = try await prepareRepositoryWorktrees(id)
        if oldWorktreeExists {
            let intentURL = try queueDeferredRepositoryRemoval(taskID: id, record: initialRecord)
            scheduleDeferredWorktreeRemoval(taskID: id, record: initialRecord, intentURL: intentURL)
        }
        PlayhouseDiagnostics.record("workspace.repository.renew.succeeded", fields: [
            "taskID": id.uuidString,
            "repositoryPath": initialRecord.repositoryPath,
            "retiredBranch": initialRecord.branch,
            "renewedRepositoryCount": String(renewed.count),
            "reopened": String(wasDone)
        ])
        return prepared
    }

    /// Moves a Done task back to In Progress for a follow-up turn, so a task an agent is
    /// working on sits in the board's columns rather than the archive. Moving to Done removed
    /// its managed worktrees, so each one is renewed from the merge target first.
    @discardableResult
    func reopenDoneTask(_ id: UUID) async throws -> BoardTask {
        let task = try requireTask(id)
        guard task.status == .done else { return task }
        if let removed = task.repositoryWorktrees.first(where: {
            !$0.isPending && !FileManager.default.fileExists(atPath: $0.worktreePath)
        }) {
            return try await renewRepository(id, worktree: .record(removed))
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .done else { return task }
            task.status = .inProgress
            task.lifecycleRevision += 1
            task.statusMessage = nil
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.reopened", fields: ["taskID": id.uuidString])
            return task
        }
    }

    /// Removes a worktree the task no longer uses once its current turn ends, because the
    /// turn's provider may still run in it. A restart picks the intent up through
    /// `reconcileDeferredRepositoryRemovals`.
    func scheduleDeferredWorktreeRemoval(taskID id: UUID, record: RepositoryWorktreeRecord, intentURL deferredIntentURL: URL?) {
        // Runs after this request returns, once the task's turn ends; keep
        // this request's environment and diagnostics routing for it.
        let requestContext = PlayhouseRequestContext.capture()
        Task.detached { @MainActor in
            await requestContext.run {
                do {
                    PlayhouseDiagnostics.record("workspace.repository.deferred_removal_waiting", fields: [
                        "taskID": id.uuidString,
                        "repositoryPath": record.repositoryPath,
                        "worktreePath": record.worktreePath
                    ])
                    try await self.withConversationTurnReservation(id) {
                        try await self.withTaskOperationLock(id) {
                            guard let deferredIntentURL,
                                  FileManager.default.fileExists(atPath: deferredIntentURL.path) else { return }
                            if try self.isRepositoryAttached(record, to: id) {
                                try self.clearDeferredRepositoryRemoval(at: deferredIntentURL)
                                return
                            }
                            PlayhouseDiagnostics.record("workspace.repository.deferred_removal_reservation_acquired", fields: [
                                "taskID": id.uuidString,
                                "repositoryPath": record.repositoryPath,
                                "worktreePath": record.worktreePath
                            ])
                            if try await self.worktreeService.hasChanges(record) {
                                PlayhouseDiagnostics.record("workspace.repository.deferred_removal_kept_dirty", fields: [
                                    "taskID": id.uuidString,
                                    "repositoryPath": record.repositoryPath,
                                    "worktreePath": record.worktreePath
                                ])
                                try self.clearDeferredRepositoryRemoval(at: deferredIntentURL)
                                return
                            }
                            try await self.worktreeService.remove(record)
                            PlayhouseDiagnostics.record("workspace.repository.deferred_removal_succeeded", fields: [
                                "taskID": id.uuidString,
                                "repositoryPath": record.repositoryPath,
                                "worktreePath": record.worktreePath
                            ])
                            try self.clearDeferredRepositoryRemoval(at: deferredIntentURL)
                        }
                    }
                } catch {
                    PlayhouseDiagnostics.record("workspace.repository.deferred_removal_failed", fields: [
                        "taskID": id.uuidString,
                        "repositoryPath": record.repositoryPath,
                        "worktreePath": record.worktreePath,
                        "error": error.localizedDescription
                    ])
                }
            }
        }
    }

    func removeRepositoryWhileTurnReserved(
        _ id: UUID,
        worktree selector: RepositoryWorktreeSelector,
        deferWorktreeRemovalUntilTurnEnds: Bool = false
    ) async throws -> BoardTaskRecord {
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status != .done else {
                throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
            }
            let record = try repositoryRecord(selector, in: task)
            let originalRepositories = task.repositoryWorktrees
            let originalRoots = task.workspaceRootPaths
            let updatedRepositories = originalRepositories.filter { !$0.isSameWorktree(as: record) }
            let roots = try Self.normalizeOptionalRoots(updatedRepositories.map(\.worktreePath) + task.contextFolderPaths)
            // A task with no repository roots is a valid standalone conversation.
            let shouldRemoveWorktree = record.createdByPlayhouse && !record.isPending
                && FileManager.default.fileExists(atPath: record.worktreePath)

            return try await withRepositoryAllocationLocks([record.repositoryPath]) {
                let currentTask = try requireTask(id)
                guard currentTask.status != .done,
                      currentTask.repositoryWorktrees == originalRepositories,
                      currentTask.workspaceRootPaths == originalRoots else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its repository was being checked. Try again.")
                }
                if shouldRemoveWorktree, try await worktreeService.hasChanges(record) {
                    throw BridgeCommandError(
                        code: "operation_failed",
                        message: "Can't remove this repository because its worktree has uncommitted changes: \(record.worktreePath)"
                    )
                }

                let deferredIntentURL = shouldRemoveWorktree && deferWorktreeRemovalUntilTurnEnds
                    ? try queueDeferredRepositoryRemoval(taskID: id, record: record)
                    : nil

                currentTask.repositoryWorktrees = updatedRepositories
                currentTask.workspaceRootPaths = roots
                do {
                    try await saveTaskContext(taskID: id)
                } catch {
                    currentTask.repositoryWorktrees = originalRepositories
                    currentTask.workspaceRootPaths = originalRoots
                    throw error
                }

                if shouldRemoveWorktree {
                    if deferWorktreeRemovalUntilTurnEnds {
                        PlayhouseDiagnostics.record("workspace.repository.deferred_removal_scheduled", fields: [
                            "taskID": id.uuidString,
                            "repositoryPath": record.repositoryPath,
                            "worktreePath": record.worktreePath
                        ])
                        scheduleDeferredWorktreeRemoval(taskID: id, record: record, intentURL: deferredIntentURL)
                    } else {
                    do {
                        try await worktreeService.remove(record)
                    } catch {
                        let removalError = error
                        guard let current = try? requireTask(id),
                              current.repositoryWorktrees == updatedRepositories,
                              current.workspaceRootPaths == roots else {
                            throw removalError
                        }
                        current.repositoryWorktrees = originalRepositories
                        current.workspaceRootPaths = originalRoots
                        do {
                            try await saveTaskContext(taskID: id)
                        } catch {
                            throw BridgeCommandError(
                                code: "operation_failed",
                                message: "Couldn't remove the repository worktree (\(removalError.localizedDescription)) or restore its task record (\(error.localizedDescription))."
                            )
                        }
                        throw removalError
                    }
                    }
                }
                return try get(id)
            }
        }
    }

    @discardableResult
    func move(
        _ id: UUID,
        to statusName: String,
        allowUnmergedPullRequests: Bool = false,
        allowDiscardingUncommittedChanges: Bool = false,
        skipMergeVerification: Bool = false
    ) async throws -> BoardTaskRecord {
        PlayhouseDiagnostics.record("task.move.started", fields: [
            "taskID": id.uuidString,
            "requestedStatus": statusName,
            "allowUnmergedPullRequests": String(allowUnmergedPullRequests),
            "allowDiscardingUncommittedChanges": String(allowDiscardingUncommittedChanges),
            "skipMergeVerification": String(skipMergeVerification)
        ])
        guard let status = TaskStatus(rawValue: statusName) else {
            throw PlayhouseManagerError.invalidStatus(statusName)
        }
        // Review has its own gate (`moveToReview`); every other status is set by
        // the conversation itself.
        guard status == .done else {
            throw PlayhouseManagerError.invalidTransition("Task status is controlled by Codex. Start or continue a conversation to update it.")
        }
        let requestedSource = try requireTask(id).status
        let moveToDone: @MainActor () async throws -> BoardTaskRecord = { [self] in try await withTaskOperationLock(id) {
            let initialTask = try requireTask(id)
            guard initialTask.status != .done else { return BoardTaskRecord(task: initialTask) }
            let sourceStatus = initialTask.status
            guard TaskStatus.manualDoneSources.contains(sourceStatus) else {
                throw PlayhouseManagerError.invalidTransition("Only a task in Review, Waiting Response or Blocked can move to Done.")
            }
            // The turn reservation was chosen for the status read before this lock.
            guard sourceStatus == requestedSource else {
                throw PlayhouseManagerError.invalidTransition("The task's status changed before it could move to Done. Try again.")
            }

            let originalRepositories = initialTask.repositoryWorktrees
            // A closed pull request never merges; it doesn't hold the task back.
            let linkedRecords = originalRepositories.filter { $0.pullRequestNumber != nil && !$0.isPullRequestClosed }
            if !linkedRecords.isEmpty && !allowUnmergedPullRequests && !skipMergeVerification {
                let executable = try pullRequestService.resolveExecutable()
                var unmerged: [RepositoryWorktreeRecord] = []
                for record in linkedRecords {
                    let isMerged = try await pullRequestService.isMerged(record, executable: executable)
                    if !isMerged { unmerged.append(record) }
                }
                if !unmerged.isEmpty {
                    throw PlayhouseManagerError.unmergedPullRequests(unmerged.compactMap(\.pullRequestNumber))
                }
            }
            let task = try requireTask(id)
            guard task.status == sourceStatus else {
                throw PlayhouseManagerError.invalidTransition("The task's status changed before it could move to Done. Try again.")
            }
            guard task.repositoryWorktrees == originalRepositories else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task's pull request links changed while they were being checked. Try again.")
            }
            let removable = originalRepositories.filter { !$0.isPending && $0.createdByPlayhouse }
            if !allowDiscardingUncommittedChanges {
                // Removing a worktree deletes whatever was never committed, so the
                // caller must confirm before that happens.
                var dirty: [String] = []
                for record in removable where FileManager.default.fileExists(atPath: record.worktreePath) {
                    if try await worktreeService.hasChanges(record) { dirty.append(record.worktreePath) }
                }
                if !dirty.isEmpty { throw PlayhouseManagerError.uncommittedChanges(dirty) }
            }
            try await withRepositoryAllocationLocks(originalRepositories.map(\.repositoryPath)) {
                for record in removable {
                    try await worktreeService.removeAfterConfirmation(record)
                }
            }
            task.status = .done
            task.statusMessage = nil
            if !allowUnmergedPullRequests {
                // Every linked pull request was confirmed merged on the way to Done.
                task.repositoryWorktrees = task.repositoryWorktrees.map { record in
                    var record = record
                    if record.pullRequestNumber != nil, !record.isPullRequestClosed { record.isPullRequestMerged = true }
                    return record
                }
            }
            clearProgressReport(task)
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.move.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        } }
        guard requestedSource != .review, TaskStatus.manualDoneSources.contains(requestedSource) else { return try await moveToDone() }
        // A blocking question shows Waiting Response while its turn still runs, and a reply
        // can start one mid-move; hold the reservation so no turn uses the worktrees this
        // move removes.
        guard let moved = try await withConversationTurnReservationIfFree(id, operation: moveToDone) else {
            throw PlayhouseManagerError.invalidTransition("This task's conversation turn is still running. Answer or stop it before moving the task to Done.")
        }
        return moved
    }
}
