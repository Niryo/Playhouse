import Foundation

extension PlayhouseBridgeRuntime {
    package func taskWorkspaceOperation(
        _ request: BridgeRequest,
        taskManager: BoardTaskManager,
        workspaces: WorkspaceManager,
        settings: WorkspaceSettingsManager
    ) async throws -> BridgeValue {
        switch request.command {
        case "task.rename":
            return try Self.value(try await taskManager.rename(request.requiredUUID("taskID"), title: request.requiredString("title")))
        case "task.repository.add":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await workspaces.addRepository(request.requiredString("repositoryPath"), to: request.requiredUUID("taskID")))
        case "task.repository.add-batch":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await workspaces.addRepositories(request.requiredStrings("repositoryPaths"), to: request.requiredUUID("taskID")))
        case "task.repository.replace":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await workspaces.replaceRepositories(request.requiredStrings("repositoryPaths"), on: request.requiredUUID("taskID")))
        case "task.repository.recent":
            let taskID = try request.requiredUUID("taskID")
            try Self.rejectStandaloneChat(taskManager, taskID)
            return .object(["repositories": .array(try workspaces.recentRepositorySuggestions(for: taskID).map(BridgeValue.string))])
        case "task.repository.add-worktree":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await workspaces.addWorktree(
                request.requiredString("repositoryPath"), to: request.requiredUUID("taskID"),
                branch: request.arguments["branch"]?.string, branchFrom: request.arguments["branchFrom"]?.string
            ))
        case "task.repository.edit":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await taskManager.updateRepository(
                request.requiredUUID("taskID"), worktree: Self.worktreeSelector(request),
                branch: request.requiredString("branch"), branchFrom: request.requiredString("branchFrom"),
                mergeTarget: request.arguments["mergeTarget"]?.string
            ))
        case "task.repository.resolve":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await taskManager.resolveRepositoryDefaults(
                request.requiredUUID("taskID"), worktree: Self.worktreeSelector(request)
            ))
        case "task.repository.renew":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await workspaces.renewRepository(Self.worktreeSelector(request), on: request.requiredUUID("taskID")))
        case "task.repository.remove":
            // Removal remains available to clean up repositories from older standalone chats.
            return try Self.value(await workspaces.removeRepository(Self.worktreeSelector(request), from: request.requiredUUID("taskID")))
        case "task.prompt.save":
            let status = try request.arguments["status"]?.string.map { value -> TaskStatus in
                guard let status = TaskStatus(rawValue: value) else { throw PlayhouseManagerError.invalidStatus(value) }
                return status
            }
            guard let prompt = request.arguments["prompt"]?.string else {
                throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: prompt.")
            }
            let submitted = request.arguments["submitted"]?.bool ?? false
            guard !submitted || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeCommandError(code: "invalid_argument", message: "A submitted prompt must contain text.")
            }
            return try Self.value(try await taskManager.savePrompt(
                request.requiredUUID("taskID"), prompt: prompt, status: status, submitted: submitted,
                imageDataURLs: request.arguments["images"]?.strings
            ))
        case "task.draft.save":
            guard let prompt = request.arguments["prompt"]?.string else {
                throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: prompt.")
            }
            return try Self.value(try await taskManager.saveDraft(
                request.requiredUUID("taskID"), prompt: prompt, imageDataURLs: request.arguments["images"]?.strings ?? []
            ))
        case "task.comments.save":
            guard let json = request.arguments["comments"]?.string, let data = json.data(using: .utf8),
                  (try? JSONDecoder().decode([ConversationAnnotation].self, from: data)) != nil else {
                throw BridgeCommandError(code: "invalid_argument", message: "Pass comments as a JSON array of comment objects.")
            }
            return try Self.value(try await taskManager.savePendingAnnotations(
                request.requiredUUID("taskID"), data: data, appending: request.arguments["append"]?.bool ?? false
            ))
        case "task.comments.edit":
            return try Self.value(try await taskManager.editPendingAnnotation(
                request.requiredUUID("taskID"), annotationID: request.requiredUUID("commentID"),
                comment: request.arguments["text"]?.string ?? ""
            ))
        case "task.roots.get", "workspace.roots":
            return .object(["roots": .array(try workspaces.roots(for: request.requiredUUID("taskID")).map(BridgeValue.string))])
        case "task.roots.set":
            try Self.rejectStandaloneChat(taskManager, request.requiredUUID("taskID"))
            return try Self.value(await workspaces.setRoots(request.requiredStrings("roots"), for: request.requiredUUID("taskID")))
        case "task.terminal":
            return try Self.value(workspaces.terminalLaunch(for: request.requiredUUID("taskID")))
        case "task.changes.list":
            return try Self.value(await workspaces.changes(for: request.requiredUUID("taskID")))
        case "task.changes.mark-viewed":
            try await workspaces.markViewed(for: request.requiredUUID("taskID"), repository: request.requiredString("repository"), path: request.requiredString("path"))
            return .object(["viewed": .boolean(true)])
        case "task.changes.mark-all-viewed":
            let count = try await workspaces.markAllViewed(for: request.requiredUUID("taskID"))
            return .object(["markedCount": .integer(count)])
        case "task.changes.mark-unviewed":
            try await workspaces.markUnviewed(for: request.requiredUUID("taskID"), repository: request.requiredString("repository"), path: request.requiredString("path"))
            return .object(["viewed": .boolean(false)])
        case "task.changes.diff":
            return try Self.value(await workspaces.diff(
                for: request.requiredUUID("taskID"), repository: request.requiredString("repository"),
                path: request.requiredString("path"), group: request.requiredString("group")
            ))
        case "workspace.suggest":
            let repositories = try await workspaces.suggestedRepositories(parentPath: request.requiredString("parent"))
            return .object(["repositories": .array(repositories.map(BridgeValue.string))])
        case "workspace.repositories.list":
            let root = try settings.requireRepositoryRootFolder()
            let repositories = try await workspaces.suggestedRepositories(parentPath: root.path)
            return .object(["root": .string(root.path), "repositories": .array(repositories.map(BridgeValue.string))])
        case "task.progress.publish":
            let rawType = try request.requiredString("type")
            guard let type = TaskProgressType(rawValue: rawType) else {
                throw BridgeCommandError(code: "invalid_argument", message: "Unknown progress type '\(rawType)'. Valid types: \(TaskProgressType.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return try Self.value(try await taskManager.publishProgressReport(
                request.requiredUUID("taskID"), type: type, detail: request.arguments["detail"]?.string
            ))
        case "task.progress.custom":
            return try Self.value(try await taskManager.publishProgressReport(
                request.requiredUUID("taskID"), type: nil, customLabel: request.requiredString("label"),
                detail: request.arguments["detail"]?.string
            ))
        case "task.progress.clear":
            return try Self.value(try await taskManager.clearProgressReport(request.requiredUUID("taskID")))
        case "task.outcome":
            let taskID = try request.requiredUUID("taskID")
            let report = try await taskManager.reportTurnOutcome(
                taskID, outcome: request.requiredString("outcome"), reason: request.arguments["reason"]?.string
            )
            var result: [String: BridgeValue] = [
                "outcome": .string(report.outcome),
                "taskStatus": .string(try taskManager.conversationSubject(taskID).status.rawValue),
                "recorded": .boolean(report.message == nil),
            ]
            if let message = report.message { result["message"] = .string(message) }
            return .object(result)
        default:
            throw BridgeCommandError(code: "unsupported_command", message: "Unsupported task workspace command: \(request.command).")
        }
    }
}

extension PlayhouseBridgeRuntime {
    /// The worktree a request names: `repositoryPath` when the task has one worktree
    /// of it, else `worktreePath`; `worktreeBranch` picks among records not started yet.
    package static func worktreeSelector(_ request: BridgeRequest) throws -> RepositoryWorktreeSelector {
        func value(_ name: String) -> String? {
            request.arguments[name]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let selector = RepositoryWorktreeSelector(
            repositoryPath: value("repositoryPath"), worktreePath: value("worktreePath"), branch: value("worktreeBranch")
        )
        guard selector.repositoryPath != nil || selector.worktreePath != nil else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: repositoryPath or worktreePath.")
        }
        return selector
    }
}
