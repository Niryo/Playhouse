import AppKit
import SwiftData
import SwiftUI

extension KanbanBoardView {
    func moveTask(
        id: UUID,
        to status: TaskStatus,
        allowUnmergedPullRequests: Bool = false,
        allowDiscardingUncommittedChanges: Bool = false
    ) {
        guard let task = tasks.first(where: { $0.id == id }), task.status != status else { return }
        if status == .review {
            guard task.status == .waitingResponse else { return }
            Task { @MainActor in
                do {
                    _ = try await remoteConversations.moveTaskToReview(taskID: id)
                } catch {
                    reviewMoveError = error.localizedDescription
                }
            }
            return
        }
        guard status == .done else { return }
        let skipMergeVerification = mergedReviewTaskIDs.contains(id)
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).move(
                    id,
                    to: status.rawValue,
                    allowUnmergedPullRequests: allowUnmergedPullRequests,
                    allowDiscardingUncommittedChanges: allowDiscardingUncommittedChanges,
                    skipMergeVerification: skipMergeVerification
                )
            } catch PlayhouseManagerError.unmergedPullRequests {
                taskAwaitingUnmergedConfirmation = id
            } catch let error as PlayhouseManagerError {
                if case .uncommittedChanges = error {
                    discardConfirmationMessage = error.localizedDescription
                    taskAwaitingDiscardConfirmation = id
                } else {
                    doneMoveError = error.localizedDescription
                }
            } catch {
                doneMoveError = error.localizedDescription
            }
        }
    }

    func checkReviewPullRequests() {
        let now = Date()
        // Tests shorten the cooldown; what they check (checks suppressed while it runs,
        // then exactly one trailing check) does not depend on its length.
        let minimumInterval = ProcessInfo.processInfo.environment["PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS"]
            .flatMap(TimeInterval.init) ?? 20
        if checkingMergedPullRequests {
            mergedPullRequestCheckPending = true
            return
        }
        if let lastMergedPullRequestCheckAt {
            let remaining = minimumInterval - now.timeIntervalSince(lastMergedPullRequestCheckAt)
            if remaining > 0 {
                mergedPullRequestCheckPending = true
                guard !mergedPullRequestCheckTimerScheduled else { return }
                mergedPullRequestCheckTimerScheduled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(remaining))
                    mergedPullRequestCheckTimerScheduled = false
                    guard mergedPullRequestCheckPending else { return }
                    mergedPullRequestCheckPending = false
                    checkReviewPullRequests()
                }
                return
            }
        }
        let reviewTasks = tasks.filter { task in
            task.status == .review && task.repositoryWorktrees.contains {
                !$0.isPending && $0.pullRequestNumber != nil
            }
        }
        let reviewIDs = reviewTasks.map(\.id)
        guard !reviewIDs.isEmpty else {
            mergedReviewTaskIDs = []
            conflictedReviewTaskIDs = []
            return
        }
        lastMergedPullRequestCheckAt = now
        checkingMergedPullRequests = true
        Task { @MainActor in
            defer {
                checkingMergedPullRequests = false
                if mergedPullRequestCheckPending {
                    mergedPullRequestCheckPending = false
                    checkReviewPullRequests()
                }
            }
            let manager = BoardTaskManager(modelContext: modelContext)
            await withTaskGroup(of: (UUID, [PullRequestReviewState]?, String?).self) { group in
                for task in reviewTasks {
                    group.addTask {
                        do { return (task.id, try await manager.reviewPullRequests(task), nil) }
                        catch { return (task.id, nil, error.localizedDescription) }
                    }
                }
                for await (id, states, error) in group {
                    if let states {
                        recordPullRequestHealth(id, states: states)
                        if states.isEmpty {
                            // The persisted query can briefly lag the visible
                            // SwiftData task after an external store update.
                            // Allow the already-coalesced appearance/focus check
                            // to retry immediately with the refreshed records.
                            lastMergedPullRequestCheckAt = nil
                        }
                        if !states.isEmpty && states.allSatisfy(\.merged) { mergedReviewTaskIDs.insert(id) }
                        else { mergedReviewTaskIDs.remove(id) }
                        if states.contains(where: \.requiresConflictResolution) { conflictedReviewTaskIDs.insert(id) }
                        else { conflictedReviewTaskIDs.remove(id) }
                        syncReviewChangesIfNeeded(for: id, states: states)
                        followPullRequestAutopilot(for: id, states: states)
                    } else if let error {
                        mergedReviewTaskIDs.remove(id)
                        conflictedReviewTaskIDs.remove(id)
                        if isStillInReview(id) { pullRequestError = error }
                    }
                }
            }
            mergedReviewTaskIDs.formIntersection(reviewIDs)
            conflictedReviewTaskIDs.formIntersection(reviewIDs)
            autopilotPendingTaskIDs.formIntersection(reviewIDs)
            scheduleAutopilotPollIfNeeded()
        }
    }

    /// Whether a probe's failure is still worth reporting: a task that left Review while its
    /// probe ran (moved to Done) has no pull request state left. The move removes the worktrees
    /// before it saves the status this board reads, so a removed worktree counts as gone too.
    func isStillInReview(_ id: UUID) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), task.status == .review else { return false }
        return task.repositoryWorktrees.allSatisfy { $0.isPending || FileManager.default.fileExists(atPath: $0.worktreePath) }
    }

    /// A card keeps its last colours while a fix turn runs; they refresh on the
    /// next probe once the task is back in Review.
    func recordPullRequestHealth(_ id: UUID, states: [PullRequestReviewState]) {
        guard !states.isEmpty else { return }
        pullRequestHealth[id] = Dictionary(states.map { ($0.number, $0.health) }, uniquingKeysWith: { _, new in new })
    }

    /// Autopilot tasks act on what the probe found: red asks the daemon to run a
    /// fix turn (it re-probes and decides through the same shared assessment),
    /// pending keeps the slow poll alive, and green or merged lets it stop.
    func followPullRequestAutopilot(for id: UUID, states: [PullRequestReviewState]) {
        guard let task = tasks.first(where: { $0.id == id }), task.pullRequestAutopilot, task.status == .review else {
            autopilotPendingTaskIDs.remove(id)
            return
        }
        switch BoardTaskManager.assessPullRequestAutopilot(states) {
        case .pending:
            autopilotPendingTaskIDs.insert(id)
        case .merged:
            autopilotPendingTaskIDs.remove(id)
        case .green:
            autopilotPendingTaskIDs.remove(id)
            // The daemon owns the loop guard and the merge: let it confirm green,
            // reset the fix streak so a later red state gets a full set of
            // attempts, and in merge mode merge the PRs.
            if task.pullRequestAutoMerge || task.pullRequestAutopilotFixAttempts > 0 || task.pullRequestAutopilotLastFixSignature != nil {
                runPullRequestAutopilot(for: id)
            }
        case .needsFix:
            autopilotPendingTaskIDs.remove(id)
            runPullRequestAutopilot(for: id)
        }
    }

    func runPullRequestAutopilot(for id: UUID) {
        guard autopilotRunningTaskIDs.insert(id).inserted else {
            // A probe that lands while the previous pass is still finishing must
            // not be lost: the poll looks again shortly.
            autopilotPendingTaskIDs.insert(id)
            scheduleAutopilotPollIfNeeded()
            return
        }
        Task { @MainActor in
            defer { autopilotRunningTaskIDs.remove(id) }
            do {
                let outcome = try await remoteConversations.runPullRequestAutopilot(taskID: id) { states in
                    recordPullRequestHealth(id, states: states)
                }
                switch outcome.action {
                case "fixed", "merged":
                    // Its states predate the fix or merge; probe the task's PRs
                    // afresh so the card shows where they stand now.
                    lastMergedPullRequestCheckAt = nil
                    checkReviewPullRequests()
                case "green", "stalled":
                    recordPullRequestHealth(id, states: outcome.states)
                default:
                    recordPullRequestHealth(id, states: outcome.states)
                    autopilotPendingTaskIDs.insert(id)
                }
                scheduleAutopilotPollIfNeeded()
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }

    /// While an autopilot PR still has checks running, re-probe just those tasks
    /// every few minutes. The poll stops once none are pending; a focus probe
    /// that finds one red again restarts it.
    func scheduleAutopilotPollIfNeeded() {
        guard !autopilotPendingTaskIDs.isEmpty, !autopilotPollScheduled else { return }
        autopilotPollScheduled = true
        let interval = ProcessInfo.processInfo.environment["PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS"]
            .flatMap(TimeInterval.init) ?? 180
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            autopilotPollScheduled = false
            let pending = tasks.filter { autopilotPendingTaskIDs.contains($0.id) && $0.status == .review && $0.pullRequestAutopilot }
            autopilotPendingTaskIDs = Set(pending.map(\.id))
            let manager = BoardTaskManager(modelContext: modelContext)
            for task in pending {
                do {
                    let states = try await manager.reviewPullRequests(task)
                    recordPullRequestHealth(task.id, states: states)
                    followPullRequestAutopilot(for: task.id, states: states)
                } catch {
                    autopilotPendingTaskIDs.remove(task.id)
                    if isStillInReview(task.id) { pullRequestError = error.localizedDescription }
                }
            }
            scheduleAutopilotPollIfNeeded()
        }
    }

    /// A reviewed task must not hold local-only pull request changes. When a
    /// probe finds the local and remote heads diverged on a mergeable PR, sync
    /// (commit, merge remote PR commits, push) through the shared bridge command.
    /// Each head pairing is attempted once, so a repository the sync cannot act
    /// on (for example, one with no publishing remote) keeps its conflict action
    /// without a retry loop; the daemon moves the task to Blocked when a sync fails.
    func syncReviewChangesIfNeeded(for id: UUID, states: [PullRequestReviewState]) {
        let needsSync = states.contains { state in
            !state.merged && !state.hasConflicts && state.headRefOid != nil && state.headRefOid != state.localHeadOid
        }
        guard needsSync else { return }
        let signature = states
            .map { "\($0.number):\($0.headRefOid ?? "-"):\($0.localHeadOid ?? "-")" }
            .sorted()
            .joined(separator: "|")
        guard attemptedReviewSyncSignatures[id] != signature, !syncingReviewTaskIDs.contains(id) else { return }
        attemptedReviewSyncSignatures[id] = signature
        syncingReviewTaskIDs.insert(id)
        Task { @MainActor in
            defer { syncingReviewTaskIDs.remove(id) }
            do {
                let outcome = try await remoteConversations.syncPullRequestChanges(taskID: id)
                if outcome.skipped != nil {
                    // An active turn owns the worktree; let a later probe retry.
                    attemptedReviewSyncSignatures.removeValue(forKey: id)
                    return
                }
                guard outcome.records.contains(where: { $0.action.hasSuffix("pushed") }) else { return }
                lastMergedPullRequestCheckAt = nil
                checkReviewPullRequests()
            } catch {
                attemptedReviewSyncSignatures.removeValue(forKey: id)
                pullRequestError = error.localizedDescription
            }
        }
    }

    var reviewPullRequestSignature: [String] {
        tasks.flatMap { task in
            task.repositoryWorktrees.compactMap { record in
                guard task.status == .review, let number = record.pullRequestNumber else {
                    return nil
                }
                // The mode is part of the key so turning autopilot on re-probes
                // once the board sees the change.
                return "\(task.id.uuidString):\(record.repositoryPath):\(number):\(task.pullRequestMode.rawValue)"
            }
        }.sorted()
    }

    func createPullRequests(for task: BoardTask) {
        guard taskCreatingPullRequests.insert(task.id).inserted else { return }
        Task { @MainActor in
            defer { taskCreatingPullRequests.remove(task.id) }
            do {
                _ = try await remoteConversations.createPullRequests(taskID: task.id)
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }

    func setPullRequestMode(for task: BoardTask, mode: PullRequestMode) {
        Task { @MainActor in
            do {
                // Turning autopilot on in Review changes `reviewPullRequestSignature`,
                // which re-probes the PR and starts following it.
                _ = try await remoteConversations.setPullRequestMode(taskID: task.id, mode: mode)
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }
}
