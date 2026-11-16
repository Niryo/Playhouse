import Foundation

/// What a user confirms for a scheduled task: when it runs, and the prompt it sends.
struct TaskScheduleRequest {
    var kind: TaskScheduleKind
    var fireAt: Date?
    var recurrence: TaskRecurrence?
    /// Required for a recurring schedule; it names the task each run creates.
    var title: String?
    var prompt: String
    var imageDataURLs: [String] = []
    var mode: ConversationMode = .code
    var modelID: String?
    /// Only moves an already scheduled task, keeping the prompt, images, mode and model it was
    /// scheduled with; the payload fields above are ignored.
    var keepsPayload = false
}

/// One run taken from a schedule, with everything needed to start it after the schedule's
/// next state is already saved.
struct ScheduledRunClaim {
    let scheduleTaskID: UUID
    let kind: TaskScheduleKind
    var occurrence: Date
    /// More than the grace period late: the run is placed in Blocked instead of starting.
    var dropped: Bool
    let title: String
    let prompt: String
    let imageDataURLs: [String]
    let mode: ConversationMode
    let modelID: String?
    let provider: ConversationProvider
    let effort: String?
    let pullRequestMode: PullRequestMode
    let repositories: [RepositoryWorktreeSpec]
    let contextFolders: [String]
}

struct ScheduledRunOutcome: Codable, Equatable {
    let scheduleTaskID: UUID
    let taskID: UUID
    let dropped: Bool
}

struct ScheduleTickResult: Codable, Equatable {
    var fired: [ScheduledRunOutcome] = []
    var dropped: [ScheduledRunOutcome] = []
    var failed: [String] = []
}

/// Work the bridge daemon must stay alive for although no request is running: a scheduled
/// turn started by a tick outlives the tick's own request. The daemon installs the hooks;
/// in any other process they're no-ops.
enum BridgeBackgroundWork {
    nonisolated(unsafe) static var onBegin: (() -> Void)?
    nonisolated(unsafe) static var onEnd: (() -> Void)?

    @MainActor
    static func start(_ operation: @escaping @MainActor () async -> Void) {
        onBegin?()
        Task { @MainActor in
            await operation()
            onEnd?()
        }
    }
}

/// Fires due schedules. Every run becomes an ordinary board task: a one-time schedule's own
/// task, or a new task per recurring occurrence. A run more than `gracePeriod` late is not
/// started; it's left Blocked so the user can choose to run it.
@MainActor
struct TaskScheduler {
    static let gracePeriod: TimeInterval = 3600

    let tasks: BoardTaskManager
    let conversations: ConversationManager

    func tick(now: Date = .now) async -> ScheduleTickResult {
        var result = ScheduleTickResult()
        let due: [UUID]
        do {
            due = try tasks.dueScheduledTaskIDs(at: now)
        } catch {
            result.failed.append(error.localizedDescription)
            return result
        }
        for id in due {
            do {
                guard let claim = try await tasks.claimScheduledRun(id, now: now, gracePeriod: Self.gracePeriod) else { continue }
                let outcome = try await start(claim)
                if outcome.dropped { result.dropped.append(outcome) } else { result.fired.append(outcome) }
            } catch {
                result.failed.append("\(id.uuidString): \(error.localizedDescription)")
                PlayhouseDiagnostics.record("task.schedule.fire.failed", fields: ["taskID": id.uuidString].merging(PlayhouseDiagnostics.errorFields(error)) { _, new in new })
            }
        }
        return result
    }

    /// Starts one run of a schedule now, whatever its time.
    func runNow(_ id: UUID, now: Date = .now) async throws -> ScheduledRunOutcome {
        guard let claim = try await tasks.claimScheduledRun(id, now: now, gracePeriod: Self.gracePeriod, runNow: true) else {
            throw BridgeCommandError(code: "invalid_transition", message: "This task isn't scheduled.")
        }
        return try await start(claim)
    }

    private func start(_ claim: ScheduledRunClaim) async throws -> ScheduledRunOutcome {
        let taskID: UUID
        switch claim.kind {
        case .once: taskID = claim.scheduleTaskID
        case .recurring: taskID = try await tasks.createScheduledRunTask(for: claim).id
        }
        let outcome = ScheduledRunOutcome(scheduleTaskID: claim.scheduleTaskID, taskID: taskID, dropped: claim.dropped)
        guard !claim.dropped else { return outcome }
        let statusBeforeSubmission = (try? tasks.get(taskID).status).flatMap(TaskStatus.init(rawValue:)) ?? .backlog
        let conversations = conversations
        let tasks = tasks
        // The turn runs on after the tick returns, like a turn a window starts.
        BridgeBackgroundWork.start {
            do {
                _ = try await conversations.send(
                    taskID: taskID,
                    text: claim.prompt,
                    imageDataURLs: claim.imageDataURLs,
                    mode: claim.mode,
                    modelID: claim.modelID,
                    statusBeforeSubmission: statusBeforeSubmission
                )
            } catch {
                PlayhouseDiagnostics.record("task.schedule.turn.failed", fields: ["taskID": taskID.uuidString].merging(PlayhouseDiagnostics.errorFields(error)) { _, new in new })
                try? await tasks.markScheduledRunFailed(taskID, reason: error.localizedDescription)
            }
        }
        PlayhouseDiagnostics.record("task.schedule.fired", fields: [
            "scheduleTaskID": claim.scheduleTaskID.uuidString,
            "taskID": taskID.uuidString
        ])
        return outcome
    }
}
