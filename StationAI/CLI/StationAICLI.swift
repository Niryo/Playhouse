import Darwin
import Foundation

@main
enum StationAICLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            print(helpText)
            return
        }

        let request: BridgeRequest
        do {
            request = try parse(arguments)
        } catch {
            let invalid = BridgeRequest(command: "invalid")
            printResponse(.failure(invalid, code: "invalid_argument", message: error.localizedDescription))
            exit(2)
        }

        let dataDirectory = ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"]
        let defaultsSuite = ProcessInfo.processInfo.environment["STATIONAI_E2E_DEFAULTS_SUITE"]
        var configuredRequest = request
        configuredRequest.dataDirectory = dataDirectory
        configuredRequest.defaultsSuite = defaultsSuite

        do {
            let response = try BridgeClient().send(configuredRequest) { event in
                printJSON(event)
            }
            printResponse(response)
            guard response.ok else { exit(exitStatus(for: response.error?.code)) }
        } catch {
            let unavailable = BridgeResponse.failure(
                configuredRequest,
                code: "service_unavailable",
                message: error.localizedDescription
            )
            printResponse(unavailable)
            exit(69)
        }
    }

    private static func parse(_ args: [String]) throws -> BridgeRequest {
        guard let group = args.first else { throw CLIError.usage("Missing command group.") }
        let rest = Array(args.dropFirst())
        switch group {
        case "status":
            return BridgeRequest(command: "status")
        case "board":
            guard rest == ["list"] else { throw CLIError.usage("Use: stationai board list") }
            return BridgeRequest(command: "board.list")
        case "task":
            guard let operation = rest.first else { throw CLIError.usage("Missing task operation.") }
            let tail = Array(rest.dropFirst())
            switch operation {
            case "list":
                return BridgeRequest(command: "task.list")
            case "create":
                let flags = try parseFlags(tail, valueFlags: ["--title", "--root"])
                let title = try requiredFlag("--title", flags: flags).first!
                let roots = flags["--root"] ?? []
                return BridgeRequest(command: "task.create", arguments: [
                    "title": .string(title), "roots": .array(roots.map(BridgeValue.string))
                ])
            case "get", "show":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.get", arguments: ["taskID": .string(id)])
            case "move":
                guard tail.count == 2 else { throw CLIError.usage("Use: stationai task move <task-id> <status>") }
                return BridgeRequest(command: "task.move", arguments: ["taskID": .string(tail[0]), "status": .string(tail[1])])
            case "rename":
                guard let id = tail.first else { throw CLIError.usage("Use: stationai task rename <task-id> --title <title>") }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--title"])
                let title = try requiredFlag("--title", flags: flags).first!
                return BridgeRequest(command: "task.rename", arguments: ["taskID": .string(id), "title": .string(title)])
            case "delete":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.delete", arguments: ["taskID": .string(id)])
            case "roots":
                guard let action = tail.first, tail.count >= 2 else { throw CLIError.usage("Use: stationai task roots get <task-id> or task roots set <task-id> --root <path>...") }
                let id = tail[1]
                if action == "get" {
                    return BridgeRequest(command: "task.roots.get", arguments: ["taskID": .string(id)])
                }
                guard action == "set" else { throw CLIError.usage("Unknown roots operation '\(action)'.") }
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--root"])
                return BridgeRequest(command: "task.roots.set", arguments: [
                    "taskID": .string(id), "roots": .array((flags["--root"] ?? []).map(BridgeValue.string))
                ])
            case "changes":
                guard let action = tail.first else {
                    throw CLIError.usage("Use: stationai task changes list <task-id> or task changes diff <task-id> --repository <path> --path <relative-path> --group <staged|working>")
                }
                switch action {
                case "list":
                    guard tail.count == 2 else { throw CLIError.usage("Use: stationai task changes list <task-id>") }
                    return BridgeRequest(command: "task.changes.list", arguments: ["taskID": .string(tail[1])])
                case "diff":
                    guard tail.count >= 2 else {
                        throw CLIError.usage("Use: stationai task changes diff <task-id> --repository <path> --path <relative-path> --group <staged|working>")
                    }
                    let flags = try parseFlags(
                        Array(tail.dropFirst(2)),
                        valueFlags: ["--repository", "--path", "--group"]
                    )
                    return BridgeRequest(command: "task.changes.diff", arguments: [
                        "taskID": .string(tail[1]),
                        "repository": .string(try requiredFlag("--repository", flags: flags).first!),
                        "path": .string(try requiredFlag("--path", flags: flags).first!),
                        "group": .string(try requiredFlag("--group", flags: flags).first!),
                    ])
                default:
                    throw CLIError.usage("Unknown task changes operation '\(action)'.")
                }
            default:
                throw CLIError.usage("Unknown task operation '\(operation)'.")
            }
        case "workspace":
            guard rest.first == "suggest" else { throw CLIError.usage("Use: stationai workspace suggest --parent <path>") }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--parent"])
            return BridgeRequest(command: "workspace.suggest", arguments: [
                "parent": .string(try requiredFlag("--parent", flags: flags).first!)
            ])
        case "settings":
            guard let operation = rest.first else { throw CLIError.usage("Missing settings operation.") }
            switch operation {
            case "get": return BridgeRequest(command: "settings.get")
            case "clear-parent": return BridgeRequest(command: "settings.clear-parent")
            case "set-parent":
                guard rest.count == 2 else { throw CLIError.usage("Use: stationai settings set-parent <path>") }
                return BridgeRequest(command: "settings.set-parent", arguments: ["path": .string(rest[1])])
            default: throw CLIError.usage("Unknown settings operation '\(operation)'.")
            }
        case "conversation":
            guard let operation = rest.first else { throw CLIError.usage("Missing conversation operation.") }
            let tail = Array(rest.dropFirst())
            guard let id = tail.first else { throw CLIError.usage("A task ID is required.") }
            switch operation {
            case "history": return BridgeRequest(command: "conversation.history", arguments: ["taskID": .string(id)])
            case "send":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message"])
                return BridgeRequest(command: "conversation.send", arguments: [
                    "taskID": .string(id), "message": .string(try requiredFlag("--message", flags: flags).first!)
                ])
            default: throw CLIError.usage("Unknown conversation operation '\(operation)'.")
            }
        default:
            throw CLIError.usage("Unknown command group '\(group)'.")
        }
    }

    private static func parseFlags(_ args: [String], valueFlags: Set<String>) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        var index = 0
        while index < args.count {
            let name = args[index]
            guard valueFlags.contains(name), index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw CLIError.usage("Expected a value after \(name).")
            }
            result[name, default: []].append(args[index + 1])
            index += 2
        }
        return result
    }

    private static func requiredFlag(_ name: String, flags: [String: [String]]) throws -> [String] {
        guard let values = flags[name], !values.isEmpty else { throw CLIError.usage("Missing required option \(name).") }
        return values
    }

    private static func firstPositional(_ args: [String]) throws -> String {
        guard let value = args.first, args.count == 1 else { throw CLIError.usage("Expected exactly one task ID.") }
        return value
    }

    private static func printResponse(_ response: BridgeResponse) { printJSON(response) }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func exitStatus(for code: String?) -> Int32 {
        switch code {
        case "invalid_argument", "unsupported_version", "unknown_command": 2
        case "not_found": 3
        case "service_unavailable": 69
        default: 1
        }
    }

    private static let helpText = """
    StationAI CLI (uses the XPC service bundled in StationAI.app)

    Usage:
      stationai status
      stationai board list
      stationai task list|get <task-id>
      stationai task create --title <title> --root <path> [--root <path>...]
      stationai task move <task-id> <Backlog|Ready|In Progress|Done>
      stationai task rename <task-id> --title <title>
      stationai task roots get <task-id>
      stationai task roots set <task-id> --root <path> [--root <path>...]
      stationai task changes list <task-id>
      stationai task changes diff <task-id> --repository <path> --path <relative-path> --group <staged|working>
      stationai task delete <task-id>
      stationai workspace suggest --parent <path>
      stationai settings get|clear-parent|set-parent <path>
      stationai conversation history <task-id>
      stationai conversation send <task-id> --message <text>

    Results are JSON. Conversation send emits JSON event lines followed by a final response.
    """
}

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let message) = self { message } else { "Invalid CLI arguments." } }
}
