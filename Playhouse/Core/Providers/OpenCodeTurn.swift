import Foundation

/// One running turn of one OpenCode session on a shared `opencode serve`.
///
/// The turn reads the server's event stream (`GET /api/event`): a turn starts when OpenCode
/// delivers its prompt from the session's inbox and ends with `session.execution.succeeded`,
/// `failed` or `interrupted`. Text, tool and step events in between become the turn's messages,
/// activities and usage; `permission.asked` and `form.created` are answered through the API.
/// After a daemon restart a turn is rebuilt from the session's messages and followed live.
@MainActor
package final class OpenCodeTurn {
    package typealias ClientError = OpenCodeClient.ClientError

    /// A question OpenCode's `question` tool asked through a form.
    package struct PendingQuestion {
        package let requestKey: String
        package let formID: String
        package let sessionID: String
        /// Each question's ID with the form field its answer goes in.
        package let fields: [(questionID: String, key: String)]

        package init(requestKey: String, formID: String, sessionID: String, fields: [(questionID: String, key: String)]) {
            self.requestKey = requestKey
            self.formID = formID
            self.sessionID = sessionID
            self.fields = fields
        }
    }

    package let sessionID: String
    package let connection: OpenCodeServerConnection
    package weak var owner: OpenCodeClient?
    package let turnID: String
    package let mode: ConversationMode
    package let readOnly: Bool
    package var promptMessageID: String?
    package var subscription: UUID?
    package var started = false
    package var finished = false
    package var wasInterrupted = false
    package var result: Result<Void, Error>?
    package var waiter: CheckedContinuation<Void, Error>?

    /// The answer OpenCode is writing, by its text part (`<message>:<ordinal>`). A later text,
    /// a tool call or a steer closes it as commentary; the turn's last one is its final answer.
    package var pendingAssistantText: (id: String, text: String, recorded: Bool)?
    package var recordedTextIDs: Set<String> = []
    /// Text parts a rebuild already holds in full: their live deltas are not added again.
    package var rebuiltTextIDs: Set<String> = []
    package var toolNames: [String: String] = [:]
    package var toolActivities: [String: ConversationActivity] = [:]
    package var activityStartedAtUptime: [String: UInt64] = [:]
    package var activityDurations: [String: Int] = [:]
    /// Subagent sessions this turn started, with the activity that stands for each.
    package var children: [String: String] = [:]
    package var steers: [String: (text: String, images: [String])] = [:]
    package var usage = ConversationTokenUsage()
    package var stepError: (type: String, message: String)?
    package var pendingQuestion: PendingQuestion?
    package var pendingUserInputRequest: ConversationUserInputRequest?
    package var callbacks: ConversationTurnCallbacks

    package init(
        sessionID: String, connection: OpenCodeServerConnection, owner: OpenCodeClient?, mode: ConversationMode,
        readOnly: Bool, callbacks: ConversationTurnCallbacks, turnID: String = UUID().uuidString.lowercased()
    ) {
        self.sessionID = sessionID
        self.connection = connection
        self.owner = owner
        self.mode = mode
        self.readOnly = readOnly
        self.callbacks = callbacks
        self.turnID = turnID
    }

    package var canInterrupt: Bool { !finished }

    package func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["provider"] = ConversationProvider.opencode.rawValue
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["opencodePID"] = String(connection.processIdentifier)
        fields["activeThreadID"] = sessionID
        fields["activeTurnID"] = finished ? "" : turnID
        fields["isTurnActive"] = String(!finished)
        return fields
    }

    // MARK: - Running

    package func listen() async throws {
        subscription = try await connection.subscribe { [weak self] event in self?.handle(event) }
    }

    /// Sends the prompt and waits for OpenCode to finish the execution it starts.
    package func run(text: String, imageDataURLs: [String], cwd: String) async throws {
        try await listen()
        let sent = try await connection.data("POST", "api/session/\(sessionID)/prompt", body: OpenCodeLaunch.promptBody(text: text, imageDataURLs: imageDataURLs))
        guard let messageID = sent["id"] as? String else { throw ClientError.protocolFailure("OpenCode accepted the prompt without an ID.") }
        promptMessageID = messageID
        callbacks.onTurnStarted(turnID)
        connection.recordTurn(sessionID, .init(
            promptMessageID: messageID, mode: mode.rawValue, readOnly: readOnly, cwd: cwd, startedAt: Date()
        ))
        try await waitForCompletion()
    }

    package func waitForCompletion() async throws {
        if let result {
            if case .failure(let error) = result { throw error }
            return
        }
        try await withCheckedThrowingContinuation { continuation in waiter = continuation }
    }

    package func finish(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        finished = true
        self.result = result
        if let subscription { connection.unsubscribe(subscription) }
        subscription = nil
        connection.recordTurn(sessionID, nil)
        pendingQuestion = nil
        pendingUserInputRequest = nil
        owner?.turnStateChanged()
        guard let waiter else { return }
        self.waiter = nil
        switch result {
        case .success: waiter.resume()
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    // MARK: - Control

    package func interrupt() async throws -> Bool {
        guard !finished else { return false }
        wasInterrupted = true
        do {
            try await connection.request("POST", "api/session/\(sessionID)/interrupt")
            return true
        } catch {
            wasInterrupted = false
            throw error
        }
    }

    /// Adds input to the running execution through the session's inbox, which OpenCode delivers
    /// at the agent's next step without cancelling the work in flight.
    package func steer(text: String, imageDataURLs: [String]) async throws -> Bool {
        guard !finished, started else { return false }
        // What OpenCode wrote before this input is recorded above it.
        recordHeldAnswer()
        var body = OpenCodeLaunch.promptBody(text: text, imageDataURLs: imageDataURLs)
        body["delivery"] = "steer"
        body["resume"] = false
        let sent = try await connection.data("POST", "api/session/\(sessionID)/prompt", body: body)
        if let id = sent["id"] as? String { steers[id] = (text, imageDataURLs) }
        PlayhouseDiagnostics.record("opencode.turn.steered", fields: diagnosticFields(["imageCount": String(imageDataURLs.count)]))
        return true
    }

    /// A steer OpenCode had not delivered when its execution ended is sent again to start the
    /// execution that answers it, still within this turn.
    package func resendUndeliveredSteers() async -> Bool {
        guard !steers.isEmpty else { return false }
        let pending = steers
        steers.removeAll()
        var resent = false
        for (inboxID, steer) in pending {
            _ = try? await connection.request("DELETE", "api/session/\(sessionID)/inbox/\(inboxID)")
            guard let sent = try? await connection.data(
                "POST", "api/session/\(sessionID)/prompt", body: OpenCodeLaunch.promptBody(text: steer.text, imageDataURLs: steer.images)
            ), let id = sent["id"] as? String else { continue }
            if !resent {
                promptMessageID = id
                started = false
                if var turn = connection.manifest.turns[sessionID] {
                    turn.promptMessageID = id
                    connection.recordTurn(sessionID, turn)
                }
            }
            resent = true
        }
        return resent
    }

    package func answerUserInput(requestID: String, answers: [String: [String]]) -> Bool {
        guard let pending = pendingQuestion, pending.requestKey == requestID else { return false }
        guard Set(answers.keys) == Set(pending.fields.map(\.questionID)),
              answers.values.allSatisfy({ values in values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }) else {
            PlayhouseDiagnostics.record("opencode.user_input.answer.failed", fields: [
                "requestID": requestID, "threadID": sessionID, "reason": "invalid_answer_shape",
            ])
            return false
        }
        var answer: [String: Any] = [:]
        for field in pending.fields { answer[field.key] = (answers[field.questionID] ?? []).joined(separator: ", ") }
        clearPendingQuestion()
        let connection = connection
        Task { _ = try? await connection.request("POST", "api/session/\(pending.sessionID)/form/\(pending.formID)/reply", body: ["answer": answer]) }
        PlayhouseDiagnostics.record("opencode.user_input.answer.succeeded", fields: [
            "requestID": requestID, "threadID": sessionID, "questionCount": String(answers.count),
        ])
        return true
    }

    package func rejectUserInput(requestID: String, message: String) {
        guard let pending = pendingQuestion, pending.requestKey == requestID else { return }
        clearPendingQuestion()
        let connection = connection
        let sessionID = sessionID
        Task {
            _ = try? await connection.request("DELETE", "api/session/\(pending.sessionID)/form/\(pending.formID)")
            _ = try? await connection.request("POST", "api/session/\(sessionID)/interrupt")
        }
        finish(.failure(ClientError.turnFailed(message)))
    }

    package func clearPendingQuestion() {
        pendingQuestion = nil
        pendingUserInputRequest = nil
        owner?.turnStateChanged()
    }

    // MARK: - Events

    package func ownsSession(_ id: String?) -> Bool {
        guard let id else { return false }
        return id == sessionID || children[id] != nil
    }

    package func handle(_ envelope: [String: Any]) {
        guard !finished else { return }
        let type = envelope["type"] as? String ?? ""
        let data = envelope["data"] as? [String: Any] ?? [:]
        switch type {
        case "playhouse.server.exited":
            finish(.failure(ClientError.processExited("The OpenCode server stopped during the turn.")))
            return
        case "playhouse.stream.reconnected":
            Task { await self.resync() }
            return
        case "session.created":
            noteChildCreated(data)
            return
        case "permission.asked":
            if ownsSession(data["sessionID"] as? String) { answerPermission(data) }
            return
        case "form.created":
            if let form = data["form"] as? [String: Any], ownsSession(form["sessionID"] as? String) { presentQuestions(form) }
            return
        case "form.replied", "form.cancelled":
            if let pending = pendingQuestion, pending.formID == data["id"] as? String { clearPendingQuestion() }
            return
        default:
            break
        }
        let eventSession = data["sessionID"] as? String
        if let eventSession, eventSession != sessionID, children[eventSession] != nil {
            handleChildEvent(type, data, child: eventSession)
            return
        }
        guard eventSession == sessionID else { return }
        if type == "session.inbox.delivered", let inboxID = data["inboxID"] as? String {
            if inboxID == promptMessageID || (promptMessageID == nil && !started) {
                started = true
            } else {
                // A delivered steer was shown when Playhouse sent it.
                steers.removeValue(forKey: inboxID)
            }
            return
        }
        guard started else { return }
        handleRootEvent(type, data)
    }

    package func handleRootEvent(_ type: String, _ data: [String: Any]) {
        switch type {
        case "session.text.delta":
            guard let messageID = data["assistantMessageID"] as? String, let delta = data["delta"] as? String else { return }
            let key = "\(messageID):\(data["ordinal"] as? Int ?? 0)"
            guard !rebuiltTextIDs.contains(key) else { return }
            appendText(key: key, delta)
            callbacks.onDelta(delta)
        case "session.text.ended":
            guard let messageID = data["assistantMessageID"] as? String, let text = data["text"] as? String else { return }
            let key = "\(messageID):\(data["ordinal"] as? Int ?? 0)"
            if let pending = pendingAssistantText, pending.id == key {
                pendingAssistantText = (key, text, pending.recorded)
            } else if !rebuiltTextIDs.contains(key) {
                closePendingAssistantText()
                pendingAssistantText = (key, text, recordedTextIDs.contains(key))
            }
        case "session.tool.input.started", "session.tool.called", "session.tool.progress", "session.tool.success", "session.tool.failed":
            handleTool(type, data)
        case "session.step.ended":
            if let tokens = data["tokens"] as? [String: Any] { addUsage(tokens) }
            owner?.requestLogStepEnded(sessionID, connection: connection)
        case "session.step.failed":
            if let tokens = data["tokens"] as? [String: Any] { addUsage(tokens) }
            if let error = data["error"] as? [String: Any] {
                stepError = (error["type"] as? String ?? "", error["message"] as? String ?? "OpenCode's model request failed.")
            }
        case "session.execution.succeeded":
            Task { await self.executionEnded(.succeeded) }
        case "session.execution.interrupted":
            Task { await self.executionEnded(.interrupted) }
        case "session.execution.failed":
            let error = data["error"] as? [String: Any]
            let failure = error.map { ($0["type"] as? String ?? "", $0["message"] as? String ?? "") }
            Task { await self.executionEnded(.failed(failure ?? self.stepError ?? ("", ""))) }
        default:
            break
        }
    }

    package enum ExecutionEnd {
        case succeeded
        case interrupted
        case failed((type: String, message: String))
    }

    package func executionEnded(_ end: ExecutionEnd) async {
        guard !finished else { return }
        switch end {
        case .succeeded:
            if await resendUndeliveredSteers() { return }
            if let stepError, stepError.type != "aborted" {
                fail(stepError)
                return
            }
            complete()
        case .interrupted:
            wasInterrupted = true
            discardUndeliveredSteers()
            reportUsage()
            settleActivities(status: "interrupted")
            finish(.failure(ClientError.turnFailed("The OpenCode turn was interrupted.")))
        case .failed(let error):
            if wasInterrupted || error.type == "aborted" {
                await executionEnded(.interrupted)
            } else {
                fail(error)
            }
        }
    }

    package func discardUndeliveredSteers() {
        let connection = connection
        let sessionID = sessionID
        for inboxID in steers.keys {
            Task { _ = try? await connection.request("DELETE", "api/session/\(sessionID)/inbox/\(inboxID)") }
        }
        steers.removeAll()
    }

    package func fail(_ error: (type: String, message: String)) {
        reportUsage()
        settleActivities(status: "failed")
        let message = error.message.isEmpty ? "OpenCode couldn't finish the turn." : error.message
        if error.type == "provider.auth" {
            finish(.failure(ClientError.authentication(message)))
        } else {
            finish(.failure(OpenCodeClient.classifyFailure(ClientError.turnFailed(message), text: "\(error.type) \(message)")))
        }
    }

    package func complete() {
        if let pending = pendingAssistantText {
            pendingAssistantText = nil
            emitFinal(pending)
        }
        reportUsage()
        settleActivities(status: "completed")
        finish(.success(()))
    }

    package func addUsage(_ tokens: [String: Any]) {
        func value(_ object: [String: Any]?, _ key: String) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        let cache = tokens["cache"] as? [String: Any]
        usage.inputTokens += value(tokens, "input")
        usage.outputTokens += value(tokens, "output") + value(tokens, "reasoning")
        usage.cacheReadTokens += value(cache, "read")
        usage.cacheCreationTokens += value(cache, "write")
    }

    package func reportUsage() {
        guard !usage.isEmpty else { return }
        let labels = toolActivities.values.filter { $0.turnID == turnID }.map(\.tokenUsageLabel)
        callbacks.onTokenUsage(ConversationTurnUsageReport(turnID: turnID, usage: usage, toolLabels: Array(Set(labels)).sorted()))
        usage = ConversationTokenUsage()
    }

    // MARK: - Text

    package func appendText(key: String, _ delta: String) {
        if let pending = pendingAssistantText, pending.id == key {
            pendingAssistantText = (key, pending.text + delta, pending.recorded)
        } else {
            closePendingAssistantText()
            pendingAssistantText = (key, delta, recordedTextIDs.contains(key))
        }
    }

    /// Records the held answer as progress now (a steer follows it), keeping it held so that if
    /// nothing else follows it still becomes the final answer.
    package func recordHeldAnswer() {
        guard let pending = pendingAssistantText, !pending.recorded else { return }
        emitProgress(id: pending.id, text: pending.text)
        pendingAssistantText = (pending.id, pending.text, true)
    }

    package func emitFinal(_ pending: (id: String, text: String, recorded: Bool)) {
        let text = pending.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if pending.recorded, let recordedFinal = callbacks.onRecordedFinalMessage {
            recordedFinal(text, pending.id)
        } else if !pending.recorded {
            callbacks.onFinalMessage(text)
        }
    }

    /// Closes the held answer as commentary: the turn went on to other work after it.
    package func closePendingAssistantText() {
        if let pending = pendingAssistantText, !pending.recorded,
           !pending.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emitProgress(id: pending.id, text: pending.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        pendingAssistantText = nil
    }

    package func emitProgress(id: String, text: String) {
        recordedTextIDs.insert(id)
        connection.noteRecordedText(sessionID, id)
        callbacks.onProgressMessage(ConversationMessage(
            id: id, role: .assistant, text: text, phase: "commentary", turnID: turnID, provider: .opencode
        ))
    }

    // MARK: - Tools

    package func handleTool(_ type: String, _ data: [String: Any]) {
        guard let callID = data["id"] as? String else { return }
        if let name = data["name"] as? String { toolNames[callID] = name }
        let status: String = switch type {
        case "session.tool.success": "completed"
        case "session.tool.failed": "failed"
        default: "inProgress"
        }
        let input = data["input"] as? [String: Any]
        var output = Self.outputText(data["content"])
        if type == "session.tool.failed" { output = (data["error"] as? [String: Any])?["message"] as? String ?? output }
        record(callID: callID, name: toolNames[callID] ?? "", input: input, status: status, output: output)
    }

    package func record(callID: String, name: String, input: [String: Any]?, status: String, output: String?) {
        let existing = toolActivities[callID]
        var activity = Self.activity(id: callID, name: name, input: input ?? [:], status: status, output: output, existing: existing, turnID: turnID)
        if existing == nil {
            if !(activity.input.map { TaskProgressReportInstructions.reportCommand(in: $0) != nil } ?? false) {
                closePendingAssistantText()
            }
            activityStartedAtUptime[callID] = DispatchTime.now().uptimeNanoseconds
        }
        if let child = children.first(where: { $0.value == callID })?.key { activity.childThreadID = child }
        if !activity.isActive, let started = activityStartedAtUptime.removeValue(forKey: callID) {
            let duration = max(1, Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000))
            activity.durationMs = duration
            activityDurations[activity.id] = duration
        }
        toolActivities[callID] = activity
        callbacks.onActivity(activity)
    }

    /// A subagent's session is a child of this turn's session; the newest running subagent row
    /// without one stands for it, and opens its history.
    package func noteChildCreated(_ data: [String: Any]) {
        guard let childID = data["sessionID"] as? String, let parentID = data["parentID"] as? String,
              ownsSession(parentID), children[childID] == nil else { return }
        let row = toolActivities.values
            .filter { $0.isSubagent && $0.isActive && !children.values.contains($0.id) }
            .max { (activityStartedAtUptime[$0.id] ?? 0) < (activityStartedAtUptime[$1.id] ?? 0) }
        children[childID] = row?.id ?? childID
        if var activity = row {
            activity.childThreadID = childID
            toolActivities[activity.id] = activity
            callbacks.onActivity(activity)
        }
    }

    package func handleChildEvent(_ type: String, _ data: [String: Any], child: String) {
        guard type == "session.tool.called", let name = data["name"] as? String,
              let rowID = children[child], var activity = toolActivities[rowID] else { return }
        activity.detail = [activity.agentPath, "Using \(name)"].compactMap { $0 }.joined(separator: "\n")
        toolActivities[rowID] = activity
        callbacks.onActivity(activity)
    }

    /// A finished turn has no running tools left to observe.
    package func settleActivities(status: String) {
        for (id, activity) in toolActivities where activity.isActive {
            let settled = ConversationActivity(
                id: activity.id, title: activity.title, detail: activity.detail, status: status,
                childThreadID: activity.childThreadID, agentPath: activity.agentPath, model: activity.model,
                toolKind: activity.toolKind, server: activity.server, tool: activity.tool, turnID: activity.turnID
            ).preservingTimelineFields(of: activity)
            toolActivities[id] = settled
            callbacks.onActivity(settled)
        }
    }

    // MARK: - Permissions and questions

    /// Code mode runs without approval prompts, as with the other providers; OpenCode has already
    /// applied the user's own rules before asking. A read-only side chat may only read and run
    /// the Playhouse CLI's board commands (`SideChatReadOnlyPolicy`).
    package func answerPermission(_ data: [String: Any]) {
        guard let requestID = data["id"] as? String, let session = data["sessionID"] as? String else { return }
        let allowed = !readOnly || Self.readOnlyAllows(action: data["action"] as? String ?? "", resources: data["resources"] as? [String] ?? [])
        if !allowed {
            PlayhouseDiagnostics.record("opencode.permission.denied_read_only", fields: diagnosticFields(["action": data["action"] as? String ?? ""]))
        }
        let connection = connection
        Task {
            _ = try? await connection.request("POST", "api/session/\(session)/permission/\(requestID)/reply", body: [
                "decision": allowed ? "once" : "reject",
            ])
        }
    }

    package static func readOnlyAllows(action: String, resources: [String]) -> Bool {
        switch action {
        case "edit", "write", "patch", "delete", "move":
            return false
        case "shell", "bash":
            return resources.allSatisfy { command in
                SideChatReadOnlyPolicy.allows(
                    toolName: "Bash", input: ["command": command],
                    cliPaths: [TaskThreadDeveloperInstructions.cliExecutableURL().path]
                )
            }
        default:
            return true
        }
    }

    /// OpenCode's `question` tool asks through a form with one field per question (`q0`, `q1`…),
    /// whose options are the choices; a field marked `custom` also takes the user's own answer.
    package func presentQuestions(_ form: [String: Any]) {
        guard let formID = form["id"] as? String, let session = form["sessionID"] as? String else { return }
        let fieldList = form["fields"] as? [[String: Any]] ?? []
        var fields: [(questionID: String, key: String)] = []
        var questions: [ConversationUserQuestion] = []
        for (index, field) in fieldList.enumerated() {
            guard let key = field["key"] as? String else { continue }
            let options = (field["options"] as? [[String: Any]] ?? []).compactMap { option -> ConversationUserQuestion.Option? in
                guard let value = option["value"] as? String ?? option["label"] as? String else { return nil }
                return .init(label: value, description: option["description"] as? String)
            }
            let questionID = "question-\(index + 1)"
            questions.append(ConversationUserQuestion(
                id: questionID, header: field["title"] as? String ?? "Question",
                question: field["description"] as? String ?? field["title"] as? String ?? form["title"] as? String ?? "",
                options: options, allowsOther: field["custom"] as? Bool ?? options.isEmpty, isSecret: false
            ))
            fields.append((questionID, key))
        }
        guard !questions.isEmpty else {
            let connection = connection
            Task { _ = try? await connection.request("DELETE", "api/session/\(session)/form/\(formID)") }
            return
        }
        closePendingAssistantText()
        let key = "form-\(formID)"
        pendingQuestion = PendingQuestion(requestKey: key, formID: formID, sessionID: session, fields: fields)
        let request = ConversationUserInputRequest(id: key, threadID: sessionID, questions: questions, isBlocking: true, mode: mode)
        pendingUserInputRequest = request
        owner?.turnStateChanged()
        let handler = callbacks.onUserInput
        Task { @MainActor in await handler(request) }
    }

    // MARK: - Rebuilding

    /// Rebuilds the turn from the session's messages after its prompt, when this daemon didn't
    /// see its events (a restart, or a stream that dropped): text already recorded is not
    /// recorded again. Returns whether the session still runs.
    @discardableResult
    package func rebuild(recorded: [String]) async throws -> Bool {
        recordedTextIDs.formUnion(recorded)
        let list = try await connection.messages(sessionID)
        var afterPrompt = promptMessageID == nil
        var ended: String?
        for message in list {
            if message["id"] as? String == promptMessageID { afterPrompt = true; started = true; continue }
            guard afterPrompt else { continue }
            switch message["type"] as? String {
            case "assistant":
                let messageID = message["id"] as? String ?? UUID().uuidString
                var ordinal = 0
                for part in message["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "text":
                        let key = "\(messageID):\(ordinal)"
                        ordinal += 1
                        guard let text = part["text"] as? String else { continue }
                        if pendingAssistantText?.id != key { closePendingAssistantText() }
                        pendingAssistantText = (key, text, recordedTextIDs.contains(key))
                        rebuiltTextIDs.insert(key)
                    case "tool":
                        guard let callID = part["id"] as? String else { continue }
                        let state = part["state"] as? [String: Any] ?? [:]
                        let status: String = switch state["status"] as? String {
                        case "completed": "completed"
                        case "error": "failed"
                        default: "inProgress"
                        }
                        let output = Self.outputText(state["content"]) ?? state["output"] as? String
                            ?? (state["error"] as? [String: Any])?["message"] as? String
                        if let name = part["name"] as? String { toolNames[callID] = name }
                        record(callID: callID, name: toolNames[callID] ?? "", input: state["input"] as? [String: Any], status: status, output: output)
                    default:
                        break
                    }
                }
                if let tokens = message["tokens"] as? [String: Any] { addUsage(tokens) }
            case "idle":
                ended = message["outcome"] as? String ?? "succeeded"
            default:
                break
            }
        }
        if let ended {
            await executionEnded(ended == "interrupted" ? .interrupted : ended == "failed" ? .failed(stepError ?? ("", "")) : .succeeded)
            return false
        }
        let active = (try? await connection.request("GET", "api/session/active") as? [String: Any])?["data"] as? [String: Any] ?? [:]
        guard active[sessionID] != nil else {
            await executionEnded(.succeeded)
            return false
        }
        started = true
        for form in (try? await connection.request("GET", "api/session/\(sessionID)/form") as? [String: Any])?["data"] as? [[String: Any]] ?? [] {
            presentQuestions(form)
        }
        for permission in (try? await connection.request("GET", "api/session/\(sessionID)/permission") as? [String: Any])?["data"] as? [[String: Any]] ?? [] {
            answerPermission(permission)
        }
        return true
    }

    /// The event stream reopened: whatever this turn missed meanwhile comes from its messages.
    package func resync() async {
        guard !finished else { return }
        let recorded = Array(recordedTextIDs)
        pendingAssistantText = pendingAssistantText.map { ($0.id, $0.text, recordedTextIDs.contains($0.id)) }
        _ = try? await rebuild(recorded: recorded)
    }

    // MARK: - Mapping

    /// One timeline activity for an OpenCode tool call, merged with what an earlier event reported.
    package static func activity(
        id: String, name: String, input: [String: Any], status: String, output: String?,
        existing: ConversationActivity?, turnID: String?
    ) -> ConversationActivity {
        let name = name.isEmpty ? existing?.tool ?? "" : name
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let path = string("path") ?? string("filePath") ?? string("file")
        var activity: ConversationActivity
        switch kind(forTool: name) {
        case "execute":
            let command = string("command") ?? ""
            activity = ConversationActivity(
                id: id, title: command.isEmpty ? "Running command" : "Running \(command)", detail: string("description") ?? "",
                status: status, tool: name, turnID: turnID
            )
            activity.input = command.isEmpty ? existing?.input : String(command.prefix(ConversationActivity.timelineInputLimit))
            activity.summary = string("description")
        case "edit":
            activity = ConversationActivity(id: id, title: "Editing 1 file", detail: path ?? "", status: status, tool: name, turnID: turnID)
            activity.summary = path
        case "read":
            activity = ConversationActivity(
                id: id, title: "Reading \(path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file")",
                detail: path ?? "", status: status, tool: name, turnID: turnID
            )
            activity.summary = path
        case "search":
            let pattern = string("pattern") ?? string("query") ?? ""
            activity = ConversationActivity(
                id: id, title: name == "websearch" ? "Searching the web" : "Searching files", detail: pattern,
                status: status, tool: name, turnID: turnID
            )
            activity.summary = [string("pattern") ?? string("query"), string("path")].compactMap { $0 }.joined(separator: " in ")
        case "fetch":
            activity = ConversationActivity(id: id, title: "Fetching a web page", detail: string("url") ?? "", status: status, tool: name, turnID: turnID)
            activity.summary = string("url")
        case "subagent":
            let agent = string("agent") ?? string("subagent_type") ?? existing?.agentPath ?? "general"
            activity = ConversationActivity(
                id: id, title: agent.prefix(1).uppercased() + agent.dropFirst(),
                detail: [agent, string("description")].compactMap { $0 }.joined(separator: "\n"),
                status: status, childThreadID: existing?.childThreadID ?? id, agentPath: agent, model: string("model"), turnID: turnID
            )
        default:
            if let separator = name.firstIndex(of: "_"), !builtInTools.contains(name) {
                // MCP tools are named `<server>_<tool>`; their arguments stay private.
                let server = String(name[..<separator])
                let tool = String(name[name.index(after: separator)...])
                activity = ConversationActivity(
                    id: id, title: "MCP · \(tool)", detail: "Server · \(server)", status: status,
                    toolKind: "mcp", server: server, tool: tool, turnID: turnID
                )
            } else {
                activity = ConversationActivity(
                    id: id, title: "Tool · \(name.isEmpty ? "tool" : name)", detail: "",
                    status: status, toolKind: "dynamic", tool: name, turnID: turnID
                )
            }
        }
        // A later event can leave out the call's input; what an earlier one described stands.
        if input.isEmpty, let existing {
            let kept = activity
            activity = ConversationActivity(
                id: kept.id, title: existing.title, detail: kept.detail.isEmpty ? existing.detail : kept.detail,
                status: kept.status, childThreadID: existing.childThreadID, agentPath: existing.agentPath,
                model: existing.model, toolKind: existing.toolKind, server: existing.server, tool: existing.tool,
                turnID: kept.turnID, summary: existing.summary
            )
            activity.input = existing.input
        }
        if let output, !output.isEmpty {
            if activity.toolKind != "mcp", !activity.isSubagent {
                activity.detail = [activity.detail, String(output.suffix(2_000))].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            if activity.isTimelineToolCall, activity.input != nil { activity.output = String(output.suffix(2_000)) }
        }
        return existing.map { activity.preservingTimelineFields(of: $0) } ?? activity
    }

    package static func kind(forTool name: String) -> String {
        switch name {
        case "write", "edit", "patch", "multiedit", "apply_patch": "edit"
        case "shell", "bash": "execute"
        case "read": "read"
        case "grep", "glob", "list", "websearch": "search"
        case "webfetch": "fetch"
        case "subagent", "task": "subagent"
        default: "other"
        }
    }

    package static let builtInTools: Set<String> = [
        "generate_image", "generate_video", "opencode_list_mcp_resources", "opencode_read_mcp_resource",
    ]

    package static func outputText(_ content: Any?) -> String? {
        let blocks = content as? [[String: Any]] ?? []
        let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}
