import Darwin
import Foundation

extension PlayhouseCLI {
    /// `task pr autopilot`'s options, or nil when one is unknown or `--confirm-with` lacks its plugin id.
    static func autopilotOptions(_ options: ArraySlice<String>) -> (merge: Bool, resetAttempts: Bool, confirmWith: String?)? {
        var result: (merge: Bool, resetAttempts: Bool, confirmWith: String?) = (false, false, nil)
        var iterator = options.makeIterator()
        while let option = iterator.next() {
            switch option {
            case "--merge": result.merge = true
            case "--reset-attempts": result.resetAttempts = true
            case "--confirm-with":
                guard let pluginID = iterator.next(), !pluginID.hasPrefix("--") else { return nil }
                result.confirmWith = pluginID
            default: return nil
            }
        }
        return result
    }

    /// The worktree a repository command names: `--worktree <path>`, `--repo <path>` (one
    /// worktree of it on the task), and `--worktree-branch` for a worktree not created yet.
    static func worktreeArguments(_ flags: [String: [String]], usage: String) throws -> [String: BridgeValue] {
        var arguments: [String: BridgeValue] = [:]
        if let repository = flags["--repo"]?.last { arguments["repositoryPath"] = .string(repository) }
        if let worktree = flags["--worktree"]?.last { arguments["worktreePath"] = .string(worktree) }
        if let branch = flags["--worktree-branch"]?.last { arguments["worktreeBranch"] = .string(branch) }
        guard arguments["repositoryPath"] != nil || arguments["worktreePath"] != nil else { throw CLIError.usage(usage) }
        return arguments
    }

    /// Commands this CLI answers itself, without the daemon: its own version, the
    /// installer (which stops the daemon), and the daemon's lifecycle, which must
    /// not start a daemon just to ask about it.
    static func runLocally(_ args: [String]) throws -> BridgeResponse? {
        let group = args.first ?? ""
        let operation = args.dropFirst().first ?? ""
        let tail = Array(args.dropFirst(2))
        switch (group, operation) {
        case ("version", _):
            guard args.count == 1 else { throw CLIError.usage("Use: playhouse version") }
            let request = BridgeRequest(command: "version")
            let info = Bundle.main.infoDictionary ?? [:]
            return .success(request, result: .object([
                "version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
                "build": .string(info["CFBundleVersion"] as? String ?? ""),
                "commit": .string(info["PlayhouseGitCommit"] as? String ?? ""),
                "channel": .string(PlayhouseRelease.channel(of: info)),
                "bundleIdentifier": .string(Bundle.main.bundleIdentifier ?? ""),
                "bundlePath": .string(Bundle.main.bundleURL.path)
            ]))
        case ("update", "apply"):
            let usage = "Use: playhouse update apply --staged <app> --target <app> --state-dir <path> [--service-name <name>] [--socket-path <path>] [--relaunch-env <NAME=value>...]"
            let flags = try parseFlags(tail, valueFlags: ["--staged", "--target", "--state-dir", "--service-name", "--socket-path", "--relaunch-env"])
            guard let staged = flags["--staged"]?.first, let target = flags["--target"]?.first, let stateDirectory = flags["--state-dir"]?.first else {
                throw CLIError.usage(usage)
            }
            var options = ReleaseInstaller.Options(
                staged: URL(fileURLWithPath: staged, isDirectory: true),
                target: URL(fileURLWithPath: target, isDirectory: true),
                stateDirectory: URL(fileURLWithPath: stateDirectory, isDirectory: true)
            )
            options.serviceName = flags["--service-name"]?.first
            options.socketPath = flags["--socket-path"]?.first
            for assignment in flags["--relaunch-env"] ?? [] {
                guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else { throw CLIError.usage(usage) }
                options.relaunchEnvironment[String(assignment[..<separator])] = String(assignment[assignment.index(after: separator)...])
            }
            let request = BridgeRequest(command: "update.apply")
            let record = ReleaseInstaller(options: options).run()
            let result = (try? BridgeValue.encoding(record)) ?? .null
            return record.status == "installed"
                ? .success(request, result: result)
                : .failure(request, code: record.status == "rolledBack" ? "update_rolled_back" : "update_failed", message: record.message ?? record.status)
        case ("update", "verify-bundle"):
            let flags = try parseFlags(tail, valueFlags: ["--bundle", "--replacing", "--version"])
            guard let bundle = flags["--bundle"]?.first else {
                throw CLIError.usage("Use: playhouse update verify-bundle --bundle <app> [--replacing <installed app>] [--version <x.y.z>]")
            }
            let request = BridgeRequest(command: "update.verify-bundle")
            let candidate = URL(fileURLWithPath: bundle, isDirectory: true)
            do {
                let summary = try ReleaseBundleVerifier.verify(
                    candidate: candidate,
                    replacing: flags["--replacing"]?.first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? candidate,
                    expectedVersion: flags["--version"]?.first
                )
                return .success(request, result: .object([
                    "bundleIdentifier": .string(summary.bundleIdentifier),
                    "version": .string(summary.version),
                    "build": .string(summary.build),
                    "certificateSHA256": (try ReleaseBundleVerifier.leafCertificate(ofValidBundle: candidate)).map(BridgeValue.string) ?? .null
                ]))
            } catch let error as ReleaseVerificationError {
                return .failure(request, code: error.code, message: error.message)
            }
        case ("daemon", "info"), ("daemon", "shutdown"):
            guard tail.isEmpty else { throw CLIError.usage("Use: playhouse daemon info|shutdown") }
            let request = BridgeRequest(command: "daemon.\(operation)")
            let (_, socketPath) = BridgeClient.endpoint()
            guard let connection = try? BridgeSocketConnection.connect(to: socketPath) else {
                return .success(request, result: .object(["running": .boolean(false)]))
            }
            defer { connection.close() }
            let response = try BridgeDaemonLauncher.request(request, over: connection)
            guard response.ok, var result = response.result?.object else { return response }
            if operation == "shutdown", let processID = result["processID"]?.int {
                BridgeDaemonLauncher.waitForExit(pid_t(processID), timeout: BridgeDaemonLauncher.daemonExitTimeout)
            }
            result["running"] = .boolean(operation == "info")
            return .success(request, result: .object(result))
        case ("daemon", _):
            throw CLIError.usage("Use: playhouse daemon info|shutdown")
        default:
            return nil
        }
    }

    /// The bridge request for `args`. Only a command `CLICommandCatalog` declares gets here,
    /// so every command this accepts has a help entry; a declared command this switch doesn't
    /// handle throws `CLIError.unknownCommand`, which the CLI's unit checks look for.
    static func parse(_ args: [String]) throws -> BridgeRequest {
        guard let group = args.first, CLICommandCatalog.command(matching: args) != nil else { throw CLIError.unknownCommand(args) }
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
                let prUsage = "Use: playhouse task pr create|conflicts|status|verify|resolve|sync|autopilot <task-id> [resolve-and-push|resolve-only|keep], playhouse task pr create <task-id> [--if-needed] [--title <title>] [--body <text>], playhouse task pr link <task-id> (--worktree <path>|--repo <path>) --url <pr-url>, playhouse task pr status <task-id> [--review-threads] [--shared], or playhouse task pr autopilot <task-id> [--merge] [--reset-attempts] [--confirm-with <plugin-id>]"
                guard tail.count >= 2 else {
                    throw CLIError.usage("Use: playhouse task pr create|conflicts|status|verify|resolve|sync|autopilot <task-id> [action]")
                }
                switch tail[0] {
                // One pass of the `pull-request-mode` plugin's Green mode, or Merge with `--merge`.
                // `--confirm-with <plugin-id>` asks that plugin's service again before a merge or fix turn.
                case "autopilot":
                    guard let options = Self.autopilotOptions(tail.dropFirst(2)) else { throw CLIError.usage(prUsage) }
                    var arguments: [String: BridgeValue] = [
                        "taskID": .string(tail[1]),
                        "merge": .boolean(options.merge),
                        "resetAttempts": .boolean(options.resetAttempts)
                    ]
                    if let confirmWith = options.confirmWith { arguments["confirmWith"] = .string(confirmWith) }
                    return BridgeRequest(command: "task.pr.autopilot", arguments: arguments)
                case "create":
                    let rest = Array(tail.dropFirst(2))
                    let flags = try parseFlags(rest.filter { $0 != "--if-needed" }, valueFlags: ["--title", "--body"])
                    var arguments: [String: BridgeValue] = ["taskID": .string(tail[1]), "ifNeeded": .boolean(rest.contains("--if-needed"))]
                    if let title = flags["--title"]?.last { arguments["title"] = .string(title) }
                    if let body = flags["--body"]?.last { arguments["body"] = .string(body) }
                    return BridgeRequest(command: "task.pr.create", arguments: arguments)
                case "link":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo", "--worktree", "--url"])
                    var arguments = try Self.worktreeArguments(flags, usage: "Use: playhouse task pr link <task-id> (--worktree <path>|--repo <path>) --url <pr-url>")
                    arguments["taskID"] = .string(tail[1])
                    arguments["url"] = .string(try requiredFlag("--url", flags: flags).first!)
                    return BridgeRequest(command: "task.pr.link", arguments: arguments)
                case "conflicts":
                    guard tail.count == 2 else { throw CLIError.usage(prUsage) }
                    return BridgeRequest(command: "task.pr.conflicts", arguments: ["taskID": .string(tail[1])])
                case "status":
                    guard Set(tail.dropFirst(2)).isSubset(of: ["--review-threads", "--shared"]) else { throw CLIError.usage(prUsage) }
                    return BridgeRequest(command: "task.pr.status", arguments: [
                        "taskID": .string(tail[1]),
                        "reviewThreads": .boolean(tail.contains("--review-threads")),
                        "shared": .boolean(tail.contains("--shared")),
                        // Every recorded pull request, closed and retired ones included.
                        "all": .boolean(true)
                    ])
                case "verify":
                    guard tail.count == 2 else { throw CLIError.usage(prUsage) }
                    return BridgeRequest(command: "task.pr.verify", arguments: ["taskID": .string(tail[1])])
                case "resolve":
                    guard tail.count == 3 else { throw CLIError.usage(prUsage) }
                    return BridgeRequest(command: "task.pr.resolve", arguments: ["taskID": .string(tail[1]), "action": .string(tail[2])])
                case "sync":
                    guard tail.count == 2 else { throw CLIError.usage(prUsage) }
                    return BridgeRequest(command: "task.pr.sync", arguments: ["taskID": .string(tail[1])])
                default:
                    throw CLIError.unknownCommand(args)
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
                    throw CLIError.unknownCommand(args)
                }
            case "outcome":
                let usage = "Use: playhouse task outcome <task-id> <completed|waiting-response|blocked> [--reason <text>] (blocked requires --reason)"
                guard tail.count == 2 || tail.count == 4 else { throw CLIError.usage(usage) }
                let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--reason"])
                var requestArguments: [String: BridgeValue] = [
                    "taskID": .string(tail[0]), "outcome": .string(tail[1])
                ]
                if let reason = flags["--reason"]?.first { requestArguments["reason"] = .string(reason) }
                return BridgeRequest(command: "task.outcome", arguments: requestArguments)
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
                guard tail.count >= 2 else { throw CLIError.usage("Use: playhouse task repository add|add-batch|add-worktree|replace|edit|remove|renew|recent <task-id> ...") }
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
                case "add":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo"])
                    let repository = try requiredFlag("--repo", flags: flags).first!
                    return BridgeRequest(
                        command: "task.repository.add",
                        arguments: ["taskID": .string(id), "repositoryPath": .string(repository)]
                    )
                case "add-worktree":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo", "--branch", "--branch-from"])
                    var arguments: [String: BridgeValue] = [
                        "taskID": .string(id), "repositoryPath": .string(try requiredFlag("--repo", flags: flags).first!)
                    ]
                    if let branch = flags["--branch"]?.last { arguments["branch"] = .string(branch) }
                    if let branchFrom = flags["--branch-from"]?.last { arguments["branchFrom"] = .string(branchFrom) }
                    return BridgeRequest(command: "task.repository.add-worktree", arguments: arguments)
                case "remove", "renew", "resolve":
                    let flags = try parseFlags(Array(tail.dropFirst(2)), valueFlags: ["--repo", "--worktree", "--worktree-branch"])
                    var arguments = try Self.worktreeArguments(flags, usage: "Use: playhouse task repository \(tail[0]) <task-id> (--repo <path>|--worktree <path>)")
                    arguments["taskID"] = .string(id)
                    return BridgeRequest(command: "task.repository.\(tail[0])", arguments: arguments)
                case "recent":
                    guard tail.count == 2 else { throw CLIError.usage("Use: playhouse task repository recent <task-id>") }
                    return BridgeRequest(command: "task.repository.recent", arguments: ["taskID": .string(id)])
                case "edit":
                    let flags = try parseFlags(
                        Array(tail.dropFirst(2)),
                        valueFlags: ["--repo", "--worktree", "--worktree-branch", "--branch", "--branch-from", "--merge-target"]
                    )
                    var arguments = try Self.worktreeArguments(flags, usage: "Use: playhouse task repository edit <task-id> (--repo <path>|--worktree <path>) --branch <name> --branch-from <ref> [--merge-target <ref>]")
                    let branch = try requiredFlag("--branch", flags: flags).first!
                    let branchFrom = try requiredFlag("--branch-from", flags: flags).first!
                    let mergeTarget = flags["--merge-target"]?.last ?? ""
                    arguments["taskID"] = .string(id)
                    arguments["branch"] = .string(branch)
                    arguments["branchFrom"] = .string(branchFrom)
                    arguments["mergeTarget"] = .string(mergeTarget)
                    return BridgeRequest(command: "task.repository.edit", arguments: arguments)
                default:
                    throw CLIError.unknownCommand(args)
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
                guard action == "set" else { throw CLIError.unknownCommand(args) }
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
                    throw CLIError.unknownCommand(args)
                }
            default:
                throw CLIError.unknownCommand(args)
            }
        case "chat":
            if rest == ["open"] {
                return BridgeRequest(command: "chat.open")
            }
            if rest == ["status"] {
                return BridgeRequest(command: "chat.status")
            }
            if rest.first == "bubble", rest.count >= 2 {
                let tail = Array(rest.dropFirst(2))
                switch rest[1] {
                case "send":
                    let flags = try parseFlags(tail, valueFlags: ["--message", "--image"])
                    return BridgeRequest(command: "chat.bubble.send", arguments: [
                        "message": .string(flags["--message"]?.first ?? ""),
                        "images": .array(try imageDataURLs(flags["--image"] ?? [])),
                    ])
                case "list" where tail.isEmpty:
                    return BridgeRequest(command: "chat.bubble.list")
                case "close":
                    let id = try firstPositional(tail)
                    return BridgeRequest(command: "chat.bubble.close", arguments: ["bubbleID": .string(id)])
                default:
                    throw CLIError.unknownCommand(args)
                }
            }
            guard rest.first == "page", rest.count >= 2 else { throw CLIError.unknownCommand(args) }
            let tail = Array(rest.dropFirst(2))
            switch rest[1] {
            case "list":
                let flags = try parseFlags(tail, valueFlags: ["--limit", "--title"])
                var arguments: [String: BridgeValue] = [:]
                if let limit = flags["--limit"]?.first { arguments["limit"] = .string(limit) }
                if let title = flags["--title"]?.first { arguments["title"] = .string(title) }
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
                throw CLIError.unknownCommand(args)
            }
        case "workspace":
            if rest == ["repos", "list"] {
                return BridgeRequest(command: "workspace.repositories.list")
            }
            guard rest.first == "suggest" else { throw CLIError.unknownCommand(args) }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--parent"])
            return BridgeRequest(command: "workspace.suggest", arguments: [
                "parent": .string(try requiredFlag("--parent", flags: flags).first!)
            ])
        case "plugin":
            let renderUsage = "Use: playhouse plugin render (--file <plugin.js> | --page <catalog-page> | --plugin <plugin-id> [--task <task-id>]) [--props <json>] [--event <testID>:<event>[:<value>] | @<app-event>[:<json>] | +<seconds>...] [--advance <seconds>]"
            let usage = "Use: playhouse plugin mode [--on|--off] | list | refresh | sessions | edit --id <plugin-id> | delete --id <plugin-id> | enable --id <plugin-id> | disable --id <plugin-id> | state --id <plugin-id> [--key <key> --value <json>] | event <name> [--payload <json>] | author --placement <\(pluginPlacements)> [--provider <codex|claude>] [--name <name> --presentation <popover|modal|sidebar|page|inline>] | render …"
            switch rest.first {
            case "mode":
                let options = Array(rest.dropFirst())
                switch options {
                case []: return BridgeRequest(command: "plugin.mode")
                case ["--on"]: return BridgeRequest(command: "plugin.mode", arguments: ["enabled": .boolean(true)])
                case ["--off"]: return BridgeRequest(command: "plugin.mode", arguments: ["enabled": .boolean(false)])
                default: throw CLIError.usage("Use: playhouse plugin mode [--on|--off]")
                }
            case "list", "refresh", "sessions":
                guard rest.count == 1 else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "plugin.\(rest[0])")
            case "delete", "enable", "disable", "edit", "save", "discard", "versions":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--id"])
                return BridgeRequest(command: "plugin.\(rest[0])", arguments: ["pluginID": .string(try requiredFlag("--id", flags: flags).first!)])
            case "state":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--id", "--key", "--value"])
                let id = BridgeValue.string(try requiredFlag("--id", flags: flags).first!)
                switch (flags["--key"]?.first, flags["--value"]?.first) {
                case (nil, nil):
                    return BridgeRequest(command: "plugin.state.get", arguments: ["pluginID": id])
                case (let key?, let json?):
                    guard let value = try? JSONDecoder().decode(BridgeValue.self, from: Data(json.utf8)) else {
                        throw CLIError.usage("--value must be JSON, such as true, 3, \"text\" or null (which removes the key).")
                    }
                    return BridgeRequest(command: "plugin.state.set", arguments: ["pluginID": id, "key": .string(key), "value": value])
                default:
                    throw CLIError.usage("Use: playhouse plugin state --id <plugin-id> [--key <key> --value <json>]")
                }
            case "event":
                guard rest.count >= 2, !rest[1].hasPrefix("--") else { throw CLIError.usage("Use: playhouse plugin event <name> [--payload <json>]") }
                let flags = try parseFlags(Array(rest.dropFirst(2)), valueFlags: ["--payload"])
                var payload = BridgeValue.object([:])
                if let json = flags["--payload"]?.first {
                    guard let value = try? JSONDecoder().decode(BridgeValue.self, from: Data(json.utf8)), value.object != nil else {
                        throw CLIError.usage("--payload must be a JSON object.")
                    }
                    payload = value
                }
                return BridgeRequest(command: "plugin.event", arguments: ["name": .string(rest[1]), "payload": payload])
            case "restore":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--id", "--version"])
                guard let version = Int(try requiredFlag("--version", flags: flags).first!) else { throw CLIError.usage("Version must be an integer.") }
                return BridgeRequest(command: "plugin.restore", arguments: ["pluginID": .string(try requiredFlag("--id", flags: flags).first!), "version": .integer(version)])
            case "author":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--placement", "--provider", "--name", "--presentation"])
                var arguments: [String: BridgeValue] = ["placement": .string(try requiredFlag("--placement", flags: flags).first!)]
                arguments["provider"] = flags["--provider"]?.first.map(BridgeValue.string)
                arguments["name"] = flags["--name"]?.first.map(BridgeValue.string)
                arguments["presentation"] = flags["--presentation"]?.first.map(BridgeValue.string)
                return BridgeRequest(command: "plugin.author", arguments: arguments)
            case "services":
                guard rest.count == 1 else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "plugin.services")
            case "service":
                let serviceUsage = "Use: playhouse plugin service (--file <index.js> | --plugin <plugin-id>) --event <name>[:<json payload>]... [--props <json>] [--mock <command>[:<tool>]=<json>...]"
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--file", "--plugin", "--props", "--event", "--mock"])
                guard (flags["--file"] == nil) != (flags["--plugin"] == nil), let events = flags["--event"], !events.isEmpty else { throw CLIError.usage(serviceUsage) }
                var arguments: [String: BridgeValue] = ["events": .array(events.map(BridgeValue.string))]
                arguments["file"] = flags["--file"]?.first.map { path in
                    .string(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path)
                }
                arguments["pluginID"] = flags["--plugin"]?.first.map(BridgeValue.string)
                arguments["props"] = flags["--props"]?.first.map(BridgeValue.string)
                if let mocks = try parseMocks(flags["--mock"]) { arguments["mocks"] = mocks }
                return BridgeRequest(command: "plugin.service", arguments: arguments)
            case "render":
                break
            default:
                throw CLIError.unknownCommand(args)
            }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--file", "--page", "--plugin", "--task", "--props", "--event", "--advance", "--mock"])
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
            if let mocks = try parseMocks(flags["--mock"]) { arguments["mocks"] = mocks }
            return BridgeRequest(command: "plugin.render", arguments: arguments)
        case "agent":
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--plugin", "--prompt", "--model", "--allowed-tool", "--json-schema", "--context", "--cwd", "--run", "--provider"])
            func json(_ flag: String) throws -> BridgeValue? {
                guard let text = flags[flag]?.first else { return nil }
                guard let value = try? JSONDecoder().decode(BridgeValue.self, from: Data(text.utf8)) else { throw CLIError.usage("\(flag) must be JSON.") }
                return value
            }
            switch rest.first {
            case "run":
                var arguments: [String: BridgeValue] = [
                    "pluginID": .string(try requiredFlag("--plugin", flags: flags).first!),
                    "prompt": .string(try requiredFlag("--prompt", flags: flags).first!),
                ]
                arguments["model"] = flags["--model"]?.first.map(BridgeValue.string)
                arguments["provider"] = flags["--provider"]?.first.map(BridgeValue.string)
                arguments["allowedTools"] = flags["--allowed-tool"].map { .array($0.map(BridgeValue.string)) }
                arguments["jsonSchema"] = try json("--json-schema")
                arguments["context"] = try json("--context")
                arguments["cwd"] = flags["--cwd"]?.first.map { path in
                    .string(URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path)
                }
                return BridgeRequest(command: "agent.run", arguments: arguments)
            case "cancel":
                return BridgeRequest(command: "agent.cancel", arguments: [
                    "pluginID": .string(try requiredFlag("--plugin", flags: flags).first!),
                    "runID": .string(try requiredFlag("--run", flags: flags).first!),
                ])
            case "runs":
                return BridgeRequest(command: "agent.runs", arguments: flags["--plugin"]?.first.map { ["pluginID": .string($0)] } ?? [:])
            default:
                throw CLIError.unknownCommand(args)
            }
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
                throw CLIError.unknownCommand(args)
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
                throw CLIError.unknownCommand(args)
            }
        case "mcp":
            guard let operation = rest.first else { throw CLIError.usage("Missing mcp operation.") }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: [
                "--task", "--server", "--scope", "--name", "--root", "--command", "--arg", "--env", "--url", "--header", "--config-json", "--provider",
                "--tool", "--arguments", "--plugin", "--timeout",
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
            case "call":
                var call: [String: BridgeValue] = ["tool": .string(try requiredFlag("--tool", flags: flags).first!)]
                if let json = flags["--arguments"]?.first {
                    guard let value = try? JSONDecoder().decode(BridgeValue.self, from: Data(json.utf8)), value.object != nil else {
                        throw CLIError.usage("--arguments must be a JSON object.")
                    }
                    call["arguments"] = value
                }
                call["pluginID"] = flags["--plugin"]?.first.map(BridgeValue.string)
                call["provider"] = flags["--provider"]?.first.map(BridgeValue.string)
                if let timeout = flags["--timeout"]?.first {
                    guard let seconds = Double(timeout) else { throw CLIError.usage("--timeout is a number of seconds.") }
                    call["timeout"] = .decimal(seconds)
                }
                return BridgeRequest(command: "mcp.call", arguments: call)
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
                throw CLIError.unknownCommand(args)
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
                throw CLIError.unknownCommand(args)
            }
        case "mentions":
            guard rest.first == "list" else { throw CLIError.usage("Use: playhouse mentions list --task <task-id> [--query <text>]") }
            let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--task", "--query"])
            var arguments: [String: BridgeValue] = ["taskID": .string(try requiredFlag("--task", flags: flags).first!)]
            if let query = flags["--query"]?.first { arguments["query"] = .string(query) }
            return BridgeRequest(command: "mentions.list", arguments: arguments)
        case "slash-commands":
            let use = "Use: playhouse slash-commands list --task <task-id> [--query <text>] [--complete] [--draft <text>] | run --task <task-id> --command <name> [--item <item-id> [--button <button-id>]] [--confirm] [--draft <text>]"
            guard let operation = rest.first, ["list", "run"].contains(operation) else { throw CLIError.usage(use) }
            let switches: Set<String> = ["--status", "--complete", "--confirm"]
            let options = Array(rest.dropFirst())
            let flags = try parseFlags(options.filter { !switches.contains($0) }, valueFlags: ["--task", "--query", "--command", "--item", "--button", "--draft"])
            var arguments: [String: BridgeValue] = ["taskID": .string(try requiredFlag("--task", flags: flags).first!)]
            if let draft = flags["--draft"]?.first { arguments["draft"] = .string(draft) }
            if operation == "list" {
                if let query = flags["--query"]?.first { arguments["query"] = .string(query) }
                // `--status` is the older name of `--complete`.
                if options.contains("--complete") || options.contains("--status") { arguments["complete"] = .boolean(true) }
                return BridgeRequest(command: "slash.list", arguments: arguments)
            }
            guard let command = flags["--command"]?.first else { throw CLIError.usage(use) }
            arguments["command"] = .string(command)
            if let item = flags["--item"]?.first { arguments["item"] = .string(item) }
            if let button = flags["--button"]?.first { arguments["button"] = .string(button) }
            if options.contains("--confirm") { arguments["confirm"] = .boolean(true) }
            return BridgeRequest(command: "slash.run", arguments: arguments)
        case "schedule":
            guard let operation = rest.first else {
                throw CLIError.usage("Use: playhouse schedule list|set|clear|pause|resume|run-now|tick ...")
            }
            let tail = Array(rest.dropFirst())
            switch operation {
            case "list":
                return BridgeRequest(command: "schedule.list")
            case "set":
                let usage = "Use: playhouse schedule set <task-id> [--prompt <text>] (--once <ISO8601> | --repeat <hourly|daily|weekdays|weekly> [--time HH:MM] [--minute MM] [--weekday mon]) [--title <title>] [--image <path>...] [--mode default|plan] [--model <id>]"
                guard let id = tail.first, !id.hasPrefix("--") else { throw CLIError.usage(usage) }
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: [
                    "--prompt", "--once", "--repeat", "--time", "--minute", "--weekday", "--title", "--image", "--mode", "--model"
                ])
                guard (flags["--once"] == nil) != (flags["--repeat"] == nil) else { throw CLIError.usage(usage) }
                // Without --prompt the task is only rescheduled and keeps its saved payload, so
                // the payload's own flags would have nothing to change.
                if flags["--prompt"] == nil, ["--image", "--mode", "--model"].contains(where: { flags[$0] != nil }) {
                    throw CLIError.usage("--image, --mode and --model need --prompt; without it, schedule set only moves an existing schedule.")
                }
                var arguments: [String: BridgeValue] = [
                    "taskID": .string(id),
                    "kind": .string(flags["--once"] != nil ? "once" : "recurring"),
                    "images": .array(try (flags["--image"] ?? []).map(draftImageDataURL))
                ]
                if let prompt = flags["--prompt"]?.first { arguments["prompt"] = .string(prompt) }
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
                throw CLIError.unknownCommand(args)
            }
        case "update":
            let usage = "Use: playhouse update status|check [--automatic true]|download|cancel|install [--when-idle true]|set-auto-check <on|off>|launched|dismiss-notice"
            guard let operation = rest.first else { throw CLIError.usage(usage) }
            let tail = Array(rest.dropFirst())
            switch operation {
            case "status", "download", "cancel", "launched", "dismiss-notice":
                guard tail.isEmpty else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "update.\(operation)")
            case "check":
                let flags = try parseFlags(tail, valueFlags: ["--automatic"])
                return BridgeRequest(command: "update.check", arguments: ["automatic": .boolean(flags["--automatic"]?.first == "true")])
            case "install":
                let flags = try parseFlags(tail, valueFlags: ["--when-idle"])
                return BridgeRequest(command: "update.install", arguments: ["whenIdle": .boolean(flags["--when-idle"]?.first == "true")])
            case "set-auto-check":
                guard tail.count == 1, tail[0] == "on" || tail[0] == "off" else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "update.set-auto-check", arguments: ["enabled": .boolean(tail[0] == "on")])
            default:
                throw CLIError.unknownCommand(args)
            }
        case "providers":
            let usage = "Use: playhouse providers list|install <codex|claude>"
            switch rest.first {
            case "list":
                guard rest.count == 1 else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "providers.list")
            case "install":
                guard rest.count == 2 else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "providers.install", arguments: ["provider": .string(rest[1])])
            case nil: throw CLIError.usage(usage)
            default: throw CLIError.unknownCommand(args)
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
            case "set-status-sounds":
                guard rest.count == 2, rest[1] == "on" || rest[1] == "off" else {
                    throw CLIError.usage("Use: playhouse settings set-status-sounds <on|off>")
                }
                return BridgeRequest(command: "settings.set-status-sounds", arguments: ["enabled": .boolean(rest[1] == "on")])
            case "set-auto-compaction":
                let usage = "Use: playhouse settings set-auto-compaction [--enabled <true|false>] [--idle-minutes <minutes>] [--minimum <tokens>]"
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--enabled", "--idle-minutes", "--minimum"])
                var arguments: [String: BridgeValue] = [:]
                if let enabled = flags["--enabled"]?.last {
                    guard enabled == "true" || enabled == "false" else { throw CLIError.usage(usage) }
                    arguments["enabled"] = .boolean(enabled == "true")
                }
                for (flag, key) in [("--idle-minutes", "idleMinutes"), ("--minimum", "minimumTokens")] {
                    guard let text = flags[flag]?.last else { continue }
                    guard let value = Int(text) else { throw CLIError.usage(usage) }
                    arguments[key] = .integer(value)
                }
                guard !arguments.isEmpty else { throw CLIError.usage(usage) }
                return BridgeRequest(command: "settings.set-auto-compaction", arguments: arguments)
            case "set-parent":
                guard rest.count == 2 else { throw CLIError.usage("Use: playhouse settings set-parent <path>") }
                return BridgeRequest(command: "settings.set-parent", arguments: ["path": .string(rest[1])])
            case "set-last-repositories":
                let flags = try parseFlags(Array(rest.dropFirst()), valueFlags: ["--repo"])
                return BridgeRequest(command: "settings.set-last-repositories", arguments: [
                    "repositories": .array((flags["--repo"] ?? []).map(BridgeValue.string))
                ])
            default: throw CLIError.unknownCommand(args)
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
                let options = Array(tail.dropFirst())
                let flags = try parseFlags(options.filter { $0 != "--defer-images" && $0 != "--include-task" }, valueFlags: ["--limit", "--before", "--after", "--page"])
                var arguments: [String: BridgeValue] = ["taskID": .string(id)]
                if let limit = flags["--limit"]?.first { arguments["limit"] = .string(limit) }
                if let before = flags["--before"]?.first { arguments["before"] = .string(before) }
                if let after = flags["--after"]?.first { arguments["after"] = .string(after) }
                if let page = flags["--page"]?.first { arguments["page"] = .string(page) }
                if options.contains("--defer-images") { arguments["deferImages"] = .boolean(true) }
                if options.contains("--include-task") { arguments["includeTask"] = .boolean(true) }
                return BridgeRequest(command: "conversation.history", arguments: arguments)
            case "images":
                let flags = try parseFlags(Array(tail.dropFirst()), valueFlags: ["--message"])
                guard let messages = flags["--message"], !messages.isEmpty else {
                    throw CLIError.usage("Use: playhouse conversation images <task-id> --message <message-id> [--message <message-id>]...")
                }
                return BridgeRequest(command: "conversation.images", arguments: [
                    "taskID": .string(id), "messages": .array(messages.map(BridgeValue.string))
                ])
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
            case "context-mode":
                let modeArguments = Array(tail.dropFirst())
                if modeArguments.isEmpty {
                    return BridgeRequest(command: "conversation.context-mode.get", arguments: ["taskID": .string(id)])
                }
                if modeArguments.count == 2, modeArguments[0] == "set" {
                    return BridgeRequest(command: "conversation.context-mode.set", arguments: [
                        "taskID": .string(id), "mode": .string(modeArguments[1]),
                    ])
                }
                throw CLIError.usage("Use: playhouse conversation context-mode <task-id> [set <full|optimized>]")
            case "outline":
                guard tail.count == 1 else { throw CLIError.usage("Use: playhouse conversation outline <task-id>") }
                return BridgeRequest(command: "conversation.outline", arguments: ["taskID": .string(id)])
            case "read":
                let options = Array(tail.dropFirst())
                let flags = try parseFlags(options.filter { $0 != "--include-tools" }, valueFlags: ["--at", "--from", "--to", "--kinds"])
                func list(_ flag: String) -> [String] {
                    (flags[flag] ?? []).flatMap { $0.split(separator: ",") }
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                var arguments: [String: BridgeValue] = ["taskID": .string(id)]
                let positions = list("--at")
                if !positions.isEmpty { arguments["at"] = .array(positions.map(BridgeValue.string)) }
                if let from = flags["--from"]?.first { arguments["from"] = .string(from) }
                if let to = flags["--to"]?.first { arguments["to"] = .string(to) }
                let kinds = list("--kinds")
                if !kinds.isEmpty { arguments["kinds"] = .array(kinds.map(BridgeValue.string)) }
                if options.contains("--include-tools") { arguments["includeTools"] = .boolean(true) }
                return BridgeRequest(command: "conversation.read", arguments: arguments)
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
                case let values where (values.count == 2 || (values.count == 3 && values[2] == "--keep-default")) && values[0] == "set":
                    return BridgeRequest(command: "conversation.provider.set", arguments: [
                        "taskID": .string(id), "provider": .string(values[1]), "remembersDefault": .boolean(values.count == 2),
                    ])
                default:
                    throw CLIError.usage("Use: playhouse conversation provider <task-id> [set <codex|claude> [--keep-default]|capabilities]")
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
                let options = Array(tail.dropFirst())
                let flags = try parseFlags(
                    options.filter { $0 != "--defer-images" && $0 != "--new-page" },
                    valueFlags: ["--message", "--mode", "--model", "--answer", "--image", "--context-page"]
                )
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
                if options.contains("--defer-images") { sendArguments["deferImages"] = .boolean(true) }
                // Standalone chat only: the turn starts a new page without the last page's context.
                if options.contains("--new-page") { sendArguments["newPage"] = .boolean(true) }
                return BridgeRequest(command: "conversation.send", arguments: sendArguments)
            default: throw CLIError.unknownCommand(args)
            }
        default:
            throw CLIError.unknownCommand(args)
        }
    }
}
