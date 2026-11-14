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
@MainActor
final class ClaudeAgentRun {
    let directory: URL
    private(set) var manifest: ClaudeRunManifest
    var identity: AgentProcessIdentity? { manifest.process }
    private let input: AgentInputWriter
    private var writesInFlight = 0
    /// Why the agent's input failed; the agent is stopped then, and its exit reports this.
    private(set) var inputFailure: AgentInputWriter.WriteError?
    private var tailer: LineTailer
    private var reader: Int32 = -1
    private var outputSource: DispatchSourceFileSystemObject?
    private var pollTask: Task<Void, Never>?
    private var exitSource: DispatchSourceProcess?
    private var answeredSinceCommit: [String] = []
    private var pendingSinceCommit: [String] = []
    private(set) var hasExited = false

    private init(directory: URL, manifest: ClaudeRunManifest) {
        self.directory = directory
        self.manifest = manifest
        input = AgentInputWriter(path: ClaudeRunFiles.inputPath(directory))
        tailer = LineTailer(offset: manifest.consumedOffset)
    }

    deinit {
        if reader >= 0 { close(reader) }
    }

    /// Starts a run in a new folder under `runsDirectory`.
    static func start(
        runsDirectory: URL,
        sessionID: String,
        mode: ConversationMode,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws -> ClaudeAgentRun {
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = runsDirectory.appendingPathComponent("\(sessionID)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard mkfifo(ClaudeRunFiles.inputPath(directory), 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: ClaudeRunFiles.inputPath(directory)])
        }
        var manifest = ClaudeRunManifest(
            serviceName: AgentRunService.name, sessionID: sessionID, state: "spawning", process: nil,
            createdAt: Date(), mode: mode.rawValue
        )
        // Recorded before the spawn, so an agent whose daemon dies right after starting it is
        // still matched to this folder.
        try AgentManifestFile.write(manifest, to: ClaudeRunFiles.manifestURL(directory))
        let identity = try AgentRunHost.spawn(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            // The child holds its own writer, so its input never ends between daemons.
            stdin: .path(ClaudeRunFiles.inputPath(directory), flags: O_RDWR),
            stdout: .path(ClaudeRunFiles.outputPath(directory), flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path(ClaudeRunFiles.errorPath(directory), flags: O_WRONLY | O_CREAT | O_APPEND)
        )
        manifest.process = identity
        manifest.state = "running"
        try AgentManifestFile.write(manifest, to: ClaudeRunFiles.manifestURL(directory))
        return ClaudeAgentRun(directory: directory, manifest: manifest)
    }

    /// The run recorded in `directory`, for a daemon carrying it on.
    static func attach(directory: URL) -> ClaudeAgentRun? {
        guard let manifest = AgentManifestFile.read(ClaudeRunManifest.self, from: ClaudeRunFiles.manifestURL(directory)) else { return nil }
        return ClaudeAgentRun(directory: directory, manifest: manifest)
    }

    var isRunning: Bool { !hasExited && identity?.isAlive == true }

    /// Writes one JSON line to the agent's input and returns once it is written, without
    /// holding the main actor while the agent reads it.
    func write(_ line: Data) async throws {
        let error: AgentInputWriter.WriteError? = try await withCheckedThrowingContinuation { continuation in
            do {
                try queue(line) { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if let error { throw error }
    }

    /// Queues one JSON line without waiting for it. A line that fails stops the agent, and the
    /// agent's exit ends the turn with `inputFailure`.
    func send(_ line: Data) throws {
        try queue(line) { _ in }
    }

    /// Lines reach the agent whole and in the order they are queued. A line is written whole or
    /// the turn is lost, so the manifest marks the run while any line is in flight.
    private func queue(_ line: Data, completion: @escaping @MainActor (AgentInputWriter.WriteError?) -> Void) throws {
        if let inputFailure { throw inputFailure }
        if writesInFlight == 0 {
            manifest.writeInProgress = true
            try saveManifest()
        }
        writesInFlight += 1
        input.enqueue(line) { error in
            Task { @MainActor [weak self] in
                self?.finishWrite(error)
                completion(error)
            }
        }
    }

    private func finishWrite(_ error: AgentInputWriter.WriteError?) {
        writesInFlight -= 1
        if let error {
            // The line may be cut off in the agent's input, so the marker stays and the agent,
            // which can't take another line, is stopped.
            guard inputFailure == nil else { return }
            inputFailure = error
            if let identity { Task { await AgentRunHost.terminate(identity) } }
            return
        }
        if writesInFlight == 0, inputFailure == nil {
            manifest.writeInProgress = false
            try? saveManifest()
        }
    }

    /// Lines up to the committed offset: what this run's previous daemon already handled.
    func handledLines() -> [Data] {
        guard let data = FileManager.default.contents(atPath: ClaudeRunFiles.outputPath(directory)) else { return [] }
        let prefix = data.prefix(Int(manifest.consumedOffset))
        return prefix.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast(prefix.last == 0x0A ? 1 : 0).map { Data($0) }
    }

    /// Follows the log from the committed offset: `onLines` gets each batch of complete lines,
    /// and `onExit` runs once after the process exits and the log is read to its end.
    func follow(onLines: @escaping @MainActor ([Data], UInt64) async -> Void, onExit: @escaping @MainActor (Int32?) async -> Void) {
        reader = open(ClaudeRunFiles.outputPath(directory), O_RDONLY | O_CLOEXEC | O_CREAT, 0o600)
        let pump = ProviderOutputPump(label: "claude") { [weak self] item in
            guard let self else { return }
            switch item {
            case .output:
                let lines = self.tailer.read(from: self.reader)
                guard let end = lines.last?.endOffset else { return }
                await onLines(lines.map(\.line), end)
            case .ended(let status):
                let lines = self.tailer.read(from: self.reader)
                if let end = lines.last?.endOffset { await onLines(lines.map(\.line), end) }
                self.hasExited = true
                self.stopFollowing()
                await onExit(status)
            case .exit:
                break
            }
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: reader, eventMask: [.extend, .write], queue: .global())
        source.setEventHandler { pump.push(.output(Data())) }
        source.resume()
        outputSource = source
        // A file event can be missed; a slow poll backs it up.
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                pump.push(.output(Data()))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        pump.push(.output(Data()))
        if let identity {
            exitSource = AgentRunHost.onExit(identity) { status in pump.push(.ended(status)) }
        } else {
            pump.push(.ended(nil))
        }
    }

    private func stopFollowing() {
        outputSource?.cancel()
        outputSource = nil
        pollTask?.cancel()
        pollTask = nil
    }

    func noteAnswered(_ requestID: String) { answeredSinceCommit.append(requestID) }
    func notePending(_ requestID: String) { pendingSinceCommit.append(requestID) }

    /// Records that everything before `offset` was handled, with the answers written for it.
    func commit(offset: UInt64) {
        manifest.commit(answered: answeredSinceCommit, pending: pendingSinceCommit, offset: offset)
        answeredSinceCommit.removeAll()
        pendingSinceCommit.removeAll()
        try? saveManifest()
    }

    /// An answer written outside the log's handling (a user's answer to a question).
    func commitAnswer(_ requestID: String) {
        manifest.commit(answered: [requestID], offset: manifest.consumedOffset)
        try? saveManifest()
    }

    func recordRequestID(_ number: Int) {
        guard number > manifest.maxRequestID else { return }
        manifest.maxRequestID = number
        try? saveManifest()
    }

    var stderrTail: String {
        guard let handle = FileHandle(forReadingAtPath: ClaudeRunFiles.errorPath(directory)) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 4_000 ? size - 4_000 : 0)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }

    private func saveManifest() throws {
        try AgentManifestFile.write(manifest, to: ClaudeRunFiles.manifestURL(directory))
    }

    /// Stops the agent (verified by identity) and removes its folder once it is gone.
    func terminateAndRemove() async {
        stopFollowing()
        exitSource?.cancel()
        exitSource = nil
        input.close()
        if let identity { await AgentRunHost.terminate(identity) }
        if reader >= 0 { close(reader); reader = -1 }
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Owns the Claude Code CLI process for one turn of one session.
///
/// Claude Code starts a fresh process per turn and resumes a conversation by
/// session ID, so every Playhouse conversation can run its own process with its
/// own worktree as the working directory. All per-turn protocol state lives
/// here rather than on the client, which is what lets separate conversations
/// run at the same time without a shared turn slot.
@MainActor
final class ClaudeSessionRunner {
    typealias ClientError = ClaudeCodeClient.ClientError

    struct PendingQuestion {
        let controlRequestID: String
        let sessionID: String
        let input: [String: Any]
        let questions: [ConversationUserQuestion]
    }

    private struct TurnCompletion {
        var resultReceived = false
        var resultError: Error?
        /// Results Claude sent during this logical turn, including woken turns.
        var resultCount = 0
        /// Provider turns Claude Code started to deliver a background task's
        /// notification. Each owes its own result, which can arrive after the
        /// earlier turn's result or before it.
        var wokenTurnCount = 0
        /// A top-level background task finished and Claude Code has not yet
        /// delivered its notification to the parent, either in a new provider
        /// turn (`system init`) or in the running one's next request.
        var awaitingParentWake = false
        /// Whether the `system init` of the provider turn Claude Code started
        /// for the pending wake has already been counted, so repeated `init`
        /// events for one wake can't owe several results. It also authorizes
        /// the wake backstop to give that count back: only a wake whose woken
        /// turn was counted here has a result to stop owing when it times out.
        var countedWakeInit = false
    }

    /// How long a settled turn waits for Claude Code to deliver a finished
    /// background task before treating the notification as already consumed.
    nonisolated static let parentWakeGracePeriod: Duration = .seconds(15)

    /// Tests shorten both backstop grace periods so a case does not spend the
    /// product's wall clock waiting one out; what they check — which silence
    /// settles the turn and which one waits for Claude — does not depend on the
    /// lengths. Resolved per turn, inside the request that carries the
    /// environment, rather than read from the backstop's detached task.
    nonisolated static func graceOverride(_ name: String, default fallback: Duration) -> Duration {
        guard let seconds = PlayhouseProcessEnvironment.current[name].flatMap(Double.init),
              seconds.isFinite, seconds > 0, seconds < 86_400 else { return fallback }
        return .milliseconds(Int(seconds * 1000))
    }

    /// How long a woken turn Claude Code announced with `system init` may stay
    /// silent before Playhouse stops waiting for the result it owes. It is far
    /// longer than `parentWakeGracePeriod` because this turn exists and may
    /// simply be slow to speak — time to first token, or a retry backoff the
    /// CLI never reports — and cutting a live turn off loses its notification,
    /// while a turn that is really stranded only has to end eventually.
    nonisolated static let wokenTurnSilenceGracePeriod: Duration = .seconds(120)

    /// This turn's resolved grace periods, read once where the request's
    /// environment is in scope.
    private var wakeGrace: Duration = ClaudeSessionRunner.parentWakeGracePeriod
    private var wokenSilenceGrace: Duration = ClaudeSessionRunner.wokenTurnSilenceGracePeriod

    let sessionID: String
    private let executable: String
    private let configDirectoryOverride: String?
    private let persistsSessions: Bool
    private weak var owner: ClaudeCodeClient?

    private var outputPump: ProviderOutputPump?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var process: Process?
    private var inputPipe: Pipe?
    /// The run with file-backed stdio a runner of a daemon's shared client uses instead of a
    /// piped child, so its turn outlives the daemon.
    private var agentRun: ClaudeAgentRun?
    private let runsDirectory: URL?
    /// Set while rebuilding the turn from log lines a previous daemon already handled: nothing
    /// is written, recorded or reported again.
    private var isReplaying = false
    private var nextControlRequestID = 1
    private var pendingControlRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var activeMode: ConversationMode = .code
    /// A side chat's turn: file-editing tools and shell commands other than the CLI are denied.
    private var activeReadOnly = false
    private var pendingCommandUUIDs = Set<String>()
    /// What each model call (by message ID) has reported so far, so the live
    /// counter adds a call once and only its later growth after that.
    private var liveCallUsage: [String: (sent: Int, output: Int, usage: ConversationTokenUsage)] = [:]
    private var sawCommandLifecycle = false
    private var sessionWasMissing = false
    private var turnCompletion = TurnCompletion()
    private var turnWaiter: CheckedContinuation<Void, Error>?
    private var planWasPresented = false
    private var pendingAssistantText: (id: String, text: String)?
    /// Set when the pending answer text was followed only by Playhouse's
    /// end-of-turn call — a task outcome, or a standalone chat's page
    /// close-turn — so text Claude writes after it extends the same answer.
    private var pendingTextSpansOutcomeReport = false
    private var toolActivities: [String: ConversationActivity] = [:]
    private var activityStartedAtUptime: [String: UInt64] = [:]
    /// Background Agent/Task calls currently reported as outstanding by the most
    /// recent `background_tasks_changed` event. The turn must not settle while
    /// any of these are still running, or their results and the activity rows
    /// tracking them would be lost when the process is torn down.
    private var outstandingBackgroundTaskIDs: Set<String> = []
    /// A task_updated terminal status is not the final report. Wait for the
    /// distinct task_notification event even if background_tasks_changed has
    /// already removed the task from its outstanding list.
    private var pendingBackgroundTaskNotificationIDs: Set<String> = []
    /// Maps the provider's own background task id to the tool-use id (the
    /// activity's `childThreadID`) that launched it, learned from `task_started`.
    private var backgroundTaskToolUseIDs: [String: String] = [:]
    /// Task ids owned by a subagent itself (for example a nested Bash call the
    /// background agent ran), not a top-level Agent/Task call Playhouse tracks
    /// as its own activity row. Their notifications are internal to the agent's
    /// own work and must not spawn a stray top-level activity.
    private var nestedBackgroundTaskIDs: Set<String> = []
    /// Tool-use ids for Agent/Task and Bash calls launched with
    /// `run_in_background: true`, so their instant launch-confirmation
    /// tool_result isn't mistaken for the actual completion.
    private var backgroundedToolUseIDs: Set<String> = []
    /// Top-level background shells (`local_bash` not owned by a subagent). They
    /// keep the turn open like agents, but their summary is command status, not
    /// an agent report for the transcript.
    private var backgroundShellTaskIDs: Set<String> = []
    private var parentWakeBackstopGeneration = 0
    /// Why Playhouse sent this turn's `/compact`, which Claude Code itself
    /// reports as a manual compaction; nil for every other turn.
    var compactionTrigger: ContextCompactionTrigger?
    /// The timeline row of a compaction Claude Code has started and not yet
    /// finished, so its boundary completes that row instead of adding one.
    private var pendingCompactionActivityID: String?

    private(set) var activeTurnID: String?
    private(set) var isTurnActive = false
    private(set) var pendingQuestion: PendingQuestion?
    private(set) var pendingUserInputRequest: ConversationUserInputRequest?
    private(set) var wasInterrupted = false
    private(set) var activityDurations: [String: Int] = [:]
    /// Set once Claude Code has accepted this session ID and owns its transcript.
    /// From then on the session exists whether or not the turn succeeds, so the
    /// next turn must resume it instead of claiming the ID again.
    private(set) var sessionExists = false

    var deltaHandler: ((String) -> Void)?
    var finalMessageHandler: ((String) -> Void)?
    var progressMessageHandler: ((ConversationMessage) -> Void)?
    var steerMessageHandler: ((String, [String]) -> Void)?
    var activityHandler: ((ConversationActivity) -> Void)?
    var actionRequestHandler: (() -> Void)?
    var userInputHandler: ((ConversationUserInputRequest) async -> Void)?
    var tokenUsageHandler: ((ConversationTurnUsageReport) -> Void)?

    init(
        sessionID: String,
        executable: String,
        configDirectoryOverride: String?,
        persistsSessions: Bool,
        owner: ClaudeCodeClient?,
        runsDirectory: URL? = nil
    ) {
        self.sessionID = sessionID
        self.executable = executable
        self.configDirectoryOverride = configDirectoryOverride
        self.persistsSessions = persistsSessions
        self.owner = owner
        self.runsDirectory = runsDirectory
    }

    var processIdentifier: Int32 { agentRun?.identity?.pid ?? process?.processIdentifier ?? -1 }

    private var isAgentRunning: Bool { agentRun?.isRunning ?? (process?.isRunning == true) }

    var canInterrupt: Bool { activeTurnID != nil }

    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["provider"] = ConversationProvider.claude.rawValue
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["claudePID"] = String(processIdentifier)
        fields["activeThreadID"] = sessionID
        fields["activeTurnID"] = activeTurnID ?? ""
        fields["isTurnActive"] = String(isTurnActive)
        return fields
    }

    // MARK: - Turn

    /// Runs one turn to completion in this session's own process.
    func runTurn(
        text: String,
        imageDataURLs: [String],
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort,
        workspace: ConversationWorkspaceContext,
        isNewSession: Bool,
        sessionRecoveryContext: String?,
        developerInstructions: String?,
        sensitiveUserInputAnswerValues: [String],
        hideSensitiveRecoveryPrompt: Bool
    ) async throws {
        activeMode = mode
        activeReadOnly = workspace.isReadOnly
        wakeGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS", default: ClaudeSessionRunner.parentWakeGracePeriod
        )
        wokenSilenceGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS", default: ClaudeSessionRunner.wokenTurnSilenceGracePeriod
        )
        var providerPrompt = text
        var initialize: [String: Any]
        do {
            initialize = try await launch(
                resume: !isNewSession, mode: mode, modelID: modelID, effort: effort,
                workspace: workspace, developerInstructions: developerInstructions
            )
        } catch ClientError.sessionNotFound {
            // A new session ID may have been persisted before its first turn
            // reached Claude Code. A missing resumed session needs the visible
            // Playhouse transcript so Claude does not silently lose its context.
            if !isNewSession {
                providerPrompt = ConversationHandoff.prompt(
                    ConversationHandoff.stripContext(from: text),
                    context: sessionRecoveryContext
                )
            }
            stopProcess()
            initialize = try await launch(
                resume: false, mode: mode, modelID: modelID, effort: effort,
                workspace: workspace, developerInstructions: developerInstructions
            )
        }
        // Claude Code has the session now. A turn that fails after this point
        // still leaves the transcript behind, so the next turn resumes it.
        sessionExists = true
        try ClaudeCodeClient.verifyVersion(initialize["claude_code_version"] as? String)

        let turnID = UUID().uuidString.lowercased()
        let userMessageID = UUID().uuidString.lowercased()
        activeTurnID = turnID
        turnCompletion = TurnCompletion()
        parentWakeBackstopGeneration += 1
        pendingCommandUUIDs = [userMessageID]
        // Active before the write, which suspends: Claude Code can answer before it returns,
        // and the runner must not look idle meanwhile.
        isTurnActive = true
        do {
            try await writeUserMessage(text: providerPrompt, imageDataURLs: imageDataURLs, uuid: userMessageID, priority: nil)
        } catch {
            isTurnActive = false
            throw error
        }
        owner?.runnerStateChanged(self)
        ClaudeCodeClient.markProcessActive(sessionID: sessionID)
        ConversationSteerMailbox.publishActiveTurn(threadID: sessionID, turnID: turnID)
        PlayhouseDiagnostics.record("claude.turn.started", fields: diagnosticFields([
            "threadID": sessionID,
            "turnID": turnID,
            "mode": mode.rawValue,
            "workspaceRootCount": String(workspace.roots.count)
        ]))

        let mailboxTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.activeTurnID == turnID {
                await ConversationSteerMailbox.service(threadID: self.sessionID, turnID: turnID) { text, images in
                    let accepted = try await self.sendSteerInput(text: text, imageDataURLs: images)
                    if accepted { self.steerMessageHandler?(text, images) }
                    return accepted
                } interrupt: {
                    try await self.interrupt()
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        defer { mailboxTask.cancel() }
        do {
            try await waitForTurnCompletion()
            PlayhouseDiagnostics.record("claude.turn.ended", fields: diagnosticFields([
                "threadID": sessionID, "turnID": turnID, "turnStatus": "completed"
            ]))
        } catch {
            var fields = hideSensitiveRecoveryPrompt
                ? ["error": "Private conversation recovery turn failed."]
                : PlayhouseDiagnostics.errorFields(error, redacting: sensitiveUserInputAnswerValues)
            fields["threadID"] = sessionID
            fields["turnID"] = turnID
            fields["turnStatus"] = wasInterrupted ? "interrupted" : "failed"
            fields.merge(diagnosticFields([:])) { _, new in new }
            PlayhouseDiagnostics.record("claude.turn.ended", fields: fields)
            throw error
        }
    }

    func finishTurnCleanup() {
        ClaudeCodeClient.clearProcessActive(sessionID: sessionID)
        ConversationSteerMailbox.clearActiveTurn(threadID: sessionID)
        activeTurnID = nil
        activeMode = .code
        activeReadOnly = false
        isTurnActive = false
        pendingQuestion = nil
        pendingUserInputRequest = nil
        deltaHandler = nil
        finalMessageHandler = nil
        progressMessageHandler = nil
        steerMessageHandler = nil
        activityHandler = nil
        userInputHandler = nil
        stopProcess()
    }

    func interrupt() async throws -> Bool {
        guard activeTurnID != nil, isAgentRunning else { return false }
        wasInterrupted = true
        do {
            _ = try await controlRequest(["subtype": "interrupt"])
            return true
        } catch {
            wasInterrupted = false
            throw error
        }
    }

    /// Delivers input into the running turn with `priority: "next"`, which Claude
    /// Code injects at its next tool boundary without cancelling in-flight work.
    /// A turn Claude Code answered but that this runner still holds open — for
    /// an outstanding background task, an undelivered notification, or a parent
    /// wake — is as steerable as one still streaming: Playhouse keeps showing it
    /// as the active turn, so its input must still reach the running process.
    func sendSteerInput(text: String, imageDataURLs: [String]) async throws -> Bool {
        guard isTurnActive, activeTurnID != nil, isAgentRunning,
              !isTurnSettled || !turnCompletion.resultReceived || !pendingCommandUUIDs.isEmpty else {
            // A refusal is invisible to the user — the follow-up just stays
            // queued — so record why the runtime turned it down.
            PlayhouseDiagnostics.record("claude.turn.steer_rejected", fields: diagnosticFields([
                "isTurnSettled": String(isTurnSettled),
                "resultReceived": String(turnCompletion.resultReceived),
                "pendingCommandCount": String(pendingCommandUUIDs.count),
                "processRunning": String(isAgentRunning),
                "outstandingBackgroundTaskCount": String(outstandingBackgroundTaskIDs.count),
                "pendingBackgroundNotificationCount": String(pendingBackgroundTaskNotificationIDs.count),
                "awaitingParentWake": String(turnCompletion.awaitingParentWake),
                "resultCount": String(turnCompletion.resultCount),
                "wokenTurnCount": String(turnCompletion.wokenTurnCount)
            ]))
            return false
        }
        let uuid = UUID().uuidString.lowercased()
        pendingCommandUUIDs.insert(uuid)
        do {
            try await writeUserMessage(text: text, imageDataURLs: imageDataURLs, uuid: uuid, priority: "next")
        } catch {
            pendingCommandUUIDs.remove(uuid)
            throw error
        }
        // The answer to this input, not the result that preceded it, ends the turn.
        if turnCompletion.resultError == nil { turnCompletion.resultReceived = false }
        PlayhouseDiagnostics.record("claude.turn.steered", fields: diagnosticFields(["imageCount": String(imageDataURLs.count)]))
        return true
    }

    func answerUserInput(requestID: String, answers: [String: [String]]) -> Bool {
        guard let pending = pendingQuestion, pending.controlRequestID == requestID else { return false }
        let questionsByID = Dictionary(uniqueKeysWithValues: pending.questions.map { ($0.id, $0) })
        let valid = Set(answers.keys) == Set(questionsByID.keys) && answers.allSatisfy { id, values in
            guard !values.isEmpty, let question = questionsByID[id] else { return false }
            return values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && (question.allowsOther || values.allSatisfy { value in question.options.contains { $0.label == value } })
        }
        guard valid else {
            PlayhouseDiagnostics.record("claude.user_input.answer.failed", fields: [
                "requestID": requestID, "threadID": sessionID, "reason": "invalid_answer_shape"
            ])
            return false
        }
        var updatedInput = pending.input
        var answerMap: [String: String] = [:]
        for question in pending.questions {
            answerMap[question.question] = (answers[question.id] ?? []).joined(separator: ", ")
        }
        updatedInput["answers"] = answerMap
        do {
            try sendControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": updatedInput])
        } catch {
            actionRequestHandler?()
            return false
        }
        agentRun?.commitAnswer(requestID)
        clearPendingQuestion()
        PlayhouseDiagnostics.record("claude.user_input.answer.succeeded", fields: [
            "requestID": requestID, "threadID": sessionID, "questionCount": String(answers.count)
        ])
        return true
    }

    func rejectUserInput(requestID: String, message: String) {
        guard let pending = pendingQuestion, pending.controlRequestID == requestID else { return }
        clearPendingQuestion()
        try? sendControlResponse(requestID: requestID, response: ["behavior": "deny", "message": message, "interrupt": true])
        agentRun?.commitAnswer(requestID)
        finishTurn(.failure(ClientError.turnFailed(message)))
    }

    func shutdown() {
        stopProcess()
    }

    // MARK: - Process and protocol

    /// Starts this session's process. Claude Code only ever sees one session per
    /// process, so the working directory is the conversation's own worktree.
    func launch(
        resume: Bool,
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort?,
        workspace: ConversationWorkspaceContext,
        developerInstructions: String?
    ) async throws -> [String: Any] {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--forward-subagent-text",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", mode == .plan ? "plan" : "default"
        ]
        if !resume, let source = owner?.forkSourceSessionID(for: sessionID) {
            // A side chat's first turn copies the source session's context under its own ID.
            arguments += ["--resume", source, "--fork-session", "--session-id", sessionID]
        } else {
            arguments += [resume ? "--resume" : "--session-id", sessionID]
        }
        if workspace.isReadOnly {
            arguments += ["--disallowedTools", ClaudeSessionRunner.readOnlyDeniedTools.joined(separator: ",")]
        }
        if modelID != ClaudeCodeClient.defaultModelID { arguments += ["--model", modelID] }
        if !persistsSessions { arguments.append("--no-session-persistence") }
        for root in workspace.roots.dropFirst() { arguments += ["--add-dir", root.path] }
        // Skills from the Agent Skills folders reach Claude Code through a
        // Playhouse wrapper laid out as `.claude/skills`, and disabled skills are
        // turned off for this run only, so the user's settings stay untouched.
        if let bridge = workspace.skillBridge {
            for directory in bridge.claudeAddDirectories { arguments += ["--add-dir", directory] }
        }
        // Turned-off rule files are excluded the same way, AGENTS.md is read
        // alongside a CLAUDE.md, and the working repository's .mcp.json servers
        // are started or skipped, so they all share one --settings value.
        var settings = RuleBridgeLaunch.claudeSettingsJSON(skills: workspace.skillBridge, rules: workspace.ruleBridge, mcp: workspace.mcpBridge)
        if workspace.isReadOnly { settings = ClaudeSessionRunner.readOnlySettings(settings) }
        if let settings {
            arguments += ["--settings", settings]
        }
        // MCP servers Claude Code doesn't read itself, such as Codex's own or
        // another task repository's, are added for this run only.
        if let servers = workspace.mcpBridge?.claudeMcpConfig { arguments += ["--mcp-config", servers] }
        // Background Bash and Agent/Task calls report through Claude Code's task
        // events and keep the turn open, so Claude may end its response while
        // they run instead of blocking on a wait it cannot satisfy. Only a process
        // detached with `&` or `nohup` is invisible to Claude Code and Playhouse.
        var systemPrompt = ClaudeCodeClient.executionInstruction
        // Rule files Claude Code does not load itself, such as ~/.agents/AGENTS.md
        // or Codex's global AGENTS.md, follow the task's instructions.
        if let instructions = RuleBridgeLaunch.combined(developerInstructions, workspace.ruleBridge?.claudeInstructions) {
            systemPrompt += "\n\n" + instructions
        }
        arguments += ["--append-system-prompt", systemPrompt]

        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = ClaudeCodeClient.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: owner?.dataDirectoryOverride ?? nil)
        // Claude Code finds its keychain sign-in by user name; services started by
        // launchd are not guaranteed a login environment.
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        if let configDirectoryOverride { environment["CLAUDE_CONFIG_DIR"] = configDirectoryOverride }
        if let effort { environment["CLAUDE_CODE_EFFORT_LEVEL"] = effort.rawValue }
        // Claude Code auto-compacts once the context nears this many tokens,
        // instead of near the model's whole (up to 1M-token) window.
        if let window = workspace.claudeAutoCompactWindowTokens {
            environment[ContextCompactionSettings.autoCompactWindowVariable] = String(window)
        }
        // The CLI is a child of Playhouse, not an IDE integration or nested session.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")

        if let runsDirectory {
            let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
            stdoutBuffer.removeAll(keepingCapacity: true)
            stderrTail = ""
            sessionWasMissing = false
            let run: ClaudeAgentRun
            do {
                run = try ClaudeAgentRun.start(
                    runsDirectory: runsDirectory, sessionID: sessionID, mode: mode,
                    executable: command.executable, arguments: command.arguments,
                    environment: environment, workingDirectory: workspace.cwd.path
                )
            } catch {
                throw ClientError.processStart(error.localizedDescription)
            }
            agentRun = run
            followAgentRun(run)
            PlayhouseDiagnostics.record("claude.process.started", fields: diagnosticFields([
                "executable": executable,
                "workingDirectory": workspace.cwd.path,
                "processID": String(run.identity?.pid ?? -1),
                "resume": String(resume),
                "mode": mode.rawValue,
                "transport": "files",
                "environmentNames": environment.keys.sorted().joined(separator: ",")
            ]))
            return try await controlRequest(["subtype": "initialize"])
        }

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        child.executableURL = URL(fileURLWithPath: command.executable)
        child.arguments = command.arguments
        child.currentDirectoryURL = workspace.cwd
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        child.environment = environment
        process = child
        inputPipe = stdin
        stdoutBuffer.removeAll(keepingCapacity: true)
        stderrTail = ""
        sessionWasMissing = false
        // The provider's output and exit are handled outside the request that
        // launched it; keep that request's environment and diagnostics routing.
        let requestContext = PlayhouseRequestContext.capture()
        let pump = ProviderOutputPump(label: "claude") { [weak self] item in
            await requestContext.run {
                switch item {
                case .output(let data): await self?.consumeOutput(data)
                case .exit(let terminated): self?.processDidTerminate(terminated)
                case .ended: break // A piped child reports its exit as `.exit`.
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
        stderr.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                if child?.isRunning != true { handle.readabilityHandler = nil }
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4_000))
            }
        }
        child.terminationHandler = { terminated in
            pump.pushReading {
                stdout.fileHandleForReading.readabilityHandler = nil
                let remaining = ProviderOutputPump.readAvailableBytes(from: stdout.fileHandleForReading.fileDescriptor)
                return remaining.isEmpty ? nil : .output(remaining)
            }
            pump.push(.exit(terminated))
        }
        do {
            try child.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            process = nil
            inputPipe = nil
            throw ClientError.processStart(error.localizedDescription)
        }
        PlayhouseDiagnostics.record("claude.process.started", fields: diagnosticFields([
            "executable": executable,
            "workingDirectory": workspace.cwd.path,
            "processID": String(child.processIdentifier),
            "resume": String(resume),
            "mode": mode.rawValue,
            "environmentNames": environment.keys.sorted().joined(separator: ",")
        ]))
        return try await controlRequest(["subtype": "initialize"])
    }

    func controlRequest(_ request: [String: Any]) async throws -> [String: Any] {
        let requestID = "playhouse-\(nextControlRequestID)"
        // Recorded before it is sent, so a later daemon never reuses the number.
        agentRun?.recordRequestID(nextControlRequestID)
        nextControlRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingControlRequests[requestID] = continuation
            do {
                try queueJSON(["type": "control_request", "request_id": requestID, "request": request])
            } catch {
                pendingControlRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendControlResponse(requestID: String, response: [String: Any]) throws {
        try queueJSON(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": response]])
        agentRun?.noteAnswered(requestID)
    }

    private func sendControlError(requestID: String, message: String) {
        try? queueJSON(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": message]])
        agentRun?.noteAnswered(requestID)
    }

    private func writeUserMessage(text: String, imageDataURLs: [String], uuid: String, priority: String?) async throws {
        var content: [[String: Any]] = []
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        for dataURL in imageDataURLs {
            guard let comma = dataURL.firstIndex(of: ",") else { continue }
            let header = dataURL[..<comma]
            let mediaType = header.replacingOccurrences(of: "data:", with: "").replacingOccurrences(of: ";base64", with: "")
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": mediaType, "data": String(dataURL[dataURL.index(after: comma)...])
            ]])
        }
        var message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
            "parent_tool_use_id": NSNull(),
            "uuid": uuid
        ]
        if let priority { message["priority"] = priority }
        try await sendJSON(message)
    }

    /// Writes one line to Claude Code and returns once it is written; the main actor stays free
    /// while Claude Code reads it.
    private func sendJSON(_ object: [String: Any]) async throws {
        guard !isReplaying else { return }
        if let agentRun {
            guard agentRun.isRunning else { throw ClientError.processExited(stderrSummary()) }
            do {
                try await agentRun.write(Self.jsonLine(object))
            } catch {
                throw ClientError.protocolFailure(error.localizedDescription)
            }
            return
        }
        try writeToProcessPipe(object)
    }

    /// Queues one line for Claude Code without waiting. A line that fails stops the agent, whose
    /// exit fails the turn and any control request still waiting for its reply.
    private func queueJSON(_ object: [String: Any]) throws {
        guard !isReplaying else { return }
        if let agentRun {
            guard agentRun.isRunning else { throw ClientError.processExited(stderrSummary()) }
            do {
                try agentRun.send(Self.jsonLine(object))
            } catch {
                throw ClientError.protocolFailure(error.localizedDescription)
            }
            return
        }
        try writeToProcessPipe(object)
    }

    private static func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    private func writeToProcessPipe(_ object: [String: Any]) throws {
        guard let process, process.isRunning, let inputPipe else {
            throw ClientError.processExited(stderrSummary())
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw ClientError.protocolFailure(error.localizedDescription)
        }
    }

    /// Whether Claude has finished everything this logical turn owns: its
    /// result, steered input, background tasks, and any turn Claude Code starts
    /// to deliver a finished background task. A failure settles regardless.
    private var isTurnSettled: Bool {
        guard turnCompletion.resultReceived, pendingCommandUUIDs.isEmpty || !sawCommandLifecycle,
              outstandingBackgroundTaskIDs.isEmpty,
              pendingBackgroundTaskNotificationIDs.isEmpty else { return false }
        if turnCompletion.resultError != nil { return true }
        return !turnCompletion.awaitingParentWake && turnCompletion.resultCount > turnCompletion.wokenTurnCount
    }

    private func waitForTurnCompletion() async throws {
        if isTurnSettled {
            if let error = turnCompletion.resultError { throw error }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            turnWaiter = continuation
        }
    }

    private func finishTurn(_ result: Result<Void, Error>) {
        guard let waiter = turnWaiter else {
            if case .failure(let error) = result {
                turnCompletion.resultReceived = true
                turnCompletion.resultError = error
            }
            return
        }
        turnWaiter = nil
        switch result {
        case .success: waiter.resume()
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    private func stopProcess() {
        if let agentRun {
            self.agentRun = nil
            let threadID = sessionID
            Task { await TaskCPUUsageSampler.shared.forget(threadID: threadID) }
            let stopped = ClientError.processExited("Playhouse stopped Claude Code.")
            for continuation in pendingControlRequests.values { continuation.resume(throwing: stopped) }
            pendingControlRequests.removeAll()
            if turnWaiter != nil { finishTurn(.failure(stopped)) }
            // Its input never ends while it holds its own writer, so it is stopped by signal.
            Task { await agentRun.terminateAndRemove() }
            return
        }
        guard let process else { return }
        self.process = nil
        let threadID = sessionID
        Task { await TaskCPUUsageSampler.shared.forget(threadID: threadID) }
        let stopped = ClientError.processExited("Playhouse stopped Claude Code.")
        for continuation in pendingControlRequests.values { continuation.resume(throwing: stopped) }
        pendingControlRequests.removeAll()
        if turnWaiter != nil { finishTurn(.failure(stopped)) }
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    private func processDidTerminate(_ terminated: Process) {
        // A process stopped by `stopProcess` (or replaced by a relaunch) is no
        // longer this runner's; its late termination must not fail new requests.
        guard process === terminated else { return }
        PlayhouseDiagnostics.record("claude.process.exited", fields: diagnosticFields([
            "processID": String(terminated.processIdentifier),
            "exitStatus": String(terminated.terminationStatus)
        ]))
        let error: Error = sessionWasMissing || stderrTail.contains("No conversation found with session ID")
            ? ClientError.sessionNotFound
            : ClaudeCodeClient.classifyFailure(ClientError.processExited(stderrSummary(status: terminated.terminationStatus)), text: stderrTail)
        for continuation in pendingControlRequests.values { continuation.resume(throwing: error) }
        pendingControlRequests.removeAll()
        if !turnCompletion.resultReceived || turnWaiter != nil {
            finishTurn(.failure(error))
        }
        process = nil
        inputPipe = nil
    }

    private func followAgentRun(_ run: ClaudeAgentRun) {
        let requestContext = PlayhouseRequestContext.capture()
        run.follow(onLines: { [weak self, weak run] lines, end in
            await requestContext.run {
                guard let self else { return }
                for line in lines {
                    guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    await self.handle(message)
                }
                // Committed once the batch's transcript writes and replies are done.
                run?.commit(offset: end)
            }
        }, onExit: { [weak self, weak run] status in
            await requestContext.run {
                guard let self, let run else { return }
                self.agentRunDidExit(run, status: status)
            }
        })
    }

    private func agentRunDidExit(_ run: ClaudeAgentRun, status: Int32?) {
        guard agentRun === run else { return }
        stderrTail = run.stderrTail
        let exitCode = status.map { ($0 >> 8) & 0xFF }
        PlayhouseDiagnostics.record("claude.process.exited", fields: diagnosticFields([
            "processID": String(run.identity?.pid ?? -1),
            "exitStatus": exitCode.map(String.init) ?? "unknown",
        ]))
        let error: Error = if let inputFailure = run.inputFailure {
            // Playhouse stopped an agent that wouldn't take its input; say so, not "it exited".
            ClientError.protocolFailure(inputFailure.localizedDescription)
        } else if sessionWasMissing || stderrTail.contains("No conversation found with session ID") {
            ClientError.sessionNotFound
        } else {
            ClaudeCodeClient.classifyFailure(ClientError.processExited(stderrSummary(status: exitCode)), text: stderrTail)
        }
        if let inputFailure = run.inputFailure {
            PlayhouseDiagnostics.record("claude.input.failed", fields: diagnosticFields([
                "processID": String(run.identity?.pid ?? -1),
                "reason": inputFailure.localizedDescription,
            ]))
        }
        for continuation in pendingControlRequests.values { continuation.resume(throwing: error) }
        pendingControlRequests.removeAll()
        if !turnCompletion.resultReceived || turnWaiter != nil {
            finishTurn(.failure(error))
        }
    }

    /// Carries on a turn whose run outlived the daemon that started it. The lines that daemon
    /// already handled are replayed without side effects to rebuild this turn's state (its
    /// result, activities, background tasks, and any unanswered question); the rest of the log
    /// is handled live, and the run is followed to the turn's end.
    func reattach(
        _ run: ClaudeAgentRun,
        onAttached: () -> Void
    ) async throws -> ConversationReattachResult {
        activeMode = ConversationMode(rawValue: run.manifest.mode) ?? .code
        wakeGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS", default: ClaudeSessionRunner.parentWakeGracePeriod
        )
        wokenSilenceGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS", default: ClaudeSessionRunner.wokenTurnSilenceGracePeriod
        )
        agentRun = run
        nextControlRequestID = ClaudeRunFiles.firstRequestID(afterReattaching: run.manifest.maxRequestID)
        sessionExists = true
        turnCompletion = TurnCompletion()
        parentWakeBackstopGeneration += 1
        let handlers = (deltaHandler, finalMessageHandler, progressMessageHandler, steerMessageHandler,
                        activityHandler, actionRequestHandler, userInputHandler, tokenUsageHandler)
        (deltaHandler, finalMessageHandler, progressMessageHandler, steerMessageHandler) = (nil, nil, nil, nil)
        (activityHandler, actionRequestHandler, userInputHandler, tokenUsageHandler) = (nil, nil, nil, nil)
        isReplaying = true
        for line in run.handledLines() {
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            await handle(message)
        }
        isReplaying = false
        (deltaHandler, finalMessageHandler, progressMessageHandler, steerMessageHandler,
         activityHandler, actionRequestHandler, userInputHandler, tokenUsageHandler) = handlers
        // A line cut off mid-write ends the run at its next input, so the turn can't go on.
        if run.manifest.writeInProgress {
            PlayhouseDiagnostics.record("claude.turn.reattach_cut_off_write", fields: diagnosticFields([:]))
            agentRun = nil
            await run.terminateAndRemove()
            return .agentGone
        }
        let turnID = UUID().uuidString.lowercased()
        activeTurnID = turnID
        isTurnActive = true
        owner?.runnerStateChanged(self)
        ClaudeCodeClient.markProcessActive(sessionID: sessionID)
        ConversationSteerMailbox.publishActiveTurn(threadID: sessionID, turnID: turnID)
        PlayhouseDiagnostics.record("claude.turn.reattached", fields: diagnosticFields([
            "threadID": sessionID,
            "turnID": turnID,
            "processAlive": String(run.isRunning),
            "consumedOffset": String(run.manifest.consumedOffset),
        ]))
        if let pending = pendingQuestion {
            let request = ConversationUserInputRequest(id: pending.controlRequestID, threadID: sessionID, questions: pending.questions, isBlocking: true, mode: activeMode)
            let handler = userInputHandler
            Task { @MainActor in
                await handler?(request)
                guard self.pendingQuestion?.controlRequestID == request.id else { return }
                self.pendingUserInputRequest = request
                self.owner?.runnerStateChanged(self)
            }
        }
        onAttached()
        followAgentRun(run)
        let mailboxTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.activeTurnID == turnID {
                await ConversationSteerMailbox.service(threadID: self.sessionID, turnID: turnID) { text, images in
                    let accepted = try await self.sendSteerInput(text: text, imageDataURLs: images)
                    if accepted { self.steerMessageHandler?(text, images) }
                    return accepted
                } interrupt: {
                    try await self.interrupt()
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        defer { mailboxTask.cancel() }
        try await waitForTurnCompletion()
        PlayhouseDiagnostics.record("claude.turn.ended", fields: diagnosticFields([
            "threadID": sessionID, "turnID": turnID, "turnStatus": "completed"
        ]))
        return .finished
    }

    private func stderrSummary(status: Int32? = nil) -> String {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).suffix(3).joined(separator: " ")
        let exit = status.map { "Claude Code exited with status \($0)." } ?? "Restart Playhouse and try again."
        return detail.isEmpty ? exit : "\(exit) \(detail)"
    }

    private func consumeOutput(_ data: Data) async {
        stdoutBuffer.append(data)
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            await handle(message)
        }
    }

    func debugImportReplay(_ message: [String: Any]) async { await handle(message) } // DEBUG-IMPORT: replays a recorded session line through the live handler.

    private func handle(_ message: [String: Any]) async {
        switch message["type"] as? String {
        case "control_response":
            guard let response = message["response"] as? [String: Any],
                  let requestID = response["request_id"] as? String,
                  let continuation = pendingControlRequests.removeValue(forKey: requestID) else { return }
            if response["subtype"] as? String == "error" {
                continuation.resume(throwing: ClientError.protocolFailure(response["error"] as? String ?? "Claude Code rejected a control request."))
            } else {
                continuation.resume(returning: response["response"] as? [String: Any] ?? [:])
            }
        case "control_request":
            guard let requestID = message["request_id"] as? String,
                  let request = message["request"] as? [String: Any] else { return }
            await handleControlRequest(requestID: requestID, request: request)
        case "command_lifecycle":
            sawCommandLifecycle = true
            guard let uuid = message["command_uuid"] as? String,
                  ["completed", "cancelled", "failed"].contains(message["state"] as? String ?? "") else { return }
            pendingCommandUUIDs.remove(uuid)
            completeTurnIfSettled()
        case "stream_event":
            guard message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil else { return }
            noteParentResponseStarted()
            // A new parent request carries any notification queued before it.
            if (message["event"] as? [String: Any])?["type"] as? String == "message_start" {
                setAwaitingParentWake(false)
            }
            guard let event = message["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            deltaHandler?(text)
        case "assistant":
            handleAssistant(message)
        case "user":
            if handleSyntheticUserMessage(message) { return }
            handleToolResults(message)
        case "system":
            handleSystem(message)
        case "result":
            handleResult(message)
        case "rate_limit_event":
            // Account-wide, so it feeds the shared store rather than this turn.
            guard !isReplaying else { return }
            AgentUsageStore.shared(scope: owner?.runtimeScope).recordClaudeEvent(message)
        default:
            break
        }
    }

    private func handleControlRequest(requestID: String, request: [String: Any]) async {
        // A previous daemon of this run already answered it.
        if let agentRun, agentRun.manifest.hasAnswered(requestID) { return }
        if isReplaying {
            // Only a question still waiting for the user carries over from handled lines.
            guard agentRun?.manifest.pendingRequestIDs.contains(requestID) == true,
                  request["tool_name"] as? String == "AskUserQuestion" else { return }
            presentQuestions(requestID: requestID, input: request["input"] as? [String: Any] ?? [:])
            return
        }
        guard request["subtype"] as? String == "can_use_tool" else {
            if request["subtype"] as? String == "elicitation" { actionRequestHandler?() }
            sendControlError(requestID: requestID, message: "Playhouse does not provide this optional integration.")
            return
        }
        let toolName = request["tool_name"] as? String ?? ""
        let input = request["input"] as? [String: Any] ?? [:]
        switch toolName {
        case "AskUserQuestion":
            presentQuestions(requestID: requestID, input: input)
        case "ExitPlanMode" where activeMode == .plan:
            // Playhouse keeps plan mode until the user starts implementation, so the
            // plan becomes this turn's answer and Claude stops without editing.
            if let pendingAssistantText {
                emitProgress(id: pendingAssistantText.id, text: pendingAssistantText.text)
                self.pendingAssistantText = nil
            }
            let plan = (input["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !plan.isEmpty {
                planWasPresented = true
                finalMessageHandler?(plan)
            }
            try? sendControlResponse(requestID: requestID, response: [
                "behavior": "deny",
                "message": "Playhouse showed this plan to the user, who will reply in a later message. End your turn now without further output."
            ])
        case _ where activeReadOnly && !ClaudeSessionRunner.readOnlyAllows(toolName: toolName, input: input):
            try? sendControlResponse(requestID: requestID, response: [
                "behavior": "deny",
                "message": SideChatReadOnlyPolicy.denialMessage
            ])
        default:
            // Code mode runs without approval prompts. Claude Code has already
            // applied the user's native allow and deny rules before asking.
            try? sendControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": input])
        }
    }

    /// The tools a read-only turn never gets, removed from its launch as well as denied.
    static let readOnlyDeniedTools = SideChatReadOnlyPolicy.deniedTools

    /// Whether a read-only turn may use a tool Claude Code asked about (see `SideChatReadOnlyPolicy`).
    static func readOnlyAllows(toolName: String, input: [String: Any]) -> Bool {
        SideChatReadOnlyPolicy.allows(toolName: toolName, input: input, cliPaths: [TaskThreadDeveloperInstructions.cliExecutableURL().path])
    }

    /// The launch's `--settings` with the read-only `PreToolUse` hook added, so every tool call
    /// is checked before the user's own Claude Code allow rules can approve it.
    static func readOnlySettings(_ settings: String?) -> String? {
        var object = settings.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
        let cli = TaskThreadDeveloperInstructions.cliExecutableURL().path
        let command = ([cli] + SideChatReadOnlyPolicy.hookSubcommand)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        var hooks = object["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append(["matcher": "*", "hooks": [["type": "command", "command": command]]])
        hooks["PreToolUse"] = preToolUse
        object["hooks"] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return settings }
        return String(data: data, encoding: .utf8)
    }

    private func presentQuestions(requestID: String, input: [String: Any]) {
        let rawQuestions = input["questions"] as? [[String: Any]] ?? []
        let questions = rawQuestions.enumerated().compactMap { index, raw -> ConversationUserQuestion? in
            guard let question = raw["question"] as? String, !question.isEmpty else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> ConversationUserQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return .init(label: label, description: option["description"] as? String)
            }
            return ConversationUserQuestion(
                id: "question-\(index + 1)", header: raw["header"] as? String ?? "Question",
                question: question, options: options, allowsOther: true, isSecret: false
            )
        }
        guard !questions.isEmpty else {
            try? sendControlResponse(requestID: requestID, response: ["behavior": "deny", "message": "The question had no content."])
            return
        }
        if let pendingAssistantText {
            emitProgress(id: pendingAssistantText.id, text: pendingAssistantText.text)
            self.pendingAssistantText = nil
        }
        pendingQuestion = PendingQuestion(controlRequestID: requestID, sessionID: sessionID, input: input, questions: questions)
        if !isReplaying { agentRun?.notePending(requestID) }
        let request = ConversationUserInputRequest(id: requestID, threadID: sessionID, questions: questions, isBlocking: true, mode: activeMode)
        if isReplaying {
            return
        }
        let handler = userInputHandler
        Task { @MainActor in
            await handler?(request)
            // The handler rejects private reminder questions before they can be shown.
            // Publish only a request that survived that decision (and any answer).
            guard self.pendingQuestion?.controlRequestID == requestID else { return }
            self.pendingUserInputRequest = request
            self.owner?.runnerStateChanged(self)
        }
    }

    private func clearPendingQuestion() {
        pendingQuestion = nil
        pendingUserInputRequest = nil
        owner?.runnerStateChanged(self)
    }

    /// Reports one model call as soon as the stream shows it. Claude Code
    /// writes an `assistant` message per content block of a call, all sharing
    /// the call's message ID, so the first sight counts the call and later
    /// ones only add what its usage has since grown by.
    private func reportLiveCall(_ body: [String: Any], agentID: String?) {
        guard let id = body["id"] as? String, let payload = body["usage"] as? [String: Any] else { return }
        let usage = ConversationTokenUsage(providerPayload: payload)
        let sent = usage.inputTokens + usage.cacheReadTokens + usage.cacheCreationTokens
        guard sent + usage.outputTokens > 0 else { return }
        let previous = liveCallUsage[id]
        guard previous?.sent != sent || previous?.output != usage.outputTokens else { return }
        liveCallUsage[id] = (sent, usage.outputTokens, usage)
        tokenUsageHandler?(ConversationTurnUsageReport(
            turnID: nil, usage: ConversationTokenUsage(), toolLabels: [],
            liveCall: ConversationLiveCall(
                agentID: agentID,
                calls: previous == nil ? 1 : 0,
                sentTokens: sent - (previous?.sent ?? 0),
                outputTokens: usage.outputTokens - (previous?.output ?? 0),
                uncachedInputTokens: usage.inputTokens - (previous?.usage.inputTokens ?? 0),
                cacheReadTokens: usage.cacheReadTokens - (previous?.usage.cacheReadTokens ?? 0),
                cacheWriteTokens: usage.cacheCreationTokens - (previous?.usage.cacheCreationTokens ?? 0),
                contextTokens: sent
            )
        ))
    }

    private func handleAssistant(_ message: [String: Any]) {
        guard let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        let parentToolID = message["parent_tool_use_id"] as? String
        reportLiveCall(body, agentID: parentToolID)
        let messageID = body["id"] as? String ?? UUID().uuidString
        if parentToolID == nil { noteParentResponseStarted() }
        for (index, block) in content.enumerated() {
            switch block["type"] as? String {
            case "text":
                guard parentToolID == nil, !planWasPresented,
                      let text = block["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let pending = pendingAssistantText, pendingTextSpansOutcomeReport {
                    // Claude often answers, reports the outcome, then adds a closing
                    // line; the answer must not be demoted to commentary.
                    pendingAssistantText = (pending.id, pending.text + "\n\n" + text)
                    pendingTextSpansOutcomeReport = false
                    continue
                }
                if let pending = pendingAssistantText { emitProgress(id: pending.id, text: pending.text) }
                pendingAssistantText = ("\(messageID)-\(index)", text)
                pendingTextSpansOutcomeReport = false
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                if let parentToolID {
                    noteSubagentProgress(parentToolID: parentToolID, toolName: name)
                    continue
                }
                if name == "AskUserQuestion" || (name == "ExitPlanMode" && activeMode == .plan) { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                // Playhouse's own progress, outcome, and chat page reports are
                // bookkeeping, not work, so they don't turn the answer written
                // before them into commentary.
                let report = ClaudeCodeClient.reportCommand(name: name, input: input)
                if pendingAssistantText != nil, let report {
                    if report == .outcome { pendingTextSpansOutcomeReport = true }
                } else if let pending = pendingAssistantText {
                    emitProgress(id: pending.id, text: pending.text)
                    pendingAssistantText = nil
                    pendingTextSpansOutcomeReport = false
                }
                activityStartedAtUptime[toolID] = DispatchTime.now().uptimeNanoseconds
                if ["Task", "Agent", "Bash"].contains(name), input["run_in_background"] as? Bool == true {
                    backgroundedToolUseIDs.insert(toolID)
                }
                let activity = ClaudeCodeClient.activity(toolID: toolID, name: name, input: input, status: "inProgress", turnID: activeTurnID)
                toolActivities[toolID] = activity
                activityHandler?(activity)
            default:
                continue
            }
        }
    }

    private func noteSubagentProgress(parentToolID: String, toolName: String) {
        guard var activity = toolActivities[parentToolID], activity.isSubagent else { return }
        activity.detail = [activity.agentPath, "Using \(toolName)"].compactMap { $0 }.joined(separator: "\n")
        toolActivities[parentToolID] = activity
        activityHandler?(activity)
    }

    /// Claude Code adds a user message of its own inside a turn, for example when the turn ended
    /// on a tool call with no visible text after it. It is not the user's, so it is recorded as an
    /// automatic notice. The answer written before it is closed as its own final message, so
    /// whatever Claude writes in response is a separate message rather than appended to it.
    private func handleSyntheticUserMessage(_ message: [String: Any]) -> Bool {
        guard message["isSynthetic"] as? Bool == true,
              message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil,
              let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return false }
        let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let pending = pendingAssistantText {
            pendingAssistantText = nil
            pendingTextSpansOutcomeReport = false
            finalMessageHandler?(pending.text)
        }
        // The event's own ID keeps a replayed run from recording the notice twice.
        let id = "claude-notice-\((message["uuid"] as? String) ?? UUID().uuidString.lowercased())"
        progressMessageHandler?(ConversationMessage(
            id: id, role: .user, text: ProviderAutomaticNotice.claudeCode(text), turnID: activeTurnID, provider: .claude
        ))
        return true
    }

    private func handleToolResults(_ message: [String: Any]) {
        guard message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil,
              let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String, var activity = toolActivities[toolID] else { continue }
            let output = ClaudeCodeClient.resultText(block["content"])
            // A backgrounded Agent/Task call's tool_result only confirms the launch,
            // not completion; its real outcome arrives later as a system task event.
            // The launch confirmation is still what the call returned.
            if backgroundedToolUseIDs.contains(toolID) {
                if activity.isTimelineToolCall, activity.input != nil, !output.isEmpty {
                    activity.output = String(output.suffix(2_000))
                    toolActivities[toolID] = activity
                    activityHandler?(activity)
                }
                continue
            }
            let isError = block["is_error"] as? Bool ?? false
            var detail = activity.detail
            if !output.isEmpty, activity.toolKind != "mcp" {
                detail = [detail, String(output.suffix(2_000))].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            let duration = activityStartedAtUptime.removeValue(forKey: toolID).map {
                max(1, Int((DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000))
            }
            activity = ConversationActivity(
                id: activity.id, title: activity.title, detail: detail, status: isError ? "failed" : "completed",
                childThreadID: activity.childThreadID, agentPath: activity.agentPath, model: activity.model,
                toolKind: activity.toolKind, server: activity.server, tool: activity.tool,
                durationMs: duration, turnID: activity.turnID,
                summary: activity.summary, input: activity.input,
                // Only a call with an IN block shows what it returned; a file read's
                // contents, say, would just repeat the file.
                output: activity.isTimelineToolCall && activity.input != nil && !output.isEmpty
                    ? String(output.suffix(2_000)) : activity.output
            )
            if let duration { activityDurations[activity.id] = duration }
            toolActivities[toolID] = activity
            activityHandler?(activity)
        }
    }

    /// Background Agent/Task progress arrives as `system` events (enabled by
    /// `--forward-subagent-text`), not as a `tool_result` on the launching turn,
    /// since the agent can keep running after that turn's own answer is given.
    private func handleSystem(_ message: [String: Any]) {
        guard let subtype = message["subtype"] as? String else { return }
        switch subtype {
        case "init":
            // Claude Code starts a provider turn of its own to deliver a finished
            // background task; that turn's result also belongs to this one. The
            // wake itself stays pending until that turn's parent request starts,
            // which is what clears it below: `init` alone means Claude Code has
            // not delivered the notification yet, and a turn that counted the
            // woken result here while clearing the wake could look settled with
            // nothing running — stranding the turn open (no backstop is armed
            // once the wake is clear) and making the runtime refuse steered
            // input for a turn Playhouse still shows as active.
            if turnCompletion.awaitingParentWake, !turnCompletion.countedWakeInit {
                turnCompletion.countedWakeInit = true
                turnCompletion.wokenTurnCount += 1
                scheduleParentWakeBackstopIfNeeded()
            }
        case "status":
            // Claude Code compacts before the call that would cross its
            // auto-compact window, and for `/compact`; either way it reports
            // the start here and the result as a boundary.
            let rowID = "claude-compaction-\((message["uuid"] as? String) ?? UUID().uuidString.lowercased())"
            if message["status"] as? String == "compacting" {
                pendingCompactionActivityID = rowID
                activityHandler?(compactionActivity(id: rowID, status: "inProgress", details: nil))
            } else if let result = message["compact_result"] as? String, result != "success",
                      let pending = pendingCompactionActivityID {
                pendingCompactionActivityID = nil
                activityHandler?(compactionActivity(id: pending, status: "failed", details: nil))
            }
        case "compact_boundary":
            let metadata = message["compact_metadata"] as? [String: Any] ?? [:]
            let rowID = pendingCompactionActivityID
                ?? "claude-compaction-\((message["uuid"] as? String) ?? UUID().uuidString.lowercased())"
            pendingCompactionActivityID = nil
            let details = ContextCompactionDetails(
                trigger: .reported(metadata["trigger"] as? String, requested: compactionTrigger),
                preTokens: (metadata["pre_tokens"] as? NSNumber)?.intValue,
                postTokens: (metadata["post_tokens"] as? NSNumber)?.intValue
            )
            activityHandler?(compactionActivity(id: rowID, status: "completed", details: details))
        case "background_tasks_changed":
            let tasks = message["tasks"] as? [[String: Any]] ?? []
            outstandingBackgroundTaskIDs = Set(tasks.compactMap { $0["task_id"] as? String })
            completeTurnIfSettled()
        case "task_started":
            guard let taskID = message["task_id"] as? String,
                  let toolUseID = message["tool_use_id"] as? String else { return }
            let taskType = message["task_type"] as? String
            guard message["owned_by_subagent"] as? Bool != true,
                  taskType == "local_agent" || taskType == "local_bash" else {
                nestedBackgroundTaskIDs.insert(taskID)
                return
            }
            if taskType == "local_bash" { backgroundShellTaskIDs.insert(taskID) }
            pendingBackgroundTaskNotificationIDs.insert(taskID)
            backgroundTaskToolUseIDs[taskID] = toolUseID
            guard var activity = toolActivities[toolUseID] else { return }
            activity.backgroundTaskID = taskID
            toolActivities[toolUseID] = activity
            activityHandler?(activity)
        case "task_progress":
            guard let taskID = message["task_id"] as? String, !nestedBackgroundTaskIDs.contains(taskID),
                  let toolUseID = (message["tool_use_id"] as? String) ?? backgroundTaskToolUseIDs[taskID],
                  var activity = toolActivities[toolUseID] else { return }
            let lastTool = message["last_tool_name"] as? String
            activity.detail = [activity.agentPath, lastTool.map { "Using \($0)" }].compactMap { $0 }.joined(separator: "\n")
            activity.backgroundTaskID = taskID
            toolActivities[toolUseID] = activity
            activityHandler?(activity)
        case "task_updated", "task_notification":
            guard let taskID = message["task_id"] as? String else { return }
            let isTaskNotification = subtype == "task_notification"
            if isTaskNotification {
                outstandingBackgroundTaskIDs.remove(taskID)
                pendingBackgroundTaskNotificationIDs.remove(taskID)
            }
            guard !nestedBackgroundTaskIDs.contains(taskID) else { return }
            // Claude Code delivers every top-level notification to the parent.
            if isTaskNotification { setAwaitingParentWake(true) }
            let isShell = backgroundShellTaskIDs.contains(taskID)
            let patch = message["patch"] as? [String: Any]
            guard let rawStatus = (message["status"] as? String) ?? (patch?["status"] as? String) else {
                completeTurnIfSettled()
                return
            }
            let status = Self.resolvedBackgroundTaskStatus(rawStatus)
            let summary = message["summary"] as? String
            // A task_updated event can report a terminal status before Claude
            // sends the task_notification containing the actual agent result.
            // Keep the activity and parent turn open until that result arrives.
            if !isTaskNotification, status != "inProgress" {
                pendingBackgroundTaskNotificationIDs.insert(taskID)
                completeTurnIfSettled()
                return
            }
            if let toolUseID = (message["tool_use_id"] as? String) ?? backgroundTaskToolUseIDs[taskID],
               let existing = toolActivities[toolUseID] {
                let duration = activityStartedAtUptime.removeValue(forKey: toolUseID).map {
                    max(1, Int((DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000))
                }
                let activity = ConversationActivity(
                    id: existing.id, title: existing.title, detail: summary ?? existing.detail, status: status,
                    childThreadID: existing.childThreadID, agentPath: existing.agentPath, model: existing.model,
                    toolKind: existing.toolKind, server: existing.server, tool: existing.tool,
                    durationMs: duration ?? existing.durationMs, turnID: existing.turnID, backgroundTaskID: taskID,
                    backgroundTaskSummary: isShell ? nil : summary ?? existing.backgroundTaskSummary
                ).preservingTimelineFields(of: existing)
                if let duration { activityDurations[activity.id] = duration }
                toolActivities[toolUseID] = activity
                activityHandler?(activity)
            } else {
                // No in-memory record: a prior process started this agent and this
                // runner never saw its task_started. Surface a synthetic update keyed
                // only by backgroundTaskID so the owner can resolve it against the
                // persisted activity from whichever earlier turn launched it.
                activityHandler?(ConversationActivity(
                    id: taskID, title: "Background agent", detail: summary ?? "", status: status,
                    backgroundTaskID: taskID, backgroundTaskSummary: summary
                ))
            }
            completeTurnIfSettled()
        default:
            break
        }
    }

    /// The timeline row of one compaction. Claude Code names Playhouse's own
    /// `/compact` a manual one, so the trigger Playhouse asked for labels it.
    private func compactionActivity(id: String, status: String, details: ContextCompactionDetails?) -> ConversationActivity {
        let trigger = details?.trigger ?? compactionTrigger
        let automatic = trigger?.isAutomatic ?? false
        let detail: String
        switch status {
        case "inProgress": detail = automatic ? "Automatic · \(trigger?.label ?? "")" : ""
        case "failed": detail = "Claude Code couldn't compact the context."
        default: detail = details?.summary ?? ""
        }
        return ConversationActivity(
            id: id, title: status == "failed"
                ? (automatic ? "Automatic context compaction failed" : "Context compaction failed")
                : (automatic ? "Context compacted automatically" : "Context compacted"), detail: detail,
            status: status, isContextCompaction: true, turnID: activeTurnID, compaction: details
        )
    }

    private static func resolvedBackgroundTaskStatus(_ status: String) -> String {
        switch status {
        case "completed": "completed"
        case "stopped": "stopped"
        default: "failed"
        }
    }

    private func handleResult(_ message: [String: Any]) {
        let subtype = message["subtype"] as? String ?? ""
        let isError = message["is_error"] as? Bool ?? (subtype != "success")
        reportTokenUsage(message)
        if isError {
            let text = (message["result"] as? String) ?? (message["errors"] as? [String])?.joined(separator: " ") ?? ""
            if text.contains("No conversation found with session ID") { sessionWasMissing = true }
            let error: Error
            if wasInterrupted {
                error = ClientError.turnFailed("The Claude turn was interrupted.")
            } else {
                error = ClaudeCodeClient.classifyFailure(ClientError.turnFailed(text.isEmpty ? "Claude couldn't complete this turn (\(subtype))." : text), text: text)
            }
            turnCompletion.resultReceived = true
            turnCompletion.resultError = error
            // An interrupt or failure ends the logical turn even if steered input is queued.
            pendingCommandUUIDs.removeAll()
        } else {
            turnCompletion.resultReceived = true
        }
        turnCompletion.resultCount += 1
        completeTurnIfSettled()
    }

    /// Claude Code reports a turn's token cost on its `result` message. A logical
    /// Playhouse turn can take several results (each background-task wake owes
    /// its own), so every result's usage is reported and the recorder sums them.
    private func reportTokenUsage(_ message: [String: Any]) {
        guard let payload = message["usage"] as? [String: Any] else { return }
        let usage = ConversationTokenUsage(providerPayload: payload)
        guard !usage.isEmpty else {
            // A non-empty payload that parses to all zeros means Claude Code
            // changed its usage field names; silently dropping it would make a
            // real regression invisible.
            PlayhouseDiagnostics.record("claude.turn.usage_unparsed", fields: diagnosticFields([
                "payloadKeys": payload.keys.sorted().joined(separator: ","),
            ]))
            return
        }
        let labels = toolActivities.values
            .filter { $0.turnID == activeTurnID }
            .map(\.tokenUsageLabel)
        tokenUsageHandler?(ConversationTurnUsageReport(
            turnID: activeTurnID,
            usage: usage,
            toolLabels: Array(Set(labels)).sorted()
        ))
    }

    /// Every change to the expected wake invalidates a pending backstop, so a
    /// timer started for one notification can't clear a later one.
    private func setAwaitingParentWake(_ awaiting: Bool) {
        turnCompletion.awaitingParentWake = awaiting
        turnCompletion.countedWakeInit = false
        parentWakeBackstopGeneration += 1
    }

    /// When only an undelivered background notification holds a finished turn
    /// open, settle after a grace period: Claude Code normally starts the woken
    /// turn within milliseconds, and a notification it consumed without a new
    /// request must not hold the task In Progress indefinitely. A woken turn
    /// Claude Code announced with `system init` and then never spoke in is
    /// covered too, on its own longer grace, so a turn whose expected woken
    /// result never arrives still settles rather than staying active forever.
    private func scheduleParentWakeBackstopIfNeeded() {
        guard turnCompletion.awaitingParentWake, turnCompletion.resultError == nil,
              turnCompletion.resultReceived,
              outstandingBackgroundTaskIDs.isEmpty, pendingBackgroundTaskNotificationIDs.isEmpty else { return }
        parentWakeBackstopGeneration += 1
        let generation = parentWakeBackstopGeneration
        // A wake whose woken turn already announced itself gets the long grace:
        // that turn exists, so silence may only mean it is slow to speak.
        let announced = turnCompletion.countedWakeInit
        let grace = announced ? wokenSilenceGrace : wakeGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.parentWakeBackstopGeneration == generation,
                  self.turnCompletion.awaitingParentWake else { return }
            PlayhouseDiagnostics.record("claude.turn.parent_wake_timeout", fields: self.diagnosticFields([
                "wokenTurnAnnounced": String(announced)
            ]))
            // The woken turn this wake was counted for never produced a result
            // of its own, so the turn stops owing one. Without this the counted
            // wake outlives the notification it belonged to and the turn can
            // never satisfy `resultCount > wokenTurnCount` again.
            if self.turnCompletion.countedWakeInit { self.turnCompletion.wokenTurnCount -= 1 }
            self.setAwaitingParentWake(false)
            self.completeTurnIfSettled()
        }
    }

    /// Claude Code wakes the parent for a background agent's notification after
    /// its earlier result, so any new parent response means that result no
    /// longer ends the turn; only the parent's next result does.
    private func noteParentResponseStarted() {
        guard turnCompletion.resultReceived, turnCompletion.resultError == nil else { return }
        turnCompletion.resultReceived = false
    }

    private func completeTurnIfSettled() {
        guard isTurnSettled else {
            scheduleParentWakeBackstopIfNeeded()
            return
        }
        if let error = turnCompletion.resultError {
            finishTurn(.failure(error))
            return
        }
        if let pending = pendingAssistantText {
            pendingAssistantText = nil
            finalMessageHandler?(pending.text)
        }
        // A completed turn has no running tools left to observe.
        for (id, var activity) in toolActivities where activity.isActive {
            activity = ConversationActivity(
                id: activity.id, title: activity.title, detail: activity.detail, status: "completed",
                childThreadID: activity.childThreadID, agentPath: activity.agentPath, model: activity.model,
                toolKind: activity.toolKind, server: activity.server, tool: activity.tool, turnID: activity.turnID
            ).preservingTimelineFields(of: activity)
            toolActivities[id] = activity
            activityHandler?(activity)
        }
        finishTurn(.success(()))
    }

    private func emitProgress(id: String, text: String) {
        progressMessageHandler?(ConversationMessage(
            id: id, role: .assistant, text: text, phase: "commentary", turnID: activeTurnID, provider: .claude
        ))
    }
}

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
    private static var processActiveSessionIDs = Set<String>()
    /// Session-to-runner routing for this process, so steering, interrupts, and
    /// answers reach the right turn no matter which client started it.
    private static var activeRunnersBySessionID: [String: ClaudeSessionRunner] = [:]
    private static var sharedPrimaryClients: [String: ClaudeCodeClient] = [:]

    @Published private(set) var isTurnActive = false
    /// Every conversation with a running turn. A view observes this instead of
    /// `isTurnActive` so one conversation's turn ending is still an observable
    /// change while another conversation keeps running.
    @Published private(set) var activeThreadIDs: Set<String> = []
    @Published private(set) var pendingUserInputRequest: ConversationUserInputRequest?

    private(set) var isPreparingForApplicationTermination = false

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

    private let executableOverride: String?
    private let configDirectoryOverride: String?
    private let persistsSessions: Bool
    /// This instance's own resolved data directory, fixed at construction time
    /// (debug/test builds only; always `nil` in production). Forwarded by each
    /// `ClaudeSessionRunner` into its own child process instead of an ambient
    /// global, so a different client instance's concurrently-resolved
    /// directory can never leak into this one's child process environment.
    fileprivate let dataDirectoryOverride: String?
    /// The data directory this client serves (debug/test isolation); nil in production.
    var runtimeScope: String? { dataDirectoryOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
    private var runners: [String: ClaudeSessionRunner] = [:]
    private var runsDirectory: URL?
    private var newSessionIDs = Set<String>()
    private var forkSourceSessionIDs: [String: String] = [:]
    /// The trigger of the `/compact` turn `compactSession` is about to run, by session.
    private var requestedCompactionTriggers: [String: ContextCompactionTrigger] = [:]
    private var startingSessionIDs = Set<String>()
    private var interruptedThreadIDs = Set<String>()
    /// The process and turn identity each conversation last ran under, so a
    /// failure recorded after the runner is torn down still names its own turn.
    private var lastTurnDiagnosticsByThread: [String: [String: String]] = [:]
    private var activityDurationsByThread: [String: [String: Int]] = [:]
    private var lastFinishedThreadID: String?
    private var conversationOperationsInFlight = 0
    private static let bundledSkillsLifetime: TimeInterval = 10 * 60
    private var bundledSkillsCache: (readAt: Date, skills: [(name: String, description: String)])?
    /// The plan usage read in flight, and whether another was asked for meanwhile.
    fileprivate var planUsageRead: Task<Void, Never>?
    fileprivate var planUsageReadQueued = false
    fileprivate static let planUsageReadTimeout: Duration = .seconds(15)

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
        configDirectoryOverride
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
    private final class McpLoginSession {
        let runner: ClaudeSessionRunner
        var task: Task<McpLoginResult, Never>?
        /// A newer sign-in to the same server replaced this one.
        var superseded = false
        init(runner: ClaudeSessionRunner) { self.runner = runner }
    }

    private var mcpLogins: [String: McpLoginSession] = [:]

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
        runner.progressMessageHandler = onProgressMessage
        runner.steerMessageHandler = onSteerMessage
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

    private func runner(for threadID: String) -> ClaudeSessionRunner? {
        runners[threadID] ?? Self.activeRunnersBySessionID[threadID]
    }

    // MARK: - Metadata

    private struct MetadataResponse {
        let initialize: [String: Any]
        let extra: [String: Any]
    }

    /// Starts a short-lived process that never receives a prompt, so no model
    /// request is made, and reads its initialize response plus one extra query.
    private func withMetadataSession(
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

    static func reportCommand(name: String, input: [String: Any]) -> TaskProgressReportInstructions.ReportCommand? {
        guard name == "Bash", let command = input["command"] as? String else { return nil }
        return TaskProgressReportInstructions.reportCommand(in: command)
    }

    static func activity(toolID: String, name: String, input: [String: Any], status: String, turnID: String?) -> ConversationActivity {
        var activity = baseActivity(toolID: toolID, name: name, input: input, status: status, turnID: turnID)
        guard activity.isTimelineToolCall else { return activity }
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash":
            activity.summary = string("description")
            activity.input = string("command").map { String($0.prefix(ConversationActivity.timelineInputLimit)) }
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "Read":
            activity.summary = string("file_path") ?? string("notebook_path")
        case "Grep", "Glob":
            activity.summary = [string("pattern"), string("path")].compactMap { $0 }.joined(separator: " in ")
        case "WebSearch":
            activity.summary = string("query")
        case "WebFetch":
            activity.summary = string("url")
        default:
            // MCP and other tools keep their arguments and raw results private.
            break
        }
        return activity
    }

    private static func baseActivity(toolID: String, name: String, input: [String: Any], status: String, turnID: String?) -> ConversationActivity {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash":
            let command = string("command") ?? ""
            return ConversationActivity(id: toolID, title: command.isEmpty ? "Running command" : "Running \(command)", detail: string("description") ?? "", status: status, tool: name, turnID: turnID)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = string("file_path") ?? string("notebook_path") ?? ""
            return ConversationActivity(id: toolID, title: "Editing 1 file", detail: path, status: status, tool: name, turnID: turnID)
        case "Read":
            return ConversationActivity(id: toolID, title: "Reading \(string("file_path").map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file")", detail: string("file_path") ?? "", status: status, tool: name, turnID: turnID)
        case "Grep", "Glob":
            return ConversationActivity(id: toolID, title: "Searching files", detail: string("pattern") ?? "", status: status, tool: name, turnID: turnID)
        case "WebSearch":
            return ConversationActivity(id: toolID, title: "Searching the web", detail: string("query") ?? "", status: status, tool: name, turnID: turnID)
        case "WebFetch":
            return ConversationActivity(id: toolID, title: "Fetching a web page", detail: string("url") ?? "", status: status, tool: name, turnID: turnID)
        case "Task", "Agent":
            let agentType = string("subagent_type") ?? "general-purpose"
            let spaced = agentType.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return ConversationActivity(
                id: toolID, title: spaced.prefix(1).uppercased() + spaced.dropFirst(),
                detail: [agentType, string("description")].compactMap { $0 }.joined(separator: "\n"),
                status: status, childThreadID: toolID, agentPath: agentType, model: string("model"), turnID: turnID
            )
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.dropFirst(5).components(separatedBy: "__")
                let server = parts.first ?? ""
                let tool = parts.dropFirst().joined(separator: "__")
                return ConversationActivity(
                    id: toolID, title: "MCP · \(tool.isEmpty ? "Tool" : tool)",
                    detail: server.isEmpty ? "" : "Server · \(server)", status: status,
                    toolKind: "mcp", server: server, tool: tool, turnID: turnID
                )
            }
            return ConversationActivity(id: toolID, title: "Tool · \(name)", detail: "", status: status, toolKind: "dynamic", tool: name, turnID: turnID)
        }
    }

    static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    static func classifyFailure(_ error: ClientError, text: String) -> Error {
        let normalized = text.lowercased()
        if normalized.contains("/login") || normalized.contains("not logged in") || normalized.contains("invalid api key")
            || normalized.contains("authentication") || normalized.contains("oauth token") {
            return ClientError.authentication(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return error
    }

    static func verifyVersion(_ version: String?) throws {
        guard let version else { return }
        let current = version.split(separator: " ").first.map(String.init) ?? version
        if current.compare(minimumVersion, options: .numeric) == .orderedAscending {
            throw ClientError.unsupportedVersion(current)
        }
    }

    fileprivate var loginProcess: Process?

    fileprivate var executablePath: String? {
        if executableOverride == ConversationProviderFixture.notInstalledOverride { return nil }
        return executableOverride ?? Self.findExecutable()
    }

    static func findExecutable() -> String? {
        let home = NSHomeDirectory()
        let pathEntries = (PlayhouseProcessEnvironment.current["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path }
        let common = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"
        ]
        return (pathEntries + common).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        paths.append(contentsOf: ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

// MARK: - Account and usage

extension ClaudeCodeClient {
    var isInstalled: Bool { executablePath != nil }

    /// Reads the sign-in state with `claude auth status`, a local call that
    /// needs no network, then the plan's usage.
    func refreshAgentUsage() async {
        let store = AgentUsageStore.shared(scope: runtimeScope)
        store.setInstalled(.claude, isInstalled)
        guard isInstalled else { return }
        guard let output = await runAuthCommand(["auth", "status", "--json"]),
              let status = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else {
            // Status and usage are independent provider operations. Preserve the
            // known identity when status fails and try reading usage anyway.
            await readPlanUsage()
            return
        }
        let subscription = (status["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        store.setAuth(
            .claude,
            loggedIn: loggedIn,
            account: (status["email"] as? String) ?? (status["authMethod"] as? String),
            plan: subscription
        )
        if loggedIn { await readPlanUsage() }
    }

    /// Reads the plan's usage with Claude Code's `get_usage` control request, in
    /// a session that never receives a prompt, so no model request is made.
    /// The stream's `rate_limit_event` is sent only when a limit's status
    /// changes, and carries no utilization at all for a usage-based plan, so
    /// this read is what keeps the numbers current after each turn. Reads asked
    /// for while one runs share one follow-up read.
    func readPlanUsage() async {
        if let running = planUsageRead {
            planUsageReadQueued = true
            await running.value
            return
        }
        let read = Task { @MainActor in
            repeat {
                planUsageReadQueued = false
                await readPlanUsageOnce()
            } while planUsageReadQueued
            planUsageRead = nil
        }
        planUsageRead = read
        await read.value
    }

    private func readPlanUsageOnce() async {
        guard isInstalled, let workspace = try? ConversationWorkspaceContext(roots: []) else { return }
        do {
            let response = try await withMetadataSession(workspace: workspace) { runner in
                // A reply that never comes (a stalled usage service, or a CLI that ignores
                // the request) must not hold every later read: stopping the session fails it.
                let timeout = Task { @MainActor in
                    try await Task.sleep(for: Self.planUsageReadTimeout)
                    runner.shutdown()
                }
                defer { timeout.cancel() }
                return try await runner.controlRequest(["subtype": "get_usage", "skip_behaviors": true])
            }
            AgentUsageStore.shared(scope: runtimeScope).recordClaudeRead(response.extra)
        } catch {
            // An older Claude Code without `get_usage` still reports through the stream.
            PlayhouseDiagnostics.record("claude.usage.read_failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }

    /// Starts `claude auth login`, which opens the browser itself and exits once
    /// the sign-in finishes; the block refreshes then.
    func startAccountLogin() throws {
        guard loginProcess?.isRunning != true else { return }
        let process = try makeAuthProcess(["auth", "login"])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let store = AgentUsageStore.shared(scope: runtimeScope)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.loginProcess = nil
                store.setLoginInProgress(.claude, false)
                await self?.refreshAgentUsage()
            }
        }
        try process.run()
        loginProcess = process
        store.setLoginInProgress(.claude, true)
    }

    /// Signs out through the CLI. The state shown afterwards is read back from
    /// `claude auth status`, so a logout that failed is reported, not assumed.
    func logoutAccount() async throws {
        guard await runAuthCommand(["auth", "logout"]) != nil else {
            throw ClientError.protocolFailure("Claude Code could not sign out.")
        }
        await refreshAgentUsage()
    }

    private func makeAuthProcess(_ arguments: [String]) throws -> Process {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        if let configDirectoryOverride { environment["CLAUDE_CONFIG_DIR"] = configDirectoryOverride }
        process.environment = environment
        return process
    }

    /// Runs a short `claude` command and returns its output, or nil if it could
    /// not start, failed, or did not finish within `timeout`.
    private func runAuthCommand(_ arguments: [String], timeout: TimeInterval = 20) async -> (data: Data, status: Int32)? {
        guard let process = try? makeAuthProcess(arguments) else { return nil }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? (data, process.terminationStatus) : nil)
            }
        }
    }
}

/// Reads a Claude Code session's per-call usage back from its own files.
///
/// The stream's `result` message sums a turn for the main agent only; the
/// session files hold every model call, the main agent's in
/// `<session>.jsonl` and each subagent's in `<session>/subagents/agent-*.jsonl`.
/// A call is written once per content block, all lines sharing the call's
/// message ID, so a call is counted by ID and the last line's usage wins.
enum ClaudeSessionUsageReader {
    static func read(sessionID: String, configDirectory: String) -> ConversationCallUsageSnapshot? {
        guard let mainURL = sessionFile(sessionID: sessionID, configDirectory: configDirectory) else { return nil }
        var snapshot = ConversationCallUsageSnapshot(provider: ConversationProvider.claude.rawValue, updatedAt: .now)
        // Subagent lines belong to their own files, never to the main agent.
        snapshot.main = usage(in: mainURL) { $0["isSidechain"] as? Bool != true }
        for subagent in subagentFiles(mainFile: mainURL) {
            let result = usage(in: subagent.file) { _ in true }
            if !result.isEmpty { snapshot.subagents[subagent.agentID] = result }
        }
        return snapshot.totalCalls > 0 ? snapshot : nil
    }

    /// Each subagent's own file, `<session>/subagents/agent-<id>.jsonl`, by agent ID.
    static func subagentFiles(mainFile: URL) -> [(agentID: String, file: URL)] {
        let subagentDirectory = mainFile.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: subagentDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .map { (String($0.deletingPathExtension().lastPathComponent.dropFirst("agent-".count)), $0) }
            .sorted { $0.agentID < $1.agentID }
    }

    static func sessionFile(sessionID: String, configDirectory: String) -> URL? {
        let projects = URL(fileURLWithPath: configDirectory, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        let directories = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return directories
            .map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Sums the distinct calls in one file; `include` can drop lines that belong to another agent.
    private static func usage(in file: URL, include: ([String: Any]) -> Bool) -> ConversationCallUsage {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return ConversationCallUsage() }
        var order: [String] = []
        var calls: [String: ConversationTokenUsage] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  include(object),
                  let message = object["message"] as? [String: Any],
                  let id = message["id"] as? String,
                  let payload = message["usage"] as? [String: Any] else { continue }
            let tokens = ConversationTokenUsage(providerPayload: payload)
            let sent = tokens.inputTokens + tokens.cacheReadTokens + tokens.cacheCreationTokens
            // Synthetic entries (local command output, interruptions) carry zeros.
            guard sent + tokens.outputTokens > 0 else { continue }
            if calls[id] == nil { order.append(id) }
            calls[id] = tokens
        }
        var result = ConversationCallUsage()
        for id in order {
            guard let call = calls[id] else { continue }
            result.addCall(usage: call)
        }
        return result
    }
}
