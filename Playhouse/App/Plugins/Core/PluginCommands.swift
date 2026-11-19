import Foundation

// MARK: - Manifest

/// One `/` command a plugin exposes, as its manifest's `commands` declares it,
/// so the composer can list it without running the plugin.
struct PluginCommandManifest: Codable, Equatable, Sendable {
    /// What the user types after the `/`: lowercase words joined by hyphens.
    var name: String
    /// The command row's second line.
    var detail: String
    /// An SF Symbol; the plugin's icon when absent.
    var icon: String?
    /// Choosing the command opens its own list (the `list` handler) instead of
    /// running it at once (the `run` handler).
    var list: Bool?

    var hasList: Bool { list == true }
}

// MARK: - What the handlers return

/// Whether the task can run a command now, from the `available` handler.
struct PluginCommandAvailability: Codable, Equatable, Sendable {
    var enabled = true
    /// Shown in place of the command's detail while it can't run.
    var reason: String?
}

/// A button at the end of a list item's row; pressing it calls the `press` handler.
struct PluginCommandButton: Codable, Equatable, Sendable, Identifiable {
    /// Unique in its row; the row's testID ends with it.
    var id: String
    /// What VoiceOver and the UI tests read.
    var label: String
    var help: String?
    /// An SF Symbol.
    var icon: String?
    /// A bordered button's text, beside its icon.
    var text: String?
    /// "icon" (the default, a borderless icon) or "bordered" (a small bordered button with `text`).
    var style: String?
    var disabled: Bool?
    var destructive: Bool?
}

/// One row of a command's own list; choosing it calls the `choose` handler.
struct PluginCommandItem: Codable, Equatable, Sendable, Identifiable {
    /// Unique in the list; the row's testID is `slash-item-<id>`.
    var id: String
    var title: String
    var detail: String?
    /// An SF Symbol; the command's icon when absent.
    var icon: String?
    var help: String?
    /// More text the typed filter matches, beside the title and the detail.
    var keywords: [String]?
    var buttons: [PluginCommandButton]?
    /// The plugin's own value, handed back to `choose` and `press` with the item.
    var data: PluginValue?
}

/// What a command's `list` handler shows. The host filters `items` by the text
/// typed after the command and draws the rows.
struct PluginCommandList: Codable, Equatable, Sendable {
    /// The menu's header.
    var title: String
    var items: [PluginCommandItem]
    /// A note beside the header (such as "Checking sign-in…") while the host
    /// asks the handler again with `complete` true, for a list whose slower
    /// details arrive later; nil for a list that is already complete.
    var pending: String?
    /// The text of a list with no items, "No items" when absent.
    var empty: String?
    /// The text when no item matches the filter, before the quoted filter;
    /// "No item matches" when absent.
    var noMatch: String?
}

/// What `run`, `choose` and `press` return. The host first removes the typed
/// command; `text` takes its place in the draft.
struct PluginCommandOutcome: Codable, Equatable, Sendable {
    var text: String?
}

// MARK: - Handlers

/// The steps of a command, each one handler a plugin registers.
enum PluginCommandPhase: String, Codable, Sendable, CaseIterable {
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
typealias PluginCommandHost = @Sendable (_ kind: String, _ name: String, _ arguments: PluginValue) async -> Result<PluginValue, PluginHostError>

/// Runs a plugin's commands: a JavaScript plugin's `Playhouse.commands`
/// handlers (`JavaScriptCommandHandler`), or a built-in plugin's Swift ones,
/// which reach the app only through `host`, the same calls a script makes.
protocol PluginCommandHandler: Sendable {
    func perform(
        _ phase: PluginCommandPhase, command: String, request: PluginValue,
        props: [String: PluginValue], host: @escaping PluginCommandHost
    ) async throws -> PluginValue
}

extension PluginCommandHandler {
    func availability(props: [String: PluginValue], host: @escaping PluginCommandHost) async throws -> [String: PluginCommandAvailability] {
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

    func list(_ command: String, filter: String, complete: Bool, props: [String: PluginValue], host: @escaping PluginCommandHost) async throws -> PluginCommandList {
        let value = try await perform(.list, command: command, request: .object(["filter": .string(filter), "complete": .bool(complete)]), props: props, host: host)
        return try PluginValueDecoder.decode(PluginCommandList.self, from: value)
    }

    /// `run`, `choose` or `press`, whose result is an outcome or nothing.
    func act(_ phase: PluginCommandPhase, command: String, request: PluginValue, props: [String: PluginValue], host: @escaping PluginCommandHost) async throws -> PluginCommandOutcome {
        let value = try await perform(phase, command: command, request: request, props: props, host: host)
        if case .object = value { return try PluginValueDecoder.decode(PluginCommandOutcome.self, from: value) }
        return PluginCommandOutcome()
    }
}

/// A host-call failure as the error a Swift handler throws.
extension Result where Success == PluginValue, Failure == PluginHostError {
    func value() throws -> PluginValue {
        switch self {
        case .success(let value): value
        case .failure(let error): throw error
        }
    }
}

extension PluginValue {
    /// `value` as it would cross to a script, through its JSON.
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(PluginValue.self, from: JSONEncoder().encode(value))
    }
}

extension PluginHostError: LocalizedError {
    var errorDescription: String? { message }
}

/// A JavaScript plugin's commands: each phase runs in a fresh runtime of its
/// script with the composer's context, its host calls answered by `host`,
/// until the handler's promise settles.
struct JavaScriptCommandHandler: PluginCommandHandler {
    let source: String
    let sourceName: String
    var resources = PluginRuntime.bundledResources
    /// Host calls and timers a handler may take before it is given up on.
    static let stepLimit = 200

    init(source: String, sourceName: String, resources: URL? = PluginRuntime.bundledResources) {
        self.source = source
        self.sourceName = sourceName
        self.resources = resources
    }

    init(plugin: PluginRecord, resources: URL? = PluginRuntime.bundledResources) throws {
        self.init(
            source: try String(contentsOfFile: plugin.entryPath, encoding: .utf8),
            sourceName: URL(fileURLWithPath: plugin.entryPath).lastPathComponent, resources: resources
        )
    }

    func perform(
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
    static func commandErrors(_ commands: [PluginCommandManifest], presentation: PluginPresentation?, hasEvents: Bool = false) -> [String] {
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
    static func serviceErrors(events: [String], mcpTools: [String]?) -> [String] {
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
enum PluginMcpTool {
    static func isQualified(_ name: String) -> Bool {
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
final class PluginHeadlessHost: @unchecked Sendable {
    let placement: PluginPlacement
    let bridge: @Sendable (String, PluginValue) async throws -> PluginValue
    let confirm: Bool
    private let lock = NSLock()
    private var recorded: [PluginValue] = []

    init(placement: PluginPlacement, confirm: Bool, bridge: @escaping @Sendable (String, PluginValue) async throws -> PluginValue) {
        self.placement = placement
        self.confirm = confirm
        self.bridge = bridge
    }

    /// Each host call in order: {kind, name, arguments, ok, result | error}.
    var hostCalls: [PluginValue] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ entry: PluginValue) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(entry)
    }

    var answer: PluginCommandHost {
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
