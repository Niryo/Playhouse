import Foundation

extension BoardTaskManager {
    /// Carries each task's pull request mode, which the task kept before the
    /// `pull-request-mode` plugin owned it, into the plugin's state, once. A
    /// task created since reads as PR (`BoardTask.init`), which imports
    /// nothing, so it is skipped wherever it was created; a task saved while PR
    /// was the default gets it from `pinPullRequestModeOfExistingTasks`, which
    /// runs right after. The bridge runs both at the start of every request.
    package func importLegacyPullRequestModes(into settings: WorkspaceSettingsManager) throws {
        guard !settings.legacyPullRequestModesImported else { return }
        let state = settings.pluginState(BuiltInPlugins.pullRequestModeID)
        var imported = 0
        for task in try modelContext.fetch(ModelFetch<BoardTask>()) {
            let mode = task.legacyPullRequestMode
            guard mode != .pullRequest, state[task.id.uuidString] == nil else { continue }
            settings.setPluginState(BuiltInPlugins.pullRequestModeID, key: task.id.uuidString, value: .string(mode.rawValue))
            imported += 1
        }
        settings.legacyPullRequestModesImported = true
        PlayhouseDiagnostics.record("plugin.pull_request_mode.imported", fields: ["count": String(imported)])
    }

    /// PR was the default mode before Manual, so a task saved then with no mode
    /// of its own opened its pull request on Review. Saves PR for each such
    /// task, once, so only tasks created since get the Manual default. A
    /// schedule's run whose schedule still exists is left to inherit the mode
    /// its schedule now keeps.
    package func pinPullRequestModeOfExistingTasks(into settings: WorkspaceSettingsManager) throws {
        guard !settings.existingTaskPullRequestModesPinned else { return }
        let state = settings.pluginState(BuiltInPlugins.pullRequestModeID)
        let tasks = try modelContext.fetch(ModelFetch<BoardTask>())
        let taskIDs = Set(tasks.map(\.id))
        var pinned = 0
        for task in tasks where state[task.id.uuidString] == nil {
            if let source = task.scheduleSourceTaskID, taskIDs.contains(source) { continue }
            settings.setPluginState(BuiltInPlugins.pullRequestModeID, key: task.id.uuidString, value: .string(PullRequestMode.pullRequest.rawValue))
            pinned += 1
        }
        settings.existingTaskPullRequestModesPinned = true
        PlayhouseDiagnostics.record("plugin.pull_request_mode.pinned", fields: ["count": String(pinned)])
    }

    /// Autopilot gives up after this many fix turns that never got the PRs green,
    /// even when each one changed something.
    package static let maxPullRequestAutopilotFixAttempts = 5

    /// What autopilot should do about a task's probed pull requests. Shared by the
    /// board's probe (to decide whether to ask the daemon at all) and the daemon's
    /// `task.pr.autopilot` command (which acts on it).
    package enum PullRequestAutopilotAssessment: String, Codable, Sendable {
        case merged, green, pending, needsFix = "needs-fix"
    }

    package static func assessPullRequestAutopilot(_ states: [PullRequestReviewState]) -> PullRequestAutopilotAssessment {
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
    package static func pullRequestAutopilotSignature(_ states: [PullRequestReviewState]) -> String {
        states.filter { !$0.merged }.map { state in
            [
                String(state.number), state.headRefOid ?? "-", state.checks.rawValue,
                state.failingChecks.joined(separator: ","), state.mergeable,
                String(state.unresolvedReviewThreads ?? 0)
            ].joined(separator: ":")
        }.sorted().joined(separator: "|")
    }

    package enum PullRequestAutopilotClaim {
        /// Send a fix turn for this red state.
        case fix
        /// Stop the loop: the task moved to Waiting Response with this reason.
        case stalled(String)
    }

    /// Records a fix attempt for a red state, or stops the loop when the same
    /// state was already sent or the attempt budget is spent.
    package func claimPullRequestAutopilotFix(_ id: UUID, signature: String) async throws -> PullRequestAutopilotClaim {
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
    package func releasePullRequestAutopilotFix(_ id: UUID, signature: String) async throws {
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
    package func clearPullRequestAutopilotSignature(_ id: UUID) async throws {
        guard let task = try? requireTask(id), task.pullRequestAutopilotLastFixSignature != nil else { return }
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            task.pullRequestAutopilotLastFixSignature = nil
            try await saveTaskContext(taskID: id)
        }
    }

    package enum PullRequestMergeResult {
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
    package func mergeGreenPullRequests(_ id: UUID, states: [PullRequestReviewState]) async throws -> PullRequestMergeResult {
        let outcome: Result<[Int], BridgeCommandError>? = try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .review, try !hasConversationTurnReservation(id) else { return nil }
            let heads = Dictionary(states.filter { !$0.merged }.map { ($0.worktreePath, $0.headRefOid) }, uniquingKeysWith: { first, _ in first })
            let records = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && heads.keys.contains($0.worktreePath) }
            let executable = try pullRequestService.resolveExecutable()
            var merged: [Int] = []
            for record in records {
                let number = record.pullRequestNumber ?? 0
                do {
                    guard let head = heads[record.worktreePath] ?? nil else {
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
    package func resetPullRequestAutopilotAttempts(_ id: UUID) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.pullRequestAutopilotFixAttempts != 0 || task.pullRequestAutopilotLastFixSignature != nil else { return }
            task.pullRequestAutopilotFixAttempts = 0
            task.pullRequestAutopilotLastFixSignature = nil
            try await saveTaskContext(taskID: id)
        }
    }

    /// Opens a pull request for every started worktree that waits for one. `title` and
    /// `body` replace the task title and the generated description when given.
    package func createPullRequests(
        _ id: UUID,
        clients: ConversationClients,
        settingsManager: WorkspaceSettingsManager? = nil,
        title requestedTitle: String? = nil,
        body requestedBody: String? = nil
    ) async throws -> BoardTaskRecord {
        let requestedTitle = requestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let requestedBody = requestedBody?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
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
            for index in records.indices where !records[index].hasPullRequest || records[index].awaitsPullRequest {
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
                    records[index].isPullRequestClosed = false
                    records[index].isPullRequestMerged = false
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
        if let requestedBody {
            summary = requestedBody
        } else if !conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        SystemPrompts.pullRequestDescription(title: currentTitle, conversation: conversationText),
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
                    pullRequest = try await pullRequestService.create(record, title: requestedTitle ?? currentTitle, body: summary, executable: gh)
                }
                updatedRecords[index].pullRequestNumber = pullRequest.number
                updatedRecords[index].pullRequestURL = pullRequest.url
                updatedRecords[index].isPullRequestClosed = false
                updatedRecords[index].isPullRequestMerged = false
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

    package func pullRequestConflictRepositories(_ id: UUID) async throws -> [String] {
        try await withTaskOperationLock(id) {
            try await pullRequestConflictRepositoriesUnlocked(id)
        }
    }

    package func reviewPullRequests(_ id: UUID, includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
        let task = try requireTask(id)
        return try await reviewPullRequests(task, includeReviewThreads: includeReviewThreads)
    }

    /// The status read behind `task.pr.status`. Done removes a task's worktrees, so a
    /// probe of a Done task whose linked worktrees are gone (often one that was already
    /// running when the task moved) has no state to report; that is not a failure.
    package func pullRequestStatus(_ id: UUID, includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
        // Best-effort: the status of the pull requests already linked is read without it.
        do {
            try await detectPullRequests(id)
        } catch {
            PlayhouseDiagnostics.record("task.pr.detect.failed", fields: ["taskID": id.uuidString, "error": "\(error)"])
        }
        do {
            return try await reviewPullRequests(id, includeReviewThreads: includeReviewThreads)
        } catch {
            // The move removes the worktrees before it records Done; the lock waits it out.
            let hasNoStateToReport = try await withTaskOperationLock(id) {
                let task = try requireTask(id)
                let linked = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil }
                return task.status == .done && !linked.contains { FileManager.default.fileExists(atPath: $0.worktreePath) }
            }
            guard hasNoStateToReport else { throw error }
            return []
        }
    }

    /// Every pull request the task has recorded that `probed` (a status read's answer)
    /// leaves out: closed ones, a Done task's (whose worktrees are gone), and those of
    /// worktrees retired by renew, marked `past`. Read from the task's records, not probed.
    package func recordedPullRequests(_ id: UUID, besides probed: [PullRequestReviewState]) throws -> [PullRequestReviewState] {
        let task = try requireTask(id)
        func state(_ record: RepositoryWorktreeRecord, past: Bool) -> PullRequestReviewState? {
            guard let number = record.pullRequestNumber else { return nil }
            var state = PullRequestReviewState(
                repositoryPath: record.repositoryPath, worktreePath: record.worktreePath, branch: record.branch,
                url: record.pullRequestURL, number: number, merged: record.isPullRequestMerged,
                mergeable: "UNKNOWN", headRefOid: nil, localHeadOid: nil, closed: record.isPullRequestClosed
            )
            state.past = past ? true : nil
            return state
        }
        let current = task.repositoryWorktrees.filter { record in
            !probed.contains { $0.worktreePath == record.worktreePath && $0.number == record.pullRequestNumber }
        }
        return current.compactMap { state($0, past: false) } + task.pastRepositoryWorktrees.compactMap { state($0, past: true) }
    }

    /// Autopilot also reads unresolved review threads; a plain status probe skips
    /// that GitHub request because nothing acts on it.
    package func reviewPullRequests(_ task: BoardTask, includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
        // A closed pull request has no review state left to act on; the card shows it closed.
        let records = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && !$0.isPullRequestClosed }
        let states = try await reviewPullRequests(records, includeReviewThreads: includeReviewThreads)
        try await recordPullRequestOutcomes(
            task.id,
            merged: states.filter(\.merged).map(\.worktreePath),
            closed: states.filter(\.closed).map(\.worktreePath)
        )
        return states.filter { !$0.closed }
    }

    /// Persists that these worktrees' linked pull requests merged, so follow-up turns
    /// are told to renew the worktree instead of committing to the finished branch, or
    /// closed unmerged on GitHub, so the card shows them closed and Done doesn't wait on them.
    package func recordPullRequestOutcomes(_ id: UUID, merged: [String], closed: [String]) async throws {
        let mergedPaths = Set(merged)
        let closedPaths = Set(closed)
        guard !mergedPaths.isEmpty || !closedPaths.isEmpty else { return }
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            var changed = false
            let records = task.repositoryWorktrees.map { record in
                var record = record
                guard record.pullRequestNumber != nil else { return record }
                if !record.isPullRequestMerged, mergedPaths.contains(record.worktreePath) {
                    record.isPullRequestMerged = true
                    changed = true
                }
                if !record.isPullRequestClosed, closedPaths.contains(record.worktreePath) {
                    record.isPullRequestClosed = true
                    changed = true
                }
                return record
            }
            guard changed else { return }
            task.repositoryWorktrees = records
            try await saveTaskContext(taskID: id)
        }
    }

    package func reviewPullRequests(_ records: [RepositoryWorktreeRecord], includeReviewThreads: Bool = false) async throws -> [PullRequestReviewState] {
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
            return states.sorted { ($0.repositoryPath, $0.worktreePath) < ($1.repositoryPath, $1.worktreePath) }
        }
    }

    /// Brings each started worktree's record in line with Git and GitHub, so a pull
    /// request opened outside Playhouse (plain `gh pr create`) still shows on the task.
    /// A worktree switched to another branch records that branch; a pull request linked
    /// to the old branch moves to the task's past worktrees and stays listed. A worktree
    /// without an open or merged pull request takes the one GitHub has for its branch.
    /// Best effort: Git or GitHub being unavailable leaves the records unchanged.
    /// A turn holding the task skips it: the agent may be mid-way through switching or
    /// pushing a branch, and the next read after the turn records what it left.
    package func detectPullRequests(_ id: UUID) async throws {
        let task = try requireTask(id)
        guard task.status != .done, try !hasConversationTurnReservation(id) else { return }
        let candidates = task.repositoryWorktrees.filter {
            !$0.isPending && FileManager.default.fileExists(atPath: $0.worktreePath)
        }
        guard !candidates.isEmpty else { return }
        let executable = try? pullRequestService.resolveExecutable()
        var updates: [(old: RepositoryWorktreeRecord, new: RepositoryWorktreeRecord, retired: RepositoryWorktreeRecord?)] = []
        for record in candidates {
            var updated = record
            var retired: RepositoryWorktreeRecord?
            if let branch = try? await worktreeService.checkedOutBranch(record), branch != record.branch {
                if let problem = await adoptedBranchProblem(branch, for: record, in: task) {
                    // Keeping the recorded branch leaves Review's "switch it back" check in force.
                    PlayhouseDiagnostics.record("task.pr.detect.branch_not_adopted", fields: [
                        "taskID": id.uuidString, "worktreePath": record.worktreePath,
                        "recordedBranch": record.branch, "checkedOutBranch": branch, "reason": problem
                    ])
                    continue
                }
                if record.hasPullRequest { retired = record }
                updated.branch = branch
                updated.pullRequestNumber = nil
                updated.pullRequestURL = nil
                updated.isPullRequestMerged = false
                updated.isPullRequestClosed = false
                updated.pullRequestSkippedHead = nil
                PlayhouseDiagnostics.record("task.pr.detect.branch_corrected", fields: [
                    "taskID": id.uuidString, "worktreePath": record.worktreePath,
                    "recordedBranch": record.branch, "checkedOutBranch": branch
                ])
            }
            if let executable, !updated.hasPullRequest || updated.isPullRequestClosed {
                do {
                    if let found = try await pullRequestService.find(branch: updated.branch, record: updated, executable: executable),
                       found.number != updated.pullRequestNumber || found.isClosed != updated.isPullRequestClosed {
                        // A closed pull request the branch has since replaced stays listed.
                        if retired == nil, updated.hasPullRequest, updated.pullRequestURL != found.url { retired = updated }
                        updated.pullRequestNumber = found.number
                        updated.pullRequestURL = found.url
                        updated.isPullRequestMerged = found.isMerged
                        updated.isPullRequestClosed = found.isClosed
                        updated.pullRequestSkippedHead = nil
                        PlayhouseDiagnostics.record("task.pr.detect.found", fields: [
                            "taskID": id.uuidString, "worktreePath": record.worktreePath,
                            "number": String(found.number), "state": found.state
                        ])
                    }
                } catch {
                    PlayhouseDiagnostics.record("task.pr.detect.failed", fields: [
                        "taskID": id.uuidString, "worktreePath": record.worktreePath, "error": error.localizedDescription
                    ])
                }
            }
            if updated != record { updates.append((record, updated, retired)) }
        }
        guard !updates.isEmpty else { return }
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            var applied: [(old: RepositoryWorktreeRecord, new: RepositoryWorktreeRecord, retired: RepositoryWorktreeRecord?)] = []
            task.repositoryWorktrees = task.repositoryWorktrees.map { current in
                guard let update = updates.first(where: { $0.old == current }) else { return current }
                // Another worktree or task may have taken the branch while GitHub answered.
                if update.new.branch != current.branch, heldBranchProblem(update.new.branch, for: current, in: task) != nil { return current }
                applied.append(update)
                return update.new
            }
            guard !applied.isEmpty else { return }
            retirePullRequests(applied.compactMap(\.retired), on: task)
            try await saveTaskContext(taskID: id)
        }
    }

    /// Keeps pull requests a worktree no longer holds listed on the task, once each.
    /// A pull request a current worktree still holds is already listed there.
    package func retirePullRequests(_ records: [RepositoryWorktreeRecord], on task: BoardTask) {
        var listed = Set((task.pastRepositoryWorktrees + task.repositoryWorktrees).compactMap(\.pullRequestURL))
        for record in records where record.hasPullRequest {
            guard let url = record.pullRequestURL, listed.insert(url).inserted else { continue }
            task.pastRepositoryWorktrees.append(record)
        }
    }

    /// Why a worktree can't take the branch it was switched to as its task branch, or
    /// nil when it can. Detection and linking adopt a switched branch, and later commits
    /// and pushes go to the recorded branch, so a shared base or merge target, or a
    /// branch another worktree or task holds, never becomes one.
    package func adoptedBranchProblem(_ branch: String, for record: RepositoryWorktreeRecord, in task: BoardTask) async -> String? {
        let remoteBase = record.branchFrom.hasPrefix("origin/") ? String(record.branchFrom.dropFirst("origin/".count)) : nil
        if [record.mergeTarget, record.branchFrom, remoteBase].contains(branch) {
            return "it is the worktree's base or merge target"
        }
        if let problem = heldBranchProblem(branch, for: record, in: task) { return problem }
        let repositoryPath = record.repositoryPath
        let defaultBranch = try? await PlayhouseBackgroundOperation.run {
            try PlayhouseWorktreeManager.defaultLocalBranch(repositoryPath: repositoryPath)
        }
        return defaultBranch == branch ? "it is the repository's default branch" : nil
    }

    /// Why `branch` is held by another worktree of the task or by another task, or nil.
    /// Read again under the task operation lock, since either can change while GitHub answers.
    package func heldBranchProblem(_ branch: String, for record: RepositoryWorktreeRecord, in task: BoardTask) -> String? {
        let siblings = task.repositoryWorktrees.filter { !$0.isSameWorktree(as: record) }
        if ownBranches(of: record.repositoryPath, in: siblings).contains(branch) {
            return "another worktree of this task uses it"
        }
        if reservedBranches(repositoryPath: record.repositoryPath, excludingTaskID: task.id).contains(branch) {
            return "another task uses it"
        }
        return nil
    }

    /// Records the pull request at `url` on the selected worktree. GitHub must report
    /// the worktree's checked-out branch as the pull request's head branch.
    package func linkPullRequest(_ id: UUID, worktree selector: RepositoryWorktreeSelector, url: String) async throws -> BoardTaskRecord {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmedURL)?.host != nil else {
            throw BridgeCommandError(code: "invalid_argument", message: "Pass the pull request's URL, for example https://github.com/owner/repo/pull/12.")
        }
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Pull requests can't be linked on a completed task.")
        }
        let record = try repositoryRecord(selector, in: initialTask)
        guard !record.isPending else {
            throw BridgeCommandError(code: "invalid_transition", message: "Start the task so this worktree exists before linking a pull request to it.")
        }
        let branch = try await worktreeService.checkedOutBranch(record)
        let executable = try pullRequestService.resolveExecutable()
        let pullRequest = try await pullRequestService.view(url: trimmedURL, record: record, executable: executable)
        guard let branch, pullRequest.headRefName == branch else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Pull request #\(pullRequest.number) is for branch '\(pullRequest.headRefName ?? "unknown")', but the worktree \(record.worktreePath) is on \(branch.map { "branch '\($0)'" } ?? "a detached HEAD"). Link it to the worktree of that branch."
            )
        }
        if branch != record.branch, let problem = await adoptedBranchProblem(branch, for: record, in: initialTask) {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "The worktree \(record.worktreePath) is on branch '\(branch)', which can't be a task branch because \(problem). Switch it back to '\(record.branch)', or create another worktree with task repository add-worktree."
            )
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard let index = task.repositoryWorktrees.firstIndex(where: { $0 == record }) else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task worktrees changed while the pull request was being read. Try again.")
            }
            if branch != record.branch, let problem = heldBranchProblem(branch, for: record, in: task) {
                throw BridgeCommandError(
                    code: "invalid_argument",
                    message: "The worktree \(record.worktreePath) is on branch '\(branch)', which can't be a task branch because \(problem). Switch it back to '\(record.branch)', or create another worktree with task repository add-worktree."
                )
            }
            var updated = record
            updated.branch = branch
            updated.pullRequestNumber = pullRequest.number
            updated.pullRequestURL = pullRequest.url
            updated.isPullRequestMerged = pullRequest.isMerged
            updated.isPullRequestClosed = pullRequest.isClosed
            updated.pullRequestSkippedHead = nil
            var repositories = task.repositoryWorktrees
            repositories[index] = updated
            task.repositoryWorktrees = repositories
            if record.hasPullRequest, record.pullRequestURL != pullRequest.url || record.branch != branch {
                retirePullRequests([record], on: task)
            }
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.pr.linked", fields: [
                "taskID": id.uuidString, "worktreePath": record.worktreePath, "number": String(pullRequest.number)
            ])
            return BoardTaskRecord(task: task)
        }
    }

    package func pullRequestConflictRepositoriesUnlocked(_ id: UUID) async throws -> [String] {
        let task = try requireSubject(id)
        guard !task.repositoryWorktrees.isEmpty else { return [] }
        var conflicts: [String] = []
        for record in task.repositoryWorktrees where !record.isPending && record.pullRequestNumber == nil {
            if try await worktreeService.hasMergeConflicts(record) { conflicts.append(record.repositoryPath) }
        }
        return conflicts
    }

    package func resolvePullRequestConflicts(_ id: UUID, action: String, clients: ConversationClients) async throws -> BoardTaskRecord {
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
    package func resolveMergeConflictsWithProvider(
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
                SystemPrompts.stagedMergeConflicts(),
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

    package static let reviewSyncBlockedMessagePrefix = "Playhouse couldn't sync this task's changes with its pull request"

    package static func reviewSyncBlockedMessage(_ error: Error) -> String {
        "\(reviewSyncBlockedMessagePrefix): \(error.localizedDescription)"
    }

    /// Commits local work, merges new remote pull request commits, and pushes
    /// every PR-linked task branch, so a reviewed task never holds local-only
    /// changes. Merge conflicts are resolved by the task's provider. A repository
    /// without a publishing remote or remote branch is left untouched. A worktree
    /// switched off its task branch fails the sync untouched. Throws on any
    /// failure so the caller can move the task to Blocked.
    package func syncPullRequestChanges(_ id: UUID, clients: ConversationClients) async throws -> [TaskBranchSyncResult] {
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
    package func reopenChangedSkippedRepositories(_ task: BoardTask) async throws {
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
    package func syncPullRequestChangesOrBlock(_ id: UUID, clients: ConversationClients) async throws -> [TaskBranchSyncResult] {
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
    package var legacyPullRequestMode: PullRequestMode {
        if pullRequestAutopilot { return pullRequestAutoMerge ? .merge : .autopilot }
        return autoCreatePullRequestOnReview ? .pullRequest : .manual
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
