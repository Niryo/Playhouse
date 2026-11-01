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
    }

    /// How long a settled turn waits for Claude Code to deliver a finished
    /// background task before treating the notification as already consumed.
    nonisolated static let parentWakeGracePeriod: Duration = .seconds(15)

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
    private var nextControlRequestID = 1
    private var pendingControlRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var activeMode: ConversationMode = .code
    private var pendingCommandUUIDs = Set<String>()
    private var sawCommandLifecycle = false
    private var sessionWasMissing = false
    private var turnCompletion = TurnCompletion()
    private var turnWaiter: CheckedContinuation<Void, Error>?
    private var planWasPresented = false
    private var pendingAssistantText: (id: String, text: String)?
    /// Set when the pending answer text was followed only by Playhouse's outcome
    /// call, so text Claude writes after that call extends the same answer.
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
        owner: ClaudeCodeClient?
    ) {
        self.sessionID = sessionID
        self.executable = executable
        self.configDirectoryOverride = configDirectoryOverride
        self.persistsSessions = persistsSessions
        self.owner = owner
    }

    var processIdentifier: Int32 { process?.processIdentifier ?? -1 }

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
        try writeUserMessage(text: providerPrompt, imageDataURLs: imageDataURLs, uuid: userMessageID, priority: nil)
        isTurnActive = true
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
                    let accepted = try self.sendSteerInput(text: text, imageDataURLs: images)
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
        guard activeTurnID != nil, process?.isRunning == true else { return false }
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
    func sendSteerInput(text: String, imageDataURLs: [String]) throws -> Bool {
        guard isTurnActive, activeTurnID != nil, process?.isRunning == true,
              !isTurnSettled || !turnCompletion.resultReceived || !pendingCommandUUIDs.isEmpty else { return false }
        let uuid = UUID().uuidString.lowercased()
        pendingCommandUUIDs.insert(uuid)
        do {
            try writeUserMessage(text: text, imageDataURLs: imageDataURLs, uuid: uuid, priority: "next")
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
            "--permission-mode", mode == .plan ? "plan" : "default",
            resume ? "--resume" : "--session-id", sessionID
        ]
        if modelID != ClaudeCodeClient.defaultModelID { arguments += ["--model", modelID] }
        if !persistsSessions { arguments.append("--no-session-persistence") }
        for root in workspace.roots.dropFirst() { arguments += ["--add-dir", root.path] }
        // Background Bash and Agent/Task calls report through Claude Code's task
        // events and keep the turn open, so Claude may end its response while
        // they run instead of blocking on a wait it cannot satisfy. Only a process
        // detached with `&` or `nohup` is invisible to Claude Code and Playhouse.
        var systemPrompt = ClaudeCodeClient.executionInstruction
        if let developerInstructions, !developerInstructions.isEmpty {
            systemPrompt += "\n\n" + developerInstructions
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
        // The CLI is a child of Playhouse, not an IDE integration or nested session.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")

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
        nextControlRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingControlRequests[requestID] = continuation
            do {
                try sendJSON(["type": "control_request", "request_id": requestID, "request": request])
            } catch {
                pendingControlRequests.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendControlResponse(requestID: String, response: [String: Any]) throws {
        try sendJSON(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": response]])
    }

    private func sendControlError(requestID: String, message: String) {
        try? sendJSON(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": message]])
    }

    private func writeUserMessage(text: String, imageDataURLs: [String], uuid: String, priority: String?) throws {
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
        try sendJSON(message)
    }

    private func sendJSON(_ object: [String: Any]) throws {
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
        guard let process else { return }
        self.process = nil
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
            handleToolResults(message)
        case "system":
            handleSystem(message)
        case "result":
            handleResult(message)
        default:
            break
        }
    }

    private func handleControlRequest(requestID: String, request: [String: Any]) async {
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
        default:
            // Code mode runs without approval prompts. Claude Code has already
            // applied the user's native allow and deny rules before asking.
            try? sendControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": input])
        }
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
        let request = ConversationUserInputRequest(id: requestID, threadID: sessionID, questions: questions, isBlocking: true, mode: activeMode)
        pendingUserInputRequest = request
        owner?.runnerStateChanged(self)
        let handler = userInputHandler
        Task { @MainActor in await handler?(request) }
    }

    private func clearPendingQuestion() {
        pendingQuestion = nil
        pendingUserInputRequest = nil
        owner?.runnerStateChanged(self)
    }

    private func handleAssistant(_ message: [String: Any]) {
        guard let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        let parentToolID = message["parent_tool_use_id"] as? String
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
                // Playhouse's own progress and outcome reports are bookkeeping, not
                // work, so they don't turn the answer written before them into commentary.
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

    private func handleToolResults(_ message: [String: Any]) {
        guard message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil,
              let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        for block in content where block["type"] as? String == "tool_result" {
            guard let toolID = block["tool_use_id"] as? String, var activity = toolActivities[toolID] else { continue }
            // A backgrounded Agent/Task call's tool_result only confirms the launch,
            // not completion; its real outcome arrives later as a system task event.
            if backgroundedToolUseIDs.contains(toolID) { continue }
            let isError = block["is_error"] as? Bool ?? false
            let output = ClaudeCodeClient.resultText(block["content"])
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
                durationMs: duration, turnID: activity.turnID
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
            // background task; that turn's result also belongs to this one.
            if turnCompletion.awaitingParentWake {
                setAwaitingParentWake(false)
                turnCompletion.wokenTurnCount += 1
            }
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
                )
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
        parentWakeBackstopGeneration += 1
    }

    /// When only an undelivered background notification holds a finished turn
    /// open, settle after a grace period: Claude Code normally starts the woken
    /// turn within milliseconds, and a notification it consumed without a new
    /// request must not hold the task In Progress indefinitely.
    private func scheduleParentWakeBackstopIfNeeded() {
        guard turnCompletion.awaitingParentWake, turnCompletion.resultError == nil,
              turnCompletion.resultReceived, turnCompletion.resultCount > turnCompletion.wokenTurnCount,
              outstandingBackgroundTaskIDs.isEmpty, pendingBackgroundTaskNotificationIDs.isEmpty else { return }
        parentWakeBackstopGeneration += 1
        let generation = parentWakeBackstopGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ClaudeSessionRunner.parentWakeGracePeriod)
            guard let self, self.parentWakeBackstopGeneration == generation,
                  self.turnCompletion.awaitingParentWake else { return }
            PlayhouseDiagnostics.record("claude.turn.parent_wake_timeout", fields: self.diagnosticFields([:]))
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
            )
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
    private var newSessionIDs = Set<String>()
    private var startingSessionIDs = Set<String>()
    private var interruptedThreadIDs = Set<String>()
    /// The process and turn identity each conversation last ran under, so a
    /// failure recorded after the runner is torn down still names its own turn.
    private var lastTurnDiagnosticsByThread: [String: [String: String]] = [:]
    private var activityDurationsByThread: [String: [String: Int]] = [:]
    private var lastFinishedThreadID: String?
    private var conversationOperationsInFlight = 0

    /// `dataDirectory` only ever varies across calls in debug/test builds (via
    /// `BridgeRequest.dataDirectory`); production always passes `nil`, so one
    /// real app only ever has one entry here. It's part of the cache key so
    /// that the bridge daemon — now a single long-lived process that can serve
    /// many isolated test data directories in sequence or concurrently — gives
    /// each one its own client (and thus its own child process with correctly
    /// scoped environment forwarding) instead of silently sharing one across
    /// directories that happen to share a process.
    static func sharedPrimaryClient(executableOverride: String?, dataDirectory: String? = nil) -> ClaudeCodeClient {
        let key = [
            executableOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "__default__",
            dataDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "",
        ].joined(separator: "\u{1}")
        if let client = sharedPrimaryClients[key] { return client }
        let client = ClaudeCodeClient(executableOverride: executableOverride, dataDirectory: dataDirectory)
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

    func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption] {
        let response = try await withMetadataSession(workspace: workspace) { _ in [:] }
        let models = (response.initialize["models"] as? [[String: Any]] ?? []).compactMap { item -> ConversationModelOption? in
            guard let value = item["value"] as? String, !value.isEmpty else { return nil }
            let isPreferredDefault = value == Self.defaultModelID || value.lowercased().contains(Self.preferredDefaultModelID)
            return ConversationModelOption(id: value, name: item["displayName"] as? String ?? value, isDefault: isPreferredDefault)
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
            owner: self
        )
        runner.deltaHandler = onDelta
        runner.finalMessageHandler = onFinalMessage
        runner.progressMessageHandler = onProgressMessage
        runner.steerMessageHandler = onSteerMessage
        runner.activityHandler = onActivity
        runner.actionRequestHandler = onActionRequest
        runner.userInputHandler = onUserInput
        runner.tokenUsageHandler = onTokenUsage
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
            if runner.sessionExists { newSessionIDs.remove(sessionID) }
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
        let accepted = try runner.sendSteerInput(text: normalized, imageDataURLs: imageDataURLs)
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

    private var executablePath: String? { executableOverride ?? Self.findExecutable() }

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
