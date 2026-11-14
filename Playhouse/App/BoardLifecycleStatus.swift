import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension BoardTaskManager {
    @discardableResult
    func moveToReview(
        _ id: UUID,
        clients: ConversationClients,
        settingsManager: WorkspaceSettingsManager? = nil
    ) async throws -> BoardTaskRecord {
        PlayhouseDiagnostics.record("task.move.review.started", fields: ["taskID": id.uuidString])
        let initialTask = try requireTask(id)
        if initialTask.status == .review { return BoardTaskRecord(task: initialTask) }
        guard initialTask.status == .waitingResponse else {
            throw PlayhouseManagerError.invalidTransition("Only a task in Waiting Response can move to Review.")
        }
        // A blocking question also shows Waiting Response while its turn is
        // still running; that turn owns the worktree and the final status.
        guard try !hasConversationTurnReservation(id) else {
            throw PlayhouseManagerError.invalidTransition("This task's conversation turn is still running. Answer or stop it before moving the task to Review.")
        }
        // Hold the reservation so a turn started after the check above waits
        // instead of writing files while the sync commits and pushes them.
        let record = try await withConversationTurnReservation(id) {
            _ = try await syncPullRequestChanges(id, clients: clients)
            guard try await transitionLifecycleStatus(id, from: .waitingResponse, to: .review) != nil else {
                throw PlayhouseManagerError.invalidTransition("The task's status changed before it could move to Review. Try again.")
            }
            return try get(id)
        }
        await createPullRequestsOnReviewIfNeeded(record, clients: clients, settingsManager: settingsManager)
        PlayhouseDiagnostics.record("task.move.succeeded", fields: ["taskID": id.uuidString, "status": TaskStatus.review.rawValue])
        return try get(id)
    }
    func setLifecycleStatus(_ id: UUID, to status: TaskStatus, message: String? = nil) async throws -> BoardTaskRecord {
        PlayhouseDiagnostics.record("task.lifecycle_status.write.started", fields: [
            "taskID": id.uuidString,
            "status": status.rawValue,
            "hasStatusMessage": String(message != nil)
        ])
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.status != .done else { return BoardTaskRecord(task: task) }
            let previousStatus = task.status
            task.status = status
            task.lifecycleRevision += 1
            task.statusMessage = message
            if status != .inProgress { clearProgressReport(task) }
            try await saveTaskContext(taskID: id)
            playStatusSound(for: task, from: previousStatus)
            PlayhouseDiagnostics.record("task.lifecycle_status.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    func transitionLifecycleStatus(_ id: UUID, from expectedStatus: TaskStatus, to status: TaskStatus) async throws -> Int? {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.status == expectedStatus, task.status != .done else { return nil }
            task.status = status
            task.statusMessage = nil
            if status != .inProgress { clearProgressReport(task) }
            try await saveTaskContext(taskID: id)
            playStatusSound(for: task, from: expectedStatus)
            PlayhouseDiagnostics.record("task.lifecycle_status.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return task.lifecycleRevision
        }
    }

    func restoreLifecycleStatus(_ id: UUID, to status: TaskStatus, ifRevision revision: Int) async throws -> Bool {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.status == .waitingResponse, task.lifecycleRevision == revision else { return false }
            task.status = status
            task.statusMessage = nil
            if status != .inProgress { clearProgressReport(task) }
            try await saveTaskContext(taskID: id)
            playStatusSound(for: task, from: .waitingResponse)
            PlayhouseDiagnostics.record("task.lifecycle_status.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return true
        }
    }

    func resumeWaitingResponseAfterUserInput(_ id: UUID) async throws -> BoardTaskRecord {
        let activeTurnURL = try conversationTurnActiveURL(id)
        PlayhouseDiagnostics.record("task.lifecycle_status.user_input_resume.started", fields: ["taskID": id.uuidString])
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.status == .waitingResponse,
                  FileManager.default.fileExists(atPath: activeTurnURL.path) else {
                PlayhouseDiagnostics.record("task.lifecycle_status.user_input_resume.skipped", fields: [
                    "taskID": id.uuidString,
                    "reason": FileManager.default.fileExists(atPath: activeTurnURL.path) ? "status_not_waiting_response" : "turn_outcome_inactive",
                ])
                return BoardTaskRecord(task: task)
            }
            task.status = .inProgress
            task.statusMessage = nil
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.lifecycle_status.user_input_resumed", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    func reportTurnOutcome(_ id: UUID, outcome: String) async throws -> String {
        guard TurnOutcome(rawValue: outcome) != nil else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Unknown turn outcome '\(outcome)'. Valid outcomes: "
                    + TurnOutcome.allCases.map(\.rawValue).joined(separator: ", ") + "."
            )
        }
        // A chat settles its turn with `chat page close-turn` (`settleStandaloneChatTurn`);
        // it has no board status for an outcome to decide.
        guard try standaloneChatModel(id) == nil else {
            throw BridgeCommandError(code: "invalid_argument", message: "Standalone chat has no task outcome. End its turn with chat page close-turn.")
        }
        let outcomeURL = try conversationTurnOutcomeURL(id)
        let activeURL = try conversationTurnActiveURL(id)
        let lockURL = outcomeURL.appendingPathExtension("lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-outcome") {
            guard try self.hasConversationTurnReservation(id), FileManager.default.fileExists(atPath: activeURL.path) else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "Turn outcomes can only be reported during an active conversation turn."
                )
            }
            let task = try requireSubject(id)
            // A Done task's follow-up turn reports outcomes too; they leave it Done.
            guard task.status == .inProgress || task.status == .done else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "Turn outcomes can only be reported while a task is In Progress."
                )
            }
            try Data(outcome.utf8).write(to: outcomeURL, options: .atomic)
            return outcome
        }
    }

    /// Records a standalone chat's `chat page close-turn` as its running turn's settled outcome,
    /// in the same per-turn store a task's outcome uses. A signal sent outside a turn (or naming
    /// no chat) only files the page, as before.
    func settleStandaloneChatTurn(_ chatID: String) async throws {
        guard let id = UUID(uuidString: chatID), try standaloneChatModel(id) != nil else { return }
        let outcomeURL = try conversationTurnOutcomeURL(id)
        let activeURL = try conversationTurnActiveURL(id)
        let lockURL = outcomeURL.appendingPathExtension("lock")
        try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-outcome") {
            guard try self.hasConversationTurnReservation(id), FileManager.default.fileExists(atPath: activeURL.path) else { return }
            try Data(TurnOutcome.completed.rawValue.utf8).write(to: outcomeURL, options: .atomic)
        }
    }

    @discardableResult
    func publishProgressReport(_ id: UUID, type: TaskProgressType?, customLabel: String? = nil, detail: String? = nil) async throws -> BoardTaskRecord {
        let label = type?.label ?? customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty, label.count <= 60 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Progress labels must contain 1 to 60 characters.")
        }
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (normalizedDetail?.count ?? 0) <= 200 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Progress details must be 200 characters or fewer.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            // A Done task's follow-up turn may report progress; the archive shows none.
            if task.status == .done { return BoardTaskRecord(task: task) }
            guard task.status == .inProgress else {
                throw BridgeCommandError(code: "invalid_transition", message: "Progress reports can only be published while a task is In Progress.")
            }
            task.progressTypeRawValue = type?.rawValue
            task.progressLabel = label
            task.progressDetail = normalizedDetail?.isEmpty == true ? nil : normalizedDetail
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    func recordConversationActivityDuration(taskID: UUID, activityID: String, durationMs: Int) async throws {
        guard !activityID.isEmpty, durationMs >= 0 else { return }
        try await withTaskOperationLock(taskID) {
            let task = try self.requireSubject(taskID)
            var durations = (try? task.conversationActivityDurationsData.map {
                try JSONDecoder().decode([String: Int].self, from: $0)
            }) ?? [:]
            durations[activityID] = durationMs
            task.conversationActivityDurationsData = try? JSONEncoder().encode(durations)
            try await self.saveTaskContext(taskID: taskID)
        }
    }

    func conversationActivityDurations(taskID: UUID) -> [String: Int] {
        guard let task = try? requireSubject(taskID), let data = task.conversationActivityDurationsData else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    /// Adds one turn's reported cost to the task's running totals and to its
    /// per-turn breakdown. A logical turn can report several times (Claude owes
    /// a result per background-task wake), so a repeat for the same turn adds to
    /// that turn's row rather than replacing it.
    /// Writes the per-turn transcript row before the task's running totals, so a
    /// failure between the two steps leaves the totals behind the visible
    /// breakdown rather than ahead of it: the modal (which reads the rows) and
    /// the diagnostics log both see the gap, instead of the dot silently
    /// counting a turn that never appears in the breakdown.

    func cpuUsage(_ id: UUID, dataDirectory: String? = nil) async throws -> TaskCPUUsageResult {
        let task = try requireSubject(id)
        guard let threadID = task.activeConversationID,
              let percent = await TaskCPUUsageSnapshot.current(dataDirectory: dataDirectory).percentByThreadID[threadID] else {
            return TaskCPUUsageResult(cpuPercent: nil, reason: "not_running")
        }
        return TaskCPUUsageResult(cpuPercent: percent, reason: nil)
    }

    func answeredAsyncQuestionIDs(taskID: UUID) throws -> [String] {
        try requireSubject(taskID).answeredAsyncQuestionIDs
    }

    func recordAnsweredAsyncQuestion(taskID: UUID, itemID: String) async throws {
        try await withTaskOperationLock(taskID) {
            let task = try self.requireSubject(taskID)
            if !task.answeredAsyncQuestionIDs.contains(itemID) {
                task.answeredAsyncQuestionIDs.append(itemID)
                try await self.saveTaskContext(taskID: taskID)
            }
        }
    }

    @discardableResult
    func clearProgressReport(_ id: UUID) async throws -> BoardTaskRecord {
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            clearProgressReport(task)
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    func clearProgressReport(_ task: any ConversationSubject) {
        task.progressTypeRawValue = nil
        task.progressLabel = nil
        task.progressDetail = nil
    }

    /// The prompt never reached the provider. A draft typed after sending it was saved
    /// separately, so return both to the composer rather than one.
    func returnSubmittedPromptToDraft(_ task: any ConversationSubject, submittedPrompt: String) {
        let draft = task.hasUnsentDraft ? task.savedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        let submittedText = submittedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if submittedText.isEmpty {
            // An image-only send returns through its images, still in the draft.
        } else if draft.isEmpty {
            task.savedPrompt = submittedPrompt
        } else if draft != submittedText {
            task.savedPrompt = submittedPrompt + "\n\n" + (task.savedPrompt ?? "")
        }
        task.hasUnsentDraft = task.savedPrompt != nil || !task.draftImageDataURLs.isEmpty
        task.pendingSubmittedPrompt = nil
    }

    /// A send that failed before any turn started has not delivered its prompt, so the prompt
    /// returns to the composer as the unsent draft rather than staying as the last sent prompt.
    func returnUnsentSubmittedPromptToDraft(_ id: UUID) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard let submittedPrompt = task.pendingSubmittedPrompt else { return }
            returnSubmittedPromptToDraft(task, submittedPrompt: submittedPrompt)
            try await saveTaskContext(taskID: id)
        }
    }
}
