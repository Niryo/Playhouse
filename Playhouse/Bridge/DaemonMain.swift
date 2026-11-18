import Darwin
import Foundation

/// One stderr line with time and pid; the spawner routes stderr to the socket's `.log`.
func daemonLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) playhouse-daemon[\(ProcessInfo.processInfo.processIdentifier)]: \(message)\n".utf8))
}

/// Tracks how many connections are open and how many `PlayhouseBridgeRuntime
/// .perform` calls are still running, and exits the process once both are zero
/// for a short grace period. This is what gives the daemon "runs only when
/// needed, never a ghost process" behavior, in place of `launchd`'s `KeepAlive`.
/// A dropped connection does not, by itself, end an in-flight request: a turn
/// started from the GUI keeps running (and keeps `inFlightRequests` above
/// zero) even if the GUI quits mid-turn.
final class DaemonLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var openConnections = 0
    /// Connections accepted after a shutdown began, which are only ever refused, and when the last arrived.
    private var lateConnections = 0
    private var lastLateConnection = Date.distantPast
    private var inFlightRequests = 0
    private var idleWorkItem: DispatchWorkItem?
    private let gracePeriod: TimeInterval
    /// Runs before an idle exit, off the main thread, and returns once it finished.
    var beforeIdleExit: (() -> Void)?
    /// Removes the socket path, so later callers start the daemon that follows this one.
    var releaseSocketPath: (() -> Void)?

    init(gracePeriod: TimeInterval = 10) {
        self.gracePeriod = gracePeriod
    }

    /// Returns whether the connection arrived after a shutdown began.
    func connectionOpened() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        openConnections += 1
        cancelIdleTimerLocked()
        if stopping {
            lateConnections += 1
            lastLateConnection = Date()
        }
        return stopping
    }

    func connectionClosed(late: Bool) {
        lock.lock()
        openConnections = max(0, openConnections - 1)
        if late { lateConnections = max(0, lateConnections - 1) }
        scheduleIdleExitIfNeededLocked()
        lock.unlock()
    }

    func requestStarted() {
        lock.lock()
        inFlightRequests += 1
        cancelIdleTimerLocked()
        lock.unlock()
    }

    func requestFinished() {
        lock.lock()
        inFlightRequests = max(0, inFlightRequests - 1)
        scheduleIdleExitIfNeededLocked()
        lock.unlock()
    }

    /// Caller already holds `lock`.
    private func cancelIdleTimerLocked() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
    }

    /// Caller already holds `lock`.
    private func scheduleIdleExitIfNeededLocked() {
        guard openConnections == 0, inFlightRequests == 0 else { return }
        idleWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.exitIfStillIdle() }
        idleWorkItem = workItem
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod, execute: workItem)
    }

    private func exitIfStillIdle() {
        lock.lock()
        let stillIdle = openConnections == 0 && inFlightRequests == 0
        lock.unlock()
        guard stillIdle else { return }
        // Agents outlive the daemon only while they have work: idle ones are stopped first.
        beforeIdleExit?()
        lock.lock()
        let idleAfterCleanup = openConnections == 0 && inFlightRequests == 0
        lock.unlock()
        guard idleAfterCleanup else { return }
        daemonLog("idle, exiting")
        exit(0)
    }

    /// Set once a shutdown began: new requests are turned away from then on.
    var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }
    private var stopping = false
    /// Set once a shutdown hands its agents over: a request those agents still
    /// answer is left to the next daemon, so its caller sees the connection
    /// drop rather than a failure from this one.
    var isAbandoningRequests: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoning
    }
    private var abandoning = false

    /// Leaves on request. New requests are answered `daemon_exiting` from now
    /// on, so their callers wait for this daemon to go and start the next one,
    /// rather than reaching a daemon that drops them, or starting a second
    /// daemon while this one still hands its agents over. Quick requests on open
    /// connections get a moment to be answered; a turn's streaming connection
    /// stays open, so this doesn't wait for it to close.
    func shutDown() {
        lock.lock()
        stopping = true
        lock.unlock()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            lock.lock()
            let open = openConnections
            lock.unlock()
            if open == 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock()
        abandoning = true
        lock.unlock()
        beforeIdleExit?()
        // Callers that connected just now are still queued on the socket; exiting at once would
        // drop their requests unanswered. Later callers start the next daemon, and these are
        // refused as exiting, which tells them to send again, before this daemon leaves.
        lock.lock()
        lastLateConnection = Date()
        lock.unlock()
        releaseSocketPath?()
        let drainDeadline = Date().addingTimeInterval(2)
        while Date() < drainDeadline {
            lock.lock()
            let drained = lateConnections == 0 && Date().timeIntervalSince(lastLateConnection) >= 0.1
            lock.unlock()
            if drained { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        daemonLog("released the socket, exiting")
        exit(0)
    }
}

@main
enum PlayhouseBridgeDaemonMain {
    /// The daemon outlives the invocation that happened to start it and serves
    /// every later caller, so it keeps only the login-session variables (as the
    /// launchd-started XPC service it replaced had) plus its own identity. Each
    /// request then overlays its caller's session values; per-invocation
    /// Playhouse settings travel as `BridgeRequest` fields.
    static func reduceToSessionEnvironment() {
        let kept = BridgeContract.sessionEnvironmentNames
            .union(["PLAYHOUSE_BRIDGE_SERVICE_NAME", "PLAYHOUSE_BRIDGE_SOCKET_PATH", "PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS", "PLAYHOUSE_MUTE_SOUNDS"])
        for name in ProcessInfo.processInfo.environment.keys where !kept.contains(name) {
            unsetenv(name)
        }
    }

    /// This request's environment: the daemon's own, with the caller's session
    /// values (its `PATH`, for instance) in place of the daemon's. Note that the
    /// caller (the CLI or the GUI app) already trimmed `request.environment` down
    /// to the names it itself considered forwardable before this ever arrived —
    /// see `BridgeContract.environmentNamesToForward`.
    static func environment(for request: BridgeRequest) -> [String: String] {
        let callerEnvironment = request.environment ?? [:]
        let allowed = BridgeContract.environmentNamesToForward(
            applicationIdentifier: PlayhouseAppIdentity.applicationIdentifier,
            from: callerEnvironment
        )
        let callerSession = callerEnvironment.filter { allowed.contains($0.key) }
        return ProcessInfo.processInfo.environment.merging(callerSession) { _, caller in caller }
    }

    static func main() {
        // The updater's health check: the daemon starts and knows its version.
        if CommandLine.arguments.dropFirst().first == "--version" {
            let info = Bundle.main.infoDictionary ?? [:]
            let version = BridgeValue.object([
                "version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
                "build": .string(info["CFBundleVersion"] as? String ?? ""),
            ])
            if let data = try? BridgeFraming.encoder.encode(version) { print(String(decoding: data, as: UTF8.self)) }
            exit(0)
        }
        // A client that disconnects mid-turn, or a provider child that exits,
        // must surface as a write error, not kill every other conversation.
        signal(SIGPIPE, SIG_IGN)
        reduceToSessionEnvironment()
        _ = launchedIdentity
        _ = launchedVersion
        let environment = ProcessInfo.processInfo.environment
        // Same override the CLI already honors today (`PLAYHOUSE_BRIDGE_SERVICE_NAME`),
        // so existing per-test isolation keeps working unchanged. Otherwise, since
        // this binary lives at `Contents/MacOS/playhouse-daemon` inside the app
        // bundle (same as `playhouse-cli`), `Bundle.main` resolves to the same
        // app identity the GUI process itself has — no separate Info.plist needed.
        let serviceName = environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
            ?? BridgeContract.serviceName(forApplication: PlayhouseAppIdentity.applicationIdentifier)
        AgentRunService.name = serviceName
        let socketURL = environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"].map { URL(fileURLWithPath: $0) }
            ?? BridgeContract.socketURL(forServiceName: serviceName)

        // One daemon serves a socket at a time. A stopping daemon gives up its socket path just
        // before it exits, so a successor a caller starts in that moment waits here, until the
        // other process has exited, before it takes over any agent.
        waitForPredecessorExit(socketPath: socketURL.path)

        let listener: BridgeSocketListener
        do {
            listener = try BridgeSocketListener.listen(at: socketURL.path)
        } catch {
            daemonLog("couldn't listen at \(socketURL.path): \(error)")
            exit(70)
        }
        daemonLog("listening at \(socketURL.path)")

        // How long the daemon lingers with no connection and no running request.
        let lifecycle = environment["PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS"].flatMap(TimeInterval.init).map { DaemonLifecycle(gracePeriod: $0) }
            ?? DaemonLifecycle()
        let acceptThread = Thread {
            while true {
                guard let connection = try? listener.accept() else { continue }
                let late = lifecycle.connectionOpened()
                Thread.detachNewThread {
                    handleConnection(connection, lifecycle: lifecycle, late: late)
                }
            }
        }
        acceptThread.name = "playhouse-daemon.accept"
        acceptThread.start()
        lifecycle.releaseSocketPath = { unlink(socketURL.path) }
        // A scheduled turn a tick starts runs on after the tick's request ends.
        BridgeBackgroundWork.onBegin = { lifecycle.requestStarted() }
        BridgeBackgroundWork.onEnd = { lifecycle.requestFinished() }
        lifecycle.beforeIdleExit = {
            let finished = DispatchSemaphore(value: 0)
            Task { @MainActor in
                await CodexAppServerClient.stopIdleSharedServersBeforeExit()
                await ClaudeCodeClient.stopRunsBeforeExit()
                finished.signal()
            }
            _ = finished.wait(timeout: .now() + 15)
        }
        // The built-in plugins' background halves hear app events here, whether
        // or not a window is open.
        MainActor.assumeIsolated {
            PluginServiceHost.services = [PullRequestModeService()]
        }
        startScheduleTicker(environment: environment)
        RunLoop.current.run()
    }

    /// Takes the socket's instance lock for the life of this process. It is closed on exec, so
    /// the agents this daemon starts never hold it after the daemon exits.
    private static func waitForPredecessorExit(socketPath: String) {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = Darwin.open(socketPath + ".instance.lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let deadline = Date().addingTimeInterval(30)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            // Another successor already took over and serves the socket; this one isn't needed.
            if let live = try? BridgeSocketConnection.connect(to: socketPath) {
                live.close()
                daemonLog("another daemon already serves \(socketPath); exiting")
                exit(0)
            }
            guard Date() < deadline else {
                daemonLog("the previous daemon still holds \(socketPath).instance.lock; starting anyway")
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// While the daemon is up, fires due schedules of the default store every 30
    /// seconds. The ticker itself never keeps the daemon alive: with the app closed,
    /// the scheduler LaunchAgent starts a `schedule tick` each minute instead. Test
    /// bundles keep isolated stores per case and drive ticks explicitly, so they
    /// don't tick here.
    private static func startScheduleTicker(environment: [String: String]) {
        let interval: TimeInterval = 30
        guard !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) else { return }
        Task { @MainActor in
            while true {
                let request = BridgeRequest(command: "schedule.tick", environment: environment)
                let context = PlayhouseRequestContext(environment: environment, scope: PlayhouseDiagnosticsScope())
                _ = await context.run {
                    await PlayhouseBridgeRuntime().perform(request) { _ in }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Runs on its own dedicated thread for the life of one connection: one
    /// blocking read of the request frame, one `perform()` call (bridged onto
    /// the main actor, since every bridge manager is main-actor-isolated),
    /// streaming any event frames back as they're produced, then the final
    /// response frame.
    private static func handleConnection(_ connection: BridgeSocketConnection, lifecycle: DaemonLifecycle, late: Bool) {
        defer {
            connection.shutdown()
            connection.close()
            lifecycle.connectionClosed(late: late)
        }

        var buffer = Data()
        let request: BridgeRequest
        do {
            guard let first = try connection.readMessages(as: BridgeRequest.self, buffer: &buffer).first else { return }
            request = first
        } catch {
            return
        }

        if lifecycle.isStopping {
            daemonLog("refused \(request.command): exiting")
            let response = BridgeResponse.failure(request, code: BridgeContract.daemonExitingCode, message: "The Playhouse bridge daemon is exiting.")
            if let framed = try? BridgeFraming.frame(BridgeWireMessage.response(response)) { try? connection.write(framed) }
            return
        }

        if request.command.hasPrefix("daemon.") {
            handleDaemonCommand(request, over: connection, lifecycle: lifecycle)
            return
        }

        lifecycle.requestStarted()
        defer { lifecycle.requestFinished() }

        // A caller in a read-only sandbox, such as a Codex side chat's CLI call, gets only board
        // requests: the daemon runs outside that sandbox and must not do what the sandbox forbids.
        if !SideChatReadOnlyPolicy.allowsSandboxedRequest(request), let peer = connection.peerProcessID,
           callerIsReadOnlySandboxed(peer) {
            let denied = BridgeResponse.failure(request, code: "forbidden", message: SideChatReadOnlyPolicy.sandboxedCallerMessage)
            if let framed = try? BridgeFraming.frame(BridgeWireMessage.response(denied)) { try? connection.write(framed) }
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = ResponseBox()
        let requestTask = Task { @MainActor in
            // This request's caller environment and its own diagnostics scope,
            // so concurrent or later requests can't redirect either.
            let context = PlayhouseRequestContext(environment: environment(for: request), scope: PlayhouseDiagnosticsScope())
            let response = await context.run {
                await PlayhouseBridgeRuntime().perform(request) { event in
                    guard let framed = try? BridgeFraming.frame(BridgeWireMessage.event(event)) else { return }
                    try? connection.write(framed)
                }
            }
            responseBox.response = response
            semaphore.signal()
        }
        // A turn outlives the window that started it, but a subscription exists
        // only for its window: stop it when the peer goes away. Every streaming
        // command ends in `.subscribe`; one left running holds the daemon awake.
        if request.command.hasSuffix(".subscribe") {
            Thread.detachNewThread {
                while let chunk = try? connection.readAvailable(), !chunk.isEmpty {}
                requestTask.cancel()
            }
        }
        semaphore.wait()

        // Requests still running when the daemon exits fail only because it is
        // going away; the peer reconnects instead of reading that failure.
        guard let response = responseBox.response,
              !(lifecycle.isAbandoningRequests && !response.ok),
              let framed = try? BridgeFraming.frame(BridgeWireMessage.response(response)) else { return }
        try? connection.write(framed)
    }

    /// The executable this daemon started from, read at launch: an update that
    /// replaces the bundle afterwards changes the file at that path, not this.
    static let launchedIdentity = BridgeDaemonIdentity.currentProcess()
    /// Read at startup: an update swaps the bundle under a running daemon, and
    /// it must keep reporting the version it runs.
    static let launchedVersion: (version: String, build: String) = {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "", info["CFBundleVersion"] as? String ?? "")
    }()

    /// The daemon's own lifecycle commands, answered without opening any store.
    /// `daemon.hello` comes from a caller's launcher (see `BridgeDaemonLauncher`);
    /// `daemon.shutdown` from the updater before it replaces the bundle.
    private static func handleDaemonCommand(_ request: BridgeRequest, over connection: BridgeSocketConnection, lifecycle: DaemonLifecycle) {
        let processID = BridgeValue.integer(Int(ProcessInfo.processInfo.processIdentifier))
        var leaving = false
        let response: BridgeResponse
        switch request.command {
        case "daemon.hello":
            let expected = try? request.arguments["expected"]?.decoded(BridgeDaemonIdentity.self)
            if let expected, let launchedIdentity, expected.isReplacement(of: launchedIdentity) {
                leaving = true
                daemonLog("the daemon executable at \(expected.path) was replaced; exiting for the new one")
            }
            response = .success(request, result: .object(["stale": .boolean(leaving), "processID": processID]))
        case "daemon.info":
            response = .success(request, result: .object([
                "processID": processID,
                "executablePath": launchedIdentity.map { .string($0.path) } ?? .null,
                "bridgeVersion": .integer(BridgeContract.currentVersion),
                "appVersion": .string(launchedVersion.version),
                "appBuild": .string(launchedVersion.build),
                "replacedOnDisk": .boolean(launchedIdentity.map { launched in
                    BridgeDaemonIdentity(executablePath: launched.path).map { $0 != launched } ?? true
                } ?? false)
            ]))
        case "daemon.shutdown":
            leaving = true
            daemonLog("shutdown requested")
            response = .success(request, result: .object(["processID": processID]))
        default:
            response = .failure(request, code: "invalid_command", message: "Unknown daemon command \(request.command).")
        }
        if let framed = try? BridgeFraming.frame(BridgeWireMessage.response(response)) {
            try? connection.write(framed)
        }
        guard leaving else { return }
        // Agents with work outlive the daemon as on an idle exit; the next daemon
        // reattaches them. Exits from its own thread so this reply gets out first.
        Thread.detachNewThread { lifecycle.shutDown() }
    }

    /// Whether `pid` runs in a sandbox that forbids it to write even beside the bridge sockets, as
    /// Codex's read-only sandbox does. A sandbox that lets its process write there, such as the
    /// UI test runner's, and a process with no sandbox are not read-only. The sandbox carries
    /// over to every child a process starts, so a sandboxed caller can't shed it.
    private static func callerIsReadOnlySandboxed(_ pid: pid_t) -> Bool {
        guard playhouse_is_sandboxed(pid) == 1 else { return false }
        // The sockets' own directory, which exists while this daemon listens in it.
        let directory = BridgeContract.socketURL(forServiceName: BridgeContract.serviceName)
            .deletingLastPathComponent().resolvingSymlinksInPath()
        return playhouse_sandbox_denies_file_create(pid, directory.path) == 1
    }

    /// A plain reference box to hand a value out of the `@MainActor` task above
    /// without requiring the box itself to be `Sendable`-checked as a closure
    /// capture of a `var`.
    private final class ResponseBox: @unchecked Sendable {
        var response: BridgeResponse?
    }
}
