import Foundation

extension CodexAppServerClient {
    package func makeAuxiliaryClient() -> ConversationProviderClient {
        CodexAppServerClient(codexExecutableOverride: codexExecutableOverrideSetting)
    }

    package func isProviderUnavailable(_ error: Error) -> Bool {
        switch error as? ClientError {
        case .cliNotFound, .processStart, .authentication: true
        default: false
        }
    }

    package func applySkillBridge(_ workspace: ConversationWorkspaceContext) async throws {
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

    package func ensureInitialized(workspace: ConversationWorkspaceContext) async throws {
        if initialized, transportIsRunning { return }
        if let initializationTask { return try await initializationTask.value }
        let initialization = Task { @MainActor in try await self.initializeProcess(workspace: workspace) }
        initializationTask = initialization
        defer { initializationTask = nil }
        try await initialization.value
    }

    package func initializeProcess(workspace: ConversationWorkspaceContext) async throws {

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

    package func launchProcess(workspaceURL: URL) throws {
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

    package func resumeThreadIfNeeded(
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

    /// A thread's messages and activities. Consecutive agent messages of one turn are joined
    /// into one entry for display unless `joinsAgentMessages` is false, as a backfill needs
    /// each message on its own to tell which ones a turn already streamed.
    package func readMessages(threadID: String, joinsAgentMessages: Bool = true) async throws -> ConversationHistory {
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
                if joinsAgentMessages,
                   message.role == .assistant,
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
    package func request(method: String, params: [String: Any], timeout: Duration? = nil) async throws -> [String: Any] {
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

    package func sendNotification(method: String) throws {
        try sendJSON(["jsonrpc": "2.0", "method": method])
    }

    package func sendJSON(_ object: [String: Any]) throws {
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

    package func consumeOutput(_ data: Data, from source: AnyObject?) async {
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.range(of: newline) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            await consume(line: line, from: source)
        }
    }

    package func consume(line: Data, from source: AnyObject?) async {
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

    package static func diagnosticNotificationFields(method: String, params: [String: Any]) -> [String: String] {
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

    package static let highVolumeDeltaMethods: Set<String> = [
        "item/agentMessage/delta", "item/plan/delta", "item/commandExecution/outputDelta"
    ]

    package func recordDeltaLogSummary(method: String, params: [String: Any]) {
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
    package func reportCallUsage(_ params: [String: Any]) {
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

    package func flushDeltaLogSummary(for key: String, reason: String) {
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

    package func flushDeltaLogSummaries(threadID: String, turnID: String, reason: String) {
        let keys = deltaLogSummaries.compactMap { key, entry in
            entry.threadID == threadID && (entry.turnID == turnID || entry.turnID.isEmpty) ? key : nil
        }
        for key in keys { flushDeltaLogSummary(for: key, reason: reason) }
    }
}
