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

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId", objective, status, tokenBudget, tokensUsed, timeUsedSeconds
    }
}

@MainActor
final class CodexAppServerClient: ObservableObject, ConversationProviderClient {
    let provider = ConversationProvider.codex
    nonisolated static let modelID = "gpt-6-luna"
    static var processActiveThreadIDs = Set<String>()
    static var activeClientsByThreadID: [String: CodexAppServerClient] = [:]
    /// The client whose turn owns this thread, if it serves the same data
    /// directory as this client. Thread IDs are only unique within one Codex
    /// home, so a client for another isolated store never counts as the owner.
    /// A window and the CLI share one client per Codex home, so the owner is
    /// usually this client; another is one following a turn on a server started
    /// before that (see `sharedClient(for:runDirectory:)`).
    func activeClient(forThread threadID: String) -> CodexAppServerClient? {
        guard let owner = Self.activeClientsByThreadID[threadID], owner.runtimeScope == runtimeScope else { return nil }
        return owner
    }
    var startingThreadIDs = Set<String>()
    @Published var isTurnActive = false
    @Published var activeThreadID: String?
    @Published var pendingUserInputRequest: ConversationUserInputRequest?
    @Published var goalStateThreadID: String?
    @Published var goalStateRevision = 0
    @Published var goalTurnRevision = 0
    @Published var goalTurnCompletedRevision = 0
    @Published var goalTurnCompletedTurnID: String?
    @Published var goalTurnStartedThreadID: String?
    /// When this client's goal state last changed, in this process's order of goal events,
    /// so a runtime snapshot over several clients reports the most recent one's thread IDs.
    var goalEventOrder = 0
    static var lastGoalEventOrder = 0
    func noteGoalEvent() {
        Self.lastGoalEventOrder += 1
        goalEventOrder = Self.lastGoalEventOrder
    }
    var activeConversationMode: ConversationMode = .code

    enum ClientError: LocalizedError {
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

    var lastServerActivity = Date()
    /// The union of extra skill roots most recently configured on this app-server.
    var appliedSkillExtraRoots: [String] = []
    var isRefreshingAgentUsage = false
    var agentUsageRefreshPending = false
    /// Servers whose sign-in this client started and has not yet reported as complete.
    var startedMcpLogins = Set<String>()
    /// Pending browser sign-ins keep this app-server and bridge alive.
    var mcpLoginHolds: [String: Task<Void, Never>] = [:]

    var outputPump: ProviderOutputPump?
    var stdoutBuffer = Data()
    var process: Process?
    /// Set for the long-lived shared clients: their app-server listens on a Unix socket and
    /// outlives this daemon, so the next daemon of the same service reconnects to it and the
    /// turns it runs keep going across a restart. Short-lived clients keep a stdio child.
    let persistentServer: CodexSharedServer?
    var socketConnection: CodexSocketConnection?
    var serverManifest: CodexServerManifest?
    var serverExitSource: DispatchSourceProcess?
    var serverOwnership: AgentOwnershipLock?
    /// A server started by another Codex version or with other flags: kept while it runs a
    /// turn, stopped as soon as it is idle.
    var isRetiringServer = false
    var idleShutdownTask: Task<Void, Never>?
    var inputPipe: Pipe?
    var outputPipe: Pipe?
    var stderrPipe: Pipe?
    var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    var pendingRequestDiagnostics: [Int: (method: String, startedAt: UInt64)] = [:]
    struct DeltaLogSummary {
        var notificationCount = 0
        var payloadBytes = 0
    }
    var deltaLogSummaries: [String: (threadID: String, turnID: String, itemID: String, method: String, summary: DeltaLogSummary)] = [:]
    let deltaLogSummaryLimit = 100
    var nextRequestID = 1
    var initialized = false
    var initializationTask: Task<Void, Error>?
    /// What a thread was last started/resumed with in this still-running
    /// app-server process. Skipping a redundant `thread/resume` call is only
    /// safe when a later call's own model/workspace parameters are identical
    /// to what's already active for that thread in the app-server — otherwise
    /// the app-server would silently keep using stale parameters from an
    /// earlier, unrelated request. This only matters now that one
    /// `CodexAppServerClient` instance can legitimately serve many separate
    /// requests over its life (the bridge daemon), rather than exactly one.
    struct ResumeParameters: Equatable {
        let modelID: String
        let cwd: String
        let roots: [String]
        let developerInstructions: String?
        /// The thread's MCP server config, so turning a server on or off resumes the thread.
        var mcpServers: String? = nil
    }
    var resumedThreadParameters: [String: ResumeParameters] = [:]
    var activeTurnID: String?
    var conversationOperationsInFlight = 0
    var applicationShutdownInterruptResult: String?
    var wasLastTurnInterrupted = false
    var isPreparingForApplicationTermination = false
    final class TurnContext {
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
    var turnContexts: [String: TurnContext] = [:]
    /// Subagent thread -> the thread that spawned it, from `thread/started`.
    var threadParents: [String: String] = [:]
    /// The cumulative total last seen per thread, so a repeated usage
    /// notification isn't counted as another call.
    var lastReportedTotals: [String: Int] = [:]
    var completedActivityDurations: [String: [String: Int]] = [:]
    var interruptedThreadIDs = Set<String>()
    var goalObservationThreadID: String?
    /// The running turn, per task thread, that Codex started without a send of ours, such as a
    /// Goal's work turn, whether a window or the CLI set the Goal. It has no turn context, and
    /// the window and the CLI share this client, so it is kept per thread rather than in
    /// `activeThreadID`/`activeTurnID`, which sends also use. Only a window follows its Goal
    /// signals (`goalObservationThreadID`), but every caller sees it running.
    var contextlessTurnIDs: [String: String] = [:]
    /// Follows a thread's Goal turns for a window. A turn running on another thread keeps its
    /// entry until it completes, so it stays active and interruptible meanwhile.
    func followGoalTurns(threadID: String) {
        goalObservationThreadID = threadID
        Self.activeClientsByThreadID[threadID] = self
    }
    var goalTurnStartRevision = 0
    var lastTurnActivityDurations: [String: Int] { activeThreadID.map { lastTurnActivityDurations(threadID: $0) } ?? [:] }
    func lastTurnActivityDurations(threadID: String) -> [String: Int] {
        turnContexts[threadID]?.durations ?? completedActivityDurations[threadID] ?? [:]
    }
    func wasLastTurnInterrupted(threadID: String) -> Bool { interruptedThreadIDs.contains(threadID) }
    var actionRequestHandler: (() -> Void)?
    // History reads and other sends can change the displayed thread while a
    // provider turn is waiting. Question ownership follows the requesting thread.
    struct UserInputContext {
        let mode: ConversationMode
        let handler: (ConversationUserInputRequest) async -> Void
    }
    struct PendingUserInput {
        let nativeID: Any
        let request: ConversationUserInputRequest
        var published = false
        /// The app-server process (or socket connection) that asked. Only that one,
        /// while it is still the running one, can receive a live answer.
        weak var asker: AnyObject?
    }
    var userInputContexts: [String: UserInputContext] = [:]
    @Published var pendingUserInputs: [String: PendingUserInput] = [:]
    let codexExecutableOverride: String?
    let codexHomeOverride: String?
    /// This instance's own resolved data directory, fixed at construction time
    /// (debug/test builds only; always `nil` in production). Forwarded into
    /// this client's app-server child process instead of an ambient global, so
    /// a different client instance's concurrently-resolved directory can never
    /// leak into this one's child process environment.
    let dataDirectoryOverride: String?
    /// The data directory this client serves (debug/test isolation); nil in production.
    var runtimeScope: String? { dataDirectoryOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
    var turnWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    var completedTurns: [String: Result<Void, Error>] = [:]
    final class PendingCompaction {
        var turnID: String?
        var result: Result<Void, Error>?
    }
    var pendingCompactions: [String: PendingCompaction] = [:]
    var rejectedTurnKeys = Set<String>()

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
    static var sharedClients: [String: CodexAppServerClient] = [:]

    /// The parts of a current shared client's key: executable, Codex home, data directory.
    static let keyPartCount = 3

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
    static func resolvedCodexHome(_ override: String?) -> String {
        let home = override.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.codex"
        return URL(fileURLWithPath: home).standardizedFileURL.path
    }

    static func sharedClient(
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
        pendingUserInputs.filter { $0.value.published }.mapValues(\.request)
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



    func waitForTurn(_ key: String) async throws {
        if let result = completedTurns.removeValue(forKey: key) {
            return try result.get()
        }

        try await withCheckedThrowingContinuation { continuation in
            turnWaiters[key] = continuation
        }
    }

    func waitForGoalTurnStart(threadID: String, after revision: Int) async throws {
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

}
