import Foundation

/// What OpenCode's server reports beyond a turn: the MCP servers it runs for a folder and their
/// sign-in, and a subagent's own child session.
extension OpenCodeClient {
    /// The MCP servers OpenCode starts for the workspace's folder, from `GET /api/mcp`.
    package func mcpServerStatuses(workspace: ConversationWorkspaceContext) async throws -> [McpProviderStatus] {
        try await mcpServers(workspace: workspace).map { server in
            let status = (server["status"] as? [String: Any])?["status"] as? String ?? "unknown"
            return McpProviderStatus(name: server["name"] as? String ?? "", status: status, needsSignIn: status == "needs_auth")
        }
    }

    /// The servers OpenCode runs for the workspace's folder, from its own configuration.
    package func mcpServers(workspace: ConversationWorkspaceContext) async throws -> [[String: Any]] {
        let connection = try await connection(for: workspace)
        let listed = try await connection.request("GET", "api/mcp", query: OpenCodeServerConnection.location(workspace.cwd.path))
        return (listed as? [String: Any])?["data"] as? [[String: Any]] ?? []
    }

    /// Starts the OAuth sign-in OpenCode offers for the server's integration and returns the link
    /// to open; OpenCode finishes it when the browser redirects back to it.
    package func startMcpLogin(name: String, workspace: ConversationWorkspaceContext) async throws -> String {
        guard let server = try await mcpServers(workspace: workspace).first(where: { $0["name"] as? String == name }) else {
            throw BridgeCommandError(code: "invalid_argument", message: "OpenCode doesn't have an MCP server named \(name).")
        }
        guard let integration = server["integrationID"] as? String else {
            throw BridgeCommandError(code: "unavailable", message: "OpenCode offers no sign-in for the MCP server \(name).")
        }
        let connection = try await connection(for: workspace)
        let location = OpenCodeServerConnection.location(workspace.cwd.path)
        let info = try await connection.data("GET", "api/integration/\(integration)", query: location)
        guard let method = (info["methods"] as? [[String: Any]] ?? []).first(where: { $0["type"] as? String == "oauth" })?["id"] as? String else {
            throw BridgeCommandError(code: "unavailable", message: "OpenCode offers no browser sign-in for the MCP server \(name).")
        }
        let attempt = try await connection.data("POST", "api/integration/\(integration)/connect/oauth", query: location, body: ["methodID": method])
        guard let attemptID = attempt["attemptID"] as? String, let url = attempt["url"] as? String else {
            throw BridgeCommandError(code: "operation_failed", message: "OpenCode didn't return a sign-in link for \(name).")
        }
        mcpLoginAttempts[name] = (integration, attemptID)
        // The daemon stays up while the browser sign-in is pending, as for Codex.
        mcpLoginHolds.removeValue(forKey: name)?.cancel()
        BridgeBackgroundWork.onBegin?()
        let timeout = McpLogin.timeout
        mcpLoginHolds[name] = Task {
            defer { BridgeBackgroundWork.onEnd?() }
            try? await Task.sleep(for: timeout)
        }
        PlayhouseDiagnostics.record("mcp.login.started", fields: ["provider": "opencode"])
        return url
    }

    /// Waits for OpenCode to finish a started sign-in: complete, failed, or timed out.
    package func waitForMcpLogin(name: String, workspace: ConversationWorkspaceContext) async -> McpLoginResult {
        guard let attempt = mcpLoginAttempts[name] else { return McpLogin.notStarted(provider: .opencode, name: name) }
        defer {
            mcpLoginAttempts.removeValue(forKey: name)
            mcpLoginHolds.removeValue(forKey: name)?.cancel()
        }
        let timeout = McpLogin.timeout
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: McpLogin.pollInterval(for: timeout))
            do {
                let connection = try await connection(for: workspace)
                let status = try await connection.data(
                    "GET", "api/integration/\(attempt.integration)/connect/oauth/\(attempt.attemptID)",
                    query: OpenCodeServerConnection.location(workspace.cwd.path)
                )
                switch status["status"] as? String {
                case "complete":
                    PlayhouseDiagnostics.record("mcp.login.finished", fields: ["provider": "opencode", "signedIn": "true"])
                    return McpLoginResult(provider: .opencode, name: name, signedIn: true, error: nil)
                case "failed", "cancelled", "expired":
                    return McpLoginResult(provider: .opencode, name: name, signedIn: false,
                                          error: status["message"] as? String ?? "OpenCode couldn't sign in to \(name).")
                default:
                    continue
                }
            } catch {
                return McpLoginResult(provider: .opencode, name: name, signedIn: false, error: error.localizedDescription)
            }
        }
        return McpLogin.timedOut(provider: .opencode, name: name)
    }

    /// A subagent runs in a child session of its parent's; its history is that session's messages.
    package func subagentHistory(childSessionID: String, workspace: ConversationWorkspaceContext) async throws -> ConversationHistory {
        let connection = try await connection(for: workspace)
        var messages: [ConversationMessage] = []
        var tools: [ConversationActivity] = []
        for message in try await connection.messages(childSessionID) {
            let messageID = message["id"] as? String ?? UUID().uuidString
            switch message["type"] as? String {
            case "user":
                let text = message["text"] as? String ?? (message["payload"] as? [String: Any])?["text"] as? String ?? ""
                if !text.isEmpty { messages.append(ConversationMessage(id: messageID, role: .user, text: text, provider: .opencode)) }
            case "assistant":
                for (index, part) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
                    switch part["type"] as? String {
                    case "text":
                        guard let text = part["text"] as? String, !text.isEmpty else { continue }
                        messages.append(ConversationMessage(id: "\(messageID):\(index)", role: .assistant, text: text, phase: "commentary", provider: .opencode))
                    case "tool":
                        guard let callID = part["id"] as? String else { continue }
                        let state = part["state"] as? [String: Any] ?? [:]
                        let status: String = switch state["status"] as? String {
                        case "completed": "completed"
                        case "error": "failed"
                        default: "inProgress"
                        }
                        var activity = OpenCodeTurn.activity(
                            id: callID, name: part["name"] as? String ?? "", input: state["input"] as? [String: Any] ?? [:],
                            status: status, output: OpenCodeTurn.outputText(state["content"]), existing: nil, turnID: nil
                        )
                        activity.afterMessageID = messages.last?.id
                        tools.append(activity)
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        if let last = messages.indices.last, messages[last].role == .assistant { messages[last].phase = "final_answer" }
        return ConversationHistory(messages: messages, activities: tools, timelineActivities: tools.filter(\.isTimelineToolCall), diff: nil)
    }
}
