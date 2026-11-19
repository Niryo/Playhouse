import Foundation

/// Something that happened in the app, delivered to plugins: a JavaScript
/// plugin's mounted UI hears it through `Playhouse.on(name, listener)` and its
/// background half in the daemon through `Playhouse.service.on`, a built-in
/// through its view or its daemon service. The payload is plain JSON.
struct PluginEvent: Equatable, Sendable {
    /// A task moved between board columns: `{taskID, from, to}` (statuses as the board names them).
    static let taskStatusChanged = "task.statusChanged"
    /// The app became the active application: `{}`.
    static let appFocus = "app.focus"
    /// A plugin's saved state changed: `{pluginID, key, value}`, targeted at that plugin.
    static let pluginStateChanged = "plugin.stateChanged"
    /// An agent a plugin started with `agent.run` finished:
    /// `{runID, status, result, error, context}`, targeted at that plugin.
    static let agentFinished = "agent.finished"

    /// The app launched: `{}`, once per launch to each plugin, when it is
    /// first mounted, so it can refresh what an earlier launch left.
    static let appLaunched = "app.launched"

    static let names = [taskStatusChanged, appFocus, pluginStateChanged, appLaunched, agentFinished]

    var name: String
    var payload: [String: PluginValue] = [:]
    /// The one plugin the event is for, or nil for an event every plugin may hear.
    /// A targeted event wakes only that plugin's service and mounted runtimes.
    var pluginID: String?

    static func statusChanged(taskID: String, from: String, to: String) -> PluginEvent {
        PluginEvent(name: taskStatusChanged, payload: ["taskID": .string(taskID), "from": .string(from), "to": .string(to)])
    }

    static func stateChanged(pluginID: String, key: String, value: PluginValue) -> PluginEvent {
        PluginEvent(name: pluginStateChanged, payload: ["pluginID": .string(pluginID), "key": .string(key), "value": value], pluginID: pluginID)
    }

    /// `status` is "done", "failed" or "cancelled"; `result` is the run's structured
    /// output or final text, and `context` the value `agent.run` was given, unchanged.
    static func agentFinished(pluginID: String, runID: String, status: String, result: PluginValue, error: String?, context: PluginValue) -> PluginEvent {
        PluginEvent(name: agentFinished, payload: [
            "runID": .string(runID), "status": .string(status), "result": result,
            "error": error.map(PluginValue.string) ?? .null, "context": context
        ], pluginID: pluginID)
    }

    /// Whether the plugin `pluginID` may hear this event: it isn't targeted at another plugin.
    func reaches(_ pluginID: String?) -> Bool {
        self.pluginID == nil || self.pluginID == pluginID
    }

    /// `<name>[:<json payload>]`, as `plugin event` and `plugin render --event @…` take it.
    init(parsing text: String) throws {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.first, !name.isEmpty else {
            throw PluginTreeError(message: "A plugin event is <name>[:<json payload>], not \"\(text)\".")
        }
        var payload: [String: PluginValue] = [:]
        if parts.count == 2 {
            guard let object = try? JSONDecoder().decode(PluginValue.self, from: Data(parts[1].utf8)).object else {
                throw PluginTreeError(message: "A plugin event's payload must be a JSON object.")
            }
            payload = object
        }
        self.init(name: name, payload: payload, pluginID: Self.target(of: name, payload: payload))
    }

    /// The plugin an event given by name and payload (`plugin event`, `--event`) is
    /// targeted at: a state change's or an agent run's `pluginID`.
    static func target(of name: String, payload: [String: PluginValue]) -> String? {
        [pluginStateChanged, agentFinished].contains(name) ? payload["pluginID"]?.string : nil
    }

    init(name: String, payload: [String: PluginValue] = [:], pluginID: String? = nil) {
        self.name = name
        self.payload = payload
        self.pluginID = pluginID
    }
}

/// Keeps a noisy trigger (every focus, every column move) from flooding a
/// slow or rate-limited service such as GitHub: per key, the first call runs
/// at once; calls made while it runs or within `interval` after it started
/// collapse into one trailing call when the interval is up. Plugins get the
/// same helper as `Playhouse.throttle(fn, seconds)`.
@MainActor
final class PluginThrottle {
    private struct Entry {
        var lastStart: Date?
        var running = false
        var pending = false
        var timerScheduled = false
        /// The interval the latest call asked for, which its trailing call keeps.
        var interval: TimeInterval?
    }

    /// Shared by everything that throttles the same work, such as the task
    /// card's pull request probes and the board's, keyed by what they guard.
    static let shared = PluginThrottle(interval: PluginThrottle.defaultInterval)

    /// 20 seconds; tests shorten it with `PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS`.
    /// What they check (calls suppressed while one runs, then exactly one trailing
    /// call) does not depend on its length.
    nonisolated static var defaultInterval: TimeInterval {
        ProcessInfo.processInfo.environment["PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS"].flatMap(TimeInterval.init) ?? 20
    }

    let interval: TimeInterval
    private var entries: [String: Entry] = [:]
    private var operations: [String: @MainActor () async -> Void] = [:]

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Runs `operation` now, or once later when `key` ran too recently or is still running.
    /// The latest operation passed for a key is the one a trailing call runs. `interval`
    /// overrides the throttle's own for this call (a daemon reads it per request).
    func run(_ key: String, interval: TimeInterval? = nil, _ operation: @escaping @MainActor () async -> Void) {
        operations[key] = operation
        var entry = entries[key] ?? Entry()
        if let interval { entry.interval = interval }
        let interval = entry.interval ?? self.interval
        if entry.running {
            entry.pending = true
            entries[key] = entry
            return
        }
        if let lastStart = entry.lastStart {
            let remaining = interval - Date().timeIntervalSince(lastStart)
            if remaining > 0 {
                entry.pending = true
                if !entry.timerScheduled {
                    entry.timerScheduled = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(remaining))
                        self?.fireTrailing(key)
                    }
                }
                entries[key] = entry
                return
            }
        }
        start(key, entry: entry)
    }

    /// Forgets `key`'s cooldown, so its next call runs at once (after a change
    /// that makes the last result stale, such as a merge).
    func reset(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.lastStart = nil
        entries[key] = entry
    }

    private func fireTrailing(_ key: String) {
        guard var entry = entries[key] else { return }
        entry.timerScheduled = false
        entries[key] = entry
        guard entry.pending, !entry.running else { return }
        start(key, entry: entry)
    }

    private func start(_ key: String, entry: Entry) {
        var entry = entry
        entry.lastStart = Date()
        entry.running = true
        entry.pending = false
        entries[key] = entry
        guard let operation = operations[key] else { return }
        Task { @MainActor [weak self] in
            await operation()
            guard let self, var entry = entries[key] else { return }
            entry.running = false
            entries[key] = entry
            if entry.pending { run(key, interval: entry.interval, operations[key] ?? {}) }
        }
    }
}
