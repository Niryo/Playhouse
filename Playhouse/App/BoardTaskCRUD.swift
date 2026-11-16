import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension BoardTaskManager {
    func list(status: TaskStatus? = nil) throws -> [BoardTaskRecord] {
        // A chat left over as a hidden task would otherwise list as an ordinary card. This is
        // best-effort maintenance on a read path: if the store itself is unreadable, the fetch
        // below reports that with its own full diagnostics rather than failing here first.
        do {
            try migrateLegacyStandaloneChatTasks()
        } catch {
            PlayhouseDiagnostics.record("chat.legacy_task.migration_deferred", fields: PlayhouseDiagnostics.errorFields(error))
        }
        let descriptor: FetchDescriptor<BoardTask>
        if let status {
            let statusRawValue = status.rawValue
            descriptor = FetchDescriptor(
                predicate: #Predicate { $0.statusRawValue == statusRawValue },
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        }
        let readFields = persistenceReadFields(operation: "BoardTaskManager.list")
        let readStartedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("persistence.read.started", fields: readFields)
        do {
            let tasks = try modelContext.fetch(descriptor)
                .filter { !$0.isRecurringScheduleTemplate }
                .map { BoardTaskRecord(task: $0, includeDraftImages: false) }
            var fields = readFields
            fields["resultCount"] = String(tasks.count)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            PlayhouseDiagnostics.record("persistence.read.succeeded", fields: fields)
            return tasks
        } catch {
            var fields = persistenceReadFailureFields(error, context: readFields)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            PlayhouseDiagnostics.record("persistence.read.failed", fields: fields)
            throw error
        }
    }

    func get(_ id: UUID) throws -> BoardTaskRecord {
        BoardTaskRecord(task: try requireTask(id))
    }

    @discardableResult
    func create(title: String, workspaceRoots: [String], provider: ConversationProvider = .codex) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw PlayhouseManagerError.invalidTitle }
        let normalizedRoots = try Self.normalizeRoots(workspaceRoots)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: normalizedRoots, conversationProvider: provider)
        modelContext.insert(task)
        try await saveTaskContext(taskID: task.id)
        PlayhouseDiagnostics.record("task.create.succeeded", fields: [
            "taskID": task.id.uuidString,
            "titleByteCount": String(normalizedTitle.utf8.count),
            "workspaceRootCount": String(normalizedRoots.count),
            "workspaceRoots": normalizedRoots.joined(separator: "\n"),
            "status": task.status.rawValue
        ])
        return BoardTaskRecord(task: task)
    }

    @discardableResult
    func create(title: String, repositories: [RepositoryWorktreeSpec], contextFolders: [String], provider: ConversationProvider = .codex, prompt: String? = nil, pluginPlacement: String? = nil, authoredPluginID: String? = nil) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw PlayhouseManagerError.invalidTitle }
        let folders = try Self.normalizeOptionalRoots(contextFolders)
        var worktrees: [RepositoryWorktreeRecord] = []
        for spec in repositories {
            worktrees.append(try await worktreeService.pendingRecord(spec: spec))
        }
        let duplicate = worktrees.first { record in
            worktrees.filter { $0.repositoryPath == record.repositoryPath }.count > 1
        }
        if let duplicate {
            throw BridgeCommandError(code: "invalid_argument", message: "A repository can be selected only once per task: \(duplicate.repositoryPath)")
        }
        let roots = try Self.normalizeOptionalRoots(worktrees.map(\.repositoryPath) + folders)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: roots, conversationProvider: provider)
        task.repositoryWorktrees = worktrees
        task.contextFolderPaths = folders
        task.pluginPlacement = pluginPlacement
        task.authoredPluginID = authoredPluginID
        // A prompt given at creation has not been sent, so it is the composer's draft.
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            task.savedPrompt = prompt
            task.hasUnsentDraft = true
        }
        return try await withRepositoryAllocationLocks(worktrees.map(\.repositoryPath)) {
            try validateRepositoryAssignments(worktrees, excludingTaskID: nil)
            modelContext.insert(task)
            try await saveTaskContext(taskID: task.id)
            PlayhouseDiagnostics.record("task.create.succeeded", fields: [
                "taskID": task.id.uuidString,
                "titleByteCount": String(normalizedTitle.utf8.count),
                "repositoryCount": String(worktrees.count),
                "repositoryPaths": worktrees.map(\.repositoryPath).joined(separator: "\n"),
                "contextFolderCount": String(folders.count),
                "contextFolders": folders.joined(separator: "\n"),
                "status": task.status.rawValue,
                "provider": provider.rawValue,
                "hasSavedPrompt": String(task.savedPrompt != nil)
            ])
            return BoardTaskRecord(task: task)
        }
    }

    /// Converts any standalone chat still stored as a hidden board task into the dedicated
    /// model, then deletes the board row.
    ///
    /// The chat's ID is carried over, because the conversation transcript is keyed by it — a
    /// fresh ID would strand the user's existing chat history. Page content is keyed
    /// separately in the chat archive and is unaffected either way. Without this, dropping the
    /// hidden-task flag would let that row surface as an ordinary "Chat" card on the board.
    func migrateLegacyStandaloneChatTasks() throws {
        let legacy = try modelContext.fetch(
            FetchDescriptor<BoardTask>(predicate: #Predicate { $0.legacyStandaloneChatMarker })
        )
        guard !legacy.isEmpty else { return }
        var alreadyMigrated = try modelContext.fetch(FetchDescriptor<StandaloneChat>()).contains { $0.authoredPluginID == nil }
        for task in legacy {
            if !alreadyMigrated {
                let chat = StandaloneChat(provider: task.conversationProvider)
                chat.id = task.id
                chat.title = task.title
                chat.createdAt = task.createdAt
                chat.statusRawValue = task.statusRawValue
                chat.lifecycleRevision = task.lifecycleRevision
                // Carry the status's explanation and timing with the status itself: a chat
                // migrated mid-turn would otherwise sit In Progress with no stated reason.
                chat.statusMessage = task.statusMessage
                chat.progressTypeRawValue = task.progressTypeRawValue
                chat.progressLabel = task.progressLabel
                chat.progressDetail = task.progressDetail
                chat.inProgressStartedAt = task.inProgressStartedAt
                chat.totalInProgressSeconds = task.totalInProgressSeconds
                chat.codexThreadID = task.codexThreadID
                chat.claudeSessionID = task.claudeSessionID
                chat.conversationEffortRawValue = task.conversationEffortRawValue
                chat.conversationModelIDsData = task.conversationModelIDsData
                chat.savedPrompt = task.savedPrompt
                chat.pendingSubmittedPrompt = task.pendingSubmittedPrompt
                chat.hasUnsentDraft = task.hasUnsentDraft
                chat.draftImageDataURLsData = task.draftImageDataURLsData
                chat.pendingAnnotationsData = task.pendingAnnotationsData
                chat.sideChatsData = task.sideChatsData
                chat.conversationActivityDurationsData = task.conversationActivityDurationsData
                chat.answeredAsyncQuestionIDsData = task.answeredAsyncQuestionIDsData
                modelContext.insert(chat)
                alreadyMigrated = true
            }
            modelContext.delete(task)
        }
        try modelContext.save()
        PlayhouseDiagnostics.record("chat.legacy_task.migrated", fields: ["count": String(legacy.count)])
    }

    /// Returns the single standalone chat, creating it the first time it's needed.
    ///
    /// The chat is its own model, not a task: it has no board column, repositories or
    /// worktrees, so nothing needs to filter it out of `list()` or the Kanban columns.
    @discardableResult
    func getOrCreateStandaloneChat(provider: ConversationProvider) async throws -> BoardTaskRecord {
        try migrateLegacyStandaloneChatTasks()
        let descriptor = FetchDescriptor<StandaloneChat>(sortBy: [SortDescriptor(\.createdAt)])
        if let existing = try modelContext.fetch(descriptor).first(where: { $0.authoredPluginID == nil }) {
            return BoardTaskRecord(task: existing)
        }
        let chat = StandaloneChat(provider: provider)
        modelContext.insert(chat)
        try await saveTaskContext(taskID: chat.id)
        PlayhouseDiagnostics.record("chat.created", fields: ["chatID": chat.id.uuidString, "provider": provider.rawValue])
        return BoardTaskRecord(task: chat)
    }

    func setPluginDraftContext(_ id: UUID, folder: String) throws -> BoardTaskRecord {
        guard let chat = try standaloneChatModel(id) else {
            throw BridgeCommandError(code: "not_found", message: "Plugin editor not found.")
        }
        chat.pluginContextFolder = folder
        try modelContext.save()
        return BoardTaskRecord(task: chat)
    }

    /// Creates an editor conversation without adding a card to the task board.
    func createPluginConversation(name: String, pluginID: String, placement: String, contextFolder: String, provider: ConversationProvider, authoringName: String? = nil, presentation: String? = nil, prompt: String? = nil) async throws -> BoardTaskRecord {
        let chat = StandaloneChat(provider: provider)
        chat.title = name
        chat.authoredPluginID = pluginID
        chat.pluginPlacement = placement
        chat.pluginAuthoringName = authoringName
        chat.pluginAuthoringPresentation = presentation
        chat.pluginContextFolder = contextFolder
        chat.savedPrompt = prompt
        chat.hasUnsentDraft = prompt?.isEmpty == false
        modelContext.insert(chat)
        try await saveTaskContext(taskID: chat.id)
        return BoardTaskRecord(task: chat)
    }

    func pluginConversations() throws -> [BoardTaskRecord] {
        let sessions = try modelContext.fetch(FetchDescriptor<StandaloneChat>(sortBy: [SortDescriptor(\.createdAt)]))
            .filter { $0.authoredPluginID != nil }.map { chat in
                var record = BoardTaskRecord(task: chat)
                // The agent can rename the plugin; its draft manifest's name wins over the setup-time title.
                if let folder = chat.pluginContextFolder, let id = chat.authoredPluginID, PluginLibrary.isValidID(id),
                   FileManager.default.fileExists(atPath: URL(fileURLWithPath: folder).appendingPathComponent(id).appendingPathComponent("plugin.json").path),
                   let name = try? PluginLibrary(dataDirectory: URL(fileURLWithPath: folder).deletingLastPathComponent().path).plugin(id: id, validate: false).name,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.title = name
                }
                return record
            }
        let legacy = try modelContext.fetch(FetchDescriptor<BoardTask>())
            .filter { $0.authoredPluginID != nil && $0.repositoryWorktrees.isEmpty }
            .map { BoardTaskRecord(task: $0) }
        return sessions + legacy
    }

    func withPluginOperationLock<T>(_ id: String, operation: @MainActor () async throws -> T) async throws -> T {
        guard PluginLibrary.isValidID(id) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Invalid plugin ID.")
        }
        guard let directory = taskOperationLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the plugin operation lock directory.")
        }
        return try await withExclusiveFileLocks(at: [directory.appendingPathComponent("plugin-\(id).lock")], purpose: "plugin-operation") {
            try await operation()
        }
    }

    /// Preserve the transcript and provider sessions of editors created as board cards.
    func migrateLegacyPluginConversation(_ id: UUID) async throws -> BoardTaskRecord {
        try await withConversationTurnReservation(id) {
            try await self.withTaskOperationLock(id) {
                if let existing = try self.standaloneChatModel(id) { return BoardTaskRecord(task: existing) }
                let task = try self.requireTask(id)
                guard task.authoredPluginID != nil, task.repositoryWorktrees.isEmpty else {
                    throw BridgeCommandError(code: "invalid_argument", message: "This task cannot be converted to a plugin editor.")
                }
                let chat = StandaloneChat(provider: task.conversationProvider)
                chat.id = task.id
                chat.title = task.title.hasPrefix("New plugin: ") ? String(task.title.dropFirst("New plugin: ".count)) : task.title
                chat.createdAt = task.createdAt
                chat.authoredPluginID = task.authoredPluginID
                chat.pluginPlacement = task.pluginPlacement
                chat.pluginContextFolder = task.contextFolderPaths.first
                chat.statusRawValue = task.status == .done ? TaskStatus.waitingResponse.rawValue : task.statusRawValue
                chat.lifecycleRevision = task.lifecycleRevision
                chat.statusMessage = task.statusMessage
                chat.progressTypeRawValue = task.progressTypeRawValue
                chat.progressLabel = task.progressLabel
                chat.progressDetail = task.progressDetail
                chat.inProgressStartedAt = task.inProgressStartedAt
                chat.totalInProgressSeconds = task.totalInProgressSeconds
                chat.codexThreadID = task.codexThreadID
                chat.claudeSessionID = task.claudeSessionID
                chat.conversationEffortRawValue = task.conversationEffortRawValue
                chat.conversationModelIDsData = task.conversationModelIDsData
                chat.savedPrompt = task.savedPrompt
                chat.pendingSubmittedPrompt = task.pendingSubmittedPrompt
                chat.hasUnsentDraft = task.hasUnsentDraft
                chat.draftImageDataURLsData = task.draftImageDataURLsData
                chat.pendingAnnotationsData = task.pendingAnnotationsData
                chat.sideChatsData = task.sideChatsData
                chat.conversationActivityDurationsData = task.conversationActivityDurationsData
                chat.answeredAsyncQuestionIDsData = task.answeredAsyncQuestionIDsData
                chat.totalInputTokens = task.totalInputTokens
                chat.totalOutputTokens = task.totalOutputTokens
                chat.totalCacheReadTokens = task.totalCacheReadTokens
                chat.totalCacheCreationTokens = task.totalCacheCreationTokens
                chat.callUsageSnapshotsData = task.callUsageSnapshotsData
                self.modelContext.insert(chat)
                self.modelContext.delete(task)
                try self.modelContext.save()
                return BoardTaskRecord(task: chat)
            }
        }
    }

    /// Serialize filesystem mutations with every active or starting editor turn.
    func withPluginEditorsReserved<T>(id: String, operation: () async throws -> T) async throws -> T {
        let ids = try pluginConversations().filter { $0.authoredPluginID == id }.map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        func reserve(_ index: Int) async throws -> T {
            if index == ids.count { return try await operation() }
            return try await withConversationTurnReservation(ids[index]) {
                try await self.withTaskOperationLock(ids[index]) {
                    try await reserve(index + 1)
                }
            }
        }
        return try await reserve(0)
    }

    /// Lock every editor turn while deleting its plugin, then remove its conversation records.
    /// If deleting the folder fails, the saved conversations remain available for retry.
    func deletePlugin(id: String, library: PluginLibrary) async throws {
        _ = try library.plugin(id: id, validate: false)
        let ids = try pluginConversations().filter { $0.authoredPluginID == id }.map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        func reserve(_ index: Int) async throws {
            if index < ids.count {
                try await withConversationTurnReservation(ids[index]) {
                    try await self.withTaskOperationLock(ids[index]) {
                        try await reserve(index + 1)
                    }
                }
                return
            }
            try library.delete(id: id)
            for id in ids {
                if let chat = try standaloneChatModel(id) { modelContext.delete(chat) }
                else if let task = try? taskModel(id) { modelContext.delete(task) }
            }
            if !ids.isEmpty { try modelContext.save() }
        }
        try await reserve(0)
    }
}
