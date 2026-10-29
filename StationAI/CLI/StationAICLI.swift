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
        configuredRequest.environment = ProcessInfo.processInfo.environment
            .filter { BridgeContract.sessionEnvironmentNames.contains($0.key) }
        if let fixtureExecutable = ProcessInfo.processInfo.environment["STATIONAI_E2E_CODEX_EXECUTABLE"] {
            configuredRequest.arguments["__codexExecutable"] = .string(fixtureExecutable)
        }
        if let fixtureExecutable = ProcessInfo.processInfo.environment["STATIONAI_E2E_CLAUDE_EXECUTABLE"] {
            configuredRequest.arguments["__claudeExecutable"] = .string(fixtureExecutable)
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
        case "archive":
            guard rest.count == 2, rest[0] == "search" else { throw CLIError.usage("Use: stationai archive search <query>") }
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
                let flags = try parseFlags(tail, valueFlags: ["--title", "--root", "--repo", "--branch", "--branch-from", "--merge-target", "--provider"])
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
                return BridgeRequest(command: "task.create", arguments: createArguments)
            case "get", "show":
                let id = try firstPositional(tail)
                return BridgeRequest(command: "task.get", arguments: ["taskID": .string(id)])
            case "move":
                guard (2...3).contains(tail.count), tail.count == 2 || tail[2] == "--allow-unmerged" else {
                    throw CLIError.usage("Use: stationai task move <task-id> <status> [--allow-unmerged]")
                }
                return BridgeRequest(command: "task.move", arguments: [
                    "taskID": .string(tail[0]), "status": .string(tail[1]),
                    "allowUnmergedPullRequests": .boolean(tail.count == 3)
                ])
            case "pr":
                guard tail.count >= 2 else {
                    throw CLIError.usage("Use: stationai task pr create|conflicts|status|verify|resolve <task-id> [action]")
                }
                switch tail[0] {
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
                default:
                    throw CLIError.usage("Use: stationai task pr create|conflicts|status|verify|resolve <task-id> [resolve-and-push|resolve-only|keep]")
                }
            case "progress":
                guard let action = tail.first else { throw CLIError.usage("Use: stationai task progress publish|custom|clear <task-id> ...") }
                let values = Array(tail.dropFirst())
                switch action {
                case "publish":
                    guard let id = values.first else { throw CLIError.usage("Use: stationai task progress publish <task-id> --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail <text>]") }
                    let flags = try parseFlags(Array(values.dropFirst()), valueFlags: ["--type", "--detail"])
                    var requestArguments: [String: BridgeValue] = [
                        "taskID": .string(id),
                        "type": .string(try requiredFlag("--type", flags: flags).first!)
                    ]
                    if let detail = flags["--detail"]?.first { requestArguments["detail"] = .string(detail) }
                    return BridgeRequest(command: "task.progress.publish", arguments: requestArguments)
                case "custom":
                    guard let id = values.first else { throw CLIError.usage("Use: stationai task progress custom <task-id> --label <label> [--detail <text>]") }
                    let flags = try parseFlags(Array(values.dropFirst()), valueFlags: ["--label", "--detail"])
                    var requestArguments: [String: BridgeValue] = [
                        "taskID": .string(id),
                        "label": .string(try requiredFlag("--label", flags: flags).first!)
                    ]
                    if let detail = flags["--detail"]?.first { requestArguments["detail"] = .string(detail) }
                    return BridgeRequest(command: "task.progress.custom", arguments: requestArguments)
                case "clear":
                    guard values.count == 1 else { throw CLIError.usage("Use: stationai task progress clear <task-id>") }
                    return BridgeRequest(command: "task.progress.clear", arguments: ["taskID": .string(values[0])])
                default:
                    throw CLIError.usage("Unknown task progress operation '\(action)'.")
                }
            case "outcome":
                guard tail.count == 2 else {
                    throw CLIError.usage("Use: stationai task outcome <task-id> <completed|waiting-response>")
                }
                return BridgeRequest(command: "task.outcome", arguments: [
                    "taskID": .string(tail[0]), "outcome": .string(tail[1])
                ])
            case "reconcile":
                guard tail.count == 1 else { throw CLIError.usage("Use: stationai task reconcile <task-id>") }
                return BridgeRequest(command: "task.reconcile", arguments: ["taskID": .string(tail[0])])
            case "title":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--prompt"])
                guard let taskID = tail.first, let prompt = flags["--prompt"]?.first else {
                    throw CLIError.usage("Use: stationai task title <task-id> --prompt <text>")
                }
                return BridgeRequest(command: "task.title.generate", arguments: ["taskID": .string(taskID), "prompt": .string(prompt)])
            case "rename":
                guard let id = tail.first else { throw CLIError.usage("Use: stationai task rename <task-id> --title <title>") }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--title"])
                let title = try requiredFlag("--title", flags: flags).first!
                return BridgeRequest(command: "task.rename", arguments: ["taskID": .string(id), "title": .string(title)])
            case "repository":
                guard tail.count >= 2 else { throw CLIError.usage("Use: stationai task repository add|add-batch|replace|edit|remove <task-id> ...") }
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
                case "add", "remove":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo"])
                    let repository = try requiredFlag("--repo", flags: flags).first!
                    return BridgeRequest(
                        command: "task.repository.\(tail[0])",
                        arguments: ["taskID": .string(id), "repositoryPath": .string(repository)]
                    )
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
                    throw CLIError.usage("Use: stationai task repository add|add-batch|replace|edit|remove <task-id> ...")
                }
            case "prompt":
                guard let id = tail.first else { throw CLIError.usage("Use: stationai task prompt <task-id> --text <prompt> [--status <status>] [--submitted true]") }
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
                    arguments["images"] = .array(try imagePaths.map { path in
                        let data = try Data(contentsOf: URL(fileURLWithPath: path))
                        let mime: String
                        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { mime = "image/png" }
                        else if data.starts(with: [255, 216, 255]) { mime = "image/jpeg" }
                        else { throw CLIError.usage("Images must be PNG or JPEG files.") }
                        return .string("data:\(mime);base64,\(data.base64EncodedString())")
                    })
                }
                if let status { arguments["status"] = .string(status) }
                if submitted { arguments["submitted"] = .boolean(true) }
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
                    throw CLIError.usage("Use: stationai task changes list <task-id>, mark-viewed <task-id> --repository <path> --path <relative-path>, or diff <task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>")
                }
                switch action {
                case "list":
                    guard tail.count == 2 else { throw CLIError.usage("Use: stationai task changes list <task-id>") }
                    return BridgeRequest(command: "task.changes.list", arguments: ["taskID": .string(tail[1])])
                case "diff":
                    guard tail.count >= 2 else {
                        throw CLIError.usage("Use: stationai task changes diff <task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>")
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
                    guard tail.count >= 2 else { throw CLIError.usage("Use: stationai task changes mark-viewed <task-id> --repository <path> --path <relative-path>") }
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repository", "--path"])
                    return BridgeRequest(command: "task.changes.mark-viewed", arguments: [
                        "taskID": .string(tail[1]),
                        "repository": .string(try requiredFlag("--repository", flags: flags).first!),
                        "path": .string(try requiredFlag("--path", flags: flags).first!),
                    ])
                default:
                    throw CLIError.usage("Unknown task changes operation '\(action)'.")
                }
            default:
                throw CLIError.usage("Unknown task operation '\(operation)'.")
            }
        case "workspace":
            if rest == ["repos", "list"] {
                return BridgeRequest(command: "workspace.repositories.list")
            }
            guard rest.first == "suggest" else {
                throw CLIError.usage("Use: stationai workspace repos list or workspace suggest --parent <path>")
            }
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
            case "set-default-provider":
                guard rest.count == 2 else { throw CLIError.usage("Use: stationai settings set-default-provider <codex|claude>") }
                return BridgeRequest(command: "settings.set-default-provider", arguments: ["provider": .string(rest[1])])
            case "set-parent":
                guard rest.count == 2 else { throw CLIError.usage("Use: stationai settings set-parent <path>") }
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
                guard tail.isEmpty || tail == ["--watch"] else { throw CLIError.usage("Use: stationai conversation runtime [--watch]") }
                return BridgeRequest(command: tail.isEmpty ? "conversation.runtime" : "conversation.runtime.subscribe")
            }
            guard let id = tail.first else { throw CLIError.usage("A task ID is required.") }
            switch operation {
            case "history": return BridgeRequest(command: "conversation.history", arguments: ["taskID": .string(id)])
            case "present-image":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--image", "--caption"])
                guard let path = flags["--image"]?.first, !path.isEmpty else {
                    throw CLIError.usage("Use: stationai conversation present-image <task-id> --image <path> [--caption <text>]")
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
                default: throw CLIError.usage("Use: stationai conversation models <task-id> [--cached]")
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
                throw CLIError.usage("Use: stationai conversation effort <task-id> [set <low|medium|high|xhigh>]")
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
                throw CLIError.usage("Use: stationai conversation model <task-id> [set <model-id>]")
            case "stop": return BridgeRequest(command: "conversation.stop", arguments: ["taskID": .string(id)])
            case "provider":
                switch Array(tail.dropFirst()) {
                case []: return BridgeRequest(command: "conversation.provider.get", arguments: ["taskID": .string(id)])
                case ["capabilities"]: return BridgeRequest(command: "conversation.provider.capabilities", arguments: ["taskID": .string(id)])
                case let values where values.count == 2 && values[0] == "set":
                    return BridgeRequest(command: "conversation.provider.set", arguments: ["taskID": .string(id), "provider": .string(values[1])])
                default:
                    throw CLIError.usage("Use: stationai conversation provider <task-id> [set <codex|claude>|capabilities]")
                }
            case "goal":
                guard tail.count >= 2 else { throw CLIError.usage("Use: stationai conversation goal <task-id> <get|set|pause|resume|clear> [--text <objective>]") }
                let action = tail[1]
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--text"])
                var arguments: [String: BridgeValue] = ["taskID": .string(id), "action": .string(action)]
                if let text = flags["--text"]?.first { arguments["objective"] = .string(text) }
                if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] { arguments["__codexHome"] = .string(codexHome) }
                return BridgeRequest(command: "conversation.goal", arguments: arguments)
            case "queue":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message"])
                return BridgeRequest(command: "conversation.queue", arguments: ["taskID": .string(id), "message": .string(flags["--message"]?.first ?? "")])
            case "subagent-history":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--activity"])
                guard let activityJSON = flags["--activity"]?.first,
                      let activity = try? JSONDecoder().decode(BridgeValue.self, from: Data(activityJSON.utf8)) else {
                    throw CLIError.usage("Use: stationai conversation subagent-history <task-id> --activity <activity-json>")
                }
                return BridgeRequest(command: "conversation.subagent_history", arguments: ["taskID": .string(id), "activity": activity])
            case "answered-async": return BridgeRequest(command: "conversation.answered_async", arguments: ["taskID": .string(id)])
            case "queue-list": return BridgeRequest(command: "conversation.queue.list", arguments: ["taskID": .string(id)])
            case "queue-retry":
                guard tail.count == 2 else { throw CLIError.usage("Use: stationai conversation queue-retry <task-id> <message-id>") }
                return BridgeRequest(command: "conversation.queue.retry", arguments: ["taskID": .string(id), "messageID": .string(tail[1])])
            case "queue-remove":
                guard tail.count == 2 else { throw CLIError.usage("Use: stationai conversation queue-remove <task-id> <message-id>") }
                return BridgeRequest(command: "conversation.queue.remove", arguments: ["taskID": .string(id), "messageID": .string(tail[1])])
            case "queue-steer":
                guard tail.count == 2 else { throw CLIError.usage("Use: stationai conversation queue-steer <task-id> <message-id>") }
                return BridgeRequest(command: "conversation.queue.steer", arguments: ["taskID": .string(id), "messageID": .string(tail[1])])
            case "steer":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--image"])
                let images = try (flags["--image"] ?? []).map { path -> BridgeValue in
                    let url = URL(fileURLWithPath: path)
                    let data = try Data(contentsOf: url)
                    guard data.count <= 10_000_000 else { throw CLIError.usage("Each image must be smaller than 10 MB.") }
                    let mime = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "image/jpeg" : "image/png"
                    return .string("data:\(mime);base64,\(data.base64EncodedString())")
                }
                return BridgeRequest(command: "conversation.steer", arguments: ["taskID": .string(id), "message": .string(flags["--message"]?.first ?? ""), "images": .array(images)])
            case "repair-user-input":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--from-task"])
                guard let sourceTaskID = flags["--from-task"]?.first else {
                    throw CLIError.usage("Use: stationai conversation repair-user-input <task-id> --from-task <source-task-id>")
                }
                return BridgeRequest(command: "conversation.repair_user_input", arguments: ["taskID": .string(id), "sourceTaskID": .string(sourceTaskID)])
            case "answer-async":
                guard tail.count >= 2 else { throw CLIError.usage("Use: stationai conversation answer-async <task-id> <item-id> --answer <text> [--answer <text>]...") }
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--answer"])
                return BridgeRequest(command: "conversation.answer_async", arguments: [
                    "taskID": .string(id), "itemID": .string(tail[1]),
                    "answers": .array((flags["--answer"] ?? []).map(BridgeValue.string))
                ])
            case "answer-user-input":
                guard tail.count >= 2 else { throw CLIError.usage("Use: stationai conversation answer-user-input <task-id> <request-id> --answer <question-id>=<answer> [--answer <question-id>=<answer>]...") }
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
            case "send":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message", "--mode", "--model", "--answer", "--image"])
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
                let images = try (flags["--image"] ?? []).map { path -> BridgeValue in
                    let url = URL(fileURLWithPath: path)
                    let data = try Data(contentsOf: url)
                    guard data.count <= 10_000_000 else { throw CLIError.usage("Each image must be smaller than 10 MB.") }
                    let mime = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? "image/jpeg" : "image/png"
                    return .string("data:\(mime);base64,\(data.base64EncodedString())")
                }
                var sendArguments: [String: BridgeValue] = [
                    "taskID": .string(id),
                    "message": .string(flags["--message"]?.first ?? ""),
                    "mode": .string(flags["--mode"]?.first ?? "default"),
                    "answers": .object(answers.mapValues { BridgeValue.array($0.map(BridgeValue.string)) }),
                    "images": .array(images)
                ]
                // Without --model, the task's provider chooses its default model.
                if let model = flags["--model"]?.first { sendArguments["model"] = .string(model) }
                return BridgeRequest(command: "conversation.send", arguments: sendArguments)
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
    StationAI CLI (talks to the bridge daemon bundled in StationAI.app, starting it on demand)

    Usage:
      stationai status
      stationai board list
      stationai archive search <query>
      stationai task list|get <task-id>
      stationai task create --title <title> --root <path> [--root <path>...] [--provider <codex|claude>]
      stationai task create --title <title> --repo <path> [--repo <path>...] [--branch <repo-path>=<name>] [--branch-from <repo-path>=<ref>] [--merge-target <repo-path>=<local-branch>]
      stationai task move <task-id> Done
      stationai task move <task-id> Done --allow-unmerged
      stationai task pr create <task-id>
      stationai task pr status <task-id>
      stationai task pr verify <task-id>
      stationai task progress publish <task-id> --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail <text>]
      stationai task progress custom <task-id> --label <label> [--detail <text>]
      stationai task progress clear <task-id>
      stationai task outcome <task-id> <completed|waiting-response>
      stationai task rename <task-id> --title <title>
      stationai task repository add <task-id> --repo <path>
      stationai task repository add-batch <task-id> --repo <path> [--repo <path>...]
      stationai task repository replace <task-id> --repo <path> [--repo <path>...]
      stationai task repository edit <task-id> --repo <path> --branch <name> --branch-from <ref> [--merge-target <ref>]
      stationai task repository remove <task-id> --repo <path>
      stationai task prompt <task-id> --text <prompt> [--status <status>] [--submitted true]
      stationai task roots get <task-id>
      stationai task roots set <task-id> --root <path> [--root <path>...]
      stationai task changes list <task-id>
      stationai task changes diff <task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>
      stationai task changes mark-viewed <task-id> --repository <path> --path <relative-path>
      stationai task delete <task-id>
      stationai task delete-check <task-id>
      stationai workspace suggest --parent <path>
      stationai workspace repos list
      stationai settings get|clear-parent|set-parent <path>|set-last-repositories --repo <path>...|set-appearance <dark|light>|set-default-provider <codex|claude>
      stationai conversation history <task-id>
      stationai conversation present-image <task-id> --image <path> [--caption <text>]
      stationai conversation queue <task-id> --message <text>
      stationai conversation queue-list <task-id>
      stationai conversation runtime [--watch]
      stationai conversation answered-async <task-id>
      stationai conversation subagent-history <task-id> --activity <activity-json>
      stationai task reconcile <task-id>
      stationai task title <task-id> --prompt <text>
      stationai conversation queue-retry <task-id> <message-id>
      stationai conversation queue-remove <task-id> <message-id>
      stationai conversation queue-steer <task-id> <message-id>
      stationai conversation steer <task-id> --message <text> [--image <path>]...
      stationai conversation answer-async <task-id> <item-id> --answer <text> [--answer <text>]...
      stationai conversation repair-user-input <task-id> --from-task <source-task-id>
      stationai conversation answer-user-input <task-id> <request-id> --answer <question-id>=<answer> [--answer <question-id>=<answer>]...
      stationai conversation models <task-id>
      stationai conversation effort <task-id> [set <low|medium|high|xhigh>]
      stationai conversation model <task-id> [set <model-id>]
      stationai conversation models <task-id> --cached
      stationai conversation stop <task-id>
      stationai conversation provider <task-id> [set <codex|claude>|capabilities]
      stationai conversation goal <task-id> <get|set|pause|resume|clear> [--text <objective>]
      stationai conversation send <task-id> --message <text> [--image <path>]... [--mode <default|plan>] [--model <model-id>] [--answer <question-id>=<answer>...]

    Results are JSON. Conversation send emits JSON event lines followed by a final response.
    Conversation commands use the task's provider; tasks without one use Codex.
    Conversation models --cached reads the last saved list without contacting the provider.
    """
}

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let message) = self { message } else { "Invalid CLI arguments." } }
}
