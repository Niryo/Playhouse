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
    let goalRuntimeEnabled: Bool
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
                "Codex CLI wasn't found. Install Codex CLI or add it to PATH, then restart StationAI."
            case .processStart(let detail):
                "StationAI couldn't start Codex CLI: \(detail)"
            case .processExited(let detail):
                "The Codex app-server stopped unexpectedly. \(detail)"
            case .protocolFailure(let detail):
                "StationAI couldn't communicate with Codex: \(detail)"
            case .server(let detail):
                detail
            case .staleTurn(let detail):
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
    private struct DeltaLogSummary {
        var notificationCount = 0
        var payloadBytes = 0
    }
    private var deltaLogSummaries: [String: (threadID: String, turnID: String, itemID: String, method: String, summary: DeltaLogSummary)] = [:]
    private let deltaLogSummaryLimit = 100
    private var nextRequestID = 1
    private var initialized = false
    private var resumedThreadIDs = Set<String>()
    private var activeTurnID: String?
    private var conversationOperationsInFlight = 0
    private var applicationShutdownInterruptResult: String?
    private(set) var wasLastTurnInterrupted = false
    private(set) var isPreparingForApplicationTermination = false
    private var activeDeltaHandler: ((String) -> Void)?
    private var activeFinalMessageHandler: ((String) -> Void)?
    private var activeProgressMessageHandler: ((ConversationMessage) -> Void)?
    private var activeSteerMessageHandler: ((String, [String]) -> Void)?
    private var activeActivityHandler: ((ConversationActivity) -> Void)?
    private var activeDiffHandler: ((ConversationTurnDiff) -> Void)?
    private var activeActivities: [String: ConversationActivity] = [:]
    private var goalObservationThreadID: String?
    private var goalTurnStartRevision = 0
    private var activityStartedAtUptime: [String: UInt64] = [:]
    private var activityStartedAtDate: [String: Date] = [:]
    private(set) var lastTurnActivityDurations: [String: Int] = [:]
    private var actionRequestHandler: (() -> Void)?
    private var userInputHandler: ((ConversationUserInputRequest) async -> Void)?
    private var pendingUserInputRequestID: Any?
    private var pendingUserInputThreadID: String?
    private var pendingUserInputQuestions: [String: ConversationUserQuestion] = [:]
    private let codexExecutableOverride: String?
    private let codexHomeOverride: String?
    private let goalFeatureEnabled: Bool
    private var turnWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var completedTurns: [String: Result<Void, Error>] = [:]
    private var rejectedTurnKeys = Set<String>()

    init(codexExecutableOverride: String? = nil, codexHomeOverride: String? = nil, goalFeatureEnabled: Bool = false, goalRuntimeEnabled: Bool = false) {
        self.codexExecutableOverride = ConversationProviderFixture.ownedExecutable(
            codexExecutableOverride,
            providerMarker: (".stationai-codex-fixture-owner", "StationAI test owns this Codex protocol fixture (v1).\n")
        )
        self.codexHomeOverride = codexHomeOverride
        self.goalFeatureEnabled = goalFeatureEnabled
        self.goalRuntimeEnabled = goalRuntimeEnabled
    }

    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
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
        workspace: ConversationWorkspaceContext,
        developerInstructions: String? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        sensitiveConversation: Bool = false,
        onActionRequest: @escaping () -> Void
    ) async throws -> ConversationHistory {
        actionRequestHandler = onActionRequest
        if goalRuntimeEnabled {
            if activeThreadID != threadID {
                activeTurnID = nil
                isTurnActive = false
            }
            activeThreadID = threadID
            goalObservationThreadID = threadID
            Self.activeClientsByThreadID[threadID] = self
        }
        try await resumeThreadIfNeeded(
            id: threadID,
            workspace: workspace,
            developerInstructions: developerInstructions,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            sensitiveConversation: sensitiveConversation
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

    func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption] {
        try await ensureInitialized(workspace: workspace)
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
        return models.isEmpty ? [ConversationModelOption(id: Self.modelID, name: "GPT-6 Luna", isDefault: true)] : models
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
        guard let threadID = activeThreadID,
              threadID == expectedThreadID,
              let turnID = activeTurnID else {
            // Another StationAI process may own the turn.
            guard Self.activeClientsByThreadID[expectedThreadID] == nil else { return false }
            return try await ConversationSteerMailbox.requestInterrupt(threadID: expectedThreadID)
        }
        wasLastTurnInterrupted = true
        do {
            _ = try await request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID])
            return true
        } catch {
            wasLastTurnInterrupted = false
            throw error
        }
    }

    func getGoal(threadID: String, workspace: ConversationWorkspaceContext) async throws -> CodexThreadGoal? {
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace)
        let response = try await request(method: "thread/goal/get", params: ["threadId": threadID])
        guard let value = response["goal"] as? [String: Any] else { return nil }
        return Self.decodeGoal(value)
    }

    func setGoal(threadID: String, objective: String? = nil, status: String? = nil, workspace: ConversationWorkspaceContext, observeRuntime: Bool = false) async throws -> CodexThreadGoal? {
        let startRevision = goalTurnStartRevision
        if observeRuntime && goalRuntimeEnabled {
            activeThreadID = threadID
            activeTurnID = nil
            activeConversationMode = .code
            goalObservationThreadID = threadID
            goalTurnStartedThreadID = nil
            isTurnActive = false
            Self.activeClientsByThreadID[threadID] = self
        }
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace)
        var params: [String: Any] = ["threadId": threadID]
        if let objective { params["objective"] = objective }
        if let status { params["status"] = status }
        let response = try await request(method: "thread/goal/set", params: params)
        guard let value = response["goal"] as? [String: Any] else { return nil }
        if observeRuntime && goalRuntimeEnabled {
            try await waitForGoalTurnStart(threadID: threadID, after: startRevision)
            goalTurnRevision += 1
        }
        return Self.decodeGoal(value)
    }

    func clearGoal(threadID: String, workspace: ConversationWorkspaceContext) async throws {
        try await resumeThreadIfNeeded(id: threadID, workspace: workspace)
        _ = try await request(method: "thread/goal/clear", params: ["threadId": threadID])
    }

    func shutdown() {
        guard let process else {
            StationAIDiagnostics.record("codex.app_server.shutdown.skipped", fields: ["reason": "no_process"])
            return
        }
        guard process.isRunning else {
            StationAIDiagnostics.record("codex.app_server.shutdown.skipped", fields: [
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
        StationAIDiagnostics.record("codex.app_server.shutdown.finished", fields: [
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
        StationAIDiagnostics.record("application.shutdown.started", fields: [
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
                    StationAIDiagnostics.record("application.shutdown.interrupt_failed", fields: [
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
        StationAIDiagnostics.record("application.shutdown.turn_drained", fields: [
            "turnStillActive": String(isTurnActive),
            "conversationOperationsInFlight": String(conversationOperationsInFlight),
            "interruptAttempted": String(interruptAttempted),
            "interruptAccepted": interruptResult,
            "drainTimedOut": String(conversationOperationsInFlight > 0),
            "elapsedMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
        ])
        shutdown()
        StationAIDiagnostics.record("application.shutdown.finished", fields: [
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
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard let target = Self.activeClientsByThreadID[expectedThreadID] else {
            return try await ConversationSteerMailbox.requestSteer(threadID: expectedThreadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        guard let threadID = target.activeThreadID, threadID == expectedThreadID,
              let turnID = target.activeTurnID, target.isTurnActive else { return false }
        return try await target.sendSteerRequest(threadID: threadID, turnID: turnID, text: normalized, imageDataURLs: imageDataURLs)
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
            if accepted { activeSteerMessageHandler?(text, images) }
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
        onTurnStarted: @escaping (String) -> Void,
        sensitiveUserInputAnswerValues: [String] = [],
        hideSensitiveRecoveryPrompt: Bool = false
    ) async throws {
        actionRequestHandler = onActionRequest
        userInputHandler = onUserInput
        try await resumeThreadIfNeeded(
            id: threadID,
            workspace: workspace,
            modelID: modelID,
            developerInstructions: developerInstructions,
            sensitiveUserInputAnswerValues: sensitiveUserInputAnswerValues,
            sensitiveConversation: hideSensitiveRecoveryPrompt || !sensitiveUserInputAnswerValues.isEmpty
        )
        goalObservationThreadID = nil
        activeThreadID = threadID
        Self.activeClientsByThreadID[threadID] = self
        activeTurnID = nil
        activeConversationMode = mode
        isTurnActive = false
        wasLastTurnInterrupted = false
        activeDeltaHandler = onDelta
        activeFinalMessageHandler = onFinalMessage
        activeProgressMessageHandler = onProgressMessage
        activeSteerMessageHandler = onSteerMessage
        activeActivityHandler = onActivity
        activeDiffHandler = onDiff
        activeActivities.removeAll()
        activityStartedAtUptime.removeAll()
        activityStartedAtDate.removeAll()
        lastTurnActivityDurations.removeAll()
        defer {
            Self.processActiveThreadIDs.remove(threadID)
            ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
            if Self.activeClientsByThreadID[threadID] === self {
                Self.activeClientsByThreadID.removeValue(forKey: threadID)
            }
            activeThreadID = nil
            activeTurnID = nil
            activeConversationMode = .code
            isTurnActive = false
            activeDeltaHandler = nil
            activeFinalMessageHandler = nil
            activeProgressMessageHandler = nil
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
                        "reasoningEffort": effort.rawValue
                    ]
                ]
            ]
        )

        guard let turn = response["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw ClientError.protocolFailure("Codex did not return a turn ID.")
        }
        activeTurnID = turnID
        onTurnStarted(turnID)
        isTurnActive = true
        ConversationSteerMailbox.publishActiveTurn(threadID: threadID, turnID: turnID)
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
                var fields = hideSensitiveRecoveryPrompt
                    ? ["errorDescription": "Private conversation recovery turn failed."]
                    : StationAIDiagnostics.errorFields(error)
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

    func isObservingGoal(threadID: String) -> Bool {
        goalObservationThreadID == threadID
    }

    func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        if let target = Self.activeClientsByThreadID[threadID],
           target.isTurnActive(threadID: threadID) {
            return Int32(ProcessInfo.processInfo.processIdentifier)
        }
        return ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: threadID)
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

    private func ensureInitialized(workspace: ConversationWorkspaceContext) async throws {
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
        var arguments = [
            "app-server",
            "--listen", "stdio://",
            "--disable", "apps",
            "--disable", "remote_plugin",
            "--disable", "hooks",
            "-c", "mcp_servers={}"
        ]
        if goalFeatureEnabled || goalRuntimeEnabled {
            arguments += ["-c", "features.goals=true"]
        }
        child.arguments = arguments
        child.currentDirectoryURL = workspaceURL
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardStationAIBridgeEnvironment(&environment)
        if let codexHomeOverride { environment["CODEX_HOME"] = codexHomeOverride }
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

    private func resumeThreadIfNeeded(
        id threadID: String,
        workspace: ConversationWorkspaceContext,
        modelID: String = CodexAppServerClient.modelID,
        developerInstructions: String? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        sensitiveConversation: Bool = false
    ) async throws {
        if resumedThreadIDs.contains(threadID), process?.isRunning == true, initialized {
            return
        }

        try await ensureInitialized(workspace: workspace)
        StationAIDiagnostics.record("codex.thread.resume_started", fields: diagnosticFields([
            "threadID": threadID,
        ]))
        let response: [String: Any]
        do {
            var params: [String: Any] = [
                    "threadId": threadID,
                    "model": modelID,
                    "cwd": workspace.cwd.path,
                    "sandbox": "danger-full-access",
                    "approvalPolicy": "never",
                    "approvalsReviewer": "user",
                    "runtimeWorkspaceRoots": workspace.roots.map(\.path)
                ]
            if let developerInstructions {
                params["developerInstructions"] = developerInstructions
            }
            response = try await request(method: "thread/resume", params: params)
        } catch {
            var fields = sensitiveConversation
                ? ["errorDescription": "History for a private recovery conversation could not be loaded."]
                : StationAIDiagnostics.errorFields(error, redacting: sensitiveUserInputAnswerValues)
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
                    historicalItem["_stationaiTurnID"] = entry["turnId"]
                    if let index = toolItemIndexes[itemID] {
                        historicalToolItems[index] = historicalItem
                    } else {
                        toolItemIndexes[itemID] = historicalToolItems.count
                        historicalToolItems.append(historicalItem)
                    }
                }
                var historicalSubagentItem = item
                historicalSubagentItem["_stationaiTurnID"] = entry["turnId"]
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
                    latestTurnItems.removeAll()
                    lastAssistantTurnID = nil
                    lastAssistantPhase = nil
                }
                var latestTurnItem = item
                latestTurnItem["_stationaiTurnID"] = entry["turnId"]
                latestTurnItems.append(latestTurnItem)
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
            cursor = response["nextCursor"] as? String

            if let cursor, !visitedCursors.insert(cursor).inserted {
                throw ClientError.protocolFailure("Codex returned a repeated history cursor.")
            }
        } while cursor != nil

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
            activity.turnID = item["_stationaiTurnID"] as? String
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
            activity.turnID = item["_stationaiTurnID"] as? String
            let key = activity.childThreadID ?? activity.id
            if let index = activityIndexes[key] { activities[index] = activity }
            else { activityIndexes[key] = activities.count; activities.append(activity) }
        }
        for item in historicalSubagentItems {
            guard var activity = ConversationActivity.from(item: item) else { continue }
            activity.turnID = item["_stationaiTurnID"] as? String
            let key = activity.childThreadID ?? activity.id
            if let index = activityIndexes[key] { activities[index] = activity }
            else { activityIndexes[key] = activities.count; activities.append(activity) }
        }
        return ConversationHistory(
            messages: messages,
            activities: activities,
            diff: ConversationTurnDiff.fromFileChangeItems(latestTurnItems)
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
                let params = message["params"] as? [String: Any] ?? [:]
                if Self.highVolumeDeltaMethods.contains(method) {
                    recordDeltaLogSummary(method: method, params: params)
                } else {
                    StationAIDiagnostics.record("codex.notification", fields: Self.diagnosticNotificationFields(
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
            StationAIDiagnostics.record("codex.rpc.response.failed", fields: responseFields.merging([
                "errorCode": String(describing: serverError["code"] ?? "unknown"),
                "errorDescription": "Codex returned an RPC error."
            ]) { _, new in new })
            continuation.resume(throwing: Self.error(
                forServerMessage: detail,
                method: requestDiagnostics?.method
            ))
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

    private func flushDeltaLogSummary(for key: String, reason: String) {
        guard let entry = deltaLogSummaries.removeValue(forKey: key) else { return }
        StationAIDiagnostics.record("codex.notification.summary", fields: [
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
        switch method {
        case "thread/goal/updated", "thread/goal/cleared":
            guard let threadID = params["threadId"] as? String else { return }
            goalStateThreadID = threadID
            goalStateRevision += 1
        case "turn/started":
            // Server notifications use params {threadId, turn:{id,status,...}}.
            guard let threadID = params["threadId"] as? String,
                  threadID == activeThreadID,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }
            activeTurnID = turnID
            isTurnActive = true
            Self.processActiveThreadIDs.insert(threadID)
            if goalObservationThreadID == threadID {
                goalTurnStartRevision += 1
                goalTurnRevision += 1
                goalTurnStartedThreadID = threadID
            }
        case "item/agentMessage/delta", "item/plan/delta":
            guard params["threadId"] as? String == activeThreadID,
                  let delta = params["delta"] as? String else { return }
            activeDeltaHandler?(delta)
        case "item/started", "item/completed":
            guard params["threadId"] as? String == activeThreadID,
                  let item = params["item"] as? [String: Any] else { return }
            if goalObservationThreadID == activeThreadID { goalTurnRevision += 1 }
            if method == "item/completed",
               let itemType = item["type"] as? String,
               itemType == "agentMessage" || itemType == "plan" {
                let text = item["text"] as? String ?? ""
                let questions = itemType == "agentMessage" && item["delivery"] as? String == "async"
                    ? Self.asyncQuestions(from: item) : nil
                guard !text.isEmpty || questions != nil else { return }
                if itemType == "agentMessage", item["delivery"] as? String == "async",
                   let questions {
                    activeProgressMessageHandler?(ConversationMessage(
                        id: item["id"] as? String ?? UUID().uuidString,
                        role: .assistant,
                        text: text,
                        phase: item["phase"] as? String,
                        turnID: params["turnId"] as? String,
                        asyncQuestions: questions
                    ))
                } else if itemType == "agentMessage", item["phase"] as? String == "commentary" {
                    activeProgressMessageHandler?(ConversationMessage(
                        id: item["id"] as? String ?? UUID().uuidString,
                        role: .assistant,
                        text: text,
                        phase: "commentary",
                        turnID: params["turnId"] as? String
                    ))
                } else {
                    activeFinalMessageHandler?(text)
                }
            }
            let activityID = item["type"] as? String == "subAgentActivity"
                ? (item["agentThreadId"] as? String ?? item["id"] as? String)
                : item["id"] as? String
            guard let activityID else { return }
            if method == "item/started" {
                activityStartedAtUptime[activityID] = activityStartedAtUptime[activityID] ?? DispatchTime.now().uptimeNanoseconds
                activityStartedAtDate[activityID] = activityStartedAtDate[activityID] ?? .now
            }
            let measuredDuration: Int?
            if method == "item/completed", let started = activityStartedAtUptime[activityID] {
                measuredDuration = max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
            } else {
                measuredDuration = nil
            }
            guard let activity = ConversationActivity.from(
                item: item,
                lifecycle: method == "item/completed" ? "completed" : "inProgress",
                turnID: params["turnId"] as? String,
                startedAt: activityStartedAtDate[activityID],
                measuredDurationMs: measuredDuration
            ) else { return }
            if method == "item/completed" {
                if let durationMs = activity.durationMs { lastTurnActivityDurations[activity.id] = durationMs }
                activityStartedAtUptime.removeValue(forKey: activityID)
                activityStartedAtDate.removeValue(forKey: activityID)
            }
            activeActivities[activity.id] = activity
            activeActivityHandler?(activity)
        case "item/commandExecution/outputDelta":
            guard params["threadId"] as? String == activeThreadID,
                  let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String,
                  var activity = activeActivities[itemID] else { return }
            let output = String((activity.detail + delta).suffix(2_000))
            activity.detail = output
            activeActivities[itemID] = activity
            activeActivityHandler?(activity)
        case "turn/diff/updated":
            guard params["threadId"] as? String == activeThreadID,
                  let diff = params["diff"] as? String, !diff.isEmpty else { return }
            activeDiffHandler?(ConversationTurnDiff(unifiedDiff: diff))
        case "turn/completed":
            // A terminal notification has the same threadId/turn envelope; only a matching waiter completes.
            guard let threadID = params["threadId"] as? String,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String else { return }

            flushDeltaLogSummaries(threadID: threadID, turnID: turnID, reason: "turn_completed")

            StationAIDiagnostics.record("codex.turn.ended", fields: diagnosticFields([
                "threadID": threadID,
                "turnID": turnID,
                "turnStatus": turn["status"] as? String ?? "unknown",
            ]))

            if goalObservationThreadID == threadID, activeTurnID == turnID {
                activeTurnID = nil
                isTurnActive = false
                goalTurnCompletedTurnID = turnID
                Self.processActiveThreadIDs.remove(threadID)
                ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
                goalTurnRevision += 1
                goalTurnCompletedRevision += 1
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

    private func handleServerRequest(method: String, params: [String: Any], requestID: Any) async {
        let normalizedMethod = method.lowercased()
        if normalizedMethod.contains("approval") || normalizedMethod.contains("item/tool/") ||
            normalizedMethod.contains("elicitation"),
           method != "item/tool/requestUserInput", method != "tool/requestUserInput" {
            actionRequestHandler?()
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
            pendingUserInputRequestID = requestID
            pendingUserInputThreadID = threadID
            pendingUserInputQuestions = Dictionary(uniqueKeysWithValues: questions.map { ($0.id, $0) })
            let request = ConversationUserInputRequest(
                id: requestIDString,
                threadID: threadID,
                questions: questions,
                isBlocking: activeConversationMode == .plan || (params["isBlocking"] as? Bool ?? true),
                mode: activeConversationMode
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

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }

        for key in Array(deltaLogSummaries.keys) { flushDeltaLogSummary(for: key, reason: "app_server_exit") }

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
            return "Codex Luna (\(Self.modelID)) isn't available to the current Codex sign-in. StationAI didn't switch models. Sign in with an account or provider that supports this model, then try again."
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
            return ClientError.server("Codex couldn't use \(Self.modelID): \(message). StationAI won't switch models.")
        }
        return ClientError.server(message)
    }

    static var isInstalled: Bool { findCodexExecutable(override: nil) != nil }

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

    private static func expandedSearchPath(_ existingPath: String?) -> String {
        var paths = (existingPath ?? "").split(separator: ":").map(String.init)
        paths.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin"])
        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
    }
}

enum TaskThreadDeveloperInstructions {
    /// Instructions StationAI attaches to provider conversation turns.
    static func make(
        taskID: UUID,
        repositories: [RepositoryWorktreeRecord] = [],
        contextFolders: [String] = [],
        repositoryRootPath: String? = nil
    ) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let id = taskID.uuidString
        return """
        Report your current work on the StationAI task board using the StationAI CLI. Publish at every phase change, when starting or finishing a substantial tool call, and at least every 30 seconds during long commands, builds, tests, waits, or investigation. Keep the report current while a tool runs; after it finishes, replace it with the next active action. During tests, identify the active suite/case and position when known (for example, "CLI/XPC 3/8: task progress persistence"); during other work, name the concrete action and useful target. Keep each detail to a short subtitle, ideally under 80 characters. Do not report every tiny edit. Use these commands for this task:
        \(quotedExecutable) task progress publish \(id) --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail \"short detail\"]
        \(quotedExecutable) task progress custom \(id) --label \"short label\" [--detail \"short detail\"]
        \(quotedExecutable) task progress clear \(id)
        Progress reports are hidden from the conversation and shown on the task card. Keep details brief. Do not use lifecycle task status commands for progress.
        To show the user an image you created (such as a screenshot or chart), publish it into this task's chat with:
        \(quotedExecutable) conversation present-image \(id) --image <path> [--caption "short caption"]
        This adds a durable assistant image message to the chat. Use PNG or JPEG files smaller than 10 MB.

        Repository context for this task:
        - Selected repositories (source identity): \(repositories.isEmpty ? "none" : repositories.map(\.repositoryPath).joined(separator: ", "))
        - Active task worktrees for edits: \(repositories.isEmpty ? "none" : repositories.map { "\($0.repositoryPath) -> \($0.worktreePath)" }.joined(separator: "; "))
        - Additional context folders: \(contextFolders.isEmpty ? "none" : contextFolders.joined(separator: ", "))
        - Configured repository root: \(repositoryRootPath ?? "not available")
        A task may intentionally have no selected repository. Decide whether it is standalone or needs repository context. For read-only inspection, you do not need to attach a repository or create a worktree: call \(quotedExecutable) workspace repos list, then inspect a clearly matching returned repository path read-only. Never edit files in those source paths. If the request is standalone, proceed without repository context.
        Add a repository to this task only when you intend to create or commit changes in it. If the needed repository is not already selected, call \(quotedExecutable) workspace repos list, choose a clearly matching returned path, then call \(quotedExecutable) task repository add <task-id> --repo <path> (or add-batch for multiple repositories). This creates the task worktree and returns the source-to-worktree mapping; make all changes in the returned worktreePath. You do not need to ask the user for special permission to read another listed repository, and you do not need to add a repository just to inspect it. If no returned path clearly matches a requested change, ask the user which repository to modify. Do not add or replace repositories merely because the selected context seems unrelated to the task; the user may have intentionally left a sticky default selected.
        For already selected repositories, make changes in their corresponding active task worktrees above. For folder-only tasks, use the selected additional context folder; with no repository or folder context, treat the task as standalone unless the user asks for files that clearly belong in a repository. StationAI starts the provider conversation with the active task worktree as cwd and runtime workspace root. Temporary files under /tmp and other non-repository directories remain available when useful.
        Use the workspace repos list API for repository discovery; do not search the configured root to find repositories yourself. Once the API returns a repository path, you may inspect that repository's contents read-only without adding it. For read-only inspection of returned source paths, you do not need to add a repository.
        A selected repository can be a sticky default from an earlier task, and the user may have forgotten to change it. Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated. Use workspace repos list to discover alternatives when needed. Read-only inspection of returned source paths does not require adding repositories. Add a repository only when you intend to make or commit changes there, and use its task worktreePath for every edit. Do not replace or remove selected repositories unless the user explicitly asks; adding a worktree for a change is sufficient. Never silently edit a source repository path.
        Repository context commands for this task:
        \(quotedExecutable) task get \(id)
        \(quotedExecutable) task repository add \(id) --repo <path>
        \(quotedExecutable) task repository add-batch \(id) --repo <path> [--repo <path>...]
        \(quotedExecutable) task repository replace \(id) --repo <path> [--repo <path>...]
        \(quotedExecutable) task repository remove \(id) --repo <path>
        \(quotedExecutable) settings get
        \(quotedExecutable) workspace repos list

        At the very end of every turn, make exactly one definitive outcome call using this task ID:
        \(quotedExecutable) task outcome \(id) <completed|waiting-response>
        Use completed only when all work for this turn is finished and no user decision or response is needed. If you need the user to answer, choose between options, provide missing information, or take another action before you can continue, use waiting-response. The outcome call must be your final CLI action for the turn. StationAI moves the task to Review only for completed. If you omit the outcome call, StationAI moves it to Waiting Response.
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

enum TaskProgressReportInstructions {
    static let executableName = "stationai-cli"
    static let progressSubcommand = "task progress"
    static let outcomeSubcommand = "task outcome"

    enum ReportCommand { case progress, outcome }

    /// Classifies a provider shell command as one of the reports these instructions request.
    static func reportCommand(in shellCommand: String) -> ReportCommand? {
        guard shellCommand.contains(executableName) else { return nil }
        if shellCommand.contains(" \(outcomeSubcommand) ") { return .outcome }
        if shellCommand.contains(" \(progressSubcommand) ") { return .progress }
        return nil
    }

}
