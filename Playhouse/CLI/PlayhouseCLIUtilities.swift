import Darwin
import Foundation

extension PlayhouseCLI {
    /// Conversation image flags as data URLs; the bridge validates the image bytes.
    static func imageDataURLs(_ paths: [String]) throws -> [BridgeValue] {
        try paths.map { path in
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard data.count <= 10_000_000 else { throw CLIError.usage("Each image must be smaller than 10 MB.") }
            let mime = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "image/jpeg" : "image/png"
            return .string("data:\(mime);base64,\(data.base64EncodedString())")
        }
    }

    static let pluginPlacements = "mainSidebar|conversationSidebar|conversationToolbar|composerActions"

    static func parseFlags(_ args: [String], valueFlags: Set<String>) throws -> [String: [String]] {
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

    static func requiredFlag(_ name: String, flags: [String: [String]]) throws -> [String] {
        guard let values = flags[name], !values.isEmpty else { throw CLIError.usage("Missing required option \(name).") }
        return values
    }

    static func draftImageDataURL(_ path: String) throws -> BridgeValue {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let mime: String
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { mime = "image/png" }
        else if data.starts(with: [255, 216, 255]) { mime = "image/jpeg" }
        else { throw CLIError.usage("Images must be PNG or JPEG files.") }
        return .string("data:\(mime);base64,\(data.base64EncodedString())")
    }

    static func keyedOptions(_ values: [String]) throws -> [String: String] {
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

    static func firstPositional(_ args: [String]) throws -> String {
        guard let value = args.first, args.count == 1 else { throw CLIError.usage("Expected exactly one task ID.") }
        return value
    }

    static func printResponse(_ response: BridgeResponse) { printJSON(response) }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func exitStatus(for code: String?) -> Int32 {
        switch code {
        case "invalid_argument", "unsupported_version", "unknown_command": 2
        case "not_found": 3
        case "service_unavailable": 69
        default: 1
        }
    }

    static let helpText = """
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
      playhouse task outcome <task-id> <completed|waiting-response|blocked> [--reason <text>]
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
      playhouse plugin author --placement <mainSidebar|conversationSidebar|conversationToolbar|composerActions> [--provider <codex|claude>] [--name <name> --presentation <popover|modal|sidebar|page>]
      playhouse plugin sessions | edit --id <plugin-id>
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
      playhouse mentions list --task <task-id> [--query <text>]
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
      playhouse settings get|clear-parent|set-parent <path>|set-last-repositories --repo <path>...|set-appearance <dark|light>|set-default-provider <codex|claude>|set-token-usage-color-max <tokens>|set-cpu-usage-color-max <percent>|set-status-sounds <on|off>
      playhouse settings set-auto-compaction [--enabled <true|false>] [--threshold <tokens>] [--idle-minutes <minutes>] [--minimum <tokens>]
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

enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? { if case .usage(let message) = self { message } else { "Invalid CLI arguments." } }
}
