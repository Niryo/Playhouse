import Foundation

/// Static checks on a plugin folder: manifest fields, the view trees against the
/// component catalog, binding syntax, and (unless `logic` is `.skip`) that every
/// action a view names exists in logic.js.
enum PluginValidator {
    static let logicLoadTimeout: TimeInterval = 5
    private static let idPattern = #"^[a-z0-9][a-z0-9-]*$"#
    private static let manifestKeys: Set<String> = ["id", "name", "version", "description", "live", "contributes"]

    /// How logic.js is evaluated to learn its action names.
    enum LogicCheck {
        /// Don't evaluate logic.js; action names aren't checked.
        case skip
        /// On a throwaway plugin thread in this process (`playhouse-plugin-dev`, which runs plugins anyway).
        case inProcess
        /// In a short-lived `playhouse-plugin-dev --list-actions` process, so a runaway
        /// top level is killed instead of spinning inside a long-lived daemon or the app.
        case runner(URL)
        /// The check can't run here; reported as an issue rather than skipped silently.
        case unavailable(String)

        /// The runner beside this executable in the app's Contents/MacOS.
        static var bundledRunner: LogicCheck {
            let runner = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("playhouse-plugin-dev")
            guard let runner, FileManager.default.isExecutableFile(atPath: runner.path) else {
                return .unavailable("playhouse-plugin-dev isn't beside this executable, so logic.js actions weren't checked.")
            }
            return .runner(runner)
        }
    }

    static func validate(directory: URL, logic: LogicCheck) -> [PluginIssue] {
        do {
            return validate(try PluginLoader.load(directory: directory), logic: logic)
        } catch {
            return [PluginIssue(file: fileName(for: error), path: nil, message: error.localizedDescription)]
        }
    }

    static func validate(_ bundle: PluginBundle, logic: LogicCheck) -> [PluginIssue] {
        var issues = manifestIssues(bundle.manifest)
        for contribution in bundle.manifest.views where bundle.views[contribution.id] == nil {
            issues.append(PluginIssue(file: PluginBundle.viewFile, path: nil, message: "plugin.json declares the view \"\(contribution.id)\", but view.json has no tree for it."))
        }
        var actions: [(name: String, path: String)] = []
        for viewID in bundle.views.keys.sorted() {
            guard let root = bundle.views[viewID] else { continue }
            for node in root.allNodes {
                issues += nodeIssues(node, actions: &actions)
            }
        }
        let defined: Result<Set<String>, PluginLoadError>?
        switch logic {
        case .skip: defined = nil
        case .inProcess: defined = logicActions(bundle.logicSource)
        case .runner(let runner): defined = bundle.logicSource == nil ? .success([]) : logicActions(directory: bundle.directory, runner: runner)
        case .unavailable(let reason): defined = bundle.logicSource == nil ? .success([]) : .failure(PluginLoadError(reason))
        }
        if let defined {
            switch defined {
            case .success(let defined):
                for action in actions where !defined.contains(action.name) {
                    issues.append(PluginIssue(file: PluginBundle.viewFile, path: action.path, message: bundle.logicSource == nil
                        ? "The action \"\(action.name)\" needs a logic.js that defines it."
                        : "logic.js has no action named \"\(action.name)\"."))
                }
            case .failure(let error):
                issues.append(PluginIssue(file: PluginBundle.logicFile, path: nil, message: error.localizedDescription))
            }
        }
        return issues
    }

    private static func manifestIssues(_ manifest: PluginManifest) -> [PluginIssue] {
        var issues: [PluginIssue] = []
        func add(_ path: String?, _ message: String) { issues.append(PluginIssue(file: PluginBundle.manifestFile, path: path, message: message)) }
        if manifest.id.range(of: idPattern, options: .regularExpression) == nil {
            add("id", "The id must be lowercase letters, digits and dashes, for example \"pr-radar\".")
        }
        if manifest.name.trimmingCharacters(in: .whitespaces).isEmpty { add("name", "The name is required.") }
        if manifest.version.trimmingCharacters(in: .whitespaces).isEmpty { add("version", "The version is required.") }
        for key in manifest.raw.keys.sorted() where !manifestKeys.contains(key) {
            add(key, "Unknown key \"\(key)\".")
        }
        let contributes = manifest.raw["contributes"]?.object ?? [:]
        if contributes["buttons"] != nil {
            add("contributes.buttons", "Buttons are reserved for a later version; plugins can contribute views only.")
        }
        for key in contributes.keys.sorted() where key != "views" && key != "buttons" {
            add("contributes.\(key)", "Unknown contribution \"\(key)\".")
        }
        let views = contributes["views"]?.array ?? []
        if views.isEmpty { add("contributes.views", "Contribute at least one view.") }
        for (index, view) in views.enumerated() {
            let path = "contributes.views[\(index)]"
            guard let object = view.object, let id = object["id"]?.string, !id.isEmpty else {
                add(path, "Each view needs an \"id\".")
                continue
            }
            if object["placement"] != nil {
                add("\(path).placement", "Placements are reserved for a later version; views open from the Plugins menu.")
            }
            for key in object.keys.sorted() where !["id", "title", "placement"].contains(key) {
                add("\(path).\(key)", "Unknown key \"\(key)\".")
            }
        }
        return issues
    }

    private static func nodeIssues(_ node: PluginViewNode, actions: inout [(name: String, path: String)]) -> [PluginIssue] {
        var issues: [PluginIssue] = []
        func add(_ path: String, _ message: String) { issues.append(PluginIssue(file: PluginBundle.viewFile, path: path, message: message)) }
        guard let spec = PluginComponentCatalog.spec(node.type) else {
            add("\(node.path).type", "Unknown component \"\(node.type)\". Run `playhouse-cli plugin components` for the supported list.")
            return issues
        }
        if !spec.acceptsChildren, !node.children.isEmpty {
            add("\(node.path).children", "\(node.type) doesn't take children.")
        }
        let accepted = PluginComponentCatalog.acceptedPropNames(spec)
        for name in node.props.keys.sorted() {
            let value = node.props[name]!
            let path = "\(node.path).props.\(name)"
            guard accepted.contains(name) else {
                add(path, "\(node.type) has no prop \"\(name)\".")
                continue
            }
            if PluginComponentCatalog.isEventName(name, for: spec) {
                guard let object = value.object, let action = object["action"]?.string, !action.isEmpty else {
                    add(path, "An event must be { \"action\": \"name\", \"payload\": … }.")
                    continue
                }
                for key in object.keys where key != "action" && key != "payload" {
                    add("\(path).\(key)", "Unknown event key \"\(key)\".")
                }
                actions.append((action, "\(path).action"))
                issues += bindingIssues(object["payload"] ?? .null, path: "\(path).payload")
                continue
            }
            issues += bindingIssues(value, path: path)
            let kind = spec.props.first { $0.name == name }?.kind ?? PluginComponentCatalog.commonProps.first { $0.name == name }?.kind ?? .any
            if let problem = typeProblem(value, kind: kind) { add(path, problem) }
        }
        for prop in spec.props where prop.required && node.props[prop.name] == nil {
            add("\(node.path).props", "\(node.type) needs the prop \"\(prop.name)\".")
        }
        return issues
    }

    private static func bindingIssues(_ value: BridgeValue, path: String) -> [PluginIssue] {
        switch value {
        case .string(let text):
            if case .failure(let error) = PluginBindings.expressions(in: text) {
                return [PluginIssue(file: PluginBundle.viewFile, path: path, message: error.message)]
            }
            return []
        case .array(let values):
            return values.enumerated().flatMap { bindingIssues($1, path: "\(path)[\($0)]") }
        case .object(let object):
            return object.keys.sorted().flatMap { bindingIssues(object[$0]!, path: "\(path).\($0)") }
        default:
            return []
        }
    }

    /// Literal values only: a binding is checked when it resolves, not here.
    private static func typeProblem(_ value: BridgeValue, kind: PluginPropKind) -> String? {
        if case .string(let text) = value, text.contains("{{") { return nil }
        switch kind {
        case .any:
            return nil
        case .string:
            return value.string == nil ? "Expected a string." : nil
        case .number:
            return value.number == nil ? "Expected a number." : nil
        case .bool:
            return value.bool == nil ? "Expected true or false." : nil
        case .color:
            guard let text = value.string, PluginComponentCatalog.isValidColor(text) else {
                return "Expected a color: one of \(PluginComponentCatalog.semanticColors.joined(separator: ", ")) or #RRGGBB."
            }
            return nil
        case .options(let options):
            let text = value.string ?? value.number.map { BridgeValue.decimal($0).interpolatedText }
            guard let text, options.contains(text) else { return "Expected one of \(options.joined(separator: ", "))." }
            return nil
        }
    }

    private static var timeoutError: PluginLoadError {
        PluginLoadError("logic.js did not finish loading within \(Int(logicLoadTimeout)) seconds.")
    }

    /// The action names logic.js defines, evaluated on a throwaway thread so a
    /// runaway top level can't block the caller (its thread is abandoned).
    static func logicActions(_ source: String?) -> Result<Set<String>, PluginLoadError> {
        guard let source else { return .success([]) }
        let host = PluginHost(name: "validator", log: PluginLog(capacity: 10), transport: nil)
        let finished = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Set<String>, PluginLoadError>?
        host.perform {
            let outcome: Result<Set<String>, PluginLoadError>
            do {
                outcome = .success(Set(try host.load(logic: source)))
            } catch {
                outcome = .failure(error as? PluginLoadError ?? PluginLoadError(error.localizedDescription))
            }
            lock.lock()
            result = outcome
            lock.unlock()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + logicLoadTimeout)
        // Timers a top level started never fire: the context is dropped here.
        host.stop()
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(timeoutError)
    }

    /// Runs `playhouse-plugin-dev --list-actions <dir>` and kills it after the timeout.
    static func logicActions(directory: URL, runner: URL) -> Result<Set<String>, PluginLoadError> {
        let process = Process()
        process.executableURL = runner
        process.arguments = ["--list-actions", directory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(PluginLoadError("Couldn't start playhouse-plugin-dev to check logic.js: \(error.localizedDescription)"))
        }
        // Read while it runs, so a large reply can't fill the pipe and stall it.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        guard exited.wait(timeout: .now() + logicLoadTimeout) == .success else {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            return .failure(timeoutError)
        }
        _ = drained.wait(timeout: .now() + 2)
        guard let reply = (try? BridgeValue.parsingJSON(String(decoding: data, as: UTF8.self)))?.object else {
            return .failure(PluginLoadError("playhouse-plugin-dev gave no answer while checking logic.js."))
        }
        if let error = reply["error"]?.string { return .failure(PluginLoadError(error)) }
        return .success(Set(reply["actions"]?.strings ?? []))
    }

    private static func fileName(for error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("view.json") { return PluginBundle.viewFile }
        if message.contains("logic.js") { return PluginBundle.logicFile }
        return PluginBundle.manifestFile
    }
}
