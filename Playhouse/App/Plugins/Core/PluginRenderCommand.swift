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
    var propsJSON: String?
    var events: [Event] = []
    var advance: Double = 0
    var resources = PluginRuntime.bundledResources

    /// The catalog's pages, each `catalog/<page>.js` in the runtime folder.
    static func catalogPages(resources: URL?) -> [String] {
        guard let folder = resources?.appendingPathComponent("catalog", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return files.filter { $0.hasSuffix(".js") }.map { String($0.dropLast(3)) }.sorted()
    }

    /// A catalog page's script and props: the sample task data every page receives.
    static func catalogPage(_ page: String, resources: URL?) throws -> (source: String, props: [String: PluginValue]) {
        guard let folder = resources?.appendingPathComponent("catalog", isDirectory: true) else {
            throw PluginTreeError(message: "This build has no bundled plugin runtime.")
        }
        guard catalogPages(resources: resources).contains(page) else {
            throw PluginTreeError(message: "Unknown catalog page \"\(page)\". Pages: \(catalogPages(resources: resources).joined(separator: ", ")).")
        }
        let source = try String(contentsOf: folder.appendingPathComponent("\(page).js"), encoding: .utf8)
        let sample = try JSONDecoder().decode(PluginValue.self, from: Data(contentsOf: folder.appendingPathComponent("sample-task.json")))
        return (source, sample.object ?? [:])
    }

    func run() throws -> PluginValue {
        let source: String
        var props: [String: PluginValue] = [:]
        let name: String
        if let page {
            (source, props) = try Self.catalogPage(page, resources: resources)
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
        // Effects run from a zero-delay scheduler timer; flush them so the tree is settled.
        runtime.runDueTimers()
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
            runtime.runDueTimers()
            noteCommit("\(event.testID):\(event.name)", since: before)
        }
        if advance > 0, runtime.errors.isEmpty {
            let before = runtime.tree.lastCommit?.number
            runtime.runDueTimers(advancing: advance)
            noteCommit("advance", since: before)
        }
        return .object([
            "atoms": .array(AtomType.allCases.map { .string($0.rawValue) }),
            "commits": .array(commits),
            "tree": runtime.tree.snapshot(),
            "errors": .array(runtime.errors.map(PluginValue.string)),
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
