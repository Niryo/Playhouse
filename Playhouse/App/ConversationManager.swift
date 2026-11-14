import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    /// Sends `message` to a side chat. Without `sideChatID` it opens one: the task's
    /// provider forks its conversation, read-only, and the first message carries the
    /// selected text, which `source` places in the transcript. The task, its status and its
    /// own conversation are left untouched; only the side chat is saved on it.
    /// `modelID` and `effort` choose this message's model; without them a new side chat uses
    /// the task's and a later message keeps the side chat's previous choice.
    func sideChat(
        taskID: UUID,
        sideChatID: String?,
        selectedText: String?,
        source: ConversationTextSource? = nil,
        message: String,
        modelID requestedModelID: String? = nil,
        effort requestedEffort: ConversationEffort? = nil,
        onDelta: @escaping (String) -> Void = { _ in }
    ) async throws -> SideChatReply {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Type a message for the side chat.")
        }
        if let requestedModelID, !Self.isValidModelID(requestedModelID) {
            throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, digits, dots, underscores, and hyphens.")
        }
        let id: String
        var prompt = message
        if let sideChatID {
            if SideChatSessions.sessions[sideChatID] == nil {
                try resumeSavedSideChat(taskID: taskID, sideChatID: sideChatID)
            }
            guard let existing = SideChatSessions.sessions[sideChatID], existing.taskID == taskID else {
                throw BridgeCommandError(code: "not_found", message: "This side chat has ended. Select the text again to start a new one.")
            }
            guard !existing.isResponding else {
                throw BridgeCommandError(code: "invalid_transition", message: "The side chat is still answering.")
            }
            // Busy from here, before anything is awaited, so a second message can't start a turn too.
            SideChatSessions.sessions[sideChatID]?.isResponding = true
            id = sideChatID
        } else {
            let selection = (selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selection.isEmpty else {
                throw BridgeCommandError(code: "invalid_argument", message: "Select text in the conversation to start a side chat.")
            }
            if let source, source.messageID.isEmpty || source.startOffset < 0 || source.endOffset < 0
                || (source.endBlockID == source.blockID && source.endOffset <= source.startOffset) {
                throw BridgeCommandError(code: "invalid_argument", message: "The side chat's source must name a message and a non-empty range of its text.")
            }
            let task = try tasks.conversationSubject(taskID)
            guard let sourceThreadID = task.activeConversationID else {
                throw BridgeCommandError(code: "invalid_transition", message: "This task has no conversation to discuss yet.")
            }
            let provider = task.conversationProvider
            let client = clients.client(for: provider)
            let workspace = try sideChatWorkspace(for: task)
            let modelID = try requestedModelID ?? modelID(taskID: taskID) ?? provider.defaultModelID
            let effort = try requestedEffort ?? effort(taskID: taskID)
            try await client.validateEffort(effort, modelID: modelID, workspace: workspace)
            let threadID = try await client.forkThread(
                sourceThreadID: sourceThreadID, workspace: workspace, modelID: modelID,
                developerInstructions: TaskThreadDeveloperInstructions.sideChat(taskID: taskID)
            )
            id = UUID().uuidString.lowercased()
            SideChatSessions.sessions[id] = SideChatSessions.Session(
                taskID: taskID,
                saved: SavedSideChat(
                    id: id, provider: provider, threadID: threadID, modelID: modelID, effort: effort,
                    selectedText: selection, source: source, messages: [], createdAt: .now
                ),
                workspace: workspace, isResponding: true
            )
            PlayhouseDiagnostics.record("conversation.side_chat.opened", fields: [
                "taskID": taskID.uuidString, "sideChatID": id, "provider": provider.rawValue,
                "sourceThreadID": sourceThreadID, "threadID": threadID
            ])
            prompt = "<selected-text>\n\(selection)\n</selected-text>\n\n\(message)"
        }
        defer { SideChatSessions.sessions[id]?.isResponding = false }
        if let current = SideChatSessions.sessions[id], sideChatID != nil, requestedModelID != nil || requestedEffort != nil {
            // A follow-up's new choice is checked before it is kept for later messages.
            try await clients.client(for: current.saved.provider).validateEffort(
                requestedEffort ?? current.saved.effort, modelID: requestedModelID ?? current.saved.modelID, workspace: current.workspace
            )
        }
        // The live entry, which closing the bubble removes meanwhile; never a copy written back.
        if let requestedModelID { SideChatSessions.sessions[id]?.saved.modelID = requestedModelID }
        if let requestedEffort { SideChatSessions.sessions[id]?.saved.effort = requestedEffort }
        guard let session = SideChatSessions.sessions[id] else {
            throw BridgeCommandError(code: "not_found", message: "This side chat has ended. Select the text again to start a new one.")
        }
        let client = clients.client(for: session.saved.provider)
        let threadID = session.saved.threadID
        var answers: [String] = []
        try await client.sendMessage(
            prompt, imageDataURLs: [], mode: .code, modelID: session.saved.modelID, effort: session.saved.effort,
            threadID: threadID, workspace: session.workspace, sessionRecoveryContext: nil,
            developerInstructions: TaskThreadDeveloperInstructions.sideChat(taskID: taskID),
            onDelta: onDelta,
            onFinalMessage: { text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { answers.append(text) }
            },
            onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in }, onActionRequest: {},
            onUserInput: { request in
                // The bubble has no question form; the agent asks in its answer instead.
                client.rejectUserInput(
                    requestID: request.id, threadID: threadID,
                    message: "The side chat can't show questions. Ask the user in your answer instead."
                )
            },
            onSteerMessage: { _, _ in }, onProgressMessage: { _ in }, onMessageTimestamp: { _, _ in }, onTurnStarted: { _ in },
            onTokenUsage: { _ in },
            sensitiveUserInputAnswerValues: [], hideSensitiveRecoveryPrompt: false
        )
        let reply = answers.joined(separator: "\n\n")
        let saved = try await tasks.appendSideChatExchange(taskID, session.saved, exchange: [
            SavedSideChat.Message(isUser: true, text: message), SavedSideChat.Message(isUser: false, text: reply)
        ])
        SideChatSessions.sessions[id]?.saved = saved
        return SideChatReply(sideChatID: id, taskID: taskID, provider: saved.provider, reply: reply, sideChat: saved)
    }

    /// Ends a side chat's live session. Its saved exchanges stay on the task, and its next
    /// message continues the same provider conversation.
    func closeSideChat(taskID: UUID, sideChatID: String) -> Bool {
        guard let session = SideChatSessions.sessions[sideChatID], session.taskID == taskID else { return false }
        SideChatSessions.sessions.removeValue(forKey: sideChatID)
        return true
    }

    /// The side chats saved on the task, oldest first.
    func savedSideChats(taskID: UUID) throws -> [SavedSideChat] {
        try tasks.sideChats(taskID)
    }

    /// Starts a live session again for a side chat saved on the task, in the read-only
    /// workspace its turns run in. An unknown id leaves no session.
    func resumeSavedSideChat(taskID: UUID, sideChatID: String) throws {
        guard let saved = try tasks.sideChats(taskID).first(where: { $0.id == sideChatID }) else { return }
        let workspace = try sideChatWorkspace(for: try tasks.conversationSubject(taskID))
        SideChatSessions.sessions[sideChatID] = SideChatSessions.Session(taskID: taskID, saved: saved, workspace: workspace)
        PlayhouseDiagnostics.record("conversation.side_chat.resumed", fields: [
            "taskID": taskID.uuidString, "sideChatID": sideChatID, "provider": saved.provider.rawValue, "threadID": saved.threadID
        ])
    }

    func sideChatWorkspace(for task: any ConversationSubject) throws -> ConversationWorkspaceContext {
        let roots = Self.launchRoots(task).compactMap { WorkspaceSettings.validDirectoryURL(for: $0) }
        var workspace = try launchWorkspace(for: task, roots: roots)
        workspace.isReadOnly = true
        return workspace
    }
}
@MainActor
final class ConversationManager {
    var lastReportedTurnOutcomeByTaskID: [UUID: String] = [:]
    let tasks: BoardTaskManager
    let clients: ConversationClients
    let settingsManager: WorkspaceSettingsManager
    let preferences: UserDefaults
    var dispatchingQueuedMessages = false
    static var dispatchingQueuedTaskIDs = Set<UUID>()
    /// Bumped whenever a turn changes what a task's conversation shows (its
    /// transcript or its queue), including while the turn is still running.
    /// The turn's own stream reaches only the caller that started it; any
    /// other window follows these instead.
    static var visibleRevisions: [UUID: Int] = [:]
    static func bumpVisibleRevision(_ taskID: UUID) { visibleRevisions[taskID, default: 0] += 1 }
    /// Turn updates whose content history can already return. Text deltas are
    /// left out: they arrive many times a second, each bump makes a following
    /// window reload history, and the completed message bumps anyway.
    static let historyVisibleUpdateTypes: Set<String> = [
        "queue_changed", "steered_message", "assistant_progress", "assistant_final", "activity", "diff",
        // A background page decision lands after its turn ended and moves the turn to a page.
        "chat_page_updated",
    ]
    static var pendingQueuedTaskDispatchIDs = Set<UUID>()
    var activeSendTaskIDs = Set<UUID>()
    // ConversationManager is lightweight and some entry points construct one per send.
    // Keep resolver coordination shared so a later request can see the pending task.
    static var standalonePageFallbackTasks: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    func shouldDrainMissedSteerImmediately(taskID: UUID) -> Bool {
        guard !activeSendTaskIDs.contains(taskID) else { return false }
        return (try? tasks.hasConversationTurnReservation(taskID)) != true
    }

    init(tasks: BoardTaskManager, clients: ConversationClients, settingsManager: WorkspaceSettingsManager? = nil, preferences: UserDefaults = WorkspaceSettings.preferencesStore) {
        self.tasks = tasks
        self.clients = clients
        self.settingsManager = settingsManager ?? WorkspaceSettingsManager()
        self.preferences = preferences
        if let directory = try? tasks.conversationSteerMailboxDirectory() {
            ConversationSteerMailbox.configure(directory: directory)
        }
    }

    var transcripts: ConversationTranscriptStore {
        get throws { try tasks.conversationTranscriptStore() }
    }


    func client(for task: any ConversationSubject) -> ConversationProviderClient {
        clients.client(for: task.conversationProvider)
    }

    /// The workspace a provider launch for `task` runs in, carrying the skill,
    /// rule and MCP bridges so the provider sees the whole gallery, every rule and
    /// every MCP server that is on. Every path that can start
    /// or load the task's own provider session (send, history, goals) uses this:
    /// Codex keeps a loaded thread's skill config, so the first load decides it.
    func launchWorkspace(for task: any ConversationSubject, roots: [URL], message: String = "") throws -> ConversationWorkspaceContext {
        var workspace = try ConversationWorkspaceContext(roots: roots)
        if let skills = clients.skills {
            let bridge = skills.bridge(for: task, message: message)
            workspace.skillBridge = bridge
        }
        if let rules = clients.rules {
            workspace.ruleBridge = rules.bridge(roots: SkillRoot.roots(for: task))
        }
        if let mcp = clients.mcp {
            workspace.mcpBridge = mcp.bridge(roots: SkillRoot.roots(for: task))
        }
        if task.conversationProvider == .claude, !task.isStandaloneChat {
            workspace.claudeAutoCompactWindowTokens = settingsManager.contextCompaction.autoCompactWindowTokens
        }
        return workspace
    }

    /// The roots a turn runs in. Moving a task to Done removes its managed worktrees, so a
    /// follow-up turn on a Done task runs in each removed worktree's source repository.
    static func launchRoots(_ task: any ConversationSubject) -> [String] {
        guard task.status == .done else { return task.workspaceRootPaths }
        let sources = Dictionary(
            task.repositoryWorktrees.map { ($0.worktreePath, $0.repositoryPath) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        return task.workspaceRootPaths.compactMap { root in
            let path = FileManager.default.fileExists(atPath: root) ? root : (sources[root] ?? root)
            return seen.insert(path).inserted ? path : nil
        }
    }

    static func historyRoots(_ task: any ConversationSubject) -> [String] {
        // Moving a task to Done removes its managed worktrees, so a finished task
        // reads its history from the repositories once any worktree folder is gone.
        let worktreesGone = task.workspaceRootPaths.contains { !FileManager.default.fileExists(atPath: $0) }
        return (task.workspaceRootPaths.isEmpty || worktreesGone) && task.status == .done
            ? task.repositoryWorktrees.map { $0.repositoryPath }
            : task.workspaceRootPaths
    }

    /// The task's conversation, oldest first. With `messageLimit`, returns only
    /// the newest `messageLimit` messages (before `beforeMessageID`, when given)
    /// and reports how many earlier messages remain, so a reader can page
    /// backward. Image data is read only for the messages returned, and only
    /// when `includesImageData` asks for it; internal readers never need it.

    /// Answers a live provider request when its process still owns the control
    /// request. After a restart, replays the answer as a new provider turn using
    /// the durable question saved in the task transcript.
    func answerUserInput(
        taskID: UUID,
        request: ConversationUserInputRequest,
        answers: [String: [String]],
        modelID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> Bool {
        let task = try tasks.conversationSubject(taskID)
        guard request.threadID == task.activeConversationID else {
            throw BridgeCommandError(code: "invalid_transition", message: "That question no longer belongs to this conversation.")
        }
        let transcript = try transcripts.readState(taskID)
        guard transcript.pendingUserInputRequest == request else {
            throw BridgeCommandError(code: "not_found", message: "That pending question is no longer available.")
        }
        let questionsByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
        let valid = Set(answers.keys) == Set(questionsByID.keys) && answers.allSatisfy { id, values in
            guard !values.isEmpty, let question = questionsByID[id] else { return false }
            return values.allSatisfy { value in
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.isEmpty && (question.allowsOther || question.options.isEmpty || question.options.contains { $0.label == value })
            }
        }
        guard valid else {
            throw BridgeCommandError(code: "invalid_argument", message: "Supply a non-empty answer for every question.")
        }

        let client = client(for: task)
        if client.answerUserInput(requestID: request.id, threadID: request.threadID, answers: answers) {
            try clearPendingUserInputRequest(taskID: taskID, requestID: request.id)
            if request.isBlocking {
                let resumed = try await tasks.resumeWaitingResponseAfterUserInput(taskID)
                onUpdate(ConversationUpdate(type: "task_status", taskStatus: resumed.status))
            }
            return true
        }

        guard !(try tasks.hasConversationTurnReservation(taskID)) else {
            throw BridgeCommandError(code: "invalid_transition", message: "This question is still active in another Playhouse process. Answer it there or reopen after that process ends.")
        }
        let answerLines = request.questions.map { question in
            let answer = (answers[question.id] ?? []).joined(separator: ", ")
            return "Question: \(question.question)\nAnswer: \(answer)"
        }
        let sensitiveValues = request.questions
            .filter(\.isSecret)
            .flatMap { answers[$0.id] ?? [] }
            .map { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        let requiresSensitiveAnswerRedaction = request.questions.contains(where: \.isSecret)
        let sensitiveCodexTurnIDsBeforeRecovery = Set(try transcripts.readState(taskID).sensitiveCodexTurnIDs ?? [])
        try transcripts.mutate(taskID, turns: .none) { transcript in
            transcript.pendingSensitiveUserInputRedaction = true
        }
        let secretNote = request.questions.contains(where: \.isSecret)
            ? "The user re-entered the requested secret answer(s) after restart. Apply them now; do not ask for them again."
            : ""
        let recoveryPrompt = """
        Continue this conversation by applying the user's answer to the pending question from the prior Playhouse session. The prior provider process ended, so this answer arrives as a new turn.

        \(secretNote)

        \(answerLines.joined(separator: "\n\n"))
        """
        // The answered question stays saved for redaction and retry, but history
        // hides it while this send applies it. The request is cleared before the
        // reservation is released, so a reader never sees it come back on success.
        _ = try await send(
            taskID: taskID,
            text: recoveryPrompt,
            mode: request.mode,
            modelID: modelID,
            onUpdate: onUpdate,
            sensitiveUserInputAnswerValues: sensitiveValues,
            requiresSensitiveAnswerRedaction: requiresSensitiveAnswerRedaction,
            hideSensitiveRecoveryPrompt: true,
            applyingUserInputRequestID: request.id,
            onUserInputApplied: { [self] in
                if requiresSensitiveAnswerRedaction {
                    try transcripts.mutate(taskID, turns: .none) { transcript in
                        let recoveryTurnIDs = Set(transcript.sensitiveCodexTurnIDs ?? []).subtracting(sensitiveCodexTurnIDsBeforeRecovery)
                        var storedMessages = transcript.sensitiveCodexTurnMessages ?? [:]
                        for turnID in recoveryTurnIDs {
                            storedMessages[turnID] = storedMessages[turnID]?.map { message in
                                guard message.role == .assistant else { return message }
                                var hidden = message
                                hidden.text = "[Response to private answer hidden]"
                                hidden.asyncQuestions = nil
                                return hidden
                            }
                        }
                        transcript.sensitiveCodexTurnMessages = storedMessages
                    }
                }
                try clearPendingUserInputRequest(taskID: taskID, requestID: request.id)
            }
        )
        return true
    }

    func answerUserInput(
        taskID: UUID,
        requestID: String,
        answers: [String: [String]],
        modelID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> Bool {
        guard let request = try transcripts.readState(taskID).pendingUserInputRequest,
              request.id == requestID else {
            throw BridgeCommandError(code: "not_found", message: "That pending question is no longer available.")
        }
        return try await answerUserInput(
            taskID: taskID, request: request, answers: answers, modelID: modelID, onUpdate: onUpdate
        )
    }

    /// Repairs the historical shared-callback bug without answering the question
    /// or resuming its provider. The native thread identity determines ownership.
    func repairPendingUserInput(taskID: UUID, sourceTaskID: UUID) async throws -> ConversationUserInputRequest {
        let task = try tasks.conversationSubject(taskID)
        let source = try tasks.conversationSubject(sourceTaskID)
        guard taskID != sourceTaskID, task.status != .done,
              let threadID = task.activeConversationID,
              source.activeConversationID != threadID else {
            throw BridgeCommandError(code: "invalid_transition", message: "Choose the question's original conversation and a different source task.")
        }
        let request = try transcripts.reassignPendingUserInput(from: sourceTaskID, to: taskID, threadID: threadID)
        if request.isBlocking, task.status == .inProgress {
            _ = try await tasks.transitionLifecycleStatus(taskID, from: .inProgress, to: .waitingResponse)
        }
        PlayhouseDiagnostics.record("conversation.user_input.repaired", fields: [
            "taskID": taskID.uuidString, "sourceTaskID": sourceTaskID.uuidString,
            "threadID": threadID, "requestID": request.id
        ])
        return request
    }

    func persistPendingUserInputRequest(_ request: ConversationUserInputRequest, taskID: UUID) throws {
        guard try tasks.conversationSubject(taskID).activeConversationID == request.threadID else {
            throw BridgeCommandError(code: "invalid_transition", message: "The question belongs to another conversation.")
        }
        try transcripts.mutate(taskID, turns: .none) { transcript in
            transcript.pendingUserInputRequest = request
        }
    }

    func clearPendingUserInputRequest(taskID: UUID, requestID: String) throws {
        try transcripts.mutate(taskID, turns: .none) { transcript in
            guard transcript.pendingUserInputRequest?.id == requestID else { return }
            transcript.pendingUserInputRequest = nil
        }
    }

    /// Hides a saved question while the recovery turn holding the task's turn
    /// reservation applies its answer. Without the reservation that recovery
    /// ended or crashed, so the question is shown again for retry.
    func visiblePendingUserInputRequest(taskID: UUID, transcript: ConversationTranscript) -> ConversationUserInputRequest? {
        guard let request = transcript.pendingUserInputRequest else { return nil }
        guard transcript.applyingUserInputRequestID == request.id,
              (try? tasks.hasConversationTurnReservation(taskID)) == true else { return request }
        return nil
    }

    /// Publishes an image produced by an agent as a durable assistant message.
    /// This is Playhouse-owned presentation state, so both provider runtimes use
    /// the same transcript path.
    func publishImage(taskID: UUID, path: String, caption: String = "") async throws -> ConversationMessage {
        let task = try tasks.conversationSubject(taskID)
        let provider = task.conversationProvider
        let codexClient = clients.codex
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard data.count <= 10_000_000 else {
            throw BridgeCommandError(code: "invalid_argument", message: "The image must be smaller than 10 MB.")
        }
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        default: throw BridgeCommandError(code: "invalid_argument", message: "Use a PNG or JPEG image.")
        }
        let image = "data:\(mime);base64,\(data.base64EncodedString())"
        guard Self.isValidImageDataURL(image) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The file is not a valid PNG or JPEG image.")
        }
        let activeCodexThreadID = provider == .codex ? task.activeConversationID : nil
        let activeCodexTurnID = activeCodexThreadID.flatMap { threadID in
            codexClient.activeTurnID(for: threadID)
                ?? ConversationSteerMailbox.activeTurnID(threadID: threadID)
        }
        let isActiveCodexPublication = activeCodexThreadID != nil && activeCodexTurnID != nil
        // A Codex thread can reject a history read while its turn is writing.
        // An agent publishes its generated image from inside that turn, so use
        // the active turn identity and attach the image to Playhouse's transcript.
        // History composition positions it after that turn's native messages.
        let existingHistory = isActiveCodexPublication ? nil : try await history(taskID: taskID)
        let message = ConversationMessage(
            id: UUID().uuidString.lowercased(), role: .assistant,
            text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
            imageDataURLs: [image], phase: "agent_image", turnID: activeCodexTurnID,
            timelineOrder: existingHistory.flatMap { history in
                provider == .codex
                    ? (history.messages.compactMap(\.timelineOrder).max() ?? history.messages.count - 1) + 1
                    : nil
            },
            provider: provider
        )
        let activeClaudeTurn = provider == .claude
            && task.activeConversationID.map {
                client(for: task).isTurnActive(threadID: $0)
                    || client(for: task).isTurnActiveInProcess(threadID: $0)
                    || ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: $0) != nil
            } == true
        try transcripts.mutate(taskID, turns: .latest) { transcript in
            var segment = transcript.segments.last.flatMap { $0.provider == provider ? $0 : nil }
            if segment == nil {
                let created = ConversationTranscript.Segment(id: UUID().uuidString, provider: provider, startedAt: .now, handoffDelivered: true)
                transcript.segments.append(created)
                segment = created
            }
            guard let segment else { return }
            if provider == .codex, let index = transcript.segments.firstIndex(where: { $0.id == segment.id }) {
                if let activeCodexTurnID, !transcript.segments[index].codexTurnIDs.contains(activeCodexTurnID) {
                    transcript.segments[index].codexTurnIDs.append(activeCodexTurnID)
                }
                let claimed = Set(transcript.segments.flatMap(\.codexTurnIDs))
                let ids = Self.orderedTurnIDs(existingHistory?.messages ?? [])
                transcript.segments[index].codexTurnIDs += ids.filter { !claimed.contains($0) }
            }
            if activeClaudeTurn,
               let index = transcript.turns.indices.last,
               transcript.turns[index].segmentID == segment.id {
                var attributed = message
                attributed.turnID = transcript.turns[index].id
                transcript.turns[index].messages.append(attributed)
            } else {
                transcript.turns.append(.init(id: "agent-image-\(message.id)", segmentID: segment.id, messages: [message]))
            }
        }
        return message
    }




    // MARK: - Goals (Codex only)

    func goal(taskID: UUID, objective: String? = nil, action: String = "get", observeRuntime: Bool = false) async throws -> CodexThreadGoal? {
        var task = try tasks.conversationSubject(taskID)
        guard ["get", "set", "pause", "resume", "clear"].contains(action) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Goal action must be get, set, pause, resume, or clear.")
        }
        guard task.conversationProvider.supportsGoals else {
            guard action == "get" else {
                throw BridgeCommandError(code: "invalid_transition", message: "Goals are available only in Codex conversations. Switch this task to Codex to use a Goal.")
            }
            return nil
        }
        let client = clients.codex
        guard action == "get" || task.status != .done else {
            throw PlayhouseManagerError.invalidTransition("Done tasks are closed. Create a new task to change its goal.")
        }
        if action == "set" {
            guard let objective else { throw PlayhouseManagerError.invalidMessage }
            let value = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 4000 else {
                throw BridgeCommandError(code: "invalid_argument", message: "Goal text must contain 1 to 4,000 characters.")
            }
        }
        if task.codexThreadID == nil {
            guard action == "set" else { return nil }
            let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            // A goal starts its own thread, so it needs the skill bridge a send would add.
            let workspace = try launchWorkspace(for: task, roots: roots)
            let id = try await client.startThread(
                workspace: workspace,
                developerInstructions: TaskThreadDeveloperInstructions.make(
                    taskID: taskID,
                    repositories: task.repositoryWorktrees,
                    contextFolders: task.contextFolderPaths,
                    repositoryRootPath: task.isStandaloneChat ? nil : settingsManager.defaultParentFolderURL?.path,
                    isStandaloneChat: task.isStandaloneChat,
                    isPluginEditor: task.authoringPluginID != nil,
                    pluginPlacement: task.authoringPluginPlacement,
                    pluginID: task.authoringPluginID,
                    pluginName: (task as? StandaloneChat)?.pluginAuthoringName,
                    pluginPresentation: (task as? StandaloneChat)?.pluginAuthoringPresentation,
                    pluginsDirectory: task.authoringPluginID != nil ? task.contextFolderPaths.first : clients.skills?.pluginsDirectory
                )
            )
            _ = try await tasks.persistConversationID(taskID, provider: .codex, id: id)
            task = try tasks.conversationSubject(taskID)
        }
        guard let threadID = task.codexThreadID else { return nil }
        // Any goal call can load the thread, which then needs the skill bridge.
        let workspace = try launchWorkspace(for: task, roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
        switch action {
        case "get": return try await client.getGoal(threadID: threadID, workspace: workspace)
        case "set":
            let normalizedObjective = objective?.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousGoal = try await client.getGoal(threadID: threadID, workspace: workspace)
            if previousGoal == nil, let normalizedObjective,
               ["Untitled task", "Generating title…"].contains(task.title) {
                let reserved: Bool
                if task.title != "Generating title…" {
                    reserved = try await tasks.renameIfTitleMatches(
                        taskID,
                        expectedTitle: task.title,
                        title: "Generating title…"
                    ) != nil
                } else {
                    reserved = true
                }
                if reserved {
                    _ = try await generateAndApplyTitle(
                        taskID: taskID,
                        prompt: normalizedObjective,
                        workspace: workspace,
                        clients: clients.helperClients(preferring: task.conversationProvider)
                    )
                    task = try tasks.conversationSubject(taskID)
                }
            }
            let goal = try await client.setGoal(threadID: threadID, objective: normalizedObjective, status: "active", workspace: workspace, observeRuntime: observeRuntime)
            if let goal, let normalizedObjective {
                CodexGoalGenerationStore.recordSet(taskID: taskID, objective: normalizedObjective, previousGoal: previousGoal, goal: goal, defaults: preferences)
            }
            _ = try await tasks.setLifecycleStatus(taskID, to: .inProgress)
            return goal
        case "pause": return try await client.setGoal(threadID: threadID, status: "paused", workspace: workspace)
        case "resume": return try await client.setGoal(threadID: threadID, status: "active", workspace: workspace)
        case "clear":
            let previousGoal = try await client.getGoal(threadID: threadID, workspace: workspace)
            try await client.clearGoal(threadID: threadID, workspace: workspace)
            CodexGoalGenerationStore.recordClear(taskID: taskID, goal: previousGoal, defaults: preferences)
            return nil
        default: throw BridgeCommandError(code: "invalid_argument", message: "Goal action must be get, set, pause, resume, or clear.")
        }
    }


    // MARK: - Transcript recording

    /// Appends or updates a visible element of the current Claude turn. Writes
    /// are incremental so a crash mid-turn keeps everything already shown, and
    /// touch only this message's row, never the rest of the transcript.

    /// The transcript the UI shows. Page sessions rotate, so a provider that answers history
    /// from its own thread (Codex) would otherwise drop earlier pages from view after a
    /// rotation. The value returned to callers stays provider-truth, because `send` derives
    /// the turn it just ran from the last message.
}
