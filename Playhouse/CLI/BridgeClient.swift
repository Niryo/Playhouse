import Darwin
import Foundation

final class BridgeClient {
    /// Sends one request over the daemon's Unix socket and blocks (streaming
    /// `onEvent` as frames arrive) until the final response frame. Starts the
    /// daemon itself, lock-guarded against a concurrent caller doing the same,
    /// if nothing is listening yet — the daemon then runs on its own, exiting
    /// once idle, independent of this CLI invocation's lifetime.
    func send(_ request: BridgeRequest, onEvent: @escaping (BridgeEvent) -> Void) throws -> BridgeResponse {
        let serviceName = ProcessInfo.processInfo.environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
            ?? BridgeContract.serviceName(forApplication: Self.applicationIdentifier() ?? "")
        let socketPath = ProcessInfo.processInfo.environment["PLAYHOUSE_BRIDGE_SOCKET_PATH"]
            ?? BridgeContract.socketURL(forServiceName: serviceName).path

        let connection: BridgeSocketConnection
        do {
            connection = try BridgeDaemonLauncher.connect(
                socketPath: socketPath,
                serviceName: serviceName,
                daemonExecutablePath: Self.daemonExecutablePath()
            )
        } catch BridgeSocketError.daemonNotFound {
            throw BridgeClientError.daemonNotFound
        } catch {
            throw BridgeClientError.unreachable("\(error.localizedDescription) (socket \(socketPath))")
        }
        defer { connection.close() }
        connection.setReceiveTimeout(seconds: 5)

        do {
            try connection.write(BridgeFraming.frame(request))
        } catch {
            throw BridgeClientError.connection
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(24 * 60 * 60)
        while true {
            let messages: [BridgeWireMessage]
            do {
                messages = try connection.readMessages(as: BridgeWireMessage.self, buffer: &buffer)
            } catch BridgeSocketError.readTimedOut {
                if Date() > deadline { throw BridgeClientError.timeout }
                continue
            } catch {
                throw BridgeClientError.connection
            }
            for message in messages {
                switch message {
                case .event(let event): onEvent(event)
                case .response(let response): return response
                }
            }
        }
    }

    /// The daemon ships as a sibling of this CLI executable
    /// (`Contents/MacOS/playhouse-daemon`, next to `Contents/MacOS/playhouse-cli`).
    private static func daemonExecutablePath() -> String? {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else { return nil }
        let daemonURL = URL(fileURLWithPath: executablePath).standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("playhouse-daemon")
        return FileManager.default.isExecutableFile(atPath: daemonURL.path) ? daemonURL.path : nil
    }

    /// This CLI executable lives at `<App>.app/Contents/MacOS/playhouse-cli`, so
    /// `Bundle.main` already resolves to the same app bundle (and the same
    /// `Info.plist`) the GUI process itself has — no separate identity lookup
    /// or sibling-bundle walk needed.
    private static func applicationIdentifier() -> String? {
        Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier
    }
}

enum BridgeClientError: LocalizedError {
    case connection
    case unreachable(String)
    case timeout
    case daemonNotFound

    var errorDescription: String? {
        switch self {
        case .connection: "Couldn't connect to the Playhouse bridge daemon. Confirm Playhouse is installed and try again."
        case .unreachable(let reason): "Couldn't connect to the Playhouse bridge daemon: \(reason)"
        case .timeout: "The Playhouse bridge daemon did not respond before the request timed out."
        case .daemonNotFound: "Couldn't find the Playhouse bridge daemon next to this CLI. Reinstall Playhouse."
        }
    }
}

extension BridgeRequest {
    /// This request with the caller's Playhouse settings attached: its data
    /// directory, test overrides and forwardable session environment. Shared by
    /// `playhouse-cli` and `playhouse-plugin-dev`, which both run from the app's
    /// Contents/MacOS.
    func configuredForCaller(environment: [String: String] = ProcessInfo.processInfo.environment) -> BridgeRequest {
        let dataDirectory = environment["PLAYHOUSE_DATA_DIRECTORY"]
        let defaultsSuite = environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"]
        var configuredRequest = self
        configuredRequest.dataDirectory = dataDirectory
        configuredRequest.defaultsSuite = defaultsSuite
        configuredRequest.worktreeDirectory = environment["PLAYHOUSE_E2E_WORKTREE_DIRECTORY"]
        // Same identity lookup as BridgeClient.applicationIdentifier(): these tools
        // live in `<App>.app/Contents/MacOS/`, so `Bundle.main` already resolves
        // to the app's own Info.plist.
        let applicationIdentifier = Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String
            ?? Bundle.main.bundleIdentifier ?? ""
        let forwardableNames = BridgeContract.environmentNamesToForward(
            applicationIdentifier: applicationIdentifier,
            from: environment
        )
        configuredRequest.environment = environment
            .filter { forwardableNames.contains($0.key) }
        if let codexHome = environment["CODEX_HOME"] {
            configuredRequest.arguments["__codexHome"] = .string(codexHome)
        }
        if let fixtureExecutable = environment["PLAYHOUSE_E2E_CODEX_EXECUTABLE"] {
            configuredRequest.arguments["__codexExecutable"] = .string(fixtureExecutable)
        }
        if let fixtureExecutable = environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] {
            configuredRequest.arguments["__claudeExecutable"] = .string(fixtureExecutable)
        }
        // The daemon is started by launchd and never sees the caller's environment,
        // so a caller's own Claude config directory travels with the request, as
        // CODEX_HOME does: its turns and its session-file reads then use it.
        if let claudeConfig = environment["CLAUDE_CONFIG_DIR"], !claudeConfig.isEmpty {
            configuredRequest.arguments["__claudeConfigDirectory"] = .string(claudeConfig)
        }
        return configuredRequest
    }
}
