import Foundation
import SwiftData

/// A window's view of conversation operations. Everything that starts, steers,
/// pauses, answers, or inspects a provider turn runs in the bridge daemon, which
/// is the only process that owns provider state, so a window and the CLI always
/// reach the same turn. The operations that only read or write Playhouse's own
/// store (queued follow-ups, model and effort choices) stay in this process: the
/// store is shared and safe across processes, and the window needs those answers
/// synchronously while it renders.
@MainActor
struct RemoteConversationManager {
    private let daemon: DaemonClient
    private let runtime: ConversationRuntimeModel
    private let store: ConversationManager

    init(daemon: DaemonClient, runtime: ConversationRuntimeModel, modelContext: ModelContext) {
        self.daemon = daemon
        self.runtime = runtime
        // These clients are never started: the store operations below don't use them.
        store = ConversationManager(
            tasks: BoardTaskManager(modelContext: modelContext),
            clients: ConversationClients(codex: CodexAppServerClient(), claude: ClaudeCodeClient())
        )
    }

    private func id(_ taskID: UUID) -> BridgeValue { .string(taskID.uuidString) }

    private func forwardUpdates(_ onUpdate: @escaping (ConversationUpdate) -> Void) -> (BridgeEvent) -> Void {
        { event in
            guard let update = try? event.payload.decoded(ConversationUpdate.self) else { return }
            onUpdate(update)
        }
    }

    // MARK: - Store-only operations

    func modelID(taskID: UUID) throws -> String? { try store.modelID(taskID: taskID) }
    func effort(taskID: UUID) throws -> ConversationEffort { try store.effort(taskID: taskID) }
    func setModelID(taskID: UUID, modelID: String) throws { try store.setModelID(taskID: taskID, modelID: modelID) }
    func cachedModels(taskID: UUID) throws -> [ConversationModelOption] { try store.cachedModels(taskID: taskID) }
    func cachedModels(taskID: UUID, provider: ConversationProvider) throws -> [ConversationModelOption] {
        try store.cachedModels(taskID: taskID, provider: provider)
    }
    func queuedMessages(taskID: UUID) throws -> [QueuedConversationMessage] { try store.queuedMessages(taskID: taskID) }
    func savedUserInputRequest(taskID: UUID) throws -> ConversationUserInputRequest? { try store.savedUserInputRequest(taskID: taskID) }
    func answeredAsyncQuestionIDs(taskID: UUID) throws -> [String] { try store.answeredAsyncQuestionIDs(taskID: taskID) }
    func queueMessage(taskID: UUID, text: String, imageDataURLs: [String] = []) throws -> QueuedConversationMessage {
        try store.queueMessage(taskID: taskID, text: text, imageDataURLs: imageDataURLs)
    }
    func removeQueuedMessage(taskID: UUID, messageID: UUID) throws {
        try store.removeQueuedMessage(taskID: taskID, messageID: messageID)
    }

    // MARK: - Provider operations, owned by the daemon

    /// With `messageLimit`, only the newest messages (before `beforeMessageID`,
    /// when given) cross the bridge, with a count of the earlier ones left.
    func history(
        taskID: UUID,
        messageLimit: Int? = nil,
        beforeMessageID: String? = nil,
        onActionRequest: @escaping () -> Void = {}
    ) async throws -> ConversationHistory {
        var arguments: [String: BridgeValue] = ["taskID": id(taskID)]
        if let messageLimit { arguments["limit"] = .string(String(messageLimit)) }
        if let beforeMessageID { arguments["before"] = .string(beforeMessageID) }
        let result = try await daemon.call("conversation.history", arguments) { event in
            if event.type == "action_request" { onActionRequest() }
        }
        await runtime.refresh()
        return try result.decoded(ConversationHistory.self)
    }

    func send(
        taskID: UUID,
        text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode = .code,
        modelID: String? = nil,
        statusBeforeSubmission: TaskStatus? = nil,
        contextPageIDs: [String] = [],
        onTurnStarting: (() -> Void)? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (ConversationUserInputRequest) -> Void = { _ in }
    ) async throws -> ConversationHistory {
        var arguments: [String: BridgeValue] = [
            "taskID": id(taskID),
            "message": .string(text),
            "mode": .string(mode.rawValue),
            "images": .array(imageDataURLs.map(BridgeValue.string)),
            "reportTurnStarting": .boolean(onTurnStarting != nil),
            // The window keeps its own paged transcript, so the finished turn
            // only needs to bring back the newest page rather than everything.
            "historyLimit": .string(String(TaskConversationView.historyPageSize)),
        ]
        if let modelID { arguments["model"] = .string(modelID) }
        if let statusBeforeSubmission { arguments["statusBeforeSubmission"] = .string(statusBeforeSubmission.rawValue) }
        // Standalone chat only: pages an annotation quotes, carried for this turn.
        if !contextPageIDs.isEmpty { arguments["contextPages"] = .array(contextPageIDs.map(BridgeValue.string)) }
        let forward = forwardUpdates(onUpdate)
        do {
            let result = try await daemon.call("conversation.send", arguments) { event in
                if event.type == "turn_starting" {
                    onTurnStarting?()
                    return
                }
                forward(event)
                if event.type == "user_input",
                   let request = (try? event.payload.decoded(ConversationUpdate.self))?.userInputRequest {
                    onUserInput(request)
                }
            }
            return try result.decoded(ConversationHistory.self)
        } catch {
            await recoverFromFailedTurn(taskID: taskID, error: error)
            throw error
        }
    }

    /// The failure may be a pause, which the window reads from the daemon's state.
    /// If the daemon itself went away mid-turn, nothing is left to finish the turn
    /// or settle its status, so a fresh daemon reconciles the task now instead of
    /// leaving it In Progress with no turn behind it.
    private func recoverFromFailedTurn(taskID: UUID, error: Error) async {
        await runtime.refresh()
        if error is DaemonClientError {
            _ = try? await reconcileLifecycleStatusOnOpen(taskID: taskID)
        }
    }

    func answerUserInput(
        taskID: UUID,
        request: ConversationUserInputRequest,
        answers: [String: [String]],
        modelID: String? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> Bool {
        var arguments: [String: BridgeValue] = [
            "taskID": id(taskID),
            "requestID": .string(request.id),
            "answers": .object(answers.mapValues { .array($0.map(BridgeValue.string)) }),
        ]
        if let modelID { arguments["model"] = .string(modelID) }
        do {
            let result = try await daemon.call("conversation.answer_user_input", arguments, onEvent: forwardUpdates(onUpdate))
            return result.object?["accepted"]?.bool ?? false
        } catch {
            await recoverFromFailedTurn(taskID: taskID, error: error)
            throw error
        }
    }

    func steer(taskID: UUID, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let result = try await daemon.call("conversation.steer", [
            "taskID": id(taskID),
            "message": .string(text),
            "images": .array(imageDataURLs.map(BridgeValue.string)),
            "queueIfMissed": .boolean(false),
        ])
        return result.object?["accepted"]?.bool ?? false
    }

    func queueMissedSteer(taskID: UUID, text: String, imageDataURLs: [String] = []) async throws -> QueuedConversationMessage {
        try await daemon.call("conversation.queue.missed_steer", [
            "taskID": id(taskID),
            "message": .string(text),
            "images": .array(imageDataURLs.map(BridgeValue.string)),
        ]).decoded(QueuedConversationMessage.self)
    }

    func steerQueuedMessage(taskID: UUID, messageID: UUID) async throws -> (message: String, imageDataURLs: [String], accepted: Bool) {
        let result = try await daemon.call("conversation.queue.steer", ["taskID": id(taskID), "messageID": .string(messageID.uuidString)])
        let queued = result.object?["queued"]?.bool ?? false
        return (result.object?["text"]?.string ?? "", result.object?["images"]?.strings ?? [], !queued)
    }

    func retryQueuedMessage(
        taskID: UUID,
        messageID: UUID,
        onUserInput: @escaping (ConversationUserInputRequest) -> Void = { _ in }
    ) async throws -> Bool {
        let result = try await daemon.call("conversation.queue.retry", ["taskID": id(taskID), "messageID": .string(messageID.uuidString)]) { event in
            guard event.type == "user_input",
                  let request = (try? event.payload.decoded(ConversationUpdate.self))?.userInputRequest else { return }
            onUserInput(request)
        }
        return result.object?["retried"]?.bool ?? false
    }

    func answerAsyncQuestion(
        taskID: UUID,
        question: ConversationMessage,
        answers: [String]
    ) async throws -> (text: String, queued: Bool, history: ConversationHistory?) {
        let result = try await daemon.call("conversation.answer_async", [
            "taskID": id(taskID),
            "itemID": .string(question.id),
            "answers": .array(answers.map(BridgeValue.string)),
            "historyLimit": .string(String(TaskConversationView.historyPageSize)),
        ])
        let history = try result.object?["history"].map { try $0.decoded(ConversationHistory.self) }
        return (result.object?["text"]?.string ?? "", result.object?["queued"]?.bool ?? false, history)
    }

    func interrupt(taskID: UUID) async throws -> Bool {
        let result = try await daemon.call("conversation.stop", ["taskID": id(taskID)])
        return result.object?["interrupted"]?.bool ?? false
    }

    func models(taskID: UUID) async throws -> [ConversationModelOption] {
        let result = try await daemon.call("conversation.models", ["taskID": id(taskID)])
        return try result.object?["models"].map { try $0.decoded([ConversationModelOption].self) } ?? []
    }

    func setEffort(taskID: UUID, effort: ConversationEffort) async throws -> BoardTaskRecord {
        try await daemon.call("conversation.effort.set", ["taskID": id(taskID), "effort": .string(effort.rawValue)])
            .decoded(BoardTaskRecord.self)
    }

    func setProvider(taskID: UUID, provider: ConversationProvider) async throws -> BoardTaskRecord {
        try await daemon.call("conversation.provider.set", ["taskID": id(taskID), "provider": .string(provider.rawValue)])
            .decoded(BoardTaskRecord.self)
    }

    // MARK: - Skills, read and managed by the daemon like the CLI's `skills` commands

    func skills(taskID: UUID, includeBundled: Bool) async throws -> SkillCatalog {
        try await daemon.call("skills.list", ["taskID": id(taskID), "includeBundled": .boolean(includeBundled)])
            .decoded(SkillCatalog.self)
    }

    /// The skill's SKILL.md exactly as written, or nil for a skill without a folder.
    func skillContent(taskID: UUID, skillID: String) async throws -> String? {
        let result = try await daemon.call("skills.get", ["taskID": id(taskID), "skillID": .string(skillID)])
        return result.object?["content"]?.string
    }

    func createSkill(
        taskID: UUID, name: String, description: String, body: String, fields: [String: String],
        scope: SkillScope, root: String?
    ) async throws -> SkillRecord {
        var arguments: [String: BridgeValue] = [
            "taskID": id(taskID), "name": .string(name), "description": .string(description),
            "body": .string(body), "scope": .string(scope.rawValue), "fields": .object(fields.mapValues(BridgeValue.string)),
        ]
        if let root { arguments["root"] = .string(root) }
        return try await daemon.call("skills.create", arguments).decoded(SkillRecord.self)
    }

    /// Replaces the whole SKILL.md; the daemon rejects a renamed or description-less file.
    func updateSkillContent(taskID: UUID, skillID: String, content: String) async throws -> SkillRecord {
        try await daemon.call("skills.update", [
            "taskID": id(taskID), "skillID": .string(skillID), "content": .string(content),
        ]).decoded(SkillRecord.self)
    }

    func deleteSkills(taskID: UUID, skillIDs: [String]) async throws {
        _ = try await daemon.call("skills.delete", ["taskID": id(taskID), "skillIDs": .array(skillIDs.map(BridgeValue.string))])
    }

    /// Opens a task whose agent repairs the skills, and returns it with the prompt to send.
    func fixSkills(taskID: UUID, skillIDs: [String]) async throws -> (task: BoardTaskRecord, prompt: String) {
        let result = try await daemon.call("skills.fix", ["taskID": id(taskID), "skillIDs": .array(skillIDs.map(BridgeValue.string))])
        guard let task = result.object?["task"], let prompt = result.object?["prompt"]?.string else {
            throw BridgeCommandError(code: "invalid_response", message: "The bridge did not return the new task.")
        }
        return (try task.decoded(BoardTaskRecord.self), prompt)
    }

    func moveSkill(taskID: UUID, skillID: String, scope: SkillScope, root: String?) async throws -> SkillRecord {
        var arguments: [String: BridgeValue] = ["taskID": id(taskID), "skillID": .string(skillID), "scope": .string(scope.rawValue)]
        if let root { arguments["root"] = .string(root) }
        return try await daemon.call("skills.move", arguments).decoded(SkillRecord.self)
    }

    func setSkillEnabled(taskID: UUID, skillID: String, enabled: Bool) async throws -> SkillRecord {
        try await daemon.call("skills.enable", [
            "taskID": id(taskID), "skillID": .string(skillID), "enabled": .boolean(enabled), "includeBundled": .boolean(true),
        ]).decoded(SkillRecord.self)
    }

    func linkSkill(taskID: UUID, skillID: String, linked: Bool) async throws -> SkillRecord {
        try await daemon.call(linked ? "skills.link" : "skills.unlink", ["taskID": id(taskID), "skillID": .string(skillID)])
            .decoded(SkillRecord.self)
    }

    func rules(taskID: UUID) async throws -> RuleCatalog {
        try await daemon.call("rules.list", ["taskID": id(taskID)]).decoded(RuleCatalog.self)
    }

    func ruleContent(taskID: UUID, ruleID: String) async throws -> String {
        let result = try await daemon.call("rules.get", ["taskID": id(taskID), "ruleID": .string(ruleID)])
        guard let content = result.object?["content"]?.string else {
            throw BridgeCommandError(code: "invalid_response", message: "The bridge did not return the rule's text.")
        }
        return content
    }

    /// A nil name writes the shared AGENTS.md; a name writes a topic file in `.claude/rules`.
    func createRule(taskID: UUID, name: String?, paths: [String], body: String, scope: RuleScope, root: String?) async throws -> RuleRecord {
        var arguments: [String: BridgeValue] = [
            "taskID": id(taskID), "scope": .string(scope.rawValue), "body": .string(body),
            "paths": .array(paths.map(BridgeValue.string)),
        ]
        if let name { arguments["name"] = .string(name) }
        if let root { arguments["root"] = .string(root) }
        return try await daemon.call("rules.create", arguments).decoded(RuleRecord.self)
    }

    func updateRuleContent(taskID: UUID, ruleID: String, content: String) async throws -> RuleRecord {
        try await daemon.call("rules.update", [
            "taskID": id(taskID), "ruleID": .string(ruleID), "content": .string(content),
        ]).decoded(RuleRecord.self)
    }

    func deleteRules(taskID: UUID, ruleIDs: [String]) async throws {
        _ = try await daemon.call("rules.delete", ["taskID": id(taskID), "ruleIDs": .array(ruleIDs.map(BridgeValue.string))])
    }

    func setRuleEnabled(taskID: UUID, ruleID: String, enabled: Bool) async throws -> RuleRecord {
        try await daemon.call("rules.enable", [
            "taskID": id(taskID), "ruleID": .string(ruleID), "enabled": .boolean(enabled),
        ]).decoded(RuleRecord.self)
    }

    func linkRule(taskID: UUID, ruleID: String, linked: Bool) async throws -> RuleRecord {
        try await daemon.call(linked ? "rules.link" : "rules.unlink", ["taskID": id(taskID), "ruleID": .string(ruleID)])
            .decoded(RuleRecord.self)
    }

    /// Opens a task whose agent repairs the rules, and returns it with the prompt to send.
    func fixRules(taskID: UUID, ruleIDs: [String]) async throws -> (task: BoardTaskRecord, prompt: String) {
        let result = try await daemon.call("rules.fix", ["taskID": id(taskID), "ruleIDs": .array(ruleIDs.map(BridgeValue.string))])
        guard let task = result.object?["task"], let prompt = result.object?["prompt"]?.string else {
            throw BridgeCommandError(code: "invalid_response", message: "The bridge did not return the new task.")
        }
        return (try task.decoded(BoardTaskRecord.self), prompt)
    }

    func providerCapabilities(taskID: UUID) async throws -> [ConversationProviderCapabilities] {
        try await daemon.call("conversation.provider.capabilities", ["taskID": id(taskID)])
            .decoded([ConversationProviderCapabilities].self)
    }

    func goal(taskID: UUID, objective: String? = nil, action: String = "get", observeRuntime: Bool = false) async throws -> CodexThreadGoal? {
        var arguments: [String: BridgeValue] = ["taskID": id(taskID), "action": .string(action), "observe": .boolean(observeRuntime)]
        if let objective { arguments["objective"] = .string(objective) }
        let result = try await daemon.call("conversation.goal", arguments)
        if case .null = result { return nil }
        return try result.decoded(CodexThreadGoal.self)
    }

    func subagentHistory(taskID: UUID, activity: ConversationActivity) async throws -> ConversationHistory {
        try await daemon.call("conversation.subagent_history", [
            "taskID": id(taskID),
            "activity": try .encoding(activity),
        ]).decoded(ConversationHistory.self)
    }

    func generateTitle(taskID: UUID, prompt: String) async -> (title: String, provider: ConversationProvider)? {
        guard let result = try? await daemon.call("task.title.generate", ["taskID": id(taskID), "prompt": .string(prompt)]),
              let title = result.object?["title"]?.string,
              let providerName = result.object?["provider"]?.string,
              let provider = ConversationProvider(rawValue: providerName) else { return nil }
        return (title, provider)
    }

    func reconcileLifecycleStatusOnOpen(taskID: UUID) async throws -> BoardTaskRecord {
        try await daemon.call("task.reconcile", ["taskID": id(taskID)]).decoded(BoardTaskRecord.self)
    }

    func createPullRequests(taskID: UUID) async throws -> BoardTaskRecord {
        try await daemon.call("task.pr.create", ["taskID": id(taskID)]).decoded(BoardTaskRecord.self)
    }

    func setPullRequestMode(taskID: UUID, mode: PullRequestMode) async throws -> BoardTaskRecord {
        try await daemon.call("task.pr.mode", ["taskID": id(taskID), "mode": .string(mode.rawValue)]).decoded(BoardTaskRecord.self)
    }

    /// Runs one autopilot pass in the daemon. `onStatus` gets the probed states
    /// before any fix turn starts; the call itself returns after that turn ends.
    func runPullRequestAutopilot(
        taskID: UUID,
        onStatus: @escaping ([PullRequestReviewState]) -> Void = { _ in }
    ) async throws -> PullRequestAutopilotOutcome {
        try await daemon.call("task.pr.autopilot", ["taskID": id(taskID)]) { event in
            guard event.type == "autopilot_status",
                  let states = try? event.payload.decoded([PullRequestReviewState].self) else { return }
            onStatus(states)
        }.decoded(PullRequestAutopilotOutcome.self)
    }

    /// Review syncs pull request changes and may open PRs, which needs the
    /// daemon's provider clients, so this move runs there rather than in-process.
    func moveTaskToReview(taskID: UUID) async throws -> BoardTaskRecord {
        try await daemon.call("task.move", ["taskID": id(taskID), "status": .string(TaskStatus.review.rawValue)]).decoded(BoardTaskRecord.self)
    }

    func syncPullRequestChanges(taskID: UUID) async throws -> PullRequestSyncOutcome {
        try await daemon.call("task.pr.sync", ["taskID": id(taskID)]).decoded(PullRequestSyncOutcome.self)
    }

    func deleteTask(taskID: UUID) async throws {
        try await daemon.call("task.delete", ["taskID": id(taskID)])
    }

    /// Starts one run of a schedule now. The turn runs in the daemon.
    func runScheduleNow(taskID: UUID) async throws -> ScheduledRunOutcome {
        try await daemon.call("schedule.run-now", ["taskID": id(taskID)]).decoded(ScheduledRunOutcome.self)
    }

    func searchArchive(query: String) async throws -> [BoardTaskRecord] {
        try await daemon.call("archive.search", ["query": .string(query)]).decoded([BoardTaskRecord].self)
    }
}
