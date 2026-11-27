import Foundation

// MARK: - Manifest

/// One `/` command a plugin exposes, as its manifest's `commands` declares it,
/// so the composer can list it without running the plugin.
package struct PluginCommandManifest: Codable, Equatable, Sendable {
    /// What the user types after the `/`: lowercase words joined by hyphens.
    package var name: String
    /// The command row's second line.
    package var detail: String
    /// An SF Symbol; the plugin's icon when absent.
    package var icon: String?
    /// Choosing the command opens its own list (the `list` handler) instead of
    /// running it at once (the `run` handler).
    package var list: Bool?

    package var hasList: Bool { list == true }

    package init(name: String, detail: String, icon: String? = nil, list: Bool? = nil) {
        self.name = name
        self.detail = detail
        self.icon = icon
        self.list = list
    }
}

// MARK: - What the handlers return

/// Whether the task can run a command now, from the `available` handler.
package struct PluginCommandAvailability: Codable, Equatable, Sendable {
    package var enabled = true
    /// Shown in place of the command's detail while it can't run.
    package var reason: String?

    package init(enabled: Bool = true, reason: String? = nil) {
        self.enabled = enabled
        self.reason = reason
    }
}

/// A button at the end of a list item's row; pressing it calls the `press` handler.
package struct PluginCommandButton: Codable, Equatable, Sendable, Identifiable {
    /// Unique in its row; the row's testID ends with it.
    package var id: String
    /// What VoiceOver and the UI tests read.
    package var label: String
    package var help: String?
    /// An SF Symbol.
    package var icon: String?
    /// A bordered button's text, beside its icon.
    package var text: String?
    /// "icon" (the default, a borderless icon) or "bordered" (a small bordered button with `text`).
    package var style: String?
    package var disabled: Bool?
    package var destructive: Bool?

    package init(id: String, label: String, help: String? = nil, icon: String? = nil, text: String? = nil, style: String? = nil, disabled: Bool? = nil, destructive: Bool? = nil) {
        self.id = id
        self.label = label
        self.help = help
        self.icon = icon
        self.text = text
        self.style = style
        self.disabled = disabled
        self.destructive = destructive
    }
}

/// One row of a command's own list; choosing it calls the `choose` handler.
package struct PluginCommandItem: Codable, Equatable, Sendable, Identifiable {
    /// Unique in the list; the row's testID is `slash-item-<id>`.
    package var id: String
    package var title: String
    package var detail: String?
    /// An SF Symbol; the command's icon when absent.
    package var icon: String?
    package var help: String?
    /// More text the typed filter matches, beside the title and the detail.
    package var keywords: [String]?
    package var buttons: [PluginCommandButton]?
    /// The plugin's own value, handed back to `choose` and `press` with the item.
    package var data: PluginValue?

    package init(id: String, title: String, detail: String? = nil, icon: String? = nil, help: String? = nil, keywords: [String]? = nil, buttons: [PluginCommandButton]? = nil, data: PluginValue? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.icon = icon
        self.help = help
        self.keywords = keywords
        self.buttons = buttons
        self.data = data
    }
}

/// What a command's `list` handler shows. The host filters `items` by the text
/// typed after the command and draws the rows.
package struct PluginCommandList: Codable, Equatable, Sendable {
    /// The menu's header.
    package var title: String
    package var items: [PluginCommandItem]
    /// A note beside the header (such as "Checking sign-in…") while the host
    /// asks the handler again with `complete` true, for a list whose slower
    /// details arrive later; nil for a list that is already complete.
    package var pending: String?
    /// The text of a list with no items, "No items" when absent.
    package var empty: String?
    /// The text when no item matches the filter, before the quoted filter;
    /// "No item matches" when absent.
    package var noMatch: String?

    package init(title: String, items: [PluginCommandItem], pending: String? = nil, empty: String? = nil, noMatch: String? = nil) {
        self.title = title
        self.items = items
        self.pending = pending
        self.empty = empty
        self.noMatch = noMatch
    }
}

/// What `run`, `choose` and `press` return. The host first removes the typed
/// command; `text` takes its place in the draft.
package struct PluginCommandOutcome: Codable, Equatable, Sendable {
    package var text: String?

    package init(text: String? = nil) {
        self.text = text
    }
}

// MARK: - Handlers

/// The steps of a command, each one handler a plugin registers.
package enum PluginCommandPhase: String, Codable, Sendable, CaseIterable {
    /// Every command's `PluginCommandAvailability`, keyed by name.
    case available
    /// A command with a list: its `PluginCommandList`. Request: {filter, complete}.
    case list
    /// A command without a list, chosen: its `PluginCommandOutcome`.
    case run
    /// A list item chosen. Request: {item, filter}.
    case choose
    /// A list item's button pressed. Request: {item, button}.
    case press
}

/// Answers a command's host calls, `Playhouse.bridge`, `Playhouse.ui` and
/// `fetch`: the window's `PluginHost` or the daemon's `slash.run`, each
/// refusing what `PluginHostRules` refuses at the composer's placement.
package typealias PluginCommandHost = @Sendable (_ kind: String, _ name: String, _ arguments: PluginValue) async -> Result<PluginValue, PluginHostError>

/// Runs a plugin's commands: a JavaScript plugin's `Playhouse.commands`
/// handlers (`JavaScriptCommandHandler`), or a built-in plugin's Swift ones,
/// which reach the app only through `host`, the same calls a script makes.
package protocol PluginCommandHandler: Sendable {
    func perform(
        _ phase: PluginCommandPhase, command: String, request: PluginValue,
        props: [String: PluginValue], host: @escaping PluginCommandHost
    ) async throws -> PluginValue
}

extension PluginCommandHandler {
    package func availability(props: [String: PluginValue], host: @escaping PluginCommandHost) async throws -> [String: PluginCommandAvailability] {
        let value = try await perform(.available, command: "", request: .object([:]), props: props, host: host)
        var result: [String: PluginCommandAvailability] = [:]
        for (name, entry) in value.object ?? [:] {
            switch entry {
            case .bool(let enabled): result[name] = PluginCommandAvailability(enabled: enabled)
            case .null: break
            default: result[name] = try PluginValueDecoder.decode(PluginCommandAvailability.self, from: entry)
            }
        }
        return result
    }

    package func list(_ command: String, filter: String, complete: Bool, props: [String: PluginValue], host: @escaping PluginCommandHost) async throws -> PluginCommandList {
        let value = try await perform(.list, command: command, request: .object(["filter": .string(filter), "complete": .bool(complete)]), props: props, host: host)
        return try PluginValueDecoder.decode(PluginCommandList.self, from: value)
    }

    /// `run`, `choose` or `press`, whose result is an outcome or nothing.
    package func act(_ phase: PluginCommandPhase, command: String, request: PluginValue, props: [String: PluginValue], host: @escaping PluginCommandHost) async throws -> PluginCommandOutcome {
        let value = try await perform(phase, command: command, request: request, props: props, host: host)
        if case .object = value { return try PluginValueDecoder.decode(PluginCommandOutcome.self, from: value) }
        return PluginCommandOutcome()
    }
}

/// A host-call failure as the error a Swift handler throws.
extension Result where Success == PluginValue, Failure == PluginHostError {
    package func value() throws -> PluginValue {
        switch self {
        case .success(let value): value
        case .failure(let error): throw error
        }
    }
}

extension PluginValue {
    /// `value` as it would cross to a script, through its JSON.
    package init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(PluginValue.self, from: JSONEncoder().encode(value))
    }
}

extension PluginHostError: LocalizedError {
    package var errorDescription: String? { message }
}

/// A JavaScript plugin's commands: each phase runs in a fresh runtime of its
/// script with the composer's context, its host calls answered by `host`,
/// until the handler's promise settles.
package struct JavaScriptCommandHandler: PluginCommandHandler {
    package let source: String
    package let sourceName: String
    package var resources = PluginRuntime.bundledResources
    /// Host calls and timers a handler may take before it is given up on.
    package static let stepLimit = 200

    package init(source: String, sourceName: String, resources: URL? = PluginRuntime.bundledResources) {
        self.source = source
        self.sourceName = sourceName
        self.resources = resources
    }

    package init(plugin: PluginRecord, resources: URL? = PluginRuntime.bundledResources) throws {
        self.init(
            source: try String(contentsOfFile: plugin.entryPath, encoding: .utf8),
            sourceName: URL(fileURLWithPath: plugin.entryPath).lastPathComponent, resources: resources
        )
    }

    package func perform(
        _ phase: PluginCommandPhase, command: String, request: PluginValue,
        props: [String: PluginValue], host: @escaping PluginCommandHost
    ) async throws -> PluginValue {
        let runtime = try PluginRuntime(source: source, sourceName: sourceName, props: props, resources: resources, timers: .manual)
        if let error = runtime.errors.first { throw PluginHostError(code: "script_error", message: error) }
        let token = runtime.runCommand(command, phase: phase.rawValue, request: request)
        for _ in 0..<Self.stepLimit {
            if let result = runtime.commandResult(token) { return try result.value() }
            if let call = runtime.pendingHostCalls.first {
                runtime.answerHostCall(call.id, result: await host(call.kind, call.name, call.arguments))
            } else if !runtime.runNextTimer() {
                break
            }
        }
        if let result = runtime.commandResult(token) { return try result.value() }
        if let error = runtime.errors.first { throw PluginHostError(code: "script_error", message: error) }
        throw PluginHostError(code: "operation_failed", message: "The /\(command) command's \(phase.rawValue) handler never finished.")
    }
}

// MARK: - Validation

extension PluginLibrary {
    /// Why a manifest's commands are invalid, for its presentation. A headless
    /// plugin needs commands, events for a background half, or both.
    package static func commandErrors(_ commands: [PluginCommandManifest], presentation: PluginPresentation?, hasEvents: Bool = false) -> [String] {
        var errors: [String] = []
        if presentation == .headless, commands.isEmpty, !hasEvents {
            errors.append("A headless plugin has no surface; it needs at least one command in \"commands\" or an event in \"events\".")
        }
        var seen: Set<String> = []
        for command in commands {
            if !isValidID(command.name) {
                errors.append("The command name \"\(command.name)\" must be lowercase words joined by hyphens.")
            } else if !seen.insert(command.name).inserted {
                errors.append("The command /\(command.name) is declared twice.")
            } else if BuiltInPlugins.commandNames.contains(command.name) {
                errors.append("/\(command.name) is a built-in command.")
            }
            if command.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("The command /\(command.name) needs a detail.")
            }
        }
        return errors
    }
}

extension PluginLibrary {
    /// Why a manifest's `events` and `mcpTools` are invalid.
    package static func serviceErrors(events: [String], mcpTools: [String]?) -> [String] {
        var errors: [String] = []
        var seen: Set<String> = []
        for event in events {
            if !PluginEvent.names.contains(event) {
                errors.append("Unknown event \"\(event)\" in \"events\". Events: \(PluginEvent.names.joined(separator: ", ")).")
            } else if !seen.insert(event).inserted {
                errors.append("The event \(event) is listed twice in \"events\".")
            }
        }
        for tool in mcpTools ?? [] where !PluginMcpTool.isQualified(tool) {
            errors.append("\"\(tool)\" in \"mcpTools\" is not a fully qualified MCP tool name such as mcp__<server>__<tool>.")
        }
        return errors
    }
}

/// An MCP tool's fully qualified name, as Claude Code calls it: `mcp__<server>__<tool>`.
package enum PluginMcpTool {
    package static func isQualified(_ name: String) -> Bool {
        guard name.hasPrefix("mcp__") else { return false }
        let rest = name.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return false }
        return !rest[..<separator.lowerBound].isEmpty && !rest[separator.upperBound...].isEmpty
    }
}

// MARK: - Headless host

/// Answers a command's host calls with no window, for `slash.run`: bridge
/// calls go to `bridge`, `fetch` to the network, and `ui` calls, which only
/// a window can do, are recorded and answered with null (`ui.confirm` with
/// `confirm`). `PluginHostRules` refuses what it refuses in the window.
package final class PluginHeadlessHost: @unchecked Sendable {
    package let placement: PluginPlacement
    package let bridge: @Sendable (String, PluginValue) async throws -> PluginValue
    package let confirm: Bool
    private let lock = NSLock()
    private var recorded: [PluginValue] = []

    package init(placement: PluginPlacement, confirm: Bool, bridge: @escaping @Sendable (String, PluginValue) async throws -> PluginValue) {
        self.placement = placement
        self.confirm = confirm
        self.bridge = bridge
    }

    /// Each host call in order: {kind, name, arguments, ok, result | error}.
    package var hostCalls: [PluginValue] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ entry: PluginValue) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(entry)
    }

    package var answer: PluginCommandHost {
        { [self] kind, name, arguments in
            let result: Result<PluginValue, PluginHostError>
            if let refusal = PluginHostRules.refusal(kind: kind, name: name, placement: placement, arguments: arguments) {
                result = .failure(refusal)
            } else if kind == "bridge" {
                do {
                    result = .success(try await bridge(name, arguments))
                } catch let error as PluginHostError {
                    result = .failure(error)
                } catch {
                    result = .failure(PluginHostError(code: "operation_failed", message: error.localizedDescription))
                }
            } else if kind == "net" {
                result = await PluginNetwork.fetch(arguments)
            } else {
                result = .success(name == "confirm" ? .bool(confirm) : .null)
            }
            var entry: [String: PluginValue] = ["kind": .string(kind), "name": .string(name), "arguments": arguments]
            switch result {
            case .success(let value): entry["ok"] = .bool(true); entry["result"] = value
            case .failure(let error): entry["ok"] = .bool(false); entry["error"] = .object(["code": .string(error.code), "message": .string(error.message)])
            }
            record(.object(entry))
            return result
        }
    }
}
