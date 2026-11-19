import Foundation
import AppKit
import SwiftData
import Darwin

extension CodexAppServerClient {
    /// Loads a thread for a window without reading its history, which Playhouse keeps
    /// itself: the window follows the thread's Goal turns and owns the action handler.
    func attachThread(
        id threadID: String,
        workspace: ConversationWorkspaceContext,
        modelID: String? = nil,
        developerInstructions: String? = nil,
        onActionRequest: @escaping () -> Void
    ) async throws {
        actionRequestHandler = onActionRequest
        // A thread whose send runs here already streams to its sender.
        if turnContexts[threadID] == nil {
            followGoalTurns(threadID: threadID)
        }
        // A thread with a turn running here is already loaded with that turn's
        // model and instructions; resuming it with history's defaults would
        // replace them under the running turn. Reading history doesn't run the
        // model, so it resumes with the task's model but accepts whichever one
        // Codex reports: a thread Codex still has open (a turn that just ended)
        // keeps its own. Sends still confirm the model they run with.
        try await resumeThreadIfNeeded(
            id: threadID,
            workspace: workspace,
            modelID: modelID ?? Self.modelID,
            developerInstructions: developerInstructions,
            // A Goal turn Codex runs on its own uses the loaded thread too.
            reusingLoadedThread: turnContexts[threadID] != nil || contextlessTurnIDs[threadID] != nil,
            confirmingModel: false
        )
    }


    /// Requests Codex app-server to compact a thread's native history. The
    /// provider returns no size metadata for this control request.
    func compactThread(
        id threadID: String, workspace: ConversationWorkspaceContext, modelID: String,
        developerInstructions: String?
    ) async throws {
        try await resumeThreadIfNeeded(
            id: threadID, workspace: workspace, modelID: modelID,
            developerInstructions: developerInstructions,
            reusingLoadedThread: true, confirmingModel: false
        )
        // The empty RPC response only acknowledges the request. Register before
        // sending it because turn notifications can arrive before that response.
        interruptedThreadIDs.remove(threadID)
        let pending = PendingCompaction()
        pendingCompactions[threadID] = pending
        defer { pendingCompactions.removeValue(forKey: threadID) }
        _ = try await request(method: "thread/compact/start", params: ["threadId": threadID])
        while pending.result == nil {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        try pending.result?.get()
    }

    /// Reads a child thread without resuming it or changing its turn state.
    func inspectThreadReadOnly(id threadID: String, workspace: ConversationWorkspaceContext) async throws -> ConversationHistory {
        try await ensureInitialized(workspace: workspace)
        _ = try await request(method: "thread/read", params: ["threadId": threadID])
        _ = try await request(method: "thread/turns/list", params: ["threadId": threadID, "limit": 100])
        return try await readMessages(threadID: threadID)
    }

    func startThread(
        workspace: ConversationWorkspaceContext,
        modelID: String = CodexAppServerClient.modelID,
        developerInstructions: String? = nil
    ) async throws -> String {
        // Rule files Codex does not read itself join the thread's instructions.
        let developerInstructions = RuleBridgeLaunch.combined(developerInstructions, workspace.ruleBridge?.codexInstructions)
        try await ensureInitialized(workspace: workspace)

        var params: [String: Any] = [
                "model": modelID,
                "allowProviderModelFallback": false,
                "cwd": workspace.cwd.path,
                "sandbox": "danger-full-access",
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "historyMode": "paginated",
                "dynamicTools": [],
                "selectedCapabilityRoots": [],
                "runtimeWorkspaceRoots": workspace.roots.map(\.path)
            ]
        if let developerInstructions {
            params["developerInstructions"] = developerInstructions
        }
        try await applySkillBridge(workspace)
        if let config = workspace.codexThreadConfig { params["config"] = config }
        let response = try await request(method: "thread/start", params: params)

        guard let thread = response["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a thread ID.")
        }
        try confirmModel(response["model"] as? String, expected: modelID)
        let parameters = ResumeParameters(
            modelID: modelID, cwd: workspace.cwd.path, roots: workspace.roots.map(\.path), developerInstructions: developerInstructions,
            mcpServers: workspace.mcpBridge?.codexServersJSON
        )
        resumedThreadParameters[threadID] = parameters
        recordServedThread(threadID, parameters)
        return threadID
    }

    /// Forks `sourceThreadID` into a new thread that starts with its whole history. A
    /// read-only workspace's fork runs in Codex's read-only sandbox, with network access
    /// so the Playhouse CLI still reaches the bridge daemon's socket.
    func forkThread(
        sourceThreadID: String,
        workspace: ConversationWorkspaceContext,
        modelID: String,
        developerInstructions: String?
    ) async throws -> String {
        let developerInstructions = RuleBridgeLaunch.combined(developerInstructions, workspace.ruleBridge?.codexInstructions)
        try await ensureInitialized(workspace: workspace)
        var params: [String: Any] = [
            "threadId": sourceThreadID,
            "model": modelID,
            "cwd": workspace.cwd.path,
            "sandbox": workspace.isReadOnly ? "read-only" : "danger-full-access",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            // The fork's own turns are all a side chat reads, so the copied history stays on the server.
            "excludeTurns": true
        ]
        if let developerInstructions { params["developerInstructions"] = developerInstructions }
        try await applySkillBridge(workspace)
        if let config = workspace.codexThreadConfig { params["config"] = config }
        let response = try await request(method: "thread/fork", params: params)
        guard let thread = response["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a forked thread ID.")
        }
        try confirmModel(response["model"] as? String, expected: modelID)
        let parameters = ResumeParameters(
            modelID: modelID, cwd: workspace.cwd.path, roots: workspace.roots.map(\.path), developerInstructions: developerInstructions,
            mcpServers: workspace.mcpBridge?.codexServersJSON
        )
        resumedThreadParameters[threadID] = parameters
        recordServedThread(threadID, parameters)
        PlayhouseDiagnostics.record("codex.thread.forked", fields: diagnosticFields([
            "threadID": threadID, "sourceThreadID": sourceThreadID, "readOnly": String(workspace.isReadOnly)
        ]))
        return threadID
    }

    /// The MCP servers Codex configures for itself, with whether each needs the
    /// user to sign in (`codex mcp login`).
    func mcpServerStatuses(workspace: ConversationWorkspaceContext) async throws -> [McpProviderStatus] {
        try await ensureInitialized(workspace: workspace)
        let response = try await request(method: "mcpServerStatus/list", params: [:])
        return (response["data"] as? [[String: Any]] ?? []).compactMap { server in
            guard let name = server["name"] as? String else { return nil }
            let auth = server["authStatus"] as? String ?? "unknown"
            return McpProviderStatus(name: name, status: auth, needsSignIn: auth == "notLoggedIn")
        }
    }

    /// Asks Codex to start the OAuth sign-in of one of its MCP servers and
    /// returns the link to open in the browser. Codex finishes the sign-in itself
    /// when the browser redirects back to it.
    func startMcpLogin(name: String, workspace: ConversationWorkspaceContext) async throws -> String {
        try await ensureInitialized(workspace: workspace)
        let response = try await request(method: "mcpServer/oauth/login", params: ["name": name])
        guard let link = response["authorizationUrl"] as? String, !link.isEmpty else {
            throw ClientError.protocolFailure("Codex did not return a sign-in link for \(name).")
        }
        startedMcpLogins.insert(name)
        holdBridgeForMcpLogin(name)
        PlayhouseDiagnostics.record("mcp.login.started", fields: ["provider": "codex"])
        return link
    }

    func holdBridgeForMcpLogin(_ name: String) {
        releaseBridgeForMcpLogin(name)
        BridgeBackgroundWork.onBegin?()
        let timeout = McpLogin.timeout
        mcpLoginHolds[name] = Task {
            defer { BridgeBackgroundWork.onEnd?() }
            try? await Task.sleep(for: timeout)
        }
    }

    func releaseBridgeForMcpLogin(_ name: String) {
        mcpLoginHolds.removeValue(forKey: name)?.cancel()
    }

    /// Waits until Codex reports the server as signed in, or the sign-in times out.
    func waitForMcpLogin(name: String, workspace: ConversationWorkspaceContext) async -> McpLoginResult {
        guard startedMcpLogins.contains(name) else { return McpLogin.notStarted(provider: .codex, name: name) }
        defer {
            startedMcpLogins.remove(name)
            releaseBridgeForMcpLogin(name)
        }
        let timeout = McpLogin.timeout
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: McpLogin.pollInterval(for: timeout))
            do {
                guard let server = try await mcpServerStatuses(workspace: workspace).first(where: { $0.name == name }) else {
                    return McpLoginResult(provider: .codex, name: name, signedIn: false, error: "Codex doesn't have an MCP server named \(name).")
                }
                if !server.needsSignIn {
                    PlayhouseDiagnostics.record("mcp.login.finished", fields: ["provider": "codex", "signedIn": "true"])
                    return McpLoginResult(provider: .codex, name: name, signedIn: true, error: nil)
                }
            } catch {
                return McpLoginResult(provider: .codex, name: name, signedIn: false, error: error.localizedDescription)
            }
        }
        return McpLogin.timedOut(provider: .codex, name: name)
    }

    func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption] {
        try await ensureInitialized(workspace: workspace)
        for attempt in 0..<3 {
            let response = try await request(method: "model/list", params: ["includeHidden": false])
            let models = (response["data"] as? [[String: Any]] ?? []).compactMap { item -> ConversationModelOption? in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let supportedEfforts = (item["supportedReasoningEfforts"] as? [Any])?.compactMap { value -> ConversationEffort? in
                    let rawValue = (value as? String) ?? (value as? [String: Any])?["reasoningEffort"] as? String
                    guard let rawValue else { return nil }
                    return ConversationEffort(rawValue: rawValue)
                }
                return ConversationModelOption(
                    id: id,
                    name: item["displayName"] as? String ?? item["model"] as? String ?? id,
                    isDefault: item["isDefault"] as? Bool ?? false,
                    supportedEfforts: supportedEfforts?.isEmpty == false ? supportedEfforts : nil
                )
            }
            if !models.isEmpty { return models }
            if attempt < 2 { try await Task.sleep(for: .milliseconds(200)) }
        }
        return [ConversationModelOption(id: Self.modelID, name: "GPT-6 Luna", isDefault: true)]
    }
}

/// One plugin agent turn on an ephemeral Codex thread: the text of its last agent
/// message and how its turn ended.
@MainActor
final class CodexPlainTurn {
    struct Outcome {
        var status: String
        var text: String?
        var error: String?
    }

    let threadID: String
    var turnID: String?
    private var lastMessage: String?
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    init(threadID: String) { self.threadID = threadID }

    /// Takes one of the thread's notifications; true once the turn has ended.
    func observe(method: String, params: [String: Any]) -> Bool {
        switch method {
        case "turn/started":
            turnID = (params["turn"] as? [String: Any])?["id"] as? String ?? turnID
        case "item/completed":
            if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage", let text = item["text"] as? String {
                lastMessage = text
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            let error = (turn["error"] as? [String: Any])?["message"] as? String
            switch turn["status"] as? String ?? "completed" {
            case "completed": finish(status: "completed", error: nil)
            case "interrupted": finish(status: "interrupted", error: error)
            default: finish(status: "failed", error: error ?? "Codex couldn't finish the turn.")
            }
            return true
        default:
            break
        }
        return false
    }

    func finish(status: String, error: String?) {
        guard outcome == nil else { return }
        let outcome = Outcome(status: status, text: lastMessage, error: error)
        self.outcome = outcome
        waiters.forEach { $0.resume(returning: outcome) }
        waiters.removeAll()
    }

    func result() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Plugins' background work

extension CodexAppServerClient {
    /// A thread Codex keeps in memory only, for a plugin's background work: it
    /// never appears in the user's Codex threads. It runs read-only with no
    /// approval prompts, since nobody watches it.
    func startEphemeralThread(workspace: ConversationWorkspaceContext, modelID: String) async throws -> String {
        try await ensureInitialized(workspace: workspace)
        let response = try await request(method: "thread/start", params: [
            "ephemeral": true, "model": modelID, "cwd": workspace.cwd.path,
            "sandbox": "read-only", "approvalPolicy": "never", "approvalsReviewer": "user",
            "dynamicTools": [], "selectedCapabilityRoots": [], "runtimeWorkspaceRoots": workspace.roots.map(\.path)
        ])
        guard let threadID = (response["thread"] as? [String: Any])?["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a thread ID.")
        }
        return threadID
    }

    /// Calls an MCP tool Codex is connected to (`mcp__<server>__<tool>`) with
    /// `mcpServer/tool/call`, with no model turn, on an ephemeral thread kept warm
    /// `ClaudeCodeClient.McpCallSession.idleLifetime` after its last call.
    func callMcpTool(_ qualified: String, arguments: [String: Any], workspace: ConversationWorkspaceContext, timeout: Duration) async throws -> [String: Any] {
        guard isInstalled else { throw ClientError.cliNotFound }
        guard let (server, tool) = McpToolCallError.split(qualified) else {
            throw McpToolCallError.toolFailed("Not a fully-qualified MCP tool name: \(qualified)")
        }
        let threadID: String
        if let warm = mcpCallThread {
            threadID = warm.id
        } else if let start = mcpCallThreadStart {
            threadID = try await start.value
        } else {
            let start = Task { @MainActor in try await self.startEphemeralThread(workspace: workspace, modelID: Self.modelID) }
            mcpCallThreadStart = start
            defer { mcpCallThreadStart = nil }
            threadID = try await start.value
        }
        mcpCallThread?.idle?.cancel()
        mcpCallThread = (threadID, nil)
        mcpCallsInFlight += 1
        // The idle wait starts when the last call returns, so a long call keeps its thread.
        defer {
            mcpCallsInFlight -= 1
            if mcpCallsInFlight == 0, mcpCallThread?.id == threadID {
                let lifetime = ClaudeCodeClient.McpCallSession.idleLifetime
                mcpCallThread = (threadID, Task { @MainActor [weak self] in
                    try? await Task.sleep(for: lifetime)
                    guard !Task.isCancelled, self?.mcpCallThread?.id == threadID, self?.mcpCallsInFlight == 0 else { return }
                    self?.mcpCallThread = nil
                    self?.releaseEphemeralThread(threadID)
                })
            }
        }
        do {
            return try await request(method: "mcpServer/tool/call", params: [
                "threadId": threadID, "server": server, "tool": tool, "arguments": arguments
            ], timeout: timeout)
        } catch ClientError.protocolFailure(let message) where message.contains("did not answer") {
            throw McpToolCallError.timedOut(Int(timeout.components.seconds))
        } catch let error as ClientError {
            let message = error.localizedDescription
            let lowered = message.lowercased()
            if lowered.contains("method not found") || lowered.contains("unknown variant") {
                throw McpToolCallError.unsupported("This Codex release can't call MCP tools directly; update Codex.")
            }
            // The thread went away (a restarted app-server): the next call starts another.
            if lowered.contains("thread not found") { mcpCallThread?.idle?.cancel(); mcpCallThread = nil }
            if case .processExited = error { throw error }
            throw McpToolCallError.toolFailed(message)
        }
    }

    /// Starts a plugin's agent turn on an ephemeral thread, with `outputSchema`
    /// constraining its final message when given; await `CodexPlainTurn.result()`.
    func startPlainTurn(prompt: String, modelID: String?, outputSchema: [String: Any]?, workspace: ConversationWorkspaceContext) async throws -> CodexPlainTurn {
        guard isInstalled else { throw ClientError.cliNotFound }
        let model = modelID ?? Self.modelID
        let threadID = try await startEphemeralThread(workspace: workspace, modelID: model)
        // Waiting before the turn starts, since its notifications can precede the answer.
        let turn = CodexPlainTurn(threadID: threadID)
        plainTurns[threadID] = turn
        var params: [String: Any] = [
            "threadId": threadID, "model": model, "cwd": workspace.cwd.path, "approvalPolicy": "never",
            "sandboxPolicy": ["type": "readOnly", "networkAccess": true],
            "input": [["type": "text", "text": prompt]]
        ]
        if let outputSchema { params["outputSchema"] = outputSchema }
        do {
            let response = try await request(method: "turn/start", params: params)
            turn.turnID = turn.turnID ?? (response["turn"] as? [String: Any])?["id"] as? String
        } catch {
            plainTurns[threadID] = nil
            throw error
        }
        return turn
    }

    /// Lets the app-server unload an ephemeral thread whose work is over, so a
    /// long session doesn't keep every run's thread loaded.
    func releaseEphemeralThread(_ threadID: String) {
        Task { @MainActor in
            _ = try? await request(method: "thread/unsubscribe", params: ["threadId": threadID], timeout: .seconds(5))
        }
    }

    /// Stops a plugin's agent turn; it ends `interrupted`.
    func interruptPlainTurn(_ turn: CodexPlainTurn) async {
        guard let turnID = turn.turnID else { return }
        _ = try? await request(method: "turn/interrupt", params: ["threadId": turn.threadID, "turnId": turnID])
    }
}

