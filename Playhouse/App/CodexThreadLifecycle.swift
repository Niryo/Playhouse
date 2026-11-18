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
