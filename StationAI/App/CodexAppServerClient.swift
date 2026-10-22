import Combine
import Darwin
import Foundation

enum CodexChatRole: String, Codable, Equatable {
    case user
    case assistant
}

struct CodexChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: CodexChatRole
    var text: String
    var imageDataURLs: [String]

    init(id: String, role: CodexChatRole, text: String, imageDataURLs: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.imageDataURLs = imageDataURLs
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, imageDataURLs }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(CodexChatRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        imageDataURLs = try container.decodeIfPresent([String].self, forKey: .imageDataURLs) ?? []
    }
}

struct CodexUserQuestion: Identifiable, Codable, Equatable {
    struct Option: Identifiable, Codable, Equatable {
        let label: String
        let description: String?
        var id: String { label }
    }
    let id: String
    let header: String
    let question: String
    let options: [Option]
    let allowsOther: Bool
    let isSecret: Bool
}

struct CodexUserInputRequest: Identifiable, Codable, Equatable {
    let id: String
    let threadID: String
    let questions: [CodexUserQuestion]
    let isBlocking: Bool
}

private struct ConversationSteerMailboxRequest: Codable {
    let id: String
    let threadID: String
    let expectedTurnID: String
    let text: String
    var imageDataURLs: [String]? = []
}

private struct ConversationSteerMailboxActiveTurn: Codable {
    let threadID: String
    let turnID: String
    let processID: Int32
}

private struct ConversationSteerMailboxResponse: Codable {
    let accepted: Bool
    let error: String?
}

enum CodexConversationMode: String, CaseIterable, Hashable {
    case code = "default"
    case plan

    var title: String {
        switch self {
        case .code: "Code mode"
        case .plan: "Plan mode"
        }
    }
}

struct CodexModelOption: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

@MainActor
final class CodexAppServerClient: ObservableObject {
    nonisolated static let modelID = "gpt-6-luna"
    private static var processActiveThreadIDs = Set<String>()
    private static var activeClientsByThreadID: [String: CodexAppServerClient] = [:]
    private static var steerMailboxDirectory: URL?
    private var startingThreadIDs = Set<String>()
    @Published private(set) var isTurnActive = false
    @Published private(set) var activeThreadID: String?
    @Published private(set) var pendingUserInputRequest: CodexUserInputRequest?
    private var activeConversationMode: CodexConversationMode = .code

    private enum ClientError: LocalizedError {
        case cliNotFound
        case processStart(String)
        case processExited(String)
        case protocolFailure(String)
        case server(String)
        case authentication(String)
        case modelMismatch(String, String)
        case turnFailed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "Codex CLI wasn't found. Install Codex CLI or add it to PATH, then restart StationAI."
            case .processStart(let detail):
                "StationAI couldn't start Codex CLI: \(detail)"
            case .processExited(let detail):
                "The Codex app-server stopped unexpectedly. \(detail)"
            case .protocolFailure(let detail):
                "StationAI couldn't communicate with Codex: \(detail)"
            case .server(let detail):
                detail
            case .authentication(let detail):
                "Codex CLI needs a valid sign-in. Run `codex login` in Terminal, then try again. \(detail)"
            case .modelMismatch(let model, let expected):
                "Codex selected \(model) instead of \(expected). StationAI stopped without switching models."
            case .turnFailed(let detail):
                detail
            }
        }
    }

    private let outputQueue = DispatchQueue(label: "com.stationai.codex.stdout")
    private var stdoutBuffer = Data()
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingRequestDiagnostics: [Int: (method: String, startedAt: UInt64)] = [:]
    private var nextRequestID = 1
    private var initialized = false
    private var resumedThreadIDs = Set<String>()
    private var activeTurnID: String?
    private(set) var wasLastTurnInterrupted = false
    private var activeDeltaHandler: ((String) -> Void)?
    private var activeFinalMessageHandler: ((String) -> Void)?
    private var activeSteerMessageHandler: ((String, [String]) -> Void)?
    private var activeActivityHandler: ((CodexActivity) -> Void)?
    private var activeDiffHandler: ((CodexTurnDiff) -> Void)?
    private var activeActivities: [String: CodexActivity] = [:]
    private var actionRequestHandler: (() -> Void)?
    private var userInputHandler: ((CodexUserInputRequest) async -> Void)?
    private var pendingUserInputRequestID: Any?
    private var pendingUserInputThreadID: String?
    private var pendingUserInputQuestions: [String: CodexUserQuestion] = [:]
    private let codexExecutableOverride: String?
    var executableOverrideForTitleGeneration: String? { codexExecutableOverride }
    private var turnWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedTurns: [String: Result<Void, Error>] = [:]
    private var rejectedTurnKeys = Set<String>()

    init(codexExecutableOverride: String? = nil) {
        self.codexExecutableOverride = Self.ownedTestFixtureExecutable(codexExecutableOverride)
    }

    func diagnosticFields(_ additionalFields: [String: String] = [:]) -> [String: String] {
        var fields = additionalFields
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["codexPID"] = String(process?.processIdentifier ?? -1)
        fields["activeThreadID"] = activeThreadID ?? ""
        fields["activeTurnID"] = activeTurnID ?? ""
        fields["isTurnActive"] = String(isTurnActive)
        fields["pendingInputThreadID"] = pendingUserInputThreadID ?? ""
        return fields
    }

    func loadThread(
        id threadID: String,
        workspace: CodexWorkspaceContext,
        onActionRequest: @escaping () -> Void
    ) async throws -> CodexThreadHistory {
        actionRequestHandler = onActionRequest
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace)
        return try await readMessages(threadID: threadID)
    }

    func startThread(
        workspace: CodexWorkspaceContext,
        modelID: String = CodexAppServerClient.modelID,
        developerInstructions: String? = nil
    ) async throws -> String {
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
        let response = try await request(method: "thread/start", params: params)

        guard let thread = response["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a thread ID.")
        }
        try confirmModel(response["model"] as? String, expected: modelID)
        resumedThreadIDs.insert(threadID)
        return threadID
    }

    func availableModels(workspace: CodexWorkspaceContext) async throws -> [CodexModelOption] {
        try await ensureInitialized(workspace: workspace)
        let response = try await request(method: "model/list", params: ["includeHidden": false])
        let models = (response["data"] as? [[String: Any]] ?? []).compactMap { item -> CodexModelOption? in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            return CodexModelOption(
                id: id,
                name: item["displayName"] as? String ?? item["model"] as? String ?? id,
                isDefault: item["isDefault"] as? Bool ?? false
            )
        }
        return models.isEmpty ? [CodexModelOption(id: Self.modelID, name: "GPT-6 Luna", isDefault: true)] : models
    }

    func interruptActiveTurn(threadID expectedThreadID: String) async throws -> Bool {
        guard let threadID = activeThreadID,
              threadID == expectedThreadID,
              let turnID = activeTurnID else { return false }
        wasLastTurnInterrupted = true
        do {
            _ = try await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
            return true
        } catch {
            wasLastTurnInterrupted = false
            throw error
        }
    }

    func steerActiveTurn(threadID expectedThreadID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard let target = Self.activeClientsByThreadID[expectedThreadID] else {
            return try await requestSteerFromTurnOwner(threadID: expectedThreadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        guard let threadID = target.activeThreadID, threadID == expectedThreadID,
              let turnID = target.activeTurnID, target.isTurnActive else { return false }
        return try await target.sendSteerRequest(threadID: threadID, turnID: turnID, text: normalized, imageDataURLs: imageDataURLs)
    }

    static func configureSteerMailbox(directory: URL) {
        steerMailboxDirectory = directory
    }

    private func sendSteerRequest(threadID: String, turnID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        // Verified against `codex-cli 0.162.1` app-server schemas: params require
        // threadId/input/expectedTurnId and the response requires turnId.
        let response = try await request(method: "turn/steer", params: [
            "threadId": threadID,
            "input": (text.isEmpty ? [] : [["type": "text", "text": text]]) + imageDataURLs.map { ["type": "image", "url": $0] },
            "expectedTurnId": turnID
        ])
        guard response["turnId"] as? String == turnID else {
            throw ClientError.protocolFailure("Codex acknowledged steering for an unexpected turn.")
        }
        return true
    }

    private func requestSteerFromTurnOwner(threadID: String, text: String, imageDataURLs: [String]) async throws -> Bool {
        guard let directory = Self.steerMailboxDirectory else { return false }
        let activeURL = Self.activeTurnMailboxURL(threadID: threadID, directory: directory)
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return false }
        let activeTurn = try JSONDecoder().decode(ConversationSteerMailboxActiveTurn.self, from: Data(contentsOf: activeURL))
        guard activeTurn.threadID == threadID else { return false }
        guard Darwin.kill(activeTurn.processID, 0) == 0 || errno == EPERM else {
            try? FileManager.default.removeItem(at: activeURL)
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = Darwin.chmod(directory.path, mode_t(0o700))
        let requestID = UUID().uuidString
        let requestURL = directory.appendingPathComponent("\(requestID).request.json")
        let responseURL = directory.appendingPathComponent("\(requestID).response.json")
        let request = ConversationSteerMailboxRequest(id: requestID, threadID: threadID, expectedTurnID: activeTurn.turnID, text: text, imageDataURLs: imageDataURLs)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        _ = Darwin.chmod(requestURL.path, mode_t(0o600))
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                let response = try JSONDecoder().decode(ConversationSteerMailboxResponse.self, from: Data(contentsOf: responseURL))
                if let error = response.error { throw ClientError.server(error) }
                return response.accepted
            }
            if !FileManager.default.fileExists(atPath: activeURL.path) { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func serviceSteerMailbox(threadID: String, turnID: String) async {
        guard let directory = Self.steerMailboxDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for requestURL in files where requestURL.lastPathComponent.hasSuffix(".request.json") {
            guard let request = try? JSONDecoder().decode(ConversationSteerMailboxRequest.self, from: Data(contentsOf: requestURL)),
                  request.threadID == threadID else { continue }
            let claimedURL = directory.appendingPathComponent("\(request.id).claimed.json")
            do { try FileManager.default.moveItem(at: requestURL, to: claimedURL) }
            catch { continue }
            let responseURL = directory.appendingPathComponent("\(request.id).response.json")
            let response: ConversationSteerMailboxResponse
            if request.expectedTurnID != turnID {
                response = ConversationSteerMailboxResponse(accepted: false, error: "The active turn changed before the steering message could be sent.")
            } else {
                do {
                    let images = request.imageDataURLs ?? []
                    _ = try await sendSteerRequest(threadID: threadID, turnID: turnID, text: request.text, imageDataURLs: images)
                    activeSteerMessageHandler?(request.text, images)
                    response = ConversationSteerMailboxResponse(accepted: true, error: nil)
                } catch {
                    response = ConversationSteerMailboxResponse(accepted: false, error: error.localizedDescription)
                }
            }
            if let data = try? JSONEncoder().encode(response) {
                try? data.write(to: responseURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: claimedURL)
        }
    }

    private static func activeTurnMailboxURL(threadID: String, directory: URL) -> URL {
        let key = threadID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("active-\(key).json")
    }

    private func publishActiveTurnForMailbox(threadID: String, turnID: String) {
        guard let directory = Self.steerMailboxDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = Darwin.chmod(directory.path, mode_t(0o700))
            let data = try JSONEncoder().encode(ConversationSteerMailboxActiveTurn(
                threadID: threadID,
                turnID: turnID,
                processID: Int32(ProcessInfo.processInfo.processIdentifier)
            ))
            let url = Self.activeTurnMailboxURL(threadID: threadID, directory: directory)
            try data.write(to: url, options: .atomic)
            _ = Darwin.chmod(url.path, mode_t(0o600))
        } catch {
            StationAIDiagnostics.record("conversation.steer_mailbox.publish_failed", fields: ["threadID": threadID])
        }
    }

    private func clearActiveTurnForMailbox(threadID: String) {
        guard let directory = Self.steerMailboxDirectory else { return }
        try? FileManager.default.removeItem(at: Self.activeTurnMailboxURL(threadID: threadID, directory: directory))
    }

    func sendMessage(
        _ text: String,
        imageDataURLs: [String] = [],
        mode: CodexConversationMode,
        modelID: String,
        threadID: String,
        workspace: CodexWorkspaceContext,
        onDelta: @escaping (String) -> Void,
        onFinalMessage: @escaping (String) -> Void,
        onActivity: @escaping (CodexActivity) -> Void,
        onDiff: @escaping (CodexTurnDiff) -> Void,
        onHistory: @escaping (CodexThreadHistory) -> Void,
        onActionRequest: @escaping () -> Void,
        onUserInput: @escaping (CodexUserInputRequest) async -> Void,
        onSteerMessage: @escaping (String, [String]) -> Void = { _, _ in }
    ) async throws {
        actionRequestHandler = onActionRequest
        userInputHandler = onUserInput
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, modelID: modelID)

        activeThreadID = threadID
        Self.activeClientsByThreadID[threadID] = self
        activeTurnID = nil
        activeConversationMode = mode
        isTurnActive = false
        wasLastTurnInterrupted = false
        activeDeltaHandler = onDelta
        activeFinalMessageHandler = onFinalMessage
        activeSteerMessageHandler = onSteerMessage
        activeActivityHandler = onActivity
        activeDiffHandler = onDiff
        activeActivities.removeAll()
        defer {
            Self.processActiveThreadIDs.remove(threadID)
            clearActiveTurnForMailbox(threadID: threadID)
            if Self.activeClientsByThreadID[threadID] === self {
                Self.activeClientsByThreadID.removeValue(forKey: threadID)
            }
            activeThreadID = nil
            activeTurnID = nil
            activeConversationMode = .code
            isTurnActive = false
            activeDeltaHandler = nil
            activeFinalMessageHandler = nil
            activeSteerMessageHandler = nil
            activeActivityHandler = nil
            activeDiffHandler = nil
            activeActivities.removeAll()
            userInputHandler = nil
        }

        let response = try await request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": (text.isEmpty ? [] : [["type": "text", "text": text]]) + imageDataURLs.map { ["type": "image", "url": $0] },
                "model": modelID,
                "cwd": workspace.cwd.path,
                "runtimeWorkspaceRoots": workspace.roots.map(\.path),
                "approvalPolicy": "never",
                "approvalsReviewer": "user",
                "collaborationMode": [
                    "mode": mode.rawValue,
                    "settings": [
                        "model": modelID,
                        "reasoningEffort": NSNull(),
                        "developerInstructions": NSNull()
                    ]
                ]
            ]
        )

        guard let turn = response["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a turn ID.")
        }
        activeTurnID = turnID
        isTurnActive = true
        publishActiveTurnForMailbox(threadID: threadID, turnID: turnID)
        Self.processActiveThreadIDs.insert(threadID)
        StationAIDiagnostics.record("codex.turn.started", fields: diagnosticFields([
            "threadID": threadID,
            "turnID": turnID,
            "turnStatus": turn["status"] as? String ?? "unknown",
            "workspaceRootCount": String(workspace.roots.count),
        ]))

        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        switch turn["status"] as? String {
        case "completed":
            break
        case "failed", "interrupted":
            StationAIDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))
            throw ClientError.turnFailed(Self.turnFailureDescription(turn))
        default:
            let mailboxTask = Task { @MainActor [weak self] in
                while let self, !Task.isCancelled, self.activeThreadID == threadID, self.activeTurnID == turnID {
                    await self.serviceSteerMailbox(threadID: threadID, turnID: turnID)
                    try? await Task.sleep(for: .milliseconds(75))
                }
            }
            defer { mailboxTask.cancel() }
            do {
                try await waitForTurn(turnKey)
            } catch {
                var fields = StationAIDiagnostics.errorFields(error)
                fields["threadID"] = threadID
                fields["turnID"] = turnID
                fields.merge(diagnosticFields()) { _, new in new }
                StationAIDiagnostics.record("codex.turn.wait_failed", fields: fields)
                throw error
            }
        }

        if let history = try? await readMessages(threadID: threadID) {
            onHistory(history)
        }
    }

    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
        StationAIDiagnostics.record("codex.user_input.answer.started", fields: [
            "requestID": requestID,
            "threadID": threadID,
            "questionCount": String(answers.count),
            "answerCount": String(answers.values.reduce(0) { $0 + $1.count })
        ])
        guard let requestIDValue = pendingUserInputRequestID,
              String(describing: requestIDValue) == requestID,
              pendingUserInputThreadID == threadID else { return false }
        let answersAreValid = Set(answers.keys) == Set(pendingUserInputQuestions.keys) &&
            answers.allSatisfy { questionID, values in
                guard !values.isEmpty, let question = pendingUserInputQuestions[questionID] else { return false }
                guard !question.options.isEmpty else { return values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
                let allowedLabels = Set(question.options.map(\.label))
                return values.allSatisfy { allowedLabels.contains($0) || question.allowsOther }
            }
        guard answersAreValid else {
            StationAIDiagnostics.record("codex.user_input.answer.failed", fields: [
                "requestID": requestID,
                "threadID": threadID,
                "reason": "invalid_answer_shape",
                "questionCount": String(answers.count)
            ])
            self.pendingUserInputRequestID = nil
            pendingUserInputThreadID = nil
            pendingUserInputQuestions.removeAll()
            pendingUserInputRequest = nil
            sendServerError(requestID: requestIDValue, code: -32602, message: "Answers must include a non-empty response for every question.")
            return false
        }
        self.pendingUserInputRequestID = nil
        pendingUserInputThreadID = nil
        pendingUserInputQuestions.removeAll()
        do {
            try sendJSON(["jsonrpc": "2.0", "id": requestIDValue,
                          "result": ["answers": answers.mapValues { ["answers": $0] }]])
            self.pendingUserInputRequest = nil
            StationAIDiagnostics.record("codex.user_input.answer.succeeded", fields: [
                "requestID": requestID,
                "threadID": threadID,
                "questionCount": String(answers.count),
                "answerCount": String(answers.values.reduce(0) { $0 + $1.count })
            ])
            return true
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["requestID"] = requestID
            fields["threadID"] = threadID
            StationAIDiagnostics.record("codex.user_input.answer.failed", fields: fields)
            actionRequestHandler?()
            return false
        }
    }

    func rejectUserInput(requestID: String, threadID: String, message: String) {
        guard let requestIDValue = pendingUserInputRequestID,
              String(describing: requestIDValue) == requestID,
              pendingUserInputThreadID == threadID else { return }
        pendingUserInputRequestID = nil
        pendingUserInputThreadID = nil
        pendingUserInputQuestions.removeAll()
        pendingUserInputRequest = nil
        sendServerError(requestID: requestIDValue, code: -32000, message: message)

        guard activeThreadID == threadID, let turnID = activeTurnID else { return }
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

    func isTurnActive(threadID: String) -> Bool {
        startingThreadIDs.contains(threadID)
            || (activeThreadID == threadID && activeTurnID != nil)
            || pendingUserInputThreadID == threadID
    }

    func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        if let target = Self.activeClientsByThreadID[threadID],
           target.isTurnActive(threadID: threadID) {
            return Int32(ProcessInfo.processInfo.processIdentifier)
        }
        guard let directory = Self.steerMailboxDirectory else { return nil }
        let activeURL = Self.activeTurnMailboxURL(threadID: threadID, directory: directory)
        guard let active = try? JSONDecoder().decode(ConversationSteerMailboxActiveTurn.self, from: Data(contentsOf: activeURL)),
              active.threadID == threadID else { return nil }
        guard Darwin.kill(active.processID, 0) == 0 || errno == EPERM else {
            try? FileManager.default.removeItem(at: activeURL)
            return nil
        }
        return active.processID
    }

    func canInterruptActiveTurn(threadID: String) -> Bool {
        activeThreadID == threadID && activeTurnID != nil
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

    static func isTurnActiveInProcess(threadID: String) -> Bool {
        processActiveThreadIDs.contains(threadID)
    }

    private func ensureInitialized(workspace: CodexWorkspaceContext) async throws {
        if initialized, process?.isRunning == true {
            return
        }

        if process?.isRunning != true {
            if let stoppedProcess = process {
                processDidTerminate(stoppedProcess)
            }
            try launchProcess(workspaceURL: workspace.cwd)
        }

        _ = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "stationai",
                    "title": "StationAI",
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

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        child.executableURL = URL(fileURLWithPath: executablePath)
        child.arguments = [
            "app-server",
            "--listen", "stdio://",
            "--disable", "apps",
            "--disable", "remote_plugin",
            "--disable", "hooks",
            "-c", "mcp_servers={}"
        ]
        child.currentDirectoryURL = workspaceURL
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        child.environment = environment

        process = child
        inputPipe = stdin
        outputPipe = stdout
        stderrPipe = stderr
        stdoutBuffer.removeAll(keepingCapacity: true)

        let stdoutQueue = outputQueue
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            stdoutQueue.async { [weak self] in
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
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        child.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.processDidTerminate(terminatedProcess)
            }
        }

        do {
            try child.run()
            StationAIDiagnostics.record("codex.app_server.started", fields: diagnosticFields([
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

    private func resumeThreadIfNeeded(id threadID: String, workspace: CodexWorkspaceContext, modelID: String = CodexAppServerClient.modelID) async throws {
        if resumedThreadIDs.contains(threadID), process?.isRunning == true, initialized {
            return
        }

        try await ensureInitialized(workspace: workspace)
        StationAIDiagnostics.record("codex.thread.resume_started", fields: diagnosticFields([
            "threadID": threadID,
        ]))
        let response: [String: Any]
        do {
            response = try await request(
                method: "thread/resume",
                params: [
                    "threadId": threadID,
                    "model": modelID,
                    "cwd": workspace.cwd.path,
                    "sandbox": "danger-full-access",
                    "approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "runtimeWorkspaceRoots": workspace.roots.map(\.path)
                ]
            )
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["threadID"] = threadID
            fields.merge(diagnosticFields()) { _, new in new }
            StationAIDiagnostics.record("codex.thread.resume_failed", fields: fields)
            throw error
        }
        try confirmModel(response["model"] as? String, expected: modelID)
        resumedThreadIDs.insert(threadID)
        StationAIDiagnostics.record("codex.thread.resumed", fields: diagnosticFields([
            "threadID": threadID,
        ]))
    }

    private func readMessages(threadID: String) async throws -> CodexThreadHistory {
        var messages: [CodexChatMessage] = []
        var latestTurnItems: [[String: Any]] = []
        var lastAssistantTurnID: String?
        var cursor: String?
        var visitedCursors = Set<String>()

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
            let data = response["data"] as? [[String: Any]] ?? []
            for entry in data {
                guard let item = entry["item"] as? [String: Any] else { continue }
                if item["type"] as? String == "userMessage" {
                    latestTurnItems.removeAll()
                }
                latestTurnItems.append(item)
                if let message = Self.chatMessage(from: entry) {
                    if message.role == .assistant,
                       let turnID = entry["turnId"] as? String,
                       turnID == lastAssistantTurnID,
                       let lastIndex = messages.indices.last,
                       messages[lastIndex].role == .assistant {
                        messages[lastIndex].text += "\n\n" + message.text
                    } else {
                        messages.append(message)
                    }
                    lastAssistantTurnID = message.role == .assistant ? entry["turnId"] as? String : nil
                }
            }
            cursor = response["nextCursor"] as? String

            if let cursor, !visitedCursors.insert(cursor).inserted {
                throw ClientError.protocolFailure("Codex returned a repeated history cursor.")
            }
        } while cursor != nil

        let activities = latestTurnItems.compactMap(CodexActivity.from)
        return CodexThreadHistory(
            messages: messages,
            activities: activities,
            diff: CodexTurnDiff.fromFileChangeItems(latestTurnItems)
        )
    }

    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
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
        StationAIDiagnostics.record("codex.rpc.request.started", fields: fields)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
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
                var fields = StationAIDiagnostics.errorFields(error)
                fields["requestID"] = String(requestID)
                fields["method"] = method
                fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                StationAIDiagnostics.record("codex.rpc.request.failed", fields: fields)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String) throws {
        try sendJSON(["jsonrpc": "2.0", "method": method])
    }

    private func sendJSON(_ object: [String: Any]) throws {
        guard let process, process.isRunning, let inputPipe else {
            throw ClientError.processExited("Restart StationAI and try again.")
        }

        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw ClientError.protocolFailure(error.localizedDescription)
        }
    }

    private func consumeOutput(_ data: Data) async {
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.range(of: newline) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            await consume(line: line)
        }
    }

    private func consume(line: Data) async {
        guard !line.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if let method = message["method"] as? String {
            if let requestID = message["id"] {
                let params = message["params"] as? [String: Any] ?? [:]
                StationAIDiagnostics.record("codex.rpc.server_request", fields: Self.diagnosticNotificationFields(method: method, params: params))
                await handleServerRequest(method: method, params: params, requestID: requestID)
            } else {
                StationAIDiagnostics.record("codex.notification", fields: Self.diagnosticNotificationFields(
                    method: method,
                    params: message["params"] as? [String: Any] ?? [:]
                ))
                handleNotification(method: method, params: message["params"] as? [String: Any] ?? [:])
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
            StationAIDiagnostics.record("codex.rpc.response.failed", fields: responseFields.merging([
                "errorCode": String(describing: serverError["code"] ?? "unknown"),
                "errorDescription": "Codex returned an RPC error."
            ]) { _, new in new })
            continuation.resume(throwing: Self.error(forServerMessage: detail))
        } else if let result = message["result"] as? [String: Any] {
            StationAIDiagnostics.record("codex.rpc.response.succeeded", fields: responseFields.merging([
                "resultFieldNames": result.keys.sorted().joined(separator: ",")
            ]) { _, new in new })
            continuation.resume(returning: result)
        } else {
            StationAIDiagnostics.record("codex.rpc.response.failed", fields: responseFields.merging([
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
        for key in ["threadId", "itemId"] {
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

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            // Server notifications use params {threadId, turn:{id,status,...}}.
            guard let threadID = params["threadId"] as? String,
                  threadID == activeThreadID,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }
            activeTurnID = turnID
            isTurnActive = true
            Self.processActiveThreadIDs.insert(threadID)
        case "item/agentMessage/delta":
            guard params["threadId"] as? String == activeThreadID,
                  let delta = params["delta"] as? String else { return }
            activeDeltaHandler?(delta)
        case "item/started", "item/completed":
            guard params["threadId"] as? String == activeThreadID,
                  let item = params["item"] as? [String: Any] else { return }
            if method == "item/completed",
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String,
               !text.isEmpty {
                activeFinalMessageHandler?(text)
            }
            guard let activity = CodexActivity.from(item: item) else { return }
            activeActivities[activity.id] = activity
            activeActivityHandler?(activity)
        case "item/commandExecution/outputDelta":
            guard params["threadId"] as? String == activeThreadID,
                  let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String,
                  var activity = activeActivities[itemID] else { return }
            let output = String((activity.detail + delta).suffix(2_000))
            activity = CodexActivity(
                id: activity.id,
                title: activity.title,
                detail: output,
                status: activity.status
            )
            activeActivities[itemID] = activity
            activeActivityHandler?(activity)
        case "turn/diff/updated":
            guard params["threadId"] as? String == activeThreadID,
                  let diff = params["diff"] as? String, !diff.isEmpty else { return }
            activeDiffHandler?(CodexTurnDiff(unifiedDiff: diff))
        case "turn/completed":
            // A terminal notification has the same threadId/turn envelope; only a matching waiter completes.
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }

            StationAIDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))

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

    private func handleServerRequest(method: String, params: [String: Any], requestID: Any) async {
        let normalizedMethod = method.lowercased()
        if normalizedMethod.contains("approval") || normalizedMethod.contains("item/tool/") ||
            normalizedMethod.contains("elicitation"), method != "item/tool/requestUserInput" {
            actionRequestHandler?()
        }

        let result: [String: Any]
        switch method {
        case "item/tool/requestUserInput":
            guard let questionsRaw = params["questions"] as? [[String: Any]],
                  let threadID = params["threadId"] as? String,
                  let requestIDString = requestID as? String ?? (requestID as? NSNumber)?.stringValue else {
                sendServerError(requestID: requestID, code: -32602, message: "Invalid user input request.")
                return
            }
            let questions = questionsRaw.compactMap { raw -> CodexUserQuestion? in
                guard let id = raw["id"] as? String, let question = raw["question"] as? String else { return nil }
                let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> CodexUserQuestion.Option? in
                    guard let label = option["label"] as? String else { return nil }
                    return CodexUserQuestion.Option(label: label, description: option["description"] as? String)
                }
                return CodexUserQuestion(id: id, header: raw["header"] as? String ?? "Question", question: question,
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
            pendingUserInputRequestID = requestID
            pendingUserInputThreadID = threadID
            pendingUserInputQuestions = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
            let request = CodexUserInputRequest(
                id: requestIDString,
                threadID: threadID,
                questions: questions,
                isBlocking: activeConversationMode == .plan || (params["isBlocking"] as? Bool ?? true)
            )
            pendingUserInputRequest = request
            await userInputHandler?(request)
            return
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": "decline"]
        case "item/permissions/requestApproval":
            result = ["permissions": [:], "scope": "turn"]
        case "applyPatchApproval", "execCommandApproval":
            result = [
                "decision": [
                    "denied": ["rejection": "StationAI is configured without approval prompts; this action was not approved."]
                ]
            ]
        case "mcpServer/elicitation/request":
            result = ["action": "decline"]
        default:
            sendServerError(
                requestID: requestID,
                code: -32601,
                message: "StationAI does not provide this optional integration."
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

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }

        let exitDetail = "Codex CLI exited with status \(terminatedProcess.terminationStatus)."
        StationAIDiagnostics.record("codex.app_server.exited", fields: diagnosticFields([
            "codexPID": String(terminatedProcess.processIdentifier),
            "exitStatus": String(terminatedProcess.terminationStatus),
            "activeThreadID": activeThreadID ?? "",
            "activeTurnID": activeTurnID ?? "",
        ]))
        let error = ClientError.processExited(exitDetail)
        process = nil
        inputPipe = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        stderrPipe = nil
        initialized = false
        resumedThreadIDs.removeAll()
        activeThreadID = nil
        activeDeltaHandler = nil

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

    private static func chatMessage(from entry: [String: Any]) -> CodexChatMessage? {
        guard let item = entry["item"] as? [String: Any],
              let itemID = item["id"] as? String,
              let type = item["type"] as? String else {
            return nil
        }

        switch type {
        case "userMessage":
            let content = item["content"] as? [[String: Any]] ?? []
            let text = content.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined()
            let images = content.compactMap { part -> String? in
                guard part["type"] as? String == "image" else { return nil }
                return part["url"] as? String ?? part["image_url"] as? String
            }
            guard !text.isEmpty || !images.isEmpty else { return nil }
            return CodexChatMessage(id: itemID, role: .user, text: text, imageDataURLs: images)
        case "agentMessage":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return CodexChatMessage(id: itemID, role: .assistant, text: text)
        default:
            return nil
        }
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
            return "Codex Luna (\(Self.modelID)) isn't available to the current Codex sign-in. StationAI didn't switch models. Sign in with an account or provider that supports this model, then try again."
        }
        return message
    }

    private static func error(forServerMessage message: String) -> Error {
        let normalized = message.lowercased()
        if normalized.contains("unauthorized") || normalized.contains("authentication") ||
            normalized.contains("not logged in") || normalized.contains("sign in") ||
            normalized.contains("401") {
            return ClientError.authentication(message)
        }
        if normalized.contains("model") &&
            (normalized.contains("not found") || normalized.contains("unavailable") || normalized.contains("unknown") ||
                normalized.contains("not supported") || normalized.contains("unsupported")) {
            return ClientError.server("Codex couldn't use \(Self.modelID): \(message). StationAI won't switch models.")
        }
        return ClientError.server(message)
    }

    private static func findCodexExecutable(override: String?) -> String? {
        if let override, FileManager.default.isExecutableFile(atPath: override) { return override }
        let home = NSHomeDirectory()
        let commonPaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/opt/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex"
        ]
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
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

    private static func ownedTestFixtureExecutable(_ path: String?) -> String? {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let markerValues = [
            (".stationai-codex-fixture-owner", "StationAI test owns this Codex protocol fixture (v1).\n"),
            (".stationai-bridge-fixture", "StationAI bridge tests own this deterministic fixture (v1).\n"),
        ]
        for (name, value) in markerValues {
            let marker = directory.appendingPathComponent(name)
            if (try? String(contentsOf: marker, encoding: .utf8)) == value { return path }
        }
        return nil
    }

    private static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        paths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

enum TaskProgressReportInstructions {
    static func make(taskID: UUID) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let id = taskID.uuidString
        return """
        Report your current work on the StationAI task board using the StationAI CLI. Publish at phase changes and periodically during substantial work so the card stays current, without reporting every small step. During tests, identify the active test and position when known (for example, "Test 3/8: task progress persistence"); during other work, name the current concrete activity. Keep each detail to a short subtitle, ideally under 80 characters, and update it as the work moves on. Use these commands for this task:
        \(quotedExecutable) task progress publish \(id) --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail \"short detail\"]
        \(quotedExecutable) task progress custom \(id) --label \"short label\" [--detail \"short detail\"]
        \(quotedExecutable) task progress clear \(id)
        Progress reports are hidden from the conversation and shown on the task card. Keep details brief. Do not use lifecycle task status commands for progress; StationAI clears the report when the turn finishes or requests user input.
        """
    }

    private static func cliExecutableURL() -> URL {
        let fileManager = FileManager.default
        var candidate = Bundle.main.bundleURL
        for _ in 0..<5 {
            let cli = candidate.appendingPathComponent("Contents/MacOS/stationai-cli")
            if fileManager.isExecutableFile(atPath: cli.path) { return cli }
            candidate.deleteLastPathComponent()
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/stationai-cli")
    }
}
