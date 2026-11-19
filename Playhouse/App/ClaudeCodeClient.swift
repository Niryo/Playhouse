import Combine
import Darwin
import Foundation

/// Native capabilities a provider reports for a workspace, shown when a task
/// switches providers. Playhouse reads each provider's own configuration and
/// never copies settings or credentials between them.
struct ConversationProviderCapabilities: Codable, Equatable {
    struct MCPServer: Codable, Equatable {
        let name: String
        let status: String
    }

    let provider: ConversationProvider
    var isAvailable: Bool
    var version: String?
    var skills: [String] = []
    var subagents: [String] = []
    var mcpServers: [MCPServer] = []
    var supportsGoals: Bool
    var notes: [String] = []
    var error: String?
}

/// One `claude -p` process with file-backed stdio that outlives the daemon that started it.
/// Its stdin is a FIFO the process itself also holds open, so it never reads end of input while
/// no daemon is writing; stdout and stderr go to append-only files the daemon tails. The run's
/// manifest records how far the log was handled and which requests were answered, so the next
/// daemon of the service picks the turn up where this one left it.

/// Owns the Claude Code CLI process for one turn of one session.
///
/// Claude Code starts a fresh process per turn and resumes a conversation by
/// session ID, so every Playhouse conversation can run its own process with its
/// own worktree as the working directory. All per-turn protocol state lives
/// here rather than on the client, which is what lets separate conversations
/// run at the same time without a shared turn slot.

/// Runs Claude Code turns through the installed `claude` executable using its
/// documented streaming JSON protocol (`--input-format stream-json` /
/// `--output-format stream-json`), the same transport the Claude Agent SDK
/// wraps.
///
/// Each conversation gets its own `ClaudeSessionRunner`, so turns for different
/// conversations run as independent CLI processes in their own worktrees at the
/// same time. The client only routes by session ID and publishes aggregate
/// state for the UI; it never serializes turns.
@MainActor
final class ClaudeCodeClient: ObservableObject, ConversationProviderClient {
    nonisolated static let defaultModelID = "default"
    /// The model family Playhouse prefers when the user hasn't picked one, so new
    /// conversations default to Sonnet rather than whatever Claude Code's own
    /// account-level default currently resolves to.
    nonisolated static let preferredDefaultModelID = "sonnet"
    nonisolated static let titleModelID = "haiku"
    /// The first Claude Code release Playhouse verified for active-turn steering
    /// (`priority: "next"`) and command lifecycle events.
    nonisolated static let minimumVersion = "2.1.296"
    nonisolated static let executionInstruction = """
        Run shell commands in the foreground or with the Bash tool's run_in_background, and run Agent/Task calls in the foreground or in the background, whichever suits the work. Never detach a process with & or nohup: Playhouse tracks background work only through the Bash and Agent tools. Playhouse keeps the task running while background shells or agents are outstanding and you are woken when each one finishes, so after launching them you can end your response instead of waiting; never poll or loop on a condition that cannot become true. Report the task outcome only after you have handled every background result.
        """

    let provider = ConversationProvider.claude
    static var processActiveSessionIDs = Set<String>()
    /// Session-to-runner routing for this process, so steering, interrupts, and
    /// answers reach the right turn no matter which client started it.
    static var activeRunnersBySessionID: [String: ClaudeSessionRunner] = [:]
    static var sharedPrimaryClients: [String: ClaudeCodeClient] = [:]

    @Published var isTurnActive = false
    /// Every conversation with a running turn. A view observes this instead of
    /// `isTurnActive` so one conversation's turn ending is still an observable
    /// change while another conversation keeps running.
    @Published var activeThreadIDs: Set<String> = []
    @Published var pendingUserInputRequest: ConversationUserInputRequest?

    var isPreparingForApplicationTermination = false

    enum ClientError: LocalizedError {
        case cliNotFound
        case processStart(String)
        case processExited(String)
        case protocolFailure(String)
        case authentication(String)
        case unsupportedVersion(String)
        case turnFailed(String)
        case sessionNotFound

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "Claude Code wasn't found. Install Claude Code or add `claude` to PATH, then restart Playhouse."
            case .processStart(let detail):
                "Playhouse couldn't start Claude Code: \(detail)"
            case .processExited(let detail):
                "Claude Code stopped unexpectedly. \(detail)"
            case .protocolFailure(let detail):
                "Playhouse couldn't communicate with Claude Code: \(detail)"
            case .authentication(let detail):
                "Claude Code needs a valid sign-in. Run `claude` in Terminal and sign in, then try again. \(detail)"
            case .unsupportedVersion(let version):
                "Claude Code \(version) is too old for Playhouse. Update to \(ClaudeCodeClient.minimumVersion) or later (`claude update`), then try again."
            case .turnFailed(let detail):
                detail
            case .sessionNotFound:
                "Claude Code couldn't find this conversation's session."
            }
        }
    }

    let executableOverride: String?
    var loginProcess: Process?
    let configDirectoryOverride: String?
    let persistsSessions: Bool
    /// This instance's own resolved data directory, fixed at construction time
    /// (debug/test builds only; always `nil` in production). Forwarded by each
    /// `ClaudeSessionRunner` into its own child process instead of an ambient
    /// global, so a different client instance's concurrently-resolved
    /// directory can never leak into this one's child process environment.
    let dataDirectoryOverride: String?
    /// The data directory this client serves (debug/test isolation); nil in production.
    var runtimeScope: String? { dataDirectoryOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
    var runners: [String: ClaudeSessionRunner] = [:]
    var runsDirectory: URL?
    var newSessionIDs = Set<String>()
    var forkSourceSessionIDs: [String: String] = [:]
    /// The trigger of the `/compact` turn `compactSession` is about to run, by session.
    var requestedCompactionTriggers: [String: ContextCompactionTrigger] = [:]
    var startingSessionIDs = Set<String>()
    var interruptedThreadIDs = Set<String>()
    /// The staged stopping outcome of each session's running turn, as its owner exposes it.
    var stoppingOutcomeProbes: [String: ProviderStoppingOutcomeProbe] = [:]
    /// The process and turn identity each conversation last ran under, so a
    /// failure recorded after the runner is torn down still names its own turn.
    var lastTurnDiagnosticsByThread: [String: [String: String]] = [:]
    var activityDurationsByThread: [String: [String: Int]] = [:]
    var lastFinishedThreadID: String?
    var conversationOperationsInFlight = 0
    static let bundledSkillsLifetime: TimeInterval = 10 * 60
    var bundledSkillsCache: (readAt: Date, skills: [(name: String, description: String)])?
    /// The plan usage read in flight, and whether another was asked for meanwhile.
    var planUsageRead: Task<Void, Never>?
    var planUsageReadQueued = false
    static let planUsageReadTimeout: Duration = .seconds(15)

    /// `dataDirectory` only ever varies across calls in debug/test builds (via
    /// `BridgeRequest.dataDirectory`); production always passes `nil`, so one
    /// real app only ever has one entry here. It's part of the cache key so
    /// that the bridge daemon — now a single long-lived process that can serve
    /// many isolated test data directories in sequence or concurrently — gives
    /// each one its own client (and thus its own child process with correctly
    /// scoped environment forwarding) instead of silently sharing one across
    /// directories that happen to share a process.
    /// Where Claude Code keeps its sessions: the override Playhouse launches it
    /// with, else the user's own configuration directory.
    var configDirectory: String {
        Self.configDirectory(override: configDirectoryOverride)
    }

    static func configDirectory(override: String?) -> String {
        override
            ?? PlayhouseProcessEnvironment.current["CLAUDE_CONFIG_DIR"]
            ?? NSHomeDirectory() + "/.claude"
    }

    static func sharedPrimaryClient(executableOverride: String?, configDirectoryOverride: String? = nil, dataDirectory: String? = nil, runDirectory: URL? = nil) -> ClaudeCodeClient {
        let key = [
            executableOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "__default__",
            dataDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "",
            configDirectoryOverride ?? "",
        ].joined(separator: "\u{1}")
        if let client = sharedPrimaryClients[key] { return client }
        let client = ClaudeCodeClient(executableOverride: executableOverride, configDirectoryOverride: configDirectoryOverride, dataDirectory: dataDirectory)
        // A daemon's shared client runs each turn with file-backed stdio beside its store, so the
        // turn outlives the daemon. Other clients keep piped children that end with them.
        client.runsDirectory = runDirectory.map { ClaudeRunFiles.runsDirectory(dataDirectory: $0) }
        sharedPrimaryClients[key] = client
        return client
    }

    init(
        executableOverride: String? = nil,
        configDirectoryOverride: String? = nil,
        persistsSessions: Bool = true,
        dataDirectory: String? = nil
    ) {
        self.executableOverride = ConversationProviderFixture.ownedExecutable(
            executableOverride,
            providerMarker: (".playhouse-claude-fixture-owner", "Playhouse test owns this Claude Code protocol fixture (v1).\n")
        )
        self.configDirectoryOverride = configDirectoryOverride
        self.persistsSessions = persistsSessions
        self.dataDirectoryOverride = dataDirectory
    }

    static func markProcessActive(sessionID: String) { processActiveSessionIDs.insert(sessionID) }

    static func clearProcessActive(sessionID: String) { processActiveSessionIDs.remove(sessionID) }

    /// Republishes the state the UI observes after any runner changes.
    func runnerStateChanged(_ runner: ClaudeSessionRunner) {
        let active = runners.values.filter { $0.isTurnActive }
        activeThreadIDs = Set(active.map(\.sessionID))
        isTurnActive = !active.isEmpty
        pendingUserInputRequest = runners.values.compactMap(\.pendingUserInputRequest).first
    }

    /// Client-wide fields only. With parallel turns there is no single active
    /// process or turn to report; `diagnosticFields(forThread:)` describes one.
    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["provider"] = provider.rawValue
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["isTurnActive"] = String(isTurnActive)
        fields["activeTurnCount"] = String(activeThreadIDs.count)
        return fields
    }

    /// Describes the conversation's own turn, so a failure record never carries
    /// another conversation's process or turn identity. A turn that has already
    /// torn down its process is described by the identity it ran under, which is
    /// what a failure record needs.
    func diagnosticFields(forThread threadID: String, _ additionalFields: [String: String]) -> [String: String] {
        var fields = diagnosticFields(additionalFields)
        guard let turnFields = runners[threadID]?.diagnosticFields([:]) ?? lastTurnDiagnosticsByThread[threadID] else {
            return fields
        }
        fields.merge(turnFields) { _, new in new }
        return fields
    }

    /// Claude Code creates a session on its first message, so a new session is
    /// only an ID that the first turn passes as `--session-id`.
    func startThread(workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?) async throws -> String {
        guard executablePath != nil else { throw ClientError.cliNotFound }
        let sessionID = UUID().uuidString.lowercased()
        newSessionIDs.insert(sessionID)
        return sessionID
    }

    /// A fork is a new session ID too; its first turn resumes the source session with
    /// `--fork-session`, so Claude Code copies that context under the new ID and the
    /// source session never gains the fork's turns.
    func forkThread(sourceThreadID: String, workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?) async throws -> String {
        let sessionID = try await startThread(workspace: workspace, modelID: modelID, developerInstructions: developerInstructions)
        forkSourceSessionIDs[sessionID] = sourceThreadID
        return sessionID
    }

    /// The session a new session's first turn forks, until Claude Code has accepted it.
    func forkSourceSessionID(for sessionID: String) -> String? { forkSourceSessionIDs[sessionID] }

    func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption] {
        let response = try await withMetadataSession(workspace: workspace) { _ in [:] }
        // Claude Code announces its newest release of a family only through the bare
        // alias (`opus` resolving to `claude-opus-5-5`); there is no entry whose value
        // is the concrete ID. Keying the option on `resolvedModel` gives that entry a
        // parseable version, so the newest release is no longer discarded as an
        // unversioned alias in favour of an older concrete model.
        //
        // The resolved name is also what `--model` receives. Claude Code accepts it even
        // though it never offers it as a `value`: verified against CLI 2.1.309, where
        // `--model claude-haiku-5-5` reported `canonicalModel: claude-haiku-5-5`.
        var seenIDs = Set<String>()
        let models = (response.initialize["models"] as? [[String: Any]] ?? []).compactMap { item -> ConversationModelOption? in
            guard let value = item["value"] as? String, !value.isEmpty else { return nil }
            let resolved = (item["resolvedModel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // "default" stays a placeholder rather than a model, so the picker still drops
            // it. Keying it on its own value also keeps it out of the dedup below, where it
            // would otherwise claim the resolved ID and evict the real entry for it.
            let id = value == Self.defaultModelID ? value : (resolved ?? value)
            // An alias and a concrete entry can resolve to the same model. Keep whichever
            // arrives first, which carries Claude Code's own display name for the release.
            guard seenIDs.insert(id).inserted else { return nil }
            let isPreferredDefault = value == Self.defaultModelID || value.lowercased().contains(Self.preferredDefaultModelID)
            return ConversationModelOption(id: id, name: item["displayName"] as? String ?? id, isDefault: isPreferredDefault)
        }
        return models.isEmpty ? [ConversationModelOption(id: Self.defaultModelID, name: "Default", isDefault: true)] : models
    }

    /// Reads Claude Code's own skills, subagents, and MCP servers for the workspace
    /// without starting a model turn.
    func capabilities(workspace: ConversationWorkspaceContext) async -> ConversationProviderCapabilities {
        var capabilities = ConversationProviderCapabilities(provider: .claude, isAvailable: false, supportsGoals: false)
        do {
            let response = try await withMetadataSession(workspace: workspace) { runner in
                try await runner.controlRequest(["subtype": "mcp_status"])
            }
            capabilities.isAvailable = true
            capabilities.version = response.initialize["claude_code_version"] as? String
            capabilities.skills = (response.initialize["commands"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            capabilities.subagents = (response.initialize["agents"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            capabilities.mcpServers = (response.extra["mcpServers"] as? [[String: Any]] ?? []).compactMap { server in
                guard let name = server["name"] as? String else { return nil }
                return .init(name: name, status: server["status"] as? String ?? "unknown")
            }
            capabilities.notes = ["Uses your Claude Code settings, skills, hooks, and MCP servers."]
        } catch {
            capabilities.error = error.localizedDescription
        }
        return capabilities
    }

    /// A sign-in in progress for one MCP server. Claude Code listens for the
    /// browser's redirect inside its own process, so that process stays up until
    /// the sign-in finishes, fails, or times out.
    final class McpLoginSession {
        let runner: ClaudeSessionRunner
        var task: Task<McpLoginResult, Never>?
        /// A newer sign-in to the same server replaced this one.
        var superseded = false
        init(runner: ClaudeSessionRunner) { self.runner = runner }
    }

    var mcpLogins: [String: McpLoginSession] = [:]

    /// Asks Claude Code to start the OAuth sign-in of an MCP server and returns
    /// the link to open in the browser. Claude Code is told not to open it itself.
    ///
    /// This uses Claude Code's `mcp_authenticate` control request, which its own
    /// remote UI uses but which isn't part of its documented interface: a failure
    /// surfaces as an error here, and a missing redirect as the sign-in's timeout.
    /// The sign-in counts as background work while it waits, so the bridge daemon
    /// doesn't idle-exit and take the process, and its callback port, with it.
    func startMcpLogin(name: String, workspace: ConversationWorkspaceContext) async throws -> String {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let runner = ClaudeSessionRunner(
            sessionID: UUID().uuidString.lowercased(),
            executable: executable,
            configDirectoryOverride: configDirectoryOverride,
            persistsSessions: false,
            owner: nil
        )
        let reply: [String: Any]
        do {
            _ = try await runner.launch(
                resume: false, mode: .code, modelID: Self.defaultModelID, effort: nil,
                workspace: workspace, developerInstructions: nil
            )
            reply = try await runner.controlRequest(["subtype": "mcp_authenticate", "serverName": name])
        } catch {
            runner.shutdown()
            throw error
        }
        guard reply["requiresUserAction"] as? Bool != false, let link = reply["authUrl"] as? String, !link.isEmpty else {
            runner.shutdown()
            throw BridgeCommandError(code: "invalid_argument", message: "Claude Code doesn't need you to sign in to \(name).")
        }
        let session = McpLoginSession(runner: runner)
        let timeout = McpLogin.timeout
        BridgeBackgroundWork.onBegin?()
        session.task = Task { @MainActor [session] in
            defer {
                runner.shutdown()
                BridgeBackgroundWork.onEnd?()
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: McpLogin.pollInterval(for: timeout))
                guard let status = try? await runner.controlRequest(["subtype": "mcp_status"]) else {
                    return McpLoginResult(provider: .claude, name: name, signedIn: false, error: "Claude Code stopped before the sign-in finished.")
                }
                let servers = status["mcpServers"] as? [[String: Any]] ?? []
                switch servers.first(where: { $0["name"] as? String == name })?["status"] as? String {
                case "connected":
                    return McpLoginResult(provider: .claude, name: name, signedIn: true, error: nil)
                case "failed":
                    return McpLoginResult(provider: .claude, name: name, signedIn: false, error: "Claude Code couldn't connect to \(name) after the sign-in.")
                default:
                    continue
                }
            }
            if session.superseded {
                return McpLoginResult(provider: .claude, name: name, signedIn: false, error: "A newer sign-in to \(name) replaced this one.")
            }
            return McpLogin.timedOut(provider: .claude, name: name)
        }
        // Replaced only now, after the awaits, so overlapping starts for one
        // server can't each leave a process behind.
        if let previous = mcpLogins.removeValue(forKey: name) {
            previous.superseded = true
            previous.task?.cancel()
            previous.runner.shutdown()
        }
        mcpLogins[name] = session
        PlayhouseDiagnostics.record("mcp.login.started", fields: ["provider": "claude"])
        return link
    }

    /// Waits for the sign-in started for `name` to finish.
    func waitForMcpLogin(name: String) async -> McpLoginResult {
        guard let session = mcpLogins[name], let task = session.task else { return McpLogin.notStarted(provider: .claude, name: name) }
        let result = await task.value
        // A finished sign-in is reported once; a newer one for the same server stays.
        if mcpLogins[name] === session { mcpLogins[name] = nil }
        PlayhouseDiagnostics.record("mcp.login.finished", fields: ["provider": "claude", "signedIn": String(result.signedIn)])
        return result
    }

    /// The skills and commands built into Claude Code itself, which have no
    /// folder on disk, read without starting a model turn.
    /// Claude Code's built-in skills and commands. They come with the binary
    /// rather than the workspace, so one metadata session's answer is reused
    /// for a while instead of starting a session on every Skills page read.
    func bundledSkills(workspace: ConversationWorkspaceContext) async throws -> [(name: String, description: String)] {
        if let cached = bundledSkillsCache, Date().timeIntervalSince(cached.readAt) < Self.bundledSkillsLifetime {
            return cached.skills
        }
        let response = try await withMetadataSession(workspace: workspace) { _ in [:] }
        let skills: [(name: String, description: String)] = (response.initialize["commands"] as? [[String: Any]] ?? []).compactMap { command in
            guard command["builtin"] as? Bool == true, let name = command["name"] as? String, !name.hasPrefix("_") else { return nil }
            return (name, command["description"] as? String ?? "")
        }
        bundledSkillsCache = (Date(), skills)
        return skills
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
        onRecordedFinalMessage: ((String, String) -> Void)? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        hideSensitiveRecoveryPrompt: Bool = false
    ) async throws {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let sessionID = threadID
        // Separate conversations run in parallel; only the same conversation is
        // single-flight, because a session's transcript can take one writer.
        guard Self.activeRunnersBySessionID[sessionID] == nil else {
            PlayhouseDiagnostics.record("claude.turn.rejected", fields: diagnosticFields([
                "requestedThreadID": sessionID,
                "reason": "session_turn_already_active"
            ]))
            throw ClientError.protocolFailure("Another Claude Code turn is already running for this conversation.")
        }

        let runner = ClaudeSessionRunner(
            sessionID: sessionID,
            executable: executable,
            configDirectoryOverride: configDirectoryOverride,
            persistsSessions: persistsSessions,
            owner: self,
            runsDirectory: runsDirectory
        )
        runner.deltaHandler = onDelta
        runner.finalMessageHandler = onFinalMessage
        runner.recordedFinalHandler = onRecordedFinalMessage
        runner.progressMessageHandler = onProgressMessage
        runner.steerMessageHandler = onSteerMessage
        runner.turnStartedHandler = onTurnStarted
        runner.activityHandler = onActivity
        runner.actionRequestHandler = onActionRequest
        runner.userInputHandler = onUserInput
        runner.tokenUsageHandler = onTokenUsage
        runner.compactionTrigger = requestedCompactionTriggers.removeValue(forKey: sessionID)
        runners[sessionID] = runner
        Self.activeRunnersBySessionID[sessionID] = runner
        // A new turn supersedes a stop another client recorded for this session.
        for client in Self.allSharedPrimaryClients { client.interruptedThreadIDs.remove(sessionID) }
        interruptedThreadIDs.remove(sessionID)
        activityDurationsByThread[sessionID] = [:]
        lastFinishedThreadID = sessionID
        defer {
            // A session Claude Code accepted is no longer new, whether or not the
            // turn succeeded. Keeping the marker past a failed first turn would
            // claim the ID again on the retry and fail with "already in use",
            // leaving the conversation unresumable.
            if runner.sessionExists {
                newSessionIDs.remove(sessionID)
                forkSourceSessionIDs.removeValue(forKey: sessionID)
            }
            // The identity only; the client reports whether a turn is still active.
            lastTurnDiagnosticsByThread[sessionID] = runner.diagnosticFields([:])
                .filter { $0.key != "isTurnActive" }
            runner.finishTurnCleanup()
            stoppingOutcomeProbes.removeValue(forKey: sessionID)
            interruptedThreadIDs.formUnion(runner.wasInterrupted ? [sessionID] : [])
            activityDurationsByThread[sessionID] = runner.activityDurations
            lastFinishedThreadID = sessionID
            if Self.activeRunnersBySessionID[sessionID] === runner {
                Self.activeRunnersBySessionID.removeValue(forKey: sessionID)
            }
            if runners[sessionID] === runner { runners.removeValue(forKey: sessionID) }
            runnerStateChanged(runner)
            // The turn spent plan usage that its stream does not report.
            Task { await self.readPlanUsage() }
        }

        let isNewSession = newSessionIDs.contains(sessionID)
        try await runner.runTurn(
            text: text,
            imageDataURLs: imageDataURLs,
            mode: mode,
            modelID: modelID,
            effort: effort,
            workspace: workspace,
            isNewSession: isNewSession,
            sessionRecoveryContext: sessionRecoveryContext,
            developerInstructions: developerInstructions,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            hideSensitiveRecoveryPrompt: hideSensitiveRecoveryPrompt
        )
    }

    /// Compacts an existing session's context with Claude Code's own
    /// `/compact`, as a turn of its own: its compaction row is labelled with
    /// `trigger`, and it writes no answer. `modelID` should be the model whose
    /// prompt cache holds the context, so the summary reads it from the cache.
    func compactSession(
        trigger: ContextCompactionTrigger,
        threadID: String,
        modelID: String,
        effort: ConversationEffort,
        workspace: ConversationWorkspaceContext,
        developerInstructions: String?,
        callbacks: ConversationTurnCallbacks
    ) async throws {
        requestedCompactionTriggers[threadID] = trigger
        defer { requestedCompactionTriggers.removeValue(forKey: threadID) }
        try await sendMessage(
            "/compact",
            mode: .code,
            modelID: modelID,
            effort: effort,
            threadID: threadID,
            workspace: workspace,
            developerInstructions: developerInstructions,
            onDelta: { _ in },
            onFinalMessage: { _ in },
            onActivity: callbacks.onActivity,
            onDiff: { _ in },
            onHistory: { _ in },
            onActionRequest: callbacks.onActionRequest,
            onUserInput: { request in
                self.rejectUserInput(requestID: request.id, threadID: request.threadID, message: "This is Playhouse's automatic context compaction; there is nobody to answer.")
            },
            onProgressMessage: { _ in },
            onTurnStarted: { _ in },
            onTokenUsage: callbacks.onTokenUsage
        )
    }

    func followReattachedTurn(
        threadID: String,
        workspace: ConversationWorkspaceContext,
        callbacks: ConversationTurnCallbacks,
        onAttached: @escaping () -> Void
    ) async throws -> ConversationReattachResult {
        guard let runsDirectory, let executable = executablePath else { return .agentGone }
        let sessionID = threadID
        guard Self.activeRunnersBySessionID[sessionID] == nil else { return .notRunning }
        let candidates = ClaudeRunFiles.runs(in: runsDirectory)
            .filter { $0.manifest.sessionID == sessionID }
            .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
        guard let newest = candidates.last, let run = ClaudeAgentRun.attach(directory: newest.directory) else { return .agentGone }
        // An older run of the session can only be one its daemon never finished stopping.
        for stale in candidates.dropLast() {
            await ClaudeAgentRun.attach(directory: stale.directory)?.terminateAndRemove()
        }
        let runner = ClaudeSessionRunner(
            sessionID: sessionID,
            executable: executable,
            configDirectoryOverride: configDirectoryOverride,
            persistsSessions: persistsSessions,
            owner: self,
            runsDirectory: runsDirectory
        )
        runner.deltaHandler = callbacks.onDelta
        runner.finalMessageHandler = callbacks.onFinalMessage
        runner.recordedFinalHandler = callbacks.onRecordedFinalMessage
        runner.progressMessageHandler = callbacks.onProgressMessage
        runner.steerMessageHandler = callbacks.onSteerMessage
        runner.activityHandler = callbacks.onActivity
        runner.actionRequestHandler = callbacks.onActionRequest
        runner.userInputHandler = callbacks.onUserInput
        runner.tokenUsageHandler = callbacks.onTokenUsage
        runners[sessionID] = runner
        Self.activeRunnersBySessionID[sessionID] = runner
        newSessionIDs.remove(sessionID)
        activityDurationsByThread[sessionID] = [:]
        lastFinishedThreadID = sessionID
        defer {
            lastTurnDiagnosticsByThread[sessionID] = runner.diagnosticFields([:])
                .filter { $0.key != "isTurnActive" }
            runner.finishTurnCleanup()
            stoppingOutcomeProbes.removeValue(forKey: sessionID)
            interruptedThreadIDs.formUnion(runner.wasInterrupted ? [sessionID] : [])
            activityDurationsByThread[sessionID] = runner.activityDurations
            lastFinishedThreadID = sessionID
            if Self.activeRunnersBySessionID[sessionID] === runner {
                Self.activeRunnersBySessionID.removeValue(forKey: sessionID)
            }
            if runners[sessionID] === runner { runners.removeValue(forKey: sessionID) }
            runnerStateChanged(runner)
        }
        return try await runner.reattach(run, onAttached: onAttached)
    }

    static func hasActiveRunner(sessionID: String) -> Bool { activeRunnersBySessionID[sessionID] != nil }

    /// Before an idle daemon exits: a run left after its turn ended has nothing more to do.
    static func stopRunsBeforeExit() async {
        for client in allSharedPrimaryClients {
            for runner in client.runners.values where !runner.isTurnActive { runner.shutdown() }
        }
    }

    func interruptActiveTurn(threadID: String) async throws -> Bool {
        guard let runner = runners[threadID], runner.canInterrupt else {
            // Another Playhouse process may own the turn.
            guard Self.activeRunnersBySessionID[threadID] == nil else { return false }
            return try await ConversationSteerMailbox.requestInterrupt(threadID: threadID)
        }
        let interrupted = try await runner.interrupt()
        if interrupted { interruptedThreadIDs.insert(threadID) }
        return interrupted
    }

    func steerActiveTurn(threadID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard let runner = Self.activeRunnersBySessionID[threadID] else {
            return try await ConversationSteerMailbox.requestSteer(threadID: threadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        let accepted = try await runner.sendSteerInput(text: normalized, imageDataURLs: imageDataURLs)
        // The turn's own stream shows and records the steer, whoever sent it.
        if accepted { runner.steerMessageHandler?(normalized, imageDataURLs) }
        return accepted
    }

    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
        guard let runner = runner(for: threadID) else { return false }
        return runner.answerUserInput(requestID: requestID, answers: answers)
    }

    func rejectUserInput(requestID: String, threadID: String, message: String) {
        runner(for: threadID)?.rejectUserInput(requestID: requestID, message: message)
    }

    func isTurnActive(threadID: String) -> Bool {
        if startingSessionIDs.contains(threadID) { return true }
        guard let runner = runners[threadID] else { return false }
        return runner.activeTurnID != nil || runner.pendingQuestion != nil
    }

    func isTurnActiveInProcess(threadID: String) -> Bool {
        Self.processActiveSessionIDs.contains(threadID)
    }

    /// Every session with a running turn, a turn that is starting, or a
    /// question waiting for an answer.
    var activeThreadIDsSnapshot: Set<String> {
        Set(runners.keys.filter { isTurnActive(threadID: $0) }).union(startingSessionIDs)
    }

    var pendingUserInputsSnapshot: [String: ConversationUserInputRequest] {
        runners.compactMapValues(\.pendingUserInputRequest)
    }

    /// Process IDs of every turn-active session's own Claude Code process,
    /// keyed by thread/session ID. Used to attribute CPU usage per task;
    /// idle sessions are excluded since there's nothing meaningful to sample.
    var activeProcessIdentifiersByThreadID: [String: pid_t] {
        var result: [String: pid_t] = [:]
        for (threadID, runner) in runners where isTurnActive(threadID: threadID) {
            let pid = runner.processIdentifier
            if pid > 0 { result[threadID] = pid }
        }
        return result
    }

    var interruptedThreadIDsSnapshot: Set<String> { interruptedThreadIDs }

    /// Every client this process has created through `sharedPrimaryClient`.
    static var allSharedPrimaryClients: [ClaudeCodeClient] { Array(sharedPrimaryClients.values) }

    func setStoppingOutcomeProbe(_ probe: ProviderStoppingOutcomeProbe?, threadID: String) {
        stoppingOutcomeProbes[threadID] = probe
    }

    func canInterruptActiveTurn(threadID: String) -> Bool {
        runners[threadID]?.canInterrupt == true
    }

    func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        if Self.activeRunnersBySessionID[threadID] != nil {
            return Int32(ProcessInfo.processInfo.processIdentifier)
        }
        return ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: threadID)
    }

    func markTurnStarting(threadID: String) {
        startingSessionIDs.insert(threadID)
    }

    func clearTurnStarting(threadID: String) {
        startingSessionIDs.remove(threadID)
    }

    func beginConversationOperation() { conversationOperationsInFlight += 1 }

    func finishConversationOperation() { conversationOperationsInFlight = max(0, conversationOperationsInFlight - 1) }

    func prepareForApplicationTermination() async {
        isPreparingForApplicationTermination = true
        for runner in runners.values where runner.isTurnActive {
            _ = try? await runner.interrupt()
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while conversationOperationsInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        shutdown()
    }

    func shutdown() {
        for runner in runners.values { runner.shutdown() }
    }

    func isProviderUnavailable(_ error: Error) -> Bool {
        switch error as? ClientError {
        case .cliNotFound, .processStart, .authentication, .unsupportedVersion: true
        default: false
        }
    }

    func makeAuxiliaryClient() -> ConversationProviderClient {
        ClaudeCodeClient(executableOverride: executableOverride, configDirectoryOverride: configDirectoryOverride, persistsSessions: false)
    }

    // MARK: - Per-conversation turn results

    /// Whether the conversation's own most recent turn ended because the user
    /// stopped it. Parallel turns each keep their own answer.
    func wasLastTurnInterrupted(threadID: String) -> Bool {
        interruptedThreadIDs.contains(threadID)
    }

    func lastTurnActivityDurations(threadID: String) -> [String: Int] {
        activityDurationsByThread[threadID] ?? [:]
    }

    func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? {
        runners[threadID]?.pendingUserInputRequest
    }

    var wasLastTurnInterrupted: Bool {
        lastFinishedThreadID.map { interruptedThreadIDs.contains($0) } ?? false
    }

    var lastTurnActivityDurations: [String: Int] {
        lastFinishedThreadID.flatMap { activityDurationsByThread[$0] } ?? [:]
    }

    func runner(for threadID: String) -> ClaudeSessionRunner? {
        runners[threadID] ?? Self.activeRunnersBySessionID[threadID]
    }

    // MARK: - Metadata

    struct MetadataResponse {
        let initialize: [String: Any]
        let extra: [String: Any]
    }

    /// Starts a short-lived process that never receives a prompt, so no model
    /// request is made, and reads its initialize response plus one extra query.
    func withMetadataSession(
        workspace: ConversationWorkspaceContext,
        _ query: (ClaudeSessionRunner) async throws -> [String: Any]
    ) async throws -> MetadataResponse {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let runner = ClaudeSessionRunner(
            sessionID: UUID().uuidString.lowercased(),
            executable: executable,
            configDirectoryOverride: configDirectoryOverride,
            persistsSessions: false,
            owner: nil
        )
        defer { runner.shutdown() }
        let initialize = try await runner.launch(
            resume: false, mode: .code, modelID: Self.defaultModelID, effort: nil,
            workspace: workspace, developerInstructions: nil
        )
        return MetadataResponse(initialize: initialize, extra: try await query(runner))
    }

    // MARK: - Mapping
}


// MARK: - Account and usage


/// Reads a Claude Code session's per-call usage back from its own files.
///
/// The stream's `result` message sums a turn for the main agent only; the
/// session files hold every model call, the main agent's in
/// `<session>.jsonl` and each subagent's in `<session>/subagents/agent-*.jsonl`.
/// A call is written once per content block, all lines sharing the call's
/// message ID, so a call is counted by ID and the last line's usage wins.
