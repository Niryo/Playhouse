import Foundation

/// `playhouse plugin render`: runs a plugin headlessly through the same
/// runtime and node tree the app renders, sends it events by the testID of
/// the atom that raises them, and reports every commit and the final tree.
/// The app's catalog pages run the same way with `page`.
struct PluginRenderCommand: Sendable {
    struct Event: Sendable {
        var testID: String
        var name: String
        var value: String?

        /// `<testID>:<event>[:<value>]`.
        init(parsing text: String) throws {
            let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw PluginTreeError(message: "An event is <testID>:<event>[:<value>], not \"\(text)\".")
            }
            testID = parts[0]
            name = parts[1]
            value = parts.count == 3 ? parts[2] : nil
        }
    }

    var file: String?
    var page: String?
    /// Props under `propsJSON`, such as an installed plugin's placement context.
    var baseProps: [String: PluginValue] = [:]
    var propsJSON: String?
    /// Answers the plugin's `Playhouse.bridge` calls; without one they are
    /// rejected. `Playhouse.ui` calls are recorded and resolved with null.
    var bridge: (@Sendable (String, PluginValue) async throws -> PluginValue)?
    /// An installed plugin's placement, which decides what its host refuses.
    var placement: PluginPlacement?
    var events: [Event] = []
    var advance: Double = 0
    var resources = PluginRuntime.bundledResources

    /// The catalog's pages, each `catalog/<page>.js` in the runtime folder.
    static func catalogPages(resources: URL?) -> [String] {
        guard let folder = resources?.appendingPathComponent("catalog", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".js") }.map { String($0.dropLast(3)) }.sorted()
    }

    /// A catalog page's script and props: the sample data every page receives,
    /// the top-level fields of every `catalog/sample-*.json` in one object
    /// (the task item's `task`, the Agents info section's `agentsInfo`).
    static func catalogPage(_ page: String, resources: URL?) throws -> (source: String, props: [String: PluginValue]) {
        guard let folder = resources?.appendingPathComponent("catalog", isDirectory: true) else {
            throw PluginTreeError(message: "This build has no bundled plugin runtime.")
        }
        guard catalogPages(resources: resources).contains(page) else {
            throw PluginTreeError(message: "Unknown catalog page \"\(page)\". Pages: \(catalogPages(resources: resources).joined(separator: ", ")).")
        }
        let source = try String(contentsOf: folder.appendingPathComponent("\(page).js"), encoding: .utf8)
        let samples = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("sample-") && $0.hasSuffix(".json") }
            .sorted()
        var props: [String: PluginValue] = [:]
        for sample in samples {
            let value = try JSONDecoder().decode(PluginValue.self, from: Data(contentsOf: folder.appendingPathComponent(sample)))
            for (key, field) in value.object ?? [:] {
                guard props[key] == nil else {
                    throw PluginTreeError(message: "Catalog sample \(sample) repeats the field \"\(key)\" of another sample.")
                }
                props[key] = field
            }
        }
        return (source, props)
    }

    func run() async throws -> PluginValue {
        let source: String
        var props = baseProps
        let name: String
        if let page {
            let catalog = try Self.catalogPage(page, resources: resources)
            source = catalog.source
            props.merge(catalog.props) { _, new in new }
            name = "\(page).js"
        } else if let file {
            source = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
            name = URL(fileURLWithPath: file).lastPathComponent
        } else {
            throw PluginTreeError(message: "Pass a plugin file or a catalog page.")
        }
        if let propsJSON {
            guard let object = try? JSONDecoder().decode(PluginValue.self, from: Data(propsJSON.utf8)).object else {
                throw PluginTreeError(message: "--props must be a JSON object.")
            }
            props.merge(object) { _, new in new }
        }

        let runtime = try PluginRuntime(source: source, sourceName: name, props: props, resources: resources, timers: .manual)
        var commits: [PluginValue] = []
        func noteCommit(_ step: String, since before: Int?) {
            guard let commit = runtime.tree.lastCommit, commit.number != before else { return }
            commits.append(.object([
                "step": .string(step),
                "number": .number(Double(commit.number)),
                "ops": .array(commit.ops.map(PluginValue.string)),
                "touchedNodes": .array(commit.touchedNodes.map { .number(Double($0)) })
            ]))
        }
        var hostCalls: [PluginValue] = []
        // Answers every pending host call, then runs the timers its answers
        // scheduled, until the plugin stops calling (bounded, for a loop).
        func settle() async {
            runtime.runDueTimers()
            for _ in 0..<50 {
                guard let call = runtime.pendingHostCalls.first else { return }
                var entry: [String: PluginValue] = ["kind": .string(call.kind), "name": .string(call.name), "arguments": call.arguments]
                let result: Result<PluginValue, PluginHostError>
                if let refusal = PluginHostRules.refusal(kind: call.kind, name: call.name, placement: placement) {
                    result = .failure(refusal)
                } else if call.kind == "bridge", let bridge {
                    do {
                        result = .success(try await bridge(call.name, call.arguments))
                    } catch let error as PluginHostError {
                        result = .failure(error)
                    } catch {
                        result = .failure(PluginHostError(code: "operation_failed", message: error.localizedDescription))
                    }
                } else if call.kind == "bridge" {
                    result = .failure(PluginHostError(code: "unavailable", message: "Bridge calls are not available here."))
                } else {
                    result = .success(.null)
                }
                switch result {
                case .success(let value): entry["ok"] = .bool(true); entry["result"] = value
                case .failure(let error): entry["ok"] = .bool(false); entry["error"] = .object(["code": .string(error.code), "message": .string(error.message)])
                }
                hostCalls.append(.object(entry))
                runtime.answerHostCall(call.id, result: result)
                runtime.runDueTimers()
            }
        }
        // Effects run from a zero-delay scheduler timer; flush them so the tree is settled.
        await settle()
        noteCommit("render", since: nil)
        for event in events where runtime.errors.isEmpty {
            guard let node = Self.find(testID: event.testID, in: runtime.tree.root) else {
                throw PluginTreeError(message: "No atom has testID \"\(event.testID)\".")
            }
            guard node.events.contains(event.name) else {
                throw PluginTreeError(message: "<\(node.type)> \(event.testID) has no \(event.name) handler.")
            }
            let before = runtime.tree.lastCommit?.number
            runtime.dispatch(nodeID: node.id, event: event.name, value: event.value.map(PluginValue.string))
            await settle()
            noteCommit("\(event.testID):\(event.name)", since: before)
        }
        if advance > 0, runtime.errors.isEmpty {
            let before = runtime.tree.lastCommit?.number
            runtime.runDueTimers(advancing: advance)
            await settle()
            noteCommit("advance", since: before)
        }
        return .object([
            "atoms": .array(AtomType.allCases.map { .string($0.rawValue) }),
            "containerAtoms": .array(AtomType.allCases.filter(\.isContainer).map { .string($0.rawValue) }),
            "commits": .array(commits),
            "tree": runtime.tree.snapshot(),
            "errors": .array(runtime.errors.map(PluginValue.string)),
            "hostCalls": .array(hostCalls),
            "log": .array(runtime.log.map { .string("\($0.level): \($0.message)") })
        ])
    }

    static func find(testID: String, in node: PluginNode) -> PluginNode? {
        if node.props["testID"]?.string == testID { return node }
        for child in node.children {
            if let found = find(testID: testID, in: child) { return found }
        }
        return nil
    }
}
