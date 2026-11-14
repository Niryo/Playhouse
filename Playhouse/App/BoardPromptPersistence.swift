import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension BoardTaskManager {
    @discardableResult
    func rename(_ id: UUID, title: String) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw PlayhouseManagerError.invalidTitle }
        PlayhouseDiagnostics.record("task.rename.started", fields: [
            "taskID": id.uuidString,
            "titleByteCount": String(normalizedTitle.utf8.count)
        ])
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            task.title = normalizedTitle
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.rename.succeeded", fields: ["taskID": id.uuidString])
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func renameIfTitleMatches(_ id: UUID, expectedTitle: String, title: String) async throws -> BoardTaskRecord? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw PlayhouseManagerError.invalidTitle }
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.title == expectedTitle else { return nil }
            let previousTitle = task.title
            task.title = normalizedTitle
            do {
                try await saveTaskContext(taskID: id)
            } catch {
                task.title = previousTitle
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    /// `replacingDraft` marks a send of the composer's own draft, which replaces the unsent
    /// draft in this same write; other submitted prompts leave a different unsent draft alone.
    func savePrompt(_ id: UUID, prompt: String, status: TaskStatus? = nil, submitted: Bool = false, imageDataURLs: [String]? = nil, replacingDraft: Bool = false) async throws -> BoardTaskRecord {
        PlayhouseDiagnostics.record("task.prompt.write.started", fields: [
            "taskID": id.uuidString,
            "promptByteCount": String(prompt.utf8.count),
            "status": status?.rawValue ?? "unchanged",
            "submitted": String(submitted)
        ])
        if let status, status != .backlog && status != .inProgress {
            throw PlayhouseManagerError.invalidTransition("Saving a task prompt can only place it in Backlog or Progress.")
        }
        if submitted, status != .inProgress {
            throw PlayhouseManagerError.invalidTransition("A submitted prompt must place the task in Progress.")
        }
        if let imageDataURLs, imageDataURLs.count > 8 || imageDataURLs.contains(where: { !ConversationManager.isValidImageDataURL($0) }) {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            if submitted, let boardTask = task as? BoardTask {
                // A recurring schedule is a template; each run is its own task.
                if boardTask.isRecurringScheduleTemplate {
                    throw BridgeCommandError(
                        code: "invalid_transition",
                        message: "This task is a recurring schedule. Run it from Scheduled Tasks, or remove its schedule first."
                    )
                }
                // Sending a one-time scheduled task by hand starts it now, so its schedule is done.
                if boardTask.scheduleKind == .once { Self.resetSchedule(boardTask) }
            }
            let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            // A prompt sent from elsewhere (a queued follow-up, the CLI) must not replace an
            // unsent composer draft holding different text.
            let keepsUnsentDraft = submitted && !replacingDraft && task.hasUnsentDraft
                && (task.savedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") != normalizedPrompt
            if !keepsUnsentDraft {
                task.savedPrompt = normalizedPrompt.isEmpty ? nil : prompt
                if let imageDataURLs { task.draftImageDataURLs = imageDataURLs }
                // An unsubmitted prompt has not been sent, so it is the composer's unsent draft.
                task.hasUnsentDraft = !submitted && !replacingDraft && (task.savedPrompt != nil || !task.draftImageDataURLs.isEmpty)
            }
            task.pendingSubmittedPrompt = submitted ? prompt : nil
            // A Done task stays Done until its follow-up's send reopens it (`reopenDoneTask`).
            if let status, task.status != .done {
                task.status = status
                if status != .inProgress { clearProgressReport(task) }
            }
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.prompt.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue,
                "submitted": String(submitted)
            ])
            return BoardTaskRecord(task: task)
        }
    }

    /// Saves the composer's unsent text and images as one draft. Unlike `savePrompt`, it leaves
    /// the submitted prompt and status alone, so the composer can save while a turn runs
    /// without ending that turn's pending prompt. Steering, queueing, and sending clear the
    /// draft by saving the emptied composer; a blank draft therefore means the user cleared it.
    func saveDraft(_ id: UUID, prompt: String, imageDataURLs: [String]) async throws -> BoardTaskRecord {
        PlayhouseDiagnostics.record("task.draft.write.started", fields: [
            "taskID": id.uuidString,
            "promptByteCount": String(prompt.utf8.count),
            "imageCount": String(imageDataURLs.count)
        ])
        if imageDataURLs.count > 8 || imageDataURLs.contains(where: { !ConversationManager.isValidImageDataURL($0) }) {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            task.savedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
            task.draftImageDataURLs = imageDataURLs
            task.hasUnsentDraft = task.savedPrompt != nil || !imageDataURLs.isEmpty
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record("task.draft.write.succeeded", fields: [
                "taskID": id.uuidString,
                "status": task.status.rawValue
            ])
            return BoardTaskRecord(task: task)
        }
    }

    /// Saves the unsent review comments with the draft. An empty `data` clears them. Comments
    /// leave `hasUnsentDraft` alone: that flag says whether `savedPrompt` and the images are a
    /// draft, and a comment added after a send must not turn the sent prompt back into one.
    /// `appending` adds only comments not already saved, keeping the rest; a send that ends
    /// without delivering its comments returns them this way, so it never overwrites comments a
    /// newer view of the task saved meanwhile.
    @discardableResult
    func savePendingAnnotations(_ id: UUID, data: Data?, appending: Bool = false) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            var annotations = PersistedAnnotations.decode(data)
            if appending {
                let saved = PersistedAnnotations.decode(task.pendingAnnotationsData)
                annotations = saved + annotations.filter { added in !saved.contains { $0.id == added.id } }
            }
            let encoded = PersistedAnnotations.encode(annotations)
            guard task.pendingAnnotationsData != encoded else { return BoardTaskRecord(task: task) }
            task.pendingAnnotationsData = encoded
            try await saveTaskContext(taskID: id)
            return BoardTaskRecord(task: task)
        }
    }

    /// Changes the text of one unsent comment; text that is empty once trimmed deletes it.
    @discardableResult
    func editPendingAnnotation(_ id: UUID, annotationID: UUID, comment: String) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            var annotations = PersistedAnnotations.decode(task.pendingAnnotationsData)
            guard let index = annotations.firstIndex(where: { $0.id == annotationID }) else {
                throw BridgeCommandError(code: "not_found", message: "No unsent comment \(annotationID.uuidString) on this task.")
            }
            let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if comment.isEmpty {
                annotations.remove(at: index)
            } else {
                annotations[index].comment = comment
            }
            task.pendingAnnotationsData = PersistedAnnotations.encode(annotations)
            try await saveTaskContext(taskID: id)
            PlayhouseDiagnostics.record(comment.isEmpty ? "task.comment.deleted" : "task.comment.edited", fields: [
                "taskID": id.uuidString, "commentID": annotationID.uuidString
            ])
            return BoardTaskRecord(task: task)
        }
    }

    /// The side chats saved on the task, oldest first.
    func sideChats(_ id: UUID) throws -> [SavedSideChat] {
        SavedSideChats.decode(try requireSubject(id).sideChatsData)
    }

    /// Adds `exchange` to the side chat saved with `sideChat`'s id, or saves `sideChat` with it
    /// when it isn't saved yet, keeping `sideChat`'s model and effort. Returns the saved copy.
    func appendSideChatExchange(_ id: UUID, _ sideChat: SavedSideChat, exchange: [SavedSideChat.Message]) async throws -> SavedSideChat {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            var sideChats = SavedSideChats.decode(task.sideChatsData)
            let index = sideChats.firstIndex(where: { $0.id == sideChat.id })
            var saved = index.map { sideChats[$0] } ?? sideChat
            saved.modelID = sideChat.modelID
            saved.effort = sideChat.effort
            saved.messages += exchange
            if let index { sideChats[index] = saved } else { sideChats.append(saved) }
            task.sideChatsData = SavedSideChats.encode(sideChats)
            try await saveTaskContext(taskID: id)
            return saved
        }
    }

    /// Images sent with a prompt stay in the draft until its turn starts, so a restart before
    /// then returns them with the prompt. Once the turn starts they leave the draft, unless the
    /// user has since saved a new draft. A draft saved in that short window replaces the sent
    /// images, so only the prompt text returns if Playhouse also stops before the turn starts.
    func clearSentDraftImages(_ id: UUID, sentImageDataURLs: [String]) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard !task.hasUnsentDraft, !sentImageDataURLs.isEmpty, task.draftImageDataURLs == sentImageDataURLs else { return }
            task.draftImageDataURLs = []
            try await saveTaskContext(taskID: id)
        }
    }

    func clearPendingSubmittedPrompt(_ id: UUID) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            guard task.pendingSubmittedPrompt != nil else { return }
            task.pendingSubmittedPrompt = nil
            try await saveTaskContext(taskID: id)
        }
    }
}
