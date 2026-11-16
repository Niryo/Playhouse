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
        // One pass of the `pull-request-mode` plugin's Green (`merge` false) or
        // Merge (`merge` true) mode.
        case "task.pr.autopilot":
            let taskID = try request.requiredUUID("taskID")
            defer { PullRequestStatusCache.invalidate(request, taskID: taskID) }
            let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
            return try Self.value(await conversations.runPullRequestAutopilot(
                taskID: taskID,
                merge: request.arguments["merge"]?.bool ?? false,
                resetAttempts: request.arguments["resetAttempts"]?.bool ?? false,
                // `confirmWith`: the plugin whose service started the pass, asked
                // again right before it merges or sends a fix turn.
                confirm: { action in
                    guard let pluginID = request.arguments["confirmWith"]?.string else { return true }
                    return await PluginServiceHost.confirm(pluginID: pluginID, action: action, taskID: taskID.uuidString, origin: request)
                },
                onStatus: { states in
                    if let payload = try? Self.value(states) {
                        eventHandler(BridgeEvent(requestID: request.id, type: "autopilot_status", payload: payload))
                    }
                }
            ))
        case "task.pr.create":
            let taskID = try request.requiredUUID("taskID")
            defer { PullRequestStatusCache.invalidate(request, taskID: taskID) }
            // `ifNeeded`: only when a repository still waits for its pull request,
            // as reaching Review in a mode that opens them asks.
            if request.arguments["ifNeeded"]?.bool == true,
               try !taskManager.taskModel(taskID).repositoryWorktrees.contains(where: \.awaitsPullRequest) {
                return try Self.value(BoardTaskRecord(task: taskManager.taskModel(taskID)))
            }
            return try Self.value(await taskManager.createPullRequests(
                taskID, clients: conversationClients(), settingsManager: settings
            ))
        case "task.pr.conflicts":
            return .object(["repositories": .array(try await taskManager.pullRequestConflictRepositories(request.requiredUUID("taskID")).map(BridgeValue.string))])
        case "task.pr.status":
            let taskID = try request.requiredUUID("taskID")
            let reviewThreads = request.arguments["reviewThreads"]?.bool ?? false
            // `shared`: a probe that may reuse another caller's recent answer.
            guard request.arguments["shared"]?.bool == true else {
                return try Self.value(await taskManager.reviewPullRequests(taskID, includeReviewThreads: reviewThreads))
            }
            return try Self.value(await PullRequestStatusCache.states(request, taskID: taskID, reviewThreads: reviewThreads) {
                try await taskManager.reviewPullRequests(taskID, includeReviewThreads: reviewThreads)
            })
        case "task.pr.verify":
            return .object(["status": .string(try await taskManager.verifyPullRequestResolution(request.requiredUUID("taskID")).rawValue)])
        case "task.pr.resolve":
            defer { if let taskID = try? request.requiredUUID("taskID") { PullRequestStatusCache.invalidate(request, taskID: taskID) } }
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
            defer { PullRequestStatusCache.invalidate(request, taskID: taskID) }
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

/// Keeps a `shared` `task.pr.status` from asking GitHub again for the same
/// task within a few seconds: the task card's pull request plugin and other
/// plugins all probe on focus and on moves, often together, while an explicit
/// read (the CLI's, without `--shared`) always asks GitHub. A probe already
/// running is shared by everyone who asks during it, and a result is reused
/// for `ttl` seconds. Creating, syncing, resolving or following a task's pull
/// requests forgets its entry, since they change what GitHub reports.
@MainActor
enum PullRequestStatusCache {
    private struct Entry {
        var task: Task<[PullRequestReviewState], Error>
        var finishedAt: Date?
    }

    private static var entries: [String: Entry] = [:]

    static var ttl: TimeInterval {
        PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_PR_STATUS_CACHE_SECONDS"].flatMap(TimeInterval.init) ?? 3
    }

    static func states(
        _ request: BridgeRequest,
        taskID: UUID,
        reviewThreads: Bool,
        probe: @escaping @MainActor () async throws -> [PullRequestReviewState]
    ) async throws -> [PullRequestReviewState] {
        let key = "\(prefix(request, taskID: taskID))\(reviewThreads)"
        if let entry = entries[key] {
            if let finishedAt = entry.finishedAt, Date().timeIntervalSince(finishedAt) > ttl {
                entries[key] = nil
            } else {
                PlayhouseDiagnostics.record("task.pr.status.shared", fields: ["taskID": taskID.uuidString, "running": String(entry.finishedAt == nil)])
                return try await entry.task.value
            }
        }
        let task = Task { @MainActor in try await probe() }
        entries[key] = Entry(task: task)
        do {
            let states = try await task.value
            if entries[key]?.task == task { entries[key]?.finishedAt = Date() }
            return states
        } catch {
            // A failed probe isn't kept; the next caller asks GitHub again.
            if entries[key]?.task == task { entries[key] = nil }
            throw error
        }
    }

    static func invalidate(_ request: BridgeRequest, taskID: UUID) {
        let prefix = prefix(request, taskID: taskID)
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    private static func prefix(_ request: BridgeRequest, taskID: UUID) -> String {
        "\(request.dataDirectory ?? "default"):\(taskID.uuidString):"
    }
}
