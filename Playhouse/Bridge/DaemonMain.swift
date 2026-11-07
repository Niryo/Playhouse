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
    private var inFlightRequests = 0
    private var idleWorkItem: DispatchWorkItem?
    private let gracePeriod: TimeInterval

    init(gracePeriod: TimeInterval = 10) {
        self.gracePeriod = gracePeriod
    }

    func connectionOpened() {
        lock.lock()
        openConnections += 1
        cancelIdleTimerLocked()
        lock.unlock()
    }

    func connectionClosed() {
        lock.lock()
        openConnections = max(0, openConnections - 1)
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
        daemonLog("idle, exiting")
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
            .union(["PLAYHOUSE_BRIDGE_SERVICE_NAME", "PLAYHOUSE_BRIDGE_SOCKET_PATH", "PLAYHOUSE_BRIDGE_IDLE_GRACE_SECONDS"])
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
        // A client that disconnects mid-turn, or a provider child that exits,
        // must surface as a write error, not kill every other conversation.
        signal(SIGPIPE, SIG_IGN)
        reduceToSessionEnvironment()
        let environment = ProcessInfo.processInfo.environment
        // Same override the CLI already honors today (`PLAYHOUSE_BRIDGE_SERVICE_NAME`),
        // so existing per-test isolation keeps working unchanged. Otherwise, since
        // this binary lives at `Contents/MacOS/playhouse-daemon` inside the app
        // bundle (same as `playhouse-cli`), `Bundle.main` resolves to the same
        // app identity the GUI process itself has — no separate Info.plist needed.
        let serviceName = environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
            ?? BridgeContract.serviceName(forApplication: PlayhouseAppIdentity.applicationIdentifier)
        let socketURL = environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"].map { URL(fileURLWithPath: $0) }
            ?? BridgeContract.socketURL(forServiceName: serviceName)

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
                lifecycle.connectionOpened()
                Thread.detachNewThread {
                    handleConnection(connection, lifecycle: lifecycle)
                }
            }
        }
        acceptThread.name = "playhouse-daemon.accept"
        acceptThread.start()
        // A scheduled turn a tick starts runs on after the tick's request ends.
        BridgeBackgroundWork.onBegin = { lifecycle.requestStarted() }
        BridgeBackgroundWork.onEnd = { lifecycle.requestFinished() }
        startScheduleTicker(environment: environment)
        RunLoop.current.run()
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
    private static func handleConnection(_ connection: BridgeSocketConnection, lifecycle: DaemonLifecycle) {
        defer {
            connection.shutdown()
            connection.close()
            lifecycle.connectionClosed()
        }

        var buffer = Data()
        let request: BridgeRequest
        do {
            guard let first = try connection.readMessages(as: BridgeRequest.self, buffer: &buffer).first else { return }
            request = first
        } catch {
            return
        }

        lifecycle.requestStarted()
        defer { lifecycle.requestFinished() }

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

        guard let response = responseBox.response,
              let framed = try? BridgeFraming.frame(BridgeWireMessage.response(response)) else { return }
        try? connection.write(framed)
    }

    /// A plain reference box to hand a value out of the `@MainActor` task above
    /// without requiring the box itself to be `Sendable`-checked as a closure
    /// capture of a `var`.
    private final class ResponseBox: @unchecked Sendable {
        var response: BridgeResponse?
    }
}
