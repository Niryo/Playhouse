import Foundation

extension CodexAppServerClient {
    // MARK: Account and usage

    /// How long an account or usage read may go unanswered. Tests shorten it through the one
    /// variable family a test request forwards.
    package static var accountReadTimeout: Duration {
        let environment = PlayhouseProcessEnvironment.current
        let seconds = (environment["PLAYHOUSE_E2E_CODEX_ACCOUNT_READ_TIMEOUT_SECONDS"] ?? environment["PLAYHOUSE_CODEX_ACCOUNT_READ_TIMEOUT_SECONDS"])
            .flatMap(Double.init) ?? 30
        return .milliseconds(Int(seconds * 1000))
    }

    package var isInstalled: Bool { Self.findCodexExecutable(override: codexExecutableOverride) != nil }

    /// Reads the account and its rate limits from the app-server, launching it
    /// if it is not running. Later changes arrive as `account/rateLimits/updated`
    /// pushes; periodic reads also catch usage from other clients.
    package func refreshAgentUsage() async {
        let store = AgentUsageStore.shared(scope: runtimeScope)
        store.setInstalled(.codex, isInstalled)
        guard isInstalled else { return }
        // A refresh asked for while one runs (a login finishing during the launch
        // read) runs again afterwards rather than being dropped.
        guard !isRefreshingAgentUsage else {
            agentUsageRefreshPending = true
            return
        }
        isRefreshingAgentUsage = true
        defer { isRefreshingAgentUsage = false }
        // Read through this client's own app-server, never a second one: Codex serializes
        // its sign-in refresh only within one process, so two app-servers on one Codex home
        // could both use the refresh token and sign the user out. Pushes from the same server
        // update the numbers between refreshes. A read that is never answered
        // fails after a timeout, without stopping the server, so it never blocks later refreshes
        // and the last known account and usage stay.
        await readAccountAndUsage(into: store)
        if agentUsageRefreshPending {
            agentUsageRefreshPending = false
            isRefreshingAgentUsage = false
            await refreshAgentUsage()
        }
    }

    package func readAccountAndUsage(into store: AgentUsageStore) async {
        do {
            let workspace = try ConversationWorkspaceContext(roots: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
            try await ensureInitialized(workspace: workspace)
            do {
                let response = try await request(method: "account/read", params: ["refreshToken": false], timeout: Self.accountReadTimeout)
                guard let account = response["account"] as? [String: Any] else {
                    store.setAuth(.codex, loggedIn: false, account: nil, plan: nil)
                    return
                }
                let type = account["type"] as? String
                store.setAuth(
                    .codex,
                    loggedIn: true,
                    account: (account["email"] as? String) ?? (type == "apiKey" ? "API key" : nil),
                    plan: CodexRateLimits.planName(account["planType"] as? String)
                )
            } catch {
                // Account metadata can fail independently of rate limits (for example,
                // when Codex cannot load workspace requirements). Keep the last known
                // identity and still try the usage endpoint.
                PlayhouseDiagnostics.record("codex.agent_usage.account_read.failed", fields: diagnosticFields(["error": error.localizedDescription]))
            }
            store.recordCodexRead(try await request(method: "account/rateLimits/read", params: [:], timeout: Self.accountReadTimeout))
        } catch {
            PlayhouseDiagnostics.record("codex.agent_usage.refresh.failed", fields: diagnosticFields(["error": error.localizedDescription]))
        }
    }

    /// Starts Codex's browser sign-in and returns the URL the user opens. The
    /// app-server completes it with `account/login/completed`.
    /// Sign-in and sign-out run on the shared app-server: its login server has to
    /// stay up until the browser step finishes, and its account notifications
    /// refresh the block afterwards.
    package func startAccountLogin() async throws -> String {
        let workspace = try ConversationWorkspaceContext(roots: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
        try await ensureInitialized(workspace: workspace)
        let response = try await request(method: "account/login/start", params: ["type": "chatgpt"])
        guard let url = response["authUrl"] as? String, !url.isEmpty else {
            throw ClientError.protocolFailure("Codex did not return a sign-in URL.")
        }
        AgentUsageStore.shared(scope: runtimeScope).setLoginInProgress(.codex, true)
        return url
    }

    package func logoutAccount() async throws {
        let workspace = try ConversationWorkspaceContext(roots: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
        try await ensureInitialized(workspace: workspace)
        _ = try await request(method: "account/logout", params: [:])
        AgentUsageStore.shared(scope: runtimeScope).setAuth(.codex, loggedIn: false, account: nil, plan: nil)
    }

    package func validateEffort(_ effort: ConversationEffort, modelID: String, workspace: ConversationWorkspaceContext) async throws {
        guard let model = try await availableModels(workspace: workspace).first(where: { $0.id == modelID }),
              let supportedEfforts = model.supportedEfforts,
              !supportedEfforts.isEmpty else { return }
        guard supportedEfforts.contains(effort) else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Effort '\(effort.rawValue)' is not supported by model '\(modelID)'. Supported efforts: \(supportedEfforts.map(\.rawValue).joined(separator: ", "))."
            )
        }
    }
}
