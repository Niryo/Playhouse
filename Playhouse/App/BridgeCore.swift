import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

/// Marker line Playhouse puts at the top of the status nudges it sends itself.
/// The conversation shows these turns like any other, but renders the prompt as
/// an automatic Playhouse message (`PlayhouseSentMessage`) rather than the user's.
enum PrivateOutcomeNudgeMarker {
    static let current = "Playhouse internal outcome nudge:"
    /// Threads and transcripts written before the nudge rename.
    static let legacy = "Playhouse internal outcome reminder:"

    static func matches(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains(current) || text.localizedCaseInsensitiveContains(legacy)
    }
}

/// The stopping outcome a provider reports when its turn is about to end. Playhouse owns
/// the mapping from an outcome to the board status, so both providers reach the same
/// lifecycle through the same shared CLI vocabulary. There is no outcome for "still
/// working": a task stays In Progress for as long as its provider is executing, which
/// Playhouse reads from the provider's runtime events, never from a report.
enum TurnOutcome: String, CaseIterable {
    /// All requested work is finished; nothing is waiting on the user. A standalone chat's
    /// close-turn writes this too, only as its turn's settlement marker: a chat's outcome never
    /// decides a status (`settleFinishedTurn`).
    case completed
    /// Work cannot continue until the user answers or decides.
    case waitingResponse = "waiting-response"
    /// Work cannot continue and no answer from the user would unblock it; the report
    /// carries the concrete reason.
    case blocked

    static var commandChoices: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }

    /// The outcome older instructions used for "the turn is ending but work remains". It is
    /// still accepted from threads started under those instructions, but it is not a stopping
    /// outcome: it only withdraws an outcome staged earlier in the turn.
    static let legacyInProgress = "in-progress"

    static let legacyInProgressGuidance = "in-progress is no longer a turn outcome and was not recorded. "
        + "Keep working in this turn until the work is completed, needs the user (waiting-response), "
        + "or is blocked (blocked --reason \"<why>\"); await required commands instead of ending the turn."

    /// How long a blocked reason may be; it is shown on the task card.
    static let maxBlockedReasonLength = 500

    /// What a turn's outcome store holds: the outcome on the first line, a blocked
    /// outcome's reason after it.
    static func storedReport(_ outcome: TurnOutcome, reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return outcome.rawValue }
        return outcome.rawValue + "\n" + reason
    }

    static func parseStoredReport(_ stored: String?) -> (outcome: TurnOutcome, reason: String?)? {
        guard let stored else { return nil }
        let parts = stored.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let outcome = TurnOutcome(rawValue: String(first)) else { return nil }
        let reason = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (outcome, reason.isEmpty ? nil : reason)
    }
}

enum CodexGoalGenerationStore {
    static func generationIDKey(taskID: UUID) -> String {
        "playhouse.codex.goal-generation.\(taskID.uuidString)"
    }

    static func objectiveKey(taskID: UUID) -> String {
        "playhouse.codex.goal-generation-objective.\(taskID.uuidString)"
    }

    static func timeBaselineKey(taskID: UUID) -> String {
        "playhouse.codex.goal-generation-time-baseline.\(taskID.uuidString)"
    }

    static func clearedTimeCarryoverKey(taskID: UUID) -> String {
        "playhouse.codex.goal-cleared-time-carryover.\(taskID.uuidString)"
    }

    static func recordClear(taskID: UUID, goal: CodexThreadGoal?, defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        guard let goal else { return }
        defaults.set(Double(goal.timeUsedSeconds ?? 0), forKey: clearedTimeCarryoverKey(taskID: taskID))
    }

    static func recordSet(taskID: UUID, objective: String, previousGoal: CodexThreadGoal?, goal: CodexThreadGoal, defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        let startsNewGeneration = previousGoal == nil
            || previousGoal?.status == "complete"
            || previousGoal?.objective != objective
        guard startsNewGeneration else { return }
        let previousTimeTotal: Double?
        if let previousGoal {
            previousTimeTotal = Double(previousGoal.timeUsedSeconds ?? 0)
        } else {
            previousTimeTotal = defaults.object(forKey: clearedTimeCarryoverKey(taskID: taskID)) as? Double
        }
        let reportedSeconds = Double(goal.timeUsedSeconds ?? 0)
        let timeBaseline = previousTimeTotal.map { reportedSeconds >= $0 ? $0 : 0 } ?? 0
        defaults.set(UUID().uuidString, forKey: generationIDKey(taskID: taskID))
        defaults.set(goal.objective, forKey: objectiveKey(taskID: taskID))
        defaults.set(timeBaseline, forKey: timeBaselineKey(taskID: taskID))
        defaults.removeObject(forKey: clearedTimeCarryoverKey(taskID: taskID))
    }
}

/// Preference keys that hold one task's or chat's state, each ending in its UUID.
/// They belong to that conversation, so they're removed once it no longer exists.
/// A new per-conversation key must be listed in `all` to be removed.
enum TaskPreferenceKeys {
    static func responseStartedAt(taskID: UUID) -> String {
        "playhouse.codex.response-started-at.\(taskID.uuidString)"
    }

    static func completedResponseDuration(taskID: UUID) -> String {
        "playhouse.codex.completed-response-duration.\(taskID.uuidString)"
    }

    static func goalAchievementTimeline(taskID: UUID) -> String {
        "playhouse.codex.goal-achievement-timeline.\(taskID.uuidString)"
    }

    static func conversationMode(taskID: UUID) -> String {
        "conversationMode.\(taskID.uuidString)"
    }

    private static let all: [(UUID) -> String] = [
        responseStartedAt, completedResponseDuration, goalAchievementTimeline, conversationMode,
        CodexGoalGenerationStore.generationIDKey, CodexGoalGenerationStore.objectiveKey,
        CodexGoalGenerationStore.timeBaselineKey, CodexGoalGenerationStore.clearedTimeCarryoverKey,
    ]

    /// Removes every per-conversation key whose task or chat isn't in `liveIDs`,
    /// including keys left by tasks deleted before this cleanup existed.
    static func removeOrphans(keeping liveIDs: Set<UUID>, defaults: UserDefaults) {
        let uuidLength = UUID().uuidString.count
        let prefixes = Set(all.map { String($0(UUID()).dropLast(uuidLength)) })
        for key in defaults.dictionaryRepresentation().keys where key.count > uuidLength {
            guard prefixes.contains(String(key.dropLast(uuidLength))),
                  let id = UUID(uuidString: String(key.suffix(uuidLength))),
                  !liveIDs.contains(id) else { continue }
            defaults.removeObject(forKey: key)
        }
    }
}

/// Generates a short task title with a one-shot helper turn. Clients are tried
/// in order, moving to the next only when a provider is unavailable (not
/// installed, can't start, or not signed in), so a working provider's empty
/// answer still falls back to the prompt rather than to another model.
@MainActor
struct ConversationTitleGenerator {
    let clients: [ConversationProviderClient]

    func generateTitle(from prompt: String, workspace: ConversationWorkspaceContext, taskID: UUID) async -> (title: String, provider: ConversationProvider)? {
        for client in clients {
            switch await attempt(client, prompt: prompt, workspace: workspace, taskID: taskID) {
            case .generated(let title): return (title, client.provider)
            case .unavailable: continue
            case .failed: return nil
            }
        }
        return nil
    }

    private enum Attempt {
        case generated(String)
        case unavailable
        case failed
    }

    private func attempt(_ client: ConversationProviderClient, prompt: String, workspace: ConversationWorkspaceContext, taskID: UUID) async -> Attempt {
        var phase = "thread-start"
        var threadID = ""
        do {
            threadID = try await client.startThread(workspace: workspace, modelID: client.provider.titleModelID, developerInstructions: nil)
            PlayhouseDiagnostics.record("task.title_generation.started", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "modelID": client.provider.titleModelID,
                "provider": client.provider.rawValue
            ])
            var generated: String?
            phase = "title-turn"
            try await client.sendMessage(
                "Write a concise task title of at most 8 words for this request. Return only the title:\n\n\(prompt)",
                mode: .plan,
                modelID: client.provider.titleModelID,
                threadID: threadID,
                workspace: workspace,
                onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
            guard let title = generated?.components(separatedBy: .newlines).first,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                PlayhouseDiagnostics.record("task.title_generation.failed", fields: [
                    "taskID": taskID.uuidString,
                    "threadID": threadID,
                    "phase": phase,
                    "provider": client.provider.rawValue,
                    "reason": "empty_response"
                ])
                return .failed
            }
            PlayhouseDiagnostics.record("task.title_generation.succeeded", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "phase": phase,
                "provider": client.provider.rawValue,
                "titleWordCount": String(title.split(whereSeparator: \.isWhitespace).count)
            ])
            return .generated(title)
        } catch {
            let unavailable = client.isProviderUnavailable(error)
            var fields = PlayhouseDiagnostics.errorFields(error, redacting: [prompt])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["phase"] = phase
            fields["provider"] = client.provider.rawValue
            fields["providerUnavailable"] = String(unavailable)
            PlayhouseDiagnostics.record("task.title_generation.failed", fields: fields)
            return unavailable ? .unavailable : .failed
        }
    }
}

/// A side chat saved on its task, so closing its bubble keeps it: the selected text it
/// discusses, where that text is, its exchanges, and the provider conversation it continues.
struct SavedSideChat: Codable, Equatable, Identifiable {
    struct Message: Codable, Equatable {
        let isUser: Bool
        let text: String
    }

    let id: String
    let provider: ConversationProvider
    let threadID: String
    var modelID: String
    var effort: ConversationEffort
    let selectedText: String
    /// Nil for a side chat opened on text alone, which no transcript range highlights.
    let source: ConversationTextSource?
    var messages: [Message]
    let createdAt: Date
}

/// Encoding rules for the side chats saved with a task.
enum SavedSideChats {
    static func encode(_ sideChats: [SavedSideChat]) -> Data? {
        sideChats.isEmpty ? nil : try? JSONEncoder().encode(sideChats)
    }

    /// Missing or unreadable data is an empty list, so tasks stored before the field existed load.
    static func decode(_ data: Data?) -> [SavedSideChat] {
        guard let data, let decoded = try? JSONDecoder().decode([SavedSideChat].self, from: data) else { return [] }
        return decoded
    }
}

/// One answer of a side chat, and the side chat it belongs to, as saved with the answer.
struct SideChatReply: Codable, Equatable {
    let sideChatID: String
    let taskID: UUID
    let provider: ConversationProvider
    let reply: String
    let sideChat: SavedSideChat
}

/// The side chats the daemon is running. A side chat is a read-only provider conversation
/// forked from a task's own conversation, where the user discusses text they selected in it.
/// Each answered exchange is saved on the task (`SavedSideChat`), so a side chat whose bubble
/// closed, or whose daemon restarted, continues its provider conversation on its next message.
@MainActor
enum SideChatSessions {
    struct Session {
        let taskID: UUID
        /// The side chat as saved, whose model and effort are its latest message's; each
        /// message may choose its own.
        var saved: SavedSideChat
        let workspace: ConversationWorkspaceContext
        var isResponding = false
    }

    static var sessions: [String: Session] = [:]
}


/// Repairs a standalone-chat page signal that the active agent omitted. The
/// helper uses only the providers' inexpensive models (Haiku or Luna at low
/// effort) and returns a machine-readable decision rather than parsing prose.
@MainActor
struct StandaloneChatPageFallbackClassifier {
    struct Decision: Decodable {
        let continues: Bool
        let title: String?
    }

    let clients: [ConversationProviderClient]

    func classify(
        currentQuestion: String,
        precedingMessages: [StandaloneChatMessage],
        workspace: ConversationWorkspaceContext
    ) async -> (decision: Decision, provider: ConversationProvider)? {
        let excerpt = precedingMessages.suffix(8).map { message in
            let body = String(message.text.suffix(1_200))
            return "\(message.role.uppercased()): \(body)"
        }.joined(separator: "\n\n")
        let hasEarlierUserMessage = precedingMessages.contains { $0.role == ConversationRole.user.rawValue }
        let boundedQuestion = String(currentQuestion.suffix(4_000))
        let prompt = """
        Classify the latest user message for Playhouse's continuous chat page index.
        Decide whether it continues the topic of the earlier messages in the current page.
        If it starts a distinct topic, provide a concise title of at most 8 words.
        If this page has no earlier user message, classify it as a new page and title it.
        Return only one JSON object with exactly these fields: {"continues": true|false, "title": string|null}.
        For continues=true, title must be null. For continues=false, title must be a non-empty string.

        Earlier messages on this page:
        \(excerpt.isEmpty ? "(none)" : excerpt)

        Latest user message:
        \(boundedQuestion)
        """

        for client in clients {
            for attempt in 1...2 {
                let modelID = client.provider.titleModelID
                var phase = "thread-start"
                do {
                    let threadID = try await client.startThread(
                        workspace: workspace,
                        modelID: modelID,
                        developerInstructions: "Return the requested JSON only. Do not call tools or include prose."
                    )
                    var responseText: String?
                    phase = "classification-turn"
                    try await client.sendMessage(
                        prompt,
                        mode: .plan,
                        modelID: modelID,
                        effort: .low,
                        threadID: threadID,
                        workspace: workspace,
                        onFinalMessage: { responseText = $0 }
                    )
                    guard let responseText, let decision = Self.decode(responseText),
                          Self.isValid(decision, hasEarlierUserMessage: hasEarlierUserMessage) else {
                        PlayhouseDiagnostics.record("chat.page.fallback.invalid_response", fields: [
                            "provider": client.provider.rawValue,
                            "modelID": modelID,
                            "attempt": String(attempt)
                        ])
                        if attempt == 2 { return nil }
                        continue
                    }
                    PlayhouseDiagnostics.record("chat.page.fallback.succeeded", fields: [
                        "provider": client.provider.rawValue,
                        "modelID": modelID,
                        "continues": String(decision.continues),
                        "attempt": String(attempt)
                    ])
                    return (decision, client.provider)
                } catch {
                    let unavailable = client.isProviderUnavailable(error)
                    PlayhouseDiagnostics.record("chat.page.fallback.failed", fields: [
                        "provider": client.provider.rawValue,
                        "modelID": modelID,
                        "phase": phase,
                        "attempt": String(attempt),
                        "providerUnavailable": String(unavailable)
                    ])
                    if unavailable { break }
                }
            }
        }
        return nil
    }

    private static func isValid(_ decision: Decision, hasEarlierUserMessage: Bool) -> Bool {
        let title = decision.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if decision.continues {
            return hasEarlierUserMessage && decision.title == nil
        }
        return !title.isEmpty
    }

    private static func decode(_ text: String) -> Decision? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["continues", "title"]),
              object["title"] is NSNull || object["title"] is String else { return nil }
        return try? JSONDecoder().decode(Decision.self, from: data)
    }
}

enum PlayhouseTaskTitleDiagnostics {
    static func state(of title: String) -> String {
        switch title {
        case "Untitled task": "untitled"
        case "Generating title…": "generating"
        default: "custom"
        }
    }
}


struct StoreLifecycleLockError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct StoreSchemaRepairError: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct BridgeFileLockError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum RepositoryAllocationLock {
    static func fileName(for repositoryPath: String) -> String {
        let canonicalPath = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in canonicalPath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(format: "%016llx.lock", hash)
    }
}

@MainActor
enum TaskOperationLockGate {
    private static var heldKeys: Set<String> = []
    private static var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func acquire(_ key: String) async {
        guard !heldKeys.contains(key) else {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
            return
        }
        heldKeys.insert(key)
    }

    static func isHeld(_ key: String) -> Bool {
        heldKeys.contains(key)
    }

    static func release(_ key: String) {
        guard var pending = waiters[key], !pending.isEmpty else {
            heldKeys.remove(key)
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        next.resume()
    }
}

struct BoardTaskRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    let status: String
    let statusMessage: String?
    let progressType: String?
    let progressLabel: String?
    let progressDetail: String?
    let createdAt: Date
    let codexThreadID: String?
    let claudeSessionID: String?
    let conversationProvider: String
    let conversationEffort: String
    let savedPrompt: String?
    let pendingSubmittedPrompt: String?
    let hasUnsentDraft: Bool
    /// Unsent review comments saved with the draft.
    let pendingCommentCount: Int
    let workspaceRoots: [String]
    let repositoryWorktrees: [RepositoryWorktreeRecord]
    /// Records retired by `task repository renew`; their merged PRs stay on the card.
    let pastRepositoryWorktrees: [RepositoryWorktreeRecord]
    let contextFolders: [String]
    let draftImageDataURLs: [String]?
    let autoCreatePullRequestOnReview: Bool
    let pullRequestMode: String
    /// Present for a scheduled task (one-time or a recurring template).
    let schedule: TaskScheduleRecord?
    /// The recurring schedule that started this task, if any.
    let scheduleSourceTaskID: UUID?
    /// The plugin placement an Add Plugin mode task builds for, if any.
    let pluginPlacement: String?
    let authoredPluginID: String?
    /// The name and presentation a plugin editor was set up with; the empty conversation shows them.
    let pluginAuthoringName: String?
    let pluginAuthoringPresentation: String?

    /// Accepts any conversation owner: a board task, or the standalone chat, which reports
    /// empty workspace roots and worktrees because it has none.
    init(task: any ConversationSubject, includeDraftImages: Bool = true) {
        let boardTask = task as? BoardTask
        schedule = boardTask.flatMap(TaskScheduleRecord.init(task:))
        scheduleSourceTaskID = boardTask?.scheduleSourceTaskID
        pluginPlacement = boardTask?.pluginPlacement ?? (task as? StandaloneChat)?.pluginPlacement
        authoredPluginID = boardTask?.authoredPluginID ?? (task as? StandaloneChat)?.authoredPluginID
        pluginAuthoringName = (task as? StandaloneChat)?.pluginAuthoringName
        pluginAuthoringPresentation = (task as? StandaloneChat)?.pluginAuthoringPresentation
        id = task.id
        title = task.title
        status = task.status.rawValue
        statusMessage = task.statusMessage
        progressType = task.progressTypeRawValue
        progressLabel = task.progressLabel
        progressDetail = task.progressDetail
        createdAt = task.createdAt
        codexThreadID = task.codexThreadID
        claudeSessionID = task.claudeSessionID
        conversationProvider = task.conversationProvider.rawValue
        conversationEffort = task.conversationEffort
        savedPrompt = task.savedPrompt
        pendingSubmittedPrompt = task.pendingSubmittedPrompt
        hasUnsentDraft = task.hasUnsentDraft
        pendingCommentCount = PersistedAnnotations.decode(task.pendingAnnotationsData).count
        workspaceRoots = task.workspaceRootPaths
        repositoryWorktrees = task.repositoryWorktrees
        pastRepositoryWorktrees = boardTask?.pastRepositoryWorktrees ?? []
        contextFolders = task.contextFolderPaths
        draftImageDataURLs = includeDraftImages ? task.draftImageDataURLs : nil
        autoCreatePullRequestOnReview = task.autoCreatePullRequestOnReview
        pullRequestMode = task.pullRequestMode.rawValue
    }
}

extension BridgeValue {
    /// A plugin's value as a bridge argument, through the JSON both encode.
    init(plugin value: PluginValue) {
        self = (try? JSONDecoder().decode(BridgeValue.self, from: JSONEncoder().encode(value))) ?? .null
    }
}

extension PluginValue {
    /// A bridge result as a plugin's value, through the JSON both encode.
    init(bridge value: BridgeValue) {
        self = (try? JSONDecoder().decode(PluginValue.self, from: JSONEncoder().encode(value))) ?? .null
    }
}

extension PluginTaskContext {
    /// The details a conversation placement hands its plugins.
    init(task: any ConversationSubject) {
        self.init(
            id: task.id.uuidString, title: task.title, status: task.status.rawValue,
            provider: task.conversationProvider.rawValue, isStandaloneChat: task.isStandaloneChat,
            repositories: task.repositoryWorktrees.map {
                .init(repositoryPath: $0.repositoryPath, worktreePath: $0.worktreePath, branch: $0.branch)
            },
            contextFolders: task.contextFolderPaths
        )
    }
}

struct TaskScheduleRecord: Codable, Equatable {
    let kind: String
    let scheduledAt: Date?
    let recurrence: TaskRecurrence?
    let summary: String
    let prompt: String?
    let imageCount: Int
    let mode: String?
    let model: String?
    let paused: Bool
    let lastRunAt: Date?
    let lastRunTaskID: UUID?

    init?(task: BoardTask) {
        guard let kind = task.scheduleKind else { return nil }
        self.kind = kind.rawValue
        scheduledAt = task.scheduledAt
        recurrence = task.scheduleRecurrence
        summary = kind == .recurring ? (task.scheduleRecurrence?.summary() ?? "") : "Once"
        prompt = task.scheduledPrompt
        imageCount = task.scheduledImageDataURLs.count
        mode = task.scheduledModeRawValue
        model = task.scheduledModelID
        paused = task.schedulePaused
        lastRunAt = task.lastScheduledRunAt
        lastRunTaskID = task.lastScheduledRunTaskID
    }
}

struct QueuedConversationMessage: Codable, Equatable, Identifiable {
    enum State: String, Codable { case queued, dispatching, needsAction }
    let id: UUID
    let taskID: UUID
    let threadID: String
    let text: String
    var imageDataURLs: [String]? = []
    var state: State
    var enqueuedProcessID: Int32? = nil
    var dispatchingProcessID: Int32? = nil
    var asyncQuestionItemID: String? = nil
}



struct DeferredRepositoryRemoval: Codable {
    var taskID: UUID
    var record: RepositoryWorktreeRecord
}


struct ConversationUpdate: Codable {
    let type: String
    var text: String?
    var itemID: String?
    var phase: String?
    var asyncQuestions: [ConversationAsyncQuestion]?
    var activity: ConversationActivity?
    var diff: String?
    var history: ConversationHistory?
    var message: String?
    var imageDataURLs: [String]?
    var userInputRequest: ConversationUserInputRequest?
    var taskStatus: String?
}

/// The live updates of every turn a task runs, for callers that didn't start it: a window
/// watching a CLI send, a scheduled turn, or a turn this daemon reattached after a restart.
/// A turn's own sender still gets its updates directly; this is a copy of the same stream.
@MainActor
enum ConversationTurnEvents {
    private static var activeTurns: [UUID: Int] = [:]
    private static var watchers: [UUID: [UUID: AsyncStream<ConversationUpdate>.Continuation]] = [:]

    static func isActive(_ taskID: UUID) -> Bool { activeTurns[taskID, default: 0] > 0 }

    /// Turns can nest (a reminder continuation inside a send), so watchers stay until the
    /// outermost one ends.
    static func begin(_ taskID: UUID) { activeTurns[taskID, default: 0] += 1 }

    static func end(_ taskID: UUID) {
        let remaining = activeTurns[taskID, default: 0] - 1
        guard remaining <= 0 else {
            activeTurns[taskID] = remaining
            return
        }
        activeTurns.removeValue(forKey: taskID)
        for continuation in (watchers.removeValue(forKey: taskID) ?? [:]).values { continuation.finish() }
    }

    static func publish(_ taskID: UUID, _ update: ConversationUpdate) {
        for continuation in watchers[taskID, default: [:]].values { continuation.yield(update) }
    }

    /// The task's updates until its turns end, or nil when no turn is running.
    static func watch(_ taskID: UUID) -> AsyncStream<ConversationUpdate>? {
        guard isActive(taskID) else { return nil }
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ConversationUpdate.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { _ in
            Task { @MainActor in _ = ConversationTurnEvents.watchers[taskID]?.removeValue(forKey: id) }
        }
        watchers[taskID, default: [:]][id] = continuation
        return stream
    }
}

/// A one-time answer an async caller waits for; the first `set` wins.
@MainActor
final class AsyncFlag {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func set(_ value: Bool) {
        guard result == nil else { return }
        result = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters.removeAll()
    }

    var value: Bool {
        get async {
            if let result { return result }
            return await withCheckedContinuation { waiters.append($0) }
        }
    }
}


struct BridgeCommandError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}



extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension BridgeRequest {
    func requiredString(_ name: String) throws -> String {
        guard let value = arguments[name]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: \(name).")
        }
        return value
    }

    func requiredInt(_ name: String) throws -> Int {
        guard let value = arguments[name]?.int else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing or non-numeric required argument: \(name).")
        }
        return value
    }

    func requiredStrings(_ name: String) throws -> [String] {
        guard let value = arguments[name]?.strings else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required list argument: \(name).")
        }
        return value
    }

    func requiredStringArrays(_ name: String) throws -> [String: [String]] {
        guard let object = arguments[name]?.object else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required answer map: \(name).")
        }
        var result: [String: [String]] = [:]
        for (key, value) in object {
            guard case .array(let values) = value else {
                throw BridgeCommandError(code: "invalid_argument", message: "Answers for \(key) must be a list of strings.")
            }
            let strings = values.compactMap(\.string)
            guard strings.count == values.count else {
                throw BridgeCommandError(code: "invalid_argument", message: "Answers for \(key) must be a list of strings.")
            }
            result[key] = strings
        }
        return result
    }

    func optionalStringArrays(_ name: String) throws -> [String: [String]] {
        guard arguments[name] != nil else { return [:] }
        return try requiredStringArrays(name)
    }

    func repositorySpecs(_ name: String) throws -> [RepositoryWorktreeSpec] {
        guard case .array(let values)? = arguments[name] else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing repository list argument: \(name).")
        }
        return try values.map { value in
            guard let object = value.object, let path = object["repositoryPath"]?.string else {
                throw BridgeCommandError(code: "invalid_argument", message: "Each repository must include a repositoryPath.")
            }
            return RepositoryWorktreeSpec(
                repositoryPath: path,
                branch: object["branch"]?.string,
                branchFrom: object["branchFrom"]?.string,
                mergeTarget: object["mergeTarget"]?.string
            )
        }
    }

    /// A positive message count for a paged history read, when one was given.
    func optionalHistoryLimit(_ name: String = "historyLimit") throws -> Int? {
        guard let raw = arguments[name]?.string else { return nil }
        guard let limit = Int(raw), limit > 0 else {
            throw BridgeCommandError(code: "invalid_argument", message: "The history limit must be a positive number of messages.")
        }
        return limit
    }

    /// A whole-number argument, sent by the CLI as text; out of `range` is a caller error.
    func optionalInteger(_ name: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let raw = arguments[name] else { return nil }
        let value: Int?
        switch raw {
        case .integer(let number): value = number
        case .string(let text): value = Int(text)
        default: value = nil
        }
        guard let value, range.contains(value) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be a whole number from \(range.lowerBound)\(range.upperBound == Int.max ? " up" : " to \(range.upperBound)").")
        }
        return value
    }

    /// One of a fixed set of named choices, `fallback` when the argument is absent.
    func optionalChoice<Choice: RawRepresentable & CaseIterable>(_ name: String, default fallback: Choice) throws -> Choice
    where Choice.RawValue == String {
        guard let raw = arguments[name]?.string else { return fallback }
        guard let choice = Choice(rawValue: raw) else {
            let names = Choice.allCases.map(\.rawValue).joined(separator: ", ")
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be one of: \(names).")
        }
        return choice
    }

    func requiredUUID(_ name: String) throws -> UUID {
        guard let rawValue = arguments[name]?.string, let id = UUID(uuidString: rawValue) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be a task UUID.")
        }
        return id
    }

    /// An ISO 8601 date-time such as `2026-11-09T09:00:00Z`, when one was given.
    func optionalDate(_ name: String) throws -> Date? {
        guard let raw = arguments[name]?.string, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be an ISO 8601 date-time, such as 2026-11-09T09:00:00Z.")
        }
        return date
    }

    /// `schedule.set`'s arguments: `kind` (once/recurring), `at` for once; `repeat`,
    /// `time` (HH:MM), `minute` and `weekday` for recurring; then `title`, `prompt`,
    /// `images`, `mode` and `model`.
    @MainActor func scheduleRequest() throws -> TaskScheduleRequest {
        let kind: TaskScheduleKind = try optionalChoice("kind", default: .once)
        var recurrence: TaskRecurrence?
        if kind == .recurring {
            let preset: TaskRecurrence.Preset = try optionalChoice("repeat", default: .daily)
            var hour = 9
            var minute = 0
            if let time = arguments["time"]?.string {
                let parts = time.split(separator: ":").map { Int($0) }
                guard parts.count == 2, let h = parts[0], let m = parts[1], (0...23).contains(h), (0...59).contains(m) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Argument time must be HH:MM.")
                }
                hour = h
                minute = m
            }
            if let explicitMinute = try optionalInteger("minute", in: 0...59) { minute = explicitMinute }
            var weekday: Int?
            if let raw = arguments["weekday"]?.string?.lowercased() {
                let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
                if let index = names.firstIndex(where: { raw.hasPrefix($0) }) {
                    weekday = index + 1
                } else if let number = Int(raw), (1...7).contains(number) {
                    weekday = number
                } else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Argument weekday must be a day name, such as mon.")
                }
            }
            if preset == .weekly, weekday == nil {
                throw BridgeCommandError(code: "invalid_argument", message: "A weekly schedule needs --weekday.")
            }
            recurrence = TaskRecurrence(preset: preset, hour: hour, minute: minute, weekday: weekday)
        }
        let fireAt = try optionalDate("at")
        if kind == .once, fireAt == nil {
            throw BridgeCommandError(code: "invalid_argument", message: "A one-time schedule needs --at.")
        }
        let mode: ConversationMode = try optionalChoice("mode", default: .code)
        let modelID = arguments["model"]?.string
        if let modelID, !ConversationManager.isValidModelID(modelID) {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument model isn't a valid model ID.")
        }
        return TaskScheduleRequest(
            kind: kind,
            fireAt: fireAt,
            recurrence: recurrence,
            title: arguments["title"]?.string,
            prompt: arguments["prompt"]?.string ?? "",
            imageDataURLs: arguments["images"]?.strings ?? [],
            mode: mode,
            modelID: modelID
        )
    }
}

extension String {
    /// Treats an all-whitespace joined context block as no context at all.
    var nilWhenBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
