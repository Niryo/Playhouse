import Foundation
import JavaScriptCore

/// A dedicated thread with its own run loop. A plugin's JSContext is created and
/// used only on its thread, so a slow plugin never blocks the app, the daemon or
/// other plugins.
final class PluginThread: Thread {
    private let ready = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?

    init(name: String) {
        super.init()
        self.name = name
        qualityOfService = .userInitiated
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A port keeps the run loop alive while nothing else is scheduled.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
    }

    /// Starts the thread and waits until it can accept work.
    func startAndWait() {
        start()
        ready.wait()
    }

    func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func stop() {
        cancel()
        perform { CFRunLoopStop(CFRunLoopGetCurrent()) }
    }
}

/// One plugin's JavaScript runtime. Apart from `perform`, `stop` and `busySince`,
/// every method must be called on the host's thread.
final class PluginHost {
    let thread: PluginThread
    private let log: PluginLog
    private let transport: PluginDaemonTransport?
    private var context: JSContext?
    private var timers: [Int: Timer] = [:]
    private var actionCompletions: [Int: (String?) -> Void] = [:]
    private var finishedActions: [() -> Void] = []
    private var nextActionToken = 1
    private var entryDepth = 0
    private let busyLock = NSLock()
    private var busyStart: Date?

    /// Runs on the host thread after every call into JavaScript has returned, so
    /// the session can snapshot state, including what async continuations changed.
    var onTurnEnded: (() -> Void)?

    init(name: String, log: PluginLog, transport: PluginDaemonTransport?) {
        thread = PluginThread(name: "Playhouse plugin \(name)")
        self.log = log
        self.transport = transport
        thread.startAndWait()
    }

    func perform(_ block: @escaping () -> Void) { thread.perform(block) }

    func stop() {
        perform { [self] in
            timers.values.forEach { $0.invalidate() }
            timers.removeAll()
            context = nil
        }
        thread.stop()
    }

    /// When the current call into JavaScript began, or nil while idle.
    var busySince: Date? {
        busyLock.lock()
        defer { busyLock.unlock() }
        return busyStart
    }

    /// Creates the context, evaluates logic.js and returns the action names it defines.
    func load(logic: String?) throws -> [String] {
        let context = JSContext(virtualMachine: JSVirtualMachine())!
        context.name = thread.name ?? "Playhouse plugin"
        var loadError: String?
        context.exceptionHandler = { [weak self] _, exception in
            let message = PluginScript.describe(exception)
            if self?.isLoading == true { loadError = loadError ?? message }
            self?.log.append(.exception, message)
        }
        context.setObject(nativeFunctions() as NSDictionary, forKeyedSubscript: "__playhouseNative" as NSString)
        context.evaluateScript(PluginScript.prelude, withSourceURL: URL(string: "playhouse://prelude.js"))
        self.context = context
        isLoading = true
        defer { isLoading = false }
        let actionsJSON: String? = enter {
            if let logic {
                context.evaluateScript(PluginScript.strippingExports(logic), withSourceURL: URL(string: "logic.js"))
            }
            guard loadError == nil else { return nil }
            context.evaluateScript(PluginScript.epilogue)
            return context.objectForKeyedSubscript("__playhouse")?.invokeMethod("start", withArguments: [])?.toString()
        }
        if let loadError { throw PluginLoadError("logic.js failed to load: \(loadError)") }
        guard let actionsJSON, case .array(let names)? = try? BridgeValue.parsingJSON(actionsJSON) else {
            throw PluginLoadError("logic.js's initialState must be JSON-serializable.")
        }
        return names.compactMap(\.string)
    }

    private var isLoading = false

    /// The current state as JSON.
    func state() -> BridgeValue {
        guard let text = context?.objectForKeyedSubscript("__playhouse")?.invokeMethod("state", withArguments: [])?.toString() else {
            return .null
        }
        return (try? BridgeValue.parsingJSON(text)) ?? .null
    }

    /// Runs `actions[name](state, payload, api)`; `completion` gets nil or the error once the action settles.
    func dispatch(_ name: String, payload: BridgeValue, completion: @escaping (String?) -> Void) {
        guard let context else { return completion("The plugin isn't loaded.") }
        let token = nextActionToken
        nextActionToken += 1
        actionCompletions[token] = completion
        enter {
            _ = context.objectForKeyedSubscript("__playhouse")?.invokeMethod("dispatch", withArguments: [name, payload.jsonText, token])
        }
    }

    @discardableResult
    private func enter<T>(_ body: () -> T) -> T {
        entryDepth += 1
        if entryDepth == 1 { setBusy(Date()) }
        let result = body()
        entryDepth -= 1
        if entryDepth == 0 {
            setBusy(nil)
            if !isLoading { onTurnEnded?() }
            // Completions run after the turn's snapshot, so a caller that waits
            // for an action always sees the state that action left.
            let finished = finishedActions
            finishedActions.removeAll()
            finished.forEach { $0() }
        }
        return result
    }

    private func setBusy(_ date: Date?) {
        busyLock.lock()
        busyStart = date
        busyLock.unlock()
    }

    private func fireTimer(_ id: Int, repeats: Bool) {
        if !repeats { timers[id] = nil }
        guard let context else { return }
        enter {
            _ = context.objectForKeyedSubscript("__playhouse")?.invokeMethod("fireTimer", withArguments: [id])
        }
    }

    private func settle(_ token: Int, result: Result<BridgeValue, Error>) {
        guard let context else { return }
        enter {
            let playhouse = context.objectForKeyedSubscript("__playhouse")
            switch result {
            case .success(let value):
                _ = playhouse?.invokeMethod("settle", withArguments: [token, true, value.jsonText])
            case .failure(let error):
                _ = playhouse?.invokeMethod("settle", withArguments: [token, false, error.localizedDescription])
            }
        }
    }

    private func nativeFunctions() -> [String: Any] {
        let logBlock: @convention(block) (String, String) -> Void = { [weak self] level, message in
            self?.log.append(PluginLogEntry.Level(rawValue: level) ?? .log, message)
        }
        let scheduleBlock: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, milliseconds, repeats in
            guard let self else { return }
            let timer = Timer(timeInterval: max(milliseconds / 1000, 0.001), repeats: repeats) { [weak self] _ in
                self?.fireTimer(id, repeats: repeats)
            }
            RunLoop.current.add(timer, forMode: .default)
            timers[id] = timer
        }
        let cancelBlock: @convention(block) (Int) -> Void = { [weak self] id in
            self?.timers.removeValue(forKey: id)?.invalidate()
        }
        let callBlock: @convention(block) (Int, String, String) -> Void = { [weak self] token, command, argumentsJSON in
            guard let self else { return }
            let arguments = (try? BridgeValue.parsingJSON(argumentsJSON))?.object ?? [:]
            guard let transport else {
                log.append(.api, "api.call \(command) failed: this host has no daemon connection.")
                perform { [weak self] in
                    self?.settle(token, result: .failure(PluginTransportError(message: "api.call is unavailable: this host has no daemon connection.")))
                }
                return
            }
            log.append(.api, "api.call \(command) \(argumentsJSON)")
            transport.call(command: command, arguments: arguments) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: log.append(.api, "api.call \(command) succeeded")
                case .failure(let error): log.append(.api, "api.call \(command) failed: \(error.localizedDescription)")
                }
                perform { [weak self] in self?.settle(token, result: result) }
            }
        }
        let doneBlock: @convention(block) (Int, JSValue) -> Void = { [weak self] token, error in
            guard let self, let completion = actionCompletions.removeValue(forKey: token) else { return }
            let message = error.isNull || error.isUndefined ? nil : error.toString()
            finishedActions.append { completion(message) }
        }
        return [
            "log": logBlock,
            "schedule": scheduleBlock,
            "cancel": cancelBlock,
            "call": callBlock,
            "done": doneBlock,
        ]
    }
}

struct PluginTransportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
