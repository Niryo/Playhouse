import Foundation
import AppKit
import SwiftData
import Darwin

extension CodexAppServerClient {
    func processDidTerminate(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        transportDidStop(terminatedProcess, detail: "Codex CLI exited with status \(terminatedProcess.terminationStatus).", fields: [
            "codexPID": String(terminatedProcess.processIdentifier),
            "exitStatus": String(terminatedProcess.terminationStatus),
        ])
    }

    /// Whether this client can talk to its app-server now: its stdio child runs, or its socket
    /// connection is open to a live shared server.
    var transportIsRunning: Bool {
        if let socketConnection {
            return socketConnection.isOpen && serverManifest?.process?.isAlive == true
        }
        return process?.isRunning == true
    }

    /// What a question's asker is compared against: the stdio child or the socket connection.
    var transportToken: AnyObject? { socketConnection ?? process }

    /// Connects to this key's shared app-server, starting one when none runs. A server left by
    /// a previous daemon of this service is reused, so its running turns carry on.
    func connectSharedServer(_ server: CodexSharedServer, workspaceURL: URL) async throws {
        guard let executablePath = Self.findCodexExecutable(override: codexExecutableOverride) else {
            throw ClientError.cliNotFound
        }
        appliedSkillExtraRoots = []
        if serverOwnership == nil {
            // Waits only for a predecessor daemon that is still exiting.
            serverOwnership = try await AgentOwnershipLock.acquire(path: server.lockPath, timeout: 15)
        }
        let flags = sharedServerFlags
        let resolvedExecutable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        var manifest = server.readManifest()
        if let existing = manifest, existing.process?.isAlive != true {
            // A server that died (or a spawn its daemon never finished) leaves only files.
            if let process = existing.process { await AgentRunHost.terminate(process) }
            server.removeFiles(socketPath: existing.socketPath)
            manifest = nil
        }
        if manifest == nil {
            let command = ConversationProviderFixture.launchCommand(executable: executablePath, arguments: ["app-server"] + flags)
            do {
                manifest = try server.spawn(
                    executable: command.executable, arguments: command.arguments, environment: launchEnvironment(),
                    workingDirectory: workspaceURL.path, resolvedExecutablePath: resolvedExecutable,
                    flags: flags, codexHome: codexHomeOverride
                )
            } catch {
                throw ClientError.processStart(error.localizedDescription)
            }
            PlayhouseDiagnostics.record("codex.app_server.started", fields: diagnosticFields([
                "executable": executablePath,
                "workingDirectory": workspaceURL.path,
                "processID": String(manifest?.process?.pid ?? -1),
                "transport": "socket",
            ]))
        }
        guard let manifest, let identity = manifest.process else { throw ClientError.processStart("The Codex app-server did not start.") }
        // A server keyed before one app-server served every caller is only kept for a turn it
        // still runs: the current client for its Codex home runs everything else.
        isRetiringServer = manifest.resolvedExecutablePath != resolvedExecutable || manifest.flags != flags
            || server.keyParts.count != Self.keyPartCount
        let connection: CodexSocketConnection
        do {
            connection = try await CodexSharedServer.connect(to: manifest, timeout: 20)
        } catch {
            if !identity.isAlive { server.removeFiles(socketPath: manifest.socketPath) }
            throw ClientError.processStart(error.localizedDescription)
        }
        serverManifest = manifest
        socketConnection = connection
        stdoutBuffer.removeAll(keepingCapacity: true)
        let requestContext = PlayhouseRequestContext.capture()
        let pump = ProviderOutputPump(label: "codex") { [weak self, weak connection] item in
            await requestContext.run {
                switch item {
                case .output(let data): await self?.consumeOutput(data, from: connection)
                case .exit: break
                case .ended:
                    guard let self, let connection else { return }
                    let serverAlive = self.serverManifest?.process?.isAlive == true
                    self.transportDidStop(connection, detail: serverAlive
                        ? "The connection to the Codex app-server closed."
                        : "The Codex app-server stopped.", fields: ["codexPID": String(identity.pid)])
                    if !serverAlive { self.serverDidExit(identity) }
                }
            }
        }
        outputPump = pump
        connection.start(onMessage: { message in
            pump.push(.output(message + Data([0x0A])))
        }, onClose: {
            pump.push(.ended(nil))
        })
        serverExitSource?.cancel()
        serverExitSource = AgentRunHost.onExit(identity) { _ in
            // The server's exit closes its end of the socket, and the reader reports the close
            // once it has read everything the server wrote before exiting. Shutting the socket
            // down at once would discard what is still unread, such as a question or a final
            // message followed by a quick exit, reporting a crash that lost it. Only a socket
            // something else still holds open is shut down, a moment later.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { connection.shutdownConnection() }
        }
        lastServerActivity = Date()
        startIdleServerWatch()
        PlayhouseDiagnostics.record("codex.app_server.connected", fields: diagnosticFields([
            "processID": String(identity.pid),
            "retiring": String(isRetiringServer),
        ]))
    }

    /// How long a shared server may sit with nothing to do before it is stopped.
    static var idleServerSeconds: TimeInterval {
        // Tests shorten it through the one variable family a test request forwards.
        let environment = PlayhouseProcessEnvironment.current
        return (environment["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS"] ?? environment["PLAYHOUSE_CODEX_SERVER_IDLE_SECONDS"])
            .flatMap(TimeInterval.init) ?? 600
    }

    /// Nothing a user waits on: no turn running or starting, no question, no operation, and
    /// no Goal this client follows. An active Goal nobody follows is checked with the server.
    /// A question no conversation here owns is ignored, not added to `pendingUserInputs`, so
    /// it never counts: the idle stop stays the backstop for a question nobody will answer.
    var serverHasLocalWork: Bool {
        !turnContexts.isEmpty || !startingThreadIDs.isEmpty || !pendingUserInputs.isEmpty || !contextlessTurnIDs.isEmpty || !plainTurns.isEmpty
            || goalObservationThreadID != nil || conversationOperationsInFlight > 0 || initializationTask != nil
    }

    func serverHasActiveGoal() async -> Bool {
        for threadID in serverManifest?.threads.keys.sorted() ?? [] {
            guard let response = try? await request(method: "thread/goal/get", params: ["threadId": threadID]) else { continue }
            if (response["goal"] as? [String: Any]).flatMap(Self.decodeGoal)?.status == "active" { return true }
        }
        return false
    }

    /// Stops the shared server when it has been idle long enough, or right away when it is
    /// retiring (or `force`). A server with work keeps running. Returns whether it stopped.
    @discardableResult
    func stopSharedServerIfIdle(force: Bool = false) async -> Bool {
        guard persistentServer != nil, serverManifest != nil, !serverHasLocalWork else { return false }
        let idleFor = Date().timeIntervalSince(lastServerActivity)
        guard force || isRetiringServer || idleFor >= Self.idleServerSeconds else { return false }
        guard transportIsRunning, !(await serverHasActiveGoal()) else { return false }
        guard !serverHasLocalWork else { return false }
        await stopSharedServer(reason: isRetiringServer ? "retiring" : (force ? "daemon_exit" : "idle"))
        return true
    }

    func stopSharedServer(reason: String) async {
        guard let persistentServer, let manifest = serverManifest else { return }
        PlayhouseDiagnostics.record("codex.app_server.stopping", fields: diagnosticFields(["reason": reason]))
        if let token = transportToken { transportDidStop(token, detail: "The Codex app-server was stopped.", fields: ["reason": reason]) }
        if let identity = manifest.process { await AgentRunHost.terminate(identity) }
        persistentServer.removeFiles(socketPath: manifest.socketPath)
        serverManifest = nil
        serverExitSource?.cancel()
        serverExitSource = nil
        serverOwnership?.release()
        serverOwnership = nil
    }

    func startIdleServerWatch() {
        idleShutdownTask?.cancel()
        let interval = max(1, min(30, Self.idleServerSeconds / 4))
        idleShutdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, self.serverManifest != nil else { return }
                if await self.stopSharedServerIfIdle() { return }
            }
        }
    }

    /// Before an idle daemon exits: every shared server with nothing to do stops, so none is
    /// left behind. One running a turn, a question or an active Goal keeps going, and the
    /// next daemon reconnects to it.
    static func stopIdleSharedServersBeforeExit() async {
        for client in allSharedClients { await client.stopSharedServerIfIdle(force: true) }
    }

    /// The flags every app-server of this client starts with. Goals are always on, since a
    /// window and the CLI share the server; whether a caller follows Goal turns is per request.
    var sharedServerFlags: [String] {
        ["--disable", "apps", "--disable", "remote_plugin", "--disable", "hooks", "-c", "features.goals=true"]
    }

    func launchEnvironment() -> [String: String] {
        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        if let codexHomeOverride {
            // Codex refuses to start with a home that doesn't exist yet.
            try? FileManager.default.createDirectory(atPath: codexHomeOverride, withIntermediateDirectories: true)
            environment["CODEX_HOME"] = codexHomeOverride
        }
        return environment
    }

    /// The shared server exited: its files go, and the next call starts a fresh one.
    func serverDidExit(_ identity: AgentProcessIdentity) {
        guard let persistentServer, serverManifest?.process == identity || serverManifest == nil else { return }
        persistentServer.removeFiles(socketPath: serverManifest?.socketPath)
        serverManifest = nil
        serverExitSource?.cancel()
        serverExitSource = nil
    }

    /// Records the threads this server has open, so a later daemon knows what it serves.
    func recordServedThread(_ threadID: String, _ parameters: ResumeParameters) {
        guard let persistentServer, var manifest = serverManifest else { return }
        let thread = CodexServerManifest.Thread(
            modelID: parameters.modelID, cwd: parameters.cwd, roots: parameters.roots,
            developerInstructions: parameters.developerInstructions, mcpServers: parameters.mcpServers
        )
        guard manifest.threads[threadID] != thread else { return }
        manifest.threads[threadID] = thread
        serverManifest = manifest
        try? persistentServer.writeManifest(manifest)
    }

    /// The connection or child this client used stopped: everything waiting on it fails.
    func transportDidStop(_ token: AnyObject, detail: String, fields extraFields: [String: String]) {
        guard token === transportToken else { return }

        for key in Array(deltaLogSummaries.keys) { flushDeltaLogSummary(for: key, reason: "app_server_exit") }

        let exitDetail = detail
        pendingUserInputs.removeAll()
        pendingUserInputRequest = nil
        PlayhouseDiagnostics.record("codex.app_server.exited", fields: diagnosticFields(extraFields.merging([
            "activeThreadID": activeThreadID ?? "",
            "activeTurnID": activeTurnID ?? "",
        ]) { _, new in new }))
        let error = ClientError.processExited(exitDetail)
        for pending in pendingCompactions.values { pending.result = .failure(error) }
        for plain in plainTurns.values { plain.finish(status: "failed", error: exitDetail) }
        plainTurns.removeAll()
        mcpCallThread?.idle?.cancel()
        mcpCallThread = nil
        process = nil
        inputPipe = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        stderrPipe = nil
        socketConnection?.shutdownConnection()
        socketConnection = nil
        initialized = false
        resumedThreadParameters.removeAll()
        activeThreadID = nil
        contextlessTurnIDs.removeAll()
        contextlessTurnEntries.removeAll()
        runningTurnThreadIDs.removeAll()
        threadStatuses.removeAll()

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

    func confirmModel(_ model: String?, expected: String) throws {
        guard let model else {
            throw ClientError.protocolFailure("Codex did not report which model it selected.")
        }
        guard model == expected else {
            throw ClientError.modelMismatch(model, expected)
        }
    }
}
