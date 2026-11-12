import Darwin
import Foundation

@main
enum PlayhouseCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            print(helpText)
            return
        }

        // Claude Code's read-only side chat hook: answered here, without the daemon, for each tool call.
        if arguments == SideChatReadOnlyPolicy.hookSubcommand {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let cliPaths = [CommandLine.arguments[0]] + (Bundle.main.executableURL.map { [$0.path] } ?? [])
            if let output = SideChatReadOnlyPolicy.hookOutput(for: input, cliPaths: cliPaths) {
                FileHandle.standardOutput.write(output)
            }
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

        let configuredRequest = request.configuredForCaller()

        do {
            let response = try BridgeClient().send(configuredRequest) { event in
                printJSON(event)
            }
            printResponse(response)
            guard response.ok else { exit(exitStatus(for: response.error?.code)) }
            // A plugin that renders with errors still answers with the full report, but fails the process.
            if configuredRequest.command == "plugin.render",
               case .array(let errors)? = response.result?.object?["errors"], !errors.isEmpty {
                exit(1)
            }
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
            guard rest == ["list"] else { throw CLIError.usage("Use: playhouse board list") }
            return BridgeRequest(command: "board.list")
        case "archive":
            guard rest.count == 2, rest[0] == "search" else { throw CLIError.usage("Use: playhouse archive search <query>") }
            var arguments: [String: BridgeValue] = ["query": .string(rest[1])]
            if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] { arguments["codexHome"] = .string(codexHome) }
            return BridgeRequest(command: "archive.search", arguments: arguments)
        case "task":
            guard let operation = rest.first else { throw CLIError.usage("Missing task operation.") }
            let tail = Array(rest.dropFirst())
            switch operation {
            case "list":
                return BridgeRequest(command: "task.list")
            case "create":
                let flags = try parseFlags(tail, valueFlags: ["--title", "--root", "--repo", "--branch", "--branch-from", "--merge-target", "--provider", "--prompt"])
                let title = try requiredFlag("--title", flags: flags).first!
                let roots = flags["--root"] ?? []
                let repositories = flags["--repo"] ?? []
                let branches = try keyedOptions(flags["--branch"] ?? [])
                let branchFrom = try keyedOptions(flags["--branch-from"] ?? [])
                let mergeTargets = try keyedOptions(flags["--merge-target"] ?? [])
                var createArguments: [String: BridgeValue] = [
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
                ]
                if let provider = flags["--provider"]?.first { createArguments["provider"] = .string(provider) }
                createArguments["prompt"] = .string(try requiredFlag("--prompt", flags: flags).first!)
                return BridgeRequest(command: "task.create", arguments: createArguments)
            case "get", "show":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.get", arguments: ["taskID": .string(id)])
            case "token-usage":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.token-usage", arguments: ["taskID": .string(id)])
            case "token-waste":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.token-waste", arguments: ["taskID": .string(id)])
            case "raw-input", "raw-input-text", "raw-input-export":
                let id = try firstPositional(Array(tail.prefix(1)))
                let names: Set<String> = switch operation {
                case "raw-input": ["--agent", "--scope", "--order", "--query", "--offset", "--limit", "--focus", "--request"]
                case "raw-input-export": ["--agent", "--request", "--format"]
                default: ["--agent", "--item", "--offset", "--length"]
                }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: names)
                var arguments: [String: BridgeValue] = ["taskID": .string(id)]
                for name in names {
                    if let value = flags[name]?.first { arguments[String(name.dropFirst(2))] = .string(value) }
                }
                if operation == "raw-input-text", arguments["item"] == nil {
                    throw CLIError.usage("Use: playhouse task raw-input-text <task-id> --item <n> [--agent <id>] [--offset <n>] [--length <n>]")
                }
                return BridgeRequest(command: "task.\(operation)", arguments: arguments)
            case "cpu-usage":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.cpu-usage", arguments: ["taskID": .string(id)])
            case "move":
                let flags = Array(tail.dropFirst(2))
                guard tail.count >= 2, Set(flags).isSubset(of: ["--allow-unmerged", "--discard-changes"]), Set(flags).count == flags.count else {
                    throw CLIError.usage("Use: playhouse task move <task-id> <status> [--allow-unmerged] [--discard-changes]")
                }
                return BridgeRequest(command: "task.move", arguments: [
                    "taskID": .string(tail[0]), "status": .string(tail[1]),
                    "allowUnmergedPullRequests": .boolean(flags.contains("--allow-unmerged")),
                    "allowDiscardingUncommittedChanges": .boolean(flags.contains("--discard-changes"))
                ])
            case "pr":
                guard tail.count >= 2 else {
                    throw CLIError.usage("Use: playhouse task pr create|conflicts|status|verify|resolve|sync|auto|mode|autopilot <task-id> [action]")
                }
                switch tail[0] {
                case "auto" where tail.count == 3 && (tail[2] == "on" || tail[2] == "off"):
                    return BridgeRequest(command: "task.pr.auto", arguments: ["taskID": .string(tail[1]), "enabled": .boolean(tail[2] == "on")])
                case "mode" where tail.count == 3:
                    return BridgeRequest(command: "task.pr.mode", arguments: ["taskID": .string(tail[1]), "mode": .string(tail[2])])
                case "autopilot" where tail.count == 2:
                    return BridgeRequest(command: "task.pr.autopilot", arguments: ["taskID": .string(tail[1])])
                case "create" where tail.count == 2:
                    return BridgeRequest(command: "task.pr.create", arguments: ["taskID": .string(tail[1])])
                case "conflicts" where tail.count == 2:
                    return BridgeRequest(command: "task.pr.conflicts", arguments: ["taskID": .string(tail[1])])
                case "status" where tail.count == 2:
                    return BridgeRequest(command: "task.pr.status", arguments: ["taskID": .string(tail[1])])
                case "verify" where tail.count == 2:
                    return BridgeRequest(command: "task.pr.verify", arguments: ["taskID": .string(tail[1])])
                case "resolve" where tail.count == 3:
                    return BridgeRequest(command: "task.pr.resolve", arguments: ["taskID": .string(tail[1]), "action": .string(tail[2])])
                case "sync" where tail.count == 2:
                    return BridgeRequest(command: "task.pr.sync", arguments: ["taskID": .string(tail[1])])
                default:
                    throw CLIError.usage("Use: playhouse task pr create|conflicts|status|verify|resolve|sync|autopilot <task-id> [resolve-and-push|resolve-only|keep], playhouse task pr auto <task-id> on|off, or playhouse task pr mode <task-id> manual|pr|autopilot|merge")
                }
            case "progress":
                guard let action = tail.first else { throw CLIError.usage("Use: playhouse task progress publish|custom|clear <task-id> ...") }
                let values = Array(tail.dropFirst())
                switch action {
                case "publish":
                    guard let id = values.first else { throw CLIError.usage("Use: playhouse task progress publish <task-id> --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail <text>]") }
                    let flags = try parseFlags(Array(values.dropFirst()), valueFlags: ["--type", "--detail"])
                    var requestArguments: [String: BridgeValue] = [
                        "taskID": .string(id),
                        "type": .string(try requiredFlag("--type", flags: flags).first!)
                    ]
                    if let detail = flags["--detail"]?.first { requestArguments["detail"] = .string(detail) }
                    return BridgeRequest(command: "task.progress.publish", arguments: requestArguments)
                case "custom":
                    guard let id = values.first else { throw CLIError.usage("Use: playhouse task progress custom <task-id> --label <label> [--detail <text>]") }
                    let flags = try parseFlags(Array(values.dropFirst()), valueFlags: ["--label", "--detail"])
                    var requestArguments: [String: BridgeValue] = [
                        "taskID": .string(id),
                        "label": .string(try requiredFlag("--label", flags: flags).first!)
                    ]
                    if let detail = flags["--detail"]?.first { requestArguments["detail"] = .string(detail) }
                    return BridgeRequest(command: "task.progress.custom", arguments: requestArguments)
                case "clear":
                    guard values.count == 1 else { throw CLIError.usage("Use: playhouse task progress clear <task-id>") }
                    return BridgeRequest(command: "task.progress.clear", arguments: ["taskID": .string(values[0])])
                default:
                    throw CLIError.usage("Unknown task progress operation '\(action)'.")
                }
            case "outcome":
                guard tail.count == 2 else {
                    throw CLIError.usage("Use: playhouse task outcome <task-id> <completed|in-progress|waiting-response>")
                }
                return BridgeRequest(command: "task.outcome", arguments: [
                    "taskID": .string(tail[0]), "outcome": .string(tail[1])
                ])
            case "reconcile":
                guard tail.count == 1 else { throw CLIError.usage("Use: playhouse task reconcile <task-id>") }
                return BridgeRequest(command: "task.reconcile", arguments: ["taskID": .string(tail[0])])
            case "title":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--prompt"])
                guard let taskID = tail.first, let prompt = flags["--prompt"]?.first else {
                    throw CLIError.usage("Use: playhouse task title <task-id> --prompt <text>")
                }
                return BridgeRequest(command: "task.title.generate", arguments: ["taskID": .string(taskID), "prompt": .string(prompt)])
            case "rename":
                guard let id = tail.first else { throw CLIError.usage("Use: playhouse task rename <task-id> --title <title>") }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--title"])
                let title = try requiredFlag("--title", flags: flags).first!
                return BridgeRequest(command: "task.rename", arguments: ["taskID": .string(id), "title": .string(title)])
            case "repository":
                guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse task repository add|add-batch|replace|edit|remove|renew|recent <task-id> ...") }
                let id = tail[1]
                switch tail[0] {
                case "add-batch":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo"])
                    let repositories = try requiredFlag("--repo", flags: flags)
                    return BridgeRequest(command: "task.repository.add-batch", arguments: [
                        "taskID": .string(id),
                        "repositoryPaths": .array(repositories.map(BridgeValue.string))
                    ])
                case "replace":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo"])
                    let repositories = try requiredFlag("--repo", flags: flags)
                    return BridgeRequest(command: "task.repository.replace", arguments: [
                        "taskID": .string(id),
                        "repositoryPaths": .array(repositories.map(BridgeValue.string))
                    ])
                case "add", "remove", "renew":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo"])
                    let repository = try requiredFlag("--repo", flags: flags).first!
                    return BridgeRequest(
                        command: "task.repository.\(tail[0])",
                        arguments: ["taskID": .string(id), "repositoryPath": .string(repository)]
                    )
                case "recent":
                    guard tail.count == 2 else { throw CLIError.usage("Use: playhouse task repository recent <task-id>") }
                    return BridgeRequest(command: "task.repository.recent", arguments: ["taskID": .string(id)])
                case "edit":
                    let flags = try parseFlags(
                        Array(tail.dropFirst(2)),
                        valueFlags: ["--repo", "--branch", "--branch-from", "--merge-target"]
                    )
                    let repository = try requiredFlag("--repo", flags: flags).first!
                    let branch = try requiredFlag("--branch", flags: flags).first!
                    let branchFrom = try requiredFlag("--branch-from", flags: flags).first!
                    let mergeTarget = flags["--merge-target"]?.last ?? ""
                    return BridgeRequest(command: "task.repository.edit", arguments: [
                        "taskID": .string(id),
                        "repositoryPath": .string(repository),
                        "branch": .string(branch),
                        "branchFrom": .string(branchFrom),
                        "mergeTarget": .string(mergeTarget)
                    ])
                default:
                    throw CLIError.usage("Use: playhouse task repository add|add-batch|replace|edit|remove|renew|recent <task-id> ...")
                }
            case "prompt":
                guard let id = tail.first else { throw CLIError.usage("Use: playhouse task prompt <task-id> --text <prompt> [--status <status>] [--submitted true]") }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--text", "--status", "--submitted", "--image"])
                let prompt = try requiredFlag("--text", flags: flags).first!
                let status = flags["--status"]?.first
                let submittedValue = flags["--submitted"]?.first
                var submitted = false
                if let submittedValue {
                    guard submittedValue == "true" || submittedValue == "false" else {
                        throw CLIError.usage("Use true or false for --submitted.")
                    }
                    submitted = submittedValue == "true"
                }
                if submitted, (status != "In Progress" || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    throw CLIError.usage("A submitted prompt requires nonblank text and --status \"In Progress\".")
                }
                var arguments: [String: BridgeValue] = ["taskID": .string(id), "prompt": .string(prompt)]
                if let imagePaths = flags["--image"] {
                    arguments["images"] = .array(try imagePaths.map(draftImageDataURL))
                }
                if let status { arguments["status"] = .string(status) }
                if submitted { arguments["submitted"] = .boolean(true) }
                return BridgeRequest(command: "task.prompt.save", arguments: arguments)
            case "draft":
                // Saves the composer draft as a whole: text plus every attached image.
                guard let id = tail.first else { throw CLIError.usage("Use: playhouse task draft <task-id> --text <draft> [--image <path>...]") }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--text", "--image"])
                let prompt = try requiredFlag("--text", flags: flags).first!
                return BridgeRequest(command: "task.draft.save", arguments: [
                    "taskID": .string(id),
                    "prompt": .string(prompt),
                    "images": .array(try (flags["--image"] ?? []).map(draftImageDataURL))
                ])
            case "comments":
                guard let id = tail.first else { throw CLIError.usage("Use: playhouse task comments <task-id> --json <comments-array> [--append]") }
                let rest = Array(tail.dropFirst())
                if rest.first == "edit" {
                    guard rest.count >= 2 else { throw CLIError.usage("Use: playhouse task comments <task-id> edit <comment-id> --text <text>") }
                    let flags = try parseFlags(Array(rest.dropFirst(2)), valueFlags: ["--text"])
                    return BridgeRequest(command: "task.comments.edit", arguments: [
                        "taskID": .string(id), "commentID": .string(rest[1]),
                        "text": .string(try requiredFlag("--text", flags: flags).first!)
                    ])
                }
                let flags = try parseFlags(rest.filter { $0 != "--append" }, valueFlags: ["--json"])
                return BridgeRequest(command: "task.comments.save", arguments: [
                    "taskID": .string(id),
                    "comments": .string(try requiredFlag("--json", flags: flags).first!),
                    "append": .boolean(rest.contains("--append"))
                ])
            case "delete":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.delete", arguments: ["taskID": .string(id)])
            case "delete-check":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.delete.requires-confirmation", arguments: ["taskID": .string(id)])
            case "roots":
                guard let action = tail.first, tail.count >= 2 else { throw CLIError.usage("Use: playhouse task roots get <task-id> or task roots set <task-id> --root <path>...") }
                let id = tail[1]
                if action == "get" {
                    return BridgeRequest(command: "task.roots.get", arguments: ["taskID": .string(id)])
                }
                guard action == "set" else { throw CLIError.usage("Unknown roots operation '\(action)'.") }
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--root"])
                return BridgeRequest(command: "task.roots.set", arguments: [
                    "taskID": .string(id), "roots": .array((flags["--root"] ?? []).map(BridgeValue.string))
                ])
            case "terminal":
                guard tail.count == 1 else { throw CLIError.usage("Use: playhouse task terminal <task-id>") }
                return BridgeRequest(command: "task.terminal", arguments: ["taskID": .string(tail[0])])
            case "changes":
                guard let action = tail.first else {
                    throw CLIError.usage("Use: playhouse task changes list <task-id>, mark-viewed <task-id> --repository <path> --path <relative-path>, mark-unviewed <task-id> --repository <path> --path <relative-path>, mark-all-viewed <task-id>, or diff <task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>")
                }
                switch action {
                case "list":
                    guard tail.count == 2 else { throw CLIError.usage("Use: playhouse task changes list <task-id>") }
                    return BridgeRequest(command: "task.changes.list", arguments: ["taskID": .string(tail[1])])
                case "diff":
                    guard tail.count >= 2 else {
                        throw CLIError.usage("Use: playhouse task changes diff <task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>")
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
                case "mark-viewed":
                    guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse task changes mark-viewed <task-id> --repository <path> --path <relative-path>") }
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repository", "--path"])
                    return BridgeRequest(command: "task.changes.mark-viewed", arguments: [
                        "taskID": .string(tail[1]),
                        "repository": .string(try requiredFlag("--repository", flags: flags).first!),
                        "path": .string(try requiredFlag("--path", flags: flags).first!),
                    ])
                case "mark-unviewed":
                    guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse task changes mark-unviewed <task-id> --repository <path> --path <relative-path>") }
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repository", "--path"])
                    return BridgeRequest(command: "task.changes.mark-unviewed", arguments: [
                        "taskID": .string(tail[1]),
                        "repository": .string(try requiredFlag("--repository", flags: flags).first!),
                        "path": .string(try requiredFlag("--path", flags: flags).first!),
                    ])
                case "mark-all-viewed":
                    guard tail.count == 2 else { throw CLIError.usage("Use: playhouse task changes mark-all-viewed <task-id>") }
                    return BridgeRequest(command: "task.changes.mark-all-viewed", arguments: ["taskID": .string(tail[1])])
                default:
                    throw CLIError.usage("Unknown task changes operation '\(action)'.")
                }
            default:
                throw CLIError.usage("Unknown task operation '\(operation)'.")
            }
        case "chat":
            if rest == ["open"] {
                return BridgeRequest(command: "chat.open")
            }
            if rest == ["status"] {
                return BridgeRequest(command: "chat.status")
            }
            guard rest.first == "page", rest.count >= 2 else {
                throw CLIError.usage("Use: playhouse chat open or playhouse chat page list|search|read|new|close-turn ...")
            }
            let tail = Array(rest.dropFirst(2))
            switch rest[1] {
            case "list":
                let flags = try parseFlags(tail, valueFlags: ["--limit"])
                var arguments: [String: BridgeValue] = [:]
                if let limit = flags["--limit"]?.first { arguments["limit"] = .string(limit) }
                return BridgeRequest(command: "chat.page.list", arguments: arguments)
            case "search":
                let query = try firstPositional(tail)
                return BridgeRequest(command: "chat.page.search", arguments: ["query": .string(query)])
            case "read":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "chat.page.read", arguments: ["pageID": .string(id)])
            case "new":
                let flags = try parseFlags(tail, valueFlags: ["--title"])
                let title = try requiredFlag("--title", flags: flags).first!
                return BridgeRequest(command: "chat.page.new", arguments: ["title": .string(title)])
            case "close-turn":
                guard let chatID = tail.first else {
                    throw CLIError.usage("Use: playhouse chat page close-turn <chat-id> --continues <true|false> [--new-title <title>]")
                }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--continues", "--new-title", "--summary-hint"])
                let continuesValue = try requiredFlag("--continues", flags: flags).first!
                guard continuesValue == "true" || continuesValue == "false" else {
                    throw CLIError.usage("Use --continues true or --continues false.")
                }
                var arguments: [String: BridgeValue] = [
                    "chatID": .string(chatID),
                    "continues": .boolean(continuesValue == "true"),
                ]
                if let newTitle = flags["--new-title"]?.first { arguments["newTitle"] = .string(newTitle) }
                if let summaryHint = flags["--summary-hint"]?.first { arguments["summaryHint"] = .string(summaryHint) }
                return BridgeRequest(command: "chat.page.close-turn", arguments: arguments)
            default:
                throw CLIError.usage("Unknown chat page operation '\(rest[1])'.")
            }
        case "workspace":
            if rest == ["repos", "list"] {
                return BridgeRequest(command: "workspace.repositories.list")
            }
            guard rest.first == "suggest" else {
                throw CLIError.usage("Use: playhouse workspace repos list or workspace suggest --parent <path>")
            }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--parent"])
            return BridgeRequest(command: "workspace.suggest", arguments: [
                "parent": .string(try requiredFlag("--parent", flags: flags).first!)
            ])
        case "plugin":
            let renderUsage = "Use: playhouse plugin render (--file <plugin.js> | --page <catalog-page> | --plugin <plugin-id> [--task <task-id>]) [--props <json>] [--event <testID>:<event>[:<value>]...] [--advance <seconds>]"
            let usage = "Use: playhouse plugin mode [--on|--off] | list | refresh | delete --id <plugin-id> | author --placement <\(pluginPlacements)> [--provider <codex|claude>] | render …"
            switch rest.first {
            case "mode":
                let options = Array(rest.dropFirst())
                switch options {
                case []: return BridgeRequest(command: "plugin.mode")
                case ["--on"]: return BridgeRequest(command: "plugin.mode", arguments: ["enabled": .boolean(true)])
                case ["--off"]: return BridgeRequest(command: "plugin.mode", arguments: ["enabled": .boolean(false)])
                default: throw CLIError.usage("Use: playhouse plugin mode [--on|--off]")
                }
            case "list", "refresh":
                guard rest.count == 1 else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "plugin.\(rest[0])")
            case "delete":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--id"])
                return BridgeRequest(command: "plugin.delete", arguments: ["pluginID": .string(try requiredFlag("--id", flags: flags).first!)])
            case "author":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--placement", "--provider"])
                var arguments: [String: BridgeValue] = ["placement": .string(try requiredFlag("--placement", flags: flags).first!)]
                arguments["provider"] = flags["--provider"]?.first.map(BridgeValue.string)
                return BridgeRequest(command: "plugin.author", arguments: arguments)
            case "render":
                break
            default:
                throw CLIError.usage(usage)
            }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--file", "--page", "--plugin", "--task", "--props", "--event", "--advance"])
            guard [flags["--file"], flags["--page"], flags["--plugin"]].compactMap({ $0 }).count == 1 else { throw CLIError.usage(renderUsage) }
            guard flags["--task"] == nil || flags["--plugin"] != nil else { throw CLIError.usage(renderUsage) }
            var arguments: [String: BridgeValue] = [:]
            // The daemon resolves paths from its own working directory, so send an absolute one.
            arguments["file"] = flags["--file"]?.first.map { path in
                .string(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path)
            }
            arguments["page"] = flags["--page"]?.first.map(BridgeValue.string)
            arguments["pluginID"] = flags["--plugin"]?.first.map(BridgeValue.string)
            arguments["taskID"] = flags["--task"]?.first.map(BridgeValue.string)
            arguments["props"] = flags["--props"]?.first.map(BridgeValue.string)
            arguments["events"] = flags["--event"].map { .array($0.map(BridgeValue.string)) }
            if let advance = flags["--advance"]?.first {
                guard let seconds = Double(advance), seconds >= 0 else { throw CLIError.usage(renderUsage) }
                arguments["advance"] = .decimal(seconds)
            }
            return BridgeRequest(command: "plugin.render", arguments: arguments)
        case "usage":
            switch rest.first {
            case "get":
                let flags = Array(rest.dropFirst())
                guard flags.allSatisfy({ $0 == "--refresh" || $0 == "--watch" }), !(flags.contains("--refresh") && flags.contains("--watch")) else {
                    throw CLIError.usage("Use: playhouse usage get [--refresh|--watch]")
                }
                if flags.contains("--watch") { return BridgeRequest(command: "usage.subscribe") }
                return BridgeRequest(command: "usage.get", arguments: ["refresh": .boolean(flags.contains("--refresh"))])
            case "login", "switch-account":
                guard rest.count == 2 else { throw CLIError.usage("Use: playhouse usage \(rest[0]) <codex|claude>") }
                return BridgeRequest(command: "usage.\(rest[0])", arguments: ["provider": .string(rest[1])])
            default:
                throw CLIError.usage("Use: playhouse usage get [--refresh|--watch]|login <codex|claude>|switch-account <codex|claude>")
            }
        case "skills":
            guard let operation = rest.first else { throw CLIError.usage("Missing skills operation.") }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: [
                "--task", "--skill", "--scope", "--name", "--description", "--body", "--root", "--content", "--content-file",
                "--message", "--include-bundled", "--field",
            ])
            var arguments: [String: BridgeValue] = [:]
            if let task = flags["--task"]?.first { arguments["taskID"] = .string(task) }
            if let root = flags["--root"]?.first { arguments["root"] = .string(root) }
            func skillID() throws -> BridgeValue { .string(try requiredFlag("--skill", flags: flags).first!) }
            func skillIDs() throws -> BridgeValue { .array(try requiredFlag("--skill", flags: flags).map(BridgeValue.string)) }
            /// `--field key=value`, repeatable; an empty value removes the field.
            func skillFields() throws -> BridgeValue? {
                guard let values = flags["--field"], !values.isEmpty else { return nil }
                var fields: [String: BridgeValue] = [:]
                for value in values {
                    guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                        throw CLIError.usage("Use --field <name>=<value>, for example --field license=MIT.")
                    }
                    fields[String(value[..<separator])] = .string(String(value[value.index(after: separator)...]))
                }
                return .object(fields)
            }
            switch operation {
            case "list":
                if let bundled = flags["--include-bundled"]?.first { arguments["includeBundled"] = .boolean(bundled == "true") }
                return BridgeRequest(command: "skills.list", arguments: arguments)
            case "get":
                arguments["skillID"] = try skillID()
                if let bundled = flags["--include-bundled"]?.first { arguments["includeBundled"] = .boolean(bundled == "true") }
                return BridgeRequest(command: "skills.get", arguments: arguments)
            case "create":
                arguments["scope"] = .string(try requiredFlag("--scope", flags: flags).first!)
                arguments["name"] = .string(try requiredFlag("--name", flags: flags).first!)
                arguments["description"] = .string(flags["--description"]?.first ?? "")
                if let body = flags["--body"]?.first { arguments["body"] = .string(body) }
                if let fields = try skillFields() { arguments["fields"] = fields }
                return BridgeRequest(command: "skills.create", arguments: arguments)
            case "update":
                arguments["skillID"] = try skillID()
                if let path = flags["--content-file"]?.first {
                    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                        throw CLIError.usage("Could not read \(path).")
                    }
                    arguments["content"] = .string(content)
                } else if let content = flags["--content"]?.first {
                    arguments["content"] = .string(content)
                } else {
                    // A structured edit: only the parts given change.
                    if let description = flags["--description"]?.first { arguments["description"] = .string(description) }
                    if let body = flags["--body"]?.first { arguments["body"] = .string(body) }
                    if let fields = try skillFields() { arguments["fields"] = fields }
                    guard arguments["description"] != nil || arguments["body"] != nil || arguments["fields"] != nil else {
                        throw CLIError.usage("Use --content, --content-file, or any of --description, --body, and --field.")
                    }
                }
                return BridgeRequest(command: "skills.update", arguments: arguments)
            case "move":
                arguments["skillID"] = try skillID()
                arguments["scope"] = .string(try requiredFlag("--scope", flags: flags).first!)
                return BridgeRequest(command: "skills.move", arguments: arguments)
            case "enable", "disable":
                arguments["skillID"] = try skillID()
                arguments["enabled"] = .boolean(operation == "enable")
                if let bundled = flags["--include-bundled"]?.first { arguments["includeBundled"] = .boolean(bundled == "true") }
                return BridgeRequest(command: "skills.enable", arguments: arguments)
            case "delete":
                arguments["skillIDs"] = try skillIDs()
                return BridgeRequest(command: "skills.delete", arguments: arguments)
            case "fix":
                guard arguments["taskID"] != nil else { throw CLIError.usage("Use: playhouse skills fix --task <task-id> --skill <skill-id> [--skill <skill-id>...]") }
                arguments["skillIDs"] = try skillIDs()
                return BridgeRequest(command: "skills.fix", arguments: arguments)
            case "link", "unlink":
                arguments["skillID"] = try skillID()
                return BridgeRequest(command: "skills.\(operation)", arguments: arguments)
            case "bridge":
                guard arguments["taskID"] != nil else { throw CLIError.usage("Use: playhouse skills bridge --task <task-id> [--message <text>]") }
                if let message = flags["--message"]?.first { arguments["message"] = .string(message) }
                return BridgeRequest(command: "skills.bridge", arguments: arguments)
            default:
                throw CLIError.usage("Unknown skills operation \(operation).")
            }
        case "mcp":
            guard let operation = rest.first else { throw CLIError.usage("Missing mcp operation.") }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: [
                "--task", "--server", "--scope", "--name", "--root", "--command", "--arg", "--env", "--url", "--header", "--config-json", "--provider",
            ])
            var arguments: [String: BridgeValue] = [:]
            if let task = flags["--task"]?.first { arguments["taskID"] = .string(task) }
            if let root = flags["--root"]?.first { arguments["root"] = .string(root) }
            func serverID() throws -> BridgeValue { .string(try requiredFlag("--server", flags: flags).first!) }
            /// The definition from --config-json, or from --command/--arg/--env or --url/--header.
            func config() throws -> BridgeValue {
                if let json = flags["--config-json"]?.first {
                    guard let data = json.data(using: .utf8),
                          let value = try? JSONDecoder().decode(BridgeValue.self, from: data), value.object != nil else {
                        throw CLIError.usage("--config-json must be a JSON object.")
                    }
                    return value
                }
                func pairs(_ flag: String, separator: Character) throws -> [String: BridgeValue] {
                    var result: [String: BridgeValue] = [:]
                    for entry in flags[flag] ?? [] {
                        guard let index = entry.firstIndex(of: separator), index != entry.startIndex else {
                            throw CLIError.usage(flag == "--env" ? "Use --env NAME=value." : "Use --header \"Name: value\".")
                        }
                        result[String(entry[..<index]).trimmingCharacters(in: .whitespaces)] =
                            .string(String(entry[entry.index(after: index)...]).trimmingCharacters(in: .whitespaces))
                    }
                    return result
                }
                if let url = flags["--url"]?.first {
                    return .object(["transport": .string("http"), "url": .string(url), "headers": .object(try pairs("--header", separator: ":"))])
                }
                guard let command = flags["--command"]?.first else { throw CLIError.usage("Use --command <command> or --url <url>, or --config-json.") }
                return .object([
                    "transport": .string("stdio"), "command": .string(command),
                    "args": .array((flags["--arg"] ?? []).map(BridgeValue.string)), "env": .object(try pairs("--env", separator: "=")),
                ])
            }
            switch operation {
            case "list":
                return BridgeRequest(command: "mcp.list", arguments: arguments)
            case "get":
                arguments["serverID"] = try serverID()
                return BridgeRequest(command: "mcp.get", arguments: arguments)
            case "create":
                arguments["scope"] = .string(try requiredFlag("--scope", flags: flags).first!)
                arguments["name"] = .string(try requiredFlag("--name", flags: flags).first!)
                arguments["config"] = try config()
                return BridgeRequest(command: "mcp.create", arguments: arguments)
            case "update":
                arguments["serverID"] = try serverID()
                arguments["config"] = try config()
                return BridgeRequest(command: "mcp.update", arguments: arguments)
            case "enable", "disable":
                arguments["serverID"] = try serverID()
                arguments["enabled"] = .boolean(operation == "enable")
                return BridgeRequest(command: "mcp.enable", arguments: arguments)
            case "delete":
                arguments["serverIDs"] = .array(try requiredFlag("--server", flags: flags).map(BridgeValue.string))
                return BridgeRequest(command: "mcp.delete", arguments: arguments)
            case "link":
                arguments["serverID"] = try serverID()
                return BridgeRequest(command: "mcp.link", arguments: arguments)
            case "fix":
                guard arguments["taskID"] != nil else { throw CLIError.usage("Use: playhouse mcp fix --task <task-id> --server <server-id> [--server <server-id>...]") }
                arguments["serverIDs"] = .array(try requiredFlag("--server", flags: flags).map(BridgeValue.string))
                return BridgeRequest(command: "mcp.fix", arguments: arguments)
            case "bridge":
                guard arguments["taskID"] != nil else { throw CLIError.usage("Use: playhouse mcp bridge --task <task-id>") }
                return BridgeRequest(command: "mcp.bridge", arguments: arguments)
            case "status":
                if let provider = flags["--provider"]?.first { arguments["provider"] = .string(provider) }
                return BridgeRequest(command: "mcp.status", arguments: arguments)
            case "authenticate", "authenticate-wait":
                arguments["provider"] = .string(try requiredFlag("--provider", flags: flags).first!)
                arguments["name"] = .string(try requiredFlag("--name", flags: flags).first!)
                return BridgeRequest(command: operation == "authenticate" ? "mcp.authenticate" : "mcp.authenticate.wait", arguments: arguments)
            default:
                throw CLIError.usage("Unknown mcp operation \(operation).")
            }
        case "rules":
            guard let operation = rest.first else { throw CLIError.usage("Missing rules operation.") }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: [
                "--task", "--rule", "--scope", "--name", "--path", "--body", "--root", "--content", "--content-file",
            ])
            var arguments: [String: BridgeValue] = [:]
            if let task = flags["--task"]?.first { arguments["taskID"] = .string(task) }
            if let root = flags["--root"]?.first { arguments["root"] = .string(root) }
            func ruleID() throws -> BridgeValue { .string(try requiredFlag("--rule", flags: flags).first!) }
            switch operation {
            case "list":
                return BridgeRequest(command: "rules.list", arguments: arguments)
            case "get":
                arguments["ruleID"] = try ruleID()
                return BridgeRequest(command: "rules.get", arguments: arguments)
            case "create":
                arguments["scope"] = .string(try requiredFlag("--scope", flags: flags).first!)
                if let name = flags["--name"]?.first { arguments["name"] = .string(name) }
                if let paths = flags["--path"], !paths.isEmpty { arguments["paths"] = .array(paths.map(BridgeValue.string)) }
                arguments["body"] = .string(flags["--body"]?.first ?? "")
                return BridgeRequest(command: "rules.create", arguments: arguments)
            case "update":
                arguments["ruleID"] = try ruleID()
                if let path = flags["--content-file"]?.first {
                    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                        throw CLIError.usage("Could not read \(path).")
                    }
                    arguments["content"] = .string(content)
                } else if let content = flags["--content"]?.first {
                    arguments["content"] = .string(content)
                } else {
                    throw CLIError.usage("Use --content or --content-file.")
                }
                return BridgeRequest(command: "rules.update", arguments: arguments)
            case "enable", "disable":
                arguments["ruleID"] = try ruleID()
                arguments["enabled"] = .boolean(operation == "enable")
                return BridgeRequest(command: "rules.enable", arguments: arguments)
            case "delete":
                arguments["ruleIDs"] = .array(try requiredFlag("--rule", flags: flags).map(BridgeValue.string))
                return BridgeRequest(command: "rules.delete", arguments: arguments)
            case "fix":
                guard arguments["taskID"] != nil else { throw CLIError.usage("Use: playhouse rules fix --task <task-id> --rule <rule-id> [--rule <rule-id>...]") }
                arguments["ruleIDs"] = .array(try requiredFlag("--rule", flags: flags).map(BridgeValue.string))
                return BridgeRequest(command: "rules.fix", arguments: arguments)
            case "link", "unlink":
                arguments["ruleID"] = try ruleID()
                return BridgeRequest(command: "rules.\(operation)", arguments: arguments)
            case "bridge":
                guard arguments["taskID"] != nil else { throw CLIError.usage("Use: playhouse rules bridge --task <task-id>") }
                return BridgeRequest(command: "rules.bridge", arguments: arguments)
            default:
                throw CLIError.usage("Unknown rules operation \(operation).")
            }
        case "schedule":
            guard let operation = rest.first else {
                throw CLIError.usage("Use: playhouse schedule list|set|clear|pause|resume|run-now|tick ...")
            }
            let tail = Array(rest.dropFirst())
            switch operation {
            case "list":
                return BridgeRequest(command: "schedule.list")
            case "set":
                let usage = "Use: playhouse schedule set <task-id> --prompt <text> (--once <ISO8601> | --repeat <hourly|daily|weekdays|weekly> [--time HH:MM] [--minute MM] [--weekday mon]) [--title <title>] [--image <path>...] [--mode default|plan] [--model <id>]"
                guard let id = tail.first, !id.hasPrefix("--") else { throw CLIError.usage(usage) }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: [
                    "--prompt", "--once", "--repeat", "--time", "--minute", "--weekday", "--title", "--image", "--mode", "--model"
                ])
                guard (flags["--once"] == nil) != (flags["--repeat"] == nil) else { throw CLIError.usage(usage) }
                var arguments: [String: BridgeValue] = [
                    "taskID": .string(id),
                    "kind": .string(flags["--once"] != nil ? "once" : "recurring"),
                    "prompt": .string(flags["--prompt"]?.first ?? ""),
                    "images": .array(try (flags["--image"] ?? []).map(draftImageDataURL))
                ]
                let names = ["--once": "at", "--repeat": "repeat", "--time": "time", "--minute": "minute", "--weekday": "weekday", "--title": "title", "--mode": "mode", "--model": "model"]
                for (flag, name) in names {
                    if let value = flags[flag]?.first { arguments[name] = .string(value) }
                }
                return BridgeRequest(command: "schedule.set", arguments: arguments)
            case "clear", "pause", "resume", "run-now":
                guard tail.count == 1 else { throw CLIError.usage("Use: playhouse schedule \(operation) <task-id>") }
                return BridgeRequest(command: "schedule.\(operation)", arguments: ["taskID": .string(tail[0])])
            case "tick":
                let flags = try parseFlags(tail, valueFlags: ["--now"])
                var arguments: [String: BridgeValue] = [:]
                if let now = flags["--now"]?.first { arguments["now"] = .string(now) }
                return BridgeRequest(command: "schedule.tick", arguments: arguments)
            default:
                throw CLIError.usage("Unknown schedule operation '\(operation)'.")
            }
        case "settings":
            guard let operation = rest.first else { throw CLIError.usage("Missing settings operation.") }
            switch operation {
            case "get": return BridgeRequest(command: "settings.get")
            case "clear-parent": return BridgeRequest(command: "settings.clear-parent")
            case "set-appearance":
                guard rest.count == 2 else { throw CLIError.usage("Use: playhouse settings set-appearance <dark|light>") }
                return BridgeRequest(command: "settings.set-appearance", arguments: ["appearance": .string(rest[1])])
            case "set-default-provider":
                guard rest.count == 2 else { throw CLIError.usage("Use: playhouse settings set-default-provider <codex|claude>") }
                return BridgeRequest(command: "settings.set-default-provider", arguments: ["provider": .string(rest[1])])
            case "set-token-usage-color-max":
                guard rest.count == 2, let max = Int(rest[1]) else {
                    throw CLIError.usage("Use: playhouse settings set-token-usage-color-max <tokens>")
                }
                return BridgeRequest(command: "settings.set-token-usage-color-max", arguments: ["max": .integer(max)])
            case "set-cpu-usage-color-max":
                guard rest.count == 2, let max = Int(rest[1]) else {
                    throw CLIError.usage("Use: playhouse settings set-cpu-usage-color-max <percent>")
                }
                return BridgeRequest(command: "settings.set-cpu-usage-color-max", arguments: ["max": .integer(max)])
            case "set-parent":
                guard rest.count == 2 else { throw CLIError.usage("Use: playhouse settings set-parent <path>") }
                return BridgeRequest(command: "settings.set-parent", arguments: ["path": .string(rest[1])])
            case "set-last-repositories":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--repo"])
                return BridgeRequest(command: "settings.set-last-repositories", arguments: [
                    "repositories": .array((flags["--repo"] ?? []).map(BridgeValue.string))
                ])
            default: throw CLIError.usage("Unknown settings operation '\(operation)'.")
            }
        case "conversation":
            guard let operation = rest.first else { throw CLIError.usage("Missing conversation operation.") }
            let tail = Array(rest.dropFirst())
            if operation == "runtime" {
                guard tail.isEmpty || tail == ["--watch"] else { throw CLIError.usage("Use: playhouse conversation runtime [--watch]") }
                return BridgeRequest(command: tail.isEmpty ? "conversation.runtime" : "conversation.runtime.subscribe")
            }
            if operation == "cpu-usage" {
                guard tail.isEmpty || tail == ["--watch"] else { throw CLIError.usage("Use: playhouse conversation cpu-usage [--watch]") }
                return BridgeRequest(command: tail.isEmpty ? "conversation.cpuUsage" : "conversation.cpuUsage.subscribe")
            }
            guard let id = tail.first else { throw CLIError.usage("A task ID is required.") }
            switch operation {
            case "watch":
                guard tail.count == 1 else { throw CLIError.usage("Use: playhouse conversation watch <task-id>") }
                return BridgeRequest(command: "conversation.events.subscribe", arguments: ["taskID": .string(id)])
            case "history":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--limit", "--before"])
                var arguments: [String: BridgeValue] = ["taskID": .string(id)]
                if let limit = flags["--limit"]?.first { arguments["limit"] = .string(limit) }
                if let before = flags["--before"]?.first { arguments["before"] = .string(before) }
                return BridgeRequest(command: "conversation.history", arguments: arguments)
            case "present-image":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--image", "--caption"])
                guard let path = flags["--image"]?.first, !path.isEmpty else {
                    throw CLIError.usage("Use: playhouse conversation present-image <task-id> --image <path> [--caption <text>]")
                }
                let url = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: url)
                guard data.count <= 10_000_000 else { throw CLIError.usage("The image must be smaller than 10 MB.") }
                return BridgeRequest(command: "conversation.present-image", arguments: [
                    "taskID": .string(id), "path": .string(path),
                    "caption": .string(flags["--caption"]?.first ?? "")
                ])
            case "models":
                switch Array(tail.dropFirst()) {
                case []: return BridgeRequest(command: "conversation.models", arguments: ["taskID": .string(id)])
                case ["--cached"]: return BridgeRequest(command: "conversation.models.cached", arguments: ["taskID": .string(id)])
                default: throw CLIError.usage("Use: playhouse conversation models <task-id> [--cached]")
                }
            case "effort":
                let effortArguments = Array(tail.dropFirst())
                if effortArguments.isEmpty {
                    return BridgeRequest(command: "conversation.effort.get", arguments: ["taskID": .string(id)])
                }
                if effortArguments.count == 2, effortArguments[0] == "set" {
                    return BridgeRequest(command: "conversation.effort.set", arguments: [
                        "taskID": .string(id), "effort": .string(effortArguments[1]),
                    ])
                }
                throw CLIError.usage("Use: playhouse conversation effort <task-id> [set <low|medium|high|xhigh>]")
            case "model":
                let modelArguments = Array(tail.dropFirst())
                if modelArguments.isEmpty {
                    return BridgeRequest(command: "conversation.model.get", arguments: ["taskID": .string(id)])
                }
                if modelArguments.count == 2, modelArguments[0] == "set" {
                    return BridgeRequest(command: "conversation.model.set", arguments: [
                        "taskID": .string(id), "modelID": .string(modelArguments[1]),
                    ])
                }
                throw CLIError.usage("Use: playhouse conversation model <task-id> [set <model-id>]")
            case "stop": return BridgeRequest(command: "conversation.stop", arguments: ["taskID": .string(id)])
            case "provider":
                switch Array(tail.dropFirst()) {
                case []: return BridgeRequest(command: "conversation.provider.get", arguments: ["taskID": .string(id)])
                case ["capabilities"]: return BridgeRequest(command: "conversation.provider.capabilities", arguments: ["taskID": .string(id)])
                case let values where values.count == 2 && values[0] == "set":
                    return BridgeRequest(command: "conversation.provider.set", arguments: ["taskID": .string(id), "provider": .string(values[1])])
                default:
                    throw CLIError.usage("Use: playhouse conversation provider <task-id> [set <codex|claude>|capabilities]")
                }
            case "goal":
                guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse conversation goal <task-id> <get|set|pause|resume|clear> [--text <objective>]") }
                let action = tail[1]
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--text"])
                var arguments: [String: BridgeValue] = ["taskID": .string(id), "action": .string(action)]
                if let text = flags["--text"]?.first { arguments["objective"] = .string(text) }
                return BridgeRequest(command: "conversation.goal", arguments: arguments)
            case "queue":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--image"])
                return BridgeRequest(command: "conversation.queue", arguments: [
                    "taskID": .string(id), "message": .string(flags["--message"]?.first ?? ""),
                    "images": .array(try imageDataURLs(flags["--image"] ?? []))
                ])
            case "subagent-history":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--activity"])
                guard let activityJSON = flags["--activity"]?.first,
                      let activity = try? JSONDecoder().decode(BridgeValue.self, from: Data(activityJSON.utf8)) else {
                    throw CLIError.usage("Use: playhouse conversation subagent-history <task-id> --activity <activity-json>")
                }
                return BridgeRequest(command: "conversation.subagent_history", arguments: ["taskID": .string(id), "activity": activity])
            case "answered-async": return BridgeRequest(command: "conversation.answered_async", arguments: ["taskID": .string(id)])
            case "queue-list": return BridgeRequest(command: "conversation.queue.list", arguments: ["taskID": .string(id)])
            case "queue-retry":
                guard tail.count == 2 else { throw CLIError.usage("Use: playhouse conversation queue-retry <task-id> <message-id>") }
                return BridgeRequest(command: "conversation.queue.retry", arguments: ["taskID": .string(id), "messageID": .string(tail[1])])
            case "queue-remove":
                guard tail.count == 2 else { throw CLIError.usage("Use: playhouse conversation queue-remove <task-id> <message-id>") }
                return BridgeRequest(command: "conversation.queue.remove", arguments: ["taskID": .string(id), "messageID": .string(tail[1])])
            case "queue-steer":
                guard tail.count == 2 else { throw CLIError.usage("Use: playhouse conversation queue-steer <task-id> <message-id>") }
                return BridgeRequest(command: "conversation.queue.steer", arguments: ["taskID": .string(id), "messageID": .string(tail[1])])
            case "steer":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--image"])
                return BridgeRequest(command: "conversation.steer", arguments: [
                    "taskID": .string(id), "message": .string(flags["--message"]?.first ?? ""),
                    "images": .array(try imageDataURLs(flags["--image"] ?? []))
                ])
            case "repair-user-input":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--from-task"])
                guard let sourceTaskID = flags["--from-task"]?.first else {
                    throw CLIError.usage("Use: playhouse conversation repair-user-input <task-id> --from-task <source-task-id>")
                }
                return BridgeRequest(command: "conversation.repair_user_input", arguments: ["taskID": .string(id), "sourceTaskID": .string(sourceTaskID)])
            case "answer-async":
                guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse conversation answer-async <task-id> <item-id> --answer <text> [--answer <text>]...") }
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--answer"])
                return BridgeRequest(command: "conversation.answer_async", arguments: [
                    "taskID": .string(id), "itemID": .string(tail[1]),
                    "answers": .array((flags["--answer"] ?? []).map(BridgeValue.string))
                ])
            case "answer-user-input":
                guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse conversation answer-user-input <task-id> <request-id> --answer <question-id>=<answer> [--answer <question-id>=<answer>]...") }
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--answer"])
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
                return BridgeRequest(command: "conversation.answer_user_input", arguments: [
                    "taskID": .string(id), "requestID": .string(tail[1]),
                    "answers": .object(answers.mapValues { .array($0.map(BridgeValue.string)) })
                ])
            case "side-chat":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--selection", "--source", "--side-chat", "--model", "--effort"])
                guard let message = flags["--message"]?.first,
                      (flags["--selection"]?.first != nil) != (flags["--side-chat"]?.first != nil),
                      flags["--source"] == nil || flags["--selection"] != nil else {
                    throw CLIError.usage("Use: playhouse conversation side-chat <task-id> --message <text> (--selection <text> [--source <json>] | --side-chat <side-chat-id>) [--model <model-id>] [--effort <low|medium|high|xhigh>]")
                }
                var arguments: [String: BridgeValue] = ["taskID": .string(id), "message": .string(message)]
                if let model = flags["--model"]?.first { arguments["model"] = .string(model) }
                if let effort = flags["--effort"]?.first { arguments["effort"] = .string(effort) }
                if let selection = flags["--selection"]?.first { arguments["selection"] = .string(selection) }
                if let source = flags["--source"]?.first { arguments["source"] = .string(source) }
                if let sideChatID = flags["--side-chat"]?.first { arguments["sideChatID"] = .string(sideChatID) }
                return BridgeRequest(command: "conversation.side_chat", arguments: arguments)
            case "side-chats":
                guard tail.count == 1 else { throw CLIError.usage("Use: playhouse conversation side-chats <task-id>") }
                return BridgeRequest(command: "conversation.side_chats.list", arguments: ["taskID": .string(id)])
            case "side-chat-close":
                guard tail.count == 2 else { throw CLIError.usage("Use: playhouse conversation side-chat-close <task-id> <side-chat-id>") }
                return BridgeRequest(command: "conversation.side_chat.close", arguments: ["taskID": .string(id), "sideChatID": .string(tail[1])])
            case "send":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--mode", "--model", "--answer", "--image", "--context-page"])
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
                let images = try imageDataURLs(flags["--image"] ?? [])
                var sendArguments: [String: BridgeValue] = [
                    "taskID": .string(id),
                    "message": .string(flags["--message"]?.first ?? ""),
                    "mode": .string(flags["--mode"]?.first ?? "default"),
                    "answers": .object(answers.mapValues { BridgeValue.array($0.map(BridgeValue.string)) }),
                    "images": .array(images)
                ]
                // Without --model, the task's provider chooses its default model.
                if let model = flags["--model"]?.first { sendArguments["model"] = .string(model) }
                // Standalone chat only: pages an annotation points at, carried for this turn.
                if let contextPages = flags["--context-page"] {
                    sendArguments["contextPages"] = .array(contextPages.map(BridgeValue.string))
                }
                return BridgeRequest(command: "conversation.send", arguments: sendArguments)
            default: throw CLIError.usage("Unknown conversation operation '\(operation)'.")
            }
        default:
            throw CLIError.usage("Unknown command group '\(group)'.")
        }
    }

    /// Conversation image flags as data URLs; the bridge validates the image bytes.
    private static func imageDataURLs(_ paths: [String]) throws -> [BridgeValue] {
        try paths.map { path in
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard data.count <= 10_000_000 else { throw CLIError.usage("Each image must be smaller than 10 MB.") }
            let mime = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "image/jpeg" : "image/png"
            return .string("data:\(mime);base64,\(data.base64EncodedString())")
        }
    }

    private static let pluginPlacements = "mainSidebar|conversationSidebar|conversationToolbar|composerActions"

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

    private static func draftImageDataURL(_ path: String) throws -> BridgeValue {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let mime: String
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { mime = "image/png" }
        else if data.starts(with: [255, 216, 255]) { mime = "image/jpeg" }
        else { throw CLIError.usage("Images must be PNG or JPEG files.") }
        return .string("data:\(mime);base64,\(data.base64EncodedString())")
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
    Playhouse CLI (talks to the bridge daemon bundled in Playhouse.app, starting it on demand)

    Usage:
      playhouse status
      playhouse board list
      playhouse archive search <query>
      playhouse task list|get <task-id>
      playhouse task create --title <title> --prompt <text> --root <path> [--root <path>...] [--provider <codex|claude>]
      playhouse task create --title <title> --prompt <text> --repo <path> [--repo <path>...] [--branch <repo-path>=<name>] [--branch-from <repo-path>=<ref>] [--merge-target <repo-path>=<local-branch>]
      playhouse task move <task-id> Review
      playhouse task move <task-id> Done
      playhouse task move <task-id> Done --allow-unmerged
      playhouse task move <task-id> Done --discard-changes
      playhouse task pr create <task-id>
      playhouse task pr status <task-id>
      playhouse task pr verify <task-id>
      playhouse task pr sync <task-id>
      playhouse task pr mode <task-id> <manual|pr|autopilot|merge>
      playhouse task pr autopilot <task-id>
      playhouse task progress publish <task-id> --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail <text>]
      playhouse task progress custom <task-id> --label <label> [--detail <text>]
      playhouse task progress clear <task-id>
      playhouse task outcome <task-id> <completed|in-progress|waiting-response>
      playhouse task rename <task-id> --title <title>
      playhouse schedule list
      playhouse schedule set <task-id> --prompt <text> --once <ISO8601> [--image <path>...] [--mode default|plan] [--model <id>]
      playhouse schedule set <task-id> --prompt <text> --repeat <hourly|daily|weekdays|weekly> --title <title> [--time HH:MM] [--minute MM] [--weekday mon] [--image <path>...] [--mode default|plan] [--model <id>]
      playhouse schedule clear|pause|resume|run-now <task-id>
      playhouse schedule tick
      playhouse task repository add <task-id> --repo <path>
      playhouse task repository add-batch <task-id> --repo <path> [--repo <path>...]
      playhouse task repository replace <task-id> --repo <path> [--repo <path>...]
      playhouse task repository edit <task-id> --repo <path> --branch <name> --branch-from <ref> [--merge-target <ref>]
      playhouse task repository remove <task-id> --repo <path>
      playhouse task repository renew <task-id> --repo <path>   (after its pull request merged: fresh worktree from the merge target)
      playhouse task repository recent <task-id>
      playhouse task prompt <task-id> --text <prompt> [--status <status>] [--submitted true]
      playhouse task draft <task-id> --text <draft> [--image <path>...]
      playhouse task comments <task-id> --json <comments-array> [--append]   (save unsent review comments with the draft; [] clears; --append adds only new ones)
      playhouse task comments <task-id> edit <comment-id> --text <text>   (change an unsent comment; empty text deletes it)
      playhouse task roots get <task-id>
      playhouse task roots set <task-id> --root <path> [--root <path>...]
      playhouse task terminal <task-id>
      playhouse task changes list <task-id>
      playhouse task changes diff <task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>
      playhouse task changes mark-viewed <task-id> --repository <path> --path <relative-path>
      playhouse task changes mark-unviewed <task-id> --repository <path> --path <relative-path>
      playhouse task changes mark-all-viewed <task-id>
      playhouse task delete <task-id>
      playhouse task delete-check <task-id>
      playhouse chat open
      playhouse chat status
      playhouse chat page list [--limit <n>]
      playhouse chat page search <query>
      playhouse chat page read <page-id>
      playhouse chat page new --title <title>
      playhouse chat page close-turn <chat-id> --continues <true|false> [--new-title <title>] [--summary-hint <text>]
      playhouse workspace suggest --parent <path>
      playhouse workspace repos list
      playhouse plugin mode [--on|--off]
      playhouse plugin list|refresh
      playhouse plugin delete --id <plugin-id>
      playhouse plugin author --placement <mainSidebar|conversationSidebar|conversationToolbar|composerActions> [--provider <codex|claude>]
      playhouse plugin render (--file <plugin.js> | --page <catalog-page> | --plugin <plugin-id> [--task <task-id>]) [--props <json>] [--event <testID>:<event>[:<value>]...] [--advance <seconds>]
      playhouse usage get [--refresh|--watch]|login <codex|claude>|switch-account <codex|claude>
      playhouse skills list [--task <task-id>] [--include-bundled true]
      playhouse skills get --skill <skill-id> [--task <task-id>]
      playhouse skills create --scope <repo|private|global> --name <name> --description <text> [--body <text>] [--field <name>=<value>...] [--task <task-id>] [--root <repo-path>]
      playhouse skills update --skill <skill-id> (--content <text>|--content-file <path>|[--description <text>] [--body <text>] [--field <name>=<value>...]) [--task <task-id>]
      playhouse skills move --skill <skill-id> --scope <repo|private|global> [--root <repo-path>] [--task <task-id>]
      playhouse skills enable|disable|link|unlink --skill <skill-id> [--task <task-id>]
      playhouse skills delete --skill <skill-id> [--skill <skill-id>...] [--task <task-id>]
      playhouse skills fix --task <task-id> --skill <skill-id> [--skill <skill-id>...]
      playhouse skills bridge --task <task-id> [--message <text>]
      playhouse rules list [--task <task-id>]
      playhouse rules get --rule <rule-id> [--task <task-id>]
      playhouse rules create --scope <repo|global> [--name <name>] [--path <glob>...] --body <text> [--task <task-id>] [--root <repo-path>]
      playhouse rules update --rule <rule-id> (--content <text>|--content-file <path>) [--task <task-id>]
      playhouse rules enable|disable|link|unlink --rule <rule-id> [--task <task-id>]
      playhouse rules delete --rule <rule-id> [--rule <rule-id>...] [--task <task-id>]
      playhouse rules fix --task <task-id> --rule <rule-id> [--rule <rule-id>...]
      playhouse rules bridge --task <task-id>
      playhouse mcp list [--task <task-id>]
      playhouse mcp get --server <server-id> [--task <task-id>]
      playhouse mcp create --scope <repo|global> --name <name> (--command <command> [--arg <arg>...] [--env NAME=value...] | --url <url> [--header "Name: value"...] | --config-json <json>) [--task <task-id>] [--root <repo-path>]
      playhouse mcp update --server <server-id> (--command ... | --url ... | --config-json <json>) [--task <task-id>]
      playhouse mcp enable|disable|link --server <server-id> [--task <task-id>]
      playhouse mcp delete --server <server-id> [--server <server-id>...] [--task <task-id>]
      playhouse mcp fix --task <task-id> --server <server-id> [--server <server-id>...]
      playhouse mcp bridge --task <task-id>
      playhouse mcp status [--task <task-id>] [--provider <claude|codex>]
      playhouse mcp authenticate --provider <claude|codex> --name <server-name> [--task <task-id>]
      playhouse mcp authenticate-wait --provider <claude|codex> --name <server-name> [--task <task-id>]
      playhouse settings get|clear-parent|set-parent <path>|set-last-repositories --repo <path>...|set-appearance <dark|light>|set-default-provider <codex|claude>|set-token-usage-color-max <tokens>|set-cpu-usage-color-max <percent>
      playhouse task token-usage <task-id>
      playhouse task token-waste <task-id>
      playhouse task raw-input <task-id> [--agent <id>] [--scope final|all|request] [--request <n>] [--order transcript|size|rent] [--query <text>] [--offset <n>] [--limit <n>] [--focus <item>]
      playhouse task raw-input-export <task-id> [--agent <id>] [--request <n>] [--format text|json]
      playhouse task raw-input-text <task-id> --item <n> [--agent <id>] [--offset <n>] [--length <n>]
      playhouse task cpu-usage <task-id>
      playhouse conversation history <task-id> [--limit <messages>] [--before <message-id>]
      playhouse conversation present-image <task-id> --image <path> [--caption <text>]
      playhouse conversation queue <task-id> --message <text> [--image <path>]...
      playhouse conversation queue-list <task-id>
      playhouse conversation runtime [--watch]
      playhouse conversation cpu-usage [--watch]
      playhouse conversation watch <task-id>
      playhouse conversation answered-async <task-id>
      playhouse conversation subagent-history <task-id> --activity <activity-json>
      playhouse task reconcile <task-id>
      playhouse task title <task-id> --prompt <text>
      playhouse conversation queue-retry <task-id> <message-id>
      playhouse conversation queue-remove <task-id> <message-id>
      playhouse conversation queue-steer <task-id> <message-id>
      playhouse conversation steer <task-id> --message <text> [--image <path>]...
      playhouse conversation answer-async <task-id> <item-id> --answer <text> [--answer <text>]...
      playhouse conversation repair-user-input <task-id> --from-task <source-task-id>
      playhouse conversation answer-user-input <task-id> <request-id> --answer <question-id>=<answer> [--answer <question-id>=<answer>]...
      playhouse conversation models <task-id>
      playhouse conversation effort <task-id> [set <low|medium|high|xhigh>]
      playhouse conversation model <task-id> [set <model-id>]
      playhouse conversation models <task-id> --cached
      playhouse conversation stop <task-id>
      playhouse conversation provider <task-id> [set <codex|claude>|capabilities]
      playhouse conversation goal <task-id> <get|set|pause|resume|clear> [--text <objective>]
      playhouse conversation side-chat <task-id> --message <text> (--selection <text> [--source <json>] | --side-chat <side-chat-id>) [--model <model-id>] [--effort <low|medium|high|xhigh>]
      playhouse conversation side-chats <task-id>
      playhouse conversation side-chat-close <task-id> <side-chat-id>
      playhouse conversation send <task-id> --message <text> [--image <path>]... [--mode <default|plan>] [--model <model-id>] [--answer <question-id>=<answer>...] [--context-page <page-id>]...

    Results are JSON. Conversation send emits JSON event lines followed by a final response.
    Conversation commands use the task's provider; tasks without one use Codex.
    Conversation models --cached reads the last saved list without contacting the provider.
    """
}

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let message) = self { message } else { "Invalid CLI arguments." } }
}
