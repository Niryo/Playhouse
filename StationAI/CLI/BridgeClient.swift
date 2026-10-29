import Darwin
import Foundation

final class BridgeClient {
    /// Sends one request over the daemon's Unix socket and blocks (streaming
    /// `onEvent` as frames arrive) until the final response frame. Starts the
    /// daemon itself, lock-guarded against a concurrent caller doing the same,
    /// if nothing is listening yet — the daemon then runs on its own, exiting
    /// once idle, independent of this CLI invocation's lifetime.
    func send(_ request: BridgeRequest, onEvent: @escaping (BridgeEvent) -> Void) throws -> BridgeResponse {
        let serviceName = ProcessInfo.processInfo.environment["STATIONAI_BRIDGE_SERVICE_NAME"]
            ?? BridgeContract.serviceName(forApplication: Self.applicationIdentifier() ?? "")
        let socketPath = ProcessInfo.processInfo.environment["STATIONAI_BRIDGE_SOCKET_PATH"]
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
    /// (`Contents/MacOS/stationai-daemon`, next to `Contents/MacOS/stationai-cli`).
    private static func daemonExecutablePath() -> String? {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else { return nil }
        let daemonURL = URL(fileURLWithPath: executablePath).standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("stationai-daemon")
        return FileManager.default.isExecutableFile(atPath: daemonURL.path) ? daemonURL.path : nil
    }

    /// This CLI executable lives at `<App>.app/Contents/MacOS/stationai-cli`, so
    /// `Bundle.main` already resolves to the same app bundle (and the same
    /// `Info.plist`) the GUI process itself has — no separate identity lookup
    /// or sibling-bundle walk needed.
    private static func applicationIdentifier() -> String? {
        Bundle.main.infoDictionary?["StationAIApplicationBundleIdentifier"] as? String ?? Bundle.main.bundleIdentifier
    }
}

enum BridgeClientError: LocalizedError {
    case connection
    case unreachable(String)
    case timeout
    case daemonNotFound

    var errorDescription: String? {
        switch self {
        case .connection: "Couldn't connect to the StationAI bridge daemon. Confirm StationAI is installed and try again."
        case .unreachable(let reason): "Couldn't connect to the StationAI bridge daemon: \(reason)"
        case .timeout: "The StationAI bridge daemon did not respond before the request timed out."
        case .daemonNotFound: "Couldn't find the StationAI bridge daemon next to this CLI. Reinstall StationAI."
        }
    }
}
