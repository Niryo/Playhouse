import Foundation

@MainActor
package final class ClaudeAgentRun {
    package let directory: URL
    package private(set) var manifest: ClaudeRunManifest
    package var identity: AgentProcessIdentity? { manifest.process }
    private let input: AgentInputWriter
    private var writesInFlight = 0
    /// Why the agent's input failed; the agent is stopped then, and its exit reports this.
    package private(set) var inputFailure: AgentInputWriter.WriteError?
    private var tailer: LineTailer
    private var reader: Int32 = -1
    private var outputSource: FileWriteWatch?
    private var pollTask: Task<Void, Never>?
    private var exitSource: ProcessExitWatch?
    private var answeredSinceCommit: [String] = []
    private var pendingSinceCommit: [String] = []
    package private(set) var hasExited = false

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
    package static func start(
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
    package static func attach(directory: URL) -> ClaudeAgentRun? {
        guard let manifest = AgentManifestFile.read(ClaudeRunManifest.self, from: ClaudeRunFiles.manifestURL(directory)) else { return nil }
        return ClaudeAgentRun(directory: directory, manifest: manifest)
    }

    package var isRunning: Bool { !hasExited && identity?.isAlive == true }

    /// Writes one JSON line to the agent's input and returns once it is written, without
    /// holding the main actor while the agent reads it.
    package func write(_ line: Data) async throws {
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
    package func send(_ line: Data) throws {
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
    package func handledLines() -> [Data] {
        guard let data = FileManager.default.contents(atPath: ClaudeRunFiles.outputPath(directory)) else { return [] }
        let prefix = data.prefix(Int(manifest.consumedOffset))
        return prefix.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast(prefix.last == 0x0A ? 1 : 0).map { Data($0) }
    }

    /// Follows the log from the committed offset: `onLines` gets each batch of complete lines,
    /// and `onExit` runs once after the process exits and the log is read to its end.
    package func follow(onLines: @escaping @MainActor ([Data], UInt64) async -> Void, onExit: @escaping @MainActor (Int32?) async -> Void) {
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
        outputSource = FileWriteWatch(descriptor: reader, queue: .global()) { pump.push(.output(Data())) }
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

    package func noteAnswered(_ requestID: String) { answeredSinceCommit.append(requestID) }
    package func notePending(_ requestID: String) { pendingSinceCommit.append(requestID) }

    /// Records that everything before `offset` was handled, with the answers written for it.
    package func commit(offset: UInt64) {
        manifest.commit(answered: answeredSinceCommit, pending: pendingSinceCommit, offset: offset)
        answeredSinceCommit.removeAll()
        pendingSinceCommit.removeAll()
        try? saveManifest()
    }

    /// An answer written outside the log's handling (a user's answer to a question).
    package func commitAnswer(_ requestID: String) {
        manifest.commit(answered: [requestID], offset: manifest.consumedOffset)
        try? saveManifest()
    }

    package func recordRequestID(_ number: Int) {
        guard number > manifest.maxRequestID else { return }
        manifest.maxRequestID = number
        try? saveManifest()
    }

    package var stderrTail: String {
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
    package func terminateAndRemove() async {
        stopFollowing()
        exitSource?.cancel()
        exitSource = nil
        input.close()
        if let identity { await AgentRunHost.terminate(identity) }
        if reader >= 0 { close(reader); reader = -1 }
        try? FileManager.default.removeItem(at: directory)
    }
}
package enum ClaudeSessionUsageReader {
    package static func read(sessionID: String, configDirectory: String) -> ConversationCallUsageSnapshot? {
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
    package static func subagentFiles(mainFile: URL) -> [(agentID: String, file: URL)] {
        let subagentDirectory = mainFile.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: subagentDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .map { (String($0.deletingPathExtension().lastPathComponent.dropFirst("agent-".count)), $0) }
            .sorted { $0.agentID < $1.agentID }
    }

    /// The working folder Claude Code recorded for a session, from the first line
    /// carrying a `cwd`; nil when the session or folder is gone.
    package static func recordedWorkingDirectory(sessionID: String, configDirectory: String) -> URL? {
        guard let file = sessionFile(sessionID: sessionID, configDirectory: configDirectory),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String else { continue }
            return WorkspaceSettings.validDirectoryURL(for: cwd)
        }
        return nil
    }

    package static func sessionFile(sessionID: String, configDirectory: String) -> URL? {
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

/// Reads a Claude Code subagent's own work from its sidechain file.
///
/// Claude Code streams only a subagent's launch, progress and final report to
/// its parent; the subagent's prompt, text and tool calls are written to
/// `<session>/subagents/agent-<id>.jsonl`, and its `agent-<id>.meta.json`
/// names the parent's tool-use ID (the activity's `childThreadID`). The file
/// grows while the agent works, so reading it again shows its latest work.
package enum ClaudeSubagentTranscriptReader {
    /// The sidechain file of the agent the given tool use launched: the given
    /// sessions' agents first, then the other sessions of the same folders,
    /// which hold agents of earlier pages or replaced sessions.
    package nonisolated static func agentFile(toolUseID: String, sessionIDs: [String], configDirectory: String) -> URL? {
        let mainFiles = sessionIDs.compactMap { ClaudeSessionUsageReader.sessionFile(sessionID: $0, configDirectory: configDirectory) }
        if let file = agentFile(toolUseID: toolUseID, mainFiles: mainFiles) { return file }
        var projects: [URL] = []
        for project in mainFiles.map({ $0.deletingLastPathComponent() }) where !projects.contains(project) { projects.append(project) }
        let siblings = projects.flatMap { project in
            ((try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" && !mainFiles.contains($0) }
        }
        return agentFile(toolUseID: toolUseID, mainFiles: siblings)
    }

    nonisolated private static func agentFile(toolUseID: String, mainFiles: [URL]) -> URL? {
        for main in mainFiles {
            for subagent in ClaudeSessionUsageReader.subagentFiles(mainFile: main) {
                let meta = subagent.file.deletingPathExtension().appendingPathExtension("meta.json")
                guard let data = try? Data(contentsOf: meta),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["toolUseId"] as? String == toolUseID else { continue }
                return subagent.file
            }
        }
        return nil
    }

    /// What a sidechain file holds, parsed off the main actor; the file grows
    /// without bound while the agent works and is read again on every refresh.
    package struct Sidechain: Sendable {
        package struct Message: Sendable { let id: String; let isUser: Bool; let text: String; let createdAt: Date?; let modelID: String? }
        package struct Call: Sendable { let id: String; let name: String; let input: Data; let afterMessageID: String?; var status = "inProgress"; var output = "" }
        package var messages: [Message] = []
        package var calls: [Call] = []

        package init(messages: [Message] = [], calls: [Call] = []) {
            self.messages = messages
            self.calls = calls
        }
    }

    package nonisolated static func parse(_ data: Data) -> Sidechain {
        var sidechain = Sidechain()
        var callIndexes: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = object["message"] as? [String: Any] else { continue }
            let createdAt = (object["timestamp"] as? String).flatMap { timestampFormatter.date(from: $0) }
            let blocks: [[String: Any]] = (message["content"] as? String).map { [["type": "text", "text": $0]] }
                ?? message["content"] as? [[String: Any]] ?? []
            switch object["type"] as? String {
            case "user":
                for block in blocks {
                    if block["type"] as? String == "tool_result" {
                        guard let toolID = block["tool_use_id"] as? String, let index = callIndexes[toolID] else { continue }
                        sidechain.calls[index].status = block["is_error"] as? Bool == true ? "failed" : "completed"
                        sidechain.calls[index].output = ClaudeCodeClient.resultText(block["content"])
                    } else if block["type"] as? String == "text", let text = block["text"] as? String,
                              // Claude Code's own reminders and notices are not the agent's prompt.
                              !text.isEmpty, !text.hasPrefix("<") {
                        let id = "\(object["uuid"] as? String ?? "user")-\(sidechain.messages.count)"
                        sidechain.messages.append(.init(id: id, isUser: true, text: text, createdAt: createdAt, modelID: nil))
                    }
                }
            case "assistant":
                // Claude Code writes a call's blocks on lines of their own that share its ID.
                let lineID = object["uuid"] as? String ?? message["id"] as? String ?? "assistant"
                for (index, block) in blocks.enumerated() {
                    if block["type"] as? String == "text", let text = block["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sidechain.messages.append(.init(
                            id: "\(lineID)-\(index)", isUser: false, text: text, createdAt: createdAt, modelID: message["model"] as? String
                        ))
                    } else if block["type"] as? String == "tool_use", let toolID = block["id"] as? String,
                              let name = block["name"] as? String, callIndexes[toolID] == nil {
                        let input = (try? JSONSerialization.data(withJSONObject: block["input"] as? [String: Any] ?? [:])) ?? Data()
                        callIndexes[toolID] = sidechain.calls.count
                        sidechain.calls.append(.init(id: toolID, name: name, input: input, afterMessageID: sidechain.messages.last?.id))
                    }
                }
            default:
                continue
            }
        }
        return sidechain
    }

    /// The agent's prompt and text as messages, and its tool calls as timeline
    /// rows placed after the message each followed.
    @MainActor
    package static func history(_ sidechain: Sidechain) -> ConversationHistory {
        let messages = sidechain.messages.map { message in
            message.isUser
                ? ConversationMessage(id: message.id, role: .user, text: message.text, provider: .claude, createdAt: message.createdAt)
                : ConversationMessage(
                    id: message.id, role: .assistant, text: message.text, phase: "commentary",
                    provider: .claude, createdAt: message.createdAt, modelID: message.modelID
                )
        }
        let tools = sidechain.calls.map { call in
            let input = (try? JSONSerialization.jsonObject(with: call.input)) as? [String: Any] ?? [:]
            var activity = ClaudeCodeClient.activity(toolID: call.id, name: call.name, input: input, status: call.status, turnID: nil)
            activity.afterMessageID = call.afterMessageID
            if activity.input != nil, !call.output.isEmpty { activity.output = String(call.output.suffix(2_000)) }
            return activity
        }
        return ConversationHistory(messages: messages, activities: tools, timelineActivities: tools.filter(\.isTimelineToolCall), diff: nil)
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
