import Foundation

/// A plugin's background half: it hears the app's events in the bridge
/// daemon, whether or not a window shows the plugin, and acts only through
/// bridge commands, the same ones a JavaScript plugin's `Playhouse.bridge`
/// reaches. A built-in's is Swift; a script plugin's is
/// `JavaScriptPluginService`, which runs its `Playhouse.service.on` handlers.
@MainActor
protocol PluginService: AnyObject {
    var pluginID: String { get }
    /// The events the service hears (a script plugin's manifest `events`), or
    /// nil for a built-in, which hears every event not targeted at another plugin.
    var events: Set<String>? { get }
    func handle(_ event: PluginEvent, context: PluginServiceContext) async
    /// Whether the service still wants `action` done for `taskID`, asked by a
    /// command it started right before an irreversible step (a merge, a fix
    /// turn), since the user may have changed their mind while it probed.
    func confirms(_ action: String, taskID: String, context: PluginServiceContext) async -> Bool
}

extension PluginService {
    var events: Set<String>? { nil }

    func confirms(_ action: String, taskID: String, context: PluginServiceContext) async -> Bool { true }
}

/// What a service may do: run bridge commands as the request whose change
/// raised the event, so they reach the same store, settings and fixtures.
@MainActor
struct PluginServiceContext {
    let origin: BridgeRequest

    func call(_ command: String, _ arguments: [String: PluginValue] = [:]) async throws -> PluginValue {
        var nested = origin
        nested.id = UUID().uuidString
        nested.command = command
        nested.arguments = origin.arguments.filter { $0.key.hasPrefix("__") }
            .merging(BridgeValue(plugin: .object(arguments)).object ?? [:]) { _, new in new }
        let response = await PlayhouseBridgeRuntime().perform(nested) { _ in }
        guard response.ok else {
            throw PluginHostError(code: response.error?.code ?? "operation_failed", message: response.error?.message ?? "The bridge command failed.")
        }
        return PluginValue(bridge: response.result ?? .null)
    }

    /// The plugin's saved state, or nil when the user disabled the plugin.
    func enabledState(of pluginID: String) async -> [String: PluginValue]? {
        guard let value = try? await call("plugin.state.get", ["pluginID": .string(pluginID)]).object,
              value["enabled"] != .bool(false) else { return nil }
        return value["state"]?.object ?? [:]
    }
}

/// Delivers app events to the plugins' services. The bridge daemon installs
/// the built-ins' and finds the script plugins' (`scriptServices`); a window
/// forwards the changes it saves itself to the daemon (`plugin.event`), so each
/// change reaches the services once. An event wakes only the services it is
/// for: a targeted one only its plugin's, and a script plugin only for the
/// events its manifest lists.
@MainActor
enum PluginServiceHost {
    /// The request being performed, whose isolation a service's commands reuse.
    @TaskLocal static var origin: BridgeRequest?

    nonisolated(unsafe) static var services: [any PluginService] = []
    /// Set in the daemon: the script plugins' services for the store `context`'s
    /// request reaches, found afresh for each event, so a plugin saved, deleted,
    /// enabled or disabled is heard (or not) from its next event on.
    nonisolated(unsafe) static var scriptServices: (@MainActor (PluginServiceContext) async -> [any PluginService])?
    /// Set in the app: sends an event it raised to the daemon's services.
    nonisolated(unsafe) static var forward: ((PluginEvent) -> Void)?

    private static var running: [UUID: (taskID: String?, task: Task<Void, Never>)] = [:]

    /// How many events in a row may each be raised by a service's reaction to the one
    /// before. A service's requests carry the depth of the event it heard (`__pluginEventDepth`),
    /// so two services that keep waking each other, or one that wakes itself through
    /// another event, stop here instead of running for as long as the daemon lives.
    /// The depth never resets along a context's life: work that reuses its context (the
    /// pull request mode's polls) stays at its depth, but a chain that keeps going deeper,
    /// such as many fix turns each raising a move, ends here (`plugin.event.dropped`).
    static let maximumEventDepth = 8

    static func eventDepth(of request: BridgeRequest) -> Int {
        request.arguments["__pluginEventDepth"]?.int ?? 0
    }

    static func publish(_ event: PluginEvent) {
        if let forward {
            forward(event)
            return
        }
        guard !services.isEmpty || scriptServices != nil else { return }
        guard let origin else {
            PlayhouseDiagnostics.record("plugin.event.dropped", fields: ["name": event.name, "reason": "no-origin-request"])
            return
        }
        let depth = eventDepth(of: origin)
        guard depth < maximumEventDepth else {
            PlayhouseDiagnostics.record("plugin.event.dropped", fields: [
                "name": event.name, "target": event.pluginID ?? "", "reason": "event-chain-too-deep", "depth": String(depth)
            ])
            return
        }
        PlayhouseDiagnostics.record("plugin.event.published", fields: [
            "name": event.name, "taskID": event.payload["taskID"]?.string ?? "", "to": event.payload["to"]?.string ?? "",
            "target": event.pluginID ?? ""
        ])
        // What the services do in reaction is one event further down the chain.
        var reacting = origin
        reacting.arguments["__pluginEventDepth"] = .integer(depth + 1)
        let context = PluginServiceContext(origin: reacting)
        let taskID = event.payload["taskID"]?.string
        for service in services where accepts(service, event) {
            start(service, event, context: context, taskID: taskID)
        }
        guard let scriptServices else { return }
        // A script service never hears its own state writes, so a handler that
        // saves state can't wake itself over and over.
        let writer = origin.arguments["__pluginService"]?.string
        if event.name == PluginEvent.pluginStateChanged, let writer, event.pluginID == writer { return }
        let id = UUID()
        BridgeBackgroundWork.onBegin?()
        // Script handlers are third-party code: they are background work, but a
        // move that waits for its reactions (`settle`) waits only for the built-ins'.
        let task = Task { @MainActor in
            for service in await scriptServices(context) where accepts(service, event) {
                start(service, event, context: context, taskID: nil)
            }
            running[id] = nil
            BridgeBackgroundWork.onEnd?()
        }
        running[id] = (nil, task)
    }

    /// Whether `service` hears `event`: it isn't targeted at another plugin and,
    /// for a script plugin, its manifest lists it.
    static func accepts(_ service: any PluginService, _ event: PluginEvent) -> Bool {
        event.reaches(service.pluginID) && service.events?.contains(event.name) != false
    }

    private static func start(_ service: any PluginService, _ event: PluginEvent, context: PluginServiceContext, taskID: String?) {
        let id = UUID()
        // The daemon stays up until the service has acted.
        BridgeBackgroundWork.onBegin?()
        let task = Task { @MainActor in
            if await context.enabledState(of: service.pluginID) != nil {
                await service.handle(event, context: context)
            }
            running[id] = nil
            BridgeBackgroundWork.onEnd?()
        }
        // The task can't start before this main-actor turn ends, so it's
        // recorded before it can remove itself.
        running[id] = (taskID, task)
    }

    /// Asks the service of `pluginID` whether it still wants `action` done for
    /// `taskID` (see `PluginService.confirms`); true when no such service runs here.
    static func confirm(pluginID: String, action: String, taskID: String, origin: BridgeRequest) async -> Bool {
        guard let service = services.first(where: { $0.pluginID == pluginID }) else { return true }
        return await service.confirms(action, taskID: taskID, context: PluginServiceContext(origin: origin))
    }

    /// Waits for the services' reactions to the events raised for `taskID`
    /// so far, so a command that moved the task returns once, for example,
    /// the pull request mode has created its pull requests. Work a service
    /// starts in the background (an autopilot pass) is not waited for.
    static func settle(taskID: UUID) async {
        let id = taskID.uuidString
        while let next = running.values.first(where: { $0.taskID == id }) {
            await next.task.value
        }
    }
}
