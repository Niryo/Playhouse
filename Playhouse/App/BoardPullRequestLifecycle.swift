import Foundation
import SwiftData

extension BoardTaskManager {
    /// Carries each task's pull request mode, which the task kept before the
    /// `pull-request-mode` plugin owned it, into the plugin's state, once. A
    /// task created since reads as the default mode (`BoardTask.init`), so it
    /// is skipped wherever it was created; the bridge runs this at the start of
    /// every request.
    func importLegacyPullRequestModes(into settings: WorkspaceSettingsManager) throws {
        guard !settings.legacyPullRequestModesImported else { return }
        let state = settings.pluginState(BuiltInPlugins.pullRequestModeID)
        var imported = 0
        for task in try modelContext.fetch(FetchDescriptor<BoardTask>()) {
            let mode = task.legacyPullRequestMode
            guard mode != PullRequestMode.defaultMode, state[task.id.uuidString] == nil else { continue }
            settings.setPluginState(BuiltInPlugins.pullRequestModeID, key: task.id.uuidString, value: .string(mode.rawValue))
            imported += 1
        }
        settings.legacyPullRequestModesImported = true
        PlayhouseDiagnostics.record("plugin.pull_request_mode.imported", fields: ["count": String(imported)])
    }

    /// Autopilot gives up after this many fix turns that never got the PRs green,
    /// even when each one changed something.
    static let maxPullRequestAutopilotFixAttempts = 5

    /// What autopilot should do about a task's probed pull requests. Shared by the
    /// board's probe (to decide whether to ask the daemon at all) and the daemon's
    /// `task.pr.autopilot` command (which acts on it).
    enum PullRequestAutopilotAssessment: String, Codable, Sendable {
        case merged, green, pending, needsFix = "needs-fix"
    }

    static func assessPullRequestAutopilot(_ states: [PullRequestReviewState]) -> PullRequestAutopilotAssessment {
        let open = states.filter { !$0.merged }
        guard !open.isEmpty else { return .merged }
        // A local head GitHub hasn't received yet is the review sync's to push
        // first; a fix turn now would race it for the worktree.
        if open.contains(where: { !$0.hasConflicts && $0.headRefOid != nil && $0.headRefOid != $0.localHeadOid }) { return .pending }
        if open.contains(where: { $0.health == .red || ($0.unresolvedReviewThreads ?? 0) > 0 }) { return .needsFix }
        if open.contains(where: { $0.health == .pending }) { return .pending }
        return .green
    }

    /// Identifies a red state so the same unchanged failure is never sent twice.
    static func pullRequestAutopilotSignature(_ states: [PullRequestReviewState]) -> String {
        states.filter { !$0.merged }.map { state in
            [
                String(state.number), state.headRefOid ?? "-", state.checks.rawValue,
                state.failingChecks.joined(separator: ","), state.mergeable,
                String(state.unresolvedReviewThreads ?? 0)
            ].joined(separator: ":")
        }.sorted().joined(separator: "|")
    }

    enum PullRequestAutopilotClaim {
        /// Send a fix turn for this red state.
        case fix
        /// Stop the loop: the task moved to Waiting Response with this reason.
        case stalled(String)
    }

    /// Records a fix attempt for a red state, or stops the loop when the same
    /// state was already sent or the attempt budget is spent.
    func claimPullRequestAutopilotFix(_ id: UUID, signature: String) async throws -> PullRequestAutopilotClaim {
        let reason: String? = try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            if task.pullRequestAutopilotLastFixSignature == signature {
                return "Autopilot already asked \(task.conversationProvider.displayName) to fix this pull request state, and nothing changed. Review the pull request, then send a message to continue."
            }
            if task.pullRequestAutopilotFixAttempts >= Self.maxPullRequestAutopilotFixAttempts {
                return "Autopilot sent \(Self.maxPullRequestAutopilotFixAttempts) fix turns without getting the pull request green. Review it, then send a message to continue."
            }
            task.pullRequestAutopilotFixAttempts += 1
            task.pullRequestAutopilotLastFixSignature = signature
            try await saveTaskContext(taskID: id)
            return nil
        }
        if let reason {
            _ = try await setLifecycleStatus(id, to: .waitingResponse, message: reason)
            PlayhouseDiagnostics.record("task.pr.autopilot.stalled", fields: ["taskID": id.uuidString])
            return .stalled(reason)
        }
        return .fix
    }

    /// Gives back a claimed attempt whose fix turn never ran, so the next probe
    /// retries it instead of reporting that nothing changed.
    func releasePullRequestAutopilotFix(_ id: UUID, signature: String) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.pullRequestAutopilotLastFixSignature == signature else { return }
            task.pullRequestAutopilotFixAttempts = max(0, task.pullRequestAutopilotFixAttempts - 1)
            task.pullRequestAutopilotLastFixSignature = nil
            try await saveTaskContext(taskID: id)
        }
    }

    /// A message from the user is a fresh request, so the PR state autopilot last
    /// sent may be sent again; the attempt count still bounds the streak.
    func clearPullRequestAutopilotSignature(_ id: UUID) async throws {
        guard let task = try? requireTask(id), task.pullRequestAutopilotLastFixSignature != nil else { return }
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            task.pullRequestAutopilotLastFixSignature = nil
            try await saveTaskContext(taskID: id)
        }
    }

    enum PullRequestMergeResult {
        case merged([Int])
        /// The task left Review or a turn took it while the PRs were being probed.
        case skipped
        case refused(String)
    }

    /// Merge mode's last step: merges every open linked PR at the head it was
    /// probed green at. It re-checks the task under the task operation lock, so a
    /// turn or a move out of Review during the probe stops the merge. A merge GitHub
    /// refuses (required reviews, branch protection) is not the model's to fix,
    /// so the task moves to Waiting Response with GitHub's reason.
    func mergeGreenPullRequests(_ id: UUID, states: [PullRequestReviewState]) async throws -> PullRequestMergeResult {
        let outcome: Result<[Int], BridgeCommandError>? = try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .review, try !hasConversationTurnReservation(id) else { return nil }
            let heads = Dictionary(states.filter { !$0.merged }.map { ($0.repositoryPath, $0.headRefOid) }, uniquingKeysWith: { first, _ in first })
            let records = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && heads.keys.contains($0.repositoryPath) }
            let executable = try pullRequestService.resolveExecutable()
            var merged: [Int] = []
            for record in records {
                let number = record.pullRequestNumber ?? 0
                do {
                    guard let head = heads[record.repositoryPath] ?? nil else {
                        throw BridgeCommandError(code: "operation_failed", message: "GitHub didn't report its head commit.")
                    }
                    let method = try await pullRequestService.merge(record, headOid: head, executable: executable)
                    merged.append(number)
                    PlayhouseDiagnostics.record("task.pr.autopilot.merged", fields: [
                        "taskID": id.uuidString, "number": String(number), "method": method
                    ])
                } catch {
                    let done = merged.isEmpty ? "" : " Already merged: \(merged.map { "#\($0)" }.joined(separator: ", "))."
                    return .failure(BridgeCommandError(
                        code: "operation_failed",
                        message: "Autopilot couldn't merge pull request #\(number): \(error.localizedDescription)\(done)"
                    ))
                }
            }
            return .success(merged)
        }
        switch outcome {
        case nil:
            return .skipped
        case .success(let merged)?:
            return .merged(merged)
        case .failure(let error)?:
            _ = try await setLifecycleStatus(id, to: .waitingResponse, message: error.message)
            return .refused(error.message)
        }
    }

    /// A green state ends the current fix streak.
    func resetPullRequestAutopilotAttempts(_ id: UUID) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.pullRequestAutopilotFixAttempts != 0 || task.pullRequestAutopilotLastFixSignature != nil else { return }
            task.pullRequestAutopilotFixAttempts = 0
            task.pullRequestAutopilotLastFixSignature = nil
            try await saveTaskContext(taskID: id)
        }
    }

    func createPullRequests(_ id: UUID, clients: ConversationClients, settingsManager: WorkspaceSettingsManager? = nil) async throws -> BoardTaskRecord {
        let lookup = try await withTaskOperationLock(id) {
            let initialTask = try requireTask(id)
            let originalRecords = initialTask.repositoryWorktrees
            guard !originalRecords.isEmpty else {
                throw BridgeCommandError(code: "invalid_transition", message: "This task has no repository for a pull request.")
            }
            let gh = try pullRequestService.resolveExecutable()
            guard !originalRecords.contains(where: \.isPending) else {
                throw BridgeCommandError(code: "invalid_transition", message: "Start the task conversation before creating a pull request so its repository worktree is ready.")
            }
            var records = originalRecords
            for index in records.indices where records[index].pullRequestNumber == nil || records[index].pullRequestURL == nil {
                do {
                    // `--head` skips gh's push flow, and `gh pr list` also needs a
                    // published branch. Commit and publish before either GH request.
                    try await worktreeService.commitChanges(records[index], message: "Complete task: \(initialTask.title)")
                    try await worktreeService.publishBranch(records[index])
                } catch {
                    throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI couldn't publish the task branch. \(error.localizedDescription)")
                }
                records[index].pullRequestSkippedHead = nil
                if let existing = try await pullRequestService.findOpen(records[index], executable: gh) {
                    records[index].pullRequestNumber = existing.number
                    records[index].pullRequestURL = existing.url
                } else if try await !worktreeService.hasCommitsAheadOfMergeTarget(records[index]) {
                    // A repository the task never changed has nothing to propose;
                    // the card stops offering it one until the task changes it.
                    records[index].pullRequestSkippedHead = try await worktreeService.headOid(records[index])
                }
            }
            let taskAfterLookup = try requireTask(id)
            guard taskAfterLookup.repositoryWorktrees == originalRecords else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while pull requests were being checked. Try again.")
            }
            taskAfterLookup.repositoryWorktrees = records
            try await saveTaskContext(taskID: id)
            return (gh, records, BoardTaskRecord(task: taskAfterLookup))
        }
        let (gh, records, lookedUpRecords) = lookup
        guard records.contains(where: \.awaitsPullRequest) else {
            if records.allSatisfy({ $0.pullRequestNumber == nil }) {
                throw BridgeCommandError(code: "invalid_transition", message: "No repository in this task has changes to open a pull request for.")
            }
            return lookedUpRecords
        }

        let conversation = try await ConversationManager(tasks: self, clients: clients, settingsManager: settingsManager).history(taskID: id)
        let helperClients = clients.helperClients(preferring: try requireSubject(id).conversationProvider)
        let conversationText = conversation.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let currentTitle = try requireSubject(id).title
        let summary: String
        if !conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let roots = records.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) }
            let workspace = try ConversationWorkspaceContext(roots: roots)
            var generated = ""
            var summaryProvider = helperClients[0].provider
            // Fall back to the other provider only when the task's provider can't run here.
            for (index, client) in helperClients.enumerated() {
                summaryProvider = client.provider
                do {
                    let summaryThread = try await client.startThread(workspace: workspace, modelID: client.provider.defaultModelID, developerInstructions: nil)
                    try await client.sendMessage(
                        "Write a very concise GitHub pull request description. Explain what problem this change solves, how it solves it, and briefly mention any special issue or caveat from the conversation. Use Markdown, no more than three short sections, and return only the description.\n\nTask: \(currentTitle)\n\nConversation:\n\(conversationText)",
                        mode: .plan,
                        modelID: client.provider.defaultModelID,
                        threadID: summaryThread,
                        workspace: workspace,
                        onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    )
                    break
                } catch where client.isProviderUnavailable(error) && index < helperClients.count - 1 {
                    continue
                }
            }
            guard !generated.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "\(summaryProvider.displayName) returned an empty pull request summary. Try again.")
            }
            summary = generated
        } else {
            summary = "Implements: \(currentTitle)."
        }

        let taskBeforeCreation = try requireSubject(id)
        guard taskBeforeCreation.repositoryWorktrees == records,
              taskBeforeCreation.title == currentTitle else {
            throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its pull request summary was being prepared. Try again.")
        }
        return try await withTaskOperationLock(id) {
            let taskAtCreation = try requireSubject(id)
            guard taskAtCreation.repositoryWorktrees == records,
                  taskAtCreation.title == currentTitle else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its pull request summary was being prepared. Try again.")
            }
            var updatedRecords = records
            var expectedRecords = records
            for index in updatedRecords.indices where updatedRecords[index].awaitsPullRequest {
                let record = updatedRecords[index]
                let pullRequest: GitHubPullRequestManager.PullRequest
                if let existing = try await pullRequestService.findOpen(record, executable: gh) {
                    pullRequest = existing
                } else {
                    do {
                        try await worktreeService.commitChanges(record, message: "Complete task: \(currentTitle)")
                        try await worktreeService.publishBranch(record)
                    } catch {
                        throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI couldn't publish the task branch. \(error.localizedDescription)")
                    }
                    pullRequest = try await pullRequestService.create(record, title: currentTitle, body: summary, executable: gh)
                }
                updatedRecords[index].pullRequestNumber = pullRequest.number
                updatedRecords[index].pullRequestURL = pullRequest.url
                let currentTask = try requireTask(id)
                guard currentTask.repositoryWorktrees == expectedRecords else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while the pull request was being created.")
                }
                currentTask.repositoryWorktrees = updatedRecords
                try await saveTaskContext(taskID: id)
                expectedRecords = updatedRecords
            }
            return try get(id)
        }
    }

    func pullRequestConflictRepositories(_ id: UUID) async throws -> [String] {
        try await withTaskOperationLock(id) {
            try await pullRequestConflictRepositoriesUnlocked(id)
        }
    }

    func reviewPullRequests(_ id: UUID, includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
        let task = try requireTask(id)
        return try await reviewPullRequests(task, includeReviewThreads: includeReviewThreads)
    }

    /// Autopilot also reads unresolved review threads; a plain status probe skips
    /// that GitHub request because nothing acts on it.
    func reviewPullRequests(_ task: BoardTask, includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
        let records = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil }
        let states = try await reviewPullRequests(records, includeReviewThreads: includeReviewThreads)
        try await recordPullRequestsMerged(task.id, repositoryPaths: states.filter(\.merged).map(\.repositoryPath))
        return states
    }

    /// Persists that these repositories' linked pull requests merged, so follow-up turns
    /// are told to renew the worktree instead of committing to the finished branch.
    func recordPullRequestsMerged(_ id: UUID, repositoryPaths: [String]) async throws {
        let paths = Set(repositoryPaths)
        guard !paths.isEmpty else { return }
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            var changed = false
            let records = task.repositoryWorktrees.map { record in
                var record = record
                if record.pullRequestNumber != nil, !record.isPullRequestMerged, paths.contains(record.repositoryPath) {
                    record.isPullRequestMerged = true
                    changed = true
                }
                return record
            }
            guard changed else { return }
            task.repositoryWorktrees = records
            try await saveTaskContext(taskID: id)
        }
    }

    func reviewPullRequests(_ records: [RepositoryWorktreeRecord], includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
        guard !records.isEmpty else { return [] }
        let executable = try pullRequestService.resolveExecutable()
        return try await withThrowingTaskGroup(of: PullRequestReviewState.self) { group in
            for record in records {
                group.addTask {
                    try await PlayhousePullRequestService().reviewState(record, executable: executable, includeReviewThreads: includeReviewThreads)
                }
            }
            var states: [PullRequestReviewState] = []
            for try await state in group { states.append(state) }
            return states.sorted { $0.repositoryPath < $1.repositoryPath }
        }
    }

    func verifyPullRequestResolution(_ id: UUID) async throws -> PullRequestResolutionCheck {
        var latest: [PullRequestReviewState] = []
        for attempt in 0..<5 {
            latest = try await reviewPullRequests(id)
            if !latest.isEmpty && latest.allSatisfy(\.isConfirmedResolved) { return .resolved }
            if attempt < 4 { try await Task.sleep(for: .seconds(1)) }
        }
        guard !latest.isEmpty else { return .inconclusive }
        return latest.contains(where: {
            $0.hasConflicts || ($0.headRefOid != nil && $0.headRefOid != $0.localHeadOid)
        }) ? .stillConflicted : .inconclusive
    }

    func pullRequestConflictRepositoriesUnlocked(_ id: UUID) async throws -> [String] {
        let task = try requireSubject(id)
        guard !task.repositoryWorktrees.isEmpty else { return [] }
        var conflicts: [String] = []
        for record in task.repositoryWorktrees where !record.isPending && record.pullRequestNumber == nil {
            if try await worktreeService.hasMergeConflicts(record) { conflicts.append(record.repositoryPath) }
        }
        return conflicts
    }

    func resolvePullRequestConflicts(_ id: UUID, action: String, clients: ConversationClients) async throws -> BoardTaskRecord {
        guard ["resolve-and-push", "resolve-only", "keep"].contains(action) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose resolve-and-push, resolve-only, or keep.")
        }
        if action == "keep" { return try get(id) }
        return try await withTaskOperationLock(id) {
            let records = try requireSubject(id).repositoryWorktrees.filter { !$0.isPending && $0.pullRequestNumber == nil }
            let conflicted = try await pullRequestConflictRepositoriesUnlocked(id)
            guard !conflicted.isEmpty else { return try get(id) }
            let affected = records.filter { conflicted.contains($0.repositoryPath) }
            for record in affected {
                guard let target = record.mergeTarget else { continue }
                // A prior provider attempt may have left Git's merge in progress,
                // including after every conflict file was staged. Resume it.
                if try await worktreeService.hasMergeInProgress(record) == false {
                    try await worktreeService.mergeTarget(record, target: target)
                }
            }
            try await resolveMergeConflictsWithProvider(affected, provider: try requireTask(id).conversationProvider, clients: clients)
            for record in affected {
                try await worktreeService.commitChanges(record, message: "Resolve merge conflicts with \(record.mergeTarget ?? "target")")
                if action == "resolve-and-push" { try await worktreeService.publishBranch(record) }
            }
            PlayhouseDiagnostics.record("task.pr.conflicts.resolved", fields: [
                "taskID": id.uuidString, "repositoryCount": String(affected.count), "pushed": String(action == "resolve-and-push")
            ])
            return try get(id)
        }
    }

    /// Runs a provider turn that resolves the staged Git merge conflicts in the
    /// given worktrees, then verifies none remain. Throws when any conflict is
    /// left, leaving the merge in progress for manual resolution.
    func resolveMergeConflictsWithProvider(
        _ records: [RepositoryWorktreeRecord],
        provider: ConversationProvider,
        clients: ConversationClients
    ) async throws {
        var unresolved: [RepositoryWorktreeRecord] = []
        for record in records {
            if try await worktreeService.hasUnmergedFiles(record) { unresolved.append(record) }
        }
        guard !unresolved.isEmpty else { return }
        let client = clients.client(for: provider)
        let failureMessage = "\(client.provider.displayName) couldn't resolve every merge conflict. The task branch was left available for manual resolution."
        let roots = try ConversationWorkspaceContext(roots: unresolved.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) })
        let thread = try await client.startThread(workspace: roots, modelID: client.provider.defaultModelID, developerInstructions: nil)
        do {
            try await client.sendMessage(
                "Resolve every Git merge conflict in the current workspace. Preserve the intended changes from both sides, inspect the resulting files, and stage the resolved files. Do not commit or push. Report which conflicts you resolved.",
                mode: .code,
                modelID: client.provider.defaultModelID,
                threadID: thread,
                workspace: roots,
                onFinalMessage: { _ in },
                onUserInput: { request in
                    client.rejectUserInput(
                        requestID: request.id,
                        threadID: request.threadID,
                        message: "Conflict resolution cannot continue while \(client.provider.displayName) is waiting for user input."
                    )
                }
            )
        } catch {
            for record in unresolved {
                if try await worktreeService.hasUnmergedFiles(record) {
                    throw BridgeCommandError(code: "operation_failed", message: failureMessage)
                }
            }
            throw error
        }
        for record in unresolved {
            if try await worktreeService.hasUnmergedFiles(record) {
                throw BridgeCommandError(code: "operation_failed", message: failureMessage)
            }
        }
    }

    static let reviewSyncBlockedMessagePrefix = "Playhouse couldn't sync this task's changes with its pull request"

    static func reviewSyncBlockedMessage(_ error: Error) -> String {
        "\(reviewSyncBlockedMessagePrefix): \(error.localizedDescription)"
    }

    /// Commits local work, merges new remote pull request commits, and pushes
    /// every PR-linked task branch, so a reviewed task never holds local-only
    /// changes. Merge conflicts are resolved by the task's provider. A repository
    /// without a publishing remote or remote branch is left untouched. A worktree
    /// switched off its task branch fails the sync untouched. Throws on any
    /// failure so the caller can move the task to Blocked.
    func syncPullRequestChanges(_ id: UUID, clients: ConversationClients) async throws -> [TaskBranchSyncResult] {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            let provider = task.conversationProvider
            let title = task.title
            let records = task.repositoryWorktrees.filter { !$0.isPending && $0.pullRequestNumber != nil }
            var results: [TaskBranchSyncResult] = []
            // GitHub is the source of truth for a merged PR; without gh the check is skipped.
            let executable = records.isEmpty ? nil : try? pullRequestService.resolveExecutable()
            for record in records {
                // Every step below acts on HEAD; never commit to or merge into a
                // branch the agent switched to instead of the pull request branch.
                try await worktreeService.requireTaskBranchCheckedOut(record)
                // A failed earlier sync can leave its merge in progress; resolve
                // its conflicts before anything else touches the working tree.
                // A merge whose result matches HEAD leaves no file changes but must still be concluded.
                let mergeWasInProgress = try await worktreeService.hasMergeInProgress(record)
                if mergeWasInProgress {
                    try await resolveMergeConflictsWithProvider([record], provider: provider, clients: clients)
                }
                let hadLocalChanges = try await worktreeService.hasChanges(record) || mergeWasInProgress
                if hadLocalChanges {
                    try await worktreeService.commitChanges(record, message: "Complete task: \(title)")
                }
                // A merged PR's branch is usually deleted on the remote, so there is
                // nothing left to fetch or push; local work stays committed.
                var isMerged = record.isPullRequestMerged
                if !isMerged, let executable {
                    isMerged = (try? await pullRequestService.isMerged(record, executable: executable)) == true
                }
                if isMerged {
                    if !record.isPullRequestMerged {
                        task.repositoryWorktrees = task.repositoryWorktrees.map { candidate in
                            var candidate = candidate
                            if candidate == record { candidate.isPullRequestMerged = true }
                            return candidate
                        }
                        try await saveTaskContext(taskID: id)
                    }
                    results.append(TaskBranchSyncResult(repositoryPath: record.repositoryPath, action: "pr-merged"))
                    continue
                }
                let state = try await worktreeService.fetchRemoteBranchState(record)
                guard state.remote != nil else {
                    results.append(TaskBranchSyncResult(repositoryPath: record.repositoryPath, action: "no-remote"))
                    continue
                }
                guard state.remoteBranchExists else {
                    results.append(TaskBranchSyncResult(repositoryPath: record.repositoryPath, action: "no-remote-branch"))
                    continue
                }
                var resolvedConflicts = false
                if state.behindCount > 0 {
                    try await worktreeService.mergeFetchedRemoteBranch(record)
                    if try await worktreeService.hasUnmergedFiles(record) {
                        resolvedConflicts = true
                        try await resolveMergeConflictsWithProvider([record], provider: provider, clients: clients)
                    }
                    try await worktreeService.commitChanges(record, message: "Merge remote changes for \(record.branch)")
                }
                if state.aheadCount > 0 || state.behindCount > 0 || hadLocalChanges {
                    try await worktreeService.publishBranch(record)
                    let action = resolvedConflicts ? "resolved-and-pushed" : (state.behindCount > 0 ? "merged-and-pushed" : "pushed")
                    results.append(TaskBranchSyncResult(repositoryPath: record.repositoryPath, action: action))
                } else {
                    results.append(TaskBranchSyncResult(repositoryPath: record.repositoryPath, action: "up-to-date"))
                }
            }
            try await reopenChangedSkippedRepositories(task)
            PlayhouseDiagnostics.record("task.review.sync.completed", fields: [
                "taskID": id.uuidString,
                "actions": results.map { "\($0.repositoryPath)=\($0.action)" }.joined(separator: ",")
            ])
            return results
        }
    }

    /// A repository pull request creation skipped as unchanged is offered a
    /// pull request again once its branch moved or it holds local changes. A
    /// repository Git can't read counts as changed, so the offer comes back.
    func reopenChangedSkippedRepositories(_ task: BoardTask) async throws {
        var worktrees = task.repositoryWorktrees
        var reopened = false
        for index in worktrees.indices where worktrees[index].pullRequestNumber == nil {
            guard let skippedHead = worktrees[index].pullRequestSkippedHead else { continue }
            let record = worktrees[index]
            let isClean = (try? await worktreeService.hasChanges(record)) == false
            let head = try? await worktreeService.headOid(record)
            if !isClean || head != skippedHead {
                worktrees[index].pullRequestSkippedHead = nil
                reopened = true
            }
        }
        guard reopened else { return }
        task.repositoryWorktrees = worktrees
        try await saveTaskContext(taskID: task.id)
    }

    /// The review guarantee for a task already on the board: after this call the
    /// task either has no local-only pull request changes or sits in Blocked with
    /// the sync failure message. A successful rerun heals a block this sync caused.
    func syncPullRequestChangesOrBlock(_ id: UUID, clients: ConversationClients) async throws -> [TaskBranchSyncResult] {
        do {
            let results = try await syncPullRequestChanges(id, clients: clients)
            if let task = try? requireTask(id), task.status == .blocked,
               task.statusMessage?.hasPrefix(Self.reviewSyncBlockedMessagePrefix) == true {
                _ = try await setLifecycleStatus(id, to: .review)
            }
            return results
        } catch {
            PlayhouseDiagnostics.record("task.review.sync.failed", fields: [
                "taskID": id.uuidString,
                "error": error.localizedDescription
            ])
            let status = (try? requireTask(id))?.status
            if status == .review || status == .blocked {
                _ = try? await setLifecycleStatus(id, to: .blocked, message: Self.reviewSyncBlockedMessage(error))
            }
            throw error
        }
    }

}

extension BoardTask {
    /// The mode the task kept before the `pull-request-mode` plugin owned it;
    /// read once to import it into the plugin's state.
    var legacyPullRequestMode: PullRequestMode {
        if pullRequestAutopilot { return pullRequestAutoMerge ? .merge : .autopilot }
        return autoCreatePullRequestOnReview ? .pullRequest : .manual
    }
}
