import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

@MainActor
final class BoardTaskManager {
    let modelContext: ModelContext
    let worktreeRoot: URL
    let taskOperationLockDirectory: URL?

    func queuedConversationMessages(taskID: UUID) throws -> [QueuedConversationMessage] {
        try mutateQueuedMessages(taskID: taskID) { items in
            for index in items.indices where items[index].state == .dispatching {
                let processID = items[index].dispatchingProcessID
                guard let processID, Darwin.kill(processID, 0) == 0 || errno == EPERM else {
                    items[index].state = .needsAction
                    items[index].dispatchingProcessID = nil
                    items[index].enqueuedProcessID = nil
                    continue
                }
            }
        }
        return try readQueuedMessages()[taskID.uuidString] ?? []
    }

    func enqueueConversationMessage(taskID: UUID, text: String, imageDataURLs: [String] = [], asyncQuestionItemID: String? = nil) throws -> QueuedConversationMessage {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        let task = try conversationSubject(taskID)
        guard let threadID = task.activeConversationID else {
            throw BridgeCommandError(code: "invalid_transition", message: "A follow-up can only be queued after this conversation has a \(task.conversationProvider.displayName) conversation.")
        }
        let item = QueuedConversationMessage(
            id: UUID(), taskID: taskID, threadID: threadID, text: normalized, imageDataURLs: imageDataURLs, state: .queued,
            enqueuedProcessID: nil, asyncQuestionItemID: asyncQuestionItemID
        )
        try mutateQueuedMessages(taskID: taskID) { $0.append(item) }
        return item
    }

    func conversationSteerMailboxDirectory() throws -> URL {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for steering requests.")
        }
        return storeURL.deletingLastPathComponent().appendingPathComponent("conversation-steer-mailbox", isDirectory: true)
    }

    func conversationTranscriptStore() throws -> ConversationTranscriptStore {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for conversation transcripts.")
        }
        return try ConversationTranscriptStore.open(directory: storeURL.deletingLastPathComponent())
    }

    /// Resolves the same isolated data directory as the task store itself (so e2e test
    /// isolation and worktree-specific app data apply here too), rather than needing a raw
    /// dataDirectory string threaded through every call site.
    func standaloneChatManager() throws -> StandaloneChatManager {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for standalone chat.")
        }
        return try StandaloneChatManager(dataDirectory: storeURL.deletingLastPathComponent().path)
    }

    func claimNextQueuedMessage(taskID: UUID, threadID: String, messageID: UUID? = nil) throws -> QueuedConversationMessage? {
        var claimed: QueuedConversationMessage?
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: {
                $0.state == .queued && $0.threadID == threadID && (messageID == nil || $0.id == messageID)
            }) else { return }
            items[index].state = .dispatching
            items[index].dispatchingProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
            claimed = items[index]
        }
        return claimed
    }

    func finishQueuedMessage(_ message: QueuedConversationMessage, succeeded: Bool) throws {
        try mutateQueuedMessages(taskID: message.taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == message.id && $0.state == .dispatching }) else { return }
            if succeeded { items.remove(at: index) }
            else { items[index].state = .needsAction; items[index].dispatchingProcessID = nil }
        }
    }

    func retryQueuedMessage(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .needsAction }) else {
                throw BridgeCommandError(code: "invalid_transition", message: "That queued message is not waiting for an explicit retry.")
            }
            items[index].state = .queued
            items[index].enqueuedProcessID = nil
            items[index].dispatchingProcessID = nil
        }
    }

    func removeQueuedMessage(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID }),
                  items[index].state != .dispatching else {
                throw BridgeCommandError(code: "invalid_transition", message: "That follow-up can no longer be removed.")
            }
            items.remove(at: index)
        }
    }

    func reserveQueuedMessageForSteering(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .queued }) else {
                throw BridgeCommandError(code: "invalid_transition", message: "That follow-up is no longer available to steer.")
            }
            items[index].state = .dispatching
            items[index].dispatchingProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
        }
    }

    func finishQueuedMessageSteering(taskID: UUID, messageID: UUID, accepted: Bool) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .dispatching }) else { return }
            if accepted { items.remove(at: index) }
            else {
                items[index].state = .needsAction
                items[index].dispatchingProcessID = nil
            }
        }
    }

    func requeueMissedSteer(taskID: UUID, messageID: UUID) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            guard let index = items.firstIndex(where: { $0.id == messageID && $0.state == .dispatching }) else { return }
            items[index].state = .queued
            items[index].dispatchingProcessID = nil
        }
    }

    func retainQueuedMessagesForUserAction(taskID: UUID, threadID: String) throws {
        try mutateQueuedMessages(taskID: taskID) { items in
            for index in items.indices where items[index].threadID == threadID && items[index].state == .queued {
                items[index].state = .needsAction
            }
        }
    }

    func readQueuedMessages() throws -> [String: [QueuedConversationMessage]] {
        let url = try queuedMessagesURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: [QueuedConversationMessage]].self, from: Data(contentsOf: url))
    }

    func mutateQueuedMessages(taskID: UUID, _ mutation: (inout [QueuedConversationMessage]) throws -> Void) throws {
        let url = try queuedMessagesURL()
        let lockURL = url.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { _ = Darwin.close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK); lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_SETLKW, &lock) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { lock.l_type = Int16(F_UNLCK); _ = Darwin.fcntl(descriptor, F_SETLK, &lock) }
        var all: [String: [QueuedConversationMessage]] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            all = try JSONDecoder().decode([String: [QueuedConversationMessage]].self, from: Data(contentsOf: url))
        }
        var items = all[taskID.uuidString] ?? []
        try mutation(&items)
        all[taskID.uuidString] = items
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
        guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    func queuedMessagesURL() throws -> URL {
        guard let storeURL = modelContext.container.configurations.first?.url else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't locate the task store for queued messages.")
        }
        return storeURL.deletingLastPathComponent().appendingPathComponent("queued-conversation-messages.json")
    }
    let repositoryAllocationLockDirectory: URL?
    let conversationTurnLockDirectory: URL?
    let worktreeService = PlayhouseWorktreeService()
    let pullRequestService = PlayhousePullRequestService()
    let preferences: UserDefaults

    init(
        modelContext: ModelContext,
        worktreeRoot: URL = PlayhouseWorktreeManager.defaultRoot(),
        preferences: UserDefaults = WorkspaceSettings.preferencesStore
    ) {
        self.modelContext = modelContext
        self.worktreeRoot = worktreeRoot
        self.preferences = preferences
        self.taskOperationLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("task-operation-locks", isDirectory: true)
        self.repositoryAllocationLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("repository-allocation-locks", isDirectory: true)
        self.conversationTurnLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("conversation-turn-locks", isDirectory: true)
    }


    /// Board tasks. Recurring schedule templates are not board tasks, so they're left out;
    /// `scheduledTasks()` lists them.


    /// The user's manual counterpart to a `completed` outcome: a task left in
    /// Waiting Response moves to Review through the same review gate — its
    /// pull request changes are synced first and its PR mode then applies.
    /// A sync failure is reported and leaves the task in Waiting Response.

    /// Opens the pull requests a task's PR mode asks for once it reaches
    /// Review. A failure is recorded rather than thrown: the task stays in
    /// Review and its card keeps the manual create action.
    func playStatusSound(for task: any ConversationSubject, from previous: TaskStatus) {
        guard task is BoardTask, task.status != previous else { return }
        let name: String
        switch task.status {
        case .review: name = "Glass"
        case .waitingResponse: name = "Ping"
        default: return
        }
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        let played = sound?.play() == true
        PlayhouseDiagnostics.record(played ? "task.status_sound.played" : "task.status_sound.failed", fields: [
            "taskID": task.id.uuidString, "status": task.status.rawValue, "sound": name
        ])
        // Each transition owns its sound, so overlapping transitions do not interrupt one another.
        if let sound, played {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                _ = sound
            }
        }
    }


    func reconcileLifecycleStatusOnOpen(_ id: UUID, clients: ConversationClients) async throws -> BoardTaskRecord {
        let currentTask = try requireSubject(id)
        guard currentTask.activeConversationID != nil || currentTask.pendingSubmittedPrompt != nil else {
            return BoardTaskRecord(task: currentTask)
        }
        return try await withTaskOperationLock(id) {
            let task = try requireSubject(id)
            let previousStatus = task.status
            let providerName = task.conversationProvider.displayName
            let client = clients.client(for: task.conversationProvider)
            guard let threadID = task.activeConversationID else {
                if let submittedPrompt = task.pendingSubmittedPrompt, !(try hasConversationTurnReservation(id)) {
                    if task.status == .inProgress {
                        task.status = .waitingResponse
                        task.statusMessage = "Playhouse restarted before \(providerName) started this turn. Your prompt is saved; review it and continue when ready."
                    }
                    returnSubmittedPromptToDraft(task, submittedPrompt: submittedPrompt)
                    try await saveTaskContext(taskID: id)
                    playStatusSound(for: task, from: previousStatus)
                }
                return BoardTaskRecord(task: task)
            }
            let hasActiveReservation = try hasConversationTurnReservation(id)
            guard !client.isTurnActive(threadID: threadID),
                  !client.isTurnActiveInProcess(threadID: threadID),
                  !hasActiveReservation else {
                return BoardTaskRecord(task: task)
            }
            let pendingQuestion = try conversationTranscriptStore().readState(id).pendingUserInputRequest
            if let pendingQuestion, pendingQuestion.threadID == threadID, task.status != .done {
                let pendingStatus: TaskStatus = pendingQuestion.isBlocking ? .waitingResponse : .inProgress
                let pendingStatusMessage = pendingQuestion.isBlocking
                    ? "Waiting for your saved question to be answered."
                    : "A saved question is available for your response."
                if task.status != pendingStatus || task.statusMessage != pendingStatusMessage {
                    task.status = pendingStatus
                    task.statusMessage = pendingStatusMessage
                    clearProgressReport(task)
                    try await saveTaskContext(taskID: id)
                    playStatusSound(for: task, from: previousStatus)
                }
                return BoardTaskRecord(task: task)
            }
            // A turn the user paused is waiting on purpose; it needs no restart notice.
            if task.status == .waitingResponse, client.wasLastTurnInterrupted(threadID: threadID) {
                return BoardTaskRecord(task: task)
            }
            let message: String
            switch task.status {
            case .inProgress:
                message = ConversationManager.interruptedByRestartMessage
            default:
                // Waiting Response without a saved question is a finished turn waiting for the user.
                return BoardTaskRecord(task: task)
            }
            task.status = .waitingResponse
            task.statusMessage = message
            task.pendingSubmittedPrompt = nil
            clearProgressReport(task)
            try await saveTaskContext(taskID: id)
            playStatusSound(for: task, from: previousStatus)
            return BoardTaskRecord(task: task)
        }
    }

    func resetAllTasksForLifecycle() async throws -> [String] {
        let all = try listModels()
        var dirtyManagedWorktrees: [String] = []
        for snapshot in all {
            let dirtyForTask = try await withTaskOperationLock(snapshot.id) { () async throws -> [String] in
                let task: BoardTask
                do {
                    task = try requireTask(snapshot.id)
                } catch let error as PlayhouseManagerError {
                    if case .taskNotFound = error { return [] }
                    throw error
                }
                var dirtyPaths: [String] = []
                for record in task.repositoryWorktrees where record.createdByPlayhouse {
                    guard FileManager.default.fileExists(atPath: record.worktreePath) else { continue }
                    if (try? await worktreeService.hasChanges(record)) != false {
                        dirtyPaths.append(record.worktreePath)
                    } else {
                        try await worktreeService.remove(record)
                    }
                }
                modelContext.delete(task)
                try await saveTaskContext(taskID: snapshot.id)
                return dirtyPaths
            }
            dirtyManagedWorktrees.append(contentsOf: dirtyForTask)
        }
        return dirtyManagedWorktrees
    }




    func delete(_ id: UUID, diagnostics: [String: String] = [:]) async throws {
        try await withConversationTurnReservation(id) {
            try await self.deleteWhileTurnReserved(id, diagnostics: diagnostics)
        }
    }

    func deleteWhileTurnReserved(_ id: UUID, diagnostics: [String: String]) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            try await withRepositoryAllocationLocks(task.repositoryWorktrees.map(\.repositoryPath)) {
                try await deleteTaskWhileLocked(task, diagnostics: diagnostics)
            }
        }
    }

    func deleteTaskWhileLocked(_ task: BoardTask, diagnostics: [String: String]) async throws {
        var phase = "worktree-removal"
        var fields = [
            "taskID": task.id.uuidString,
            "taskStatus": task.status.rawValue,
            "threadID": task.activeConversationID ?? "",
            "provider": task.conversationProvider.rawValue,
            "worktreeCount": String(task.repositoryWorktrees.count),
            "storePath": PlayhouseDiagnostics.storeURL.path
        ]
        fields.merge(diagnostics) { _, new in new }
        PlayhouseDiagnostics.record("task.delete.started", fields: fields)
        do {
            for worktree in task.repositoryWorktrees {
                guard !worktree.isPending else { continue }
                fields["worktreePath"] = worktree.worktreePath
                PlayhouseDiagnostics.record("task.delete.worktree_removal_started", fields: fields)
                try await worktreeService.removeAfterConfirmation(worktree)
                PlayhouseDiagnostics.record("task.delete.worktree_removal_succeeded", fields: fields)
            }
            phase = "swiftdata-save"
            let taskID = task.id
            modelContext.delete(task)
            try await saveTaskContext(taskID: taskID)
            try? conversationTranscriptStore().remove(taskID)
            removeOrphanedTaskPreferences()
            PlayhouseDiagnostics.record("task.delete.succeeded", fields: fields)
        } catch {
            fields["phase"] = phase
            fields.merge(
                PlayhouseDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? "", task.pendingSubmittedPrompt ?? ""])
            ) { _, new in new }
            PlayhouseDiagnostics.record("task.delete.failed", fields: fields)
            throw error
        }
    }

    func taskModel(_ id: UUID) throws -> BoardTask {
        try requireTask(id)
    }

    func removeOrphanedTaskPreferences() {
        do {
            let taskIDs = try modelContext.fetch(FetchDescriptor<BoardTask>()).map(\.id)
            let chatIDs = try modelContext.fetch(FetchDescriptor<StandaloneChat>()).map(\.id)
            TaskPreferenceKeys.removeOrphans(keeping: Set(taskIDs + chatIDs), defaults: preferences)
        } catch {
            PlayhouseDiagnostics.record("task.preferences.cleanup_failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }

    /// Resolves whatever owns the conversation with this ID: a board task or the standalone
    /// chat. The conversation engine runs against this rather than against `BoardTask`, so a
    /// chat never has to exist as a task to hold a conversation.
    func conversationSubject(_ id: UUID) throws -> any ConversationSubject {
        try requireSubject(id)
    }

    func standaloneChatIDs() -> [UUID] {
        (try? modelContext.fetch(FetchDescriptor<StandaloneChat>()).map(\.id)) ?? []
    }

    /// The standalone chat with this ID, or nil when the ID belongs to a board task.
    func standaloneChatModel(_ id: UUID) throws -> StandaloneChat? {
        var descriptor = FetchDescriptor<StandaloneChat>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func setViewedWorkspaceChanges(_ newSnapshots: [WorkspaceViewedChange], taskID: UUID) async throws {
        let task = try requireTask(taskID)
        var snapshots = task.viewedWorkspaceChanges
        for snapshot in newSnapshots {
            snapshots.removeAll { $0.repository == snapshot.repository && $0.path == snapshot.path }
            snapshots.append(snapshot)
        }
        task.viewedWorkspaceChanges = snapshots
        try await saveTaskContext(operation: "BoardTaskManager.setViewedWorkspaceChanges", taskID: taskID)
    }

    func removeViewedWorkspaceChange(repository: String, path: String, taskID: UUID) async throws {
        let task = try requireTask(taskID)
        task.viewedWorkspaceChanges = task.viewedWorkspaceChanges.filter { !($0.repository == repository && $0.path == path) }
        try await saveTaskContext(operation: "BoardTaskManager.removeViewedWorkspaceChange", taskID: taskID)
    }

    func isRepositoryAttached(_ record: RepositoryWorktreeRecord, to taskID: UUID) throws -> Bool {
        do {
            return try requireSubject(taskID).repositoryWorktrees.contains {
                $0.repositoryPath == record.repositoryPath && $0.worktreePath == record.worktreePath
            }
        } catch PlayhouseManagerError.taskNotFound(_) {
            return false
        }
    }

    func prepareRepositoryWorktrees(
        _ id: UUID,
        fallbackPrompt: String? = nil,
        resolvedTitle: String? = nil
    ) async throws -> BoardTask {
        let initialTask = try requireTask(id)
        let initialRecords = initialTask.repositoryWorktrees
        let pending = initialRecords.filter(\.isPending)
        guard !pending.isEmpty else { return initialTask }
        let branchTitle: String
        if let resolvedTitle, !resolvedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            branchTitle = resolvedTitle
        } else if ["Generating title…", "Untitled task"].contains(initialTask.title) {
            // A send names the branch after the prompt it sent; an unsent draft kept beside it
            // describes later work.
            let prompt = fallbackPrompt ?? initialTask.savedPrompt ?? initialTask.title
            branchTitle = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        } else {
            branchTitle = initialTask.title
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.repositoryWorktrees == initialRecords else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while worktrees were being prepared. Try again.")
            }
            return try await withRepositoryAllocationLocks(pending.map(\.repositoryPath)) {
                var resolved: [RepositoryWorktreeRecord] = []
                do {
                    try validateRepositoryAssignments(pending, excludingTaskID: id)
                    for item in pending {
                        let requestedBranch = item.branch == "auto" ? nil : item.branch
                        let record = try await worktreeService.resolve(
                            spec: RepositoryWorktreeSpec(
                                repositoryPath: item.repositoryPath,
                                branch: requestedBranch,
                                branchFrom: item.branchFrom,
                                mergeTarget: item.mergeTarget
                            ),
                            title: branchTitle,
                            root: worktreeRoot,
                            reservedBranches: reservedBranches(repositoryPath: item.repositoryPath, excludingTaskID: id)
                        )
                        resolved.append(record)
                    }
                    let currentTask = try requireTask(id)
                    guard currentTask.repositoryWorktrees == initialRecords else {
                        throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while worktrees were being prepared. Try again.")
                    }
                    try validateRepositoryAssignments(resolved, excludingTaskID: id)
                    var iterator = resolved.makeIterator()
                    currentTask.repositoryWorktrees = currentTask.repositoryWorktrees.map { $0.isPending ? (iterator.next() ?? $0) : $0 }
                    currentTask.workspaceRootPaths = try Self.normalizeOptionalRoots(currentTask.repositoryWorktrees.map(\.worktreePath) + currentTask.contextFolderPaths)
                    try await saveTaskContext(taskID: id)
                    return currentTask
                } catch {
                    for record in resolved where record.createdByPlayhouse {
                        try? await worktreeService.remove(record)
                    }
                    throw error
                }
            }
        }
    }

    func deleteRequiresConfirmation(_ id: UUID) async throws -> Bool {
        let task = try requireTask(id)
        var dirtyWorktree = false
        for record in task.repositoryWorktrees where !record.isPending {
            if try await worktreeService.hasChanges(record) {
                dirtyWorktree = true
                break
            }
        }
        if dirtyWorktree { return true }
        let hasSavedConversation = task.hasConversation
            || !(task.savedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return dirtyWorktree || hasSavedConversation
    }

    /// Resolves whichever creature owns this conversation. Conversation-level manager methods
    /// use this so the standalone chat reaches the same shared logic board tasks do; methods
    /// that genuinely need a workspace use `requireBoardTask` and reject a chat ID by type.
    func requireSubject(_ id: UUID) throws -> any ConversationSubject {
        if let chat = try standaloneChatModel(id) { return chat }
        return try requireTask(id)
    }

    func requireTask(_ id: UUID) throws -> BoardTask {
        var descriptor = FetchDescriptor<BoardTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let readFields = persistenceReadFields(operation: "BoardTaskManager.requireTask", taskID: id)
        let readStartedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("persistence.read.started", fields: readFields)
        do {
            guard let task = try modelContext.fetch(descriptor).first else {
                var fields = readFields
                fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
                PlayhouseDiagnostics.record("persistence.read.missing", fields: fields)
                throw PlayhouseManagerError.taskNotFound(id)
            }
            var fields = readFields
            fields["status"] = task.status.rawValue
            fields["repositoryCount"] = String(task.repositoryWorktrees.count)
            fields["workspaceRootCount"] = String(task.workspaceRootPaths.count)
            fields["hasCodexThread"] = String(task.codexThreadID != nil)
            fields["hasClaudeSession"] = String(task.claudeSessionID != nil)
            fields["hasSavedPrompt"] = String(task.savedPrompt != nil)
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
            PlayhouseDiagnostics.record("persistence.read.succeeded", fields: fields)
            return task
        } catch {
            if !(error is PlayhouseManagerError) {
                var fields = persistenceReadFailureFields(error, context: readFields)
                fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - readStartedAt) / 1_000_000)
                PlayhouseDiagnostics.record("persistence.read.failed", fields: fields)
            }
            throw error
        }
    }

    func persistenceReadFields(operation: String, taskID: UUID? = nil) -> [String: String] {
        let storeURL = modelContext.container.configurations.first?.url
        var fields = [
            "storePathAvailable": String(storeURL != nil)
        ]
        if let storeURL {
            fields["storePath"] = storeURL.standardizedFileURL.path
        }
        fields["readID"] = UUID().uuidString
        fields["operation"] = operation
        fields["entity"] = "BoardTask"
        if let taskID { fields["taskID"] = taskID.uuidString }
        return fields
    }

    func persistenceReadFailureFields(_ error: Error, context: [String: String]) -> [String: String] {
        var fields = PlayhouseDiagnostics.errorFields(error, includeUserInfoDetails: true)
        fields.merge(context) { _, new in new }
        let storeURL = modelContext.container.configurations.first?.url
        fields.merge(PlayhouseDiagnostics.storeContextFields(for: storeURL)) {
            _, new in new
        }
        fields.merge(PlayhouseStore.schemaProbeFields(at: storeURL)) { _, new in new }
        return fields
    }

    /// Branches other active tasks use in a repository, which an auto-named branch avoids.
    func reservedBranches(repositoryPath: String, excludingTaskID: UUID?) -> Set<String> {
        let repository = Self.canonicalPath(repositoryPath)
        var names: Set<String> = []
        for other in (try? listModels()) ?? [] where other.id != excludingTaskID && other.status != .done {
            for record in other.repositoryWorktrees where !record.isPending && Self.canonicalPath(record.repositoryPath) == repository {
                names.insert(record.branch)
            }
        }
        return names
    }

    func validateRepositoryAssignments(
        _ candidates: [RepositoryWorktreeRecord],
        excludingTaskID: UUID?
    ) throws {
        for other in try listModels() where other.id != excludingTaskID && other.status != .done {
            for candidate in candidates {
                let repositoryPath = Self.canonicalPath(candidate.repositoryPath)
                if candidate.branch != "auto",
                   other.repositoryWorktrees.contains(where: {
                       Self.canonicalPath($0.repositoryPath) == repositoryPath && $0.branch == candidate.branch
                   }) {
                    throw PlayhouseManagerError.branchAssigned(branch: candidate.branch, taskTitle: other.title)
                }

                let candidateWorkspacePath = Self.canonicalPath(
                    candidate.isPending ? candidate.repositoryPath : candidate.worktreePath
                )
                if other.repositoryWorktrees.contains(where: {
                    !$0.isPending && Self.canonicalPath($0.worktreePath) == candidateWorkspacePath
                }) {
                    throw PlayhouseManagerError.repositoryAssigned(candidateWorkspacePath)
                }
            }
        }
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func repositoryRecord(_ path: String, in task: BoardTask) throws -> RepositoryWorktreeRecord {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let record = task.repositoryWorktrees.first(where: {
            URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == normalizedPath
        }) else {
            throw BridgeCommandError(code: "not_found", message: "This repository isn't attached to the task: \(normalizedPath)")
        }
        return record
    }

    static func normalizeRoots(_ roots: [String]) throws -> [String] {
        let paths = roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        guard !paths.isEmpty else { throw PlayhouseManagerError.noWorkspaceRoots }
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            guard WorkspaceSettings.validDirectoryURL(for: path) != nil else {
                throw PlayhouseManagerError.unavailableWorkspaceRoot(path)
            }
            unique.append(path)
        }
        return unique
    }

    static func normalizeOptionalRoots(_ roots: [String]) throws -> [String] {
        let paths = roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            guard WorkspaceSettings.validDirectoryURL(for: path) != nil else {
                throw PlayhouseManagerError.unavailableWorkspaceRoot(path)
            }
            unique.append(path)
        }
        return unique
    }

    func listModels() throws -> [BoardTask] {
        let readFields = persistenceReadFields(operation: "BoardTaskManager.listModels")
        let readStartedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("persistence.read.started", fields: readFields)
        do {
            let tasks = try modelContext.fetch(FetchDescriptor<BoardTask>())
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

    func saveTaskContext(operation: String = #function, taskID: UUID? = nil) async throws {
        let storeURL = modelContext.container.configurations.first?.url
        let writeID = UUID().uuidString
        let fields = [
            "writeID": writeID,
            "operation": operation,
            "entity": "BoardTask",
            "taskID": taskID?.uuidString ?? "",
            "storePath": storeURL?.path ?? "",
            "hasChanges": String(modelContext.hasChanges)
        ]
        PlayhouseDiagnostics.record("persistence.write.started", fields: fields)

        let lockWaitStartedAt = DispatchTime.now().uptimeNanoseconds
        var lockWaitMilliseconds = 0
        var lockAcquired = false
        var attemptCount = 0
        var retryCount = 0
        do {
            guard let storeURL else {
                throw BridgeFileLockError(message: "Couldn't determine the task-store location for a write lock.")
            }
            let lockURL = storeURL.deletingLastPathComponent().appendingPathComponent("store-write.lock")
            try await withExclusiveFileLocks(at: [lockURL], purpose: "task-store-write") {
                lockWaitMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - lockWaitStartedAt) / 1_000_000)
                lockAcquired = true
                var lockFields = fields
                lockFields["lockWaitMilliseconds"] = String(lockWaitMilliseconds)
                PlayhouseDiagnostics.record("persistence.write.lock_acquired", fields: lockFields)

                let retryDelays: [UInt64] = [100_000_000, 300_000_000, 600_000_000]
                while true {
                    attemptCount += 1
                    do {
                        try modelContext.save()
                        var successFields = fields
                        successFields["attemptCount"] = String(attemptCount)
                        successFields["retryCount"] = String(retryCount)
                        successFields["lockWaitMilliseconds"] = String(lockWaitMilliseconds)
                        PlayhouseDiagnostics.record("persistence.write.succeeded", fields: successFields)
                        return
                    } catch {
                        guard Self.isStoreOpenFailure(error), retryCount < retryDelays.count else {
                            throw error
                        }
                        let retryDelayMilliseconds = retryDelays[retryCount] / 1_000_000
                        var retryFields = PlayhouseDiagnostics.errorFields(error, includeUserInfoDetails: true)
                        retryFields.merge(fields) { _, new in new }
                        retryFields["attempt"] = String(attemptCount)
                        retryFields["retryCount"] = String(retryCount + 1)
                        retryFields["retryDelayMilliseconds"] = String(retryDelayMilliseconds)
                        retryFields["lockWaitMilliseconds"] = String(lockWaitMilliseconds)
                        PlayhouseDiagnostics.record("persistence.write.retry", fields: retryFields)
                        try await Task.sleep(nanoseconds: retryDelays[retryCount])
                        retryCount += 1
                    }
                }
            }
        } catch {
            var failureFields = PlayhouseDiagnostics.errorFields(error, includeUserInfoDetails: true)
            failureFields.merge(fields) { _, new in new }
            failureFields["attemptCount"] = String(attemptCount)
            failureFields["retryCount"] = String(retryCount)
            failureFields["lockWaitMilliseconds"] = String(lockAcquired
                ? lockWaitMilliseconds
                : Int((DispatchTime.now().uptimeNanoseconds - lockWaitStartedAt) / 1_000_000))
            PlayhouseDiagnostics.record("persistence.write.failed", fields: failureFields)
            throw error
        }
    }

}
