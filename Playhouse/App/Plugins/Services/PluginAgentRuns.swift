import Darwin
import Foundation

/// An agent a plugin started with `agent.run` that hasn't finished, saved so
/// a daemon that starts after it was cut off reports it as interrupted.
struct PluginAgentRunRecord: Codable, Equatable, Sendable {
    var runID: String
    var pluginID: String
    /// The plugin's own value, handed back unchanged in `agent.finished`.
    var context: PluginValue
    var startedAt: Date
    var model: String?
    /// The Claude Code process, stopped if it outlives the daemon that started it.
    var process: AgentProcessIdentity?
    /// "claude" or "codex"; nil in a record written before Codex runs.
    var provider: String? = nil
    /// A Codex run's ephemeral thread and turn, interrupted if the turn outlives
    /// the daemon that started it (the shared app-server can).
    var threadID: String? = nil
    var turnID: String? = nil
}

/// The unfinished runs of one store, in `plugin-agent-runs.json` beside it:
/// per-store records of processes, which go with the store and which the next
/// daemon reads back right after an earlier one wrote them. (A path-named
/// defaults suite, an isolated test store's, keeps serving a process the value
/// another process wrote before it, so settings couldn't carry them there.)
@MainActor
struct PluginAgentRunStore {
    let url: URL

    init(storeDirectory: String) {
        url = URL(fileURLWithPath: storeDirectory, isDirectory: true).appendingPathComponent("plugin-agent-runs.json")
    }

    var runs: [PluginAgentRunRecord] {
        get { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PluginAgentRunRecord].self, from: $0) } ?? [] }
        nonmutating set {
            do {
                try JSONEncoder().encode(newValue).write(to: url, options: .atomic)
            } catch {
                PlayhouseDiagnostics.record("plugin.agent.store.failed", fields: PlayhouseDiagnostics.errorFields(error))
            }
        }
    }
}

/// Plugins' background agents (`agent.run`), run in the daemon so closing the
/// plugin's popover doesn't stop them: one non-persisted turn each, a Claude
/// Code `claude -p` (with the plugin's model, allowed tools and JSON schema)
/// or a Codex turn on an ephemeral thread of the shared app-server (with its
/// model and the schema as `outputSchema`, read-only and without approvals).
/// When a run ends, the plugin's background half hears `agent.finished`,
/// targeted at that plugin only.
@MainActor
enum PluginAgentRuns {
    struct Request {
        var pluginID: String
        var prompt: String
        var model: String?
        var allowedTools: [String]
        var jsonSchema: PluginValue?
        var context: PluginValue
        var cwd: URL
    }

    /// A run of this daemon process, by run ID.
    final class Run {
        let record: PluginAgentRunRecord
        /// Ends the run: terminates Claude Code, or interrupts the Codex turn.
        let stop: () -> Void
        var cancelled = false
        var timedOut = false
        init(record: PluginAgentRunRecord, stop: @escaping () -> Void) {
            self.record = record
            self.stop = stop
        }
    }

    private(set) static var active: [String: Run] = [:]
    /// The cut-off runs this daemon has reported, so concurrent recoveries tell each once.
    private static var reported: Set<String> = []

    /// 15 minutes; tests shorten it with `PLAYHOUSE_E2E_PLUGIN_AGENT_TIMEOUT_SECONDS`.
    static var timeout: TimeInterval {
        PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_PLUGIN_AGENT_TIMEOUT_SECONDS"].flatMap(TimeInterval.init) ?? 15 * 60
    }

    /// The largest `context` a run keeps, as JSON.
    static let contextLimit = 16 * 1024

    /// Starts the run and returns its ID at once; `agent.finished` follows.
    static func start(_ request: Request, claude: ClaudeCodeClient, store: PluginAgentRunStore, origin: BridgeRequest) throws -> String {
        guard let executable = claude.executablePath else {
            throw BridgeCommandError(code: "unavailable", message: "Claude Code isn't installed, so a plugin can't run an agent.")
        }
        var arguments = ["-p", "--output-format", "json", "--no-session-persistence"]
        if let model = request.model { arguments += ["--model", model] }
        if let schema = request.jsonSchema { arguments += ["--json-schema", schema.jsonText] }
        if !request.allowedTools.isEmpty { arguments += ["--allowedTools", request.allowedTools.joined(separator: ",")] }
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.currentDirectoryURL = request.cwd
        process.environment = ClaudeCodeClient.childEnvironment(dataDirectoryOverride: claude.dataDirectoryOverride, configDirectoryOverride: claude.configDirectoryOverride)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw BridgeCommandError(code: "unavailable", message: "Playhouse couldn't start Claude Code: \(error.localizedDescription)")
        }
        let record = PluginAgentRunRecord(
            runID: newRunID(), pluginID: request.pluginID, context: request.context, startedAt: Date(),
            model: request.model, process: AgentProcessIdentity.current(pid: process.processIdentifier), provider: ConversationProvider.claude.rawValue
        )
        let prompt = Data(request.prompt.utf8)
        let hasSchema = request.jsonSchema != nil
        return follow(record, request: request, store: store, origin: origin, stop: { process.terminate() }) {
            let (stdout, stderr) = await Task.detached {
                input.fileHandleForWriting.write(prompt)
                try? input.fileHandleForWriting.close()
                async let errorText = errors.fileHandleForReading.readDataToEndOfFile()
                let text = output.fileHandleForReading.readDataToEndOfFile()
                let stderr = await errorText
                process.waitUntilExit()
                return (text, stderr)
            }.value
            return Self.outcome(stdout: stdout, stderr: stderr, exitStatus: process.terminationStatus, structured: hasSchema)
        }
    }

    /// Starts a Codex run on an ephemeral thread and returns its ID once the turn has started.
    static func startCodex(_ request: Request, codex: CodexAppServerClient, store: PluginAgentRunStore, origin: BridgeRequest) async throws -> String {
        guard codex.isInstalled else {
            throw BridgeCommandError(code: "unavailable", message: "Codex isn't installed, so a plugin can't run an agent on it.")
        }
        guard let workspace = try? ConversationWorkspaceContext(roots: [request.cwd]) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The agent's cwd \(request.cwd.path) can't be used.")
        }
        let schema = request.jsonSchema.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.jsonText.utf8))) as? [String: Any] }
        let turn: CodexPlainTurn
        do {
            turn = try await codex.startPlainTurn(prompt: request.prompt, modelID: request.model, outputSchema: schema, workspace: workspace)
        } catch {
            throw BridgeCommandError(code: codex.isProviderUnavailable(error) ? "unavailable" : "operation_failed",
                                     message: "Codex couldn't start the agent: \(error.localizedDescription)")
        }
        let record = PluginAgentRunRecord(
            runID: newRunID(), pluginID: request.pluginID, context: request.context, startedAt: Date(),
            model: request.model, process: nil, provider: ConversationProvider.codex.rawValue, threadID: turn.threadID, turnID: turn.turnID
        )
        // Codex has no per-turn tool list: its runs are read-only, and allowedTools is Claude Code's.
        if !request.allowedTools.isEmpty {
            PlayhouseDiagnostics.record("plugin.agent.allowed_tools_ignored", fields: ["pluginID": request.pluginID, "provider": "codex", "count": String(request.allowedTools.count)])
        }
        let structured = schema != nil
        let stop = { [weak codex] in
            Task { @MainActor in
                await codex?.interruptPlainTurn(turn)
                // Ends even if Codex never reports the interrupted turn.
                turn.finish(status: "interrupted", error: nil)
                if codex?.plainTurns.removeValue(forKey: turn.threadID) != nil { codex?.releaseEphemeralThread(turn.threadID) }
            }
            return
        }
        return follow(record, request: request, store: store, origin: origin, stop: stop) {
            Self.outcome(codex: await turn.result(), structured: structured)
        }
    }

    /// Starts an OpenCode run in a session of its own, read-only like a Codex run, and returns
    /// its ID once OpenCode accepted the prompt. OpenCode's server has no structured output, so a
    /// run with a JSON schema asks for it in the prompt (`PluginJSONSchema`) and checks the
    /// answer; one that doesn't match is asked once more in the same session, and the session
    /// is removed when the run ends.
    static func startOpenCode(_ request: Request, opencode: OpenCodeClient, store: PluginAgentRunStore, origin: BridgeRequest) async throws -> String {
        guard opencode.isInstalled else {
            throw BridgeCommandError(code: "unavailable", message: "OpenCode isn't installed, so a plugin can't run an agent on it.")
        }
        guard var workspace = try? ConversationWorkspaceContext(roots: [request.cwd]) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The agent's cwd \(request.cwd.path) can't be used.")
        }
        workspace.isReadOnly = true
        let client = opencode.makePluginAgentClient()
        let sessionID: String
        do {
            sessionID = try await client.startThread(workspace: workspace, modelID: request.model ?? OpenCodeClient.defaultModelID, developerInstructions: nil)
        } catch {
            throw BridgeCommandError(code: client.isProviderUnavailable(error) ? "unavailable" : "operation_failed",
                                     message: "OpenCode couldn't start the agent: \(error.localizedDescription)")
        }
        let record = PluginAgentRunRecord(
            runID: newRunID(), pluginID: request.pluginID, context: request.context, startedAt: Date(),
            model: request.model, process: nil, provider: ConversationProvider.opencode.rawValue, threadID: sessionID, turnID: nil
        )
        if !request.allowedTools.isEmpty {
            PlayhouseDiagnostics.record("plugin.agent.allowed_tools_ignored", fields: ["pluginID": request.pluginID, "provider": "opencode", "count": String(request.allowedTools.count)])
        }
        let schema = request.jsonSchema
        func send(_ text: String) async throws -> String {
            var answer = ""
            try await client.sendMessage(
                text, mode: .code, modelID: request.model ?? OpenCodeClient.defaultModelID, effort: .medium,
                threadID: sessionID, workspace: workspace,
                onDelta: { _ in }, onFinalMessage: { answer = $0 }, onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in },
                onActionRequest: {}, onUserInput: { _ in }, onTurnStarted: { _ in }
            )
            return answer
        }
        let turn = Task { @MainActor () -> Outcome in
            let outcome: Outcome
            do {
                outcome = try await openCodeOutcome(
                    first: send(schema.map { PluginJSONSchema.prompt(request.prompt, schema: $0) } ?? request.prompt),
                    schema: schema, pluginID: request.pluginID, retry: send
                )
            } catch {
                outcome = Outcome(status: "failed", result: .null, error: client.wasLastTurnInterrupted(threadID: sessionID)
                    ? "OpenCode interrupted the turn." : error.localizedDescription)
            }
            await client.deleteSession(sessionID, workspace: workspace)
            return outcome
        }
        let stop = { [weak client] in
            // A run stopped between its answer and the schema's retry asks no more.
            turn.cancel()
            Task { @MainActor in _ = try? await client?.interruptActiveTurn(threadID: sessionID) }
            return
        }
        return follow(record, request: request, store: store, origin: origin, stop: stop) { await turn.value }
    }

    private static func newRunID() -> String { "agent-run-" + UUID().uuidString.lowercased() }

    /// Tracks and saves a started run, ends it at the timeout, and tells its
    /// plugin how it ended once `wait` returns.
    private static func follow(
        _ record: PluginAgentRunRecord, request: Request, store: PluginAgentRunStore, origin: BridgeRequest,
        stop: @escaping () -> Void, wait: @escaping @MainActor () async -> Outcome
    ) -> String {
        let run = Run(record: record, stop: stop)
        // Active before it is saved, so a recovery pass never takes it for a cut-off run.
        active[record.runID] = run
        store.runs.append(record)
        PlayhouseDiagnostics.record("plugin.agent.started", fields: [
            "pluginID": request.pluginID, "runID": record.runID, "provider": record.provider ?? "", "model": request.model ?? "default",
            "allowedTools": String(request.allowedTools.count), "schema": String(request.jsonSchema != nil)
        ])
        let timeout = timeout
        let requestContext = PlayhouseRequestContext.capture()
        // The daemon stays up while the agent runs, whatever window started it.
        BridgeBackgroundWork.onBegin?()
        Task { @MainActor in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                run.timedOut = true
                run.stop()
            }
            let finished = await wait()
            timer.cancel()
            let outcome: Outcome
            if run.cancelled {
                outcome = Outcome(status: "cancelled", result: .null, error: "The run was cancelled.")
            } else if run.timedOut {
                outcome = Outcome(status: "failed", result: .null, error: "The agent didn't finish within \(Int(timeout)) seconds.")
            } else {
                outcome = finished
            }
            await requestContext.run {
                finish(record.runID, outcome: outcome, store: store, origin: origin)
            }
            BridgeBackgroundWork.onEnd?()
        }
        return record.runID
    }

    /// How a Codex turn ended: its last agent message is the answer, parsed as
    /// JSON when the turn had an output schema.
    static func outcome(codex turn: CodexPlainTurn.Outcome, structured: Bool) -> Outcome {
        switch turn.status {
        case "completed":
            let text = turn.text ?? ""
            guard structured else { return Outcome(status: "done", result: .string(text), error: nil) }
            guard let value = try? JSONDecoder().decode(PluginValue.self, from: Data(text.utf8)) else {
                return Outcome(status: "failed", result: .null, error: "Codex returned no structured output for the JSON schema.")
            }
            return Outcome(status: "done", result: value, error: nil)
        case "interrupted":
            return Outcome(status: "failed", result: .null, error: turn.error ?? "Codex interrupted the turn.")
        default:
            return Outcome(status: "failed", result: .null, error: turn.error ?? "Codex couldn't finish the turn.")
        }
    }

    /// How an OpenCode run ended: its final answer, or with a schema the JSON in it. An answer
    /// that doesn't match the schema is asked for once more with what was wrong; a second
    /// mismatch fails the run.
    static func openCodeOutcome(
        first answer: String, schema: PluginValue?, pluginID: String, retry: (String) async throws -> String
    ) async throws -> Outcome {
        guard let schema else { return Outcome(status: "done", result: .string(answer), error: nil) }
        let problem: String
        switch PluginJSONSchema.check(answer, schema: schema) {
        case .valid(let value): return Outcome(status: "done", result: value, error: nil)
        case .invalid(let found): problem = found
        }
        try Task.checkCancellation()
        PlayhouseDiagnostics.record("plugin.agent.schema_retry", fields: ["pluginID": pluginID, "provider": "opencode", "problem": problem])
        switch PluginJSONSchema.check(try await retry(PluginJSONSchema.correction(problem, schema: schema)), schema: schema) {
        case .valid(let value):
            return Outcome(status: "done", result: value, error: nil)
        case .invalid(let again):
            return Outcome(status: "failed", result: .null, error: "OpenCode's answer didn't match the JSON schema: \(again)")
        }
    }

    struct Outcome {
        var status: String
        var result: PluginValue
        var error: String?
    }

    /// What `claude -p --output-format json` printed: its one result object,
    /// whose `structured_output` is the answer when a schema was given.
    static func outcome(stdout: Data, stderr: Data, exitStatus: Int32, structured: Bool) -> Outcome {
        let lines = String(decoding: stdout, as: UTF8.self).split(separator: "\n")
        let result = lines.reversed().lazy.compactMap { line in
            (try? JSONDecoder().decode(PluginValue.self, from: Data(line.utf8)))?.object
        }.first { $0["type"]?.string == "result" || $0["result"] != nil }
        guard let result else {
            let detail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(status: "failed", result: .null, error: detail.isEmpty
                ? "Claude Code exited with status \(exitStatus) without a result."
                : String(detail.suffix(2_000)))
        }
        if result["is_error"]?.bool == true || exitStatus != 0 {
            return Outcome(status: "failed", result: .null, error: result["result"]?.string ?? "Claude Code reported an error (\(result["subtype"]?.string ?? "error")).")
        }
        if structured {
            guard let output = result["structured_output"], output != .null else {
                return Outcome(status: "failed", result: .null, error: "Claude Code returned no structured output for the JSON schema.")
            }
            return Outcome(status: "done", result: output, error: nil)
        }
        return Outcome(status: "done", result: result["result"] ?? .string(""), error: nil)
    }

    private static func finish(_ runID: String, outcome: Outcome, store: PluginAgentRunStore, origin: BridgeRequest) {
        guard let run = active.removeValue(forKey: runID) else { return }
        let saved = store.runs
        store.runs = saved.filter { $0.runID != runID }
        // A run whose plugin was deleted meanwhile has nobody to tell.
        guard saved.contains(where: { $0.runID == runID }) else { return }
        PlayhouseDiagnostics.record(outcome.status == "done" ? "plugin.agent.finished" : "plugin.agent.failed", fields: [
            "pluginID": run.record.pluginID, "runID": runID, "status": outcome.status, "error": outcome.error ?? ""
        ])
        deliver(run.record, outcome: outcome, origin: origin)
    }

    private static func deliver(_ record: PluginAgentRunRecord, outcome: Outcome, origin: BridgeRequest) {
        let event = PluginEvent.agentFinished(
            pluginID: record.pluginID, runID: record.runID, status: outcome.status,
            result: outcome.result, error: outcome.error, context: record.context
        )
        // As the request that started the run, so its service reaches the same store.
        PluginServiceHost.$origin.withValue(origin) { PluginServiceHost.publish(event) }
    }

    /// Stops a run; its plugin hears `agent.finished` with status `cancelled`.
    static func cancel(pluginID: String, runID: String, store: PluginAgentRunStore, origin: BridgeRequest, codex: CodexAppServerClient? = nil) throws {
        guard let record = store.runs.first(where: { $0.runID == runID && $0.pluginID == pluginID }) else {
            throw BridgeCommandError(code: "not_found", message: "The plugin \(pluginID) has no running agent \(runID).")
        }
        if let run = active[runID] {
            run.cancelled = true
            run.stop()
            return
        }
        // Another daemon's run: stop its process or turn and report it here.
        stop(record, codex: codex)
        store.runs = store.runs.filter { $0.runID != runID }
        deliver(record, outcome: Outcome(status: "cancelled", result: .null, error: "The run was cancelled."), origin: origin)
    }

    /// A deleted plugin's runs stop with no event: there is no plugin left to hear it.
    static func cancelAll(pluginID: String, store: PluginAgentRunStore, codex: CodexAppServerClient? = nil) {
        let runs = store.runs.filter { $0.pluginID == pluginID }
        guard !runs.isEmpty else { return }
        store.runs = store.runs.filter { $0.pluginID != pluginID }
        for record in runs {
            if let run = active[record.runID] {
                run.cancelled = true
                run.stop()
            } else {
                stop(record, codex: codex)
            }
        }
        PlayhouseDiagnostics.record("plugin.agent.cancelled", fields: ["pluginID": pluginID, "count": String(runs.count)])
    }

    /// Runs saved by a daemon that was cut off (it crashed, was killed or
    /// replaced) never finished: each plugin hears `agent.finished` with
    /// status `failed` and the error "interrupted".
    static func recoverInterrupted(store: PluginAgentRunStore, origin: BridgeRequest, codex: CodexAppServerClient? = nil) {
        let saved = store.runs
        let interrupted = saved.filter { active[$0.runID] == nil }
        guard !interrupted.isEmpty else { return }
        store.runs = saved.filter { active[$0.runID] != nil }
        // Requests run concurrently; each cut-off run is reported once.
        for record in interrupted where reported.insert(record.runID).inserted {
            stop(record, codex: codex)
            PlayhouseDiagnostics.record("plugin.agent.interrupted", fields: ["pluginID": record.pluginID, "runID": record.runID])
            deliver(record, outcome: Outcome(status: "failed", result: .null, error: "interrupted"), origin: origin)
        }
    }

    /// The plugins' unfinished runs, oldest first: `{runID, pluginID, context, startedAt, model, running}`.
    static func list(store: PluginAgentRunStore, pluginID: String?) -> [PluginValue] {
        store.runs.filter { pluginID == nil || $0.pluginID == pluginID }.map { record in
            .object([
                "runID": .string(record.runID), "pluginID": .string(record.pluginID), "context": record.context,
                "startedAt": .string(ISO8601DateFormatter().string(from: record.startedAt)),
                "model": record.model.map(PluginValue.string) ?? .null,
                "provider": .string(record.provider ?? ConversationProvider.claude.rawValue),
                "running": .bool(active[record.runID] != nil)
            ])
        }
    }

    /// Stops the Claude Code process of a run this daemon no longer follows.
    private static func stop(_ record: PluginAgentRunRecord, codex: CodexAppServerClient? = nil) {
        if let threadID = record.threadID, let turnID = record.turnID, let codex {
            Task { @MainActor in _ = try? await codex.request(method: "turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
        }
        guard let identity = record.process, identity.isAlive else { return }
        kill(identity.pid, SIGTERM)
    }
}
