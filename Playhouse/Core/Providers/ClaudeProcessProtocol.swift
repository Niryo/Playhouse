import Foundation

extension ClaudeSessionRunner {
    package func launch(
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
        let forkSource = resume ? nil : owner?.forkSourceSessionID(for: sessionID)
        if let source = forkSource {
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

        var environment = ClaudeCodeClient.childEnvironment(dataDirectoryOverride: owner?.dataDirectoryOverride ?? nil, configDirectoryOverride: configDirectoryOverride)
        if let effort { environment["CLAUDE_CODE_EFFORT_LEVEL"] = effort.rawValue }

        // Claude Code finds a session to resume under its working folder. A rootless task's
        // folder follows the repository root setting (and was the home folder in earlier
        // builds), so its resumed or forked session keeps the folder Claude Code recorded for it.
        let resumedSessionID = forkSource ?? (resume ? sessionID : nil)
        let workingDirectory = workspace.roots.isEmpty
            ? resumedSessionID.flatMap {
                ClaudeSessionUsageReader.recordedWorkingDirectory(
                    sessionID: $0, configDirectory: ClaudeCodeClient.configDirectory(override: configDirectoryOverride)
                )
            } ?? workspace.cwd
            : workspace.cwd

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
                    environment: environment, workingDirectory: workingDirectory.path
                )
            } catch {
                throw ClientError.processStart(error.localizedDescription)
            }
            agentRun = run
            followAgentRun(run)
            PlayhouseDiagnostics.record("claude.process.started", fields: diagnosticFields([
                "executable": executable,
                "workingDirectory": workingDirectory.path,
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
        child.currentDirectoryURL = workingDirectory
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
            "workingDirectory": workingDirectory.path,
            "processID": String(child.processIdentifier),
            "resume": String(resume),
            "mode": mode.rawValue,
            "environmentNames": environment.keys.sorted().joined(separator: ",")
        ]))
        return try await controlRequest(["subtype": "initialize"])
    }

    package func controlRequest(_ request: [String: Any]) async throws -> [String: Any] {
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

    package func sendControlResponse(requestID: String, response: [String: Any]) throws {
        try queueJSON(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": response]])
        agentRun?.noteAnswered(requestID)
    }

    package func sendControlError(requestID: String, message: String) {
        try? queueJSON(["type": "control_response", "response": ["subtype": "error", "request_id": requestID, "error": message]])
        agentRun?.noteAnswered(requestID)
    }

    package func writeUserMessage(text: String, imageDataURLs: [String], uuid: String, priority: String?) async throws {
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
    package func sendJSON(_ object: [String: Any]) async throws {
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
    package func queueJSON(_ object: [String: Any]) throws {
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

    package static func jsonLine(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    package func writeToProcessPipe(_ object: [String: Any]) throws {
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
}
