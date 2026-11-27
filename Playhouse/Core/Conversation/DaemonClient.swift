import Foundation
import Observation

/// A window's channel to the bridge daemon, which owns every provider process,
/// running turn, and queued follow-up. Each call is one request on its own
/// connection, exactly as the CLI sends them, so a window and a command-line
/// call reach the same owner. Starts the daemon on demand.
package final class DaemonClient: @unchecked Sendable {
    package struct Configuration: Sendable {
        package var dataDirectory: String?
        package var defaultsSuite: String?
        package var worktreeDirectory: String?
        package var codexExecutable: String?
        package var claudeExecutable: String?
        package var openCodeExecutable: String?
        package var codexHome: String?
        package var claudeConfigDirectory: String?
        package var serviceName: String
        package var socketPath: String

        package static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            let serviceName = environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
                ?? BridgeContract.serviceName(forApplication: PlayhouseAppIdentity.applicationIdentifier)
            return Configuration(
                dataDirectory: environment["PLAYHOUSE_DATA_DIRECTORY"],
                defaultsSuite: environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"],
                worktreeDirectory: environment["PLAYHOUSE_E2E_WORKTREE_DIRECTORY"],
                codexExecutable: environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"],
                claudeExecutable: environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"],
                openCodeExecutable: environment["PLAYHOUSE_E2E_OPENCODE_EXECUTABLE"],
                codexHome: environment["CODEX_HOME"],
                claudeConfigDirectory: environment["PLAYHOUSE_E2E_CLAUDE_CONFIG_DIR"],
                serviceName: serviceName,
                socketPath: environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] ?? BridgeContract.socketURL(forServiceName: serviceName).path
            )
        }

        package init(dataDirectory: String? = nil, defaultsSuite: String? = nil, worktreeDirectory: String? = nil, codexExecutable: String? = nil, claudeExecutable: String? = nil, openCodeExecutable: String? = nil, codexHome: String? = nil, claudeConfigDirectory: String? = nil, serviceName: String, socketPath: String) {
            self.dataDirectory = dataDirectory
            self.defaultsSuite = defaultsSuite
            self.worktreeDirectory = worktreeDirectory
            self.codexExecutable = codexExecutable
            self.claudeExecutable = claudeExecutable
            self.openCodeExecutable = openCodeExecutable
            self.codexHome = codexHome
            self.claudeConfigDirectory = claudeConfigDirectory
            self.serviceName = serviceName
            self.socketPath = socketPath
        }
    }

    private enum Item {
        case message(BridgeWireMessage)
        case failure(Error)
    }

    /// The live connection of one call, so cancelling the call can wake the
    /// thread blocked reading it.
    private final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: BridgeSocketConnection?
        private var isCancelled = false

        func attach(_ connection: BridgeSocketConnection) {
            lock.lock()
            self.connection = connection
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { connection.shutdown() }
        }

        func detachAndClose() {
            lock.lock()
            let connection = self.connection
            self.connection = nil
            connection?.close()
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            connection?.shutdown()
            lock.unlock()
        }
    }

    package let configuration: Configuration

    package init(configuration: Configuration = .fromEnvironment()) {
        self.configuration = configuration
    }

    /// The daemon ships next to this app's own executable in `Contents/MacOS`.
    private static var daemonExecutablePath: String? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("playhouse-daemon").path
    }

    private func configuredRequest(_ command: String, _ arguments: [String: BridgeValue]) -> BridgeRequest {
        var request = BridgeRequest(command: command, arguments: arguments)
        request.arguments["__guiRuntime"] = .boolean(true)
        if let codex = configuration.codexExecutable { request.arguments["__codexExecutable"] = .string(codex) }
        if let claude = configuration.claudeExecutable { request.arguments["__claudeExecutable"] = .string(claude) }
        if let opencode = configuration.openCodeExecutable { request.arguments["__opencodeExecutable"] = .string(opencode) }
        if let installer = ProcessInfo.processInfo.environment["PLAYHOUSE_E2E_PROVIDER_INSTALLER"], !installer.isEmpty {
            request.arguments["__providerInstaller"] = .string(installer)
        }
        if let codexHome = configuration.codexHome { request.arguments["__codexHome"] = .string(codexHome) }
        if let claudeConfig = configuration.claudeConfigDirectory { request.arguments["__claudeConfigDirectory"] = .string(claudeConfig) }
        // Test overrides for the release feed; the daemon honors them only in a test bundle.
        for (name, argument) in BridgeContract.updateOverrideArguments {
            if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { request.arguments[argument] = .string(value) }
        }
        request.dataDirectory = configuration.dataDirectory
        request.defaultsSuite = configuration.defaultsSuite
        request.worktreeDirectory = configuration.worktreeDirectory
        let forwardableNames = BridgeContract.environmentNamesToForward(
            applicationIdentifier: PlayhouseAppIdentity.applicationIdentifier,
            from: ProcessInfo.processInfo.environment
        )
        request.environment = ProcessInfo.processInfo.environment
            .filter { forwardableNames.contains($0.key) }
        return request
    }

    /// Sends one command and returns its result, delivering streamed events (in
    /// order, on the main actor) as they arrive. Cancelling the calling task
    /// drops the connection; a turn the daemon already started keeps running.
    @MainActor
    @discardableResult
    package func call(
        _ command: String,
        _ arguments: [String: BridgeValue] = [:],
        onEvent: (BridgeEvent) -> Void = { _ in }
    ) async throws -> BridgeValue {
        let request = configuredRequest(command, arguments)
        let configuration = configuration
        let call = Call()
        let (stream, continuation) = AsyncStream<Item>.makeStream()

        Thread.detachNewThread {
            defer {
                call.detachAndClose()
                continuation.finish()
            }
            do {
                // A daemon that is shutting down refuses the request without running it.
                let retryDeadline = Date().addingTimeInterval(30)
                attempts: while true {
                    let connection = try BridgeDaemonLauncher.connect(
                        socketPath: configuration.socketPath,
                        serviceName: configuration.serviceName,
                        daemonExecutablePath: Self.daemonExecutablePath
                    )
                    call.attach(connection)
                    try connection.write(BridgeFraming.frame(request))
                    var buffer = Data()
                    while true {
                        for message in try connection.readMessages(as: BridgeWireMessage.self, buffer: &buffer) {
                            if case .response(let response) = message {
                                if BridgeDaemonLauncher.shouldRetry(response, until: retryDeadline) {
                                    call.detachAndClose()
                                    continue attempts
                                }
                                continuation.yield(.message(message))
                                return
                            }
                            continuation.yield(.message(message))
                        }
                    }
                }
            } catch {
                continuation.yield(.failure(error))
            }
        }

        return try await withTaskCancellationHandler {
            for await item in stream {
                switch item {
                case .message(.event(let event)):
                    onEvent(event)
                case .message(.response(let response)):
                    guard response.ok else {
                        let failure = response.error
                        throw BridgeCommandError(
                            code: failure?.code ?? "operation_failed",
                            message: failure?.message ?? "The Playhouse bridge request failed."
                        )
                    }
                    return response.result ?? .null
                case .failure(let error):
                    if Task.isCancelled { throw CancellationError() }
                    throw DaemonClientError.unavailable(error.localizedDescription)
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw DaemonClientError.unavailable("The Playhouse bridge daemon closed the connection.")
        } onCancel: {
            call.cancel()
        }
    }
}

package enum DaemonClientError: LocalizedError {
    case unavailable(String)

    package var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Couldn't reach the Playhouse bridge daemon. \(reason)"
        }
    }
}

/// What the daemon says about running turns, kept current for the views. This
/// replaces the observable state the window's own provider clients used to hold:
/// the window no longer runs providers, so it watches the daemon that does.
///
/// Reading `snapshot` (or a query that reads it) in a view re-renders that view on every
/// snapshot. The snapshot changes with every turn and revision of every task, so an open
/// conversation reads `untracked` instead and re-renders for its own task's changes through
/// `ConversationRuntimeSliceObserver`.
@MainActor
@Observable
package final class ConversationRuntimeModel {
    /// Bumped with every snapshot; reading `snapshot` observes it.
    private var revision = 0
    @ObservationIgnored private var current = ConversationRuntimeSnapshot()
    @ObservationIgnored package let client: DaemonClient
    @ObservationIgnored private var subscription: Task<Void, Never>?

    package init(client: DaemonClient) {
        self.client = client
    }

    package private(set) var snapshot: ConversationRuntimeSnapshot {
        get {
            _ = revision
            return current
        }
        set {
            current = newValue
            revision &+= 1
        }
    }

    /// This model read without observing it.
    package var untracked: Untracked { Untracked(model: self) }

    /// Follows the daemon's state, reconnecting if it goes away. Turns that were
    /// running in a daemon that has died are not running any more, so the
    /// snapshot is cleared whenever the connection drops.
    package func start() {
        guard subscription == nil else { return }
        subscription = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.client.call("conversation.runtime.subscribe") { event in
                        guard event.type == "runtime_state",
                              let next = try? event.payload.decoded(ConversationRuntimeSnapshot.self) else { return }
                        self.snapshot = next
                    }
                } catch {
                    PlayhouseDiagnostics.record("conversation.runtime.subscription_failed", fields: PlayhouseDiagnostics.errorFields(error))
                }
                self.snapshot = ConversationRuntimeSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    package func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Reads the daemon's state now, for the moment right after a request ended,
    /// when the stream may not have caught up yet.
    package func refresh() async {
        guard let value = try? await client.call("conversation.runtime"),
              let current = try? value.decoded(ConversationRuntimeSnapshot.self) else { return }
        snapshot = current
    }

    package func isTurnActive(threadID: String) -> Bool { snapshot.isTurnActive(threadID: threadID) }
    package func isTurnActive(taskID: UUID) -> Bool { snapshot.isTurnActive(taskID: taskID.uuidString) }
    package func canInterruptActiveTurn(threadID: String) -> Bool { snapshot.canInterruptActiveTurn(threadID: threadID) }
    package func wasLastTurnInterrupted(threadID: String) -> Bool { snapshot.wasLastTurnInterrupted(threadID: threadID) }
    package func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? { snapshot.pendingUserInput[threadID] }
    package func isObservingGoal(threadID: String) -> Bool { snapshot.goal.observedThreadIDs.contains(threadID) }

    /// The same queries as the model, read without observing it.
    @MainActor
    package struct Untracked {
        package let model: ConversationRuntimeModel

        package var client: DaemonClient { model.client }
        package var snapshot: ConversationRuntimeSnapshot { model.current }
        package func refresh() async { await model.refresh() }
        package func isTurnActive(threadID: String) -> Bool { snapshot.isTurnActive(threadID: threadID) }
        package func isTurnActive(taskID: UUID) -> Bool { snapshot.isTurnActive(taskID: taskID.uuidString) }
        package func canInterruptActiveTurn(threadID: String) -> Bool { snapshot.canInterruptActiveTurn(threadID: threadID) }
        package func wasLastTurnInterrupted(threadID: String) -> Bool { snapshot.wasLastTurnInterrupted(threadID: threadID) }
        package func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? { snapshot.pendingUserInput[threadID] }
        package func isObservingGoal(threadID: String) -> Bool { snapshot.goal.observedThreadIDs.contains(threadID) }

        package init(model: ConversationRuntimeModel) {
            self.model = model
        }
    }
}

/// Announces a change when one task's slice of the runtime snapshot changes (see
/// `ConversationRuntimeSnapshot.slice`), so a view reading the model untracked re-renders for
/// its own task only, by reading `changeCount`. The thread IDs are read on each snapshot, so a
/// conversation started after `observe` is followed from its first turn.
@MainActor
@Observable
package final class ConversationRuntimeSliceObserver {
    private struct Observed: Equatable {
        var threadIDs: Set<String>
        var slice: ConversationRuntimeSnapshot
    }

    /// Bumped when the followed task's slice changes; a view reads it to re-render then.
    package private(set) var changeCount = 0
    @ObservationIgnored private weak var model: ConversationRuntimeModel?
    @ObservationIgnored private var taskID: String?
    @ObservationIgnored private var threadIDs: (@MainActor () -> Set<String>)?
    @ObservationIgnored private var observed: Observed?
    /// Tells a pending observation of an earlier task to stop.
    @ObservationIgnored private var generation = 0

    package nonisolated init() {}

    /// Follows `taskID`; called again with another task, it follows that one instead.
    package func observe(
        _ model: ConversationRuntimeModel,
        taskID: String,
        threadIDs: @escaping @MainActor () -> Set<String>
    ) {
        guard self.model !== model || self.taskID != taskID else { return }
        self.model = model
        self.taskID = taskID
        self.threadIDs = threadIDs
        observed = nil
        generation += 1
        // The first slice is what the view already rendered from.
        update(announce: false)
    }

    private func update(announce: Bool) {
        guard let model, let taskID, let threadIDs else { return }
        let generation = generation
        let snapshot = withObservationTracking {
            model.snapshot
        } onChange: { [weak self] in
            // Called before the model stores the new value; read it once it has.
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.update(announce: true)
            }
        }
        let ids = threadIDs()
        // The thread IDs are compared too: a slice taken before a new conversation's ID
        // was stored can equal the one after its turn ends, though the view showed the
        // turn running in between.
        let next = Observed(threadIDs: ids, slice: snapshot.slice(taskID: taskID, threadIDs: ids))
        guard next != observed else { return }
        observed = next
        if announce { changeCount += 1 }
    }
}

/// Live CPU usage per turn-active task (Claude or Codex), sampled
/// daemon-side and streamed here the same way `ConversationRuntimeModel`
/// follows turn state (see `TaskCPUUsageSnapshot`).
@MainActor
@Observable
package final class TaskCPUUsageModel {
    package private(set) var snapshot = TaskCPUUsageSnapshot()
    @ObservationIgnored package let client: DaemonClient
    @ObservationIgnored private var subscription: Task<Void, Never>?

    package init(client: DaemonClient) {
        self.client = client
    }

    package func start() {
        guard subscription == nil else { return }
        subscription = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.client.call("conversation.cpuUsage.subscribe") { event in
                        guard event.type == "cpu_usage_state",
                              let next = try? event.payload.decoded(TaskCPUUsageSnapshot.self) else { return }
                        self.snapshot = next
                    }
                } catch {
                    PlayhouseDiagnostics.record("conversation.cpuUsage.subscription_failed", fields: PlayhouseDiagnostics.errorFields(error))
                }
                self.snapshot = TaskCPUUsageSnapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    package func stop() {
        subscription?.cancel()
        subscription = nil
    }

    package func percent(threadID: String?) -> Double? {
        threadID.flatMap { snapshot.percentByThreadID[$0] }
    }
}
