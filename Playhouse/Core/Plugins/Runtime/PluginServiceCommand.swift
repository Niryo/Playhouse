import Foundation

/// A plugin's background half run for app events: each event loads the script
/// into a fresh service runtime (`Playhouse.service.on` registers, `render`
/// does nothing) with the placement's props, calls the event's handlers, waits
/// for their promises to settle and throws the runtime away, so nothing but
/// the plugin's state carries over from one event to the next.
///
/// The daemon's `JavaScriptPluginService` runs it `live`; `plugin service`
/// runs it headlessly, where `mcp.call`, `agent.run` and `agent.cancel` are
/// `unavailable` unless a mock answers them.
package struct PluginServiceCommand: Sendable {
    package var source: String
    package var sourceName: String
    package var props: [String: PluginValue] = [:]
    package var events: [PluginEvent] = []
    /// Answers `Playhouse.bridge` calls; without one they are `unavailable`.
    package var bridge: (@Sendable (String, PluginValue) async throws -> PluginValue)?
    /// Canned answers by bridge command, or by `mcp.call:<tool>` for one tool:
    /// a value resolves the call; `{"error": {"code", "message"}}` rejects it.
    package var mocks: [String: PluginValue] = [:]
    /// Whether the calls that start real provider work reach `bridge`.
    package var live = false
    /// For a script run from a file, which no store knows: `plugin.state.get`
    /// and `plugin.state.set` read and write this, starting from `props.state`.
    package var localState = false
    /// How long one event's handlers may run before they are given up on.
    package var timeout: TimeInterval = PluginServiceCommand.defaultTimeout
    package var resources = PluginRuntime.bundledResources

    package static let defaultTimeout: TimeInterval = 60
    /// Host calls and timers one event's handlers may take before they are given up on.
    package static let stepLimit = 500
    /// Commands that start provider work, so a headless run needs a mock for them.
    package static let providerCommands: Set<String> = ["mcp.call", "agent.run", "agent.cancel"]

    /// `{events: [{name, handlers, errors}], hostCalls, stateWritten, state, errors, log}`.
    package func run() async throws -> PluginValue {
        var hostCalls: [PluginValue] = []
        var stateWritten: [PluginValue] = []
        var delivered: [PluginValue] = []
        var errors: [String] = []
        var log: [String] = []
        let state = LocalState(props["state"]?.object ?? [:])
        for event in events {
            var props = props
            if localState { props["state"] = .object(state.values) }
            let runtime = try PluginRuntime(source: source, sourceName: sourceName, props: props, resources: resources, timers: .manual, service: true)
            var eventErrors = runtime.errors
            var handlers = 0
            if eventErrors.isEmpty {
                let token = runtime.runService(event)
                let deadline = Date().addingTimeInterval(timeout)
                var settled = false
                for _ in 0..<Self.stepLimit {
                    if let result = runtime.commandResult(token) {
                        let value = (try? result.value())?.object ?? [:]
                        handlers = value["handlers"]?.int ?? 0
                        eventErrors += (value["errors"]?.array ?? []).compactMap(\.string)
                        settled = true
                        break
                    }
                    guard Date() < deadline else { break }
                    if let call = runtime.pendingHostCalls.first {
                        // A handler stuck on a slow call is given up on at the deadline too.
                        guard let result = await answer(call, state: localState ? state : nil, before: deadline) else { break }
                        var entry: [String: PluginValue] = ["kind": .string(call.kind), "name": .string(call.name), "arguments": call.arguments]
                        switch result {
                        case .success(let value):
                            entry["ok"] = .bool(true); entry["result"] = value
                            if call.kind == "bridge", call.name == "plugin.state.set", let arguments = call.arguments.object {
                                stateWritten.append(.object(["key": arguments["key"] ?? .null, "value": arguments["value"] ?? .null]))
                            }
                        case .failure(let error):
                            entry["ok"] = .bool(false); entry["error"] = .object(["code": .string(error.code), "message": .string(error.message)])
                        }
                        hostCalls.append(.object(entry))
                        runtime.answerHostCall(call.id, result: result)
                    } else if !runtime.runNextTimer() {
                        break
                    }
                }
                eventErrors += runtime.errors.filter { !eventErrors.contains($0) }
                if !settled {
                    eventErrors.append(Date() < deadline
                        ? "The \(event.name) handlers never finished."
                        : "The \(event.name) handlers didn't finish within \(Int(timeout)) seconds.")
                }
            }
            log += runtime.log.map { "\($0.level): \($0.message)" }
            errors += eventErrors
            delivered.append(.object([
                "name": .string(event.name), "handlers": .number(Double(handlers)),
                "errors": .array(eventErrors.map(PluginValue.string))
            ]))
        }
        return .object([
            "events": .array(delivered),
            "hostCalls": .array(hostCalls),
            "stateWritten": .array(stateWritten),
            // A file run's state after its events; an installed plugin's is in its store.
            "state": localState ? .object(state.values) : .null,
            "errors": .array(errors.map(PluginValue.string)),
            "log": .array(log.map(PluginValue.string))
        ])
    }

    /// A service has no window: `ui` calls are refused, `fetch` reaches the
    /// network, and bridge calls go to a mock, then to `bridge`.
    /// `call`'s answer, or nil when `deadline` passes first.
    private func answer(_ call: PluginRuntime.HostCall, state: LocalState?, before deadline: Date) async -> Result<PluginValue, PluginHostError>? {
        // Not a task group, which would wait for the call it gives up on.
        let race = FirstAnswer()
        return await withCheckedContinuation { continuation in
            race.start(continuation)
            Task { race.finish(await answer(call, state: state)) }
            Task {
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                race.finish(nil)
            }
        }
    }

    /// Resumes its continuation with the first answer it gets.
    private final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<PluginValue, PluginHostError>?, Never>?

        func start(_ continuation: CheckedContinuation<Result<PluginValue, PluginHostError>?, Never>) {
            lock.lock(); defer { lock.unlock() }
            self.continuation = continuation
        }

        func finish(_ answer: Result<PluginValue, PluginHostError>?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: answer)
        }
    }

    private func answer(_ call: PluginRuntime.HostCall, state: LocalState?) async -> Result<PluginValue, PluginHostError> {
        switch call.kind {
        case "ui":
            return .failure(PluginHostError(code: "unavailable", message: "A plugin's background half has no window, so it can't call ui.\(call.name)."))
        case "net":
            if let refusal = PluginHostRules.refusal(kind: call.kind, name: call.name, placement: nil, arguments: call.arguments) { return .failure(refusal) }
            return await PluginNetwork.fetch(call.arguments)
        case "bridge":
            if let refusal = PluginHostRules.refusal(kind: call.kind, name: call.name, placement: nil, arguments: call.arguments) { return .failure(refusal) }
            if let mock = PluginRenderCommand.mock(for: call, in: mocks) {
                if let error = mock.object?["error"]?.object, mock.object?.count == 1 {
                    return .failure(PluginHostError(code: error["code"]?.string ?? "operation_failed", message: error["message"]?.string ?? "The mocked call failed."))
                }
                return .success(mock)
            }
            if let state, call.name == "plugin.state.get" || call.name == "plugin.state.set" {
                return state.answer(call.name, call.arguments)
            }
            if Self.providerCommands.contains(call.name), !live {
                return .failure(PluginHostError(code: "unavailable", message: "\(call.name) starts provider work, which plugin service and plugin render only fake: pass --mock \(call.name)=<json>."))
            }
            guard let bridge else { return .failure(PluginHostError(code: "unavailable", message: "Bridge calls are not available here.")) }
            do {
                return .success(try await bridge(call.name, call.arguments))
            } catch let error as PluginHostError {
                return .failure(error)
            } catch {
                return .failure(PluginHostError(code: "operation_failed", message: error.localizedDescription))
            }
        default:
            return .failure(PluginHostError(code: "invalid_argument", message: "Unknown host call \(call.kind).\(call.name)."))
        }
    }

    /// The state of a plugin run from a file, kept across its events.
    package final class LocalState: @unchecked Sendable {
        package private(set) var values: [String: PluginValue]
        package init(_ values: [String: PluginValue]) { self.values = values }

        package func answer(_ name: String, _ arguments: PluginValue) -> Result<PluginValue, PluginHostError> {
            let arguments = arguments.object ?? [:]
            let pluginID = arguments["pluginID"] ?? .null
            guard name == "plugin.state.set" else {
                return .success(.object(["pluginID": pluginID, "state": .object(values), "enabled": .bool(true)]))
            }
            guard let key = arguments["key"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                return .failure(PluginHostError(code: "invalid_argument", message: "A plugin state key can't be empty."))
            }
            let value = arguments["value"] ?? .null
            values[key] = value == .null ? nil : value
            return .success(.object(["pluginID": pluginID, "state": .object(values)]))
        }
    }
}
