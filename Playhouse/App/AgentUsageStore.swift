import Foundation

/// What the daemon currently knows about each provider's account and usage.
/// Limits are account-wide, so one store serves every task; the clients feed it
/// as their providers report, and the bridge reads it for the window.
@MainActor
final class AgentUsageStore {
    private static var stores: [String: AgentUsageStore] = [:]

    /// One store per data directory (`nil` in production), matching the shared clients' scope.
    static func shared(scope: String?) -> AgentUsageStore {
        let key = scope.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? ""
        if let store = stores[key] { return store }
        let store = AgentUsageStore()
        stores[key] = store
        return store
    }

    private var states: [String: AgentProviderUsage] = [:]
    private var persistenceURL: URL?

    /// Loads the last-known values saved under `directory`, once. Claude only
    /// reports while a task runs, so these are what an idle app shows.
    func configurePersistence(directory: URL) {
        guard persistenceURL == nil else { return }
        let url = directory.appendingPathComponent("agent-usage.json")
        persistenceURL = url
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([String: AgentProviderUsage].self, from: data) else { return }
        for (provider, state) in saved where states[provider] == nil { states[provider] = state }
    }

    func state(_ provider: ConversationProvider) -> AgentProviderUsage {
        states[provider.rawValue] ?? AgentProviderUsage(provider: provider.rawValue)
    }

    private func update(_ provider: ConversationProvider, _ change: (inout AgentProviderUsage) -> Void) {
        var state = self.state(provider)
        let before = state
        change(&state)
        guard state != before else { return }
        states[provider.rawValue] = state
        persist()
    }

    private func persist() {
        guard let persistenceURL, let data = try? JSONEncoder().encode(states) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    func setInstalled(_ provider: ConversationProvider, _ installed: Bool) {
        update(provider) { $0.installed = installed }
    }

    func setLoginInProgress(_ provider: ConversationProvider, _ inProgress: Bool) {
        update(provider) { $0.loginInProgress = inProgress }
    }

    /// Records the login state. A different account, or none, drops the old
    /// account's usage with it.
    func setAuth(_ provider: ConversationProvider, loggedIn: Bool, account: String?, plan: String?) {
        update(provider) { state in
            if !loggedIn || (state.account != nil && account != nil && state.account != account) { state.snapshot = nil }
            state.loggedIn = loggedIn
            state.account = loggedIn ? account : nil
            state.plan = loggedIn ? plan : nil
            if loggedIn { state.loginInProgress = false }
        }
    }

    /// Forgets cached usage, as when the account is being switched.
    func clearUsage(_ provider: ConversationProvider) {
        update(provider) { $0.snapshot = nil }
    }

    func recordClaudeEvent(_ message: [String: Any], now: Date = .now) {
        guard let parsed = ClaudeRateLimitEvent.parse(message) else { return }
        update(.claude) { state in
            var snapshot = state.snapshot ?? AgentUsageSnapshot(updatedAt: now.timeIntervalSince1970)
            for window in parsed.windows {
                if let index = snapshot.windows.firstIndex(where: { $0.id == window.id }) {
                    var existing = snapshot.windows[index]
                    // A window that rolled over since it was last seen starts from nothing.
                    if let old = existing.resetsAt, let new = window.resetsAt, new > old, window.usedPercent == nil { existing.usedPercent = nil }
                    existing.usedPercent = window.usedPercent ?? existing.usedPercent
                    existing.resetsAt = window.resetsAt ?? existing.resetsAt
                    snapshot.windows[index] = existing
                } else {
                    snapshot.windows.append(window)
                }
            }
            snapshot.windows.sort(by: ClaudeRateLimitEvent.windowOrder)
            if let status = parsed.status { snapshot.status = status }
            snapshot.updatedAt = now.timeIntervalSince1970
            state.snapshot = snapshot
            state.loggedIn = state.loggedIn ?? true
        }
    }

    /// Records Codex's rate limits. A full read replaces everything; a push is
    /// sparse, so it only replaces the windows and credits it carries.
    func recordCodexRead(_ result: [String: Any], now: Date = .now) {
        let buckets = CodexRateLimits.parseRead(result)
        update(.codex) { state in
            var snapshot = AgentUsageSnapshot(updatedAt: now.timeIntervalSince1970)
            for bucket in buckets {
                snapshot.windows += bucket.windows
                if bucket.coveredPrefix.isEmpty { snapshot.credits = bucket.credits }
                if bucket.limitReached { snapshot.status = .rejected }
            }
            if let plan = buckets.first?.plan.flatMap(CodexRateLimits.planName) { state.plan = plan }
            state.snapshot = snapshot
        }
    }

    func recordCodexUpdate(_ snapshotObject: [String: Any], now: Date = .now) {
        let parsed = CodexRateLimits.parse(snapshotObject)
        update(.codex) { state in
            var snapshot = state.snapshot ?? AgentUsageSnapshot(updatedAt: now.timeIntervalSince1970)
            for window in parsed.windows {
                if let index = snapshot.windows.firstIndex(where: { $0.id == window.id }) { snapshot.windows[index] = window }
                else { snapshot.windows.append(window) }
            }
            if parsed.coveredPrefix.isEmpty, let credits = parsed.credits { snapshot.credits = credits }
            snapshot.status = parsed.limitReached ? .rejected : nil
            if let plan = CodexRateLimits.planName(parsed.plan) { state.plan = plan }
            snapshot.updatedAt = now.timeIntervalSince1970
            state.snapshot = snapshot
        }
    }

    /// The providers as of `now`, with passed reset times already applied.
    func report(now: Date = .now) -> AgentUsageReport {
        let seconds = now.timeIntervalSince1970
        let providers = ConversationProvider.allCases.map { provider -> AgentProviderUsage in
            var state = self.state(provider)
            state.snapshot = state.snapshot?.effective(now: seconds)
            return state
        }
        return AgentUsageReport(providers: providers, generatedAt: seconds)
    }
}

/// The bridge's usage operations, shared by the window and the CLI.
///
/// Usage is pushed by the providers while tasks run (see the clients), so a
/// refresh only reads what a push cannot give: Codex's snapshot and both
/// accounts' login state. Claude's idle usage has no official source; a future
/// one (for example the OAuth usage endpoint behind `/usage`) can feed
/// `AgentUsageStore.recordClaudeEvent`-style updates without touching callers.
@MainActor
enum AgentUsageService {
    static func report(clients: ConversationClients, refresh: Bool) async -> AgentUsageReport {
        let store = AgentUsageStore.shared(scope: clients.codex.runtimeScope)
        if refresh {
            async let codex: Void = clients.codex.refreshAgentUsage()
            async let claude: Void = clients.claude.refreshAgentUsage()
            _ = await (codex, claude)
        }
        return store.report()
    }

    /// Starts a sign-in. Codex returns the URL to open; Claude opens its own browser.
    static func login(_ provider: ConversationProvider, clients: ConversationClients) async throws -> String? {
        switch provider {
        case .codex: return try await clients.codex.startAccountLogin()
        case .claude:
            try clients.claude.startAccountLogin()
            return nil
        }
    }

    /// Signs out, drops the account's cached usage, and starts a new sign-in.
    static func switchAccount(_ provider: ConversationProvider, clients: ConversationClients) async throws -> String? {
        let store = AgentUsageStore.shared(scope: clients.codex.runtimeScope)
        switch provider {
        case .codex: try await clients.codex.logoutAccount()
        case .claude: try await clients.claude.logoutAccount()
        }
        store.clearUsage(provider)
        return try await login(provider, clients: clients)
    }
}
