import Darwin
import Combine
import Foundation
import SwiftUI

/// A window's channel to the bridge daemon, which owns every provider process,
/// running turn, and queued follow-up. Each call is one request on its own
/// connection, exactly as the CLI sends them, so a window and a command-line
/// call reach the same owner. Starts the daemon on demand.
final class DaemonClient: @unchecked Sendable {
    struct Configuration: Sendable {
        var dataDirectory: String?
        var defaultsSuite: String?
        var worktreeDirectory: String?
        var codexExecutable: String?
        var claudeExecutable: String?
        var codexHome: String?
        var claudeConfigDirectory: String?
        var serviceName: String
        var socketPath: String

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            let serviceName = environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
                ?? BridgeContract.serviceName(forApplication: PlayhouseAppIdentity.applicationIdentifier)
            return Configuration(
                dataDirectory: environment["PLAYHOUSE_DATA_DIRECTORY"],
                defaultsSuite: environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"],
                worktreeDirectory: environment["PLAYHOUSE_E2E_WORKTREE_DIRECTORY"],
                codexExecutable: environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"],
                claudeExecutable: environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"],
                codexHome: environment["CODEX_HOME"],
                claudeConfigDirectory: environment["PLAYHOUSE_E2E_CLAUDE_CONFIG_DIR"],
                serviceName: serviceName,
                socketPath: environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"] ?? BridgeContract.socketURL(forServiceName: serviceName).path
            )
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

    let configuration: Configuration

    init(configuration: Configuration = .fromEnvironment()) {
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
        if let codexHome = configuration.codexHome { request.arguments["__codexHome"] = .string(codexHome) }
        if let claudeConfig = configuration.claudeConfigDirectory { request.arguments["__claudeConfigDirectory"] = .string(claudeConfig) }
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
    func call(
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
                        continuation.yield(.message(message))
                        if case .response = message { return }
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

enum DaemonClientError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Couldn't reach the Playhouse bridge daemon. \(reason)"
        }
    }
}

/// What the daemon says about running turns, kept current for the views. This
/// replaces the observable state the window's own provider clients used to hold:
/// the window no longer runs providers, so it watches the daemon that does.
@MainActor
final class ConversationRuntimeModel: ObservableObject {
    @Published private(set) var snapshot = ConversationRuntimeSnapshot()
    let client: DaemonClient
    private var subscription: Task<Void, Never>?

    init(client: DaemonClient) {
        self.client = client
    }

    /// Follows the daemon's state, reconnecting if it goes away. Turns that were
    /// running in a daemon that has died are not running any more, so the
    /// snapshot is cleared whenever the connection drops.
    func start() {
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

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// Reads the daemon's state now, for the moment right after a request ended,
    /// when the stream may not have caught up yet.
    func refresh() async {
        guard let value = try? await client.call("conversation.runtime"),
              let current = try? value.decoded(ConversationRuntimeSnapshot.self) else { return }
        snapshot = current
    }

    func isTurnActive(threadID: String) -> Bool { snapshot.isTurnActive(threadID: threadID) }
    func isTurnActive(taskID: UUID) -> Bool { snapshot.isTurnActive(taskID: taskID.uuidString) }
    func canInterruptActiveTurn(threadID: String) -> Bool { snapshot.canInterruptActiveTurn(threadID: threadID) }
    func wasLastTurnInterrupted(threadID: String) -> Bool { snapshot.wasLastTurnInterrupted(threadID: threadID) }
    func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? { snapshot.pendingUserInput[threadID] }
    func isObservingGoal(threadID: String) -> Bool { snapshot.goal.observedThreadIDs.contains(threadID) }
}

/// The runtime model without observing it. Reading it through `@EnvironmentObject` re-renders a
/// view on every snapshot, and the snapshot changes with every turn and revision of every task,
/// so an open conversation re-ran its whole transcript while other tasks worked.
/// `ConversationRuntimeSliceObserver` re-renders it for its own task's changes instead.
private struct ConversationRuntimeModelKey: EnvironmentKey {
    static let defaultValue: ConversationRuntimeModel? = nil
}

extension EnvironmentValues {
    var conversationRuntimeModel: ConversationRuntimeModel? {
        get { self[ConversationRuntimeModelKey.self] }
        set { self[ConversationRuntimeModelKey.self] = newValue }
    }
}

/// Announces a change when one task's slice of the runtime snapshot changes (see
/// `ConversationRuntimeSnapshot.slice`), so a view reading the unobserved model re-renders for
/// its own task only. The thread IDs are read on each snapshot, so a conversation started after
/// `observe` is followed from its first turn.
@MainActor
final class ConversationRuntimeSliceObserver: ObservableObject {
    private struct Observed: Equatable {
        var threadIDs: Set<String>
        var slice: ConversationRuntimeSnapshot
    }

    private var subscription: AnyCancellable?
    private var taskID: String?
    private var observed: Observed?

    /// Follows `taskID`; called again with another task, it follows that one instead.
    func observe(
        _ model: ConversationRuntimeModel,
        taskID: String,
        threadIDs: @escaping @MainActor () -> Set<String>
    ) {
        guard subscription == nil || self.taskID != taskID else { return }
        subscription?.cancel()
        self.taskID = taskID
        observed = nil
        // `$snapshot` publishes before the model stores the value; the view re-renders on a
        // later pass, when it reads the stored one.
        subscription = model.$snapshot.sink { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ids = threadIDs()
                // The thread IDs are compared too: a slice taken before a new conversation's ID
                // was stored can equal the one after its turn ends, though the view showed the
                // turn running in between.
                let next = Observed(threadIDs: ids, slice: snapshot.slice(taskID: taskID, threadIDs: ids))
                guard next != self.observed else { return }
                // The first slice is what the view already rendered from.
                let isFirst = self.observed == nil
                self.observed = next
                if !isFirst { self.objectWillChange.send() }
            }
        }
    }
}

/// Live CPU usage per turn-active task (Claude or Codex), sampled
/// daemon-side and streamed here the same way `ConversationRuntimeModel`
/// follows turn state (see `TaskCPUUsageSnapshot`).
@MainActor
final class TaskCPUUsageModel: ObservableObject {
    @Published private(set) var snapshot = TaskCPUUsageSnapshot()
    let client: DaemonClient
    private var subscription: Task<Void, Never>?

    init(client: DaemonClient) {
        self.client = client
    }

    func start() {
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

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    func percent(threadID: String?) -> Double? {
        threadID.flatMap { snapshot.percentByThreadID[$0] }
    }
}
