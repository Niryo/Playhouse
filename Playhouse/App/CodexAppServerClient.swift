import Combine
import Darwin
import Foundation

struct CodexThreadGoal: Codable, Equatable {
    let threadID: String
    let objective: String
    let status: String
    let tokenBudget: Int?
    let tokensUsed: Int?
    let timeUsedSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case threadID = "threadId", objective, status, tokenBudget, tokensUsed, timeUsedSeconds
    }
}

@MainActor
final class CodexAppServerClient: ObservableObject, ConversationProviderClient {
    let provider = ConversationProvider.codex
    nonisolated static let modelID = "gpt-6-luna"
    private static var processActiveThreadIDs = Set<String>()
    private static var activeClientsByThreadID: [String: CodexAppServerClient] = [:]
    /// The client whose turn owns this thread, if it serves the same data
    /// directory as this client. Thread IDs are only unique within one Codex
    /// home, so a client for another isolated store never counts as the owner.
    /// A window and the CLI share one client per Codex home, so the owner is
    /// usually this client; another is one following a turn on a server started
    /// before that (see `sharedClient(for:runDirectory:)`).
    private func activeClient(forThread threadID: String) -> CodexAppServerClient? {
        guard let owner = Self.activeClientsByThreadID[threadID], owner.runtimeScope == runtimeScope else { return nil }
        return owner
    }
    private var startingThreadIDs = Set<String>()
    @Published private(set) var isTurnActive = false
    @Published private(set) var activeThreadID: String?
    @Published private(set) var pendingUserInputRequest: ConversationUserInputRequest?
    @Published private(set) var goalStateThreadID: String?
    @Published private(set) var goalStateRevision = 0
    @Published private(set) var goalTurnRevision = 0
    @Published private(set) var goalTurnCompletedRevision = 0
    @Published private(set) var goalTurnCompletedTurnID: String?
    @Published private(set) var goalTurnStartedThreadID: String?
    /// When this client's goal state last changed, in this process's order of goal events,
    /// so a runtime snapshot over several clients reports the most recent one's thread IDs.
    private(set) var goalEventOrder = 0
    private static var lastGoalEventOrder = 0
    private func noteGoalEvent() {
        Self.lastGoalEventOrder += 1
        goalEventOrder = Self.lastGoalEventOrder
    }
    private var activeConversationMode: ConversationMode = .code

    private enum ClientError: LocalizedError {
        case cliNotFound
        case processStart(String)
        case processExited(String)
        case protocolFailure(String)
        case server(String)
        case staleTurn(String)
        case authentication(String)
        case modelMismatch(String, String)
        case turnFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "Codex CLI wasn't found. Install Codex CLI or add it to PATH, then restart Playhouse."
            case .processStart(let detail):
                "Playhouse couldn't start Codex CLI: \(detail)"
            case .processExited(let detail):
                "The Codex app-server stopped unexpectedly. \(detail)"
            case .protocolFailure(let detail):
                "Playhouse couldn't communicate with Codex: \(detail)"
            case .server(let detail):
                detail
            case .staleTurn(let detail):
                detail
            case .authentication(let detail):
                "Codex CLI needs a valid sign-in. Run `codex login` in Terminal, then try again. \(detail)"
            case .modelMismatch(let model, let expected):
                "Codex selected \(model) instead of \(expected). Playhouse stopped without switching models."
            case .turnFailed(let detail):
                detail
            }
        }
    }

    private var outputPump: ProviderOutputPump?
    private var stdoutBuffer = Data()
    private var process: Process?
    /// Set for the long-lived shared clients: their app-server listens on a Unix socket and
    /// outlives this daemon, so the next daemon of the same service reconnects to it and the
    /// turns it runs keep going across a restart. Short-lived clients keep a stdio child.
    private let persistentServer: CodexSharedServer?
    private var socketConnection: CodexSocketConnection?
    private var serverManifest: CodexServerManifest?
    private var serverExitSource: DispatchSourceProcess?
    private var serverOwnership: AgentOwnershipLock?
    /// A server started by another Codex version or with other flags: kept while it runs a
    /// turn, stopped as soon as it is idle.
    private(set) var isRetiringServer = false
    private var idleShutdownTask: Task<Void, Never>?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingRequestDiagnostics: [Int: (method: String, startedAt: UInt64)] = [:]
    private struct DeltaLogSummary {
        var notificationCount = 0
        var payloadBytes = 0
    }
    private var deltaLogSummaries: [String: (threadID: String, turnID: String, itemID: String, method: String, summary: DeltaLogSummary)] = [:]
    private let deltaLogSummaryLimit = 100
    private var nextRequestID = 1
    private var initialized = false
    private var initializationTask: Task<Void, Error>?
    /// What a thread was last started/resumed with in this still-running
    /// app-server process. Skipping a redundant `thread/resume` call is only
    /// safe when a later call's own model/workspace parameters are identical
    /// to what's already active for that thread in the app-server — otherwise
    /// the app-server would silently keep using stale parameters from an
    /// earlier, unrelated request. This only matters now that one
    /// `CodexAppServerClient` instance can legitimately serve many separate
    /// requests over its life (the bridge daemon), rather than exactly one.
    private struct ResumeParameters: Equatable {
        let modelID: String
        let cwd: String
        let roots: [String]
        let developerInstructions: String?
        /// The thread's MCP server config, so turning a server on or off resumes the thread.
        var mcpServers: String? = nil
    }
    private var resumedThreadParameters: [String: ResumeParameters] = [:]
    private var activeTurnID: String?
    private var conversationOperationsInFlight = 0
    private var applicationShutdownInterruptResult: String?
    private(set) var wasLastTurnInterrupted = false
    private(set) var isPreparingForApplicationTermination = false
    private final class TurnContext {
        var turnID: String?
        let onDelta: (String) -> Void
        let onFinal: (String) -> Void
        let onProgress: (ConversationMessage) -> Void
        let onMessageTimestamp: (String, Date) -> Void
        let onSteer: (String, [String]) -> Void
        let onActivity: (ConversationActivity) -> Void
        let onDiff: (ConversationTurnDiff) -> Void
        let onAction: () -> Void
        let onTokenUsage: (ConversationTurnUsageReport) -> Void
        var activities: [String: ConversationActivity] = [:]
        var startedAtUptime: [String: UInt64] = [:]
        var startedAtDate: [String: Date] = [:]
        var messageTimestamps: [String: Date] = [:]
        var durations: [String: Int] = [:]
        /// The main thread's per-call usage so far this turn, reported at
        /// completion when the terminal notification carries no usage itself.
        var callUsage = ConversationTokenUsage()

        init(onDelta: @escaping (String) -> Void, onFinal: @escaping (String) -> Void,
             onProgress: @escaping (ConversationMessage) -> Void, onMessageTimestamp: @escaping (String, Date) -> Void, onSteer: @escaping (String, [String]) -> Void,
             onActivity: @escaping (ConversationActivity) -> Void, onDiff: @escaping (ConversationTurnDiff) -> Void,
             onAction: @escaping () -> Void,
             onTokenUsage: @escaping (ConversationTurnUsageReport) -> Void = { _ in }) {
            self.onDelta = onDelta; self.onFinal = onFinal; self.onProgress = onProgress; self.onMessageTimestamp = onMessageTimestamp
            self.onSteer = onSteer; self.onActivity = onActivity; self.onDiff = onDiff; self.onAction = onAction
            self.onTokenUsage = onTokenUsage
        }
    }
    private var turnContexts: [String: TurnContext] = [:]
    /// Subagent thread -> the thread that spawned it, from `thread/started`.
    private var threadParents: [String: String] = [:]
    /// The cumulative total last seen per thread, so a repeated usage
    /// notification isn't counted as another call.
    private var lastReportedTotals: [String: Int] = [:]
    private var completedActivityDurations: [String: [String: Int]] = [:]
    private var interruptedThreadIDs = Set<String>()
    private var goalObservationThreadID: String?
    /// The running turn, per task thread, that Codex started without a send of ours, such as a
    /// Goal's work turn, whether a window or the CLI set the Goal. It has no turn context, and
    /// the window and the CLI share this client, so it is kept per thread rather than in
    /// `activeThreadID`/`activeTurnID`, which sends also use. Only a window follows its Goal
    /// signals (`goalObservationThreadID`), but every caller sees it running.
    private var contextlessTurnIDs: [String: String] = [:]
    /// Follows a thread's Goal turns for a window. A turn running on another thread keeps its
    /// entry until it completes, so it stays active and interruptible meanwhile.
    private func followGoalTurns(threadID: String) {
        goalObservationThreadID = threadID
        Self.activeClientsByThreadID[threadID] = self
    }
    private var goalTurnStartRevision = 0
    var lastTurnActivityDurations: [String: Int] { activeThreadID.map { lastTurnActivityDurations(threadID: $0) } ?? [:] }
    func lastTurnActivityDurations(threadID: String) -> [String: Int] {
        turnContexts[threadID]?.durations ?? completedActivityDurations[threadID] ?? [:]
    }
    func wasLastTurnInterrupted(threadID: String) -> Bool { interruptedThreadIDs.contains(threadID) }
    private var actionRequestHandler: (() -> Void)?
    // History reads and other sends can change the displayed thread while a
    // provider turn is waiting. Question ownership follows the requesting thread.
    private struct UserInputContext {
        let mode: ConversationMode
        let handler: (ConversationUserInputRequest) async -> Void
    }
    private struct PendingUserInput {
        let nativeID: Any
        let request: ConversationUserInputRequest
        /// The app-server process (or socket connection) that asked. Only that one,
        /// while it is still the running one, can receive a live answer.
        weak var asker: AnyObject?
    }
    private var userInputContexts: [String: UserInputContext] = [:]
    @Published private var pendingUserInputs: [String: PendingUserInput] = [:]
    private let codexExecutableOverride: String?
    private let codexHomeOverride: String?
    /// This instance's own resolved data directory, fixed at construction time
    /// (debug/test builds only; always `nil` in production). Forwarded into
    /// this client's app-server child process instead of an ambient global, so
    /// a different client instance's concurrently-resolved directory can never
    /// leak into this one's child process environment.
    private let dataDirectoryOverride: String?
    /// The data directory this client serves (debug/test isolation); nil in production.
    var runtimeScope: String? { dataDirectoryOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
    private var turnWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedTurns: [String: Result<Void, Error>] = [:]
    private var rejectedTurnKeys = Set<String>()

    init(codexExecutableOverride: String? = nil, codexHomeOverride: String? = nil, dataDirectory: String? = nil, persistentServer: CodexSharedServer? = nil) {
        self.codexExecutableOverride = ConversationProviderFixture.ownedExecutable(
            codexExecutableOverride,
            providerMarker: (".playhouse-codex-fixture-owner", "Playhouse test owns this Codex protocol fixture (v1).\n")
        )
        self.codexHomeOverride = codexHomeOverride
        self.dataDirectoryOverride = dataDirectory
        self.persistentServer = persistentServer
    }

    /// One Codex client per Codex home, shared across every caller in this process: a window's
    /// requests and the CLI's use the same client and so the same app-server. The bridge
    /// daemon is a single long-lived process per data directory, so this is what makes a Codex
    /// thread's app-server process (and its in-memory turn/ownership state) reachable the same
    /// way no matter which request handles a later steer/interrupt for it — mirroring
    /// `ClaudeCodeClient.sharedPrimaryClient`, which already did this for Claude.
    ///
    /// Codex serializes auth token refresh only within one process, and allows a thread to be
    /// open in only one process, so two app-servers on one Codex home could sign the user out
    /// (a refresh token used twice) or block each other on a thread. What differs between
    /// callers, such as whether a window follows a thread's Goal turns, is per request.
    private static var sharedClients: [String: CodexAppServerClient] = [:]

    /// The parts of a current shared client's key: executable, Codex home, data directory.
    private static let keyPartCount = 3

    /// `dataDirectory` only ever varies across calls in debug/test builds (via
    /// `BridgeRequest.dataDirectory`); production always passes `nil`, so one
    /// real app only ever has one entry here. It's part of the cache key so
    /// that the bridge daemon — now a single long-lived process that can serve
    /// many isolated test data directories in sequence or concurrently — gives
    /// each one its own client (and thus its own app-server child process with
    /// correctly scoped environment forwarding) instead of silently sharing
    /// one across directories that happen to share a process.
    static func sharedClient(
        executableOverride: String?,
        codexHomeOverride: String? = nil,
        dataDirectory: String? = nil,
        runDirectory: URL? = nil
    ) -> CodexAppServerClient {
        let parts = [
            executableOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "__default__",
            resolvedCodexHome(codexHomeOverride),
            dataDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "",
        ]
        return sharedClient(
            parts: parts, executableOverride: executableOverride, codexHomeOverride: codexHomeOverride,
            dataDirectory: dataDirectory, runDirectory: runDirectory
        )
    }

    /// The Codex home an override names, or the one Codex uses without one, so a caller that
    /// sets `CODEX_HOME` to the default home shares the client of one that doesn't set it.
    private static func resolvedCodexHome(_ override: String?) -> String {
        let home = override.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.codex"
        return URL(fileURLWithPath: home).standardizedFileURL.path
    }

    private static func sharedClient(
        parts: [String],
        executableOverride: String?,
        codexHomeOverride: String?,
        dataDirectory: String?,
        runDirectory: URL?
    ) -> CodexAppServerClient {
        let key = parts.joined(separator: "\u{1}")
        if let client = sharedClients[key] { return client }
        // The server's files sit beside the store this data directory opens, and its key
        // includes the service, so two services sharing a data folder never share a server.
        let persistentServer = runDirectory.map {
            CodexSharedServer(
                runDirectory: CodexSharedServer.runsDirectory(dataDirectory: $0),
                keyHash: CodexSharedServer.keyHash(parts: parts, serviceName: AgentRunService.name),
                serviceName: AgentRunService.name,
                keyParts: parts
            )
        }
        let client = CodexAppServerClient(
            codexExecutableOverride: executableOverride,
            codexHomeOverride: codexHomeOverride,
            dataDirectory: dataDirectory,
            persistentServer: persistentServer
        )
        sharedClients[key] = client
        return client
    }

    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["codexPID"] = String(process?.processIdentifier ?? serverManifest?.process?.pid ?? -1)
        fields["activeThreadID"] = activeThreadID ?? ""
        fields["activeTurnID"] = activeTurnID ?? ""
        fields["isTurnActive"] = String(isTurnActive)
        fields["pendingInputThreadID"] = pendingUserInputRequest?.threadID ?? ""
        return fields
    }

    func diagnosticFields(forThread threadID: String, _ additionalFields: [String: String]) -> [String: String] {
        var fields = diagnosticFields(additionalFields)
        fields["activeThreadID"] = threadID
        fields["activeTurnID"] = activeTurnID(for: threadID) ?? ""
        fields["isTurnActive"] = String(isTurnActive(threadID: threadID))
        fields["pendingInputThreadID"] = pendingUserInputRequest(forThread: threadID)?.threadID ?? ""
        return fields
    }

    func loadThread(
        id threadID: String,
        workspace: ConversationWorkspaceContext,
        modelID: String? = nil,
        developerInstructions: String? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        sensitiveConversation: Bool = false,
        observeGoalTurns: Bool = false,
        onActionRequest: @escaping () -> Void
    ) async throws -> ConversationHistory {
        // A window's history request follows the thread's Goal turns and owns the action
        // handler; a CLI read on the same client only reads.
        if observeGoalTurns || actionRequestHandler == nil { actionRequestHandler = onActionRequest }
        // A thread whose send runs here already streams to its sender.
        if observeGoalTurns, turnContexts[threadID] == nil {
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
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            sensitiveConversation: sensitiveConversation,
            // A Goal turn Codex runs on its own uses the loaded thread too.
            reusingLoadedThread: turnContexts[threadID] != nil || contextlessTurnIDs[threadID] != nil,
            confirmingModel: false
        )
        return try await readMessages(threadID: threadID)
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

    /// The servers whose sign-in this client started and that no wait has reported on yet.
    private var startedMcpLogins = Set<String>()
    /// While a sign-in is pending the bridge counts as busy, so it doesn't idle-exit and
    /// stop this app-server, which is the one listening for the browser's redirect.
    private var mcpLoginHolds: [String: Task<Void, Never>] = [:]

    private func holdBridgeForMcpLogin(_ name: String) {
        releaseBridgeForMcpLogin(name)
        BridgeBackgroundWork.onBegin?()
        let timeout = McpLogin.timeout
        mcpLoginHolds[name] = Task {
            defer { BridgeBackgroundWork.onEnd?() }
            try? await Task.sleep(for: timeout)
        }
    }

    private func releaseBridgeForMcpLogin(_ name: String) {
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

    // MARK: Account and usage

    private var isRefreshingAgentUsage = false
    private var agentUsageRefreshPending = false
    /// How long an account or usage read may go unanswered. Tests shorten it through the one
    /// variable family a test request forwards.
    private static var accountReadTimeout: Duration {
        let environment = PlayhouseProcessEnvironment.current
        let seconds = (environment["PLAYHOUSE_E2E_CODEX_ACCOUNT_READ_TIMEOUT_SECONDS"] ?? environment["PLAYHOUSE_CODEX_ACCOUNT_READ_TIMEOUT_SECONDS"])
            .flatMap(Double.init) ?? 30
        return .milliseconds(Int(seconds * 1000))
    }

    var isInstalled: Bool { Self.findCodexExecutable(override: codexExecutableOverride) != nil }

    /// Reads the account and its rate limits from the app-server, launching it
    /// if it is not running. Later changes arrive as `account/rateLimits/updated`
    /// pushes, so this runs on launch and after a login, not on a timer.
    func refreshAgentUsage() async {
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
        // keep the numbers current between refreshes. A read that is never answered
        // fails after a timeout, without stopping the server, so it never blocks later refreshes
        // and the last known account and usage stay.
        await readAccountAndUsage(into: store)
        if agentUsageRefreshPending {
            agentUsageRefreshPending = false
            isRefreshingAgentUsage = false
            await refreshAgentUsage()
        }
    }

    private func readAccountAndUsage(into store: AgentUsageStore) async {
        do {
            let workspace = try ConversationWorkspaceContext(roots: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
            try await ensureInitialized(workspace: workspace)
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
    func startAccountLogin() async throws -> String {
        let workspace = try ConversationWorkspaceContext(roots: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
        try await ensureInitialized(workspace: workspace)
        let response = try await request(method: "account/login/start", params: ["type": "chatgpt"])
        guard let url = response["authUrl"] as? String, !url.isEmpty else {
            throw ClientError.protocolFailure("Codex did not return a sign-in URL.")
        }
        AgentUsageStore.shared(scope: runtimeScope).setLoginInProgress(.codex, true)
        return url
    }

    func logoutAccount() async throws {
        let workspace = try ConversationWorkspaceContext(roots: [URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)])
        try await ensureInitialized(workspace: workspace)
        _ = try await request(method: "account/logout", params: [:])
        AgentUsageStore.shared(scope: runtimeScope).setAuth(.codex, loggedIn: false, account: nil, plan: nil)
    }

    func validateEffort(_ effort: ConversationEffort, modelID: String, workspace: ConversationWorkspaceContext) async throws {
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

    func interruptActiveTurn(threadID expectedThreadID: String) async throws -> Bool {
        if let owner = activeClient(forThread: expectedThreadID), owner !== self {
            return try await owner.interruptActiveTurn(threadID: expectedThreadID)
        }
        guard let turnID = activeTurnID(for: expectedThreadID) else {
            guard activeClient(forThread: expectedThreadID) == nil else { return false }
            return try await ConversationSteerMailbox.requestInterrupt(threadID: expectedThreadID)
        }
        let threadID = expectedThreadID
        wasLastTurnInterrupted = true
        interruptedThreadIDs.insert(threadID)
        do {
            _ = try await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
            return true
        } catch {
            wasLastTurnInterrupted = false
            interruptedThreadIDs.remove(threadID)
            throw error
        }
    }

    func getGoal(threadID: String, workspace: ConversationWorkspaceContext) async throws -> CodexThreadGoal? {
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, reusingLoadedThread: true)
        let response = try await request(method: "thread/goal/get", params: ["threadId": threadID])
        guard let value = response["goal"] as? [String: Any] else { return nil }
        return Self.decodeGoal(value)
    }

    func setGoal(threadID: String, objective: String? = nil, status: String? = nil, workspace: ConversationWorkspaceContext, observeRuntime: Bool = false) async throws -> CodexThreadGoal? {
        let startRevision = goalTurnStartRevision
        // Only a window's own Goal set follows the turns Codex starts for it; a CLI set on the
        // same app-server just sets the Goal.
        if observeRuntime {
            followGoalTurns(threadID: threadID)
            goalTurnStartedThreadID = nil
        }
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, reusingLoadedThread: true)
        var params: [String: Any] = ["threadId": threadID]
        if let objective { params["objective"] = objective }
        if let status { params["status"] = status }
        let response = try await request(method: "thread/goal/set", params: params)
        guard let value = response["goal"] as? [String: Any] else { return nil }
        if observeRuntime {
            try await waitForGoalTurnStart(threadID: threadID, after: startRevision)
            goalTurnRevision += 1
            noteGoalEvent()
        }
        return Self.decodeGoal(value)
    }

    func clearGoal(threadID: String, workspace: ConversationWorkspaceContext) async throws {
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, reusingLoadedThread: true)
        _ = try await request(method: "thread/goal/clear", params: ["threadId": threadID])
    }

    func shutdown() {
        if persistentServer != nil, serverManifest != nil {
            Task { await stopSharedServer(reason: "shutdown") }
            return
        }
        guard let process else {
            PlayhouseDiagnostics.record("codex.app_server.shutdown.skipped", fields: ["reason": "no_process"])
            return
        }
        guard process.isRunning else {
            PlayhouseDiagnostics.record("codex.app_server.shutdown.skipped", fields: [
                "reason": "already_stopped",
                "processID": String(process.processIdentifier),
                "terminationStatus": String(process.terminationStatus)
            ])
            return
        }
        let processID = process.processIdentifier
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            _ = kill(processID, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        PlayhouseDiagnostics.record("codex.app_server.shutdown.finished", fields: [
            "processID": String(processID),
            "terminationStatus": process.isRunning ? "still_running" : String(process.terminationStatus)
        ])
    }

    func prepareForApplicationTermination() async {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = ContinuousClock.now + .seconds(4)
        isPreparingForApplicationTermination = true
        applicationShutdownInterruptResult = nil
        let threadID = activeThreadID
        var interruptAttempted = false
        var interruptResult = "not_attempted"
        PlayhouseDiagnostics.record("application.shutdown.started", fields: [
            "hasActiveTurn": String(isTurnActive),
            "conversationOperationsInFlight": String(conversationOperationsInFlight),
            "hasActiveThread": String(threadID != nil)
        ])
        if let threadID, isTurnActive {
            interruptAttempted = true
            interruptResult = "pending"
            Task { [weak self] in
                guard let self else { return }
                do {
                    let accepted = try await self.interruptActiveTurn(threadID: threadID)
                    self.applicationShutdownInterruptResult = accepted ? "accepted" : "not_accepted"
                } catch {
                    let failure = error as NSError
                    self.applicationShutdownInterruptResult = "failed"
                    PlayhouseDiagnostics.record("application.shutdown.interrupt_failed", fields: [
                        "errorDomain": failure.domain,
                        "errorCode": String(failure.code)
                    ])
                }
            }
        }
        while conversationOperationsInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let result = applicationShutdownInterruptResult { interruptResult = result }
        PlayhouseDiagnostics.record("application.shutdown.turn_drained", fields: [
            "turnStillActive": String(isTurnActive),
            "conversationOperationsInFlight": String(conversationOperationsInFlight),
            "interruptAttempted": String(interruptAttempted),
            "interruptAccepted": interruptResult,
            "drainTimedOut": String(conversationOperationsInFlight > 0),
            "elapsedMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        ])
        shutdown()
        PlayhouseDiagnostics.record("application.shutdown.finished", fields: [
            "elapsedMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        ])
    }

    func beginConversationOperation() {
        conversationOperationsInFlight += 1
    }

    func finishConversationOperation() {
        conversationOperationsInFlight = max(0, conversationOperationsInFlight - 1)
    }

    private static func decodeGoal(_ value: [String: Any]) -> CodexThreadGoal? {
        guard let threadID = value["threadId"] as? String,
              let objective = value["objective"] as? String,
              let status = value["status"] as? String else { return nil }
        return CodexThreadGoal(threadID: threadID, objective: objective, status: status,
            tokenBudget: value["tokenBudget"] as? Int, tokensUsed: value["tokensUsed"] as? Int,
            timeUsedSeconds: value["timeUsedSeconds"] as? Double)
    }

    func steerActiveTurn(threadID expectedThreadID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard let target = activeClient(forThread: expectedThreadID) else {
            return try await ConversationSteerMailbox.requestSteer(threadID: expectedThreadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        guard let turnID = target.activeTurnID(for: expectedThreadID) else { return false }
        let accepted = try await target.sendSteerRequest(threadID: expectedThreadID, turnID: turnID, text: normalized, imageDataURLs: imageDataURLs)
        // The turn's own stream shows the steer, whoever sent it.
        if accepted { target.turnContexts[expectedThreadID]?.onSteer(normalized, imageDataURLs) }
        return accepted
    }

    private func sendSteerRequest(threadID: String, turnID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        // Verified against `codex-cli 0.162.1` app-server schemas: params require
        // threadId/input/expectedTurnId and the response requires turnId.
        let response: [String: Any]
        do {
            response = try await request(method: "turn/steer", params: [
                "threadId": threadID,
                "input": (text.isEmpty ? [] : [["type": "text", "text": text]]) + imageDataURLs.map { ["type": "image", "url": $0] },
                "expectedTurnId": turnID
            ])
        } catch {
            if case ClientError.staleTurn = error {
                return false
            }
            throw error
        }
        guard response["turnId"] as? String == turnID else {
            return false
        }
        return true
    }

    private func serviceSteerMailbox(threadID: String, turnID: String) async {
        await ConversationSteerMailbox.service(threadID: threadID, turnID: turnID) { text, images in
            let accepted: Bool
            do {
                accepted = try await sendSteerRequest(threadID: threadID, turnID: turnID, text: text, imageDataURLs: images)
            } catch {
                if case ClientError.staleTurn = error { return false }
                throw error
            }
            if accepted { turnContexts[threadID]?.onSteer(text, images) }
            return accepted
        } interrupt: {
            try await interruptActiveTurn(threadID: threadID)
        }
    }

    func sendMessage(
        _ text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        sessionRecoveryContext: String? = nil,
        developerInstructions: String? = nil,
        onDelta: @escaping (String) -> Void,
        onFinalMessage: @escaping (String) -> Void,
        onActivity: @escaping (ConversationActivity) -> Void,
        onDiff: @escaping (ConversationTurnDiff) -> Void,
        onHistory: @escaping (ConversationHistory) -> Void,
        onActionRequest: @escaping () -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void,
        onSteerMessage: @escaping (String, [String]) -> Void = { _, _ in },
        onProgressMessage: @escaping (ConversationMessage) -> Void = { _ in },
        onMessageTimestamp: @escaping (String, Date) -> Void = { _, _ in },
        onTurnStarted: @escaping (String) -> Void,
        onTokenUsage: @escaping (ConversationTurnUsageReport) -> Void = { _ in },
        sensitiveUserInputAnswerValues: [String] = [],
        hideSensitiveRecoveryPrompt: Bool = false
    ) async throws {
        guard turnContexts[threadID] == nil else {
            throw BridgeCommandError(code: "invalid_transition", message: "This conversation already has an active send.")
        }
        let context = TurnContext(onDelta: onDelta, onFinal: onFinalMessage, onProgress: onProgressMessage, onMessageTimestamp: onMessageTimestamp,
                                  onSteer: onSteerMessage, onActivity: onActivity, onDiff: onDiff, onAction: onActionRequest,
                                  onTokenUsage: onTokenUsage)
        turnContexts[threadID] = context
        // A new turn supersedes a stop another client recorded for this thread.
        for client in Self.allSharedClients { client.interruptedThreadIDs.remove(threadID) }
        interruptedThreadIDs.remove(threadID)
        userInputContexts[threadID] = UserInputContext(mode: mode, handler: onUserInput)
        defer {
            completedActivityDurations[threadID] = context.durations
            turnContexts.removeValue(forKey: threadID)
            userInputContexts.removeValue(forKey: threadID)
            Self.processActiveThreadIDs.remove(threadID)
            ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            if Self.activeClientsByThreadID[threadID] === self {
                Self.activeClientsByThreadID.removeValue(forKey: threadID)
            }
            if activeThreadID == threadID {
                activeThreadID = turnContexts.first(where: { $0.value.turnID != nil })?.key
                activeTurnID = activeThreadID.flatMap { turnContexts[$0]?.turnID }
                activeConversationMode = .code
            }
            isTurnActive = turnContexts.values.contains { $0.turnID != nil }
        }
        try await resumeThreadIfNeeded(
            id: threadID,
            workspace: workspace,
            modelID: modelID,
            developerInstructions: developerInstructions,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            sensitiveConversation: hideSensitiveRecoveryPrompt || !sensitiveUserInputAnswerValues.isEmpty
        )
        // This send's own stream follows the thread now. A Goal a window follows on another
        // thread keeps being followed: the CLI sends through the same client.
        if goalObservationThreadID == threadID { goalObservationThreadID = nil }
        contextlessTurnIDs.removeValue(forKey: threadID)
        activeThreadID = threadID
        Self.activeClientsByThreadID[threadID] = self
        activeTurnID = nil
        activeConversationMode = mode
        isTurnActive = turnContexts.values.contains { $0.turnID != nil }
        wasLastTurnInterrupted = false
        var input: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        input += imageDataURLs.map { ["type": "image", "url": $0] }
        // Codex has no slash commands, so a `/skill` the message names travels as a skill input.
        input += (workspace.skillBridge?.invocations ?? []).map { ["type": "skill", "name": $0.name, "path": $0.path] }
        var turnParams: [String: Any] = [
            "threadId": threadID,
            "input": input,
            "model": modelID,
            "cwd": workspace.cwd.path,
            "runtimeWorkspaceRoots": workspace.roots.map(\.path),
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "collaborationMode": [
                "mode": mode.rawValue,
                "settings": [
                    "model": modelID,
                    "reasoningEffort": effort.rawValue
                ]
            ]
        ]
        // Every turn of a read-only thread names its sandbox, so a resume can't widen it.
        if workspace.isReadOnly { turnParams["sandboxPolicy"] = ["type": "readOnly", "networkAccess": true] }
        let response = try await request(method: "turn/start", params: turnParams)

        guard let turn = response["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a turn ID.")
        }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        let returnedStatus = turn["status"] as? String
        let turnAlreadyTerminal = completedTurns[turnKey] != nil
            || returnedStatus.map { ["completed", "failed", "interrupted"].contains($0) } == true
        context.turnID = turnAlreadyTerminal ? nil : turnID
        // Another request (a window following a Goal, or a send on another thread) may have
        // moved the single active slot while this turn started; this turn's context has it.
        if activeThreadID == threadID { activeTurnID = turnAlreadyTerminal ? nil : turnID }
        onTurnStarted(turnID)
        isTurnActive = !turnAlreadyTerminal
        if !turnAlreadyTerminal {
            ConversationSteerMailbox.publishActiveTurn(threadID: threadID, turnID: turnID)
            Self.processActiveThreadIDs.insert(threadID)
        }
        PlayhouseDiagnostics.record("codex.turn.started", fields: diagnosticFields([
            "threadID": threadID,
            "turnID": turnID,
            "turnStatus": returnedStatus ?? "unknown",
            "workspaceRootCount": String(workspace.roots.count),
        ]))

        switch turn["status"] as? String {
        case "completed":
            break
        case "failed", "interrupted":
            PlayhouseDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))
            throw ClientError.turnFailed(Self.turnFailureDescription(turn))
        default:
            let mailboxTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.turnContexts[threadID]?.turnID == turnID {
                    await self.serviceSteerMailbox(threadID: threadID, turnID: turnID)
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            defer { mailboxTask.cancel() }
            do {
                try await waitForTurn(turnKey)
            } catch {
                var fields = hideSensitiveRecoveryPrompt
                    ? ["errorDescription": "Private conversation recovery turn failed."]
                    : PlayhouseDiagnostics.errorFields(error)
                fields["threadID"] = threadID
                fields["turnID"] = turnID
                fields.merge(diagnosticFields()) { _, new in new }
                PlayhouseDiagnostics.record("codex.turn.wait_failed", fields: fields)
                throw error
            }
        }

        if let history = try? await readMessages(threadID: threadID) {
            onHistory(history)
        }
    }

    /// Connects to a live server a previous daemon left with no turn for this one to follow, so
    /// its idle timer (and this daemon's exit) can stop it rather than leave it running unseen.
    func adoptSharedServer() async {
        guard socketConnection == nil, let manifest = persistentServer?.readManifest(), manifest.process?.isAlive == true else { return }
        let cwd = manifest.threads.values.first?.cwd ?? NSHomeDirectory()
        guard let workspace = try? ConversationWorkspaceContext(roots: [URL(fileURLWithPath: cwd, isDirectory: true)]) else { return }
        try? await ensureInitialized(workspace: workspace)
    }

    /// The shared client a server's manifest belongs to, as `sharedClient` would build it.
    /// A server started before one app-server served every caller has a key that also held
    /// two goal flags. It gets a client of its own, so a turn it still runs is followed to its
    /// end; that client retires the server as soon as it is idle (see `connectSharedServer`).
    static func sharedClient(for server: CodexSharedServer, runDirectory: URL) -> CodexAppServerClient? {
        let parts = server.keyParts
        let dataDirectory: String
        switch parts.count {
        case keyPartCount: dataDirectory = parts[2]
        case 5: dataDirectory = parts[4]
        default: return nil
        }
        return sharedClient(
            parts: parts,
            executableOverride: parts[0] == "__default__" ? nil : parts[0],
            codexHomeOverride: parts[1].isEmpty ? nil : parts[1],
            dataDirectory: dataDirectory.isEmpty ? nil : dataDirectory,
            runDirectory: runDirectory
        )
    }

    /// Whether a shared server this service started is still running, from its manifest.
    var hasLiveSharedServer: Bool {
        if transportIsRunning, socketConnection != nil { return true }
        return persistentServer?.readManifest()?.process?.isAlive == true
    }

    /// The threads the shared server has loaded, as its manifest records them.
    var sharedServerThreadIDs: Set<String> {
        Set((serverManifest ?? persistentServer?.readManifest())?.threads.keys.map { $0 } ?? [])
    }

    /// Reconnects to the shared server that kept running while the daemon restarted and follows
    /// the thread's running turn. Codex doesn't replay notifications missed while nothing was
    /// connected, so `thread/resume` and the thread's paginated history are the source of truth:
    /// the resume re-sends any pending approval or question, and the turn list says whether the
    /// turn is still running or finished in the meantime.
    func followReattachedTurn(
        threadID: String,
        workspace: ConversationWorkspaceContext,
        callbacks: ConversationTurnCallbacks,
        onAttached: @escaping () -> Void
    ) async throws -> ConversationReattachResult {
        guard let persistentServer, hasLiveSharedServer else { return .agentGone }
        guard turnContexts[threadID] == nil else { return .notRunning }
        let context = TurnContext(onDelta: callbacks.onDelta, onFinal: callbacks.onFinalMessage, onProgress: callbacks.onProgressMessage, onMessageTimestamp: callbacks.onMessageTimestamp,
                                  onSteer: callbacks.onSteerMessage, onActivity: callbacks.onActivity, onDiff: callbacks.onDiff,
                                  onAction: callbacks.onActionRequest, onTokenUsage: callbacks.onTokenUsage)
        turnContexts[threadID] = context
        userInputContexts[threadID] = UserInputContext(mode: .code, handler: callbacks.onUserInput)
        defer {
            completedActivityDurations[threadID] = context.durations
            turnContexts.removeValue(forKey: threadID)
            userInputContexts.removeValue(forKey: threadID)
            Self.processActiveThreadIDs.remove(threadID)
            ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            if Self.activeClientsByThreadID[threadID] === self {
                Self.activeClientsByThreadID.removeValue(forKey: threadID)
            }
            if activeThreadID == threadID {
                activeThreadID = turnContexts.first(where: { $0.value.turnID != nil })?.key
                activeTurnID = activeThreadID.flatMap { turnContexts[$0]?.turnID }
                activeConversationMode = .code
            }
            isTurnActive = turnContexts.values.contains { $0.turnID != nil }
        }
        try await ensureInitialized(workspace: workspace)
        let saved = serverManifest?.threads[threadID] ?? persistentServer.readManifest()?.threads[threadID]
        let parameters = ResumeParameters(
            modelID: saved?.modelID ?? Self.modelID,
            cwd: saved?.cwd ?? workspace.cwd.path,
            roots: saved?.roots ?? workspace.roots.map(\.path),
            developerInstructions: saved?.developerInstructions,
            mcpServers: saved?.mcpServers
        )
        var resumeParameters: [String: Any] = [
            "threadId": threadID,
            "excludeTurns": true,
            "model": parameters.modelID,
            "cwd": parameters.cwd,
            "sandbox": "danger-full-access",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "runtimeWorkspaceRoots": parameters.roots,
        ]
        if let developerInstructions = parameters.developerInstructions { resumeParameters["developerInstructions"] = developerInstructions }
        if let config = workspace.codexThreadConfig { resumeParameters["config"] = config }
        _ = try await request(method: "thread/resume", params: resumeParameters)
        resumedThreadParameters[threadID] = parameters
        let turns = try await request(method: "thread/turns/list", params: ["threadId": threadID, "limit": 1, "sortDirection": "desc"])
        guard let latest = (turns["data"] as? [[String: Any]])?.first, let turnID = latest["id"] as? String else {
            onAttached()
            return .notRunning
        }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        PlayhouseDiagnostics.record("codex.turn.reattached", fields: diagnosticFields([
            "threadID": threadID,
            "turnID": turnID,
            "turnStatus": latest["status"] as? String ?? "unknown",
        ]))
        if latest["status"] as? String == "inProgress", completedTurns[turnKey] == nil {
            context.turnID = turnID
            activeThreadID = threadID
            activeTurnID = turnID
            activeConversationMode = .code
            Self.activeClientsByThreadID[threadID] = self
            Self.processActiveThreadIDs.insert(threadID)
            isTurnActive = true
            ConversationSteerMailbox.publishActiveTurn(threadID: threadID, turnID: turnID)
            onAttached()
            let mailboxTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.turnContexts[threadID]?.turnID == turnID {
                    await self.serviceSteerMailbox(threadID: threadID, turnID: turnID)
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            defer { mailboxTask.cancel() }
            try await waitForTurn(turnKey)
        } else {
            onAttached()
            completedTurns.removeValue(forKey: turnKey)
            if latest["status"] as? String != "completed" {
                if latest["status"] as? String == "interrupted" { interruptedThreadIDs.insert(threadID) }
                if let history = try? await readMessages(threadID: threadID) { callbacks.onHistory(history) }
                throw ClientError.turnFailed(Self.turnFailureDescription(latest))
            }
        }
        if let history = try? await readMessages(threadID: threadID) {
            callbacks.onHistory(history)
        }
        return .finished
    }

    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
        PlayhouseDiagnostics.record("codex.user_input.answer.started", fields: [
            "requestID": requestID,
            "threadID": threadID,
            "questionCount": String(answers.count),
            "answerCount": String(answers.values.reduce(0) { $0 + $1.count })
        ])
        if let owner = activeClient(forThread: threadID), owner !== self {
            return owner.answerUserInput(requestID: requestID, threadID: threadID, answers: answers)
        }
        guard let pending = pendingUserInputs[threadID], pending.request.id == requestID else { return false }
        // A question is only live while the app-server that asked it is still
        // the running one. Its exit can be handled before its last output is,
        // and a later call may already have launched a replacement, so check
        // the asker itself; otherwise the saved copy recovers it as a new turn.
        guard let asker = pending.asker, asker === transportToken, transportIsRunning else {
            clearPendingUserInput(threadID: threadID)
            return false
        }
        let requestIDValue = pending.nativeID
        let pendingUserInputQuestions = Dictionary(uniqueKeysWithValues: pending.request.questions.map { ($0.id, $0) })
        let answersAreValid = Set(answers.keys) == Set(pendingUserInputQuestions.keys) &&
            answers.allSatisfy { questionID, values in
                guard !values.isEmpty, let question = pendingUserInputQuestions[questionID] else { return false }
                guard !question.options.isEmpty else { return values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
                let allowedLabels = Set(question.options.map(\.label))
                return values.allSatisfy { allowedLabels.contains($0) || question.allowsOther }
            }
        guard answersAreValid else {
            PlayhouseDiagnostics.record("codex.user_input.answer.failed", fields: [
                "requestID": requestID,
                "threadID": threadID,
                "reason": "invalid_answer_shape",
                "questionCount": String(answers.count)
            ])
            clearPendingUserInput(threadID: threadID)
            sendServerError(requestID: requestIDValue, code: -32602, message: "Answers must include a non-empty response for every question.")
            return false
        }
        do {
            try sendJSON(["jsonrpc": "2.0", "id": requestIDValue,
                          "result": ["answers": answers.mapValues { ["answers": $0] }]])
            clearPendingUserInput(threadID: threadID)
            PlayhouseDiagnostics.record("codex.user_input.answer.succeeded", fields: [
                "requestID": requestID,
                "threadID": threadID,
                "questionCount": String(answers.count),
                "answerCount": String(answers.values.reduce(0) { $0 + $1.count })
            ])
            return true
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["requestID"] = requestID
            fields["threadID"] = threadID
            PlayhouseDiagnostics.record("codex.user_input.answer.failed", fields: fields)
            actionRequestHandler?()
            return false
        }
    }

    func rejectUserInput(requestID: String, threadID: String, message: String) {
        if let owner = activeClient(forThread: threadID), owner !== self {
            owner.rejectUserInput(requestID: requestID, threadID: threadID, message: message)
            return
        }
        guard let pending = pendingUserInputs[threadID], pending.request.id == requestID else { return }
        let requestIDValue = pending.nativeID
        clearPendingUserInput(threadID: threadID)
        sendServerError(requestID: requestIDValue, code: -32000, message: message)

        guard let turnID = activeTurnID(for: threadID) else { return }
        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        rejectedTurnKeys.insert(turnKey)
        let error = ClientError.turnFailed(message)
        if let waiter = turnWaiters.removeValue(forKey: turnKey) {
            waiter.resume(throwing: error)
        } else {
            completedTurns[turnKey] = .failure(error)
        }
        Task { try? await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
    }

    func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? {
        pendingUserInputs[threadID]?.request
    }

    private func clearPendingUserInput(threadID: String) {
        pendingUserInputs.removeValue(forKey: threadID)
        pendingUserInputRequest = pendingUserInputs.values.first?.request
    }

    func isTurnActive(threadID: String) -> Bool {
        startingThreadIDs.contains(threadID)
            || turnContexts[threadID]?.turnID != nil
            || contextlessTurnIDs[threadID] != nil
            || (activeThreadID == threadID && activeTurnID != nil)
            || pendingUserInputs[threadID] != nil
    }

    func activeTurnID(for threadID: String) -> String? {
        if let turnID = turnContexts[threadID]?.turnID { return turnID }
        if let turnID = contextlessTurnIDs[threadID] { return turnID }
        guard activeThreadID == threadID else { return nil }
        return activeTurnID
    }

    func isObservingGoal(threadID: String) -> Bool {
        goalObservationThreadID == threadID
    }

    /// Every thread with a running turn, a turn that is starting, or a question
    /// waiting for an answer. What `isTurnActive(threadID:)` answers per thread.
    var activeThreadIDsSnapshot: Set<String> {
        var ids = startingThreadIDs
        for (threadID, context) in turnContexts where context.turnID != nil { ids.insert(threadID) }
        if let activeThreadID, activeTurnID != nil { ids.insert(activeThreadID) }
        ids.formUnion(contextlessTurnIDs.keys)
        ids.formUnion(pendingUserInputs.keys)
        return ids
    }

    var pendingUserInputsSnapshot: [String: ConversationUserInputRequest] {
        pendingUserInputs.mapValues(\.request)
    }

    /// The running app-server's OS process ID. Every thread on this client
    /// shares it, so CPU is attributed per thread from its descendants'
    /// working directories (see `CodexProcessAttribution`), not from this PID.
    var appServerProcessIdentifier: pid_t? {
        if let server = serverManifest?.process, socketConnection != nil, server.isAlive { return server.pid }
        guard let process, process.isRunning, process.processIdentifier > 0 else { return nil }
        return process.processIdentifier
    }

    /// The workspace (`cwd` first, then the runtime roots) each turn-active
    /// thread was started or resumed with on this app-server, keyed by
    /// thread ID. A thread still starting has no parameters yet and maps to
    /// no roots, but still counts as active.
    var activeThreadWorkspaceRootsByThreadID: [String: [String]] {
        var result: [String: [String]] = [:]
        for threadID in activeThreadIDsSnapshot {
            guard let parameters = resumedThreadParameters[threadID] else {
                result[threadID] = []
                continue
            }
            var roots = [parameters.cwd]
            for root in parameters.roots where !roots.contains(root) { roots.append(root) }
            result[threadID] = roots
        }
        return result
    }

    var interruptedThreadIDsSnapshot: Set<String> { interruptedThreadIDs }

    var observedGoalThreadIDs: [String] {
        goalObservationThreadID.map { [$0] } ?? []
    }

    /// Every client this process has created through `sharedClient`.
    static var allSharedClients: [CodexAppServerClient] { Array(sharedClients.values) }

    func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        if let target = activeClient(forThread: threadID),
           target.isTurnActive(threadID: threadID) {
            return Int32(ProcessInfo.processInfo.processIdentifier)
        }
        return ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: threadID)
    }

    func canInterruptActiveTurn(threadID: String) -> Bool {
        activeTurnID(for: threadID) != nil
    }

    func markTurnStarting(threadID: String) {
        startingThreadIDs.insert(threadID)
        activeThreadID = threadID
    }

    func clearTurnStarting(threadID: String) {
        startingThreadIDs.remove(threadID)
        if activeThreadID == threadID, activeTurnID == nil {
            activeThreadID = nil
        }
    }

    func isTurnActiveInProcess(threadID: String) -> Bool {
        Self.processActiveThreadIDs.contains(threadID)
    }

    func makeAuxiliaryClient() -> ConversationProviderClient {
        CodexAppServerClient(codexExecutableOverride: codexExecutableOverride)
    }

    func isProviderUnavailable(_ error: Error) -> Bool {
        switch error as? ClientError {
        case .cliNotFound, .processStart, .authentication: true
        default: false
        }
    }

    /// The extra skill roots this app-server was last given. One app-server
    /// serves every task, so it gets the union of their bridge folders and each
    /// thread's config hides the folders that are not its own.
    private var appliedSkillExtraRoots: [String] = []

    private func applySkillBridge(_ workspace: ConversationWorkspaceContext) async throws {
        guard let roots = workspace.skillBridge?.codexExtraRoots, roots != appliedSkillExtraRoots else { return }
        do {
            _ = try await request(method: "skills/extraRoots/set", params: ["extraRoots": roots])
            appliedSkillExtraRoots = roots
        } catch {
            // An older Codex without bridged skills still runs the turn.
            PlayhouseDiagnostics.record("codex.skills.extra_roots_failed", fields: diagnosticFields([
                "errorDescription": error.localizedDescription,
            ]))
        }
    }

    private func ensureInitialized(workspace: ConversationWorkspaceContext) async throws {
        if initialized, transportIsRunning { return }
        if let initializationTask { return try await initializationTask.value }
        let initialization = Task { @MainActor in try await self.initializeProcess(workspace: workspace) }
        initializationTask = initialization
        defer { initializationTask = nil }
        try await initialization.value
    }

    private func initializeProcess(workspace: ConversationWorkspaceContext) async throws {

        if let persistentServer {
            if !transportIsRunning {
                if let token = transportToken { transportDidStop(token, detail: "The connection to the Codex app-server closed.", fields: [:]) }
                try await connectSharedServer(persistentServer, workspaceURL: workspace.cwd)
            }
        } else if process?.isRunning != true {
            if let stoppedProcess = process {
                processDidTerminate(stoppedProcess)
            }
            try launchProcess(workspaceURL: workspace.cwd)
        }

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "playhouse",
                    "title": "Playhouse",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        )
        try sendNotification(method: "initialized")
        initialized = true
    }

    private func launchProcess(workspaceURL: URL) throws {
        guard let executablePath = Self.findCodexExecutable(override: codexExecutableOverride) else {
            throw ClientError.cliNotFound
        }
        appliedSkillExtraRoots = []

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        child.executableURL = URL(fileURLWithPath: executablePath)
        let arguments = [
            "app-server",
            "--listen", "stdio://",
            "--disable", "apps",
            "--disable", "remote_plugin",
            "--disable", "hooks",
            // Goals are always on: a window and the CLI share this app-server.
            "-c", "features.goals=true"
        ]
        let command = ConversationProviderFixture.launchCommand(executable: executablePath, arguments: arguments)
        child.executableURL = URL(fileURLWithPath: command.executable)
        child.arguments = command.arguments
        child.currentDirectoryURL = workspaceURL
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr

        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        if let codexHomeOverride {
            // Codex refuses to start with a home that doesn't exist yet.
            try? FileManager.default.createDirectory(atPath: codexHomeOverride, withIntermediateDirectories: true)
            environment["CODEX_HOME"] = codexHomeOverride
        }
        child.environment = environment

        process = child
        inputPipe = stdin
        outputPipe = stdout
        stderrPipe = stderr
        stdoutBuffer.removeAll(keepingCapacity: true)

        // The provider's output and exit are handled outside the request that
        // launched it; keep that request's environment and diagnostics routing.
        let requestContext = PlayhouseRequestContext.capture()
        let pump = ProviderOutputPump(label: "codex") { [weak self, weak child] item in
            await requestContext.run {
                switch item {
                case .output(let data): await self?.consumeOutput(data, from: child)
                case .exit(let terminated): self?.processDidTerminate(terminated)
                case .ended: break
                }
            }
        }
        outputPump = pump
        stdout.fileHandleForReading.readabilityHandler = { [weak child] handle in
            pump.pushReading {
                // At EOF this fires continuously with empty data; an empty read
                // while the child still runs is a spurious wakeup.
                let data = handle.availableData
                guard !data.isEmpty else {
                    if child?.isRunning != true { handle.readabilityHandler = nil }
                    return nil
                }
                return .output(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak child] handle in
            if handle.availableData.isEmpty, child?.isRunning != true { handle.readabilityHandler = nil }
        }
        child.terminationHandler = { terminatedProcess in
            // Output the child wrote before exiting must be handled before its
            // exit: a question or final message followed by a quick exit would
            // otherwise be reported as a crash that lost it.
            pump.pushReading {
                stdout.fileHandleForReading.readabilityHandler = nil
                let remaining = ProviderOutputPump.readAvailableBytes(from: stdout.fileHandleForReading.fileDescriptor)
                return remaining.isEmpty ? nil : .output(remaining)
            }
            pump.push(.exit(terminatedProcess))
        }

        do {
            try child.run()
            PlayhouseDiagnostics.record("codex.app_server.started", fields: diagnosticFields([
                "executable": executablePath,
                "workingDirectory": workspaceURL.path,
                "processID": String(child.processIdentifier)
            ]))
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            process = nil
            inputPipe = nil
            outputPipe = nil
            stderrPipe = nil
            throw ClientError.processStart(error.localizedDescription)
        }
    }

    private func resumeThreadIfNeeded(
        id threadID: String,
        workspace: ConversationWorkspaceContext,
        modelID: String = CodexAppServerClient.modelID,
        developerInstructions: String? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        sensitiveConversation: Bool = false,
        reusingLoadedThread: Bool = false,
        confirmingModel: Bool = true
    ) async throws {
        let developerInstructions = RuleBridgeLaunch.combined(developerInstructions, workspace.ruleBridge?.codexInstructions)
        var currentParameters = ResumeParameters(
            modelID: modelID, cwd: workspace.cwd.path, roots: workspace.roots.map(\.path), developerInstructions: developerInstructions,
            mcpServers: workspace.mcpBridge?.codexServersJSON
        )
        // Goal reads and writes don't change how the thread runs, so any loaded
        // copy serves them. Resuming again would also fail for a thread started
        // in this process that has no rollout yet.
        if let loaded = resumedThreadParameters[threadID], reusingLoadedThread || loaded == currentParameters,
           transportIsRunning, initialized {
            return
        }

        try await ensureInitialized(workspace: workspace)
        PlayhouseDiagnostics.record("codex.thread.resume_started", fields: diagnosticFields([
            "threadID": threadID,
        ]))
        let response: [String: Any]
        do {
            var params: [String: Any] = [
                    "threadId": threadID,
                    "model": modelID,
                    "cwd": workspace.cwd.path,
                    "sandbox": workspace.isReadOnly ? "read-only" : "danger-full-access",
                    "approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "runtimeWorkspaceRoots": workspace.roots.map(\.path)
                ]
            if let developerInstructions {
                params["developerInstructions"] = developerInstructions
            }
            try await applySkillBridge(workspace)
            if let config = workspace.codexThreadConfig { params["config"] = config }
            response = try await request(method: "thread/resume", params: params)
        } catch {
            var fields = sensitiveConversation
                ? ["errorDescription": "History for a private recovery conversation could not be loaded."]
                : PlayhouseDiagnostics.errorFields(error, redacting: sensitiveUserInputAnswerValues)
            fields["threadID"] = threadID
            fields.merge(diagnosticFields()) { _, new in new }
            PlayhouseDiagnostics.record("codex.thread.resume_failed", fields: fields)
            throw error
        }
        let reportedModel = response["model"] as? String
        if confirmingModel {
            try confirmModel(reportedModel, expected: modelID)
        } else if let reportedModel, reportedModel != modelID {
            // Record the model the thread really has, so a send asking for
            // another one resumes again and has its own model confirmed.
            PlayhouseDiagnostics.record("codex.thread.resume_kept_model", fields: diagnosticFields([
                "threadID": threadID,
                "requestedModel": modelID,
                "reportedModel": reportedModel
            ]))
            currentParameters = ResumeParameters(
                modelID: reportedModel, cwd: currentParameters.cwd, roots: currentParameters.roots,
                developerInstructions: currentParameters.developerInstructions, mcpServers: currentParameters.mcpServers
            )
        }
        resumedThreadParameters[threadID] = currentParameters
        recordServedThread(threadID, currentParameters)
        PlayhouseDiagnostics.record("codex.thread.resumed", fields: diagnosticFields([
            "threadID": threadID,
        ]))
    }

    private func readMessages(threadID: String) async throws -> ConversationHistory {
        var messages: [ConversationMessage] = []
        var latestTurnItems: [[String: Any]] = []
        var compactionHistory: [(item: [String: Any], turnID: String?, order: Int)] = []
        var historicalToolItems: [[String: Any]] = []
        var toolItemIndexes: [String: Int] = [:]
        var historicalSubagentItems: [[String: Any]] = []
        var subagentIndexes: [String: Int] = [:]
        var lastAssistantTurnID: String?
        var lastAssistantPhase: String?
        var cursor: String?
        var visitedCursors = Set<String>()
        var historyItemOrder = 0
        var timelineToolItems: [(item: [String: Any], anchor: String?)] = []
        var timelineToolItemIndexes: [String: Int] = [:]
        var entries: [[String: Any]] = []

        repeat {
            var params: [String: Any] = [
                "threadId": threadID,
                "sortDirection": "asc",
                "limit": 100
            ]
            if let cursor {
                params["cursor"] = cursor
            }

            let response = try await request(method: "thread/items/list", params: params)
            // The installed codex-cli 0.162.1 schema returns {data:[{threadId,turnId,item}],nextCursor}.
            entries += response["data"] as? [[String: Any]] ?? []
            cursor = response["nextCursor"] as? String

            if let cursor, !visitedCursors.insert(cursor).inserted {
                throw ClientError.protocolFailure("Codex returned a repeated history cursor.")
            }
        } while cursor != nil

        for entry in entries {
            guard let item = entry["item"] as? [String: Any] else { continue }
            if item["type"] as? String == "contextCompaction" {
                compactionHistory.append((item, entry["turnId"] as? String, historyItemOrder))
                // Preserve the event boundary between same-phase assistant
                // items so timeline ordering is not collapsed into one bubble.
                lastAssistantTurnID = nil
                lastAssistantPhase = nil
            }
            if ["mcpToolCall", "dynamicToolCall"].contains(item["type"] as? String ?? ""),
               let itemID = item["id"] as? String {
                var historicalItem = item
                historicalItem["_playhouseTurnID"] = entry["turnId"]
                if let index = toolItemIndexes[itemID] {
                    historicalToolItems[index] = historicalItem
                } else {
                    toolItemIndexes[itemID] = historicalToolItems.count
                    historicalToolItems.append(historicalItem)
                }
            }
            var historicalSubagentItem = item
            historicalSubagentItem["_playhouseTurnID"] = entry["turnId"]
            if item["type"] as? String == "subAgentActivity",
               let activity = ConversationActivity.from(item: historicalSubagentItem),
               let childThreadID = activity.childThreadID {
                if let index = subagentIndexes[childThreadID] {
                    var mergedItem = historicalSubagentItem
                    for metadataKey in ["agentPath", "model", "reasoningEffort"]
                    where mergedItem[metadataKey] == nil {
                        mergedItem[metadataKey] = historicalSubagentItems[index][metadataKey]
                    }
                    historicalSubagentItems[index] = mergedItem
                } else {
                    subagentIndexes[childThreadID] = historicalSubagentItems.count
                    historicalSubagentItems.append(historicalSubagentItem)
                }
            }
            if item["type"] as? String == "userMessage" {
                // The diff is the latest turn the user started; a status nudge Playhouse sent
                // is shown in the conversation but must not replace it.
                if !PrivateOutcomeNudgeMarker.matches(Self.chatMessage(from: entry)?.text ?? "") {
                    latestTurnItems.removeAll()
                }
                lastAssistantTurnID = nil
                lastAssistantPhase = nil
            }
            var latestTurnItem = item
            latestTurnItem["_playhouseTurnID"] = entry["turnId"]
            latestTurnItems.append(latestTurnItem)
            if Self.timelineToolItemTypes.contains(item["type"] as? String ?? ""),
               let itemID = item["id"] as? String {
                // A repeated item updates the call but keeps the place it first took.
                let anchor = timelineToolItemIndexes[itemID].map { timelineToolItems[$0].anchor } ?? messages.last?.id
                let record = (item: latestTurnItem, anchor: anchor)
                if let index = timelineToolItemIndexes[itemID] {
                    timelineToolItems[index] = record
                } else {
                    timelineToolItemIndexes[itemID] = timelineToolItems.count
                    timelineToolItems.append(record)
                }
                // Text after the call is a message of its own, below the call.
                lastAssistantTurnID = nil
                lastAssistantPhase = nil
            }
            if var message = Self.chatMessage(from: entry) {
                message.timelineOrder = historyItemOrder
                if message.role == .assistant,
                   message.asyncQuestions == nil,
                   let turnID = entry["turnId"] as? String,
                   turnID == lastAssistantTurnID,
                   message.phase == lastAssistantPhase,
                   let lastIndex = messages.indices.last,
                   messages[lastIndex].role == .assistant,
                   messages[lastIndex].asyncQuestions == nil {
                    messages[lastIndex].text += "\n\n" + message.text
                } else {
                    messages.append(message)
                }
                lastAssistantTurnID = message.role == .assistant ? entry["turnId"] as? String : nil
                lastAssistantPhase = message.role == .assistant ? message.phase : nil
            }
            historyItemOrder += 1
        }

        var activityIndexes: [String: Int] = [:]
        var activities: [ConversationActivity] = []
        for record in compactionHistory {
            guard var activity = ConversationActivity.from(item: record.item, lifecycle: "completed") else { continue }
            activity.turnID = record.turnID
            activity.timelineOrder = record.order
            let key = activity.childThreadID ?? activity.id
            if let index = activityIndexes[key] {
                activities[index] = activity
            } else {
                activityIndexes[key] = activities.count
                activities.append(activity)
            }
        }
        for item in historicalToolItems {
            guard var activity = ConversationActivity.from(item: item) else { continue }
            activity.turnID = item["_playhouseTurnID"] as? String
            let key = activity.childThreadID ?? activity.id
            if let index = activityIndexes[key] { activities[index] = activity }
            else { activityIndexes[key] = activities.count; activities.append(activity) }
        }
        for item in latestTurnItems
            where item["type"] as? String != "contextCompaction"
                && !["mcpToolCall", "dynamicToolCall"].contains(item["type"] as? String ?? "") {
            guard var activity = ConversationActivity.from(item: item) else { continue }
            // Several activity item types don't currently map the optional
            // turnID themselves. Apply it here so sensitive-turn filtering
            // covers every content-bearing activity type.
            activity.turnID = item["_playhouseTurnID"] as? String
            let key = activity.childThreadID ?? activity.id
            if let index = activityIndexes[key] { activities[index] = activity }
            else { activityIndexes[key] = activities.count; activities.append(activity) }
        }
        for item in historicalSubagentItems {
            guard var activity = ConversationActivity.from(item: item) else { continue }
            activity.turnID = item["_playhouseTurnID"] as? String
            let key = activity.childThreadID ?? activity.id
            if let index = activityIndexes[key] { activities[index] = activity }
            else { activityIndexes[key] = activities.count; activities.append(activity) }
        }
        let timelineActivities = timelineToolItems.compactMap { record -> ConversationActivity? in
            guard let anchor = record.anchor, var activity = ConversationActivity.from(item: record.item),
                  activity.isTimelineToolCall else { return nil }
            activity.turnID = record.item["_playhouseTurnID"] as? String
            activity.afterMessageID = anchor
            return activity
        }
        return ConversationHistory(
            messages: messages,
            activities: activities,
            timelineActivities: timelineActivities,
            diff: ConversationTurnDiff.fromFileChangeItems(latestTurnItems)
        )
    }

    /// `timeout` fails a request the app-server never answers without stopping the server; a
    /// late answer is then ignored like any answer with no pending request.
    private func request(method: String, params: [String: Any], timeout: Duration? = nil) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1
        let startedAt = DispatchTime.now().uptimeNanoseconds
        pendingRequestDiagnostics[requestID] = (method, startedAt)
        var fields = diagnosticFields([
            "requestID": String(requestID),
            "method": method,
            "parameterNames": params.keys.sorted().joined(separator: ",")
        ])
        for key in ["threadId", "turnId", "cwd", "model", "sandbox", "approvalPolicy"] {
            if let value = params[key] as? String { fields["parameter.\(key)"] = value }
        }
        if let roots = params["runtimeWorkspaceRoots"] as? [String] {
            fields["workspaceRootCount"] = String(roots.count)
            fields["workspaceRoots"] = roots.joined(separator: "\n")
        }
        PlayhouseDiagnostics.record("codex.rpc.request.started", fields: fields)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            if let timeout {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard let self, let continuation = self.pendingRequests.removeValue(forKey: requestID) else { return }
                    self.pendingRequestDiagnostics.removeValue(forKey: requestID)
                    PlayhouseDiagnostics.record("codex.rpc.request.timed_out", fields: [
                        "requestID": String(requestID), "method": method,
                    ])
                    continuation.resume(throwing: ClientError.protocolFailure("Codex did not answer \(method) in time."))
                }
            }
            do {
                try sendJSON([
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "method": method,
                    "params": params
                ])
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                pendingRequestDiagnostics.removeValue(forKey: requestID)
                var fields = PlayhouseDiagnostics.errorFields(error)
                fields["requestID"] = String(requestID)
                fields["method"] = method
                fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                PlayhouseDiagnostics.record("codex.rpc.request.failed", fields: fields)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String) throws {
        try sendJSON(["jsonrpc": "2.0", "method": method])
    }

    private func sendJSON(_ object: [String: Any]) throws {
        lastServerActivity = Date()
        if let socketConnection {
            guard socketConnection.isOpen else { throw ClientError.processExited("The connection to the Codex app-server closed.") }
            do {
                try socketConnection.send(try JSONSerialization.data(withJSONObject: object))
            } catch {
                throw ClientError.protocolFailure(error.localizedDescription)
            }
            return
        }
        guard let process, process.isRunning, let inputPipe else {
            throw ClientError.processExited("Restart Playhouse and try again.")
        }

        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw ClientError.protocolFailure(error.localizedDescription)
        }
    }

    private func consumeOutput(_ data: Data, from source: AnyObject?) async {
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.range(of: newline) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            await consume(line: line, from: source)
        }
    }

    private func consume(line: Data, from source: AnyObject?) async {
        lastServerActivity = Date()
        guard !line.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if let method = message["method"] as? String {
            if let requestID = message["id"] {
                let params = message["params"] as? [String: Any] ?? [:]
                PlayhouseDiagnostics.record("codex.rpc.server_request", fields: Self.diagnosticNotificationFields(method: method, params: params))
                await handleServerRequest(method: method, params: params, requestID: requestID, from: source)
            } else {
                let params = message["params"] as? [String: Any] ?? [:]
                if Self.highVolumeDeltaMethods.contains(method) {
                    recordDeltaLogSummary(method: method, params: params)
                } else {
                    PlayhouseDiagnostics.record("codex.notification", fields: Self.diagnosticNotificationFields(
                        method: method,
                        params: params
                    ))
                }
                handleNotification(method: method, params: params)
            }
            return
        }

        guard let requestID = message["id"] as? Int,
              let continuation = pendingRequests.removeValue(forKey: requestID) else {
            return
        }
        let requestDiagnostics = pendingRequestDiagnostics.removeValue(forKey: requestID)
        let responseFields: [String: String] = [
            "requestID": String(requestID),
            "method": requestDiagnostics?.method ?? "unknown",
            "responseBytes": String(line.count),
            "durationMilliseconds": requestDiagnostics.map {
                String((DispatchTime.now().uptimeNanoseconds - $0.startedAt) / 1_000_000)
            } ?? ""
        ]

        if let serverError = message["error"] as? [String: Any] {
            let detail = serverError["message"] as? String ?? "Codex returned an unspecified error."
            PlayhouseDiagnostics.record("codex.rpc.response.failed", fields: responseFields.merging([
                "errorCode": String(describing: serverError["code"] ?? "unknown"),
                "errorDescription": "Codex returned an RPC error."
            ]) { _, new in new })
            continuation.resume(throwing: Self.error(
                forServerMessage: detail,
                method: requestDiagnostics?.method
            ))
        } else if let result = message["result"] as? [String: Any] {
            PlayhouseDiagnostics.record("codex.rpc.response.succeeded", fields: responseFields.merging([
                "resultFieldNames": result.keys.sorted().joined(separator: ",")
            ]) { _, new in new })
            continuation.resume(returning: result)
        } else {
            PlayhouseDiagnostics.record("codex.rpc.response.failed", fields: responseFields.merging([
                "errorCode": "empty_response",
                "errorDescription": "Codex returned an empty response."
            ]) { _, new in new })
            continuation.resume(throwing: ClientError.protocolFailure("Codex returned an empty response."))
        }
    }

    private static func diagnosticNotificationFields(method: String, params: [String: Any]) -> [String: String] {
        var fields: [String: String] = [
            "method": method,
            "parameterNames": params.keys.sorted().joined(separator: ",")
        ]
        for key in ["threadId", "turnId", "itemId"] {
            if let value = params[key] as? String { fields[key] = value }
        }
        if let turn = params["turn"] as? [String: Any] {
            fields["turnID"] = turn["id"] as? String ?? ""
            fields["turnStatus"] = turn["status"] as? String ?? ""
        }
        if let item = params["item"] as? [String: Any] {
            fields["itemID"] = item["id"] as? String ?? ""
            fields["itemType"] = item["type"] as? String ?? ""
            fields["itemStatus"] = item["status"] as? String ?? ""
            if let text = item["text"] as? String { fields["textBytes"] = String(text.utf8.count) }
            if let command = item["command"] as? String {
                fields["command"] = command
                fields["commandBytes"] = String(command.utf8.count)
            } else if let commandParts = item["command"] as? [String] {
                let command = commandParts.joined(separator: " ")
                fields["command"] = command
                fields["commandBytes"] = String(command.utf8.count)
            }
            if let workingDirectory = item["cwd"] as? String { fields["workingDirectory"] = workingDirectory }
            if let exitCode = item["exitCode"] { fields["exitCode"] = String(describing: exitCode) }
            if let output = item["aggregatedOutput"] as? String { fields["outputBytes"] = String(output.utf8.count) }
            if let changes = item["changes"] as? [[String: Any]] {
                fields["changedPathCount"] = String(changes.count)
                fields["changedPaths"] = changes.compactMap { $0["path"] as? String }.joined(separator: "\n")
                fields["changeKinds"] = changes.compactMap { $0["kind"] as? String }.joined(separator: ",")
            }
        }
        for key in ["delta", "diff"] {
            if let text = params[key] as? String { fields["\(key)Bytes"] = String(text.utf8.count) }
        }
        return fields
    }

    private static let highVolumeDeltaMethods: Set<String> = [
        "item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"
    ]

    private func recordDeltaLogSummary(method: String, params: [String: Any]) {
        let threadID = params["threadId"] as? String ?? ""
        let turnID = params["turnId"] as? String
            ?? contextlessTurnIDs[threadID]
            ?? (threadID == activeThreadID ? activeTurnID : nil)
            ?? ""
        let itemID = params["itemId"] as? String ?? (params["item"] as? [String: Any])?["id"] as? String ?? ""
        let key = [threadID, turnID, itemID, method].joined(separator: "\u{1F}")
        var entry = deltaLogSummaries[key] ?? (threadID, turnID, itemID, method, DeltaLogSummary())
        entry.summary.notificationCount += 1
        entry.summary.payloadBytes += (params["delta"] as? String)?.utf8.count ?? 0
        deltaLogSummaries[key] = entry
        if entry.summary.notificationCount >= deltaLogSummaryLimit {
            flushDeltaLogSummary(for: key, reason: "batch")
        }
    }

    /// Reports one model call from `thread/tokenUsage/updated` as it happens.
    /// A subagent's call lands on the thread that spawned it, so it joins that
    /// task's counter; its own `agentID` keeps it apart from the main agent.
    private func reportCallUsage(_ params: [String: Any]) {
        guard let threadID = params["threadId"] as? String,
              let usage = params["tokenUsage"] as? [String: Any],
              let total = usage["total"] as? [String: Any],
              let last = usage["last"] as? [String: Any] else { return }
        let totalTokens = total["totalTokens"] as? Int ?? 0
        guard totalTokens > 0, lastReportedTotals[threadID] != totalTokens else { return }
        lastReportedTotals[threadID] = totalTokens
        var rootID = threadID
        var hops = 0
        while turnContexts[rootID] == nil, let parent = threadParents[rootID], hops < 8 {
            rootID = parent
            hops += 1
        }
        guard let context = turnContexts[rootID] else { return }
        let call = ConversationTokenUsage(codexPayload: last)
        let sent = call.inputTokens + call.cacheReadTokens + call.cacheCreationTokens
        if rootID == threadID { context.callUsage = context.callUsage + call }
        context.onTokenUsage(ConversationTurnUsageReport(
            turnID: nil, usage: ConversationTokenUsage(), toolLabels: [],
            liveCall: ConversationLiveCall(
                agentID: rootID == threadID ? nil : threadID,
                calls: 1, sentTokens: sent, outputTokens: call.outputTokens,
                uncachedInputTokens: call.inputTokens, cacheReadTokens: call.cacheReadTokens, cacheWriteTokens: call.cacheCreationTokens,
                contextTokens: sent
            )
        ))
    }

    private func flushDeltaLogSummary(for key: String, reason: String) {
        guard let entry = deltaLogSummaries.removeValue(forKey: key) else { return }
        PlayhouseDiagnostics.record("codex.notification.summary", fields: [
            "method": entry.method,
            "threadID": entry.threadID,
            "turnID": entry.turnID,
            "itemID": entry.itemID,
            "notificationCount": String(entry.summary.notificationCount),
            "payloadBytes": String(entry.summary.payloadBytes),
            "flushReason": reason
        ])
    }

    private func flushDeltaLogSummaries(threadID: String, turnID: String, reason: String) {
        let keys = deltaLogSummaries.compactMap { key, entry in
            entry.threadID == threadID && (entry.turnID == turnID || entry.turnID.isEmpty) ? key : nil
        }
        for key in keys { flushDeltaLogSummary(for: key, reason: reason) }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        let context = (params["threadId"] as? String).flatMap { turnContexts[$0] }
        switch method {
        case "thread/goal/updated", "thread/goal/cleared":
            guard let threadID = params["threadId"] as? String else { return }
            goalStateThreadID = threadID
            goalStateRevision += 1
            noteGoalEvent()
        case "turn/started":
            // Server notifications use params {threadId, turn:{id,status,...}}.
            // A subagent's thread reports through its parent's turn instead.
            guard let threadID = params["threadId"] as? String,
                  context != nil || threadParents[threadID] == nil,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }
            context?.turnID = turnID
            if context == nil {
                contextlessTurnIDs[threadID] = turnID
            } else if activeThreadID == threadID {
                activeTurnID = turnID
            }
            isTurnActive = true
            Self.processActiveThreadIDs.insert(threadID)
            if goalObservationThreadID == threadID {
                goalTurnStartRevision += 1
                goalTurnRevision += 1
                goalTurnStartedThreadID = threadID
                noteGoalEvent()
            }
        case "item/agentMessage/delta", "item/plan/delta":
            guard let context, let delta = params["delta"] as? String else { return }
            context.onDelta(delta)
        case "item/started", "item/completed":
            if goalObservationThreadID == (params["threadId"] as? String) {
                goalTurnRevision += 1
                noteGoalEvent()
            }
            guard let context, let item = params["item"] as? [String: Any] else { return }
            if let id = item["id"] as? String,
               let type = item["type"] as? String,
               ["userMessage", "agentMessage", "plan"].contains(type) {
                if context.messageTimestamps[id] == nil {
                    let observedAt = Date()
                    context.messageTimestamps[id] = observedAt
                    context.onMessageTimestamp(id, observedAt)
                }
            }
            if method == "item/completed",
               let itemType = item["type"] as? String,
               itemType == "agentMessage" || itemType == "plan" {
                let text = item["text"] as? String ?? ""
                let questions = itemType == "agentMessage" && item["delivery"] as? String == "async"
                    ? Self.asyncQuestions(from: item) : nil
                guard !text.isEmpty || questions != nil else { return }
                if itemType == "agentMessage", item["delivery"] as? String == "async",
                   let questions {
                    context.onProgress(ConversationMessage(
                        id: item["id"] as? String ?? UUID().uuidString,
                        role: .assistant,
                        text: text,
                        phase: item["phase"] as? String,
                        turnID: params["turnId"] as? String,
                        asyncQuestions: questions
                    ))
                } else if itemType == "agentMessage", item["phase"] as? String == "commentary" {
                    context.onProgress(ConversationMessage(
                        id: item["id"] as? String ?? UUID().uuidString,
                        role: .assistant,
                        text: text,
                        phase: "commentary",
                        turnID: params["turnId"] as? String
                    ))
                } else {
                    context.onFinal(text)
                }
            }
            let activityID = item["type"] as? String == "subAgentActivity"
                ? (item["agentThreadId"] as? String ?? item["id"] as? String)
                : item["id"] as? String
            guard let activityID else { return }
            if method == "item/started" {
                context.startedAtUptime[activityID] = context.startedAtUptime[activityID] ?? DispatchTime.now().uptimeNanoseconds
                context.startedAtDate[activityID] = context.startedAtDate[activityID] ?? .now
            }
            let measuredDuration: Int?
            if method == "item/completed", let started = context.startedAtUptime[activityID] {
                measuredDuration = max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
            } else {
                measuredDuration = nil
            }
            guard let activity = ConversationActivity.from(
                item: item,
                lifecycle: method == "item/completed" ? "completed" : "inProgress",
                turnID: params["turnId"] as? String,
                startedAt: context.startedAtDate[activityID],
                measuredDurationMs: measuredDuration
            ) else { return }
            if method == "item/completed" {
                if let durationMs = activity.durationMs { context.durations[activity.id] = durationMs }
                context.startedAtUptime.removeValue(forKey: activityID)
                context.startedAtDate.removeValue(forKey: activityID)
            }
            context.activities[activity.id] = activity
            context.onActivity(activity)
        case "item/commandExecution/outputDelta":
            guard let context, let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String,
                  var activity = context.activities[itemID] else { return }
            let output = String((activity.detail + delta).suffix(2_000))
            activity.detail = output
            context.activities[itemID] = activity
            context.onActivity(activity)
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let id = thread["id"] as? String,
               let parent = thread["parentThreadId"] as? String
                ?? (((thread["source"] as? [String: Any])?["subAgent"] as? [String: Any])?["thread_spawn"] as? [String: Any])?["parent_thread_id"] as? String {
                threadParents[id] = parent
            }
        case "thread/tokenUsage/updated":
            reportCallUsage(params)
        case "account/rateLimits/updated":
            if let snapshot = params["rateLimits"] as? [String: Any] {
                AgentUsageStore.shared(scope: runtimeScope).recordCodexUpdate(snapshot)
            }
        case "account/login/completed", "account/updated":
            Task { await refreshAgentUsage() }
        case "turn/diff/updated":
            guard let context, let diff = params["diff"] as? String, !diff.isEmpty else { return }
            context.onDiff(ConversationTurnDiff(unifiedDiff: diff))
        case "turn/completed":
            // A terminal notification has the same threadId/turn envelope; only a matching waiter completes.
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }

            flushDeltaLogSummaries(threadID: threadID, turnID: turnID, reason: "turn_completed")

            // The app-server reports a turn's cost on its terminal notification,
            // either beside the turn envelope or inside it.
            if let context,
               let payload = (params["usage"] as? [String: Any]) ?? (turn["usage"] as? [String: Any]) {
                let usage = ConversationTokenUsage(codexPayload: payload)
                if usage.isEmpty {
                    // A non-empty payload that parses to all zeros means the
                    // app-server changed its usage field names; silently
                    // dropping it would make a real regression invisible.
                    PlayhouseDiagnostics.record("codex.turn.usage_unparsed", fields: diagnosticFields([
                        "threadID": threadID,
                        "turnID": turnID,
                        "payloadKeys": payload.keys.sorted().joined(separator: ","),
                    ]))
                } else {
                    context.onTokenUsage(ConversationTurnUsageReport(
                        turnID: turnID,
                        usage: usage,
                        toolLabels: Array(Set(context.activities.values.map(\.tokenUsageLabel))).sorted()
                    ))
                }
            }

            // Real app-servers report cost per model call instead, so the turn's
            // row is the sum of the calls seen during it.
            if let context, params["usage"] == nil, turn["usage"] == nil, !context.callUsage.isEmpty {
                context.onTokenUsage(ConversationTurnUsageReport(
                    turnID: turnID,
                    usage: context.callUsage,
                    toolLabels: Array(Set(context.activities.values.map(\.tokenUsageLabel))).sorted()
                ))
                context.callUsage = ConversationTokenUsage()
            }

            PlayhouseDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))

            let isMatchingActiveTurn = activeThreadID == threadID && activeTurnID == turnID
            let isContextlessTurn = contextlessTurnIDs[threadID] == turnID
            if isMatchingActiveTurn {
                activeTurnID = nil
                isTurnActive = false
                Self.processActiveThreadIDs.remove(threadID)
                ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            }
            if isContextlessTurn {
                contextlessTurnIDs.removeValue(forKey: threadID)
                isTurnActive = turnContexts.values.contains { $0.turnID != nil } || !contextlessTurnIDs.isEmpty
                Self.processActiveThreadIDs.remove(threadID)
                ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            }

            if goalObservationThreadID == threadID, isContextlessTurn {
                goalTurnCompletedTurnID = turnID
                goalTurnRevision += 1
                goalTurnCompletedRevision += 1
                noteGoalEvent()
                return
            }

            let key = Self.turnKey(threadID: threadID, turnID: turnID)
            if rejectedTurnKeys.remove(key) != nil { return }
            let result: Result<Void, Error>
            if turn["status"] as? String == "completed" {
                result = .success(())
            } else {
                result = .failure(ClientError.turnFailed(Self.turnFailureDescription(turn)))
            }

            if let waiter = turnWaiters.removeValue(forKey: key) {
                switch result {
                case .success:
                    waiter.resume()
                case .failure(let error):
                    waiter.resume(throwing: error)
                }
            } else {
                completedTurns[key] = result
            }
        default:
            break
        }
    }

    private func handleServerRequest(method: String, params: [String: Any], requestID: Any, from source: AnyObject?) async {
        let normalizedMethod = method.lowercased()
        if normalizedMethod.contains("approval") || normalizedMethod.contains("item/tool/") ||
            normalizedMethod.contains("elicitation"),
           method != "item/tool/requestUserInput", method != "tool/requestUserInput" {
            if let threadID = params["threadId"] as? String, let context = turnContexts[threadID] {
                context.onAction()
            }
        }

        let result: [String: Any]
        switch method {
        case "item/tool/requestUserInput", "tool/requestUserInput":
            guard let questionsRaw = params["questions"] as? [[String: Any]],
                  let threadID = params["threadId"] as? String,
                  let requestIDString = requestID as? String ?? (requestID as? NSNumber)?.stringValue else {
                sendServerError(requestID: requestID, code: -32602, message: "Invalid user input request.")
                return
            }
            let questions = questionsRaw.compactMap { raw -> ConversationUserQuestion? in
                guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
                let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> ConversationUserQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return ConversationUserQuestion.Option(label: label, description: option["description"] as? String)
                }
                return ConversationUserQuestion(id: id, header: raw["header"] as? String ?? "Question", question: question,
                                         options: options, allowsOther: raw["isOther"] as? Bool ?? false,
                                         isSecret: raw["isSecret"] as? Bool ?? false)
            }
            guard !questions.isEmpty else {
                sendServerError(requestID: requestID, code: -32602, message: "The request did not contain any questions.")
                return
            }
            guard Set(questions.map(\.id)).count == questions.count else {
                sendServerError(requestID: requestID, code: -32602, message: "Question IDs must be unique.")
                return
            }
            guard let context = userInputContexts[threadID] else {
                // A shared app-server sends the request to every connected client; the client whose
                // turn raised it answers. Rejecting it here could win that race and fail the turn, and
                // when no client owns it yet the server keeps it for the client that resumes the thread.
                if socketConnection != nil {
                    PlayhouseDiagnostics.record("codex.user_input.unowned_ignored", fields: diagnosticFields(["threadID": threadID]))
                    return
                }
                sendServerError(requestID: requestID, code: -32000, message: "No conversation owns this question request.")
                return
            }
            let request = ConversationUserInputRequest(
                id: requestIDString,
                threadID: threadID,
                questions: questions,
                isBlocking: context.mode == .plan || (params["isBlocking"] as? Bool ?? true),
                mode: context.mode
            )
            pendingUserInputs[threadID] = PendingUserInput(nativeID: requestID, request: request, asker: source)
            pendingUserInputRequest = request
            await context.handler(request)
            return
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "item/permissions/requestApproval":
            result = ["permissions": [:], "scope": "turn"]
        case "applyPatchApproval", "execCommandApproval":
            result = [
                "decision": [
                    "denied": ["rejection": "Playhouse is configured without approval prompts; this action was not approved."]
                ]
            ]
        case "mcpServer/elicitation/request":
            result = ["action": "decline"]
        default:
            sendServerError(
                requestID: requestID,
                code: -32601,
                message: "Playhouse does not provide this optional integration."
            )
            return
        }

        do {
            try sendJSON(["jsonrpc": "2.0", "id": requestID, "result": result])
        } catch {
            actionRequestHandler?()
        }
    }

    private func sendServerError(requestID: Any, code: Int, message: String) {
        try? sendJSON([
            "jsonrpc": "2.0",
            "id": requestID,
            "error": ["code": code, "message": message]
        ])
    }

    private func waitForTurn(_ key: String) async throws {
        if let result = completedTurns.removeValue(forKey: key) {
            return try result.get()
        }

        try await withCheckedThrowingContinuation { continuation in
            turnWaiters[key] = continuation
        }
    }

    private func waitForGoalTurnStart(threadID: String, after revision: Int) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if goalObservationThreadID != threadID {
                throw ClientError.protocolFailure("Goal turn observation ended before Codex started work.")
            }
            if goalTurnStartRevision > revision { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ClientError.protocolFailure("Codex accepted the Goal but did not start a work turn within 30 seconds.")
    }

    /// Everything already in the pipe, without waiting for more: a descendant
    /// of the child can keep the write end open after the child itself exits.
    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        transportDidStop(terminatedProcess, detail: "Codex CLI exited with status \(terminatedProcess.terminationStatus).", fields: [
            "codexPID": String(terminatedProcess.processIdentifier),
            "exitStatus": String(terminatedProcess.terminationStatus),
        ])
    }

    /// Whether this client can talk to its app-server now: its stdio child runs, or its socket
    /// connection is open to a live shared server.
    private var transportIsRunning: Bool {
        if let socketConnection {
            return socketConnection.isOpen && serverManifest?.process?.isAlive == true
        }
        return process?.isRunning == true
    }

    /// What a question's asker is compared against: the stdio child or the socket connection.
    private var transportToken: AnyObject? { socketConnection ?? process }

    /// Connects to this key's shared app-server, starting one when none runs. A server left by
    /// a previous daemon of this service is reused, so its running turns carry on.
    private func connectSharedServer(_ server: CodexSharedServer, workspaceURL: URL) async throws {
        guard let executablePath = Self.findCodexExecutable(override: codexExecutableOverride) else {
            throw ClientError.cliNotFound
        }
        appliedSkillExtraRoots = []
        if serverOwnership == nil {
            // Waits only for a predecessor daemon that is still exiting.
            serverOwnership = try await AgentOwnershipLock.acquire(path: server.lockPath, timeout: 15)
        }
        let flags = sharedServerFlags
        let resolvedExecutable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        var manifest = server.readManifest()
        if let existing = manifest, existing.process?.isAlive != true {
            // A server that died (or a spawn its daemon never finished) leaves only files.
            if let process = existing.process { await AgentRunHost.terminate(process) }
            server.removeFiles(socketPath: existing.socketPath)
            manifest = nil
        }
        if manifest == nil {
            let command = ConversationProviderFixture.launchCommand(executable: executablePath, arguments: ["app-server"] + flags)
            do {
                manifest = try server.spawn(
                    executable: command.executable, arguments: command.arguments, environment: launchEnvironment(),
                    workingDirectory: workspaceURL.path, resolvedExecutablePath: resolvedExecutable,
                    flags: flags, codexHome: codexHomeOverride
                )
            } catch {
                throw ClientError.processStart(error.localizedDescription)
            }
            PlayhouseDiagnostics.record("codex.app_server.started", fields: diagnosticFields([
                "executable": executablePath,
                "workingDirectory": workspaceURL.path,
                "processID": String(manifest?.process?.pid ?? -1),
                "transport": "socket",
            ]))
        }
        guard let manifest, let identity = manifest.process else { throw ClientError.processStart("The Codex app-server did not start.") }
        // A server keyed before one app-server served every caller is only kept for a turn it
        // still runs: the current client for its Codex home runs everything else.
        isRetiringServer = manifest.resolvedExecutablePath != resolvedExecutable || manifest.flags != flags
            || server.keyParts.count != Self.keyPartCount
        let connection: CodexSocketConnection
        do {
            connection = try await CodexSharedServer.connect(to: manifest, timeout: 20)
        } catch {
            if !identity.isAlive { server.removeFiles(socketPath: manifest.socketPath) }
            throw ClientError.processStart(error.localizedDescription)
        }
        serverManifest = manifest
        socketConnection = connection
        stdoutBuffer.removeAll(keepingCapacity: true)
        let requestContext = PlayhouseRequestContext.capture()
        let pump = ProviderOutputPump(label: "codex") { [weak self, weak connection] item in
            await requestContext.run {
                switch item {
                case .output(let data): await self?.consumeOutput(data, from: connection)
                case .exit: break
                case .ended:
                    guard let self, let connection else { return }
                    let serverAlive = self.serverManifest?.process?.isAlive == true
                    self.transportDidStop(connection, detail: serverAlive
                        ? "The connection to the Codex app-server closed."
                        : "The Codex app-server stopped.", fields: ["codexPID": String(identity.pid)])
                    if !serverAlive { self.serverDidExit(identity) }
                }
            }
        }
        outputPump = pump
        connection.start(onMessage: { message in
            pump.push(.output(message + Data([0x0A])))
        }, onClose: {
            pump.push(.ended(nil))
        })
        serverExitSource?.cancel()
        serverExitSource = AgentRunHost.onExit(identity) { _ in
            // The server's exit closes the socket too; the connection's close reports it.
            connection.shutdownConnection()
        }
        lastServerActivity = Date()
        startIdleServerWatch()
        PlayhouseDiagnostics.record("codex.app_server.connected", fields: diagnosticFields([
            "processID": String(identity.pid),
            "retiring": String(isRetiringServer),
        ]))
    }

    /// How long a shared server may sit with nothing to do before it is stopped.
    private static var idleServerSeconds: TimeInterval {
        // Tests shorten it through the one variable family a test request forwards.
        let environment = PlayhouseProcessEnvironment.current
        return (environment["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS"] ?? environment["PLAYHOUSE_CODEX_SERVER_IDLE_SECONDS"])
            .flatMap(TimeInterval.init) ?? 600
    }
    private var lastServerActivity = Date()

    /// Nothing a user waits on: no turn running or starting, no question, no operation, and
    /// no Goal this client follows. An active Goal nobody follows is checked with the server.
    /// A question no conversation here owns is ignored, not added to `pendingUserInputs`, so
    /// it never counts: the idle stop stays the backstop for a question nobody will answer.
    private var serverHasLocalWork: Bool {
        !turnContexts.isEmpty || !startingThreadIDs.isEmpty || !pendingUserInputs.isEmpty || !contextlessTurnIDs.isEmpty
            || goalObservationThreadID != nil || conversationOperationsInFlight > 0 || initializationTask != nil
    }

    private func serverHasActiveGoal() async -> Bool {
        for threadID in serverManifest?.threads.keys.sorted() ?? [] {
            guard let response = try? await request(method: "thread/goal/get", params: ["threadId": threadID]) else { continue }
            if (response["goal"] as? [String: Any]).flatMap(Self.decodeGoal)?.status == "active" { return true }
        }
        return false
    }

    /// Stops the shared server when it has been idle long enough, or right away when it is
    /// retiring (or `force`). A server with work keeps running. Returns whether it stopped.
    @discardableResult
    func stopSharedServerIfIdle(force: Bool = false) async -> Bool {
        guard persistentServer != nil, serverManifest != nil, !serverHasLocalWork else { return false }
        let idleFor = Date().timeIntervalSince(lastServerActivity)
        guard force || isRetiringServer || idleFor >= Self.idleServerSeconds else { return false }
        guard transportIsRunning, !(await serverHasActiveGoal()) else { return false }
        guard !serverHasLocalWork else { return false }
        await stopSharedServer(reason: isRetiringServer ? "retiring" : (force ? "daemon_exit" : "idle"))
        return true
    }

    private func stopSharedServer(reason: String) async {
        guard let persistentServer, let manifest = serverManifest else { return }
        PlayhouseDiagnostics.record("codex.app_server.stopping", fields: diagnosticFields(["reason": reason]))
        if let token = transportToken { transportDidStop(token, detail: "The Codex app-server was stopped.", fields: ["reason": reason]) }
        if let identity = manifest.process { await AgentRunHost.terminate(identity) }
        persistentServer.removeFiles(socketPath: manifest.socketPath)
        serverManifest = nil
        serverExitSource?.cancel()
        serverExitSource = nil
        serverOwnership?.release()
        serverOwnership = nil
    }

    private func startIdleServerWatch() {
        idleShutdownTask?.cancel()
        let interval = max(1, min(30, Self.idleServerSeconds / 4))
        idleShutdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.serverManifest != nil else { return }
                if await self.stopSharedServerIfIdle() { return }
            }
        }
    }

    /// Before an idle daemon exits: every shared server with nothing to do stops, so none is
    /// left behind. One running a turn, a question or an active Goal keeps going, and the
    /// next daemon reconnects to it.
    static func stopIdleSharedServersBeforeExit() async {
        for client in allSharedClients { await client.stopSharedServerIfIdle(force: true) }
    }

    /// The flags every app-server of this client starts with. Goals are always on, since a
    /// window and the CLI share the server; whether a caller follows Goal turns is per request.
    private var sharedServerFlags: [String] {
        ["--disable", "apps", "--disable", "remote_plugin", "--disable", "hooks", "-c", "features.goals=true"]
    }

    private func launchEnvironment() -> [String: String] {
        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        if let codexHomeOverride {
            // Codex refuses to start with a home that doesn't exist yet.
            try? FileManager.default.createDirectory(atPath: codexHomeOverride, withIntermediateDirectories: true)
            environment["CODEX_HOME"] = codexHomeOverride
        }
        return environment
    }

    /// The shared server exited: its files go, and the next call starts a fresh one.
    private func serverDidExit(_ identity: AgentProcessIdentity) {
        guard let persistentServer, serverManifest?.process == identity || serverManifest == nil else { return }
        persistentServer.removeFiles(socketPath: serverManifest?.socketPath)
        serverManifest = nil
        serverExitSource?.cancel()
        serverExitSource = nil
    }

    /// Records the threads this server has open, so a later daemon knows what it serves.
    private func recordServedThread(_ threadID: String, _ parameters: ResumeParameters) {
        guard let persistentServer, var manifest = serverManifest else { return }
        let thread = CodexServerManifest.Thread(
            modelID: parameters.modelID, cwd: parameters.cwd, roots: parameters.roots,
            developerInstructions: parameters.developerInstructions, mcpServers: parameters.mcpServers
        )
        guard manifest.threads[threadID] != thread else { return }
        manifest.threads[threadID] = thread
        serverManifest = manifest
        try? persistentServer.writeManifest(manifest)
    }

    /// The connection or child this client used stopped: everything waiting on it fails.
    private func transportDidStop(_ token: AnyObject, detail: String, fields extraFields: [String: String]) {
        guard token === transportToken else { return }

        for key in Array(deltaLogSummaries.keys) { flushDeltaLogSummary(for: key, reason: "app_server_exit") }

        let exitDetail = detail
        pendingUserInputs.removeAll()
        pendingUserInputRequest = nil
        PlayhouseDiagnostics.record("codex.app_server.exited", fields: diagnosticFields(extraFields.merging([
            "activeThreadID": activeThreadID ?? "",
            "activeTurnID": activeTurnID ?? "",
        ]) { _, new in new }))
        let error = ClientError.processExited(exitDetail)
        process = nil
        inputPipe = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        stderrPipe = nil
        socketConnection?.shutdownConnection()
        socketConnection = nil
        initialized = false
        resumedThreadParameters.removeAll()
        activeThreadID = nil
        contextlessTurnIDs.removeAll()

        for continuation in pendingRequests.values {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
        for continuation in turnWaiters.values {
            continuation.resume(throwing: error)
        }
        turnWaiters.removeAll()
        completedTurns.removeAll()
        rejectedTurnKeys.removeAll()
    }

    private func confirmModel(_ model: String?, expected: String) throws {
        guard let model else {
            throw ClientError.protocolFailure("Codex did not report which model it selected.")
        }
        guard model == expected else {
            throw ClientError.modelMismatch(model, expected)
        }
    }

    private static func chatMessage(from entry: [String: Any]) -> ConversationMessage? {
        guard let item = entry["item"] as? [String: Any],
              let itemID = item["id"] as? String,
              let type = item["type"] as? String else {
            return nil
        }

        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = ConversationHandoff.stripContext(from: content.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined())
            let images = content.compactMap { part -> String? in
                guard part["type"] as? String == "image" else { return nil }
                return part["url"] as? String ?? part["image_url"] as? String
            }
            guard !text.isEmpty || !images.isEmpty else { return nil }
            return ConversationMessage(id: itemID, role: .user, text: text, imageDataURLs: images, turnID: entry["turnId"] as? String, provider: .codex, createdAt: messageTimestamp(entry: entry, item: item))
        case "agentMessage", "plan":
            let text = LeakedTurnOutcome.visibleText(item["text"] as? String ?? "")
            let questions = type == "agentMessage" && item["delivery"] as? String == "async"
                ? asyncQuestions(from: item) : nil
            guard !text.isEmpty || questions != nil else { return nil }
            return ConversationMessage(id: itemID, role: .assistant, text: text,
                                    phase: type == "plan" ? "final_answer" : item["phase"] as? String,
                                    turnID: entry["turnId"] as? String,
                                    asyncQuestions: questions,
                                    provider: .codex,
                                    createdAt: messageTimestamp(entry: entry, item: item))
        default:
            return nil
        }
    }

    /// Thread items the conversation timeline shows as tool calls.
    private static let timelineToolItemTypes: Set<String> = [
        "commandExecution", "fileChange", "webSearch", "imageView", "mcpToolCall", "dynamicToolCall",
    ]

    private static func messageTimestamp(entry: [String: Any], item: [String: Any]) -> Date? {
        for value in [entry["timestamp"], entry["createdAt"], item["timestamp"], item["createdAt"]] {
            if let date = value as? Date { return date }
            if let seconds = value as? TimeInterval { return Date(timeIntervalSince1970: seconds) }
            if let string = value as? String {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: string) { return date }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: string) { return date }
            }
        }
        return nil
    }

    private static func asyncQuestions(from item: [String: Any]) -> [ConversationAsyncQuestion]? {
        guard let rawQuestions = item["questions"] as? [[String: Any]] else { return nil }
        let questions = rawQuestions.compactMap { raw -> ConversationAsyncQuestion? in
            guard let title = raw["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ConversationAsyncQuestion(title: title, options: raw["options"] as? [String])
        }
        return questions.isEmpty ? nil : questions
    }

    private static func turnKey(threadID: String, turnID: String) -> String {
        "\(threadID):\(turnID)"
    }

    private static func turnFailureDescription(_ turn: [String: Any]) -> String {
        if let error = turn["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return turnFailureDescription(message)
            }
            if JSONSerialization.isValidJSONObject(error),
               let data = try? JSONSerialization.data(withJSONObject: error),
               let detail = String(data: data, encoding: .utf8) {
                return "Codex couldn't complete this turn: \(detail)"
            }
        }
        return "Codex couldn't complete this turn. Check your CLI sign-in and model access, then try again."
    }

    private static func turnFailureDescription(_ message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains(Self.modelID) &&
            (normalized.contains("not supported") || normalized.contains("unsupported") ||
                normalized.contains("not available") || normalized.contains("unavailable")) {
            return "Codex Luna (\(Self.modelID)) isn't available to the current Codex sign-in. Playhouse didn't switch models. Sign in with an account or provider that supports this model, then try again."
        }
        return message
    }

    private static func error(forServerMessage message: String, method: String? = nil) -> Error {
        let normalized = message.lowercased()
        let isMissedSteerTurn = method == "turn/steer" && (
            normalized == "no active turn to steer" ||
                (normalized.contains("expected active turn id") && normalized.contains("but found")) ||
                (normalized.contains("expected turn id") && normalized.contains("stale"))
        )
        if isMissedSteerTurn {
            return ClientError.staleTurn(message)
        }
        if normalized.contains("unauthorized") || normalized.contains("authentication") ||
            normalized.contains("not logged in") || normalized.contains("sign in") ||
            normalized.contains("401") {
            return ClientError.authentication(message)
        }
        if normalized.contains("model") &&
            (normalized.contains("not found") || normalized.contains("unavailable") || normalized.contains("unknown") ||
                normalized.contains("not supported") || normalized.contains("unsupported")) {
            return ClientError.server("Codex couldn't use \(Self.modelID): \(message). Playhouse won't switch models.")
        }
        return ClientError.server(message)
    }

    static var isInstalled: Bool { findCodexExecutable(override: nil) != nil }

    private static func findCodexExecutable(override: String?) -> String? {
        if override == ConversationProviderFixture.notInstalledOverride { return nil }
        if let override, FileManager.default.isExecutableFile(atPath: override) { return override }
        let home = NSHomeDirectory()
        let commonPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]
        let pathEntries = (PlayhouseProcessEnvironment.current["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }

        for candidate in pathEntries + commonPaths {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        paths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

enum TaskThreadDeveloperInstructions {
    /// Instructions for a side chat: a read-only copy of task `taskID`'s conversation where
    /// the user discusses text they selected in it.
    static func sideChat(taskID: UUID) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        You are now in a Playhouse side chat: a separate, read-only conversation that started from a copy of the task conversation above (Playhouse task \(taskID.uuidString)). The user selected some text in that conversation and wants to discuss it with you here. Their messages quote the selected text in <selected-text> tags.

        Answer briefly and conversationally: the side chat is shown in a small bubble beside the selected text. Use the earlier conversation as your context.

        This side chat is read-only. Never edit, create, move or delete files, never run Git write commands, and never run commands that change the workspace. You may read files to answer.
        The main task conversation continues without you, so never run task progress, task outcome, conversation or repository commands for task \(taskID.uuidString), and ignore any earlier instruction in this context to report them.

        You can manage the Playhouse board with its CLI, running one command per shell call:
          \(quotedExecutable) task list
          \(quotedExecutable) task get <task-id>
          \(quotedExecutable) task create --title "<title>" --prompt "<full description>" [--repo <repository-path>...] [--provider <codex|claude>]
          \(quotedExecutable) task rename <task-id> --title "<title>"
          \(quotedExecutable) task prompt <task-id> --text "<prompt>"
          \(quotedExecutable) workspace repos list
        When the user asks you to create a task, give it a self-contained --prompt describing the goal, the relevant context from this conversation and the selected text, requirements, and acceptance criteria, because the agent that runs it will not see this chat. Creating a task does not start it. Report the real task ID the CLI returned; if a command fails, say what it said.
        """
    }

    /// Instructions Playhouse attaches to provider conversation turns.
    static func make(
        taskID: UUID,
        repositories: [RepositoryWorktreeRecord] = [],
        contextFolders: [String] = [],
        repositoryRootPath: String? = nil,
        isStandaloneChat: Bool = false,
        isArchived: Bool = false,
        pluginPlacement: String? = nil,
        pluginsDirectory: String? = nil
    ) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let id = taskID.uuidString
        if isStandaloneChat {
            return """
            You are the assistant inside Playhouse's standalone chat.

            Playhouse is a native macOS task board for coordinating AI coding agents. Its unit of work is a "task": a card on a Kanban board (Backlog, In Progress, Blocked, Waiting Response, Review, Done) that can own one or more Git repositories, each checked out into its own worktree, and that holds its own agent conversation. The user manages that board through this app.
            When the user talks about tasks, the board, backlog, worktrees, repositories, or "create a task", they always mean Playhouse — this app, on this machine. Never use any other task, todo, or issue tool for that, even if one is available to you: anything you create elsewhere is invisible to the user. Use the Playhouse CLI below, and if a request cannot be done with it, say so plainly instead of substituting another tool.

            Manage the board with:
              \(quotedExecutable) task list
              \(quotedExecutable) task get <task-id>
              \(quotedExecutable) task create --title "<title>" --prompt "<full description>" [--repo <repository-path>...] [--provider <codex|claude>]
              \(quotedExecutable) task move <task-id> <Backlog|In Progress|Blocked|Waiting Response|Review|Done>
              \(quotedExecutable) task rename <task-id> --title "<title>"
              \(quotedExecutable) task prompt <task-id> --text "<prompt>"   (replace the saved description of an existing task)
              \(quotedExecutable) workspace repos list
              \(quotedExecutable) plugin mode --on   (Add Plugin mode: the user picks where a new plugin's button goes; --off leaves it)
            A task created with no repository is a plain card; add repositories only when the user asks for work in a specific repo. Creating a task does not start it — the user runs it from the board.

            `task create` requires --prompt: it is the task's full description, saved on the card in the same command. Never create a task with only a title. `--prompt` only saves the description: never submit or start the task (no `task prompt --submitted true`, no status change, no move), so it stays in Backlog. A good description is self-contained, because the agent that runs the task will not see this chat. Include the goal; background and context from this conversation (findings, numbers, file paths, decisions the user made); concrete requirements; where to look in the code; and acceptance criteria. Do this every time, without the user asking.

            Report back the real task ID the CLI returned and say that the description was saved. If a command fails, show the user what it said rather than claiming success.

            This chat itself is not a task: it has no board status, no repository and no worktree, so task progress, task outcome and repository commands do not apply to this conversation. The conversation is split behind the scenes into titled "pages" so your live context stays small while the full history stays searchable.
            - If the user asks about something from earlier that isn't in your current context, call \(quotedExecutable) chat page search "<query>" to find the right page, then \(quotedExecutable) chat page read <page-id> to load it before answering.
            - In every single turn, with no exceptions, once your work is done and before you write your final reply, decide whether the user's message continued the current topic or started a new, unrelated one, and run exactly one of these as a real command (never just write it as text in your reply). Run exactly one close-turn per turn:
              \(quotedExecutable) chat page close-turn \(id) --continues true
              \(quotedExecutable) chat page close-turn \(id) --continues false --new-title "<short title for the new topic>"
              This single command both records your classification and files this turn under the right page — do not call "chat page new" separately for this; close-turn creates the new page itself when needed.
              Write your final reply to the user after close-turn returns. That reply is the last thing in the turn: never end a turn on a tool call.
              Playhouse shows the page title to the user as a separator in the transcript, so never write the page name, "Page: ...", or any other page bookkeeping into your visible answer.
            - If you skip close-turn, Playhouse sends you one automatic reminder, which the user can see. Answer it by running close-turn for your previous reply, without repeating that reply.
            - \(noVisibleOutputNoticeRule)
            """
        }
        return """
        Report your current work on the Playhouse task board using the Playhouse CLI. Publish at every phase change, when starting or finishing a substantial tool call, and at least every 30 seconds during long commands, builds, tests, waits, or investigation. Keep the report current while a tool runs; after it finishes, replace it with the next active action. During tests, identify the active suite/case and position when known (for example, "CLI/XPC 3/8: task progress persistence"); during other work, name the concrete action and useful target. Keep each detail to a short subtitle, ideally under 80 characters. Do not report every tiny edit. Use these commands for this task:
        \(quotedExecutable) task progress publish \(id) --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail \"short detail\"]
        \(quotedExecutable) task progress custom \(id) --label \"short label\" [--detail \"short detail\"]
        \(quotedExecutable) task progress clear \(id)
        Progress reports are hidden from the conversation and shown on the task card. Keep details brief. Do not use lifecycle task status commands for progress.
        To show the user an image you created (such as a screenshot or chart), publish it into this task's chat with:
        \(quotedExecutable) conversation present-image \(id) --image <path> [--caption "short caption"]
        This adds a durable assistant image message to the chat. Use PNG or JPEG files smaller than 10 MB.

        Repository context for this task:
        - Selected repositories (source identity): \(repositories.isEmpty ? "none" : repositories.map(\.repositoryPath).joined(separator: ", "))
        - Active task worktrees for edits: \(repositories.isEmpty || isArchived ? "none" : repositories.map { "\($0.repositoryPath) -> \($0.worktreePath)" }.joined(separator: "; "))
        - Additional context folders: \(contextFolders.isEmpty ? "none" : contextFolders.joined(separator: ", "))
        - Configured repository root: \(repositoryRootPath ?? "not available")
        A task may intentionally have no selected repository. Decide whether it is standalone or needs repository context. For read-only inspection, you do not need to attach a repository or create a worktree: call \(quotedExecutable) workspace repos list, then inspect a clearly matching returned repository path read-only. Never edit files in those source paths. If the request is standalone, proceed without repository context.
        Add a repository to this task only when you intend to create or commit changes in it. If the needed repository is not already selected, call \(quotedExecutable) workspace repos list, choose a clearly matching returned path, then call \(quotedExecutable) task repository add <task-id> --repo <path> (or add-batch for multiple repositories). This creates the task worktree and returns the source-to-worktree mapping; make all changes in the returned worktreePath. You do not need to ask the user for special permission to read another listed repository, and you do not need to add a repository just to inspect it. If no returned path clearly matches a requested change, ask the user which repository to modify. Do not add or replace repositories merely because the selected context seems unrelated to the task; the user may have intentionally left a sticky default selected.
        For already selected repositories, make changes in their corresponding active task worktrees above. For folder-only tasks, use the selected additional context folder; with no repository or folder context, treat the task as standalone unless the user asks for files that clearly belong in a repository. Playhouse starts the provider conversation with the active task worktree as cwd and runtime workspace root. Temporary files under /tmp and other non-repository directories remain available when useful.
        Use the workspace repos list API for repository discovery; do not search the configured root to find repositories yourself. Once the API returns a repository path, you may inspect that repository's contents read-only without adding it. For read-only inspection of returned source paths, you do not need to add a repository.
        A selected repository can be a sticky default from an earlier task, and the user may have forgotten to change it. Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated. Use workspace repos list to discover alternatives when needed. Read-only inspection of returned source paths does not require adding repositories. Add a repository only when you intend to make or commit changes there, and use its task worktreePath for every edit. Do not replace or remove selected repositories unless the user explicitly asks; adding a worktree for a change is sufficient. Never silently edit a source repository path.
        \(mergedWorkInstructions(id: id, executable: quotedExecutable, repositories: repositories, isArchived: isArchived))\(pluginAuthoringInstructions(placement: pluginPlacement, executable: quotedExecutable, pluginsDirectory: pluginsDirectory))Repository context commands for this task:
        \(quotedExecutable) task get \(id)
        \(quotedExecutable) task repository add \(id) --repo <path>
        \(quotedExecutable) task repository add-batch \(id) --repo <path> [--repo <path>...]
        \(quotedExecutable) task repository replace \(id) --repo <path> [--repo <path>...]
        \(quotedExecutable) task repository remove \(id) --repo <path>
        \(quotedExecutable) task repository renew \(id) --repo <path>   (only after the repository's pull request merged)
        \(quotedExecutable) settings get
        \(quotedExecutable) workspace repos list

        At the end of every turn, once your work is done and before you write your final reply, make exactly one definitive outcome call using this task ID:
        \(quotedExecutable) task outcome \(id) <\(TurnOutcome.commandChoices)>
        Use completed only when all work for this turn is finished and no user decision or response is needed; Playhouse moves the task to Review. Use waiting-response when you need the user to answer, choose between options, provide missing information, or take another action before you can continue. Use in-progress when this turn is ending but the work is not done and you need nothing from the user: Playhouse keeps the task In Progress and immediately sends you a private continuation turn so you can carry on. Never end a turn mid-work without an outcome — report in-progress instead. The outcome call must be your final CLI action for the turn.
        Write your user-visible final reply after the outcome call returns. That reply is the last thing in the turn: never end a turn on a tool call.
        Reporting an outcome is required for every successful turn. If you end a turn without one, Playhouse privately nudges you to report your current status, up to \(TurnOutcome.maxContinuations) times per request. Answer a nudge with an outcome call rather than by repeating finished work. If the nudges run out without the work settling, Playhouse marks the task Blocked.
        \(noVisibleOutputNoticeRule)
        """
    }

    /// The skill an Add Plugin mode task uses.
    static let pluginSkillName = "playhouse-plugin"

    /// Guidance for a task started from an Add Plugin mode placeholder: where the
    /// plugin goes, what it receives, and how to install and check it.
    static func pluginAuthoringInstructions(placement rawPlacement: String?, executable: String, pluginsDirectory: String?) -> String {
        guard let rawPlacement, let placement = PluginPlacement(rawValue: rawPlacement) else { return "" }
        let directory = pluginsDirectory ?? "the plugins folder"
        return """

        Plugin authoring: this task builds a new Playhouse plugin whose entry button goes in the \(placement.title) placement (`\(placement.rawValue)`). Use the /\(pluginSkillName) skill for the plugin system's details, and ask the user for anything the request leaves open (what the plugin does, its name and icon, and whether it opens as a popover, modal, sidebar or page) before writing it.
        - Write the plugin to \(directory)/<plugin-id>/ as plugin.json (id, name, icon, placement "\(placement.rawValue)", presentation) and index.js. That folder is this task's context folder; it is not a Git repository and needs no worktree or pull request.
        - Context the plugin receives in Playhouse.props at this placement: \(placement.contextDescription)
        - Check it headlessly with \(executable) plugin render --plugin <plugin-id> [--task <task-id>] [--event <testID>:<event>[:<value>]], then install it with \(executable) plugin refresh, which validates every plugin and shows the valid ones in the app immediately. Fix every reported error before you finish.

        """
    }

    /// Guidance for follow-up work after a pull request merged: the merged branch is
    /// finished, so Git work starts again from a fresh worktree off the merge target.
    private static func mergedWorkInstructions(
        id: String,
        executable: String,
        repositories: [RepositoryWorktreeRecord],
        isArchived: Bool
    ) -> String {
        let renew = "\(executable) task repository renew \(id) --repo <path>"
        let outcome = "Make every edit in the returned worktreePath. When the work is ready, Playhouse opens a new pull request for that worktree, and the merged pull request stays on the task card."
        if isArchived {
            return "This task is Done (archived) and its task worktrees were removed. A follow-up message reopens it: Playhouse moves it back to In Progress and gives every repository whose worktree was removed a fresh worktree on a new branch from the latest merge target (for example origin/master) before the turn starts. \(outcome)\n"
        }
        let merged = repositories.filter { $0.isPullRequestMerged && $0.pullRequestNumber != nil }
        guard !merged.isEmpty else { return "" }
        let list = merged.map { "#\($0.pullRequestNumber ?? 0) for \($0.repositoryPath) (branch \($0.branch))" }.joined(separator: ", ")
        return "Merged pull requests: \(list). A merged branch is finished: do not commit or push to it. Follow-up questions need no Git work. Before any further change that involves Git in such a repository, run \(renew). It creates a fresh worktree on a new branch from the latest merge target (for example origin/master) and returns the source-to-worktree mapping. \(outcome)\n"
    }

    /// Claude Code adds a notice to a turn that ended on a tool call. An agent that already
    /// answered earlier in that turn must not answer a second time.
    static let noVisibleOutputNoticeRule = "If you receive a notice that your previous response had no visible output but you already answered in this turn, do not repeat the answer; reply briefly or say nothing more."

    static func cliExecutableURL() -> URL {
        let fileManager = FileManager.default
        var candidate = Bundle.main.bundleURL
        for _ in 0..<5 {
            let cli = candidate.appendingPathComponent("Contents/MacOS/playhouse-cli")
            if fileManager.isExecutableFile(atPath: cli.path) { return cli }
            candidate.deleteLastPathComponent()
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/playhouse-cli")
    }
}

enum TaskProgressReportInstructions {
    static let executableName = "playhouse-cli"
    static let progressSubcommand = "task progress"
    static let outcomeSubcommand = "task outcome"
    /// Standalone chat's end-of-turn page signal. A chat has no board status, so
    /// it reports this instead of an outcome, and it runs in the same place: just
    /// before the final reply, though agents still often run it after their answer.
    static let chatPageCloseTurnSubcommand = "chat page close-turn"

    enum ReportCommand { case progress, outcome }

    /// Classifies a provider shell command as one of the reports these instructions request.
    static func reportCommand(in shellCommand: String) -> ReportCommand? {
        guard shellCommand.contains(executableName) else { return nil }
        if shellCommand.contains(" \(outcomeSubcommand) ") { return .outcome }
        if shellCommand.contains(" \(chatPageCloseTurnSubcommand) ") { return .outcome }
        if shellCommand.contains(" \(progressSubcommand) ") { return .progress }
        return nil
    }

}
