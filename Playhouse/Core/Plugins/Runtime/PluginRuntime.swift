import Foundation
import Observation

/// Runs one plugin: a JavaScript engine (`ScriptEngine`) with the vendored React,
/// react-reconciler and scheduler, the prelude's host config, and the
/// plugin's script. Each React commit arrives as one array of ops, read
/// straight from the JavaScript value with no JSON string, and is applied to
/// `tree`; `dispatch` sends an atom's event back to its handler.
///
/// Not thread-safe: create and use it on one thread (the main thread in the
/// app). With `.manual` timers nothing runs until `runDueTimers` is called,
/// which is how the daemon's `plugin render` drives it headlessly.
@Observable
package final class PluginRuntime {
    package enum Timers {
        case mainQueue
        case manual
    }

    package struct LogEntry: Equatable {
        package var level: String
        package var message: String

        package init(level: String, message: String) {
            self.level = level
            self.message = message
        }
    }

    /// A call the plugin made to its host: `Playhouse.bridge(command, arguments)`
    /// (`kind` "bridge") or `Playhouse.ui.<name>(…)` (`kind` "ui"). The plugin
    /// waits on a promise until the host answers it with `answerHostCall`.
    package struct HostCall: Equatable {
        package var id: Int
        package var kind: String
        package var name: String
        package var arguments: PluginValue

        package init(id: Int, kind: String, name: String, arguments: PluginValue) {
            self.id = id
            self.kind = kind
            self.name = name
            self.arguments = arguments
        }
    }

    /// The vendored modules, in the order they are defined.
    package static let vendorModules = ["react", "scheduler", "react-reconciler"]

    /// The app bundle's runtime folder (prelude.js and vendor/), found from the
    /// app and from the daemon, which runs inside the same bundle.
    package static var bundledResources: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("PluginRuntime", isDirectory: true)
    }

    package let tree = PluginNodeTree()
    /// Script errors, uncaught exceptions and invalid commits, oldest first.
    package private(set) var errors: [String] = []
    @ObservationIgnored package private(set) var log: [LogEntry] = []
    /// Host calls not answered yet, oldest first.
    @ObservationIgnored package private(set) var pendingHostCalls: [HostCall] = []
    /// Called for each host call as the plugin makes it; it stays pending until answered.
    @ObservationIgnored package var onHostCall: ((HostCall) -> Void)?

    @ObservationIgnored private let engine: any ScriptEngine
    @ObservationIgnored private let timerMode: Timers
    @ObservationIgnored private var pendingTimers: [Int: DispatchWorkItem] = [:]
    @ObservationIgnored private var manualTimers: [(id: Int, due: Double)] = []
    @ObservationIgnored private var manualClock: Double = 0
    @ObservationIgnored private var commandResults: [Int: Result<PluginValue, PluginHostError>] = [:]
    @ObservationIgnored private var nextCommandToken = 0

    /// The plugin whose props this runtime holds; an event targeted at another plugin skips it.
    /// Nil for a script with no plugin in its props.
    @ObservationIgnored private var pluginID: String?

    /// Loads the runtime from `resources` and runs `source`. `props` is the
    /// plugin's input, readable as `Playhouse.props`. A script that throws
    /// leaves its error in `errors` rather than failing the init. With
    /// `service`, it is the plugin's background half: `Playhouse.service.on`
    /// registers handlers and `Playhouse.render` does nothing.
    package init(source: String, sourceName: String = "plugin.js", props: [String: PluginValue] = [:], resources: URL? = PluginRuntime.bundledResources, timers: Timers = .mainQueue, service: Bool = false) throws {
        guard let resources else { throw PluginTreeError(message: "This build has no bundled plugin runtime.") }
        engine = try ScriptEngines.make(name: "Playhouse plugin: \(sourceName)")
        timerMode = timers
        tree.validate = AtomType.validate
        tree.validateChild = AtomType.validateChild
        engine.onError = { [weak self] message in
            self?.record(error: message)
        }
        installNative()
        pluginID = props["plugin"]?.object?["id"]?.string
        if service { engine.setGlobal("__playhouseService", to: .bool(true)) }

        let prelude = try String(contentsOf: resources.appendingPathComponent("prelude.js"), encoding: .utf8)
        engine.evaluate(prelude, sourceURL: resources.appendingPathComponent("prelude.js"))
        for module in Self.vendorModules {
            let file = resources.appendingPathComponent("vendor/\(module).js")
            let text = try String(contentsOf: file, encoding: .utf8)
            let wrapped = "__playhouseDefine(\(PluginValue.string(module).jsonText), function (module, exports, require) {\n\(text)\n});"
            engine.evaluate(wrapped, sourceURL: file)
        }
        engine.setGlobal("__playhouseProps", to: .object(props))
        engine.call("__playhouseBoot", [.array(AtomType.allCases.map { .string($0.rawValue) })])
        guard errors.isEmpty else { return }
        engine.evaluate(source, sourceURL: URL(fileURLWithPath: sourceName))
    }

    deinit {
        pendingTimers.values.forEach { $0.cancel() }
    }

    /// Sends `event` to node `nodeID`'s handler. Returns false when the node
    /// has no such handler. The handler's state updates commit before this returns.
    @discardableResult
    package func dispatch(nodeID: Int, event: String, value: PluginValue? = nil) -> Bool {
        var arguments: [PluginValue] = [.number(Double(nodeID)), .string(event)]
        if let value { arguments.append(value) }
        return engine.call("__playhouseDispatch", arguments) == .bool(true)
    }

    /// Delivers an app event to the plugin's `Playhouse.on` listeners, whose
    /// updates commit as one batch. Returns how many listeners heard it.
    @discardableResult
    package func emit(_ event: PluginEvent) -> Int {
        // A script rendered from a file has no plugin id of its own, so it hears every event.
        guard pluginID == nil || event.reaches(pluginID) else { return 0 }
        guard case .number(let heard)? = engine.call("__playhouseEmit", [.string(event.name), .object(event.payload)]) else { return 0 }
        return Int(heard)
    }

    /// Replaces `Playhouse.props` and tells `Playhouse.useProps` subscribers,
    /// whose updates commit as one batch.
    package func updateProps(_ props: [String: PluginValue]) {
        pluginID = props["plugin"]?.object?["id"]?.string ?? pluginID
        engine.call("__playhouseSetProps", [.object(props)])
    }

    /// Resolves (or rejects) the promise of host call `id`.
    package func answerHostCall(_ id: Int, result: Result<PluginValue, PluginHostError>) {
        guard pendingHostCalls.contains(where: { $0.id == id }) else { return }
        pendingHostCalls.removeAll { $0.id == id }
        switch result {
        case .success(let value):
            engine.call("__playhouseAnswerHostCall", [.number(Double(id)), .bool(true), value])
        case .failure(let error):
            let failure = PluginValue.object(["code": .string(error.code), "message": .string(error.message)])
            engine.call("__playhouseAnswerHostCall", [.number(Double(id)), .bool(false), failure])
        }
    }

    /// With `.manual` timers: advances the clock by `seconds` and fires every
    /// timer that came due, including ones those timers schedule.
    package func runDueTimers(advancing seconds: Double = 0) {
        let target = manualClock + seconds
        // The clock steps to each timer as it fires, so a timer it schedules
        // (an interval's next tick, an effect's timer) counts from then.
        while let next = manualTimers.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            manualTimers.removeAll { $0.id == next.id }
            manualClock = max(manualClock, next.due)
            fireTimer(next.id)
        }
        manualClock = target
    }

    /// With `.manual` timers: fires the earliest pending timer, advancing the
    /// clock to it. Returns false when no timer is pending.
    @discardableResult
    package func runNextTimer() -> Bool {
        guard let next = manualTimers.min(by: { $0.due < $1.due }) else { return false }
        runDueTimers(advancing: max(0, next.due - manualClock))
        return true
    }

    /// The command names the script registered with `Playhouse.commands.register`.
    package func registeredCommands() -> [String] {
        engine.call("__playhouseCommandNames", [])?.array?.compactMap(\.string) ?? []
    }

    /// Starts the `phase` handler of command `name` with `request`; its result
    /// arrives in `commandResult(_:)` once the handler's promise settles.
    package func runCommand(_ name: String, phase: String, request: PluginValue) -> Int {
        nextCommandToken += 1
        let token = nextCommandToken
        engine.call("__playhouseRunCommand", [.number(Double(token)), .string(name), .string(phase), request])
        return token
    }

    /// Calls the background half's handlers for `event`; once every promise they
    /// returned has settled, `commandResult(_:)` holds `{handlers, errors}`.
    package func runService(_ event: PluginEvent) -> Int {
        nextCommandToken += 1
        let token = nextCommandToken
        engine.call("__playhouseRunService", [.number(Double(token)), .string(event.name), .object(event.payload)])
        return token
    }

    /// What command run `token` settled with, or nil while it runs.
    package func commandResult(_ token: Int) -> Result<PluginValue, PluginHostError>? {
        commandResults[token]
    }

    private func installNative() {
        engine.defineNativeObject("__native", functions: [
            // A commit's op array arrives as the engine's own value and is read directly, with no JSON string.
            "commit": { [weak self] arguments in
                guard let self else { return }
                do {
                    try tree.apply(try arguments.value(0))
                } catch {
                    record(error: "Invalid commit: \(error.localizedDescription)")
                }
            },
            "log": { [weak self] arguments in
                let level = arguments.string(0), message = arguments.string(1)
                self?.log.append(LogEntry(level: level, message: message))
                if level == "error" { self?.record(error: message) }
            },
            "setTimer": { [weak self] arguments in
                self?.schedule(arguments.int(0), after: arguments.number(1) / 1000)
            },
            "clearTimer": { [weak self] arguments in
                let id = arguments.int(0)
                self?.pendingTimers.removeValue(forKey: id)?.cancel()
                self?.manualTimers.removeAll { $0.id == id }
            },
            "hostCall": { [weak self] arguments in
                guard let self else { return }
                let call = HostCall(
                    id: arguments.int(0), kind: arguments.string(1), name: arguments.string(2),
                    arguments: (try? arguments.value(3)) ?? .null
                )
                pendingHostCalls.append(call)
                onHostCall?(call)
            },
            "commandResult": { [weak self] arguments in
                let token = arguments.int(0)
                let result = (try? arguments.value(2)) ?? .null
                if arguments.bool(1) {
                    self?.commandResults[token] = .success(result)
                } else {
                    let object = result.object ?? [:]
                    self?.commandResults[token] = .failure(PluginHostError(
                        code: object["code"]?.string ?? "script_error", message: object["message"]?.string ?? "The command failed."
                    ))
                }
            },
        ])
    }

    private func schedule(_ id: Int, after seconds: Double) {
        switch timerMode {
        case .manual:
            manualTimers.append((id, manualClock + seconds))
        case .mainQueue:
            let item = DispatchWorkItem { [weak self] in
                self?.pendingTimers[id] = nil
                self?.fireTimer(id)
            }
            pendingTimers[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    private func fireTimer(_ id: Int) {
        engine.call("__playhouseFireTimer", [.number(Double(id))])
    }

    private func record(error: String) {
        errors.append(error)
    }

}

/// Why the host turned down a plugin's call; the plugin's promise rejects
/// with an Error carrying this `code` and `message`.
package struct PluginHostError: Error, Equatable, Sendable {
    package var code: String
    package var message: String

    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
