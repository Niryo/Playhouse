import Combine
import Foundation

enum CodexChatRole: String, Codable, Equatable {
    case user
    case assistant
}

struct CodexChatMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: CodexChatRole
    var text: String
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
    private var startingThreadIDs = Set<String>()
    @Published private(set) var isTurnActive = false
    @Published private(set) var pendingUserInputRequest: CodexUserInputRequest?

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
    private var nextRequestID = 1
    private var initialized = false
    private var resumedThreadIDs = Set<String>()
    private var activeThreadID: String?
    private var activeTurnID: String?
    private(set) var wasLastTurnInterrupted = false
    private var activeDeltaHandler: ((String) -> Void)?
    private var activeFinalMessageHandler: ((String) -> Void)?
    private var activeActivityHandler: ((CodexActivity) -> Void)?
    private var activeDiffHandler: ((CodexTurnDiff) -> Void)?
    private var activeActivities: [String: CodexActivity] = [:]
    private var actionRequestHandler: (() -> Void)?
    private var userInputHandler: ((CodexUserInputRequest) -> Void)?
    private var pendingUserInputRequestID: Any?
    private var pendingUserInputThreadID: String?
    private var pendingUserInputQuestions: [String: CodexUserQuestion] = [:]
    private let codexExecutableOverride: String?
    private var turnWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedTurns: [String: Result<Void, Error>] = [:]

    init(codexExecutableOverride: String? = nil) {
        self.codexExecutableOverride = Self.ownedTestFixtureExecutable(codexExecutableOverride)
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

    func startThread(workspace: CodexWorkspaceContext, modelID: String = CodexAppServerClient.modelID) async throws -> String {
        try await ensureInitialized(workspace: workspace)

        let response = try await request(
            method: "thread/start",
            params: [
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
        )

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

    func sendMessage(
        _ text: String,
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
        onUserInput: @escaping (CodexUserInputRequest) -> Void
    ) async throws {
        actionRequestHandler = onActionRequest
        userInputHandler = onUserInput
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace, modelID: modelID)

        activeThreadID = threadID
        activeTurnID = nil
        isTurnActive = false
        wasLastTurnInterrupted = false
        activeDeltaHandler = onDelta
        activeFinalMessageHandler = onFinalMessage
        activeActivityHandler = onActivity
        activeDiffHandler = onDiff
        activeActivities.removeAll()
        defer {
            Self.processActiveThreadIDs.remove(threadID)
            activeThreadID = nil
            activeTurnID = nil
            isTurnActive = false
            activeDeltaHandler = nil
            activeFinalMessageHandler = nil
            activeActivityHandler = nil
            activeDiffHandler = nil
            activeActivities.removeAll()
            userInputHandler = nil
        }

        let response = try await request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": text]],
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
        Self.processActiveThreadIDs.insert(threadID)

        let turnKey = Self.turnKey(threadID: threadID, turnID: turnID)
        switch turn["status"] as? String {
        case "completed":
            break
        case "failed", "interrupted":
            throw ClientError.turnFailed(Self.turnFailureDescription(turn))
        default:
            try await waitForTurn(turnKey)
        }

        if let history = try? await readMessages(threadID: threadID) {
            onHistory(history)
        }
    }

    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
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
            return true
        } catch {
            actionRequestHandler?()
            return false
        }
    }

    func isTurnActive(threadID: String) -> Bool {
        startingThreadIDs.contains(threadID)
            || (activeThreadID == threadID && activeTurnID != nil)
            || pendingUserInputThreadID == threadID
    }

    func markTurnStarting(threadID: String) {
        startingThreadIDs.insert(threadID)
    }

    func clearTurnStarting(threadID: String) {
        startingThreadIDs.remove(threadID)
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
            "--disable", "multi_agent",
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
                Task { @MainActor [weak self] in
                    self?.consumeOutput(data)
                }
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
        let response = try await request(
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
        try confirmModel(response["model"] as? String, expected: modelID)
        resumedThreadIDs.insert(threadID)
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

    private func consumeOutput(_ data: Data) {
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.range(of: newline) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            consume(line: line)
        }
    }

    private func consume(line: Data) {
        guard !line.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if let method = message["method"] as? String {
            if let requestID = message["id"] {
                handleServerRequest(method: method, params: message["params"] as? [String: Any] ?? [:], requestID: requestID)
            } else {
                handleNotification(method: method, params: message["params"] as? [String: Any] ?? [:])
            }
            return
        }

        guard let requestID = message["id"] as? Int,
              let continuation = pendingRequests.removeValue(forKey: requestID) else {
            return
        }

        if let serverError = message["error"] as? [String: Any] {
            let detail = serverError["message"] as? String ?? "Codex returned an unspecified error."
            continuation.resume(throwing: Self.error(forServerMessage: detail))
        } else if let result = message["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: ClientError.protocolFailure("Codex returned an empty response."))
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
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
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }

            let key = Self.turnKey(threadID: threadID, turnID: turnID)
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

    private func handleServerRequest(method: String, params: [String: Any], requestID: Any) {
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
                isBlocking: params["isBlocking"] as? Bool ?? true
            )
            pendingUserInputRequest = request
            userInputHandler?(request)
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
            guard !text.isEmpty else { return nil }
            return CodexChatMessage(id: itemID, role: .user, text: text)
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
