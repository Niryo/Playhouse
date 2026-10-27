import Combine
import Darwin
import Foundation

/// Serializes sends through one Claude client. Primary app and bridge runtimes
/// reuse a client; auxiliary clients own independent one-shot processes.
private actor ClaudeTurnGate {
    private let lockURL: URL?
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var fileDescriptor: Int32?

    init(lockURL: URL?) {
        self.lockURL = lockURL
    }

    func acquire() async throws -> Bool {
        let wasQueued = isOccupied
        if wasQueued {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isOccupied = true
        }
        do {
            let (descriptor, waitedForProcess) = try await acquireProcessLock()
            fileDescriptor = descriptor
            return wasQueued || waitedForProcess
        } catch {
            if waiters.isEmpty {
                isOccupied = false
            } else {
                waiters.removeFirst().resume()
            }
            throw error
        }
    }

    func release() {
        if let fileDescriptor, fileDescriptor >= 0 {
            var lock = flock()
            lock.l_type = Int16(F_UNLCK)
            lock.l_whence = Int16(SEEK_SET)
            _ = Darwin.fcntl(fileDescriptor, F_SETLK, &lock)
            _ = Darwin.close(fileDescriptor)
            self.fileDescriptor = nil
        }
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func acquireProcessLock() async throws -> (Int32, Bool) {
        guard let lockURL else { return (-1, false) }
        let url = lockURL
        return try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            var waited = false
            while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
                if errno == EACCES || errno == EAGAIN {
                    waited = true
                    usleep(50_000)
                    continue
                }
                let code = errno
                _ = Darwin.close(descriptor)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            return (descriptor, waited)
        }.value
    }
}

/// Native capabilities a provider reports for a workspace, shown when a task
/// switches providers. StationAI reads each provider's own configuration and
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

/// Runs Claude Code turns through the installed `claude` executable using its
/// documented streaming JSON protocol (`--input-format stream-json` /
/// `--output-format stream-json`), the same transport the Claude Agent SDK
/// wraps. Each turn runs in its own process resumed by session ID; StationAI
/// persists the visible transcript itself.
@MainActor
final class ClaudeCodeClient: ObservableObject, ConversationProviderClient {
    nonisolated static let defaultModelID = "default"
    /// The model family StationAI prefers when the user hasn't picked one, so new
    /// conversations default to Sonnet rather than whatever Claude Code's own
    /// account-level default currently resolves to.
    nonisolated static let preferredDefaultModelID = "sonnet"
    nonisolated static let titleModelID = "haiku"
    /// The first Claude Code release StationAI verified for active-turn steering
    /// (`priority: "next"`) and command lifecycle events.
    nonisolated static let minimumVersion = "2.1.296"
    nonisolated static let foregroundExecutionInstruction = """
        Run every shell command in the foreground and wait for it to finish, including long sleeps, builds, and tests. Never set run_in_background, never background a command with &, and never end your turn while work you started is still running.
        """

    let provider = ConversationProvider.claude
    private static var processActiveSessionIDs = Set<String>()
    private static var activeClientsBySessionID: [String: ClaudeCodeClient] = [:]
    private static var sharedPrimaryClients: [String: ClaudeCodeClient] = [:]
    private let turnGate: ClaudeTurnGate

    @Published private(set) var isTurnActive = false
    @Published private(set) var activeThreadID: String?
    @Published private(set) var pendingUserInputRequest: ConversationUserInputRequest?

    private(set) var wasLastTurnInterrupted = false
    private(set) var isPreparingForApplicationTermination = false
    private(set) var lastTurnActivityDurations: [String: Int] = [:]

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
                "Claude Code wasn't found. Install Claude Code or add `claude` to PATH, then restart StationAI."
            case .processStart(let detail):
                "StationAI couldn't start Claude Code: \(detail)"
            case .processExited(let detail):
                "Claude Code stopped unexpectedly. \(detail)"
            case .protocolFailure(let detail):
                "StationAI couldn't communicate with Claude Code: \(detail)"
            case .authentication(let detail):
                "Claude Code needs a valid sign-in. Run `claude` in Terminal and sign in, then try again. \(detail)"
            case .unsupportedVersion(let version):
                "Claude Code \(version) is too old for StationAI. Update to \(ClaudeCodeClient.minimumVersion) or later (`claude update`), then try again."
            case .turnFailed(let detail):
                detail
            case .sessionNotFound:
                "Claude Code couldn't find this conversation's session."
            }
        }
    }

    private struct PendingQuestion {
        let controlRequestID: String
        let sessionID: String
        let input: [String: Any]
        let questions: [ConversationUserQuestion]
    }

    private struct TurnCompletion {
        var resultReceived = false
        var resultError: Error?
    }

    private let executableOverride: String?
    private let configDirectoryOverride: String?
    private let persistsSessions: Bool
    private let outputQueue = DispatchQueue(label: "com.stationai.claude.stdout")
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private var process: Process?
    private var inputPipe: Pipe?
    private var nextControlRequestID = 1
    private var pendingControlRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var newSessionIDs = Set<String>()
    private var startingSessionIDs = Set<String>()
    private var activeTurnID: String?
    private var activeMode: ConversationMode = .code
    private var pendingCommandUUIDs = Set<String>()
    private var sawCommandLifecycle = false
    private var sessionWasMissing = false
    private var turnCompletion = TurnCompletion()
    private var turnWaiter: CheckedContinuation<Void, Error>?
    private var pendingQuestion: PendingQuestion?
    private var planWasPresented = false
    private var pendingAssistantText: (id: String, text: String)?
    /// Set when the pending answer text was followed only by StationAI's outcome
    /// call, so text Claude writes after that call extends the same answer.
    private var pendingTextSpansOutcomeReport = false
    private var toolActivities: [String: ConversationActivity] = [:]
    private var subagentToolIDs = Set<String>()
    private var activityStartedAtUptime: [String: UInt64] = [:]
    private var conversationOperationsInFlight = 0
    private var deltaHandler: ((String) -> Void)?
    private var finalMessageHandler: ((String) -> Void)?
    private var progressMessageHandler: ((ConversationMessage) -> Void)?
    private var steerMessageHandler: ((String, [String]) -> Void)?
    private var activityHandler: ((ConversationActivity) -> Void)?
    private var actionRequestHandler: (() -> Void)?
    private var userInputHandler: ((ConversationUserInputRequest) async -> Void)?

    static func sharedPrimaryClient(executableOverride: String?) -> ClaudeCodeClient {
        let key = executableOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "__default__"
        if let client = sharedPrimaryClients[key] { return client }
        let client = ClaudeCodeClient(executableOverride: executableOverride, usesSharedProcessSlot: true)
        sharedPrimaryClients[key] = client
        return client
    }

    init(
        executableOverride: String? = nil,
        configDirectoryOverride: String? = nil,
        persistsSessions: Bool = true,
        usesSharedProcessSlot: Bool = false
    ) {
        let lockURL = usesSharedProcessSlot
            ? StationAIDiagnostics.storeURL.deletingLastPathComponent().appendingPathComponent("claude-primary-turn.lock")
            : nil
        turnGate = ClaudeTurnGate(lockURL: lockURL)
        self.executableOverride = ConversationProviderFixture.ownedExecutable(
            executableOverride,
            providerMarker: (".stationai-claude-fixture-owner", "StationAI test owns this Claude Code protocol fixture (v1).\n")
        )
        self.configDirectoryOverride = configDirectoryOverride
        self.persistsSessions = persistsSessions
    }

    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["provider"] = provider.rawValue
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["claudePID"] = String(process?.processIdentifier ?? -1)
        fields["activeThreadID"] = activeThreadID ?? ""
        fields["activeTurnID"] = activeTurnID ?? ""
        fields["isTurnActive"] = String(isTurnActive)
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
            let response = try await withMetadataSession(workspace: workspace) { client in
                try await client.controlRequest(["subtype": "mcp_status"])
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
        sensitiveUserInputAnswerValues: [String] = [],
        hideSensitiveRecoveryPrompt: Bool = false
    ) async throws {
        let wasQueued: Bool
        do {
            wasQueued = try await turnGate.acquire()
        } catch {
            throw ClientError.processStart("Couldn't reserve the Claude Code process slot: \(error.localizedDescription)")
        }
        if wasQueued {
            StationAIDiagnostics.record("claude.turn.queued", fields: [
                "requestedThreadID": threadID,
                "activeThreadID": activeThreadID ?? "",
                "clientPID": String(ProcessInfo.processInfo.processIdentifier)
            ])
        }
        defer { Task { await turnGate.release() } }

        guard process == nil else {
            StationAIDiagnostics.record("claude.turn.rejected", fields: diagnosticFields([
                "requestedThreadID": threadID,
                "reason": "client_process_still_active"
            ]))
            throw ClientError.protocolFailure("Another Claude Code turn is already running in this client.")
        }
        let sessionID = threadID
        activeThreadID = sessionID
        activeTurnID = nil
        activeMode = mode
        isTurnActive = false
        wasLastTurnInterrupted = false
        planWasPresented = false
        pendingAssistantText = nil
        pendingTextSpansOutcomeReport = false
        toolActivities.removeAll()
        subagentToolIDs.removeAll()
        activityStartedAtUptime.removeAll()
        lastTurnActivityDurations.removeAll()
        deltaHandler = onDelta
        finalMessageHandler = onFinalMessage
        progressMessageHandler = onProgressMessage
        steerMessageHandler = onSteerMessage
        activityHandler = onActivity
        actionRequestHandler = onActionRequest
        userInputHandler = onUserInput
        Self.activeClientsBySessionID[sessionID] = self
        defer {
            Self.processActiveSessionIDs.remove(sessionID)
            ConversationSteerMailbox.clearActiveTurn(threadID: sessionID)
            if Self.activeClientsBySessionID[sessionID] === self {
                Self.activeClientsBySessionID.removeValue(forKey: sessionID)
            }
            activeThreadID = nil
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

        let isNewSession = newSessionIDs.contains(sessionID)
        var providerPrompt = text
        var initialize: [String: Any]
        do {
            initialize = try await launchSession(
                sessionID: sessionID, resume: !isNewSession, mode: mode, modelID: modelID,
                effort: effort,
                workspace: workspace, developerInstructions: developerInstructions
            )
        } catch ClientError.sessionNotFound {
            // A new session ID may have been persisted before its first turn
            // reached Claude Code. A missing resumed session needs the visible
            // StationAI transcript so Claude does not silently lose its context.
            if !isNewSession {
                providerPrompt = ConversationHandoff.prompt(
                    ConversationHandoff.stripContext(from: text),
                    context: sessionRecoveryContext
                )
            }
            stopProcess()
            initialize = try await launchSession(
                sessionID: sessionID, resume: false, mode: mode, modelID: modelID,
                effort: effort,
                workspace: workspace, developerInstructions: developerInstructions
            )
        }
        newSessionIDs.remove(sessionID)
        try Self.verifyVersion(initialize["claude_code_version"] as? String)

        let turnID = UUID().uuidString.lowercased()
        let userMessageID = UUID().uuidString.lowercased()
        activeTurnID = turnID
        turnCompletion = TurnCompletion()
        pendingCommandUUIDs = [userMessageID]
        try writeUserMessage(text: providerPrompt, imageDataURLs: imageDataURLs, uuid: userMessageID, priority: nil)
        isTurnActive = true
        Self.processActiveSessionIDs.insert(sessionID)
        ConversationSteerMailbox.publishActiveTurn(threadID: sessionID, turnID: turnID)
        StationAIDiagnostics.record("claude.turn.started", fields: diagnosticFields([
            "threadID": sessionID,
            "turnID": turnID,
            "mode": mode.rawValue,
            "workspaceRootCount": String(workspace.roots.count)
        ]))

        let mailboxTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.activeThreadID == sessionID, self.activeTurnID == turnID {
                await ConversationSteerMailbox.service(threadID: sessionID, turnID: turnID) { text, images in
                    let accepted = try self.sendSteerInput(text: text, imageDataURLs: images)
                    if accepted { self.steerMessageHandler?(text, images) }
                    return accepted
                } interrupt: {
                    try await self.interruptActiveTurn(threadID: sessionID)
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        defer { mailboxTask.cancel() }
        do {
            try await waitForTurnCompletion()
            StationAIDiagnostics.record("claude.turn.ended", fields: diagnosticFields([
                "threadID": sessionID, "turnID": turnID, "turnStatus": "completed"
            ]))
        } catch {
            var fields = hideSensitiveRecoveryPrompt
                ? ["error": "Private conversation recovery turn failed."]
                : StationAIDiagnostics.errorFields(error, redacting: sensitiveUserInputAnswerValues)
            fields["threadID"] = sessionID
            fields["turnID"] = turnID
            fields["turnStatus"] = wasLastTurnInterrupted ? "interrupted" : "failed"
            fields.merge(diagnosticFields([:])) { _, new in new }
            StationAIDiagnostics.record("claude.turn.ended", fields: fields)
            throw error
        }
    }

    func interruptActiveTurn(threadID: String) async throws -> Bool {
        guard activeThreadID == threadID, activeTurnID != nil, process?.isRunning == true else {
            // Another StationAI process may own the turn.
            guard Self.activeClientsBySessionID[threadID] == nil else { return false }
            return try await ConversationSteerMailbox.requestInterrupt(threadID: threadID)
        }
        wasLastTurnInterrupted = true
        do {
            _ = try await controlRequest(["subtype": "interrupt"])
            return true
        } catch {
            wasLastTurnInterrupted = false
            throw error
        }
    }

    func steerActiveTurn(threadID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard let target = Self.activeClientsBySessionID[threadID] else {
            return try await ConversationSteerMailbox.requestSteer(threadID: threadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        return try target.sendSteerInput(text: normalized, imageDataURLs: imageDataURLs)
    }

    /// Delivers input into the running turn with `priority: "next"`, which Claude
    /// Code injects at its next tool boundary without cancelling in-flight work.
    private func sendSteerInput(text: String, imageDataURLs: [String]) throws -> Bool {
        guard isTurnActive, activeTurnID != nil, process?.isRunning == true,
              !turnCompletion.resultReceived || !pendingCommandUUIDs.isEmpty else { return false }
        let uuid = UUID().uuidString.lowercased()
        pendingCommandUUIDs.insert(uuid)
        do {
            try writeUserMessage(text: text, imageDataURLs: imageDataURLs, uuid: uuid, priority: "next")
        } catch {
            pendingCommandUUIDs.remove(uuid)
            throw error
        }
        StationAIDiagnostics.record("claude.turn.steered", fields: diagnosticFields(["imageCount": String(imageDataURLs.count)]))
        return true
    }

    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
        guard let pending = pendingQuestion, pending.controlRequestID == requestID, pending.sessionID == threadID else { return false }
        let questionsByID = Dictionary(uniqueKeysWithValues: pending.questions.map { ($0.id, $0) })
        let valid = Set(answers.keys) == Set(questionsByID.keys) && answers.allSatisfy { id, values in
            guard !values.isEmpty, let question = questionsByID[id] else { return false }
            return values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && (question.allowsOther || values.allSatisfy { value in question.options.contains { $0.label == value } })
        }
        guard valid else {
            StationAIDiagnostics.record("claude.user_input.answer.failed", fields: [
                "requestID": requestID, "threadID": threadID, "reason": "invalid_answer_shape"
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
        pendingQuestion = nil
        pendingUserInputRequest = nil
        StationAIDiagnostics.record("claude.user_input.answer.succeeded", fields: [
            "requestID": requestID, "threadID": threadID, "questionCount": String(answers.count)
        ])
        return true
    }

    func rejectUserInput(requestID: String, threadID: String, message: String) {
        guard let pending = pendingQuestion, pending.controlRequestID == requestID, pending.sessionID == threadID else { return }
        pendingQuestion = nil
        pendingUserInputRequest = nil
        try? sendControlResponse(requestID: requestID, response: ["behavior": "deny", "message": message, "interrupt": true])
        finishTurn(.failure(ClientError.turnFailed(message)))
    }

    func isTurnActive(threadID: String) -> Bool {
        startingSessionIDs.contains(threadID)
            || (activeThreadID == threadID && activeTurnID != nil)
            || pendingQuestion?.sessionID == threadID
    }

    func isTurnActiveInProcess(threadID: String) -> Bool {
        Self.processActiveSessionIDs.contains(threadID)
    }

    func canInterruptActiveTurn(threadID: String) -> Bool {
        activeThreadID == threadID && activeTurnID != nil
    }

    func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        if let target = Self.activeClientsBySessionID[threadID], target.isTurnActive(threadID: threadID) {
            return Int32(ProcessInfo.processInfo.processIdentifier)
        }
        return ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: threadID)
    }

    func markTurnStarting(threadID: String) {
        startingSessionIDs.insert(threadID)
        // Do not replace the identity of a live process while this session
        // waits at the shared-client gate. Mailbox steering, interrupt, and
        // user-input routing for that process all use activeThreadID.
        if startingSessionIDs.count == 1, activeThreadID == nil, process == nil, activeTurnID == nil {
            activeThreadID = threadID
        }
    }

    func clearTurnStarting(threadID: String) {
        startingSessionIDs.remove(threadID)
        if activeThreadID == threadID, activeTurnID == nil { activeThreadID = nil }
    }

    func beginConversationOperation() { conversationOperationsInFlight += 1 }

    func finishConversationOperation() { conversationOperationsInFlight = max(0, conversationOperationsInFlight - 1) }

    func prepareForApplicationTermination() async {
        isPreparingForApplicationTermination = true
        if let threadID = activeThreadID, isTurnActive {
            _ = try? await interruptActiveTurn(threadID: threadID)
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while conversationOperationsInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        shutdown()
    }

    func shutdown() {
        stopProcess()
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

    // MARK: - Process and protocol

    private struct MetadataResponse {
        let initialize: [String: Any]
        let extra: [String: Any]
    }

    /// Starts a short-lived process that never receives a prompt, so no model
    /// request is made, and reads its initialize response plus one extra query.
    private func withMetadataSession(
        workspace: ConversationWorkspaceContext,
        _ query: (ClaudeCodeClient) async throws -> [String: Any]
    ) async throws -> MetadataResponse {
        let client = ClaudeCodeClient(executableOverride: executableOverride, configDirectoryOverride: configDirectoryOverride, persistsSessions: false)
        defer { client.stopProcess() }
        let initialize = try await client.launchSession(
            sessionID: UUID().uuidString.lowercased(), resume: false, mode: .code, modelID: Self.defaultModelID,
            effort: nil,
            workspace: workspace, developerInstructions: nil
        )
        return MetadataResponse(initialize: initialize, extra: try await query(client))
    }

    private func launchSession(
        sessionID: String,
        resume: Bool,
        mode: ConversationMode,
        modelID: String,
        effort: ConversationEffort?,
        workspace: ConversationWorkspaceContext,
        developerInstructions: String?
    ) async throws -> [String: Any] {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", mode == .plan ? "plan" : "default",
            resume ? "--resume" : "--session-id", sessionID
        ]
        if modelID != Self.defaultModelID { arguments += ["--model", modelID] }
        if !persistsSessions { arguments.append("--no-session-persistence") }
        for root in workspace.roots.dropFirst() { arguments += ["--add-dir", root.path] }
        // Each turn's process exits when the turn ends, so work Claude moves to the
        // background is lost and its turn stops early. Keep every command in the foreground.
        var systemPrompt = Self.foregroundExecutionInstruction
        if let developerInstructions, !developerInstructions.isEmpty {
            systemPrompt += "\n\n" + developerInstructions
        }
        arguments += ["--append-system-prompt", systemPrompt]

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardStationAIBridgeEnvironment(&environment)
        // Claude Code finds its keychain sign-in by user name; services started by
        // launchd are not guaranteed a login environment.
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        if let configDirectoryOverride { environment["CLAUDE_CONFIG_DIR"] = configDirectoryOverride }
        if let effort { environment["CLAUDE_CODE_EFFORT_LEVEL"] = effort.rawValue }
        // The CLI is a child of StationAI, not an IDE integration or nested session.
        environment.removeValue(forKey: "CLAUDECODE")
        environment.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
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
        let queue = outputQueue
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            queue.async { [weak self] in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let consumed = DispatchSemaphore(value: 0)
                Task { @MainActor [weak self] in
                    await self?.consumeOutput(data)
                    consumed.signal()
                }
                consumed.wait()
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4_000))
            }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.processDidTerminate(terminated) }
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
        StationAIDiagnostics.record("claude.process.started", fields: diagnosticFields([
            "executable": executable,
            "workingDirectory": workspace.cwd.path,
            "processID": String(child.processIdentifier),
            "resume": String(resume),
            "mode": mode.rawValue,
            "environmentNames": environment.keys.sorted().joined(separator: ",")
        ]))
        return try await controlRequest(["subtype": "initialize"])
    }

    private func controlRequest(_ request: [String: Any]) async throws -> [String: Any] {
        let requestID = "stationai-\(nextControlRequestID)"
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

    private func waitForTurnCompletion() async throws {
        if turnCompletion.resultReceived, pendingCommandUUIDs.isEmpty || !sawCommandLifecycle {
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
        let stopped = ClientError.processExited("StationAI stopped Claude Code.")
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
        // longer this client's; its late termination must not fail new requests.
        guard process === terminated else { return }
        StationAIDiagnostics.record("claude.process.exited", fields: diagnosticFields([
            "processID": String(terminated.processIdentifier),
            "exitStatus": String(terminated.terminationStatus)
        ]))
        let error: Error = sessionWasMissing || stderrTail.contains("No conversation found with session ID")
            ? ClientError.sessionNotFound
            : Self.classifyFailure(ClientError.processExited(stderrSummary(status: terminated.terminationStatus)), text: stderrTail)
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
        let exit = status.map { "Claude Code exited with status \($0)." } ?? "Restart StationAI and try again."
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
            guard message["parent_tool_use_id"] is NSNull || message["parent_tool_use_id"] == nil,
                  let event = message["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return }
            deltaHandler?(text)
        case "assistant":
            handleAssistant(message)
        case "user":
            handleToolResults(message)
        case "result":
            handleResult(message)
        default:
            break
        }
    }

    private func handleControlRequest(requestID: String, request: [String: Any]) async {
        guard request["subtype"] as? String == "can_use_tool" else {
            if request["subtype"] as? String == "elicitation" { actionRequestHandler?() }
            sendControlError(requestID: requestID, message: "StationAI does not provide this optional integration.")
            return
        }
        let toolName = request["tool_name"] as? String ?? ""
        let input = request["input"] as? [String: Any] ?? [:]
        switch toolName {
        case "AskUserQuestion":
            presentQuestions(requestID: requestID, input: input)
        case "ExitPlanMode" where activeMode == .plan:
            // StationAI keeps plan mode until the user starts implementation, so the
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
                "message": "StationAI showed this plan to the user, who will reply in a later message. End your turn now without further output."
            ])
        default:
            // Code mode runs without approval prompts. Claude Code has already
            // applied the user's native allow and deny rules before asking.
            try? sendControlResponse(requestID: requestID, response: ["behavior": "allow", "updatedInput": input])
        }
    }

    private func presentQuestions(requestID: String, input: [String: Any]) {
        guard let sessionID = activeThreadID else {
            sendControlError(requestID: requestID, message: "No active StationAI turn can answer this question.")
            return
        }
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
        let request = ConversationUserInputRequest(id: requestID, threadID: sessionID, questions: questions, isBlocking: true)
        pendingUserInputRequest = request
        let handler = userInputHandler
        Task { @MainActor in await handler?(request) }
    }

    private func handleAssistant(_ message: [String: Any]) {
        guard let body = message["message"] as? [String: Any],
              let content = body["content"] as? [[String: Any]] else { return }
        let parentToolID = message["parent_tool_use_id"] as? String
        let messageID = body["id"] as? String ?? UUID().uuidString
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
                // StationAI's own progress and outcome reports are bookkeeping, not
                // work, so they don't turn the answer written before them into commentary.
                let report = Self.reportCommand(name: name, input: input)
                if pendingAssistantText != nil, let report {
                    if report == .outcome { pendingTextSpansOutcomeReport = true }
                } else if let pending = pendingAssistantText {
                    emitProgress(id: pending.id, text: pending.text)
                    pendingAssistantText = nil
                    pendingTextSpansOutcomeReport = false
                }
                activityStartedAtUptime[toolID] = DispatchTime.now().uptimeNanoseconds
                let activity = Self.activity(toolID: toolID, name: name, input: input, status: "inProgress", turnID: activeTurnID)
                if activity.isSubagent { subagentToolIDs.insert(toolID) }
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
            let isError = block["is_error"] as? Bool ?? false
            let output = Self.resultText(block["content"])
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
            if let duration { lastTurnActivityDurations[activity.id] = duration }
            toolActivities[toolID] = activity
            activityHandler?(activity)
        }
    }

    private func handleResult(_ message: [String: Any]) {
        let subtype = message["subtype"] as? String ?? ""
        let isError = message["is_error"] as? Bool ?? (subtype != "success")
        if isError {
            let text = (message["result"] as? String) ?? (message["errors"] as? [String])?.joined(separator: " ") ?? ""
            if text.contains("No conversation found with session ID") { sessionWasMissing = true }
            let error: Error
            if wasLastTurnInterrupted {
                error = ClientError.turnFailed("The Claude turn was interrupted.")
            } else {
                error = Self.classifyFailure(ClientError.turnFailed(text.isEmpty ? "Claude couldn't complete this turn (\(subtype))." : text), text: text)
            }
            turnCompletion.resultReceived = true
            turnCompletion.resultError = error
            // An interrupt or failure ends the logical turn even if steered input is queued.
            pendingCommandUUIDs.removeAll()
        } else {
            turnCompletion.resultReceived = true
        }
        completeTurnIfSettled()
    }

    private func completeTurnIfSettled() {
        guard turnCompletion.resultReceived, pendingCommandUUIDs.isEmpty || !sawCommandLifecycle else { return }
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
            return ConversationActivity(id: toolID, title: command.isEmpty ? "Running command" : "Running \(command)", detail: string("description") ?? "", status: status, turnID: turnID)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = string("file_path") ?? string("notebook_path") ?? ""
            return ConversationActivity(id: toolID, title: "Editing 1 file", detail: path, status: status, turnID: turnID)
        case "Read":
            return ConversationActivity(id: toolID, title: "Reading \(string("file_path").map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file")", detail: string("file_path") ?? "", status: status, turnID: turnID)
        case "Grep", "Glob":
            return ConversationActivity(id: toolID, title: "Searching files", detail: string("pattern") ?? "", status: status, turnID: turnID)
        case "WebSearch":
            return ConversationActivity(id: toolID, title: "Searching the web", detail: string("query") ?? "", status: status, turnID: turnID)
        case "WebFetch":
            return ConversationActivity(id: toolID, title: "Fetching a web page", detail: string("url") ?? "", status: status, turnID: turnID)
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

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    private static func classifyFailure(_ error: ClientError, text: String) -> Error {
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
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude").path }
        let common = [
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude"
        ]
        return (pathEntries + common).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        let home = NSHomeDirectory()
        paths.append(contentsOf: ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

