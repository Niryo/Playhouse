import Darwin
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
        var serviceName: String
        var socketPath: String

        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            let serviceName = environment["STATIONAI_BRIDGE_SERVICE_NAME"]
                ?? BridgeContract.serviceName(forApplication: StationAIAppIdentity.applicationIdentifier)
            return Configuration(
                dataDirectory: environment["STATIONAI_DATA_DIRECTORY"],
                defaultsSuite: environment["STATIONAI_E2E_DEFAULTS_SUITE"],
                worktreeDirectory: environment["STATIONAI_E2E_WORKTREE_DIRECTORY"],
                codexExecutable: environment["STATIONAI_E2E_CODEX_EXECUTABLE"],
                claudeExecutable: environment["STATIONAI_E2E_CLAUDE_EXECUTABLE"],
                codexHome: environment["CODEX_HOME"],
                serviceName: serviceName,
                socketPath: environment["STATIONAI_BRIDGE_SOCKET_PATH"] ?? BridgeContract.socketURL(forServiceName: serviceName).path
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
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("stationai-daemon").path
    }

    private func configuredRequest(_ command: String, _ arguments: [String: BridgeValue]) -> BridgeRequest {
        var request = BridgeRequest(command: command, arguments: arguments)
        request.arguments["__guiRuntime"] = .boolean(true)
        if let codex = configuration.codexExecutable { request.arguments["__codexExecutable"] = .string(codex) }
        if let claude = configuration.claudeExecutable { request.arguments["__claudeExecutable"] = .string(claude) }
        if let codexHome = configuration.codexHome { request.arguments["__codexHome"] = .string(codexHome) }
        request.dataDirectory = configuration.dataDirectory
        request.defaultsSuite = configuration.defaultsSuite
        request.worktreeDirectory = configuration.worktreeDirectory
        request.environment = ProcessInfo.processInfo.environment
            .filter { BridgeContract.sessionEnvironmentNames.contains($0.key) }
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
                            message: failure?.message ?? "The StationAI bridge request failed."
                        )
                    }
                    return response.result ?? .null
                case .failure(let error):
                    if Task.isCancelled { throw CancellationError() }
                    throw DaemonClientError.unavailable(error.localizedDescription)
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw DaemonClientError.unavailable("The StationAI bridge daemon closed the connection.")
        } onCancel: {
            call.cancel()
        }
    }
}

enum DaemonClientError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Couldn't reach the StationAI bridge daemon. \(reason)"
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
                    StationAIDiagnostics.record("conversation.runtime.subscription_failed", fields: StationAIDiagnostics.errorFields(error))
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
    func canInterruptActiveTurn(threadID: String) -> Bool { snapshot.canInterruptActiveTurn(threadID: threadID) }
    func wasLastTurnInterrupted(threadID: String) -> Bool { snapshot.wasLastTurnInterrupted(threadID: threadID) }
    func pendingUserInputRequest(forThread threadID: String) -> ConversationUserInputRequest? { snapshot.pendingUserInput[threadID] }
    func isObservingGoal(threadID: String) -> Bool { snapshot.goal.observedThreadIDs.contains(threadID) }
}
