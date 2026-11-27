import Foundation

/// What a user confirms for a scheduled task: when it runs, and the prompt it sends.
package struct TaskScheduleRequest {
    package var kind: TaskScheduleKind
    package var fireAt: Date?
    package var recurrence: TaskRecurrence?
    /// Required for a recurring schedule; it names the task each run creates.
    package var title: String?
    package var prompt: String
    package var imageDataURLs: [String] = []
    package var mode: ConversationMode = .code
    package var modelID: String?
    /// Only moves an already scheduled task, keeping the prompt, images, mode and model it was
    /// scheduled with; the payload fields above are ignored.
    package var keepsPayload = false

    package init(kind: TaskScheduleKind, fireAt: Date? = nil, recurrence: TaskRecurrence? = nil, title: String? = nil, prompt: String, imageDataURLs: [String] = [], mode: ConversationMode = .code, modelID: String? = nil, keepsPayload: Bool = false) {
        self.kind = kind
        self.fireAt = fireAt
        self.recurrence = recurrence
        self.title = title
        self.prompt = prompt
        self.imageDataURLs = imageDataURLs
        self.mode = mode
        self.modelID = modelID
        self.keepsPayload = keepsPayload
    }
}

/// One run taken from a schedule, with everything needed to start it after the schedule's
/// next state is already saved.
package struct ScheduledRunClaim {
    package let scheduleTaskID: UUID
    package let kind: TaskScheduleKind
    package var occurrence: Date
    /// More than the grace period late: the run is placed in Blocked instead of starting.
    package var dropped: Bool
    package let title: String
    package var prompt: String
    package var imageDataURLs: [String]
    package let mode: ConversationMode
    package let modelID: String?
    package let provider: ConversationProvider
    package let effort: String?
    package let repositories: [RepositoryWorktreeSpec]
    package let contextFolders: [String]

    package init(scheduleTaskID: UUID, kind: TaskScheduleKind, occurrence: Date, dropped: Bool, title: String, prompt: String, imageDataURLs: [String], mode: ConversationMode, modelID: String?, provider: ConversationProvider, effort: String?, repositories: [RepositoryWorktreeSpec], contextFolders: [String]) {
        self.scheduleTaskID = scheduleTaskID
        self.kind = kind
        self.occurrence = occurrence
        self.dropped = dropped
        self.title = title
        self.prompt = prompt
        self.imageDataURLs = imageDataURLs
        self.mode = mode
        self.modelID = modelID
        self.provider = provider
        self.effort = effort
        self.repositories = repositories
        self.contextFolders = contextFolders
    }
}

package struct ScheduledRunOutcome: Codable, Equatable {
    package let scheduleTaskID: UUID
    package let taskID: UUID
    package let dropped: Bool

    package init(scheduleTaskID: UUID, taskID: UUID, dropped: Bool) {
        self.scheduleTaskID = scheduleTaskID
        self.taskID = taskID
        self.dropped = dropped
    }
}

package struct ScheduleTickResult: Codable, Equatable {
    package var fired: [ScheduledRunOutcome] = []
    package var dropped: [ScheduledRunOutcome] = []
    package var failed: [String] = []

    package init(fired: [ScheduledRunOutcome] = [], dropped: [ScheduledRunOutcome] = [], failed: [String] = []) {
        self.fired = fired
        self.dropped = dropped
        self.failed = failed
    }
}

/// Work the bridge daemon must stay alive for although no request is running: a scheduled
/// turn started by a tick outlives the tick's own request. The daemon installs the hooks;
/// in any other process they're no-ops.
package enum BridgeBackgroundWork {
    package nonisolated(unsafe) static var onBegin: (() -> Void)?
    package nonisolated(unsafe) static var onEnd: (() -> Void)?

    @MainActor
    package static func start(_ operation: @escaping @MainActor () async -> Void) {
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
package struct TaskScheduler {
    package static let gracePeriod: TimeInterval = 3600

    package let tasks: BoardTaskManager
    package let conversations: ConversationManager

    package func tick(now: Date = .now) async -> ScheduleTickResult {
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
    package func runNow(_ id: UUID, now: Date = .now) async throws -> ScheduledRunOutcome {
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

    package init(tasks: BoardTaskManager, conversations: ConversationManager) {
        self.tasks = tasks
        self.conversations = conversations
    }
}
