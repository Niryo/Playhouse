import Foundation

/// A script plugin's background half in the daemon: for each event its
/// manifest lists in `events`, `plugin.service` loads its script into a fresh
/// service runtime with the placement's props (the plugin and its state),
/// runs its `Playhouse.service.on` handlers until their promises settle (or
/// time out) and throws the runtime away. Its bridge calls run as the request
/// that raised the event; its state is all it remembers between events.
@MainActor
final class JavaScriptPluginService: PluginService {
    let pluginID: String
    private(set) var events: Set<String>?
    /// Focus events arrive each time the user comes back to the app; they
    /// collapse per plugin, as the built-ins' do. Events with a payload of their
    /// own (a move, a state change, an agent's result) are each delivered.
    private let throttle = PluginThrottle(interval: PluginThrottle.defaultInterval)

    init(pluginID: String, events: Set<String>) {
        self.pluginID = pluginID
        self.events = events
    }

    /// 20 seconds; tests shorten it with `PLAYHOUSE_E2E_PLUGIN_SERVICE_COOLDOWN_SECONDS`.
    static var focusInterval: TimeInterval {
        PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_PLUGIN_SERVICE_COOLDOWN_SECONDS"].flatMap(TimeInterval.init) ?? 20
    }

    func handle(_ event: PluginEvent, context: PluginServiceContext) async {
        guard event.name == PluginEvent.appFocus else {
            await deliver(event, context: context)
            return
        }
        throttle.run("\(pluginID)|\(event.name)", interval: Self.focusInterval) { [weak self] in
            BridgeBackgroundWork.onBegin?()
            await self?.deliver(event, context: context)
            BridgeBackgroundWork.onEnd?()
        }
    }

    private func deliver(_ event: PluginEvent, context: PluginServiceContext) async {
        do {
            let report = try await context.call("plugin.service", [
                "pluginID": .string(pluginID),
                "deliver": .object(["name": .string(event.name), "payload": .object(event.payload)])
            ]).object ?? [:]
            let errors = (report["errors"]?.array ?? []).compactMap(\.string)
            PlayhouseDiagnostics.record(errors.isEmpty ? "plugin.service.handled" : "plugin.service.failed", fields: [
                "pluginID": pluginID, "name": event.name,
                "hostCalls": String(report["hostCalls"]?.array?.count ?? 0),
                "errors": errors.joined(separator: " | ")
            ])
        } catch {
            PlayhouseDiagnostics.record("plugin.service.failed", fields: ["pluginID": pluginID, "name": event.name, "errors": error.localizedDescription])
        }
    }

    // MARK: - The daemon's script services

    /// One service per plugin and store, so a plugin's focus cooldown carries
    /// across events; a test's isolated store gets its own.
    private static var instances: [String: JavaScriptPluginService] = [:]

    /// The enabled, valid script plugins with `events` in the store `context`
    /// reaches, read afresh each time (`plugin.services`).
    static func services(_ context: PluginServiceContext) async -> [any PluginService] {
        guard let listed = try? await context.call("plugin.services").object?["services"]?.array else { return [] }
        let scope = context.origin.dataDirectory ?? ""
        return listed.compactMap { entry -> JavaScriptPluginService? in
            guard let object = entry.object, let pluginID = object["pluginID"]?.string else { return nil }
            let events = Set((object["events"]?.array ?? []).compactMap(\.string))
            let key = scope + "\u{1}" + pluginID
            if let service = instances[key] {
                service.events = events
                return service
            }
            let service = JavaScriptPluginService(pluginID: pluginID, events: events)
            instances[key] = service
            return service
        }
    }
}
