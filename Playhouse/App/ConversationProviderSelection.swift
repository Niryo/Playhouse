import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func modelCacheKey(for provider: ConversationProvider) -> String {
        "conversation.models.cache.\(provider.rawValue)"
    }

    func selectedModelKey(for provider: ConversationProvider) -> String {
        "conversation.model.selected.\(provider.rawValue)"
    }

    func cachedModels(taskID: UUID) throws -> [ConversationModelOption] {
        let task = try tasks.conversationSubject(taskID)
        return try cachedModels(provider: task.conversationProvider)
    }

    func cachedModels(taskID: UUID, provider: ConversationProvider) throws -> [ConversationModelOption] {
        _ = try tasks.conversationSubject(taskID)
        return try cachedModels(provider: provider)
    }

    func cachedModels(provider: ConversationProvider) throws -> [ConversationModelOption] {
        guard let data = preferences.data(forKey: modelCacheKey(for: provider)),
              let models = try? JSONDecoder().decode([ConversationModelOption].self, from: data),
              !models.isEmpty else { return [] }
        return models.newestVersionPerFamily()
    }

    func models(taskID: UUID) async throws -> [ConversationModelOption] {
        PlayhouseDiagnostics.record("conversation.models.read.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.conversationSubject(taskID)
        var selectionToReconcile = task.conversationModelID
        if let selectedModelID = task.conversationModelID,
           let replacement = try cachedModels(provider: task.conversationProvider)
                .supersedingModel(forSelectedID: selectedModelID) {
            let replaced = try await tasks.replaceConversationModelID(
                taskID,
                expectedProvider: task.conversationProvider,
                expectedModelID: selectedModelID,
                replacementModelID: replacement.id
            )
            selectionToReconcile = replaced ? replacement.id : nil
        }
        let workspace = try ConversationWorkspaceContext(roots: task.workspaceRootPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        let models = try await client(for: task).availableModels(workspace: workspace).newestVersionPerFamily()
        if let data = try? JSONEncoder().encode(models) {
            preferences.set(data, forKey: modelCacheKey(for: task.conversationProvider))
        }
        if let selectedModelID = selectionToReconcile,
           let replacement = models.supersedingModel(forSelectedID: selectedModelID) {
            _ = try await tasks.replaceConversationModelID(
                taskID,
                expectedProvider: task.conversationProvider,
                expectedModelID: selectedModelID,
                replacementModelID: replacement.id
            )
        }
        PlayhouseDiagnostics.record("conversation.models.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "provider": task.conversationProvider.rawValue,
            "modelCount": String(models.count),
            "modelIDs": models.map(\.id).joined(separator: ",")
        ])
        return models
    }

    func effort(taskID: UUID) throws -> ConversationEffort {
        ConversationEffort(rawValue: try tasks.conversationSubject(taskID).conversationEffort) ?? .medium
    }

    func modelID(taskID: UUID) throws -> String? {
        let task = try tasks.conversationSubject(taskID)
        let key = selectedModelKey(for: task.conversationProvider)
        if let conversationModelID = task.conversationModelID {
            return supersededSelection(conversationModelID, provider: task.conversationProvider, key: nil)
        }
        if let historicalModelID = latestTranscriptModelID(taskID: taskID, provider: task.conversationProvider) {
            return supersededSelection(historicalModelID, provider: task.conversationProvider, key: nil)
        }
        if let selectedModelID = preferences.string(forKey: key) {
            return supersededSelection(selectedModelID, provider: task.conversationProvider, key: key)
        }
        return nil
    }

    func latestTranscriptModelID(taskID: UUID, provider: ConversationProvider) -> String? {
        // Opening a conversation asks this on the main thread, so it reads the segments and
        // then only as many messages as it takes to find a model, never the whole transcript.
        guard let transcript = try? transcripts.readState(taskID) else { return nil }
        let segmentIDs = Set(transcript.segments.filter { $0.provider == provider }.map(\.id))
        return try? transcripts.latestAssistantModelID(taskID, segmentIDs: segmentIDs)
    }

    /// A remembered model the provider no longer offers keeps running behind the
    /// picker, so a selection superseded within its own family follows the family
    /// forward, keeping sends and the composer on one model.
    ///
    /// This sits on the read rather than on the model refresh so that every consumer
    /// converges at once: the composer primes from cache before `models(taskID:)`
    /// returns, and a send reads the remembered ID without refreshing the list. The
    /// write is idempotent — once the stored ID is one the provider offers, later
    /// reads find nothing to supersede. `key` is nil when the caller persists the
    /// result itself.
    ///
    /// The cache is the only source of truth here, so on the first launch after an
    /// update a send issued before the first `models(taskID:)` fetch lands still uses
    /// the remembered ID. That window closes on the next read and never clobbers a
    /// selection, which is why an empty cache deliberately supersedes nothing.
    func supersededSelection(_ selectedModelID: String, provider: ConversationProvider, key: String?) -> String {
        guard let models = try? cachedModels(provider: provider),
              let replacement = models.supersedingModel(forSelectedID: selectedModelID) else { return selectedModelID }
        if let key { preferences.set(replacement.id, forKey: key) }
        PlayhouseDiagnostics.record("conversation.model.selection.superseded", fields: [
            "provider": provider.rawValue, "from": selectedModelID, "to": replacement.id
        ])
        return replacement.id
    }

    func setEffort(taskID: UUID, effort: ConversationEffort) async throws -> BoardTaskRecord {
        try await tasks.setConversationEffort(taskID, effort: effort)
    }

    func setModelID(taskID: UUID, modelID: String) async throws {
        let task = try tasks.conversationSubject(taskID)
        try await tasks.setConversationModelID(taskID, modelID: modelID)
        preferences.set(modelID, forKey: selectedModelKey(for: task.conversationProvider))
    }
    // MARK: - Providers

    /// Detected native capabilities, so switching can show what differs. Playhouse
    /// starts Codex without apps or hooks and with the MCP servers turned on in
    /// the MCP page; Claude Code uses its own configuration.
    func providerCapabilities(taskID: UUID) async throws -> [ConversationProviderCapabilities] {
        let task = try tasks.conversationSubject(taskID)
        let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
        let codex = ConversationProviderCapabilities(
            provider: .codex,
            isAvailable: clients.codex.isInstalled,
            supportsGoals: true,
            notes: ["Playhouse runs Codex without apps or hooks, with the MCP servers turned on in Skills, Rules & MCP.", "Goals are available."]
        )
        return [codex, await clients.claude.capabilities(workspace: workspace)]
    }

    /// What each provider reports about the MCP servers it would start for the
    /// task, such as one that needs the user to sign in. Claude Code is asked
    /// with the task's own MCP bridge, so it also reports the servers Playhouse
    /// passes it and its claude.ai connectors and plugin servers; Codex reports
    /// the servers in its own configuration.
    /// The workspace a provider is asked about the task's MCP servers in: the
    /// task's folders with its MCP bridge, or an empty one without a task.
    func mcpWorkspace(taskID: UUID?) -> ConversationWorkspaceContext? {
        let task = taskID.flatMap { try? tasks.conversationSubject($0) }
        let roots = task.map { Self.historyRoots($0).map { URL(fileURLWithPath: $0, isDirectory: true) } } ?? []
        guard var workspace = (try? ConversationWorkspaceContext(roots: roots)) ?? (try? ConversationWorkspaceContext(roots: [])) else { return nil }
        if let task, let mcp = clients.mcp { workspace.mcpBridge = mcp.bridge(roots: SkillRoot.roots(for: task)) }
        return workspace
    }

    /// With `provider`, only that provider is asked, so a sign-in that is being
    /// waited on doesn't start the other one.
    func mcpStatus(taskID: UUID?, provider: ConversationProvider? = nil) async -> McpStatusReport {
        var report = McpStatusReport()
        guard let workspace = mcpWorkspace(taskID: taskID) else {
            report.errors = ["claude": "The task's folders are missing.", "codex": "The task's folders are missing."]
            return report
        }
        if provider != .codex {
            let claude = await clients.claude.capabilities(workspace: workspace)
            if claude.isAvailable {
                report.claude = claude.mcpServers.map { McpProviderStatus(name: $0.name, status: $0.status, needsSignIn: $0.status == "needs-auth") }
            } else {
                report.errors["claude"] = claude.error ?? "Claude Code is not installed."
            }
        }
        if provider != .claude {
            if clients.codex.isInstalled {
                do {
                    report.codex = try await clients.codex.mcpServerStatuses(workspace: workspace)
                } catch {
                    report.errors["codex"] = error.localizedDescription
                }
            } else {
                report.errors["codex"] = "Codex is not installed."
            }
        }
        PlayhouseDiagnostics.record("mcp.status.read", fields: [
            "claudeCount": String(report.claude.count), "codexCount": String(report.codex.count),
        ])
        return report
    }

    /// Starts the sign-in of an MCP server in one provider and returns the link
    /// to open in the browser. The provider finishes the sign-in when the browser
    /// redirects back to it; `mcpLoginResult` waits for that.
    func startMcpLogin(taskID: UUID?, provider: ConversationProvider, name: String) async throws -> McpLoginStart {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Name the MCP server to sign in to.")
        }
        guard let workspace = mcpWorkspace(taskID: taskID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The task's folders are missing.")
        }
        let link: String
        switch provider {
        case .claude: link = try await clients.claude.startMcpLogin(name: name, workspace: workspace)
        case .codex:
            guard clients.codex.isInstalled else { throw BridgeCommandError(code: "unavailable", message: "Codex is not installed.") }
            link = try await clients.codex.startMcpLogin(name: name, workspace: workspace)
        }
        return McpLoginStart(provider: provider, name: name, authorizationUrl: link)
    }

    /// Waits for a started sign-in to finish: signed in, failed, or timed out.
    func mcpLoginResult(taskID: UUID?, provider: ConversationProvider, name: String) async -> McpLoginResult {
        switch provider {
        case .claude: return await clients.claude.waitForMcpLogin(name: name)
        case .codex:
            guard let workspace = mcpWorkspace(taskID: taskID) else { return McpLogin.notStarted(provider: .codex, name: name) }
            return await clients.codex.waitForMcpLogin(name: name, workspace: workspace)
        }
    }

    /// Changes the provider that runs the task's next turn. A switch waits for the
    /// current turn, pending questions, queued follow-ups, and background
    /// subagents to settle, and records a boundary in the transcript.
    func setProvider(taskID: UUID, provider: ConversationProvider) async throws -> BoardTaskRecord {
        var task = try tasks.conversationSubject(taskID)
        PlayhouseDiagnostics.record("conversation.provider.switch.started", fields: [
            "taskID": taskID.uuidString, "from": task.conversationProvider.rawValue, "to": provider.rawValue
        ])
        guard task.status != .done else {
            throw PlayhouseManagerError.invalidTransition("Done tasks are closed. Create a new task to use another provider.")
        }
        // The user's explicit choice becomes the default for the next task or
        // chat, so a provider switch doesn't keep reverting to Codex.
        try? settingsManager.setDefaultConversationProvider(provider.rawValue)
        guard task.conversationProvider != provider else { return BoardTaskRecord(task: task) }
        guard task.hasConversation else {
            return try await tasks.setConversationProvider(taskID, provider: provider)
        }
        let history = try await requireSettledConversation(task)
        if history.activities.contains(where: { $0.isSubagent && $0.isActive }) {
            throw Self.switchBlocked("Subagents are still running. Wait for them to finish before switching providers.")
        }
        // Turns follow their segments in order, so the last segment has turns
        // exactly when it owns the latest turn.
        try transcripts.mutate(taskID, turns: .latest) { transcript in
            if transcript.segments.isEmpty {
                transcript.segments.append(.init(id: UUID().uuidString, provider: task.conversationProvider, startedAt: .now, handoffDelivered: true))
            }
            // A segment with no turns can be replaced instead of leaving an empty boundary.
            if let last = transcript.segments.last, transcript.turns(in: last).isEmpty, transcript.segments.count > 1 {
                transcript.segments.removeLast()
            }
            if transcript.segments.last?.provider != provider {
                transcript.segments.append(.init(id: UUID().uuidString, provider: provider, startedAt: .now))
            }
        }
        task = try tasks.conversationSubject(taskID)
        let record = try await tasks.setConversationProvider(taskID, provider: provider)
        PlayhouseDiagnostics.record("conversation.provider.switch.succeeded", fields: [
            "taskID": taskID.uuidString, "provider": provider.rawValue,
            "segmentCount": String((try? transcripts.readState(taskID).segments.count) ?? 0)
        ])
        return record
    }

    /// Returns the visible history once nothing is still running or waiting.
    func requireSettledConversation(_ task: any ConversationSubject) async throws -> ConversationHistory {
        let client = client(for: task)
        if try tasks.hasConversationTurnReservation(task.id) || activeSendTaskIDs.contains(task.id) {
            throw Self.switchBlocked("Wait for the current turn to finish before switching providers.")
        }
        if let conversationID = task.activeConversationID,
           client.isTurnActive(threadID: conversationID) || client.isTurnActiveInProcess(threadID: conversationID)
            || client.activeTurnOwnerProcessID(threadID: conversationID) != nil {
            throw Self.switchBlocked("Wait for the current turn to finish before switching providers.")
        }
        if task.pendingSubmittedPrompt != nil {
            throw Self.switchBlocked("Wait for the submitted prompt to start before switching providers.")
        }
        if !(try tasks.queuedConversationMessages(taskID: task.id)).isEmpty {
            throw Self.switchBlocked("Send or remove the queued follow-ups before switching providers.")
        }
        let history = try await self.history(taskID: task.id)
        if history.pendingUserInputRequest != nil {
            throw Self.switchBlocked("Answer the pending structured question before switching providers.")
        }
        let answered = Set(history.answeredAsyncQuestionIDs)
        if history.messages.contains(where: { $0.asyncQuestions != nil && !answered.contains($0.id) }),
           task.status == .waitingResponse {
            throw Self.switchBlocked("Answer the pending question before switching providers.")
        }
        return history
    }

    static func switchBlocked(_ message: String) -> BridgeCommandError {
        PlayhouseDiagnostics.record("conversation.provider.switch.blocked", fields: ["reason": message])
        return BridgeCommandError(code: "invalid_transition", message: message)
    }
}
