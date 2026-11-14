import Combine
import Darwin
import Foundation

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
