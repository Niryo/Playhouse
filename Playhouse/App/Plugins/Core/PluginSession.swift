import Foundation

/// Everything a renderer or the dev runner needs to show one plugin view.
struct PluginSnapshot {
    var revision = 0
    /// Increments on every load, so observers can tell a reload from an update.
    var loadCount = 0
    var manifest: PluginManifest?
    var viewID: String?
    var state: BridgeValue = .null
    var tree: PluginResolvedNode?
    var actions: [String] = []
    var issues: [PluginIssue] = []
    /// Why the plugin couldn't load or render, or why it stopped.
    var error: String?
    var hung = false
    /// Why the last action failed; cleared by the next action that succeeds.
    var actionError: String?
}

enum PluginActionOutcome: Equatable {
    case completed
    case failed(String)
}

/// One running plugin view: loads the folder, runs logic.js on its own thread,
/// resolves the view against state after every turn, and turns taps and edits
/// on numbered nodes into actions. The app and `playhouse-plugin-dev` both drive
/// plugins through this one type.
final class PluginSession {
    static let hangTimeout: TimeInterval = 10

    let directory: URL
    let log = PluginLog()
    /// Runs on the plugin thread (or the watchdog's queue for a hang) after every change.
    var onSnapshot: ((PluginSnapshot) -> Void)?

    private let requestedViewID: String?
    private let transport: PluginDaemonTransport?
    private let watchFiles: Bool
    private let allocator = PluginNodeIDAllocator()
    private let lock = NSLock()
    private var current = PluginSnapshot()
    private var host: PluginHost?
    private var generation = 0
    private var root: PluginViewNode?
    private var appearedNodeIDs: Set<Int> = []
    private var outstanding: [UUID: (PluginActionOutcome) -> Void] = [:]
    private var watchdog: DispatchSourceTimer?
    private var watcher: DispatchSourceTimer?
    private var fingerprint = ""
    private var stopped = false

    init(directory: URL, viewID: String? = nil, transport: PluginDaemonTransport? = nil, watchFiles: Bool = false) {
        self.directory = directory.standardizedFileURL
        requestedViewID = viewID
        self.transport = transport
        self.watchFiles = watchFiles
    }

    deinit { stop() }

    var snapshot: PluginSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func start() {
        startWatchdog()
        if watchFiles { startWatcher() }
        reload()
    }

    /// Discards the running copy and loads the folder again; state resets to `initialState`.
    func reload() {
        lock.lock()
        guard !stopped else { return lock.unlock() }
        generation += 1
        let generation = generation
        let previous = host
        let host = PluginHost(name: directory.lastPathComponent, log: log, transport: transport)
        self.host = host
        fingerprint = PluginLoader.fingerprint(directory: directory)
        let waiting = outstanding
        outstanding.removeAll()
        lock.unlock()
        waiting.values.forEach { $0(.failed("The plugin was reloaded before the action finished.")) }
        previous?.stop()
        host.onTurnEnded = { [weak self, weak host] in
            guard let host else { return }
            self?.render(generation: generation, host: host)
        }
        host.perform { [weak self] in self?.load(host: host, generation: generation) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let host = host
        self.host = nil
        let waiting = outstanding
        outstanding.removeAll()
        watchdog?.cancel()
        watcher?.cancel()
        watchdog = nil
        watcher = nil
        lock.unlock()
        waiting.values.forEach { $0(.failed("The plugin was stopped.")) }
        host?.stop()
    }

    /// Runs the node's `onTap` action.
    func tap(nodeID: Int, completion: @escaping (PluginActionOutcome) -> Void) {
        fire(nodeID: nodeID, event: "onTap", value: nil, completion: completion)
    }

    /// Runs the node's `onChange` action with text typed for it, read as the kind of
    /// value the control reports: `true` for a toggle, `3` for a slider, text otherwise.
    func input(nodeID: Int, text: String, completion: @escaping (PluginActionOutcome) -> Void) {
        let kind = snapshot.tree?.allNodes.first { $0.id == nodeID }
            .flatMap { PluginComponentCatalog.spec($0.type) }
            .flatMap { PluginComponentCatalog.event("onChange", for: $0)?.valueKind }
        let value: BridgeValue
        switch kind {
        case .bool?:
            guard let flag = ["true": true, "false": false][text.lowercased()] else {
                return completion(.failed("Node \(nodeID) takes true or false."))
            }
            value = .boolean(flag)
        case .number?:
            guard let number = Double(text) else { return completion(.failed("Node \(nodeID) takes a number.")) }
            value = number == number.rounded() && abs(number) < 1e15 ? .integer(Int(number)) : .decimal(number)
        default:
            value = .string(text)
        }
        fire(nodeID: nodeID, event: "onChange", value: value, completion: completion)
    }

    /// Runs any of the node's event actions, with `{ value }` merged into its payload when the event carries one.
    func fire(nodeID: Int, event: String, value: BridgeValue?, completion: @escaping (PluginActionOutcome) -> Void) {
        trigger(nodeID: nodeID, event: event, value: value, completion: completion)
    }

    func tap(nodeID: Int) { tap(nodeID: nodeID) { _ in } }
    func input(nodeID: Int, text: String) { input(nodeID: nodeID, text: text) { _ in } }
    func fire(nodeID: Int, event: String, value: BridgeValue?) { fire(nodeID: nodeID, event: event, value: value) { _ in } }

    // MARK: - Plugin thread

    private func load(host: PluginHost, generation: Int) {
        var snapshot = PluginSnapshot()
        snapshot.loadCount = self.snapshot.loadCount + 1
        do {
            let bundle = try PluginLoader.load(directory: directory)
            snapshot.manifest = bundle.manifest
            snapshot.issues = PluginValidator.validate(bundle, logic: .skip)
            guard let viewID = requestedViewID ?? bundle.manifest.views.first?.id ?? bundle.views.keys.sorted().first else {
                throw PluginLoadError("The plugin has no views; add one to plugin.json and view.json.")
            }
            snapshot.viewID = viewID
            guard let root = bundle.views[viewID] else {
                throw PluginLoadError("view.json has no view named \"\(viewID)\".")
            }
            snapshot.actions = try host.load(logic: bundle.logicSource)
            guard isCurrent(generation) else { return }
            lock.lock()
            self.root = root
            appearedNodeIDs = []
            lock.unlock()
            log.append(.lifecycle, snapshot.loadCount == 1 ? "Loaded \(bundle.manifest.id)." : "Reloaded \(bundle.manifest.id).")
            publish(snapshot, generation: generation)
            render(generation: generation, host: host)
        } catch {
            guard isCurrent(generation) else { return }
            lock.lock()
            root = nil
            lock.unlock()
            snapshot.error = error.localizedDescription
            log.append(.lifecycle, "Couldn't load: \(error.localizedDescription)")
            publish(snapshot, generation: generation)
        }
    }

    private func render(generation: Int, host: PluginHost) {
        guard isCurrent(generation) else { return }
        lock.lock()
        let root = root
        var snapshot = current
        lock.unlock()
        guard let root, let viewID = snapshot.viewID else { return }
        snapshot.state = host.state()
        let tree = PluginTreeResolver(allocator: allocator).resolve(root, viewID: viewID, state: snapshot.state)
        snapshot.tree = tree
        guard publish(snapshot, generation: generation) else { return }

        // onAppear runs when a node enters the tree, in the app and the runner alike.
        let nodes = tree.allNodes
        lock.lock()
        let appearing = nodes.filter { $0.events["onAppear"] != nil && !appearedNodeIDs.contains($0.id) }
        appearedNodeIDs = Set(nodes.map(\.id))
        lock.unlock()
        for node in appearing {
            guard let binding = node.events["onAppear"] else { continue }
            host.perform { [weak self] in self?.run(binding, host: host, generation: generation) { _ in } }
        }
    }

    private func trigger(nodeID: Int, event: String, value: BridgeValue?, completion: @escaping (PluginActionOutcome) -> Void) {
        let snapshot = self.snapshot
        guard !snapshot.hung else {
            return completion(.failed("The plugin is hung; reload it to start a fresh copy."))
        }
        guard let tree = snapshot.tree else {
            return completion(.failed(snapshot.error ?? "The plugin hasn't rendered yet."))
        }
        guard let node = tree.allNodes.first(where: { $0.id == nodeID }) else {
            return completion(.failed("There is no node \(nodeID) in the current view."))
        }
        guard var binding = node.events[event] else {
            return completion(.failed("Node \(nodeID) (\(node.type)) has no \(event) action."))
        }
        // A disabled element can't be used in the app, so the runner refuses it too.
        if node.props["disabled"]?.isTruthy == true {
            return completion(.failed("Node \(nodeID) (\(node.type)) is disabled."))
        }
        let spec = PluginComponentCatalog.spec(node.type)
        // A dialog or popover that isn't showing can't be answered.
        if spec?.presentation == true, node.props["open"]?.isTruthy != true {
            return completion(.failed("Node \(nodeID) (\(node.type)) is closed."))
        }
        if let problem = valueProblem(value, event: event, node: node, spec: spec) {
            return completion(.failed("Node \(nodeID) (\(node.type)) \(event): \(problem)"))
        }
        if let value {
            switch binding.payload {
            case .object(var object):
                object["value"] = value
                binding.payload = .object(object)
            case .null:
                binding.payload = .object(["value": value])
            default:
                binding.payload = .object(["value": value, "payload": binding.payload])
            }
        }
        lock.lock()
        let generation = generation
        let host = host
        lock.unlock()
        guard let host else { return completion(.failed("The plugin was stopped.")) }
        host.perform { [weak self] in
            guard let self else { return completion(.failed("The plugin was stopped.")) }
            run(binding, host: host, generation: generation, completion: completion)
        }
    }

    /// Why `value` isn't something this event can carry, or nil when it is fine.
    private func valueProblem(_ value: BridgeValue?, event: String, node: PluginResolvedNode, spec: PluginComponentSpec?) -> String? {
        let eventSpec = spec.flatMap { PluginComponentCatalog.event(event, for: $0) }
        guard let kind = eventSpec?.valueKind else {
            return value == nil ? nil : "the event carries no value."
        }
        guard let value else { return "the event needs a \(kind.label) value." }
        switch kind {
        case .bool where value.bool == nil: return "expected true or false."
        case .number where value.number == nil: return "expected a number."
        case .string where value.string == nil: return "expected a string."
        default: break
        }
        if let source = eventSpec?.valueFrom {
            let allowed = (node.props[source]?.array ?? []).compactMap { $0.string ?? $0.object?["value"]?.string }
            if !allowed.contains(value.string ?? "") {
                return "\(value.jsonText) isn't one of the options (\(allowed.joined(separator: ", ")))."
            }
        }
        return nil
    }

    private func run(_ binding: PluginEventBinding, host: PluginHost, generation: Int, completion: @escaping (PluginActionOutcome) -> Void) {
        guard isCurrent(generation) else { return completion(.failed("The plugin was reloaded.")) }
        let token = UUID()
        lock.lock()
        outstanding[token] = completion
        lock.unlock()
        host.dispatch(binding.action, payload: binding.payload) { [weak self] error in
            guard let self else { return }
            if let error { log.append(.exception, "Action \(binding.action) failed: \(error)") }
            setActionError(error.map { "Action \(binding.action) failed: \($0)" }, generation: generation)
            lock.lock()
            let completion = outstanding.removeValue(forKey: token)
            lock.unlock()
            completion?(error.map(PluginActionOutcome.failed) ?? .completed)
        }
    }

    /// Shows a failed action inline in the view (and in the runner's snapshot) until an action succeeds.
    private func setActionError(_ message: String?, generation: Int) {
        lock.lock()
        let unchanged = current.actionError == message
        var snapshot = current
        lock.unlock()
        guard !unchanged else { return }
        snapshot.actionError = message
        publish(snapshot, generation: generation)
    }

    // MARK: - Helpers

    private var currentHost: PluginHost? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation && !stopped
    }

    /// Publishes `snapshot` unless a reload or stop has replaced its generation;
    /// returns whether it was published. The check and the update share the lock,
    /// so a stale render from a previous copy can never overwrite a newer load.
    @discardableResult
    private func publish(_ snapshot: PluginSnapshot, generation: Int) -> Bool {
        lock.lock()
        guard generation == self.generation, !stopped else {
            lock.unlock()
            return false
        }
        var snapshot = snapshot
        snapshot.revision = current.revision + 1
        snapshot.hung = current.hung && snapshot.loadCount == current.loadCount
        current = snapshot
        let handler = onSnapshot
        lock.unlock()
        handler?(snapshot)
        return true
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkForHang() }
        lock.lock()
        watchdog = timer
        lock.unlock()
        timer.resume()
    }

    private func checkForHang() {
        guard let host = currentHost, let since = host.busySince,
              Date().timeIntervalSince(since) > Self.hangTimeout, !snapshot.hung else { return }
        let message = "logic.js has run for more than \(Int(Self.hangTimeout)) seconds without yielding, so the plugin is marked hung. Reload it to start a fresh copy."
        log.append(.lifecycle, message)
        lock.lock()
        current.hung = true
        current.error = message
        current.revision += 1
        let snapshot = current
        let waiting = outstanding
        outstanding.removeAll()
        let handler = onSnapshot
        lock.unlock()
        waiting.values.forEach { $0(.failed(message)) }
        handler?(snapshot)
    }

    private func startWatcher() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let latest = PluginLoader.fingerprint(directory: directory)
            lock.lock()
            let changed = latest != fingerprint
            lock.unlock()
            if changed { reload() }
        }
        lock.lock()
        watcher = timer
        lock.unlock()
        timer.resume()
    }
}
