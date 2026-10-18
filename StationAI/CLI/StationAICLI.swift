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
        configuredRequest.worktreeDirectory = ProcessInfo.processInfo.environment["STATIONAI_E2E_WORKTREE_DIRECTORY"]
        if let fixtureExecutable = ProcessInfo.processInfo.environment["STATIONAI_E2E_CODEX_EXECUTABLE"] {
            configuredRequest.arguments["__codexExecutable"] = .string(fixtureExecutable)
        }

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
                let flags = try parseFlags(tail, valueFlags: ["--title", "--root", "--repo", "--branch", "--branch-from", "--merge-target"])
                let title = try requiredFlag("--title", flags: flags).first!
                let roots = flags["--root"] ?? []
                let repositories = flags["--repo"] ?? []
                let branches = try keyedOptions(flags["--branch"] ?? [])
                let branchFrom = try keyedOptions(flags["--branch-from"] ?? [])
                let mergeTargets = try keyedOptions(flags["--merge-target"] ?? [])
                return BridgeRequest(command: "task.create", arguments: [
                    "title": .string(title),
                    "roots": .array(roots.map(BridgeValue.string)),
                    "repositories": .array(repositories.map { path in
                        .object([
                            "repositoryPath": .string(path),
                            "branch": branches[path].map(BridgeValue.string) ?? .null,
                            "branchFrom": branchFrom[path].map(BridgeValue.string) ?? .null,
                            "mergeTarget": mergeTargets[path].map(BridgeValue.string) ?? .null,
                        ])
                    })
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
            case "prompt":
                guard let id = tail.first else { throw CLIError.usage("Use: stationai task prompt <task-id> --text <prompt> [--status <status>]") }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--text", "--status"])
                var arguments: [String: BridgeValue] = ["taskID": .string(id), "prompt": .string(try requiredFlag("--text", flags: flags).first!)]
                if let status = flags["--status"]?.first { arguments["status"] = .string(status) }
                return BridgeRequest(command: "task.prompt.save", arguments: arguments)
            case "delete":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.delete", arguments: ["taskID": .string(id)])
            case "delete-check":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.delete.requires-confirmation", arguments: ["taskID": .string(id)])
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
            case "set-appearance":
                guard rest.count == 2 else { throw CLIError.usage("Use: stationai settings set-appearance <dark|light>") }
                return BridgeRequest(command: "settings.set-appearance", arguments: ["appearance": .string(rest[1])])
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
            case "models": return BridgeRequest(command: "conversation.models", arguments: ["taskID": .string(id)])
            case "send":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--mode", "--model", "--answer"])
                var answers: [String: [String]] = [:]
                for pair in flags["--answer"] ?? [] {
                    guard let separator = pair.firstIndex(of: "="), separator != pair.startIndex else {
                        throw CLIError.usage("Use --answer <question-id>=<answer>.")
                    }
                    let questionID = String(pair[..<separator])
                    let answer = String(pair[pair.index(after: separator)...])
                    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CLIError.usage("Question answers can't be blank.")
                    }
                    answers[questionID, default: []].append(answer)
                }
                return BridgeRequest(command: "conversation.send", arguments: [
                    "taskID": .string(id),
                    "message": .string(try requiredFlag("--message", flags: flags).first!),
                    "mode": .string(flags["--mode"]?.first ?? "default"),
                    "model": .string(flags["--model"]?.first ?? "gpt-6-luna"),
                    "answers": .object(answers.mapValues { BridgeValue.array($0.map(BridgeValue.string)) })
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

    private static func keyedOptions(_ values: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw CLIError.usage("Use <repository-path>=<value> for branch options.")
            }
            let path = String(value[..<separator])
            let option = String(value[value.index(after: separator)...])
            guard !option.isEmpty else { throw CLIError.usage("Branch options can't be empty.") }
            result[path] = option
        }
        return result
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
      stationai task create --title <title> --repo <path> [--repo <path>...] [--branch <repo-path>=<name>] [--branch-from <repo-path>=<ref>] [--merge-target <repo-path>=<local-branch>]
      stationai task move <task-id> Done
      stationai task rename <task-id> --title <title>
      stationai task roots get <task-id>
      stationai task roots set <task-id> --root <path> [--root <path>...]
      stationai task changes list <task-id>
      stationai task changes diff <task-id> --repository <path> --path <relative-path> --group <staged|working>
      stationai task delete <task-id>
      stationai task delete-check <task-id>
      stationai workspace suggest --parent <path>
      stationai settings get|clear-parent|set-parent <path>|set-appearance <dark|light>
      stationai conversation history <task-id>
      stationai conversation models <task-id>
      stationai conversation send <task-id> --message <text> [--mode <default|plan>] [--model <model-id>] [--answer <question-id>=<answer>...]

    Results are JSON. Conversation send emits JSON event lines followed by a final response.
    """
}

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let message) = self { message } else { "Invalid CLI arguments." } }
}
