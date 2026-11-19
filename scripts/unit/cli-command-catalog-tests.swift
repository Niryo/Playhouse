import Foundation

// Unit checks of Playhouse/Bridge/CLICommandCatalog.swift against the CLI's parser, compiled
// with the CLI's sources except its entry point and run by scripts/test-e2e.sh before the
// bridge suite. They fail when a command the parser handles has no help entry, or a declared
// command has no handler; the bridge case `test_cli_help_lists_commands_by_group_and_audience`
// covers the help the built CLI prints.

/// Stands in for the CLI's `@main` type from PlayhouseCLI.swift, which this test replaces.
enum PlayhouseCLI {}

@main
struct CLICommandCatalogTests {
    static var failures: [String] = []
    static var checks = 0

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !condition { failures.append(message()) }
    }

    /// Whether running `args` reaches a handler. Local commands get an extra argument so they
    /// only report their usage and never run. Other commands are parsed with a placeholder
    /// ID after their words, which gets past a group's own argument count check to its
    /// operation switch, and handled means that call is anything but `CLIError.unknownCommand`
    /// or the bare command parses into a request (a command that takes no ID, like `chat open`).
    static func isHandled(_ args: [String]) -> Bool {
        do {
            if try PlayhouseCLI.runLocally(args + ["--unit-check"]) != nil { return true }
        } catch CLIError.unknownCommand {
            return false
        } catch {
            return true
        }
        if (try? PlayhouseCLI.parse(args)) != nil { return true }
        do {
            _ = try PlayhouseCLI.parse(args + ["00000000-0000-0000-0000-000000000000"])
        } catch CLIError.unknownCommand {
            return false
        } catch {}
        return true
    }

    enum HelpOutcome: Equatable { case refused, notHelp, help([String], CLIAudience?) }

    static func help(_ args: [String]) -> HelpOutcome {
        do {
            guard let request = try PlayhouseCLI.helpRequest(args) else { return .notHelp }
            return .help(request.words, request.audience)
        } catch {
            return .refused
        }
    }

    static func main() {
        let catalog = CLICommandCatalog.commands

        // Every declared command reaches a handler: help and the side chat hook in the
        // CLI's entry point, every other command in its local commands or its parser.
        for command in catalog {
            expect(!command.summary.isEmpty, "\(command.path) has no description.")
            for path in command.expandedPaths {
                let args = path.split(separator: " ").map(String.init)
                switch args[0] {
                case "help":
                    expect(help(args) == .help([], nil), "help is not a help request.")
                case "hook":
                    expect(args == SideChatReadOnlyPolicy.hookSubcommand, "The CLI's hook is \(SideChatReadOnlyPolicy.hookSubcommand), not \(path).")
                default:
                    expect(isHandled(args), "`\(path)` is declared in CLICommandCatalog but the parser doesn't handle it.")
                }
            }
        }
        let usages = catalog.map(\.usage)
        expect(Set(usages).count == usages.count, "A command is declared twice: \(usages.filter { usage in usages.filter { $0 == usage }.count > 1 }).")

        // Every command word the parser switches on is declared, so the parser can't handle a
        // command that help doesn't list; the gate in `parse` refuses anything else.
        let words = Set(catalog.flatMap { $0.words.flatMap { $0 } })
        if CommandLine.arguments.count > 1, let source = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) {
            let caseLine = try! NSRegularExpression(pattern: #"^\s*case ([^:\n]*):"#, options: .anchorsMatchLines)
            let literal = try! NSRegularExpression(pattern: #""([^"\\]*)""#)
            var literals = 0
            for match in caseLine.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let patterns = String(source[Range(match.range(at: 1), in: source)!])
                // Bindings and array patterns match a command's arguments, not its words.
                guard !patterns.hasPrefix("let "), !patterns.hasPrefix("[") else { continue }
                for value in literal.matches(in: patterns, range: NSRange(patterns.startIndex..., in: patterns)) {
                    let word = String(patterns[Range(value.range(at: 1), in: patterns)!])
                    guard !word.hasPrefix("--") else { continue }
                    literals += 1
                    expect(words.contains(word), "The parser handles `\(word)`, which no CLICommandCatalog declaration names.")
                }
            }
            expect(literals > 100, "The parser source should have its command cases (found \(literals)).")
        } else {
            expect(false, "Pass the path of PlayhouseCLIParsing.swift.")
        }

        // The parser refuses what isn't declared, and the error points at help.
        for args in [["frobnicate"], ["task"], ["task", "bogus"], ["schedule", "frob"], ["chat", "page", "nope"], ["conversation", "nope", "id"]] {
            expect(!isHandled(args), "`\(args.joined(separator: " "))` should be refused as an unknown command.")
            expect(CLIError.unknownCommand(args).localizedDescription.contains("help"), "The unknown command error for \(args) should point at help.")
        }
        expect(CLIError.unknownCommand(["chat", "open", "extra"]).localizedDescription == "Use: playhouse chat open",
               "A declared command with arguments its handler can't read gets its declared usage.")

        // Help requests: whole, one group either way, one audience, and refusals.
        expect(help([]) == .help([], nil), "No arguments asks for the full help.")
        expect(help(["task", "--help"]) == .help(["task"], nil), "`task --help` asks for the task group.")
        expect(help(["task", "get", "123", "-h"]) == .help(["task", "get"], nil), "A task ID after the command words isn't part of the selection.")
        expect(help(["help", "schedule", "--for", "chat"]) == .help(["schedule"], .chat), "--for names the audience.")
        expect(help(["task", "--help", "--for", "side-chat"]) == .help(["task"], .sideChat), "--for also follows `<group> --help`.")
        expect(help(["task", "list"]) == .notHelp, "An ordinary command isn't a help request.")
        expect(help(["conversation", "send", "ID", "--message", "--help"]) == .notHelp, "A --help that is an option's value isn't a help request.")
        expect(help(["help", "nosuch"]) == .refused, "An unknown group is refused.")
        expect(help(["help", "--for", "nobody"]) == .refused, "An unknown audience is refused.")

        // Audiences: agents never see internal commands, and chats never see task-only ones.
        for audience in CLIAudience.allCases {
            let listed = CLICommandCatalog.commands(selecting: [], for: audience)
            expect(!listed.contains(where: \.isInternal), "The \(audience.rawValue) help lists an internal command.")
            expect(listed.contains { $0.path == "help" }, "The \(audience.rawValue) help doesn't list help itself.")
        }
        let chatUsages = CLICommandCatalog.commands(selecting: [], for: .chat).map(\.usage)
        for taskOnly in ["task outcome", "task progress publish", "task pr autopilot", "--discard-changes", "schedule tick"] {
            expect(!chatUsages.contains { $0.contains(taskOnly) }, "The chat's help lists \(taskOnly).")
        }
        for needed in ["task create", "schedule set", "schedule list", "chat page close-turn"] {
            expect(chatUsages.contains { $0.hasPrefix(needed) }, "The chat's help doesn't list \(needed).")
        }
        // The side chat's audience is its permission list; widening it grants a read-only chat a command.
        expect(SideChatReadOnlyPolicy.allowedCLICommands == ["help", "version", "task list", "task get", "task show", "task create", "task rename", "task prompt", "workspace repos list"],
               "The side chat's commands changed: \(SideChatReadOnlyPolicy.allowedCLICommands).")
        // Every protocol command the agent instructions embed is declared.
        if CommandLine.arguments.count > 2, let instructions = try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8) {
            let invocation = try! NSRegularExpression(pattern: #"CLICommandCatalog\.invocation\("([^"]+)""#)
            let paths = invocation.matches(in: instructions, range: NSRange(instructions.startIndex..., in: instructions))
                .map { String(instructions[Range($0.range(at: 1), in: instructions)!]) }
            expect(paths.count >= 10, "The instructions should build their protocol commands from the catalog (found \(paths.count)).")
            for path in paths { expect(CLICommandCatalog.declares(path), "The instructions embed `\(path)`, which the CLI doesn't declare.") }
        } else {
            expect(false, "Pass the path of CodexTaskInstructions.swift.")
        }
        // Claude's side chat hook refuses what the daemon refuses a sandboxed Codex side chat.
        let cli = "/Applications/Playhouse.app/Contents/MacOS/playhouse-cli"
        func hookAllows(_ subcommand: String) -> Bool {
            SideChatReadOnlyPolicy.allows(toolName: "Bash", input: ["command": "'\(cli)' \(subcommand)"], cliPaths: [cli])
        }
        expect(hookAllows("help --for side-chat"), "The side chat hook allows its help.")
        expect(hookAllows("task prompt ID --text 'Fix it'"), "The side chat hook allows saving a prompt.")
        expect(!hookAllows("task prompt ID --text 'Fix it' --status 'In Progress' --submitted true"), "The side chat hook refuses starting a task.")
        expect(!hookAllows("task move ID Done"), "The side chat hook refuses moving a task.")

        if failures.isEmpty {
            print("CLI command catalog checks passed: \(checks) checks over \(catalog.count) declarations.")
        } else {
            FileHandle.standardError.write(Data((failures.map { "FAIL: \($0)" }.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
    }
}
