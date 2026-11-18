import Foundation
import JavaScriptCore
import Observation

/// Runs one plugin: a JavaScriptCore context with the vendored React,
/// react-reconciler and scheduler, the prelude's host config, and the
/// plugin's script. Each React commit arrives as one array of ops, read
/// straight from the JavaScript value with no JSON string, and is applied to
/// `tree`; `dispatch` sends an atom's event back to its handler.
///
/// Not thread-safe: create and use it on one thread (the main thread in the
/// app). With `.manual` timers nothing runs until `runDueTimers` is called,
/// which is how the daemon's `plugin render` drives it headlessly.
@Observable
final class PluginRuntime {
    enum Timers {
        case mainQueue
        case manual
    }

    struct LogEntry: Equatable {
        var level: String
        var message: String
    }

    /// A call the plugin made to its host: `Playhouse.bridge(command, arguments)`
    /// (`kind` "bridge") or `Playhouse.ui.<name>(…)` (`kind` "ui"). The plugin
    /// waits on a promise until the host answers it with `answerHostCall`.
    struct HostCall: Equatable {
        var id: Int
        var kind: String
        var name: String
        var arguments: PluginValue
    }

    /// The vendored modules, in the order they are defined.
    static let vendorModules = ["react", "scheduler", "react-reconciler"]

    /// The app bundle's runtime folder (prelude.js and vendor/), found from the
    /// app and from the daemon, which runs inside the same bundle.
    static var bundledResources: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("PluginRuntime", isDirectory: true)
    }

    let tree = PluginNodeTree()
    /// Script errors, uncaught exceptions and invalid commits, oldest first.
    private(set) var errors: [String] = []
    @ObservationIgnored private(set) var log: [LogEntry] = []
    /// Host calls not answered yet, oldest first.
    @ObservationIgnored private(set) var pendingHostCalls: [HostCall] = []
    /// Called for each host call as the plugin makes it; it stays pending until answered.
    @ObservationIgnored var onHostCall: ((HostCall) -> Void)?

    @ObservationIgnored private let context: JSContext
    @ObservationIgnored private let timerMode: Timers
    @ObservationIgnored private var pendingTimers: [Int: DispatchWorkItem] = [:]
    @ObservationIgnored private var manualTimers: [(id: Int, due: Double)] = []
    @ObservationIgnored private var manualClock: Double = 0
    @ObservationIgnored private var commandResults: [Int: Result<PluginValue, PluginHostError>] = [:]
    @ObservationIgnored private var nextCommandToken = 0

    /// Loads the runtime from `resources` and runs `source`. `props` is the
    /// plugin's input, readable as `Playhouse.props`. A script that throws
    /// leaves its error in `errors` rather than failing the init.
    init(source: String, sourceName: String = "plugin.js", props: [String: PluginValue] = [:], resources: URL? = PluginRuntime.bundledResources, timers: Timers = .mainQueue) throws {
        guard let resources else { throw PluginTreeError(message: "This build has no bundled plugin runtime.") }
        guard let context = JSContext() else { throw PluginTreeError(message: "Couldn't create a JavaScript context.") }
        self.context = context
        timerMode = timers
        context.name = "Playhouse plugin: \(sourceName)"
        tree.validate = AtomType.validate
        tree.validateChild = AtomType.validateChild
        context.exceptionHandler = { [weak self] _, exception in
            self?.record(error: Self.describe(exception))
        }
        installNative()

        let prelude = try String(contentsOf: resources.appendingPathComponent("prelude.js"), encoding: .utf8)
        context.evaluateScript(prelude, withSourceURL: resources.appendingPathComponent("prelude.js"))
        for module in Self.vendorModules {
            let file = resources.appendingPathComponent("vendor/\(module).js")
            let text = try String(contentsOf: file, encoding: .utf8)
            let wrapped = "__playhouseDefine(\(PluginValue.string(module).jsonText), function (module, exports, require) {\n\(text)\n});"
            context.evaluateScript(wrapped, withSourceURL: file)
        }
        context.setObject(PluginValue.object(props).javaScriptValue(in: context), forKeyedSubscript: "__playhouseProps" as NSString)
        context.objectForKeyedSubscript("__playhouseBoot").call(withArguments: [AtomType.allCases.map(\.rawValue)])
        guard errors.isEmpty else { return }
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: sourceName))
    }

    deinit {
        pendingTimers.values.forEach { $0.cancel() }
    }

    /// Sends `event` to node `nodeID`'s handler. Returns false when the node
    /// has no such handler. The handler's state updates commit before this returns.
    @discardableResult
    func dispatch(nodeID: Int, event: String, value: PluginValue? = nil) -> Bool {
        let dispatcher = context.objectForKeyedSubscript("__playhouseDispatch")
        var arguments: [Any] = [nodeID, event]
        if let value { arguments.append(value.javaScriptValue(in: context)) }
        return dispatcher?.call(withArguments: arguments)?.toBool() ?? false
    }

    /// Delivers an app event to the plugin's `Playhouse.on` listeners, whose
    /// updates commit as one batch. Returns how many listeners heard it.
    @discardableResult
    func emit(_ event: PluginEvent) -> Int {
        let emitter = context.objectForKeyedSubscript("__playhouseEmit")
        return Int(emitter?.call(withArguments: [event.name, PluginValue.object(event.payload).javaScriptValue(in: context)])?.toInt32() ?? 0)
    }

    /// Replaces `Playhouse.props` and tells `Playhouse.useProps` subscribers,
    /// whose updates commit as one batch.
    func updateProps(_ props: [String: PluginValue]) {
        context.objectForKeyedSubscript("__playhouseSetProps")?.call(withArguments: [PluginValue.object(props).javaScriptValue(in: context)])
    }

    /// Resolves (or rejects) the promise of host call `id`.
    func answerHostCall(_ id: Int, result: Result<PluginValue, PluginHostError>) {
        guard pendingHostCalls.contains(where: { $0.id == id }) else { return }
        pendingHostCalls.removeAll { $0.id == id }
        let answer = context.objectForKeyedSubscript("__playhouseAnswerHostCall")
        switch result {
        case .success(let value):
            answer?.call(withArguments: [id, true, value.javaScriptValue(in: context)])
        case .failure(let error):
            let failure = PluginValue.object(["code": .string(error.code), "message": .string(error.message)])
            answer?.call(withArguments: [id, false, failure.javaScriptValue(in: context)])
        }
    }

    /// With `.manual` timers: advances the clock by `seconds` and fires every
    /// timer that came due, including ones those timers schedule.
    func runDueTimers(advancing seconds: Double = 0) {
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
    func runNextTimer() -> Bool {
        guard let next = manualTimers.min(by: { $0.due < $1.due }) else { return false }
        runDueTimers(advancing: max(0, next.due - manualClock))
        return true
    }

    /// The command names the script registered with `Playhouse.commands.register`.
    func registeredCommands() -> [String] {
        context.objectForKeyedSubscript("__playhouseCommandNames")?.call(withArguments: [])?.toArray()?.compactMap { $0 as? String } ?? []
    }

    /// Starts the `phase` handler of command `name` with `request`; its result
    /// arrives in `commandResult(_:)` once the handler's promise settles.
    func runCommand(_ name: String, phase: String, request: PluginValue) -> Int {
        nextCommandToken += 1
        let token = nextCommandToken
        context.objectForKeyedSubscript("__playhouseRunCommand")?.call(withArguments: [token, name, phase, request.javaScriptValue(in: context)])
        return token
    }

    /// What command run `token` settled with, or nil while it runs.
    func commandResult(_ token: Int) -> Result<PluginValue, PluginHostError>? {
        commandResults[token]
    }

    private func installNative() {
        let native = JSValue(newObjectIn: context)!
        // A commit's op array arrives as a JavaScript value and is read directly, with no JSON string.
        let commit: @convention(block) (JSValue) -> Void = { [weak self] ops in
            guard let self else { return }
            do {
                try tree.apply(PluginValue(javaScript: ops))
            } catch {
                record(error: "Invalid commit: \(error.localizedDescription)")
            }
        }
        let log: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log.append(LogEntry(level: level, message: message))
            if level == "error" { self?.record(error: message) }
        }
        let setTimer: @convention(block) (Int, Double) -> Void = { [weak self] id, milliseconds in
            self?.schedule(id, after: milliseconds / 1000)
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            self?.pendingTimers.removeValue(forKey: id)?.cancel()
            self?.manualTimers.removeAll { $0.id == id }
        }
        let hostCall: @convention(block) (Int, String, String, JSValue) -> Void = { [weak self] id, kind, name, arguments in
            guard let self else { return }
            let call = HostCall(id: id, kind: kind, name: name, arguments: (try? PluginValue(javaScript: arguments)) ?? .null)
            pendingHostCalls.append(call)
            onHostCall?(call)
        }
        let commandResult: @convention(block) (Int, Bool, JSValue) -> Void = { [weak self] token, ok, value in
            let result = (try? PluginValue(javaScript: value)) ?? .null
            if ok {
                self?.commandResults[token] = .success(result)
            } else {
                let object = result.object ?? [:]
                self?.commandResults[token] = .failure(PluginHostError(
                    code: object["code"]?.string ?? "script_error", message: object["message"]?.string ?? "The command failed."
                ))
            }
        }
        native.setObject(commandResult, forKeyedSubscript: "commandResult" as NSString)
        native.setObject(hostCall, forKeyedSubscript: "hostCall" as NSString)
        native.setObject(commit, forKeyedSubscript: "commit" as NSString)
        native.setObject(log, forKeyedSubscript: "log" as NSString)
        native.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        native.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        context.setObject(native, forKeyedSubscript: "__native" as NSString)
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
        context.objectForKeyedSubscript("__playhouseFireTimer")?.call(withArguments: [id])
    }

    private func record(error: String) {
        errors.append(error)
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "Unknown JavaScript error" }
        let message = exception.toString() ?? "Unknown JavaScript error"
        if let line = exception.objectForKeyedSubscript("line"), !line.isUndefined, let source = exception.objectForKeyedSubscript("sourceURL")?.toString(), source != "undefined" {
            return "\(message) (\(URL(fileURLWithPath: source).lastPathComponent):\(line.toInt32()))"
        }
        return message
    }
}

/// Why the host turned down a plugin's call; the plugin's promise rejects
/// with an Error carrying this `code` and `message`.
struct PluginHostError: Error, Equatable, Sendable {
    var code: String
    var message: String
}
