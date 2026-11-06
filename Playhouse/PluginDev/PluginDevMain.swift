import Darwin
import Foundation

/// `playhouse-plugin-dev <plugin-dir>`: runs one plugin live, without the app, so
/// agents can develop it by using it. It links only the plugin core plus the
/// bridge client (see scripts/build-bridge.sh). `api` calls go to the real daemon.
@main
enum PlayhouseDevRunner {
    static let usage = """
    Usage: playhouse-plugin-dev <plugin-dir> [--view <view-id>] [--json]

    Loads the plugin and reads one command per line from stdin:
      view               Print the resolved view tree with each element's number
      tap <id>           Run element <id>'s onTap action and wait for it to settle
      type <id> <text>   Run element <id>'s onChange action with { value: <text> }
      state              Print the current state as JSON
      log [n]            Print the last n log lines (console, exceptions, api calls)
      reload             Load the plugin folder again (state resets)
      help               Show this help
      quit               Exit

    The plugin reloads by itself when plugin.json, view.json or logic.js changes.
    With --json, every reply is one JSON object per line.
    """

    static let actionTimeout: TimeInterval = 60

    /// `--list-actions <dir>`: evaluates logic.js and prints its action names as JSON.
    /// The daemon and the app validate plugins through this short-lived process, so
    /// plugin JavaScript never runs inside them; a runaway logic.js is simply killed.
    static func listActions(_ directory: URL) -> Never {
        let reply: BridgeValue
        do {
            let bundle = try PluginLoader.load(directory: directory)
            switch PluginValidator.logicActions(bundle.logicSource) {
            case .success(let actions): reply = .object(["actions": .array(actions.sorted().map(BridgeValue.string))])
            case .failure(let error): reply = .object(["error": .string(error.message)])
            }
        } catch {
            reply = .object(["error": .string(error.localizedDescription)])
        }
        FileHandle.standardOutput.write(Data((reply.jsonText + "\n").utf8))
        exit(0)
    }

    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            exit(arguments.isEmpty ? 2 : 0)
        }
        if arguments.first == "--list-actions", arguments.count == 2 {
            listActions(URL(fileURLWithPath: arguments[1], isDirectory: true))
        }
        let json = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        var viewID: String?
        if let index = arguments.firstIndex(of: "--view"), arguments.indices.contains(index + 1) {
            viewID = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("Expected exactly one plugin folder.\n\(usage)\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: arguments[0], relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        let output = RunnerOutput(json: json)
        let runner = Runner(directory: directory, viewID: viewID, output: output)
        runner.start()
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed == "quit" || trimmed == "exit" { break }
            runner.handle(trimmed)
        }
        runner.stop()
        exit(0)
    }
}

/// Serializes everything written to stdout, including reload notices from the plugin thread.
final class RunnerOutput {
    let json: Bool
    private let lock = NSLock()

    init(json: Bool) { self.json = json }

    func text(_ text: String) {
        write(text)
    }

    func reply(_ command: String, _ fields: [String: BridgeValue], text: String) {
        if json {
            var object = fields
            object["command"] = .string(command)
            if object["ok"] == nil { object["ok"] = .boolean(true) }
            write(BridgeValue.object(object).jsonText)
        } else {
            write(text)
        }
    }

    func failure(_ command: String, _ message: String) {
        reply(command, ["ok": .boolean(false), "error": .string(message)], text: "error: \(message)")
    }

    private func write(_ text: String) {
        lock.lock()
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
        lock.unlock()
    }
}

final class Runner {
    private let session: PluginSession
    private let output: RunnerOutput
    private let firstLoad = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var announcedLoadCount = 0
    private var announcedHang = false

    init(directory: URL, viewID: String?, output: RunnerOutput) {
        self.output = output
        session = PluginSession(directory: directory, viewID: viewID, transport: DaemonTransport(), watchFiles: true)
        session.onSnapshot = { [weak self] snapshot in self?.observe(snapshot) }
    }

    func start() {
        session.start()
        // Commands wait for the first load, so `view` right away shows the real tree.
        _ = firstLoad.wait(timeout: .now() + PluginValidator.logicLoadTimeout + 5)
    }

    func stop() { session.stop() }

    /// Announces loads, reloads and hangs as they happen.
    private func observe(_ snapshot: PluginSnapshot) {
        lock.lock()
        let isNewLoad = snapshot.loadCount != announcedLoadCount && (snapshot.tree != nil || snapshot.error != nil)
        if isNewLoad { announcedLoadCount = snapshot.loadCount }
        let isNewHang = snapshot.hung && !announcedHang
        if isNewHang { announcedHang = true }
        if !snapshot.hung { announcedHang = false }
        lock.unlock()
        if isNewLoad {
            let event = snapshot.loadCount == 1 ? "loaded" : "reloaded"
            let name = snapshot.manifest.map { "\($0.name) (\($0.id))" } ?? session.directory.lastPathComponent
            var fields: [String: BridgeValue] = ["event": .string(event), "plugin": .string(snapshot.manifest?.id ?? "")]
            var text = "\(event) \(name)"
            if let error = snapshot.error {
                fields["ok"] = .boolean(false)
                fields["error"] = .string(error)
                text += "\nerror: \(error)"
            }
            if !snapshot.issues.isEmpty {
                fields["issues"] = .array(snapshot.issues.map { .string($0.summary) })
                text += "\n" + snapshot.issues.map { "warning: \($0.summary)" }.joined(separator: "\n")
            }
            output.reply(event, fields, text: text)
            if snapshot.loadCount == 1 { firstLoad.signal() }
        }
        if isNewHang {
            output.reply("hung", ["event": .string("hung"), "ok": .boolean(false), "error": .string(snapshot.error ?? "")], text: "hung: \(snapshot.error ?? "")")
        }
    }

    func handle(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        let command = parts[0]
        switch command {
        case "help":
            output.reply(command, ["usage": .string(PlayhouseDevRunner.usage)], text: PlayhouseDevRunner.usage)
        case "view":
            let snapshot = session.snapshot
            guard let tree = snapshot.tree else {
                return output.failure(command, snapshot.error ?? "The plugin hasn't rendered yet.")
            }
            var fields: [String: BridgeValue] = ["tree": PluginTreeFormatter.value(tree), "view": .string(snapshot.viewID ?? "")]
            var text = PluginTreeFormatter.text(tree)
            if let error = snapshot.error {
                fields["error"] = .string(error)
                text += "\nerror: \(error)"
            }
            output.reply(command, fields, text: text)
        case "state":
            let state = session.snapshot.state
            output.reply(command, ["state": state], text: state.prettyJSON)
        case "log":
            let count = parts.count > 1 ? Int(parts[1]) ?? 50 : 50
            let entries = session.log.entries.suffix(count)
            output.reply(command, ["log": .array(entries.map { entry in
                .object(["level": .string(entry.level.rawValue), "message": .string(entry.message)])
            })], text: entries.isEmpty ? "(no log entries)" : entries.map(\.line).joined(separator: "\n"))
        case "reload":
            session.reload()
            output.reply(command, [:], text: "reloading")
        case "tap", "type":
            guard parts.count >= 2, let nodeID = Int(parts[1]) else {
                return output.failure(command, command == "tap" ? "Use: tap <id>" : "Use: type <id> <text>")
            }
            let finished = DispatchSemaphore(value: 0)
            let outcomeLock = NSLock()
            var settled: PluginActionOutcome?
            let completion: (PluginActionOutcome) -> Void = { result in
                outcomeLock.lock()
                settled = settled ?? result
                outcomeLock.unlock()
                finished.signal()
            }
            if command == "tap" {
                session.tap(nodeID: nodeID, completion: completion)
            } else {
                session.input(nodeID: nodeID, text: parts.count > 2 ? parts[2] : "", completion: completion)
            }
            _ = finished.wait(timeout: .now() + PlayhouseDevRunner.actionTimeout)
            outcomeLock.lock()
            let outcome = settled ?? .failed("The action is still running after \(Int(PlayhouseDevRunner.actionTimeout)) seconds.")
            // A completion arriving after this reply is dropped rather than racing it.
            settled = settled ?? outcome
            outcomeLock.unlock()
            switch outcome {
            case .completed: output.reply(command, ["node": .integer(nodeID)], text: "ok")
            case .failed(let message): output.failure(command, message)
            }
        default:
            output.failure(command, "Unknown command \"\(command)\". Type help for the list.")
        }
    }
}

/// Sends `api.call` requests to the real daemon, the same way `playhouse-cli` does.
final class DaemonTransport: PluginDaemonTransport {
    func call(command: String, arguments: [String: BridgeValue], completion: @escaping (Result<BridgeValue, Error>) -> Void) {
        let request = BridgeRequest(command: command, arguments: arguments).configuredForCaller()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let response = try BridgeClient().send(request) { _ in }
                if response.ok {
                    completion(.success(response.result ?? .null))
                } else {
                    completion(.failure(PluginTransportError(message: response.error.map { "\($0.code): \($0.message)" } ?? "The daemon rejected \(command).")))
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}

private extension BridgeValue {
    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }
}
