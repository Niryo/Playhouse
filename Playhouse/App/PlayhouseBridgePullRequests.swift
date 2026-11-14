import Foundation

extension PlayhouseBridgeRuntime {
    func pullRequestOperation(
        _ request: BridgeRequest,
        taskManager: BoardTaskManager,
        settings: WorkspaceSettingsManager,
        conversationClients: () -> ConversationClients,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async throws -> BridgeValue {
        switch request.command {
        case "task.pr.auto":
            let mode: PullRequestMode = request.arguments["enabled"]?.bool == true ? .pullRequest : .manual
            return try Self.value(await taskManager.setPullRequestMode(request.requiredUUID("taskID"), mode: mode))
        case "task.pr.mode":
            let mode = try PullRequestMode.parse(request.requiredString("mode"))
            return try Self.value(await taskManager.setPullRequestMode(request.requiredUUID("taskID"), mode: mode))
        case "task.pr.autopilot":
            let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
            return try Self.value(await conversations.runPullRequestAutopilot(
                taskID: request.requiredUUID("taskID"),
                onStatus: { states in
                    if let payload = try? Self.value(states) {
                        eventHandler(BridgeEvent(requestID: request.id, type: "autopilot_status", payload: payload))
                    }
                }
            ))
        case "task.pr.create":
            return try Self.value(await taskManager.createPullRequests(
                request.requiredUUID("taskID"), clients: conversationClients(), settingsManager: settings
            ))
        case "task.pr.conflicts":
            return .object(["repositories": .array(try await taskManager.pullRequestConflictRepositories(request.requiredUUID("taskID")).map(BridgeValue.string))])
        case "task.pr.status":
            return try Self.value(await taskManager.reviewPullRequests(request.requiredUUID("taskID")))
        case "task.pr.verify":
            return .object(["status": .string(try await taskManager.verifyPullRequestResolution(request.requiredUUID("taskID")).rawValue)])
        case "task.pr.resolve":
            return try Self.value(await taskManager.resolvePullRequestConflicts(
                request.requiredUUID("taskID"), action: request.requiredString("action"), clients: conversationClients()
            ))
        case "task.pr.sync":
            let taskID = try request.requiredUUID("taskID")
            // An active turn owns the worktree; its completion gate syncs after it releases it.
            if try taskManager.hasConversationTurnReservation(taskID) {
                return .object([
                    "records": .array([]),
                    "status": .string(try taskManager.taskModel(taskID).status.rawValue),
                    "skipped": .string("turn-active")
                ])
            }
            let records = try await taskManager.syncPullRequestChangesOrBlock(taskID, clients: conversationClients())
            return .object([
                "records": try .encoding(records),
                "status": .string(try taskManager.taskModel(taskID).status.rawValue)
            ])
        default:
            throw BridgeCommandError(code: "unsupported_command", message: "Unsupported pull request command: \(request.command).")
        }
    }
}
