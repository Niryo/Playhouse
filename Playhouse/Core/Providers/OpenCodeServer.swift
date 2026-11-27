import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A shared `opencode serve` that outlives the daemon that started it: it listens on a loopback
/// port behind a password only this manifest records, so the next daemon of the same service
/// reconnects to it and follows the turns it still runs.
package struct OpenCodeServerManifest: Codable, Equatable {
    /// A turn the server runs, with what a later daemon needs to carry it on.
    package struct Turn: Codable, Equatable {
        /// The prompt's inbox ID: the turn's events come after OpenCode delivers it.
        package var promptMessageID: String
        package var mode: String
        package var readOnly: Bool
        package var cwd: String
        /// Text parts (`<assistant message>:<ordinal>`) already recorded in Playhouse's history.
        package var recordedTextIDs: [String] = []
        package var startedAt: Date

        package init(promptMessageID: String, mode: String, readOnly: Bool, cwd: String, recordedTextIDs: [String] = [], startedAt: Date) {
            self.promptMessageID = promptMessageID
            self.mode = mode
            self.readOnly = readOnly
            self.cwd = cwd
            self.recordedTextIDs = recordedTextIDs
            self.startedAt = startedAt
        }
    }

    package var version = 1
    package var serviceName: String
    package var keyHash: String
    /// `spawning` until the server's identity and port are recorded, then `running`.
    package var state: String
    package var process: AgentProcessIdentity?
    package var createdAt: Date
    package var port: Int?
    package var password: String
    package var resolvedExecutablePath: String
    package var openCodeVersion: String?
    package var turns: [String: Turn] = [:]

    package init(version: Int = 1, serviceName: String, keyHash: String, state: String, process: AgentProcessIdentity? = nil, createdAt: Date, port: Int? = nil, password: String, resolvedExecutablePath: String, openCodeVersion: String? = nil, turns: [String: Turn] = [:]) {
        self.version = version
        self.serviceName = serviceName
        self.keyHash = keyHash
        self.state = state
        self.process = process
        self.createdAt = createdAt
        self.port = port
        self.password = password
        self.resolvedExecutablePath = resolvedExecutablePath
        self.openCodeVersion = openCodeVersion
        self.turns = turns
    }
}

/// Where a shared server's files live, and how one is started.
package struct OpenCodeSharedServer {
    package let runDirectory: URL
    package let keyHash: String
    package let serviceName: String

    package static func runsDirectory(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("opencode-runs", isDirectory: true)
    }

    package static func keyHash(parts: [String], serviceName: String) -> String {
        let digest = Hashing.sha256(Data((parts + [serviceName]).joined(separator: "\u{1}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    package var manifestURL: URL { runDirectory.appendingPathComponent("\(keyHash).json") }
    package var logURL: URL { runDirectory.appendingPathComponent("\(keyHash).log") }
    package var lockPath: String { runDirectory.appendingPathComponent("\(keyHash).owner.lock").path }

    package func readManifest() -> OpenCodeServerManifest? {
        AgentManifestFile.read(OpenCodeServerManifest.self, from: manifestURL)
    }

    package func writeManifest(_ manifest: OpenCodeServerManifest) throws {
        try AgentManifestFile.write(manifest, to: manifestURL)
    }

    package func removeFiles() {
        for url in [manifestURL, logURL] { try? FileManager.default.removeItem(at: url) }
    }

    /// Starts `opencode serve` on a free loopback port and waits for it to report the port. The
    /// manifest is written before the spawn, so a daemon killed in between leaves a `spawning`
    /// entry the orphan sweep can match.
    package func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        resolvedExecutablePath: String,
        openCodeVersion: String?
    ) async throws -> OpenCodeServerManifest {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(runDirectory.path, 0o700)
        try? FileManager.default.removeItem(at: logURL)
        let password = Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        var manifest = OpenCodeServerManifest(
            serviceName: serviceName, keyHash: keyHash, state: "spawning", process: nil, createdAt: Date(), port: nil,
            password: password, resolvedExecutablePath: resolvedExecutablePath, openCodeVersion: openCodeVersion
        )
        try writeManifest(manifest)
        var environment = environment
        environment["OPENCODE_PASSWORD"] = password
        let identity = try AgentRunHost.spawn(
            executable: executable,
            arguments: arguments + ["serve", "--hostname", "127.0.0.1", "--port", "0"],
            environment: environment,
            workingDirectory: runDirectory.path,
            stdin: .path("/dev/null", flags: O_RDONLY),
            stdout: .path(logURL.path, flags: O_WRONLY | O_CREAT | O_APPEND),
            stderr: .path(logURL.path, flags: O_WRONLY | O_CREAT | O_APPEND)
        )
        manifest.process = identity
        try writeManifest(manifest)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let port = Self.listeningPort(in: logURL) {
                manifest.port = port
                manifest.state = "running"
                try writeManifest(manifest)
                return manifest
            }
            guard identity.isAlive else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let tail = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        await AgentRunHost.terminate(identity)
        removeFiles()
        let detail = tail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).suffix(3).joined(separator: " ")
        throw OpenCodeClient.classifyFailure(
            OpenCodeClient.ClientError.processStart(detail.isEmpty ? "`opencode serve` didn't start listening." : detail), text: tail
        )
    }

    /// The port in OpenCode's `Server listening on http://127.0.0.1:<port>` line.
    package static func listeningPort(in log: URL) -> Int? {
        guard let text = try? String(contentsOf: log, encoding: .utf8),
              let range = text.range(of: "listening on http://127.0.0.1:") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Every server manifest `serviceName` left in `runsDirectory` (every service's, for nil).
    package static func manifests(in runsDirectory: URL, serviceName: String?) -> [(server: OpenCodeSharedServer, manifest: OpenCodeServerManifest)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }.compactMap { url in
            guard let manifest = AgentManifestFile.read(OpenCodeServerManifest.self, from: url),
                  serviceName == nil || manifest.serviceName == serviceName else { return nil }
            return (OpenCodeSharedServer(runDirectory: runsDirectory, keyHash: manifest.keyHash, serviceName: manifest.serviceName), manifest)
        }
    }

    package init(runDirectory: URL, keyHash: String, serviceName: String) {
        self.runDirectory = runDirectory
        self.keyHash = keyHash
        self.serviceName = serviceName
    }
}

/// The daemon's connection to one shared `opencode serve`: its HTTP API and the one event
/// stream every turn on it reads. Turns subscribe before they prompt, so none misses its start.
@MainActor
package final class OpenCodeServerConnection {
    package typealias ClientError = OpenCodeClient.ClientError

    /// One connection per server, shared by every client of the daemon (helper turns included).
    package static var connections: [String: OpenCodeServerConnection] = [:]

    package let server: OpenCodeSharedServer
    package private(set) var manifest: OpenCodeServerManifest
    package var ownership: AgentOwnershipLock?
    private var subscribers: [UUID: ([String: Any]) -> Void] = [:]
    private var eventTask: Task<Void, Never>?
    private var connectedWaiters: [CheckedContinuation<Void, Error>] = []
    package private(set) var isStreamConnected = false
    private var exitSource: ProcessExitWatch?
    private var idleTask: Task<Void, Never>?
    package var lastActivity = Date()
    package var isStopped = false
    private let session: URLSession

    package static func key(_ server: OpenCodeSharedServer) -> String { server.runDirectory.standardizedFileURL.path + "\u{1}" + server.keyHash }

    package init(server: OpenCodeSharedServer, manifest: OpenCodeServerManifest, ownership: AgentOwnershipLock?) {
        self.server = server
        self.manifest = manifest
        self.ownership = ownership
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7 * 24 * 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: configuration)
        if let identity = manifest.process {
            exitSource = AgentRunHost.onExit(identity) { [weak self] _ in
                Task { @MainActor in self?.serverDidExit() }
            }
        }
        startIdleWatch()
    }

    package var processIdentifier: Int32 { manifest.process?.pid ?? -1 }
    package var isAlive: Bool { !isStopped && manifest.process?.isAlive == true }
    package var openCodeVersion: String? { manifest.openCodeVersion }

    // MARK: - HTTP

    package var baseURL: URL { URL(string: "http://127.0.0.1:\(manifest.port ?? 0)")! }

    package var authorization: String {
        "Basic " + Data("opencode:\(manifest.password)".utf8).base64EncodedString()
    }

    /// Calls the server's API and returns its decoded JSON (nil for an empty answer). A missing
    /// session throws `sessionNotFound`; another refusal throws its message.
    @discardableResult
    package func request(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil, timeout: TimeInterval = 60) async throws -> Any? {
        guard isAlive else { throw ClientError.processExited("The OpenCode server stopped.") }
        lastActivity = Date()
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.percentEncodedQueryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: Self.encode($0.key), value: Self.encode($0.value))
            }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw isAlive ? ClientError.protocolFailure(error.localizedDescription) : ClientError.processExited("The OpenCode server stopped.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard (200..<300).contains(status) else {
            let error = object as? [String: Any] ?? [:]
            let message = error["message"] as? String ?? String(decoding: data.prefix(500), as: UTF8.self)
            if error["_tag"] as? String == "SessionNotFoundError" { throw ClientError.sessionNotFound }
            throw OpenCodeClient.classifyFailure(ClientError.protocolFailure(message.isEmpty ? "OpenCode answered \(status)." : message), text: message)
        }
        return object
    }

    /// The `data` object of a response.
    package func data(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil) async throws -> [String: Any] {
        (try await request(method, path, query: query, body: body) as? [String: Any])?["data"] as? [String: Any] ?? [:]
    }

    /// Every message of a session, oldest first, read a page at a time (OpenCode answers at most
    /// 200 per request).
    package func messages(_ sessionID: String) async throws -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<50 {
            // A cursor carries the page's order; OpenCode refuses both together.
            let query = cursor.map { ["cursor": $0, "limit": "200"] } ?? ["order": "asc", "limit": "200"]
            let page = try await request("GET", "api/session/\(sessionID)/message", query: query) as? [String: Any] ?? [:]
            messages += page["data"] as? [[String: Any]] ?? []
            cursor = (page["cursor"] as? [String: Any])?["next"] as? String
            guard cursor != nil else { break }
        }
        return messages
    }

    package static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    package static func location(_ directory: String) -> [String: String] { ["location[directory]": directory] }

    // MARK: - Events

    /// Receives every event the server sends until `unsubscribe`. The stream is open once this
    /// returns, so an event a request made afterwards causes is delivered.
    package func subscribe(_ handler: @escaping ([String: Any]) -> Void) async throws -> UUID {
        let id = UUID()
        subscribers[id] = handler
        do {
            try await waitForStream()
        } catch {
            subscribers.removeValue(forKey: id)
            throw error
        }
        return id
    }

    package func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        lastActivity = Date()
    }

    package var hasSubscribers: Bool { !subscribers.isEmpty }

    private func waitForStream() async throws {
        if isStreamConnected { return }
        startEventStream()
        try await withCheckedThrowingContinuation { continuation in
            connectedWaiters.append(continuation)
        }
    }

    private func startEventStream() {
        guard eventTask == nil, isAlive else {
            if !isAlive { failWaiters(ClientError.processExited("The OpenCode server stopped.")) }
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/event"), timeoutInterval: 7 * 24 * 3600)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = self.session
        eventTask = Task { @MainActor [weak self] in
            do {
                #if canImport(FoundationNetworking)
                // swift-corelibs-foundation can't stream a response body; a Linux port reads the
                // server-sent events through its own HTTP client here.
                throw ClientError.protocolFailure("This platform can't stream OpenCode's events yet.")
                #else
                let (bytes, response) = try await session.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ClientError.protocolFailure("OpenCode refused its event stream.")
                }
                for try await line in bytes.lines {
                    guard let self else { return }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                    self.dispatch(event)
                }
                self?.streamEnded(nil)
                #endif
            } catch {
                self?.streamEnded(error)
            }
        }
    }

    private func dispatch(_ event: [String: Any]) {
        lastActivity = Date()
        if event["type"] as? String == "server.connected" {
            let reconnected = !isStreamConnected && !subscribers.isEmpty && connectedWaiters.isEmpty
            isStreamConnected = true
            let waiters = connectedWaiters
            connectedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if reconnected { broadcast(["type": "playhouse.stream.reconnected"]) }
            return
        }
        broadcast(event)
    }

    private func broadcast(_ event: [String: Any]) {
        for handler in subscribers.values { handler(event) }
    }

    /// The stream closed: it reopens while turns listen, and they check what they missed.
    private func streamEnded(_ error: Error?) {
        eventTask = nil
        isStreamConnected = false
        guard isAlive else {
            failWaiters(ClientError.processExited("The OpenCode server stopped."))
            broadcast(["type": "playhouse.server.exited"])
            return
        }
        guard !subscribers.isEmpty || !connectedWaiters.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.startEventStream()
        }
    }

    private func failWaiters(_ error: Error) {
        let waiters = connectedWaiters
        connectedWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    // MARK: - Turns the server runs

    package func recordTurn(_ sessionID: String, _ turn: OpenCodeServerManifest.Turn?) {
        guard manifest.turns[sessionID] != turn else { return }
        manifest.turns[sessionID] = turn
        try? server.writeManifest(manifest)
    }

    package func noteRecordedText(_ sessionID: String, _ textID: String) {
        guard var turn = manifest.turns[sessionID], !turn.recordedTextIDs.contains(textID) else { return }
        turn.recordedTextIDs.append(textID)
        recordTurn(sessionID, turn)
    }

    // MARK: - Lifetime

    /// How long a server may sit with no turn and no request before it is stopped.
    package static var idleSeconds: TimeInterval {
        let environment = PlayhouseProcessEnvironment.current
        return (environment["PLAYHOUSE_E2E_OPENCODE_SERVER_IDLE_SECONDS"] ?? environment["PLAYHOUSE_OPENCODE_SERVER_IDLE_SECONDS"])
            .flatMap(TimeInterval.init) ?? 600
    }

    package var hasWork: Bool { !subscribers.isEmpty || !manifest.turns.isEmpty || !connectedWaiters.isEmpty }

    private func startIdleWatch() {
        idleTask?.cancel()
        let interval = max(1, min(30, Self.idleSeconds / 4))
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !self.isStopped else { return }
                if await self.stopIfIdle() { return }
            }
        }
    }

    /// Stops the server when nothing has used it for `idleSeconds` (at once with `force`). A
    /// server with a turn keeps running, so the next daemon reconnects to it.
    @discardableResult
    package func stopIfIdle(force: Bool = false) async -> Bool {
        guard !isStopped, !hasWork else { return false }
        guard force || Date().timeIntervalSince(lastActivity) >= Self.idleSeconds else { return false }
        // A shell OpenCode moved to the background keeps the server, as a turn does.
        if await hasRunningJobs() {
            lastActivity = Date()
            return false
        }
        guard !hasWork else { return false }
        await stop(reason: force ? "daemon_exit" : "idle")
        return true
    }

    package func hasRunningJobs() async -> Bool {
        let listed = (try? await request("GET", "api/experimental/job", query: ["status": "running"]) as? [String: Any])?["data"] as? [[String: Any]]
        return !(listed ?? []).isEmpty
    }

    /// The connection to a live server a manifest records, made once per daemon: a server a
    /// previous daemon started is adopted, so its idle stop runs here and this connection is the
    /// only writer of its manifest.
    package static func adopt(_ server: OpenCodeSharedServer, manifest: OpenCodeServerManifest) -> OpenCodeServerConnection? {
        let key = key(server)
        if let existing = connections[key], existing.isAlive { return existing }
        guard manifest.state == "running", manifest.port != nil, manifest.process?.isAlive == true else { return nil }
        let connection = OpenCodeServerConnection(server: server, manifest: manifest, ownership: try? AgentOwnershipLock.tryAcquire(path: server.lockPath))
        connections[key] = connection
        PlayhouseDiagnostics.record("opencode.server.adopted", fields: ["processID": String(connection.processIdentifier)])
        return connection
    }

    package func stop(reason: String) async {
        guard !isStopped else { return }
        PlayhouseDiagnostics.record("opencode.server.stopping", fields: ["reason": reason, "processID": String(processIdentifier)])
        isStopped = true
        idleTask?.cancel()
        eventTask?.cancel()
        eventTask = nil
        if let identity = manifest.process { await AgentRunHost.terminate(identity) }
        serverDidExit()
    }

    private func serverDidExit() {
        isStopped = true
        exitSource?.cancel()
        exitSource = nil
        idleTask?.cancel()
        server.removeFiles()
        ownership?.release()
        ownership = nil
        failWaiters(ClientError.processExited("The OpenCode server stopped."))
        broadcast(["type": "playhouse.server.exited"])
        if Self.connections[Self.key(server)] === self { Self.connections.removeValue(forKey: Self.key(server)) }
        PlayhouseDiagnostics.record("opencode.server.exited", fields: ["processID": String(processIdentifier)])
    }

    /// Before an idle daemon exits: every server with nothing to do stops; one running a turn
    /// keeps going, and the next daemon reconnects to it.
    package static func stopIdleServersBeforeExit() async {
        for connection in Array(connections.values) { await connection.stopIfIdle(force: true) }
    }
}
