import Foundation

/// Runs OpenCode turns through the installed `opencode` executable's HTTP server
/// (`opencode serve`, OpenCode 2's API).
///
/// OpenCode stores its sessions itself, so a Playhouse conversation is an OpenCode session ID.
/// Like Codex's app-server, one shared server runs every conversation's turns at once, as a
/// detached process that outlives the daemon: the next daemon reconnects to it and carries on
/// the turns it still runs. It is started with no skill, rule or MCP configuration: OpenCode
/// finds those in each session's folder itself, and everything else a turn needs (instructions,
/// permissions, extra folders, agent, model) is set on its session.
@MainActor
package final class OpenCodeClient: ConversationProviderClient {
    /// The model OpenCode itself picks: the user's configured default, else its own.
    package nonisolated static let defaultModelID = "default"
    /// The OpenCode 2 release whose server API Playhouse verified: sessions with per-session
    /// permissions and instruction entries, the session inbox's steering, forms for questions,
    /// and the event stream.
    package nonisolated static let minimumVersion = "2.4.0"

    package let provider = ConversationProvider.opencode
    /// Every running turn in this process, by session, whichever client started it.
    package static var activeTurnsBySessionID: [String: OpenCodeTurn] = [:]
    package static var sharedPrimaryClients: [String: OpenCodeClient] = [:]
    package static var versionsByExecutable: [String: String] = [:]
    /// The server each session last ran a turn on, by its connection key.
    package static var serverKeysBySessionID: [String: String] = [:]

    package var isTurnActive = false
    package var activeThreadIDs: Set<String> = []
    package var pendingUserInputRequest: ConversationUserInputRequest?

    package var isPreparingForApplicationTermination = false

    package enum ClientError: LocalizedError {
        case cliNotFound
        case processStart(String)
        case processExited(String)
        case protocolFailure(String)
        case authentication(String)
        case unsupportedVersion(String)
        case turnFailed(String)
        case sessionNotFound

        package var errorDescription: String? {
            switch self {
            case .cliNotFound:
                "OpenCode wasn't found. Install OpenCode or add `opencode` to PATH, then restart Playhouse."
            case .processStart(let detail):
                "Playhouse couldn't start OpenCode: \(detail)"
            case .processExited(let detail):
                "OpenCode stopped unexpectedly. \(detail)"
            case .protocolFailure(let detail):
                "Playhouse couldn't communicate with OpenCode: \(detail)"
            case .authentication(let detail):
                "OpenCode needs a model provider it can use. Run `opencode auth login` in Terminal, then try again. \(detail)"
            case .unsupportedVersion(let version):
                "OpenCode \(version) is too old for Playhouse. Update to \(OpenCodeClient.minimumVersion) or later (`opencode upgrade`), then try again."
            case .turnFailed(let detail):
                detail
            case .sessionNotFound:
                "OpenCode couldn't find this conversation's session."
            }
        }
    }

    /// The test harness's executable as given; `executableOverride` resolves it on each read,
    /// so a CLI installed while Playhouse runs is found without a restart.
    package let executableOverrideSetting: String?
    package var executableOverride: String? {
        ConversationProviderFixture.currentExecutable(executableOverrideSetting, providerMarker: Self.fixtureMarker)
    }
    package static let fixtureMarker = (name: ".playhouse-opencode-fixture-owner", value: "Playhouse test owns this OpenCode protocol fixture (v1).\n")
    /// How long this client's sessions stay in OpenCode's session list.
    package enum SessionLifetime {
        /// A task's or chat's session, whose turns' messages are written for the token map.
        case kept
        /// A helper client's one-shot turns (titles, summaries) delete theirs once done.
        case oneTurn
        /// A plugin agent may answer in several turns of its session, and removes it once done.
        case untilDeleted
    }
    package let sessionLifetime: SessionLifetime
    /// This instance's own data directory (debug/test builds only; nil in production).
    package let dataDirectoryOverride: String?
    package var runtimeScope: String? { dataDirectoryOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
    /// Where shared servers keep their manifests and logs: beside the daemon's store, so a
    /// server outlives the daemon; a helper client shares its primary client's.
    package let runsDirectory: URL
    /// Where a finished turn writes its session's messages for the token map (`OpenCodeRequestLog`),
    /// beside the store; nil for a client with no store.
    package let requestLogDirectory: URL?
    package var turns: [String: OpenCodeTurn] = [:]
    package var startingServers: [String: Task<OpenCodeServerConnection, Error>] = [:]
    package var startingSessionIDs = Set<String>()
    package var interruptedThreadIDs = Set<String>()
    package var stoppingOutcomeProbes: [String: ProviderStoppingOutcomeProbe] = [:]
    package var lastTurnDiagnosticsByThread: [String: [String: String]] = [:]
    package var activityDurationsByThread: [String: [String: Int]] = [:]
    package var lastFinishedThreadID: String?
    package var conversationOperationsInFlight = 0
    package var mcpLoginAttempts: [String: (integration: String, attemptID: String)] = [:]
    package var mcpLoginHolds: [String: Task<Void, Never>] = [:]
    package var modelsCache: (readAt: Date, key: String, models: [ConversationModelOption], variants: [String: [String]])?
    package static let modelsCacheLifetime: TimeInterval = 5 * 60

    package static func sharedPrimaryClient(executableOverride: String?, dataDirectory: String? = nil, runDirectory: URL? = nil) -> OpenCodeClient {
        let key = [
            executableOverride.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "__default__",
            dataDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? "",
        ].joined(separator: "\u{1}")
        if let client = sharedPrimaryClients[key] { return client }
        let client = OpenCodeClient(
            executableOverride: executableOverride, dataDirectory: dataDirectory,
            runsDirectory: runDirectory.map { OpenCodeSharedServer.runsDirectory(dataDirectory: $0) },
            requestLogDirectory: runDirectory.map { OpenCodeRequestLog.directory(storeDirectory: $0) }
        )
        sharedPrimaryClients[key] = client
        return client
    }

    package init(
        executableOverride: String? = nil, sessionLifetime: SessionLifetime = .kept, dataDirectory: String? = nil, runsDirectory: URL? = nil,
        requestLogDirectory: URL? = nil
    ) {
        executableOverrideSetting = executableOverride
        self.sessionLifetime = sessionLifetime
        self.requestLogDirectory = requestLogDirectory
        dataDirectoryOverride = dataDirectory
        self.runsDirectory = runsDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("playhouse-opencode-runs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    package static var allSharedPrimaryClients: [OpenCodeClient] { Array(sharedPrimaryClients.values) }
    package static func hasActiveTurn(sessionID: String) -> Bool { activeTurnsBySessionID[sessionID] != nil }

    package func turnStateChanged() {
        let active = turns.values.filter { !$0.finished }
        activeThreadIDs = Set(active.map(\.sessionID))
        isTurnActive = !active.isEmpty
        pendingUserInputRequest = turns.values.compactMap(\.pendingUserInputRequest).first
    }

    package func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["provider"] = provider.rawValue
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["isTurnActive"] = String(isTurnActive)
        fields["activeTurnCount"] = String(activeThreadIDs.count)
        return fields
    }

    package func diagnosticFields(forThread threadID: String, _ additionalFields: [String: String]) -> [String: String] {
        var fields = diagnosticFields(additionalFields)
        guard let turnFields = turns[threadID]?.diagnosticFields([:]) ?? lastTurnDiagnosticsByThread[threadID] else { return fields }
        fields.merge(turnFields) { _, new in new }
        return fields
    }

    // MARK: - Servers

    /// The one server every task runs on, reusing one this daemon or a previous one started,
    /// else starting it. It is the same for every workspace: OpenCode finds each folder's skills,
    /// rules and MCP servers itself, the way it does when used directly.
    package func connection(for workspace: ConversationWorkspaceContext) async throws -> OpenCodeServerConnection {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let environment = OpenCodeLaunch.serverEnvironment(dataDirectoryOverride: dataDirectoryOverride)
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let keyHash = OpenCodeSharedServer.keyHash(parts: [resolved, dataDirectoryOverride ?? ""], serviceName: AgentRunService.name)
        let server = OpenCodeSharedServer(runDirectory: runsDirectory, keyHash: keyHash, serviceName: AgentRunService.name)
        let key = OpenCodeServerConnection.key(server)
        if let existing = OpenCodeServerConnection.connections[key], existing.isAlive { return existing }
        if let starting = startingServers[key] { return try await starting.value }
        let start = Task { @MainActor in
            try await self.openServer(server, executable: executable, resolvedExecutable: resolved, environment: environment)
        }
        startingServers[key] = start
        defer { startingServers.removeValue(forKey: key) }
        let connection = try await start.value
        OpenCodeServerConnection.connections[key] = connection
        return connection
    }

    package func openServer(
        _ server: OpenCodeSharedServer, executable: String, resolvedExecutable: String, environment: [String: String]
    ) async throws -> OpenCodeServerConnection {
        // Waits only for a predecessor daemon that is still exiting.
        let ownership = try? await AgentOwnershipLock.acquire(path: server.lockPath, timeout: 15)
        if let manifest = server.readManifest() {
            if manifest.state == "running", manifest.process?.isAlive == true, manifest.port != nil {
                PlayhouseDiagnostics.record("opencode.server.adopted", fields: diagnosticFields(["processID": String(manifest.process?.pid ?? -1)]))
                return OpenCodeServerConnection(server: server, manifest: manifest, ownership: ownership)
            }
            if let process = manifest.process { await AgentRunHost.terminate(process) }
            server.removeFiles()
        }
        let version = try await Self.version(of: executable)
        try Self.verifyVersion(version)
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: [])
        let manifest = try await server.spawn(
            executable: command.executable, arguments: command.arguments, environment: environment,
            resolvedExecutablePath: resolvedExecutable, openCodeVersion: version
        )
        PlayhouseDiagnostics.record("opencode.server.started", fields: diagnosticFields([
            "executable": executable, "processID": String(manifest.process?.pid ?? -1), "version": version ?? "",
        ]))
        return OpenCodeServerConnection(server: server, manifest: manifest, ownership: ownership)
    }

    /// The live server that runs `sessionID`'s turn, left by this daemon or a previous one.
    package func connectionRunning(sessionID: String) -> OpenCodeServerConnection? {
        if let turn = Self.activeTurnsBySessionID[sessionID] { return turn.connection }
        for entry in OpenCodeSharedServer.manifests(in: runsDirectory, serviceName: AgentRunService.name)
        where entry.manifest.turns[sessionID] != nil {
            if let connection = OpenCodeServerConnection.adopt(entry.server, manifest: entry.manifest) { return connection }
        }
        return nil
    }

    /// The live server `sessionID` last ran a turn on, which runs its background jobs.
    package func connectionLastUsed(sessionID: String) -> OpenCodeServerConnection? {
        if let connection = connectionRunning(sessionID: sessionID) { return connection }
        guard let key = Self.serverKeysBySessionID[sessionID], let connection = OpenCodeServerConnection.connections[key], connection.isAlive else { return nil }
        return connection
    }

    /// `opencode --version` prints `opencode v2.4.0` (OpenCode 1 prints the bare number).
    package static func version(of executable: String) async throws -> String? {
        let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolved)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(resolved)\u{1}\(modified)"
        if let cached = versionsByExecutable[cacheKey] { return cached }
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: ["--version"])
        guard let output = await OpenCodeLaunch.run(command.executable, command.arguments, environment: PlayhouseProcessEnvironment.current) else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        guard let token = text.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.first?.isNumber == true || ($0.first == "v" && $0.dropFirst().first?.isNumber == true) }) else { return nil }
        let version = token.hasPrefix("v") ? String(token.dropFirst()) : String(token)
        versionsByExecutable[cacheKey] = version
        return version
    }

    // MARK: - Sessions

    /// A new session in the workspace's working folder, with the task's permissions and other
    /// folders already set, so a send that follows only prompts it.
    package func startThread(workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?) async throws -> String {
        let connection = try await connection(for: workspace)
        let created = try await connection.data("POST", "api/session", body: [
            "location": ["directory": workspace.cwd.path],
            "permissions": OpenCodeLaunch.sessionPermissions(workspace: workspace),
        ])
        guard let sessionID = created["id"] as? String, !sessionID.isEmpty else {
            throw ClientError.protocolFailure("OpenCode created a session without an ID.")
        }
        PlayhouseDiagnostics.record("opencode.session.created", fields: diagnosticFields(["threadID": sessionID]))
        return sessionID
    }

    /// A new session that starts with a copy of the source session's history. It inherits the
    /// source's permissions and instructions, which the next send replaces with its own.
    package func forkThread(sourceThreadID: String, workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?) async throws -> String {
        let connection = try await connection(for: workspace)
        let forked = try await connection.data("POST", "api/session/\(sourceThreadID)/fork", body: [String: Any]())
        guard let sessionID = forked["id"] as? String, !sessionID.isEmpty else {
            throw ClientError.protocolFailure("OpenCode forked a session without an ID.")
        }
        try await connection.request("PATCH", "api/session/\(sessionID)", body: ["permissions": OpenCodeLaunch.sessionPermissions(workspace: workspace)])
        return sessionID
    }

    /// False when OpenCode no longer has the session, so the send starts a new one seeded with
    /// Playhouse's own transcript. OpenCode assigns session IDs, so a missing session can't be
    /// recreated under its old ID the way Claude Code's can.
    package func loadThreadForSend(
        threadID: String, workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?,
        sensitiveUserInputAnswerValues: [String], hideSensitiveRecoveryPrompt: Bool
    ) async throws -> Bool {
        guard executablePath != nil, Self.activeTurnsBySessionID[threadID] == nil else { return true }
        do {
            let connection = try await connection(for: workspace)
            try await connection.request("GET", "api/session/\(threadID)")
            return true
        } catch ClientError.sessionNotFound {
            PlayhouseDiagnostics.record("opencode.session.missing", fields: diagnosticFields(["threadID": threadID]))
            return false
        } catch {
            // The send reports other failures itself.
            return true
        }
    }

    /// The chat models OpenCode offers the workspace's folder, with each one's effort variants;
    /// the current default is the one a conversation with no model of its own runs.
    package func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption] {
        try await modelCatalog(workspace: workspace).models
    }

    package func modelCatalog(workspace: ConversationWorkspaceContext) async throws -> (models: [ConversationModelOption], variants: [String: [String]]) {
        let key = workspace.cwd.path
        if let cache = modelsCache, cache.key == key, Date().timeIntervalSince(cache.readAt) < Self.modelsCacheLifetime {
            return (cache.models, cache.variants)
        }
        let connection = try await connection(for: workspace)
        let location = OpenCodeServerConnection.location(workspace.cwd.path)
        // OpenCode loads a folder's catalog on its first request, which answers before it is
        // loaded with no models, and briefly with only its built-in providers before the
        // configured ones; the list is asked again until two reads half a second apart agree.
        var listed: [[String: Any]] = []
        var previous: [[String: Any]]?
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            listed = (try await connection.request("GET", "api/model", query: location) as? [String: Any])?["data"] as? [[String: Any]] ?? []
            if let previous, !listed.isEmpty, NSArray(array: previous).isEqual(to: listed) { break }
            previous = listed.isEmpty ? nil : listed
            try await Task.sleep(for: .milliseconds(listed.isEmpty ? 250 : 500))
        } while ContinuousClock.now < deadline
        let fallback = try? await connection.data("GET", "api/model/default", query: location)
        let catalog = Self.models(from: listed, default: fallback.flatMap(Self.modelID))
        if !catalog.models.isEmpty { modelsCache = (Date(), key, catalog.models, catalog.variants) }
        return catalog
    }

    package nonisolated static func modelID(_ model: [String: Any]) -> String? {
        guard let provider = model["providerID"] as? String, let id = model["modelID"] as? String ?? model["id"] as? String else { return nil }
        return "\(provider)/\(id)"
    }

    package nonisolated static func models(from listed: [[String: Any]], default defaultID: String?) -> (models: [ConversationModelOption], variants: [String: [String]]) {
        var variants: [String: [String]] = [:]
        let models = listed.compactMap { model -> ConversationModelOption? in
            guard let id = modelID(model), model["enabled"] as? Bool != false else { return nil }
            let names = (model["variants"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            variants[id] = names
            let efforts = ConversationEffort.allCases.filter { names.contains($0.rawValue) }
            let name = (model["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            return ConversationModelOption(id: id, name: name, isDefault: id == defaultID, supportedEfforts: efforts.isEmpty ? nil : efforts)
        }
        return (models, variants)
    }

    /// The variant an effort asks for: the same one when the model has it, else the strongest
    /// one below it (OpenCode's variants often stop at high), else none.
    package nonisolated static func variant(for effort: ConversationEffort, among variants: [String]) -> String? {
        guard !variants.isEmpty else { return nil }
        let order = ConversationEffort.allCases
        let index = order.firstIndex(of: effort) ?? 1
        return order[...index].reversed().map(\.rawValue).first(where: variants.contains)
    }

    /// The session's agent, model and variant for this turn, and what Playhouse adds to it:
    /// permissions for its other folders and mode, and Playhouse's task guidance as an entry
    /// OpenCode adds to the system prompt. Rules come only from what OpenCode reads itself.
    package func configureSession(
        _ sessionID: String, connection: OpenCodeServerConnection, workspace: ConversationWorkspaceContext,
        mode: ConversationMode, modelID: String, effort: ConversationEffort, developerInstructions: String?
    ) async throws {
        try await connection.request("PATCH", "api/session/\(sessionID)", body: ["permissions": OpenCodeLaunch.sessionPermissions(workspace: workspace)])
        let entry = "api/experimental/session/\(sessionID)/instructions/entries/playhouse"
        if let instructions = developerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            try await connection.request("PUT", entry, body: ["value": instructions])
        } else {
            _ = try? await connection.request("DELETE", entry)
        }
        try await connection.request("POST", "api/session/\(sessionID)/agent", body: ["agent": mode == .plan ? "plan" : "build"])
        let catalog = try? await modelCatalog(workspace: workspace)
        let model = modelID == Self.defaultModelID || modelID.isEmpty ? catalog?.models.first(where: \.isDefault)?.id : modelID
        guard let model, let slash = model.firstIndex(of: "/") else { return }
        var reference: [String: Any] = ["providerID": String(model[..<slash]), "id": String(model[model.index(after: slash)...])]
        if let variant = Self.variant(for: effort, among: catalog?.variants[model] ?? []) { reference["variant"] = variant }
        try await connection.request("POST", "api/session/\(sessionID)/model", body: ["model": reference])
    }

    /// What the model-switch compaction rule needs: the model the session last ran, the size of
    /// its last model call's context, and whether it was compacted since.
    package func compactionState(sessionID: String, workspace: ConversationWorkspaceContext) async -> ContextCompactionSessionState? {
        guard executablePath != nil, let connection = try? await connection(for: workspace),
              let info = try? await connection.data("GET", "api/session/\(sessionID)") else { return nil }
        let listed = (try? await connection.request("GET", "api/session/\(sessionID)/message", query: ["order": "desc", "limit": "20"])) as? [String: Any]
        let recent = (listed?["data"] as? [[String: Any]] ?? []).filter { $0["type"] as? String != "idle" }
        guard let last = recent.first(where: { $0["type"] as? String == "assistant" && $0["tokens"] != nil }),
              let tokens = last["tokens"] as? [String: Any] else { return nil }
        func value(_ object: [String: Any]?, _ key: String) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        let cache = tokens["cache"] as? [String: Any]
        let updated = ((info["time"] as? [String: Any])?["updated"] as? NSNumber)?.doubleValue
        return ContextCompactionSessionState(
            lastCallAt: updated.map { Date(timeIntervalSince1970: $0 / 1000) },
            contextTokens: value(tokens, "input") + value(cache, "read") + value(cache, "write"),
            model: (info["model"] as? [String: Any]).flatMap(Self.modelID),
            lastCompaction: nil,
            compactedSinceLastCall: recent.first?["type"] as? String == "compaction"
        )
    }

    /// Compacts the session with OpenCode's own summary and waits until it is done.
    package func compactSession(_ sessionID: String, workspace: ConversationWorkspaceContext) async throws {
        let connection = try await connection(for: workspace)
        var outcome: Result<Void, Error>?
        let subscription = try await connection.subscribe { event in
            let data = event["data"] as? [String: Any] ?? [:]
            guard data["sessionID"] as? String == sessionID || event["type"] as? String == "playhouse.server.exited" else { return }
            switch event["type"] as? String {
            case "session.compaction.ended", "session.execution.succeeded": outcome = outcome ?? .success(())
            case "session.compaction.failed", "session.execution.failed", "playhouse.server.exited":
                let message = ((data["error"] as? [String: Any])?["message"] as? String) ?? "OpenCode couldn't compact the session."
                outcome = outcome ?? .failure(ClientError.turnFailed(message))
            default: break
            }
        }
        defer { connection.unsubscribe(subscription) }
        try await connection.request("POST", "api/session/\(sessionID)/compact", body: [String: Any]())
        let deadline = ContinuousClock.now + .seconds(600)
        while outcome == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try (outcome ?? .failure(ClientError.turnFailed("OpenCode's compaction didn't finish."))).get()
        // The summary now stands for the history the token map shows.
        await writeRequestLog(sessionID, connection: connection)
    }

    package func deleteSession(_ sessionID: String, connection: OpenCodeServerConnection) async {
        _ = try? await connection.request("DELETE", "api/session/\(sessionID)")
    }

    /// Removes a session of an `untilDeleted` client once its work is done.
    package func deleteSession(_ sessionID: String, workspace: ConversationWorkspaceContext) async {
        guard let connection = try? await connection(for: workspace) else { return }
        await deleteSession(sessionID, connection: connection)
    }

    // MARK: - Turns

    package func sendMessage(
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
        onMessageTimestamp: @escaping (String, Date) -> Void = { _, _ in },
        onTurnStarted: @escaping (String) -> Void,
        onTokenUsage: @escaping (ConversationTurnUsageReport) -> Void = { _ in },
        onRecordedFinalMessage: ((String, String) -> Void)? = nil,
        sensitiveUserInputAnswerValues: [String] = [],
        hideSensitiveRecoveryPrompt: Bool = false
    ) async throws {
        let sessionID = threadID
        guard Self.activeTurnsBySessionID[sessionID] == nil else {
            PlayhouseDiagnostics.record("opencode.turn.rejected", fields: diagnosticFields([
                "requestedThreadID": sessionID, "reason": "session_turn_already_active",
            ]))
            throw ClientError.protocolFailure("Another OpenCode turn is already running for this conversation.")
        }
        let connection = try await connection(for: workspace)
        try await configureSession(
            sessionID, connection: connection, workspace: workspace, mode: mode, modelID: modelID, effort: effort,
            developerInstructions: developerInstructions
        )
        let turn = OpenCodeTurn(
            sessionID: sessionID, connection: connection, owner: self, mode: mode, readOnly: workspace.isReadOnly,
            callbacks: ConversationTurnCallbacks(
                onDelta: onDelta, onFinalMessage: onFinalMessage, onActivity: onActivity, onDiff: onDiff, onHistory: onHistory,
                onActionRequest: onActionRequest, onUserInput: onUserInput, onSteerMessage: onSteerMessage,
                onProgressMessage: onProgressMessage, onMessageTimestamp: onMessageTimestamp, onTurnStarted: onTurnStarted,
                onTokenUsage: onTokenUsage, onRecordedFinalMessage: onRecordedFinalMessage
            )
        )
        for client in Self.allSharedPrimaryClients { client.interruptedThreadIDs.remove(sessionID) }
        interruptedThreadIDs.remove(sessionID)
        install(turn)
        defer { uninstall(turn) }
        PlayhouseDiagnostics.record("opencode.turn.started", fields: turn.diagnosticFields([
            "threadID": sessionID, "turnID": turn.turnID, "mode": mode.rawValue, "workspaceRootCount": String(workspace.roots.count),
        ]))
        let mailbox = serviceMailbox(turn)
        defer { mailbox.cancel() }
        do {
            try await turn.run(text: text, imageDataURLs: imageDataURLs, cwd: workspace.cwd.path)
            PlayhouseDiagnostics.record("opencode.turn.ended", fields: turn.diagnosticFields(["threadID": sessionID, "turnStatus": "completed"]))
        } catch {
            if !turn.finished { turn.finish(.failure(error)) }
            var fields = PlayhouseDiagnostics.errorFields(error, redacting: [])
            fields["threadID"] = sessionID
            fields["turnStatus"] = turn.wasInterrupted ? "interrupted" : "failed"
            PlayhouseDiagnostics.record("opencode.turn.ended", fields: fields)
            await writeRequestLog(sessionID, connection: connection)
            throw error
        }
        await writeRequestLog(sessionID, connection: connection)
        if sessionLifetime == .oneTurn { await deleteSession(sessionID, connection: connection) }
    }

    /// The finished turn's messages, written before the turn returns so its token map is complete.
    package func writeRequestLog(_ sessionID: String, connection: OpenCodeServerConnection) async {
        guard sessionLifetime == .kept, let requestLogDirectory else { return }
        await OpenCodeRequestLog.write(sessionID: sessionID, connection: connection, directory: requestLogDirectory)
    }

    /// A model request of a running turn ended: its log follows soon, so an open token map
    /// shows the running turn's requests.
    package func requestLogStepEnded(_ sessionID: String, connection: OpenCodeServerConnection) {
        guard sessionLifetime == .kept, let requestLogDirectory else { return }
        OpenCodeRequestLog.update(sessionID: sessionID, connection: connection, directory: requestLogDirectory)
    }

    package func followReattachedTurn(
        threadID: String,
        workspace: ConversationWorkspaceContext,
        callbacks: ConversationTurnCallbacks,
        onAttached: @escaping () -> Void
    ) async throws -> ConversationReattachResult {
        let sessionID = threadID
        guard Self.activeTurnsBySessionID[sessionID] == nil else { return .notRunning }
        guard let connection = connectionRunning(sessionID: sessionID), let record = connection.manifest.turns[sessionID] else { return .agentGone }
        let turn = OpenCodeTurn(
            sessionID: sessionID, connection: connection, owner: self, mode: ConversationMode(rawValue: record.mode) ?? .code,
            readOnly: record.readOnly, callbacks: callbacks
        )
        turn.promptMessageID = record.promptMessageID
        install(turn)
        defer { uninstall(turn) }
        try await turn.listen()
        PlayhouseDiagnostics.record("opencode.turn.reattached", fields: turn.diagnosticFields(["threadID": sessionID]))
        onAttached()
        let mailbox = serviceMailbox(turn)
        defer { mailbox.cancel() }
        do {
            try await turn.rebuild(recorded: record.recordedTextIDs)
        } catch ClientError.sessionNotFound {
            turn.finish(.failure(ClientError.sessionNotFound))
            return .agentGone
        }
        do {
            try await turn.waitForCompletion()
        } catch {
            await writeRequestLog(sessionID, connection: connection)
            throw error
        }
        await writeRequestLog(sessionID, connection: connection)
        return .finished
    }

    private func install(_ turn: OpenCodeTurn) {
        turns[turn.sessionID] = turn
        Self.serverKeysBySessionID[turn.sessionID] = OpenCodeServerConnection.key(turn.connection.server)
        Self.activeTurnsBySessionID[turn.sessionID] = turn
        activityDurationsByThread[turn.sessionID] = [:]
        lastFinishedThreadID = turn.sessionID
        ConversationSteerMailbox.publishActiveTurn(threadID: turn.sessionID, turnID: turn.turnID)
        turnStateChanged()
    }

    private func uninstall(_ turn: OpenCodeTurn) {
        let sessionID = turn.sessionID
        if !turn.finished { turn.finish(.failure(ClientError.turnFailed("The OpenCode turn ended."))) }
        lastTurnDiagnosticsByThread[sessionID] = turn.diagnosticFields([:]).filter { $0.key != "isTurnActive" }
        ConversationSteerMailbox.clearActiveTurn(threadID: sessionID)
        stoppingOutcomeProbes.removeValue(forKey: sessionID)
        if turn.wasInterrupted { interruptedThreadIDs.insert(sessionID) }
        activityDurationsByThread[sessionID] = turn.activityDurations
        lastFinishedThreadID = sessionID
        if Self.activeTurnsBySessionID[sessionID] === turn { Self.activeTurnsBySessionID.removeValue(forKey: sessionID) }
        if turns[sessionID] === turn { turns.removeValue(forKey: sessionID) }
        Task { await TaskCPUUsageSampler.shared.forget(threadID: sessionID) }
        turnStateChanged()
    }

    package func serviceMailbox(_ turn: OpenCodeTurn) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak turn] in
            while let turn, !Task.isCancelled, !turn.finished {
                await ConversationSteerMailbox.service(threadID: turn.sessionID, turnID: turn.turnID) { text, images in
                    try await self?.steerActiveTurn(threadID: turn.sessionID, text: text, imageDataURLs: images) ?? false
                } interrupt: {
                    try await turn.interrupt()
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
    }

    /// Before an idle daemon exits: a server with no turn left has nothing more to do.
    package static func stopRunsBeforeExit() async {
        await OpenCodeServerConnection.stopIdleServersBeforeExit()
    }

    package func interruptActiveTurn(threadID: String) async throws -> Bool {
        guard let turn = turns[threadID] ?? Self.activeTurnsBySessionID[threadID], turn.canInterrupt else {
            guard Self.activeTurnsBySessionID[threadID] == nil else { return false }
            return try await ConversationSteerMailbox.requestInterrupt(threadID: threadID)
        }
        let interrupted = try await turn.interrupt()
        if interrupted { interruptedThreadIDs.insert(threadID) }
        return interrupted
    }

    /// Shells OpenCode moved to the background keep running after the turn that started them.
    package func hasBackgroundWorkToStop(threadID: String) async -> Bool {
        guard let connection = connectionLastUsed(sessionID: threadID) else { return false }
        return !(await runningJobs(threadID: threadID, connection: connection)).isEmpty
    }

    package func stopBackgroundWork(threadID: String) async throws -> Bool {
        guard let connection = connectionLastUsed(sessionID: threadID) else { return false }
        let jobs = await runningJobs(threadID: threadID, connection: connection)
        for job in jobs { _ = try? await connection.request("POST", "api/experimental/job/\(job)/cancel") }
        return !jobs.isEmpty
    }

    package func runningJobs(threadID: String, connection: OpenCodeServerConnection) async -> [String] {
        let listed = (try? await connection.request("GET", "api/experimental/job", query: [
            "sessionID": threadID, "status": "running", "descendants": "true",
        ]) as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return listed.compactMap { $0["id"] as? String }
    }

    package func forceStopActiveTurn(threadID: String, interruptProvider: Bool) async -> Bool {
        guard let turn = turns[threadID] ?? Self.activeTurnsBySessionID[threadID] else { return false }
        let stopped = !turn.finished
        turn.wasInterrupted = true
        interruptedThreadIDs.insert(threadID)
        if interruptProvider {
            let connection = turn.connection
            Task { _ = try? await connection.request("POST", "api/session/\(threadID)/interrupt") }
        }
        turn.settleActivities(status: "interrupted")
        turn.finish(.failure(ClientError.turnFailed("The OpenCode turn was interrupted.")))
        return stopped
    }

    package func steerActiveTurn(threadID: String, text: String, imageDataURLs: [String] = []) async throws -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || !imageDataURLs.isEmpty else { throw PlayhouseManagerError.invalidMessage }
        guard let turn = Self.activeTurnsBySessionID[threadID] else {
            return try await ConversationSteerMailbox.requestSteer(threadID: threadID, text: normalized, imageDataURLs: imageDataURLs)
        }
        let accepted = try await turn.steer(text: normalized, imageDataURLs: imageDataURLs)
        if accepted { turn.callbacks.onSteerMessage(normalized, imageDataURLs) }
        return accepted
    }

    package func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool {
        turn(for: threadID)?.answerUserInput(requestID: requestID, answers: answers) ?? false
    }

    package func rejectUserInput(requestID: String, threadID: String, message: String) {
        turn(for: threadID)?.rejectUserInput(requestID: requestID, message: message)
    }

    package func isTurnActive(threadID: String) -> Bool {
        if startingSessionIDs.contains(threadID) { return true }
        guard let turn = turns[threadID] else { return false }
        return !turn.finished
    }

    package func isTurnActiveInProcess(threadID: String) -> Bool { Self.activeTurnsBySessionID[threadID]?.finished == false }

    package var activeThreadIDsSnapshot: Set<String> {
        Set(turns.keys.filter { isTurnActive(threadID: $0) }).union(startingSessionIDs)
    }

    package var pendingUserInputsSnapshot: [String: ConversationUserInputRequest] {
        turns.compactMapValues(\.pendingUserInputRequest)
    }

    /// The shared server's process, for a turn that is the only one it runs: with several, the
    /// server's load can't be told apart by conversation.
    package var activeProcessIdentifiersByThreadID: [String: pid_t] {
        let active = turns.values.filter { !$0.finished }
        var result: [String: pid_t] = [:]
        for turn in active where active.filter({ $0.connection === turn.connection }).count == 1 {
            let pid = turn.connection.processIdentifier
            if pid > 0 { result[turn.sessionID] = pid }
        }
        return result
    }

    package var interruptedThreadIDsSnapshot: Set<String> { interruptedThreadIDs }

    package func setStoppingOutcomeProbe(_ probe: ProviderStoppingOutcomeProbe?, threadID: String) {
        stoppingOutcomeProbes[threadID] = probe
    }

    package func canInterruptActiveTurn(threadID: String) -> Bool { turns[threadID]?.canInterrupt == true }

    package func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        if Self.activeTurnsBySessionID[threadID] != nil { return Int32(ProcessInfo.processInfo.processIdentifier) }
        return ConversationSteerMailbox.activeTurnOwnerProcessID(threadID: threadID)
    }

    package func markTurnStarting(threadID: String) { startingSessionIDs.insert(threadID) }
    package func clearTurnStarting(threadID: String) { startingSessionIDs.remove(threadID) }
    package func beginConversationOperation() { conversationOperationsInFlight += 1 }
    package func finishConversationOperation() { conversationOperationsInFlight = max(0, conversationOperationsInFlight - 1) }

    package func prepareForApplicationTermination() async {
        isPreparingForApplicationTermination = true
        for turn in turns.values where !turn.finished {
            _ = try? await turn.interrupt()
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while conversationOperationsInFlight > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        shutdown()
    }

    /// The servers keep running for the turns they still have, and stop on their own when idle.
    package func shutdown() {}

    package func isProviderUnavailable(_ error: Error) -> Bool {
        switch error as? ClientError {
        case .cliNotFound, .processStart, .authentication, .unsupportedVersion: true
        default: false
        }
    }

    package func makeAuxiliaryClient() -> ConversationProviderClient {
        OpenCodeClient(executableOverride: executableOverrideSetting, sessionLifetime: .oneTurn, dataDirectory: dataDirectoryOverride, runsDirectory: runsDirectory)
    }

    /// A client for a plugin agent, whose session stays until `deleteSession(_:workspace:)`.
    package func makePluginAgentClient() -> OpenCodeClient {
        OpenCodeClient(executableOverride: executableOverrideSetting, sessionLifetime: .untilDeleted, dataDirectory: dataDirectoryOverride, runsDirectory: runsDirectory)
    }

    // MARK: - Per-conversation turn results

    package func wasLastTurnInterrupted(threadID: String) -> Bool { interruptedThreadIDs.contains(threadID) }
    package func lastTurnActivityDurations(threadID: String) -> [String: Int] { activityDurationsByThread[threadID] ?? [:] }
    package func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? { turns[threadID]?.pendingUserInputRequest }

    package var wasLastTurnInterrupted: Bool { lastFinishedThreadID.map { interruptedThreadIDs.contains($0) } ?? false }
    package var lastTurnActivityDurations: [String: Int] { lastFinishedThreadID.flatMap { activityDurationsByThread[$0] } ?? [:] }

    package func turn(for threadID: String) -> OpenCodeTurn? {
        turns[threadID] ?? Self.activeTurnsBySessionID[threadID]
    }

    // MARK: - Executable

    package var isInstalled: Bool { executablePath != nil }

    package var executablePath: String? {
        if executableOverride == ConversationProviderFixture.notInstalledOverride { return nil }
        return executableOverride ?? Self.findExecutable()
    }

    package static func findExecutable() -> String? {
        let home = NSHomeDirectory()
        let pathEntries = (PlayhouseProcessEnvironment.current["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("opencode").path }
        let common = [
            "\(home)/.opencode/bin/opencode", "\(home)/.local/bin/opencode", "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode", "\(home)/.npm-global/bin/opencode", "\(home)/.bun/bin/opencode",
        ]
        return (pathEntries + common).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    package static func verifyVersion(_ version: String?) throws {
        guard let version else { return }
        let current = version.split(separator: " ").first.map(String.init) ?? version
        if current.compare(minimumVersion, options: .numeric) == .orderedAscending {
            throw ClientError.unsupportedVersion(current)
        }
    }

    package nonisolated static func classifyFailure(_ error: ClientError, text: String) -> Error {
        let normalized = text.lowercased()
        if normalized.contains("auth_required") || normalized.contains("authentication required") || normalized.contains("invalid api key")
            || normalized.contains("provider.auth") || normalized.contains("no provider") || normalized.contains("api key") && normalized.contains("missing") {
            return ClientError.authentication(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return error
    }
}

/// What every `opencode serve` Playhouse starts is launched with, and what it sets on sessions.
@MainActor
package enum OpenCodeLaunch {
    /// The rules Playhouse puts on a session: the task's other folders are open to it (OpenCode
    /// asks before touching a folder outside the session's own), and a side chat can't edit and
    /// is asked about every command. Code mode adds nothing over the user's own rules.
    package static func sessionPermissions(workspace: ConversationWorkspaceContext) -> [[String: String]] {
        var rules: [[String: String]] = []
        for root in workspace.roots where root.standardizedFileURL != workspace.cwd.standardizedFileURL {
            // Tools compare the written path without following symlinks, so both spellings count.
            for path in Array(Set([root.path, root.resolvingSymlinksInPath().path])).sorted() {
                rules.append(["action": "external_directory", "resource": path + "/*", "effect": "allow"])
            }
        }
        if workspace.isReadOnly {
            rules.append(["action": "edit", "resource": "*", "effect": "deny"])
            rules.append(["action": "shell", "resource": "*", "effect": "ask"])
        }
        return rules
    }

    package static func promptBody(text: String, imageDataURLs: [String]) -> [String: Any] {
        var body: [String: Any] = ["text": text]
        let files = imageDataURLs.enumerated().map { index, url -> [String: Any] in
            ["uri": url, "name": "image-\(index + 1)"]
        }
        if !files.isEmpty { body["files"] = files }
        return body
    }

    /// The server's environment: Playhouse's bridge variables and nothing about skills, rules or
    /// MCP, so OpenCode reads the user's own configuration and folders as it does when used
    /// directly. Playhouse never changes the user's files.
    package static func serverEnvironment(dataDirectoryOverride: String?) -> [String: String] {
        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = ClaudeCodeClient.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        // Playhouse updates the CLI through the composer's install button, not mid-turn.
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        return environment
    }

    /// Runs a short OpenCode command and returns its output, or nil when it fails.
    package static func run(_ executable: String, _ arguments: [String], environment: [String: String], timeout: TimeInterval = 20) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = environment
        environment["PATH"] = ClaudeCodeClient.expandedSearchPath(environment["PATH"])
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
