import Foundation
import SwiftData

extension BoardTaskManager {
    // MARK: Scheduling

    /// Every scheduled task: one-time schedules still waiting to fire and recurring
    /// templates, soonest first.
    func scheduledTasks() throws -> [BoardTaskRecord] {
        try listModels()
            .filter { $0.scheduleKind != nil }
            .sorted { ($0.scheduledAt ?? .distantFuture) < ($1.scheduledAt ?? .distantFuture) }
            .map { BoardTaskRecord(task: $0, includeDraftImages: false) }
    }

    /// Confirms a schedule for a task. A started conversation can have one-time follow-ups;
    /// recurring schedules remain templates for conversations that haven't started. A request
    /// that keeps its payload reschedules an already scheduled task, keeping its saved prompt.
    @discardableResult
    func setSchedule(_ id: UUID, _ request: TaskScheduleRequest, now: Date = .now) async throws -> BoardTaskRecord {
        if request.imageDataURLs.count > 8 || request.imageDataURLs.contains(where: { !ConversationManager.isValidImageDataURL($0) }) {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let nextRun: Date
        switch request.kind {
        case .once:
            guard let fireAt = request.fireAt else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose when the task should run.")
            }
            guard fireAt > now else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose a time in the future.")
            }
            nextRun = fireAt
        case .recurring:
            guard !title.isEmpty else {
                throw BridgeCommandError(code: "invalid_argument", message: "A recurring task needs a title.")
            }
            guard let recurrence = request.recurrence, recurrence.isValid else {
                throw BridgeCommandError(code: "invalid_argument", message: "Choose how often the task should repeat.")
            }
            nextRun = recurrence.nextOccurrence(after: now)
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            let hasStarted = task.activeConversationID != nil || task.pendingSubmittedPrompt != nil
                || !(task.status == .backlog || task.status == .blocked)
            guard !hasStarted || request.kind == .once else {
                throw BridgeCommandError(code: "invalid_transition", message: "An existing conversation can only have a one-time scheduled message.")
            }
            // A request that keeps its payload only reschedules: the task keeps the prompt,
            // images, mode and model it was scheduled with.
            var request = request
            if request.keepsPayload {
                guard task.scheduleKind != nil else {
                    throw BridgeCommandError(code: "invalid_argument", message: "A scheduled task needs a prompt.")
                }
                request.prompt = task.scheduledPrompt ?? ""
                request.imageDataURLs = task.scheduledImageDataURLs
                request.mode = task.scheduledModeRawValue.flatMap(ConversationMode.init(rawValue:)) ?? request.mode
                request.modelID = task.scheduledModelID
            }
            let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty || !request.imageDataURLs.isEmpty else {
                throw BridgeCommandError(code: "invalid_argument", message: "A scheduled task needs a prompt.")
            }
            if !title.isEmpty { task.title = title }
            task.scheduleKind = request.kind
            task.scheduledAt = nextRun
            task.scheduleRecurrence = request.kind == .recurring ? request.recurrence : nil
            task.scheduledPrompt = prompt.isEmpty ? nil : request.prompt
            task.scheduledImageDataURLs = request.imageDataURLs
            task.scheduledModeRawValue = request.mode.rawValue
            task.scheduledModelID = request.modelID
            task.schedulePaused = false
            // A new task keeps the scheduled prompt as its unsent draft until delivery. For an
            // existing conversation the schedule payload stays separate from the user's draft.
            if !hasStarted {
                task.savedPrompt = prompt.isEmpty ? nil : request.prompt
                task.draftImageDataURLs = request.imageDataURLs
                task.hasUnsentDraft = task.savedPrompt != nil || !request.imageDataURLs.isEmpty
            }
            if !hasStarted && task.status != .backlog {
                task.status = .backlog
                task.statusMessage = nil
            }
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.schedule.set", fields: [
                "taskID": id.uuidString,
                "kind": request.kind.rawValue,
                "scheduledAt": ISO8601DateFormatter().string(from: nextRun)
            ])
            return BoardTaskRecord(task: task)
        }
    }

    /// Removes a task's schedule. A recurring template becomes an ordinary Backlog task.
    @discardableResult
    func clearSchedule(_ id: UUID) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.scheduleKind != nil else {
                throw BridgeCommandError(code: "invalid_transition", message: "This task isn't scheduled.")
            }
            if !task.hasUnsentDraft, let prompt = task.scheduledPrompt {
                task.savedPrompt = prompt
                task.draftImageDataURLs = task.scheduledImageDataURLs
                task.hasUnsentDraft = true
            }
            Self.resetSchedule(task)
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.schedule.cleared", fields: ["taskID": id.uuidString])
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func setSchedulePaused(_ id: UUID, paused: Bool, now: Date = .now) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.scheduleKind == .recurring, let recurrence = task.scheduleRecurrence else {
                throw BridgeCommandError(code: "invalid_transition", message: "Only a recurring task can be paused.")
            }
            task.schedulePaused = paused
            // Resuming starts from the next occurrence rather than catching up the pause.
            if !paused { task.scheduledAt = recurrence.nextOccurrence(after: now) }
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    func dueScheduledTaskIDs(at now: Date) throws -> [UUID] {
        try listModels()
            .filter { $0.scheduleKind != nil && !$0.schedulePaused && ($0.scheduledAt.map { $0 <= now } ?? false) }
            .sorted { ($0.scheduledAt ?? now) < ($1.scheduledAt ?? now) }
            .map(\.id)
    }

    /// Takes one due run of a schedule, saving the schedule's next state before anything is
    /// sent, so a second tick (another process, or a retry) can't run it twice.
    /// `runNow` takes a run immediately regardless of the schedule's time.
    func claimScheduledRun(_ id: UUID, now: Date, gracePeriod: TimeInterval, runNow: Bool = false) async throws -> ScheduledRunClaim? {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard let kind = task.scheduleKind, let scheduledAt = task.scheduledAt else {
                if runNow { throw BridgeCommandError(code: "invalid_transition", message: "This task isn't scheduled.") }
                return nil
            }
            guard runNow || (!task.schedulePaused && scheduledAt <= now) else { return nil }
            var payload = ScheduledRunClaim(
                scheduleTaskID: id,
                kind: kind,
                occurrence: runNow ? now : scheduledAt,
                dropped: false,
                title: task.title,
                prompt: task.scheduledPrompt ?? "",
                imageDataURLs: task.scheduledImageDataURLs,
                mode: task.scheduledModeRawValue.flatMap(ConversationMode.init(rawValue:)) ?? .code,
                modelID: task.scheduledModelID,
                provider: task.conversationProvider,
                effort: task.conversationEffortRawValue,
                pullRequestMode: task.pullRequestMode,
                repositories: task.repositoryWorktrees.map {
                    RepositoryWorktreeSpec(
                        repositoryPath: $0.repositoryPath,
                        branch: nil,
                        branchFrom: $0.branchFrom,
                        mergeTarget: $0.mergeTarget
                    )
                },
                contextFolders: task.contextFolderPaths
            )
            switch kind {
            case .once:
                let hasStarted = task.activeConversationID != nil || task.pendingSubmittedPrompt != nil
                    || !(task.status == .backlog || task.status == .blocked)
                payload.dropped = !runNow && now.timeIntervalSince(scheduledAt) > gracePeriod
                Self.resetSchedule(task)
                if payload.dropped && !hasStarted {
                    Self.markMissedScheduledRun(task, occurrence: scheduledAt, prompt: payload.prompt, imageDataURLs: payload.imageDataURLs)
                } else if !payload.dropped && !hasStarted {
                    // Until the send records the prompt, it waits as a draft, so a daemon that stops
                    // in between leaves it in the composer rather than losing it.
                    task.savedPrompt = payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : payload.prompt
                    task.draftImageDataURLs = payload.imageDataURLs
                    task.hasUnsentDraft = task.savedPrompt != nil || !payload.imageDataURLs.isEmpty
                }
            case .recurring:
                guard let recurrence = task.scheduleRecurrence else { return nil }
                if !runNow {
                    // Missed occurrences collapse into the newest one; older ones are skipped.
                    let occurrence = recurrence.latestOccurrence(atOrBefore: now, notBefore: scheduledAt) ?? scheduledAt
                    payload.occurrence = occurrence
                    payload.dropped = now.timeIntervalSince(occurrence) > gracePeriod
                    task.scheduledAt = recurrence.nextOccurrence(after: now)
                }
                task.lastScheduledRunAt = payload.occurrence
            }
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.schedule.claimed", fields: [
                "taskID": id.uuidString,
                "kind": kind.rawValue,
                "dropped": String(payload.dropped),
                "runNow": String(runNow)
            ])
            return payload
        }
    }

    /// Creates the board task for one run of a recurring schedule. A dropped run lands in
    /// Blocked with the prompt as its draft, so the user decides whether to run it.
    func createScheduledRunTask(for claim: ScheduledRunClaim) async throws -> BoardTaskRecord {
        let created = try await create(
            title: claim.title,
            repositories: claim.repositories,
            contextFolders: claim.contextFolders,
            provider: claim.provider,
            pullRequestMode: claim.pullRequestMode,
            prompt: claim.prompt
        )
        let record = try await withTaskOperationLock(created.id) {
            let task = try requireTask(created.id)
            task.scheduleSourceTaskID = claim.scheduleTaskID
            task.conversationEffortRawValue = claim.effort
            if claim.dropped {
                Self.markMissedScheduledRun(task, occurrence: claim.occurrence, prompt: claim.prompt, imageDataURLs: claim.imageDataURLs)
            }
            try await saveTaskContext(taskID: created.id)
            return BoardTaskRecord(task: task)
        }
        try await withTaskOperationLock(claim.scheduleTaskID) {
            guard let template = try? requireTask(claim.scheduleTaskID) else { return }
            template.lastScheduledRunTaskID = created.id
            try await saveTaskContext(taskID: claim.scheduleTaskID)
        }
        return record
    }

    /// A scheduled run that couldn't start is left Blocked with its prompt as the draft.
    func markScheduledRunFailed(_ id: UUID, reason: String) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.codexThreadID == nil, task.claudeSessionID == nil else { return }
            task.status = .blocked
            task.statusMessage = "The scheduled run couldn't start: \(reason)"
            if task.savedPrompt != nil || !task.draftImageDataURLs.isEmpty { task.hasUnsentDraft = true }
            try await saveTaskContext(taskID: id)
        }
    }

    static func resetSchedule(_ task: BoardTask) {
        task.scheduleKind = nil
        task.scheduledAt = nil
        task.scheduleRecurrence = nil
        task.scheduledPrompt = nil
        task.scheduledImageDataURLs = []
        task.scheduledModeRawValue = nil
        task.scheduledModelID = nil
        task.schedulePaused = false
    }

    static func markMissedScheduledRun(_ task: BoardTask, occurrence: Date, prompt: String, imageDataURLs: [String]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        task.status = .blocked
        task.statusMessage = "Missed scheduled run (\(formatter.string(from: occurrence))) — not started"
        task.savedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
        task.draftImageDataURLs = imageDataURLs
        task.hasUnsentDraft = task.savedPrompt != nil || !imageDataURLs.isEmpty
    }
}
